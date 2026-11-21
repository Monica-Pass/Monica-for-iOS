//
//  AppSessionModel+AccountTemplates.swift
//  Monica
//
//  issue #127：常用账号模板的会话操作。
//
//  模板数据放在保险库加密侧表里（见 MonicaStorage/AccountTemplates.swift），
//  这里只负责：载入、套用到「新建条目」编辑器、自定义模板的增删排序、
//  以及 JSON 导入导出的预览/确认流程。
//

import Foundation
import MonicaStorage

extension AppSessionModel {
    // MARK: - 仓储

    /// 当前解锁会话的模板仓储；未解锁时返回 nil。
    func accountTemplateRepository() -> AccountTemplateRepository? {
        guard let session = activeVaultSession, let entryRepository = activeEntryRepository else {
            return nil
        }
        return AccountTemplateRepository(
            entryRepository: entryRepository,
            session: session,
            anchorStore: vaultFolderAnchorStore
        )
    }

    // MARK: - 读取

    /// 重新载入内置 + 自定义模板。锁库或读取失败时清空列表。
    func reloadAccountTemplates() {
        guard let repository = accountTemplateRepository() else {
            accountTemplates = []
            return
        }
        do {
            accountTemplates = try repository.allTemplates()
        } catch {
            accountTemplates = []
            entryOperationState = .failed(error.localizedDescription)
        }
    }

    /// 编辑器首次展示前预取模板；已经载入过或未解锁时直接返回。
    func prepareAccountTemplatesForEditor() {
        guard activeVaultSession != nil, accountTemplates.isEmpty else { return }
        reloadAccountTemplates()
    }

    func accountTemplates(for kind: UnifiedVaultItemKind) -> [AccountTemplate] {
        accountTemplates.filter { $0.itemKind == kind }
    }

    /// 自定义模板（按 sortOrder，内置模板在前面的目录里）。
    var customAccountTemplates: [AccountTemplate] {
        accountTemplates.filter { !$0.isBuiltin }
    }

    // MARK: - 管理页

    func presentAccountTemplates() {
        prepareAccountTemplatesForEditor()
        isAccountTemplatesPresented = true
    }

    func dismissAccountTemplates() {
        isAccountTemplatesPresented = false
        cancelAccountTemplateImport()
        accountTemplateStatusMessage = nil
    }

    // MARK: - 套用到编辑器

    /// 清空上一次套用留下的提示（打开新建编辑器时调用）。
    func resetAccountTemplatePrefill() {
        accountTemplateUsernamePrompt = ""
        accountTemplatePrefillMessage = nil
    }

    /// 套用模板：只填空白字段，用户已经输入的内容保持不变；模板不含密码，永远不会写入密码。
    func applyAccountTemplate(_ template: AccountTemplate) {
        guard presentedEditorMode?.isAdding == true else { return }
        let draft = AccountTemplateFillDraft(
            title: loginTitle,
            urls: LoginEntryURLRules.normalizedURLs(primary: loginURL, additional: loginAdditionalURLs),
            username: loginUsername,
            notes: loginNotes,
            customFieldLabels: presentedCustomFields.map(\.label)
        )
        let outcome = AccountTemplateFill.apply(template, to: draft)
        loginTitle = outcome.title
        loginURL = outcome.urls.first ?? ""
        loginAdditionalURLs = Array(outcome.urls.dropFirst())
        loginNotes = outcome.notes
        for field in outcome.customFieldsToAdd {
            presentedCustomFields.append(
                VaultCustomField(
                    label: field.trimmedLabel,
                    kind: field.kind,
                    value: field.defaultValue,
                    order: presentedCustomFields.count
                )
            )
        }
        accountTemplateUsernamePrompt = outcome.usernamePlaceholder
        accountTemplatePrefillMessage = outcome.hasChanges
            ? String(localized: "已套用模板，已填写的字段可以继续修改。")
            : String(localized: "模板内容与当前填写一致，没有覆盖任何字段。")
    }

    // MARK: - 新增 / 修改 / 删除 / 排序

    @discardableResult
    func saveAccountTemplate(_ template: AccountTemplate) throws -> AccountTemplate {
        guard let repository = accountTemplateRepository() else {
            throw AccountTemplateError.engineUnavailable
        }
        let saved = try repository.save(template)
        reloadAccountTemplates()
        accountTemplateStatusMessage = String(localized: "模板已保存。")
        return saved
    }

    func deleteAccountTemplate(_ template: AccountTemplate) {
        guard let repository = accountTemplateRepository() else { return }
        do {
            try repository.delete(templateID: template.templateID)
            reloadAccountTemplates()
            accountTemplateStatusMessage = String(localized: "模板已删除。")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
        }
    }

    /// 上移 / 下移一条自定义模板（offset = -1 / +1）。
    func moveAccountTemplate(_ template: AccountTemplate, offset: Int) {
        var customs = customAccountTemplates
        guard let index = customs.firstIndex(where: { $0.templateID == template.templateID }) else {
            return
        }
        let target = index + offset
        guard customs.indices.contains(target) else { return }
        customs.swapAt(index, target)
        guard let repository = accountTemplateRepository() else { return }
        do {
            try repository.reorder(customTemplateIDs: customs.map(\.templateID))
            reloadAccountTemplates()
        } catch {
            entryOperationState = .failed(error.localizedDescription)
        }
    }

    /// 把内置模板复制成可编辑的自定义模板。
    func duplicateAccountTemplate(_ template: AccountTemplate) {
        guard let repository = accountTemplateRepository() else { return }
        do {
            _ = try repository.duplicateAsCustom(template)
            reloadAccountTemplates()
            accountTemplateStatusMessage = String(localized: "已复制为自定义模板，可以继续编辑。")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
        }
    }

    // MARK: - 导入（先预览，确认后才写库）

    func presentAccountTemplateImportPicker() {
        isAccountTemplateImportPickerPresented = true
    }

    func beginAccountTemplateImport(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            accountTemplateImportData = try Data(contentsOf: url)
            refreshAccountTemplateImportPreview(fileName: url.lastPathComponent)
        } catch {
            accountTemplateImportData = nil
            accountTemplateImportPreview = nil
            entryOperationState = .failed(error.localizedDescription)
        }
    }

    /// 切换「覆盖同 ID 模板」后重新预览。
    func updateAccountTemplateImportOverwrite(_ overwrite: Bool) {
        accountTemplateImportOverwrite = overwrite
        refreshAccountTemplateImportPreview(fileName: accountTemplateImportPreview?.fileName)
    }

    func confirmAccountTemplateImport() {
        guard let preview = accountTemplateImportPreview,
              let repository = accountTemplateRepository() else {
            return
        }
        do {
            _ = try repository.importTemplates(preview.templates)
            reloadAccountTemplates()
            accountTemplateStatusMessage = String(localized: "模板已导入。")
            cancelAccountTemplateImport()
        } catch {
            entryOperationState = .failed(error.localizedDescription)
        }
    }

    func cancelAccountTemplateImport() {
        accountTemplateImportPreview = nil
        accountTemplateImportData = nil
        accountTemplateImportOverwrite = false
    }

    private func refreshAccountTemplateImportPreview(fileName: String?) {
        guard let data = accountTemplateImportData else { return }
        let summary = AccountTemplateCodec.preview(
            data: data,
            options: AccountTemplateImportOptions(
                existingTemplateIDs: Set(customAccountTemplates.map(\.templateID)),
                overwriteExisting: accountTemplateImportOverwrite
            )
        )
        accountTemplateImportPreview = AccountTemplateImportPreview(summary: summary, fileName: fileName)
    }

    // MARK: - 导出

    func exportAccountTemplates() {
        let templates = customAccountTemplates
        guard !templates.isEmpty else {
            accountTemplateStatusMessage = String(localized: "还没有自定义模板可以导出。")
            return
        }
        do {
            let data = try AccountTemplateCodec.export(templates: templates)
            accountTemplateExportDocument = AccountTemplateExportDocument(data: data)
            isAccountTemplateExportPresented = true
        } catch {
            entryOperationState = .failed(error.localizedDescription)
        }
    }

    func finishAccountTemplateExport(_ result: Result<URL, Error>) {
        isAccountTemplateExportPresented = false
        accountTemplateExportDocument = nil
        switch result {
        case .success:
            accountTemplateStatusMessage = String(localized: "模板已导出。")
        case .failure(let error):
            if (error as? CocoaError)?.code == .userCancelled {
                return
            }
            entryOperationState = .failed(error.localizedDescription)
        }
    }

    // MARK: - 锁库清理

    /// 锁库时清空模板相关状态；模板正文仍留在加密侧表里，下次解锁重新载入。
    func clearAccountTemplateSession() {
        accountTemplates = []
        accountTemplateUsernamePrompt = ""
        accountTemplatePrefillMessage = nil
        accountTemplateStatusMessage = nil
        isAccountTemplatesPresented = false
        isAccountTemplateImportPickerPresented = false
        accountTemplateImportPreview = nil
        accountTemplateImportData = nil
        accountTemplateImportOverwrite = false
        isAccountTemplateExportPresented = false
        accountTemplateExportDocument = nil
    }
}
