@preconcurrency import CoreBluetooth
import Foundation
import Security

/// Authenticated, encrypted GATT transport. No IP address or network listener.
@MainActor
final class XiaozhiBluetoothTransport: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    private static let service = CBUUID(string: "CB593B10-7314-4885-A545-39F69381BA6E")
    private static let identity = CBUUID(string: "CB593B11-7314-4885-A545-39F69381BA6E")
    private static let uplink = CBUUID(string: "CB593B14-7314-4885-A545-39F69381BA6E")
    private static let downlink = CBUUID(string: "CB593B15-7314-4885-A545-39F69381BA6E")
    private static let authentication = CBUUID(string: "CB593B16-7314-4885-A545-39F69381BA6E")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var uplink: CBCharacteristic?
    private var downlink: CBCharacteristic?
    private var authentication: CBCharacteristic?
    private var pairing: XiaozhiPairing?
    private var crypto: XiaozhiBluetoothCrypto?
    private var frames = XiaozhiBluetoothFrames()
    private var sequence: UInt16 = 0
    private var connectionTicket = UUID()
    private var writing = false
    private struct Send {
        let id: UUID
        let frames: [Data]
        let binary: Bool
        var index = 0
        let continuation: CheckedContinuation<Void, Error>
        let timeout: Task<Void, Never>
    }
    private var sends: [Send] = []
    var onReady: (() -> Void)?
    var onMessage: ((Data, Bool) -> Void)?
    var onDisconnect: (() -> Void)?
    var onStatus: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private(set) var isReady = false

    func start(pairing: XiaozhiPairing) {
        self.pairing = pairing
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main, options: [
                CBCentralManagerOptionRestoreIdentifierKey: "com.koon.minis.xiaozhi.ble.voice",
                CBCentralManagerOptionShowPowerAlertKey: true
            ])
        } else if central?.state == .poweredOn { discover() }
    }

    func stop() {
        pairing = nil; central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        clearConnection()
        onStatus?("未开启")
    }

    private func clearConnection() {
        connectionTicket = UUID()
        peripheral = nil; uplink = nil; downlink = nil; authentication = nil
        crypto = nil; frames = XiaozhiBluetoothFrames(); isReady = false; writing = false
        let pending = sends; sends.removeAll()
        for send in pending {
            send.timeout.cancel()
            send.continuation.resume(throwing: XiaozhiError.message("小智蓝牙已断开"))
        }
        onDisconnect?()
    }

    private func failed(_ message: String) {
        onError?(message)
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        clearConnection()
        discover()
    }

    private func discover() {
        guard let central, central.state == .poweredOn, pairing != nil, peripheral == nil else { return }
        onStatus?("正在寻找已配对的小智")
        central.scanForPeripherals(withServices: [Self.service], options: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { discover() }
        else {
            clearConnection()
            onStatus?(central.state == .unauthorized ? "请在系统设置中允许蓝牙" : "等待手机开启蓝牙")
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard pairing != nil,
              let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let first = restored.first else { return }
        peripheral = first; first.delegate = self
        if first.state == .connected { first.discoverServices([Self.service]) }
        else { central.connect(first) }
        for extra in restored.dropFirst() { central.cancelPeripheralConnection(extra) }
    }

    func centralManager(_ central: CBCentralManager, didDiscover found: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard pairing != nil, peripheral == nil else { return }
        peripheral = found; found.delegate = self
        central.connect(found)
        let ticket = UUID(); connectionTicket = ticket
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard let self, self.connectionTicket == ticket, !self.isReady else { return }
            self.failed("蓝牙配对确认超时")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard pairing != nil, peripheral == self.peripheral else {
            central.cancelPeripheralConnection(peripheral); return
        }
        onStatus?("正在确认小智身份")
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { disconnected(peripheral) }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { disconnected(peripheral) }
    private func disconnected(_ source: CBPeripheral) {
        guard peripheral == source else { return }
        clearConnection(); central?.stopScan(); discover()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral == self.peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            failed("需要支持纯蓝牙语音的小智固件"); return
        }
        peripheral.discoverCharacteristics([Self.identity, Self.uplink, Self.downlink, Self.authentication], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral == self.peripheral else { return }
        guard error == nil, let values = service.characteristics,
              let identity = values.first(where: { $0.uuid == Self.identity }),
              let up = values.first(where: { $0.uuid == Self.uplink && $0.properties.contains(.notify) }),
              let down = values.first(where: { $0.uuid == Self.downlink && $0.properties.contains(.write) && $0.properties.contains(.writeWithoutResponse) }),
              let auth = values.first(where: { $0.uuid == Self.authentication && $0.properties.contains(.write) }) else {
            failed("小智蓝牙服务不完整"); return
        }
        uplink = up; downlink = down; authentication = auth
        peripheral.readValue(for: identity)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == self.peripheral, let pairing, error == nil, let data = characteristic.value else { return }
        do {
            if characteristic.uuid == Self.identity {
                guard String(data: data, encoding: .utf8) == pairing.discoveryName, let uplink else {
                    failed("发现的设备不是已配对的小智"); return
                }
                peripheral.setNotifyValue(true, for: uplink)
            } else if characteristic.uuid == Self.authentication, let authentication {
                var nonce = [UInt8](repeating: 0, count: 16)
                guard SecRandomCopyBytes(kSecRandomDefault, nonce.count, &nonce) == errSecSuccess,
                      peripheral.maximumWriteValueLength(for: .withResponse) >= 32 else {
                    throw XiaozhiError.message("无法建立安全蓝牙连接")
                }
                var crypto = XiaozhiBluetoothCrypto(token: pairing.setupToken)
                let proof = try crypto.authenticate(challenge: data, nonce: Data(nonce))
                self.crypto = crypto; frames = XiaozhiBluetoothFrames(); sequence = 0
                peripheral.writeValue(proof, for: authentication, type: .withResponse)
            } else if characteristic.uuid == Self.uplink, let envelope = try frames.append(data) {
                guard crypto != nil else { throw XiaozhiError.message("蓝牙尚未认证") }
                let (payload, binary) = try crypto!.open(envelope)
                if !isReady {
                    guard !binary, let value = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                          value["type"] as? String == "authenticated" else { throw XiaozhiError.message("蓝牙身份确认失败") }
                    isReady = true; central?.stopScan(); onStatus?("蓝牙已连接"); onReady?()
                } else {
                    onMessage?(payload, binary)
                }
            }
        } catch { failed(error.localizedDescription) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == self.peripheral, characteristic.uuid == Self.uplink else { return }
        guard error == nil, characteristic.isNotifying, let authentication else { failed("蓝牙语音订阅失败"); return }
        peripheral.readValue(for: authentication)
    }

    func send(_ data: Data, binary: Bool = false) async throws {
        guard isReady, crypto != nil, let peripheral, sends.count < 8 else { throw XiaozhiError.message("小智蓝牙未连接或发送繁忙") }
        let envelope = try crypto!.seal(data, binary: binary)
        let pieces = try XiaozhiBluetoothFrames.split(envelope, id: sequence,
            mtu: min(244, peripheral.maximumWriteValueLength(for: binary ? .withoutResponse : .withResponse)))
        sequence &+= 1
        try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            let timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled, let self, self.sends.contains(where: { $0.id == id }) else { return }
                self.failed("蓝牙发送超时，请靠近小智后重试")
            }
            sends.append(Send(id: id, frames: pieces, binary: binary, continuation: continuation, timeout: timeout))
            pump()
        }
    }

    private func pump() {
        guard let peripheral, let downlink, isReady, !writing else { return }
        while !sends.isEmpty {
            if sends[0].index == sends[0].frames.count {
                let sent = sends.removeFirst(); sent.timeout.cancel(); sent.continuation.resume(); continue
            }
            let binary = sends[0].binary
            if binary && !peripheral.canSendWriteWithoutResponse { return }
            let frame = sends[0].frames[sends[0].index]
            sends[0].index += 1
            writing = !binary
            peripheral.writeValue(frame, for: downlink, type: binary ? .withoutResponse : .withResponse)
            if writing { return }
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if peripheral == self.peripheral { pump() }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == self.peripheral else { return }
        if let error { failed(error.localizedDescription); return }
        if characteristic.uuid == Self.downlink { writing = false; pump() }
    }
}
