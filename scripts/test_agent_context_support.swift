// Compile with the production implementation (no copied policies):
// swiftc src/ios/Agent/Chat/AgentContextSupport.swift scripts/test_agent_context_support.swift -o /tmp/test-agent-context
// /tmp/test-agent-context
import Foundation
import SQLite3

@main
struct AgentContextSupportTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("full-output.txt")
        let original = "START\n" + String(repeating: "中🙂", count: 10_000)
            + "\nCRITICAL MIDDLE EVIDENCE\n" + String(repeating: "a", count: 20_000) + "\nEND"
        for tool in ["shell_execute", "browser_use", "file_read"] {
            let preview = AgentContextSupport.toolOutput(original, toolName: tool, inlineLimit: 15_000) {
                try $0.write(to: file, atomically: true, encoding: .utf8)
                return file.path
            }
            let persisted = try String(contentsOf: file, encoding: .utf8)
            check(persisted == original, "Full Unicode output must survive, including middle evidence")
            check(preview.contains(file.path), "Preview must point to the persisted output")
            check(preview.hasPrefix("START"), "Preserve the beginning")
            if tool != "file_read" {
                check(preview.count < 6_500, "Large shell/browser results have a bounded 6K preview")
                check(preview.contains("END"), "Preserve the ending")
                check(!preview.contains("CRITICAL MIDDLE EVIDENCE"), "Fixture must exercise omitted middle content")
            } else {
                check(preview.count > 15_000, "Do not shrink an explicit file read to the log budget")
            }
        }
        for text in ["", "small output", String(repeating: "x", count: 15_000)] {
            let output = AgentContextSupport.toolOutput(text, toolName: "shell_execute", inlineLimit: 15_000) { _ in
                preconditionFailure("Small results must not write files")
            }
            check(output == (text.isEmpty ? "(no output)" : text), "Boundary results must stay intact")
        }
        let failed = AgentContextSupport.toolOutput(original, toolName: "shell_execute", inlineLimit: 15_000) { _ in
            throw CocoaError(.fileWriteOutOfSpace)
        }
        check(failed.contains("Could not save"), "Disk failure must be visible")
        check(!failed.contains("saved to:"), "Never advertise a nonexistent file")
        check(failed.count < 15_500 && failed.contains("END"), "Failure retains a bounded head/tail preview")

        // Real SQLite persistence, including reload, repeated stream snapshots,
        // partial final events, independent retries and model attribution.
        let dbFile = dir.appendingPathComponent("usage.sqlite").path
        var db: OpaquePointer?
        check(sqlite3_open(dbFile, &db) == SQLITE_OK, "Open ledger")
        defer { sqlite3_close(db) }
        check(sqlite3_exec(db, AuxiliaryUsageLedger.schema, nil, nil, nil) == SQLITE_OK, "Create schema")
        func row(_ id: String, input: Int, output: Int, read: Int = 0, model: String = "model-a") -> AuxiliaryUsageSnapshot {
            AuxiliaryUsageSnapshot(requestId: id, sessionId: "deleted-session", modelId: model,
                modelDisplayName: "模型 ' name", providerType: nil, kind: "compaction", createdAt: 100,
                input: input, output: output, cacheWrite: 0, cacheRead: read)
        }
        check(AuxiliaryUsageLedger.record(row("request-1", input: 100, output: 0, read: 900), db: db), "Initial usage")
        check(AuxiliaryUsageLedger.record(row("request-1", input: 0, output: 20), db: db), "Partial final usage")
        check(AuxiliaryUsageLedger.record(row("request-1", input: 100, output: 20, read: 900), db: db), "Repeated usage")
        check(AuxiliaryUsageLedger.record(row("retry-2", input: 100, output: 10, model: "model-b"), db: db), "Retry usage")
        let rows = AuxiliaryUsageLedger.fetch(db: db)
        check(rows.count == 2, "Count requests, not stream events")
        check(rows.reduce(0) { $0 + $1.input } == 200, "Retries count but repeated snapshots do not")
        check(rows.reduce(0) { $0 + $1.output } == 30, "Merge partial output")
        check(rows.reduce(0) { $0 + $1.cacheRead } == 900, "Partial updates retain cache accounting")
        check(rows.allSatisfy { $0.providerType == nil && $0.modelDisplayName == "模型 ' name" }, "Safe text binding and null handling")
        check(Set(rows.map(\.modelId)) == ["model-a", "model-b"], "Keep original model attribution")
        check(sqlite3_close(db) == SQLITE_OK, "Close ledger")
        db = nil
        check(sqlite3_open(dbFile, &db) == SQLITE_OK, "Reopen ledger")
        check(sqlite3_exec(db, AuxiliaryUsageLedger.schema, nil, nil, nil) == SQLITE_OK, "Schema is idempotent")
        check(AuxiliaryUsageLedger.fetch(db: db).count == 2, "Usage survives reopen and a missing session")

        let active = AgentContextSupport.compactionSystemPrompt(continuingTask: true)
        let historical = AgentContextSupport.compactionSystemPrompt(continuingTask: false)
        check(active.contains("without a new user message") && active.contains("remaining steps"), "Active compaction preserves continuation")
        check(active.contains("cancelled or superseded"), "Do not revive cancelled work")
        check(historical.contains("not new authorization") && !historical.contains("Active task handoff"), "Manual compaction does not create new work")
        print("PASS: \(checks) checks — output preservation, budgets, accounting and compaction modes")
    }
}
