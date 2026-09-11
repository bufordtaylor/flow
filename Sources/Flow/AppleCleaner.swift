import FlowCore
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device Foundation Model. Compiles only with the macOS 26 SDK; runs only on macOS 26 with
/// Apple Intelligence on. Everywhere else `AppleCleaner.make()` returns nil and the reason.
enum AppleCleanerSupport {
    static func make() -> (cleaner: Cleaner?, availability: CleanerAvailability) {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let a = AppleCleaner.availability()
            return (a.available ? AppleCleaner() : nil, a)
        }
        #endif
        return (nil, CleanerAvailability(available: false, reason: "Needs macOS 26 with Apple Intelligence on"))
    }

    static func refreshAvailability() -> CleanerAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return AppleCleaner.availability() }
        #endif
        return CleanerAvailability(available: false, reason: "Needs macOS 26 with Apple Intelligence on")
    }

    static func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { AppleCleaner.prewarm() }
        #endif
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
final class AppleCleaner: Cleaner, Sendable {
    let backend: CleanupBackend = .apple

    static func availability() -> CleanerAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return CleanerAvailability(available: true, reason: "Apple Intelligence found")
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return CleanerAvailability(available: false, reason: "This Mac isn't eligible for Apple Intelligence")
            case .appleIntelligenceNotEnabled: return CleanerAvailability(available: false, reason: "Apple Intelligence is off. Turn it on in System Settings")
            case .modelNotReady: return CleanerAvailability(available: false, reason: "Apple Intelligence model is still downloading")
            @unknown default: return CleanerAvailability(available: false, reason: "Apple Intelligence unavailable")
            }
        }
    }

    /// Once at launch so the first cleanup of the session isn't a cold load.
    static func prewarm() {
        guard case .available = SystemLanguageModel.default.availability else { return }
        LanguageModelSession(instructions: Prompts.system(context: CleanupContext())).prewarm()
    }

    func clean(_ raw: String, context: CleanupContext) async throws -> String {
        guard case .available = SystemLanguageModel.default.availability else {
            throw CleanerUnavailableError(Self.availability().reason)
        }
        let session = LanguageModelSession(instructions: Prompts.system(context: context))
        var options = GenerationOptions(temperature: 0)
        options.maximumResponseTokens = Prompts.maxResponseTokens(rawCharacters: raw.count)
        do {
            return try await session.respond(to: raw, options: options).content
        } catch let error as LanguageModelSession.GenerationError {
            if case .guardrailViolation = error { throw CleanerFallbackError("guardrail") }
            throw error
        }
    }
}
#endif
