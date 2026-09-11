import Foundation

public enum Snippets {
    /// Case-insensitive whole-phrase replacement of each trigger, word boundaries on both sides.
    /// Runs before cleanup so the model sees the expansion.
    public static func expand(_ text: String, snippets: [Snippet]) -> String {
        var out = text
        for s in snippets where !s.triggerPhrase.isEmpty {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: s.triggerPhrase) + "(?![\\p{L}\\p{N}])"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: s.expansion))
        }
        return out
    }
}
