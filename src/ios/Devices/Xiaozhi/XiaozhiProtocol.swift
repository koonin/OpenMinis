import Foundation

enum XiaozhiError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

enum XiaozhiProtocol {
    static let sampleRate = 16_000
    static let frameSamples = 960
    static let frameBytes = frameSamples * 2
    static let maxRecordingBytes = sampleRate * 2 * 20
    static let audioParameters: [String: Any] = [
        "format": "opus", "sample_rate": sampleRate, "channels": 1, "frame_duration": 60
    ]

    static func validHello(_ value: [String: Any]) -> Bool {
        guard value["type"] as? String == "hello", value["version"] as? Int == 1,
              value["transport"] as? String == "websocket",
              let audio = value["audio_params"] as? [String: Any] else { return false }
        return audio["format"] as? String == "opus" && audio["sample_rate"] as? Int == sampleRate
            && audio["channels"] as? Int == 1 && audio["frame_duration"] as? Int == 60
    }

    static func deviceID(_ value: String?) -> String? {
        guard let value = value?.lowercased(), value.utf8.count == 17,
              value.range(of: "^(?:[0-9a-f]{2}:){5}[0-9a-f]{2}$", options: .regularExpression) != nil
        else { return nil }
        return value
    }

    static func equalSecret(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// RFC 6716 sections 3.1/3.2: configuration and frame count in the TOC.
    /// Validate duration independently of Core Audio's decoder priming.
    static func is60msMonoOpus(_ packet: Data) -> Bool {
        guard let toc = packet.first, toc & 4 == 0 else { return false }
        let config = Int(toc >> 3)
        let samples: Int
        if config < 12 { samples = [160, 320, 640, 960][config % 4] }
        else if config < 16 { samples = [160, 320][config % 2] }
        else { samples = [40, 80, 160, 320][config % 4] }
        let count: Int
        switch toc & 3 {
        case 0: count = 1
        case 1, 2: count = 2
        default:
            guard packet.count >= 2 else { return false }
            count = Int(packet[packet.startIndex + 1] & 63)
        }
        return samples * count == frameSamples
    }

    static func wav(pcm: Data) -> Data {
        var output = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { output.append(contentsOf: $0) }
        }
        append(UInt32(pcm.count + 36)); output.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2))
        append(UInt16(2)); append(UInt16(16)); output.append(Data("data".utf8))
        append(UInt32(pcm.count)); output.append(pcm)
        return output
    }
}

/// Only the small, bounded provisioning HTTP request is parsed here. WebSocket
/// framing/upgrade/ping/fragmentation are handled by Network.framework.
struct XiaozhiHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]

    static func parse(_ bytes: Data) throws -> XiaozhiHTTPRequest? {
        guard bytes.count <= 73_728 else { throw XiaozhiError.message("配置请求过大") }
        guard let end = bytes.range(of: Data("\r\n\r\n".utf8)) else {
            if bytes.count > 8192 { throw XiaozhiError.message("配置请求头过大") }
            return nil
        }
        guard end.upperBound <= 8192,
              let header = String(data: bytes[..<end.lowerBound], encoding: .utf8) else {
            throw XiaozhiError.message("配置请求格式错误")
        }
        let lines = header.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0" else {
            throw XiaozhiError.message("配置请求格式错误")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw XiaozhiError.message("请求头格式错误") }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, !name.contains(where: { $0.isWhitespace }), headers[name] == nil else {
                throw XiaozhiError.message("重复或无效的请求头")
            }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil,
              let length = Int(headers["content-length"] ?? "0"), (0...65_536).contains(length) else {
            throw XiaozhiError.message("不支持该配置请求编码")
        }
        guard bytes.count >= end.upperBound + length else { return nil }
        return Self(method: String(first[0]), path: String(first[1]), headers: headers)
    }
}
