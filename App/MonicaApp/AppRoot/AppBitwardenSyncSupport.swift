//
//  AppBitwardenSyncSupport.swift
//  Monica
//
//  Bitwarden 同步的状态、错误、预览、鉴权与密钥存储，以及同步游标与待发送变更队列的存储后端。
//

import MonicaSync
import CryptoKit
import Foundation

/// 接收 Bitwarden Send 的 UI 状态。
enum AppBitwardenReceiveState: Sendable, Equatable {
    case idle
    case running
    case succeeded(String)
    case failed(String)

    var label: String {
        switch self {
        case .idle: String(localized: "未开始")
        case .running: String(localized: "正在获取")
        case .succeeded(let title): String(localized: "已获取 \(title)")
        case .failed(let message): message
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

enum AppBitwardenSyncError: Error, Sendable, Equatable, LocalizedError {
    case providerUnavailable
    case invalidServerURL
    case attachmentUnavailable
    case fileSendUnavailable
    case invalidSendLink
    case emptyRemoteVault(localCount: Int)

    var errorDescription: String? {
        switch self {
        case .providerUnavailable:
            String(localized: "Bitwarden 同步尚未配置。")
        case .invalidServerURL:
            String(localized: "Bitwarden 服务器 URL 无效，仅支持 http/https。")
        case .attachmentUnavailable:
            String(localized: "Bitwarden 附件不可用，请重新同步后再试。")
        case .fileSendUnavailable:
            String(localized: "请选择要上传的 Bitwarden Send 文件。")
        case .invalidSendLink:
            String(localized: "Send 链接格式不正确，应形如 https://vault.bitwarden.com/#/send/<id>/<key>。")
        case .emptyRemoteVault(let localCount):
            String(localized: "Bitwarden 同步已暂停：远端返回空保险库，本地仍有 \(localCount) 个已同步条目。请确认账号或稍后重试。")
        }
    }
}

protocol AppBitwardenPasswordAuthenticationService: Sendable {
    func beginSignIn(
        email: String,
        masterPassword: String,
        serverURL: URL
    ) async throws -> BitwardenPasswordAuthenticationResult
    func completeTwoFactorSignIn(
        _ challenge: BitwardenTwoFactorLoginChallenge,
        code: String,
        providerID: Int,
        rememberDevice: Bool
    ) async throws -> BitwardenAuthenticationSession
    func requestEmailTwoFactorCode(for challenge: BitwardenTwoFactorLoginChallenge) async throws
}

struct MonicaSyncBitwardenPasswordAuthenticationService: AppBitwardenPasswordAuthenticationService {
    private let authenticator: BitwardenPasswordAuthenticator

    init(authenticator: BitwardenPasswordAuthenticator) {
        self.authenticator = authenticator
    }

    func beginSignIn(
        email: String,
        masterPassword: String,
        serverURL: URL
    ) async throws -> BitwardenPasswordAuthenticationResult {
        try await authenticator.beginSignIn(email: email, masterPassword: masterPassword, serverURL: serverURL)
    }

    func completeTwoFactorSignIn(
        _ challenge: BitwardenTwoFactorLoginChallenge,
        code: String,
        providerID: Int,
        rememberDevice: Bool
    ) async throws -> BitwardenAuthenticationSession {
        try await authenticator.completeTwoFactorSignIn(
            challenge,
            code: code,
            providerID: providerID,
            rememberDevice: rememberDevice
        )
    }

    func requestEmailTwoFactorCode(for challenge: BitwardenTwoFactorLoginChallenge) async throws {
        try await authenticator.requestEmailTwoFactorCode(for: challenge)
    }
}

struct AppBitwardenSyncPreview: Sendable, Equatable {
    let accountLabel: String
    let remoteItemCount: Int
    let remoteSendCount: Int
    let remoteLoginCount: Int
    let remotePasskeyCount: Int
    let remoteSshKeyCount: Int
    let remoteNoteCount: Int
    let remoteCardCount: Int
    let remoteIdentityCount: Int
    let remoteFolderCount: Int
    let remoteAttachmentByteCount: Int
    let premiumSource: BitwardenSyncSnapshot.PremiumSource
    let remoteSendTitles: [String]
    /// 字段级合并与集合过滤的计数；只有预览/同步路径才会填，旧调用方保持 nil。
    var mergeSummary: BitwardenSyncPreviewSummary?

    init(snapshot: BitwardenSyncSnapshot) {
        self.accountLabel = snapshot.accountLabel
        self.remoteItemCount = snapshot.items.count
        self.remoteSendCount = snapshot.sends.count
        self.remoteLoginCount = snapshot.items.filter { $0.kind == .login }.count
        self.remotePasskeyCount = snapshot.items.filter { $0.kind == .passkey }.count
        self.remoteSshKeyCount = snapshot.items.filter { $0.kind == .sshKey }.count
        self.remoteNoteCount = snapshot.items.filter { $0.kind == .secureNote }.count
        self.remoteCardCount = snapshot.items.filter { $0.kind == .card }.count
        self.remoteIdentityCount = snapshot.items.filter { $0.kind == .identity }.count
        self.remoteFolderCount = snapshot.folders.count
        self.remoteAttachmentByteCount = snapshot.items.map(\.attachmentByteCount).reduce(0, +)
            + snapshot.sends.map(\.attachmentByteCount).reduce(0, +)
        self.premiumSource = snapshot.premiumSource
        self.remoteSendTitles = snapshot.sends.map { Self.sanitizedTitle($0.title) }
    }

    var premiumSummary: String {
        switch premiumSource {
        case .none:
            String(localized: "未启用")
        case .account:
            String(localized: "账号 Premium")
        case .organization:
            String(localized: "组织 Premium")
        }
    }

    var kindSummary: String {
        var parts = [String(localized: "登录 \(remoteLoginCount)")]
        if remotePasskeyCount > 0 {
            parts.append(String(localized: "通行密钥 \(remotePasskeyCount)"))
        }
        if remoteSshKeyCount > 0 {
            parts.append("SSH Key \(remoteSshKeyCount)")
        }
        parts += [
            String(localized: "笔记 \(remoteNoteCount)"),
            String(localized: "卡片 \(remoteCardCount)"),
            String(localized: "身份 \(remoteIdentityCount)")
        ]
        return parts.joined(separator: "，")
    }

    var attachmentSummary: String {
        remoteAttachmentByteCount > 0 ? String(localized: "附件 \(remoteAttachmentByteCount) 字节") : String(localized: "无附件")
    }

    var redactedSummary: String {
        let sends = remoteSendTitles.prefix(3).joined(separator: " / ")
        return [
            String(localized: "Bitwarden \(accountLabel)：\(remoteItemCount) 个条目，\(remoteSendCount) 个 Send"),
            remoteFolderCount > 0 ? String(localized: "文件夹 \(remoteFolderCount)") : "",
            kindSummary,
            attachmentSummary,
            sends,
            mergeSummary?.redactedSummary ?? ""
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    private static func sanitizedTitle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "未命名") : trimmed
    }
}

struct FileAppBitwardenAuthenticationSessionStore: BitwardenAuthenticationSessionStore, @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(containerURL: URL, fileManager: FileManager = .default) {
        fileURL = containerURL
            .appendingPathComponent("bitwarden-auth-v1", isDirectory: true)
            .appendingPathComponent("session.json")
        self.fileManager = fileManager
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    func loadSession() throws -> BitwardenAuthenticationSession? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return try decoder.decode(BitwardenAuthenticationSession.self, from: Data(contentsOf: fileURL))
    }

    func saveSession(_ session: BitwardenAuthenticationSession) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(session)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    func clearSession() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        try fileManager.removeItem(at: fileURL)
    }
}

struct FileAppBitwardenVaultKeyStore: BitwardenVaultKeyStore, @unchecked Sendable {
    private let directoryURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(containerURL: URL, fileManager: FileManager = .default) {
        directoryURL = containerURL.appendingPathComponent("bitwarden-vault-key-v1", isDirectory: true)
        self.fileManager = fileManager
    }

    func loadVaultKey(accountLabel: String) throws -> BitwardenVaultKey? {
        let url = fileURL(accountLabel: accountLabel)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try decoder.decode(BitwardenVaultKey.self, from: Data(contentsOf: url))
    }

    func saveVaultKey(_ key: BitwardenVaultKey, accountLabel: String) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try encoder.encode(key)
        try data.write(to: fileURL(accountLabel: accountLabel), options: [.atomic, .completeFileProtection])
    }

    func clearVaultKey(accountLabel: String?) throws {
        guard let accountLabel else {
            guard fileManager.fileExists(atPath: directoryURL.path) else { return }
            try fileManager.removeItem(at: directoryURL)
            return
        }
        let url = fileURL(accountLabel: accountLabel)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func fileURL(accountLabel: String) -> URL {
        let normalized = accountLabel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directoryURL.appendingPathComponent("\(digest).json")
    }
}

protocol AppBitwardenSendSyncStateStore: Sendable {
    func loadStates(vaultID: String) throws -> [BitwardenSendSyncState]
    func saveStates(_ states: [BitwardenSendSyncState], vaultID: String) throws
}

protocol AppBitwardenFolderSyncStateStore: Sendable {
    func loadStates(vaultID: String) throws -> [BitwardenFolderSyncState]
    func saveStates(_ states: [BitwardenFolderSyncState], vaultID: String) throws
}

protocol AppBitwardenItemSyncStateStore: Sendable {
    func loadStates(vaultID: String) throws -> [BitwardenItemSyncState]
    func saveStates(_ states: [BitwardenItemSyncState], vaultID: String) throws
}

struct AppBitwardenPendingMutationBatch: Sendable, Equatable, Codable, Identifiable {
    let id: String
    let vaultID: String
    let queuedAt: Date
    let mutationCount: Int
    let redactedSummaries: [String]
    let retryCount: Int
    let lastErrorSummary: String

    init(
        id: String = UUID().uuidString,
        vaultID: String,
        queuedAt: Date = Date(),
        mutationCount: Int,
        redactedSummaries: [String],
        retryCount: Int,
        lastErrorSummary: String
    ) {
        self.id = id
        self.vaultID = vaultID
        self.queuedAt = queuedAt
        self.mutationCount = mutationCount
        self.redactedSummaries = redactedSummaries
        self.retryCount = retryCount
        self.lastErrorSummary = lastErrorSummary
    }

    var redactedSummary: String {
        String(localized: "Bitwarden 待重试 \(mutationCount) 个变更（第 \(retryCount) 次）")
    }
}

protocol AppBitwardenPendingMutationQueueStore: Sendable {
    func loadBatches(vaultID: String) throws -> [AppBitwardenPendingMutationBatch]
    func saveBatches(_ batches: [AppBitwardenPendingMutationBatch], vaultID: String) throws
}

final class MemoryAppBitwardenSendSyncStateStore: AppBitwardenSendSyncStateStore, @unchecked Sendable {
    private var statesByVaultID: [String: [BitwardenSendSyncState]] = [:]

    func loadStates(vaultID: String) throws -> [BitwardenSendSyncState] {
        statesByVaultID[vaultID, default: []]
    }

    func saveStates(_ states: [BitwardenSendSyncState], vaultID: String) throws {
        statesByVaultID[vaultID] = states
    }
}

final class MemoryAppBitwardenItemSyncStateStore: AppBitwardenItemSyncStateStore, @unchecked Sendable {
    private var statesByVaultID: [String: [BitwardenItemSyncState]] = [:]

    func loadStates(vaultID: String) throws -> [BitwardenItemSyncState] {
        statesByVaultID[vaultID, default: []]
    }

    func saveStates(_ states: [BitwardenItemSyncState], vaultID: String) throws {
        statesByVaultID[vaultID] = states
    }
}

final class MemoryAppBitwardenFolderSyncStateStore: AppBitwardenFolderSyncStateStore, @unchecked Sendable {
    private var statesByVaultID: [String: [BitwardenFolderSyncState]] = [:]

    func loadStates(vaultID: String) throws -> [BitwardenFolderSyncState] {
        statesByVaultID[vaultID, default: []]
    }

    func saveStates(_ states: [BitwardenFolderSyncState], vaultID: String) throws {
        statesByVaultID[vaultID] = states
    }
}

final class MemoryAppBitwardenPendingMutationQueueStore: AppBitwardenPendingMutationQueueStore, @unchecked Sendable {
    private var batchesByVaultID: [String: [AppBitwardenPendingMutationBatch]] = [:]

    func loadBatches(vaultID: String) throws -> [AppBitwardenPendingMutationBatch] {
        batchesByVaultID[vaultID, default: []]
    }

    func saveBatches(_ batches: [AppBitwardenPendingMutationBatch], vaultID: String) throws {
        batchesByVaultID[vaultID] = batches
    }

    func loadAllBatches() -> [AppBitwardenPendingMutationBatch] {
        batchesByVaultID
            .values
            .flatMap { $0 }
            .sorted { lhs, rhs in
                if lhs.queuedAt != rhs.queuedAt {
                    return lhs.queuedAt < rhs.queuedAt
                }
                return lhs.id < rhs.id
            }
    }
}

struct FileAppBitwardenSendSyncStateStore: AppBitwardenSendSyncStateStore, @unchecked Sendable {
    private let directoryURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(containerURL: URL, fileManager: FileManager = .default) {
        directoryURL = containerURL.appendingPathComponent("bitwarden-sync-state-v1", isDirectory: true)
        self.fileManager = fileManager
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    func loadStates(vaultID: String) throws -> [BitwardenSendSyncState] {
        let url = fileURL(vaultID: vaultID)
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }
        return try decoder.decode([BitwardenSendSyncState].self, from: Data(contentsOf: url))
    }

    func saveStates(_ states: [BitwardenSendSyncState], vaultID: String) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try encoder.encode(states).write(to: fileURL(vaultID: vaultID), options: [.atomic])
    }

    private func fileURL(vaultID: String) -> URL {
        let sanitized = vaultID
            .unicodeScalars
            .map { scalar -> String in
                switch scalar.value {
                case 48...57, 65...90, 97...122:
                    String(scalar)
                case 45, 95:
                    String(scalar)
                default:
                    "_"
                }
            }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return directoryURL.appendingPathComponent((sanitized.isEmpty ? "vault" : sanitized) + ".json")
    }
}

struct FileAppBitwardenFolderSyncStateStore: AppBitwardenFolderSyncStateStore, @unchecked Sendable {
    private let directoryURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(containerURL: URL, fileManager: FileManager = .default) {
        directoryURL = containerURL.appendingPathComponent("bitwarden-folder-sync-state-v1", isDirectory: true)
        self.fileManager = fileManager
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    func loadStates(vaultID: String) throws -> [BitwardenFolderSyncState] {
        let url = fileURL(vaultID: vaultID)
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }
        return try decoder.decode([BitwardenFolderSyncState].self, from: Data(contentsOf: url))
    }

    func saveStates(_ states: [BitwardenFolderSyncState], vaultID: String) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try encoder.encode(states).write(to: fileURL(vaultID: vaultID), options: [.atomic])
    }

    private func fileURL(vaultID: String) -> URL {
        let sanitized = vaultID
            .unicodeScalars
            .map { scalar -> String in
                switch scalar.value {
                case 48...57, 65...90, 97...122:
                    String(scalar)
                case 45, 95:
                    String(scalar)
                default:
                    "_"
                }
            }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return directoryURL.appendingPathComponent((sanitized.isEmpty ? "vault" : sanitized) + ".json")
    }
}

struct FileAppBitwardenItemSyncStateStore: AppBitwardenItemSyncStateStore, @unchecked Sendable {
    private let directoryURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(containerURL: URL, fileManager: FileManager = .default) {
        directoryURL = containerURL.appendingPathComponent("bitwarden-item-sync-state-v1", isDirectory: true)
        self.fileManager = fileManager
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    func loadStates(vaultID: String) throws -> [BitwardenItemSyncState] {
        let url = fileURL(vaultID: vaultID)
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }
        return try decoder.decode([BitwardenItemSyncState].self, from: Data(contentsOf: url))
    }

    func saveStates(_ states: [BitwardenItemSyncState], vaultID: String) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try encoder.encode(states).write(to: fileURL(vaultID: vaultID), options: [.atomic])
    }

    private func fileURL(vaultID: String) -> URL {
        let sanitized = vaultID
            .unicodeScalars
            .map { scalar -> String in
                switch scalar.value {
                case 48...57, 65...90, 97...122:
                    String(scalar)
                case 45, 95:
                    String(scalar)
                default:
                    "_"
                }
            }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return directoryURL.appendingPathComponent((sanitized.isEmpty ? "vault" : sanitized) + ".json")
    }
}

struct FileAppBitwardenPendingMutationQueueStore: AppBitwardenPendingMutationQueueStore, @unchecked Sendable {
    private let directoryURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(containerURL: URL, fileManager: FileManager = .default) {
        directoryURL = containerURL.appendingPathComponent("bitwarden-pending-mutation-queue-v1", isDirectory: true)
        self.fileManager = fileManager
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    func loadBatches(vaultID: String) throws -> [AppBitwardenPendingMutationBatch] {
        let url = fileURL(vaultID: vaultID)
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }
        return try decoder.decode([AppBitwardenPendingMutationBatch].self, from: Data(contentsOf: url))
    }

    func saveBatches(_ batches: [AppBitwardenPendingMutationBatch], vaultID: String) throws {
        let url = fileURL(vaultID: vaultID)
        if batches.isEmpty {
            guard fileManager.fileExists(atPath: url.path) else { return }
            try fileManager.removeItem(at: url)
            return
        }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try encoder.encode(batches).write(to: url, options: [.atomic])
    }

    private func fileURL(vaultID: String) -> URL {
        let sanitized = vaultID
            .unicodeScalars
            .map { scalar -> String in
                switch scalar.value {
                case 48...57, 65...90, 97...122:
                    String(scalar)
                case 45, 95:
                    String(scalar)
                default:
                    "_"
                }
            }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return directoryURL.appendingPathComponent((sanitized.isEmpty ? "vault" : sanitized) + ".json")
    }
}

enum BitwardenAuthenticationState: Sendable, Equatable {
    case disconnected
    case connected(accountLabel: String)
    case twoFactorRequired(accountLabel: String, providers: [BitwardenTwoFactorProvider])
    case failed(String)

    var label: String {
        switch self {
        case .disconnected:
            return String(localized: "Bitwarden 未登录")
        case .connected(let accountLabel):
            let normalized = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? String(localized: "Bitwarden 已登录") : String(localized: "Bitwarden 已登录 \(normalized)")
        case .twoFactorRequired(let accountLabel, let providers):
            let normalized = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let providerSummary = providers.map(\.displayName).joined(separator: "、")
            let account = normalized.isEmpty ? "Bitwarden" : "Bitwarden \(normalized)"
            return providerSummary.isEmpty
                ? String(localized: "\(account) 需要两步验证")
                : String(localized: "\(account) 需要两步验证：\(providerSummary)")
        case .failed(let message):
            return message
        }
    }

    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }

    var isTwoFactorRequired: Bool {
        if case .twoFactorRequired = self {
            return true
        }
        return false
    }
}

enum BitwardenSyncState: Sendable, Equatable {
    case idle
    case running
    case previewReady(itemCount: Int, sendCount: Int)
    case synced(itemCount: Int, sendCount: Int)
    case pushed(acceptedMutationCount: Int, conflictCount: Int)
    case queuedForRetry(mutationCount: Int)
    case queueCleared
    case twoFactorEmailSent
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            return String(localized: "就绪")
        case .running:
            return String(localized: "正在处理 Bitwarden")
        case .previewReady(let itemCount, let sendCount):
            return String(localized: "Bitwarden 已预览 \(itemCount) 个条目，\(sendCount) 个 Send")
        case .synced(let itemCount, let sendCount):
            return String(localized: "Bitwarden 已同步 \(itemCount) 个条目，\(sendCount) 个 Send")
        case .pushed(let acceptedMutationCount, let conflictCount):
            return String(localized: "Bitwarden 已推送 \(acceptedMutationCount) 个变更，\(conflictCount) 个冲突")
        case .queuedForRetry(let mutationCount):
            return String(localized: "Bitwarden 已暂存 \(mutationCount) 个变更，等待网络恢复后重试")
        case .queueCleared:
            return String(localized: "Bitwarden 同步队列已清空")
        case .twoFactorEmailSent:
            return String(localized: "Bitwarden 验证码已发送")
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


// MARK: - 增量同步检查点

/// 上次成功同步时远端返回的修订标记。只保存修订号与时间戳，
/// 不包含任何 token、主密码或条目内容，因此可以安全落盘。
struct AppBitwardenSyncCheckpoint: Codable, Sendable, Equatable {
    let revision: BitwardenSyncRevision
    let vaultID: String
    let syncedAt: Date

    var redactedSummary: String {
        String(localized: "上次同步 \(syncedAt.formatted(date: .numeric, time: .shortened))")
    }
}

protocol AppBitwardenSyncCheckpointStore: Sendable {
    func loadCheckpoint(vaultID: String) throws -> AppBitwardenSyncCheckpoint?
    func saveCheckpoint(_ checkpoint: AppBitwardenSyncCheckpoint?, vaultID: String) throws
}

final class MemoryAppBitwardenSyncCheckpointStore: AppBitwardenSyncCheckpointStore, @unchecked Sendable {
    private var checkpointsByVaultID: [String: AppBitwardenSyncCheckpoint] = [:]

    func loadCheckpoint(vaultID: String) throws -> AppBitwardenSyncCheckpoint? {
        checkpointsByVaultID[vaultID]
    }

    func saveCheckpoint(_ checkpoint: AppBitwardenSyncCheckpoint?, vaultID: String) throws {
        checkpointsByVaultID[vaultID] = checkpoint
    }
}

struct FileAppBitwardenSyncCheckpointStore: AppBitwardenSyncCheckpointStore, @unchecked Sendable {
    private let directoryURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(containerURL: URL, fileManager: FileManager = .default) {
        directoryURL = containerURL.appendingPathComponent("bitwarden-sync-checkpoint-v1", isDirectory: true)
        self.fileManager = fileManager
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    func loadCheckpoint(vaultID: String) throws -> AppBitwardenSyncCheckpoint? {
        let url = fileURL(vaultID: vaultID)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try decoder.decode(AppBitwardenSyncCheckpoint.self, from: Data(contentsOf: url))
    }

    func saveCheckpoint(_ checkpoint: AppBitwardenSyncCheckpoint?, vaultID: String) throws {
        let url = fileURL(vaultID: vaultID)
        guard let checkpoint else {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            return
        }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try encoder.encode(checkpoint).write(to: url, options: [.atomic])
    }

    private func fileURL(vaultID: String) -> URL {
        let sanitized = vaultID
            .unicodeScalars
            .map { scalar -> String in
                switch scalar.value {
                case 48...57, 65...90, 97...122:
                    String(scalar)
                case 45, 95:
                    String(scalar)
                default:
                    "_"
                }
            }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return directoryURL.appendingPathComponent((sanitized.isEmpty ? "vault" : sanitized) + ".json")
    }
}
