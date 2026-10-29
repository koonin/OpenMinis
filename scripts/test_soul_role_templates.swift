// swiftc src/ios/Views/Settings/SoulRoleTemplate.swift scripts/test_soul_role_templates.swift -o /tmp/test_soul_roles && /tmp/test_soul_roles
import Foundation

@main
struct SoulRoleTemplateTests {
    static func main() {
        let all = SoulRoleTemplate.all
        let console = all.filter(\.isConsoleRole)
        precondition(console.count == 160)
        precondition(all.count == 163)
        precondition(Set(console.map(\.language)).count == 39)
        precondition(console.filter { $0.language == "普通话" }.count == 55)
        precondition(Set(all.map(\.id)).count == all.count, "IDs must remain unique across language variants")
        precondition(all.allSatisfy { !$0.body.isEmpty && !$0.style.isEmpty && !$0.summary.isEmpty })
        // This conservative character limit is below the editor's 2,000-token limit.
        precondition(all.allSatisfy { $0.body.utf16.count <= 2_000 })
        precondition(console.allSatisfy { $0.category != .general })
        precondition(!console.contains { ["内测 · 晓双 多语言", "内测 · 晓悠 多语言", "内测 · Macerio Multilingual", "粤语女声"].contains($0.name) })

        precondition(SoulRoleTemplate.filtered(query: "  ").count == all.count)
        precondition(SoulRoleTemplate.filtered(query: "小何").map(\.id) == ["taiwan-friend", "wanwan-v2"])
        precondition(SoulRoleTemplate.filtered(query: "台灣知心朋友").map(\.id) == ["taiwan-friend"])
        precondition(SoulRoleTemplate.filtered(query: "ＶＩＶＩ").map(\.id) == ["vivi"])
        precondition(SoulRoleTemplate.filtered(query: "voix feminine").map(\.id) == ["female-fr"])
        precondition(SoulRoleTemplate.filtered(query: "SkYe 英语").map(\.id) == ["skye-en"])
        precondition(SoulRoleTemplate.filtered(query: "粤语", category: .dialects, language: "粤语").count == 3)
        precondition(SoulRoleTemplate.filtered(query: "不存在的角色xyz").isEmpty)
        precondition(SoulRoleTemplate.filtered(query: "", category: .general, language: "英语").isEmpty)
        precondition(SoulRoleTemplate.filtered(query: "", category: .general).count == 3)

        // Czech/Slovak and Spanish/Portuguese reuse labels in the console.
        // Their language filters and draft matching must remain unambiguous.
        for (name, languages) in [("mužský hlas (Male Voice)", ["捷克语", "斯洛伐克语"]),
                                  ("voz masculina (Male Voice)", ["西班牙语", "葡萄牙语"])] {
            let variants = all.filter { $0.name == name }
            precondition(variants.count == 2 && Set(variants.map(\.language)) == Set(languages))
            for variant in variants {
                precondition(SoulRoleTemplate.filtered(query: name, language: variant.language).map(\.id) == [variant.id])
            }
        }
        for role in all {
            precondition(SoulRoleTemplate.matching(style: role.style, body: role.body)?.id == role.id)
        }
        precondition(SoulRoleTemplate.matching(style: "自定义", body: "用户自己的角色") == nil)
        let originalTaiwan = all.first { $0.id == "taiwan-friend" }!
        precondition(originalTaiwan.style == "亲切、细腻、轻松口语化，偶尔使用自然的台湾语气词。")
        precondition(originalTaiwan.body.hasPrefix("## 性格与关系\n以知心朋友的方式"))
        print("PASS: 160 console roles / 39 languages, legacy matching, search, combined filters, language variants and prompt limits")
    }
}
