import XCTest
@testable import Minis

final class GPT6AstraSupportTests: XCTestCase {
    private let modelID = "gpt-6-astra"

    func testExactModelMatchDoesNotCaptureOtherModels() {
        XCTAssertTrue(GPT6AstraSupport.matches("GPT-6-ASTRA"))
        for id in ["gpt-6", "gpt-6-astra-other", "relay/gpt-6-astra", "gpt-5.6-sol"] {
            XCTAssertFalse(GPT6AstraSupport.matches(id))
        }
    }

    func testOfficialRoutingPreservesThirdPartyAndAzureEndpoints() {
        for base in [nil, "https://api.openai.com", "https://api.openai.com/v1/"] as [String?] {
            XCTAssertTrue(GPT6AstraSupport.requiresOfficialResponses(modelID: modelID, baseURL: base, isAzure: false))
        }
        for base in ["https://relay.example/v1", "https://api.openai.com.evil.example", "https://api.openai.com/custom"] {
            XCTAssertFalse(GPT6AstraSupport.requiresOfficialResponses(modelID: modelID, baseURL: base, isAzure: false))
        }
        XCTAssertFalse(GPT6AstraSupport.requiresOfficialResponses(modelID: modelID, baseURL: nil, isAzure: true))
        XCTAssertFalse(GPT6AstraSupport.requiresOfficialResponses(modelID: "gpt-5.5", baseURL: nil, isAzure: false))
    }

    func testResponsesPreservesToolsAndSummaryWhileRemovingUnsupportedParameters() {
        let input: [[String: Any]] = [["type": "function_call_output", "call_id": "call_1", "output": "ok"]]
        var body: [String: Any] = [
            "model": modelID, "input": input,
            "tools": [["type": "function", "name": "test"]],
            "reasoning": ["effort": "high", "summary": "auto"],
            "temperature": 0.2, "top_p": 0.9, "top_logprobs": 3,
            "include": ["reasoning.encrypted_content", "message.output_text.logprobs"],
            "prompt_cache_key": "unchanged"
        ]
        GPT6AstraSupport.prepare(&body, modelID: modelID, responses: true)
        for key in ["temperature", "top_p", "top_logprobs"] { XCTAssertNil(body[key]) }
        XCTAssertEqual(body["reasoning"] as? [String: String], ["effort": "high", "summary": "auto"])
        XCTAssertEqual(body["include"] as? [String], ["reasoning.encrypted_content"])
        XCTAssertEqual((body["tools"] as? [[String: String]])?.first?["name"], "test")
        XCTAssertEqual((body["input"] as? [[String: String]])?.first?["call_id"], "call_1")
        XCTAssertEqual(body["prompt_cache_key"] as? String, "unchanged")
    }

    func testEverySupportedEffortSurvivesBothWireFormats() {
        for effort in GPT6AstraSupport.effortValues {
            var responses: [String: Any] = ["reasoning": ["effort": effort]]
            GPT6AstraSupport.prepare(&responses, modelID: modelID, responses: true)
            XCTAssertEqual((responses["reasoning"] as? [String: String])?["effort"], effort)
            var chat: [String: Any] = ["reasoning_effort": effort]
            GPT6AstraSupport.prepare(&chat, modelID: modelID, responses: false)
            XCTAssertEqual(chat["reasoning_effort"] as? String, effort)
        }
    }

    func testOffAndUltraAreMappedToSupportedEfforts() {
        for (input, expected) in [("none", "low"), ("minimal", "low"), ("ultra", "max")] {
            var responses: [String: Any] = ["reasoning": ["effort": input]]
            GPT6AstraSupport.prepare(&responses, modelID: modelID, responses: true)
            XCTAssertEqual((responses["reasoning"] as? [String: String])?["effort"], expected)
            var chat: [String: Any] = ["reasoning_effort": input, "logprobs": true]
            GPT6AstraSupport.prepare(&chat, modelID: modelID, responses: false)
            XCTAssertEqual(chat["reasoning_effort"] as? String, expected)
            XCTAssertNil(chat["logprobs"])
        }
    }

    func testMissingEffortDefaultsToLow() {
        var body: [String: Any] = [:]
        GPT6AstraSupport.prepare(&body, modelID: modelID, responses: true)
        XCTAssertEqual(body["reasoning"] as? [String: String], ["effort": "low"])
    }

    func testOtherModelsAreByteForByteUnchanged() throws {
        let original: [String: Any] = ["temperature": 0.3, "reasoning": ["effort": "none"], "top_p": 0.9]
        for id in ["gpt-5.5", "gpt-5.6-sol", "deepseek-v4-pro", "custom-model"] {
            for responses in [false, true] {
                var body = original
                GPT6AstraSupport.prepare(&body, modelID: id, responses: responses)
                XCTAssertEqual(try JSONSerialization.data(withJSONObject: body, options: .sortedKeys),
                               try JSONSerialization.data(withJSONObject: original, options: .sortedKeys))
            }
        }
    }
}
