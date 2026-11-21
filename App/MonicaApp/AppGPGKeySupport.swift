//
//  AppGPGKeySupport.swift
//  Monica
//
//  GPG 密钥条目（issue #12）：导入解析预览、编辑字段与详情展示。
//
//  边界说明（重要）：
//  - 本文件只做「ASCII armor 结构化解析 + 元数据展示」，解析细节在
//    `SwiftPackages/MonicaStorage/Sources/MonicaStorage/GPGKeyEntry.swift`；
//  - **没有任何签名验证、口令校验、私钥解密或信任判定**，也不生成密钥；
//  - 因此详情页会明确标注「签名验证 / 加密依赖尚未接入」，避免把
//    「指纹对上了」误读成「密钥可信」。
//

import MonicaStorage
import SwiftUI

// MARK: - 编辑器错误

/// 编辑器侧的本地错误：与解析器的 `GPGKeyImportError` 分开，
/// 因为这里的问题不是「armor 不合法」，而是「当前会话状态不允许保存」。
enum AppGPGKeyEditorError: LocalizedError, Equatable {
    case missingImportedKey
    case duplicateFingerprint(String)
    case privateKeyRequiresConfirmation

    var errorDescription: String? {
        switch self {
        case .missingImportedKey:
            return appLocalized("还没有解析出可保存的密钥，请先粘贴 armored 密钥并点「解析」。")
        case .duplicateFingerprint(let title):
            return appLocalized("同一指纹的密钥已存在（\(title)），请勿重复导入。")
        case .privateKeyRequiresConfirmation:
            return appLocalized("私钥块需要先勾选「同时保存私钥」并确认风险，才会写入保险箱。")
        }
    }
}

// MARK: - 会话操作

extension AppSessionModel {
    /// 当前导入输入里是否已经有一个可保存的解析结果。
    var isGPGKeyImportReady: Bool {
        gpgKeyImportPreview != nil && !gpgKeyImportInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 结构化解析导入输入，产出预览；不写库、不联网、不验证签名。
    func parseGPGKeyImportInput() {
        let trimmed = gpgKeyImportInput.trimmingCharacters(in: .whitespacesAndNewlines)
        gpgKeyImportError = nil
        gpgKeyImportPreview = nil
        gpgKeyImportDuplicateEntryID = nil

        guard !trimmed.isEmpty else {
            gpgKeyImportError = GPGKeyImportError.emptyInput.localizedDescription
            return
        }

        do {
            let metadata = try GPGKeyArmorParser.parse(trimmed)
            if metadata.isSecretKey && !gpgKeyImportIncludesPrivateKey {
                // 解析成功但默认不落私钥：明确告诉用户为什么没继续。
                gpgKeyImportError = AppGPGKeyEditorError.privateKeyRequiresConfirmation.localizedDescription
                return
            }
            gpgKeyImportPreview = metadata
            if gpgKeyTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                gpgKeyTitle = metadata.ownerName.isEmpty
                    ? appLocalized("GPG 密钥")
                    : metadata.ownerName
            }
            if let duplicate = gpgKeyEntries.first(where: { $0.fingerprint == metadata.fingerprint }) {
                gpgKeyImportDuplicateEntryID = duplicate.id
            }
        } catch {
            gpgKeyImportError = error.localizedDescription
        }
    }

    /// 离开编辑器或保存成功后复位导入状态，避免下一次打开编辑器看到上一次的残留。
    func resetGPGKeyImportState() {
        gpgKeyTitle = ""
        gpgKeyNotes = ""
        gpgKeyImportInput = ""
        gpgKeyImportIncludesPrivateKey = false
        gpgKeyImportPreview = nil
        gpgKeyImportError = nil
        gpgKeyImportDuplicateEntryID = nil
    }

    func createGPGKeyEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            guard let metadata = gpgKeyImportPreview else {
                throw AppGPGKeyEditorError.missingImportedKey
            }
            let trimmed = gpgKeyImportInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw GPGKeyImportError.emptyInput
            }
            if let duplicate = gpgKeyEntries.first(where: { $0.fingerprint == metadata.fingerprint }) {
                throw AppGPGKeyEditorError.duplicateFingerprint(duplicate.title)
            }
            if metadata.isSecretKey && !gpgKeyImportIncludesPrivateKey {
                throw AppGPGKeyEditorError.privateKeyRequiresConfirmation
            }

            let project = try ensureActiveProject(projectTitle: projectTitle, entryRepository: entryRepository)
            let draft = LocalGPGKeyEntryDraft(
                title: gpgKeyTitle,
                notes: gpgKeyNotes,
                // 公钥块只保存「纯公钥 armor」；私钥块单独存放，复制公钥时不会带出私钥材料。
                armoredPublicKey: metadata.isSecretKey ? "" : trimmed,
                armoredPrivateKey: metadata.isSecretKey ? trimmed : "",
                metadata: metadata
            )
            let entry = try entryRepository.createGPGKeyEntry(projectID: project.id, draft: draft)
            gpgKeyEntries = try entryRepository.listGPGKeyEntries(projectID: project.id)
            deletedGPGKeyEntries = try entryRepository.listDeletedGPGKeyEntries(projectID: project.id)
            resetGPGKeyImportState()
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .gpgKey,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func selectGPGKeyEntryForEditing(_ entry: LocalGPGKeyEntry) {
        recordUserActivity()
        editingGPGKeyEntryID = entry.id
        editingGPGKeyTitle = entry.title
        editingGPGKeyNotes = entry.notes
        editingGPGKeyFavorite = entry.favorite
    }

    /// 编辑只允许改标题/备注/收藏：指纹、算法与密钥材料都是导入时确定的，
    /// 允许原地改会让「指纹」与「实际密钥」脱钩。
    func updateSelectedGPGKeyEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingGPGKeyEntryID,
                  let existing = gpgKeyEntries.first(where: { $0.id == entryID })
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let draft = LocalGPGKeyEntryDraft(
                title: editingGPGKeyTitle,
                notes: editingGPGKeyNotes,
                armoredPublicKey: existing.armoredPublicKey,
                armoredPrivateKey: existing.armoredPrivateKey,
                metadata: existing.metadata,
                importedAt: existing.importedAt
            )
            let entry = try entryRepository.updateGPGKeyEntry(
                projectID: projectID,
                entryID: entryID,
                draft: draft
            )
            gpgKeyEntries = try entryRepository.listGPGKeyEntries(projectID: projectID)
            deletedGPGKeyEntries = try entryRepository.listDeletedGPGKeyEntries(projectID: projectID)
            selectGPGKeyEntryForEditing(entry)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .gpgKey,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedGPGKeyFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingGPGKeyEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setGPGKeyEntryFavorite(
                projectID: projectID,
                entryID: entryID,
                favorite: favorite
            )
            gpgKeyEntries = try entryRepository.listGPGKeyEntries(projectID: projectID)
            selectGPGKeyEntryForEditing(updated)
            entryOperationState = .succeeded(
                favorite
                    ? appLocalized("已收藏 \(updated.title)")
                    : appLocalized("已取消收藏 \(updated.title)")
            )
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedGPGKeyEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingGPGKeyEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingGPGKeyTitle
            try entryRepository.deleteGPGKeyEntry(projectID: projectID, entryID: entryID)
            gpgKeyEntries = try entryRepository.listGPGKeyEntries(projectID: projectID)
            deletedGPGKeyEntries = try entryRepository.listDeletedGPGKeyEntries(projectID: projectID)
            clearEditingGPGKeyEntry()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .gpgKey,
                itemID: entryID,
                itemTitle: deletedTitle
            )
            entryOperationState = .succeeded(appLocalized("已删除 \(deletedTitle)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func restoreGPGKeyEntry(_ entry: LocalGPGKeyEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreGPGKeyEntry(projectID: projectID, entryID: entry.id)
            gpgKeyEntries = try entryRepository.listGPGKeyEntries(projectID: projectID)
            deletedGPGKeyEntries = try entryRepository.listDeletedGPGKeyEntries(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .gpgKey,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded(appLocalized("已恢复 \(restored.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func clearEditingGPGKeyEntry() {
        editingGPGKeyEntryID = nil
        editingGPGKeyTitle = ""
        editingGPGKeyNotes = ""
        editingGPGKeyFavorite = false
    }

    // MARK: 详情展示

    func gpgKeyDetailRows(for entryID: String) -> [AppExtensionCapabilityRow] {
        guard let entry = gpgKeyEntries.first(where: { $0.id == entryID }) else {
            return [
                AppExtensionCapabilityRow(
                    id: "missing",
                    title: appLocalized("条目"),
                    value: appLocalized("已不存在"),
                    detail: "",
                    systemImage: ""
                )
            ]
        }

        let created = entry.keyCreatedAt.formatted(date: .numeric, time: .omitted)
        let expires = entry.keyExpiresAt.map { $0.formatted(date: .numeric, time: .omitted) }
            ?? appLocalized("永不过期")
        let keyMaterial = entry.hasPrivateKey
            ? (entry.armoredPublicKey.isEmpty
                ? appLocalized("仅私钥块（公钥未单独导出）")
                : appLocalized("公钥 + 私钥块"))
            : appLocalized("仅公钥")

        return [
            row("title", appLocalized("标题"), entry.title),
            row("owner", appLocalized("属主"), entry.ownerName),
            row("email", appLocalized("邮箱"), entry.ownerEmail),
            row("algorithm", appLocalized("算法"), entry.algorithm),
            row("fingerprint", appLocalized("指纹（v\(entry.keyVersion)）"), entry.formattedFingerprint),
            row("keyID", "Key ID", entry.keyID),
            row("created", appLocalized("创建时间"), created),
            row("expires", appLocalized("过期时间"), expires),
            row("status", appLocalized("状态"), entry.statusSummary),
            row("material", appLocalized("密钥材料"), keyMaterial),
            row("notes", appLocalized("备注"), entry.notes),
            row("verification", appLocalized("签名验证"), appLocalized("未接入（依赖尚未提供）"))
        ]
    }

    /// 只有可公开的字段才提供复制入口；私钥材料永远不会出现在这里。
    func gpgKeyDetailSecrets(for entryID: String) -> [String: String] {
        guard let entry = gpgKeyEntries.first(where: { $0.id == entryID }) else {
            return [:]
        }
        var secrets = [
            "fingerprint": entry.fingerprint,
            "keyID": entry.keyID
        ]
        if !entry.armoredPublicKey.isEmpty {
            secrets["publicArmor"] = entry.armoredPublicKey
        }
        return secrets
    }

    private func row(_ id: String, _ title: String, _ value: String) -> AppExtensionCapabilityRow {
        AppExtensionCapabilityRow(
            id: id,
            title: title,
            value: value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? appLocalized("空")
                : value,
            detail: "",
            systemImage: ""
        )
    }
}

// MARK: - 列表卡片

struct AndroidGPGKeyListCard: View {
    let entry: LocalGPGKeyEntry

    var body: some View {
        AndroidExtendedSecretListCard(
            icon: "key.horizontal.fill",
            title: entry.title,
            primary: [entry.ownerName, entry.keyID].filter { !$0.isEmpty }.joined(separator: " · "),
            secondary: entry.formattedFingerprint,
            favorite: entry.favorite
        )
    }
}

// MARK: - 编辑器字段

struct GPGKeyEntryEditorFields: View {
    @Bindable var session: AppSessionModel
    let isAdding: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if isAdding {
                importSection
            } else {
                existingKeySection
            }
            notesField
            Text("本条目只做结构与指纹展示：签名验证 / 加密依赖尚未接入，也不会生成新密钥。")
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 导入

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("导入 ASCII armored GPG 密钥", systemImage: "square.and.arrow.down")
                .font(.subheadline.weight(.semibold))

            TextEditor(text: $session.gpgKeyImportInput)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 170)
                .padding(12)
                .scrollContentBackground(.hidden)
                .background(AndroidParityPalette.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16).stroke(AndroidParityPalette.outline, lineWidth: 1)
                }
                .accessibilityLabel(Text("armored 密钥输入"))

            HStack(spacing: 12) {
                Button {
                    session.parseGPGKeyImportInput()
                } label: {
                    Label("解析并预览", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                .disabled(session.gpgKeyImportInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Toggle(isOn: $session.gpgKeyImportIncludesPrivateKey) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("同时保存私钥块")
                    Text("默认关闭。勾选后 armored 私钥会随条目写入保险箱；本实现不校验口令、不解密，也不导出私钥。")
                        .font(.caption)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
            }
            .onChange(of: session.gpgKeyImportIncludesPrivateKey) { _, _ in
                session.parseGPGKeyImportInput()
            }

            if let error = session.gpgKeyImportError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let preview = session.gpgKeyImportPreview {
                previewCard(preview)
            }

            field(
                icon: "folder.fill",
                title: appLocalized("标题 *"),
                text: $session.gpgKeyTitle
            )
        }
    }

    private func previewCard(_ metadata: GPGKeyMetadata) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("解析结果（未做签名验证）", systemImage: "checkmark.seal")
                .font(.footnote.weight(.semibold))
            detailLine(appLocalized("属主"), metadata.ownerName)
            detailLine(appLocalized("邮箱"), metadata.ownerEmail)
            detailLine(appLocalized("算法"), metadata.algorithm)
            detailLine(appLocalized("指纹"), metadata.formattedFingerprint)
            detailLine("Key ID", metadata.keyID)
            detailLine(
                appLocalized("过期"),
                metadata.keyExpiresAt.map { $0.formatted(date: .numeric, time: .omitted) }
                    ?? appLocalized("永不过期")
            )
            if metadata.isRevoked {
                Text("该密钥带有吊销签名（仅按 packet 类型识别，未验证签名本身）。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if metadata.isSecretKey {
                Text("检测到私钥块：只有勾选「同时保存私钥块」后才会写入。")
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
            if let duplicateID = session.gpgKeyImportDuplicateEntryID {
                Text("同一指纹的密钥已存在（条目 \(duplicateID)），重复导入会被拒绝。")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AndroidParityPalette.surfaceVariant, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: 编辑已有条目

    private var existingKeySection: some View {
        VStack(alignment: .leading, spacing: 18) {
            field(
                icon: "folder.fill",
                title: appLocalized("标题 *"),
                text: $session.editingGPGKeyTitle
            )
            if let entry = session.gpgKeyEntries.first(where: { $0.id == session.editingGPGKeyEntryID }) {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant, cornerRadius: 16) {
                    detailLine(appLocalized("指纹"), entry.formattedFingerprint)
                    detailLine("Key ID", entry.keyID)
                    detailLine(appLocalized("算法"), entry.algorithm)
                    detailLine(appLocalized("状态"), entry.statusSummary)
                    detailLine(
                        appLocalized("密钥材料"),
                        entry.hasPrivateKey ? appLocalized("公钥 + 私钥块") : appLocalized("仅公钥")
                    )
                }
                Text("指纹与密钥材料在导入时确定，不支持原地修改；需要换钥请删除后重新导入。")
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var notesField: some View {
        field(
            icon: "note.text",
            title: appLocalized("备注"),
            text: isAdding ? $session.gpgKeyNotes : $session.editingGPGKeyNotes
        )
    }

    // MARK: 小组件

    private func detailLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .frame(width: 92, alignment: .leading)
            Text(value.isEmpty ? appLocalized("空") : value)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func field(icon: String, title: String, text: Binding<String>) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .foregroundStyle(AndroidParityPalette.primary)
                .frame(width: 24)
            TextField(title, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(AndroidParityPalette.surfaceVariant, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
