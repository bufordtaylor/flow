import Foundation

public enum PipelineState: String, Sendable, Equatable {
    case idle, listening, finalizing, cleaning, inserting
}

public struct PipelineConfig: Sendable, Equatable {
    public var cleanupBackend: CleanupBackend = .rules
    public var cleanupModel: String? = nil
    public var hotkeyMode: HotkeyMode = .hold
    public var trailingSpace = true
    public var storeTranscripts = true
    public var cleanupTimeoutMs = 4_000
    public var finalWaitMs = 3_000
    public var tapThresholdMs = 250
    public var maxDictationMs = 300_000
    public var sttModel = ModelLayout.modelName
    public init() {}
}

public enum PipelineEvent: Sendable, Equatable {
    case listening(level: Float, interim: String)
    case transcribing
    case cleaning
    /// Final text was inserted (or put on the clipboard). Show it with a checkmark, then hide.
    case done(text: String, result: InsertResult)
    case error(String)
    /// Hide the overlay with nothing to say (cancelled, empty transcript).
    case idle
    case timings(sttMs: Int, cleanupMs: Int?, insertMs: Int)
    /// A model backend threw "unavailable"; the app should notify and refresh availability.
    case backendUnavailable(CleanupBackend)
}

/// idle → listening → finalizing → cleaning → inserting → idle, with cancel from listening and finalizing.
public actor DictationPipeline {
    public private(set) var state: PipelineState = .idle
    public var config: PipelineConfig

    private let audio: AudioSource
    private let transcriber: Transcriber
    private let cleaners: CleanerFactory
    private let inserter: TextInserter
    private let frontmost: FrontmostApp
    private let store: PipelineStore
    private let clock: Clock

    public nonisolated let events: AsyncStream<PipelineEvent>
    private let eventCont: AsyncStream<PipelineEvent>.Continuation

    private final class Session: @unchecked Sendable {
        let id = UUID()
        let startedAt: Date
        let bundleId: String
        let appName: String
        var lastInterim = ""
        var finalText: String?
        var finalCont: CheckedContinuation<String?, Never>?
        var forwardCont: AsyncStream<[Float]>.Continuation?
        var tasks: [Task<Void, Never>] = []
        var capTask: Task<Void, Never>?
        var cleanupTask: Task<String, Error>?
        var transcriberError: String?
        init(startedAt: Date, bundleId: String, appName: String) {
            self.startedAt = startedAt; self.bundleId = bundleId; self.appName = appName
        }
    }
    private var session: Session?

    public init(audio: AudioSource, transcriber: Transcriber, cleaners: CleanerFactory, inserter: TextInserter,
                frontmost: FrontmostApp, store: PipelineStore, clock: Clock = SystemClock(), config: PipelineConfig = PipelineConfig()) {
        self.audio = audio
        self.transcriber = transcriber
        self.cleaners = cleaners
        self.inserter = inserter
        self.frontmost = frontmost
        self.store = store
        self.clock = clock
        self.config = config
        (events, eventCont) = AsyncStream.makeStream(of: PipelineEvent.self, bufferingPolicy: .unbounded)
    }

    public func setConfig(_ c: PipelineConfig) { config = c }

    // MARK: Hotkey entry points

    public func hotkeyDown() async {
        switch config.hotkeyMode {
        case .hold: await begin()
        case .toggle: await toggle()
        }
    }

    public func hotkeyUp() async {
        guard config.hotkeyMode == .hold else { return }
        await end()
    }

    /// Option-click on the menu bar icon, or the second tap in toggle mode.
    public func toggle() async {
        switch state {
        case .idle: await begin()
        case .listening: await end()
        default: break
        }
    }

    /// Escape. While listening or finalizing: cancel, write a `cancelled` row. While cleaning: skip the cleaner.
    public func escape() async {
        switch state {
        case .listening, .finalizing: cancel(silent: false)
        case .cleaning: session?.cleanupTask?.cancel()
        default: break
        }
    }

    /// Another key was pressed while the hotkey was held: it was a shortcut. Cancel with no row.
    public func abort() {
        cancel(silent: true)
    }

    // MARK: Stages

    private func begin() async {
        guard state == .idle else { return }
        let s = Session(startedAt: clock.now(), bundleId: frontmost.bundleId ?? "", appName: frontmost.name ?? "")
        let stream: AsyncStream<[Float]>
        do { stream = try audio.start() } catch {
            Log.error("audio", "engine start failed: \(error)")
            emit(.error("Couldn't open the microphone"))
            return
        }
        state = .listening
        session = s
        let (forward, fc) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .unbounded)
        s.forwardCont = fc
        let transcriptEvents = transcriber.transcribe(audio: forward)
        let id = s.id
        s.tasks.append(Task { [weak self] in
            for await chunk in stream {
                fc.yield(chunk)
                await self?.chunkArrived(level: Level.rms(chunk), session: id)
            }
            fc.finish()
        })
        s.tasks.append(Task { [weak self] in
            do {
                for try await ev in transcriptEvents { await self?.transcriptEvent(ev, session: id) }
            } catch {
                await self?.transcriberFailed(error, session: id)
            }
        })
        let capMs = config.maxDictationMs
        s.capTask = Task { [weak self, clock] in
            await clock.sleep(ms: capMs)
            guard !Task.isCancelled else { return }
            // Fresh unstructured task: end() cancels this one, and the final-transcript wait must not inherit that.
            Task { await self?.capReached(session: id) }
        }
        Log.info("pipeline", "listening app=\(s.bundleId)")
        emit(.listening(level: 0, interim: ""))
    }

    private func capReached(session id: UUID) async {
        guard session?.id == id, state == .listening else { return }
        await end()
    }

    private func chunkArrived(level: Float, session id: UUID) {
        guard let s = session, s.id == id, state == .listening else { return }
        emit(.listening(level: level, interim: s.lastInterim))
    }

    private func transcriptEvent(_ ev: TranscriptEvent, session id: UUID) {
        guard let s = session, s.id == id else { return }
        switch ev {
        case .interim(let t):
            s.lastInterim = t
            if state == .listening { emit(.listening(level: 0, interim: t)) }
        case .final(let t):
            s.finalText = t
            s.finalCont?.resume(returning: t)
            s.finalCont = nil
        }
    }

    private func transcriberFailed(_ error: Error, session id: UUID) {
        guard let s = session, s.id == id else { return }
        let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        Log.error("stt", msg)
        s.transcriberError = msg
        if state == .listening {
            // Nothing to transcribe with: stop here and say why.
            audio.stop()
            s.capTask?.cancel()
            s.forwardCont?.finish()
            s.tasks.forEach { $0.cancel() }
            record(session: s, raw: nil, cleaned: nil, inserted: nil, method: "failed", backend: .off,
                   sttMs: 0, cleanupMs: nil, wordCount: 0, error: msg, keyUpAt: clock.now())
            state = .idle
            session = nil
            emit(.error(msg))
        } else {
            s.finalCont?.resume(returning: nil)
            s.finalCont = nil
        }
    }

    private func waitForFinal(session id: UUID) async -> String? {
        guard let s = session, s.id == id else { return nil }
        if let f = s.finalText { return f }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
                if let f = s.finalText { c.resume(returning: f) } else { s.finalCont = c }
            }
        } onCancel: {
            Task { await self.resumeFinal(nil, session: id) }
        }
    }

    private func resumeFinal(_ text: String?, session id: UUID) {
        guard let s = session, s.id == id else { return }
        s.finalCont?.resume(returning: text)
        s.finalCont = nil
    }

    private func end() async {
        guard state == .listening, let s = session else { return }
        let keyUpAt = clock.now()
        let heldMs = Int(keyUpAt.timeIntervalSince(s.startedAt) * 1000)
        if config.hotkeyMode == .hold && heldMs < config.tapThresholdMs {
            cancel(silent: true)
            return
        }
        state = .finalizing
        s.capTask?.cancel()
        audio.stop()
        emit(.transcribing)

        let id = s.id
        let waitMs = config.finalWaitMs
        let finalText = try? await withTimeout(ms: waitMs, clock: clock) { await self.waitForFinal(session: id) }
        guard state == .finalizing, session?.id == id else { return }  // cancelled while waiting
        s.tasks.forEach { $0.cancel() }
        s.forwardCont?.finish()

        var error: String? = nil
        var raw: String
        if let f = finalText {
            raw = f
        } else {
            raw = s.lastInterim
            error = s.transcriberError == nil ? "stt_timeout" : "stt_error: \(s.transcriberError!)"
        }
        raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let sttMs = ms(since: keyUpAt)
        Log.info("stt", "final in \(sttMs) ms, \(WordCount.count(raw)) words\(error.map { ", \($0)" } ?? "")")
        Log.transcript("stt", raw)

        if raw.isEmpty {
            state = .idle
            session = nil
            emit(.idle)
            return
        }

        // Snippets before cleanup so the model sees the expansion.
        let expanded = Snippets.expand(raw, snippets: store.snippets())
        let style = store.appStyle(for: s.bundleId)
        let dictionary = store.dictionaryEntries()
        var cleaned = expanded
        var backendUsed: CleanupBackend = .off
        var cleanupMs: Int? = nil

        if config.cleanupBackend != .off, style.tone != "raw", let cleaner = cleaners.cleaner(for: config.cleanupBackend) {
            state = .cleaning
            emit(.cleaning)
            let ctx = CleanupContext(tone: style.tone, hint: style.hint, format: style.format, dictionary: dictionary)
            let t0 = clock.now()
            backendUsed = cleaner.backend
            let timeoutMs = config.cleanupTimeoutMs
            let clock = self.clock
            let task = Task { try await withTimeout(ms: timeoutMs, clock: clock) { try await cleaner.clean(expanded, context: ctx) } }
            s.cleanupTask = task
            do {
                let out = try await task.value
                switch CleanupGuards.check(raw: expanded, cleaned: out) {
                case .success(let c): cleaned = c
                case .failure(let f): error = append(error, "cleanup_guard"); Log.info("cleanup", "guard rejected: \(f)")
                }
            } catch is CancellationError {
                error = append(error, "cleanup_skipped")
            } catch is TimeoutError {
                error = append(error, "cleanup_timeout")
            } catch let u as CleanerUnavailableError {
                Log.error("cleanup", "\(cleaner.backend.rawValue) unavailable: \(u.reason); using rules")
                emit(.backendUnavailable(cleaner.backend))
                backendUsed = .rules
                if case .success(let c) = CleanupGuards.check(raw: expanded, cleaned: RulesCleaner.clean(expanded, context: ctx)) { cleaned = c }
                else { error = append(error, "cleanup_guard") }
            } catch let f as CleanerFallbackError {
                Log.info("cleanup", "\(cleaner.backend.rawValue) declined (\(f.reason)); using rules for this one")
                backendUsed = .rules
                error = append(error, "cleanup_guardrail")
                if case .success(let c) = CleanupGuards.check(raw: expanded, cleaned: RulesCleaner.clean(expanded, context: ctx)) { cleaned = c }
            } catch let e {
                Log.error("cleanup", "\(e)")
                error = append(error, "cleanup_error")
            }
            s.cleanupTask = nil
            cleanupMs = ms(since: t0)
            Log.info("cleanup", "\(backendUsed.rawValue) in \(cleanupMs!) ms\(error.map { ", \($0)" } ?? "")")
            Log.transcript("cleanup", cleaned)
        }
        state = .inserting
        var text = cleaned
        if config.trailingSpace && !text.hasSuffix("\n") { text += " " }
        let t1 = clock.now()
        let result = await inserter.insert(text)
        let insertMs = ms(since: t1)
        Log.info("insert", "\(result.method) in \(insertMs) ms")

        var inserted: String? = text
        var secure = false
        if case .failed(let why) = result {
            inserted = nil
            secure = why == "secure field"
            error = append(error, "insert_failed: \(why)")
        }
        let used = dictionary.filter { text.contains($0.term) }.map(\.term)
        store.incrementUse(of: used)
        let storeText = config.storeTranscripts && !secure
        record(session: s, raw: storeText ? raw : nil, cleaned: storeText ? cleaned : nil, inserted: storeText ? inserted : nil,
               method: result.method, backend: backendUsed, sttMs: sttMs, cleanupMs: cleanupMs,
               wordCount: WordCount.count(cleaned), error: error, keyUpAt: keyUpAt)
        emit(.timings(sttMs: sttMs, cleanupMs: cleanupMs, insertMs: insertMs))
        if case .failed(let why) = result { emit(.error(why)) } else { emit(.done(text: cleaned, result: result)) }
        state = .idle
        session = nil
    }

    private func cancel(silent: Bool) {
        guard let s = session, state == .listening || state == .finalizing else { return }
        audio.stop()
        s.capTask?.cancel()
        s.forwardCont?.finish()
        s.tasks.forEach { $0.cancel() }
        s.finalCont?.resume(returning: nil)
        s.finalCont = nil
        if !silent {
            record(session: s, raw: nil, cleaned: nil, inserted: nil, method: "cancelled", backend: .off,
                   sttMs: 0, cleanupMs: nil, wordCount: 0, error: nil, keyUpAt: clock.now())
            Log.info("pipeline", "cancelled")
        } else {
            Log.info("pipeline", "tap ignored")
        }
        state = .idle
        session = nil
        emit(.idle)
    }

    private func record(session s: Session, raw: String?, cleaned: String?, inserted: String?, method: String, backend: CleanupBackend,
                        sttMs: Int, cleanupMs: Int?, wordCount: Int, error: String?, keyUpAt: Date) {
        let d = Dictation(startedAt: s.startedAt, durationMs: Int(keyUpAt.timeIntervalSince(s.startedAt) * 1000),
                          appBundleId: s.bundleId, appName: s.appName, rawText: raw, cleanedText: cleaned, insertedText: inserted,
                          insertMethod: method, sttModel: config.sttModel, cleanupBackend: backend.rawValue,
                          cleanupModel: backend == .ollama || backend == .apple ? config.cleanupModel : nil,
                          sttMs: sttMs, cleanupMs: cleanupMs, wordCount: wordCount, error: error)
        store.record(d)
    }

    private func append(_ existing: String?, _ code: String) -> String {
        existing.map { $0 + "; " + code } ?? code
    }

    private func ms(since d: Date) -> Int { Int(clock.now().timeIntervalSince(d) * 1000) }

    private nonisolated func emit(_ e: PipelineEvent) { eventCont.yield(e) }

    // TODO: command mode — a second hotkey would branch here to edit the selected text instead of inserting.
}
