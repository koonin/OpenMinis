import Foundation

@main struct BluetoothTests {
    static func main() throws {
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "scripts/xiaozhi_ble_vectors.json"
        let vectors = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: String]
        func bytes(_ key: String) -> Data {
            let hex = Array(vectors[key]!)
            return Data(stride(from: 0, to: hex.count, by: 2).map { UInt8(String(hex[$0...($0 + 1)]), radix: 16)! })
        }
        var count = 0
        func check(_ passed: Bool) { precondition(passed); count += 1 }
        func rejected(_ work: () throws -> Void) {
            do { try work(); fatalError("invalid BLE input accepted") }
            catch { count += 1 }
        }
        var crypto = XiaozhiBluetoothCrypto(token: vectors["token"]!)
        check(try crypto.authenticate(challenge: bytes("challenge"), nonce: bytes("nonce")) == bytes("proof"))
        check(try crypto.seal(Data("hello".utf8), binary: false) == bytes("phoneEnvelope"))
        var tampered = bytes("deviceEnvelope"); tampered[tampered.count - 1] ^= 1
        rejected { _ = try crypto.open(tampered) }
        let first = try crypto.open(bytes("deviceEnvelope")); check(first.0 == Data("authenticated".utf8) && !first.1)
        rejected { _ = try crypto.open(bytes("deviceEnvelope")) }
        let second = try crypto.open(bytes("deviceSecondEnvelope")); check(second.0 == Data([0x18, 0]) && second.1)
        var wrong = XiaozhiBluetoothCrypto(token: String(repeating: "c", count: 48))
        rejected { _ = try wrong.authenticate(challenge: bytes("challenge"), nonce: bytes("nonce")) }
        var gap = XiaozhiBluetoothCrypto(token: vectors["token"]!)
        _ = try gap.authenticate(challenge: bytes("challenge"), nonce: bytes("nonce"))
        rejected { _ = try gap.open(bytes("deviceSecondEnvelope")) }
        rejected { _ = try crypto.seal(Data(repeating: 0, count: 1276), binary: true) }
        rejected { _ = try crypto.seal(Data(repeating: 0, count: 8193), binary: false) }
        for mtu in [20, 61, 182, 244] {
            for size in [25, 180, 8217] {
                let expected = Data((0..<size).map { UInt8(truncatingIfNeeded: $0) })
                let frames = try XiaozhiBluetoothFrames.split(expected, id: 65535, mtu: mtu)
                var decoder = XiaozhiBluetoothFrames(); var result: Data?
                for frame in frames { check(frame.count <= mtu); result = try decoder.append(frame) }
                check(result == expected)
            }
        }
        let frames = try XiaozhiBluetoothFrames.split(Data(repeating: 1, count: 300), id: 9, mtu: 61)
        var decoder = XiaozhiBluetoothFrames()
        rejected { _ = try decoder.append(frames[1]) }
        decoder = XiaozhiBluetoothFrames(); _ = try decoder.append(frames[0])
        rejected { _ = try decoder.append(frames[2]) }
        decoder = XiaozhiBluetoothFrames(); _ = try decoder.append(frames[0])
        rejected { _ = try decoder.append(frames[0]) }
        rejected { _ = try XiaozhiBluetoothFrames.split(Data(repeating: 0, count: 8218), id: 0, mtu: 182) }
        print("PASS \(count) Bluetooth checks: independent crypto vectors, authentication, tampering, replay, gaps, framing and bounds")
    }
}
