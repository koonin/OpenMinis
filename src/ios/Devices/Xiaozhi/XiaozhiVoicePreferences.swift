import AVFoundation
import Combine
import Foundation

/// Device-only selection: changing this never changes the chat's voice group.
@MainActor
final class XiaozhiVoicePreferences: ObservableObject {
    static let shared = XiaozhiVoicePreferences()
    @Published var selection: String {
        didSet { UserDefaults.standard.set(selection, forKey: "xiaozhi.voice.selection") }
    }
    @Published var speed: Double {
        didSet { UserDefaults.standard.set(speed, forKey: "xiaozhi.voice.speed") }
    }

    typealias Choice = XiaozhiVoiceChoice

    private init() {
        selection = UserDefaults.standard.string(forKey: "xiaozhi.voice.selection") ?? "follow"
        let stored = UserDefaults.standard.object(forKey: "xiaozhi.voice.speed") as? Double ?? 1
        speed = stored.isFinite ? min(1.3, max(0.8, stored)) : 1
    }

    var choices: [Choice] {
        var result = [Choice(id: "follow", name: "跟随小冠", detail: VoiceProviderResolver.outputModelLabel()),
                      Choice(id: "xiaozhi-console", name: "小智控制台音色（实验）", detail: "沿用 xiaozhi.me 的音色")]
        result += SystemVoiceCatalog.filteredAndSortedVoices().map {
            Choice(id: "system:" + $0.identifier,
                   name: SystemVoiceCatalog.displayName(for: $0), detail: $0.language, group: .system)
        }
        result += availableEntries.filter { !$0.isHidden || "entry:" + $0.id == selection }.map { entry in
            let providerName = ProviderConfigStore.shared.instance(for: entry.providerInstanceId)?.label ?? ""
            let version = volcanoVersion(for: entry)
            let metadata = version == "2.0" ? DoubaoVoiceCatalog.byID[entry.model.id] : nil
            let group: Choice.Group
            if let metadata { group = metadata.isChinese ? .doubaoChinese : .doubaoInternational }
            else if version == "1.0" { group = .doubaoLegacy }
            else { group = .other }
            let name = entry.overrides.displayName ?? (entry.isCustom ? nil : metadata?.name) ?? entry.model.displayName
            return Choice(id: "entry:" + entry.id, name: name,
                          detail: metadata.map { $0.language + " · " + $0.scene } ?? version.map { "语音合成 " + $0 } ?? "",
                          group: group, keywords: entry.model.displayName, providerName: providerName)
        }
        return result
    }

    private var availableEntries: [ModelEntry] {
        let store = ProviderConfigStore.shared
        // Check credentials once per provider, not once for each of hundreds of voices.
        let eligible = Set(store.instances.filter {
            $0.isEnabled && !VoiceProviderResolver.isSystemEntry($0.id) &&
            VoiceProviderFactory.supportsVoice(for: $0) && $0.hasAnyCredential
        }.map(\.id))
        return store.modelEntries.filter { entry in
            eligible.contains(entry.providerInstanceId) && entry.model.isVoiceOutputCandidate
        }
    }

    var volcanoServiceName: String? {
        let entry: ModelEntry?
        if selection == "follow" { entry = VoiceProviderResolver.resolvedOutputEntry() }
        else if selection.hasPrefix("entry:") { entry = ProviderConfigStore.shared.entry(for: String(selection.dropFirst(6))) }
        else { return nil }
        guard let entry, let version = volcanoVersion(for: entry) else { return nil }
        return "语音合成 " + version
    }

    private func volcanoVersion(for entry: ModelEntry) -> String? {
        guard let instance = ProviderConfigStore.shared.instance(for: entry.providerInstanceId),
              let base = instance.effectiveCustomBaseURL,
              URL(string: base)?.host?.lowercased() == "openspeech.bytedance.com" else { return nil }
        return String(DoubaoVoiceProvider.synthesisResourceID(for: entry.model.id).dropFirst("seed-tts-".count))
    }

    func synthesize(_ text: String) async throws -> Data {
        if selection == "xiaozhi-console" { return try await XiaozhiConsoleRelay.shared.synthesize(text) }
        let (provider, request) = try output(text)
        if let volcano = provider as? DoubaoVoiceProvider {
            var pcm = Data()
            try await XiaozhiVolcanoSpeech.shared.stream(volcano.buildPCMStreamRequest(request)) { pcm.append($0) }
            return XiaozhiProtocol.wav(pcm: pcm)
        }
        return try await provider.synthesize(request)
    }

    /// Returns false only for providers which still need whole-file synthesis.
    /// Streaming failures are thrown, never retried as a second paid request.
    func stream(_ text: String, onPacket: @escaping (Data) async throws -> Void) async throws -> Bool {
        if selection == "xiaozhi-console" {
            try await XiaozhiConsoleRelay.shared.stream(text, onPacket: onPacket)
            return true
        }
        let (provider, request) = try output(text)
        guard let volcano = provider as? DoubaoVoiceProvider else { return false }
        let cloudRequest = try volcano.buildPCMStreamRequest(request)
        try await XiaozhiBufferedSpeech.play(produce: { emit in
            let encoder = XiaozhiStreamingEncoder()
            try await XiaozhiVolcanoSpeech.shared.stream(cloudRequest) { pcm in
                for packet in try await encoder.append(pcm) {
                    try Task.checkCancellation()
                    try await emit(packet)
                }
            }
            for packet in try await encoder.finish() {
                try Task.checkCancellation()
                try await emit(packet)
            }
        }, consume: onPacket)
        return true
    }

    func cancelStreams() {
        XiaozhiConsoleRelay.shared.cancel()
        XiaozhiVolcanoSpeech.shared.cancel()
    }

    private func output(_ text: String) throws -> (any VoiceOutputCapable, VoiceOutputRequest) {
        guard !text.isEmpty, text.count <= 500 else { throw XiaozhiError.message("待朗读内容为空或过长") }
        let provider: any VoiceOutputCapable
        var entry: ModelEntry?
        var voice: String?
        if selection == "follow" {
            provider = VoiceProviderResolver.outputProvider()
            entry = VoiceProviderResolver.resolvedOutputEntry()
            voice = entry?.model.id ?? VoiceProviderResolver.resolvedSystemOutputVoiceId()
        } else if selection.hasPrefix("system:") {
            let id = String(selection.dropFirst(7))
            guard AVSpeechSynthesisVoice(identifier: id) != nil else {
                throw XiaozhiError.message("这个系统音色已不可用，请重新选择")
            }
            provider = SystemVoiceProvider.shared
            voice = id
        } else {
            let id = String(selection.dropFirst(6))
            guard selection.hasPrefix("entry:"), let selected = availableEntries.first(where: { $0.id == id }),
                  let resolved = VoiceProviderResolver.outputProvider(for: selected) else {
                throw XiaozhiError.message("这个语音服务已不可用，请检查供应商配置或重新选择音色")
            }
            provider = resolved; entry = selected; voice = selected.model.id
        }
        return (provider, VoiceOutputRequest(
            input: text, model: entry?.model.id, voice: voice,
            speed: Float(min(1.3, max(0.8, speed))), responseFormat: .wav, resolvedModel: entry?.model))
    }
}
