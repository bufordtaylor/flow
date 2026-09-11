import XCTest
@testable import FlowCore

final class PipelineTests: XCTestCase {
    func testHappyPathInsertsCleanedTextAndRecordsRow() async throws {
        let rig = Rig(final: "hello world")
        await rig.dictate()
        let state = await rig.pipeline.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(rig.inserter.inserted, ["HELLO WORLD "])
        XCTAssertEqual(rig.store.rows.count, 1)
        let row = rig.store.rows[0]
        XCTAssertEqual(row.rawText, "hello world")
        XCTAssertEqual(row.cleanedText, "HELLO WORLD")
        XCTAssertEqual(row.insertedText, "HELLO WORLD ")
        XCTAssertEqual(row.insertMethod, "ax")
        XCTAssertEqual(row.cleanupBackend, "ollama")
        XCTAssertEqual(row.wordCount, 2)
        XCTAssertEqual(row.durationMs, 1000)
        XCTAssertNil(row.error)
        XCTAssertEqual(rig.audio.startCount, 1)
        XCTAssertEqual(rig.audio.stopCount, 1)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(rig.events.contains { if case .done = $0 { return true }; return false })
        XCTAssertTrue(rig.events.contains { if case .timings = $0 { return true }; return false })
    }

    func testStateSequence() async throws {
        let rig = Rig()
        var idle = await rig.pipeline.state
        XCTAssertEqual(idle, .idle)
        await rig.pipeline.hotkeyDown()
        let listening = await rig.pipeline.state
        XCTAssertEqual(listening, .listening)
        rig.clock.advance(ms: 500)
        await rig.pipeline.hotkeyUp()
        idle = await rig.pipeline.state
        XCTAssertEqual(idle, .idle)
    }

    func testAccidentalTapCancelsSilently() async throws {
        let rig = Rig()
        await rig.pipeline.hotkeyDown()
        rig.clock.advance(ms: 100)
        await rig.pipeline.hotkeyUp()
        XCTAssertEqual(rig.store.rows.count, 0)
        XCTAssertEqual(rig.inserter.inserted, [])
        XCTAssertEqual(rig.audio.stopCount, 1)
    }

    func testEscapeWhileListeningWritesCancelledRowWithNullText() async throws {
        let rig = Rig()
        await rig.pipeline.hotkeyDown()
        rig.clock.advance(ms: 1000)
        await rig.pipeline.escape()
        let state = await rig.pipeline.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(rig.store.rows.count, 1)
        XCTAssertEqual(rig.store.rows[0].insertMethod, "cancelled")
        XCTAssertNil(rig.store.rows[0].rawText)
        XCTAssertNil(rig.store.rows[0].cleanedText)
        XCTAssertEqual(rig.inserter.inserted, [])
    }

    func testEmptyTranscriptWritesNothing() async throws {
        let rig = Rig(final: "   ")
        await rig.dictate()
        XCTAssertEqual(rig.store.rows.count, 0)
        XCTAssertEqual(rig.inserter.inserted, [])
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(rig.events.contains { $0 == .idle })
    }

    func testHotkeyIgnoredWhileNotIdle() async throws {
        let rig = Rig()
        await rig.pipeline.hotkeyDown()
        await rig.pipeline.hotkeyDown()
        XCTAssertEqual(rig.audio.startCount, 1)
        rig.clock.advance(ms: 1000)
        await rig.pipeline.hotkeyUp()
        XCTAssertEqual(rig.store.rows.count, 1)
    }

    func testToggleMode() async throws {
        let rig = Rig { $0.hotkeyMode = .toggle }
        await rig.pipeline.hotkeyDown()
        await rig.pipeline.hotkeyUp()  // ignored in toggle mode
        var s = await rig.pipeline.state
        XCTAssertEqual(s, .listening)
        rig.clock.advance(ms: 1000)
        await rig.pipeline.hotkeyDown()  // second tap ends
        s = await rig.pipeline.state
        XCTAssertEqual(s, .idle)
        XCTAssertEqual(rig.inserter.inserted.count, 1)
    }

    func testCleanupTimeoutInsertsRawWithoutWaitingForTheLoser() async throws {
        let rig = Rig(final: "raw words here", cleaner: FakeCleaner(mode: .park))
        await rig.pipeline.hotkeyDown()
        rig.clock.advance(ms: 1000)
        let up = Task { await rig.pipeline.hotkeyUp() }
        await rig.clock.waitForSleeper(ms: 4000)
        rig.clock.advance(ms: 4000)
        let start = Date()
        await up.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "insertion waited for the parked cleaner")
        XCTAssertEqual(rig.inserter.inserted, ["raw words here "])
        XCTAssertEqual(rig.store.rows[0].error, "cleanup_timeout")
        XCTAssertEqual(rig.store.rows[0].cleanedText, "raw words here")
    }

    func testCleanerErrorFallsBackToRaw() async throws {
        struct Boom: Error {}
        let rig = Rig(final: "some raw text", cleaner: FakeCleaner(mode: .fail(Boom())))
        await rig.dictate()
        XCTAssertEqual(rig.inserter.inserted, ["some raw text "])
        XCTAssertEqual(rig.store.rows[0].error, "cleanup_error")
    }

    func testCleanerUnavailableRetriesWithRules() async throws {
        let rig = Rig(final: "um so send it uh Tuesday no Wednesday", cleaner: FakeCleaner(mode: .unavailable))
        await rig.dictate()
        XCTAssertEqual(rig.inserter.inserted, ["So send it Wednesday. "])
        XCTAssertEqual(rig.store.rows[0].cleanupBackend, "rules")
        XCTAssertNil(rig.store.rows[0].error)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(rig.events.contains { $0 == .backendUnavailable(.ollama) })
    }

    func testGuardRejectsBadResponse() async throws {
        let rig = Rig(final: "one two three four five six seven", cleaner: FakeCleaner(mode: .transform({ _ in "no" })))
        await rig.dictate()
        XCTAssertEqual(rig.inserter.inserted, ["one two three four five six seven "])
        XCTAssertEqual(rig.store.rows[0].error, "cleanup_guard")
    }

    func testEscapeDuringCleanupSkipsCleaner() async throws {
        let rig = Rig(final: "spoken already", cleaner: FakeCleaner(mode: .park))
        await rig.pipeline.hotkeyDown()
        rig.clock.advance(ms: 1000)
        let up = Task { await rig.pipeline.hotkeyUp() }
        let reached = await rig.waitFor(.cleaning)
        XCTAssertTrue(reached)
        await rig.pipeline.escape()
        await up.value
        XCTAssertEqual(rig.inserter.inserted, ["spoken already "])
        XCTAssertEqual(rig.store.rows[0].error, "cleanup_skipped")
    }

    func testCleanupOffAndRawToneSkipCleaner() async throws {
        let rig = Rig(final: "keep me") { $0.cleanupBackend = .off }
        await rig.dictate()
        XCTAssertEqual(rig.cleaner.calls, 0)
        XCTAssertEqual(rig.store.rows[0].cleanupBackend, "off")

        let rig2 = Rig(final: "keep me too")
        rig2.store.styles["com.apple.TextEdit"] = AppStyle(bundleId: "com.apple.TextEdit", appName: "TextEdit", tone: "raw", hint: "", format: "plain")
        await rig2.dictate()
        XCTAssertEqual(rig2.cleaner.calls, 0)
        XCTAssertEqual(rig2.inserter.inserted, ["keep me too "])
    }

    func testSnippetsExpandBeforeCleanup() async throws {
        let rig = Rig(final: "my email is my sig")
        rig.store.snippetList = [Snippet(triggerPhrase: "My Sig", expansion: "buf@example.com")]
        await rig.dictate()
        XCTAssertEqual(rig.cleaner.calls, 1)
        XCTAssertEqual(rig.store.rows[0].cleanedText, "MY EMAIL IS BUF@EXAMPLE.COM")
    }

    func testAppStyleDrivesContext() async throws {
        let rig = Rig(final: "hello")
        rig.frontmost.bundleId = "com.tinyspeck.slackmacgap"
        await rig.dictate()
        XCTAssertEqual(rig.cleaner.contexts.first?.tone, "casual")
        rig.frontmost.bundleId = "com.apple.mail"
        await rig.dictate()
        XCTAssertEqual(rig.cleaner.contexts.last?.tone, "formal")
    }

    func testStoreTranscriptsOffKeepsTimingsOnly() async throws {
        let rig = Rig(final: "secret words") { $0.storeTranscripts = false }
        await rig.dictate()
        let row = rig.store.rows[0]
        XCTAssertNil(row.rawText); XCTAssertNil(row.cleanedText); XCTAssertNil(row.insertedText)
        XCTAssertEqual(row.wordCount, 2)
    }

    func testSecureFieldNeverStoresText() async throws {
        let rig = Rig(final: "hunter2")
        rig.inserter.result = .failed("secure field")
        await rig.dictate()
        let row = rig.store.rows[0]
        XCTAssertEqual(row.insertMethod, "failed")
        XCTAssertNil(row.rawText)
        XCTAssertEqual(row.error, "insert_failed: secure field")
    }

    func testTrailingSpaceRules() async throws {
        let rig = Rig(final: "with space", cleaner: FakeCleaner(mode: .transform({ $0 })))
        await rig.dictate()
        XCTAssertEqual(rig.inserter.inserted, ["with space "])
        let rig2 = Rig(final: "no space") { $0.trailingSpace = false }
        await rig2.dictate()
        XCTAssertEqual(rig2.inserter.inserted, ["NO SPACE"])
    }

    func testDictionaryUseCountIncrements() async throws {
        let rig = Rig(final: "call Wolchonok now", cleaner: FakeCleaner(mode: .transform({ $0 })))
        rig.store.entries = [DictionaryEntry(term: "Wolchonok", soundsLike: "wall chunk")]
        await rig.dictate()
        XCTAssertEqual(rig.store.useIncrements, ["Wolchonok"])
    }

    func testFinalTimeoutFallsBackToInterim() async throws {
        let rig = Rig(final: nil, cleaner: FakeCleaner(mode: .transform({ $0 })))
        await rig.pipeline.hotkeyDown()
        rig.transcriber.interim("partial words")
        rig.clock.advance(ms: 1000)
        let up = Task { await rig.pipeline.hotkeyUp() }
        await rig.clock.waitForSleeper(ms: 3000)
        rig.clock.advance(ms: 3000)
        await up.value
        XCTAssertEqual(rig.inserter.inserted, ["partial words "])
        XCTAssertEqual(rig.store.rows[0].error, "stt_timeout")
    }

    func testFiveMinuteCapEndsDictation() async throws {
        let rig = Rig(final: "long one") { $0.maxDictationMs = 5000 }
        await rig.pipeline.hotkeyDown()
        await rig.clock.waitForSleeper(ms: 5000)
        rig.clock.advance(ms: 5000)
        let idle = await rig.waitFor(.idle)
        XCTAssertTrue(idle)
        XCTAssertEqual(rig.inserter.inserted, ["LONG ONE "])
    }

    func testMicrophoneFailure() async throws {
        let rig = Rig()
        rig.audio.failOnStart = true
        await rig.pipeline.hotkeyDown()
        let s = await rig.pipeline.state
        XCTAssertEqual(s, .idle)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(rig.events.contains { $0 == .error("Couldn't open the microphone") })
    }

    func testTranscriberFailureWhileListening() async throws {
        let rig = Rig()
        rig.transcriber.failImmediately = TranscriberError.noModel
        await rig.pipeline.hotkeyDown()
        let idle = await rig.waitFor(.idle)
        XCTAssertTrue(idle)
        XCTAssertEqual(rig.store.rows.first?.insertMethod, "failed")
        XCTAssertEqual(rig.store.rows.first?.error, TranscriberError.noModel.errorDescription)
    }
}

final class WithTimeoutTests: XCTestCase {
    func testWinnerReturnsAndLoserIsAbandoned() async throws {
        let clock = ManualClock()
        let v = try await withTimeout(ms: 100, clock: clock) { 42 }
        XCTAssertEqual(v, 42)
    }

    func testTimeoutDoesNotWaitForParkedWork() async throws {
        let clock = ManualClock()
        let t = Task { () throws -> Int in
            try await withTimeout(ms: 500, clock: clock) {
                await withCheckedContinuation { (_: CheckedContinuation<Int, Never>) in }
            }
        }
        await clock.waitForSleeper(ms: 500)
        clock.advance(ms: 500)
        do { _ = try await t.value; XCTFail("expected timeout") }
        catch { XCTAssertTrue(error is TimeoutError) }
    }

    func testCancellationPropagates() async throws {
        let clock = ManualClock()
        let t = Task { () throws -> Int in
            try await withTimeout(ms: 500, clock: clock) {
                await withCheckedContinuation { (_: CheckedContinuation<Int, Never>) in }
            }
        }
        await clock.waitForSleeper(ms: 500)
        t.cancel()
        do { _ = try await t.value; XCTFail("expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
