import Foundation

public enum GuardFailure: Error, Sendable, Equatable {
    case empty, refusal, lengthRatio
    public var code: String { "cleanup_guard" }
}

/// Post-processing applied to every backend's response, then the sanity guards.
public enum CleanupGuards {
    public static func normalize(_ response: String) -> String {
        var s = response
        // Strip a <think>…</think> block a model emitted anyway.
        if let re = try? NSRegularExpression(pattern: "<think>.*?</think>", options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // One code fence.
        if s.hasPrefix("```") && s.hasSuffix("```") && s.count >= 6 {
            var inner = String(s.dropFirst(3).dropLast(3))
            if let nl = inner.firstIndex(of: "\n"), inner[inner.startIndex..<nl].allSatisfy({ $0.isLetter }) {
                inner = String(inner[inner.index(after: nl)...])
            }
            s = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // One pair of wrapping quotes.
        let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’")]
        for (open, close) in pairs where s.count >= 2 && s.first == open && s.last == close {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return s
    }

    public static func check(raw: String, cleaned: String) -> Result<String, GuardFailure> {
        let out = normalize(cleaned)
        if out.isEmpty { return .failure(.empty) }
        let rawLower = raw.lowercased()
        let outLower = out.lowercased()
        for prefix in ["i'm sorry", "i’m sorry", "i can't", "i can’t"] where outLower.hasPrefix(prefix) && !rawLower.hasPrefix(prefix) {
            return .failure(.refusal)
        }
        let rawWords = WordCount.count(raw)
        if rawWords > 5 {
            let ratio = Double(WordCount.count(out)) / Double(rawWords)
            if ratio < 0.4 || ratio > 2.0 { return .failure(.lengthRatio) }
        }
        return .success(out)
    }
}
