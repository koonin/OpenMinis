import Foundation
import Network
import Darwin

/// Dedicated device-only service. It exposes provisioning and voice frames,
/// never the Debug RPC, shell, files, or model credentials.
final class XiaozhiLANServer: @unchecked Sendable {
    enum Event {
        case ready
        case bound
        case connected(UUID)
        case message(UUID, Data, binary: Bool)
        case disconnected(UUID)
        case failed(String)
    }

    private let queue = DispatchQueue(label: "app.openminis.xiaozhi.network")
    private let pairing: XiaozhiPairingStore
    private let host: String
    private let httpPort: UInt16
    private let voicePort: UInt16
    private let event: (Event) -> Void
    private var httpListener: NWListener?
    private var voiceListener: NWListener?
    private var httpConnections: [UUID: NWConnection] = [:]
    private var voice: (id: UUID, connection: NWConnection)?
    private var readyListeners = Set<String>()
    private var stopping = false

    init(pairing: XiaozhiPairingStore, host: String, httpPort: UInt16 = 8765,
         voicePort: UInt16 = 8766, event: @escaping (Event) -> Void) {
        self.pairing = pairing; self.host = host; self.httpPort = httpPort
        self.voicePort = voicePort; self.event = event
    }

    func start() throws {
        let http = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: httpPort)!)
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true; options.maximumMessageSize = 8192
        options.setClientRequestHandler(queue) { [pairing] _, headers in
            .init(status: pairing.authenticates(headers) ? .accept : .reject, subprotocol: nil)
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        let websocket = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: voicePort)!)
        httpListener = http; voiceListener = websocket
        for (name, listener) in [("configuration", http), ("voice", websocket)] {
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.stopping else { return }
                switch state {
                case .ready:
                    self.readyListeners.insert(name)
                    if self.readyListeners.count == 2 { self.event(.ready) }
                case .failed:
                    self.event(.failed("无法开启局域网连接，请检查本地网络权限或端口占用"))
                    self.stopOnQueue()
                default: break
                }
            }
        }
        http.newConnectionHandler = { [weak self] in self?.acceptHTTP($0) }
        websocket.newConnectionHandler = { [weak self] in self?.acceptVoice($0) }
        http.start(queue: queue); websocket.start(queue: queue)
    }

    func stop() { queue.async { self.stopOnQueue() } }

    private func stopOnQueue() {
        stopping = true
        httpListener?.cancel(); voiceListener?.cancel()
        httpListener = nil; voiceListener = nil
        for connection in httpConnections.values { connection.cancel() }
        httpConnections.removeAll()
        if let voice { voice.connection.cancel(); self.voice = nil; event(.disconnected(voice.id)) }
    }

    private func acceptHTTP(_ connection: NWConnection) {
        guard !stopping, httpConnections.count < 4 else { connection.cancel(); return }
        let id = UUID(); httpConnections[id] = connection
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 8) { [weak self, weak connection] in
            guard self?.httpConnections.removeValue(forKey: id) != nil else { return }
            connection?.cancel()
        }
        readHTTP(connection, id: id, bytes: Data())
    }

    private func readHTTP(_ connection: NWConnection, id: UUID, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self, self.httpConnections[id] != nil else { return }
            var next = bytes; next.append(data ?? Data())
            do {
                if let request = try XiaozhiHTTPRequest.parse(next) {
                    try self.respond(request, connection: connection, id: id)
                } else if complete || error != nil {
                    self.endHTTP(id)
                } else {
                    self.readHTTP(connection, id: id, bytes: next)
                }
            } catch {
                self.sendHTTP(connection, id: id, status: "400 Bad Request", json: ["error": "Invalid request"])
            }
        }
    }

    private func respond(_ request: XiaozhiHTTPRequest, connection: NWConnection, id: UUID) throws {
        if request.method == "GET", request.path == "/health" {
            sendHTTP(connection, id: id, status: "200 OK", json: ["service": "openminis-xiaozhi",
                "device_bound": pairing.snapshot.deviceID != nil, "connected": voice != nil])
            return
        }
        guard ["GET", "POST"].contains(request.method), request.path.hasPrefix("/ota/"),
              let deviceID = XiaozhiProtocol.deviceID(request.headers["device-id"]),
              try pairing.bind(deviceID: deviceID, setupToken: String(request.path.dropFirst(5))) else {
            sendHTTP(connection, id: id, status: "403 Forbidden", json: ["error": "Device pairing required"])
            return
        }
        event(.bound)
        sendHTTP(connection, id: id, status: "200 OK", json: [
            "websocket": ["url": "ws://\(host):\(voicePort)/xiaozhi/v1/",
                          "token": pairing.snapshot.deviceToken, "version": 1],
            "server_time": ["timestamp": Int64(Date().timeIntervalSince1970 * 1000),
                            "timezone_offset": TimeZone.current.secondsFromGMT() / 60]
        ])
    }

    private func sendHTTP(_ connection: NWConnection, id: UUID, status: String, json: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: json) else { endHTTP(id); return }
        var bytes = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        bytes.append(body)
        connection.send(content: bytes, completion: .contentProcessed { [weak self] _ in self?.endHTTP(id) })
    }

    private func endHTTP(_ id: UUID) { httpConnections.removeValue(forKey: id)?.cancel() }

    private func acceptVoice(_ connection: NWConnection) {
        guard !stopping, voice == nil else { connection.cancel(); return }
        let id = UUID(); voice = (id, connection)
        var becameReady = false
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.voice?.id == id else { return }
            switch state {
            case .ready:
                becameReady = true; self.event(.connected(id)); self.readVoice(connection, id: id)
            case .failed, .cancelled:
                self.voice = nil; connection.cancel(); self.event(.disconnected(id))
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            if !becameReady, self?.voice?.id == id { connection.cancel() }
        }
    }

    private func readVoice(_ connection: NWConnection, id: UUID) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, self.voice?.id == id, !self.stopping else { return }
            guard error == nil, let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata else { connection.cancel(); return }
            switch metadata.opcode {
            case .text, .binary:
                guard let data, data.count <= 8192 else { connection.cancel(); return }
                self.event(.message(id, data, binary: metadata.opcode == .binary))
            case .close: connection.cancel(); return
            default: break
            }
            self.readVoice(connection, id: id)
        }
    }

    func send(_ data: Data, binary: Bool = false, to id: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let voice = self.voice, voice.id == id, !self.stopping else {
                    continuation.resume(throwing: XiaozhiError.message("小智连接已断开")); return
                }
                let metadata = NWProtocolWebSocket.Metadata(opcode: binary ? .binary : .text)
                voice.connection.send(content: data,
                    contentContext: .init(identifier: "xiaozhi", metadata: [metadata]), isComplete: true,
                    completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    })
            }
        }
    }

    func disconnect(_ id: UUID) { queue.async { if self.voice?.id == id { self.voice?.connection.cancel() } } }

    static func wifiAddress() -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return nil }
        defer { freeifaddrs(addresses) }
        var cursor = addresses
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let entry = current.pointee
            guard String(cString: entry.ifa_name) == "en0", let address = entry.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 { return String(cString: host) }
        }
        return nil
    }
}
