import Foundation
import os

/// One line per pipeline stage. Mirrors os.Logger to ~/Library/Logs/Flow/flow.log, rotated at 5 MB, two kept.
/// Transcript text is never written unless FLOW_DEBUG=1.
public final class Log: @unchecked Sendable {
    public static let shared = Log()
    public static let debugTranscripts = ProcessInfo.processInfo.environment["FLOW_DEBUG"] == "1"

    private let logger = Logger(subsystem: "com.yourname.flow", category: "flow")
    private let queue = DispatchQueue(label: "flow.log")
    private let maxBytes = 5 * 1024 * 1024
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    public let fileURL: URL

    private init() {
        let dir: URL
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("FlowTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        } else {
            dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Flow", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("flow.log")
    }

    public static func info(_ stage: String, _ message: String) { shared.write("INFO", stage, message) }
    public static func error(_ stage: String, _ message: String) { shared.write("ERROR", stage, message) }
    /// Only reaches the log with FLOW_DEBUG=1.
    public static func transcript(_ stage: String, _ text: String) {
        guard debugTranscripts else { return }
        shared.write("TEXT", stage, text)
    }

    private func write(_ level: String, _ stage: String, _ message: String) {
        if level == "ERROR" { logger.error("[\(stage, privacy: .public)] \(message, privacy: .public)") }
        else { logger.info("[\(stage, privacy: .public)] \(message, privacy: .public)") }
        let line = "\(formatter.string(from: Date())) \(level) [\(stage)] \(message)\n"
        queue.async { [self] in
            rotateIfNeeded()
            if let data = line.data(using: .utf8) {
                if let h = try? FileHandle(forWritingTo: fileURL) {
                    defer { try? h.close() }
                    _ = try? h.seekToEnd()
                    try? h.write(contentsOf: data)
                } else {
                    try? data.write(to: fileURL)
                }
            }
        }
    }

    private func rotateIfNeeded() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? Int, size >= maxBytes else { return }
        let fm = FileManager.default
        let one = fileURL.appendingPathExtension("1")
        let two = fileURL.appendingPathExtension("2")
        try? fm.removeItem(at: two)
        try? fm.moveItem(at: one, to: two)
        try? fm.moveItem(at: fileURL, to: one)
    }
}
