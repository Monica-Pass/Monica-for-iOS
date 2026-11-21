//
//  AppKeePassLibraryModel.swift
//  Monica
//
//  issue #32：KeePass 原生库浏览器（组树/条目编辑/搜索/安全写回）。
//  文档层完全保留 KDBX 的 Header、KDF、加密算法、受保护字段与未知 XML；
//  本模型只负责页面状态与导航，不接触日志，也不缓存明文。
//

import Foundation
import MonicaStorage
import Observation

@MainActor
@Observable
final class AppKeePassLibraryModel {
    enum Phase: Equatable {
        case needsDatabase
        case needsUnlock
        case unlocked
    }

    private(set) weak var session: AppSessionModel?
    private(set) var document: KeePassNativeDocument?
    private(set) var databaseData: Data?
    private(set) var databaseName = ""
    private(set) var sourceFileURL: URL?
    private(set) var keyFileName = ""
    private(set) var keyFileData: Data?

    var password = ""
    var searchText = ""
    var selectedGroupID: String?
    var expandedGroupIDs: Set<String> = []
    var isBusy = false
    var errorMessage: String?
    var statusMessage: String?

    private var securityScopedURL: URL?

    init(session: AppSessionModel) {
        self.session = session
        adoptSessionState()
    }

    // MARK: - 会话状态

    /// 设置页已经选过 KDBX 时，打开本页可以复用同一个文件与口令输入。
    func adoptSessionState() {
        guard let session else { return }
        password = session.keePassUnlockPassword
        keyFileName = session.keePassKeyFileName
        keyFileData = session.keePassKeyFileData
        guard document == nil, let data = session.keePassPendingDatabaseData else {
            return
        }
        databaseData = data
        databaseName = session.keePassPendingDatabaseName ?? String(localized: "KeePass 数据库")
        sourceFileURL = session.keePassSourceFileURL
    }

    /// 页面阶段由「是否已载入文件 / 是否已解锁」推导，避免可变的重复状态。
    var phase: Phase {
        if document != nil {
            return .unlocked
        }
        return databaseData == nil ? .needsDatabase : .needsUnlock
    }

    var databaseDisplayName: String {
        databaseName.isEmpty ? String(localized: "未选择数据库") : databaseName
    }

    /// 设置页已解析出的 KDBX 版本 / 加密信息；未解析时为空。
    var containerSummary: String {
        if let document {
            return document.headerSummary.displayName
        }
        if let headerSummary = session?.keePassImportPreview?.headerSummary {
            return headerSummary.displayName
        }
        return String(localized: "未知")
    }

    var cryptoSummary: String {
        if let document {
            return document.headerSummary.cryptoSummary?.displaySummary ?? String(localized: "未知")
        }
        return session?.keePassImportPreview?.headerSummary?.cryptoSummary?.displaySummary
            ?? String(localized: "未知")
    }

    // MARK: - 文件选择

    func importDatabase(from url: URL) {
        errorMessage = nil
        releaseSecurityScopedAccess()
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        do {
            let data = try Data(contentsOf: url)
            if didStartAccessing {
                securityScopedURL = url
            }
            closeDocument()
            databaseData = data
            databaseName = url.lastPathComponent
            sourceFileURL = url
            searchText = ""
            selectedGroupID = nil
            expandedGroupIDs = []
            statusMessage = String(localized: "已选择 KDBX 文件，请输入密码或密钥文件后解锁。")

            session?.keePassPendingDatabaseData = data
            session?.keePassPendingDatabaseName = url.lastPathComponent
            session?.keePassSourceFileURL = url
        } catch {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
            errorMessage = error.localizedDescription
        }
    }

    func importKeyFile(from url: URL) {
        errorMessage = nil
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        do {
            let data = try Data(contentsOf: url)
            keyFileData = data
            keyFileName = url.lastPathComponent
            session?.keePassKeyFileData = data
            session?.keePassKeyFileName = url.lastPathComponent
            statusMessage = String(localized: "已选择密钥文件。")
        } catch {
            errorMessage = error.localizedDescription
        }
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }

    func clearKeyFile() {
        keyFileData = nil
        keyFileName = ""
        session?.keePassKeyFileData = nil
        session?.keePassKeyFileName = ""
    }

    // MARK: - 解锁 / 写回 / 关闭

    func unlock() {
        guard !isBusy else { return }
        guard let databaseData else {
            errorMessage = String(localized: "请先选择 KDBX 数据库。")
            return
        }
        let credentials = KeePassUnlockCredentials(
            password: password,
            keyFile: keyFileData,
            keyFileName: keyFileName.isEmpty ? nil : keyFileName
        )
        guard !credentials.credentialCandidates.isEmpty else {
            errorMessage = String(localized: "请输入数据库密码或选择密钥文件。")
            return
        }

        isBusy = true
        errorMessage = nil
        statusMessage = nil
        Task { @MainActor in
            // 让 SwiftUI 先渲染进度状态，再进行同步的 KDF 解密。
            await Task.yield()
            defer { isBusy = false }
            do {
                let document = try KeePassNativeDocument.load(
                    data: databaseData,
                    sourceName: databaseName,
                    credentials: credentials
                )
                self.document = document
                selectedGroupID = document.rootGroupID
                if let rootGroupID = document.rootGroupID {
                    expandedGroupIDs = [rootGroupID]
                } else {
                    expandedGroupIDs = []
                }
                statusMessage = String(localized: "数据库已解锁。")

                session?.keePassUnlockPassword = password
                session?.keePassKeyFileData = keyFileData
                session?.keePassKeyFileName = keyFileName
                session?.keePassPendingDatabaseData = databaseData
                session?.keePassPendingDatabaseName = databaseName
                session?.keePassSourceFileURL = sourceFileURL
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func save() {
        guard !isBusy else { return }
        guard let document else { return }
        guard let sourceFileURL else {
            errorMessage = String(localized: "当前没有可写回的源文件，请先从文件 App 选择 KDBX。")
            return
        }

        isBusy = true
        errorMessage = nil
        Task { @MainActor in
            await Task.yield()
            defer { isBusy = false }
            do {
                _ = try KeePassNativeDocumentStore().save(document: document, to: sourceFileURL)
                document.markSaved()
                session?.keePassPendingDatabaseData = try? Data(contentsOf: sourceFileURL)
                session?.entryOperationState = .succeeded("KeePass")
                statusMessage = String(localized: "已写回源文件，并通过重新打开校验。")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 关闭页面时清空本页持有的明文与解密后的 XML。
    func close() {
        closeDocument()
        password = ""
        keyFileData = nil
        databaseData = nil
        keyFileName = ""
        searchText = ""
        selectedGroupID = nil
        expandedGroupIDs = []
        statusMessage = nil
        errorMessage = nil
        releaseSecurityScopedAccess()
    }

    private func closeDocument() {
        document?.close()
        document = nil
    }

    private func releaseSecurityScopedAccess() {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }

    // MARK: - 只读派生

    var phaseIsUnlocked: Bool { phase == .unlocked }
    var isDirty: Bool { document?.hasUnsavedChanges == true }
    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var groups: [KeePassNativeGroup] { document?.groups ?? [] }
    var groupCount: Int { document?.groupCount ?? 0 }
    var entryCount: Int { document?.entryCount ?? 0 }

    /// 只展示"祖先全部展开"的分组，形成可折叠的树。
    var visibleGroups: [KeePassNativeGroup] {
        guard let document else { return [] }
        return document.groups.filter { group in
            guard let parentID = group.parentID else { return true }
            var ancestorID: String? = parentID
            while let currentID = ancestorID {
                if !expandedGroupIDs.contains(currentID) { return false }
                ancestorID = document.group(id: currentID)?.parentID
            }
            return true
        }
    }

    var selectedGroup: KeePassNativeGroup? {
        guard let document, let selectedGroupID else { return nil }
        return document.group(id: selectedGroupID)
    }

    /// 搜索时跨全库；否则只显示当前分组的直接条目。
    var visibleEntries: [KeePassNativeEntry] {
        guard let document else { return [] }
        if isSearching {
            return document.entries(matching: searchText)
        }
        return document.entries(inGroup: selectedGroupID)
    }

    func selectGroup(_ group: KeePassNativeGroup) {
        selectedGroupID = group.id
        if group.childGroupCount > 0 {
            expandedGroupIDs.insert(group.id)
        }
    }

    func toggleExpansion(_ group: KeePassNativeGroup) {
        if expandedGroupIDs.contains(group.id) {
            expandedGroupIDs.remove(group.id)
        } else {
            expandedGroupIDs.insert(group.id)
        }
    }

    func entryTitle(for entry: KeePassNativeEntry) -> String {
        entry.displayTitle
    }

    // MARK: - 分组编辑

    @discardableResult
    func createGroup(title: String) -> Bool {
        guard let document else { return false }
        do {
            let created = try document.createGroup(parentID: selectedGroupID, title: title)
            if let parentID = created.parentID {
                expandedGroupIDs.insert(parentID)
            }
            expandedGroupIDs.insert(created.id)
            selectedGroupID = created.id
            statusMessage = String(localized: "已新建分组，尚未写回。")
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func renameGroup(id: String, title: String) -> Bool {
        guard let document else { return false }
        do {
            try document.renameGroup(id: id, title: title)
            statusMessage = String(localized: "已重命名分组，尚未写回。")
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func moveGroup(id: String, to parentID: String?) -> Bool {
        guard let document else { return false }
        do {
            try document.moveGroup(id: id, toParentID: parentID)
            if let parentID {
                expandedGroupIDs.insert(parentID)
            }
            statusMessage = String(localized: "已移动分组，尚未写回。")
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func deleteGroup(id: String) -> Bool {
        guard let document else { return false }
        let parentID = document.group(id: id)?.parentID
        do {
            try document.deleteGroup(id: id)
            if selectedGroupID == id {
                selectedGroupID = parentID ?? document.rootGroupID
            }
            statusMessage = String(localized: "已删除分组，尚未写回。")
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// 移动目标：排除自身、自身子树与当前父分组。
    func moveCandidates(for group: KeePassNativeGroup) -> [KeePassNativeGroup] {
        guard let document else { return [] }
        return document.groups.filter { candidate in
            guard candidate.id != group.id, candidate.id != group.parentID else {
                return false
            }
            var ancestorID: String? = candidate.parentID
            while let currentID = ancestorID {
                if currentID == group.id { return false }
                ancestorID = document.group(id: currentID)?.parentID
            }
            return true
        }
    }

    func canDelete(_ group: KeePassNativeGroup) -> Bool {
        guard !group.isRoot else { return false }
        return !group.isRecycleBin
    }

    // MARK: - 条目编辑

    @discardableResult
    func updateEntry(
        id: String,
        title: String,
        username: String,
        password: String,
        url: String,
        notes: String
    ) -> Bool {
        guard let document else { return false }
        do {
            try document.updateEntry(
                id: id,
                title: title,
                username: username,
                password: password,
                url: url,
                notes: notes
            )
            statusMessage = String(localized: "条目已更新，尚未写回。")
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func createEntry(
        title: String,
        username: String,
        password: String,
        url: String,
        notes: String
    ) -> Bool {
        guard let document else { return false }
        do {
            _ = try document.createEntry(
                groupID: selectedGroupID,
                title: title,
                username: username,
                password: password,
                url: url,
                notes: notes
            )
            statusMessage = String(localized: "已新建条目，尚未写回。")
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - 敏感字段

    /// 复制密码等敏感字段统一走 `SensitivePrivacyService`，绝不写日志。
    func copySecret(_ value: String) {
        guard !value.isEmpty else {
            errorMessage = String(localized: "没有可复制的内容。")
            return
        }
        guard let session else { return }
        statusMessage = session.copySensitiveValueToPasteboard(value).message
    }
}
