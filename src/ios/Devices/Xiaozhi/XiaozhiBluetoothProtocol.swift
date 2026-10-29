import Foundation
import CryptoKit

/// BLE v1: existing 192-bit pairing secret authenticates both peers. Every
/// reconnect gets a fresh session key; GCM counters are directional and strict.
struct XiaozhiBluetoothCrypto {
    private let key: SymmetricKey
    private var session: SymmetricKey?
    private var outgoing: UInt64 = 0
    private var incoming: UInt64 = 0
    private static let prefix = "openminis-ble-v1:"

    init(token: String) { key = SymmetricKey(data: SHA256.hash(data: Data(token.utf8))) }

    private func mac(_ label: String, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data((Self.prefix + label).utf8) + data, using: key))
    }

    mutating func authenticate(challenge: Data, nonce: Data) throws -> Data {
        guard challenge.count == 33, challenge.first == 1, nonce.count == 16 else {
            throw XiaozhiError.message("小智蓝牙协议不兼容")
        }
        let deviceNonce = Data(challenge[1..<17])
        let difference = zip(mac("device", deviceNonce).prefix(16), challenge.suffix(16))
            .reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
        guard difference == 0 else {
            throw XiaozhiError.message("小智配对凭据不匹配")
        }
        let salt = deviceNonce + nonce
        session = SymmetricKey(data: mac("session", salt))
        outgoing = 0; incoming = 0
        return nonce + mac("phone", salt).prefix(16)
    }

    private static func counter(_ value: UInt64) -> Data {
        var value = value.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    mutating func seal(_ payload: Data, binary: Bool) throws -> Data {
        guard let session, payload.count <= (binary ? 1275 : 8192), outgoing < UInt64.max else {
            throw XiaozhiError.message("蓝牙连接尚未完成认证或消息过长")
        }
        let next = outgoing + 1
        let counter = Self.counter(next)
        let nonce = try AES.GCM.Nonce(data: Data([0, 0, 0, 2]) + counter)
        let sealed = try AES.GCM.seal(Data([binary ? 1 : 0]) + payload, using: session, nonce: nonce)
        outgoing = next
        return counter + sealed.ciphertext + sealed.tag
    }

    mutating func open(_ envelope: Data) throws -> (Data, Bool) {
        guard let session, (25...8217).contains(envelope.count) else {
            throw XiaozhiError.message("蓝牙消息长度不正确")
        }
        let counter = Data(envelope.prefix(8))
        let sequence = counter.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard incoming < UInt64.max, sequence == incoming + 1 else {
            throw XiaozhiError.message("蓝牙消息缺失或重复，请按 OK 重连")
        }
        let nonce = try AES.GCM.Nonce(data: Data([0, 0, 0, 1]) + counter)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: envelope.dropFirst(8).dropLast(16), tag: envelope.suffix(16))
        let plain = try AES.GCM.open(box, using: session)
        guard let type = plain.first, type <= 1, plain.count <= (type == 1 ? 1276 : 8193) else {
            throw XiaozhiError.message("蓝牙消息类型不正确")
        }
        incoming = sequence
        return (Data(plain.dropFirst()), type == 1)
    }
}

/// Each ATT value has flags, a 16-bit message ID and a 16-bit byte offset.
/// Only one bounded message is assembled; gaps never become audible partial data.
struct XiaozhiBluetoothFrames {
    static let maxEnvelope = 8217
    private var message: UInt16?
    private var buffer = Data()

    static func split(_ data: Data, id: UInt16, mtu: Int) throws -> [Data] {
        guard !data.isEmpty, data.count <= maxEnvelope, mtu > 5 else {
            throw XiaozhiError.message("蓝牙分包长度不正确")
        }
        return stride(from: 0, to: data.count, by: mtu - 5).map { offset in
            let end = min(offset + mtu - 5, data.count)
            let flags: UInt8 = (offset == 0 ? 1 : 0) | (end == data.count ? 2 : 0)
            return Data([flags, UInt8(truncatingIfNeeded: id), UInt8(id >> 8),
                         UInt8(truncatingIfNeeded: offset), UInt8(offset >> 8)]) + data[offset..<end]
        }
    }

    mutating func append(_ data: Data) throws -> Data? {
        guard data.count > 5, data[0] & ~3 == 0 else { throw XiaozhiError.message("蓝牙分包格式不正确") }
        let id = UInt16(data[1]) | UInt16(data[2]) << 8
        let offset = Int(data[3]) | Int(data[4]) << 8
        if data[0] & 1 != 0 {
            guard message == nil, offset == 0 else { throw XiaozhiError.message("蓝牙分包丢失") }
            message = id
        }
        guard message == id, offset == buffer.count,
              buffer.count + data.count - 5 <= Self.maxEnvelope else { throw XiaozhiError.message("蓝牙分包顺序不正确") }
        buffer.append(data.dropFirst(5))
        if data[0] & 2 == 0 { return nil }
        let result = buffer
        buffer = Data(); message = nil
        return result
    }
}
