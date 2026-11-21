import Foundation
import MonicaStorage

// slice B: VaultFolders 域，从 AppSessionModel.swift 逐字搬移。
extension AppSessionModel {
    // MARK: - #27 文件夹层级与保险箱总览

    func vaultFolderRepository(
        entryRepository: LocalVaultEntryRepository
    ) -> VaultFolderRepository? {
        guard let session = activeVaultSession else { return nil }
        return VaultFolderRepository(
            entryRepository: entryRepository,
            session: session,
            anchorStore: vaultFolderAnchorStore
        )
    }

    /// 解锁或结构变更后重读文件夹森林，并把 `vaultProjects` 同步成文件夹列表。
    func refreshVaultFolders(entryRepository: LocalVaultEntryRepository) {
        guard let repository = vaultFolderRepository(entryRepository: entryRepository) else {
            vaultFolderTree = .empty
            vaultProjects = []
            return
        }
        if let tree = try? repository.tree() {
            vaultFolderTree = tree
            vaultProjects = tree.folders.map { LocalVaultProject(id: $0.id, title: $0.title) }
        }
        // 读取失败时保留上一次的树，避免瞬时错误把界面清空成「没有文件夹」。
        if let activeProject, let node = vaultFolderTree.folder(id: activeProject.id) {
            self.activeProject = LocalVaultProject(id: node.id, title: node.title)
        }
        refreshVaultSearchIndex(entryRepository: entryRepository)
    }

    /// 当前所在的文件夹；`nil` 表示停在「全部条目」这一层。
    var activeVaultFolder: VaultFolderNode? {
        guard let activeProject else { return nil }
        return vaultFolderTree.folder(id: activeProject.id)
    }

    /// 面包屑：从根到当前文件夹。
    var activeVaultFolderBreadcrumb: [VaultFolderNode] {
        activeVaultFolder.map { vaultFolderTree.path(to: $0.id) } ?? []
    }

    /// 当前层级下可直接进入的子文件夹。
    var activeVaultChildFolders: [VaultFolderNode] {
        vaultFolderTree.children(of: activeVaultFolder?.id)
    }

    /// 当前层级是否还能再建子文件夹（受最大层级约束）。
    var canCreateVaultFolder: Bool {
        let depth = activeVaultFolder.map { vaultFolderTree.depth(of: $0.id) } ?? 0
        return depth < VaultFolderNameRules.maxDepth
    }

    @discardableResult
    func createVaultFolder(
        title: String,
        parentID: String?,
        entryRepository: LocalVaultEntryRepository
    ) throws -> VaultFolderNode {
        guard let repository = vaultFolderRepository(entryRepository: entryRepository) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let node = try repository.createFolder(title: title, parentID: parentID)
        refreshVaultFolders(entryRepository: entryRepository)
        return node
    }

    /// 在指定父目录下新建文件夹；不传父目录时建在当前文件夹里。
    @discardableResult
    func createVaultFolder(title: String, parentID: String? = nil) throws -> VaultFolderNode {
        guard let entryRepository = activeEntryRepository else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let resolvedParentID = parentID ?? activeVaultFolder?.id
        return try createVaultFolder(
            title: title,
            parentID: resolvedParentID,
            entryRepository: entryRepository
        )
    }

    @discardableResult
    func renameVaultFolder(
        folderID: String,
        title: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> VaultFolderNode {
        guard let repository = vaultFolderRepository(entryRepository: entryRepository) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let node = try repository.renameFolder(id: folderID, title: title)
        refreshVaultFolders(entryRepository: entryRepository)
        return node
    }

    @discardableResult
    func renameVaultFolder(folderID: String, title: String) throws -> VaultFolderNode {
        guard let entryRepository = activeEntryRepository else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        return try renameVaultFolder(folderID: folderID, title: title, entryRepository: entryRepository)
    }

    /// 移动文件夹（含整棵子树）。禁止移入自身/后代，由仓储层拦截。
    @discardableResult
    func moveVaultFolder(folderID: String, parentID: String?) throws -> VaultFolderNode {
        guard let entryRepository = activeEntryRepository,
              let repository = vaultFolderRepository(entryRepository: entryRepository)
        else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let node = try repository.moveFolder(id: folderID, newParentID: parentID)
        refreshVaultFolders(entryRepository: entryRepository)
        publishWidgetSnapshots()
        return node
    }

    func vaultFolderDeletionPlan(folderID: String) throws -> VaultFolderDeletionPlan {
        guard let entryRepository = activeEntryRepository,
              let repository = vaultFolderRepository(entryRepository: entryRepository)
        else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        return try repository.deletionPlan(folderID: folderID)
    }

    /// 按显式策略删除文件夹：内容上移或递归进回收站，绝不静默永久删除条目。
    @discardableResult
    func deleteVaultFolder(
        folderID: String,
        strategy: VaultFolderDeleteStrategy
    ) throws -> VaultFolderDeletionResult {
        guard let entryRepository = activeEntryRepository,
              let repository = vaultFolderRepository(entryRepository: entryRepository)
        else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let removedIDs = Set(vaultFolderTree.subtree(rootedAt: folderID).map(\.id))
        let wasActive = activeProject.map { removedIDs.contains($0.id) } ?? false
        let result = try repository.deleteFolder(folderID: folderID, strategy: strategy)
        refreshVaultFolders(entryRepository: entryRepository)
        // 正停在被删子树里就退回「全部条目」，不要把人留在已经不存在的层级。
        if wasActive, activeProject.map({ vaultFolderTree.folder(id: $0.id) == nil }) ?? false {
            activeProject = nil
            clearAllEntryLists()
            resetVaultQuickFilters()
        }
        publishWidgetSnapshots()
        return result
    }

    /// 进入某个文件夹（`nil` 回到「全部条目」），面包屑据此渲染。
    func openVaultFolder(_ folderID: String?) throws {
        guard let folderID else {
            activeProject = nil
            clearAllEntryLists()
            resetVaultQuickFilters()
            return
        }
        try switchVaultCategory(projectID: folderID)
    }

    func presentVaultOverview() {
        isVaultOverviewPresented = true
        recordUserActivity()
    }

    func dismissVaultOverview() {
        isVaultOverviewPresented = false
    }

    /// 新建分类时优先写成文件夹记录，保证重启后仍能从文件夹侧表恢复；
    /// 同级同名文件夹存在时直接复用，避免导入流程产生重复分类。
    func createOrReuseVaultProject(
        title: String,
        parentID explicitParentID: String? = nil,
        entryRepository: LocalVaultEntryRepository
    ) throws -> LocalVaultProject {
        guard let folderRepository = vaultFolderRepository(entryRepository: entryRepository) else {
            return try entryRepository.createProject(title: title)
        }
        let parentID = explicitParentID ?? activeVaultFolder?.id
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let tree = try? folderRepository.tree(),
           let existing = tree.folders.first(where: {
               $0.parentID == parentID && $0.title.caseInsensitiveCompare(normalizedTitle) == .orderedSame
           }) {
            return LocalVaultProject(id: existing.id, title: existing.title)
        }
        let node = try folderRepository.createFolder(title: title, parentID: parentID)
        return LocalVaultProject(id: node.id, title: node.title)
    }

    /// 解锁/新建后自动进入第一个文件夹（分类），让用户看到条目而不是空白页。
    /// 旧库没有文件夹记录时退回项目列表，保持既有行为。
    func activateInitialVaultCategoryIfNeeded(
        entryRepository: LocalVaultEntryRepository
    ) {
        guard activeProject == nil else { return }
        let projects: [LocalVaultProject]
        if vaultProjects.isEmpty {
            // 文件夹索引自身的锚点工程不是用户分类，必须排除，否则新库会把条目写进锚点工程，
            // 重开保险库后 listProjects() 为空、分类无从激活，条目列表整片空白。
            projects = ((try? entryRepository.listProjects()) ?? []).filter {
                !VaultFolderRepository.isSystemProjectTitle($0.title)
            }
            if !projects.isEmpty {
                vaultProjects = projects
            }
        } else {
            projects = vaultProjects
        }
        guard let first = projects.first else { return }
        try? activateVaultCategory(first, entryRepository: entryRepository)
    }
}
