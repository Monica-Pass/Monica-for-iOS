import Foundation

// MARK: - 常用账号模板仓储（issue #127）
//
// 模板记录和条目自定义字段、文件夹层级一样放在「锚点工程」的加密侧表里：
// - 复用 `VaultFolderAnchorStore` 的锚点（同一个隐藏 project），这样不需要新增
//   一个会被「旧分类导入」当成根文件夹的幽灵工程；
// - 模板用独立的 entryKind（`account-template`），和文件夹记录互不干扰；
// - 记录随保险库加密，不写 UserDefaults、不落明文文件。

public extension LocalVaultEntryRepository {
    /// 列出锚点工程里的模板记录。
    func listAccountTemplates(anchorProjectID: String) throws -> [AccountTemplate] {
        try engine.listAccountTemplates(in: session.handle, anchorProjectID: anchorProjectID)
    }

    func saveAccountTemplate(anchorProjectID: String, template: AccountTemplate) throws {
        try engine.saveAccountTemplate(
            in: session.handle,
            anchorProjectID: anchorProjectID,
            template: template
        )
    }

    func deleteAccountTemplate(anchorProjectID: String, templateID: String) throws {
        try engine.deleteAccountTemplate(
            in: session.handle,
            anchorProjectID: anchorProjectID,
            templateID: templateID
        )
    }
}

/// 常用账号模板仓储：内置模板（代码常量）+ 自定义模板（加密侧表）。
public struct AccountTemplateRepository {
    private let entryRepository: LocalVaultEntryRepository
    private let session: LocalVaultSession
    private let anchorStore: any VaultFolderAnchorStore

    public init(
        entryRepository: LocalVaultEntryRepository,
        session: LocalVaultSession,
        anchorStore: any VaultFolderAnchorStore = InMemoryVaultFolderAnchorStore()
    ) {
        self.entryRepository = entryRepository
        self.session = session
        self.anchorStore = anchorStore
    }

    // MARK: 读取

    /// 只读地取锚点；不存在时返回 nil（不会创建隐藏工程）。
    public func existingAnchorProjectID() -> String? {
        try? anchorStore.loadAnchorProjectID(vaultID: session.handle.vaultID)
    }

    /// 自定义模板（已按 sortOrder 排序）。内置模板不在这里。
    ///
    /// 只读：还没建过锚点工程时直接返回空列表，不因为「打开模板页」就给
    /// 保险库塞一个隐藏工程。
    public func customTemplates() throws -> [AccountTemplate] {
        guard let anchorProjectID = existingAnchorProjectID() else { return [] }
        return try customTemplates(anchorProjectID: anchorProjectID)
    }

    /// 内置 + 自定义：内置按目录顺序在前，自定义按 sortOrder 在后。
    public func allTemplates() throws -> [AccountTemplate] {
        AccountTemplateCatalog.builtins + (try customTemplates())
    }

    /// 某个条目类型可用的模板（内置在前，自定义在后）。
    public func templates(for kind: UnifiedVaultItemKind) throws -> [AccountTemplate] {
        try allTemplates().filter { $0.itemKind == kind }
    }

    public func customTemplateCount() throws -> Int {
        try customTemplates().count
    }

    // MARK: 写入

    /// 新增或更新一条自定义模板。
    ///
    /// - 拒绝内置 ID（内置模板是代码常量，只能复制）；
    /// - 归一化后再落库，侧表里不会出现超长标题或受保护字段；
    /// - 更新时保留原有 sortOrder / createdAt，避免保存一次模板就跳到列表末尾。
    @discardableResult
    public func save(_ template: AccountTemplate) throws -> AccountTemplate {
        guard !template.isBuiltin, !AccountTemplateCatalog.isBuiltinTemplateID(template.templateID) else {
            throw AccountTemplateError.builtinTemplateReadOnly
        }
        var normalized = try template.normalized()
        normalized.isBuiltin = false
        let anchorProjectID = try ensureAnchor()
        let existing = try entryRepository.listAccountTemplates(anchorProjectID: anchorProjectID)
        if let current = existing.first(where: { $0.templateID == normalized.templateID }) {
            normalized.sortOrder = current.sortOrder
            normalized.createdAt = current.createdAt
        } else {
            guard existing.count < AccountTemplateRules.maxCustomTemplateCount else {
                throw AccountTemplateError.templateLimitReached(limit: AccountTemplateRules.maxCustomTemplateCount)
            }
            normalized.sortOrder = (existing.map(\.sortOrder).max() ?? -1) + 1
        }
        try entryRepository.saveAccountTemplate(anchorProjectID: anchorProjectID, template: normalized)
        return normalized
    }

    /// 删除一条自定义模板。不存在时按幂等处理（重复点删除不会报错）。
    public func delete(templateID: String) throws {
        guard !AccountTemplateCatalog.isBuiltinTemplateID(templateID) else {
            throw AccountTemplateError.builtinTemplateReadOnly
        }
        // 没有锚点工程 = 没有自定义模板，删除直接幂等返回。
        guard let anchorProjectID = existingAnchorProjectID() else { return }
        try entryRepository.deleteAccountTemplate(anchorProjectID: anchorProjectID, templateID: templateID)
    }

    /// 按传入顺序重排自定义模板；未列出的模板保持原顺序排在后面。
    public func reorder(customTemplateIDs: [String]) throws {
        guard let anchorProjectID = existingAnchorProjectID() else { return }
        let existing = try entryRepository.listAccountTemplates(anchorProjectID: anchorProjectID)
        var remaining = Self.sortedCustom(existing)
        var ordered: [AccountTemplate] = []
        for templateID in customTemplateIDs {
            guard let index = remaining.firstIndex(where: { $0.templateID == templateID }) else { continue }
            ordered.append(remaining.remove(at: index))
        }
        ordered.append(contentsOf: remaining)
        for (index, template) in ordered.enumerated() where template.sortOrder != index {
            var updated = template
            updated.sortOrder = index
            updated.updatedAt = Date()
            try entryRepository.saveAccountTemplate(anchorProjectID: anchorProjectID, template: updated)
        }
    }

    /// 批量导入（按 ID upsert），返回实际写入的条数。
    @discardableResult
    public func importTemplates(_ templates: [AccountTemplate]) throws -> Int {
        var imported = 0
        for template in templates {
            _ = try save(template)
            imported += 1
        }
        return imported
    }

    /// 把一条模板（通常是内置模板）复制成可编辑的自定义模板。
    @discardableResult
    public func duplicateAsCustom(_ template: AccountTemplate) throws -> AccountTemplate {
        var copy = template
        copy.templateID = UUID().uuidString
        copy.isBuiltin = false
        copy.sortOrder = 0
        copy.createdAt = Date()
        copy.updatedAt = Date()
        let suffix = " 副本"
        let base = template.displayTitle
        let maxBaseLength = max(1, AccountTemplateRules.maxTitleLength - suffix.count)
        copy.title = String(base.prefix(maxBaseLength)) + suffix
        return try save(copy)
    }

    // MARK: 内部

    /// 取锚点工程，没有就建一个（和文件夹仓储共用同一个隐藏工程）。
    private func ensureAnchor() throws -> String {
        let vaultID = session.handle.vaultID
        if let existing = try? anchorStore.loadAnchorProjectID(vaultID: vaultID), !existing.isEmpty {
            return existing
        }
        let project = try entryRepository.createProject(title: VaultFolderRepository.anchorProjectTitle)
        do {
            try anchorStore.saveAnchorProjectID(project.id, vaultID: vaultID)
        } catch {
            throw AccountTemplateError.anchorUnavailable
        }
        return project.id
    }

    private func customTemplates(anchorProjectID: String) throws -> [AccountTemplate] {
        let records = try entryRepository.listAccountTemplates(anchorProjectID: anchorProjectID)
        return Self.sortedCustom(records)
    }

    private static func sortedCustom(_ templates: [AccountTemplate]) -> [AccountTemplate] {
        templates
            .filter { !$0.isBuiltin && !AccountTemplateCatalog.isBuiltinTemplateID($0.templateID) }
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                if lhs.title != rhs.title { return lhs.title < rhs.title }
                return lhs.templateID < rhs.templateID
            }
    }
}
