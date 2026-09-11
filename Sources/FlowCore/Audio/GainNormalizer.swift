import Accelerate
import Foundation

/// Scales the whole buffer so its peak is -3 dBFS, amplifying by at most 20 dB.
public enum GainNormalizer {
    public static let targetPeak: Float = 0.7079  // -3 dBFS
    public static let maxGain: Float = 10.0       // +20 dB

    public static func gain(for samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 1 }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        guard peak > 0 else { return 1 }
        return min(targetPeak / peak, maxGain)
    }

    public static func normalize(_ samples: [Float]) -> [Float] {
        var g = gain(for: samples)
        guard !samples.isEmpty, g != 1 else { return samples }
        var out = [Float](repeating: 0, count: samples.count)
        vDSP_vsmul(samples, 1, &g, &out, 1, vDSP_Length(samples.count))
        return out
    }
}
