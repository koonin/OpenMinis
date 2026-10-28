import Foundation
import Security

struct XiaozhiPairing: Codable {
    var setupToken: String
    var deviceToken: String
    var deviceID: String?

    static func fresh() throws -> Self {
        func random() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 24)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw XiaozhiError.message("无法创建设备配对凭据")
            }
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return try Self(setupToken: random(), deviceToken: random())
    }
}

/// Device credentials never enter the model/provider configuration or iCloud.
/// The lock also serializes first-device binding with WebSocket authentication.
final class XiaozhiPairingStore: @unchecked Sendable {
    private let lock = NSLock()
    private var pairing: XiaozhiPairing
    private let save: (XiaozhiPairing) throws -> Void

    init(pairing: XiaozhiPairing, save: @escaping (XiaozhiPairing) throws -> Void) {
        self.pairing = pairing; self.save = save
    }

    var snapshot: XiaozhiPairing {
        lock.lock(); defer { lock.unlock() }; return pairing
    }

    func bind(deviceID: String, setupToken: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard XiaozhiProtocol.equalSecret(setupToken, pairing.setupToken),
              XiaozhiProtocol.deviceID(deviceID) != nil,
              pairing.deviceID == nil || pairing.deviceID == deviceID else { return false }
        if pairing.deviceID == nil {
            var updated = pairing; updated.deviceID = deviceID
            try save(updated)
            pairing = updated
        }
        return true
    }

    func authenticates(_ headers: [(name: String, value: String)]) -> Bool {
        var values: [String: String] = [:]
        for header in headers {
            let name = header.name.lowercased()
            guard values[name] == nil else { return false }
            values[name] = header.value
        }
        let current = snapshot
        return current.deviceID != nil
            && XiaozhiProtocol.deviceID(values["device-id"]) == current.deviceID
            && values["protocol-version"] == "1"
            && XiaozhiProtocol.equalSecret(values["authorization"] ?? "", "Bearer " + current.deviceToken)
    }

    static func load() throws -> XiaozhiPairingStore {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "OpenMinis") + ".xiaozhi",
            kSecAttrAccount as String: "device-pairing"]
        func save(_ pairing: XiaozhiPairing) throws {
            let data = try JSONEncoder().encode(pairing)
            let attributes: [String: Any] = [kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
            var result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if result == errSecItemNotFound {
                result = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            }
            guard result == errSecSuccess else { throw XiaozhiError.message("请解锁手机后重新开启设备连接") }
        }
        var item: CFTypeRef?
        let result = SecItemCopyMatching(query.merging([
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne
        ]) { _, new in new } as CFDictionary, &item)
        let pairing: XiaozhiPairing
        if result == errSecItemNotFound {
            pairing = try .fresh(); try save(pairing)
        } else if result == errSecSuccess, let data = item as? Data {
            pairing = try JSONDecoder().decode(XiaozhiPairing.self, from: data)
            guard pairing.setupToken.count == 48, pairing.deviceToken.count == 48 else {
                throw XiaozhiError.message("设备配对信息损坏")
            }
        } else {
            throw XiaozhiError.message("请解锁手机后重新开启设备连接")
        }
        return Self(pairing: pairing, save: save)
    }

    func reset() throws {
        lock.lock(); defer { lock.unlock() }
        let replacement = try XiaozhiPairing.fresh()
        try save(replacement); pairing = replacement
    }
}
