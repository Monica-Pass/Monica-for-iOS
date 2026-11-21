import CryptoKit
import Foundation

// MARK: - 保留策略

/// 回收站保留策略。
///
/// 时间基准是「条目被删除的那一刻」（由 `TrashLedger` 记录），不是条目创建时间；
/// 因此策略切换只影响此后是否到期，不会改变已记录的删除时间。
///
/// 默认策略为 `.never`（关闭）。自动永久删除用户数据是不可逆操作，必须由用户
/// 显式选择保留天数后才启用；已持久化的用户选择不受影响。
///
/// MDBX 引擎目前只提供软删除，没有物理清除的 FFI，
/// 所以「永久删除」由调用方用 `TrashLedger` 把条目标记为已清理，并从所有列表与
/// 搜索索引中过滤掉；底层数据行保持软删除状态，不会被恢复入口重新暴露。
public enum TrashRetentionPolicy: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
    case sevenDays
    case thirtyDays
    case ninetyDays
    case never

    public static let standard: TrashRetentionPolicy = .never

    public var id: String {
        rawValue
    }

    /// 天数；`nil` 表示永不自动清理。
    public var retentionDays: Int? {
        switch self {
        case .sevenDays:
            return 7
        case .thirtyDays:
            return 30
        case .ninetyDays:
            return 90
        case .never:
            return nil
        }
    }

    public var isAutomaticPurgeEnabled: Bool {
        retentionDays != nil
    }

    public var retentionInterval: TimeInterval? {
        guard let retentionDays else {
            return nil
        }
        return TimeInterval(retentionDays) * 86_400
    }
}

public struct TrashRetentionRecord: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: UnifiedVaultItemKind
    public let projectID: String
    public let title: String
    public let deletedAt: Date?

    public init(
        id: String,
        kind: UnifiedVaultItemKind,
        projectID: String,
        title: String,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.projectID = projectID
        self.title = title
        self.deletedAt = deletedAt
    }

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.displayName : trimmed
    }
}

public struct TrashRetentionPlan: Sendable, Equatable {
    public let policy: TrashRetentionPolicy
    public let now: Date
    /// 已到期、自动清理会永久删除的条目。
    public let expired: [TrashRetentionRecord]
    /// 尚未到期、会继续保留的条目。
    public let retained: [TrashRetentionRecord]
    /// 旧版本删除的条目没有删除时间记录，一律不自动清理，需要用户手动确认。
    public let undated: [TrashRetentionRecord]

    public init(
        policy: TrashRetentionPolicy,
        now: Date,
        expired: [TrashRetentionRecord],
        retained: [TrashRetentionRecord],
        undated: [TrashRetentionRecord]
    ) {
        self.policy = policy
        self.now = now
        self.expired = expired
        self.retained = retained
        self.undated = undated
    }

    public var totalCount: Int {
        expired.count + retained.count + undated.count
    }

    public var expiredCount: Int {
        expired.count
    }

    public var isEmpty: Bool {
        totalCount == 0
    }
}

public enum TrashRetentionEvaluator {
    /// 到期的绝对时间点；「永不清理」返回 `nil`。
    public static func expirationDate(
        deletedAt: Date,
        policy: TrashRetentionPolicy
    ) -> Date? {
        guard let interval = policy.retentionInterval else {
            return nil
        }
        return deletedAt.addingTimeInterval(interval)
    }

    /// 只有严格超过保留期才算到期：30 天策略下，删除满 30 天的条目仍然保留，
    /// 第 31 天才进入清理范围。
    public static func isExpired(
        deletedAt: Date,
        policy: TrashRetentionPolicy,
        now: Date
    ) -> Bool {
        guard let interval = policy.retentionInterval else {
            return false
        }
        return now.timeIntervalSince(deletedAt) > interval
    }

    public static func plan(
        records: [TrashRetentionRecord],
        policy: TrashRetentionPolicy,
        now: Date
    ) -> TrashRetentionPlan {
        var expired: [TrashRetentionRecord] = []
        var retained: [TrashRetentionRecord] = []
        var undated: [TrashRetentionRecord] = []
        for record in records {
            guard let deletedAt = record.deletedAt else {
                undated.append(record)
                continue
            }
            if isExpired(deletedAt: deletedAt, policy: policy, now: now) {
                expired.append(record)
            } else {
                retained.append(record)
            }
        }
        return TrashRetentionPlan(
            policy: policy,
            now: now,
            expired: expired,
            retained: retained,
            undated: undated
        )
    }
}

// MARK: - 删除记录（加密账本）

/// 回收站的删除时间与永久清理标记。
///
/// 引擎没有 `deletedAt` 列，所以删除时间由 App 在软删除成功后写入这个账本；
/// 清理完成后用 `purgedAt` 把条目从列表与搜索索引里隐藏。
public struct TrashLedgerRecord: Codable, Sendable, Equatable {
    /// 用原始字符串保存类型，避免以后新增条目类型时旧账本解码失败。
    public let kind: String
    public let projectID: String
    public let title: String
    public let deletedAt: Date
    public var purgedAt: Date?

    public init(
        kind: String,
        projectID: String,
        title: String,
        deletedAt: Date,
        purgedAt: Date? = nil
    ) {
        self.kind = kind
        self.projectID = projectID
        self.title = title
        self.deletedAt = deletedAt
        self.purgedAt = purgedAt
    }

    public var itemKind: UnifiedVaultItemKind? {
        UnifiedVaultItemKind(rawValue: kind)
    }
}

public struct TrashLedger: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var records: [String: TrashLedgerRecord]

    public init(
        schemaVersion: Int = TrashLedger.currentSchemaVersion,
        records: [String: TrashLedgerRecord] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.records = records
    }

    public func record(for itemID: String) -> TrashLedgerRecord? {
        records[itemID]
    }

    public func deletedAt(for itemID: String) -> Date? {
        records[itemID]?.deletedAt
    }

    public var purgedItemIDs: Set<String> {
        Set(records.compactMap { $0.value.purgedAt == nil ? nil : $0.key })
    }

    public func isPurged(_ itemID: String) -> Bool {
        records[itemID]?.purgedAt != nil
    }

    /// 记录一次软删除；如果条目曾经被永久清理过（恢复后再次删除），清掉旧的清理标记。
    public mutating func recordDeletion(
        itemID: String,
        kind: UnifiedVaultItemKind,
        projectID: String,
        title: String,
        at date: Date
    ) {
        records[itemID] = TrashLedgerRecord(
            kind: kind.rawValue,
            projectID: projectID,
            title: title,
            deletedAt: date,
            purgedAt: nil
        )
    }

    /// 条目被恢复：删除时间与清理标记都不再有意义。
    public mutating func markRestored(itemID: String) {
        records.removeValue(forKey: itemID)
    }

    public mutating func markPurged(itemIDs: [String], at date: Date) {
        for itemID in itemIDs {
            guard var record = records[itemID] else {
                continue
            }
            record.purgedAt = date
            records[itemID] = record
        }
    }

    /// 删除记录太多时清掉早已清理的旧行，避免账本无限增长。返回移除的行数。
    @discardableResult
    public mutating func prunePurgedRecords(olderThan date: Date) -> Int {
        let stale = records.filter { _, record in
            guard let purgedAt = record.purgedAt else {
                return false
            }
            return purgedAt < date
        }
        for key in stale.keys {
            records.removeValue(forKey: key)
        }
        return stale.count
    }

    /// 把磁盘上仍然存在（或曾经存在）但账本没有时间记录的条目补成 `undated`：
    /// 这些条目不会被自动清理，只能手动清理。
    public func recordsMissingDeletionTime(
        from live: [TrashRetentionRecord]
    ) -> [TrashRetentionRecord] {
        live.filter { records[$0.id] == nil }
    }
}

public enum TrashLedgerStoreError: Error, LocalizedError, Equatable {
    case invalidKey
    case invalidVaultIdentifier
    case corrupted
    case authenticationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "回收站记录密钥无效，无法读取回收站状态。"
        case .invalidVaultIdentifier:
            return "保险箱标识无效，无法定位回收站记录。"
        case .corrupted:
            return "回收站记录文件已损坏，无法读取。"
        case .authenticationFailed:
            return "回收站记录无法解密，密钥可能已更换。"
        }
    }
}

public protocol TrashLedgerKeyProviding: Sendable {
    /// 32 字节对称密钥；调用方负责从 Keychain 等安全存储读取，不能写进 UserDefaults。
    func trashLedgerKey() throws -> Data
}

public struct StaticTrashLedgerKeyProvider: TrashLedgerKeyProviding {
    private let key: Data

    public init(key: Data) throws {
        guard key.count == 32 else {
            throw TrashLedgerStoreError.invalidKey
        }
        self.key = key
    }

    public func trashLedgerKey() throws -> Data {
        key
    }
}

/// 每个保险箱一份 AES-GCM 加密账本，文件名用 vaultID 的 SHA256，避免把标识写进路径。
public struct TrashLedgerStore: Sendable {
    public static let magic = Data("MTRASH1".utf8)
    public static let fileNameSuffix = ".mtrash"

    public let directoryURL: URL
    private let keyProvider: any TrashLedgerKeyProviding

    public init(
        directoryURL: URL,
        keyProvider: any TrashLedgerKeyProviding
    ) {
        self.directoryURL = directoryURL
        self.keyProvider = keyProvider
    }

    public static func defaultDirectoryURL(
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("Monica", isDirectory: true)
            .appendingPathComponent("TrashLedger", isDirectory: true)
    }

    public func ledgerFileURL(vaultID: String) throws -> URL {
        let trimmed = vaultID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TrashLedgerStoreError.invalidVaultIdentifier
        }
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directoryURL
            .appendingPathComponent(name + Self.fileNameSuffix, isDirectory: false)
    }

    public func hasLedger(vaultID: String) throws -> Bool {
        FileManager.default.fileExists(atPath: try ledgerFileURL(vaultID: vaultID).path)
    }

    public func loadLedger(vaultID: String) throws -> TrashLedger {
        let url = try ledgerFileURL(vaultID: vaultID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return TrashLedger()
        }
        let data = try Data(contentsOf: url)
        return try Self.decrypt(data, key: keyProvider.trashLedgerKey())
    }

    public func saveLedger(_ ledger: TrashLedger, vaultID: String) throws {
        let url = try ledgerFileURL(vaultID: vaultID)
        let plaintext = try JSONEncoder().encode(ledger)
        let sealed = try Self.encrypt(plaintext, key: keyProvider.trashLedgerKey())
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try sealed.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public func deleteLedger(vaultID: String) throws {
        let url = try ledgerFileURL(vaultID: vaultID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }

    static func encrypt(_ plaintext: Data, key: Data) throws -> Data {
        guard key.count == 32 else {
            throw TrashLedgerStoreError.invalidKey
        }
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: key)
        )
        guard let combined = sealed.combined else {
            throw TrashLedgerStoreError.corrupted
        }
        return magic + combined
    }

    static func decrypt(_ data: Data, key: Data) throws -> TrashLedger {
        guard key.count == 32 else {
            throw TrashLedgerStoreError.invalidKey
        }
        guard data.count > magic.count, data.prefix(magic.count) == magic else {
            throw TrashLedgerStoreError.corrupted
        }
        let payload = data.dropFirst(magic.count)
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: payload)
        } catch {
            throw TrashLedgerStoreError.corrupted
        }
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key))
        } catch {
            throw TrashLedgerStoreError.authenticationFailed
        }
        do {
            return try JSONDecoder().decode(TrashLedger.self, from: plaintext)
        } catch {
            throw TrashLedgerStoreError.corrupted
        }
    }
}

// MARK: - 批量迁移

public struct VaultBatchMigrationItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: UnifiedVaultItemKind
    public let title: String

    public init(
        id: String,
        kind: UnifiedVaultItemKind,
        title: String
    ) {
        self.id = id
        self.kind = kind
        self.title = title
    }
}

public struct VaultBatchMigrationOutcome: Sendable, Equatable {
    public let sourceProjectID: String
    public let targetProjectID: String
    public let movedEntries: [LocalVaultMovedEntry]
    public let movedAttachmentIDs: [String]
    public let movedExtrasItemIDs: [String]

    public init(
        sourceProjectID: String,
        targetProjectID: String,
        movedEntries: [LocalVaultMovedEntry],
        movedAttachmentIDs: [String],
        movedExtrasItemIDs: [String]
    ) {
        self.sourceProjectID = sourceProjectID
        self.targetProjectID = targetProjectID
        self.movedEntries = movedEntries
        self.movedAttachmentIDs = movedAttachmentIDs
        self.movedExtrasItemIDs = movedExtrasItemIDs
    }

    public var movedCount: Int {
        movedEntries.count
    }
}

/// 迁移前的安全检查失败：这时还没有改动任何条目。
public enum VaultBatchMigrationPrecheckError: Error, LocalizedError, Equatable {
    case emptySelection
    case sameProject
    case projectUnavailable(String)
    case duplicateItemIDs([String])
    case unavailableItems([String])

    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "没有选择要迁移的条目。"
        case .sameProject:
            return "目标分类与当前分类相同。"
        case .projectUnavailable(let projectID):
            return "找不到分类「\(projectID)」，可能已被删除。"
        case .duplicateItemIDs(let ids):
            return "选择中存在重复条目（\(ids.joined(separator: "、"))），为避免侧表覆盖已取消迁移。"
        case .unavailableItems(let titles):
            return "以下条目已不在当前分类，迁移未开始：\(titles.joined(separator: "、"))。"
        }
    }
}

/// 迁移中途失败：已经移动的条目会按逆序回滚，错误里带上回滚结果。
public struct VaultBatchMigrationFailure: Error, LocalizedError, Equatable, Sendable {
    public let failedItemID: String
    public let failedItemTitle: String
    public let failedIndex: Int
    public let totalCount: Int
    public let reason: String
    public let movedBeforeFailure: Int
    public let rolledBackCount: Int
    public let rollbackFailures: [String]

    public init(
        failedItemID: String,
        failedItemTitle: String,
        failedIndex: Int,
        totalCount: Int,
        reason: String,
        movedBeforeFailure: Int,
        rolledBackCount: Int,
        rollbackFailures: [String]
    ) {
        self.failedItemID = failedItemID
        self.failedItemTitle = failedItemTitle
        self.failedIndex = failedIndex
        self.totalCount = totalCount
        self.reason = reason
        self.movedBeforeFailure = movedBeforeFailure
        self.rolledBackCount = rolledBackCount
        self.rollbackFailures = rollbackFailures
    }

    public var errorDescription: String? {
        var text = "移动第 \(failedIndex + 1)/\(totalCount) 项「\(failedItemTitle)」失败：\(reason)。"
        if movedBeforeFailure == 0 {
            text += "没有条目被移动，源分类保持不变。"
        } else if rolledBackCount == movedBeforeFailure {
            text += "已回滚 \(rolledBackCount) 项，源分类数据保持完整，可以重试。"
        } else {
            text += "只回滚了 \(rolledBackCount)/\(movedBeforeFailure) 项，"
            text += "其余 \(movedBeforeFailure - rolledBackCount) 项仍在目标分类，请手动移回或重试。"
        }
        if !rollbackFailures.isEmpty {
            text += "回滚异常：" + rollbackFailures.joined(separator: "；") + "。"
        }
        return text
    }
}

// MARK: - 永久清理结果

public struct TrashPurgeSkip: Sendable, Equatable, Identifiable {
    public let record: TrashRetentionRecord
    public let reason: String

    public var id: String {
        record.id
    }

    public init(record: TrashRetentionRecord, reason: String) {
        self.record = record
        self.reason = reason
    }
}

public struct TrashPurgeFailure: Sendable, Equatable, Identifiable {
    public let record: TrashRetentionRecord
    public let message: String

    public var id: String {
        record.id
    }

    public init(record: TrashRetentionRecord, message: String) {
        self.record = record
        self.message = message
    }
}

public struct TrashPurgeOutcome: Sendable, Equatable {
    public var purgedItemIDs: [String]
    public var purgedAttachmentIDs: [String]
    public var skipped: [TrashPurgeSkip]
    public var failures: [TrashPurgeFailure]
    public var wasCancelled: Bool

    public init(
        purgedItemIDs: [String] = [],
        purgedAttachmentIDs: [String] = [],
        skipped: [TrashPurgeSkip] = [],
        failures: [TrashPurgeFailure] = [],
        wasCancelled: Bool = false
    ) {
        self.purgedItemIDs = purgedItemIDs
        self.purgedAttachmentIDs = purgedAttachmentIDs
        self.skipped = skipped
        self.failures = failures
        self.wasCancelled = wasCancelled
    }

    public var purgedCount: Int {
        purgedItemIDs.count
    }

    public var hasFailures: Bool {
        !failures.isEmpty
    }
}

// MARK: - 仓库扩展

public extension LocalVaultEntryRepository {
    /// 当前分类回收站里的全部条目（12 种类型），不包含已永久清理的条目。
    /// `deletedAt` 需要调用方从 `TrashLedger` 补上。
    func listTrashEntries(projectID: String) throws -> [TrashRetentionRecord] {
        var records: [TrashRetentionRecord] = []
        for kind in UnifiedVaultItemKind.allCases {
            let entries: [EntrySummary]
            do {
                entries = try deletedEntrySummaries(kind: kind, projectID: projectID)
            } catch LocalVaultRepositoryError.unsupportedEntryType {
                // 当前引擎不支持的条目类型没有回收站数据，跳过即可。
                continue
            }
            records.append(contentsOf: entries.map {
                TrashRetentionRecord(
                    id: $0.id,
                    kind: kind,
                    projectID: projectID,
                    title: $0.title
                )
            })
        }
        return records
    }

    /// 统计分类里仍处于删除状态的条目 ID，用来在清理前二次确认「只清理已标记删除的条目」。
    func deletedEntryIdentifiers(
        kind: UnifiedVaultItemKind,
        projectID: String
    ) throws -> Set<String> {
        Set(try deletedEntrySummaries(kind: kind, projectID: projectID).map(\.id))
    }

    /// 批量迁移：先预检，再逐条移动；任意一步失败都会把已经移动的条目按逆序回滚。
    ///
    /// 复用 `moveEntry(kind:entryID:fromProjectID:toProjectID:)`，所以加密、索引和
    /// 侧表跟随（`moveItemExtras`）与单条移动完全一致。
    func moveEntries(
        _ items: [VaultBatchMigrationItem],
        fromProjectID: String,
        toProjectID: String
    ) throws -> VaultBatchMigrationOutcome {
        guard !items.isEmpty else {
            throw VaultBatchMigrationPrecheckError.emptySelection
        }
        guard fromProjectID != toProjectID else {
            throw VaultBatchMigrationPrecheckError.sameProject
        }

        let projects = try listProjects()
        let projectIDs = Set(projects.map(\.id))
        guard projectIDs.contains(fromProjectID) else {
            throw VaultBatchMigrationPrecheckError.projectUnavailable(fromProjectID)
        }
        guard projectIDs.contains(toProjectID) else {
            throw VaultBatchMigrationPrecheckError.projectUnavailable(toProjectID)
        }

        var seen: Set<String> = []
        var duplicates: [String] = []
        for item in items where !seen.insert(item.id).inserted {
            duplicates.append(item.id)
        }
        guard duplicates.isEmpty else {
            throw VaultBatchMigrationPrecheckError.duplicateItemIDs(duplicates)
        }

        var unavailable: [String] = []
        for item in items {
            let ids = try activeEntryIdentifiers(kind: item.kind, projectID: fromProjectID)
            if !ids.contains(item.id) {
                unavailable.append("「\(item.title)」(\(item.kind.displayName))")
            }
        }
        guard unavailable.isEmpty else {
            throw VaultBatchMigrationPrecheckError.unavailableItems(unavailable)
        }

        let extrasBefore = try listItemExtras(projectID: fromProjectID)
        let attachmentsByEntry = Dictionary(
            grouping: try listAttachmentMetadata(projectID: fromProjectID).filter { $0.deleted == false },
            by: { $0.entryID ?? "" }
        )

        var moved: [(item: VaultBatchMigrationItem, attachmentIDs: [String], hadExtras: Bool)] = []
        var movedEntries: [LocalVaultMovedEntry] = []
        var movedAttachmentIDs: [String] = []
        var movedExtrasItemIDs: [String] = []

        for (index, item) in items.enumerated() {
            let attachmentIDs = (attachmentsByEntry[item.id] ?? []).map(\.id)
            let hadExtras = extrasBefore[item.id] != nil
            do {
                let entry = try moveEntry(
                    kind: item.kind,
                    entryID: item.id,
                    fromProjectID: fromProjectID,
                    toProjectID: toProjectID
                )
                for attachmentID in attachmentIDs {
                    _ = try moveEntry(
                        kind: .attachmentRef,
                        entryID: attachmentID,
                        fromProjectID: fromProjectID,
                        toProjectID: toProjectID
                    )
                }
                try verifyMove(
                    item: item,
                    attachmentIDs: attachmentIDs,
                    hadExtras: hadExtras,
                    fromProjectID: fromProjectID,
                    toProjectID: toProjectID
                )
                moved.append((item, attachmentIDs, hadExtras))
                movedEntries.append(entry)
                movedAttachmentIDs.append(contentsOf: attachmentIDs)
                if hadExtras {
                    movedExtrasItemIDs.append(item.id)
                }
            } catch {
                let rollback = rollbackMoves(
                    moved,
                    originalProjectID: fromProjectID,
                    movedToProjectID: toProjectID
                )
                throw VaultBatchMigrationFailure(
                    failedItemID: item.id,
                    failedItemTitle: item.title,
                    failedIndex: index,
                    totalCount: items.count,
                    reason: readableMessage(error),
                    movedBeforeFailure: moved.count,
                    rolledBackCount: rollback.rolledBackCount,
                    rollbackFailures: rollback.failures
                )
            }
        }

        return VaultBatchMigrationOutcome(
            sourceProjectID: fromProjectID,
            targetProjectID: toProjectID,
            movedEntries: movedEntries,
            movedAttachmentIDs: movedAttachmentIDs,
            movedExtrasItemIDs: movedExtrasItemIDs
        )
    }

    /// 永久清理回收站条目。
    ///
    /// 只处理确实还处于删除状态的条目；清理前会再次核对，避免把已恢复的条目误删。
    /// 附件引用（`entryID` 指向被清理条目的活动引用）与自定义字段侧表会一起清理，
    /// 避免留下孤儿数据。`shouldContinue` 会在每条之间调用，返回 `false` 时停止。
    func purgeTrashEntries(
        _ records: [TrashRetentionRecord],
        shouldContinue: (() -> Bool)? = nil
    ) -> TrashPurgeOutcome {
        var outcome = TrashPurgeOutcome()
        var deletedCache: [String: Set<String>] = [:]

        for record in records {
            if let shouldContinue, !shouldContinue() {
                outcome.wasCancelled = true
                break
            }
            let cacheKey = record.kind.rawValue + "\u{1F}" + record.projectID
            do {
                if deletedCache[cacheKey] == nil {
                    // 当前引擎不支持的条目类型按「没有删除数据」处理，条目会被安全跳过。
                    deletedCache[cacheKey] = (try? deletedEntryIdentifiers(
                        kind: record.kind,
                        projectID: record.projectID
                    )) ?? []
                }
                guard deletedCache[cacheKey]?.contains(record.id) == true else {
                    outcome.skipped.append(
                        TrashPurgeSkip(record: record, reason: "条目已恢复或已不存在，已跳过。")
                    )
                    continue
                }

                var purgedAttachmentIDs: [String] = []
                if record.kind != .attachmentRef {
                    let references = try listAttachmentMetadata(projectID: record.projectID)
                        .filter { $0.entryID == record.id && $0.deleted == false }
                    for reference in references {
                        try deleteAttachmentMetadata(
                            projectID: record.projectID,
                            attachmentID: reference.id
                        )
                        purgedAttachmentIDs.append(reference.id)
                    }
                }

                let extras = try listItemExtras(projectID: record.projectID)
                if extras[record.id] != nil {
                    try deleteItemExtras(projectID: record.projectID, itemID: record.id)
                }

                deletedCache[cacheKey]?.remove(record.id)
                outcome.purgedItemIDs.append(record.id)
                outcome.purgedAttachmentIDs.append(contentsOf: purgedAttachmentIDs)
            } catch {
                outcome.failures.append(
                    TrashPurgeFailure(record: record, message: readableMessage(error))
                )
            }
        }
        return outcome
    }

    /// 分类里全部活动条目 ID，用作迁移前预检与迁移后校验。
    func activeEntryIdentifiers(
        kind: UnifiedVaultItemKind,
        projectID: String
    ) throws -> Set<String> {
        switch kind {
        case .login:
            return Set(try listLoginEntries(projectID: projectID).map(\.id))
        case .note:
            return Set(try listNoteEntries(projectID: projectID).map(\.id))
        case .totp:
            return Set(try listTotpEntries(projectID: projectID).map(\.id))
        case .card:
            return Set(try listCardEntries(projectID: projectID).map(\.id))
        case .identity:
            return Set(try listIdentityEntries(projectID: projectID).map(\.id))
        case .passkey:
            return Set(try listPasskeyEntries(projectID: projectID).map(\.id))
        case .sshKey:
            return Set(try listSshKeyEntries(projectID: projectID).map(\.id))
        case .apiToken:
            return Set(try listApiTokenEntries(projectID: projectID).map(\.id))
        case .wifi:
            return Set(try listWifiEntries(projectID: projectID).map(\.id))
        case .sso:
            return Set(try listSSOEntries(projectID: projectID).map(\.id))
        case .send:
            return Set(try listSendEntries(projectID: projectID).map(\.id))
        case .steam:
            return Set(try listSteamEntries(projectID: projectID).map(\.id))
        case .attachmentRef:
            return Set(
                try listAttachmentMetadata(projectID: projectID)
                    .filter { $0.deleted == false }
                    .map(\.id)
            )
        }
    }
}

// MARK: - 私有辅助

private extension LocalVaultEntryRepository {
    struct EntrySummary {
        let id: String
        let title: String
    }

    func deletedEntrySummaries(
        kind: UnifiedVaultItemKind,
        projectID: String
    ) throws -> [EntrySummary] {
        switch kind {
        case .login:
            return try listDeletedLoginEntries(projectID: projectID)
                .map { EntrySummary(id: $0.id, title: $0.title) }
        case .note:
            return try listDeletedNoteEntries(projectID: projectID)
                .map { EntrySummary(id: $0.id, title: $0.title) }
        case .totp:
            return try listDeletedTotpEntries(projectID: projectID)
                .map { EntrySummary(id: $0.id, title: $0.title) }
        case .card:
            return try listDeletedCardEntries(projectID: projectID)
                .map { EntrySummary(id: $0.id, title: $0.title) }
        case .identity:
            return try listDeletedIdentityEntries(projectID: projectID)
                .map { EntrySummary(id: $0.id, title: $0.title) }
        case .passkey:
            return try listDeletedPasskeyEntries(projectID: projectID)
                .map { EntrySummary(id: $0.id, title: $0.title) }
        case .sshKey:
            return try listDeletedSshKeyEntries(projectID: projectID)
                .map { EntrySummary(id: $0.id, title: $0.title) }
        case .apiToken:
            return try listDeletedApiTokenEntries(projectID: projectID)
                .map { EntrySummary(id: $0.id, title: $0.title) }
        case .wifi:
            return try listDeletedWifiEntries(projectID: projectID)
                .map { EntrySummary(id: $0.id, title: $0.title) }
        case .sso:
            return try listDeletedSSOEntries(projectID: projectID)
                .map { EntrySummary(id: $0.id, title: $0.title) }
        case .send:
            return try listDeletedSendEntries(projectID: projectID)
                .map { EntrySummary(id: $0.id, title: $0.title) }
        case .steam:
            return try listDeletedSteamEntries(projectID: projectID)
                .map { EntrySummary(id: $0.id, title: $0.title) }
        case .attachmentRef:
            return try listDeletedAttachmentMetadata(projectID: projectID)
                .map { EntrySummary(id: $0.id, title: $0.fileName) }
        }
    }

    func verifyMove(
        item: VaultBatchMigrationItem,
        attachmentIDs: [String],
        hadExtras: Bool,
        fromProjectID: String,
        toProjectID: String
    ) throws {
        let targetIDs = try activeEntryIdentifiers(kind: item.kind, projectID: toProjectID)
        guard targetIDs.contains(item.id) else {
            throw VaultBatchMigrationVerificationError.targetMissing(item.title)
        }
        let sourceIDs = try activeEntryIdentifiers(kind: item.kind, projectID: fromProjectID)
        guard !sourceIDs.contains(item.id) else {
            throw VaultBatchMigrationVerificationError.sourceStillContains(item.title)
        }
        if hadExtras {
            let targetExtras = try listItemExtras(projectID: toProjectID)
            guard targetExtras[item.id] != nil else {
                throw VaultBatchMigrationVerificationError.extrasLost(item.title)
            }
        }
        if !attachmentIDs.isEmpty {
            let targetAttachmentIDs = try activeEntryIdentifiers(
                kind: .attachmentRef,
                projectID: toProjectID
            )
            let missing = attachmentIDs.filter { !targetAttachmentIDs.contains($0) }
            guard missing.isEmpty else {
                throw VaultBatchMigrationVerificationError.attachmentsMissing(missing.count)
            }
        }
        // 回读一次删除列表，确认迁移没有把条目带进目标分类的回收站。
        let targetDeleted = try deletedEntryIdentifiers(kind: item.kind, projectID: toProjectID)
        guard !targetDeleted.contains(item.id) else {
            throw VaultBatchMigrationVerificationError.itemLandedInTrash(item.title)
        }
    }

    func rollbackMoves(
        _ moved: [(item: VaultBatchMigrationItem, attachmentIDs: [String], hadExtras: Bool)],
        originalProjectID: String,
        movedToProjectID: String
    ) -> (rolledBackCount: Int, failures: [String]) {
        var rolledBack = 0
        var failures: [String] = []
        for record in moved.reversed() {
            do {
                for attachmentID in record.attachmentIDs.reversed() {
                    _ = try moveEntry(
                        kind: .attachmentRef,
                        entryID: attachmentID,
                        fromProjectID: movedToProjectID,
                        toProjectID: originalProjectID
                    )
                }
                _ = try moveEntry(
                    kind: record.item.kind,
                    entryID: record.item.id,
                    fromProjectID: movedToProjectID,
                    toProjectID: originalProjectID
                )
                let sourceIDs = try activeEntryIdentifiers(
                    kind: record.item.kind,
                    projectID: originalProjectID
                )
                if sourceIDs.contains(record.item.id) {
                    rolledBack += 1
                } else {
                    failures.append("「\(record.item.title)」未回到源分类")
                }
            } catch {
                failures.append("「\(record.item.title)」回滚失败：\(readableMessage(error))")
            }
        }
        return (rolledBack, failures)
    }

    func readableMessage(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return String(describing: error)
    }
}

enum VaultBatchMigrationVerificationError: Error, LocalizedError, Equatable {
    case targetMissing(String)
    case sourceStillContains(String)
    case extrasLost(String)
    case attachmentsMissing(Int)
    case itemLandedInTrash(String)

    var errorDescription: String? {
        switch self {
        case .targetMissing(let title):
            return "「\(title)」没有出现在目标分类，已回滚"
        case .sourceStillContains(let title):
            return "「\(title)」仍留在源分类，已回滚"
        case .extrasLost(let title):
            return "「\(title)」的自定义字段没有跟随迁移，已回滚"
        case .attachmentsMissing(let count):
            return "\(count) 个附件引用没有跟随迁移，已回滚"
        case .itemLandedInTrash(let title):
            return "「\(title)」被移进了目标分类的回收站，已回滚"
        }
    }
}
