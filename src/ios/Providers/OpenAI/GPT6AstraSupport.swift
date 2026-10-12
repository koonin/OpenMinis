import Foundation

/// Official contract, checked 2026-09-07:
/// https://developers.openai.com/api/docs/guides/latest-model
/// https://developers.openai.com/api/docs/models/gpt-6-astra
/// A catalog entry is not proof that a particular ChatGPT account has access.
enum GPT6AstraSupport {
    static let modelID = "gpt-6-astra"
    static let contextWindow = 1_050_000
    static let maxOutputTokens = 128_000
    static let effortValues = ["low", "medium", "high", "xhigh", "max"]

    static func matches(_ modelID: String) -> Bool {
        modelID.lowercased() == Self.modelID
    }

    /// GPT-6.1 Sol shares Astra's always-reasoning Responses contract and
    /// context/output limits. Keep exact matching; GPT-6 Sol/Luna allow none.
    /// https://developers.openai.com/api/docs/models/gpt-6.1-sol
    static func matchesAlwaysReasoningModel(_ modelID: String) -> Bool {
        matches(modelID) || modelID.lowercased() == "gpt-6.1-sol"
    }

    /// Do not silently switch third-party endpoints to an API they may not serve.
    static func requiresOfficialResponses(modelID: String, baseURL: String?, isAzure: Bool) -> Bool {
        guard matchesAlwaysReasoningModel(modelID), !isAzure else { return false }
        guard let baseURL else { return true }
        guard let url = URL(string: baseURL), url.scheme == "https",
              url.host?.lowercased() == "api.openai.com" else { return false }
        return ["", "/", "/v1", "/v1/"].contains(url.path)
    }

    /// Apply after extra-body merging, at every request serialization boundary.
    /// OFF means the lowest supported effort for this always-reasoning model.
    /// Leave all other models and unrelated request fields untouched.
    static func prepare(_ body: inout [String: Any], modelID: String, responses: Bool) {
        guard matchesAlwaysReasoningModel(modelID) else { return }
        for key in ["temperature", "top_p", "top_logprobs"] { body.removeValue(forKey: key) }
        if responses {
            if let include = body["include"] as? [String] {
                body["include"] = include.filter { $0 != "message.output_text.logprobs" }
            }
            var reasoning = body["reasoning"] as? [String: Any] ?? [:]
            reasoning["effort"] = supportedEffort(reasoning["effort"] as? String)
            body["reasoning"] = reasoning
        } else {
            body.removeValue(forKey: "logprobs")
            body["reasoning_effort"] = supportedEffort(body["reasoning_effort"] as? String)
        }
    }

    private static func supportedEffort(_ value: String?) -> String {
        guard let value else { return "low" }
        switch value.lowercased() {
        case "none", "minimal": return "low"
        case "ultra": return "max"
        default: return value // Unknown explicit values remain server-validated.
        }
    }
}
