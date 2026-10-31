import SwiftUI
import AVFoundation

struct XiaozhiDeviceSettingsView: View {
    @ObservedObject private var service = XiaozhiDeviceService.shared
    @ObservedObject private var voice = XiaozhiVoicePreferences.shared
    @ObservedObject private var providers = ProviderConfigStore.shared
    @State private var starting = false
    @State private var previewTask: Task<Void, Never>?
    @State private var previewURL: URL?
    @State private var previewError: String?
    @State private var voiceChoices: [XiaozhiVoicePreferences.Choice] = []

    var body: some View {
        Form {
            Section {
                Toggle("连接小智设备", isOn: Binding(get: { service.isEnabled }, set: { enabled in
                    if enabled {
                        starting = true
                        Task { await service.enable(); starting = false }
                    } else { service.disable() }
                }))
                .disabled(starting)
                .accessibilityIdentifier("xiaozhi.connectionToggle")
                HStack {
                    Text("对话状态")
                    Spacer()
                    if starting || service.isBusy { ProgressView() }
                    Text(service.status).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                if let error = service.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                        .accessibilityIdentifier("xiaozhi.lastError")
                }
            } footer: {
                Text("小智与这台 iPhone 通过蓝牙传输语音，无需使用 Wi-Fi 或热点连接。手机仍需通过蜂窝网络或 Wi-Fi 访问模型服务。")
            }

            Section {
                LabeledContent("连接方式", value: "蓝牙语音")
                LabeledContent("蓝牙状态", value: service.bluetoothStatus)
            } footer: {
                Text("需要纯蓝牙语音固件。打开小冠，等蓝牙显示已连接后即可按小智 OK 对话，也可尝试锁屏使用。长时间任务可能需要打开小冠；强制退出后请重新打开。")
            }

            Section {
                NavigationLink {
                    XiaozhiReplyModelPicker(service: service)
                } label: {
                    LabeledContent("回复模型", value: replyModelName)
                }
                .disabled(!service.canChangeReplyModel)
                .accessibilityIdentifier("xiaozhi.replyModelPicker")
            } header: { Text("小冠的回复") }
            footer: {
                Text("只更改小智使用的模型，选择会保留到新对话。切换后优先快速回复，采用模型允许的最低思考强度；复杂任务可在小智会话中调整。控制台音色保持原设置。")
            }

            Section {
                NavigationLink {
                    XiaozhiVoicePicker(choices: voiceChoices, selection: $voice.selection, isBusy: service.isBusy)
                } label: {
                    LabeledContent("回复音色", value: voiceChoices.first(where: { $0.id == voice.selection })?.label ?? "原音色不可用，请重新选择")
                }
                .disabled(service.isBusy || previewTask != nil)
                .accessibilityIdentifier("xiaozhi.voicePicker")
                if let serviceName = voice.volcanoServiceName {
                    LabeledContent("所需语音服务", value: serviceName)
                }
                if voice.selection == "xiaozhi-console" {
                    Link("在小智控制台调整音色和语速", destination: URL(string: "https://xiaozhi.me/console/agents")!)
                } else {
                    HStack {
                        Text("语速")
                        Slider(value: $voice.speed, in: 0.8...1.3, step: 0.05)
                            .accessibilityLabel("小智回复语速")
                        Text(String(format: "%.2f 倍", voice.speed)).monospacedDigit()
                    }
                }
                Button {
                    stopPreview()
                    previewTask = Task { await previewVoice() }
                } label: {
                    HStack {
                        Label("在手机试听", systemImage: "speaker.wave.2")
                        if previewTask != nil { Spacer(); ProgressView() }
                    }
                }
                .disabled(previewTask != nil || service.isBusy)
                .accessibilityIdentifier("xiaozhi.previewVoice")
                if let previewError { Text(previewError).font(.footnote).foregroundStyle(.red) }
            } header: { Text("小智的声音") }
            footer: {
                if voice.selection == "xiaozhi-console" {
                    Text("回复由小冠生成，使用这台小智在 xiaozhi.me 绑定的音色，无需另配语音账号。本轮待朗读文字会发送给小智后台；逐句核对后播放，后续改写或中断时会停止，可能只听到前半段，原回复仍保留在小冠。后台中转仍需要等待。")
                } else if let serviceName = voice.volcanoServiceName {
                    Text("当前音色需要在 API Key 所属项目开通\(serviceName)。回复由小冠生成，火山语音直接合成声音，收到后即在小智播放。")
                } else {
                    Text("仅修改小智的回复。星号为已下载的增强或优质系统音色；也可使用自己配置的云端语音服务。若要沿用 xiaozhi.me 的音色，请选择“小智控制台音色（实验）”。试听使用相同的音频转换，最终音质以小智扬声器为准。")
                }
            }

            Section("语音与会话") {
                LabeledContent("语音识别", value: VoiceProviderResolver.inputModelLabel())
                LabeledContent("本次完成对话", value: String(service.completedTurns))
                if service.sessionID != nil {
                    Button {
                        guard let id = service.sessionID else { return }
                        NotificationNavigationStore.shared.setPending(id)
                        NotificationCenter.default.post(name: .openSessionFromIntent, object: nil,
                                                        userInfo: ["sessionId": id, "source": "xiaozhi"])
                    } label: {
                        Label("打开小智会话", systemImage: "bubble.left.and.bubble.right")
                    }
                }
                Button { service.newConversation() } label: {
                    Label("开始一段新对话", systemImage: "plus.bubble")
                }
                    .disabled(service.isBusy || service.isChangingReplyModel)
            }
            Section {
                if let timing = service.lastReplyTiming {
                    LabeledContent("首次出声等待", value: seconds(timing.total))
                    LabeledContent("语音识别", value: seconds(timing.recognition))
                    LabeledContent("首段回复", value: seconds(timing.model))
                    LabeledContent("生成声音", value: seconds(timing.voice))
                    LabeledContent("播放准备", value: seconds(timing.preparation))
                    if let ready = timing.answerReady { LabeledContent("完整回复就绪", value: seconds(ready)) }
                    if !timing.modelName.isEmpty { LabeledContent("本轮模型", value: timing.modelName) }
                } else {
                    Text("完成一轮对话后显示各阶段耗时")
                        .foregroundStyle(.secondary)
                }
            } header: { Text("最近一次等待") }
            footer: { Text("首次出声等待从结束收音算到发出首段音频，实际出声还会有少量播放缓冲。查询时可先播说明，完整结果仍需等待；完整回复就绪记录整轮处理完成的时间。记录仅保留在本次打开期间。") }
            .accessibilityIdentifier("xiaozhi.replyTiming")
            if !service.lastTranscript.isEmpty || !service.lastReply.isEmpty {
                Section("最近一轮") {
                    if !service.lastTranscript.isEmpty { LabeledContent("你说", value: service.lastTranscript) }
                    if !service.lastReply.isEmpty { Text(service.lastReply).textSelection(.enabled) }
                }
            }
            Section {
                if let id = service.deviceID { LabeledContent("已配对设备", value: id) }
            } footer: {
                Text("升级会保留已有设备配对。停止连接或打断播放不会撤销已经交给小冠的任务，任务进度可在小智会话中查看。换手机需要重新配对。")
            }
        }
        .navigationTitle("小智设备")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { voiceChoices = voice.choices }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            voiceChoices = voice.choices
        }
        .onChange(of: providers.config) { _ in voiceChoices = voice.choices }
        .onChange(of: voice.selection) { _ in previewError = nil }
        .onDisappear { stopPreview() }
    }

    private var replyModelName: String {
        if service.sessionID == nil, let id = service.replyModelEntryID {
            return providers.entry(for: id)?.model.displayName ?? "原模型不可用，请重新选择"
        }
        return SessionModelDisplay(store: providers).resolvedDetail(for: service.sessionID)?.modelName ?? "跟随默认模型"
    }

    private func seconds(_ value: TimeInterval) -> String { String(format: "%.1f 秒", value) }

    private func stopPreview() {
        if previewTask != nil, voice.selection == "xiaozhi-console" { XiaozhiConsoleRelay.shared.cancel() }
        previewTask?.cancel(); previewTask = nil
        if let previewURL {
            if GlobalAudioPlayer.shared.isActive(url: previewURL) { GlobalAudioPlayer.shared.stop() }
            try? FileManager.default.removeItem(at: previewURL)
        }
        previewURL = nil
    }

    @MainActor
    private func previewVoice() async {
        defer { previewTask = nil }
        previewError = nil
        do {
            let audio = try await voice.synthesize("你好，我是小冠。今天想聊点什么？我们可以慢慢说，不用着急。")
            let wav = try await Task.detached(priority: .userInitiated) {
                try XiaozhiProtocol.wav(pcm: XiaozhiAudioCodec.pcmFromAudio(audio))
            }.value
            try Task.checkCancellation()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("xiaozhi-preview-\(UUID()).wav")
            try wav.write(to: url, options: .atomic)
            previewURL = url
            GlobalAudioPlayer.shared.play(url: url)
        } catch is CancellationError { }
        catch { if !Task.isCancelled { previewError = error.localizedDescription } }
    }
}

private struct XiaozhiReplyModelPicker: View {
    @ObservedObject var service: XiaozhiDeviceService
    @ObservedObject private var providers = ProviderConfigStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selectionError: String?

    private var currentEntryID: String? {
        if let sid = service.sessionID, let binding = providers.binding(for: sid) {
            switch binding.primarySource {
            case .directEntry(let id, _): return id
            case .group(_, let id): return id
            }
        }
        return service.replyModelEntryID
    }

    var body: some View {
        UnifiedModelPicker(config: .init(
            title: "小智回复模型",
            mode: .single,
            groupScope: .none,
            candidateFilter: { $0.model.capabilities.supportedModalities.contains(.textOutput) },
            isDisabled: { entry in
                guard let provider = providers.instance(for: entry.providerInstanceId) else { return true }
                return !provider.isEnabled || !provider.hasAnyCredential
            },
            headerNote: "使用小冠里已配置的模型，仅更改小智对话。切换后优先快速回复。",
            showGroups: false,
            dismissOnSelect: false,
            currentEntryId: { currentEntryID },
            onSelect: { entry in
                Task {
                    do { try await service.selectReplyModel(entry.id); dismiss() }
                    catch is CancellationError { }
                    catch { selectionError = error.localizedDescription }
                }
            }
        ))
        .disabled(!service.canChangeReplyModel)
        .overlay {
            if service.isChangingReplyModel { ProgressView("正在切换模型").padding().background(.regularMaterial) }
        }
        .alert("无法切换模型", isPresented: Binding(get: { selectionError != nil }, set: { if !$0 { selectionError = nil } })) {
            Button("好", role: .cancel) { selectionError = nil }
        } message: { Text(selectionError ?? "") }
    }
}

struct XiaozhiDeviceSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack { XiaozhiDeviceSettingsView() }
    }
}
