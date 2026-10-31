import Foundation

/// Only visible assistant text enters this stream, never reasoning or tool data.
struct XiaozhiReplyTextUpdate {
    let blockID: UUID
    let text: String
    let complete: Bool
}

/// Small first utterance, then larger batches that can be synthesized ahead of
/// playback. The entire spoken turn retains the existing 500-character limit.
@MainActor
final class XiaozhiReplyStream {
    let text: AsyncThrowingStream<String, Error>
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private var blockID: UUID?
    private var snapshot = ""
    private var offset = 0
    private var pending = ""
    private var remaining = 500
    private var emitted = false
    private var receivedText = false
    private var ended = false

    init() {
        (text, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(64))
    }

    func receive(_ update: XiaozhiReplyTextUpdate) {
        guard !ended, remaining > 0 else { return }
        receivedText = receivedText || !update.text.isEmpty
        if blockID != update.blockID {
            extract(complete: true)
            blockID = update.blockID; snapshot = ""; offset = 0
        }
        let next = String(update.text.prefix(16_384))
        // A provider retry/edit must not replay an already spoken prefix.
        guard next.hasPrefix(snapshot) else {
            finish(throwing: XiaozhiError.message("回复内容已更新，请在手机查看；本轮没有重复朗读"))
            return
        }
        snapshot = next
        extract(complete: update.complete)
    }

    private func extract(complete: Bool) {
        let chars = Array(snapshot)
        var start = offset, i = offset
        func fence(_ at: Int) -> Bool {
            at + 2 < chars.count && chars[at] == "`" && chars[at + 1] == "`" && chars[at + 2] == "`"
        }
        while i < chars.count {
            if fence(i) {
                append(String(chars[start..<i]))
                var end = i + 3
                while end < chars.count, !fence(end) { end += 1 }
                guard end < chars.count else {
                    offset = complete ? chars.count : i
                    if complete { flush(force: true) }
                    return
                }
                i = end + 3; start = i; offset = i
                continue
            }
            let c = chars[i]
            var boundary = "。！？!?；;\n".contains(c)
            if c == "." {
                // Wait for look-ahead: streamed decimals, domains and list
                // markers must not be voiced as separate sentences.
                if i + 1 < chars.count {
                    boundary = chars[i + 1].isWhitespace && !(i == start + 1 && chars[start].isNumber)
                } else { boundary = complete }
            }
            if boundary {
                append(String(chars[start...i]))
                start = i + 1; offset = start
                flush(force: false)
            }
            i += 1
        }
        if complete {
            if start < chars.count { append(String(chars[start...])) }
            offset = chars.count
            flush(force: true)
        }
    }

    private func append(_ raw: String) {
        let clean = VoiceTextSanitizer.sanitize(raw)
        // A closing quote can arrive after its sentence was already emitted.
        // Never make a paid synthesis request for punctuation alone.
        guard clean.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else { return }
        if !pending.isEmpty { pending += "\n" }
        pending += clean
    }

    private func flush(force: Bool) {
        guard !ended, remaining > 0, !pending.isEmpty else { return }
        guard force || pending.count >= (emitted ? 80 : 8) else { return }
        let chunk = String(pending.prefix(remaining))
        pending = ""; remaining -= chunk.count; emitted = true
        switch continuation.yield(chunk) {
        case .enqueued: break
        case .dropped: finish(throwing: XiaozhiError.message("语音文字缓冲已满，本轮已停止"))
        case .terminated: ended = true
        @unknown default: ended = true
        }
    }

    func finish(fallback: String? = nil, throwing error: Error? = nil) {
        guard !ended else { return }
        if error == nil {
            extract(complete: true)
            if !receivedText, let fallback {
                receive(.init(blockID: UUID(), text: fallback, complete: true))
            }
        }
        ended = true
        continuation.finish(throwing: error)
    }
}
