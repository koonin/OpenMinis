import Foundation
import SQLite3
import XCTest
@testable import Minis

@MainActor
final class SkillStorageRecoveryTests: XCTestCase {
    func testUnreadableSkillRetainsRecordAndSettingsThenRecovers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("skills.db").path
        let skills = root.appendingPathComponent("skills")
        let rootfs = root.appendingPathComponent("rootfs")
        let store = SkillStore(databasePath: database, skillsDirectory: skills, rootfsDirectory: rootfs)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO skills (id,name,description,version,import_source,is_enabled,installed_at,updated_at,use_count) VALUES ('twitter-cli','Twitter','saved description','1','file',1,100,100,7); INSERT INTO session_skill_overrides VALUES ('session','twitter-cli',1);", nil, nil, nil), SQLITE_OK)
        store.reload()
        XCTAssertEqual(store.skills.count, 1)
        XCTAssertEqual(store.skills.first?.description, "saved description")
        XCTAssertEqual(store.skills.first?.useCount, 7)
        XCTAssertEqual(store.skills.first?.isEnabled, true)
        XCTAssertFalse(store.isEnabledForSession("twitter-cli", sessionId: "session"))
        store.rescanAndMarkChangedSkillsDirty()
        XCTAssertEqual(store.skills.count, 1)

        let dir = skills.appendingPathComponent("twitter-cli")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("SKILL.md")
        try "---\nname: Twitter\ndescription: saved description\n---\nRecovered instructions".write(to: file, atomically: true, encoding: .utf8)
        store.reload()
        XCTAssertTrue(store.isEnabledForSession("twitter-cli", sessionId: "session"))
        XCTAssertTrue(store.skills.first?.body.contains("Recovered instructions") == true)
        try FileManager.default.removeItem(at: file)
        store.reloadDatabase()
        XCTAssertEqual(store.skills.count, 1)
        XCTAssertFalse(store.isEnabledForSession("twitter-cli", sessionId: "session"))
        // Explicit deletion is still honored, unlike transient file-read failure.
        store.applyRemoteDeletion(id: "twitter-cli")
        store.reload()
        XCTAssertTrue(store.skills.isEmpty)
    }
}
