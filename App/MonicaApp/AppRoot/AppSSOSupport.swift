import Foundation
import MonicaStorage
import SwiftUI

/// SSO 条目把「用某个 IdP 登录某站点」这件事记录成一条可检索、可加密保存的元数据。
/// 这里只负责记录与展示：Monica 不会代用户完成第三方 IdP 登录，也不会提取浏览器会话或 OAuth token。
extension AppSessionModel {
    var filteredSSOEntries: [LocalSSOEntry] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = ssoSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return ssoEntries.enumerated()
            .filter { _, entry in
                guard !showFavoriteSSOEntriesOnly || entry.favorite else {
                    return false
                }
                guard !query.isEmpty else {
                    return true
                }
                return entry.title.localizedCaseInsensitiveContains(query)
                    || entry.displayProviderName.localizedCaseInsensitiveContains(query)
                    || entry.accountName.localizedCaseInsensitiveContains(query)
                    || entry.issuer.localizedCaseInsensitiveContains(query)
                    || entry.notes.localizedCaseInsensitiveContains(query)
                    || (entry.sanitizedLoginURL?.host()?.localizedCaseInsensitiveContains(query) ?? false)
            }
            .sorted { lhs, rhs in
                if lhs.element.favorite != rhs.element.favorite {
                    return lhs.element.favorite
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    var ssoLinkableLoginEntries: [LocalLoginEntry] {
        loginEntries
    }

    /// 新建表单里 URL 的问题描述；nil 表示可以保存。
    var ssoCreateFormURLIssue: String? {
        guard !ssoLoginURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return SSOEntryURLValidator.error(for: ssoLoginURL)?.errorDescription
    }

    var ssoEditFormURLIssue: String? {
        guard !editingSSOLoginURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return SSOEntryURLValidator.error(for: editingSSOLoginURL)?.errorDescription
    }

    /// 详情页「打开登录页」用的地址。条目被删除、锁定或地址不合法时都返回 nil，
    /// 保证外部跳转只发生在合法 https/http 地址上，且不会借跳转泄露已锁内容。
    func prepareSSOLoginURL(entryID: String) -> URL? {
        guard vaultState == .unlocked,
              let entry = ssoEntries.first(where: { $0.id == entryID }) else {
            return nil
        }
        return entry.sanitizedLoginURL
    }

    func createSSOEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project = try ensureActiveProject(projectTitle: projectTitle, entryRepository: entryRepository)
            let entry = try entryRepository.createSSOEntry(
                projectID: project.id,
                draft: LocalSSOEntryDraft(
                    title: ssoTitle,
                    provider: ssoProvider,
                    providerName: ssoProviderName,
                    issuer: ssoIssuer,
                    accountName: ssoAccountName,
                    loginURL: ssoLoginURL,
                    linkedLoginEntryID: ssoLinkedLoginEntryID.isEmpty ? nil : ssoLinkedLoginEntryID,
                    notes: ssoNotes,
                    secret: ssoSecret
                )
            )
            ssoSecret = ""
            ssoEntries = try entryRepository.listSSOEntries(projectID: project.id)
            deletedSSOEntries = try entryRepository.listDeletedSSOEntries(projectID: project.id)
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .sso,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func selectSSOEntryForEditing(_ entry: LocalSSOEntry) {
        recordUserActivity()
        editingSSOEntryID = entry.id
        editingSSOTitle = entry.title
        editingSSOProvider = entry.provider
        editingSSOProviderName = entry.providerName
        editingSSOIssuer = entry.issuer
        editingSSOAccountName = entry.accountName
        editingSSOLoginURL = entry.loginURL
        editingSSOLinkedLoginEntryID = entry.linkedLoginEntryID ?? ""
        editingSSONotes = entry.notes
        editingSSOSecret = entry.secret
        editingSSOFavorite = entry.favorite
    }

    func updateSelectedSSOEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingSSOEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let entry = try entryRepository.updateSSOEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalSSOEntryDraft(
                    title: editingSSOTitle,
                    provider: editingSSOProvider,
                    providerName: editingSSOProviderName,
                    issuer: editingSSOIssuer,
                    accountName: editingSSOAccountName,
                    loginURL: editingSSOLoginURL,
                    linkedLoginEntryID: editingSSOLinkedLoginEntryID.isEmpty ? nil : editingSSOLinkedLoginEntryID,
                    notes: editingSSONotes,
                    secret: editingSSOSecret
                )
            )
            ssoEntries = try entryRepository.listSSOEntries(projectID: projectID)
            deletedSSOEntries = try entryRepository.listDeletedSSOEntries(projectID: projectID)
            selectSSOEntryForEditing(entry)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .sso,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedSSOFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingSSOEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setSSOEntryFavorite(projectID: projectID, entryID: entryID, favorite: favorite)
            ssoEntries = try entryRepository.listSSOEntries(projectID: projectID)
            selectSSOEntryForEditing(updated)
            entryOperationState = .succeeded(
                favorite
                    ? String(localized: "已收藏 \(updated.title)")
                    : String(localized: "已取消收藏 \(updated.title)")
            )
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedSSOEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingSSOEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingSSOTitle
            try entryRepository.deleteSSOEntry(projectID: projectID, entryID: entryID)
            ssoEntries = try entryRepository.listSSOEntries(projectID: projectID)
            deletedSSOEntries = try entryRepository.listDeletedSSOEntries(projectID: projectID)
            clearEditingSSOEntry()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .sso,
                itemID: entryID,
                itemTitle: deletedTitle
            )
            entryOperationState = .succeeded(String(localized: "已删除 \(deletedTitle)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func restoreSSOEntry(_ entry: LocalSSOEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreSSOEntry(projectID: projectID, entryID: entry.id)
            ssoEntries = try entryRepository.listSSOEntries(projectID: projectID)
            deletedSSOEntries = try entryRepository.listDeletedSSOEntries(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .sso,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded(String(localized: "已恢复 \(restored.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func clearEditingSSOEntry() {
        editingSSOEntryID = nil
        editingSSOTitle = ""
        editingSSOProvider = .custom
        editingSSOProviderName = ""
        editingSSOIssuer = ""
        editingSSOAccountName = ""
        editingSSOLoginURL = ""
        editingSSOLinkedLoginEntryID = ""
        editingSSONotes = ""
        editingSSOSecret = ""
        editingSSOFavorite = false
    }

    func presentEditEditor(for entry: LocalSSOEntry) {
        selectSSOEntryForEditing(entry)
        presentedEditorMode = .edit(VaultItemRoute(kind: .sso, entryID: entry.id))
    }

    /// 详情页的行数据。账号与备注按敏感字段处理：锁库后条目列表被清空，这些行也就无从读出。
    func ssoDetailRows(for entry: LocalSSOEntry) -> [AppExtensionCapabilityRow] {
        var rows: [AppExtensionCapabilityRow] = [
            ssoDetailRow(id: "title", title: String(localized: "标题"), value: entry.title),
            ssoDetailRow(id: "provider", title: String(localized: "身份提供商"), value: entry.displayProviderName),
            ssoDetailRow(
                id: "issuer",
                title: String(localized: "Issuer"),
                value: entry.sanitizedIssuerURL?.absoluteString ?? String(localized: "未填写")
            ),
            ssoDetailRow(
                id: "account",
                title: String(localized: "账号"),
                value: sensitivePreviewValue(entry.accountName, category: .otherSecret, entryID: entry.id)
            ),
            ssoDetailRow(
                id: "loginURL",
                title: String(localized: "登录地址"),
                value: entry.sanitizedLoginURL?.absoluteString ?? String(localized: "地址不可用")
            ),
            ssoDetailRow(id: "linked", title: String(localized: "关联登录项"), value: ssoLinkedEntryDescription(for: entry))
        ]
        if !entry.notes.isEmpty {
            rows.append(ssoDetailRow(
                id: "notes",
                title: String(localized: "备注"),
                value: sensitivePreviewValue(entry.notes, category: .noteBody, entryID: entry.id)
            ))
        }
        if !entry.secret.isEmpty {
            rows.append(ssoDetailRow(
                id: "secret",
                title: String(localized: "可选凭据"),
                value: sensitivePreviewValue(entry.secret, category: .otherSecret, entryID: entry.id)
            ))
        }
        return rows
    }

    func ssoDetailSecrets(for entry: LocalSSOEntry) -> [String: String] {
        var secrets: [String: String] = [:]
        if !entry.accountName.isEmpty {
            secrets["account"] = entry.accountName
        }
        if !entry.notes.isEmpty {
            secrets["notes"] = entry.notes
        }
        if !entry.secret.isEmpty {
            secrets["secret"] = entry.secret
        }
        return secrets
    }

    private func ssoLinkedEntryDescription(for entry: LocalSSOEntry) -> String {
        guard entry.linkedLoginEntryID != nil else {
            return String(localized: "未关联")
        }
        guard let linked = entry.resolvedLinkedLoginEntry(in: loginEntries) else {
            // 关联项被删除后只降级成提示，不再暴露对方标题或账号。
            return String(localized: "关联登录项已删除")
        }
        return linked.title
    }

    private func ssoDetailRow(id: String, title: String, value: String) -> AppExtensionCapabilityRow {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppExtensionCapabilityRow(
            id: id,
            title: title,
            value: trimmed.isEmpty ? String(localized: "空") : trimmed,
            detail: "",
            systemImage: ""
        )
    }
}

// MARK: - Editor fields

struct SSOEntryEditorFields: View {
    @Bindable var session: AppSessionModel
    let isAdding: Bool

    private var provider: Binding<SSOProvider> {
        isAdding ? $session.ssoProvider : $session.editingSSOProvider
    }

    private var title: Binding<String> {
        isAdding ? $session.ssoTitle : $session.editingSSOTitle
    }

    private var providerName: Binding<String> {
        isAdding ? $session.ssoProviderName : $session.editingSSOProviderName
    }

    private var issuer: Binding<String> {
        isAdding ? $session.ssoIssuer : $session.editingSSOIssuer
    }

    private var accountName: Binding<String> {
        isAdding ? $session.ssoAccountName : $session.editingSSOAccountName
    }

    private var loginURL: Binding<String> {
        isAdding ? $session.ssoLoginURL : $session.editingSSOLoginURL
    }

    private var linkedLoginEntryID: Binding<String> {
        isAdding ? $session.ssoLinkedLoginEntryID : $session.editingSSOLinkedLoginEntryID
    }

    private var notes: Binding<String> {
        isAdding ? $session.ssoNotes : $session.editingSSONotes
    }

    private var secret: Binding<String> {
        isAdding ? $session.ssoSecret : $session.editingSSOSecret
    }

    private var urlIssue: String? {
        isAdding ? session.ssoCreateFormURLIssue : session.ssoEditFormURLIssue
    }

    var body: some View {
        VStack(spacing: 18) {
            SSOFormField(icon: "folder.fill", title: String(localized: "标题 *"), text: title)
            SSOProviderPicker(selection: provider)
            if provider.wrappedValue == .custom {
                SSOFormField(icon: "building.2.fill", title: String(localized: "自定义 IdP 名称"), text: providerName)
            }
            SSOFormField(icon: "checkmark.seal.fill", title: String(localized: "Issuer（https）"), text: issuer)
            SSOFormField(icon: "person.fill", title: String(localized: "账号"), text: accountName)
            SSOFormField(icon: "link", title: String(localized: "登录地址"), text: loginURL)
            if let urlIssue {
                Text(urlIssue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            SSOLinkedLoginPicker(
                selection: linkedLoginEntryID,
                entries: session.ssoLinkableLoginEntries
            )
            SSOFormField(icon: "note.text", title: String(localized: "备注"), text: notes)
            SSOSecureFormField(icon: "key.horizontal.fill", title: String(localized: "可选凭据（加密保存）"), text: secret)
            Text("只记录 SSO 配置用于查阅与打开登录页。Monica 不会代替你完成第三方登录，也不会读取浏览器 cookie 或 OAuth token。")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SSOProviderPicker: View {
    @Binding var selection: SSOProvider

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "person.badge.key.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .frame(minWidth: 34)
            Picker(String(localized: "身份提供商"), selection: $selection) {
                ForEach(SSOProvider.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.menu)
            .tint(AndroidParityPalette.primary)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 58)
        .background(AndroidParityPalette.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(AndroidParityPalette.outline, lineWidth: 1.2) }
    }
}

struct SSOLinkedLoginPicker: View {
    @Binding var selection: String
    let entries: [LocalLoginEntry]

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "link.badge.plus")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .frame(minWidth: 34)
            Picker(String(localized: "关联登录项"), selection: $selection) {
                Text(String(localized: "不关联")).tag("")
                ForEach(entries) { entry in
                    Text(entry.title).tag(entry.id)
                }
            }
            .pickerStyle(.menu)
            .tint(AndroidParityPalette.primary)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 58)
        .background(AndroidParityPalette.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(AndroidParityPalette.outline, lineWidth: 1.2) }
    }
}

struct SSOFormField: View {
    let icon: String
    let title: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .frame(minWidth: 34)
            TextField(title, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 58)
        .background(AndroidParityPalette.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(AndroidParityPalette.outline, lineWidth: 1.2) }
    }
}

struct SSOSecureFormField: View {
    let icon: String
    let title: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .frame(minWidth: 34)
            SecureField(title, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 58)
        .background(AndroidParityPalette.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(AndroidParityPalette.outline, lineWidth: 1.2) }
    }
}

// MARK: - List and detail accessories

struct AndroidSSOListCard: View {
    let entry: LocalSSOEntry

    var body: some View {
        AndroidExtendedSecretListCard(
            icon: "person.badge.key.fill",
            title: entry.title,
            primary: entry.displayProviderName,
            secondary: entry.sanitizedLoginURL?.host() ?? entry.accountName,
            favorite: entry.favorite
        )
    }
}

struct SSOLoginLinkSection: View {
    @Bindable var session: AppSessionModel
    let entry: LocalSSOEntry

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                if let url = session.prepareSSOLoginURL(entryID: entry.id) {
                    _ = openURL(url)
                }
            } label: {
                Label("打开登录页", systemImage: "safari")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
            .disabled(entry.sanitizedLoginURL == nil)

            if let issue = SSOEntryURLValidator.error(for: entry.loginURL)?.errorDescription {
                Text(issue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.primary)
            }

            Text("Monica 只替你打开 IdP 的正式登录页，不会代填密码，也不会读取第三方会话、cookie 或 token。")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
