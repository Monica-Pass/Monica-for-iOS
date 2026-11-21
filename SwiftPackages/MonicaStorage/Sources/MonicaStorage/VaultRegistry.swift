//
//  VaultRegistry.swift
//  MonicaStorage
//
//  本地保险库注册表：记录「有哪些本地库、名字、文件在哪、上次打开、哪个是默认库」。
//  这里只保存显示名 / 路径 / 时间戳，绝不保存主密码、包裹密钥或任何派生密钥；
//  密钥材料仍然只走 Keychain（见 AppUnlockSupport.KeychainWrappedVaultKeyStore）。
//

import Foundation

/// 注册表里的一项本地保险库。
///
/// - `id`：注册表行 ID，重命名或搬动文件都不变，供 UI 稳定引用。
/// - `vaultID`：MDBX 文件内部的稳定库 ID（`MonicaMDBXVaultInfo.vaultID`），
///   用来对账「同一个库」并隔离 AutoFill / 搜索 / 密钥。
/// - `fileName`：只存文件名，沙盒容器路径变化后可以用「新容器 + 文件名」重新定位。
/// - `bookmarkData`：可选书签，外部（非 App 容器内）文件重定位的兜底方式。
public struct VaultRegistryEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var vaultID: String
    public var displayName: String
    public private(set) var fileName: String
    public private(set) var fileURL: URL
    public var bookmarkData: Data?
    public var lastOpenedAt: Date?
    public var isDefault: Bool

    public init(
        id: String = UUID().uuidString,
        vaultID: String,
        displayName: String,
        fileURL: URL,
        bookmarkData: Data? = nil,
        lastOpenedAt: Date? = nil,
        isDefault: Bool = false
    ) {
        self.id = id
        self.vaultID = vaultID
        self.displayName = displayName
        self.fileName = fileURL.lastPathComponent
        self.fileURL = fileURL
        self.bookmarkData = bookmarkData
        self.lastOpenedAt = lastOpenedAt
        self.isDefault = isDefault
    }

    /// 位置变化（容器路径改变、文件被搬动）时同步文件名与书签。
    public mutating func updateFileLocation(_ fileURL: URL, bookmarkData: Data?) {
        self.fileURL = fileURL
        self.fileName = fileURL.lastPathComponent
        if let bookmarkData {
            self.bookmarkData = bookmarkData
        }
    }

    public var hasFileBookmark: Bool {
        bookmarkData != nil
    }
}

public enum VaultRegistryError: LocalizedError, Equatable, Sendable {
    case entryNotFound
    case emptyDisplayName
    case duplicateDisplayName(String)
    case vaultFileMissing(String)

    public var errorDescription: String? {
        switch self {
        case .entryNotFound:
            return String(localized: "找不到这个保险库记录。")
        case .emptyDisplayName:
            return String(localized: "保险库名称不能为空。")
        case .duplicateDisplayName:
            return String(localized: "已存在同名保险库，请换一个名称。")
        case .vaultFileMissing:
            return String(localized: "保险库文件不在原位置，请重新打开或删除该记录。")
        }
    }
}

/// 本地保险库注册表（值类型，便于测试与整体持久化）。
///
/// 约定：
/// - 任何时刻最多只有一个默认库（`isDefault`）。
/// - `selectedEntryID` 表示「上次打开 / 当前选中的库」，只用于锁屏预选，不会自动解锁。
/// - 删除注册项只动注册表，绝不删除磁盘文件。
public struct LocalVaultRegistry: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public private(set) var schemaVersion: Int
    public private(set) var entries: [VaultRegistryEntry]
    public private(set) var selectedEntryID: String?

    public init(
        schemaVersion: Int = LocalVaultRegistry.currentSchemaVersion,
        entries: [VaultRegistryEntry] = [],
        selectedEntryID: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.entries = entries
        self.selectedEntryID = selectedEntryID
        normalizeDefaultFlag()
        normalizeSelection()
    }

    public var isEmpty: Bool {
        entries.isEmpty
    }

    public var count: Int {
        entries.count
    }

    /// 默认库：只在没有上次打开记录 / 上次打开的库不可用时用于启动预选。
    public var defaultEntry: VaultRegistryEntry? {
        entries.first(where: \.isDefault)
    }

    public var selectedEntry: VaultRegistryEntry? {
        guard let selectedEntryID else { return nil }
        return entry(id: selectedEntryID)
    }

    /// 列表顺序：默认库置顶，随后按上次打开时间倒序，最后按名称。
    public var sortedEntries: [VaultRegistryEntry] {
        entries.sorted { left, right in
            if left.isDefault != right.isDefault {
                return left.isDefault
            }
            let leftDate = left.lastOpenedAt ?? .distantPast
            let rightDate = right.lastOpenedAt ?? .distantPast
            if leftDate != rightDate {
                return leftDate > rightDate
            }
            return left.displayName.localizedStandardCompare(right.displayName) == .orderedAscending
        }
    }

    public func entry(id: String) -> VaultRegistryEntry? {
        entries.first { $0.id == id }
    }

    public func entry(vaultID: String) -> VaultRegistryEntry? {
        entries.first { $0.vaultID == vaultID }
    }

    public func entry(fileURL: URL) -> VaultRegistryEntry? {
        let path = fileURL.standardizedFileURL.path
        return entries.first { $0.fileURL.standardizedFileURL.path == path }
    }

    public func displayNameIsAvailable(_ displayName: String, excluding excludedID: String? = nil) -> Bool {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !entries.contains { entry in
            guard entry.id != excludedID else { return false }
            return entry.displayName.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    // MARK: - 注册 / 切换

    /// 成功打开或创建某个库后登记它（同一个库会就地更新，不会产生重复行）。
    ///
    /// 已存在的记录不会因为文件名变化而改显示名：注册表里的名字才是用户重命名后的名字。
    /// 首个登记的库自动成为默认库。
    @discardableResult
    public mutating func register(
        vaultID: String,
        fileURL: URL,
        displayName: String,
        bookmarkData: Data? = nil,
        now: Date = Date()
    ) -> VaultRegistryEntry {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = fileURL.deletingPathExtension().lastPathComponent
        let resolvedName = trimmedName.isEmpty ? fallbackName : trimmedName

        if let index = indexOfEntry(vaultID: vaultID, fileURL: fileURL) {
            entries[index].vaultID = vaultID
            entries[index].updateFileLocation(fileURL, bookmarkData: bookmarkData)
            if entries[index].displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entries[index].displayName = resolvedName
            }
            entries[index].lastOpenedAt = now
            selectedEntryID = entries[index].id
            normalizeDefaultFlag()
            return entries[index]
        }

        let entry = VaultRegistryEntry(
            vaultID: vaultID,
            displayName: resolvedName,
            fileURL: fileURL,
            bookmarkData: bookmarkData,
            lastOpenedAt: now,
            isDefault: entries.isEmpty
        )
        entries.append(entry)
        selectedEntryID = entry.id
        normalizeDefaultFlag()
        return entry
    }

    /// 记住「上次打开的库」。只改选择，不解锁、不读密钥。
    public mutating func select(id: String) throws {
        guard entries.contains(where: { $0.id == id }) else {
            throw VaultRegistryError.entryNotFound
        }
        selectedEntryID = id
    }

    public mutating func clearSelection() {
        selectedEntryID = nil
    }

    /// 设默认库；同一时刻只会有一个默认库。
    public mutating func setDefault(id: String) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            throw VaultRegistryError.entryNotFound
        }
        for otherIndex in entries.indices {
            entries[otherIndex].isDefault = otherIndex == index
        }
    }

    /// 旧单库用户升级：注册表为空时把已记住的库迁入，并标记为默认库。
    @discardableResult
    public mutating func adoptLegacyVault(
        vaultID: String,
        fileURL: URL,
        displayName: String,
        now: Date = Date()
    ) -> Bool {
        guard entries.isEmpty else { return false }
        let entry = VaultRegistryEntry(
            vaultID: vaultID,
            displayName: displayName,
            fileURL: fileURL,
            lastOpenedAt: now,
            isDefault: true
        )
        entries = [entry]
        selectedEntryID = entry.id
        return true
    }

    // MARK: - 改名 / 删除

    /// 只改注册表显示名，不重命名磁盘文件（MDBX 文件名是库身份的一部分）。
    public mutating func rename(id: String, to displayName: String) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            throw VaultRegistryError.entryNotFound
        }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VaultRegistryError.emptyDisplayName
        }
        guard displayNameIsAvailable(trimmed, excluding: id) else {
            throw VaultRegistryError.duplicateDisplayName(trimmed)
        }
        entries[index].displayName = trimmed
    }

    /// 删除注册项。**不删除磁盘文件**：文件删除由调用方在二次确认后单独执行。
    ///
    /// 默认库被删时，把默认标记交给最近打开的剩余库；选中项被删时同样回落到仍可用的库。
    @discardableResult
    public mutating func remove(id: String) throws -> VaultRegistryEntry {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            throw VaultRegistryError.entryNotFound
        }
        let removed = entries.remove(at: index)
        if selectedEntryID == removed.id {
            selectedEntryID = nil
        }
        if removed.isDefault {
            let fallbackID = mostRecentlyOpenedEntryID(excluding: nil)
            if let fallbackID {
                for otherIndex in entries.indices {
                    entries[otherIndex].isDefault = entries[otherIndex].id == fallbackID
                }
            }
        }
        normalizeDefaultFlag()
        normalizeSelection()
        return removed
    }

    // MARK: - 路径解析

    /// 解析库文件的当前位置：
    /// 1. 记录里的绝对路径还有效 → 直接用；
    /// 2. 容器路径变了（重装 / 恢复备份）→ 用「新容器 + 原文件名」重定位；
    /// 3. 仍找不到 → 尝试书签兜底；
    /// 4. 都不行 → 返回记录路径，由调用方报「文件不在原位置」。
    public func resolveFileURL(
        for entry: VaultRegistryEntry,
        baseDirectory: URL?,
        fileExists: (URL) -> Bool = LocalVaultRegistry.fileExists
    ) -> URL {
        if fileExists(entry.fileURL) {
            return entry.fileURL
        }

        if let baseDirectory {
            let rebased = baseDirectory.appendingPathComponent(entry.fileName, isDirectory: false)
            if fileExists(rebased) {
                return rebased
            }
        }

        if let bookmarkData = entry.bookmarkData,
           let bookmarkedURL = Self.resolveBookmark(bookmarkData),
           fileExists(bookmarkedURL) {
            return bookmarkedURL
        }

        return entry.fileURL
    }

    /// 把「容器搬家」后的新路径写回注册表；返回是否发生了变更。
    @discardableResult
    public mutating func rebaseStoredPaths(
        baseDirectory: URL?,
        fileExists: (URL) -> Bool = LocalVaultRegistry.fileExists
    ) -> Bool {
        var changed = false
        for index in entries.indices {
            let entry = entries[index]
            guard !fileExists(entry.fileURL) else { continue }
            let resolved = resolveFileURL(for: entry, baseDirectory: baseDirectory, fileExists: fileExists)
            if resolved.standardizedFileURL.path != entry.fileURL.standardizedFileURL.path {
                entries[index].updateFileLocation(resolved, bookmarkData: nil)
                changed = true
            }
        }
        return changed
    }

    public func missingEntries(
        baseDirectory: URL?,
        fileExists: (URL) -> Bool = LocalVaultRegistry.fileExists
    ) -> [VaultRegistryEntry] {
        entries.filter { entry in
            !fileExists(resolveFileURL(for: entry, baseDirectory: baseDirectory, fileExists: fileExists))
        }
    }

    // MARK: - 内部维护

    public static func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func indexOfEntry(vaultID: String, fileURL: URL) -> Int? {
        let path = fileURL.standardizedFileURL.path
        return entries.firstIndex { entry in
            entry.vaultID == vaultID || entry.fileURL.standardizedFileURL.path == path
        }
    }

    private func mostRecentlyOpenedEntryID(excluding excludedID: String?) -> String? {
        entries
            .filter { $0.id != excludedID }
            .max { left, right in
                (left.lastOpenedAt ?? .distantPast) < (right.lastOpenedAt ?? .distantPast)
            }?
            .id
    }

    private static func resolveBookmark(_ bookmarkData: Data) -> URL? {
        var isStale = false
        return try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    private mutating func normalizeDefaultFlag() {
        guard !entries.isEmpty else { return }
        if let defaultIndex = entries.firstIndex(where: \.isDefault) {
            for index in entries.indices where index != defaultIndex {
                entries[index].isDefault = false
            }
            return
        }
        let fallbackID = mostRecentlyOpenedEntryID(excluding: nil)
        if let fallbackID, let fallbackIndex = entries.firstIndex(where: { $0.id == fallbackID }) {
            entries[fallbackIndex].isDefault = true
        } else {
            entries[entries.startIndex].isDefault = true
        }
    }

    private mutating func normalizeSelection() {
        guard !entries.isEmpty else {
            selectedEntryID = nil
            return
        }
        if let selectedEntryID, entries.contains(where: { $0.id == selectedEntryID }) {
            return
        }
        selectedEntryID = defaultEntry?.id ?? entries[entries.startIndex].id
    }
}
