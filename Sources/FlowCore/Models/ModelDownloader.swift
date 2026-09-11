// URLSession is allowed in this file. This is the app's one network request: the first-run model download
// from Hugging Face into `modelPath`. The only other file in the package that may use a networking API is
// Cleaners/OllamaCleaner.swift, which stays on loopback.
import Foundation

public struct DownloadProgress: Sendable, Equatable {
    public var file: String
    public var fileIndex: Int
    public var fileCount: Int
    public var bytesReceived: Int64
    public var bytesTotal: Int64
    public var fraction: Double { bytesTotal > 0 ? Double(bytesReceived) / Double(bytesTotal) : 0 }
    public init(file: String, fileIndex: Int, fileCount: Int, bytesReceived: Int64, bytesTotal: Int64) {
        self.file = file; self.fileIndex = fileIndex; self.fileCount = fileCount; self.bytesReceived = bytesReceived; self.bytesTotal = bytesTotal
    }
}

public enum ModelDownloadError: Error, LocalizedError, Sendable {
    case badListing(String)
    case httpStatus(Int, String)
    case incomplete([String])

    public var errorDescription: String? {
        switch self {
        case .badListing(let s): return "Couldn't list model files: \(s)"
        case .httpStatus(let c, let f): return "Download of \(f) failed with HTTP \(c)"
        case .incomplete(let m): return "Model folder is missing: \(m.joined(separator: ", "))"
        }
    }
}

/// Fetches the file list for each repo, downloads every file with a resumable download task, then writes
/// manifest.json and returns the manifest whose `checksum` goes into `modelChecksum`.
public final class ModelDownloader: NSObject, @unchecked Sendable {
    public let destination: URL
    private let session: URLSession
    private let hfBase = "https://huggingface.co"

    private struct Remote: Sendable { let repo: String; let folder: String; let path: String; let size: Int64 }

    public init(destination: URL) {
        self.destination = destination
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.waitsForConnectivity = true
        session = URLSession(configuration: cfg)
    }

    public func download(progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> ModelManifest {
        let files = try await listFiles()
        let total = files.reduce(0) { $0 + $1.size }
        var received: Int64 = 0
        for (i, f) in files.enumerated() {
            let dest = destination.appendingPathComponent(f.folder).appendingPathComponent(f.path)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size]) as? Int64, size == f.size {
                received += size
                progress(DownloadProgress(file: f.path, fileIndex: i, fileCount: files.count, bytesReceived: received, bytesTotal: total))
                continue
            }
            let url = URL(string: "\(hfBase)/\(f.repo)/resolve/main/\(f.path)")!
            let base = received
            try await fetch(url, to: dest, resumeKey: dest.path) { written in
                progress(DownloadProgress(file: f.path, fileIndex: i, fileCount: files.count, bytesReceived: base + written, bytesTotal: total))
            }
            received += f.size
        }
        return try Self.writeManifest(at: destination, source: "huggingface")
    }

    /// "Load from folder…": copies a folder the user picked into `modelPath`, validates it, and writes the manifest.
    /// Accepts either the layout above or a bare repo folder (the parakeet files at the top level).
    public static func importFolder(_ source: URL, into destination: URL) throws -> ModelManifest {
        let fm = FileManager.default
        var src = source
        // A bare parakeet repo folder: wrap it.
        if fm.fileExists(atPath: source.appendingPathComponent("Encoder.mlmodelc").path) {
            src = source
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: destination.appendingPathComponent(ModelLayout.asrFolder))
            if let vad = [source.deletingLastPathComponent().appendingPathComponent(ModelLayout.vadFolder)].first(where: { fm.fileExists(atPath: $0.path) }) {
                try fm.copyItem(at: vad, to: destination.appendingPathComponent(ModelLayout.vadFolder))
            }
        } else if src.standardizedFileURL != destination.standardizedFileURL {
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: destination)
        }
        let missing = ModelLayout.missing(at: destination)
        guard missing.isEmpty else { throw ModelDownloadError.incomplete(missing) }
        return try writeManifest(at: destination, source: "folder")
    }

    public static func writeManifest(at root: URL, source: String) throws -> ModelManifest {
        let missing = ModelLayout.missing(at: root)
        guard missing.isEmpty else { throw ModelDownloadError.incomplete(missing) }
        let files = try ModelChecksum.scan(root)
        let manifest = ModelManifest(source: source, downloadedAt: Date(), checksum: ModelChecksum.combined(files), files: files)
        try manifest.write(to: root)
        return manifest
    }

    // MARK: Listing

    private func listFiles() async throws -> [Remote] {
        var out: [Remote] = []
        for r in ModelLayout.repos {
            for item in r.items {
                if item.hasSuffix(".json") {
                    out.append(Remote(repo: r.repo, folder: r.folder, path: item, size: try await headSize(repo: r.repo, path: item)))
                    continue
                }
                let url = URL(string: "\(hfBase)/api/models/\(r.repo)/tree/main/\(item)?recursive=true")!
                let (data, resp) = try await session.data(from: url)
                guard (resp as? HTTPURLResponse)?.statusCode == 200,
                      let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    throw ModelDownloadError.badListing(item)
                }
                for it in items where (it["type"] as? String) == "file" {
                    guard let path = it["path"] as? String else { continue }
                    let size = (it["size"] as? NSNumber)?.int64Value ?? 0
                    out.append(Remote(repo: r.repo, folder: r.folder, path: path, size: size))
                }
            }
        }
        return out
    }

    private func headSize(repo: String, path: String) async throws -> Int64 {
        var req = URLRequest(url: URL(string: "\(hfBase)/\(repo)/resolve/main/\(path)")!)
        req.httpMethod = "HEAD"
        let (_, resp) = try await session.data(for: req)
        return (resp as? HTTPURLResponse)?.expectedContentLength ?? 0
    }

    // MARK: Download with resume

    private final class Handler: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let onProgress: @Sendable (Int64) -> Void
        var cont: CheckedContinuation<URL, Error>?
        var resumeData: Data?
        init(onProgress: @escaping @Sendable (Int64) -> Void) { self.onProgress = onProgress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            onProgress(totalBytesWritten)
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let code = (downloadTask.response as? HTTPURLResponse)?.statusCode, code != 200 {
                cont?.resume(throwing: ModelDownloadError.httpStatus(code, downloadTask.originalRequest?.url?.lastPathComponent ?? ""))
                cont = nil
                return
            }
            // Must move synchronously; the file is gone once this returns.
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do { try FileManager.default.moveItem(at: location, to: tmp); cont?.resume(returning: tmp) }
            catch { cont?.resume(throwing: error) }
            cont = nil
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error else { return }
            resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            cont?.resume(throwing: error)
            cont = nil
        }
    }

    private static var resumeStore: [String: Data] = [:]
    private static let resumeLock = NSLock()

    private func fetch(_ url: URL, to dest: URL, resumeKey: String, onProgress: @escaping @Sendable (Int64) -> Void) async throws {
        let handler = Handler(onProgress: onProgress)
        let s = URLSession(configuration: session.configuration, delegate: handler, delegateQueue: nil)
        defer { s.finishTasksAndInvalidate() }
        let resume = Self.resumeLock.withLock { Self.resumeStore[resumeKey] }
        let tmp: URL
        do {
            tmp = try await withCheckedThrowingContinuation { cont in
                handler.cont = cont
                let task = resume.map { s.downloadTask(withResumeData: $0) } ?? s.downloadTask(with: url)
                task.resume()
            }
        } catch {
            if let rd = handler.resumeData { Self.resumeLock.withLock { Self.resumeStore[resumeKey] = rd } }
            throw error
        }
        Self.resumeLock.withLock { Self.resumeStore[resumeKey] = nil }
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.moveItem(at: tmp, to: dest)
    }
}
