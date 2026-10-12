import XCTest
@testable import Minis

final class IOS114IntegrationTests: XCTestCase {
    func testBothWorkerGenerationsStayOutOfUserFacingLists() {
        var session = ChatSession(id: "child", title: "Task", modelId: "gpt-5.5",
                                  createdAt: Date(), updatedAt: Date(), source: nil)
        XCTAssertTrue(session.isUserFacingConversation)
        session.parentSessionId = "parent"
        XCTAssertFalse(session.isUserFacingConversation)
        session.parentSessionId = nil
        session.source = ChatSession.delegatedWorkerSource
        XCTAssertFalse(session.isUserFacingConversation)
    }

    func testExplicitImageModelStaysInToolNotTextModel() throws {
        let provider = OpenAIProvider(oauthTokenProvider: { "unused" }, model: .gptImage2)
        let body = try provider.codexImageRequestBody(
            prompt: "Edit the reference", imageModel: "gpt-image-2.5-flare")
        XCTAssertEqual(body["model"] as? String, "gpt-5.5")
        let tool = try XCTUnwrap((body["tools"] as? [[String: Any]])?.first)
        XCTAssertEqual(tool["model"] as? String, "gpt-image-2.5-flare")
    }

    func testSecretBearingBackupsRequireEncryption() async {
        for category: BackupCategory in [.providers, .environmentVariables, .mcpServers] {
            do {
                _ = try await BackupExporter().export(options: .init(categories: [category]))
                XCTFail("Unencrypted credential export must fail: \(category)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("encrypted backup"))
            }
        }
    }

    func testCodexUsesLiveDiscoveryAndNewClientBaseline() {
        XCTAssertTrue(ProviderType.openAI.oauthSupportsModelDiscovery)
        XCTAssertEqual(OpenAIProvider.codexClientVersion, "0.162.0")
    }
}
