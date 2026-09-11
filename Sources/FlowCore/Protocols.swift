import Foundation

// The seams the pipeline is tested through. Everything here is Foundation-only.

public protocol AudioSource: Sendable {
    /// Starts capture and returns 100 ms chunks of 16 kHz mono Float32.
    func start() throws -> AsyncStream<[Float]>
    func stop()
}

public enum TranscriptEvent: Sendable, Equatable {
    case interim(String)
    case final(String)
}

public protocol Transcriber: Sendable {
    func transcribe(audio: AsyncStream<[Float]>) -> AsyncThrowingStream<TranscriptEvent, Error>
}

public struct DictionaryEntry: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var term: String
    public var soundsLike: String?
    public var useCount: Int
    public var createdAt: Date

    public init(id: String = UUID().uuidString, term: String, soundsLike: String? = nil, useCount: Int = 0, createdAt: Date = Date()) {
        self.id = id
        self.term = term
        self.soundsLike = soundsLike
        self.useCount = useCount
        self.createdAt = createdAt
    }
}

public struct CleanupContext: Sendable, Equatable {
    public let tone: String
    public let hint: String
    public let format: String
    public let dictionary: [DictionaryEntry]

    public init(tone: String = "neutral", hint: String = "Everyday written English.", format: String = "plain", dictionary: [DictionaryEntry] = []) {
        self.tone = tone
        self.hint = hint
        self.format = format
        self.dictionary = dictionary
    }
}

public enum CleanupBackend: String, Sendable, CaseIterable, Codable {
    case apple, ollama, rules, off
}

public protocol Cleaner: Sendable {
    var backend: CleanupBackend { get }
    func clean(_ raw: String, context: CleanupContext) async throws -> String
}

/// Thrown by a model cleaner when its backend is gone (Ollama quit, Apple Intelligence off).
/// The pipeline retries once with the rules cleaner.
public struct CleanerUnavailableError: Error, Sendable, Equatable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
}

/// Thrown by a model cleaner that refused this one dictation (Apple's guardrails). The pipeline uses the
/// rules cleaner for it and does not retry the model.
public struct CleanerFallbackError: Error, Sendable, Equatable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
}

public enum InsertResult: Sendable, Equatable {
    case ax, paste, clipboardOnly
    case failed(String)

    public var method: String {
        switch self {
        case .ax: return "ax"
        case .paste: return "paste"
        case .clipboardOnly: return "clipboard_only"
        case .failed: return "failed"
        }
    }
}

public protocol TextInserter: Sendable {
    func insert(_ text: String) async -> InsertResult
}

public protocol FrontmostApp: Sendable {
    var bundleId: String? { get }
    var name: String? { get }
}

public enum HotkeyMode: String, Sendable, Codable {
    case hold, toggle
}

public struct AppStyle: Codable, Sendable, Equatable, Identifiable {
    public var bundleId: String
    public var appName: String
    public var tone: String
    public var hint: String
    public var format: String
    public var updatedAt: Date

    public var id: String { bundleId }

    public init(bundleId: String, appName: String, tone: String, hint: String, format: String, updatedAt: Date = Date()) {
        self.bundleId = bundleId
        self.appName = appName
        self.tone = tone
        self.hint = hint
        self.format = format
        self.updatedAt = updatedAt
    }

    public static let fallback = AppStyle(bundleId: "*", appName: "Default", tone: "neutral", hint: "Everyday written English.", format: "plain")
}

public struct Snippet: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var triggerPhrase: String
    public var expansion: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, triggerPhrase: String, expansion: String, createdAt: Date = Date()) {
        self.id = id
        self.triggerPhrase = triggerPhrase.lowercased()
        self.expansion = expansion
        self.createdAt = createdAt
    }
}

public struct Dictation: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var startedAt: Date
    public var durationMs: Int
    public var appBundleId: String
    public var appName: String
    public var rawText: String?
    public var cleanedText: String?
    public var insertedText: String?
    public var insertMethod: String
    public var sttModel: String
    public var cleanupBackend: String
    public var cleanupModel: String?
    public var sttMs: Int
    public var cleanupMs: Int?
    public var wordCount: Int
    public var error: String?

    public init(id: String = UUID().uuidString, startedAt: Date, durationMs: Int, appBundleId: String, appName: String,
                rawText: String?, cleanedText: String?, insertedText: String?, insertMethod: String,
                sttModel: String, cleanupBackend: String, cleanupModel: String?, sttMs: Int, cleanupMs: Int?,
                wordCount: Int, error: String?) {
        self.id = id
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.appBundleId = appBundleId
        self.appName = appName
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.insertedText = insertedText
        self.insertMethod = insertMethod
        self.sttModel = sttModel
        self.cleanupBackend = cleanupBackend
        self.cleanupModel = cleanupModel
        self.sttMs = sttMs
        self.cleanupMs = cleanupMs
        self.wordCount = wordCount
        self.error = error
    }
}

/// What the pipeline needs from storage. `FlowDatabase` is the real one; tests use an in-memory fake.
public protocol PipelineStore: Sendable {
    func appStyle(for bundleId: String?) -> AppStyle
    func dictionaryEntries() -> [DictionaryEntry]
    func snippets() -> [Snippet]
    func record(_ dictation: Dictation)
    func incrementUse(of terms: [String])
}

public enum WordCount {
    public static func count(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}
