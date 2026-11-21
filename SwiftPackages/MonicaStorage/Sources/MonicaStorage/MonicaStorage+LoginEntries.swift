// MARK: - 登录条目（LocalLoginEntry / LocalLoginEntryDraft、密码历史、多 URL）

import Foundation
import MonicaMDBX

public struct LocalLoginEntryDraft: Sendable, Equatable {
    public let title: String
    public let username: String
    /// 登录账号（邮箱 / 手机号 / 账号 ID），与 `username` 分开保存；旧数据为空字符串。
    public let account: String
    public let password: String
    /// 主 URL：AutoFill 关联只使用它。
    public let url: String
    public let notes: String
    /// 完整有序 URL 列表（含主 URL）；为空时按 `[url]` 处理。
    public let urls: [String]
    /// 应用绑定 metadata：仅用于展示与筛选，不参与系统 AutoFill 关联。
    public let appBundleID: String
    public let appName: String
    /// 上一份密码历史，最新的一条在最前面。
    ///
    /// `nil` 表示「沿用仓库里已有的历史，并在密码变化时自动追加」；
    /// 显式传入数组表示「用这份列表替换历史」（UI 删除单条/清空时使用）。
    public let passwordHistory: [LocalLoginPasswordHistoryEntry]?

    public let metadata: VaultEntryMetadata

    public init(
        title: String,
        username: String,
        account: String = "",
        password: String,
        url: String,
        notes: String = "",
        urls: [String] = [],
        appBundleID: String = "",
        appName: String = "",
        passwordHistory: [LocalLoginPasswordHistoryEntry]? = nil,
        metadata: VaultEntryMetadata = .empty
    ) {
        self.title = title
        self.username = username
        self.account = account
        self.password = password
        self.url = url
        self.notes = notes
        self.urls = urls
        self.appBundleID = appBundleID
        self.appName = appName
        self.passwordHistory = passwordHistory
        self.metadata = metadata
    }
}

public struct LocalLoginEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let username: String
    /// 登录账号（邮箱 / 手机号 / 账号 ID），与 `username` 分开保存；旧数据为空字符串。
    public let account: String
    public let password: String
    /// 主 URL：AutoFill 关联只使用它。
    public let url: String
    public let notes: String
    public let favorite: Bool
    /// 条目图标的稳定资源 ID（`sf:…` / `catalog:…`）；`nil` 表示按条目类型使用默认图标。
    public let icon: String?
    /// 完整有序 URL 列表（含主 URL）；旧库没有该字段时回退为 `[url]`。
    public let urls: [String]
    /// 应用绑定 metadata：仅用于展示与筛选，不参与系统 AutoFill 关联。
    public let appBundleID: String
    public let appName: String
    /// 上一份密码历史，最新的一条在最前面。
    public let passwordHistory: [LocalLoginPasswordHistoryEntry]
    public let metadata: VaultEntryMetadata

    public init(
        id: String,
        projectID: String,
        title: String,
        username: String,
        account: String = "",
        password: String,
        url: String,
        notes: String = "",
        favorite: Bool = false,
        icon: String? = nil,
        urls: [String] = [],
        appBundleID: String = "",
        appName: String = "",
        passwordHistory: [LocalLoginPasswordHistoryEntry] = [],
        metadata: VaultEntryMetadata = .empty
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.username = username
        self.account = account
        self.password = password
        self.url = url
        self.notes = notes
        self.favorite = favorite
        self.icon = icon
        self.urls = urls
        self.appBundleID = appBundleID
        self.appName = appName
        self.passwordHistory = passwordHistory
        self.metadata = metadata
    }

    /// 完整 URL 列表：旧数据只有单个 `url` 时等价于 `[url]`。
    public var effectiveURLs: [String] {
        urls.isEmpty ? (url.isEmpty ? [] : [url]) : urls
    }
}

extension LocalVaultEntryRepository {
    public func createLoginEntry(
        projectID: String,
        draft: LocalLoginEntryDraft
    ) throws -> LocalLoginEntry {
        let normalizedDraft = try normalizedLoginEntryDraft(draft)
        return try engine.createLoginEntry(
            in: session.handle,
            projectID: projectID,
            draft: normalizedDraft
        )
    }

    public func listLoginEntries(projectID: String) throws -> [LocalLoginEntry] {
        try engine.listLoginEntries(
            in: session.handle,
            projectID: projectID
        )
    }

    public func updateLoginEntry(
        projectID: String,
        entryID: String,
        draft: LocalLoginEntryDraft
    ) throws -> LocalLoginEntry {
        let normalizedDraft = try normalizedLoginEntryDraft(draft)
        // 只有密码确实变化时才把上一份密文追加成一条历史；UI 传回的历史会保留删除/清空结果。
        let existingEntry = try? engine.listLoginEntries(
            in: session.handle,
            projectID: projectID
        ).first(where: { $0.id == entryID })
        let history: [LocalLoginPasswordHistoryEntry]
        if let existingEntry {
            history = LoginPasswordHistoryPolicy.appending(
                previousPassword: existingEntry.password,
                newPassword: normalizedDraft.password,
                history: normalizedDraft.passwordHistory ?? existingEntry.passwordHistory
            )
        } else {
            history = normalizedDraft.passwordHistory ?? []
        }
        return try engine.updateLoginEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            draft: normalizedDraft.withPasswordHistory(history)
        )
    }

    public func setLoginEntryFavorite(
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalLoginEntry {
        try engine.setLoginEntryFavorite(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
    }

    public func setLoginEntryIcon(
        projectID: String,
        entryID: String,
        icon: String?
    ) throws -> LocalLoginEntry {
        try engine.setLoginEntryIcon(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            icon: icon
        )
    }

    public func deleteLoginEntry(projectID: String, entryID: String) throws {
        try engine.deleteLoginEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    public func listDeletedLoginEntries(projectID: String) throws -> [LocalLoginEntry] {
        try engine.listDeletedLoginEntries(
            in: session.handle,
            projectID: projectID
        )
    }

    public func restoreLoginEntry(
        projectID: String,
        entryID: String
    ) throws -> LocalLoginEntry {
        try engine.restoreLoginEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    private func normalizedLoginEntryDraft(_ draft: LocalLoginEntryDraft) throws -> LocalLoginEntryDraft {
        let normalizedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw LocalVaultRepositoryError.emptyEntryTitle
        }
        // 旧数据只有一个 `url`；新数据用有序去重列表，首项永远作为主 URL。
        let normalizedURLs = LoginEntryURLRules.normalizedURLs(primary: draft.url, additional: draft.urls)
        return LocalLoginEntryDraft(
            title: normalizedTitle,
            username: draft.username,
            account: draft.account,
            password: draft.password,
            url: normalizedURLs.first ?? "",
            notes: draft.notes,
            urls: normalizedURLs,
            appBundleID: draft.appBundleID.trimmingCharacters(in: .whitespacesAndNewlines),
            appName: draft.appName.trimmingCharacters(in: .whitespacesAndNewlines),
            passwordHistory: draft.passwordHistory.map(LoginPasswordHistoryPolicy.sanitizedHistory)
        )
    }
}

extension MDBXLocalVaultEngine {
    public func createLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalLoginEntryDraft
    ) throws -> LocalLoginEntry {
        let entry = try vault(for: handle).createLoginEntry(
            projectID: projectID,
            title: draft.title,
            username: draft.username,
            account: draft.account,
            password: draft.password,
            url: draft.url,
            notes: draft.notes,
            urls: draft.urls,
            appBundleID: draft.appBundleID,
            appName: draft.appName,
            passwordHistory: (draft.passwordHistory ?? []).map(MonicaMDBXLoginPasswordHistoryEntry.init)
        )
        return LocalLoginEntry(entry)
    }

    public func listLoginEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalLoginEntry] {
        try vault(for: handle)
            .listLoginEntries(projectID: projectID)
            .map(LocalLoginEntry.init)
    }

    public func updateLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalLoginEntryDraft
    ) throws -> LocalLoginEntry {
        let entry = try vault(for: handle).updateLoginEntry(
            projectID: projectID,
            entryID: entryID,
            title: draft.title,
            username: draft.username,
            account: draft.account,
            password: draft.password,
            url: draft.url,
            notes: draft.notes,
            urls: draft.urls,
            appBundleID: draft.appBundleID,
            appName: draft.appName,
            passwordHistory: (draft.passwordHistory ?? []).map(MonicaMDBXLoginPasswordHistoryEntry.init)
        )
        return LocalLoginEntry(entry)
    }

    public func deleteLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        try vault(for: handle).deleteLoginEntry(projectID: projectID, entryID: entryID)
    }

    public func setLoginEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalLoginEntry {
        let entry = try vault(for: handle).setLoginEntryFavorite(
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
        return LocalLoginEntry(entry)
    }

    /// 写入登录条目图标；`nil` 表示恢复默认图标。
    public func setLoginEntryIcon(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        icon: String?
    ) throws -> LocalLoginEntry {
        let entry = try vault(for: handle).setLoginEntryIcon(
            projectID: projectID,
            entryID: entryID,
            icon: icon
        )
        return LocalLoginEntry(entry)
    }

    public func listDeletedLoginEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalLoginEntry] {
        try vault(for: handle)
            .listDeletedLoginEntries(projectID: projectID)
            .map(LocalLoginEntry.init)
    }

    public func restoreLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalLoginEntry {
        let entry = try vault(for: handle).restoreLoginEntry(
            projectID: projectID,
            entryID: entryID
        )
        return LocalLoginEntry(entry)
    }
}

private extension LocalLoginEntry {
    init(_ entry: MonicaMDBXLoginEntry) {
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            username: entry.username,
            account: entry.account,
            password: entry.password,
            url: entry.url,
            notes: entry.notes,
            favorite: entry.favorite,
            icon: entry.icon,
            urls: entry.urls,
            appBundleID: entry.appBundleID,
            appName: entry.appName,
            passwordHistory: entry.passwordHistory.map(LocalLoginPasswordHistoryEntry.init),
            metadata: VaultEntryMetadata(entry.metadata)
        )
    }
}

private extension LocalLoginPasswordHistoryEntry {
    init(_ entry: MonicaMDBXLoginPasswordHistoryEntry) {
        self.init(id: entry.id, changedAt: entry.changedAt, password: entry.password)
    }
}

private extension MonicaMDBXLoginPasswordHistoryEntry {
    init(_ entry: LocalLoginPasswordHistoryEntry) {
        self.init(id: entry.id, changedAt: entry.changedAt, password: entry.password)
    }
}
