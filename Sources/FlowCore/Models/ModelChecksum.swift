import CryptoKit
import Foundation

public struct ManifestFile: Codable, Sendable, Equatable {
    public var path: String
    public var size: Int64
    public var sha256: String
    public init(path: String, size: Int64, sha256: String) { self.path = path; self.size = size; self.sha256 = sha256 }
}

public struct ModelManifest: Codable, Sendable, Equatable {
    public var model: String
    public var source: String       // "huggingface" | "folder"
    public var downloadedAt: Date
    public var checksum: String
    public var files: [ManifestFile]

    public init(model: String = ModelLayout.modelName, source: String, downloadedAt: Date, checksum: String, files: [ManifestFile]) {
        self.model = model; self.source = source; self.downloadedAt = downloadedAt; self.checksum = checksum; self.files = files
    }

    public static func load(from root: URL) -> ModelManifest? {
        guard let data = try? Data(contentsOf: ModelLayout.manifestURL(in: root)) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(ModelManifest.self, from: data)
    }

    public func write(to root: URL) throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: ModelLayout.manifestURL(in: root), options: .atomic)
    }
}

public enum ModelChecksum {
    public static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Hash of the concatenated per-file hashes, files sorted by path.
    public static func combined(_ files: [ManifestFile]) -> String {
        let joined = files.sorted { $0.path < $1.path }.map(\.sha256).joined()
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Walks every regular file under `root` except manifest.json.
    public static func scan(_ root: URL, progress: ((String) -> Void)? = nil) throws -> [ManifestFile] {
        var out: [ManifestFile] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        let base = root.standardizedFileURL.path
        for case let url as URL in e {
            let v = try url.resourceValues(forKeys: Set(keys))
            guard v.isRegularFile == true else { continue }
            let rel = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            if rel == "manifest.json" || rel.hasSuffix(".DS_Store") { continue }
            progress?(rel)
            out.append(ManifestFile(path: rel, size: Int64(v.fileSize ?? 0), sha256: try sha256(of: url)))
        }
        return out.sorted { $0.path < $1.path }
    }
}
