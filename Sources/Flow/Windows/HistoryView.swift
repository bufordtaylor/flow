import AppKit
import FlowCore
import SwiftUI

struct HistoryView: View {
    @State private var rows: [Dictation] = []
    @State private var search = ""
    @State private var showRaw = Settings.shared.historyShowsRaw
    @State private var stats = WeekStats(rows: 0, words: 0)
    private var db: FlowDatabase { AppCoordinator.shared.db }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $showRaw) {
                    Text("Raw").tag(true)
                    Text("Cleaned").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 160)
                .onChange(of: showRaw) { _, v in Settings.shared.historyShowsRaw = v }
                Spacer()
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 220)
                    .onChange(of: search) { _, _ in reload() }
            }
            .padding(12)
            Divider()
            if rows.isEmpty {
                Text(search.isEmpty ? "No dictations yet." : "No matches.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups, id: \.title) { g in
                        Section(g.title) {
                            ForEach(g.rows) { row in
                                HistoryRow(row: row, showRaw: showRaw, onDelete: { delete(row) })
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Text("\(rows.count) dictation\(rows.count == 1 ? "" : "s")").clipCheck("history", "count")
                Spacer()
                Text("\(stats.words) words this week").clipCheck("history", "words")
            }
            .font(.callout).foregroundStyle(.secondary).padding(10)
        }
        .frame(minWidth: 640, idealWidth: 820, minHeight: 400, idealHeight: 560)
        .onAppear(perform: reload)
    }

    private struct Group { let title: String; let rows: [Dictation] }

    private var groups: [Group] {
        let cal = Calendar.current
        var out: [Group] = []
        for r in rows {
            let day = cal.startOfDay(for: r.startedAt)
            let title: String
            if cal.isDateInToday(day) { title = "Today" }
            else if cal.isDateInYesterday(day) { title = "Yesterday" }
            else { title = day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) }
            if out.last?.title == title { out[out.count - 1] = Group(title: title, rows: out[out.count - 1].rows + [r]) }
            else { out.append(Group(title: title, rows: [r])) }
        }
        return out
    }

    private func reload() {
        if ClipReport.shared.enabled { rows = Self.sampleRows; stats = WeekStats(rows: rows.count, words: 31); return }
        rows = (try? db.dictations(search: search)) ?? []
        stats = db.weekStats()
    }

    /// `--check-windows` renders these so the screenshot shows real rows.
    static let sampleRows: [Dictation] = [
        Dictation(startedAt: Date(), durationMs: 4200, appBundleId: "com.apple.TextEdit", appName: "TextEdit", rawText: "um so send it uh Tuesday no Wednesday",
                  cleanedText: "So send it Wednesday.", insertedText: "So send it Wednesday. ", insertMethod: "ax", sttModel: ModelLayout.modelName,
                  cleanupBackend: "rules", cleanupModel: nil, sttMs: 380, cleanupMs: 4, wordCount: 4, error: nil),
        Dictation(startedAt: Date().addingTimeInterval(-3600), durationMs: 9100, appBundleId: "com.tinyspeck.slackmacgap", appName: "Slack",
                  rawText: "can you take a look at the PR when you get a chance thanks", cleanedText: "can you take a look at the PR when you get a chance? thanks",
                  insertedText: nil, insertMethod: "paste", sttModel: ModelLayout.modelName, cleanupBackend: "ollama", cleanupModel: "qwen3:4b",
                  sttMs: 610, cleanupMs: 4000, wordCount: 13, error: "cleanup_timeout"),
        Dictation(startedAt: Date().addingTimeInterval(-90_000), durationMs: 2000, appBundleId: "com.apple.finder", appName: "Finder", rawText: nil,
                  cleanedText: nil, insertedText: nil, insertMethod: "cancelled", sttModel: ModelLayout.modelName, cleanupBackend: "off", cleanupModel: nil,
                  sttMs: 0, cleanupMs: nil, wordCount: 0, error: nil),
    ]

    private func delete(_ r: Dictation) {
        try? db.deleteDictation(id: r.id)
        reload()
    }
}

private struct HistoryRow: View {
    let row: Dictation
    let showRaw: Bool
    let onDelete: () -> Void

    private var text: String? { showRaw ? row.rawText : row.cleanedText }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: AppIcons.icon(for: row.appBundleId)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(row.appName.isEmpty ? row.appBundleId : row.appName).fontWeight(.medium)
                    Text(row.startedAt.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
                    Text(String(format: "%.1f s", Double(row.durationMs) / 1000)).foregroundStyle(.secondary)
                    Text("\(row.wordCount) words").foregroundStyle(.secondary)
                    if row.rawText != nil, row.rawText == row.cleanedText { Tag("no changes") }
                    if row.insertMethod == "cancelled" { Tag("cancelled") }
                    Spacer()
                    Button("Copy") { copy() }.disabled(text == nil)
                    Button("Insert again") { if let t = text { AppCoordinator.shared.insertAgain(t) } }.disabled(text == nil)
                    Button("Delete", role: .destructive, action: onDelete)
                }
                .font(.callout)
                .buttonStyle(.borderless)
                if let t = text {
                    FlowLayout(spacing: 3) {
                        ForEach(Array(t.split(separator: " ").enumerated()), id: \.offset) { _, w in
                            let word = String(w)
                            Text(word).contextMenu {
                                Button("Add '\(clean(word))' to dictionary") {
                                    _ = try? AppCoordinator.shared.db.addDictionaryEntry(term: clean(word), soundsLike: nil)
                                }
                            }
                        }
                    }
                    .textSelection(.enabled)
                } else {
                    Text(row.insertMethod == "cancelled" ? "Cancelled" : "Not stored").italic().foregroundStyle(.secondary)
                }
                if let e = row.error { Text(Self.describe(e)).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 4)
    }

    private func clean(_ w: String) -> String { w.trimmingCharacters(in: .punctuationCharacters) }

    private func copy() {
        guard let t = text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
    }

    static func describe(_ code: String) -> String {
        code.split(separator: ";").map { part -> String in
            let p = part.trimmingCharacters(in: .whitespaces)
            switch p {
            case "cleanup_timeout": return "Cleanup timed out. Inserted raw text."
            case "cleanup_error": return "Cleanup failed. Inserted raw text."
            case "cleanup_guard": return "Cleanup output looked wrong. Inserted raw text."
            case "cleanup_skipped": return "Cleanup skipped with Escape."
            case "cleanup_guardrail": return "Apple's model declined this one. Used rules."
            case "stt_timeout": return "Final transcript timed out. Used the interim text."
            default: return p
            }
        }.joined(separator: " ")
    }
}

private struct Tag: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary, in: Capsule()).foregroundStyle(.secondary)
    }
}

@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    static func icon(for bundleId: String) -> NSImage {
        if let i = cache[bundleId] { return i }
        let img: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            img = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            img = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        cache[bundleId] = img
        return img
    }
}
