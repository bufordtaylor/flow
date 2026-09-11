import AVFoundation
import FlowCore
import FluidAudio

/// Test affordance: when FLOW_FAKE_AUDIO points at a WAV, dictation reads it instead of the mic, streamed in
/// 100 ms chunks. Lets the whole pipeline be exercised end to end on a machine with no usable input device.
final class FileAudioSource: FlowCore.AudioSource, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    init(url: URL) { self.url = url }

    func start() throws -> AsyncStream<[Float]> {
        let samples = try AudioConverter().resampleAudioFile(url)
        let (stream, cont) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .unbounded)
        let t = Task {
            var i = 0
            while i < samples.count {
                if Task.isCancelled { break }
                cont.yield(Array(samples[i..<min(i + Level.chunkSamples, samples.count)]))
                i += Level.chunkSamples
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            cont.finish()
        }
        lock.lock(); task = t; lock.unlock()
        return stream
    }

    func stop() { lock.lock(); task?.cancel(); task = nil; lock.unlock() }
}

/// AVAudioEngine input tap in the hardware format, converted to 16 kHz mono Float32, emitted in 100 ms chunks.
final class AudioEngineSource: FlowCore.AudioSource, @unchecked Sendable {
    struct NoInputDevice: Error {}

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var cont: AsyncStream<[Float]>.Continuation?
    private var pending: [Float] = []
    private var observer: NSObjectProtocol?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Level.sampleRate), channels: 1, interleaved: false)!

    func start() throws -> AsyncStream<[Float]> {
        let (stream, c) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .unbounded)
        lock.lock(); cont = c; pending = []; lock.unlock()
        try startEngine()
        return stream
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hw = input.outputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0, let conv = AVAudioConverter(from: hw, to: target) else { throw NoInputDevice() }
        input.installTap(onBus: 0, bufferSize: 2048, format: hw) { [weak self] buffer, _ in
            self?.convert(buffer, with: conv)
        }
        engine.prepare()
        try engine.start()
        lock.lock()
        self.engine = engine
        self.converter = conv
        lock.unlock()
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.deviceChanged()
        }
    }

    /// The default input device changed mid-dictation: keep going with whatever the engine gives us now.
    private func deviceChanged() {
        Log.info("audio", "input device changed mid-dictation; restarting engine")
        lock.lock(); let running = cont != nil; let old = engine; lock.unlock()
        guard running else { return }
        old?.inputNode.removeTap(onBus: 0)
        old?.stop()
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        do { try startEngine() } catch { Log.error("audio", "restart after device change failed: \(error)") }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, with conv: AVAudioConverter) {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        let status = conv.convert(to: out, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let ch = out.floatChannelData, out.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        lock.lock()
        pending.append(contentsOf: samples)
        var chunks: [[Float]] = []
        while pending.count >= Level.chunkSamples {
            chunks.append(Array(pending[0..<Level.chunkSamples]))
            pending.removeFirst(Level.chunkSamples)
        }
        let c = cont
        lock.unlock()
        chunks.forEach { c?.yield($0) }
    }

    func stop() {
        lock.lock()
        let e = engine; engine = nil; converter = nil
        let c = cont; cont = nil
        let tail = pending; pending = []
        lock.unlock()
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        e?.inputNode.removeTap(onBus: 0)
        e?.stop()
        if !tail.isEmpty { c?.yield(tail) }
        c?.finish()
    }
}
