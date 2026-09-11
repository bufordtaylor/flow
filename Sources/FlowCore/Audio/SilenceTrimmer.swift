import Foundation

public struct SpeechSpan: Sendable, Equatable {
    public var start: Int
    public var end: Int
    public init(start: Int, end: Int) { self.start = start; self.end = end }
}

/// Finds speech in 16 kHz samples. The real one wraps FluidAudio's VadManager; tests use a fake.
public protocol SpeechDetector: Sendable {
    func speechSpans(in samples: [Float]) async throws -> [SpeechSpan]
}

/// Keeps 200 ms before the first speech segment to 200 ms after the last one. Nothing spoken → empty.
public enum SilenceTrimmer {
    public static let paddingSamples = 3_200

    public static func trim(_ samples: [Float], spans: [SpeechSpan]) -> [Float] {
        guard let first = spans.map(\.start).min(), let last = spans.map(\.end).max(), !samples.isEmpty else { return [] }
        let start = max(0, first - paddingSamples)
        let end = min(samples.count, last + paddingSamples)
        guard end > start else { return [] }
        return Array(samples[start..<end])
    }

    public static func trim(_ samples: [Float], using detector: SpeechDetector) async throws -> [Float] {
        trim(samples, spans: try await detector.speechSpans(in: samples))
    }
}
