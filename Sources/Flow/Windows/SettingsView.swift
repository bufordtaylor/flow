import AppKit
import FlowCore
import ServiceManagement
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general = "General", speech = "Speech", cleanup = "Cleanup", apps = "Apps", privacy = "Privacy"
    var height: CGFloat {
        switch self {
        case .general: return 520
        case .speech: return 480
        case .cleanup: return 560
        case .apps: return 480
        case .privacy: return 420
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var tab: SettingsTab = .general
    var onHeight: (CGFloat) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(SettingsTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(12)
            Divider()
            Group {
                switch tab {
                case .general: GeneralTab()
                case .speech: SpeechTab()
                case .cleanup: CleanupTab()
                case .apps: AppsTab()
                case .privacy: PrivacyTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 560)
        .frame(height: tab.height)
        .onChange(of: tab) { _, t in onHeight(t.height) }
        .onAppear { onHeight(tab.height) }
    }
}

// MARK: General

struct GeneralTab: View {
    @EnvironmentObject var state: AppState
    @State private var mode = Settings.shared.hotkeyMode
    @State private var trailing = Settings.shared.trailingSpace
    @State private var sounds = Settings.shared.playSounds
    @State private var login = Settings.shared.launchAtLogin
    @State private var loginError = ""

    var body: some View {
        Form {
            Section("Hotkey") {
                HotkeyRecorder(spec: state.hotkey) { s in
                    Settings.shared.hotkey = s
                    AppCoordinator.shared.applyConfig()
                }
                Text("Press a key with modifiers (⌃⌥ Space), or press and release a single modifier on its own (⌥ (right)). A lone modifier has to be held 120 ms before it counts, so ⌥-shortcuts still work.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).clipCheck("settings", "hotkey-help")
                Picker("Mode", selection: $mode) {
                    Text("Hold to talk").tag(HotkeyMode.hold)
                    Text("Tap to start, tap to stop").tag(HotkeyMode.toggle)
                }
                .onChange(of: mode) { _, m in Settings.shared.hotkeyMode = m; AppCoordinator.shared.applyConfig() }
            }
            Section("Behavior") {
                Toggle("Add a trailing space after inserted text", isOn: $trailing).onChange(of: trailing) { _, v in Settings.shared.trailingSpace = v; AppCoordinator.shared.applyConfig() }
                Toggle("Play start and stop sounds", isOn: $sounds).onChange(of: sounds) { _, v in Settings.shared.playSounds = v }
                Toggle("Launch at login", isOn: $login).onChange(of: login) { _, v in setLogin(v) }
                if !loginError.isEmpty { Text(loginError).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            Settings.shared.launchAtLogin = on
            loginError = ""
        } catch {
            loginError = "Launch at login needs the bundled app (make run): \(error.localizedDescription)"
            login = Settings.shared.launchAtLogin
        }
    }
}

/// Records a key with modifiers, or a lone modifier pressed and released with nothing in between.
struct HotkeyRecorder: View {
    @State var spec: HotkeySpec
    var onChange: (HotkeySpec) -> Void
    @State private var recording = false
    @State private var liveFlags: UInt64 = 0
    @State private var candidateModifier: Int64?
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(recording ? (liveFlags == 0 ? "Press the hotkey…" : HotkeySpec(keyCode: -1, modifiers: liveFlags).modifiersOnlyDisplay) : spec.displayString)
                .frame(minWidth: 140, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(recording ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            if recording {
                Button("Cancel") { stop() }
            } else {
                Button("Record") { start() }
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        liveFlags = 0
        candidateModifier = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { ev in
            handle(ev)
            return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
        liveFlags = 0
    }

    private func handle(_ ev: NSEvent) {
        let flags = UInt64(ev.modifierFlags.rawValue) & HotkeyMatcher.relevantMask
        switch ev.type {
        case .flagsChanged:
            let code = Int64(ev.keyCode)
            if flags != 0 {
                // A modifier appeared. Remember it in case nothing else follows; don't finish yet.
                if liveFlags == 0, HotkeyMatcher.modifierBit(forKeyCode: code) != nil { candidateModifier = code } else { candidateModifier = nil }
                liveFlags = flags
            } else {
                // Everything released. A single modifier with no key in between is the hotkey.
                if let c = candidateModifier {
                    finish(HotkeySpec(keyCode: c, modifiers: 0))
                } else {
                    liveFlags = 0
                }
            }
        case .keyDown:
            if ev.keyCode == 53 { stop(); return }
            candidateModifier = nil
            finish(HotkeySpec(keyCode: Int64(ev.keyCode), modifiers: flags))
        default: break
        }
    }

    private func finish(_ s: HotkeySpec) {
        spec = s
        stop()
        onChange(s)
    }
}

extension HotkeySpec {
    var modifiersOnlyDisplay: String {
        var parts: [String] = []
        if modifiers & HotkeyMatcher.control != 0 { parts.append("⌃") }
        if modifiers & HotkeyMatcher.option != 0 { parts.append("⌥") }
        if modifiers & HotkeyMatcher.shift != 0 { parts.append("⇧") }
        if modifiers & HotkeyMatcher.command != 0 { parts.append("⌘") }
        if modifiers & HotkeyMatcher.fn != 0 { parts.append("fn") }
        return parts.joined() + " …"
    }
}

// MARK: Speech

struct SpeechTab: View {
    @EnvironmentObject var state: AppState
    @State private var testResult = ""
    @State private var testing = false

    var body: some View {
        Form {
            Section("Model") {
                LabeledContent("Model", value: "Parakeet TDT 0.6B v3 (CoreML, FluidAudio)")
                LabeledContent("Folder") {
                    HStack {
                        Text(Settings.shared.modelPath.path).lineLimit(1).truncationMode(.middle)
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Settings.shared.modelPath]) }
                    }
                }
                LabeledContent("Checksum") {
                    HStack {
                        Text(state.modelChecksum ?? "—").font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(state.modelChecksum ?? "", forType: .string) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).disabled(state.modelChecksum == nil)
                    }
                }
                LabeledContent("Status", value: statusText).clipCheck("settings", "model-status")
                if let p = state.downloadProgress {
                    ProgressView(value: p.fraction) { Text(p.file).font(.caption).lineLimit(1).truncationMode(.middle) }
                }
                if let e = state.downloadError { Text(e).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Button("Re-download") { AppCoordinator.shared.downloadModel() }.disabled(state.downloadProgress != nil)
                    Button("Load from folder…") {
                        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                        if p.runModal() == .OK, let u = p.url { AppCoordinator.shared.importModel(from: u) }
                    }
                }
            }
            Section("Test") {
                HStack {
                    Button(testing ? "Transcribing…" : "Test with hello_world.wav") { runTest() }.disabled(testing || !state.modelInstalled)
                    Text(testResult).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private var statusText: String {
        switch state.modelStatus {
        case .notLoaded: return state.modelInstalled ? "Installed, not loaded yet" : "Not installed"
        case .loading: return "Compiling model…"
        case .ready(let ms): return String(format: "Compiled, loads in %.1f s", Double(ms) / 1000)
        case .failed(let s): return "Failed: \(s)"
        }
    }

    private func runTest() {
        guard let url = Fixtures.url("hello_world.wav") else { testResult = "fixtures/hello_world.wav not found"; return }
        testing = true
        Task {
            do {
                let (text, ms) = try await AppCoordinator.shared.transcriber.transcribeFile(url)
                testResult = "“\(text)” in \(ms) ms"
            } catch { testResult = error.localizedDescription }
            testing = false
        }
    }
}

enum Fixtures {
    static func url(_ name: String) -> URL? {
        let n = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        if let u = Bundle.main.url(forResource: n, withExtension: ext) { return u }
        let local = URL(fileURLWithPath: "fixtures").appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: local.path) { return local }
        let tr = URL(fileURLWithPath: "fixtures/transcripts").appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: tr.path) ? tr : nil
    }
}

// MARK: Cleanup

struct CleanupTab: View {
    @EnvironmentObject var state: AppState
    @State private var backend = Settings.shared.cleanupBackend
    @State private var ollamaModel = Settings.shared.ollamaModel
    @State private var tone = AppCoordinator.shared.db.appStyle(for: nil).tone
    @State private var pullStatus = ""
    @State private var pulling = false
    @State private var testBefore = ""
    @State private var testAfter = ""
    @State private var testMs = 0
    @State private var testing = false

    var body: some View {
        Form {
            Section("Backend") {
                ForEach(CleanupBackend.allCases, id: \.self) { b in
                    BackendRow(backend: b, selected: backend == b, availability: availabilityOf(b)) { pick(b) }
                }
            }
            Section("Ollama") {
                HStack {
                    TextField("Model", text: $ollamaModel).onSubmit { saveModel() }
                    Menu {
                        ForEach(suggestions, id: \.self) { m in
                            Button(m) { ollamaModel = m; saveModel() }
                        }
                    } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).frame(width: 24)
                    Button(pulling ? "Pulling…" : "Pull") { pull() }.disabled(pulling)
                }
                if !pullStatus.isEmpty { Text(pullStatus).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
            }
            Section("Style") {
                Picker("Default tone", selection: $tone) {
                    ForEach(["formal", "neutral", "casual", "raw"], id: \.self) { Text($0.capitalized).tag($0) }
                }
                .onChange(of: tone) { _, t in
                    var s = AppCoordinator.shared.db.appStyle(for: nil); s.tone = t
                    try? AppCoordinator.shared.db.saveAppStyle(s)
                }
            }
            Section("Test") {
                Button(testing ? "Cleaning…" : "Test with sample.txt") { runTest() }.disabled(testing)
                if !testBefore.isEmpty {
                    LabeledContent("Before", value: testBefore)
                    LabeledContent("After", value: testAfter)
                    LabeledContent("Round trip", value: "\(testMs) ms")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onChange(of: state.cleanupBackend) { _, b in backend = b }
    }

    private func availabilityOf(_ b: CleanupBackend) -> CleanerAvailability {
        state.availability[b] ?? CleanerAvailability(available: b == .rules || b == .off)
    }

    private var suggestions: [String] {
        let base = ["qwen3:4b", "gemma3:4b", "llama3.2:3b"]
        return base + state.ollamaTags.filter { !base.contains($0) }
    }

    private func pick(_ b: CleanupBackend) {
        backend = b
        AppCoordinator.shared.setBackend(b)
    }

    private func saveModel() {
        Settings.shared.ollamaModel = ollamaModel.trimmingCharacters(in: .whitespaces)
        AppCoordinator.shared.applyConfig()
        Task { await AppCoordinator.shared.refreshAvailability(probeOllama: true) }
    }

    private func pull() {
        guard let o = AppCoordinator.shared.ollama else { pullStatus = "Ollama URL isn't loopback"; return }
        saveModel()
        pulling = true
        let name = ollamaModel
        Task {
            do {
                try await o.pull(model: name) { status, done, total in
                    Task { @MainActor in
                        pullStatus = total > 0 ? String(format: "%@ %.0f%%", status, Double(done) / Double(total) * 100) : status
                    }
                }
                pullStatus = "Pulled \(name)"
            } catch { pullStatus = "Pull failed: \(error)" }
            pulling = false
            await AppCoordinator.shared.refreshAvailability()
        }
    }

    private func runTest() {
        guard let url = Fixtures.url("sample.txt"), let raw = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
            testBefore = "fixtures/transcripts/sample.txt not found"; return
        }
        testing = true
        testBefore = raw
        Task {
            let t0 = Date()
            let cleaner = AppCoordinator.shared.cleaners.cleaner(for: backend)
            do {
                let out = try await cleaner?.clean(raw, context: CleanupContext()) ?? raw
                testAfter = CleanupGuards.normalize(out)
            } catch { testAfter = "Error: \(error)" }
            testMs = Int(Date().timeIntervalSince(t0) * 1000)
            testing = false
        }
    }
}

private struct BackendRow: View {
    let backend: CleanupBackend
    let selected: Bool
    let availability: CleanerAvailability
    let pick: () -> Void

    private var reason: String {
        if !availability.reason.isEmpty { return availability.reason }
        return backend == .off ? "Insert the raw transcript" : ""
    }

    var body: some View {
        HStack(alignment: .top) {
            Button(action: pick) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(availability.available ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain).disabled(!availability.available)
            VStack(alignment: .leading, spacing: 2) {
                Text(backend.title).foregroundStyle(availability.available ? Color.primary : Color.secondary)
                Text(reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .clipCheck("settings", "reason-\(backend.rawValue)")
            }
        }
    }
}

// MARK: Apps

struct AppsTab: View {
    @State private var styles: [AppStyle] = []
    @State private var selection: String?
    private var db: FlowDatabase { AppCoordinator.shared.db }

    var body: some View {
        VStack(spacing: 10) {
            Table($styles, selection: $selection) {
                TableColumn("App") { $s in Text(s.appName) }.width(min: 80, ideal: 100)
                TableColumn("Tone") { $s in
                    Picker("", selection: $s.tone) { ForEach(["formal", "neutral", "casual", "raw"], id: \.self) { Text($0).tag($0) } }
                        .labelsHidden().onChange(of: s.tone) { _, _ in try? db.saveAppStyle(s) }
                }.width(90)
                TableColumn("Format") { $s in
                    Picker("", selection: $s.format) { ForEach(["plain", "markdown"], id: \.self) { Text($0).tag($0) } }
                        .labelsHidden().onChange(of: s.format) { _, _ in try? db.saveAppStyle(s) }
                }.width(100)
                TableColumn("Hint") { $s in TextField("", text: $s.hint).onSubmit { try? db.saveAppStyle(s) } }
            }
            HStack {
                Button("Add current app") { addCurrent() }
                Button("Delete") { if let id = selection { try? db.deleteAppStyle(bundleId: id); reload() } }
                    .disabled(selection == nil || selection == "*")
                Spacer()
                Text("Tone “raw” skips cleanup for that app.").font(.callout).foregroundStyle(.secondary).clipCheck("settings", "raw-hint")
            }
        }
        .padding(20)
        .onAppear(perform: reload)
    }

    private func reload() { styles = db.appStyles() }

    private func addCurrent() {
        guard let app = AppCoordinator.shared.windows.previousApp, let id = app.bundleIdentifier else { return }
        let base = db.appStyle(for: nil)
        try? db.saveAppStyle(AppStyle(bundleId: id, appName: app.localizedName ?? id, tone: base.tone, hint: base.hint, format: base.format))
        reload()
        selection = id
    }
}

// MARK: Privacy

struct PrivacyTab: View {
    @EnvironmentObject var state: AppState
    @State private var store = Settings.shared.storeTranscripts
    @State private var days = Settings.shared.historyRetentionDays
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section("History") {
                Toggle("Store transcripts in History", isOn: $store).onChange(of: store) { _, v in Settings.shared.storeTranscripts = v; AppCoordinator.shared.applyConfig() }
                Stepper(value: $days, in: 0...3650, step: days >= 30 ? 30 : 1) {
                    Text(days == 0 ? "Keep history forever" : "Keep history for \(days) days")
                }
                .onChange(of: days) { _, v in Settings.shared.historyRetentionDays = v; AppCoordinator.shared.sweepHistory() }
                Button("Delete all history", role: .destructive) { confirmDelete = true }
                    .confirmationDialog("Delete every dictation?", isPresented: $confirmDelete) {
                        Button("Delete all", role: .destructive) { try? AppCoordinator.shared.db.deleteAllHistory() }
                    }
            }
            Section("The guarantee") {
                Text(guarantee).fixedSize(horizontal: false, vertical: true).clipCheck("settings", "guarantee")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private var guarantee: String {
        let when = state.modelDownloadedAt.map { $0.formatted(date: .long, time: .shortened) } ?? "a date not recorded yet"
        return "Audio and text never leave this Mac. The app made one network request, on \(when), to download the speech model. With Ollama as the cleaner, text goes to a local process on 127.0.0.1."
    }
}
