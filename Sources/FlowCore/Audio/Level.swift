import Accelerate
import Foundation

public enum Level {
    public static let sampleRate = 16_000
    public static let chunkSamples = 1_600  // 100 ms

    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var out: Float = 0
        vDSP_rmsqv(samples, 1, &out, vDSP_Length(samples.count))
        return out
    }
}
