import Foundation

/// Deterministic cleaner. Always available; what the tests run against.
public struct RulesCleaner: Cleaner {
    public let backend: CleanupBackend = .rules
    public init() {}

    public func clean(_ raw: String, context: CleanupContext) async throws -> String {
        Self.clean(raw, context: context)
    }

    public static func clean(_ raw: String, context: CleanupContext) -> String {
        var s = raw
        s = applyDictionary(s, entries: context.dictionary)
        s = removeFillers(s)
        s = applySelfCorrections(s)
        s = applySpokenPunctuation(s)
        s = tidy(s, tone: context.tone)
        if context.format == "markdown" { s = listify(s) }
        return s
    }

    // 1. sounds_like → term, case-insensitive, whole phrase.
    static func applyDictionary(_ s: String, entries: [DictionaryEntry]) -> String {
        var out = s
        for e in entries {
            guard let sl = e.soundsLike?.trimmingCharacters(in: .whitespaces), !sl.isEmpty else { continue }
            out = replace(out, pattern: "\\b" + NSRegularExpression.escapedPattern(for: sl) + "\\b",
                          with: NSRegularExpression.escapedTemplate(for: e.term), options: [.caseInsensitive])
        }
        return out
    }

    // 2. Fillers on word boundaries, in one pass over the original text so a filler that lands at the
    //    start only because an earlier one was removed ("um so …") is left alone.
    static func removeFillers(_ s: String) -> String {
        let any = Prompts.fillers.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let starts = Prompts.sentenceStartFillers.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let pattern = "(?:(?<=^|[.!?]\\s|[.!?]\\n)(?:\\s*)(?:\(starts))\\b,?)|(?:\\b(?:\(any))\\b,?)"
        var out = replace(s, pattern: pattern, with: "", options: [.caseInsensitive])
        out = replace(out, pattern: "\\s+,", with: ",")
        out = replace(out, pattern: ",(\\s*,)+", with: ",")
        out = replace(out, pattern: "^[\\s,]+", with: "")
        out = replace(out, pattern: "([.!?])\\s*,", with: "$1")
        out = replace(out, pattern: "\\s{2,}", with: " ")
        return out
    }

    // 3. "X, no, Y" / "X no Y" between two phrases of the same shape: keep Y.
    static func applySelfCorrections(_ s: String) -> String {
        let weekday = "(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)"
        let shapes = [
            "\\b\(weekday)\\b,?\\s+no,?\\s+(\\b\(weekday)\\b)",
            "\\b\\d+(?:[.,]\\d+)?\\b,?\\s+no,?\\s+(\\b\\d+(?:[.,]\\d+)?\\b)",
            "\\b[A-Z][a-z]+\\b,?\\s+no,?\\s+(\\b[A-Z][a-z]+\\b)",
        ]
        var out = s
        out = replace(out, pattern: shapes[0], with: "$1", options: [.caseInsensitive])
        out = replace(out, pattern: shapes[1], with: "$1")
        out = replace(out, pattern: shapes[2], with: "$1")
        return out
    }

    // 4. Spoken punctuation when it ends a clause.
    static func applySpokenPunctuation(_ s: String) -> String {
        var out = s
        out = replace(out, pattern: "\\s*\\bnew paragraph\\b[,.]?\\s*", with: "\n\n", options: [.caseInsensitive])
        out = replace(out, pattern: "\\s*\\bnew line\\b[,.]?\\s*", with: "\n", options: [.caseInsensitive])
        // period / question mark: at the end, or before what reads as a new sentence.
        out = replace(out, pattern: "\\s*\\bquestion mark\\b(?=\\s*$|\\s+[A-Z]|\\s*\\n)", with: "?", options: [])
        out = replace(out, pattern: "(?<!\\b(?:a|the|this|that|each|every|per) )\\s*\\bperiod\\b(?=\\s*$|\\s+[A-Z]|\\s*\\n)", with: ".", options: [])
        out = replace(out, pattern: "(?<=\\p{L}|\\p{N})\\s*\\bcomma\\b(?!\\s*(?:is|was|are|were|key|button|goes|before|after)\\b)(?=\\s+\\S)", with: ",", options: [.caseInsensitive])
        out = replace(out, pattern: "\\s*\\bperiod\\b\\s*$", with: ".", options: [.caseInsensitive])
        out = replace(out, pattern: "\\s*\\bquestion mark\\b\\s*$", with: "?", options: [.caseInsensitive])
        return out
    }

    // 5. Whitespace, sentence capitals, terminal period.
    static func tidy(_ s: String, tone: String) -> String {
        var out = s
        out = replace(out, pattern: "[ \\t]+", with: " ")
        out = replace(out, pattern: " *\\n *", with: "\n")
        out = replace(out, pattern: "\\n{3,}", with: "\n\n")
        out = replace(out, pattern: " ([.,!?;:])", with: "$1")
        out = replace(out, pattern: "([.!?]){2,}", with: "$1")
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return out }
        out = capitalizeSentences(out)
        if tone != "casual", let last = out.unicodeScalars.last, CharacterSet.alphanumerics.contains(last) {
            out += "."
        }
        return out
    }

    static func capitalizeSentences(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "(^|[.!?]\\s+|\\n\\s*)(\\p{Ll})", options: [.anchorsMatchLines]) else { return s }
        let ns = NSMutableString(string: s)
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            let r = m.range(at: 2)
            ns.replaceCharacters(in: r, with: ns.substring(with: r).uppercased())
        }
        return ns as String
    }

    // 6. Clause starters first/second/third or one/two/three → markdown list.
    static func listify(_ s: String) -> String {
        for words in [["first", "second", "third"], ["one", "two", "three"]] {
            let pattern = "(.*?)\\b\(words[0])\\b,?\\s+(.+?)[,.;]?\\s+\\b\(words[1])\\b,?\\s+(.+?)[,.;]?(?:\\s+(?:and\\s+)?\\b\(words[2])\\b,?\\s+(.+?))?[.]?$"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { continue }
            func g(_ i: Int) -> String? {
                let r = m.range(at: i)
                guard r.location != NSNotFound, let rr = Range(r, in: s) else { return nil }
                return String(s[rr]).trimmingCharacters(in: CharacterSet(charactersIn: " ,.;"))
            }
            var lines: [String] = []
            if let lead = g(1), !lead.isEmpty {
                var l = lead
                if let last = l.last, ".:!?".contains(last) { l.removeLast() }
                lines.append(l + ":")
            }
            for i in 2...4 { if let item = g(i), !item.isEmpty { lines.append("- " + item.prefix(1).uppercased() + item.dropFirst()) } }
            if lines.filter({ $0.hasPrefix("- ") }).count >= 2 { return lines.joined(separator: "\n") }
        }
        return s
    }

    static func replace(_ s: String, pattern: String, with template: String, options: NSRegularExpression.Options = []) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
