import XCTest
@testable import Minis

final class GPT61SolIntegrationTests: XCTestCase {
    func testDiscoveryAndInferenceShareClientVersion() throws {
        let discovery = try OpenAIModelsAPI.codexModelsRequest(token: "test-token", accountId: "test-account")
        var inference = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/codex/responses")!)
        OpenAIProvider.applyCodexClientHeaders(to: &inference)
        XCTAssertEqual(OpenAIProvider.codexClientVersion, "0.162.0")
        XCTAssertEqual(URLComponents(url: discovery.url!, resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "client_version", value: OpenAIProvider.codexClientVersion)])
        for header in ["Version", "User-Agent", "Originator", "Openai-Beta"] {
            XCTAssertEqual(discovery.value(forHTTPHeaderField: header), inference.value(forHTTPHeaderField: header))
        }
        XCTAssertEqual(discovery.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(discovery.value(forHTTPHeaderField: "Chatgpt-Account-Id"), "test-account")
    }

    func testBuiltInAndManualMetadata() {
        XCTAssertEqual(LLMModel.allOpenAICodexOAuth.filter { $0.id == "gpt-6.1-sol" }.count, 1)
        for model in [LLMModel.gpt61Sol, LLMModel(id: "gpt-6.1-sol", displayName: "Manual", provider: "OpenAI")] {
            XCTAssertEqual(model.contextWindow, 1_050_000)
            XCTAssertEqual(model.maxOutputTokens, 128_000)
            XCTAssertEqual(model.supportsReasoning, true)
            XCTAssertEqual(model.modalityOverride, [.textInput, .imageInput, .textOutput])
            XCTAssertEqual(model.selectableThinkingLevels, [.low, .medium, .high, .xhigh, .max])
            XCTAssertEqual(model.catalogMaxThinkingLevel, .max)
            for (level, effort) in [(ThinkingLevel.low, "low"), (.medium, "medium"), (.high, "high"), (.xhigh, "xhigh"), (.max, "max"), (.ultra, "max")] {
                XCTAssertEqual(OpenAIAgentProvider.reasoningEffort(for: model, level: level), effort)
            }
        }
    }

    func testDiscoveryRetainsNewModelAndRespectsVisibility() throws {
        let data = Data(#"{"models":[{"slug":"gpt-6.1-sol","display_name":"GPT-6.1-Sol","visibility":"list","context_window":272000},{"slug":"hidden-model","visibility":"hidden"},{"slug":"disabled-model","available":false}]}"#.utf8)
        let models = OpenAIModelsAPI.parseCodexModels(data)
        XCTAssertEqual(models.map(\.id), ["gpt-6.1-sol"])
        let model = try XCTUnwrap(models.first)
        XCTAssertEqual(model.contextWindow, 272_000, "Account endpoint limits override offline defaults")
        XCTAssertEqual(model.supportsReasoning, true)
        XCTAssertEqual(model.catalogMaxThinkingLevel, .max)
        XCTAssertTrue(model.modalityOverride?.contains(.imageInput) == true)
        let oldAccount = OpenAIModelsAPI.parseCodexModels(Data(#"{"models":[{"slug":"gpt-6-sol"}]}"#.utf8))
        XCTAssertFalse(oldAccount.contains { $0.id == "gpt-6.1-sol" })
    }

    func testFallbackReportsProvenanceWithoutInventingAccountAccess() {
        let warnings = ["Refresh failed"]
        let cached = OpenAIModelsAPI.codexFallbackResult(cached: [.gpt6Sol], warnings: warnings)
        XCTAssertEqual(cached.models.map(\.id), ["gpt-6-sol"])
        XCTAssertEqual(cached.source, "Codex last successful cache")
        XCTAssertEqual(cached.warnings, warnings)
        for empty in [nil, []] as [[LLMModel]?] {
            let builtIn = OpenAIModelsAPI.codexFallbackResult(cached: empty, warnings: warnings)
            XCTAssertEqual(builtIn.models.filter { $0.id == "gpt-6.1-sol" }.count, 1)
            XCTAssertTrue(builtIn.source.contains("availability unverified"))
            XCTAssertEqual(builtIn.warnings, warnings)
            XCTAssertTrue(builtIn.models.contains { $0.id == "gpt-image-2.5-flare" })
        }
    }

    func testOfficialRoutingAndExplicitOverrides() {
        XCTAssertFalse(OpenAIProvider(apiKey: "unused", model: .gpt61Sol).usesChatCompletionsAPI)
        XCTAssertFalse(OpenAIProvider(oauthTokenProvider: { "unused" }, model: .gpt61Sol).usesChatCompletionsAPI)
        XCTAssertTrue(OpenAIProvider(apiKey: "unused", model: .gpt61Sol, customBaseURL: "https://relay.example").usesChatCompletionsAPI)
        let explicit = OpenAIProvider(apiKey: "unused", model: .gpt61Sol)
        explicit.absoluteEndpointOverride = "/v1/chat/completions"
        XCTAssertTrue(explicit.usesChatCompletionsAPI)
        XCTAssertEqual(OpenAIAgentProvider.explicitOffEffort(for: explicit, model: .gpt61Sol, level: .off), "low")
    }

    func testRequestSanitizationAndExactMatching() {
        XCTAssertTrue(GPT6AstraSupport.matchesAlwaysReasoningModel("GPT-6.1-SOL"))
        for id in ["gpt-6-sol", "gpt-6-luna", "gpt-6.1-sol-other", "relay/gpt-6.1-sol"] {
            XCTAssertFalse(GPT6AstraSupport.matchesAlwaysReasoningModel(id))
        }
        for (effort, expected) in [("none", "low"), ("minimal", "low"), ("high", "high"), ("max", "max"), ("ultra", "max")] {
            var body: [String: Any] = ["reasoning": ["effort": effort, "summary": "auto"], "temperature": 0.3,
                                       "tools": [["type": "function", "name": "test"]]]
            GPT6AstraSupport.prepare(&body, modelID: "gpt-6.1-sol", responses: true)
            XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], expected)
            XCTAssertEqual((body["reasoning"] as? [String: String])?["summary"], "auto")
            XCTAssertNil(body["temperature"])
            XCTAssertNotNil(body["tools"])
        }
    }

    @MainActor
    func testRefreshPreservesCustomModelsAndHiddenOverrides() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderConfigStore(fileURL: directory.appendingPathComponent("providers.json"))
        let instanceID = UUID().uuidString
        let prior = ModelEntry(providerInstanceId: instanceID, model: .gpt6Sol,
                               overrides: ModelOverrides(displayName: "Keep name"), isHidden: true)
        let custom = ModelEntry(providerInstanceId: instanceID,
                                model: LLMModel(id: "custom", displayName: "Custom", provider: "OpenAI"), isCustom: true)
        XCTAssertTrue(store.addEntry(prior))
        XCTAssertTrue(store.addEntry(custom))
        for _ in 0..<2 { store.replaceEntries(for: instanceID, models: [.gpt6Sol, .gpt61Sol]) }
        XCTAssertEqual(store.entry(for: prior.id)?.overrides.displayName, "Keep name")
        XCTAssertEqual(store.entry(for: prior.id)?.isHidden, true)
        XCTAssertNotNil(store.entry(for: custom.id))
        XCTAssertEqual(store.entries(for: instanceID).filter { $0.baseModel.id == "gpt-6.1-sol" }.count, 1)
    }
}
