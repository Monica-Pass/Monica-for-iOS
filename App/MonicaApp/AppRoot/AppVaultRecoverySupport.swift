//
//  AppVaultRecoverySupport.swift
//  Monica
//
//  「保险库打开失败」恢复流程的数据层（issue #144）：稳定失败码、诊断文本、失败上下文、
//  上次成功打开时间与快照救援编排。界面在 AppVaultRecoveryView.swift。
//

import Foundation
import MonicaMDBX
import MonicaStorage
import Observation

// MARK: - Failure model

/// Which user flow produced the failure. Kept separate from the failure code so the recovery
/// screen can explain "what we were trying to do" without guessing from the error.
enum AppVaultRecoveryStage: String, Sendable, Equatable {
    case passwordUnlock
    case keychainUnlock
    case openVault
    case snapshotRestore

    var title: String {
        switch self {
        case .passwordUnlock:
            String(localized: "使用主密码解锁")
        case .keychainUnlock:
            String(localized: "使用设备钥匙串解锁")
        case .openVault:
            String(localized: "打开保险库文件")
        case .snapshotRestore:
            String(localized: "从快照恢复")
        }
    }
}

/// Stable, user-facing failure taxonomy for "the vault would not open".
///
/// The codes (`MVA-144-xx`) are part of the support contract: they never change and they never
/// carry raw error text, file paths or credentials, so they are safe to paste into a support
/// ticket even while the vault stays locked.
enum AppVaultRecoveryFailure: String, Sendable, Equatable, CaseIterable {
    case masterPasswordMismatch
    case vaultFileMissing
    case vaultFileUnreadable
    case vaultFileCorrupted
    case vaultIdentifierMismatch
    case vaultNotRemembered
    case keychainUnavailable
    case keyMaterialUnavailable
    case storageEngineUnavailable
    case vaultBusy
    case insufficientDiskSpace
    case snapshotUnavailable
    case snapshotCorrupted
    case snapshotKeyUnavailable
    case snapshotRestoreFailed
    case unknown

    var code: String {
        switch self {
        case .masterPasswordMismatch: "MVA-144-01"
        case .vaultFileMissing: "MVA-144-02"
        case .vaultFileUnreadable: "MVA-144-03"
        case .vaultFileCorrupted: "MVA-144-04"
        case .vaultIdentifierMismatch: "MVA-144-05"
        case .vaultNotRemembered: "MVA-144-06"
        case .keychainUnavailable: "MVA-144-07"
        case .keyMaterialUnavailable: "MVA-144-08"
        case .storageEngineUnavailable: "MVA-144-09"
        case .vaultBusy: "MVA-144-10"
        case .insufficientDiskSpace: "MVA-144-11"
        case .snapshotUnavailable: "MVA-144-12"
        case .snapshotCorrupted: "MVA-144-13"
        case .snapshotKeyUnavailable: "MVA-144-14"
        case .snapshotRestoreFailed: "MVA-144-15"
        case .unknown: "MVA-144-99"
        }
    }

    var title: String {
        switch self {
        case .masterPasswordMismatch:
            String(localized: "主密码不正确")
        case .vaultFileMissing:
            String(localized: "保险库文件不存在")
        case .vaultFileUnreadable:
            String(localized: "保险库文件无法读取")
        case .vaultFileCorrupted:
            String(localized: "保险库文件已损坏")
        case .vaultIdentifierMismatch:
            String(localized: "保险库标识不匹配")
        case .vaultNotRemembered:
            String(localized: "没有记住的保险库")
        case .keychainUnavailable:
            String(localized: "设备钥匙串不可用")
        case .keyMaterialUnavailable:
            String(localized: "钥匙串中缺少该保险库的密钥")
        case .storageEngineUnavailable:
            String(localized: "本机不支持该存储引擎")
        case .vaultBusy:
            String(localized: "保险库仍被占用")
        case .insufficientDiskSpace:
            String(localized: "可用存储空间不足")
        case .snapshotUnavailable:
            String(localized: "没有可用快照")
        case .snapshotCorrupted:
            String(localized: "快照已损坏")
        case .snapshotKeyUnavailable:
            String(localized: "快照密钥不可用")
        case .snapshotRestoreFailed:
            String(localized: "快照恢复失败")
        case .unknown:
            String(localized: "未知错误")
        }
    }

    var explanation: String {
        switch self {
        case .masterPasswordMismatch:
            String(localized: "输入的主密码与这个保险库不匹配。")
        case .vaultFileMissing:
            String(localized: "在这个位置找不到保险库文件，它可能已被移动或删除。")
        case .vaultFileUnreadable:
            String(localized: "系统拒绝读取这个保险库文件。")
        case .vaultFileCorrupted:
            String(localized: "文件内容无法解析为 Monica 保险库，可能在写入过程中被中断。")
        case .vaultIdentifierMismatch:
            String(localized: "文件内容与记录中的保险库标识不一致。")
        case .vaultNotRemembered:
            String(localized: "这台设备没有记住任何保险库，因此无法自动解锁。")
        case .keychainUnavailable:
            String(localized: "iOS 钥匙串当前不可用，无法取出快捷解锁密钥。")
        case .keyMaterialUnavailable:
            String(localized: "钥匙串里没有这个保险库的解锁密钥，可能已被系统清理。")
        case .storageEngineUnavailable:
            String(localized: "当前运行环境无法加载 MDBX 存储引擎。")
        case .vaultBusy:
            String(localized: "保险库旁边仍有未合并的写入日志，暂时不能安全地覆盖它。")
        case .insufficientDiskSpace:
            String(localized: "设备剩余空间不足以写入快照内容。")
        case .snapshotUnavailable:
            String(localized: "这个保险库没有可用的快照。")
        case .snapshotCorrupted:
            String(localized: "快照内容无法通过完整性校验。")
        case .snapshotKeyUnavailable:
            String(localized: "钥匙串中缺少快照密钥，无法解密快照。")
        case .snapshotRestoreFailed:
            String(localized: "快照内容无法写入保险库文件。")
        case .unknown:
            String(localized: "发生了未归类的错误。")
        }
    }

    var nextStep: String {
        switch self {
        case .masterPasswordMismatch:
            String(localized: "确认键盘布局与大小写后重试，或改用设备钥匙串解锁。")
        case .vaultFileMissing:
            String(localized: "在解锁页选择“打开已有保险库”并重新指定文件位置。")
        case .vaultFileUnreadable:
            String(localized: "检查文件权限，或把保险库复制到“我的 iPhone › Monica”后再试。")
        case .vaultFileCorrupted:
            String(localized: "如果有可用快照，请从快照恢复；恢复前会自动创建回滚点。")
        case .vaultIdentifierMismatch:
            String(localized: "确认选中了正确的文件，必要时用快照恢复。")
        case .vaultNotRemembered:
            String(localized: "在解锁页选择“打开已有保险库”手动指定文件。")
        case .keychainUnavailable:
            String(localized: "重试一次；仍失败时改用主密码解锁。")
        case .keyMaterialUnavailable:
            String(localized: "改用主密码解锁。")
        case .storageEngineUnavailable:
            String(localized: "请在受支持的 iOS 设备上重试。")
        case .vaultBusy:
            String(localized: "完全退出 App 后重新打开，再重试一次。")
        case .insufficientDiskSpace:
            String(localized: "清理一些存储空间后再恢复。")
        case .snapshotUnavailable:
            String(localized: "没有可用快照时无法通过快照恢复，请改用主密码重试。")
        case .snapshotCorrupted:
            String(localized: "尝试恢复更早的一份快照。")
        case .snapshotKeyUnavailable:
            String(localized: "重新解锁一次保险库以刷新快照密钥。")
        case .snapshotRestoreFailed:
            String(localized: "原保险库文件没有被删除或覆盖，可以重试或选择更早的快照。")
        case .unknown:
            String(localized: "复制诊断信息后重试，或重启 App。")
        }
    }

    /// Whether this failure points at the snapshot pipeline rather than at the master password.
    var isSnapshotRelated: Bool {
        switch self {
        case .snapshotUnavailable, .snapshotCorrupted, .snapshotKeyUnavailable,
             .snapshotRestoreFailed, .vaultBusy, .insufficientDiskSpace:
            true
        default:
            false
        }
    }
}

extension AppVaultRecoveryFailure {
    /// Maps any error thrown by the unlock / open / restore pipelines onto the stable taxonomy.
    ///
    /// Only type names and system error domains survive this mapping; message payloads that could
    /// carry paths or user data are never propagated into the recovery UI.
    static func classify(_ error: Error, stage: AppVaultRecoveryStage) -> AppVaultRecoveryFailure {
        if let failure = AppVaultRecoveryFailureClassifier().classify(error) {
            return failure
        }
        return stage == .snapshotRestore ? .snapshotRestoreFailed : .unknown
    }
}

/// Stateless error classifier, split out from the enum so it can be unit tested directly.
struct AppVaultRecoveryFailureClassifier: Sendable {
    func classify(_ error: Error) -> AppVaultRecoveryFailure? {
        if let failure = classifyKnown(error) {
            return failure
        }
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
           let failure = classifyKnown(underlying) {
            return failure
        }
        return classifySystemError(nsError)
    }

    /// Short, user-safe technical reference: type name plus system error domain/code.
    func technicalReference(for error: Error) -> String {
        let nsError = error as NSError
        let typeName = String(describing: type(of: error))
        if nsError.domain == NSCocoaErrorDomain || nsError.domain == NSPOSIXErrorDomain {
            return "\(typeName) [\(nsError.domain)/\(nsError.code)]"
        }
        return typeName
    }

    private func classifyKnown(_ error: Error) -> AppVaultRecoveryFailure? {
        if let repositoryError = error as? LocalVaultRepositoryError {
            switch repositoryError {
            case .currentPasswordMismatch, .emptyPassword:
                return .masterPasswordMismatch
            case .vaultUnavailable:
                return .vaultFileMissing
            case .emptySecurityKeyMaterial, .passwordUnchanged, .emptyVaultName,
                 .emptyProjectTitle, .emptyEntryTitle, .projectNotFound, .projectNotEmpty,
                 .unsupportedEntryType, .invalidEntryPayload:
                return nil
            }
        }
        if let keychainError = error as? AppVaultKeychainError {
            switch keychainError {
            case .rememberedVaultUnavailable:
                return .vaultNotRemembered
            case .keychainUnavailable:
                return .keychainUnavailable
            case .wrappedKeyProviderUnavailable:
                return .keyMaterialUnavailable
            case .vaultMismatch:
                return .vaultIdentifierMismatch
            case .vaultLocked, .vaultAlreadyUnlocked:
                return nil
            }
        }
        if let mdbxError = error as? MonicaMDBXError {
            switch mdbxError {
            case .unavailableOnCurrentPlatform:
                return .storageEngineUnavailable
            case .verificationFailed:
                return .vaultFileCorrupted
            }
        }
        if let snapshotError = error as? VaultSnapshotError {
            switch snapshotError {
            case .vaultFileMissing:
                return .vaultFileMissing
            case .vaultNotQuiesced:
                return .vaultBusy
            case .snapshotNotFound:
                return .snapshotUnavailable
            case .snapshotCorrupted, .envelopeVersionUnsupported, .restoreVerificationFailed:
                return .snapshotCorrupted
            case .invalidSnapshotKey, .snapshotKeyUnavailable:
                return .snapshotKeyUnavailable
            case .insufficientDiskSpace:
                return .insufficientDiskSpace
            case .vaultMismatch:
                return .vaultIdentifierMismatch
            case .emptyVaultIdentifier, .snapshotWriteFailed:
                return .snapshotRestoreFailed
            }
        }
        if let ffiError = error as? MdbxFfiError {
            switch ffiError {
            case .Storage(let message):
                let lowercased = message.lowercased()
                if lowercased.contains("credential") || lowercased.contains("password") {
                    return .masterPasswordMismatch
                }
                return .vaultFileCorrupted
            case .Serialization, .InvalidEntryType, .LockPoisoned:
                return .vaultFileCorrupted
            @unknown default:
                // 绑定由上游 UniFFI 生成；新增错误变体时按「文件损坏」保守归类。
                return .vaultFileCorrupted
            }
        }
        return nil
    }

    private func classifySystemError(_ error: NSError) -> AppVaultRecoveryFailure? {
        switch error.domain {
        case NSCocoaErrorDomain:
            switch error.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError, NSFileReadUnknownError:
                return .vaultFileMissing
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return .vaultFileUnreadable
            case NSFileWriteOutOfSpaceError:
                return .insufficientDiskSpace
            default:
                return nil
            }
        case NSPOSIXErrorDomain:
            switch Int32(clamping: error.code) {
            case ENOENT:
                return .vaultFileMissing
            case EACCES, EPERM:
                return .vaultFileUnreadable
            case ENOSPC:
                return .insufficientDiskSpace
            default:
                return nil
            }
        default:
            return nil
        }
    }
}

// MARK: - Recovery context

enum AppVaultRecoveryRetryMode: String, Sendable, Equatable {
    case password
    case keychain
}

/// What `AppSessionModel` remembers about the last failed unlock, so the recovery screen can be
/// rendered without re-running the failing operation (and without holding any secret).
struct AppVaultRecoveryContext: Sendable, Equatable {
    var failure: AppVaultRecoveryFailure
    var stage: AppVaultRecoveryStage
    var fileURL: URL?
    var displayName: String?
    var retryMode: AppVaultRecoveryRetryMode
}

// MARK: - Last successful open history

/// Remembers when each vault file was last opened successfully.
///
/// Only the standardized file path and the timestamp are stored: no master password, no key
/// material and no entry data ever reaches UserDefaults.
struct AppVaultRecoveryHistory {
    static let storageKey = "monica.vaultRecovery.lastOpenedAt.v1"
    static let capacity = 20

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func lastOpenedAt(for fileURL: URL) -> Date? {
        guard let seconds = storedEntries()[Self.key(for: fileURL)] else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    func recordOpened(fileURL: URL, at date: Date) {
        var entries = storedEntries()
        entries[Self.key(for: fileURL)] = date.timeIntervalSince1970
        if entries.count > Self.capacity {
            let newest = entries
                .sorted { $0.value > $1.value }
                .prefix(Self.capacity)
            entries = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        defaults.set(entries, forKey: Self.storageKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.storageKey)
    }

    private func storedEntries() -> [String: Double] {
        guard let raw = defaults.dictionary(forKey: Self.storageKey) else { return [:] }
        var entries: [String: Double] = [:]
        for (key, value) in raw {
            if let number = value as? NSNumber {
                entries[key] = number.doubleValue
            } else if let seconds = value as? Double {
                entries[key] = seconds
            }
        }
        return entries
    }

    private static func key(for fileURL: URL) -> String {
        fileURL.standardizedFileURL.path
    }
}

// MARK: - File evidence

/// Metadata about the vault file. Deliberately read-only and content-free.
struct AppVaultRecoveryFileSnapshot: Sendable, Equatable {
    let fileURL: URL
    let exists: Bool
    let byteCount: Int64?
    let modificationDate: Date?
    let busySidecars: [String]

    var displayName: String { fileURL.lastPathComponent }

    var isBusy: Bool { !busySidecars.isEmpty }

    var formattedByteCount: String? {
        byteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    static func inspect(_ fileURL: URL?) -> AppVaultRecoveryFileSnapshot? {
        guard let fileURL else { return nil }
        let standardized = fileURL.standardizedFileURL
        let exists = FileManager.default.fileExists(atPath: standardized.path)
        let values = try? standardized.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return AppVaultRecoveryFileSnapshot(
            fileURL: standardized,
            exists: exists,
            byteCount: values?.fileSize.map(Int64.init),
            modificationDate: values?.contentModificationDate,
            busySidecars: existingSidecars(of: standardized)
                .filter { isNonEmpty($0) }
                .map(\.lastPathComponent)
                .sorted()
        )
    }

    static func sidecars(of fileURL: URL) -> [URL] {
        let path = fileURL.path
        let base = path.hasSuffix(".mdbx") ? String(path.dropLast(".mdbx".count)) : path
        return [
            URL(fileURLWithPath: base + ".mdbx-wal"),
            URL(fileURLWithPath: base + ".mdbx-shm")
        ]
    }

    static func existingSidecars(of fileURL: URL) -> [URL] {
        sidecars(of: fileURL).filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Removes a vault file together with its MDBX sidecars.
    static func removeVaultFiles(at fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL)
        for sidecar in sidecars(of: fileURL) {
            try? FileManager.default.removeItem(at: sidecar)
        }
    }

    private static func isNonEmpty(_ fileURL: URL) -> Bool {
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size > 0
    }
}

// MARK: - Diagnostics

enum AppVaultRecoverySnapshotVerification: String, Sendable, Equatable {
    case unknown
    case verified
    case failed

    var localizedTitle: String {
        switch self {
        case .unknown:
            String(localized: "未校验")
        case .verified:
            String(localized: "通过")
        case .failed:
            String(localized: "失败")
        }
    }
}

/// Content-free description of one snapshot: counts and timestamps only.
/// `VaultSnapshotManifest.index` carries entry titles, so it is never copied into this type.
struct AppVaultRecoverySnapshotDigest: Sendable, Equatable {
    var createdAt: Date
    var reason: VaultSnapshotReason
    var itemCount: Int
    var projectCount: Int
    var payloadByteCount: Int
    var verification: AppVaultRecoverySnapshotVerification
}

struct AppVaultRecoveryReport: Sendable, Equatable {
    var failure: AppVaultRecoveryFailure
    var stage: AppVaultRecoveryStage
    var technicalReference: String
    var generatedAt: Date
    var appVersion: String
    var systemDescription: String
    var file: AppVaultRecoveryFileSnapshot?
    var lastOpenedAt: Date?
    var snapshotCount: Int
    var newestSnapshot: AppVaultRecoverySnapshotDigest?
    var snapshotIssue: AppVaultRecoveryFailure?
    var snapshotDirectoryPath: String?
}

/// Builds the copyable diagnostics text.
///
/// Invariants enforced by construction and covered by tests:
/// - never contains the master password or any key material (no secret is passed in),
/// - never contains entry titles or payload (only counts are passed in),
/// - never contains a raw error description (only a type name plus system error code).
enum AppVaultRecoveryDiagnostics {
    static func text(for report: AppVaultRecoveryReport) -> String {
        var lines: [String] = []
        lines.append(String(localized: "Monica 保险库恢复诊断"))
        lines.append("")
        lines.append(line(String(localized: "生成时间"), format(report.generatedAt)))
        lines.append(line(String(localized: "应用版本"), report.appVersion))
        lines.append(line(String(localized: "系统版本"), report.systemDescription))
        lines.append(line(String(localized: "失败码"), report.failure.code))
        lines.append(line(String(localized: "失败标题"), report.failure.title))
        lines.append(line(String(localized: "失败阶段"), report.stage.title))
        lines.append(line(String(localized: "技术引用"), report.technicalReference))

        lines.append("")
        lines.append("[\(String(localized: "保险库文件"))]")
        if let file = report.file {
            lines.append(line(String(localized: "名称"), file.displayName))
            lines.append(line(String(localized: "路径"), file.fileURL.path))
            lines.append(line(
                String(localized: "状态"),
                file.exists ? String(localized: "存在") : String(localized: "不存在")
            ))
            if let size = file.formattedByteCount {
                lines.append(line(String(localized: "大小"), size))
            }
            if let modificationDate = file.modificationDate {
                lines.append(line(String(localized: "修改时间"), format(modificationDate)))
            }
            lines.append(line(
                String(localized: "未合并的写入日志"),
                file.busySidecars.isEmpty
                    ? String(localized: "无")
                    : file.busySidecars.joined(separator: ", ")
            ))
        } else {
            lines.append(line(String(localized: "路径"), String(localized: "未知")))
        }

        lines.append("")
        lines.append("[\(String(localized: "最近一次成功打开"))]")
        if let lastOpenedAt = report.lastOpenedAt {
            lines.append(line(String(localized: "时间"), format(lastOpenedAt)))
        } else {
            lines.append(line(String(localized: "时间"), String(localized: "无记录")))
        }

        lines.append("")
        lines.append("[\(String(localized: "快照"))]")
        lines.append(line(String(localized: "快照数量"), String(report.snapshotCount)))
        if let issue = report.snapshotIssue {
            lines.append(line(String(localized: "快照状态"), issue.code + " " + issue.title))
        } else if report.snapshotCount == 0 {
            lines.append(line(String(localized: "快照状态"), String(localized: "没有可用快照")))
        } else {
            lines.append(line(String(localized: "快照状态"), String(localized: "可用")))
        }
        if let newest = report.newestSnapshot {
            lines.append(line(String(localized: "最近快照时间"), format(newest.createdAt)))
            lines.append(line(String(localized: "最近快照原因"), newest.reason.displayName))
            lines.append(line(String(localized: "最近快照条目数"), String(newest.itemCount)))
            lines.append(line(String(localized: "最近快照项目数"), String(newest.projectCount)))
            lines.append(line(String(localized: "最近快照字节数"), String(newest.payloadByteCount)))
            lines.append(line(String(localized: "最近快照完整性"), newest.verification.localizedTitle))
        }
        if let directory = report.snapshotDirectoryPath {
            lines.append(line(String(localized: "快照目录"), directory))
        }

        lines.append("")
        lines.append("[\(String(localized: "说明"))]")
        lines.append(String(localized: "本诊断只包含保险库文件与快照的元数据，不包含条目内容、标题、主密码或加密密钥。"))
        return lines.joined(separator: "\n")
    }

    static func format(_ date: Date) -> String {
        date.ISO8601Format(
            .iso8601(timeZone: TimeZone(secondsFromGMT: 0) ?? .current, includingFractionalSeconds: false)
        )
    }

    private static func line(_ label: String, _ value: String) -> String {
        label + ": " + value
    }
}

// MARK: - Environment

enum AppVaultRecoveryEnvironment {
    static func appVersion(bundle: Bundle = .main) -> String {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    static func systemDescription() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let base: String
        #if os(iOS)
        base = "iOS"
        #elseif os(macOS)
        base = "macOS"
        #else
        base = "OS"
        #endif
        return "\(base) \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

// MARK: - Recovery model

/// Locked-state recovery screen model.
///
/// Everything here is metadata and file plumbing: it never reads entries, never renders entry
/// content and never keeps the master password longer than the operation that needed it.
@MainActor
@Observable
final class AppVaultRecoveryModel {
    enum Status: Equatable {
        case idle
        case running(String)
        case succeeded(String)
        case failed(String)

        var message: String? {
            switch self {
            case .idle:
                nil
            case .running(let message), .succeeded(let message), .failed(let message):
                message
            }
        }

        var isRunning: Bool {
            if case .running = self { true } else { false }
        }

        var isFailure: Bool {
            if case .failed = self { true } else { false }
        }
    }

    var masterPassword = ""

    private(set) var status: Status = .idle
    private(set) var failure: AppVaultRecoveryFailure = .unknown
    private(set) var stage: AppVaultRecoveryStage = .openVault
    private(set) var retryMode: AppVaultRecoveryRetryMode = .password
    private(set) var file: AppVaultRecoveryFileSnapshot?
    private(set) var lastOpenedAt: Date?
    private(set) var snapshots: [VaultSnapshotRecord] = []
    private(set) var newestSnapshotVerification: AppVaultRecoverySnapshotVerification = .unknown
    private(set) var snapshotIssue: AppVaultRecoveryFailure?
    private(set) var subject: VaultSnapshotSubject?
    private(set) var technicalReference = ""
    private(set) var didRestoreSucceed = false
    private(set) var hasLoaded = false

    let snapshotDirectoryURL: URL

    private let store: VaultSnapshotStore
    private let history: AppVaultRecoveryHistory
    private let clock: @Sendable () -> Date

    init(
        directoryURL: URL = AppVaultSnapshotLocation.rootDirectory(),
        keyProvider: any VaultSnapshotKeyProviding = AppVaultSnapshotKeyProvider(),
        history: AppVaultRecoveryHistory = AppVaultRecoveryHistory(),
        clock: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.snapshotDirectoryURL = directoryURL
        self.store = AppVaultSnapshotLocation.makeStore(directoryURL: directoryURL, keyProvider: keyProvider)
        self.history = history
        self.clock = clock
    }

    var hasSnapshots: Bool { !snapshots.isEmpty }

    var canRestoreSnapshots: Bool { subject != nil && !snapshots.isEmpty }

    // MARK: Loading

    func load(session: AppSessionModel) {
        hasLoaded = true
        guard let context = session.vaultRecoveryContext else {
            failure = .unknown
            stage = .openVault
            retryMode = .password
            file = nil
            lastOpenedAt = nil
            subject = nil
            technicalReference = ""
            snapshots = []
            newestSnapshotVerification = .unknown
            snapshotIssue = nil
            return
        }
        failure = context.failure
        stage = context.stage
        retryMode = context.retryMode
        file = AppVaultRecoveryFileSnapshot.inspect(context.fileURL)
        lastOpenedAt = context.fileURL.flatMap { history.lastOpenedAt(for: $0) }
        subject = Self.resolveSubject(context: context, session: session)
        reloadSnapshots()
    }

    private static func resolveSubject(
        context: AppVaultRecoveryContext,
        session: AppSessionModel
    ) -> VaultSnapshotSubject? {
        guard let fileURL = context.fileURL?.standardizedFileURL else { return nil }
        var vaultID: String?
        var displayName = context.displayName

        if let remembered = session.rememberedVaultIdentity,
           remembered.fileURL.standardizedFileURL.path == fileURL.path {
            vaultID = remembered.vaultID
            displayName = displayName ?? remembered.displayName
        }
        if let entry = session.vaultRegistry.entry(fileURL: fileURL) {
            vaultID = vaultID ?? entry.vaultID
            displayName = displayName ?? entry.displayName
        }
        guard let vaultID, !vaultID.isEmpty else { return nil }
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return VaultSnapshotSubject(
            vaultID: vaultID,
            fileURL: fileURL,
            displayName: (name?.isEmpty == false) ? (name ?? "") : fileURL.deletingPathExtension().lastPathComponent
        )
    }

    func reloadSnapshots() {
        snapshots = []
        newestSnapshotVerification = .unknown
        snapshotIssue = nil
        guard let subject else { return }
        do {
            let records = try store.listSnapshots(vaultID: subject.vaultID)
            snapshots = records
            guard let newest = records.first else { return }
            do {
                _ = try store.verifySnapshot(snapshotID: newest.id, vaultID: subject.vaultID)
                newestSnapshotVerification = .verified
            } catch {
                newestSnapshotVerification = .failed
                snapshotIssue = AppVaultRecoveryFailure.classify(error, stage: .snapshotRestore)
            }
        } catch {
            snapshots = []
            snapshotIssue = AppVaultRecoveryFailure.classify(error, stage: .snapshotRestore)
        }
    }

    // MARK: Retry

    func retryWithPassword(session: AppSessionModel, deviceID: String) {
        guard !status.isRunning else { return }
        guard let context = session.vaultRecoveryContext, let fileURL = context.fileURL else {
            status = .failed(String(localized: "找不到要重试的保险库文件。"))
            return
        }
        guard !masterPassword.isEmpty else {
            status = .failed(String(localized: "请先输入主密码。"))
            return
        }
        status = .running(String(localized: "正在打开保险库…"))
        let password = masterPassword
        masterPassword = ""
        session.vaultPassword = password
        do {
            try session.openLocalVault(at: fileURL, deviceID: deviceID, now: clock())
            status = .succeeded(String(localized: "保险库已打开。"))
        } catch {
            status = .failed(String(localized: "仍然无法打开保险库，请查看下方的失败码。"))
            load(session: session)
        }
    }

    func retryWithKeychain(session: AppSessionModel, deviceID: String) async {
        guard !status.isRunning else { return }
        status = .running(String(localized: "正在请求设备钥匙串…"))
        do {
            try await session.unlockRememberedVaultWithKeychain(deviceID: deviceID, now: clock())
            status = .succeeded(String(localized: "保险库已打开。"))
        } catch {
            status = .failed(String(localized: "仍然无法打开保险库，请查看下方的失败码。"))
            load(session: session)
        }
    }

    // MARK: Snapshot restore

    func restore(_ record: VaultSnapshotRecord, session: AppSessionModel, deviceID: String) async {
        guard !status.isRunning else { return }
        guard let subject else {
            status = .failed(String(localized: "没有可用快照。"))
            return
        }
        guard record.manifest.vaultID == subject.vaultID else {
            status = .failed(String(localized: "这份快照属于其他保险库，已停止恢复。"))
            return
        }
        guard !masterPassword.isEmpty else {
            status = .failed(String(localized: "请先输入主密码再恢复。"))
            return
        }

        let password = masterPassword
        let store = self.store
        let target = subject.fileURL
        let displayName = subject.displayName
        let snapshotID = record.id
        let vaultID = subject.vaultID

        // 主密码确认：先把快照解到临时文件，用同一口令打开这份副本校验。
        // 校验完成前绝不触碰原库，因此口令错误或快照损坏都不会破坏原文件。
        status = .running(String(localized: "正在校验主密码与快照…"))
        do {
            try await verifySnapshotCopy(
                record,
                store: store,
                session: session,
                subject: subject,
                password: password,
                deviceID: deviceID
            )
        } catch {
            let verificationFailure = AppVaultRecoveryFailure.classify(error, stage: .snapshotRestore)
            technicalReference = AppVaultRecoveryFailureClassifier().technicalReference(for: error)
            status = .failed(verificationFailure.title + "（" + verificationFailure.code + "）")
            reloadSnapshots()
            return
        }

        status = .running(String(localized: "正在从快照恢复…"))
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try store.restoreSnapshot(
                    snapshotID: snapshotID,
                    vaultID: vaultID,
                    to: target,
                    vaultDisplayName: displayName,
                    currentIndex: .empty,
                    createSafetySnapshot: true
                )
            }.value
            masterPassword = ""
            didRestoreSucceed = true
            reloadSnapshots()
            status = .running(String(localized: "快照已恢复，正在打开保险库…"))
            session.vaultPassword = password
            do {
                try session.openLocalVault(at: target, deviceID: deviceID, now: clock())
                status = .succeeded(
                    result.safetySnapshot == nil
                        ? String(localized: "已从快照恢复并打开保险库。")
                        : String(localized: "已从快照恢复并打开保险库，恢复前的回滚点已保留。")
                )
            } catch {
                status = .failed(String(localized: "快照已恢复，但保险库仍无法打开。恢复前的原文件已保存为回滚点。"))
                load(session: session)
            }
        } catch {
            let restoreFailure = AppVaultRecoveryFailure.classify(error, stage: .snapshotRestore)
            technicalReference = AppVaultRecoveryFailureClassifier().technicalReference(for: error)
            status = .failed(restoreFailure.title + "（" + restoreFailure.code + "）")
            reloadSnapshots()
        }
    }

    /// 把快照解到临时副本，并用主密码打开这份副本，确认「这份快照 + 这个口令」真的可用。
    /// 校验结束立即删除副本及其侧车文件；原库在校验完成前始终未被触碰。
    private func verifySnapshotCopy(
        _ record: VaultSnapshotRecord,
        store: VaultSnapshotStore,
        session: AppSessionModel,
        subject: VaultSnapshotSubject,
        password: String,
        deviceID: String
    ) async throws {
        let verificationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-vault-recovery-\(UUID().uuidString)")
            .appendingPathExtension("mdbx")
        defer {
            AppVaultRecoveryFileSnapshot.removeVaultFiles(at: verificationURL)
        }

        let snapshotID = record.id
        let vaultID = subject.vaultID
        let displayName = subject.displayName
        _ = try await Task.detached(priority: .userInitiated) {
            try store.restoreSnapshot(
                snapshotID: snapshotID,
                vaultID: vaultID,
                to: verificationURL,
                vaultDisplayName: displayName,
                currentIndex: .empty,
                createSafetySnapshot: false
            )
        }.value

        try session.verifyCandidateVaultForRecovery(
            at: verificationURL,
            password: password,
            deviceID: deviceID
        )
    }

    // MARK: Diagnostics

    func diagnosticText(session: AppSessionModel) -> String {
        AppVaultRecoveryDiagnostics.text(for: makeReport())
    }

    @discardableResult
    func copyDiagnostics(session: AppSessionModel) -> SensitivePasteboardCopyFeedback {
        let feedback = session.copySensitiveValueToPasteboard(diagnosticText(session: session))
        status = .succeeded(feedback.message)
        return feedback
    }

    private func makeReport() -> AppVaultRecoveryReport {
        let newest = snapshots.first.map { record in
            AppVaultRecoverySnapshotDigest(
                createdAt: record.manifest.createdAt,
                reason: record.manifest.reason,
                itemCount: record.manifest.index.itemCount,
                projectCount: record.manifest.index.projectCount,
                payloadByteCount: record.manifest.payloadByteCount,
                verification: newestSnapshotVerification
            )
        }
        return AppVaultRecoveryReport(
            failure: failure,
            stage: stage,
            technicalReference: technicalReference.isEmpty ? "—" : technicalReference,
            generatedAt: clock(),
            appVersion: AppVaultRecoveryEnvironment.appVersion(),
            systemDescription: AppVaultRecoveryEnvironment.systemDescription(),
            file: file,
            lastOpenedAt: lastOpenedAt,
            snapshotCount: snapshots.count,
            newestSnapshot: newest,
            snapshotIssue: snapshotIssue,
            snapshotDirectoryPath: subject == nil ? nil : snapshotDirectoryURL.path
        )
    }

    // MARK: Exit

    /// "退出" only leaves the recovery screen: the vault file is never deleted or rebuilt here.
    func dismiss(session: AppSessionModel) {
        masterPassword = ""
        status = .idle
        session.vaultPassword = ""
        session.vaultRecoveryContext = nil
        session.vaultOperationState = .idle
    }
}
