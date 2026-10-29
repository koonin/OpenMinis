import Foundation

// Compile with DoubaoVoiceCatalog.swift and XiaozhiVoiceChoice.swift; no credentials or paid synthesis.
@main
struct CatalogChecks {
    static func main() {
        let voices = DoubaoVoiceCatalog.voices
        // Independently checked against the two official TTS 2.0 HTML tables on 2026-10-29.
        precondition(voices.count == 294 + 172)
        precondition(Set(voices.map(\.id)).count == voices.count)
        precondition(voices.filter(\.isChinese).count == 276)
        precondition(voices.allSatisfy { $0.id.contains("_uranus_") })
        for id in ["zh_female_xiaohe_uranus_bigtts", "zh_female_cancan_uranus_bigtts",
                   "zh_female_vv_uranus_bigtts", "zh_male_liufei_uranus_bigtts", "zh_male_m191_uranus_bigtts"] {
            precondition(DoubaoVoiceCatalog.byID[id] != nil, "Previous choice removed: " + id)
        }
        precondition(DoubaoVoiceCatalog.byID["zh_female_wanwanxiaohe_moon_bigtts"] == nil,
                     "Legacy voice must not be relabeled as 2.0")
        let choices = voices.map {
            XiaozhiVoiceChoice(id: "entry:fixture/" + $0.id, name: $0.name,
                              detail: $0.language + " · " + $0.scene,
                              group: $0.isChinese ? .doubaoChinese : .doubaoInternational,
                              providerName: "测试供应商")
        }
        let xiaohe = choices.filter { $0.matches("  小何   粤语 \n") }
        precondition(xiaohe.contains { $0.id.hasSuffix("/zh_female_xiaohe_uranus_bigtts") })
        precondition(choices.contains { $0.matches("vIVi 2.0 测试供应商") })
        precondition(choices.contains { $0.matches("客服") })
        precondition(choices.contains { $0.matches("日语") || $0.matches("日文") })
        precondition(choices.filter { $0.matches("小何 不存在的场景_987654") }.isEmpty)
        precondition(choices.filter { $0.matches(" \n ") }.count == voices.count)
        print("Catalog checks passed: 466 unique voices, prior choices preserved, version separation and search verified")
    }
}
