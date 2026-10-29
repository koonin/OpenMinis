import SwiftUI

/// Search and presentation only; choosing never starts synthesis or changes a chat voice.
struct XiaozhiVoicePicker: View {
    let choices: [XiaozhiVoiceChoice]
    @Binding var selection: String
    let isBusy: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var category = "全部"

    private var visibleGroups: [(group: XiaozhiVoiceChoice.Group, choices: [XiaozhiVoiceChoice])] {
        let filtered = choices.filter { (category == "全部" || $0.group.rawValue == category) && $0.matches(query) }
        let grouped = Dictionary(grouping: filtered, by: \.group)
        return XiaozhiVoiceChoice.Group.allCases.compactMap { group in
            guard let rows = grouped[group], !rows.isEmpty else { return nil }
            return (group, rows)
        }
    }

    var body: some View {
        let groups = visibleGroups
        List {
            Section {
                Picker("分类", selection: $category) {
                    Text("全部").tag("全部")
                    ForEach(XiaozhiVoiceChoice.Group.allCases.filter { group in choices.contains { $0.group == group } }) { group in
                        Text(group.rawValue).tag(group.rawValue)
                    }
                }
                .accessibilityIdentifier("xiaozhi.voiceCategory")
            } footer: {
                Text("目录包含官方语音合成 2.0 音色，可用音色以当前项目权限和试听为准。")
            }
            if groups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.title).foregroundStyle(.secondary)
                    Text("没有找到音色").font(.headline)
                    Text("试试其他名称、语言或场景，或将分类改为“全部”。")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 24)
                .listRowBackground(Color.clear)
            }
            ForEach(groups, id: \.group) { section in
                Section("\(section.group.rawValue) · \(section.choices.count)") {
                    ForEach(section.choices) { choice in
                        Button {
                            guard !isBusy else { return }
                            selection = choice.id
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(choice.name).foregroundStyle(.primary)
                                    if !choice.detail.isEmpty {
                                        Text(choice.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    if !choice.providerName.isEmpty {
                                        Text(choice.providerName).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 8)
                                if selection == choice.id {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                        .accessibilityLabel("已选择")
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isBusy)
                        .accessibilityIdentifier("xiaozhi.voiceChoice." + choice.id)
                        .accessibilityAddTraits(selection == choice.id ? [.isSelected] : [])
                    }
                }
            }
        }
        .navigationTitle("回复音色")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索音色、语言或场景")
        .accessibilityIdentifier("xiaozhi.voiceSearchList")
    }
}

struct XiaozhiVoicePicker_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            XiaozhiVoicePicker(choices: DoubaoVoiceCatalog.voices.map {
                XiaozhiVoiceChoice(id: $0.id, name: $0.name, detail: $0.language + " · " + $0.scene,
                                  group: $0.isChinese ? .doubaoChinese : .doubaoInternational,
                                  providerName: "Doubao (Volcano)")
            }, selection: .constant("zh_female_xiaohe_uranus_bigtts"), isBusy: false)
        }
    }
}
