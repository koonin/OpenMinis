import Foundation

struct XiaozhiVoiceChoice: Identifiable, Equatable {
    enum Group: String, CaseIterable, Identifiable {
        case shortcuts = "快捷选择"
        case doubaoChinese = "豆包 2.0 · 中文"
        case doubaoInternational = "豆包 2.0 · 外语"
        case doubaoLegacy = "豆包 1.0 · 旧版"
        case system = "系统音色"
        case other = "其他云端音色"

        var id: String { rawValue }
    }

    let id: String
    let name: String
    let detail: String
    let group: Group
    let keywords: String
    let providerName: String

    init(id: String, name: String, detail: String = "", group: Group = .shortcuts,
         keywords: String = "", providerName: String = "") {
        self.id = id; self.name = name; self.detail = detail; self.group = group
        self.keywords = keywords; self.providerName = providerName
    }

    var label: String { providerName.isEmpty ? name : name + " · " + providerName }

    func matches(_ query: String) -> Bool {
        let haystack = [name, detail, keywords, providerName, group.rawValue, id].joined(separator: " ")
        return query.split(whereSeparator: \.isWhitespace).allSatisfy {
            haystack.localizedStandardContains(String($0))
        }
    }
}
