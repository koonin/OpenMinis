import XCTest

final class StaleMarkerClassifierTests: XCTestCase {
    func testNoTabsIsExplicitlyIdle() {
        XCTAssertTrue(
            StaleMarkerClassifier.browserWasExplicitlyIdle(
                totalTabs: 0,
                tabs: [],
                inflightActionCount: 0
            )
        )
    }

    func testCachedLoadedTabIsExplicitlyIdle() {
        XCTAssertTrue(
            StaleMarkerClassifier.browserWasExplicitlyIdle(
                totalTabs: 1,
                tabs: [["inUse": false, "isLoading": false]],
                inflightActionCount: 0
            )
        )
    }

    func testMultipleCachedTabsAreExplicitlyIdle() {
        XCTAssertTrue(
            StaleMarkerClassifier.browserWasExplicitlyIdle(
                totalTabs: 2,
                tabs: [
                    ["inUse": false, "isLoading": false],
                    ["inUse": false, "isLoading": false],
                ],
                inflightActionCount: 0
            )
        )
    }

    func testInUseTabIsNotIdle() {
        XCTAssertFalse(
            StaleMarkerClassifier.browserWasExplicitlyIdle(
                totalTabs: 1,
                tabs: [["inUse": true, "isLoading": false]],
                inflightActionCount: 0
            )
        )
    }

    func testLoadingTabIsNotIdle() {
        XCTAssertFalse(
            StaleMarkerClassifier.browserWasExplicitlyIdle(
                totalTabs: 1,
                tabs: [["inUse": false, "isLoading": true]],
                inflightActionCount: 0
            )
        )
    }

    func testInflightBrowserActionIsNotIdle() {
        XCTAssertFalse(
            StaleMarkerClassifier.browserWasExplicitlyIdle(
                totalTabs: 1,
                tabs: [["inUse": false, "isLoading": false]],
                inflightActionCount: 1
            )
        )
    }

    func testIncompleteOrInconsistentSnapshotsFailClosed() {
        XCTAssertFalse(
            StaleMarkerClassifier.browserWasExplicitlyIdle(
                totalTabs: nil,
                tabs: [],
                inflightActionCount: 0
            )
        )
        XCTAssertFalse(
            StaleMarkerClassifier.browserWasExplicitlyIdle(
                totalTabs: -1,
                tabs: [],
                inflightActionCount: 0
            )
        )
        XCTAssertFalse(
            StaleMarkerClassifier.browserWasExplicitlyIdle(
                totalTabs: 1,
                tabs: nil,
                inflightActionCount: 0
            )
        )
        XCTAssertFalse(
            StaleMarkerClassifier.browserWasExplicitlyIdle(
                totalTabs: 1,
                tabs: [["inUse": false]],
                inflightActionCount: 0
            )
        )
        XCTAssertFalse(
            StaleMarkerClassifier.browserWasExplicitlyIdle(
                totalTabs: 2,
                tabs: [["inUse": false, "isLoading": false]],
                inflightActionCount: 0
            )
        )
        XCTAssertFalse(
            StaleMarkerClassifier.browserWasExplicitlyIdle(
                totalTabs: 0,
                tabs: [],
                inflightActionCount: nil
            )
        )
    }
}
