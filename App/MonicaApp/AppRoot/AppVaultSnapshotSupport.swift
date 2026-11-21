//
//  AppVaultSnapshotSupport.swift
//  Monica
//
//  保险库快照（issue #30）：密钥托管、快照中心模型与索引/差异装配。
//
//  安全约定：
//  - 快照正文与索引都用 AES-GCM 加密（MonicaStorage.VaultSnapshotStore），
//    这里只负责提供 32 字节密钥并把它保存进 Keychain；
//  - 密钥、主密码、条目明文都不写 UserDefaults / 日志 / 崩溃信息；
//  - 快照文件落在 App 容器的 Application Support 下，目录权限随 App 沙盒。
//

import Foundation
import MonicaStorage
import Observation
import Security

// MARK: - 身份

/// 快照归属的保险库身份：MDBX 库 ID + 文件位置 + 展示名。
struct VaultSnapshotSubject: Sendable, Equatable {
    let vaultID: String
    let fileURL: URL
    let displayName: String
}

// MARK: - Keychain 密钥

/// 生产环境的快照密钥来源：每个保险库一把 32 字节随机密钥，只存在 Keychain。
///
/// - service：`ru.takagi.monica.vault-snapshot-key`
/// - account：MDBX 库 ID
/// - 可访问性：`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`（不随 iCloud 钥匙串同步）
struct AppVaultSnapshotKeyProvider: VaultSnapshotKeyProviding {
    static let defaultService = "ru.takagi.monica.vault-snapshot-key"
    static let keyLength = 32

    let service: String
    let accessGroup: String?

    init(service: String = AppVaultSnapshotKeyProvider.defaultService, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    func snapshotKey(forVaultID vaultID: String) throws -> Data {
        if let existing = try existingKey(vaultID: vaultID) {
            return existing
        }

        var bytes = [UInt8](repeating: 0, count: Self.keyLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw VaultSnapshotError.snapshotKeyUnavailable("随机密钥生成失败（\(status)）")
        }
        let key = Data(bytes)
        try store(key, vaultID: vaultID)
        return key
    }

    private func baseQuery(vaultID: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultID
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func existingKey(vaultID: String) throws -> Data? {
        var query = baseQuery(vaultID: vaultID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw VaultSnapshotError.invalidSnapshotKey
            }
            guard data.count == Self.keyLength else {
                throw VaultSnapshotError.invalidSnapshotKey
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw VaultSnapshotError.snapshotKeyUnavailable("读取快照密钥失败（\(status)）")
        }
    }

    private func store(_ key: Data, vaultID: String) throws {
        let query = baseQuery(vaultID: vaultID)
        // 先删后写，避免重复项；删除失败不影响后续写入结果判断。
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = key
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        addQuery[kSecAttrSynchronizable as String] = false

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw VaultSnapshotError.snapshotKeyUnavailable("写入快照密钥失败（\(status)）")
        }
    }
}

// MARK: - 存储位置

enum AppVaultSnapshotLocation {
    /// `Library/Application Support/MonicaVaultSnapshots`（随 App 沙盒）。
    static func rootDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MonicaVaultSnapshots", isDirectory: true)
    }

    static func makeStore(
        directoryURL: URL = rootDirectory(),
        keyProvider: any VaultSnapshotKeyProviding = AppVaultSnapshotKeyProvider(),
        retentionLimit: Int = VaultSnapshotStore.defaultRetentionLimit
    ) -> VaultSnapshotStore {
        VaultSnapshotStore(
            directoryURL: directoryURL,
            keyProvider: keyProvider,
            retentionLimit: retentionLimit
        )
    }
}

extension VaultSnapshotReason {
    var displayName: String {
        switch self {
        case .manual:
            return String(localized: "手动创建")
        case .automaticLock:
            return String(localized: "锁定时自动创建")
        case .preRestoreSafety:
            return String(localized: "恢复前回滚点")
        }
    }
}

// MARK: - 快照中心模型

/// 「保险库快照」页面的状态机：列出/创建/预览/恢复/清理。
///
/// 快照必须建立在静默的 MDBX 文件上，所以创建与恢复都会先调用
/// `AppSessionModel.lockLocalVault()` 关掉 FFI 连接；当前条目索引在关库前采集，
/// 关库后仍可用于「恢复会删掉哪些条目」的预览。
@MainActor
@Observable
final class VaultSnapshotCenterModel {
    enum Status: Equatable {
        case idle
        case running(String)
        case succeeded(String)
        case failed(String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }

        var message: String? {
            switch self {
            case .idle:
                return nil
            case .running(let message), .succeeded(let message), .failed(let message):
                return message
            }
        }

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    private(set) var subject: VaultSnapshotSubject?
    private(set) var records: [VaultSnapshotRecord] = []
    private(set) var status: Status = .idle
    private(set) var currentIndex: VaultSnapshotIndex?
    /// 当前库是否已解锁（决定「创建」按钮是否可用、能否实时对比）。
    private(set) var isVaultUnlocked = false
    /// 预览用的差异；`nil` 表示还没有可对比的当前索引。
    private(set) var previewDiff: VaultSnapshotDiff?

    let directoryURL: URL
    private let store: VaultSnapshotStore

    init(
        directoryURL: URL = AppVaultSnapshotLocation.rootDirectory(),
        keyProvider: any VaultSnapshotKeyProviding = AppVaultSnapshotKeyProvider(),
        retentionLimit: Int = VaultSnapshotStore.defaultRetentionLimit
    ) {
        self.directoryURL = directoryURL
        self.store = AppVaultSnapshotLocation.makeStore(
            directoryURL: directoryURL,
            keyProvider: keyProvider,
            retentionLimit: retentionLimit
        )
    }

    // MARK: 读取

    /// 刷新身份与快照列表；解锁状态下顺便采集当前索引。
    func reload(session: AppSessionModel) {
        isVaultUnlocked = session.vaultState == .unlocked
        subject = Self.resolveSubject(session: session)
        refreshRecords()
        if isVaultUnlocked, let index = makeCurrentIndex(session: session) {
            currentIndex = index
        }
    }

    private func refreshRecords() {
        guard let subject else {
            records = []
            return
        }
        records = (try? store.listSnapshots(vaultID: subject.vaultID)) ?? []
    }

    private static func resolveSubject(session: AppSessionModel) -> VaultSnapshotSubject? {
        if let active = session.activeVaultSession {
            return VaultSnapshotSubject(
                vaultID: active.handle.vaultID,
                fileURL: active.descriptor.fileURL,
                displayName: active.descriptor.displayName
            )
        }
        if let remembered = session.rememberedVaultIdentity {
            return VaultSnapshotSubject(
                vaultID: remembered.vaultID,
                fileURL: remembered.fileURL,
                displayName: remembered.displayName
            )
        }
        return nil
    }

    // MARK: 创建

    /// 创建一致性快照：先在解锁状态采集索引，再锁库（关闭 FFI 连接）后写快照。
    func createSnapshot(session: AppSessionModel) async {
        guard !status.isRunning else { return }
        guard let subject else {
            status = .failed(String(localized: "没有可用的保险库。"))
            return
        }
        guard session.vaultState == .unlocked, session.activeEntryRepository != nil else {
            status = .failed(String(localized: "请先解锁保险库，再创建快照。"))
            return
        }

        status = .running(String(localized: "正在锁定保险库并写入快照…"))
        let index = makeCurrentIndex(session: session) ?? .empty
        // 关掉 FFI 连接：MDBX 进入静默状态，-wal/-shm 才会收敛，快照才是一致的。
        session.lockLocalVault()
        isVaultUnlocked = false

        // 读库 + AES-GCM 是纯文件 IO，放到后台执行，避免关闭库后主线程卡住。
        let store = self.store
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try store.createSnapshot(
                    vaultFileURL: subject.fileURL,
                    vaultID: subject.vaultID,
                    vaultDisplayName: subject.displayName,
                    reason: .manual,
                    index: index
                )
            }.value
            currentIndex = index
            refreshRecords()
            status = .succeeded(String(localized: "快照已创建。为保证一致性，保险库已锁定。"))
        } catch {
            currentIndex = index
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: 预览

    /// 选择一份快照，计算「恢复后会发生什么」。
    func prepareRestorePreview(record: VaultSnapshotRecord, session: AppSessionModel) {
        isVaultUnlocked = session.vaultState == .unlocked
        if isVaultUnlocked, let index = makeCurrentIndex(session: session) {
            currentIndex = index
        }
        previewDiff = Self.makeDiff(snapshot: record, current: currentIndex)
    }

    private static func makeDiff(snapshot: VaultSnapshotRecord, current: VaultSnapshotIndex?) -> VaultSnapshotDiff? {
        guard let current else { return nil }
        return VaultSnapshotDiffEngine.diff(snapshot: snapshot.manifest.index, current: current)
    }

    // MARK: 恢复

    /// 恢复快照：若还处于解锁状态先锁库；存储层会先拍回滚点再原子替换。
    func restoreSnapshot(session: AppSessionModel) async {
        guard !status.isRunning else { return }
        guard let subject, let target = recordPendingRestore else {
            status = .failed(String(localized: "请选择要恢复的快照。"))
            return
        }

        if session.vaultState == .unlocked {
            if let index = makeCurrentIndex(session: session) {
                currentIndex = index
            }
            session.lockLocalVault()
            isVaultUnlocked = false
        }

        status = .running(String(localized: "正在恢复快照…"))
        // 恢复包含整库回读校验与原子替换，放到后台执行，保持界面可响应。
        let store = self.store
        let currentIndex = currentIndex ?? .empty
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try store.restoreSnapshot(
                    snapshotID: target.id,
                    vaultID: subject.vaultID,
                    to: subject.fileURL,
                    vaultDisplayName: subject.displayName,
                    currentIndex: currentIndex
                )
            }.value
            pendingRestoreRecordID = nil
            refreshRecords()
            status = .succeeded(
                result.safetySnapshot == nil
                    ? String(localized: "快照已恢复。")
                    : String(localized: "快照已恢复，并已创建恢复前回滚点。")
            )
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// 预览里点「恢复」时记录目标，`restoreSnapshot` 只信任这个 ID。
    private(set) var pendingRestoreRecordID: String?
    var recordPendingRestore: VaultSnapshotRecord? {
        guard let pendingRestoreRecordID else { return nil }
        return records.first { $0.id == pendingRestoreRecordID }
    }

    func confirmRestore(record: VaultSnapshotRecord) {
        pendingRestoreRecordID = record.id
    }

    /// 预览页关闭时清掉待恢复目标与差异，避免下次误用旧状态。
    func cancelRestoreConfirmation() {
        pendingRestoreRecordID = nil
        previewDiff = nil
    }

    // MARK: 删除

    func deleteSnapshot(_ record: VaultSnapshotRecord) {
        guard let subject else { return }
        do {
            try store.deleteSnapshot(snapshotID: record.id, vaultID: subject.vaultID)
            refreshRecords()
            status = .succeeded(String(localized: "快照已删除。"))
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func deleteAllSnapshots() {
        guard let subject else { return }
        do {
            let count = try store.deleteAllSnapshots(vaultID: subject.vaultID)
            refreshRecords()
            status = count > 0
                ? .succeeded(String(localized: "已清理全部快照。"))
                : .succeeded(String(localized: "没有需要清理的快照。"))
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: 索引

    /// 采集当前库的条目索引（只含标题/摘要这类非敏感投影）。
    ///
    /// 与搜索索引同源：遍历所有项目、把所有类型的条目/回收站条目读出来，
    /// 交给 `VaultSearchDocumentBuilder` 生成文档，再转成快照指纹。
    /// 读取失败的类型按「没有条目」处理——索引只用于差异预览，快照正文仍是完整字节。
    func makeCurrentIndex(session: AppSessionModel) -> VaultSnapshotIndex? {
        guard let repository = session.activeEntryRepository else { return nil }
        let projects = session.vaultProjects.map {
            VaultSnapshotProject(id: $0.id, title: $0.title)
        }
        var snapshot = VaultSearchEntrySnapshot()
        for project in projects {
            let projectID = project.id
            snapshot.loginEntries += (try? repository.listLoginEntries(projectID: projectID)) ?? []
            snapshot.deletedLoginEntries += (try? repository.listDeletedLoginEntries(projectID: projectID)) ?? []
            snapshot.noteEntries += (try? repository.listNoteEntries(projectID: projectID)) ?? []
            snapshot.deletedNoteEntries += (try? repository.listDeletedNoteEntries(projectID: projectID)) ?? []
            snapshot.totpEntries += (try? repository.listTotpEntries(projectID: projectID)) ?? []
            snapshot.deletedTotpEntries += (try? repository.listDeletedTotpEntries(projectID: projectID)) ?? []
            snapshot.cardEntries += (try? repository.listCardEntries(projectID: projectID)) ?? []
            snapshot.deletedCardEntries += (try? repository.listDeletedCardEntries(projectID: projectID)) ?? []
            snapshot.identityEntries += (try? repository.listIdentityEntries(projectID: projectID)) ?? []
            snapshot.deletedIdentityEntries += (try? repository.listDeletedIdentityEntries(projectID: projectID)) ?? []
            snapshot.passkeyEntries += (try? repository.listPasskeyEntries(projectID: projectID)) ?? []
            snapshot.deletedPasskeyEntries += (try? repository.listDeletedPasskeyEntries(projectID: projectID)) ?? []
            snapshot.sshKeyEntries += (try? repository.listSshKeyEntries(projectID: projectID)) ?? []
            snapshot.deletedSshKeyEntries += (try? repository.listDeletedSshKeyEntries(projectID: projectID)) ?? []
            snapshot.apiTokenEntries += (try? repository.listApiTokenEntries(projectID: projectID)) ?? []
            snapshot.deletedApiTokenEntries += (try? repository.listDeletedApiTokenEntries(projectID: projectID)) ?? []
            snapshot.wifiEntries += (try? repository.listWifiEntries(projectID: projectID)) ?? []
            snapshot.deletedWifiEntries += (try? repository.listDeletedWifiEntries(projectID: projectID)) ?? []
            snapshot.sendEntries += (try? repository.listSendEntries(projectID: projectID)) ?? []
            snapshot.deletedSendEntries += (try? repository.listDeletedSendEntries(projectID: projectID)) ?? []
            snapshot.steamEntries += (try? repository.listSteamEntries(projectID: projectID)) ?? []
            snapshot.deletedSteamEntries += (try? repository.listDeletedSteamEntries(projectID: projectID)) ?? []
            snapshot.attachmentEntries += (try? repository.listAttachmentMetadata(projectID: projectID)) ?? []
            snapshot.deletedAttachmentEntries += (try? repository.listDeletedAttachmentMetadata(projectID: projectID)) ?? []
        }

        let documents = VaultSearchDocumentBuilder.documents(from: snapshot)
        return VaultSnapshotIndexBuilder.index(projects: projects, documents: documents)
    }
}
