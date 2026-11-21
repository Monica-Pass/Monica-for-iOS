import MonicaCore
import MonicaStorage
import SwiftUI

/// Steam Guard 导入失败原因。
enum AppSteamImportError: LocalizedError, Equatable {
    case duplicateAccount(String)
    case emptyPayload

    var errorDescription: String? {
        switch self {
        case .duplicateAccount(let account):
            return String(localized: "已存在 Steam 账号 \(account)，本次导入已跳过。")
        case .emptyPayload:
            return String(localized: "没有可导入的 Steam 数据。")
        }
    }
}

// MARK: - 会话状态

extension AppSessionModel {
    /// 与筛选、搜索联动的 Steam 条目列表。
    var filteredSteamEntries: [LocalSteamEntry] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = steamSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return filteredFavoriteEntries(
            steamEntries,
            query: query,
            favoritesOnly: showFavoriteSteamEntriesOnly,
            isFavorite: \.favorite
        ) { entry, query in
            entry.title.localizedCaseInsensitiveContains(query)
                || entry.accountName.localizedCaseInsensitiveContains(query)
                || entry.steamID.localizedCaseInsensitiveContains(query)
                || entry.issuer.localizedCaseInsensitiveContains(query)
                || entry.notes.localizedCaseInsensitiveContains(query)
        }
    }

    /// 详情页 / 列表页共用的 5 位 Steam Guard 验证码。
    func steamGuardCode(for entry: LocalSteamEntry, at date: Date = Date()) -> String {
        (try? SteamGuardGenerator.code(base64Secret: entry.sharedSecret, at: date).code) ?? "-----"
    }

    /// 当前窗口剩余秒数；密钥无效时回落 0。
    func steamGuardRemainingSeconds(for entry: LocalSteamEntry, at date: Date = Date()) -> Int {
        guard SteamSharedSecretValidator.isValid(entry.sharedSecret) else {
            return 0
        }
        return SteamGuardGenerator.remainingSeconds(at: date)
    }

    func createSteamEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project = try ensureActiveProject(projectTitle: projectTitle, entryRepository: entryRepository)
            let entry = try entryRepository.createSteamEntry(
                projectID: project.id,
                draft: newSteamDraft()
            )
            // 密钥只保留在编辑态与加密 Vault 中，草稿字段立刻清空。
            steamSharedSecret = ""
            steamEntries = try entryRepository.listSteamEntries(projectID: project.id)
            deletedSteamEntries = try entryRepository.listDeletedSteamEntries(projectID: project.id)
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .steam,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func selectSteamEntryForEditing(_ entry: LocalSteamEntry) {
        recordUserActivity()
        editingSteamEntryID = entry.id
        editingSteamTitle = entry.title
        editingSteamAccountName = entry.accountName
        editingSteamID = entry.steamID
        editingSteamSharedSecret = entry.sharedSecret
        editingSteamIssuer = entry.issuer
        editingSteamNotes = entry.notes
        editingSteamFavorite = entry.favorite
    }

    func updateSelectedSteamEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingSteamEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let entry = try entryRepository.updateSteamEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalSteamEntryDraft(
                    title: editingSteamTitle,
                    accountName: editingSteamAccountName,
                    steamID: editingSteamID,
                    sharedSecret: editingSteamSharedSecret,
                    issuer: editingSteamIssuer,
                    notes: editingSteamNotes
                )
            )
            steamEntries = try entryRepository.listSteamEntries(projectID: projectID)
            deletedSteamEntries = try entryRepository.listDeletedSteamEntries(projectID: projectID)
            selectSteamEntryForEditing(entry)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .steam,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedSteamFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingSteamEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setSteamEntryFavorite(projectID: projectID, entryID: entryID, favorite: favorite)
            steamEntries = try entryRepository.listSteamEntries(projectID: projectID)
            selectSteamEntryForEditing(updated)
            entryOperationState = .succeeded(
                favorite ? String(localized: "已收藏 \(updated.title)") : String(localized: "已取消收藏 \(updated.title)")
            )
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedSteamEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingSteamEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingSteamTitle
            try entryRepository.deleteSteamEntry(projectID: projectID, entryID: entryID)
            steamEntries = try entryRepository.listSteamEntries(projectID: projectID)
            deletedSteamEntries = try entryRepository.listDeletedSteamEntries(projectID: projectID)
            clearEditingSteamEntry()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .steam,
                itemID: entryID,
                itemTitle: deletedTitle
            )
            entryOperationState = .succeeded(String(localized: "已删除 \(deletedTitle)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func restoreSteamEntry(_ entry: LocalSteamEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreSteamEntry(projectID: projectID, entryID: entry.id)
            steamEntries = try entryRepository.listSteamEntries(projectID: projectID)
            deletedSteamEntries = try entryRepository.listDeletedSteamEntries(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .steam,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded(String(localized: "已恢复 \(restored.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func clearEditingSteamEntry() {
        editingSteamEntryID = nil
        editingSteamTitle = ""
        editingSteamAccountName = ""
        editingSteamID = ""
        editingSteamSharedSecret = ""
        editingSteamIssuer = "Steam"
        editingSteamNotes = ""
        editingSteamFavorite = false
    }

    func presentEditEditor(for entry: LocalSteamEntry) {
        selectSteamEntryForEditing(entry)
        presentedEditorMode = .edit(VaultItemRoute(kind: .steam, entryID: entry.id))
    }

    /// 导入 maFile / SDA 导出 JSON / `steamguard://` 链接，只填充新建草稿，不落库。
    ///
    /// - Returns: 导入到的 Steam 账号名，便于 UI 提示。
    @discardableResult
    func importSteamGuard(text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppSteamImportError.emptyPayload
        }

        let draft = try SteamGuardImportParser.parse(text: trimmed)
        if let existing = steamEntries.first(where: { entry in
            entry.accountName.caseInsensitiveCompare(draft.accountName) == .orderedSame
                && SteamSharedSecretValidator.normalizedBase64(entry.sharedSecret)
                    == SteamSharedSecretValidator.normalizedBase64(draft.sharedSecretBase64)
        }) {
            throw AppSteamImportError.duplicateAccount(existing.accountName.isEmpty ? existing.title : existing.accountName)
        }

        steamTitle = draft.suggestedTitle
        steamAccountName = draft.accountName
        steamID = draft.steamID
        steamSharedSecret = SteamSharedSecretValidator.normalizedBase64(draft.sharedSecretBase64)
        steamIssuer = draft.issuer.isEmpty ? "Steam" : draft.issuer
        entryOperationState = .succeeded(String(localized: "已读取 \(draft.suggestedTitle)"))
        return draft.accountName
    }

    /// 详情页展示用字段（不含密钥）。
    func steamDetailRows(for entry: LocalSteamEntry) -> [AppExtensionCapabilityRow] {
        [
            steamDetailRow(id: "title", title: String(localized: "标题"), value: entry.title),
            steamDetailRow(id: "account", title: String(localized: "账号"), value: entry.accountName),
            steamDetailRow(id: "steamID", title: "SteamID", value: entry.steamID),
            steamDetailRow(id: "issuer", title: String(localized: "签发方"), value: entry.issuer),
            steamDetailRow(id: "notes", title: String(localized: "备注"), value: entry.notes),
            steamDetailRow(
                id: "favorite",
                title: String(localized: "收藏"),
                value: entry.favorite ? String(localized: "是") : String(localized: "否")
            )
        ]
    }

    /// 详情页可复制字段；当前 Steam Guard 只复制验证码，不暴露 shared_secret。
    func steamDetailSecrets(for entry: LocalSteamEntry) -> [String: String] {
        let code = steamGuardCode(for: entry)
        return code.isEmpty ? [:] : ["code": code]
    }

    private func newSteamDraft() -> LocalSteamEntryDraft {
        LocalSteamEntryDraft(
            title: steamTitle,
            accountName: steamAccountName,
            steamID: steamID,
            sharedSecret: steamSharedSecret,
            issuer: steamIssuer,
            notes: steamNotes
        )
    }

    private func steamDetailRow(id: String, title: String, value: String) -> AppExtensionCapabilityRow {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppExtensionCapabilityRow(
            id: id,
            title: title,
            value: trimmed.isEmpty ? String(localized: "空") : value,
            detail: "",
            systemImage: ""
        )
    }
}

// MARK: - 列表卡片

/// Steam 列表条目：显示当前 5 位码与剩余秒数。
struct AndroidSteamListCard: View {
    let entry: LocalSteamEntry
    let code: String
    let remaining: Int

    var body: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.78), cornerRadius: 22) {
            HStack(alignment: .top, spacing: 18) {
                AndroidParityIconTile(systemImage: "shield.lefthalf.filled", fill: AndroidParityPalette.primaryContainer)
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.title.isEmpty ? String(localized: "未命名") : entry.title)
                        .font(.subheadline.weight(.semibold))
                    Text(entry.accountName.isEmpty ? String(localized: "未填写账号") : entry.accountName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(code)
                            .font(.system(.title3, design: .monospaced).weight(.heavy))
                            .foregroundStyle(AndroidParityPalette.textPrimary)
                            .accessibilityLabel(String(localized: "Steam Guard 验证码"))
                        Text(verbatim: "\(remaining)s")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }
                }
                Spacer()
                Image(systemName: entry.favorite ? "heart.fill" : "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(entry.favorite ? AndroidParityPalette.primary : AndroidParityPalette.textSecondary)
            }
        }
    }
}

// MARK: - 详情页实时码

/// 详情页的验证码卡片：5 位码 + 30 秒环 + 复制 + 每秒刷新。
struct SteamGuardCodePanel: View {
    @Bindable var session: AppSessionModel
    let entry: LocalSteamEntry

    @State private var copyFeedback: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let code = session.steamGuardCode(for: entry, at: context.date)
            let remaining = session.steamGuardRemainingSeconds(for: entry, at: context.date)
            let fraction = Double(remaining) / SteamGuardGenerator.period

            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.7), cornerRadius: 22) {
                HStack(spacing: 20) {
                    ZStack {
                        Circle()
                            .stroke(AndroidParityPalette.outline.opacity(0.4), lineWidth: 6)
                        Circle()
                            .trim(from: 0, to: max(0, min(1, fraction)))
                            .stroke(AndroidParityPalette.primary, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(remaining)")
                            .font(.subheadline.weight(.heavy))
                            .foregroundStyle(AndroidParityPalette.textPrimary)
                    }
                    .frame(width: 54, height: 54)
                    .animation(.linear(duration: 1), value: remaining)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(code)
                            .font(.system(size: 34, weight: .heavy, design: .monospaced))
                            .tracking(6)
                            .foregroundStyle(AndroidParityPalette.textPrimary)
                            .accessibilityLabel(String(localized: "Steam Guard 验证码"))
                        Text(entry.accountName.isEmpty ? entry.issuer : entry.accountName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        copyFeedback = session.copySensitiveValueToPasteboard(code).message
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.headline.weight(.bold))
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AndroidParityPalette.primary)
                    .accessibilityLabel(String(localized: "复制 Steam Guard 验证码"))
                }
                if let copyFeedback {
                    Text(copyFeedback)
                        .font(.caption2)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
            }
        }
    }
}

// MARK: - 编辑器字段

struct SteamEntryEditorFields: View {
    @Bindable var session: AppSessionModel
    let isAdding: Bool

    var body: some View {
        VStack(spacing: 18) {
            SteamFormField(icon: "textformat", title: String(localized: "标题"), text: title)
            SteamFormField(icon: "person", title: String(localized: "Steam 账号"), text: accountName)
            SteamFormField(icon: "number", title: "SteamID", text: steamID)
            SteamFormField(icon: "building.2", title: String(localized: "签发方"), text: issuer)
            SteamSecureFormField(
                icon: "key.fill",
                title: String(localized: "shared_secret（base64）"),
                text: sharedSecret
            )
            SteamFormField(icon: "note.text", title: String(localized: "备注"), text: notes)

            if isAdding {
                SteamImportSection(session: session)
            }

            Text("只保存 Steam Guard 的离线 shared_secret，用于本地生成验证码；不会读取登录 cookie、identity_secret，也不会发起任何 Steam 网络请求。")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
        }
    }

    private var title: Binding<String> {
        isAdding ? $session.steamTitle : $session.editingSteamTitle
    }

    private var accountName: Binding<String> {
        isAdding ? $session.steamAccountName : $session.editingSteamAccountName
    }

    private var steamID: Binding<String> {
        isAdding ? $session.steamID : $session.editingSteamID
    }

    private var issuer: Binding<String> {
        isAdding ? $session.steamIssuer : $session.editingSteamIssuer
    }

    private var sharedSecret: Binding<String> {
        isAdding ? $session.steamSharedSecret : $session.editingSteamSharedSecret
    }

    private var notes: Binding<String> {
        isAdding ? $session.steamNotes : $session.editingSteamNotes
    }
}

private struct SteamFormField: View {
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
        .overlay {
            RoundedRectangle(cornerRadius: 16).stroke(AndroidParityPalette.outline, lineWidth: 1.2)
        }
    }
}

private struct SteamSecureFormField: View {
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
        .overlay {
            RoundedRectangle(cornerRadius: 16).stroke(AndroidParityPalette.outline, lineWidth: 1.2)
        }
    }
}

// MARK: - 导入

private struct SteamImportSection: View {
    @Bindable var session: AppSessionModel
    @State private var importFeedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("从 maFile / JSON 导入")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.primary)
            TextEditor(text: $session.steamImportInput)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 96)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(AndroidParityPalette.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16).stroke(AndroidParityPalette.outline, lineWidth: 1.2)
                }
                .accessibilityLabel(String(localized: "Steam maFile 或 steamguard 链接"))
            Button {
                do {
                    let account = try session.importSteamGuard(text: session.steamImportInput)
                    importFeedback = account.isEmpty
                        ? String(localized: "已导入 Steam 数据")
                        : String(localized: "已导入 \(account)")
                } catch {
                    importFeedback = error.localizedDescription
                }
            } label: {
                Label("导入 Steam 数据", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
            if let importFeedback {
                Text(importFeedback)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }
    }
}
