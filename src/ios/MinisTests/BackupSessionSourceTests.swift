import XCTest
@testable import Minis

/// Backup restore must retain the source used to isolate delegated workers.
final class BackupSessionSourceTests: XCTestCase {
    private func withStore(_ body: (ChatStore) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-source-\(UUID().uuidString)")
        let store = ChatStore(baseURL: root)
        do {
            try await body(store)
        } catch {
            await store.closeDatabase()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        await store.closeDatabase()
        try FileManager.default.removeItem(at: root)
    }

    private func session(source: String?, updated: Double = 100) -> ChatSession {
        ChatSession(id: "restored-session", title: "Worker", category: nil,
                    modelId: "test-model", createdAt: Date(timeIntervalSince1970: 1),
                    updatedAt: Date(timeIntervalSince1970: updated), source: source)
    }

    func testNewWorkerRemainsHiddenAfterRestore() async throws {
        try await withStore { store in
            let incoming = session(source: ChatSession.delegatedWorkerSource)
            _ = await store.restoreSession(incoming, memoryEnabled: false, modelBinding: nil)
            let restored = await store.getSession(incoming.id)
            XCTAssertEqual(restored?.source, ChatSession.delegatedWorkerSource)
            XCTAssertEqual(restored?.isUserFacingConversation, false)
        }
    }

    func testNewerBackupRestoresWorkerSourceOnExistingSession() async throws {
        try await withStore { store in
            _ = await store.restoreSession(session(source: nil), memoryEnabled: false, modelBinding: nil)
            let incoming = session(source: ChatSession.delegatedWorkerSource, updated: 200)
            _ = await store.restoreSession(incoming, memoryEnabled: false, modelBinding: nil)
            let restored = await store.getSession(incoming.id)
            XCTAssertEqual(restored?.source, ChatSession.delegatedWorkerSource)
            XCTAssertEqual(restored?.isUserFacingConversation, false)
        }
    }

    func testLegacyBackupCannotClearExistingWorkerSource() async throws {
        try await withStore { store in
            _ = await store.restoreSession(session(source: ChatSession.delegatedWorkerSource),
                                           memoryEnabled: false, modelBinding: nil)
            _ = await store.restoreSession(session(source: nil, updated: 200),
                                           memoryEnabled: false, modelBinding: nil)
            let restored = await store.getSession("restored-session")
            XCTAssertEqual(restored?.source, ChatSession.delegatedWorkerSource)
            XCTAssertEqual(restored?.updatedAt, Date(timeIntervalSince1970: 200))
        }
    }

    func testOrdinaryRestoredSessionRemainsUserFacing() async throws {
        try await withStore { store in
            _ = await store.restoreSession(session(source: "shortcut"),
                                           memoryEnabled: true, modelBinding: nil)
            let restored = await store.getSession("restored-session")
            XCTAssertEqual(restored?.source, "shortcut")
            XCTAssertEqual(restored?.isUserFacingConversation, true)
        }
    }
}
