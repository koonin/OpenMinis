import SwiftUI

struct SoulRoleTemplatesView: View {
    @Binding var style: String
    @Binding var bodyText: String
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var category: SoulRoleCategory?
    @State private var language: String?

    var body: some View {
        let roles = SoulRoleTemplate.filtered(query: searchText, category: category, language: language)
        let selectedID = SoulRoleTemplate.matching(style: style, body: bodyText)?.id
        NavigationStack {
            List {
                Section {
                    Picker(AppLocalized("Role Type"), selection: $category) {
                        Text(AppLocalized("All Role Types")).tag(nil as SoulRoleCategory?)
                        ForEach(SoulRoleCategory.allCases) { item in
                            Text(AppLocalized(String.LocalizationValue(item.rawValue))).tag(Optional(item))
                        }
                    }
                    .accessibilityIdentifier("soul.roleCategoryFilter")
                    Picker(AppLocalized("Conversation Language"), selection: $language) {
                        Text(AppLocalized("All Languages")).tag(nil as String?)
                        ForEach(SoulRoleTemplate.languages, id: \.self) { item in
                            Text(item).tag(Optional(item))
                        }
                    }
                    .accessibilityIdentifier("soul.roleLanguageFilter")
                } footer: {
                    Text(String(format: AppLocalized("%lld role templates"), roles.count))
                }

                if roles.isEmpty {
                    Section {
                        Label(AppLocalized("No matching roles"), systemImage: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        Button(AppLocalized("Clear Role Filters")) {
                            searchText = ""
                            category = nil
                            language = nil
                        }
                    }
                }

                ForEach(SoulRoleCategory.allCases) { group in
                    let groupRoles = roles.filter { $0.category == group }
                    if !groupRoles.isEmpty {
                        Section(AppLocalized(String.LocalizationValue(group.rawValue))) {
                            ForEach(groupRoles) { template in
                                NavigationLink {
                                    SoulRoleTemplateDetailView(template: template) {
                                        // The sheet owns dismissal; using the detail's dismiss
                                        // would only pop back to the catalogue.
                                        style = template.style
                                        bodyText = template.body
                                        dismiss()
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(template.name).foregroundStyle(.primary)
                                            Text(template.summary).font(.caption).foregroundStyle(.secondary)
                                            Text(template.language).font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 4)
                                        if template.id == selectedID {
                                            Image(systemName: "checkmark").foregroundStyle(.tint)
                                        }
                                    }
                                }
                                .accessibilityIdentifier("soul.roleTemplate." + template.id)
                                .accessibilityAddTraits(template.id == selectedID ? [.isSelected] : [])
                            }
                        }
                    }
                }
            }
            .navigationTitle(AppLocalized("Role Templates"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: Text(AppLocalized("Search role names, personalities or languages")))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("Cancel")) { dismiss() }
                }
            }
        }
    }
}

private struct SoulRoleTemplateDetailView: View {
    let template: SoulRoleTemplate
    let apply: () -> Void

    var body: some View {
        List {
            Section {
                Text(template.name).font(.headline)
                Text(template.summary)
                LabeledContent(AppLocalized("Conversation Language"), value: template.language)
            }
            Section(AppLocalized("Style")) {
                Text(template.style)
            }
            Section {
                Text(template.body).textSelection(.enabled)
            } header: {
                Text(AppLocalized("Role Description"))
            } footer: {
                if template.isConsoleRole {
                    Text(AppLocalized("Adapted from XiaoZhi console personalities. The role changes personality and wording; choose the voice separately."))
                }
            }
            Section {
                Button(AppLocalized("Apply to Editor"), action: apply)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("soul.applyRoleTemplate.bottom")
            } footer: {
                Text(AppLocalized("Apply a template to the editor, then save to use it in phone chats and XiaoZhi conversations. Your name, avatar and voice stay as configured."))
            }
        }
        .navigationTitle(AppLocalized("Role Details"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(AppLocalized("Apply to Editor"), action: apply)
                    .accessibilityIdentifier("soul.applyRoleTemplate")
            }
        }
    }
}

struct SoulRoleTemplatesView_Previews: PreviewProvider {
    static var previews: some View {
        SoulRoleTemplatesView(style: .constant(""), bodyText: .constant(""))
    }
}
