import Foundation
import MonicaCore
import MonicaSync
import Observation
import UIKit

/// App-layer orchestration for issue #31 (cloud vault sync).
///
/// The package (`MonicaSync/CloudVault/`) owns the protocol, the manifest, the
/// remote-store adapters and the push/pull/conflict decision engine. This file
/// only wires that engine to the running app: it builds local snapshots of the
/// active vault file, persists the per-device sync bookkeeping next to that
/// vault, and applies downloaded vault bytes.
///
/// Everything here runs on the main actor. The entire local vault is encrypted
/// at rest and all repository writes are serialized on the main actor, so a
/// snapshot taken here is consistent enough for the manual, foreground-only MVP
/// documented in `CLOUD_VAULT_SYNC_NOTES.md`.
enum AppCloudVaultSyncError: Error, LocalizedError {
    case vaultLocked
    case vaultUnavailable
    case applyFailed(String)

    var errorDescription: String? {
        switch self {
        case .vaultLocked:
            return "保险库已锁定，请先解锁后再同步云端保险库"
        case .vaultUnavailable:
            return "当前没有已打开的保险库，无法同步"
        case .applyFailed(let reason):
            return "无法应用云端保险库：\(reason)"
        }
    }
}

/// The two facts the settings UI needs after a remote vault was downloaded.
enum AppCloudVaultApplyResult: Equatable {
    /// The downloaded bytes belong to the vault that is currently open. The app
    /// closed it and replaced the file in place; the user must unlock again.
    case replacedLocalVaultNeedsUnlock
    /// The downloaded bytes belong to a different vault (e.g. restoring a vault
    /// created on another device). The file was validated and saved next to the
    /// local vaults; the user opens it from the lock screen.
    case savedNewVaultFile(URL)
}

/// Main-actor bridge between the sync coordinator and `AppSessionModel`.
struct AppCloudVaultSyncBridge {
    let vaultID: String
    let vaultName: String
    let vaultFileName: String
    let deviceID: String
    let deviceName: String
    let stateFileURL: URL
    let availableProviders: [CloudVaultRemoteKind]

    let makeStore: (CloudVaultRemoteKind) throws -> any CloudVaultRemoteStore
    let localSnapshot: @MainActor () throws -> CloudVaultLocalSnapshot
    /// Applies a download whose `vaultID` equals the open vault: closes the
    /// vault and atomically replaces its file. The app ends up locked.
    let applySameVault: @MainActor (CloudVaultPullOutcome) throws -> Void
    /// Validates a download from a *different* vault with its password and saves
    /// it as a new local vault file. Never touches the currently open vault.
    let adoptDifferentVault: @MainActor (CloudVaultPullOutcome, String) throws -> URL
    /// The host a provider talks to, when the app knows it. Only the host is ever
    /// logged (never the path, query or credentials).
    var providerHost: (CloudVaultRemoteKind) -> URL? = { _ in nil }

    func provider(for kind: CloudVaultRemoteKind) -> Bool {
        availableProviders.contains(kind)
    }
}

/// Observable stage machine for the 云端保险库 settings screen.
@MainActor
@Observable
final class AppCloudVaultSyncCoordinator {
    enum Stage: Equatable {
        case idle
        case checking
        case pushing
        case pulling
        case resolvingConflict
        /// A remote vault with another identity was downloaded; the UI must ask
        /// for that vault's password before it can be adopted.
        case needsVaultPassword
        case finished(String)
        case failed(String)
    }

    let bridge: AppCloudVaultSyncBridge

    private(set) var stage: Stage = .idle
    private(set) var selectedProvider: CloudVaultRemoteKind
    private(set) var decision: CloudVaultSyncDecision?
    private(set) var conflict: CloudVaultConflict?
    private(set) var remoteSummary: String?
    private(set) var lastSyncedAt: Date?
    private(set) var remoteManifestRevision: Int?
    private(set) var pendingUpload: Bool = false
    private(set) var lastFailureMessage: String?
    private(set) var guidance: String?
    private(set) var statusMessage: String?
    private(set) var awaitingPasswordOutcome: CloudVaultPullOutcome?

    private let engine: CloudVaultSyncEngine
    private let stateStore: CloudVaultStateStore
    private var state: CloudVaultSyncState = CloudVaultSyncState()
    private var isPrepared = false
    /// Correlates every event of one user-triggered operation (issue #65).
    private var currentFlowID = UUID()

    init(bridge: AppCloudVaultSyncBridge) {
        self.bridge = bridge
        self.selectedProvider = bridge.availableProviders.first ?? .webDAV
        self.engine = CloudVaultSyncEngine()
        self.stateStore = CloudVaultStateStore(fileURL: bridge.stateFileURL)
    }

    var isBusy: Bool {
        switch stage {
        case .checking, .pushing, .pulling, .resolvingConflict:
            return true
        default:
            return false
        }
    }

    var canUseCloudVaultSync: Bool {
        !bridge.availableProviders.isEmpty
    }

    var providerDescription: String {
        switch selectedProvider {
        case .webDAV:
            return "使用设置中已配置的 WebDAV 服务器，上传完整的加密保险库文件与清单。"
        case .oneDrive:
            return "使用已登录的 OneDrive 应用文件夹，上传完整的加密保险库文件与清单。"
        case .iCloud:
            return "使用当前 Apple ID 的 iCloud 私人数据库，上传完整的加密保险库文件；云端记录里只有密文与不透明的版本标记。"
        }
    }

    var decisionDescription: String {
        guard let decision else { return "尚未检查云端版本。" }
        switch decision {
        case .upToDate:
            return "本机与云端一致，无需同步。"
        case .pushNew:
            return "云端还没有这个保险库，可以把本机版本上传为第 1 版。"
        case .pushUpdate:
            return "只有本机发生变化，上传后云端会得到新版本。"
        case .pullRemoteNewer:
            return "只有云端发生变化，可以从云端更新本机。"
        case .conflict:
            return "本机与云端都发生了变化，需要你选择保留哪一版。"
        }
    }

    // MARK: - Lifecycle

    func prepare() {
        guard !isPrepared else { return }
        isPrepared = true
        do {
            state = try stateStore.load()
            refreshRecordSummary()
        } catch {
            present(error: error)
        }
    }

    func selectProvider(_ kind: CloudVaultRemoteKind) {
        guard bridge.provider(for: kind) else { return }
        selectedProvider = kind
        decision = nil
        conflict = nil
        remoteSummary = nil
        refreshRecordSummary()
    }

    // MARK: - Actions

    func check() async {
        guard beginOperation(.checking) else { return }
        do {
            let local = try bridge.localSnapshot()
            let store = try makeStore()
            let remote = try await store.readRemote()
            let record = currentRecord(store: store)
            let plan = engine.plan(local: local, record: record, remote: remote)
            decision = plan
            if case .conflict(let detectedConflict) = plan {
                conflict = detectedConflict
            } else {
                conflict = nil
            }
            remoteSummary = remote?.redactedSummary
            remoteManifestRevision = remote?.manifest.revision
            stage = .finished(planDescription(for: plan))
        } catch {
            present(error: error)
        }
    }

    func push() async {
        guard beginOperation(.pushing) else { return }
        do {
            let local = try bridge.localSnapshot()
            let store = try makeStore()
            let record = currentRecord(store: store)
            guard let outcome = try await engine.push(local: local, store: store, record: record) else {
                decision = .upToDate
                stage = .finished("云端已是最新，无需上传。")
                return
            }
            applyPushOutcome(outcome)
            stage = .finished("已上传第 \(outcome.receipt.manifest.revision) 版（\(outcome.receipt.manifest.byteCount) 字节）。")
        } catch {
            present(error: error)
        }
    }

    func pull() async {
        guard beginOperation(.pulling) else { return }
        do {
            let store = try makeStore()
            let record = currentRecord(store: store)
            guard let outcome = try await engine.pull(store: store, record: record) else {
                decision = .upToDate
                stage = .finished("云端没有新版本。")
                return
            }
            try await applyDownloadedVault(outcome)
        } catch {
            present(error: error)
        }
    }

    func resolveConflict(_ resolution: CloudVaultConflictResolution) async {
        guard beginOperation(.resolvingConflict) else { return }
        do {
            let local = try bridge.localSnapshot()
            let store = try makeStore()
            let record = currentRecord(store: store)
            let outcome = try await engine.resolveConflict(resolution, local: local, store: store, record: record)
            switch resolution {
            case .keepLocal:
                if let pushOutcome = outcome.pushOutcome {
                    applyPushOutcome(pushOutcome)
                }
                conflict = nil
                stage = .finished("已用本机版本覆盖云端。")
            case .keepRemote:
                conflict = nil
                if let pullOutcome = outcome.pullOutcome {
                    try await applyDownloadedVault(pullOutcome)
                } else {
                    stage = .finished("已保留云端版本。")
                }
            case .createConflictCopy:
                conflict = nil
                if let copy = outcome.conflictCopyReceipt {
                    lastFailureMessage = nil
                    statusMessage = "冲突副本已上传：\(copy.fileName)"
                }
                if let pullOutcome = outcome.pullOutcome {
                    try await applyDownloadedVault(pullOutcome)
                } else {
                    stage = .finished(statusMessage ?? "已上传冲突副本。")
                }
            }
        } catch {
            present(error: error)
        }
    }

    /// Called by the UI when `stage == .needsVaultPassword`.
    func submitVaultPassword(_ password: String) async {
        guard let outcome = awaitingPasswordOutcome else { return }
        guard !password.isEmpty else {
            guidance = "请输入云端保险库的密码。"
            return
        }
        guard beginOperation(.pulling) else { return }
        do {
            let url = try bridge.adoptDifferentVault(outcome, password)
            saveConfirmedRecord(for: outcome)
            awaitingPasswordOutcome = nil
            stage = .finished("已下载并保存为「\(url.lastPathComponent)」。请锁定后可点击「打开已有保险库」选择该文件打开。")
        } catch let error as CloudVaultError {
            present(error: error)
        } catch {
            present(error: AppCloudVaultSyncError.applyFailed(error.localizedDescription))
        }
    }

    func cancelPasswordPrompt() {
        awaitingPasswordOutcome = nil
        if stage == .needsVaultPassword {
            stage = .idle
        }
    }

    func resetState() {
        state = CloudVaultSyncState()
        do {
            try stateStore.save(state)
        } catch {
            present(error: error)
        }
        decision = nil
        conflict = nil
        remoteSummary = nil
        lastSyncedAt = nil
        remoteManifestRevision = nil
        pendingUpload = false
        lastFailureMessage = nil
        statusMessage = "已清除本机的云端同步记录，云端文件保持不动。"
        stage = .finished(statusMessage ?? "已重置。")
    }

    func clearFailure() {
        if case .failed = stage {
            stage = .idle
        }
        guidance = nil
    }

    // MARK: - Internal

    private func beginOperation(_ next: Stage) -> Bool {
        guard !isBusy else { return false }
        stage = next
        lastFailureMessage = nil
        guidance = nil
        currentFlowID = UUID()
        recordOperationStarted(next)
        return true
    }

    /// Emits the operation-start event with the flow id and the provider tag.
    private func recordOperationStarted(_ next: Stage) {
        guard let code = Self.startedCode(for: next) else { return }
        DiagnosticLog.shared.record(
            code,
            level: .info,
            module: .cloudSync,
            metadata: diagnosticMetadata()
        )
    }

    /// Flow id + provider + (optionally) host. Callers merge the rest.
    private func diagnosticMetadata() -> DiagnosticMetadata {
        var metadata = DiagnosticMetadata.flow(currentFlowID)
            .merging(.provider(selectedProvider.diagnosticProviderTag))
        if let host = bridge.providerHost(selectedProvider) {
            metadata = metadata.merging(.host(of: host))
        }
        return metadata
    }

    private static func startedCode(for stage: Stage) -> DiagnosticCode? {
        switch stage {
        case .checking:
            return .cloudSyncCheckStarted
        case .pushing:
            return .cloudSyncUploadStarted
        case .pulling:
            return .cloudSyncDownloadStarted
        case .resolvingConflict:
            return .cloudSyncConflictResolveStarted
        case .idle, .needsVaultPassword, .finished, .failed:
            return nil
        }
    }

    private func makeStore() throws -> any CloudVaultRemoteStore {
        try bridge.makeStore(selectedProvider)
    }

    private func currentRecord(store: any CloudVaultRemoteStore) -> CloudVaultSyncRecord? {
        state.record(forKey: recordKey(store: store))
    }

    private func recordKey(store: any CloudVaultRemoteStore) -> String {
        CloudVaultSyncRecord.key(remoteKind: store.kind, remotePath: store.remotePath, vaultID: bridge.vaultID)
    }

    private func applyPushOutcome(_ outcome: CloudVaultPushOutcome) {
        state.setRecord(outcome.record)
        persist()
        remoteManifestRevision = outcome.receipt.manifest.revision
        remoteSummary = outcome.receipt.manifest.revision.description + " 版"
        lastSyncedAt = outcome.record.lastSyncedAt
        pendingUpload = outcome.record.pendingUpload
        refreshRecordSummary()
    }

    private func saveConfirmedRecord(for outcome: CloudVaultPullOutcome) {
        guard let record = try? engine.confirmPullApplied(outcome) else { return }
        state.setRecord(record)
        persist()
        refreshRecordSummary()
        lastSyncedAt = record.lastSyncedAt
    }

    private func applyDownloadedVault(_ outcome: CloudVaultPullOutcome) async throws {
        if outcome.remote.manifest.vaultID == bridge.vaultID {
            try bridge.applySameVault(outcome)
            saveConfirmedRecord(for: outcome)
            stage = .finished("已用云端版本覆盖本机保险库，请使用保险库密码重新解锁。")
        } else {
            awaitingPasswordOutcome = outcome
            guidance = "云端文件属于另一个保险库（\(outcome.remote.manifest.vaultName)），需要该保险库的密码才能验证并保存到本机。"
            stage = .needsVaultPassword
        }
    }

    private func persist() {
        do {
            try stateStore.save(state)
        } catch {
            lastFailureMessage = error.localizedDescription
        }
    }

    private func refreshRecordSummary() {
        guard !bridge.availableProviders.isEmpty else { return }
        do {
            let store = try makeStore()
            if let record = currentRecord(store: store) {
                lastSyncedAt = record.lastSyncedAt
                remoteManifestRevision = record.lastRemoteManifestRevision
                pendingUpload = record.pendingUpload
                lastFailureMessage = record.lastFailureMessage
                remoteSummary = record.lastRemoteManifestRevision.map { "第 \($0) 版" }
            }
        } catch {
            lastFailureMessage = error.localizedDescription
        }
    }

    private func planDescription(for decision: CloudVaultSyncDecision) -> String {
        switch decision {
        case .upToDate:
            return "本机与云端一致，无需同步。"
        case .pushNew:
            return "云端还没有这个保险库，可以上传作为第 1 版。"
        case .pushUpdate:
            return "本机有更新，可以上传到云端。"
        case .pullRemoteNewer:
            return "云端有更新，可以更新到本机。"
        case .conflict(let conflict):
            return "同步冲突：\(conflict.reason.localizedSummary)"
        }
    }

    private func present(error: Error) {
        recordFailure(error)
        let message = error.localizedDescription
        if let cloudError = error as? CloudVaultError,
           case .conflictRequiresResolution(let cloudConflict) = cloudError {
            conflict = cloudConflict
            decision = .conflict(cloudConflict)
            guidance = "请选择保留本机版本、保留云端版本，或先上传冲突副本再采用云端版本。"
            stage = .failed(message)
            return
        }
        guidance = Self.recoveryGuidance(for: error)
        stage = .failed(message)
        lastFailureMessage = message
        if awaitingPasswordOutcome != nil {
            return
        }
        if let cloudError = error as? CloudVaultError, let store = try? makeStore(),
           let record = currentRecord(store: store) {
            state.setRecord(engine.recordFailure(cloudError, in: record))
            persist()
        }
    }

    /// Logs the failure code and reason only. Never the error message, which can
    /// carry a server response, a path or provider-specific detail.
    private func recordFailure(_ error: Error) {
        var metadata = diagnosticMetadata()
        let code: DiagnosticCode
        if let coded = error as? any DiagnosticCodedError {
            code = coded.diagnosticCode
            metadata = metadata.merging(coded.diagnosticMetadata, .reason(coded.diagnosticReason))
        } else if error is AppCloudVaultSyncError {
            code = .cloudSyncUnknownFailure
            metadata = metadata.merging(.reason(.policyBlocked))
        } else {
            code = .cloudSyncUnknownFailure
            metadata = metadata.merging(.reason(.commandFailed))
        }
        DiagnosticLog.shared.record(code, level: .error, module: .cloudSync, metadata: metadata)
    }

    static func recoveryGuidance(for error: Error) -> String? {
        guard let cloudError = error as? CloudVaultError else {
            return "请稍后重试；若问题持续，可在「设置 → 隐私与安全性 → 本地网络」与云账号登录状态中排查。"
        }
        switch cloudError {
        case .unauthorized:
            return "请先在设置中重新登录云账号，再回到此处重试。"
        case .forbidden:
            return "请检查云账号是否有目标目录的写入权限，或更换远端文件名。"
        case .preconditionFailed:
            return "云端在检查之后又被其他设备修改。请先点「检查云端版本」，再决定上传或拉取。"
        case .network, .server:
            return "请检查网络连接后重试；若使用 WebDAV，请确认服务器地址、账号与自签名证书设置。"
        case .integrityMismatch, .manifestInvalid, .remoteManifestMissing, .remoteVaultMissing:
            return "云端文件不完整或被其他程序改写。请确认云端目录中的保险库文件与 .monica-cloud.json 清单未被手动修改。"
        case .vaultIDMismatch:
            return "云端文件属于另一个保险库。本机不会被覆盖；如需采用云端库，请先导出备份后从锁屏「打开已有保险库」操作。"
        case .notConfigured, .unsupportedProvider:
            return "请先在「云端备份」中配置 WebDAV 服务器，或登录 OneDrive；使用 iCloud 时请确认已在设置中开启 iCloud 同步，且 App 已配置 iCloud 容器。"
        case .cloudAccountUnavailable:
            return "请先在系统设置中登录 iCloud，再回到此处重试。"
        case .cloudQuotaExceeded:
            return "iCloud 存储空间不足。请清理空间或升级方案后重试；本机保险库没有被修改。"
        case .stateCorrupted:
            return "可点「重置同步记录」清除本机记录后重新检查云端版本（云端文件不会被删除）。"
        default:
            return "请稍后重试。"
        }
    }

    static func recoveryGuidance(for cloudError: CloudVaultError) -> String? {
        recoveryGuidance(for: cloudError as Error)
    }
}

// MARK: - Formatting helpers

extension AppCloudVaultSyncCoordinator {
    static func formattedDate(_ date: Date?) -> String {
        guard let date else { return "尚未同步" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
