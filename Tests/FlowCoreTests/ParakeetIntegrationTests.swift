import XCTest
@testable import FlowCore

/// Runs against the real model when it is installed at `modelPath` (or FLOW_MODEL_PATH). Skips otherwise.
final class ParakeetIntegrationTests: XCTestCase {
    static var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures")
    }

    func makeTranscriber() throws -> ParakeetTranscriber {
        let env = ProcessInfo.processInfo.environment
        let path = env["FLOW_MODEL_PATH"].map { URL(fileURLWithPath: $0) } ?? Settings.shared.modelPath
        try XCTSkipUnless(ModelLayout.isComplete(at: path), "speech model not installed at \(path.path)")
        return ParakeetTranscriber(modelPath: path)
    }

    func testHelloWorldFixture() async throws {
        let t = try makeTranscriber()
        let (text, ms, tokens) = try await t.transcribeFileDetailed(Self.fixtures.appendingPathComponent("hello_world.wav"))
        XCTAssertTrue(text.lowercased().contains("hello world"), "got: \(text)")
        XCTAssertLessThan(ms, 2000)
        if ProcessInfo.processInfo.environment["FLOW_RECORD_FIXTURE"] == "1" {
            let json: [String: Any] = [
                "text": text, "inference_ms": ms, "machine": hostModel(), "model": ModelLayout.modelName,
                "recorded_at": ISO8601DateFormatter().string(from: Date()), "file": "hello_world.wav",
                "note": "Recorded via ParakeetTranscriber.transcribeFileDetailed (VAD trim + gain + one pass over the fixture).",
                "tokens": tokens.map { ["token": $0.token, "start": $0.start, "end": $0.end] },
            ]
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: Self.fixtures.appendingPathComponent("parakeet/hello_world.json"))
        }
    }

    func testSilenceFixtureIsEmpty() async throws {
        let t = try makeTranscriber()
        let (text, _) = try await t.transcribeFile(Self.fixtures.appendingPathComponent("silence.wav"))
        XCTAssertEqual(text, "")
    }

    func testStreamingInterimAndFinal() async throws {
        let t = try makeTranscriber()
        try await t.load()
        let samples = try wavSamples(Self.fixtures.appendingPathComponent("hello_world.wav"))
        let (audio, cont) = AsyncStream.makeStream(of: [Float].self)
        let events = t.transcribe(audio: audio)
        let feeder = Task {
            var i = 0
            while i < samples.count {
                cont.yield(Array(samples[i..<min(i + 1600, samples.count)]))
                i += 1600
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            cont.finish()
        }
        var interims = 0
        var final: String?
        let t0 = Date()
        for try await e in events {
            switch e {
            case .interim: interims += 1
            case .final(let f): final = f
            }
        }
        _ = t0
        await feeder.value
        XCTAssertGreaterThan(interims, 0, "no interim passes ran during 3 s of audio")
        XCTAssertTrue(final?.lowercased().contains("hello world") == true, "final: \(final ?? "nil")")
    }

    private func wavSamples(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        let body = data.dropFirst(44)
        return body.withUnsafeBytes { raw in
            let i16 = raw.bindMemory(to: Int16.self)
            return i16.map { Float($0) / 32768 }
        }
    }

    private func hostModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}
