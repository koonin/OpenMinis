import XCTest
@testable import Minis

final class GPTImage25IntegrationTests: XCTestCase {
    func testPersistedOutputOnlyBaseIsRepairedBeforeImageEditPreflight() throws {
        for id in GPTImage25Support.modelIDs {
            let stale = LLMModel(id: id, displayName: "Saved model", provider: "OpenAI",
                                 modalityOverride: [.textInput, .imageOutput])
            let saved = ModelEntry(providerInstanceId: "test-provider", model: stale)
            let entry = try JSONDecoder().decode(ModelEntry.self, from: JSONEncoder().encode(saved))
            XCTAssertEqual(entry.baseModel.modalityOverride, [.textInput, .imageOutput])
            XCTAssertEqual(entry.model.capabilities.supportedModalities, [.textInput, .imageInput, .imageOutput])
            XCTAssertEqual(entry.id, saved.id)
            XCTAssertFalse(entry.model.canDescribeImages)

            let provider = OpenAIProvider(oauthTokenProvider: { "unused" }, model: entry.model)
            XCTAssertTrue(provider.usesCodexImageGeneration)
            let image = LLMMessage.ImageAttachment(mimeType: "image/jpeg", data: Data([1, 2, 3]))
            let request = try provider.codexImageRequestBody(prompt: "Restyle this photo as a cartoon",
                                                           inputImages: [image], topLevelModel: "gpt-6-astra")
            let tool = try XCTUnwrap((request["tools"] as? [[String: Any]])?.first)
            XCTAssertEqual(tool["model"] as? String, id)
            let input = try XCTUnwrap(request["input"] as? [[String: Any]])
            let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
            XCTAssertEqual(content.last?["image_url"] as? String, "data:image/jpeg;base64,AQID")
        }
    }

    func testRepairDoesNotOverrideUserIntentOrOtherModels() {
        let stale = LLMModel(id: GPTImage25Support.sunburst, displayName: "Saved model", provider: "OpenAI",
                             modalityOverride: [.textInput, .imageOutput])
        let entry = ModelEntry(providerInstanceId: "test", model: stale,
                               overrides: ModelOverrides(displayName: "My editor", modalityOverride: [.textInput, .imageOutput]),
                               isHidden: true)
        XCTAssertEqual(entry.model.displayName, "My editor")
        XCTAssertFalse(entry.model.capabilities.supportedModalities.contains(.imageInput))
        XCTAssertTrue(entry.isHidden)
        for model in [LLMModel.gpt55, .gptImage2,
                      LLMModel(id: "relay/gpt-image-2.5-sunburst", displayName: "Relay", provider: "OpenAI"),
                      LLMModel(id: GPTImage25Support.sunburst, displayName: "Custom", provider: "Custom")] {
            XCTAssertEqual(model.withVerifiedImageCapabilities(), model)
        }
    }

    func testEnrichmentAndInferencePreserveVerifiedImageInput() {
        let stale = LLMModel(id: GPTImage25Support.flare, displayName: "Saved", provider: "OpenAI",
                             modalityOverride: [.textInput, .imageOutput])
        for repaired in [ModelsDevAPI.enrichModel(stale), ModelsDevAPI.enrichModels([stale])[0], stale.withInferredModality()] {
            XCTAssertEqual(repaired.modalityOverride, [.textInput, .imageInput, .imageOutput])
        }
        XCTAssertTrue(LLMModel.gpt6Astra.canDescribeImages)
        XCTAssertFalse(LLMModel.gptImage25Sunburst.canDescribeImages)
        XCTAssertFalse(LLMModel(id: "text-only", displayName: "Text", provider: "OpenAI",
                                modalityOverride: [.textInput, .textOutput]).canDescribeImages)
    }

    func testCatalogAndManualEntriesArePureImageGenerators() {
        for id in GPTImage25Support.modelIDs {
            let model = LLMModel(id: id, displayName: "Manual", provider: "OpenAI")
            XCTAssertEqual(model.capabilities.supportedModalities, [.textInput, .imageInput, .imageOutput])
        }
        for id in [GPTImage25Support.sunburst, GPTImage25Support.flare] {
            XCTAssertEqual(LLMModel.allOpenAI.filter { $0.id == id }.count, 1)
            XCTAssertEqual(ModelsDevAPI.enrichModels(LLMModel.allOpenAICodexOAuth).filter { $0.id == id }.count, 1)
        }
        XCTAssertTrue(LLMModel.allOpenAICodexOAuth.contains { $0.id == "gpt-image-2" })
    }

    func testRouteIsSharedWithoutHijackingAPIKeysOrCustomEndpoints() {
        for model in [LLMModel.gptImage2, .gptImage25Sunburst, .gptImage25Flare] {
            let oauth = OpenAIProvider(oauthTokenProvider: { "unused" }, model: model)
            XCTAssertTrue(oauth.usesCodexImageGeneration)
            oauth.customBaseURL = "https://relay.example"
            XCTAssertFalse(oauth.usesCodexImageGeneration)
            XCTAssertFalse(OpenAIProvider(apiKey: "unused", model: model).usesCodexImageGeneration)
        }
        XCTAssertFalse(OpenAIProvider(oauthTokenProvider: { "unused" }, model: .gpt6Astra).usesCodexImageGeneration)
    }

    func testRequestSeparatesTextModelFromImageModel() throws {
        for model in [LLMModel.gptImage25Sunburst, .gptImage25Flare] {
            let provider = OpenAIProvider(oauthTokenProvider: { "unused" }, model: model)
            let body = try provider.codexImageRequestBody(prompt: "test", topLevelModel: "gpt-6-astra",
                                                         size: "1536x864", quality: "max")
            XCTAssertEqual(body["model"] as? String, "gpt-6-astra")
            let tool = try XCTUnwrap((body["tools"] as? [[String: Any]])?.first)
            XCTAssertEqual(tool["model"] as? String, model.id)
            XCTAssertEqual(tool["quality"] as? String, "max")
            XCTAssertEqual(tool["size"] as? String, "1536x864")
            XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
            XCTAssertThrowsError(try provider.codexImageRequestBody(prompt: "test", topLevelModel: model.id))
            let fallback = try provider.codexImageRequestBody(prompt: "test")
            XCTAssertEqual(fallback["model"] as? String, "gpt-5.5")
        }
    }

    func testReferenceImagesStayInResponsesInput() throws {
        let provider = OpenAIProvider(oauthTokenProvider: { "unused" }, model: .gptImage25Sunburst)
        let image = LLMMessage.ImageAttachment(mimeType: "image/png", data: Data([1, 2, 3]))
        let body = try provider.codexImageRequestBody(prompt: "edit", inputImages: [image])
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content.last?["type"] as? String, "input_image")
        XCTAssertEqual(content.last?["image_url"] as? String, "data:image/png;base64,AQID")
    }

    @MainActor
    func testRefreshAddsBothVariantsWithoutReplacingUserConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderConfigStore(fileURL: directory.appendingPathComponent("providers.json"))
        let instanceID = UUID().uuidString
        let prior = ModelEntry(providerInstanceId: instanceID, model: .gptImage2,
                               overrides: ModelOverrides(displayName: "My Image 2"), isHidden: true)
        XCTAssertTrue(store.addEntry(prior))
        for _ in 0..<2 {
            store.replaceEntries(for: instanceID, models: ModelsDevAPI.enrichModels(LLMModel.allOpenAICodexOAuth))
            for id in [GPTImage25Support.sunburst, GPTImage25Support.flare] {
                XCTAssertEqual(store.entries(for: instanceID).filter { $0.baseModel.id == id }.count, 1)
            }
        }
        XCTAssertEqual(store.entry(for: prior.id)?.overrides.displayName, "My Image 2")
        XCTAssertEqual(store.entry(for: prior.id)?.isHidden, true)
    }
}
