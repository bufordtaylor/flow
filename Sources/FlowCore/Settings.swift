import Foundation

/// All settings live in UserDefaults. There are no secrets anywhere in this app.
public final class Settings: @unchecked Sendable {
    public static let shared = Settings()
    public let defaults: UserDefaults

    public static let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Flow", isDirectory: true)

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.modelPath: Settings.supportDirectory.appendingPathComponent("models/parakeet-tdt-0.6b-v3").path,
            Key.cleanupBackend: CleanupBackend.ollama.rawValue,
            Key.ollamaModel: "qwen3:4b",
            Key.ollamaBaseURL: "http://127.0.0.1:11434",
            Key.hotkeyMode: HotkeyMode.hold.rawValue,
            Key.trailingSpace: true,
            Key.playSounds: true,
            Key.launchAtLogin: false,
            Key.storeTranscripts: true,
            Key.historyRetentionDays: 90,
            Key.historyShowsRaw: false,
            Key.defaultTone: "neutral",
        ])
    }

    public enum Key {
        public static let modelPath = "modelPath"
        public static let modelChecksum = "modelChecksum"
        public static let modelDownloadedAt = "modelDownloadedAt"
        public static let cleanupBackend = "cleanupBackend"
        public static let cleanupBackendChosen = "cleanupBackendChosen"
        public static let ollamaModel = "ollamaModel"
        public static let ollamaBaseURL = "ollamaBaseURL"
        public static let hotkey = "hotkey"
        public static let hotkeyMode = "hotkeyMode"
        public static let trailingSpace = "trailingSpace"
        public static let playSounds = "playSounds"
        public static let launchAtLogin = "launchAtLogin"
        public static let storeTranscripts = "storeTranscripts"
        public static let historyRetentionDays = "historyRetentionDays"
        public static let historyShowsRaw = "historyShowsRaw"
        public static let onboardingDone = "onboardingDone"
        public static let defaultTone = "defaultTone"
        public static let lastRetentionSweep = "lastRetentionSweep"
    }

    public var modelPath: URL {
        get { URL(fileURLWithPath: defaults.string(forKey: Key.modelPath) ?? "") }
        set { defaults.set(newValue.path, forKey: Key.modelPath) }
    }
    public var modelChecksum: String? {
        get { defaults.string(forKey: Key.modelChecksum) }
        set { defaults.set(newValue, forKey: Key.modelChecksum) }
    }
    public var modelDownloadedAt: Date? {
        get { defaults.object(forKey: Key.modelDownloadedAt) as? Date }
        set { defaults.set(newValue, forKey: Key.modelDownloadedAt) }
    }
    public var cleanupBackend: CleanupBackend {
        get { CleanupBackend(rawValue: defaults.string(forKey: Key.cleanupBackend) ?? "") ?? .ollama }
        set { defaults.set(newValue.rawValue, forKey: Key.cleanupBackend); defaults.set(true, forKey: Key.cleanupBackendChosen) }
    }
    /// True once the user (or auto-detection) picked a backend explicitly.
    public var cleanupBackendChosen: Bool {
        get { defaults.bool(forKey: Key.cleanupBackendChosen) }
        set { defaults.set(newValue, forKey: Key.cleanupBackendChosen) }
    }
    public var ollamaModel: String {
        get { defaults.string(forKey: Key.ollamaModel) ?? "qwen3:4b" }
        set { defaults.set(newValue, forKey: Key.ollamaModel) }
    }
    public var ollamaBaseURL: String {
        get { defaults.string(forKey: Key.ollamaBaseURL) ?? "http://127.0.0.1:11434" }
        set { defaults.set(newValue, forKey: Key.ollamaBaseURL) }
    }
    public var hotkey: HotkeySpec {
        get {
            guard let d = defaults.dictionary(forKey: Key.hotkey),
                  let code = d["keyCode"] as? Int, let mods = d["modifiers"] as? UInt64 ?? (d["modifiers"] as? Int).map(UInt64.init) else { return .rightOption }
            return HotkeySpec(keyCode: Int64(code), modifiers: mods)
        }
        set { defaults.set(["keyCode": Int(newValue.keyCode), "modifiers": Int(newValue.modifiers)], forKey: Key.hotkey) }
    }
    public var hotkeyMode: HotkeyMode {
        get { HotkeyMode(rawValue: defaults.string(forKey: Key.hotkeyMode) ?? "") ?? .hold }
        set { defaults.set(newValue.rawValue, forKey: Key.hotkeyMode) }
    }
    public var trailingSpace: Bool {
        get { defaults.bool(forKey: Key.trailingSpace) }
        set { defaults.set(newValue, forKey: Key.trailingSpace) }
    }
    public var playSounds: Bool {
        get { defaults.bool(forKey: Key.playSounds) }
        set { defaults.set(newValue, forKey: Key.playSounds) }
    }
    public var launchAtLogin: Bool {
        get { defaults.bool(forKey: Key.launchAtLogin) }
        set { defaults.set(newValue, forKey: Key.launchAtLogin) }
    }
    public var storeTranscripts: Bool {
        get { defaults.bool(forKey: Key.storeTranscripts) }
        set { defaults.set(newValue, forKey: Key.storeTranscripts) }
    }
    public var historyRetentionDays: Int {
        get { defaults.integer(forKey: Key.historyRetentionDays) }
        set { defaults.set(newValue, forKey: Key.historyRetentionDays) }
    }
    public var historyShowsRaw: Bool {
        get { defaults.bool(forKey: Key.historyShowsRaw) }
        set { defaults.set(newValue, forKey: Key.historyShowsRaw) }
    }
    public var onboardingDone: Bool {
        get { defaults.bool(forKey: Key.onboardingDone) }
        set { defaults.set(newValue, forKey: Key.onboardingDone) }
    }
    public var defaultTone: String {
        get { defaults.string(forKey: Key.defaultTone) ?? "neutral" }
        set { defaults.set(newValue, forKey: Key.defaultTone) }
    }
    public var lastRetentionSweep: Date? {
        get { defaults.object(forKey: Key.lastRetentionSweep) as? Date }
        set { defaults.set(newValue, forKey: Key.lastRetentionSweep) }
    }

    /// The Ollama URL is only accepted when it points at this Mac.
    public static func isLoopback(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else { return false }
        return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }
}
