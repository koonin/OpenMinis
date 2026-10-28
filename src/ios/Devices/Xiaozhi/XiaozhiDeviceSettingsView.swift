import SwiftUI

struct XiaozhiDeviceSettingsView: View {
    @ObservedObject private var service = XiaozhiDeviceService.shared
    @State private var starting = false
    @State private var showReset = false
    @State private var copied = false

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
                    Text("连接状态")
                    Spacer()
                    if starting || service.isBusy { ProgressView() }
                    Text(service.status).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                if let error = service.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                        .accessibilityIdentifier("xiaozhi.lastError")
                }
            } footer: {
                Text("小智直接连接这台 iPhone。开启后保持小冠在前台，屏幕会保持唤醒；切到其他 App 或锁屏会暂停设备连接。")
            }

            if let address = service.setupURL, service.isRunning {
                Section {
                    Text(address).font(.footnote.monospaced()).textSelection(.enabled)
                        .accessibilityIdentifier("xiaozhi.setupURL")
                    Button {
                        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: address]],
                                                     options: [.localOnly: true])
                        copied = true
                    } label: {
                        Label(copied ? "已复制配网地址" : "复制配网地址", systemImage: "doc.on.doc")
                    }
                    .accessibilityIdentifier("xiaozhi.copySetupURL")
                } header: { Text("第一次连接") }
                footer: {
                    Text("让小智与 iPhone 连同一个 Wi-Fi。在小智配网页，把 OTA 地址改为上面的地址并保存。设备就绪后按 OK 开始说话。此地址用于设备配对，请仅填写到自己的设备。")
                }
            }

            Section("语音与会话") {
                LabeledContent("语音识别", value: VoiceProviderResolver.inputModelLabel())
                LabeledContent("回复音色", value: VoiceProviderResolver.outputModelLabel())
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
                    .disabled(service.isBusy)
            }
            if !service.lastTranscript.isEmpty || !service.lastReply.isEmpty {
                Section("最近一轮") {
                    if !service.lastTranscript.isEmpty { LabeledContent("你说", value: service.lastTranscript) }
                    if !service.lastReply.isEmpty { Text(service.lastReply).textSelection(.enabled) }
                }
            }
            Section {
                if let id = service.deviceID { LabeledContent("已配对设备", value: id) }
                Button("解除设备配对", role: .destructive) { showReset = true }
                    .disabled(service.isBusy || service.deviceID == nil)
            } footer: {
                Text("停止连接或打断播放不会撤销已经交给小冠的任务，任务进度可在小智会话中查看。当前先支持同一 Wi-Fi，个人热点和后台运行尚未验证。")
            }
        }
        .navigationTitle("小智设备")
        .navigationBarTitleDisplayMode(.inline)
        .alert("解除小智配对？", isPresented: $showReset) {
            Button("取消", role: .cancel) {}
            Button("解除配对", role: .destructive) { service.resetPairing() }
        } message: {
            Text("旧配网地址和设备凭据会失效。重新连接时，需要在小智上填写新的配网地址。会话记录保留。")
        }
    }
}

struct XiaozhiDeviceSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack { XiaozhiDeviceSettingsView() }
    }
}
