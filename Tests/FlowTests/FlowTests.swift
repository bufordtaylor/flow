import XCTest
@testable import Flow
import FlowCore

final class FlowTests: XCTestCase {
    @MainActor
    func testWindowTableMatchesCheck() {
        for e in WindowCheck.table where e.name != "overlay" {
            let spec = WindowSpec.spec(WindowKind(rawValue: e.name)!)
            XCTAssertEqual(spec.size, e.size, e.name)
            XCTAssertEqual(spec.resizable, e.resizable, e.name)
            if let m = spec.minSize { XCTAssertEqual(m, e.min, e.name) }
        }
    }

    func testTerminalDetectionList() {
        XCTAssertTrue(WorkspaceFrontmost.terminalBundleIds.contains("com.apple.Terminal"))
        XCTAssertTrue(WorkspaceFrontmost.terminalBundleIds.contains("com.googlecode.iterm2"))
    }

    func testAppleCleanerReportsReasonWhenUnavailable() {
        let (cleaner, a) = AppleCleanerSupport.make()
        if cleaner == nil { XCTAssertFalse(a.reason.isEmpty) } else { XCTAssertTrue(a.available) }
    }

    func testArmDelayIs120ms() {
        XCTAssertEqual(HotkeyTap.armDelayMs, 120)
    }
}
