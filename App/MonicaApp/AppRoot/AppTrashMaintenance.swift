//
//  AppTrashMaintenance.swift
//  Monica
//
//  回收站保留策略（#28）：删除时间账本、到期清理、手动清空与批量迁移入口。
//  账本按 Vault 隔离加密落盘，密钥放 Keychain（解锁才可读）；删除时间不写明文。
//

import Foundation
import MonicaStorage
import Security

// MARK: - 保留策略的本地偏好

/// 保留策略是用户偏好，不含敏感内容，按 Vault 无关的键放在 UserDefaults。
protocol TrashRetentionPreferenceStoring {
    func loadPolicy() -> TrashRetentionPolicy
    func savePolicy(_ policy: TrashRetentionPolicy)
}

struct UserDefaultsTrashRetentionPreferenceStore: TrashRetentionPreferenceStoring {
    static let key = "com.monicapass.monica.trashRetentionPolicy"

    let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func loadPolicy() -> TrashRetentionPolicy {
        guard let raw = userDefaults.string(forKey: Self.key),
              let policy = TrashRetentionPolicy(rawValue: raw) else {
            return .standard
        }
        return policy
    }

    func savePolicy(_ policy: TrashRetentionPolicy) {
        userDefaults.set(policy.rawValue, forKey: Self.key)
    }
}

// MARK: - 账本密钥（Keychain）

enum TrashLedgerKeychainError: LocalizedError, Sendable {
    case keyMaterialUnavailable
    case vaultLocked
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keyMaterialUnavailable:
            return String(localized: "无法读取回收站账本密钥，回收站清理已暂停。")
        case .vaultLocked:
            return String(localized: "保险库已锁定，无法读写回收站账本。")
        case .unexpectedStatus(let status):
            return String(format: String(localized: "回收站账本密钥读取失败（%d）。"), status)
        }
    }
}

/// 每个 Vault 一把 32 字节密钥，`WhenUnlockedThisDeviceOnly`：
/// 设备锁定时读不到，也不会跟着备份迁移到其他设备。
struct TrashLedgerKeychain: TrashLedgerKeyProviding {
    static let defaultService = "com.monicapass.monica.trash-ledger"
    static let requiredByteCount = 32

    let vaultID: String
    let service: String

    init(vaultID: String, service: String = defaultService) {
        self.vaultID = vaultID
        self.service = service
    }

    /// `TrashLedgerStore` 的注入点：每个 Vault 一份独立密钥。
    func trashLedgerKey() throws -> Data {
        try keyMaterial(for: vaultID)
    }

    func keyMaterial(for vaultID: String) throws -> Data {
        if let existing = try load(vaultID: vaultID) {
            return existing
        }
        let material = try randomKeyMaterial()
        try save(material, vaultID: vaultID)
        return material
    }

    func removeKeyMaterial(for vaultID: String) throws {
        let status = SecItemDelete(baseQuery(vaultID: vaultID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TrashLedgerKeychainError.unexpectedStatus(status)
        }
    }

    private func randomKeyMaterial() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: Self.requiredByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw TrashLedgerKeychainError.unexpectedStatus(status)
        }
        return Data(bytes)
    }

    private func load(vaultID: String) throws -> Data? {
        var query = baseQuery(vaultID: vaultID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  data.count == Self.requiredByteCount else {
                throw TrashLedgerKeychainError.keyMaterialUnavailable
            }
            return data
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed, errSecNotAvailable:
            throw TrashLedgerKeychainError.vaultLocked
        default:
            throw TrashLedgerKeychainError.unexpectedStatus(status)
        }
    }

    private func save(_ material: Data, vaultID: String) throws {
        SecItemDelete(baseQuery(vaultID: vaultID) as CFDictionary)

        var query = baseQuery(vaultID: vaultID)
        query[kSecValueData as String] = material
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw status == errSecInteractionNotAllowed
                ? TrashLedgerKeychainError.vaultLocked
                : TrashLedgerKeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(vaultID: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultID,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }
}

extension TrashRetentionPolicy {
    var displayName: String {
        switch self {
        case .sevenDays:
            return String(localized: "7 天")
        case .thirtyDays:
            return String(localized: "30 天")
        case .ninetyDays:
            return String(localized: "90 天")
        case .never:
            return String(localized: "永久保留")
        }
    }
}

// MARK: - 会话级回收站维护

/// 管理当前 Vault 的删除时间账本，并把「到期清理」限制在确实还处于删除态的条目上。
@MainActor
final class AppTrashMaintenance {
    private let policyStore: any TrashRetentionPreferenceStoring
    private let keyProviderFactory: (String) -> any TrashLedgerKeyProviding
    private let directoryURL: URL
    private let clock: () -> Date

    private var store: TrashLedgerStore?
    private var ledger = TrashLedger()
    private(set) var vaultID: String?
    private(set) var lastErrorMessage: String?
    private var autoPurgedProjects: Set<String> = []

    init(
        policyStore: any TrashRetentionPreferenceStoring = UserDefaultsTrashRetentionPreferenceStore(),
        keyProviderFactory: @escaping (String) -> any TrashLedgerKeyProviding = {
            TrashLedgerKeychain(vaultID: $0)
        },
        directoryURL: URL = TrashLedgerStore.defaultDirectoryURL(),
        clock: @escaping () -> Date = Date.init
    ) {
        self.policyStore = policyStore
        self.keyProviderFactory = keyProviderFactory
        self.directoryURL = directoryURL
        self.clock = clock
    }

    var policy: TrashRetentionPolicy {
        get { policyStore.loadPolicy() }
        set { policyStore.savePolicy(newValue) }
    }

    var isReady: Bool {
        store != nil
    }

    /// 首次进入某个 Vault 时装载（或新建）加密账本；同一 Vault 重复调用是幂等的。
    @discardableResult
    func prepareIfNeeded(vaultID: String) -> Bool {
        if self.vaultID == vaultID, isReady {
            return true
        }
        guard self.vaultID == nil || !isReady else {
            // 已为另一个 Vault 装载过账本：先清空，避免把 A 库的删除时间用到 B 库。
            reset()
            return prepareIfNeeded(vaultID: vaultID)
        }

        do {
            let store = TrashLedgerStore(
                directoryURL: directoryURL,
                keyProvider: keyProviderFactory(vaultID)
            )
            ledger = try store.loadLedger(vaultID: vaultID)
            self.store = store
            self.vaultID = vaultID
            lastErrorMessage = nil
            return true
        } catch {
            store = nil
            self.vaultID = nil
            ledger = TrashLedger()
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    func reset() {
        store = nil
        ledger = TrashLedger()
        vaultID = nil
        autoPurgedProjects.removeAll()
    }

    func isPurged(_ itemID: String) -> Bool {
        ledger.isPurged(itemID)
    }

    /// 当前分类回收站里的条目，并补上账本里的删除时间；已永久清理的不再出现。
    func records(
        projectID: String,
        repository: LocalVaultEntryRepository
    ) throws -> [TrashRetentionRecord] {
        try repository.listTrashEntries(projectID: projectID)
            .filter { !ledger.isPurged($0.id) }
            .map { record in
                TrashRetentionRecord(
                    id: record.id,
                    kind: record.kind,
                    projectID: record.projectID,
                    title: record.displayTitle,
                    deletedAt: ledger.deletedAt(for: record.id)
                )
            }
    }

    func plan(
        projectID: String,
        repository: LocalVaultEntryRepository,
        policy: TrashRetentionPolicy? = nil,
        now: Date? = nil
    ) throws -> TrashRetentionPlan {
        TrashRetentionEvaluator.plan(
            records: try records(projectID: projectID, repository: repository),
            policy: policy ?? self.policy,
            now: now ?? clock()
        )
    }

    /// 只按账本估算当前分类已到期的数量，供 UI 在列表刷新后即时显示，不额外读库。
    func expiredCount(
        projectID: String,
        policy: TrashRetentionPolicy,
        now: Date? = nil
    ) -> Int {
        guard let interval = policy.retentionInterval else {
            return 0
        }
        let reference = now ?? clock()
        return ledger.records.values.filter { record in
            record.projectID == projectID
                && record.purgedAt == nil
                && reference.timeIntervalSince(record.deletedAt) > interval
        }.count
    }

    /// 把「第一次观测到处于删除态」的时间记进账本；已恢复的条目移除记录，便于重新计时。
    func sync(projectID: String, repository: LocalVaultEntryRepository) throws {
        guard isReady else {
            return
        }
        var changed = false
        let deleted = try repository.listTrashEntries(projectID: projectID)
        let now = clock()

        for record in deleted where ledger.record(for: record.id) == nil {
            ledger.recordDeletion(
                itemID: record.id,
                kind: record.kind,
                projectID: projectID,
                title: record.displayTitle,
                at: now
            )
            changed = true
        }

        for kind in UnifiedVaultItemKind.allCases {
            guard let active = try? repository.activeEntryIdentifiers(
                kind: kind,
                projectID: projectID
            ) else {
                continue
            }
            for itemID in active where ledger.record(for: itemID) != nil {
                ledger.markRestored(itemID: itemID)
                changed = true
            }
        }

        if changed {
            persist()
        }
    }

    /// 永久清理给定条目；只有仓库确认仍在删除态的条目才会被处理。
    func purge(
        _ records: [TrashRetentionRecord],
        repository: LocalVaultEntryRepository,
        shouldContinue: (() -> Bool)? = nil
    ) -> TrashPurgeOutcome {
        let outcome = repository.purgeTrashEntries(records, shouldContinue: shouldContinue)
        guard !outcome.purgedItemIDs.isEmpty else {
            return outcome
        }
        ledger.markPurged(itemIDs: outcome.purgedItemIDs, at: clock())
        persist()
        return outcome
    }

    /// 打开分类或迁移后触发一次；每个分类每个会话只自动清理一次，避免刷新循环。
    func autoPurgeIfNeeded(
        projectID: String,
        repository: LocalVaultEntryRepository
    ) -> TrashPurgeOutcome {
        guard isReady,
              policy.isAutomaticPurgeEnabled,
              !autoPurgedProjects.contains(projectID),
              let plan = try? plan(projectID: projectID, repository: repository),
              !plan.expired.isEmpty else {
            return TrashPurgeOutcome()
        }
        autoPurgedProjects.insert(projectID)
        return purge(plan.expired, repository: repository)
    }

    private func persist() {
        guard let store, let vaultID else {
            return
        }
        do {
            try store.saveLedger(ledger, vaultID: vaultID)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - 会话入口

extension AppSessionModel {
    func setTrashRetentionPolicy(_ policy: TrashRetentionPolicy) {
        recordUserActivity()
        trashMaintenance.policy = policy
        trashRetentionPolicy = policy
        refreshTrashPreviewFromLoadedLists()
    }

    /// 打开回收站页时调用：装载账本、同步删除时间，再刷新预览数量。
    func refreshTrashMaintenancePreview() {
        trashRetentionPolicy = trashMaintenance.policy
        guard vaultState == .unlocked,
              let repository = activeEntryRepository,
              let projectID = activeProject?.id,
              let session = activeVaultSession else {
            trashPreviewTotalCount = 0
            trashPreviewExpiredCount = 0
            return
        }
        trashMaintenance.prepareIfNeeded(vaultID: session.handle.vaultID)
        try? trashMaintenance.sync(projectID: projectID, repository: repository)
        refreshTrashPreviewFromLoadedLists()
        if let message = trashMaintenance.lastErrorMessage {
            trashMaintenanceMessage = message
        }
    }

    /// 从已经加载到内存的 12 个删除列表更新计数，供列表刷新后调用。
    func refreshTrashPreviewFromLoadedLists() {
        trashPreviewTotalCount = deletedLoginEntries.count
            + deletedNoteEntries.count
            + deletedTotpEntries.count
            + deletedCardEntries.count
            + deletedIdentityEntries.count
            + deletedPasskeyEntries.count
            + deletedSshKeyEntries.count
            + deletedApiTokenEntries.count
            + deletedWifiEntries.count
            + deletedSSOEntries.count
            + deletedSendEntries.count
            + deletedAttachmentEntries.count

        guard let projectID = activeProject?.id else {
            trashPreviewExpiredCount = 0
            return
        }
        trashPreviewExpiredCount = trashMaintenance.expiredCount(
            projectID: projectID,
            policy: trashRetentionPolicy
        )
    }

    /// 手动清理已到期条目（二次确认后调用）。返回真正清理的数量。
    @discardableResult
    func purgeExpiredTrashItems() throws -> Int {
        guard vaultState == .unlocked else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        guard let repository = activeEntryRepository,
              let projectID = activeProject?.id else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        if let session = activeVaultSession {
            trashMaintenance.prepareIfNeeded(vaultID: session.handle.vaultID)
        }
        let plan = try trashMaintenance.plan(
            projectID: projectID,
            repository: repository,
            policy: trashRetentionPolicy
        )
        guard !plan.expired.isEmpty else {
            trashMaintenanceMessage = String(localized: "没有已到期的回收站条目。")
            return 0
        }

        let outcome = trashMaintenance.purge(plan.expired, repository: repository)
        try refreshAllEntryLists(projectID: projectID, entryRepository: repository)
        applyTrashPurgeOutcome(outcome)
        return outcome.purgedCount
    }

    /// 清空当前分类回收站（二次确认后调用），包含未到期条目。
    ///
    /// 与保留策略无关：即使自动清理关闭（`.never`），用户仍可主动清空回收站；
    /// 二次确认由调用方 UI 负责，这里只做解锁与仓库可用性校验。
    @discardableResult
    func emptyTrashNow() throws -> Int {
        guard vaultState == .unlocked else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        guard let repository = activeEntryRepository,
              let projectID = activeProject?.id else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        if let session = activeVaultSession {
            trashMaintenance.prepareIfNeeded(vaultID: session.handle.vaultID)
        }
        let records = try trashMaintenance.records(projectID: projectID, repository: repository)
        guard !records.isEmpty else {
            trashMaintenanceMessage = String(localized: "回收站已经是空的。")
            return 0
        }

        let outcome = trashMaintenance.purge(records, repository: repository)
        try refreshAllEntryLists(projectID: projectID, entryRepository: repository)
        applyTrashPurgeOutcome(outcome)
        return outcome.purgedCount
    }

    func applyTrashPurgeOutcome(_ outcome: TrashPurgeOutcome, isAutomatic: Bool = false) {
        if outcome.hasFailures {
            let details = outcome.failures
                .map { "\($0.record.displayTitle)：\($0.message)" }
                .joined(separator: "\n")
            let message = String(
                format: String(localized: "有 %d 项清理失败：\n%@"),
                outcome.failures.count,
                details
            )
            trashMaintenanceMessage = message
            entryOperationState = .failed(message)
        } else if outcome.purgedCount == 0 {
            trashMaintenanceMessage = String(localized: "没有需要清理的条目。")
        } else {
            let message = String(
                format: String(localized: "已永久清理 %d 项，删除后无法恢复。"),
                outcome.purgedCount
            )
            trashMaintenanceMessage = message
            if !isAutomatic {
                entryOperationState = .succeeded(message)
            }
        }
    }
}
