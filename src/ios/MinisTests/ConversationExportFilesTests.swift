import XCTest
@testable import Minis

final class ConversationExportFilesTests: XCTestCase {
    private var root: URL!
    private var session: URL!
    private var shared: URL!
    private var payload: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        session = root.appendingPathComponent("session-a")
        shared = root.appendingPathComponent("shared")
        payload = root.appendingPathComponent("payload")
        for dir in [session!, shared!, payload!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String, under directory: URL, bytes: Data = Data([1, 2, 3])) throws -> URL {
        let url = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }

    func testMediaCopyPreservesBytesAndDeduplicatesWithoutMovingSource() throws {
        let source = try write("attachments/照片.png", under: session)
        let files = ConversationExportFiles(directory: payload)
        let first = files.copy(source, allowedRoots: [session], label: "照片.png")
        let second = files.copy(source, allowedRoots: [session], label: "照片.png")
        XCTAssertEqual(first.path, second.path)
        XCTAssertEqual(files.fileCount, 1)
        XCTAssertTrue(ConversationExportFiles.isReadableFile(source))
        let copied = payload.appendingPathComponent(try XCTUnwrap(first.path))
        XCTAssertEqual(try Data(contentsOf: copied), try Data(contentsOf: source))
        try files.finish()
        let manifest = try JSONDecoder().decode([ConversationExportFiles.Attachment].self,
                                               from: Data(contentsOf: payload.appendingPathComponent("attachments.json")))
        XCTAssertEqual(manifest.first?.path, first.path)
    }

    func testRewritesGeneratedImagesAndUserAttachmentXML() throws {
        _ = try write("workspace/卡通.png", under: session)
        _ = try write("attachments/photo.jpg", under: session)
        let files = ConversationExportFiles(directory: payload)
        let text = "![卡通](minis://workspace/%E5%8D%A1%E9%80%9A.png)\n<user-attached-files><file path=\"/var/minis/attachments/photo.jpg\" /></user-attached-files>"
        let result = files.rewriteReferences(in: text, sessionRoot: session, sharedRoot: shared)
        XCTAssertFalse(result.contains("minis://"))
        XCTAssertFalse(result.contains("/var/minis/"))
        XCTAssertTrue(result.contains("![卡通](attachments/"))
        XCTAssertTrue(result.contains("path=\"attachments/"))
        XCTAssertEqual(files.fileCount, 2)
        XCTAssertEqual(files.warningCount, 0)
    }

    func testCanonicalMinisURLAngleSpaceAndRelativePaths() throws {
        _ = try write("workspace/my image.png", under: session)
        _ = try write("workspace/plot.png", under: session)
        let files = ConversationExportFiles(directory: payload)
        let result = files.rewriteReferences(in: "![a](<minis://var/minis/workspace/my image.png>)\n![b](plot.png)", sessionRoot: session, sharedRoot: shared)
        XCTAssertTrue(result.contains("<attachments/"))
        XCTAssertFalse(result.contains("plot.png"))
        XCTAssertEqual(files.fileCount, 2)
    }

    func testDifferentSessionsNeverReuseSameNamedImage() throws {
        let other = root.appendingPathComponent("session-b")
        _ = try write("workspace/output.png", under: session, bytes: Data([1]))
        _ = try write("workspace/output.png", under: other, bytes: Data([2]))
        let files = ConversationExportFiles(directory: payload)
        let a = files.rewriteReferences(in: "![a](minis://workspace/output.png)", sessionRoot: session, sharedRoot: shared)
        let b = files.rewriteReferences(in: "![b](minis://workspace/output.png)", sessionRoot: other, sharedRoot: shared)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(files.fileCount, 2)
        let contents = try files.attachments.compactMap(\.path).map { try Data(contentsOf: payload.appendingPathComponent($0)) }
        XCTAssertEqual(contents, [Data([1]), Data([2])])
    }

    func testRejectsTraversalSymlinksAndDirectories() throws {
        let outside = try write("private.png", under: root)
        let link = session.appendingPathComponent("leak.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let files = ConversationExportFiles(directory: payload)
        XCTAssertNil(files.copy(link, allowedRoots: [session], label: "link").path)
        XCTAssertNil(files.copy(session.appendingPathComponent("../private.png"), allowedRoots: [session], label: "traversal").path)
        XCTAssertNil(files.copy(session, allowedRoots: [session], label: "directory").path)
        XCTAssertEqual(files.fileCount, 0)
        XCTAssertEqual(files.warningCount, 3)
    }

    func testMissingAndRemoteImagesAreReportedNotSilentlyDropped() throws {
        let files = ConversationExportFiles(directory: payload)
        let original = "![gone](minis://workspace/gone.png)\n![remote](https://example.com/image.png)"
        XCTAssertEqual(files.rewriteReferences(in: original, sessionRoot: session, sharedRoot: shared), original)
        XCTAssertEqual(files.warningCount, 2)
        XCTAssertEqual(files.fileCount, 0)
        try files.finish()
        let readme = try String(contentsOf: payload.appendingPathComponent("README.txt"), encoding: .utf8)
        XCTAssertTrue(readme.contains("gone.png"))
        XCTAssertTrue(readme.contains("https://example.com/image.png"))
    }

    func testPresentationGuardRejectsMissingOrMovedSource() throws {
        let file = try write("export.zip", under: root)
        XCTAssertTrue(ConversationExportFiles.isReadableFile(file))
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("moved.zip"))
        XCTAssertFalse(ConversationExportFiles.isReadableFile(file))
        XCTAssertFalse(ConversationExportFiles.isReadableFile(root))
    }

    #if os(macOS)
    func testRealZIPContainsTranscriptAndExactImageBytes() throws {
        let source = try write("attachments/photo.png", under: session, bytes: Data([137, 80, 78, 71]))
        let files = ConversationExportFiles(directory: payload)
        let image = files.copy(source, allowedRoots: [session], label: "photo.png")
        _ = try write("conversation.md", under: payload, bytes: Data("![Image](\(try XCTUnwrap(image.path)))".utf8))
        try files.finish()
        let archive = root.appendingPathComponent("export.zip")
        try ConversationExportFiles.createArchive(from: payload, to: archive)

        func unzip(_ arguments: [String]) throws -> Data {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return data
        }
        let listing = String(decoding: try unzip(["-Z1", archive.path]), as: UTF8.self).split(separator: "\n").map(String.init)
        XCTAssertTrue(listing.contains { $0.hasSuffix("conversation.md") })
        XCTAssertTrue(listing.contains { $0.hasSuffix("attachments.json") })
        let imagePath = try XCTUnwrap(listing.first { $0.hasSuffix(image.path!) })
        XCTAssertEqual(try unzip(["-p", archive.path, imagePath]), try Data(contentsOf: source))
        // Repeated export doesn't consume either the payload or the archive.
        try ConversationExportFiles.createArchive(from: payload, to: root.appendingPathComponent("export-again.zip"))
        XCTAssertTrue(ConversationExportFiles.isReadableFile(archive))
    }
    #endif
}
