import CoreML
import FluidAudio
import Foundation

// No code path in this file can open a socket: ModelHub.offlineMode is forced on before any loader runs,
// and the model files come from `modelPath`, which ModelDownloader or "Load from folder…" filled.

public enum TranscriberError: Error, LocalizedError, Sendable, Equatable {
    case noModel
    case loadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noModel: return "No speech model. Download one in Settings → Speech"
        case .loadFailed(let s): return "Speech model failed to load: \(s)"
        }
    }
}

/// Wraps FluidAudio's Parakeet TDT 0.6B v3 (CoreML) and Silero VAD.
public actor ParakeetTranscriber: Transcriber {
    public enum Status: Sendable, Equatable {
        case notLoaded, loading, ready(loadMs: Int), failed(String)
    }

    public private(set) var status: Status = .notLoaded
    public let modelPath: URL
    public var interimIntervalMs = 1_000
    public var interimWindowSeconds = 30

    private let clock: Clock
    private var asr: AsrManager?
    private var vad: VadManager?
    private var loadTask: Task<Void, Error>?
    private var interimBusy = false
    private let statusChanged: (@Sendable (Status) -> Void)?

    public init(modelPath: URL, clock: Clock = SystemClock(), statusChanged: (@Sendable (Status) -> Void)? = nil) {
        self.modelPath = modelPath
        self.clock = clock
        self.statusChanged = statusChanged
    }

    /// Loads once, on a background task; later calls await the same load. Compile on first load can take 10–30 s.
    public func load() async throws {
        if case .ready = status { return }
        if let t = loadTask { try await t.value; return }
        let t = Task { try await self.performLoad() }
        loadTask = t
        do { try await t.value } catch { loadTask = nil; throw error }
    }

    private func performLoad() async throws {
        ModelHub.offlineMode = true
        setStatus(.loading)
        let t0 = Date()
        let missing = ModelLayout.missing(at: modelPath)
        guard missing.isEmpty else { setStatus(.failed(TranscriberError.noModel.errorDescription!)); throw TranscriberError.noModel }
        do {
            let models = try Self.loadModels(from: ModelLayout.asrDirectory(in: modelPath))
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .cpuAndNeuralEngine
            let vadModel = try MLModel(contentsOf: ModelLayout.vadModelURL(in: modelPath), configuration: cfg)
            asr = manager
            vad = VadManager(vadModel: vadModel)
            // Warm the graph so the first dictation isn't the slow one.
            _ = try? await text(for: [Float](repeating: 0, count: Level.sampleRate))
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            setStatus(.ready(loadMs: ms))
            Log.info("stt", "model loaded in \(ms) ms")
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            setStatus(.failed(msg))
            Log.error("stt", "load failed: \(msg)")
            throw TranscriberError.loadFailed(msg)
        }
    }

    /// Loads the four CoreML packages and the vocabulary straight from our folder, so nothing depends on
    /// FluidAudio's own cache layout and nothing can trigger a download.
    private static func loadModels(from dir: URL) throws -> AsrModels {
        let config = AsrModels.defaultConfiguration()
        config.allowLowPrecisionAccumulationOnGPU = true
        let cpu = MLModelConfiguration()
        cpu.computeUnits = .cpuOnly
        func model(_ name: String, _ cfg: MLModelConfiguration) throws -> MLModel {
            try MLModel(contentsOf: dir.appendingPathComponent(name), configuration: cfg)
        }
        let data = try Data(contentsOf: dir.appendingPathComponent("parakeet_vocab.json"))
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw TranscriberError.loadFailed("vocabulary has an unexpected format")
        }
        var vocab: [Int: String] = [:]
        for (k, v) in dict { if let i = Int(k) { vocab[i] = v } }
        return AsrModels(
            encoder: try model("Encoder.mlmodelc", config),
            preprocessor: try model("Preprocessor.mlmodelc", cpu),
            decoder: try model("Decoder.mlmodelc", config),
            joint: try model("JointDecisionv3.mlmodelc", config),
            configuration: config,
            vocabulary: vocab,
            version: .v3)
    }

    private func setStatus(_ s: Status) {
        status = s
        statusChanged?(s)
    }

    // MARK: Transcriber

    public nonisolated func transcribe(audio: AsyncStream<[Float]>) -> AsyncThrowingStream<TranscriptEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do { try await self.run(audio, cont); cont.finish() }
                catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ audio: AsyncStream<[Float]>, _ cont: AsyncThrowingStream<TranscriptEvent, Error>.Continuation) async throws {
        if case .failed = status { throw TranscriberError.noModel }
        try await load()
        guard let asr else { throw TranscriberError.noModel }

        var buffer: [Float] = []
        buffer.reserveCapacity(Level.sampleRate * 60)
        var lastInterim = clock.now()
        for await chunk in audio {
            buffer.append(contentsOf: chunk)
            let dueMs = Int(clock.now().timeIntervalSince(lastInterim) * 1000)
            if dueMs >= interimIntervalMs, !interimBusy, buffer.count >= Level.sampleRate / 2 {
                interimBusy = true
                lastInterim = clock.now()
                let window = Array(buffer.suffix(interimWindowSeconds * Level.sampleRate))
                Task { [asr] in
                    if let t = try? await Self.text(asr, window), !t.isEmpty { cont.yield(.interim(t)) }
                    await self.interimFinished()
                }
            }
        }
        // Final pass: VAD trim, gain, one transcribe over everything.
        let t0 = Date()
        let trimmed = try await SilenceTrimmer.trim(buffer, using: self)
        guard !trimmed.isEmpty else {
            Log.info("stt", "VAD found no speech in \(buffer.count / 16) ms of audio")
            cont.yield(.final(""))
            return
        }
        let normalized = GainNormalizer.normalize(trimmed)
        let result = try await Self.text(asr, normalized)
        Log.info("stt", "final pass \(Int(Date().timeIntervalSince(t0) * 1000)) ms over \(trimmed.count / 16) ms of speech (\(buffer.count / 16) ms recorded)")
        cont.yield(.final(result))
    }

    private func interimFinished() { interimBusy = false }

    private func text(for samples: [Float]) async throws -> String {
        guard let asr else { throw TranscriberError.noModel }
        return try await Self.text(asr, samples)
    }

    private static func text(_ asr: AsrManager, _ samples: [Float]) async throws -> String {
        var padded = samples
        if padded.count < Level.sampleRate { padded.append(contentsOf: [Float](repeating: 0, count: Level.sampleRate - padded.count)) }
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let r = try await asr.transcribe(padded, decoderState: &state)
        return r.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Settings → Speech "Test" and the fixture test: same final path as a dictation.
    public func transcribeFile(_ url: URL) async throws -> (text: String, ms: Int) {
        let r = try await transcribeFileDetailed(url)
        return (r.text, r.ms)
    }

    public struct Token: Sendable, Codable, Equatable { public let token: String; public let start: Double; public let end: Double }

    /// Same path with per-token timestamps, for recording the fixture.
    public func transcribeFileDetailed(_ url: URL) async throws -> (text: String, ms: Int, tokens: [Token]) {
        try await load()
        guard let asr else { throw TranscriberError.noModel }
        let samples = try AudioConverter().resampleAudioFile(url)
        let t0 = Date()
        let trimmed = try await SilenceTrimmer.trim(samples, using: self)
        guard !trimmed.isEmpty else { return ("", Int(Date().timeIntervalSince(t0) * 1000), []) }
        var padded = GainNormalizer.normalize(trimmed)
        if padded.count < Level.sampleRate { padded.append(contentsOf: [Float](repeating: 0, count: Level.sampleRate - padded.count)) }
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(padded, decoderState: &state)
        let tokens = (result.tokenTimings ?? []).map { Token(token: $0.token, start: $0.startTime, end: $0.endTime) }
        return (result.text.trimmingCharacters(in: .whitespacesAndNewlines), Int(Date().timeIntervalSince(t0) * 1000), tokens)
    }
}

extension ParakeetTranscriber: SpeechDetector {
    public func speechSpans(in samples: [Float]) async throws -> [SpeechSpan] {
        guard let vad else { throw TranscriberError.noModel }
        var cfg = VadSegmentationConfig.default
        cfg.speechPadding = 0
        let segments = try await vad.segmentSpeech(samples, config: cfg)
        return segments.map { SpeechSpan(start: $0.startSample(sampleRate: Level.sampleRate), end: $0.endSample(sampleRate: Level.sampleRate)) }
    }
}
