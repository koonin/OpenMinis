import Foundation

enum XiaozhiError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

/// Monotonic durations only; never stores recordings or conversation text.
struct XiaozhiReplyTiming {
    var recognition: TimeInterval = 0
    var model: TimeInterval = 0
    var voice: TimeInterval = 0
    var preparation: TimeInterval = 0
    var answerReady: TimeInterval?
    var modelName = ""
    var total: TimeInterval { recognition + model + voice + preparation }
}

/// Fixed device clock with a small jitter buffer. Network send time must not
/// accumulate on top of every 60 ms frame. Rebase after a long stall so catch-up
/// never floods the device's bounded decode queue.
struct XiaozhiPlaybackClock {
    static let frame: TimeInterval = 0.060
    // 480 ms of encoded audio, below the device's 1200 ms decode queue.
    // The first packet still plays immediately; the following packets build
    // a reserve against BLE scheduling jitter without increasing first sound.
    static let prefill = 8
    private var anchor: TimeInterval

    init(now: TimeInterval) { anchor = now }

    mutating func deadline(for packet: Int, now: TimeInterval) -> TimeInterval {
        let offset = Double(max(0, packet - Self.prefill + 1)) * Self.frame
        let target = anchor + offset
        if now - target > Double(Self.prefill) * Self.frame {
            anchor = now - offset
            return now
        }
        return target
    }

    func drainDeadline(packetCount: Int) -> TimeInterval {
        anchor + Double(packetCount) * Self.frame
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
              value["transport"] as? String == "bluetooth",
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
