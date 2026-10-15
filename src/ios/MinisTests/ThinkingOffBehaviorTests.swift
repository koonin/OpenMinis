import XCTest
@testable import Minis

final class ThinkingOffBehaviorTests: XCTestCase {
    func testAlwaysReasoningModelsUseLowInsteadOfOff() {
        for model in [LLMModel.gpt61Sol, .gpt6Astra] {
            for codex in [false, true] {
                XCTAssertEqual(ThinkingLevelCatalog.minimumLevel(for: model, isCodexOAuth: codex), .low)
                XCTAssertEqual(OpenAIAgentProvider.responsesReasoningConfiguration(
                    for: model, level: .off, isCodexOAuth: codex, offEffort: "low"),
                    ["effort": "low", "summary": "auto"])
            }
        }
    }

    func testSupportedCodexOffIsExplicitAndDoesNotRequestSummary() {
        for var model in [LLMModel.gpt6Sol, .gpt6Luna] {
            model.codexReasoningEffortValues = ["none", "low", "medium", "high"]
            XCTAssertEqual(ThinkingLevelCatalog.minimumLevel(for: model, isCodexOAuth: true), .off)
            XCTAssertEqual(OpenAIAgentProvider.responsesReasoningConfiguration(
                for: model, level: .off, isCodexOAuth: true, offEffort: nil), ["effort": "none"])
            XCTAssertEqual(OpenAIAgentProvider.responsesReasoningConfiguration(
                for: model, level: .high, isCodexOAuth: true, offEffort: nil),
                ["effort": "high", "summary": "auto"])
        }
    }

    func testAPIOffSupportDoesNotImplyCodexOffSupport() {
        for model in [LLMModel.gpt6Sol, .gpt6Luna] {
            XCTAssertEqual(ThinkingLevelCatalog.minimumLevel(for: model, isCodexOAuth: true), .low)
            XCTAssertEqual(ThinkingLevelCatalog.minimumLevel(for: model, isCodexOAuth: false), .off)
            let api = OpenAIProvider(apiKey: "unused", model: model)
            let off = OpenAIAgentProvider.explicitOffEffort(for: api, model: model, level: .off)
            XCTAssertEqual(OpenAIAgentProvider.responsesReasoningConfiguration(
                for: model, level: .off, isCodexOAuth: false, offEffort: off), ["effort": "none"])
        }
    }

    func testAccountTiersOverrideOfflineAssumptions() throws {
        let data = Data(#"{"models":[{"slug":"gpt-6-sol","supported_reasoning_levels":[{"effort":"medium"},{"effort":"high"}]},{"slug":"future-model","supported_reasoning_levels":["none","low","high"]}]}"#.utf8)
        let models = OpenAIModelsAPI.parseCodexModels(data)
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(ThinkingLevelCatalog.minimumLevel(for: models[0], isCodexOAuth: true), .medium)
        XCTAssertEqual(ThinkingLevelCatalog.codexOffEffort(for: models[1]), "none")
        XCTAssertEqual(models[0].selectableThinkingLevels, [.medium, .high])
        XCTAssertEqual(models[0].catalogMaxThinkingLevel, .high)
        XCTAssertEqual(ModelEntry(providerInstanceId: "test", model: models[0], overrides: .init(maxThinkingLevel: .max)).selectableThinkingLevels, [.medium, .high])
        XCTAssertEqual(ThinkingLevelCatalog.effectiveLevel(.max, for: models[0], isCodexOAuth: true), .high)
        XCTAssertEqual(OpenAIAgentProvider.responsesReasoningConfiguration(
            for: models[0], level: .off, isCodexOAuth: true, offEffort: nil),
            ["effort": "medium", "summary": "auto"])
    }

    func testUnknownCodexRetainsConservativeMinimumButAPIIsUnaffected() {
        let model = LLMModel(id: "unknown", displayName: "Unknown", provider: "OpenAI", supportsReasoning: true)
        XCTAssertEqual(ThinkingLevelCatalog.minimumLevel(for: model, isCodexOAuth: true), .low)
        XCTAssertEqual(ThinkingLevelCatalog.minimumLevel(for: model, isCodexOAuth: false), .off)
        XCTAssertEqual(OpenAIAgentProvider.responsesReasoningConfiguration(
            for: model, level: .off, isCodexOAuth: false, offEffort: "none"), ["effort": "none"])
        XCTAssertNil(OpenAIAgentProvider.responsesReasoningConfiguration(
            for: model, level: .off, isCodexOAuth: false, offEffort: nil))
    }

    func testCodexRequestedLevelIsNotLostWhenCapabilityMetadataIsMissing() {
        let model = LLMModel(id: "unknown", displayName: "Unknown", provider: "OpenAI")
        XCTAssertEqual(OpenAIAgentProvider.responsesReasoningConfiguration(
            for: model, level: .high, isCodexOAuth: true, offEffort: nil),
            ["effort": "high", "summary": "auto"])
    }

    func testMetadataSurvivesOverridesEnrichmentAndSerialization() throws {
        var model = LLMModel.gpt6Sol
        model.codexReasoningEffortValues = ["none", "low", "high"]
        model.reasoningEffortValues = model.codexReasoningEffortValues
        model.effortDeclarationIsAuthoritative = true
        let entry = ModelEntry(providerInstanceId: "test", model: model, overrides: .init(displayName: "Renamed"))
        let restored = try JSONDecoder().decode(ModelEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(restored.model.codexReasoningEffortValues, model.codexReasoningEffortValues)
        XCTAssertEqual(restored.model.reasoningEffortValues, model.reasoningEffortValues)
        XCTAssertEqual(restored.model.effortDeclarationIsAuthoritative, true)
        let enriched = try XCTUnwrap(ModelsDevAPI.enrichModels([restored.model]).first)
        XCTAssertEqual(enriched.codexReasoningEffortValues, model.codexReasoningEffortValues)
        XCTAssertEqual(enriched.selectableThinkingLevels, [.low, .high])
    }

    func testOldModelsDecodeAndMalformedCatalogDoesNotInventOffSupport() throws {
        let old = Data(#"{"id":"old-model","displayName":"Old","provider":"OpenAI"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(LLMModel.self, from: old).codexReasoningEffortValues)
        let data = Data(#"{"models":[{"slug":"unknown","supported_reasoning_levels":[{"effort":"future-tier"}]}]}"#.utf8)
        let model = try XCTUnwrap(OpenAIModelsAPI.parseCodexModels(data).first)
        XCTAssertNil(model.codexReasoningEffortValues)
        XCTAssertEqual(ThinkingLevelCatalog.minimumLevel(for: model, isCodexOAuth: true), .low)
    }

    @MainActor
    func testExplicitDraftOffSurvivesFirstPersistence() {
        let vm = AIChatViewModel()
        vm.setThinkingLevel(.off)
        let sessionID = "thinking-off-test-" + UUID().uuidString
        vm.sessionId = sessionID
        defer { ProviderConfigStore.shared.removeInferenceConfig(for: sessionID) }
        XCTAssertTrue(vm.flushPendingThinkingLevel(), "Explicit Off must suppress group-default seeding")
        XCTAssertEqual(ProviderConfigStore.shared.inferenceConfig(for: sessionID)?.thinkingLevel, .off)
        XCTAssertFalse(vm.flushPendingThinkingLevel(), "Pending override is consumed once")
    }

    @MainActor
    func testUntouchedDraftStillInheritsGroupDefault() {
        let vm = AIChatViewModel()
        vm.sessionId = "thinking-unset-test-" + UUID().uuidString
        XCTAssertFalse(vm.flushPendingThinkingLevel())
    }
}
