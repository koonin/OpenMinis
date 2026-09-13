import Foundation
import XCTest
@testable import Minis

final class SharedStorageMigrationTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }
    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    private func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
    private func migrate() throws {
        try SharedStorageMigration.migrateOnce(from: root.appendingPathComponent("fallback"),
                                              to: root.appendingPathComponent("group"))
    }
    func testMergePreservesOldAndNewSkillsAndBackup() throws {
        try write("group/MinisFileProvider/skills/twitter-cli/SKILL.md", "old skill")
        try write("fallback/MinisFileProvider/skills/youtube-transcript/SKILL.md", "new skill")
        try write("fallback/MinisFileProvider/skills/youtube-transcript/scripts/run.py", "script")
        try migrate()
        XCTAssertEqual(try read("group/MinisFileProvider/skills/twitter-cli/SKILL.md"), "old skill")
        XCTAssertEqual(try read("group/MinisFileProvider/skills/youtube-transcript/scripts/run.py"), "script")
        XCTAssertEqual(try read("fallback/MinisFileProvider/skills/youtube-transcript/SKILL.md"), "new skill")
    }
    func testConflictingFilesAreNeverOverwritten() throws {
        try write("group/MinisFileProvider/memory/GLOBAL.md", "group version")
        try write("fallback/MinisFileProvider/memory/GLOBAL.md", "fallback version")
        try migrate()
        XCTAssertEqual(try read("group/MinisFileProvider/memory/GLOBAL.md"), "group version")
        XCTAssertEqual(try read("fallback/MinisFileProvider/memory/GLOBAL.md"), "fallback version")
    }
    func testCompletedMigrationDoesNotResurrectDeletedFiles() throws {
        try write("fallback/MinisFileProvider/skills/test/SKILL.md", "test")
        try migrate()
        try FileManager.default.removeItem(at: root.appendingPathComponent("group/MinisFileProvider/skills/test"))
        try migrate()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("group/MinisFileProvider/skills/test").path))
    }
    func testFailedMigrationRetainsSourceAndCanRetry() throws {
        try write("fallback/MinisFileProvider/skills/test/SKILL.md", "test")
        try write("group/MinisFileProvider", "blocking file")
        XCTAssertThrowsError(try migrate())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("fallback/" + SharedStorageMigration.markerName).path))
        XCTAssertEqual(try read("fallback/MinisFileProvider/skills/test/SKILL.md"), "test")
        try FileManager.default.removeItem(at: root.appendingPathComponent("group/MinisFileProvider"))
        try migrate()
        XCTAssertEqual(try read("group/MinisFileProvider/skills/test/SKILL.md"), "test")
    }
    func testDestinationSymlinkIsNotFollowed() throws {
        try write("fallback/MinisFileProvider/skills/test/SKILL.md", "test")
        try write("outside/sentinel", "untouched")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("group"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("group/MinisFileProvider"),
                                                  withDestinationURL: root.appendingPathComponent("outside"))
        XCTAssertThrowsError(try migrate())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside/skills").path))
    }
    func testMissingSourceDoesNotCreateMarker() throws {
        try migrate()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("fallback").path))
    }
    func testSymlinkLeavesSurviveRepeatedMergeWithoutTraversal() throws {
        try write("source/SKILL.md", "skill")
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("python").path,
                                                  withDestinationPath: "/nonexistent-guest-python")
        try SharedStorageMigration.mergeMissing(from: source, to: destination)
        try SharedStorageMigration.mergeMissing(from: source, to: destination)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("python").path),
                       "/nonexistent-guest-python")
    }
}
