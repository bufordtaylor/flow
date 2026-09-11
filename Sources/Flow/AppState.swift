import AppKit
import Combine
import FlowCore

/// Everything the windows observe. Main-actor only.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var micGranted = false
    @Published var axTrusted = false
    @Published var tapRunning = false
    @Published var wasEverTrusted = UserDefaults.standard.bool(forKey: "wasEverTrusted")
    @Published var modelStatus: ParakeetTranscriber.Status = .notLoaded
    @Published var modelInstalled = false
    @Published var modelChecksum: String? = Settings.shared.modelChecksum
    @Published var modelDownloadedAt: Date? = Settings.shared.modelDownloadedAt
    @Published var downloadProgress: DownloadProgress?
    @Published var downloadError: String?
    @Published var availability: [CleanupBackend: CleanerAvailability] = [:]
    @Published var lastTimings: (sttMs: Int, cleanupMs: Int?)?
    @Published var pipelineState: PipelineState = .idle
    @Published var hotkey: HotkeySpec = Settings.shared.hotkey
    @Published var cleanupBackend: CleanupBackend = Settings.shared.cleanupBackend
    @Published var ollamaTags: [String] = []

    var cleanupSummary: String {
        if availability[.apple]?.available == true { return "Apple Intelligence found" }
        if let o = availability[.ollama], o.available { return o.reason }
        return "No local model found. Using rules. Install Ollama to do better."
    }

    func markTrusted() {
        if !wasEverTrusted {
            wasEverTrusted = true
            UserDefaults.standard.set(true, forKey: "wasEverTrusted")
        }
    }
}
