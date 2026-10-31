import Foundation

@main
struct XiaozhiReplyStreamTests {
    @MainActor
    static func main() async throws {
        let watchdog = Task.detached {
            try await Task.sleep(nanoseconds: 15_000_000_000)
            fatalError("Streaming test stalled")
        }
        defer { watchdog.cancel() }
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name); checks += 1
        }
        func collect(_ stream: XiaozhiReplyStream) async throws -> [String] {
            var values: [String] = []
            for try await value in stream.text { values.append(value) }
            return values
        }
        func flat(_ value: String) -> String { value.filter { !$0.isWhitespace } }

        // The tool/model completion is intentionally withheld. Awaiting this
        // first chunk would hang in the previous wait-for-the-whole-turn path.
        let stream = XiaozhiReplyStream(), firstID = UUID()
        var iterator = stream.text.makeAsyncIterator()
        stream.receive(.init(blockID: firstID, text: "我去看看美股现在的行情", complete: false))
        stream.receive(.init(blockID: firstID, text: "我去看看美股现在的行情。", complete: false))
        let first = try await iterator.next()
        check(first == "我去看看美股现在的行情。", "first sentence arrives before tool/model completion")
        stream.receive(.init(blockID: firstID, text: "我去看看美股现在的行情。", complete: true))
        stream.receive(.init(blockID: UUID(), text: "查询完成，这是本次查到的结果。", complete: true))
        stream.finish(fallback: "我去看看美股现在的行情。查询完成，这是本次查到的结果。")
        let second = try await iterator.next(), end = try await iterator.next()
        check(second == "查询完成，这是本次查到的结果。" && end == nil, "tool boundary and final snapshot never repeat spoken prefixes")

        let decimals = XiaozhiReplyStream(), decimalID = UUID()
        decimals.receive(.init(blockID: decimalID, text: "数值是 3.", complete: false))
        decimals.receive(.init(blockID: decimalID, text: "数值是 3.14，增长 28.98%。", complete: false))
        decimals.finish()
        check(try await collect(decimals) == ["数值是 3.14，增长 28.98%。"], "decimal remains in the same utterance")

        let markdown = XiaozhiReplyStream(), markdownID = UUID()
        markdown.receive(.init(blockID: markdownID, text: "```swift\nprivateToken()\n", complete: false))
        markdown.receive(.init(blockID: markdownID, text: "```swift\nprivateToken()\n```\n**可以直接回答了。**", complete: true))
        markdown.finish()
        check(flat(try await collect(markdown).joined()) == "可以直接回答了。", "fenced code is skipped across deltas")
        let unfinishedCode = XiaozhiReplyStream()
        unfinishedCode.receive(.init(blockID: UUID(), text: "```\nprivateToken()", complete: true))
        unfinishedCode.finish(fallback: "```\nprivateToken()")
        check(try await collect(unfinishedCode).isEmpty, "unclosed code is not spoken at a tool boundary")

        let quoted = XiaozhiReplyStream(), quotedID = UUID()
        quoted.receive(.init(blockID: quotedID, text: "地精笑着说：“时间就是金钱。", complete: false))
        quoted.receive(.init(blockID: quotedID, text: "地精笑着说：“时间就是金钱。”", complete: true))
        quoted.finish()
        check(try await collect(quoted).count == 1, "late closing quote does not trigger empty-audio synthesis")

        let story = XiaozhiReplyStream(), storyID = UUID()
        let original = String(repeating: "小地精带着朋友走进森林，找到了传说中的金币。", count: 13)
        var snapshot = ""
        for character in original {
            snapshot.append(character)
            story.receive(.init(blockID: storyID, text: snapshot, complete: false))
        }
        story.finish()
        let storyChunks = try await collect(story)
        check(flat(storyChunks.joined()) == original, "long story stays complete and ordered")
        check(storyChunks.count <= 6, "later sentences are batched rather than one paid request per sentence")

        let cap = XiaozhiReplyStream()
        cap.receive(.init(blockID: UUID(), text: String(repeating: "很长的故事还在继续。", count: 200), complete: true))
        cap.finish()
        check(try await collect(cap).joined().count == 500, "whole-turn character budget is bounded")

        let rewrite = XiaozhiReplyStream(), rewriteID = UUID()
        rewrite.receive(.init(blockID: rewriteID, text: "第一份回复已经开始。", complete: false))
        rewrite.receive(.init(blockID: rewriteID, text: "供应商改写了原有回复。", complete: false))
        do { _ = try await collect(rewrite); preconditionFailure("rewritten prefix replayed") }
        catch { checks += 1 }
        let cancelled = XiaozhiReplyStream()
        cancelled.finish(throwing: CancellationError())
        cancelled.receive(.init(blockID: UUID(), text: "取消后的内容不能朗读。", complete: true))
        do { _ = try await collect(cancelled); preconditionFailure("cancel ignored") }
        catch is CancellationError { checks += 1 }

        // Keep audio prefetch decoupled from BLE pacing for subsequent batches.
        var produced = 0, consumed = 0
        try await XiaozhiBufferedSpeech.play(produce: { emit in
            for index in 0..<1200 {
                produced += 1
                try await emit(Data([UInt8(index % 256)]))
            }
        }, consume: { packet in
            if consumed == 0 { try await Task.sleep(nanoseconds: 30_000_000) }
            check(packet == Data([UInt8(consumed % 256)]), "audio packet order")
            if consumed == 1 { check(produced == 1200, "audio prefetch continues during BLE playback") }
            consumed += 1
        })
        check(consumed == 1200, "long audio fully drains")
        print("Passed \(checks) streaming voice checks")
    }
}
