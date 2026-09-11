import Foundation
@testable import FlowCore

/// Registers a sleep only when the sleeping task actually runs, so tests `waitForSleeper` before advancing.
final class ManualClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    private var sleepers: [(deadline: Date, ms: Int, cont: CheckedContinuation<Void, Never>)] = []
    private var waiters: [(ms: Int, cont: CheckedContinuation<Void, Never>)] = []
    private(set) var sleepCount = 0

    init(now: Date = Date(timeIntervalSince1970: 1_757_000_000)) { _now = now }

    func now() -> Date { lock.lock(); defer { lock.unlock() }; return _now }

    func sleep(ms: Int) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            sleepers.append((_now.addingTimeInterval(Double(ms) / 1000), ms, c))
            sleepCount += 1
            let woken = waiters.filter { $0.ms == ms }
            waiters.removeAll { $0.ms == ms }
            lock.unlock()
            woken.forEach { $0.cont.resume() }
        }
    }

    func advance(ms: Int) {
        lock.lock()
        _now = _now.addingTimeInterval(Double(ms) / 1000)
        let due = sleepers.filter { $0.deadline <= _now }
        sleepers.removeAll { $0.deadline <= _now }
        lock.unlock()
        due.forEach { $0.cont.resume() }
    }

    /// Returns once some task is parked in `sleep(ms:)` with exactly this duration.
    func waitForSleeper(ms: Int) async {
        lock.lock()
        if sleepers.contains(where: { $0.ms == ms }) { lock.unlock(); return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append((ms, c))
            lock.unlock()
        }
    }
}

final class FakeAudio: AudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var cont: AsyncStream<[Float]>.Continuation?
    var failOnStart = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    struct StartError: Error {}

    func start() throws -> AsyncStream<[Float]> {
        if failOnStart { throw StartError() }
        let (s, c) = AsyncStream.makeStream(of: [Float].self)
        lock.lock(); cont = c; startCount += 1; lock.unlock()
        return s
    }

    func stop() {
        lock.lock(); let c = cont; cont = nil; stopCount += 1; lock.unlock()
        c?.finish()
    }

    func feed(_ samples: [Float]) {
        lock.lock(); let c = cont; lock.unlock()
        c?.yield(samples)
    }
}

final class FakeTranscriber: Transcriber, @unchecked Sendable {
    private let lock = NSLock()
    private var cont: AsyncThrowingStream<TranscriptEvent, Error>.Continuation?
    /// Emitted as `.final` when the audio stream ends. nil = never send a final on its own.
    var finalOnAudioEnd: String?
    var interimOnAudioStart: String?
    var failImmediately: Error?
    private(set) var chunksSeen = 0

    init(finalOnAudioEnd: String? = nil) { self.finalOnAudioEnd = finalOnAudioEnd }

    func transcribe(audio: AsyncStream<[Float]>) -> AsyncThrowingStream<TranscriptEvent, Error> {
        AsyncThrowingStream { c in
            lock.lock(); cont = c; lock.unlock()
            if let e = failImmediately { c.finish(throwing: e); return }
            Task {
                if let i = interimOnAudioStart { c.yield(.interim(i)) }
                for await _ in audio { lock.lock(); chunksSeen += 1; lock.unlock() }
                if let f = finalOnAudioEnd { c.yield(.final(f)); c.finish() }
            }
        }
    }

    func interim(_ s: String) { lock.lock(); let c = cont; lock.unlock(); c?.yield(.interim(s)) }
    func final(_ s: String) { lock.lock(); let c = cont; lock.unlock(); c?.yield(.final(s)); c?.finish() }
    func fail(_ e: Error) { lock.lock(); let c = cont; lock.unlock(); c?.finish(throwing: e) }
}

final class FakeCleaner: Cleaner, @unchecked Sendable {
    enum Mode { case transform(@Sendable (String) -> String), fail(Error), park, unavailable }
    let backend: CleanupBackend
    var mode: Mode
    private let lock = NSLock()
    private(set) var contexts: [CleanupContext] = []
    private(set) var calls = 0

    init(backend: CleanupBackend = .ollama, mode: Mode = .transform({ $0.uppercased() })) {
        self.backend = backend
        self.mode = mode
    }

    func clean(_ raw: String, context: CleanupContext) async throws -> String {
        lock.lock(); contexts.append(context); calls += 1; let m = mode; lock.unlock()
        switch m {
        case .transform(let f): return f(raw)
        case .fail(let e): throw e
        case .unavailable: throw CleanerUnavailableError("gone")
        case .park:
            // Parks until the timeout cancels it — models often ignore cancellation, but leaving a Task
            // suspended forever across a whole suite starves the cooperative pool, so honor cancellation here.
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (_: CheckedContinuation<String, Error>) in }
            } onCancel: {}
        }
    }
}

final class FakeInserter: TextInserter, @unchecked Sendable {
    private let lock = NSLock()
    var result: InsertResult = .ax
    private(set) var inserted: [String] = []
    func insert(_ text: String) async -> InsertResult {
        lock.lock(); inserted.append(text); let r = result; lock.unlock()
        return r
    }
}

final class FakeFrontmost: FrontmostApp, @unchecked Sendable {
    var bundleId: String?
    var name: String?
    init(bundleId: String? = "com.apple.TextEdit", name: String? = "TextEdit") { self.bundleId = bundleId; self.name = name }
}

final class FakeStore: PipelineStore, @unchecked Sendable {
    private let lock = NSLock()
    var styles: [String: AppStyle] = Dictionary(uniqueKeysWithValues: FlowDatabase.seedStyles.map { ($0.bundleId, $0) })
    var entries: [DictionaryEntry] = []
    var snippetList: [Snippet] = []
    private(set) var rows: [Dictation] = []
    private(set) var useIncrements: [String] = []

    func appStyle(for bundleId: String?) -> AppStyle { styles[bundleId ?? ""] ?? styles["*"] ?? .fallback }
    func dictionaryEntries() -> [DictionaryEntry] { entries }
    func snippets() -> [Snippet] { snippetList }
    func record(_ d: Dictation) { lock.lock(); rows.append(d); lock.unlock() }
    func incrementUse(of terms: [String]) { lock.lock(); useIncrements += terms; lock.unlock() }
}

/// Everything wired with fakes. Tests tweak the pieces before driving the pipeline.
struct Rig {
    let clock = ManualClock()
    let audio = FakeAudio()
    let transcriber: FakeTranscriber
    let cleaner: FakeCleaner
    let factory = CleanerFactory()
    let inserter = FakeInserter()
    let frontmost = FakeFrontmost()
    let store = FakeStore()
    let pipeline: DictationPipeline
    let events: EventCollector

    init(final: String? = "hello world", cleaner: FakeCleaner = FakeCleaner(), configure: (inout PipelineConfig) -> Void = { _ in }) {
        transcriber = FakeTranscriber(finalOnAudioEnd: final)
        self.cleaner = cleaner
        factory.register(cleaner, availability: CleanerAvailability(available: true))
        var cfg = PipelineConfig()
        cfg.cleanupBackend = cleaner.backend
        configure(&cfg)
        pipeline = DictationPipeline(audio: audio, transcriber: transcriber, cleaners: factory, inserter: inserter,
                                     frontmost: frontmost, store: store, clock: clock, config: cfg)
        events = EventCollector(pipeline.events)
    }

    /// Hold for `ms` then release. Returns once the pipeline is idle again.
    func dictate(holdMs: Int = 1000) async {
        await pipeline.hotkeyDown()
        clock.advance(ms: holdMs)
        await pipeline.hotkeyUp()
    }

    func waitFor(_ state: PipelineState, timeoutMs: Int = 2000) async -> Bool {
        for _ in 0..<(timeoutMs / 5) {
            if await pipeline.state == state { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }
}

final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [PipelineEvent] = []
    private var task: Task<Void, Never>?
    init(_ stream: AsyncStream<PipelineEvent>) {
        task = Task { [weak self] in
            for await e in stream { self?.append(e) }
        }
    }
    private func append(_ e: PipelineEvent) { lock.lock(); _events.append(e); lock.unlock() }
    var events: [PipelineEvent] { lock.lock(); defer { lock.unlock() }; return _events }
    func contains(where p: (PipelineEvent) -> Bool) -> Bool { events.contains(where: p) }
    deinit { task?.cancel() }
}
