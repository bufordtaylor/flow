import XCTest
@testable import FlowCore

final class RulesCleanerTests: XCTestCase {
    func testAcceptanceSentence() {
        XCTAssertEqual(RulesCleaner.clean("um so send it uh Tuesday no Wednesday", context: CleanupContext()), "So send it Wednesday.")
    }

    func testDictionarySoundsLike() {
        let ctx = CleanupContext(dictionary: [DictionaryEntry(term: "Wolchonok", soundsLike: "wall chunk")])
        XCTAssertEqual(RulesCleaner.clean("call wall chunk back", context: ctx), "Call Wolchonok back.")
    }

    func testFillersAndSelfCorrections() {
        XCTAssertEqual(RulesCleaner.clean("I mean we should you know meet at 3 no 4", context: CleanupContext()), "We should meet at 4.")
        XCTAssertEqual(RulesCleaner.clean("ask Bob, no, Alice about it", context: CleanupContext()), "Ask Alice about it.")
        XCTAssertEqual(RulesCleaner.clean("like I said. So it works", context: CleanupContext()), "I said. It works.")
    }

    func testSpokenPunctuation() {
        XCTAssertEqual(RulesCleaner.clean("thanks for the update period I will reply tomorrow period", context: CleanupContext()),
                       "Thanks for the update. I will reply tomorrow.")
        XCTAssertEqual(RulesCleaner.clean("first line new line second line", context: CleanupContext()), "First line\nSecond line.")
        XCTAssertEqual(RulesCleaner.clean("are you coming question mark", context: CleanupContext()), "Are you coming?")
        XCTAssertEqual(RulesCleaner.clean("the period of time was long", context: CleanupContext()), "The period of time was long.")
    }

    func testCasualToneSkipsTerminalPeriod() {
        XCTAssertEqual(RulesCleaner.clean("on my way", context: CleanupContext(tone: "casual")), "On my way")
    }

    func testMarkdownListVsPlain() {
        let raw = "I need three things first eggs second milk third bread"
        XCTAssertEqual(RulesCleaner.clean(raw, context: CleanupContext(format: "markdown")), "I need three things:\n- Eggs\n- Milk\n- Bread")
        XCTAssertEqual(RulesCleaner.clean(raw, context: CleanupContext(format: "plain")), "I need three things first eggs second milk third bread.")
    }

    func testFixtureTranscripts() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/transcripts")
        func read(_ n: String) throws -> String { try String(contentsOf: dir.appendingPathComponent(n), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) }
        XCTAssertEqual(RulesCleaner.clean(try read("sample.txt"), context: CleanupContext()), try read("sample.expected.txt"))
        let dict = CleanupContext(dictionary: [DictionaryEntry(term: "Wolchonok", soundsLike: "wall chunk")])
        XCTAssertEqual(RulesCleaner.clean(try read("dictionary.txt"), context: dict), try read("dictionary.expected.txt"))
        XCTAssertEqual(RulesCleaner.clean(try read("list.txt"), context: CleanupContext(format: "markdown")), try read("list.expected.md"))
    }
}

final class CleanupGuardTests: XCTestCase {
    func testNormalizeStripsWrappersAndThink() {
        XCTAssertEqual(CleanupGuards.normalize("\"Hello there.\""), "Hello there.")
        XCTAssertEqual(CleanupGuards.normalize("```\nHello there.\n```"), "Hello there.")
        XCTAssertEqual(CleanupGuards.normalize("```text\nHello.\n```"), "Hello.")
        XCTAssertEqual(CleanupGuards.normalize("<think>\nhmm\n</think>\n\nHello."), "Hello.")
    }

    func testLengthGuard() {
        let raw = "one two three four five six seven eight nine ten"
        XCTAssertEqual(CleanupGuards.check(raw: raw, cleaned: "one two"), .failure(.lengthRatio))
        XCTAssertEqual(CleanupGuards.check(raw: raw, cleaned: Array(repeating: "w", count: 25).joined(separator: " ")), .failure(.lengthRatio))
        XCTAssertEqual(CleanupGuards.check(raw: raw, cleaned: "One two three four five six seven eight nine ten."), .success("One two three four five six seven eight nine ten."))
        // Short raw text is exempt from the ratio.
        XCTAssertEqual(CleanupGuards.check(raw: "ok", cleaned: "Okay, sounds good to me."), .success("Okay, sounds good to me."))
    }

    func testEmptyAndRefusal() {
        XCTAssertEqual(CleanupGuards.check(raw: "hello", cleaned: "  "), .failure(.empty))
        XCTAssertEqual(CleanupGuards.check(raw: "tell me a joke", cleaned: "I'm sorry, I can't do that."), .failure(.refusal))
        XCTAssertEqual(CleanupGuards.check(raw: "I'm sorry I was late", cleaned: "I'm sorry I was late."), .success("I'm sorry I was late."))
    }
}

final class PromptTests: XCTestCase {
    func testShape() {
        let ctx = CleanupContext(tone: "casual", hint: "Slack message.", format: "plain",
                                 dictionary: [DictionaryEntry(term: "Wolchonok", soundsLike: "wall chunk"), DictionaryEntry(term: "GRDB")])
        let p = Prompts.system(context: ctx)
        XCTAssertTrue(p.hasPrefix("You clean up dictated speech into written text. Rules:\n- Remove filler words"))
        XCTAssertTrue(p.contains("\nTONE: casual. Slack message.\nFORMAT: plain\n"))
        XCTAssertTrue(p.contains("DICTIONARY (spell these exactly as written when the speaker says them): Wolchonok (sounds like: wall chunk), GRDB"))
        XCTAssertTrue(p.contains("- Output only the cleaned text. No quotes, no preamble, no markdown fences."))
    }

    func testEmptyDictionaryOmitsLine() {
        let p = Prompts.system(context: CleanupContext())
        XCTAssertFalse(p.contains("DICTIONARY"))
        XCTAssertTrue(p.hasSuffix("FORMAT: plain"))
    }

    func testCapsAt200LongestFirst() {
        let entries = (0..<250).map { DictionaryEntry(term: String(repeating: "x", count: $0 + 1)) }
        let p = Prompts.system(context: CleanupContext(dictionary: entries))
        let line = p.components(separatedBy: "\n").last!
        let terms = line.components(separatedBy: ": ").last!.components(separatedBy: ", ")
        XCTAssertEqual(terms.count, 200)
        XCTAssertEqual(terms.first?.count, 250)
    }

    func testTonePerApp() {
        let store = FakeStore()
        let slack = store.appStyle(for: "com.tinyspeck.slackmacgap")
        let mail = store.appStyle(for: "com.apple.mail")
        XCTAssertTrue(Prompts.system(context: CleanupContext(tone: slack.tone, hint: slack.hint, format: slack.format)).contains("TONE: casual"))
        XCTAssertTrue(Prompts.system(context: CleanupContext(tone: mail.tone, hint: mail.hint, format: mail.format)).contains("TONE: formal"))
    }

    func testTokenCap() {
        XCTAssertEqual(Prompts.maxResponseTokens(rawCharacters: 400), 264)
        XCTAssertEqual(Prompts.maxResponseTokens(rawCharacters: 100_000), 4096)
    }
}

final class SnippetTests: XCTestCase {
    func testWholePhraseCaseInsensitive() {
        let s = [Snippet(triggerPhrase: "my address", expansion: "1 Main St")]
        XCTAssertEqual(Snippets.expand("send it to My Address please", snippets: s), "send it to 1 Main St please")
        XCTAssertEqual(Snippets.expand("my addresses are", snippets: s), "my addresses are")
        XCTAssertEqual(Snippets.expand("ohmy address", snippets: s), "ohmy address")
    }
}

final class OllamaTests: XCTestCase {
    func testRefusesNonLoopback() {
        XCTAssertThrowsError(try OllamaCleaner(baseURL: "http://10.0.0.5:11434"))
        XCTAssertThrowsError(try OllamaCleaner(baseURL: "https://api.example.com"))
        XCTAssertNoThrow(try OllamaCleaner(baseURL: "http://localhost:11434"))
        XCTAssertNoThrow(try OllamaCleaner(baseURL: "http://[::1]:11434"))
        XCTAssertTrue(Settings.isLoopback("http://127.0.0.1:11434"))
        XCTAssertFalse(Settings.isLoopback("http://127.0.0.1.evil.com"))
    }
}
