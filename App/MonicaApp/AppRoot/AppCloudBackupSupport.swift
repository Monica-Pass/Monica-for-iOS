//
//  AppCloudBackupSupport.swift
//  Monica
//
//  云端备份（WebDAV / OneDrive）的状态、错误、服务与偏好存储。
//

import MonicaSync
import CryptoKit
import Foundation

struct AppCloudFileRestorePreview: Sendable, Equatable {
    let provider: CloudFileProviderKind
    let fileName: String
    let byteCount: Int

    init(provider: CloudFileProviderKind, download: CloudFileDownload) {
        self.provider = provider
        self.fileName = Self.sanitizedFileName(download.item.name)
        self.byteCount = download.data.count
    }

    var redactedSummary: String {
        String(localized: "\(provider.displayName) \(fileName) \(byteCount) 字节")
    }

    private static func sanitizedFileName(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? value
        let sanitized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? String(localized: "未命名文件") : sanitized
    }
}

struct AppOneDriveAuthenticationSession: Sendable, Equatable {
    let accountLabel: String
    let accountIdentifier: String

    init(accountLabel: String, accountIdentifier: String = "") {
        self.accountLabel = accountLabel
        self.accountIdentifier = accountIdentifier
    }

    var normalizedAccountIdentifier: String {
        accountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var redactedSummary: String {
        "OneDrive \(accountLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "已登录" : accountLabel)"
    }
}

protocol AppOneDriveAuthenticationService: OneDriveAccessTokenProvider {
    func restoreSession() async throws -> AppOneDriveAuthenticationSession?
    func availableAccounts() async throws -> [AppOneDriveAuthenticationSession]
    func switchAccount(identifier: String) async throws -> AppOneDriveAuthenticationSession
    func signIn() async throws -> AppOneDriveAuthenticationSession
    func signOut() async throws
    func handleRedirectURL(_ url: URL) -> Bool
}

/// Backup location preferences are keyed by the signed-in account so account A and
/// account B never share a target directory or retention policy.
protocol AppOneDriveBackupPreferencesStore: Sendable {
    func loadPreferences(accountIdentifier: String) -> CloudFileBackupPreferences
    func savePreferences(_ preferences: CloudFileBackupPreferences, accountIdentifier: String)
}

struct UserDefaultsAppOneDriveBackupPreferencesStore: @unchecked Sendable, AppOneDriveBackupPreferencesStore {
    private let userDefaults: UserDefaults
    private let keyPrefix: String

    init(
        userDefaults: UserDefaults = .standard,
        keyPrefix: String = "Monica.OneDrive.BackupPreferences."
    ) {
        self.userDefaults = userDefaults
        self.keyPrefix = keyPrefix
    }

    func loadPreferences(accountIdentifier: String) -> CloudFileBackupPreferences {
        guard let key = Self.storageKey(accountIdentifier, prefix: keyPrefix),
              let data = userDefaults.data(forKey: key),
              let preferences = try? JSONDecoder().decode(CloudFileBackupPreferences.self, from: data)
        else {
            return CloudFileBackupPreferences()
        }
        return preferences
    }

    func savePreferences(_ preferences: CloudFileBackupPreferences, accountIdentifier: String) {
        guard let key = Self.storageKey(accountIdentifier, prefix: keyPrefix),
              let data = try? JSONEncoder().encode(preferences)
        else {
            return
        }
        userDefaults.set(data, forKey: key)
    }

    static func storageKey(_ accountIdentifier: String, prefix: String) -> String? {
        let normalized = accountIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else {
            return nil
        }
        let digest = SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return prefix + digest
    }
}

final class MemoryAppOneDriveBackupPreferencesStore: @unchecked Sendable, AppOneDriveBackupPreferencesStore {
    private let lock = NSLock()
    private var storage: [String: CloudFileBackupPreferences]

    init(seeded: [String: CloudFileBackupPreferences] = [:]) {
        self.storage = seeded.reduce(into: [:]) { result, entry in
            result[Self.key(entry.key)] = entry.value
        }
    }

    func loadPreferences(accountIdentifier: String) -> CloudFileBackupPreferences {
        lock.lock()
        defer { lock.unlock() }
        return storage[Self.key(accountIdentifier)] ?? CloudFileBackupPreferences()
    }

    func savePreferences(_ preferences: CloudFileBackupPreferences, accountIdentifier: String) {
        let key = Self.key(accountIdentifier)
        guard !key.isEmpty else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        storage[key] = preferences
    }

    var savedAccountIdentifiers: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage.keys.sorted()
    }

    private static func key(_ accountIdentifier: String) -> String {
        accountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum WebDAVBackupState: Sendable, Equatable {
    case idle
    case running
    case listed(count: Int)
    case backupSucceeded(byteCount: Int, sha256: String)
    case restorePreviewReady(fileName: String, byteCount: Int)
    case restoreSucceeded(fileName: String, byteCount: Int)
    case deleted(fileName: String)
    case permanentUpdated(fileName: String, isPermanent: Bool)
    case cleanupSucceeded(count: Int)
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            return String(localized: "就绪")
        case .running:
            return String(localized: "处理中")
        case .listed(let count):
            return String(localized: "已列出 \(count) 个备份")
        case .backupSucceeded(let byteCount, _):
            return String(localized: "已备份 \(byteCount) 字节")
        case .restorePreviewReady(let fileName, let byteCount):
            return String(localized: "预览 \(fileName) (\(byteCount) 字节)")
        case .restoreSucceeded(let fileName, let byteCount):
            return String(localized: "已恢复 \(fileName) (\(byteCount) 字节)")
        case .deleted(let fileName):
            return String(localized: "已删除 \(fileName)")
        case .permanentUpdated(let fileName, let isPermanent):
            return isPermanent ? String(localized: "已永久保留 \(fileName)") : String(localized: "已取消永久保留 \(fileName)")
        case .cleanupSucceeded(let count):
            return String(localized: "已清理 \(count) 个过期备份")
        case .failed(let message):
            return message
        }
    }

    var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }
}

enum CloudFileState: Sendable, Equatable {
    case idle
    case running(CloudFileProviderKind)
    case listed(provider: CloudFileProviderKind, count: Int)
    case restorePreviewReady(provider: CloudFileProviderKind, fileName: String, byteCount: Int)
    case backupSucceeded(provider: CloudFileProviderKind, fileName: String, byteCount: Int)
    case writeSucceeded(provider: CloudFileProviderKind, fileName: String, byteCount: Int)
    case deleted(provider: CloudFileProviderKind, fileName: String)
    case permanentUpdated(provider: CloudFileProviderKind, fileName: String, isPermanent: Bool)
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            return String(localized: "就绪")
        case .running(let provider):
            return String(localized: "正在处理 \(provider.displayName)")
        case .listed(let provider, let count):
            return String(localized: "\(provider.displayName) 已列出 \(count) 个文件")
        case .restorePreviewReady(let provider, let fileName, let byteCount):
            return String(localized: "\(provider.displayName) 预览 \(fileName) (\(byteCount) 字节)")
        case .backupSucceeded(let provider, let fileName, let byteCount):
            return String(localized: "\(provider.displayName) 已备份 \(fileName) (\(byteCount) 字节)")
        case .writeSucceeded(let provider, let fileName, let byteCount):
            return String(localized: "\(provider.displayName) 已写回 \(fileName) (\(byteCount) 字节)")
        case .deleted(let provider, let fileName):
            return String(localized: "\(provider.displayName) 已删除 \(fileName)")
        case .permanentUpdated(let provider, let fileName, let isPermanent):
            return isPermanent
                ? String(localized: "\(provider.displayName) 已永久保留 \(fileName)")
                : String(localized: "\(provider.displayName) 已取消永久保留 \(fileName)")
        case .failed(let message):
            return message
        }
    }

    var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }

    var providerKind: CloudFileProviderKind? {
        switch self {
        case .idle, .failed:
            return nil
        case .running(let provider),
             .listed(let provider, _),
             .restorePreviewReady(let provider, _, _),
             .backupSucceeded(let provider, _, _),
             .writeSucceeded(let provider, _, _),
             .deleted(let provider, _),
             .permanentUpdated(let provider, _, _):
            return provider
        }
    }
}

enum AppOneDriveBackupDirectoryState: Sendable, Equatable {
    case unknown
    case available(String)
    case missing
    case failed(String)

    var label: String {
        switch self {
        case .unknown:
            return "默认位置"
        case .available(let path):
            return path
        case .missing:
            return "备份目录已不存在"
        case .failed(let message):
            return message
        }
    }

    var isMissing: Bool {
        if case .missing = self {
            return true
        }
        return false
    }
}

enum OneDriveAuthenticationState: Sendable, Equatable {
    case disconnected
    case running
    case connected(accountLabel: String)
    case redirectHandled
    case failed(String)

    var label: String {
        switch self {
        case .disconnected:
            return String(localized: "OneDrive 未登录")
        case .running:
            return String(localized: "正在登录 OneDrive")
        case .connected(let accountLabel):
            let normalized = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? String(localized: "OneDrive 已登录") : String(localized: "OneDrive 已登录 \(normalized)")
        case .redirectHandled:
            return String(localized: "OneDrive 登录回调已处理")
        case .failed(let message):
            return message
        }
    }

    var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }

    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }
}

enum AppWebDAVBackupError: Error, Sendable, Equatable, LocalizedError {
    case vaultLocked
    case invalidEndpoint
    case emptyUsername
    case emptyPassword
    case emptyRemoteFileName
    case restorePreviewUnavailable
    case emptyRestoreVaultPassword
    case restoreValidationFailed

    var errorDescription: String? {
        switch self {
        case .vaultLocked:
            return String(localized: "请先解锁保险库，再使用 WebDAV 备份。")
        case .invalidEndpoint:
            return String(localized: "请输入有效的 WebDAV 服务器 URL。")
        case .emptyUsername:
            return String(localized: "请输入 WebDAV 用户名。")
        case .emptyPassword:
            return String(localized: "请输入 WebDAV 密码。")
        case .emptyRemoteFileName:
            return String(localized: "请输入远端备份文件名。")
        case .restorePreviewUnavailable:
            return String(localized: "恢复前请先下载恢复预览。")
        case .emptyRestoreVaultPassword:
            return String(localized: "请输入待恢复保险库的密码。")
        case .restoreValidationFailed:
            return String(localized: "无法打开恢复备份，请检查保险库密码。")
        }
    }
}

enum AppCloudFileError: Error, Sendable, Equatable, LocalizedError {
    case providerUnavailable(CloudFileProviderKind)
    case directoryUnavailable

    var errorDescription: String? {
        switch self {
        case .providerUnavailable(let provider):
            return String(localized: "\(provider.displayName) 云文件源尚未配置。")
        case .directoryUnavailable:
            return String(localized: "OneDrive 备份目录不可用，请重新登录后再试。")
        }
    }
}

protocol AppWebDAVBackupService: Sendable {
    func upload(
        endpoint: WebDAVEndpoint,
        package: WebDAVBackupPackage
    ) async throws -> WebDAVBackupReceipt

    func download(
        endpoint: WebDAVEndpoint,
        fileName: String
    ) async throws -> WebDAVDownloadedBackup

    func listBackups(endpoint: WebDAVEndpoint) async throws -> [WebDAVBackupItem]
    func deleteBackup(endpoint: WebDAVEndpoint, fileName: String) async throws
    func setBackupPermanent(endpoint: WebDAVEndpoint, fileName: String, isPermanent: Bool) async throws -> WebDAVBackupItem
    func cleanupBackups(endpoint: WebDAVEndpoint, backups: [WebDAVBackupItem], olderThan cutoff: Date) async throws -> [WebDAVBackupItem]
}

struct URLSessionAppWebDAVBackupService: AppWebDAVBackupService {
    func upload(
        endpoint: WebDAVEndpoint,
        package: WebDAVBackupPackage
    ) async throws -> WebDAVBackupReceipt {
        try await WebDAVClient(endpoint: endpoint).upload(package)
    }

    func download(
        endpoint: WebDAVEndpoint,
        fileName: String
    ) async throws -> WebDAVDownloadedBackup {
        try await WebDAVClient(endpoint: endpoint).download(fileName: fileName)
    }

    func listBackups(endpoint: WebDAVEndpoint) async throws -> [WebDAVBackupItem] {
        try await WebDAVClient(endpoint: endpoint).listBackups()
    }

    func deleteBackup(endpoint: WebDAVEndpoint, fileName: String) async throws {
        try await WebDAVClient(endpoint: endpoint).deleteBackup(fileName: fileName)
    }

    func setBackupPermanent(endpoint: WebDAVEndpoint, fileName: String, isPermanent: Bool) async throws -> WebDAVBackupItem {
        try await WebDAVClient(endpoint: endpoint).setBackupPermanent(fileName: fileName, isPermanent: isPermanent)
    }

    func cleanupBackups(
        endpoint: WebDAVEndpoint,
        backups: [WebDAVBackupItem],
        olderThan cutoff: Date
    ) async throws -> [WebDAVBackupItem] {
        try await WebDAVClient(endpoint: endpoint).cleanupBackups(backups, olderThan: cutoff)
    }
}

enum AppOneDriveAuthenticationError: Error, Sendable, Equatable, LocalizedError {
    case serviceUnavailable
    case authenticationCancelled
    case presentationUnavailable
    case invalidRedirect
    case tokenUnavailable
    case accountUnavailable
    case authenticationFailed(domain: String, code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .serviceUnavailable:
            return String(localized: "OneDrive 登录服务尚未配置。")
        case .authenticationCancelled:
            return String(localized: "OneDrive 登录已取消。")
        case .presentationUnavailable:
            return String(localized: "OneDrive 登录窗口尚未就绪，请稍后重试。")
        case .invalidRedirect:
            return String(localized: "OneDrive 登录回调无效，请重试。")
        case .tokenUnavailable:
            return String(localized: "OneDrive 需要先登录。")
        case .accountUnavailable:
            return String(localized: "OneDrive 账号不可用，请重新登录。")
        case .authenticationFailed(let domain, let code, let message):
            let cleanMessage = AppOneDriveAuthenticationError.redactedDiagnosticMessage(message)
            if cleanMessage.isEmpty {
                return String(
                    format: String(localized: "OneDrive 登录失败：%@ %lld"),
                    domain,
                    code
                )
            }
            return String(
                format: String(localized: "OneDrive 登录失败：%@ %lld %@"),
                domain,
                code,
                cleanMessage
            )
        }
    }

    private static func redactedDiagnosticMessage(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        let sensitiveKeys = ["code=", "state=", "client_info=", "id_token=", "access_token=", "refresh_token="]
        var redacted = trimmed
        for key in sensitiveKeys {
            redacted = redacted.replacingOccurrences(
                of: "\(key)[^\\s&]+",
                with: "\(key)<redacted>",
                options: .regularExpression
            )
        }
        return redacted
    }
}
