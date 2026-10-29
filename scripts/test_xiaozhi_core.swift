// Build with the platform-only Xiaozhi protocol/audio/pairing files.
// Uses synthetic pairing credentials and generated audio; never calls a model.
import Foundation

@main
struct XiaozhiCoreTests {
    static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label); checks += 1
        }
        let pairing = XiaozhiPairing(setupToken: String(repeating: "a", count: 48),
                                    deviceToken: String(repeating: "b", count: 48))
        check(pairing.discoveryName == "openminis-97daac0ee9998dfc", "stable migrated pairing identity")
        check(XiaozhiProtocol.deviceID("AA:BB:CC:00:01:02") == "aa:bb:cc:00:01:02", "normalize MAC")
        check(XiaozhiProtocol.deviceID("aa:bb:cc:00:01:02\n") == nil, "reject malformed MAC")
        check(!XiaozhiProtocol.equalSecret("中文", "secret"), "non-ASCII secret mismatch")
        check(XiaozhiProtocol.is60msMonoOpus(Data([0x18, 0])), "60 ms SILK mono")
        check(XiaozhiProtocol.is60msMonoOpus(Data([0xfb, 3, 0])), "three 20 ms CELT frames")
        check(!XiaozhiProtocol.is60msMonoOpus(Data([0x1c, 0])), "stereo refused")
        check(!XiaozhiProtocol.is60msMonoOpus(Data([0xf8, 0])), "20 ms refused")
        check(!XiaozhiProtocol.is60msMonoOpus(Data([0xfb])), "missing frame count refused")
        let hello: [String: Any] = ["type": "hello", "version": 1, "transport": "bluetooth", "audio_params": XiaozhiProtocol.audioParameters]
        check(XiaozhiProtocol.validHello(hello), "Bluetooth audio negotiation")
        var legacyHello = hello; legacyHello["transport"] = "websocket"
        check(!XiaozhiProtocol.validHello(legacyHello), "removed LAN transport refused")
        // Ten seconds of variable network overhead must not stretch device
        // playback. A pause must rebase without sending an unbounded backlog.
        var clock = XiaozhiPlaybackClock(now: 0)
        var now: TimeInterval = 0
        for index in 0..<167 {
            now = max(now, clock.deadline(for: index, now: now))
            now += [0.004, 0.012, 0.025][index % 3]
        }
        check(now < 10.02, "network overhead does not accumulate per frame")
        check(clock.drainDeadline(packetCount: 167) >= now, "buffer drains before stop")
        now += 2
        let resumed = clock.deadline(for: 167, now: now)
        check(abs(resumed - now) < 0.001, "long stall rebases device clock")
        check(clock.deadline(for: 168, now: now) >= now + 0.059, "no flood after stalled send")
        let codec = try XiaozhiAudioCodec()
        print("Protocol and pairing checks passed; checking audio"); fflush(stdout)
        var pcm = Data()
        for i in 0..<(16_000 * 3) {
            var sample = Int16(sin(Double(i) * 2 * .pi * 300 / 16_000) * 9000).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
        let packets = try codec.encode(pcm)
        check((50...52).contains(packets.count), "entire three-second recording encoded")
        var decoded = Data()
        for packet in packets { decoded.append(try codec.decode(packet)) }
        check(decoded.count == packets.count * 1920, "each packet is exactly 60 ms")
        check(decoded.contains(where: { $0 != 0 }), "decoded signal is audible")
        print("Opus round trip passed; checking WAV conversion"); fflush(stdout)
        let wav = XiaozhiProtocol.wav(pcm: pcm)
        check(try XiaozhiAudioCodec.pcmFromAudio(wav).count == pcm.count, "WAV resampling length")
        do { _ = try codec.decode(Data()); preconditionFailure("empty Opus accepted") }
        catch { checks += 1 }
        print("PASS \(checks) Xiaozhi core checks; \(packets.count) Opus packets")
    }
}
