import XCTest
@testable import FlowCore

final class AudioTests: XCTestCase {
    func testGainNormalizesPeakToMinus3dBFS() {
        let quiet: [Float] = [0.1, -0.2, 0.05]
        let out = GainNormalizer.normalize(quiet)
        XCTAssertEqual(out.map { abs($0) }.max()!, GainNormalizer.targetPeak, accuracy: 0.001)
    }

    func testGainNeverExceeds20dB() {
        let silent: [Float] = [0.001, -0.002]
        let out = GainNormalizer.normalize(silent)
        XCTAssertEqual(out[1], -0.02, accuracy: 0.0001)
        XCTAssertEqual(GainNormalizer.gain(for: [0]), 1)
        XCTAssertEqual(GainNormalizer.gain(for: []), 1)
    }

    func testLoudAudioIsAttenuated() {
        let out = GainNormalizer.normalize([1.0, -1.0, 0.5])
        XCTAssertEqual(out[0], GainNormalizer.targetPeak, accuracy: 0.001)
    }

    func testTrimmerKeeps200msPadding() {
        let samples = [Float](repeating: 0.1, count: 16_000 * 3)
        let out = SilenceTrimmer.trim(samples, spans: [SpeechSpan(start: 16_000, end: 32_000)])
        XCTAssertEqual(out.count, 16_000 + 2 * 3_200)
    }

    func testTrimmerClampsToBuffer() {
        let samples = [Float](repeating: 0.1, count: 10_000)
        XCTAssertEqual(SilenceTrimmer.trim(samples, spans: [SpeechSpan(start: 1000, end: 9000)]).count, 10_000)
    }

    func testTrimmerNoSpeechIsEmpty() {
        XCTAssertEqual(SilenceTrimmer.trim([Float](repeating: 0.1, count: 16_000), spans: []), [])
    }

    func testRms() {
        XCTAssertEqual(Level.rms([0.5, -0.5, 0.5, -0.5]), 0.5, accuracy: 0.0001)
        XCTAssertEqual(Level.rms([]), 0)
    }
}

final class HotkeyMatcherTests: XCTestCase {
    let opt = HotkeyMatcher.option
    let shift = HotkeyMatcher.shift

    func testOptionComboNeverStarts() {
        var m = HotkeyMatcher(spec: .rightOption)
        XCTAssertEqual(m.handle(kind: .flagsChanged, keyCode: 61, flags: opt, dictating: false), .arm)
        // ⌥← inside the arm window: disarm, pass through, zero side effects.
        XCTAssertEqual(m.handle(kind: .keyDown, keyCode: 123, flags: opt, dictating: false), .disarm)
        XCTAssertEqual(m.armTimerFired(), .ignore)
        XCTAssertEqual(m.handle(kind: .flagsChanged, keyCode: 61, flags: 0, dictating: false), .ignore)
        XCTAssertEqual(m.phase, .idle)
    }

    func testQuickTapDisarms() {
        var m = HotkeyMatcher(spec: .rightOption)
        XCTAssertEqual(m.handle(kind: .flagsChanged, keyCode: 61, flags: opt, dictating: false), .arm)
        XCTAssertEqual(m.handle(kind: .flagsChanged, keyCode: 61, flags: 0, dictating: false), .disarm)
        XCTAssertEqual(m.armTimerFired(), .ignore)
    }

    func testHeldBecomesDownThenUp() {
        var m = HotkeyMatcher(spec: .rightOption)
        XCTAssertEqual(m.handle(kind: .flagsChanged, keyCode: 61, flags: opt, dictating: false), .arm)
        XCTAssertEqual(m.armTimerFired(), .down(swallow: false))
        XCTAssertEqual(m.phase, .held)
        XCTAssertEqual(m.handle(kind: .flagsChanged, keyCode: 61, flags: 0, dictating: true), .up(swallow: false))
        XCTAssertEqual(m.phase, .idle)
    }

    func testShiftAlreadyHeldDoesNotArm() {
        var m = HotkeyMatcher(spec: .rightOption)
        XCTAssertEqual(m.handle(kind: .flagsChanged, keyCode: 61, flags: opt | shift, dictating: false), .ignore)
        XCTAssertEqual(m.phase, .idle)
    }

    func testLeftOptionDoesNotArmRightOptionHotkey() {
        var m = HotkeyMatcher(spec: .rightOption)
        XCTAssertEqual(m.handle(kind: .flagsChanged, keyCode: 58, flags: opt, dictating: false), .ignore)
    }

    func testOtherKeyWhileHeldCancelsSilently() {
        var m = HotkeyMatcher(spec: .rightOption)
        _ = m.handle(kind: .flagsChanged, keyCode: 61, flags: opt, dictating: false)
        _ = m.armTimerFired()
        XCTAssertEqual(m.handle(kind: .keyDown, keyCode: 51, flags: opt, dictating: true), .cancelSilently)
        XCTAssertEqual(m.phase, .idle)
    }

    func testEscapeWhileDictating() {
        var m = HotkeyMatcher(spec: .rightOption)
        XCTAssertEqual(m.handle(kind: .keyDown, keyCode: 53, flags: 0, dictating: true), .escape)
        XCTAssertEqual(m.handle(kind: .keyDown, keyCode: 53, flags: 0, dictating: false), .ignore)
    }

    func testChordHotkey() {
        var m = HotkeyMatcher(spec: HotkeySpec(keyCode: 49, modifiers: HotkeyMatcher.control | HotkeyMatcher.option))
        XCTAssertEqual(m.handle(kind: .flagsChanged, keyCode: 59, flags: HotkeyMatcher.control, dictating: false), .ignore)
        XCTAssertEqual(m.handle(kind: .keyDown, keyCode: 49, flags: HotkeyMatcher.control, dictating: false), .ignore)
        XCTAssertEqual(m.handle(kind: .keyDown, keyCode: 49, flags: HotkeyMatcher.control | HotkeyMatcher.option, dictating: false), .down(swallow: true))
        XCTAssertEqual(m.handle(kind: .keyDown, keyCode: 49, flags: HotkeyMatcher.control | HotkeyMatcher.option, dictating: true), .swallow)
        XCTAssertEqual(m.handle(kind: .keyUp, keyCode: 49, flags: HotkeyMatcher.control | HotkeyMatcher.option, dictating: true), .up(swallow: true))
        XCTAssertEqual(HotkeySpec(keyCode: 49, modifiers: HotkeyMatcher.control | HotkeyMatcher.option).displayString, "⌃⌥ Space")
        XCTAssertEqual(HotkeySpec.rightOption.displayString, "⌥ (right)")
    }
}
