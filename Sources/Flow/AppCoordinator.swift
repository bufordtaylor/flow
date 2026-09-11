import AppKit
import AVFoundation
import FlowCore

/// Wires the pieces together and reacts to pipeline events. Main-actor.
@MainActor
final class AppCoordinator {
    static let shared = AppCoordinator()

    let settings = Settings.shared
    let state = AppState.shared
    let db: FlowDatabase
    let transcriber: ParakeetTranscriber
    let cleaners = CleanerFactory()
    let ollama: OllamaCleaner?
    let inserter = AXInserter()
    let audio: FlowCore.AudioSource = {
        if let p = ProcessInfo.processInfo.environment["FLOW_FAKE_AUDIO"] { return FileAudioSource(url: URL(fileURLWithPath: p)) }
        return AudioEngineSource()
    }()
    let pipeline: DictationPipeline
    let overlay = OverlayController()
    let status = StatusItemController()
    let windows = WindowManager()
    let hotkey: HotkeyTap

    private var axTimer: Timer?
    private var retentionTimer: Timer?
    private var inSession = false
    private var appleAvailability = CleanerAvailability(available: false)

    private init() {
        do { db = try FlowDatabase() } catch { fatalError("Could not open the Flow database: \(error)") }
        let st = state
        transcriber = ParakeetTranscriber(modelPath: settings.modelPath) { s in
            Task { @MainActor in st.modelStatus = s }
        }
        ollama = try? OllamaCleaner(baseURL: settings.ollamaBaseURL, model: settings.ollamaModel)
        hotkey = HotkeyTap(spec: settings.hotkey)
        pipeline = DictationPipeline(audio: audio, transcriber: transcriber, cleaners: cleaners, inserter: inserter,
                                     frontmost: WorkspaceFrontmost(), store: db)
    }

    func start() {
        Log.info("app", "launch \(Bundle.main.bundleIdentifier ?? "(no bundle)")")
        if let o = ollama { cleaners.register(o, availability: CleanerAvailability(available: false, reason: "checking…")) }
        let apple = AppleCleanerSupport.make()
        appleAvailability = apple.availability
        if let c = apple.cleaner { cleaners.register(c, availability: apple.availability) }
        cleaners.setAvailability(.apple, apple.availability)
        state.availability = [.apple: apple.availability, .rules: CleanerAvailability(available: true), .off: CleanerAvailability(available: true)]
        AppleCleanerSupport.prewarm()

        inserter.onNoTextField = { Notify.send("Flow", "No text field was focused. The text is on your clipboard.") }
        inserter.onSecureField = { Notify.send("Flow", "That's a password field. Nothing was inserted.") }

        status.onToggleDictation = { [weak self] in
            guard let self else { return }
            Task { await self.pipeline.toggle() }
        }
        status.onPickBackend = { [weak self] b in self?.setBackend(b) }
        status.onOpen = { [weak self] k in self?.openWindow(k) }
        status.availability = { [weak self] b in self?.cleaners.availability(of: b) ?? CleanerAvailability(available: false) }
        status.update(hotkey: settings.hotkey, mode: settings.hotkeyMode)

        hotkey.onEvent = { [weak self] e in self?.hotkeyEvent(e) }

        applyConfig()
        refreshPermissions()
        axTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }

        Task { for await e in pipeline.events { handle(e) } }
        Task { await refreshAvailability(); autoPickBackendIfNeeded() }
        loadModelIfInstalled()
        sweepHistory()
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sweepHistory() }
        }

        let needsOnboarding = !settings.onboardingDone || !state.micGranted || !state.axTrusted || !state.modelInstalled
        if needsOnboarding { openWindow(.onboarding) }
    }

    // MARK: Config

    func applyConfig() {
        var c = PipelineConfig()
        c.cleanupBackend = settings.cleanupBackend
        c.cleanupModel = settings.cleanupBackend == .ollama ? settings.ollamaModel : (settings.cleanupBackend == .apple ? "apple-foundation" : nil)
        c.hotkeyMode = settings.hotkeyMode
        c.trailingSpace = settings.trailingSpace
        c.storeTranscripts = settings.storeTranscripts
        Task { await pipeline.setConfig(c) }
        hotkey.spec = settings.hotkey
        state.hotkey = settings.hotkey
        state.cleanupBackend = settings.cleanupBackend
        status.update(hotkey: settings.hotkey, mode: settings.hotkeyMode)
        ollama?.model = settings.ollamaModel
        try? ollama?.setBaseURL(settings.ollamaBaseURL)
    }

    func setBackend(_ b: CleanupBackend) {
        settings.cleanupBackend = b
        applyConfig()
    }

    private func autoPickBackendIfNeeded() {
        guard !settings.cleanupBackendChosen else { return }
        let pick: CleanupBackend = appleAvailability.available ? .apple : .ollama
        settings.defaults.set(pick.rawValue, forKey: Settings.Key.cleanupBackend)
        applyConfig()
    }

    /// Apple is always re-read (Apple Intelligence can be toggled). Ollama is probed only when it's the active
    /// backend or when Settings is open (`probeOllama`); otherwise the app never opens a socket for a backend
    /// the user isn't using, so with rules/apple/off the connection list stays empty.
    func refreshAvailability(probeOllama: Bool = false) async {
        appleAvailability = AppleCleanerSupport.refreshAvailability()
        cleaners.setAvailability(.apple, appleAvailability)
        var avail = state.availability
        avail[.apple] = appleAvailability
        if let o = ollama, probeOllama || settings.cleanupBackend == .ollama {
            let a = await o.availability()
            cleaners.setAvailability(.ollama, a)
            avail[.ollama] = a
            state.ollamaTags = await o.tags() ?? []
            Log.info("cleanup", "ollama availability: \(a.available) (\(a.reason)); model=\(settings.ollamaModel)")
        } else if ollama != nil {
            avail[.ollama] = CleanerAvailability(available: false, reason: "Open Cleanup settings to check Ollama.")
        }
        avail[.rules] = CleanerAvailability(available: true, reason: "Always available")
        avail[.off] = CleanerAvailability(available: true)
        state.availability = avail
    }

    // MARK: Permissions and hotkey

    func refreshPermissions() {
        state.micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let trusted = AXIsProcessTrusted()
        state.axTrusted = trusted
        if trusted {
            state.markTrusted()
            if !hotkey.isRunning {
                let ok = hotkey.start()
                state.tapRunning = ok
                if ok { status.setIcon(.idle) } else { status.setIcon(.error) }
            }
        } else {
            state.tapRunning = hotkey.isRunning
        }
        state.modelInstalled = ModelLayout.isComplete(at: settings.modelPath)
    }

    private func hotkeyEvent(_ e: HotkeyTap.Event) {
        switch e {
        case .down: Task { await pipeline.hotkeyDown() }
        case .up: Task { await pipeline.hotkeyUp() }
        case .cancelSilently: Task { await pipeline.abort() }
        case .escape: Task { await pipeline.escape() }
        }
    }

    // MARK: Model

    func loadModelIfInstalled() {
        guard ModelLayout.isComplete(at: settings.modelPath) else { return }
        Task.detached(priority: .userInitiated) { [transcriber] in try? await transcriber.load() }
    }

    func downloadModel() {
        state.downloadError = nil
        state.downloadProgress = DownloadProgress(file: "", fileIndex: 0, fileCount: 0, bytesReceived: 0, bytesTotal: ModelLayout.approximateBytes)
        let dest = settings.modelPath
        let st = state
        Task.detached { [weak self] in
            do {
                let m = try await ModelDownloader(destination: dest).download { p in
                    Task { @MainActor in st.downloadProgress = p }
                }
                await self?.modelReady(m)
            } catch {
                Task { @MainActor in st.downloadError = error.localizedDescription; st.downloadProgress = nil }
            }
        }
    }

    func importModel(from folder: URL) {
        state.downloadError = nil
        let dest = settings.modelPath
        Task.detached { [weak self] in
            do { await self?.modelReady(try ModelDownloader.importFolder(folder, into: dest)) }
            catch { Task { @MainActor [weak self] in self?.state.downloadError = error.localizedDescription } }
        }
    }

    private func modelReady(_ m: ModelManifest) {
        settings.modelChecksum = m.checksum
        settings.modelDownloadedAt = m.downloadedAt
        state.modelChecksum = m.checksum
        state.modelDownloadedAt = m.downloadedAt
        state.downloadProgress = nil
        state.modelInstalled = true
        loadModelIfInstalled()
    }

    // MARK: History

    func sweepHistory() {
        let days = settings.historyRetentionDays
        guard days > 0 else { return }
        if let n = try? db.purgeHistory(olderThanDays: days), n > 0 { Log.info("store", "retention removed \(n) rows") }
        settings.lastRetentionSweep = Date()
    }

    /// History → "Insert again": 1 s so the user can switch windows.
    func insertAgain(_ text: String) {
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let r = await inserter.insert(text)
            Log.info("insert", "insert again: \(r.method)")
        }
    }

    func openWindow(_ kind: WindowKind) {
        if kind == .settings { Task { await refreshAvailability(probeOllama: true) } }
        if kind == .onboarding { refreshPermissions() }
        windows.show(kind)
    }

    // MARK: Pipeline events

    private func handle(_ e: PipelineEvent) {
        switch e {
        case .listening(let level, let interim):
            if !inSession {
                inSession = true
                Sounds.play("start")
                status.setIcon(.listening)
                hotkey.setDictating(true)
                state.pipelineState = .listening
            }
            if case .ready = state.modelStatus { overlay.show(.listening(level: level, interim: interim)) }
            else { overlay.show(.compiling) }
        case .transcribing:
            Sounds.play("stop")
            status.setIcon(.processing)
            state.pipelineState = .finalizing
            overlay.show(.transcribing)
        case .cleaning:
            state.pipelineState = .cleaning
            overlay.show(.cleaning)
        case .done(let text, _):
            endSession(icon: .idle)
            overlay.show(.done(text))
        case .error(let msg):
            endSession(icon: .error)
            overlay.show(.error(msg))
            if msg.hasPrefix("No speech model") { Notify.send("Flow", msg) }
        case .idle:
            endSession(icon: .idle)
            overlay.hide()
        case .timings(let stt, let cleanup, let insert):
            state.lastTimings = (stt, cleanup)
            status.update(timings: (stt, cleanup))
            Log.info("pipeline", "stt=\(stt)ms cleanup=\(cleanup.map(String.init) ?? "-")ms insert=\(insert)ms")
        case .backendUnavailable(let b):
            Notify.send("Flow", "\(b.title) cleanup isn't available. Using rules until it's back.")
            Task { await refreshAvailability() }
        }
    }

    private func endSession(icon: StatusItemController.IconState) {
        inSession = false
        hotkey.setDictating(false)
        status.setIcon(icon)
        state.pipelineState = .idle
    }
}
