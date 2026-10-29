import AVFoundation
import Foundation

/// Experimental use of the device's official conversation protocol, not a TTS
/// API. The only exposed tool returns an immutable, already-generated answer.
/// No console model can invoke the local agent or access other local tools.
@MainActor
final class XiaozhiConsoleRelay {
    static let shared = XiaozhiConsoleRelay()
    private var busy = false
    private var operation: UUID?
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var carrier: [Data]?

    func cancel() {
        operation = nil
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    func synthesize(_ text: String) async throws -> Data {
        try await receive(text, onPacket: nil)
    }

    /// Each callback receives a packet whose caption already matches the next
    /// part of the immutable answer. A later failure may leave a spoken prefix;
    /// callers must stop playback and must not mark that turn as completed.
    func stream(_ text: String, onPacket: @escaping (Data) async throws -> Void) async throws {
        _ = try await receive(text, onPacket: onPacket)
    }

    private func receive(_ text: String, onPacket: ((Data) async throws -> Void)?) async throws -> Data {
        guard !busy else { throw XiaozhiError.message("控制台正在生成上一段声音，请稍后再试") }
        let pairing = try XiaozhiPairingStore.load().snapshot
        guard let deviceID = XiaozhiProtocol.deviceID(pairing.deviceID),
              let clientID = pairing.clientID, UUID(uuidString: clientID) != nil else {
            throw XiaozhiError.message("请先更新小智固件，并按一次 OK，让手机读取原控制台绑定")
        }
        var gate = try XiaozhiConsoleReplyGate(text: text)
        busy = true
        let ticket = UUID(); operation = ticket
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 75
        let session = URLSession(configuration: config, delegate: XiaozhiConsoleNoRedirect(), delegateQueue: nil)
        self.session = session
        defer {
            self.socket?.cancel(with: .normalClosure, reason: nil)
            self.socket = nil; self.session = nil; operation = nil; busy = false
            session.invalidateAndCancel()
        }
        // Covers OTA, carrier preparation, MCP and receipt of the full reply.
        let deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 75_000_000_000) } catch { return }
            if self?.operation == ticket { self?.cancel() }
        }
        defer { deadline.cancel() }
        do {
            let audio = try await carrierPackets()
            try check(ticket)
            let request = try await cloudRequest(session: session, deviceID: deviceID, clientID: clientID)
            try check(ticket)
            let ws = session.webSocketTask(with: request)
            socket = ws; ws.maximumMessageSize = 65_536; ws.resume()
            return try await withTaskCancellationHandler {
                try await send(["type": "hello", "version": 1, "features": ["mcp": true],
                                "transport": "websocket", "audio_params": XiaozhiProtocol.audioParameters], to: ws)
                var sid: String?
                var prompted = false
                var messageCount = 0
                while true {
                    try check(ticket)
                    let message = try await ws.receive()
                    try check(ticket)
                    messageCount += 1
                    guard messageCount <= 2_500 else { throw XiaozhiError.message("后台消息过多，已停止播报") }
                    switch message {
                    case .data(let data):
                        let verified = try gate.append(data)
                        // Await the consumer: no unbounded forwarding task or
                        // second playback queue, and cancellation propagates.
                        if let onPacket { try await onPacket(verified) }
                    case .string(let string):
                        guard let data = string.data(using: .utf8),
                              let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            throw XiaozhiError.message("小智后台消息格式错误")
                        }
                        switch event["type"] as? String {
                        case "hello":
                            guard sid == nil, let id = event["session_id"] as? String, !id.isEmpty, id.count <= 128,
                                  let params = event["audio_params"] as? [String: Any],
                                  params["format"] as? String == "opus", params["channels"] as? Int == 1,
                                  params["frame_duration"] as? Int == 60,
                                  [16_000, 24_000].contains(params["sample_rate"] as? Int ?? 0) else {
                                throw XiaozhiError.message("小智后台音频格式暂不兼容")
                            }
                            sid = id
                        case "mcp":
                            guard let sid, let rpc = event["payload"] as? [String: Any],
                                  let method = rpc["method"] as? String else {
                                throw XiaozhiError.message("小智后台工具消息格式错误")
                            }
                            if method == "notifications/initialized" { continue }
                            guard let rpcID = rpc["id"], rpcID is NSNumber || rpcID is String else {
                                throw XiaozhiError.message("小智后台工具请求缺少编号")
                            }
                            let result: [String: Any]
                            switch method {
                            case "initialize":
                                result = ["protocolVersion": "2024-11-05", "capabilities": ["tools": [:]],
                                          "serverInfo": ["name": "openminis-voice-relay", "version": "1.0"]]
                            case "tools/list":
                                result = ["tools": [["name": XiaozhiConsoleReplyGate.toolName,
                                    "description": "获取小冠已经生成的本轮答复。用户要求小冠回答时，必须先调用此工具，然后逐字朗读返回的文字，不添加开场白、解释或改写。",
                                    "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false],
                                    "annotations": ["readOnlyHint": true, "idempotentHint": true]]]]
                            case "tools/call":
                                guard prompted, let params = rpc["params"] as? [String: Any],
                                      let name = params["name"] as? String,
                                      let arguments = (params["arguments"] ?? [:]) as? [String: Any] else {
                                    throw XiaozhiError.message("后台工具请求不属于本轮播报")
                                }
                                try gate.serveTool(name: name, arguments: arguments)
                                result = ["content": [["type": "text", "text": text]], "isError": false]
                            default: throw XiaozhiError.message("后台请求了未开放的工具，已停止播报")
                            }
                            try await send(["session_id": sid, "type": "mcp", "payload": [
                                "jsonrpc": "2.0", "id": rpcID, "result": result]], to: ws)
                            if method == "tools/list", !prompted {
                                prompted = true
                                // Official backend rejects long listen.detect text.
                                // Use a short, fixed voice request over its supported audio path.
                                try await send(["session_id": sid, "type": "listen", "state": "start", "mode": "manual"], to: ws)
                                for packet in audio {
                                    try check(ticket)
                                    try await ws.send(.data(packet))
                                    try await Task.sleep(nanoseconds: 60_000_000)
                                }
                                try await send(["session_id": sid, "type": "listen", "state": "stop"], to: ws)
                            }
                        case "tts":
                            if event["state"] as? String == "sentence_start" {
                                guard let caption = event["text"] as? String else {
                                    throw XiaozhiError.message("后台播报缺少字幕，无法核对答复")
                                }
                                try gate.startSentence(caption)
                            } else if event["state"] as? String == "stop" {
                                let packets = try gate.finish()
                                if onPacket != nil { return Data() }
                                let wav = try await Task.detached(priority: .userInitiated) {
                                    // Opus supports decoding a 24 kHz source at the device's
                                    // 16 kHz clock without changing pitch or duration.
                                    let codec = try XiaozhiAudioCodec()
                                    var pcm = Data()
                                    for packet in packets { pcm.append(try codec.decode(packet)) }
                                    return XiaozhiProtocol.wav(pcm: pcm)
                                }.value
                                try check(ticket)
                                return wav
                            }
                        case "alert", "error":
                            // Never include raw cloud messages, URLs or tokens in logs/UI.
                            throw XiaozhiError.message("小智后台未完成播报，请检查控制台绑定或稍后重试")
                        default: break // STT is only the fixed carrier, never a local user turn.
                        }
                    @unknown default: throw XiaozhiError.message("无法读取后台语音")
                    }
                }
            } onCancel: { ws.cancel(with: .goingAway, reason: nil) }
        } catch is CancellationError { throw CancellationError() }
        catch let error as XiaozhiError { throw error }
        catch { throw XiaozhiError.message("连接小智后台失败或超时，原回复已保留在小冠；本轮没有重发") }
    }

    private func check(_ ticket: UUID) throws {
        try Task.checkCancellation()
        guard operation == ticket else { throw XiaozhiError.message("控制台播报已取消或超时") }
    }

    private func carrierPackets() async throws -> [Data] {
        if let carrier { return carrier }
        guard let voice = AVSpeechSynthesisVoice(language: "zh-CN") else {
            throw XiaozhiError.message("请先在 iPhone 下载一个普通话系统音色，用于触发控制台播报")
        }
        let wav = try await SystemVoiceProvider.shared.synthesize(VoiceOutputRequest(
            input: "请原样读小冠答复。", voice: voice.identifier, speed: 1.3, responseFormat: .wav))
        let packets = try await Task.detached(priority: .userInitiated) {
            try XiaozhiAudioCodec().encode(XiaozhiAudioCodec.pcmFromAudio(wav))
        }.value
        guard !packets.isEmpty, packets.count <= 100 else { throw XiaozhiError.message("无法准备控制台语音请求") }
        carrier = packets
        return packets
    }

    private func cloudRequest(session: URLSession, deviceID: String, clientID: String) async throws -> URLRequest {
        var ota = URLRequest(url: URL(string: "https://api.tenclass.net/xiaozhi/ota/")!)
        ota.httpMethod = "POST"
        ota.setValue(deviceID, forHTTPHeaderField: "Device-Id")
        ota.setValue(clientID, forHTTPHeaderField: "Client-Id")
        ota.setValue("1", forHTTPHeaderField: "Activation-Version")
        ota.setValue("OpenMinis-Voice-Relay/1.0", forHTTPHeaderField: "User-Agent")
        ota.setValue("zh-CN", forHTTPHeaderField: "Accept-Language")
        ota.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ota.httpBody = try JSONSerialization.data(withJSONObject: [
            "version": 2, "language": "zh-CN", "mac_address": deviceID, "uuid": clientID,
            "application": ["name": "OpenMinis-Voice-Relay", "version": "1.0"]])
        let (data, response) = try await session.data(for: ota)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 65_536,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XiaozhiError.message("无法读取小智控制台的设备配置")
        }
        guard body["activation"] == nil else {
            throw XiaozhiError.message("这台小智尚未绑定控制台，请先完成原设备绑定")
        }
        // Only use the official service. Ignore firmware/MQTT/upgrade responses.
        guard let websocket = body["websocket"] as? [String: Any],
              let rawURL = websocket["url"] as? String, let url = URL(string: rawURL),
              url.scheme == "wss", url.host == "api.tenclass.net", url.user == nil, url.password == nil,
              let token = websocket["token"] as? String, !token.isEmpty, token.utf8.count <= 8_192,
              !token.contains("\r"), !token.contains("\n") else {
            throw XiaozhiError.message("控制台未提供兼容的安全语音连接")
        }
        var request = URLRequest(url: url)
        request.setValue(token.contains(" ") ? token : "Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "Protocol-Version")
        request.setValue(deviceID, forHTTPHeaderField: "Device-Id")
        request.setValue(clientID, forHTTPHeaderField: "Client-Id")
        return request
    }

    private func send(_ value: [String: Any], to socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
}

private final class XiaozhiConsoleNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
