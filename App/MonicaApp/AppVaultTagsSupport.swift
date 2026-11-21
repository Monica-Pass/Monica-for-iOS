//
//  AppVaultTagsSupport.swift
//  Monica
//
//  标签、排序与归档的会话侧状态与操作。
//  标签与归档标记存放在条目加密 payload 的 monicaMeta 字段里，
//  这里只负责读取、排序、筛选和写回，不记录任何明文条目内容。
//

import Foundation
import MonicaStorage

// MARK: - 排序模型

enum VaultEntrySortField: String, CaseIterable, Codable, Sendable, Identifiable {
    case title
    case createdAt
    case modifiedAt
    case recentlyUsed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .title:
            String(localized: "标题")
        case .createdAt:
            String(localized: "创建时间")
        case .modifiedAt:
            String(localized: "修改时间")
        case .recentlyUsed:
            String(localized: "最近使用")
        }
    }

    var systemImage: String {
        switch self {
        case .title:
            "textformat"
        case .createdAt:
            "calendar.badge.plus"
        case .modifiedAt:
            "calendar.badge.clock"
        case .recentlyUsed:
            "clock.arrow.circlepath"
        }
    }
}

enum VaultEntrySortDirection: String, Codable, Sendable {
    case ascending
    case descending

    var isAscending: Bool { self == .ascending }

    var title: String {
        switch self {
        case .ascending:
            String(localized: "升序")
        case .descending:
            String(localized: "降序")
        }
    }

    var systemImage: String {
        switch self {
        case .ascending:
            "arrow.up"
        case .descending:
            "arrow.down"
        }
    }
}

struct VaultEntrySortPreference: Codable, Equatable, Sendable {
    var field: VaultEntrySortField
    var direction: VaultEntrySortDirection

    static let `default` = VaultEntrySortPreference(
        field: .modifiedAt,
        direction: .descending
    )

    var summary: String {
        "\(field.title) · \(direction.title)"
    }

    var isDefault: Bool { self == Self.default }
}

enum VaultEntrySortPreferenceStore {
    static let storageKey = "monica.vaultEntrySortPreference"

    static func load(defaults: UserDefaults = .standard) -> VaultEntrySortPreference {
        guard let data = defaults.data(forKey: storageKey),
              let preference = try? JSONDecoder().decode(VaultEntrySortPreference.self, from: data)
        else {
            return .default
        }
        return preference
    }

    static func save(
        _ preference: VaultEntrySortPreference,
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(preference) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

// MARK: - 归档与标签的会话操作

extension AppSessionModel {
    var isArchiveQuickFilterSelected: Bool {
        selectedVaultQuickFilterID == "archived"
    }

    var vaultSortSummary: String {
        vaultSortPreference.summary
    }

    var archivedVaultEntryCount: Int {
        var total = 0
        total += loginEntries.filter { $0.isArchived }.count
        total += noteEntries.filter { $0.isArchived }.count
        total += totpEntries.filter { $0.isArchived }.count
        total += cardEntries.filter { $0.isArchived }.count
        total += identityEntries.filter { $0.isArchived }.count
        total += passkeyEntries.filter { $0.isArchived }.count
        total += sshKeyEntries.filter { $0.isArchived }.count
        total += apiTokenEntries.filter { $0.isArchived }.count
        total += wifiEntries.filter { $0.isArchived }.count
        total += sendEntries.filter { $0.isArchived }.count
        total += attachmentEntries.filter { $0.isArchived }.count
        return total
    }

    var selectedVaultTagTitles: [String] {
        vaultTagCatalog
            .filter { selectedVaultTagIDs.contains($0.id) }
            .map(\.name)
    }

    func setVaultSortField(_ field: VaultEntrySortField) {
        vaultSortPreference = VaultEntrySortPreference(
            field: field,
            direction: vaultSortPreference.direction
        )
        saveVaultSortPreference()
    }

    func setVaultSortDirection(_ direction: VaultEntrySortDirection) {
        vaultSortPreference = VaultEntrySortPreference(
            field: vaultSortPreference.field,
            direction: direction
        )
        saveVaultSortPreference()
    }

    func toggleVaultSortDirection() {
        setVaultSortDirection(vaultSortPreference.direction.isAscending ? .descending : .ascending)
    }

    func resetVaultSortPreference() {
        vaultSortPreference = .default
        saveVaultSortPreference()
    }

    private func saveVaultSortPreference() {
        VaultEntrySortPreferenceStore.save(vaultSortPreference)
    }

    func toggleVaultTagFilter(_ tagID: String) {
        if selectedVaultTagIDs.contains(tagID) {
            selectedVaultTagIDs.remove(tagID)
        } else {
            selectedVaultTagIDs.insert(tagID)
        }
    }

    func clearVaultTagFilters() {
        selectedVaultTagIDs.removeAll()
    }

    /// 从当前分类重新汇总标签目录；标签只存在于条目的加密 metadata 里。
    func refreshVaultTags() {
        guard let entryRepository = activeEntryRepository else {
            vaultTagCatalog = []
            return
        }
        do {
            let tags = try entryRepository.listVaultTags()
            vaultTagCatalog = tags
            let availableTagIDs = Set(tags.map(\.id))
            selectedVaultTagIDs = selectedVaultTagIDs.intersection(availableTagIDs)
        } catch {
            // 锁定时读不到标签属于正常状态，保留上一次的目录即可。
        }
    }

    func vaultEntryMetadata(forEntryID entryID: String) -> VaultEntryMetadata {
        if let entry = loginEntries.first(where: { $0.id == entryID }) { return entry.metadata }
        if let entry = noteEntries.first(where: { $0.id == entryID }) { return entry.metadata }
        if let entry = totpEntries.first(where: { $0.id == entryID }) { return entry.metadata }
        if let entry = cardEntries.first(where: { $0.id == entryID }) { return entry.metadata }
        if let entry = identityEntries.first(where: { $0.id == entryID }) { return entry.metadata }
        if let entry = passkeyEntries.first(where: { $0.id == entryID }) { return entry.metadata }
        if let entry = sshKeyEntries.first(where: { $0.id == entryID }) { return entry.metadata }
        if let entry = apiTokenEntries.first(where: { $0.id == entryID }) { return entry.metadata }
        if let entry = wifiEntries.first(where: { $0.id == entryID }) { return entry.metadata }
        if let entry = sendEntries.first(where: { $0.id == entryID }) { return entry.metadata }
        if let entry = attachmentEntries.first(where: { $0.id == entryID }) { return entry.metadata }
        return .empty
    }

    func vaultTags(forEntryID entryID: String) -> [VaultEntryTag] {
        vaultEntryMetadata(forEntryID: entryID).tags
    }

    func isVaultEntryArchived(_ entryID: String) -> Bool {
        vaultEntryMetadata(forEntryID: entryID).isArchived
    }

    func setVaultEntryArchived(_ archived: Bool, entryID: String) throws {
        try mutateVaultEntryMetadata(entryID: entryID, successMessage: archived ? String(localized: "已归档") : String(localized: "已取消归档")) { entryRepository, projectID in
            try entryRepository.setEntryArchived(
                projectID: projectID,
                entryID: entryID,
                archived: archived
            )
        }
    }

    func addVaultTag(named rawName: String, toEntryID entryID: String) throws {
        try mutateVaultEntryMetadata(entryID: entryID, successMessage: String(localized: "已添加标签")) { entryRepository, projectID in
            _ = try entryRepository.addEntryTag(
                projectID: projectID,
                entryID: entryID,
                name: rawName,
                existingTags: self.vaultTags(forEntryID: entryID)
            )
        }
    }

    func removeVaultTag(tagID: String, fromEntryID entryID: String) throws {
        let remaining = vaultTags(forEntryID: entryID).filter { $0.id != tagID }
        try mutateVaultEntryMetadata(entryID: entryID, successMessage: String(localized: "已移除标签")) { entryRepository, projectID in
            try entryRepository.setEntryTags(
                projectID: projectID,
                entryID: entryID,
                tags: remaining
            )
        }
    }

    func renameVaultTag(tagID: String, to rawName: String) throws {
        guard let entryRepository = activeEntryRepository,
              let projectID = activeProject?.id
        else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        recordUserActivity()
        entryOperationState = .running
        do {
            let affected = try entryRepository.renameVaultTag(tagID: tagID, name: rawName)
            try refreshAllEntryLists(projectID: projectID, entryRepository: entryRepository)
            refreshVaultTags()
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .login,
                itemID: tagID,
                itemTitle: String(localized: "重命名标签")
            )
            entryOperationState = .succeeded(String(localized: "已重命名标签，受影响条目数：") + "\(affected)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteVaultTag(tagID: String) throws {
        guard let entryRepository = activeEntryRepository,
              let projectID = activeProject?.id
        else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        recordUserActivity()
        entryOperationState = .running
        do {
            let affected = try entryRepository.deleteVaultTag(tagID: tagID)
            selectedVaultTagIDs.remove(tagID)
            try refreshAllEntryLists(projectID: projectID, entryRepository: entryRepository)
            refreshVaultTags()
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .login,
                itemID: tagID,
                itemTitle: String(localized: "删除标签")
            )
            entryOperationState = .succeeded(String(localized: "已删除标签，移除关联条目数：") + "\(affected)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    private func mutateVaultEntryMetadata(
        entryID: String,
        successMessage: String,
        _ body: (LocalVaultEntryRepository, String) throws -> Void
    ) throws {
        guard let entryRepository = activeEntryRepository,
              let projectID = activeProject?.id
        else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        recordUserActivity()
        entryOperationState = .running
        do {
            try body(entryRepository, projectID)
            try refreshAllEntryLists(projectID: projectID, entryRepository: entryRepository)
            refreshVaultTags()
            try? refreshAutoFillEncryptedIndexIfConfigured()
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .login,
                itemID: entryID,
                itemTitle: successMessage
            )
            entryOperationState = .succeeded(successMessage)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    // MARK: 筛选与排序（供 filteredFavoriteEntries 与附件列表复用）

    /// 归档语义：默认列表排除归档条目；只有显式进入「归档」筛选时才只显示归档条目。
    func vaultEntryPassesArchiveAndTagFilter(_ entry: any VaultTaggedEntry) -> Bool {
        if isArchiveQuickFilterSelected {
            guard entry.isArchived else { return false }
        } else if entry.isArchived {
            return false
        }
        if !selectedVaultTagIDs.isEmpty {
            guard entry.hasAnyTag(selectedVaultTagIDs) else { return false }
        }
        return true
    }

    /// 「最近使用」的数据源：操作时间线里最近一次查看/编辑/创建/恢复/移动的时间。
    var recentlyUsedVaultEntryDates: [String: Date] {
        var latest: [String: Date] = [:]
        for event in operationTimelineEvents {
            switch event.action {
            case .viewed, .updated, .created, .restored, .moved:
                break
            default:
                continue
            }
            let occurredAt = event.occurredAt
            if let current = latest[event.itemID], current >= occurredAt {
                continue
            }
            latest[event.itemID] = occurredAt
        }
        return latest
    }

    func vaultSortedEntries<Entry: VaultTaggedEntry>(
        _ indexed: [(offset: Int, element: Entry)],
        isFavorite: (Entry) -> Bool
    ) -> [Entry] {
        let preference = vaultSortPreference
        let recentDates = preference.field == .recentlyUsed ? recentlyUsedVaultEntryDates : [:]

        return indexed.sorted { lhs, rhs in
            let lhsFavorite = isFavorite(lhs.element)
            let rhsFavorite = isFavorite(rhs.element)
            if lhsFavorite != rhsFavorite {
                return lhsFavorite
            }

            let comparison = vaultEntryComparison(
                lhs: lhs,
                rhs: rhs,
                field: preference.field,
                recentDates: recentDates
            )
            switch comparison {
            case .orderedAscending:
                return preference.direction.isAscending
            case .orderedDescending:
                return !preference.direction.isAscending
            case .orderedSame:
                if lhs.offset != rhs.offset {
                    return lhs.offset < rhs.offset
                }
                return lhs.element.id < rhs.element.id
            }
        }
        .map(\.element)
    }

    private func vaultEntryComparison<Entry: VaultTaggedEntry>(
        lhs: (offset: Int, element: Entry),
        rhs: (offset: Int, element: Entry),
        field: VaultEntrySortField,
        recentDates: [String: Date]
    ) -> ComparisonResult {
        switch field {
        case .title:
            let comparison = lhs.element.title.localizedStandardCompare(rhs.element.title)
            if comparison != .orderedSame {
                return comparison
            }
        case .createdAt:
            return vaultDateComparison(
                lhs.element.createdAt,
                rhs.element.createdAt,
                lhsOffset: lhs.offset,
                rhsOffset: rhs.offset
            )
        case .modifiedAt:
            return vaultDateComparison(
                lhs.element.updatedAt,
                rhs.element.updatedAt,
                lhsOffset: lhs.offset,
                rhsOffset: rhs.offset
            )
        case .recentlyUsed:
            return vaultDateComparison(
                recentDates[lhs.element.id],
                recentDates[rhs.element.id],
                lhsOffset: lhs.offset,
                rhsOffset: rhs.offset
            )
        }
        return .orderedSame
    }

    private func vaultDateComparison(
        _ lhsDate: Date?,
        _ rhsDate: Date?,
        lhsOffset: Int,
        rhsOffset: Int
    ) -> ComparisonResult {
        switch (lhsDate, rhsDate) {
        case let (lhs?, rhs?):
            if lhs == rhs { return .orderedSame }
            return lhs < rhs ? .orderedAscending : .orderedDescending
        case (nil, nil):
            // 旧条目没有时间戳，退回原始顺序，保证排序稳定且可复现。
            if lhsOffset == rhsOffset { return .orderedSame }
            return lhsOffset < rhsOffset ? .orderedAscending : .orderedDescending
        case (nil, _):
            return .orderedAscending
        case (_, nil):
            return .orderedDescending
        }
    }
}
