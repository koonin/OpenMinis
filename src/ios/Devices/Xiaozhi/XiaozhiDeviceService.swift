import Combine
import Foundation
import UIKit

@MainActor
final class XiaozhiDeviceService: ObservableObject {
    static let shared = XiaozhiDeviceService()
    @Published private(set) var isEnabled = false
    @Published private(set) var isRunning = false
    @Published private(set) var isBusy = false
    @Published private(set) var status = "未开启"
    @Published private(set) var setupURL: String?
    @Published private(set) var deviceID: String?
    @Published private(set) var sessionID: String? = UserDefaults.standard.string(forKey: "xiaozhi.sessionID")
    @Published private(set) var lastError: String?
    @Published private(set) var completedTurns = 0
    @Published private(set) var lastTranscript = ""
    @Published private(set) var lastReply = ""

    private var pairing: XiaozhiPairingStore?
    private var server: XiaozhiLANServer?
    private var serverGeneration = UUID()
    private var connectionID: UUID?
    private var helloReceived = false
    private var turnGeneration = UUID()
    private var capture: XiaozhiVoiceCapture?
    private var captureID: UUID?
    private var pendingListenMode: String?
    private var turnTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var lastAudioAt = Date()
    private let logger = AppLogger(category: "Xiaozhi")

    private init() {}

    func enable() async {
        guard !isEnabled else { return }
        lastError = nil
        if VoiceProviderResolver.inputProvider() is SystemVoiceProvider,
           !(await SystemVoiceProvider.ensureSpeechAuthorization()) {
            lastError = "请在系统设置中允许小冠使用语音识别"; return
        }
        do {
            if pairing == nil { pairing = try XiaozhiPairingStore.load() }
            isEnabled = true
            try startListener()
        } catch { isEnabled = false; lastError = error.localizedDescription; status = "无法开启" }
    }

    func disable() {
        isEnabled = false; pauseListener(); status = "未开启"
    }

    func foregroundChanged(_ active: Bool) {
        guard isEnabled else { return }
        if active {
            guard server == nil else { return }
            do { try startListener() }
            catch { lastError = error.localizedDescription; status = "等待连接 Wi-Fi" }
        } else {
            pauseListener(); status = "已暂停，回到小冠后恢复"
        }
    }

    func resetPairing() {
        guard !isBusy else { return }
        disable()
        do {
            if pairing == nil { pairing = try XiaozhiPairingStore.load() }
            try pairing?.reset(); deviceID = nil; setupURL = nil
        } catch { lastError = error.localizedDescription }
    }

    func newConversation() {
        guard !isBusy else { return }
        sessionID = nil; UserDefaults.standard.removeObject(forKey: "xiaozhi.sessionID")
        lastTranscript = ""; lastReply = ""
    }

    private func startListener() throws {
        guard let pairing, let address = XiaozhiLANServer.wifiAddress() else {
            throw XiaozhiError.message("请先让 iPhone 连接 Wi-Fi")
        }
        guard !SessionLockStore.shared.appIsLocked else { throw XiaozhiError.message("请先解锁小冠") }
        let generation = UUID(); serverGeneration = generation
        let server = XiaozhiLANServer(pairing: pairing, host: address) { [weak self] event in
            DispatchQueue.main.async {
                guard let self, self.serverGeneration == generation else { return }
                self.handle(event)
            }
        }
        try server.start(); self.server = server
        deviceID = pairing.snapshot.deviceID
        setupURL = "http://\(address):8765/ota/\(pairing.snapshot.setupToken)"
        status = "正在开启"
        KeepScreenAwakeController.shared.setDeviceConnectionActive(true)
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                if self.capture != nil, Date().timeIntervalSince(self.lastAudioAt) > 10,
                   let id = self.connectionID { self.fail("小智收音已中断，请按 OK 重新连接", id: id) }
            }
        }
    }

    private func pauseListener() {
        serverGeneration = UUID(); turnGeneration = UUID()
        capture?.cancel(); capture = nil; captureID = nil
        pendingListenMode = nil; connectionID = nil; helloReceived = false
        server?.stop(); server = nil; isRunning = false
        watchdog?.cancel(); watchdog = nil
        KeepScreenAwakeController.shared.setDeviceConnectionActive(false)
        // Already-submitted Agent work continues; its task owns the busy lease
        // until it actually finishes. No automatic resend after a foreground return.
    }

    private func handle(_ event: XiaozhiLANServer.Event) {
        switch event {
        case .ready:
            isRunning = true; status = isBusy ? "小冠仍在处理上一轮" : "等待小智连接"
            KeepScreenAwakeController.shared.setDeviceConnectionActive(true)
        case .bound: deviceID = pairing?.snapshot.deviceID
        case .failed(let message):
            lastError = message; disable(); status = "连接服务已停止"
        case .connected(let id):
            if isBusy { server?.disconnect(id); return }
            connectionID = id; helloReceived = false; status = "正在连接小智"
            turnGeneration = UUID()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self, self.connectionID == id, !self.helloReceived else { return }
                self.fail("小智连接握手超时", id: id)
            }
        case .disconnected(let id):
            guard connectionID == id else { return }
            turnGeneration = UUID(); connectionID = nil; helloReceived = false
            capture?.cancel(); capture = nil; captureID = nil; pendingListenMode = nil
            status = isBusy ? "小冠仍在处理上一轮" : "等待小智连接"
        case .message(let id, let data, let binary):
            guard connectionID == id, !SessionLockStore.shared.appIsLocked else {
                server?.disconnect(id); return
            }
            if binary {
                guard helloReceived else { fail("小智需要先完成连接握手", id: id); return }
                if !isBusy, capture != nil { lastAudioAt = Date(); capture?.append(data) }
                return
            }
            do {
                guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw XiaozhiError.message("小智控制消息格式错误")
                }
                try control(event, id: id)
            } catch { fail(error.localizedDescription, id: id) }
        }
    }

    private func control(_ event: [String: Any], id: UUID) throws {
        if !helloReceived {
            guard XiaozhiProtocol.validHello(event) else { throw XiaozhiError.message("小智音频协议不兼容") }
            helloReceived = true; status = "小智已连接"
            Task { try? await send("hello", id: id, fields: ["version": 1, "transport": "websocket",
                                                           "audio_params": XiaozhiProtocol.audioParameters]) }
            return
        }
        switch event["type"] as? String {
        case "abort":
            turnGeneration = UUID(); capture?.cancel(); capture = nil; captureID = nil
            pendingListenMode = nil
            Task { try? await send("tts", id: id, fields: ["state": "stop"]) }
        case "listen":
            if event["state"] as? String == "start" {
                guard let mode = event["mode"] as? String, ["auto", "manual"].contains(mode) else {
                    throw XiaozhiError.message("暂不支持同时收音和播放，请使用普通对话模式")
                }
                if isBusy { pendingListenMode = mode; status = "等待上一轮处理结束" }
                else { startCapture(mode: mode, id: id) }
            } else if event["state"] as? String == "stop" { pendingListenMode = nil; capture?.finish() }
        default: break
        }
    }

    private func startCapture(mode: String, id: UUID) {
        capture?.cancel()
        let ticket = UUID(); captureID = ticket; pendingListenMode = nil
        capture = XiaozhiVoiceCapture { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.connectionID == id, self.captureID == ticket else { return }
                self.capture?.cancel(); self.capture = nil; self.captureID = nil
                switch result {
                case .failure(let error): self.fail(error.localizedDescription, id: id)
                case .success(let wav):
                    if wav.isEmpty { self.startCapture(mode: mode, id: id) }
                    else { self.beginTurn(wav: wav, id: id) }
                }
            }
        }
        lastAudioAt = Date(); capture?.start(auto: mode == "auto"); status = "正在聆听"
    }

    private func beginTurn(wav: Data, id: UUID) {
        guard !isBusy else { return }
        isBusy = true; lastError = nil
        turnGeneration = UUID()
        let generation = turnGeneration
        turnTask = Task { [weak self] in await self?.process(wav: wav, id: id, generation: generation) }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard let self, self.isBusy, self.current(id, generation) else { return }
            self.fail("处理时间较长，请到小冠会话查看进度。请求没有重发。", id: id)
        }
    }

    private func current(_ id: UUID, _ generation: UUID) -> Bool {
        guard connectionID == id, turnGeneration == generation, isRunning else { return false }
        if SessionLockStore.shared.appIsLocked
            || sessionID.map({ SessionLockStore.shared.isVisuallyLocked($0) }) == true {
            server?.disconnect(id)
            return false
        }
        return true
    }

    private func process(wav: Data, id: UUID, generation: UUID) async {
        defer {
            isBusy = false; turnTask = nil
            if let mode = pendingListenMode, connectionID == id { startCapture(mode: mode, id: id) }
        }
        do {
            guard current(id, generation) else { return }
            try await send("tts", id: id, fields: ["state": "start"])
            status = "正在识别"
            let inputEntry = VoiceProviderResolver.resolvedInputEntry()
            let inputMode = VoiceProviderResolver.resolvedSystemInputMode()
            let recognition = try await VoiceProviderResolver.inputProvider().transcribe(VoiceInputRequest(
                audioData: wav, model: inputEntry?.model.id, language: VoiceLanguages.lastUsed,
                resolvedModel: inputEntry?.model,
                onDeviceRecognition: inputMode == .offline ? true : (inputMode == .online ? false : nil)))
            guard current(id, generation) else { return }
            let text = recognition.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw XiaozhiError.message("没有听清，请按 OK 再说一次") }
            lastTranscript = text
            try await send("stt", id: id, fields: ["text": text])
            status = "小冠正在回复"
            let reply = try await agentReply(text, id: id, generation: generation)
            guard current(id, generation) else { return }
            lastReply = reply
            let spoken = VoiceTextSanitizer.sanitize(String(reply.prefix(500)))
            guard !spoken.isEmpty else { throw XiaozhiError.message("回复没有可朗读的文字，请在手机查看") }
            status = "正在生成声音"
            let outputEntry = VoiceProviderResolver.resolvedOutputEntry()
            let audio = try await VoiceProviderResolver.outputProvider().synthesize(VoiceOutputRequest(
                input: spoken, model: outputEntry?.model.id,
                voice: outputEntry?.model.id ?? VoiceProviderResolver.resolvedSystemOutputVoiceId(),
                responseFormat: .wav, resolvedModel: outputEntry?.model))
            guard current(id, generation) else { return }
            let packets = try await Task.detached(priority: .userInitiated) {
                let pcm = try XiaozhiAudioCodec.pcmFromAudio(audio)
                return try XiaozhiAudioCodec().encode(pcm)
            }.value
            guard current(id, generation) else { return }
            try await send("llm", id: id, fields: ["emotion": "neutral"])
            try await send("tts", id: id, fields: ["state": "sentence_start", "text": spoken])
            status = "小智正在播放"
            try await Task.sleep(nanoseconds: 80_000_000)
            for packet in packets {
                guard current(id, generation), let server else { return }
                try await server.send(packet, binary: true, to: id)
                try await Task.sleep(nanoseconds: 60_000_000)
            }
            completedTurns += 1
            logger.info("Device voice turn completed (count=\(self.completedTurns))")
            // A listen.start racing this send is retained in pendingListenMode;
            // the defer releases serialization and starts that capture.
            try await send("tts", id: id, fields: ["state": "stop"])
            status = "小智已连接"
        } catch {
            if current(id, generation) { fail(error.localizedDescription, id: id) }
        }
    }

    private func agentReply(_ text: String, id: UUID, generation: UUID) async throws -> String {
        let vm: AIChatViewModel
        if let sessionID {
            guard await ChatStore.shared.getSession(sessionID) != nil else {
                throw XiaozhiError.message("小智会话已删除，请在设备设置中新建对话")
            }
            guard !SessionLockStore.shared.isVisuallyLocked(sessionID) else {
                throw XiaozhiError.message("请先在手机解锁小智会话")
            }
            let cached = ViewModelCache.shared.getOrCreate(for: sessionID)
            vm = cached.vm
            // A cached VM owns its live draft and current turn. Reloading it
            // before checking availability could replace in-flight messages.
            if cached.isNew { await vm.loadSession() }
        } else {
            vm = ViewModelCache.shared.createDraft(); vm.sessionSource = "device"
            let createdID = await vm.ensureSessionReturningId(makeActive: false)
            sessionID = createdID; UserDefaults.standard.set(createdID, forKey: "xiaozhi.sessionID")
        }
        guard current(id, generation) else { throw CancellationError() }
        guard !vm.isProcessing, !vm.isCompacting, vm.promptQueue.isEmpty,
              vm.attachments.isEmpty, vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XiaozhiError.message("这段会话正在使用，请等手机处理结束后再说")
        }
        let oldMessageIDs = Set(vm.messages.map(\.id))
        vm.routesReplyToDevice = true
        defer { vm.routesReplyToDevice = false }
        let outcome = vm.submitProgrammaticPrompt(
            "这是小智设备的语音对话，请用简短自然的语言回答，适合朗读。用户说：\n" + text,
            origin: .device, silent: true)
        guard outcome == .sent else { throw XiaozhiError.message("小冠暂时无法接收，请在手机检查") }
        guard let userID = vm.messages.first(where: { $0.role == .user && !oldMessageIDs.contains($0.id) })?.id else {
            // Keep the task serialized even if the UI message appears asynchronously.
            _ = await vm.awaitProgrammaticTurn(queuedPromptId: nil)
            throw XiaozhiError.message("无法确认本次回复归属，请在手机查看。请求没有重发。")
        }
        guard await vm.awaitProgrammaticTurn(queuedPromptId: nil), vm.errorMessage == nil else {
            throw XiaozhiError.message("小冠未完成回复，请在手机会话中查看")
        }
        guard let start = vm.messages.firstIndex(where: { $0.id == userID }) else {
            throw XiaozhiError.message("无法找到这轮对话，请在手机查看")
        }
        let following = vm.messages.dropFirst(start + 1).prefix(while: { $0.role != .user })
        let reply = following.filter { $0.role == .assistant }.flatMap(\.blocks)
            .filter { $0.kind == .text }.map(\.content).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { throw XiaozhiError.message("小冠没有返回文字，请在手机会话中查看") }
        return reply
    }

    private func send(_ type: String, id: UUID, fields: [String: Any] = [:]) async throws {
        guard let server, connectionID == id else { throw XiaozhiError.message("小智已断开") }
        var payload = fields; payload["type"] = type; payload["session_id"] = id.uuidString
        try await server.send(JSONSerialization.data(withJSONObject: payload), to: id)
    }

    private func fail(_ message: String, id: UUID) {
        guard connectionID == id else { return }
        lastError = message; status = "请检查后按 OK 重新连接"
        turnGeneration = UUID(); capture?.cancel(); capture = nil; captureID = nil; pendingListenMode = nil
        let server = server
        Task {
            try? await send("alert", id: id, fields: ["status": "小冠连接", "emotion": "sad",
                                                    "message": "请检查手机后按 OK 重新连接"])
            server?.disconnect(id)
        }
    }
}
