import XCTest
@testable import Minis

final class GPT6AstraIntegrationTests: XCTestCase {
    func testCodexHeadersUseConsistentAstraCompatibleVersion() {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/codex/responses")!)
        request.setValue("Bearer test-placeholder", forHTTPHeaderField: "Authorization")
        request.setValue("test-account", forHTTPHeaderField: "Chatgpt-Account-Id")
        OpenAIProvider.applyCodexClientHeaders(to: &request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Version"), OpenAIProvider.codexClientVersion)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "codex_cli_rs/\(OpenAIProvider.codexClientVersion) (iOS; arm64)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Originator"), "codex_cli_rs")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Openai-Beta"), "responses=experimental")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-placeholder")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Chatgpt-Account-Id"), "test-account")
    }

    func testCatalogAndManualModelsHaveOfflineMetadata() {
        XCTAssertEqual(LLMModel.allOpenAICodexOAuth.filter { $0.id == "gpt-6-astra" }.count, 1)
        for model in [LLMModel.gpt6Astra, LLMModel(id: "gpt-6-astra", displayName: "Manual", provider: "OpenAI")] {
            XCTAssertEqual(model.contextWindow, 1_050_000)
            XCTAssertEqual(model.maxOutputTokens, 128_000)
            XCTAssertEqual(model.supportsReasoning, true)
            XCTAssertEqual(model.modalityOverride, [.textInput, .imageInput, .textOutput])
            XCTAssertEqual(model.selectableThinkingLevels, [.low, .medium, .high, .xhigh, .max])
            XCTAssertEqual(model.catalogMaxThinkingLevel, .max)
        }
    }

    func testOfficialAndOAuthProvidersUseResponsesWithoutChangingOtherRoutes() {
        XCTAssertFalse(OpenAIProvider(apiKey: "unused", model: .gpt6Astra).usesChatCompletionsAPI)
        XCTAssertFalse(OpenAIProvider(oauthTokenProvider: { "unused" }, model: .gpt6Astra).usesChatCompletionsAPI)
        XCTAssertTrue(OpenAIProvider(apiKey: "unused", model: .gpt55).usesChatCompletionsAPI)
        XCTAssertTrue(OpenAIProvider(apiKey: "unused", model: .gpt6Astra,
                                     customBaseURL: "https://relay.example").usesChatCompletionsAPI)
        let explicitEndpoint = OpenAIProvider(apiKey: "unused", model: .gpt6Astra)
        explicitEndpoint.absoluteEndpointOverride = "/v1/chat/completions"
        XCTAssertTrue(explicitEndpoint.usesChatCompletionsAPI)
    }

    func testOffAndUltraDoNotSendUnsupportedEfforts() {
        let provider = OpenAIProvider(apiKey: "unused", model: .gpt6Astra)
        XCTAssertEqual(OpenAIAgentProvider.explicitOffEffort(for: provider, model: .gpt6Astra, level: .off), "low")
        XCTAssertEqual(OpenAIAgentProvider.reasoningEffort(for: .gpt6Astra, level: .ultra), "max")
        var body: [String: Any] = [:]
        OpenAIAgentProvider.injectThinkingParams(into: &body, model: .gpt6Astra, level: .max)
        XCTAssertEqual(body["reasoning_effort"] as? String, "max")
        XCTAssertNil(body["thinking"])
    }

    @MainActor
    func testRefreshPreservesExistingCustomModelsAndOverrides() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderConfigStore(fileURL: directory.appendingPathComponent("providers.json"))
        let instanceID = UUID().uuidString
        let prior = ModelEntry(providerInstanceId: instanceID, model: .gpt55,
                               overrides: ModelOverrides(displayName: "Keep my name"), isHidden: true)
        let custom = ModelEntry(providerInstanceId: instanceID,
                                model: LLMModel(id: "my-custom-model", displayName: "Custom", provider: "OpenAI"), isCustom: true)
        XCTAssertTrue(store.addEntry(prior))
        XCTAssertTrue(store.addEntry(custom))
        store.replaceEntries(for: instanceID, models: ModelsDevAPI.enrichModels(LLMModel.allOpenAICodexOAuth))
        XCTAssertEqual(store.entry(for: prior.id)?.overrides.displayName, "Keep my name")
        XCTAssertEqual(store.entry(for: prior.id)?.isHidden, true)
        XCTAssertNotNil(store.entry(for: custom.id))
        XCTAssertEqual(store.entries(for: instanceID).filter { $0.baseModel.id == "gpt-6-astra" }.count, 1)
        store.replaceEntries(for: instanceID, models: ModelsDevAPI.enrichModels(LLMModel.allOpenAICodexOAuth))
        XCTAssertEqual(store.entries(for: instanceID).filter { $0.baseModel.id == "gpt-6-astra" }.count, 1)
    }
}
