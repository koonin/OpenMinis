import Foundation

/// The cloud may narrate tool calls or rewrite answers. Accept audio only after
/// its caption matches the next part of the completed OpenMinis answer. A stream
/// can play that verified prefix; finish() still rejects an incomplete answer.
/// Zero-audio status captions (observed before MCP calls) are not speech.
struct XiaozhiConsoleReplyGate {
    static let toolName = "self.openminis.get_reply"
    private let expected: String
    private var caption: String?
    private var captionConsumed = false
    private var spoken = ""
    private(set) var served = false
    private(set) var packets: [Data] = []

    init(text: String) throws {
        expected = Self.normalized(text)
        guard !expected.isEmpty, text.count <= 500 else {
            throw XiaozhiError.message("控制台播报内容为空或过长")
        }
    }

    static func normalized(_ text: String) -> String {
        // Ignore spacing only. Minus signs, decimals and punctuation can change
        // meaning, so an uncertain rewrite fails closed rather than being read.
        String(text.precomposedStringWithCanonicalMapping.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        })
    }

    mutating func serveTool(name: String, arguments: [String: Any]) throws {
        guard name == Self.toolName, arguments.isEmpty else {
            throw XiaozhiError.message("后台请求了本轮以外的工具，已停止播报")
        }
        // Repeated calls only return the same cached answer; never run an agent.
        served = true
    }

    mutating func startSentence(_ text: String) throws {
        guard text.count <= 2_000 else { throw XiaozhiError.message("后台字幕过长") }
        caption = text; captionConsumed = false
    }

    @discardableResult
    mutating func append(_ packet: Data) throws -> Data {
        guard served, let caption, !Self.normalized(caption).isEmpty,
              packets.count < 1_500, packet.count <= 1_275,
              XiaozhiProtocol.is60msMonoOpus(packet) else {
            throw XiaozhiError.message("后台音频未对应本轮小冠答复，已停止播报")
        }
        if !captionConsumed {
            spoken += Self.normalized(caption)
            guard expected.hasPrefix(spoken) else {
                throw XiaozhiError.message("小智后台改写了答复，已停止播报；原回复可在小冠查看")
            }
            captionConsumed = true
        }
        packets.append(packet)
        return packet
    }

    func finish() throws -> [Data] {
        guard served, !packets.isEmpty, spoken == expected else {
            throw XiaozhiError.message("小智后台未完整朗读小冠答复，已停止播报")
        }
        return packets
    }
}
