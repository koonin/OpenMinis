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
    @Published private(set) var deviceID: String?
    @Published private(set) var sessionID: String? = UserDefaults.standard.string(forKey: "xiaozhi.sessionID")
    @Published private(set) var lastError: String?
    @Published private(set) var completedTurns = 0
    @Published private(set) var lastTranscript = ""
    @Published private(set) var lastReply = ""
    @Published private(set) var bluetoothStatus = "未开启"
    @Published private(set) var lastReplyTiming: XiaozhiReplyTiming?
    @Published private(set) var isChangingReplyModel = false
    @Published private(set) var replyModelEntryID = UserDefaults.standard.string(forKey: "xiaozhi.replyModelEntryID")
    var keepsScreenAwake: Bool { false }

    private var pairing: XiaozhiPairingStore?
    private let bluetooth = XiaozhiBluetoothTransport()
    private var connectionID: UUID?
    private var helloReceived = false
    private var turnGeneration = UUID()
    private var capture: XiaozhiVoiceCapture?
    private var captureID: UUID?
    private var pendingListenMode: String?
    private var turnTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var lastAudioAt = Date()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundGeneration = UUID()
    private var enabling = false
    private let logger = AppLogger(category: "Xiaozhi")

    private init() {
        bluetooth.onStatus = { [weak self] text in self?.bluetoothStatus = text }
        bluetooth.onReady = { [weak self] in
            guard let self else { return }
            self.isRunning = true; self.lastError = nil; self.status = "待命，按小智 OK 开始"
            self.logger.info("Authenticated Bluetooth voice connected")
        }
        bluetooth.onMessage = { [weak self] data, binary in self?.receive(data, binary: binary) }
        bluetooth.onDisconnect = { [weak self] in
            guard let self else { return }
            self.isRunning = false; self.clearConversation(); self.endBackgroundTask()
            if self.isEnabled { self.status = "等待小智蓝牙重连" }
        }
        bluetooth.onError = { [weak self] message in self?.lastError = message }
    }

    func restoreAccessoryIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "xiaozhi.connectionEnabled") else { return }
        Task { await enable() }
    }

    func enable() async {
        guard !isEnabled, !enabling else { return }
        enabling = true
        defer { enabling = false }
        lastError = nil
        if VoiceProviderResolver.inputProvider() is SystemVoiceProvider,
           !(await SystemVoiceProvider.ensureSpeechAuthorization()) {
            lastError = "请在系统设置中允许小冠使用语音识别"; return
        }
        do {
            if pairing == nil { pairing = try XiaozhiPairingStore.load() }
            guard let snapshot = pairing?.snapshot, snapshot.deviceID != nil else {
                throw XiaozhiError.message("尚未配置小智配对凭据，请先完成设备配对")
            }
            deviceID = snapshot.deviceID
            isEnabled = true; status = "正在连接蓝牙"
            bluetooth.start(pairing: snapshot)
            UserDefaults.standard.set(true, forKey: "xiaozhi.connectionEnabled")
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled, let self else { return }
                    if self.capture != nil, Date().timeIntervalSince(self.lastAudioAt) > 10,
                       let id = self.connectionID { self.fail("小智收音已中断，请按 OK 重新连接", id: id) }
                }
            }
        } catch { isEnabled = false; lastError = error.localizedDescription; status = "无法开启" }
    }

    func disable() {
        UserDefaults.standard.set(false, forKey: "xiaozhi.connectionEnabled")
        isEnabled = false; bluetooth.stop(); clearConversation(); endBackgroundTask()
        watchdog?.cancel(); watchdog = nil; status = "未开启"
    }

    func foregroundChanged(_ active: Bool) {
        guard !active || UIApplication.shared.applicationState == .active else { return }
        if active, !isEnabled, UserDefaults.standard.bool(forKey: "xiaozhi.connectionEnabled") {
            Task { await enable() }; return
        }
        guard isEnabled else { return }
        if active { endBackgroundTask() }
        else if isBusy || capture != nil { beginBackgroundTask() }
    }

    func newConversation() {
        guard !isBusy, !isChangingReplyModel else { return }
        sessionID = nil; UserDefaults.standard.removeObject(forKey: "xiaozhi.sessionID")
        lastTranscript = ""; lastReply = ""; lastReplyTiming = nil
    }

    var canChangeReplyModel: Bool {
        !isBusy && !isChangingReplyModel && !SessionLockStore.shared.appIsLocked
            && sessionID.map { !SessionLockStore.shared.isVisuallyLocked($0) } != false
    }

    func selectReplyModel(_ entryID: String) async throws {
        guard canChangeReplyModel else { throw XiaozhiError.message("请等待本轮结束，并解锁小智会话后再切换模型") }
        let entry = try replyModelEntry(entryID)
        isChangingReplyModel = true
        defer { isChangingReplyModel = false }
        if let sid = sessionID {
            guard await ChatStore.shared.getSession(sid) != nil else {
                throw XiaozhiError.message("小智会话已删除，请先开始一段新对话")
            }
            let cached = ViewModelCache.shared.getOrCreate(for: sid)
            if cached.isNew { await cached.vm.loadSession() }
            guard !isBusy, !SessionLockStore.shared.appIsLocked,
                  !SessionLockStore.shared.isVisuallyLocked(sid),
                  !cached.vm.isProcessing, !cached.vm.isCompacting, cached.vm.promptQueue.isEmpty else {
                throw XiaozhiError.message("小智会话正在处理任务或已锁定，请稍后切换")
            }
            try Task.checkCancellation()
            try await bindReplyModel(entry, to: cached.vm, sessionID: sid)
        }
        replyModelEntryID = entryID
        UserDefaults.standard.set(entryID, forKey: "xiaozhi.replyModelEntryID")
    }

    private func replyModelEntry(_ id: String) throws -> ModelEntry {
        let store = ProviderConfigStore.shared
        guard let entry = store.entry(for: id),
              entry.model.capabilities.supportedModalities.contains(.textOutput),
              let provider = store.instance(for: entry.providerInstanceId), provider.isEnabled,
              provider.hasAnyCredential else {
            throw XiaozhiError.message("所选回复模型不可用，请检查供应商或重新选择")
        }
        return entry
    }

    private func bindReplyModel(_ entry: ModelEntry, to vm: AIChatViewModel, sessionID: String) async throws {
        guard !vm.isProcessing, !vm.isCompacting, vm.promptQueue.isEmpty,
              !SessionLockStore.shared.appIsLocked, !SessionLockStore.shared.isVisuallyLocked(sessionID) else {
            throw XiaozhiError.message("会话正在处理任务或已锁定，未切换模型")
        }
        let store = ProviderConfigStore.shared
        store.setBinding(SessionModelBinding(sessionId: sessionID,
            primarySource: .directEntry(modelEntryId: entry.id, compositeKey: entry.compositeKey),
            subModelSource: store.binding(for: sessionID)?.subModelSource), for: sessionID)
        // Existing model capability logic clamps Off to the supported minimum.
        vm.setThinkingLevel(.off)
        NotificationCenter.default.post(name: .sessionModelBindingChanged, object: nil,
                                        userInfo: ["sessionId": sessionID])
        await ChatStore.shared.updateSessionModelId(sessionID, modelId: entry.model.id)
    }

    private func clearConversation() {
        XiaozhiVoicePreferences.shared.cancelStreams()
        turnGeneration = UUID(); connectionID = nil; helloReceived = false
        capture?.cancel(); capture = nil; captureID = nil; pendingListenMode = nil
        // Agent operations already submitted are never resubmitted or cancelled
        // by a transport failure; their task retains the busy lease.
    }

    private func closeConversation(_ id: UUID) {
        guard connectionID == id else { return }
        clearConversation()
        status = isBusy ? "小冠仍在处理上一轮" : "待命，按小智 OK 开始"
        let generation = backgroundGeneration
        Task {
            if let data = try? JSONSerialization.data(withJSONObject: ["type": "goodbye", "session_id": id.uuidString]) {
                try? await bluetooth.send(data)
            }
            if connectionID == nil, backgroundGeneration == generation { endBackgroundTask() }
        }
    }

    private func beginBackgroundTask() {
        guard UIApplication.shared.applicationState != .active, backgroundTask == .invalid else { return }
        let generation = UUID(); backgroundGeneration = generation
        logger.info("Bluetooth voice activity (background=true)")
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "小智蓝牙语音") { [weak self] in
            guard let self, self.backgroundGeneration == generation else { return }
            self.lastError = "本轮超过系统允许的后台时间，请打开小冠查看。请求没有重发。"
            if let id = self.connectionID { self.closeConversation(id) }
            self.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        backgroundGeneration = UUID()
        let task = backgroundTask; backgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }

    private func receive(_ data: Data, binary: Bool) {
        guard isEnabled, isRunning, !SessionLockStore.shared.appIsLocked else {
            if let id = connectionID { closeConversation(id) }
            return
        }
        do {
            if binary {
                guard let id = connectionID, helloReceived else { return }
                guard XiaozhiProtocol.is60msMonoOpus(data) else { fail("小智音频格式不兼容", id: id); return }
                if !isBusy, capture != nil { lastAudioAt = Date(); capture?.append(data) }
                return
            }
            guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw XiaozhiError.message("蓝牙控制消息格式错误")
            }
            if event["type"] as? String == "hello" {
                beginBackgroundTask()
                guard !isBusy else {
                    Task {
                        try? await bluetooth.send(Data("{\"type\":\"goodbye\"}".utf8))
                        if connectionID == nil { endBackgroundTask() }
                    }; return
                }
                clearConversation(); connectionID = UUID(); status = "正在准备对话"
            }
            guard let id = connectionID else { return }
            if event["type"] as? String == "goodbye" { closeConversation(id); return }
            try control(event, id: id)
        } catch {
            if let id = connectionID { fail(error.localizedDescription, id: id) }
            else { lastError = error.localizedDescription }
        }
    }

    private func control(_ event: [String: Any], id: UUID) throws {
        if !helloReceived {
            guard XiaozhiProtocol.validHello(event) else { throw XiaozhiError.message("小智音频协议不兼容") }
            if let clientID = event["client_id"] as? String,
               let deviceID = XiaozhiProtocol.deviceID(event["device_id"] as? String) {
                try pairing?.rememberClientID(clientID, deviceID: deviceID)
            }
            helloReceived = true; status = "准备收音"
            Task { try? await send("hello", id: id, fields: ["version": 1, "transport": "bluetooth",
                                                           "audio_params": XiaozhiProtocol.audioParameters]) }
            return
        }
        switch event["type"] as? String {
        case "abort":
            XiaozhiVoicePreferences.shared.cancelStreams()
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
        guard !isChangingReplyModel else { fail("正在切换回复模型，请稍后再说", id: id); return }
        isBusy = true; lastError = nil
        // Retain the last measured turn while auto-listen starts another one.
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
            closeConversation(id)
            return false
        }
        return true
    }

    private func process(wav: Data, id: UUID, generation: UUID) async {
        let startedAt = ProcessInfo.processInfo.systemUptime
        var timing = XiaozhiReplyTiming()
        defer {
            isBusy = false; turnTask = nil
            if UIApplication.shared.applicationState != .active {
                closeConversation(id)
            } else {
                endBackgroundTask()
                if let mode = pendingListenMode, connectionID == id { startCapture(mode: mode, id: id) }
            }
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
            let recognizedAt = ProcessInfo.processInfo.systemUptime
            timing.recognition = recognizedAt - startedAt
            let text = recognition.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw XiaozhiError.message("没有听清，请按 OK 再说一次") }
            lastTranscript = text
            try await send("stt", id: id, fields: ["text": text])
            status = "小冠正在回复"
            let reply = try await agentReply(text, id: id, generation: generation)
            guard current(id, generation) else { return }
            let repliedAt = ProcessInfo.processInfo.systemUptime
            timing.model = repliedAt - recognizedAt
            if let sid = sessionID {
                timing.modelName = ViewModelCache.shared.get(for: sid)?.resolveCurrentEntry()?.model.displayName ?? ""
            }
            lastReply = reply
            let spoken = VoiceTextSanitizer.sanitize(String(reply.prefix(500)))
            guard !spoken.isEmpty else { throw XiaozhiError.message("回复没有可朗读的文字，请在手机查看") }
            status = "正在生成声音"
            var firstAudioAt: TimeInterval?
            var clock: XiaozhiPlaybackClock?
            var packetCount = 0
            func play(_ packet: Data) async throws {
                guard self.current(id, generation) else { throw CancellationError() }
                if packetCount == 0 {
                    if firstAudioAt == nil {
                        firstAudioAt = ProcessInfo.processInfo.systemUptime
                        timing.voice = firstAudioAt! - repliedAt
                    }
                    try await self.send("llm", id: id, fields: ["emotion": "neutral"])
                    try await self.send("tts", id: id, fields: ["state": "sentence_start", "text": spoken])
                    self.status = "小智正在播放"
                    try await Task.sleep(nanoseconds: 80_000_000)
                    clock = XiaozhiPlaybackClock(now: ProcessInfo.processInfo.systemUptime)
                }
                let deadline = clock!.deadline(for: packetCount, now: ProcessInfo.processInfo.systemUptime)
                let delay = deadline - ProcessInfo.processInfo.systemUptime
                if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                guard self.current(id, generation) else { throw CancellationError() }
                try await self.bluetooth.send(packet, binary: true)
                if packetCount == 0 {
                    timing.preparation = ProcessInfo.processInfo.systemUptime - firstAudioAt!
                    self.lastReplyTiming = timing
                }
                packetCount += 1
            }
            let streamed = try await XiaozhiVoicePreferences.shared.stream(spoken, onPacket: play)
            if !streamed {
                let audio = try await XiaozhiVoicePreferences.shared.synthesize(spoken)
                guard current(id, generation) else { return }
                firstAudioAt = ProcessInfo.processInfo.systemUptime
                timing.voice = firstAudioAt! - repliedAt
                let packets = try await Task.detached(priority: .userInitiated) {
                    let pcm = try XiaozhiAudioCodec.pcmFromAudio(audio)
                    return try XiaozhiAudioCodec().encode(pcm)
                }.value
                for packet in packets { try await play(packet) }
            }
            guard let clock, packetCount > 0 else { throw XiaozhiError.message("回复没有可播放的音频") }
            let drain = clock.drainDeadline(packetCount: packetCount) - ProcessInfo.processInfo.systemUptime
            if drain > 0 { try await Task.sleep(nanoseconds: UInt64(drain * 1_000_000_000)) }
            guard current(id, generation) else { return }
            completedTurns += 1
            logger.info("Device voice turn completed (count=\(self.completedTurns))")
            // A listen.start racing this send is retained in pendingListenMode;
            // the defer releases serialization and starts that capture.
            try await send("tts", id: id, fields: ["state": "stop"])
            status = "本轮已结束"
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
            let preferredEntry = try replyModelEntryID.map { try replyModelEntry($0) }
            vm = ViewModelCache.shared.createDraft(); vm.sessionSource = "device"
            let createdID = await vm.ensureSessionReturningId(makeActive: false)
            sessionID = createdID; UserDefaults.standard.set(createdID, forKey: "xiaozhi.sessionID")
            if let preferredEntry { try await bindReplyModel(preferredEntry, to: vm, sessionID: createdID) }
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
        guard bluetooth.isReady, connectionID == id else { throw XiaozhiError.message("小智已断开") }
        var payload = fields; payload["type"] = type; payload["session_id"] = id.uuidString
        try await bluetooth.send(JSONSerialization.data(withJSONObject: payload))
    }

    private func fail(_ message: String, id: UUID) {
        guard connectionID == id else { return }
        lastError = message; status = "请检查后按 OK 重新连接"
        turnGeneration = UUID(); capture?.cancel(); capture = nil; captureID = nil; pendingListenMode = nil
        Task {
            try? await send("alert", id: id, fields: ["status": "小冠连接", "emotion": "sad",
                                                    "message": "请检查手机后按 OK 重新连接"])
            closeConversation(id)
        }
    }
}
