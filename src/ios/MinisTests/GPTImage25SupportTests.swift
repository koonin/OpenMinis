import XCTest
@testable import Minis

final class GPTImage25SupportTests: XCTestCase {
    func testOnlyPublishedIDsAndSnapshotsMatch() {
        for id in GPTImage25Support.modelIDs {
            XCTAssertTrue(GPTImage25Support.matches(id))
            XCTAssertTrue(GPTImage25Support.supportsCodexTool(id))
        }
        for id in ["gpt-image-2", "gpt-image-2.5", "gpt-image-2.5-sunburst-other",
                   "relay/gpt-image-2.5-flare", "gpt-6-astra"] {
            XCTAssertFalse(GPTImage25Support.matches(id))
        }
    }

    func testEveryVariantExplicitlySelectsItsExactModel() throws {
        for id in GPTImage25Support.modelIDs {
            let tool = try GPTImage25Support.codexTool(modelID: id, size: nil, quality: nil)
            XCTAssertEqual(tool as? [String: String], ["type": "image_generation", "model": id])
            XCTAssertTrue(JSONSerialization.isValidJSONObject(tool))
        }
    }

    func testQualityAndCustomSizeAreForwardedWithoutDowngrade() throws {
        for quality in ["auto", "low", "medium", "high", "xhigh", "max"] {
            let tool = try GPTImage25Support.codexTool(
                modelID: GPTImage25Support.sunburst, size: "1536x864", quality: quality)
            XCTAssertEqual(tool["quality"] as? String, quality)
            XCTAssertEqual(tool["size"] as? String, "1536x864")
            XCTAssertEqual(tool["model"] as? String, GPTImage25Support.sunburst)
        }
    }

    func testImage2PreservesLegacyBareTool() throws {
        let tool = try GPTImage25Support.codexTool(modelID: "gpt-image-2", size: "1024x1024", quality: "high")
        XCTAssertEqual(tool as? [String: String], ["type": "image_generation"])
    }

    func testUnknownModelFailsRatherThanUsingLegacyDefault() {
        for id in ["gpt-image-2.5", "gpt-image-3", "dall-e-3", "gpt-6-astra"] {
            XCTAssertThrowsError(try GPTImage25Support.codexTool(modelID: id, size: nil, quality: nil))
        }
    }
}
