#!/usr/bin/env python3
"""Exercise the production recursive splitter with an offline summarizer.

The method is extracted at run time so the test cannot pass against a stale
copy. No model requests are made. Run from any directory with python3.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "src/ios/Agent/Chat/AIChatViewModel+Compaction.swift").read_text()
start = source.index("    private func generateCompactSummaryWithSplitting(")
end = source.index("    /// [T-compact-segment-retry-any-error] Should", start)
method = source[start:end].replace("private func", "func", 1)

harness = r'''
import Foundation
struct AgentMessage { let text: String }
final class ChatMessage { var content = "" }
struct Logger { func info(_ value: String) {} }
let logger = Logger()
enum SplitError: Error { case tooLarge }
@MainActor final class Harness {
    var calls: [(String, Bool)] = []
    func buildConversationTextForSummary(_ messages: [AgentMessage]) -> String {
        messages.map(\.text).joined(separator: "|")
    }
    static func isSegmentRetryableError(_ error: Error) -> Bool { error is SplitError }
    func generateCompactSummary(conversationText: String, statusMsg: ChatMessage?, continuingTask: Bool) async throws -> String {
        calls.append((conversationText, continuingTask))
        if conversationText.contains("|") { throw SplitError.tooLarge }
        return conversationText
    }
    // PRODUCTION_METHOD
}
@main struct Test {
    @MainActor static func main() async throws {
        for continuing in [false, true] {
            let vm = Harness()
            let messages = (0..<4).map { AgentMessage(text: "message-\($0)") }
            let summary = try await vm.generateCompactSummaryWithSplitting(
                messages: messages, statusMsg: ChatMessage(),
                previousSummary: "EARLIER-DECISION", continuingTask: continuing
            )
            precondition(vm.calls.count == 7, "Fixture must force recursive splitting")
            precondition(vm.calls.allSatisfy { $0.1 == continuing }, "Every retry must preserve compaction mode")
            precondition(summary.components(separatedBy: "EARLIER-DECISION").count == 2,
                         "Keep the old summary once, without dropping it or duplicating it across segments")
            let positions = (0..<4).map { summary.range(of: "message-\($0)")!.lowerBound }
            precondition(positions == positions.sorted(), "Keep chronological segment order")
        }
        print("PASS: recursive splitting retains prior decisions, order, and both handoff modes")
    }
}
'''.replace("    // PRODUCTION_METHOD", method)

with tempfile.TemporaryDirectory(prefix="minis-handoff-") as directory:
    directory = Path(directory)
    swift = directory / "HandoffTests.swift"
    binary = directory / "test"
    swift.write_text(harness)
    subprocess.run(["swiftc", "-parse-as-library", "-module-cache-path", str(directory / "cache"),
                    str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
