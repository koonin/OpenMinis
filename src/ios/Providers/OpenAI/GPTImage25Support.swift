import Foundation

/// Explicit image model selection; never substitute the backend's default for 2.5.
enum GPTImage25Support {
    static let sunburst = "gpt-image-2.5-sunburst"
    static let flare = "gpt-image-2.5-flare"
    static let modelIDs = [sunburst, flare, sunburst + "-2026-09-08", flare + "-2026-09-08"]

    static func matches(_ id: String) -> Bool { modelIDs.contains(id) }

    static func supportsCodexTool(_ id: String) -> Bool {
        id == "gpt-image-2" || matches(id)
    }

    static func codexTool(modelID: String, size: String?, quality: String?) throws -> [String: Any] {
        guard supportsCodexTool(modelID) else {
            throw NSError(domain: "GPTImage25Support", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported Codex image model: \(modelID)"
            ])
        }
        var tool: [String: Any] = ["type": "image_generation"]
        // Keep the previously verified Image 2 wire shape. For 2.5, an explicit
        // selector is mandatory. Public Responses support does not guarantee
        // Codex account access: propagate server rejection, with no retry as 2.
        if matches(modelID) {
            tool["model"] = modelID
            if let size { tool["size"] = size }
            if let quality { tool["quality"] = quality }
        }
        return tool
    }
}
