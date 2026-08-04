import XCTest

/// [T-preflight-empty-string-allowed] preflightValidateToolCall must
/// distinguish "field absent / JSON null" (block) from "field present with a
/// legitimately empty string" (allow, per-tool whitelist — file_edit's schema
/// documents `new_string: ""` as the delete-old_string form).
final class ToolPreflightTests: XCTestCase {

    private var tools: [AgentToolDefinition] {
        [
            AgentToolDefinition(
                name: "file_edit",
                description: "Edit a file",
                parameters: [
                    "path": AgentToolParam(type: .string, description: "File path"),
                    "old_string": AgentToolParam(type: .string, description: "Text to replace"),
                    "new_string": AgentToolParam(type: .string, description: "Replacement. Use empty string to delete old_string."),
                ],
                required: ["path", "old_string", "new_string"]
            ),
            AgentToolDefinition(
                name: "shell_execute",
                description: "Run a shell command",
                parameters: [
                    "command": AgentToolParam(type: .string, description: "Command"),
                ],
                required: ["command"]
            ),
        ]
    }

    private func validate(_ name: String, _ args: [String: Any]) -> String? {
        AIChatViewModel.preflightValidateToolCall(name: name, args: args, tools: tools)
    }

    // MARK: - file_edit.new_string empty-string whitelist

    func testFileEdit_emptyNewString_isAllowed() {
        let err = validate("file_edit", [
            "path": "/var/minis/workspace/a.txt",
            "old_string": "delete me",
            "new_string": "",
        ])
        XCTAssertNil(err, "empty new_string is the documented delete form and must pass preflight")
    }

    func testFileEdit_missingNewString_isBlocked() {
        let err = validate("file_edit", [
            "path": "/var/minis/workspace/a.txt",
            "old_string": "delete me",
        ])
        XCTAssertNotNil(err)
        XCTAssertTrue(err?.contains("new_string") == true)
    }

    func testFileEdit_nullNewString_isBlocked() {
        let err = validate("file_edit", [
            "path": "/var/minis/workspace/a.txt",
            "old_string": "delete me",
            "new_string": NSNull(),
        ])
        XCTAssertNotNil(err, "JSON null is a missing value, not an empty string")
        XCTAssertTrue(err?.contains("new_string") == true)
    }

    func testFileEdit_emptyOldString_isStillBlocked() {
        // The whitelist is per-field: only new_string may be empty.
        let err = validate("file_edit", [
            "path": "/var/minis/workspace/a.txt",
            "old_string": "",
            "new_string": "x",
        ])
        XCTAssertNotNil(err)
        XCTAssertTrue(err?.contains("old_string") == true)
    }

    // MARK: - Non-whitelisted tools keep the original behavior

    func testShellExecute_emptyCommand_isBlocked() {
        let err = validate("shell_execute", ["command": ""])
        XCTAssertNotNil(err)
        XCTAssertTrue(err?.contains("command") == true)
    }

    func testShellExecute_validCommand_passes() {
        XCTAssertNil(validate("shell_execute", ["command": "ls -l"]))
    }

    // MARK: - Pre-existing behaviors unchanged

    func testUnknownTool_staysSilent() {
        XCTAssertNil(validate("no_such_tool", [:]))
    }

    func testEmptyArgs_isBlocked() {
        let err = validate("file_edit", [:])
        XCTAssertNotNil(err)
        XCTAssertTrue(err?.contains("empty arguments") == true)
    }

    func testWhitespaceOnlyString_passes() {
        // "\n" / "  " are legitimate payloads (documented in the validator);
        // the trim-then-reject behavior must not come back.
        XCTAssertNil(validate("file_edit", [
            "path": "/var/minis/workspace/a.txt",
            "old_string": "  ",
            "new_string": "\n",
        ]))
    }
}

final class DelegatedWorkerPolicyTests: XCTestCase {
    func testWorkerReadPathAllowsOnlyArtifactNamespaces() {
        XCTAssertTrue(AIChatViewModel.delegatedWorkerMayRead(path: "/var/minis/workspace/report.txt"))
        XCTAssertTrue(AIChatViewModel.delegatedWorkerMayRead(path: "minis://attachments/photo.png"))
        XCTAssertTrue(AIChatViewModel.delegatedWorkerMayRead(path: "/var/minis/shared/data.csv"))

        XCTAssertFalse(AIChatViewModel.delegatedWorkerMayRead(path: "/var/minis/memory/GLOBAL.md"))
        XCTAssertFalse(AIChatViewModel.delegatedWorkerMayRead(path: "/var/minis/skills/example/SKILL.md"))
        XCTAssertFalse(AIChatViewModel.delegatedWorkerMayRead(path: "/root/.env"))
        XCTAssertFalse(AIChatViewModel.delegatedWorkerMayRead(path: "/var/minis/workspace/../../memory/GLOBAL.md"))
        XCTAssertFalse(AIChatViewModel.delegatedWorkerMayRead(path: "/var/minis/workspace/%252e%252e/memory/GLOBAL.md"))
    }

    func testCanonicalReadRootRejectsSiblingAndSymlinkEscape() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("worker-path-test-\(UUID().uuidString)", isDirectory: true)
        let allowed = base.appendingPathComponent("allowed", isDirectory: true)
        let sibling = base.appendingPathComponent("allowed-sibling", isDirectory: true)
        try fm.createDirectory(at: allowed, withIntermediateDirectories: true)
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let inside = allowed.appendingPathComponent("inside.txt")
        let outside = sibling.appendingPathComponent("outside.txt")
        try Data("inside".utf8).write(to: inside)
        try Data("outside".utf8).write(to: outside)

        XCTAssertTrue(AIChatViewModel.canonicalFileURL(inside, isContainedIn: allowed))
        XCTAssertFalse(AIChatViewModel.canonicalFileURL(outside, isContainedIn: allowed))

        let escape = allowed.appendingPathComponent("escape")
        try fm.createSymbolicLink(at: escape, withDestinationURL: sibling)
        let escapedFile = escape.appendingPathComponent("outside.txt")
        XCTAssertFalse(AIChatViewModel.canonicalFileURL(escapedFile, isContainedIn: allowed))

        let aliasedRoot = base.appendingPathComponent("aliased-root")
        try fm.createSymbolicLink(at: aliasedRoot, withDestinationURL: sibling)
        XCTAssertFalse(AIChatViewModel.canonicalFileURL(
            aliasedRoot.appendingPathComponent("outside.txt"),
            isContainedIn: aliasedRoot
        ))
    }

    func testWorkerBrowserNavigationAllowsOnlyHTTPNetworkURLs() {
        XCTAssertTrue(AIChatViewModel.delegatedWorkerMayNavigate(to: "https://example.com/path?q=1"))
        XCTAssertTrue(AIChatViewModel.delegatedWorkerMayNavigate(to: "HTTP://localhost:8080/"))

        XCTAssertFalse(AIChatViewModel.delegatedWorkerMayNavigate(to: nil))
        XCTAssertFalse(AIChatViewModel.delegatedWorkerMayNavigate(to: "minis://memory/GLOBAL.md"))
        XCTAssertFalse(AIChatViewModel.delegatedWorkerMayNavigate(to: "file:///private/tmp/secret"))
        XCTAssertFalse(AIChatViewModel.delegatedWorkerMayNavigate(to: "data:text/plain,secret"))
        XCTAssertFalse(AIChatViewModel.delegatedWorkerMayNavigate(to: "javascript:alert(1)"))
        XCTAssertFalse(AIChatViewModel.delegatedWorkerMayNavigate(to: "https:///missing-host"))
    }
}

@MainActor
final class SessionConcurrencyManagerTests: XCTestCase {
    private func fill(_ manager: SessionConcurrencyManager) async throws {
        for index in 0..<manager.maxConcurrent {
            try await manager.acquireSlot(sessionId: "running-\(index)")
        }
    }

    func testReleaseAtomicallyReservesSlotAndIgnoresDuplicateRelease() async throws {
        let manager = SessionConcurrencyManager()
        try await fill(manager)

        let first = Task { @MainActor in
            try await manager.acquireSlot(sessionId: "queued-1")
        }
        await Task.yield()
        XCTAssertTrue(manager.isSuspended("queued-1"))

        manager.releaseSlot(sessionId: "running-0")
        XCTAssertTrue(manager.runningSessions.contains("queued-1"))
        try await first.value

        let second = Task { @MainActor in
            try await manager.acquireSlot(sessionId: "queued-2")
        }
        await Task.yield()
        XCTAssertTrue(manager.isSuspended("queued-2"))

        manager.releaseSlot(sessionId: "running-0") // stale duplicate
        await Task.yield()
        XCTAssertTrue(manager.isSuspended("queued-2"))
        XCTAssertFalse(manager.runningSessions.contains("queued-2"))

        manager.releaseSlot(sessionId: "queued-1")
        try await second.value
        XCTAssertTrue(manager.runningSessions.contains("queued-2"))
    }

    func testCancelledWaiterDoesNotLeakCapacity() async throws {
        let manager = SessionConcurrencyManager()
        try await fill(manager)

        let queued = Task { @MainActor in
            try await manager.acquireSlot(sessionId: "cancelled")
        }
        await Task.yield()
        XCTAssertTrue(manager.isSuspended("cancelled"))

        queued.cancel()
        do {
            try await queued.value
            XCTFail("Cancelled waiter unexpectedly acquired a slot")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertFalse(manager.isSuspended("cancelled"))
        XCTAssertFalse(manager.runningSessions.contains("cancelled"))
        manager.releaseSlot(sessionId: "running-0")
        XCTAssertEqual(manager.runningSessions.count, manager.maxConcurrent - 1)
        XCTAssertEqual(manager.activeLeaseCount, manager.maxConcurrent - 1)
    }

    func testSameSessionOverlapKeepsNewLeaseAfterOldReleases() async throws {
        let manager = SessionConcurrencyManager()
        for _ in 0..<manager.maxConcurrent {
            try await manager.acquireSlot(sessionId: "same-session")
        }
        XCTAssertEqual(manager.activeLeaseCount, manager.maxConcurrent)
        XCTAssertEqual(manager.runningSessions, Set(["same-session"]))

        // Model an immediate resend queued while several older acquisitions
        // for the same session are still unwinding after cancellation.
        let replacement = Task { @MainActor in
            try await manager.acquireSlot(sessionId: "same-session")
        }
        await Task.yield()
        XCTAssertTrue(manager.isSuspended("same-session"))

        // A legacy ID-only cancellation from an older active run must not
        // cancel the replacement waiter.
        manager.cancelWait(sessionId: "same-session")
        XCTAssertTrue(manager.isSuspended("same-session"))

        // One old run releases; its exact slot is handed to the replacement.
        manager.releaseSlot(sessionId: "same-session")
        try await replacement.value
        XCTAssertEqual(manager.activeLeaseCount, manager.maxConcurrent)

        // The remaining old runs release. The replacement lease must survive.
        for _ in 0..<(manager.maxConcurrent - 1) {
            manager.releaseSlot(sessionId: "same-session")
        }
        XCTAssertEqual(manager.activeLeaseCount, 1)
        XCTAssertTrue(manager.runningSessions.contains("same-session"))

        manager.releaseSlot(sessionId: "same-session")
        XCTAssertEqual(manager.activeLeaseCount, 0)
        XCTAssertFalse(manager.runningSessions.contains("same-session"))
    }
}
