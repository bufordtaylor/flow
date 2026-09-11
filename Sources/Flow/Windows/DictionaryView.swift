import AppKit
import FlowCore
import SwiftUI

struct DictionaryView: View {
    @State private var entries: [DictionaryEntry] = []
    @State private var selection: Set<String> = []
    @State private var newTerm = ""
    @State private var newSounds = ""
    @State private var message = ""
    private var db: FlowDatabase { AppCoordinator.shared.db }

    var body: some View {
        VStack(spacing: 0) {
            Table($entries, selection: $selection) {
                TableColumn("Term") { $e in
                    TextField("", text: $e.term).onSubmit { save(e) }
                }
                TableColumn("Sounds like") { $e in
                    TextField("", text: Binding(get: { e.soundsLike ?? "" }, set: { e.soundsLike = $0.isEmpty ? nil : $0 })).onSubmit { save(e) }
                }
                TableColumn("Uses") { $e in Text("\(e.useCount)").foregroundStyle(.secondary) }.width(50)
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Term", text: $newTerm).frame(minWidth: 120)
                TextField("Sounds like (optional)", text: $newSounds).frame(minWidth: 140)
                Button("Add") { add() }.disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty).keyboardShortcut(.defaultAction)
                Button("Delete") { deleteSelected() }.disabled(selection.isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            .padding(10)
            Divider()
            HStack {
                Text("\(entries.count) entr\(entries.count == 1 ? "y" : "ies")").foregroundStyle(.secondary).clipCheck("dictionary", "count")
                if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
                Spacer()
                Button("Import…") { importFile() }
                Button("Export…") { exportFile() }
            }
            .font(.callout)
            .padding(10)
        }
        .frame(minWidth: 420, idealWidth: 520, minHeight: 320, idealHeight: 440)
        .onAppear(perform: reload)
    }

    private func reload() {
        if ClipReport.shared.enabled {
            entries = [DictionaryEntry(term: "Wolchonok", soundsLike: "wall chunk", useCount: 3), DictionaryEntry(term: "GRDB", useCount: 1)]
            return
        }
        entries = db.dictionaryEntries()
    }

    private func add() {
        if (try? db.addDictionaryEntry(term: newTerm, soundsLike: newSounds)) == true {
            newTerm = ""; newSounds = ""; message = ""
        } else { message = "Already in the dictionary." }
        reload()
    }

    private func save(_ e: DictionaryEntry) {
        var copy = e
        copy.term = copy.term.trimmingCharacters(in: .whitespaces)
        guard !copy.term.isEmpty else { reload(); return }
        do { try db.updateDictionaryEntry(copy); message = "" } catch { message = "Term must be unique." }
        reload()
    }

    private func deleteSelected() {
        for id in selection { try? db.deleteDictionaryEntry(id: id) }
        selection = []
        reload()
    }

    private func importFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.plainText]
        guard p.runModal() == .OK, let url = p.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let n = (try? db.importDictionary(text: text)) ?? 0
        message = "Added \(n) term\(n == 1 ? "" : "s")."
        reload()
    }

    private func exportFile() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "flow-dictionary.txt"
        p.allowedContentTypes = [.plainText]
        guard p.runModal() == .OK, let url = p.url else { return }
        try? db.exportDictionary().write(to: url, atomically: true, encoding: .utf8)
    }
}
