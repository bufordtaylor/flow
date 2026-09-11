import Foundation

/// What lives under `modelPath`. Two Hugging Face repos, both fetched in the one first-run download:
///   <modelPath>/parakeet-tdt-0.6b-v3-coreml/{Preprocessor,Encoder,Decoder,JointDecisionv3}.mlmodelc + parakeet_vocab.json
///   <modelPath>/silero-vad-coreml/silero-vad-unified-256ms-v6.2.1.mlmodelc
/// FluidAudio's loaders look for `<parent>/<repo folder>/<file>`, so this layout feeds them directly.
public enum ModelLayout {
    public static let modelName = "parakeet-tdt-0.6b-v3"
    public static let asrRepo = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
    public static let vadRepo = "FluidInference/silero-vad-coreml"
    public static let asrFolder = "parakeet-tdt-0.6b-v3-coreml"
    public static let vadFolder = "silero-vad-coreml"
    public static let vadModelFile = "silero-vad-unified-256ms-v6.2.1.mlmodelc"
    public static let asrItems = ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc", "parakeet_vocab.json"]
    public static let vadItems = [vadModelFile]
    public static let approximateBytes: Int64 = 600 * 1024 * 1024

    /// (repo, folder, top-level items) for each repo.
    public static let repos: [(repo: String, folder: String, items: [String])] = [
        (asrRepo, asrFolder, asrItems),
        (vadRepo, vadFolder, vadItems),
    ]

    /// Top-level paths (relative to modelPath) that must exist.
    public static var requiredPaths: [String] {
        repos.flatMap { r in r.items.map { "\(r.folder)/\($0)" } }
    }

    public static func missing(at root: URL) -> [String] {
        requiredPaths.filter { !FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
    }

    public static func isComplete(at root: URL) -> Bool { missing(at: root).isEmpty }

    public static func asrDirectory(in root: URL) -> URL { root.appendingPathComponent(asrFolder, isDirectory: true) }
    public static func vadModelURL(in root: URL) -> URL { root.appendingPathComponent(vadFolder).appendingPathComponent(vadModelFile) }
    public static func manifestURL(in root: URL) -> URL { root.appendingPathComponent("manifest.json") }
}
