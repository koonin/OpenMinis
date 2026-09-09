import XCTest
@testable import Minis

final class GPTImage25IntegrationTests: XCTestCase {
    func testCatalogAndManualEntriesArePureImageGenerators() {
        for id in GPTImage25Support.modelIDs {
            let model = LLMModel(id: id, displayName: "Manual", provider: "OpenAI")
            XCTAssertEqual(model.capabilities.supportedModalities, [.textInput, .imageInput, .imageOutput])
        }
        for id in [GPTImage25Support.sunburst, GPTImage25Support.flare] {
            XCTAssertEqual(LLMModel.allOpenAI.filter { $0.id == id }.count, 1)
            XCTAssertEqual(OpenAIModelsAPI.fetchModelsOAuth().filter { $0.id == id }.count, 1)
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
            store.replaceEntries(for: instanceID, models: OpenAIModelsAPI.fetchModelsOAuth())
            for id in [GPTImage25Support.sunburst, GPTImage25Support.flare] {
                XCTAssertEqual(store.entries(for: instanceID).filter { $0.baseModel.id == id }.count, 1)
            }
        }
        XCTAssertEqual(store.entry(for: prior.id)?.overrides.displayName, "My Image 2")
        XCTAssertEqual(store.entry(for: prior.id)?.isHidden, true)
    }
}
