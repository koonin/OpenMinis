import Foundation
import XCTest

/// Opt-in physical-device smoke test for the `apple-media` native offload.
///
/// This is intentionally skipped unless `RUN_APPLE_MEDIA_DEVICE_TEST=1` is
/// present in the UI-test runner environment. It controls the user's real
/// music library and must never run as part of the normal test suite.
@MainActor
final class AppleMediaPlaybackUITests: XCTestCase {
    func testNamedPlaylistStartsWithoutHangingTheApp() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_APPLE_MEDIA_DEVICE_TEST"] == "1" else {
            throw XCTSkip("Set RUN_APPLE_MEDIA_DEVICE_TEST=1 for the opt-in physical-device smoke test.")
        }

        guard let sessionID = environment["APPLE_MEDIA_TEST_SESSION_ID"],
              !sessionID.isEmpty else {
            throw XCTSkip("Set APPLE_MEDIA_TEST_SESSION_ID to an existing chat session on the device.")
        }
        let playlist = environment["APPLE_MEDIA_TEST_PLAYLIST"] ?? "日常"
        let outputPath = "/var/minis/shared/apple-media-ui-test.json"
        let completionMarker = "APPLE_MEDIA_UI_TEST_EXIT="

        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "OpenMinis did not reach the foreground."
        )

        let sessionURL = try XCTUnwrap(URL(string: "minis://sessions/\(sessionID)"))
        app.open(sessionURL)
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "OpenMinis did not remain in the foreground after opening the test session."
        )

        let shellCommand = [
            "apple-media play-playlist",
            "--query '\(playlist.replacingOccurrences(of: "'", with: "'\\''"))'",
            "--compact > \(outputPath) 2>&1;",
            "status=$?;",
            "echo \(completionMarker)$status;",
            "echo exit=$status >> \(outputPath)",
        ].joined(separator: " ")

        var terminalComponents = URLComponents()
        terminalComponents.scheme = "minis"
        terminalComponents.host = "open_terminal"
        terminalComponents.queryItems = [
            URLQueryItem(name: "init_command", value: shellCommand),
        ]
        app.open(try XCTUnwrap(terminalComponents.url))

        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 15), "The Minis terminal did not appear.")

        // `init_command` is deliberately pre-filled rather than executed. Wait
        // until the shell has booted and the command is visible before sending
        // Return; typing immediately races the delayed terminal prefill.
        let commandReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "apple-media play-playlist"),
            object: terminal
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [commandReady], timeout: 20),
            .completed,
            "The Apple Music command was not pre-filled in the terminal."
        )
        app.typeText("\n")

        let commandCompleted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", completionMarker + "0"),
            object: terminal
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [commandCompleted], timeout: 35),
            .completed,
            "apple-media did not complete successfully before its bounded playback deadline."
        )

        // The shell command exits before MediaOffload performs its delayed
        // (~750 ms) handoff to the system player. Keep observing the process
        // beyond that boundary so an immediate exit cannot produce a false
        // positive. A successful handoff may legitimately background Minis.
        XCTAssertFalse(
            app.wait(for: .notRunning, timeout: 2),
            "OpenMinis terminated during the delayed Apple Music handoff."
        )
        XCTAssertNotEqual(
            app.state,
            .notRunning,
            "OpenMinis was no longer running after starting Apple Music."
        )
    }
}
