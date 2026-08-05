import XCTest

final class DelegatedSessionConcentrationTests: XCTestCase {
    func testOnlyDelegatedWorkerSourceIsHidden() {
        XCTAssertFalse(DelegatedSessionPolicy.isUserFacing(
            source: DelegatedSessionPolicy.sessionSource
        ))
        XCTAssertTrue(DelegatedSessionPolicy.isUserFacing(source: nil))
        XCTAssertTrue(DelegatedSessionPolicy.isUserFacing(source: "shortcut"))
        XCTAssertTrue(DelegatedSessionPolicy.isUserFacing(source: "siri"))
        XCTAssertTrue(DelegatedSessionPolicy.isUserFacing(source: "unknown"))
    }

    func testWorkerBrowserBudgetLeavesTimeForRecovery() {
        XCTAssertEqual(
            DelegatedSessionPolicy.browserActionDeadTimeout(totalTimeoutSeconds: 180),
            60
        )
        XCTAssertEqual(
            DelegatedSessionPolicy.browserActionDeadTimeout(totalTimeoutSeconds: 10),
            5
        )
        XCTAssertLessThan(
            DelegatedSessionPolicy.browserActionDeadTimeout(totalTimeoutSeconds: 900),
            900
        )
    }
}
