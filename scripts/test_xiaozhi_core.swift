// Build with the four platform-only Xiaozhi protocol/audio/pairing/LAN files.
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
        let store = XiaozhiPairingStore(pairing: pairing, save: { _ in })
        if CommandLine.arguments.contains("--serve") {
            var server: XiaozhiLANServer!
            server = XiaozhiLANServer(pairing: store, host: "127.0.0.1", httpPort: 18765, voicePort: 18766) { event in
                switch event {
                case .ready: print("READY"); fflush(stdout)
                case .failed(let error): print(error); fflush(stdout)
                case .message(let id, let data, let binary):
                    Task { try? await server.send(data, binary: binary, to: id) }
                default: break
                }
            }
            try server.start()
            try await Task.sleep(nanoseconds: 60_000_000_000)
            server.stop(); return
        }
        check(XiaozhiProtocol.deviceID("AA:BB:CC:00:01:02") == "aa:bb:cc:00:01:02", "normalize MAC")
        check(XiaozhiProtocol.deviceID("aa:bb:cc:00:01:02\n") == nil, "reject malformed MAC")
        check(!XiaozhiProtocol.equalSecret("中文", "secret"), "non-ASCII secret mismatch")
        check(XiaozhiProtocol.is60msMonoOpus(Data([0x18, 0])), "60 ms SILK mono")
        check(XiaozhiProtocol.is60msMonoOpus(Data([0xfb, 3, 0])), "three 20 ms CELT frames")
        check(!XiaozhiProtocol.is60msMonoOpus(Data([0x1c, 0])), "stereo refused")
        check(!XiaozhiProtocol.is60msMonoOpus(Data([0xf8, 0])), "20 ms refused")
        check(!XiaozhiProtocol.is60msMonoOpus(Data([0xfb])), "missing frame count refused")
        let request = Data("POST /ota/test HTTP/1.1\r\nContent-Length: 2\r\nDevice-Id: aa:bb:cc:00:01:02\r\n\r\n{}".utf8)
        check(try XiaozhiHTTPRequest.parse(request.dropLast()) == nil, "wait for body")
        check(try XiaozhiHTTPRequest.parse(request)?.headers["device-id"] == "aa:bb:cc:00:01:02", "parse request")
        for bad in ["GET / HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
                    "GET / HTTP/1.1\r\nContent-Length: 0\r\ncontent-length: 1\r\n\r\nx",
                    "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"] {
            do { _ = try XiaozhiHTTPRequest.parse(Data(bad.utf8)); preconditionFailure("bad HTTP accepted") }
            catch { checks += 1 }
        }
        check(try store.bind(deviceID: "aa:bb:cc:00:01:02", setupToken: pairing.setupToken), "first device binds")
        check(try !store.bind(deviceID: "aa:bb:cc:00:01:03", setupToken: pairing.setupToken), "second device refused")
        let headers = [(name: "Device-Id", value: "aa:bb:cc:00:01:02"),
                       (name: "Protocol-Version", value: "1"),
                       (name: "Authorization", value: "Bearer " + pairing.deviceToken)]
        check(store.authenticates(headers), "paired device authenticates")
        check(!store.authenticates(headers + [headers[2]]), "duplicate auth rejected")
        let rejectingStore = XiaozhiPairingStore(pairing: pairing, save: { _ in throw XiaozhiError.message("storage failure") })
        do { _ = try rejectingStore.bind(deviceID: "aa:bb:cc:00:01:02", setupToken: pairing.setupToken) }
        catch { checks += 1 }
        check(rejectingStore.snapshot.deviceID == nil, "failed persistence does not bind")
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
