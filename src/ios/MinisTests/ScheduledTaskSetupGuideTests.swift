import Foundation
import XCTest

final class ScheduledTaskSetupGuideTests: XCTestCase {
    func testAgentGuidanceUsesSavedShortcutFlowAndRejectsAskMinis() {
        let guidance = ScheduledTaskSetupGuide.agentGuidance

        XCTAssertTrue(guidance.contains("regular shortcut"))
        XCTAssertTrue(guidance.contains("Send Prompt"))
        XCTAssertTrue(guidance.contains("Prompt"))
        XCTAssertTrue(guidance.contains("Run Immediately"))
        XCTAssertTrue(guidance.contains("Create Personal Automation"))
        XCTAssertTrue(guidance.contains("Ask Before Running"))
        XCTAssertTrue(guidance.contains("Don’t Ask"))
        XCTAssertTrue(guidance.contains("search for that saved shortcut"))
        XCTAssertTrue(guidance.contains("Run Shortcut"))
        XCTAssertTrue(guidance.contains(ScheduledTaskSetupGuide.setupDeepLink))
        XCTAssertTrue(guidance.contains("Never tell the user to select Ask Minis"))
        XCTAssertFalse(guidance.contains("New Blank Automation"))
    }

    func testShortcutDeepLinksUseAppleShortcutsScheme() throws {
        let appURL = try XCTUnwrap(URL(string: ScheduledTaskSetupGuide.shortcutsAppDeepLink))
        let createURL = try XCTUnwrap(URL(string: ScheduledTaskSetupGuide.createShortcutDeepLink))

        XCTAssertEqual(appURL.scheme, "shortcuts")
        XCTAssertEqual(createURL.scheme, "shortcuts")
        XCTAssertEqual(createURL.host, "create-shortcut")
    }

    func testPreparedPromptRoundTripsReservedCharactersAndUnicode() throws {
        let expected = "访问 https://example.com/?a=1&b=2\n总结 #AI 热点 🤖 + 趋势"
        var components = try XCTUnwrap(URLComponents(string: ScheduledTaskSetupGuide.setupDeepLink))
        components.queryItems = [URLQueryItem(name: "prompt", value: expected)]

        let url = try XCTUnwrap(components.url)
        let prepared = try XCTUnwrap(ScheduledTaskSetupGuide.preparedPrompt(from: url))

        XCTAssertEqual(prepared.text, expected)
        XCTAssertFalse(prepared.wasTruncated)
    }

    func testPreparedPromptRejectsMissingOrWhitespaceOnlyValue() throws {
        let plainURL = try XCTUnwrap(URL(string: ScheduledTaskSetupGuide.setupDeepLink))
        let emptyURL = try XCTUnwrap(URL(string: "\(ScheduledTaskSetupGuide.setupDeepLink)?prompt=%20%0A%20"))

        XCTAssertNil(ScheduledTaskSetupGuide.preparedPrompt(from: plainURL))
        XCTAssertNil(ScheduledTaskSetupGuide.preparedPrompt(from: emptyURL))
    }

    func testPreparedPromptReportsAndLimitsOversizedValue() throws {
        let oversized = String(
            repeating: "测",
            count: ScheduledTaskSetupGuide.maxPreparedPromptCharacters + 25
        )
        var components = try XCTUnwrap(URLComponents(string: ScheduledTaskSetupGuide.setupDeepLink))
        components.queryItems = [URLQueryItem(name: "prompt", value: oversized)]

        let prepared = try XCTUnwrap(
            ScheduledTaskSetupGuide.preparedPrompt(from: try XCTUnwrap(components.url))
        )

        XCTAssertEqual(prepared.text.count, ScheduledTaskSetupGuide.maxPreparedPromptCharacters)
        XCTAssertTrue(prepared.wasTruncated)
    }

    func testMinisLogDescriptionRedactsPromptQuery() throws {
        let secret = "private task details"
        var components = try XCTUnwrap(URLComponents(string: ScheduledTaskSetupGuide.setupDeepLink))
        components.queryItems = [URLQueryItem(name: "prompt", value: secret)]

        let description = ScheduledTaskSetupGuide.logDescription(
            for: try XCTUnwrap(components.url)
        )

        XCTAssertEqual(description, "minis://settings/scheduled-tasks?<redacted>")
        XCTAssertFalse(description.contains(secret))
    }
}
