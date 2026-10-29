import Foundation
import Security
import CryptoKit

struct XiaozhiPairing: Codable {
    var setupToken: String
    var deviceToken: String
    var deviceID: String?
    var clientID: String?

    /// Public discovery identity; never advertise the pairing credential itself.
    var discoveryName: String {
        "openminis-" + SHA256.hash(data: Data(setupToken.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
    }

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
/// Existing Keychain data is retained so the Bluetooth upgrade keeps pairing.
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

    /// Only learn the original board UUID through the authenticated BLE link.
    /// It identifies the existing console binding; never invent a new device.
    func rememberClientID(_ clientID: String, deviceID: String) throws {
        guard UUID(uuidString: clientID) != nil else { return }
        lock.lock(); defer { lock.unlock() }
        guard pairing.deviceID == deviceID, pairing.clientID != clientID else { return }
        var updated = pairing; updated.clientID = clientID
        try save(updated); pairing = updated
    }

    static func load() throws -> XiaozhiPairingStore {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "OpenMinis") + ".xiaozhi",
            kSecAttrAccount as String: "device-pairing"]
        func save(_ pairing: XiaozhiPairing) throws {
            let data = try JSONEncoder().encode(pairing)
            let attributes: [String: Any] = [kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
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
            // Accessory restoration can occur with the screen locked. App and
            // conversation locks remain enforced before processing any speech.
            try save(pairing)
        } else {
            throw XiaozhiError.message("请解锁手机后重新开启设备连接")
        }
        return Self(pairing: pairing, save: save)
    }

}
