import Foundation

public struct CleanerAvailability: Sendable, Equatable {
    public var available: Bool
    public var reason: String
    public init(available: Bool, reason: String = "") { self.available = available; self.reason = reason }
}

/// Picks a cleaner by the setting and by what is actually available right now.
/// The app registers the Apple cleaner (macOS 26 only); Ollama and Rules live here.
public final class CleanerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var cleaners: [CleanupBackend: Cleaner] = [.rules: RulesCleaner()]
    private var availability: [CleanupBackend: CleanerAvailability] = [
        .rules: CleanerAvailability(available: true),
        .off: CleanerAvailability(available: true),
        .apple: CleanerAvailability(available: false, reason: "Needs macOS 26 with Apple Intelligence on"),
        .ollama: CleanerAvailability(available: false, reason: "Ollama isn't running. Install it from ollama.com and run `ollama pull qwen3:4b`."),
    ]

    public init() {}

    public func register(_ cleaner: Cleaner, availability: CleanerAvailability) {
        lock.lock(); defer { lock.unlock() }
        cleaners[cleaner.backend] = cleaner
        self.availability[cleaner.backend] = availability
    }

    public func setAvailability(_ backend: CleanupBackend, _ a: CleanerAvailability) {
        lock.lock(); defer { lock.unlock() }
        availability[backend] = a
    }

    public func availability(of backend: CleanupBackend) -> CleanerAvailability {
        lock.lock(); defer { lock.unlock() }
        return availability[backend] ?? CleanerAvailability(available: false)
    }

    /// The cleaner to run for `backend`, or nil for `off`. An unavailable model backend falls to rules.
    public func cleaner(for backend: CleanupBackend) -> Cleaner? {
        lock.lock(); defer { lock.unlock() }
        switch backend {
        case .off: return nil
        case .rules: return cleaners[.rules]
        case .apple, .ollama:
            if availability[backend]?.available == true, let c = cleaners[backend] { return c }
            return cleaners[.rules]
        }
    }

    public var rules: Cleaner { RulesCleaner() }
}
