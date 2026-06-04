import MonicaCore
import MonicaMDBX
import MonicaSecurity
import MonicaStorage
import MonicaSync
import MonicaUI
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import Foundation
import LocalAuthentication
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

struct SecurityQuestionOption: Identifiable, Sendable, Equatable {
    let id: Int
    let text: String
}

enum WifiQRCodeRenderer {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func image(for payload: String, size: CGFloat = 192) -> UIImage? {
        guard !payload.isEmpty,
              let data = payload.data(using: .utf8)
        else {
            return nil
        }

        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else {
            return nil
        }

        let extent = outputImage.extent.integral
        let scale = max(1, floor(size / max(extent.width, extent.height)))
        let transformed = outputImage
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let renderedSize = CGSize(width: extent.width * scale, height: extent.height * scale)

        guard let cgImage = context.createCGImage(transformed, from: CGRect(origin: .zero, size: renderedSize)) else {
            return nil
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { rendererContext in
            UIColor.white.setFill()
            rendererContext.fill(CGRect(x: 0, y: 0, width: size, height: size))
            rendererContext.cgContext.interpolationQuality = .none
            let origin = CGPoint(
                x: floor((size - renderedSize.width) / 2),
                y: floor((size - renderedSize.height) / 2)
            )
            UIImage(cgImage: cgImage, scale: 1, orientation: .up)
                .draw(in: CGRect(origin: origin, size: renderedSize))
        }
    }
}

struct AppPermissionStatusRow: Sendable, Equatable, Identifiable {
    enum State: String, Sendable, Equatable {
        case granted
        case denied
        case notDetermined
        case unavailable
        case configured
        case notConfigured
        case checkable

        var label: String {
            switch self {
            case .granted:
                "已允许"
            case .denied:
                "未允许"
            case .notDetermined:
                "可检查"
            case .unavailable:
                "不可用"
            case .configured:
                "已配置"
            case .notConfigured:
                "待配置"
            case .checkable:
                "可检查"
            }
        }
    }

    let id: String
    let title: String
    let systemImage: String
    let state: State
    let detail: String
    let settingsURL: URL?

    init(
        id: String,
        title: String,
        systemImage: String,
        state: State,
        detail: String,
        settingsURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.state = state
        self.detail = detail
        self.settingsURL = settingsURL
    }

    var value: String {
        state.label
    }
}

struct AppDeveloperDiagnosticRow: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let systemImage: String
}

struct AppSecurityCenterRow: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let systemImage: String
}

struct AppSecurityCenterRepairSuggestion: Sendable, Equatable, Identifiable {
    let id: String
    let relatedRowID: String
    let title: String
    let detail: String
    let systemImage: String
}

struct AppPlusEntitlementStatusRow: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let systemImage: String
}

struct AppPlusFeatureRow: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let isUnlocked: Bool

    var value: String {
        isUnlocked ? "已解锁" : "需要 Plus"
    }
}

private enum AppPlusEntitlementSource: Sendable, Equatable {
    case none
    case resourceUnlock
}

private struct AppPlusEntitlementSnapshot: Sendable, Equatable {
    var source: AppPlusEntitlementSource = .none
    var expiresAt: Date?

    var isActive: Bool {
        source != .none
    }
}

protocol AppPlusResourceUnlockService: Sendable {
    func unlockPlus() async throws -> Bool
}

struct DefaultAppPlusResourceUnlockService: AppPlusResourceUnlockService {
    func unlockPlus() async throws -> Bool {
        true
    }
}

struct AppVaultQuickFilterRow: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let isSelected: Bool
}

struct AppAttachmentContentStatus: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case available
        case missing
        case unavailable
    }

    let state: State
    let value: String
    let detail: String
}

struct AppAttachmentPreviewFile: Sendable, Equatable {
    let fileURL: URL
    let displayFileName: String
    let byteCount: Int
}

enum AppAttachmentPreviewError: Error, Sendable, Equatable, LocalizedError {
    case contentEncryptionKeyUnavailable
    case previewFailed
    case contentWriteFailed

    var errorDescription: String? {
        switch self {
        case .contentEncryptionKeyUnavailable:
            return "附件内容密钥尚未可用。"
        case .previewFailed:
            return "附件预览准备失败。"
        case .contentWriteFailed:
            return "附件内容写回失败。"
        }
    }
}

enum VaultDisplayCardDensity: String, Sendable, Codable, Equatable, CaseIterable, Identifiable {
    case comfortable
    case compact

    var id: String { rawValue }

    var label: String {
        switch self {
        case .comfortable:
            "舒适"
        case .compact:
            "紧凑"
        }
    }

    var verticalSpacing: CGFloat {
        switch self {
        case .comfortable:
            8
        case .compact:
            4
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .comfortable:
            18
        case .compact:
            14
        }
    }
}

struct VaultDisplayPreferences: Sendable, Codable, Equatable {
    static let `default` = VaultDisplayPreferences(
        cardDensity: .comfortable,
        showsLoginUsername: true,
        showsLoginURL: true,
        showsTabLabels: true
    )

    var cardDensity: VaultDisplayCardDensity
    var showsLoginUsername: Bool
    var showsLoginURL: Bool
    var showsTabLabels: Bool
}

enum AppAppearanceColorScheme: String, Sendable, Codable, Equatable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system:
            "跟随系统"
        case .light:
            "浅色"
        case .dark:
            "深色"
        }
    }

    var swiftUIColorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

enum AppAppearanceAccentColor: String, Sendable, Codable, Equatable, CaseIterable, Identifiable {
    case monica
    case green
    case blue
    case orange

    var id: String { rawValue }

    var label: String {
        switch self {
        case .monica:
            "Monica"
        case .green:
            "绿色"
        case .blue:
            "蓝色"
        case .orange:
            "橙色"
        }
    }

    var swiftUIColor: Color {
        switch self {
        case .monica:
            AndroidParityPalette.primary
        case .green:
            .green
        case .blue:
            .blue
        case .orange:
            .orange
        }
    }
}

enum AppPasswordListIconStyle: String, Sendable, Codable, Equatable, CaseIterable, Identifiable {
    case color
    case monochrome
    case hidden

    var id: String { rawValue }

    var label: String {
        switch self {
        case .color:
            "彩色"
        case .monochrome:
            "单色"
        case .hidden:
            "隐藏"
        }
    }
}

struct AppAppearancePreferences: Sendable, Codable, Equatable {
    static let `default` = AppAppearancePreferences(
        colorScheme: .system,
        accentColor: .monica,
        passwordListIconStyle: .color
    )

    var colorScheme: AppAppearanceColorScheme
    var accentColor: AppAppearanceAccentColor
    var passwordListIconStyle: AppPasswordListIconStyle

    var swiftUIColorScheme: ColorScheme? {
        colorScheme.swiftUIColorScheme
    }

    var swiftUIAccentColor: Color {
        accentColor.swiftUIColor
    }

    var showsPasswordListIcon: Bool {
        passwordListIconStyle != .hidden
    }

    var passwordListIconFill: Color {
        switch passwordListIconStyle {
        case .color:
            AndroidParityPalette.primaryContainer
        case .monochrome:
            AndroidParityPalette.surface
        case .hidden:
            .clear
        }
    }

    var passwordListIconTint: Color {
        switch passwordListIconStyle {
        case .color:
            AndroidParityPalette.primary
        case .monochrome:
            AndroidParityPalette.textSecondary
        case .hidden:
            .clear
        }
    }
}

struct AppVaultDisplayPreferenceRow: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let systemImage: String
}

struct AppAppearancePreferenceRow: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let systemImage: String
}

struct AppLoginStackedGroup: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let preview: String
    let systemImage: String
    let entryIDs: [String]
}

private struct AppLoginStackedGroupKey: Hashable {
    let title: String
    let normalized: String
    let isWebsite: Bool
}

enum AppOperationTimelineAction: String, Sendable, Equatable {
    case created
    case updated
    case deleted
    case restored
    case moved
    case viewed

    var title: String {
        switch self {
        case .created:
            "已创建"
        case .updated:
            "已更新"
        case .deleted:
            "已删除"
        case .restored:
            "已恢复"
        case .moved:
            "已移动"
        case .viewed:
            "已查看"
        }
    }

    var systemImage: String {
        switch self {
        case .created:
            "plus.circle"
        case .updated:
            "pencil.circle"
        case .deleted:
            "trash.circle"
        case .restored:
            "arrow.uturn.backward.circle"
        case .moved:
            "arrow.right.circle"
        case .viewed:
            "eye.circle"
        }
    }
}

struct AppOperationTimelineEvent: Sendable, Equatable, Identifiable {
    let id: String
    let action: AppOperationTimelineAction
    let itemKind: UnifiedVaultItemKind
    let itemID: String
    let itemTitle: String
    let occurredAt: Date

    var title: String {
        "\(action.title) \(itemKind.displayName)"
    }

    var detail: String {
        itemTitle.isEmpty ? "未命名条目" : itemTitle
    }

    var systemImage: String {
        action.systemImage
    }
}

enum AppBitwardenSyncError: Error, Sendable, Equatable, LocalizedError {
    case providerUnavailable
    case invalidServerURL
    case emptyRemoteVault(localCount: Int)

    var errorDescription: String? {
        switch self {
        case .providerUnavailable:
            "Bitwarden 同步尚未配置。"
        case .invalidServerURL:
            "Bitwarden 服务器 URL 无效，仅支持 http/https。"
        case .emptyRemoteVault(let localCount):
            "Bitwarden 同步已暂停：远端返回空保险库，本地仍有 \(localCount) 个已同步条目。请确认账号或稍后重试。"
        }
    }
}

struct AppShareImportResult: Sendable, Equatable {
    let importedCounts: [UnifiedVaultItemKind: Int]
    let importedTitles: [String]

    var totalCount: Int {
        importedCounts.values.reduce(0, +)
    }
}

struct AppShortcutEntrySummary: Sendable, Equatable, Identifiable, Codable {
    let id: String
    let kind: UnifiedVaultItemKind
    let title: String
    let subtitle: String
    let searchableText: String

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case subtitle
        case searchableText
    }

    init(
        id: String,
        kind: UnifiedVaultItemKind,
        title: String,
        subtitle: String,
        searchableText: String
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.searchableText = searchableText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let kindRawValue = try container.decode(String.self, forKey: .kind)
        guard let decodedKind = UnifiedVaultItemKind(rawValue: kindRawValue) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown widget shortcut item kind."
            )
        }
        kind = decodedKind
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decode(String.self, forKey: .subtitle)
        searchableText = try container.decode(String.self, forKey: .searchableText)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind.rawValue, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(subtitle, forKey: .subtitle)
        try container.encode(searchableText, forKey: .searchableText)
    }

    var route: VaultItemRoute {
        VaultItemRoute(kind: kind, entryID: id)
    }
}

struct AppShortcutSnapshotEntry: Sendable, Equatable, Identifiable, Codable {
    let id: String
    let kind: UnifiedVaultItemKind
    let title: String
    let subtitle: String
    let searchableText: String
    let openURL: URL

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case subtitle
        case searchableText
        case openURL
    }

    init(summary: AppShortcutEntrySummary) {
        id = summary.id
        kind = summary.kind
        title = summary.title
        subtitle = summary.subtitle
        searchableText = summary.searchableText
        openURL = URL(string: "monica://shortcut/\(summary.kind.rawValue)/\(summary.id)")!
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let kindRawValue = try container.decode(String.self, forKey: .kind)
        guard let decodedKind = UnifiedVaultItemKind(rawValue: kindRawValue) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown shortcut snapshot item kind."
            )
        }
        kind = decodedKind
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decode(String.self, forKey: .subtitle)
        searchableText = try container.decode(String.self, forKey: .searchableText)
        openURL = try container.decode(URL.self, forKey: .openURL)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind.rawValue, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(subtitle, forKey: .subtitle)
        try container.encode(searchableText, forKey: .searchableText)
        try container.encode(openURL, forKey: .openURL)
    }
}

struct AppShortcutSnapshot: Sendable, Equatable, Codable {
    let vaultState: AppWidgetVaultState
    let entries: [AppShortcutSnapshotEntry]

    static let locked = AppShortcutSnapshot(vaultState: .locked, entries: [])
}

struct AppShortcutSnapshotFileStore: Sendable {
    let snapshotFileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(containerURL: URL) {
        snapshotFileURL = containerURL.appendingPathComponent("shortcuts-snapshot-v1.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
    }

    func saveSnapshot(_ snapshot: AppShortcutSnapshot) throws {
        let data = try encoder.encode(snapshot)
        try data.write(
            to: snapshotFileURL,
            options: [.atomic, .completeFileProtection]
        )
    }

    func loadSnapshot() throws -> AppShortcutSnapshot? {
        guard FileManager.default.fileExists(atPath: snapshotFileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: snapshotFileURL)
        return try decoder.decode(AppShortcutSnapshot.self, from: data)
    }
}

enum AppWidgetVaultState: String, Sendable, Equatable, Codable {
    case locked
    case unlocked

    var label: String {
        switch self {
        case .locked:
            "已锁定"
        case .unlocked:
            "已解锁"
        }
    }
}

struct AppWidgetTotpItem: Sendable, Equatable, Identifiable, Codable {
    let id: String
    let title: String
    let issuer: String
    let accountName: String
    let secondsRemaining: Int

    var timeRemainingLabel: String {
        "\(secondsRemaining) 秒"
    }
}

struct AppWidgetSnapshot: Sendable, Equatable, Codable {
    let vaultState: AppWidgetVaultState
    let totalEntryCount: Int
    let totpItems: [AppWidgetTotpItem]
    let shortcutItems: [AppShortcutEntrySummary]

    var totalEntryLabel: String {
        "\(totalEntryCount) 项"
    }

    var redactedDebugSummary: String {
        let totpText = totpItems
            .map { "\($0.title) \($0.issuer) \($0.accountName) \($0.timeRemainingLabel)" }
            .joined(separator: " ")
        let shortcutText = shortcutItems
            .map { "\($0.kind.displayName) \($0.title) \($0.subtitle) \($0.searchableText)" }
            .joined(separator: " ")
        return [
            vaultState.label,
            totalEntryLabel,
            totpText,
            shortcutText
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }
}

struct AppWidgetSnapshotFileStore: Sendable {
    let snapshotFileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(containerURL: URL) {
        snapshotFileURL = containerURL.appendingPathComponent("widget-snapshot-v1.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
    }

    func saveSnapshot(_ snapshot: AppWidgetSnapshot) throws {
        let data = try encoder.encode(snapshot)
        try data.write(
            to: snapshotFileURL,
            options: [.atomic, .completeFileProtection]
        )
    }

    func loadSnapshot() throws -> AppWidgetSnapshot? {
        guard FileManager.default.fileExists(atPath: snapshotFileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: snapshotFileURL)
        return try decoder.decode(AppWidgetSnapshot.self, from: data)
    }
}

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
        "\(provider.displayName) \(fileName) \(byteCount) 字节"
    }

    private static func sanitizedFileName(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? value
        let sanitized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "未命名文件" : sanitized
    }
}

struct AppOneDriveAuthenticationSession: Sendable, Equatable {
    let accountLabel: String

    var redactedSummary: String {
        "OneDrive \(accountLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "已登录" : accountLabel)"
    }
}

protocol AppOneDriveAuthenticationService: OneDriveAccessTokenProvider {
    func restoreSession() async throws -> AppOneDriveAuthenticationSession?
    func signIn() async throws -> AppOneDriveAuthenticationSession
    func signOut() async throws
    func handleRedirectURL(_ url: URL) -> Bool
}

protocol AppBitwardenPasswordAuthenticationService: Sendable {
    func signIn(email: String, masterPassword: String, serverURL: URL) async throws -> BitwardenAuthenticationSession
}

struct MonicaSyncBitwardenPasswordAuthenticationService: AppBitwardenPasswordAuthenticationService {
    private let authenticator: BitwardenPasswordAuthenticator

    init(authenticator: BitwardenPasswordAuthenticator) {
        self.authenticator = authenticator
    }

    func signIn(email: String, masterPassword: String, serverURL: URL) async throws -> BitwardenAuthenticationSession {
        try await authenticator.signIn(email: email, masterPassword: masterPassword, serverURL: serverURL)
    }
}

struct AppBitwardenSyncPreview: Sendable, Equatable {
    let accountLabel: String
    let remoteItemCount: Int
    let remoteSendCount: Int
    let remoteLoginCount: Int
    let remotePasskeyCount: Int
    let remoteNoteCount: Int
    let remoteCardCount: Int
    let remoteIdentityCount: Int
    let remoteFolderCount: Int
    let remoteAttachmentByteCount: Int
    let remoteSendTitles: [String]

    init(snapshot: BitwardenSyncSnapshot) {
        self.accountLabel = snapshot.accountLabel
        self.remoteItemCount = snapshot.items.count
        self.remoteSendCount = snapshot.sends.count
        self.remoteLoginCount = snapshot.items.filter { $0.kind == .login }.count
        self.remotePasskeyCount = snapshot.items.filter { $0.kind == .passkey }.count
        self.remoteNoteCount = snapshot.items.filter { $0.kind == .secureNote }.count
        self.remoteCardCount = snapshot.items.filter { $0.kind == .card }.count
        self.remoteIdentityCount = snapshot.items.filter { $0.kind == .identity }.count
        self.remoteFolderCount = snapshot.folders.count
        self.remoteAttachmentByteCount = snapshot.items.map(\.attachmentByteCount).reduce(0, +)
            + snapshot.sends.map(\.attachmentByteCount).reduce(0, +)
        self.remoteSendTitles = snapshot.sends.map { Self.sanitizedTitle($0.title) }
    }

    var kindSummary: String {
        var parts = ["登录 \(remoteLoginCount)"]
        if remotePasskeyCount > 0 {
            parts.append("通行密钥 \(remotePasskeyCount)")
        }
        parts += [
            "笔记 \(remoteNoteCount)",
            "卡片 \(remoteCardCount)",
            "身份 \(remoteIdentityCount)"
        ]
        return parts.joined(separator: "，")
    }

    var attachmentSummary: String {
        remoteAttachmentByteCount > 0 ? "附件 \(remoteAttachmentByteCount) 字节" : "无附件"
    }

    var redactedSummary: String {
        let sends = remoteSendTitles.prefix(3).joined(separator: " / ")
        return [
            "Bitwarden \(accountLabel)：\(remoteItemCount) 个条目，\(remoteSendCount) 个 Send",
            remoteFolderCount > 0 ? "文件夹 \(remoteFolderCount)" : "",
            kindSummary,
            attachmentSummary,
            sends
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    private static func sanitizedTitle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名" : trimmed
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
        "Bitwarden 待重试 \(mutationCount) 个变更（第 \(retryCount) 次）"
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

struct AppDuplicateLoginMergePreview: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let username: String
    let url: String
    let entryCountLabel: String
    let primaryEntryID: String
    let duplicateEntryIDs: [String]
    let detail: String
}

private struct AppDuplicateLoginMergeUndo: Sendable, Equatable {
    let title: String
    let restoredEntryIDs: [String]
}

private struct DuplicateLoginEntryKey: Hashable {
    let title: String
    let username: String
    let url: String

    init?(entry: LocalLoginEntry) {
        title = Self.normalized(entry.title)
        username = Self.normalized(entry.username)
        url = Self.normalized(entry.url)
        guard !title.isEmpty || !username.isEmpty || !url.isEmpty else {
            return nil
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private extension String {
    var nonBlankValue: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum AppDeveloperDiagnostics {
    @MainActor
    static func rows(
        environment: MonicaAppEnvironment,
        session: AppSessionModel,
        storageStrategy: String,
        mdbxBridge: String
    ) -> [AppDeveloperDiagnosticRow] {
        [
            AppDeveloperDiagnosticRow(
                id: "storage",
                title: "主存储",
                value: storageStrategy,
                detail: "当前 iOS 本地 vault 主格式。",
                systemImage: "externaldrive"
            ),
            AppDeveloperDiagnosticRow(
                id: "mdbx-bridge",
                title: "MDBX 桥接",
                value: mdbxBridge,
                detail: "Swift 到 Rust MDBX 的桥接层。",
                systemImage: "point.3.connected.trianglepath.dotted"
            ),
            AppDeveloperDiagnosticRow(
                id: "app-group",
                title: "App Group",
                value: environment.appGroupIdentifier,
                detail: "主 App 与扩展共享加密索引的位置。",
                systemImage: "rectangle.connected.to.line.below"
            ),
            AppDeveloperDiagnosticRow(
                id: "device-id",
                title: "本机标识",
                value: redactedIdentifier(environment.localDeviceIdentifier),
                detail: "仅显示脱敏值，用于排查本地 vault/device 绑定。",
                systemImage: "iphone"
            ),
            AppDeveloperDiagnosticRow(
                id: "autofill-index",
                title: "AutoFill 索引",
                value: autoFillDiagnosticValue(session.autoFillIndexState),
                detail: "最近一次 AutoFill 加密索引生成状态。",
                systemImage: "key.viewfinder"
            ),
            AppDeveloperDiagnosticRow(
                id: "sync-log",
                title: "同步日志",
                value: syncDiagnosticValue(session.webDAVBackupState),
                detail: "当前 WebDAV 备份/恢复状态摘要，不包含 URL、用户名或密码。",
                systemImage: "arrow.triangle.2.circlepath"
            ),
            AppDeveloperDiagnosticRow(
                id: "bitwarden-sync",
                title: "Bitwarden",
                value: session.bitwardenSyncState.label,
                detail: "当前 Bitwarden 同步状态摘要，不包含 token、远端 ID、密码、TOTP 或 Send 内容。",
                systemImage: "lock.icloud"
            )
        ]
    }

    private static func redactedIdentifier(_ identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "未设置"
        }
        guard trimmed.count > 8 else {
            return "已设置"
        }
        return "\(trimmed.prefix(3))…\(trimmed.suffix(3))"
    }

    private static func autoFillDiagnosticValue(_ state: AutoFillIndexState) -> String {
        switch state {
        case .idle:
            return "未生成"
        case .running, .succeeded, .failed:
            return state.label
        }
    }

    private static func syncDiagnosticValue(_ state: WebDAVBackupState) -> String {
        switch state {
        case .idle:
            return "空闲"
        case .running, .backupSucceeded, .restorePreviewReady, .restoreSucceeded, .failed:
            return state.label
        }
    }
}

struct SecurityQuestionRecoverySetup: Sendable, Codable, Equatable {
    let vaultID: String
    let question1ID: Int
    let question1Text: String
    let answer1Hash: String
    let question2ID: Int
    let question2Text: String
    let answer2Hash: String
}

protocol SecurityQuestionRecoveryStore {
    func save(_ setup: SecurityQuestionRecoverySetup) throws
    func load(vaultID: String) throws -> SecurityQuestionRecoverySetup?
    func delete(vaultID: String) throws
}

enum ForgotPasswordRecoveryStep: Sendable, Equatable {
    case none
    case verifySecurityQuestions
    case resetPassword
}

struct CSVImportPreview: Sendable, Equatable {
    let report: VaultCSVImportReport

    var items: [VaultCSVItemDraft] { report.items }
    var issues: [VaultCSVImportIssue] { report.issues }
}

struct AndroidBackupImportPreview: Sendable, Equatable {
    let report: AndroidBackupImportReport

    var items: [VaultCSVItemDraft] { report.items }
    var attachments: [AndroidBackupAttachmentMetadata] { report.attachments }
    var issues: [AndroidBackupImportIssue] { report.issues }
}

struct KeePassImportPreview: Sendable, Equatable {
    let report: KeePassImportPreviewReport
    let unlockPreflight: KeePassUnlockPreflightReport?

    var format: KeePassContainerFormat { report.format }
    var status: KeePassImportStatus { report.status }
    var headerSummary: KeePassHeaderSummary? { report.headerSummary }
    var issue: KeePassImportIssue? { report.issue }
}

struct AppKeePassImportedEntryReference: Sendable, Equatable {
    let sourceEntryID: String
    let sourceGroupID: String?
    let sourceGroupPath: String
    let importedLoginEntryID: String
    let importedTotpEntryID: String?
    let importedProjectID: String
    let importedAsDeleted: Bool
    let importedAttachmentEntryIDs: [String]

    init(
        sourceEntryID: String,
        sourceGroupID: String?,
        sourceGroupPath: String,
        importedLoginEntryID: String,
        importedTotpEntryID: String? = nil,
        importedProjectID: String,
        importedAsDeleted: Bool = false,
        importedAttachmentEntryIDs: [String] = []
    ) {
        self.sourceEntryID = sourceEntryID
        self.sourceGroupID = sourceGroupID
        self.sourceGroupPath = sourceGroupPath
        self.importedLoginEntryID = importedLoginEntryID
        self.importedTotpEntryID = importedTotpEntryID
        self.importedProjectID = importedProjectID
        self.importedAsDeleted = importedAsDeleted
        self.importedAttachmentEntryIDs = importedAttachmentEntryIDs
    }
}

struct AppKeePassAttachmentEditCandidate: Sendable, Equatable, Identifiable {
    let id: String
    let entryID: String
    let attachmentID: String
    let entryTitle: String
    let entryUsername: String
    let groupPath: String
    let fileName: String
    let mediaType: String
    let originalSize: Int64
    let isDeletedEntry: Bool
    let searchableText: String
}

struct AppKeePassKdbxWritebackResult: Sendable, Equatable {
    let database: Data
    let entryCount: Int
    let attachmentCount: Int

    init(database: Data, entryCount: Int, attachmentCount: Int) {
        self.database = database
        self.entryCount = entryCount
        self.attachmentCount = attachmentCount
    }

    init(_ result: KeePassKdbx3WritebackResult) {
        self.init(
            database: result.database,
            entryCount: result.entryCount,
            attachmentCount: result.attachmentCount
        )
    }

    init(_ result: KeePassKdbx4WritebackResult) {
        self.init(
            database: result.database,
            entryCount: result.entryCount,
            attachmentCount: result.attachmentCount
        )
    }
}

struct AppKeePassCloudFileSource: Sendable, Equatable {
    let provider: CloudFileProviderKind
    let itemID: String
    let fileName: String
    let revision: String?
}

struct CSVExportDocument: FileDocument, Sendable {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }

    var text: String

    init(text: String = "") {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8)
        else {
            self.text = ""
            return
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct AndroidBackupExportDocument: FileDocument, Sendable {
    static var readableContentTypes: [UTType] { [.zip] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

typealias AndroidBackupAttachmentBlobStore = LocalAttachmentContentStore
typealias FileAndroidBackupAttachmentBlobStore = FileLocalAttachmentContentStore

enum FirstTimePasswordSetupStep: Sendable, Equatable {
    case enterPassword
    case confirmPassword
}

enum BiometricUnlockKind: Sendable, Equatable {
    case faceID
    case touchID

    var displayName: String {
        switch self {
        case .faceID:
            return "Face ID"
        case .touchID:
            return "Touch ID"
        }
    }

    var systemImage: String {
        switch self {
        case .faceID:
            return "faceid"
        case .touchID:
            return "touchid"
        }
    }
}

enum BiometricUnlockCapability: Sendable, Equatable {
    case unavailable
    case available(BiometricUnlockKind)

    var kind: BiometricUnlockKind? {
        if case .available(let kind) = self {
            return kind
        }
        return nil
    }
}

struct RememberedVaultRecord: Sendable, Codable, Equatable {
    let fileURL: URL
    let displayName: String
    let vaultID: String
}

protocol RememberedVaultStore: Sendable {
    func load() throws -> RememberedVaultRecord?
    func save(_ record: RememberedVaultRecord) throws
    func delete() throws
}

protocol BiometricUnlockPreferenceStore: Sendable {
    func loadIsEnabled() -> Bool
    func saveIsEnabled(_ isEnabled: Bool)
}

protocol VaultDisplayPreferenceStore: Sendable {
    func loadPreferences() -> VaultDisplayPreferences
    func savePreferences(_ preferences: VaultDisplayPreferences)
}

protocol AppAppearancePreferenceStore: Sendable {
    func loadPreferences() -> AppAppearancePreferences
    func savePreferences(_ preferences: AppAppearancePreferences)
}

protocol AppPlusEntitlementStore: Sendable {
    func loadIsResourceUnlocked() -> Bool
    func saveIsResourceUnlocked(_ isUnlocked: Bool)
}

protocol BiometricUnlockAuthorizer: Sendable {
    func authenticate(reason: String) async throws
}

enum FirstTimePasswordSetupError: Error, Sendable, Equatable, LocalizedError {
    case passwordMismatch

    var errorDescription: String? {
        switch self {
        case .passwordMismatch:
            return "两次输入的主密码不一致。"
        }
    }
}

enum SecurityQuestionRecoveryError: Error, Sendable, Equatable, LocalizedError {
    case duplicateQuestions
    case missingAnswers
    case missingSecurityQuestions
    case verificationRequired
    case passwordMismatch

    var errorDescription: String? {
        switch self {
        case .duplicateQuestions:
            return "请选择两道不同的密保问题。"
        case .missingAnswers:
            return "请填写两道密保问题答案。"
        case .missingSecurityQuestions:
            return "当前保险库未设置密保问题。"
        case .verificationRequired:
            return "请先通过密保问题验证。"
        case .passwordMismatch:
            return "两次输入的新密码不一致。"
        }
    }
}

struct UserDefaultsSecurityQuestionRecoveryStore: SecurityQuestionRecoveryStore {
    private let userDefaults: UserDefaults
    private let keyPrefix = "monica.securityQuestions."

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func save(_ setup: SecurityQuestionRecoverySetup) throws {
        let data = try JSONEncoder().encode(setup)
        userDefaults.set(data, forKey: key(for: setup.vaultID))
    }

    func load(vaultID: String) throws -> SecurityQuestionRecoverySetup? {
        guard let data = userDefaults.data(forKey: key(for: vaultID)) else {
            return nil
        }
        return try JSONDecoder().decode(SecurityQuestionRecoverySetup.self, from: data)
    }

    func delete(vaultID: String) throws {
        userDefaults.removeObject(forKey: key(for: vaultID))
    }

    private func key(for vaultID: String) -> String {
        keyPrefix + vaultID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class MemorySecurityQuestionRecoveryStore: SecurityQuestionRecoveryStore {
    private let lock = NSLock()
    private var setups: [String: SecurityQuestionRecoverySetup] = [:]

    func save(_ setup: SecurityQuestionRecoverySetup) throws {
        lock.lock()
        setups[setup.vaultID] = setup
        lock.unlock()
    }

    func load(vaultID: String) throws -> SecurityQuestionRecoverySetup? {
        lock.lock()
        defer { lock.unlock() }
        return setups[vaultID.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    func delete(vaultID: String) throws {
        lock.lock()
        setups.removeValue(forKey: vaultID.trimmingCharacters(in: .whitespacesAndNewlines))
        lock.unlock()
    }
}

final class UserDefaultsRememberedVaultStore: RememberedVaultStore, @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let key = "monica.rememberedVault"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func load() throws -> RememberedVaultRecord? {
        guard let data = userDefaults.data(forKey: key) else {
            return nil
        }
        return try JSONDecoder().decode(RememberedVaultRecord.self, from: data)
    }

    func save(_ record: RememberedVaultRecord) throws {
        userDefaults.set(try JSONEncoder().encode(record), forKey: key)
    }

    func delete() throws {
        userDefaults.removeObject(forKey: key)
    }
}

final class MemoryRememberedVaultStore: RememberedVaultStore, @unchecked Sendable {
    private(set) var record: RememberedVaultRecord?

    init(record: RememberedVaultRecord? = nil) {
        self.record = record
    }

    var savedDescriptor: LocalVaultDescriptor? {
        record.map {
            LocalVaultDescriptor(fileURL: $0.fileURL, displayName: $0.displayName)
        }
    }

    func load() throws -> RememberedVaultRecord? {
        record
    }

    func save(_ record: RememberedVaultRecord) throws {
        self.record = record
    }

    func delete() throws {
        record = nil
    }
}

final class UserDefaultsBiometricUnlockPreferenceStore: BiometricUnlockPreferenceStore, @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let key = "monica.biometricUnlockEnabled"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func loadIsEnabled() -> Bool {
        userDefaults.bool(forKey: key)
    }

    func saveIsEnabled(_ isEnabled: Bool) {
        userDefaults.set(isEnabled, forKey: key)
    }
}

final class MemoryBiometricUnlockPreferenceStore: BiometricUnlockPreferenceStore, @unchecked Sendable {
    private(set) var isEnabled: Bool

    init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    func loadIsEnabled() -> Bool {
        isEnabled
    }

    func saveIsEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
    }
}

final class UserDefaultsVaultDisplayPreferenceStore: VaultDisplayPreferenceStore, @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let key = "monica.vaultDisplayPreferences"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func loadPreferences() -> VaultDisplayPreferences {
        guard let data = userDefaults.data(forKey: key),
              let preferences = try? JSONDecoder().decode(VaultDisplayPreferences.self, from: data)
        else {
            return .default
        }
        return preferences
    }

    func savePreferences(_ preferences: VaultDisplayPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else {
            return
        }
        userDefaults.set(data, forKey: key)
    }
}

final class MemoryVaultDisplayPreferenceStore: VaultDisplayPreferenceStore, @unchecked Sendable {
    private(set) var preferences: VaultDisplayPreferences?

    init(preferences: VaultDisplayPreferences? = nil) {
        self.preferences = preferences
    }

    func loadPreferences() -> VaultDisplayPreferences {
        preferences ?? .default
    }

    func savePreferences(_ preferences: VaultDisplayPreferences) {
        self.preferences = preferences
    }
}

final class UserDefaultsAppAppearancePreferenceStore: AppAppearancePreferenceStore, @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let key = "monica.appAppearancePreferences"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func loadPreferences() -> AppAppearancePreferences {
        guard let data = userDefaults.data(forKey: key),
              let preferences = try? JSONDecoder().decode(AppAppearancePreferences.self, from: data)
        else {
            return .default
        }
        return preferences
    }

    func savePreferences(_ preferences: AppAppearancePreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else {
            return
        }
        userDefaults.set(data, forKey: key)
    }
}

final class MemoryAppAppearancePreferenceStore: AppAppearancePreferenceStore, @unchecked Sendable {
    private(set) var preferences: AppAppearancePreferences?

    init(preferences: AppAppearancePreferences? = nil) {
        self.preferences = preferences
    }

    func loadPreferences() -> AppAppearancePreferences {
        preferences ?? .default
    }

    func savePreferences(_ preferences: AppAppearancePreferences) {
        self.preferences = preferences
    }
}

private struct AppPlusPersistedEntitlement: Codable, Equatable {
    let source: String?

    static let inactive = AppPlusPersistedEntitlement(source: nil)
    static let resourceUnlock = AppPlusPersistedEntitlement(source: "resourceUnlock")

    var isResourceUnlocked: Bool {
        source == Self.resourceUnlock.source
    }
}

final class UserDefaultsAppPlusEntitlementStore: AppPlusEntitlementStore, @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let key = "monica.plusEntitlement"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func loadIsResourceUnlocked() -> Bool {
        guard let data = userDefaults.data(forKey: key),
              let entitlement = try? JSONDecoder().decode(AppPlusPersistedEntitlement.self, from: data)
        else {
            return false
        }
        return entitlement.isResourceUnlocked
    }

    func saveIsResourceUnlocked(_ isUnlocked: Bool) {
        let entitlement: AppPlusPersistedEntitlement = isUnlocked ? .resourceUnlock : .inactive
        guard let data = try? JSONEncoder().encode(entitlement) else {
            return
        }
        userDefaults.set(data, forKey: key)
    }
}

final class MemoryAppPlusEntitlementStore: AppPlusEntitlementStore, @unchecked Sendable {
    private var entitlement: AppPlusPersistedEntitlement

    init(isResourceUnlocked: Bool = false) {
        self.entitlement = isResourceUnlocked ? .resourceUnlock : .inactive
    }

    var persistedDebugText: String {
        guard let data = try? JSONEncoder().encode(entitlement) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    func loadIsResourceUnlocked() -> Bool {
        entitlement.isResourceUnlocked
    }

    func saveIsResourceUnlocked(_ isUnlocked: Bool) {
        entitlement = isUnlocked ? .resourceUnlock : .inactive
    }
}

struct DeviceBiometricUnlockAuthorizer: BiometricUnlockAuthorizer {
    func authenticate(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw MonicaSecurityError.localAuthenticationFailed
        }

        do {
            try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
        } catch {
            throw MonicaSecurityError.localAuthenticationFailed
        }
    }
}

func deviceBiometricUnlockCapability() -> BiometricUnlockCapability {
    let context = LAContext()
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
        return .unavailable
    }

    switch context.biometryType {
    case .faceID, .opticID:
        return .available(.faceID)
    case .touchID:
        return .available(.touchID)
    case .none:
        return .unavailable
    @unknown default:
        return .unavailable
    }
}

@MainActor
@Observable
final class AppSessionModel {
    static let securityQuestionOptions: [SecurityQuestionOption] = [
        .init(id: 42, text: "你喜欢什么奥特曼？"),
        .init(id: 1, text: "您第一只宠物的名字是什么？"),
        .init(id: 2, text: "您母亲的娘家姓是什么？"),
        .init(id: 3, text: "您出生在哪个城市？"),
        .init(id: 4, text: "您的小学校名是什么？"),
        .init(id: 5, text: "您最喜欢的电影是什么？"),
        .init(id: 6, text: "您的第一辆汽车是什么型号？"),
        .init(id: 7, text: "您童年最好朋友的名字是什么？"),
        .init(id: 8, text: "您小时候最喜欢的食物是什么？"),
        .init(id: 9, text: "您成长的街道名称是什么？"),
        .init(id: 10, text: "您高中的吉祥物是什么？")
    ]

    var selectedTab: MonicaAppTab = .passwords
    var vaultState: VaultState = .locked
    var vaultOperationState: VaultOperationState = .idle
    var vaultName = ""
    var vaultPassword = ""
    var firstTimePasswordSetupStep: FirstTimePasswordSetupStep = .enterPassword
    var activeVaultName: String?
    var entryOperationState: EntryOperationState = .idle
    var loginTitle = ""
    var loginUsername = ""
    var loginPassword = ""
    var loginURL = ""
    var loginSearchQuery = ""
    var showFavoriteLoginEntriesOnly = false
    var isLoginStackedGroupModeEnabled = false
    var loginEntries: [LocalLoginEntry] = []
    var deletedLoginEntries: [LocalLoginEntry] = []
    var breachedPasswordSHA256Fingerprints: Set<String> = []
    var operationTimelineEvents: [AppOperationTimelineEvent] = []
    private var ignoredDuplicateLoginKeys: Set<DuplicateLoginEntryKey> = []
    private var lastDuplicateLoginMergeUndo: AppDuplicateLoginMergeUndo?
    private var nextOperationTimelineEventSequence = 0
    var editingLoginEntryID: String?
    var editingLoginTitle = ""
    var editingLoginUsername = ""
    var editingLoginPassword = ""
    var editingLoginURL = ""
    var editingLoginFavorite = false
    var noteTitle = ""
    var noteBody = ""
    var noteSearchQuery = ""
    var showFavoriteNoteEntriesOnly = false
    var noteEntries: [LocalNoteEntry] = []
    var deletedNoteEntries: [LocalNoteEntry] = []
    var editingNoteEntryID: String?
    var editingNoteTitle = ""
    var editingNoteBody = ""
    var editingNoteFavorite = false
    var totpTitle = ""
    var totpSecret = ""
    var totpIssuer = ""
    var totpAccountName = ""
    var totpPeriod: UInt32 = 30
    var totpDigits: UInt32 = 6
    var totpAlgorithm = "SHA1"
    var totpImportURI = ""
    var totpSearchQuery = ""
    var showFavoriteTotpEntriesOnly = false
    var totpEntries: [LocalTotpEntry] = []
    var deletedTotpEntries: [LocalTotpEntry] = []
    var editingTotpEntryID: String?
    var editingTotpTitle = ""
    var editingTotpSecret = ""
    var editingTotpIssuer = ""
    var editingTotpAccountName = ""
    var editingTotpPeriod: UInt32 = 30
    var editingTotpDigits: UInt32 = 6
    var editingTotpAlgorithm = "SHA1"
    var editingTotpFavorite = false
    var cardTitle = ""
    var cardholderName = ""
    var cardNumber = ""
    var cardExpiryMonth = ""
    var cardExpiryYear = ""
    var cardCVV = ""
    var cardIssuer = ""
    var cardNetwork = ""
    var cardNotes = ""
    var cardSearchQuery = ""
    var showFavoriteCardEntriesOnly = false
    var cardEntries: [LocalCardEntry] = []
    var deletedCardEntries: [LocalCardEntry] = []
    var editingCardEntryID: String?
    var editingCardTitle = ""
    var editingCardholderName = ""
    var editingCardNumber = ""
    var editingCardExpiryMonth = ""
    var editingCardExpiryYear = ""
    var editingCardCVV = ""
    var editingCardIssuer = ""
    var editingCardNetwork = ""
    var editingCardNotes = ""
    var editingCardFavorite = false
    var identityTitle = ""
    var identityDocumentType = ""
    var identityFullName = ""
    var identityDocumentNumber = ""
    var identityIssuer = ""
    var identityCountry = ""
    var identityIssueDate = ""
    var identityExpiryDate = ""
    var identityNotes = ""
    var identitySearchQuery = ""
    var showFavoriteIdentityEntriesOnly = false
    var identityEntries: [LocalIdentityEntry] = []
    var deletedIdentityEntries: [LocalIdentityEntry] = []
    var editingIdentityEntryID: String?
    var editingIdentityTitle = ""
    var editingIdentityDocumentType = ""
    var editingIdentityFullName = ""
    var editingIdentityDocumentNumber = ""
    var editingIdentityIssuer = ""
    var editingIdentityCountry = ""
    var editingIdentityIssueDate = ""
    var editingIdentityExpiryDate = ""
    var editingIdentityNotes = ""
    var editingIdentityFavorite = false
    var passkeyTitle = ""
    var passkeyRelyingPartyID = ""
    var passkeyUsername = ""
    var passkeyUserHandle = ""
    var passkeyCredentialID = ""
    var passkeyPublicKeyCOSE = ""
    var passkeyPrivateKeyReference = ""
    var passkeyNotes = ""
    var passkeySearchQuery = ""
    var showFavoritePasskeyEntriesOnly = false
    var passkeyEntries: [LocalPasskeyEntry] = []
    var deletedPasskeyEntries: [LocalPasskeyEntry] = []
    var editingPasskeyEntryID: String?
    var editingPasskeyTitle = ""
    var editingPasskeyRelyingPartyID = ""
    var editingPasskeyUsername = ""
    var editingPasskeyUserHandle = ""
    var editingPasskeyCredentialID = ""
    var editingPasskeyPublicKeyCOSE = ""
    var editingPasskeyPrivateKeyReference = ""
    var editingPasskeyNotes = ""
    var editingPasskeyFavorite = false
    var sshKeyEntries: [LocalSshKeyEntry] = []
    var deletedSshKeyEntries: [LocalSshKeyEntry] = []
    var sshKeyTitle = ""
    var sshKeyUsername = ""
    var sshKeyHost = ""
    var sshKeyPublicKey = ""
    var sshKeyPrivateKeyReference = ""
    var sshKeyPassphraseHint = ""
    var sshKeyNotes = ""
    var sshKeySearchQuery = ""
    var showFavoriteSshKeyEntriesOnly = false
    var editingSshKeyEntryID: String?
    var editingSshKeyTitle = ""
    var editingSshKeyUsername = ""
    var editingSshKeyHost = ""
    var editingSshKeyPublicKey = ""
    var editingSshKeyPrivateKeyReference = ""
    var editingSshKeyPassphraseHint = ""
    var editingSshKeyNotes = ""
    var editingSshKeyFavorite = false
    var apiTokenEntries: [LocalApiTokenEntry] = []
    var deletedApiTokenEntries: [LocalApiTokenEntry] = []
    var apiTokenTitle = ""
    var apiTokenIssuer = ""
    var apiTokenAccountName = ""
    var apiTokenToken = ""
    var apiTokenScopes = ""
    var apiTokenExpiresAt = ""
    var apiTokenNotes = ""
    var apiTokenSearchQuery = ""
    var showFavoriteApiTokenEntriesOnly = false
    var editingApiTokenEntryID: String?
    var editingApiTokenTitle = ""
    var editingApiTokenIssuer = ""
    var editingApiTokenAccountName = ""
    var editingApiTokenToken = ""
    var editingApiTokenScopes = ""
    var editingApiTokenExpiresAt = ""
    var editingApiTokenNotes = ""
    var editingApiTokenFavorite = false
    var wifiEntries: [LocalWifiEntry] = []
    var deletedWifiEntries: [LocalWifiEntry] = []
    var wifiTitle = ""
    var wifiSSID = ""
    var wifiSecurityType = "WPA2"
    var wifiPassword = ""
    var wifiHidden = false
    var wifiNotes = ""
    var wifiSearchQuery = ""
    var showFavoriteWifiEntriesOnly = false
    var editingWifiEntryID: String?
    var editingWifiTitle = ""
    var editingWifiSSID = ""
    var editingWifiSecurityType = "WPA2"
    var editingWifiPassword = ""
    var editingWifiHidden = false
    var editingWifiNotes = ""
    var editingWifiFavorite = false
    var sendEntries: [LocalSendEntry] = []
    var deletedSendEntries: [LocalSendEntry] = []
    var sendTitle = ""
    var sendBody = ""
    var sendExpiresAt = ""
    var sendMaxViews = 1
    var sendNotes = ""
    var sendSearchQuery = ""
    var showFavoriteSendEntriesOnly = false
    var editingSendEntryID: String?
    var editingSendTitle = ""
    var editingSendBody = ""
    var editingSendExpiresAt = ""
    var editingSendMaxViews = 1
    var editingSendNotes = ""
    var editingSendFavorite = false
    var attachmentEntries: [LocalAttachmentMetadata] = []
    var deletedAttachmentEntries: [LocalAttachmentMetadata] = []
    var attachmentSearchQuery = ""
    var attachmentQuickLookPreviewURL: URL?
    var vaultProjects: [LocalVaultProject] = []
    var selectedVaultQuickFilterID = "all"
    var selectedVaultBatchItemIDs: Set<String> = []
    private var vaultBatchSelectionKind: UnifiedVaultItemKind?
    var vaultDisplayPreferences: VaultDisplayPreferences
    var appearancePreferences: AppAppearancePreferences
    var mdbxVerificationState: MDBXVerificationState = .idle
    var isPrivacyShieldVisible = false
    var autoLockPolicy: AppAutoLockPolicy
    var autoFillIndexState: AutoFillIndexState = .idle
    var notificationPermissionState: AppPermissionStatusRow.State = .checkable
    var vaultKeychainState: VaultKeychainState = .idle
    private var plusEntitlementSnapshot = AppPlusEntitlementSnapshot()
    var plusActivationState: PlusActivationState = .idle
    var webDAVBaseURL = ""
    var webDAVUsername = ""
    var webDAVPassword = ""
    var webDAVRemoteFileName = ""
    var webDAVRestoreVaultPassword = ""
    var webDAVBackupState: WebDAVBackupState = .idle
    var webDAVRestorePreview: WebDAVRestorePreview?
    var cloudFileState: CloudFileState = .idle
    var cloudFileItemsByProvider: [CloudFileProviderKind: [CloudFileItem]] = [:]
    var cloudFileRestorePreview: AppCloudFileRestorePreview?
    var oneDriveAuthenticationState: OneDriveAuthenticationState = .disconnected
    var bitwardenServerURL = "https://vault.bitwarden.com"
    var bitwardenEmail = ""
    var bitwardenMasterPassword = ""
    var bitwardenAuthenticationState: BitwardenAuthenticationState = .disconnected
    var bitwardenSyncState: BitwardenSyncState = .idle
    var bitwardenSyncPreview: AppBitwardenSyncPreview?
    var csvImportPreview: CSVImportPreview?
    var androidBackupImportPreview: AndroidBackupImportPreview?
    var keePassImportPreview: KeePassImportPreview?
    var keePassReadOnlySnapshot: KeePassReadOnlySnapshot?
    var keePassReadOnlyImportPlan: KeePassReadOnlyImportPlan?
    var keePassPendingDatabaseData: Data?
    var keePassPendingDatabaseName: String?
    var keePassSourceFileURL: URL?
    var keePassCloudFileSource: AppKeePassCloudFileSource?
    var keePassUnlockPassword = ""
    var keePassKeyFileData: Data?
    var keePassKeyFileName = ""
    var keePassLastMetadataImportReferences: [AppKeePassImportedEntryReference] = []
    var androidBackupDecryptPassword = ""
    var pendingAndroidEncryptedBackupFileName: String?
    var presentedEditorMode: VaultItemEditorMode?
    var expandedToolbarAction: AndroidParityToolbarAction?
    var isFabMenuPresented = false
    var securityQuestion1ID = AppSessionModel.securityQuestionOptions[0].id
    var securityQuestion2ID = AppSessionModel.securityQuestionOptions[1].id
    var securityAnswer1 = ""
    var securityAnswer2 = ""
    var securityQuestionState: VaultOperationState = .idle
    var forgotPasswordRecoveryStep: ForgotPasswordRecoveryStep = .none
    var forgotPasswordQuestion1Text = ""
    var forgotPasswordQuestion2Text = ""
    var forgotPasswordAnswer1 = ""
    var forgotPasswordAnswer2 = ""
    var forgotPasswordAttemptCount = 0
    var forgotPasswordNewPassword = ""
    var forgotPasswordConfirmPassword = ""
    var isBiometricUnlockEnabled: Bool {
        didSet {
            biometricUnlockPreferenceStore.saveIsEnabled(isBiometricUnlockEnabled)
        }
    }
    private var downloadedWebDAVRestoreBackup: WebDAVDownloadedBackup?
    private var downloadedCloudFileRestore: CloudFileDownload?

    private let vaultRepository: LocalVaultRepository
    private let vaultKeychainService: (any AppVaultKeychainService)?
    private let vaultWrappedKeyProvider: ((LocalVaultSession) throws -> WrappedVaultKey)?
    private let rememberedVaultStore: any RememberedVaultStore
    private let biometricUnlockPreferenceStore: any BiometricUnlockPreferenceStore
    private let vaultDisplayPreferenceStore: any VaultDisplayPreferenceStore
    private let appearancePreferenceStore: any AppAppearancePreferenceStore
    private let biometricUnlockAuthorizer: any BiometricUnlockAuthorizer
    private let biometricCapabilityProvider: () -> BiometricUnlockCapability
    private let securityQuestionStore: any SecurityQuestionRecoveryStore
    private let webDAVBackupService: any AppWebDAVBackupService
    private let cloudFileProviders: [CloudFileProviderKind: any CloudFileProvider]
    private let oneDriveAuthenticationService: (any AppOneDriveAuthenticationService)?
    private let bitwardenPasswordAuthenticationService: (any AppBitwardenPasswordAuthenticationService)?
    private let bitwardenSyncProvider: (any BitwardenSyncProvider)?
    private let bitwardenAuthenticationSessionStore: any BitwardenAuthenticationSessionStore
    private let bitwardenVaultKeyStore: (any BitwardenVaultKeyStore)?
    private let bitwardenSendSyncStateStore: any AppBitwardenSendSyncStateStore
    private let bitwardenFolderSyncStateStore: any AppBitwardenFolderSyncStateStore
    private let bitwardenItemSyncStateStore: any AppBitwardenItemSyncStateStore
    private let bitwardenPendingMutationQueueStore: any AppBitwardenPendingMutationQueueStore
    private let autoFillIndexStore: (any AutoFillEncryptedIndexStore)?
    private let autoFillCredentialSecretStore: (any AutoFillCredentialSecretStore)?
    private let autoFillCredentialIdentityStore: (any AppAutoFillCredentialIdentityStore)?
    private let autoFillIndexKeyMaterialProvider: ((String) throws -> AutoFillIndexKeyMaterial)?
    private let autoFillIndexCodec: AutoFillEncryptedIndexCodec
    private let autoFillCredentialSecretCodec: AutoFillCredentialSecretCodec
    private let plusResourceUnlockService: (any AppPlusResourceUnlockService)?
    private let plusEntitlementStore: any AppPlusEntitlementStore
    private let androidBackupAttachmentBlobStore: any AndroidBackupAttachmentBlobStore
    private let keePassDatabaseReader: any KeePassDatabaseReader
    private let keePassKdbxFileWritebackService: any AppKeePassKdbxFileWritebackService
    private let keePassKdbx3WritebackCoordinator: any KeePassKdbx3WritebackCoordinator
    private let keePassKdbx4WritebackCoordinator: any KeePassKdbx4WritebackCoordinator
    private let widgetSnapshotStore: AppWidgetSnapshotFileStore?
    private let shortcutSnapshotStore: AppShortcutSnapshotFileStore?
    private let attachmentContentEncryptionKeyProvider: ((LocalAttachmentMetadata) throws -> Data)?
    private let androidAttachmentWrappingKeyProvider: ((LocalAttachmentMetadata) throws -> AndroidAttachmentContentWrappingKey)?
    private let passwordGenerator: () throws -> String
    private var activeVaultSession: LocalVaultSession?
    private var activeEntryRepository: LocalVaultEntryRepository?
    private var activeProject: LocalVaultProject?
    private var rememberedVaultDescriptor: LocalVaultDescriptor?
    private var rememberedVaultID: String?
    private var lastUserActivityAt: Date?
    private var pendingAndroidEncryptedBackupData: Data?
    private var keePassLastSuccessfulUnlockCredentials: KeePassUnlockCredentials?

    init(
        vaultRepository: LocalVaultRepository = LocalVaultRepository(),
        vaultKeychainService: (any AppVaultKeychainService)? = nil,
        vaultWrappedKeyProvider: ((LocalVaultSession) throws -> WrappedVaultKey)? = nil,
        rememberedVaultStore: any RememberedVaultStore = MemoryRememberedVaultStore(),
        biometricUnlockPreferenceStore: any BiometricUnlockPreferenceStore = MemoryBiometricUnlockPreferenceStore(),
        vaultDisplayPreferenceStore: any VaultDisplayPreferenceStore = MemoryVaultDisplayPreferenceStore(),
        appearancePreferenceStore: any AppAppearancePreferenceStore = MemoryAppAppearancePreferenceStore(),
        biometricUnlockAuthorizer: any BiometricUnlockAuthorizer = DeviceBiometricUnlockAuthorizer(),
        biometricCapabilityProvider: @escaping () -> BiometricUnlockCapability = { .unavailable },
        securityQuestionStore: any SecurityQuestionRecoveryStore = UserDefaultsSecurityQuestionRecoveryStore(),
        webDAVBackupService: any AppWebDAVBackupService = URLSessionAppWebDAVBackupService(),
        cloudFileProviders: [CloudFileProviderKind: any CloudFileProvider] = [:],
        oneDriveAuthenticationService: (any AppOneDriveAuthenticationService)? = nil,
        bitwardenPasswordAuthenticationService: (any AppBitwardenPasswordAuthenticationService)? = nil,
        bitwardenSyncProvider: (any BitwardenSyncProvider)? = nil,
        bitwardenAuthenticationSessionStore: any BitwardenAuthenticationSessionStore = MemoryBitwardenAuthenticationSessionStore(),
        bitwardenVaultKeyStore: (any BitwardenVaultKeyStore)? = nil,
        bitwardenSendSyncStateStore: any AppBitwardenSendSyncStateStore = MemoryAppBitwardenSendSyncStateStore(),
        bitwardenFolderSyncStateStore: any AppBitwardenFolderSyncStateStore = MemoryAppBitwardenFolderSyncStateStore(),
        bitwardenItemSyncStateStore: any AppBitwardenItemSyncStateStore = MemoryAppBitwardenItemSyncStateStore(),
        bitwardenPendingMutationQueueStore: any AppBitwardenPendingMutationQueueStore = MemoryAppBitwardenPendingMutationQueueStore(),
        autoFillIndexStore: (any AutoFillEncryptedIndexStore)? = nil,
        autoFillCredentialSecretStore: (any AutoFillCredentialSecretStore)? = nil,
        autoFillCredentialIdentityStore: (any AppAutoFillCredentialIdentityStore)? = nil,
        autoFillIndexKeyMaterialProvider: ((String) throws -> AutoFillIndexKeyMaterial)? = nil,
        autoFillIndexCodec: AutoFillEncryptedIndexCodec = AutoFillEncryptedIndexCodec(),
        autoFillCredentialSecretCodec: AutoFillCredentialSecretCodec = AutoFillCredentialSecretCodec(),
        plusResourceUnlockService: (any AppPlusResourceUnlockService)? = nil,
        plusEntitlementStore: any AppPlusEntitlementStore = MemoryAppPlusEntitlementStore(),
        androidBackupAttachmentBlobStore: any AndroidBackupAttachmentBlobStore = FileAndroidBackupAttachmentBlobStore(),
        keePassDatabaseReader: any KeePassDatabaseReader = DefaultKeePassDatabaseReader(),
        keePassKdbxFileWritebackService: any AppKeePassKdbxFileWritebackService = FileSystemAppKeePassKdbxFileWritebackService(),
        keePassKdbx3WritebackCoordinator: any KeePassKdbx3WritebackCoordinator = DefaultKeePassKdbx3WritebackCoordinator(),
        keePassKdbx4WritebackCoordinator: any KeePassKdbx4WritebackCoordinator = DefaultKeePassKdbx4WritebackCoordinator(),
        widgetSnapshotStore: AppWidgetSnapshotFileStore? = nil,
        shortcutSnapshotStore: AppShortcutSnapshotFileStore? = nil,
        attachmentContentEncryptionKeyProvider: ((LocalAttachmentMetadata) throws -> Data)? = nil,
        androidAttachmentWrappingKeyProvider: ((LocalAttachmentMetadata) throws -> AndroidAttachmentContentWrappingKey)? = nil,
        notificationPermissionStatusProvider: @escaping () -> AppPermissionStatusRow.State = { .checkable },
        passwordGenerator: @escaping () throws -> String = {
            try PasswordGenerator.generate()
        },
        autoLockPolicy: AppAutoLockPolicy = .default
    ) {
        self.vaultRepository = vaultRepository
        self.vaultKeychainService = vaultKeychainService
        self.vaultWrappedKeyProvider = vaultWrappedKeyProvider
        self.rememberedVaultStore = rememberedVaultStore
        self.biometricUnlockPreferenceStore = biometricUnlockPreferenceStore
        self.vaultDisplayPreferenceStore = vaultDisplayPreferenceStore
        self.appearancePreferenceStore = appearancePreferenceStore
        self.biometricUnlockAuthorizer = biometricUnlockAuthorizer
        self.biometricCapabilityProvider = biometricCapabilityProvider
        self.securityQuestionStore = securityQuestionStore
        self.webDAVBackupService = webDAVBackupService
        self.cloudFileProviders = cloudFileProviders
        self.oneDriveAuthenticationService = oneDriveAuthenticationService
        self.bitwardenPasswordAuthenticationService = bitwardenPasswordAuthenticationService
        self.bitwardenSyncProvider = bitwardenSyncProvider
        self.bitwardenAuthenticationSessionStore = bitwardenAuthenticationSessionStore
        self.bitwardenVaultKeyStore = bitwardenVaultKeyStore
        self.bitwardenSendSyncStateStore = bitwardenSendSyncStateStore
        self.bitwardenFolderSyncStateStore = bitwardenFolderSyncStateStore
        self.bitwardenItemSyncStateStore = bitwardenItemSyncStateStore
        self.bitwardenPendingMutationQueueStore = bitwardenPendingMutationQueueStore
        self.autoFillIndexStore = autoFillIndexStore
        self.autoFillCredentialSecretStore = autoFillCredentialSecretStore
        self.autoFillCredentialIdentityStore = autoFillCredentialIdentityStore
        self.autoFillIndexKeyMaterialProvider = autoFillIndexKeyMaterialProvider
        self.autoFillIndexCodec = autoFillIndexCodec
        self.autoFillCredentialSecretCodec = autoFillCredentialSecretCodec
        self.plusResourceUnlockService = plusResourceUnlockService
        self.plusEntitlementStore = plusEntitlementStore
        self.androidBackupAttachmentBlobStore = androidBackupAttachmentBlobStore
        self.keePassDatabaseReader = keePassDatabaseReader
        self.keePassKdbxFileWritebackService = keePassKdbxFileWritebackService
        self.keePassKdbx3WritebackCoordinator = keePassKdbx3WritebackCoordinator
        self.keePassKdbx4WritebackCoordinator = keePassKdbx4WritebackCoordinator
        self.widgetSnapshotStore = widgetSnapshotStore
        self.shortcutSnapshotStore = shortcutSnapshotStore
        self.attachmentContentEncryptionKeyProvider = attachmentContentEncryptionKeyProvider
        self.androidAttachmentWrappingKeyProvider = androidAttachmentWrappingKeyProvider
        self.passwordGenerator = passwordGenerator
        self.autoLockPolicy = autoLockPolicy
        self.notificationPermissionState = notificationPermissionStatusProvider()
        self.isBiometricUnlockEnabled = biometricUnlockPreferenceStore.loadIsEnabled()
        self.vaultDisplayPreferences = vaultDisplayPreferenceStore.loadPreferences()
        self.appearancePreferences = appearancePreferenceStore.loadPreferences()
        if plusEntitlementStore.loadIsResourceUnlocked() {
            self.plusEntitlementSnapshot = AppPlusEntitlementSnapshot(source: .resourceUnlock, expiresAt: nil)
        }
        if let remembered = try? rememberedVaultStore.load() {
            self.rememberedVaultDescriptor = LocalVaultDescriptor(
                fileURL: remembered.fileURL,
                displayName: remembered.displayName
            )
            self.rememberedVaultID = remembered.vaultID
        }
    }

    var filteredLoginEntries: [LocalLoginEntry] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = loginSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return filteredFavoriteEntries(
            loginEntries,
            query: query,
            favoritesOnly: showFavoriteLoginEntriesOnly,
            isFavorite: { $0.favorite }
        ) { entry, query in
            entry.title.localizedCaseInsensitiveContains(query)
                || entry.username.localizedCaseInsensitiveContains(query)
                || entry.url.localizedCaseInsensitiveContains(query)
        }
    }

    var loginStackedGroups: [AppLoginStackedGroup] {
        let grouped = Dictionary(grouping: filteredLoginEntries) { entry in
            loginStackedGroupKey(for: entry)
        }
        return grouped.map { key, entries in
            let titles = entries
                .map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let usernames = entries
                .map { $0.username.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return AppLoginStackedGroup(
                id: "login-stack-\(key.normalized)",
                title: key.title,
                value: itemCountLabel(entries.count),
                detail: usernames.prefix(3).joined(separator: " / "),
                preview: titles.prefix(3).joined(separator: " / "),
                systemImage: key.isWebsite ? "globe" : "textformat",
                entryIDs: entries.map(\.id)
            )
        }
        .sorted { lhs, rhs in
            if lhs.entryIDs.count != rhs.entryIDs.count {
                return lhs.entryIDs.count > rhs.entryIDs.count
            }
            if lhs.systemImage != rhs.systemImage {
                return lhs.systemImage == "globe"
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    var filteredNoteEntries: [LocalNoteEntry] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = noteSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return filteredFavoriteEntries(
            noteEntries,
            query: query,
            favoritesOnly: showFavoriteNoteEntriesOnly,
            isFavorite: { $0.favorite }
        ) { entry, query in
            entry.title.localizedCaseInsensitiveContains(query)
                || entry.body.localizedCaseInsensitiveContains(query)
        }
    }

    var filteredTotpEntries: [LocalTotpEntry] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = totpSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return filteredFavoriteEntries(
            totpEntries,
            query: query,
            favoritesOnly: showFavoriteTotpEntriesOnly,
            isFavorite: { $0.favorite }
        ) { entry, query in
            entry.title.localizedCaseInsensitiveContains(query)
                || entry.issuer.localizedCaseInsensitiveContains(query)
                || entry.accountName.localizedCaseInsensitiveContains(query)
        }
    }

    var filteredCardEntries: [LocalCardEntry] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = cardSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return filteredFavoriteEntries(
            cardEntries,
            query: query,
            favoritesOnly: showFavoriteCardEntriesOnly,
            isFavorite: { $0.favorite }
        ) { entry, query in
            entry.title.localizedCaseInsensitiveContains(query)
                || entry.cardholderName.localizedCaseInsensitiveContains(query)
                || entry.issuer.localizedCaseInsensitiveContains(query)
                || entry.network.localizedCaseInsensitiveContains(query)
                || entry.notes.localizedCaseInsensitiveContains(query)
        }
    }

    var filteredIdentityEntries: [LocalIdentityEntry] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = identitySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return filteredFavoriteEntries(
            identityEntries,
            query: query,
            favoritesOnly: showFavoriteIdentityEntriesOnly,
            isFavorite: { $0.favorite }
        ) { entry, query in
            entry.title.localizedCaseInsensitiveContains(query)
                || entry.documentType.localizedCaseInsensitiveContains(query)
                || entry.fullName.localizedCaseInsensitiveContains(query)
                || entry.documentNumber.localizedCaseInsensitiveContains(query)
                || entry.issuer.localizedCaseInsensitiveContains(query)
                || entry.country.localizedCaseInsensitiveContains(query)
                || entry.notes.localizedCaseInsensitiveContains(query)
        }
    }

    var filteredPasskeyEntries: [LocalPasskeyEntry] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = passkeySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return filteredFavoriteEntries(
            passkeyEntries,
            query: query,
            favoritesOnly: showFavoritePasskeyEntriesOnly,
            isFavorite: { $0.favorite }
        ) { entry, query in
            entry.title.localizedCaseInsensitiveContains(query)
                || entry.relyingPartyID.localizedCaseInsensitiveContains(query)
                || entry.username.localizedCaseInsensitiveContains(query)
                || entry.notes.localizedCaseInsensitiveContains(query)
            }
    }

    var filteredSshKeyEntries: [LocalSshKeyEntry] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = sshKeySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return filteredFavoriteEntries(
            sshKeyEntries,
            query: query,
            favoritesOnly: showFavoriteSshKeyEntriesOnly,
            isFavorite: { $0.favorite }
        ) { entry, query in
            entry.title.localizedCaseInsensitiveContains(query)
                || entry.username.localizedCaseInsensitiveContains(query)
                || entry.host.localizedCaseInsensitiveContains(query)
                || entry.publicKey.localizedCaseInsensitiveContains(query)
                || entry.notes.localizedCaseInsensitiveContains(query)
        }
    }

    var filteredApiTokenEntries: [LocalApiTokenEntry] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = apiTokenSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return filteredFavoriteEntries(
            apiTokenEntries,
            query: query,
            favoritesOnly: showFavoriteApiTokenEntriesOnly,
            isFavorite: { $0.favorite }
        ) { entry, query in
            entry.title.localizedCaseInsensitiveContains(query)
                || entry.issuer.localizedCaseInsensitiveContains(query)
                || entry.accountName.localizedCaseInsensitiveContains(query)
                || entry.scopes.localizedCaseInsensitiveContains(query)
                || entry.notes.localizedCaseInsensitiveContains(query)
        }
    }

    var filteredWifiEntries: [LocalWifiEntry] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = wifiSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return filteredFavoriteEntries(
            wifiEntries,
            query: query,
            favoritesOnly: showFavoriteWifiEntriesOnly,
            isFavorite: { $0.favorite }
        ) { entry, query in
            entry.title.localizedCaseInsensitiveContains(query)
                || entry.ssid.localizedCaseInsensitiveContains(query)
                || entry.securityType.localizedCaseInsensitiveContains(query)
                || entry.notes.localizedCaseInsensitiveContains(query)
        }
    }

    var editingWifiQRCodePayload: String {
        guard let entryID = editingWifiEntryID else {
            return ""
        }
        return LocalWifiEntry(
            id: entryID,
            projectID: activeProject?.id ?? "",
            title: editingWifiTitle,
            ssid: editingWifiSSID,
            securityType: editingWifiSecurityType,
            password: editingWifiPassword,
            hidden: editingWifiHidden,
            notes: editingWifiNotes,
            favorite: editingWifiFavorite
        ).qrCodePayload
    }

    var filteredSendEntries: [LocalSendEntry] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = sendSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return filteredFavoriteEntries(
            sendEntries,
            query: query,
            favoritesOnly: showFavoriteSendEntriesOnly,
            isFavorite: { $0.favorite }
        ) { entry, query in
            entry.title.localizedCaseInsensitiveContains(query)
                || entry.body.localizedCaseInsensitiveContains(query)
                || entry.expiresAt.localizedCaseInsensitiveContains(query)
                || entry.notes.localizedCaseInsensitiveContains(query)
        }
    }

    var filteredAttachmentEntries: [LocalAttachmentMetadata] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = attachmentSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return attachmentEntries
        }
        return attachmentEntries.filter { entry in
            entry.fileName.localizedCaseInsensitiveContains(query)
                || entry.mediaType.localizedCaseInsensitiveContains(query)
                || entry.storageMode.localizedCaseInsensitiveContains(query)
                || entry.downloadState.localizedCaseInsensitiveContains(query)
                || entry.source.localizedCaseInsensitiveContains(query)
                || entry.contentHash.localizedCaseInsensitiveContains(query)
                || (entry.entryID?.localizedCaseInsensitiveContains(query) ?? false)
                || (entry.localPath?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    func shortcutEntrySummaries(matching query: String) -> [AppShortcutEntrySummary] {
        guard vaultState == .unlocked else {
            return []
        }

        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return allShortcutEntrySummaries().filter { summary in
            guard !normalizedQuery.isEmpty else {
                return true
            }
            return summary.title.localizedCaseInsensitiveContains(normalizedQuery)
                || summary.subtitle.localizedCaseInsensitiveContains(normalizedQuery)
                || summary.searchableText.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    func shortcutSnapshot() -> AppShortcutSnapshot {
        guard vaultState == .unlocked else {
            return .locked
        }
        return AppShortcutSnapshot(
            vaultState: .unlocked,
            entries: allShortcutEntrySummaries().map(AppShortcutSnapshotEntry.init(summary:))
        )
    }

    func refreshShortcutSnapshotIfConfigured() throws {
        guard let shortcutSnapshotStore else {
            return
        }
        try shortcutSnapshotStore.saveSnapshot(shortcutSnapshot())
    }

    func widgetSnapshot(now: Date = Date()) -> AppWidgetSnapshot {
        guard vaultState == .unlocked else {
            return AppWidgetSnapshot(
                vaultState: .locked,
                totalEntryCount: 0,
                totpItems: [],
                shortcutItems: []
            )
        }

        let totpItems = totpEntries.prefix(3).map { entry in
            AppWidgetTotpItem(
                id: entry.id,
                title: shortcutTitle(entry.title),
                issuer: entry.issuer,
                accountName: entry.accountName,
                secondsRemaining: totpTimeRemaining(for: entry, at: now)
            )
        }
        return AppWidgetSnapshot(
            vaultState: .unlocked,
            totalEntryCount: activeVaultEntryCount,
            totpItems: Array(totpItems),
            shortcutItems: Array(allShortcutEntrySummaries().prefix(4))
        )
    }

    func refreshWidgetSnapshotIfConfigured(now: Date = Date()) throws {
        guard let widgetSnapshotStore else {
            return
        }
        try widgetSnapshotStore.saveSnapshot(widgetSnapshot(now: now))
    }

    func openShortcutEntry(_ summary: AppShortcutEntrySummary) throws {
        recordUserActivity()
        selectedTab = tab(forShortcutEntryKind: summary.kind)
        switch summary.kind {
        case .login:
            guard let entry = loginEntries.first(where: { $0.id == summary.id }) else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            presentEditEditor(for: entry)
        case .note:
            guard let entry = noteEntries.first(where: { $0.id == summary.id }) else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            presentEditEditor(for: entry)
        case .totp:
            guard let entry = totpEntries.first(where: { $0.id == summary.id }) else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            presentEditEditor(for: entry)
        case .card:
            guard let entry = cardEntries.first(where: { $0.id == summary.id }) else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            presentEditEditor(for: entry)
        case .identity:
            guard let entry = identityEntries.first(where: { $0.id == summary.id }) else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            presentEditEditor(for: entry)
        case .passkey:
            guard let entry = passkeyEntries.first(where: { $0.id == summary.id }) else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            presentEditEditor(for: entry)
        case .sshKey:
            guard let entry = sshKeyEntries.first(where: { $0.id == summary.id }) else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            presentEditEditor(for: entry)
        case .apiToken:
            guard let entry = apiTokenEntries.first(where: { $0.id == summary.id }) else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            presentEditEditor(for: entry)
        case .wifi:
            guard let entry = wifiEntries.first(where: { $0.id == summary.id }) else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            presentEditEditor(for: entry)
        case .send:
            guard let entry = sendEntries.first(where: { $0.id == summary.id }) else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            presentEditEditor(for: entry)
        case .attachmentRef:
            throw LocalVaultRepositoryError.unsupportedEntryType(.attachmentRef)
        }
    }

    @discardableResult
    func openShortcutURL(_ url: URL) -> Bool {
        guard url.scheme == "monica",
              url.host() == "shortcut" else {
            return false
        }
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard pathComponents.count == 2,
              let kind = UnifiedVaultItemKind(rawValue: pathComponents[0]) else {
            return false
        }
        let entryID = pathComponents[1]
        do {
            try openShortcutEntry(
                AppShortcutEntrySummary(
                    id: entryID,
                    kind: kind,
                    title: "",
                    subtitle: "",
                    searchableText: ""
                )
            )
            return true
        } catch {
            vaultOperationState = .failed("快捷入口已失效，请重新选择条目。")
            return false
        }
    }

    private func allShortcutEntrySummaries() -> [AppShortcutEntrySummary] {
        var summaries: [AppShortcutEntrySummary] = []
        summaries += loginEntries.map(shortcutSummary(for:))
        summaries += noteEntries.map(shortcutSummary(for:))
        summaries += totpEntries.map(shortcutSummary(for:))
        summaries += cardEntries.map(shortcutSummary(for:))
        summaries += identityEntries.map(shortcutSummary(for:))
        summaries += passkeyEntries.map(shortcutSummary(for:))
        summaries += sshKeyEntries.map(shortcutSummary(for:))
        summaries += apiTokenEntries.map(shortcutSummary(for:))
        summaries += wifiEntries.map(shortcutSummary(for:))
        summaries += sendEntries.map(shortcutSummary(for:))
        return summaries
    }

    private func shortcutSummary(for entry: LocalLoginEntry) -> AppShortcutEntrySummary {
        let host = normalizedLoginHost(from: entry.url)
        let subtitle = shortcutSubtitle([entry.username, host])
        return AppShortcutEntrySummary(
            id: entry.id,
            kind: .login,
            title: shortcutTitle(entry.title),
            subtitle: subtitle,
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.login.displayName, entry.title, entry.username, host])
        )
    }

    private func shortcutSummary(for entry: LocalNoteEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .note,
            title: shortcutTitle(entry.title),
            subtitle: UnifiedVaultItemKind.note.displayName,
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.note.displayName, entry.title])
        )
    }

    private func shortcutSummary(for entry: LocalTotpEntry) -> AppShortcutEntrySummary {
        let subtitle = shortcutSubtitle([entry.accountName, entry.issuer])
        return AppShortcutEntrySummary(
            id: entry.id,
            kind: .totp,
            title: shortcutTitle(entry.title),
            subtitle: subtitle,
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.totp.displayName, entry.title, entry.issuer, entry.accountName])
        )
    }

    private func shortcutSummary(for entry: LocalCardEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .card,
            title: shortcutTitle(entry.title),
            subtitle: shortcutSubtitle([entry.cardholderName, entry.issuer, entry.network]),
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.card.displayName, entry.title, entry.cardholderName, entry.issuer, entry.network])
        )
    }

    private func shortcutSummary(for entry: LocalIdentityEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .identity,
            title: shortcutTitle(entry.title),
            subtitle: shortcutSubtitle([entry.fullName, entry.documentType, entry.issuer, entry.country]),
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.identity.displayName, entry.title, entry.fullName, entry.documentType, entry.issuer, entry.country])
        )
    }

    private func shortcutSummary(for entry: LocalPasskeyEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .passkey,
            title: shortcutTitle(entry.title),
            subtitle: shortcutSubtitle([entry.username, entry.relyingPartyID]),
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.passkey.displayName, entry.title, entry.username, entry.relyingPartyID])
        )
    }

    private func shortcutSummary(for entry: LocalSshKeyEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .sshKey,
            title: shortcutTitle(entry.title),
            subtitle: shortcutSubtitle([entry.username, entry.host]),
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.sshKey.displayName, entry.title, entry.username, entry.host])
        )
    }

    private func shortcutSummary(for entry: LocalApiTokenEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .apiToken,
            title: shortcutTitle(entry.title),
            subtitle: shortcutSubtitle([entry.accountName, entry.issuer, entry.expiresAt]),
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.apiToken.displayName, entry.title, entry.accountName, entry.issuer, entry.expiresAt])
        )
    }

    private func shortcutSummary(for entry: LocalWifiEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .wifi,
            title: shortcutTitle(entry.title),
            subtitle: shortcutSubtitle([entry.ssid, entry.securityType]),
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.wifi.displayName, entry.title, entry.ssid, entry.securityType])
        )
    }

    private func shortcutSummary(for entry: LocalSendEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .send,
            title: shortcutTitle(entry.title),
            subtitle: shortcutSubtitle([entry.expiresAt, "最多查看 \(entry.maxViews) 次"]),
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.send.displayName, entry.title, entry.expiresAt])
        )
    }

    private func shortcutTitle(_ value: String) -> String {
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "未命名" : title
    }

    private func shortcutSubtitle(_ values: [String?]) -> String {
        let parts = values.compactMap { value -> String? in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        return parts.isEmpty ? "可打开" : parts.joined(separator: " / ")
    }

    private func shortcutSearchableText(_ values: [String?]) -> String {
        values.compactMap { value -> String? in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        .joined(separator: " ")
    }

    private func tab(forShortcutEntryKind kind: UnifiedVaultItemKind) -> MonicaAppTab {
        switch kind {
        case .login, .sshKey, .apiToken, .wifi, .send, .attachmentRef:
            return .passwords
        case .note:
            return .notes
        case .totp:
            return .totp
        case .card, .identity:
            return .wallet
        case .passkey:
            return .passkeys
        }
    }

    func attachmentContentStatus(for entry: LocalAttachmentMetadata) -> AppAttachmentContentStatus {
        guard let vaultID = activeVaultSession?.handle.vaultID else {
            return AppAttachmentContentStatus(
                state: .unavailable,
                value: "未解锁",
                detail: "请先解锁保险库，再检查附件内容。"
            )
        }
        guard entry.downloadState == "downloaded",
              let localPath = entry.localPath,
              !localPath.isEmpty else {
            return AppAttachmentContentStatus(
                state: .missing,
                value: "待恢复",
                detail: "附件密文尚未保存在本机。"
            )
        }
        guard androidBackupAttachmentBlobStore.encryptedBlobExists(vaultID: vaultID, localPath: localPath) else {
            return AppAttachmentContentStatus(
                state: .missing,
                value: "待恢复",
                detail: "附件密文尚未保存在本机。"
            )
        }
        return AppAttachmentContentStatus(
            state: .available,
            value: "\(entry.storedSize) 字节",
            detail: entry.storageMode == "keepass-kdbx-decoded-content"
                ? "KeePass 附件内容已保存在本机，可预览。"
                : "附件密文已保存在本机，可进入预览恢复流程。"
        )
    }

    func loadAttachmentEncryptedBlob(_ entry: LocalAttachmentMetadata) throws -> Data {
        recordUserActivity()
        do {
            let vaultSession = try requireActiveVaultSession()
            guard let localPath = entry.localPath, !localPath.isEmpty else {
                throw LocalAttachmentContentStoreError.missingLocalPath
            }
            let blob = try androidBackupAttachmentBlobStore.encryptedBlobData(
                vaultID: vaultSession.handle.vaultID,
                localPath: localPath
            )
            entryOperationState = .succeeded("附件密文已读取：\(entry.fileName) \(blob.count) 字节")
            return blob
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    private func resolveAttachmentContentEncryptionKey(_ entry: LocalAttachmentMetadata) throws -> Data {
        if let attachmentContentEncryptionKeyProvider {
            return try attachmentContentEncryptionKeyProvider(entry)
        }
        guard let wrappedContentEncryptionKey = entry.wrappedContentEncryptionKey,
              !wrappedContentEncryptionKey.isEmpty,
              let androidAttachmentWrappingKeyProvider
        else {
            throw AppAttachmentPreviewError.contentEncryptionKeyUnavailable
        }
        return try AndroidWrappedAttachmentContentKeyUnwrapper.unwrap(
            wrappedContentEncryptionKey,
            using: try androidAttachmentWrappingKeyProvider(entry)
        )
    }

    func replaceAttachmentContent(
        _ entry: LocalAttachmentMetadata,
        plaintext: Data,
        mediaType: String? = nil
    ) throws -> LocalAttachmentMetadata {
        recordUserActivity()
        entryOperationState = .running

        do {
            let vaultSession = try requireActiveVaultSession()
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let contentEncryptionKey = try resolveAttachmentContentEncryptionKey(entry)
            guard contentEncryptionKey.count == LocalAttachmentContentDecryptor.androidContentEncryptionKeyByteCount else {
                throw LocalAttachmentContentCryptoError.invalidContentEncryptionKeyLength
            }

            let sealedBox = try AES.GCM.seal(
                plaintext,
                using: SymmetricKey(data: contentEncryptionKey)
            )
            guard let encryptedBlob = sealedBox.combined else {
                throw AppAttachmentPreviewError.contentWriteFailed
            }
            let requestedLocalPath = entry.localPath?.isEmpty == false ? entry.localPath! : "\(entry.id).enc"
            let localPath = try androidBackupAttachmentBlobStore.saveEncryptedBlob(
                encryptedBlob,
                vaultID: vaultSession.handle.vaultID,
                localPath: requestedLocalPath
            )
            let contentHash = Data(SHA256.hash(data: plaintext))
                .map { String(format: "%02x", $0) }
                .joined()
            let updated = try entryRepository.updateAttachmentMetadata(
                projectID: projectID,
                attachmentID: entry.id,
                entryID: entry.entryID,
                fileName: entry.fileName,
                mediaType: mediaType ?? entry.mediaType,
                originalSize: Int64(plaintext.count),
                storedSize: Int64(encryptedBlob.count),
                contentHash: "sha256:\(contentHash)",
                storageMode: "ios-edited-encrypted-blob",
                source: entry.source.isEmpty ? "ios-local-edit" : entry.source,
                downloadState: "downloaded",
                wrappedContentEncryptionKey: entry.wrappedContentEncryptionKey,
                localPath: localPath
            )
            attachmentEntries = try entryRepository.listAttachmentMetadata(projectID: projectID)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .attachmentRef,
                itemID: updated.id,
                itemTitle: sanitizedAttachmentPreviewFileName(updated.fileName)
            )
            entryOperationState = .succeeded("附件内容已替换：\(sanitizedAttachmentPreviewFileName(updated.fileName)) \(plaintext.count) 字节")
            return updated
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func materializeAttachmentPreview(
        _ entry: LocalAttachmentMetadata,
        contentEncryptionKey: Data
    ) throws -> AppAttachmentPreviewFile {
        recordUserActivity()
        do {
            let encryptedBlob = try loadAttachmentEncryptedBlob(entry)
            let plaintext = try LocalAttachmentContentDecryptor.decryptAndroidLocalBlob(
                encryptedBlob,
                contentEncryptionKey: contentEncryptionKey
            )
            let displayFileName = sanitizedAttachmentPreviewFileName(entry.fileName)
            let directoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MonicaAttachmentPreviews", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let fileURL = directoryURL.appendingPathComponent(displayFileName, isDirectory: false)
            try plaintext.write(to: fileURL, options: [.atomic])
            let preview = AppAttachmentPreviewFile(
                fileURL: fileURL,
                displayFileName: displayFileName,
                byteCount: plaintext.count
            )
            entryOperationState = .succeeded("附件预览已准备：\(displayFileName) \(plaintext.count) 字节")
            return preview
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func materializeStoredAttachmentContentPreview(
        _ entry: LocalAttachmentMetadata
    ) throws -> AppAttachmentPreviewFile {
        recordUserActivity()
        do {
            let content = try loadAttachmentEncryptedBlob(entry)
            let displayFileName = sanitizedAttachmentPreviewFileName(entry.fileName)
            let directoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MonicaAttachmentPreviews", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let fileURL = directoryURL.appendingPathComponent(displayFileName, isDirectory: false)
            try content.write(to: fileURL, options: [.atomic])
            let preview = AppAttachmentPreviewFile(
                fileURL: fileURL,
                displayFileName: displayFileName,
                byteCount: content.count
            )
            entryOperationState = .succeeded("附件预览已准备：\(displayFileName) \(content.count) 字节")
            return preview
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func presentAttachmentQuickLookPreview(_ entry: LocalAttachmentMetadata) throws {
        recordUserActivity()
        dismissAttachmentQuickLookPreview()

        if entry.storageMode == "keepass-kdbx-decoded-content" {
            do {
                let preview = try materializeStoredAttachmentContentPreview(entry)
                attachmentQuickLookPreviewURL = preview.fileURL
                appendOperationTimelineEvent(
                    action: .viewed,
                    itemKind: .attachmentRef,
                    itemID: entry.id,
                    itemTitle: preview.displayFileName
                )
                entryOperationState = .succeeded("附件预览已准备：\(preview.displayFileName) \(preview.byteCount) 字节")
                return
            } catch let error as LocalAttachmentContentStoreError {
                entryOperationState = .failed(error.localizedDescription)
                throw error
            } catch {
                let previewError = AppAttachmentPreviewError.previewFailed
                entryOperationState = .failed(previewError.localizedDescription)
                throw previewError
            }
        }

        let contentEncryptionKey: Data
        do {
            contentEncryptionKey = try resolveAttachmentContentEncryptionKey(entry)
        } catch {
            let previewError = AppAttachmentPreviewError.contentEncryptionKeyUnavailable
            entryOperationState = .failed(previewError.localizedDescription)
            throw previewError
        }

        do {
            let preview = try materializeAttachmentPreview(
                entry,
                contentEncryptionKey: contentEncryptionKey
            )
            attachmentQuickLookPreviewURL = preview.fileURL
            appendOperationTimelineEvent(
                action: .viewed,
                itemKind: .attachmentRef,
                itemID: entry.id,
                itemTitle: preview.displayFileName
            )
            entryOperationState = .succeeded("附件预览已准备：\(preview.displayFileName) \(preview.byteCount) 字节")
        } catch let error as LocalAttachmentContentStoreError {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        } catch let error as LocalAttachmentContentCryptoError {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        } catch let error as AppWebDAVBackupError {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        } catch {
            let previewError = AppAttachmentPreviewError.previewFailed
            entryOperationState = .failed(previewError.localizedDescription)
            throw previewError
        }
    }

    func dismissAttachmentQuickLookPreview() {
        guard let previewURL = attachmentQuickLookPreviewURL else {
            return
        }
        attachmentQuickLookPreviewURL = nil
        try? FileManager.default.removeItem(at: previewURL.deletingLastPathComponent())
    }

    var vaultQuickFilterRows: [AppVaultQuickFilterRow] {
        let category = activeProject
        let activeCount = activeVaultEntryCount
        let deletedCount = deletedVaultEntryCount
        var rows = [
            AppVaultQuickFilterRow(
                id: "all",
                title: "全部",
                value: itemCountLabel(activeCount),
                detail: "显示当前分类里的全部活动条目。",
                systemImage: "tray.full",
                isSelected: selectedVaultQuickFilterID == "all"
            )
        ]
        if let category {
            rows.append(
                AppVaultQuickFilterRow(
                    id: "category-\(category.id)",
                    title: category.title,
                    value: itemCountLabel(activeCount),
                    detail: "当前分类。",
                    systemImage: "folder",
                    isSelected: selectedVaultQuickFilterID == "category-\(category.id)"
                )
            )
        }
        rows.append(
            AppVaultQuickFilterRow(
                id: "favorites",
                title: "收藏",
                value: itemCountLabel(favoriteVaultEntryCount),
                detail: "只显示已收藏条目。",
                systemImage: "star",
                isSelected: selectedVaultQuickFilterID == "favorites"
            )
        )
        rows.append(
            AppVaultQuickFilterRow(
                id: "trash",
                title: "回收站",
                value: itemCountLabel(deletedCount),
                detail: "显示当前分类的已删除条目。",
                systemImage: "trash",
                isSelected: selectedVaultQuickFilterID == "trash"
            )
        )
        return rows
    }

    var activeVaultCategoryTitle: String {
        activeProject?.title ?? "未选择分类"
    }

    var activeVaultProjectID: String? {
        activeProject?.id
    }

    var isTrashQuickFilterSelected: Bool {
        selectedVaultQuickFilterID == "trash"
    }

    func applyVaultQuickFilter(_ filterID: String) {
        guard vaultQuickFilterRows.contains(where: { $0.id == filterID }) else {
            return
        }
        clearVaultBatchSelection()
        clearVaultSearchQueries()
        setAllFavoriteFilters(filterID == "favorites")
        selectedVaultQuickFilterID = filterID
    }

    var isVaultBatchSelectionActive: Bool {
        vaultBatchSelectionKind != nil
    }

    var activeVaultBatchSelectionKind: UnifiedVaultItemKind? {
        vaultBatchSelectionKind
    }

    var vaultBatchSelectionTitle: String {
        if !isVaultBatchSelectionActive {
            return "未选择"
        }
        return selectedVaultBatchItemIDs.isEmpty
            ? "选择条目"
            : "已选择 \(selectedVaultBatchItemIDs.count) 项"
    }

    var canDeleteSelectedVaultBatchItems: Bool {
        isVaultBatchSelectionActive && !isTrashQuickFilterSelected && !selectedVaultBatchItemIDs.isEmpty
    }

    var canRestoreSelectedVaultBatchItems: Bool {
        isVaultBatchSelectionActive && isTrashQuickFilterSelected && !selectedVaultBatchItemIDs.isEmpty
    }

    var canMoveSelectedVaultBatchItems: Bool {
        isVaultBatchSelectionActive
            && !isTrashQuickFilterSelected
            && !selectedVaultBatchItemIDs.isEmpty
            && !availableVaultBatchMoveTargets.isEmpty
    }

    var availableVaultBatchMoveTargets: [LocalVaultProject] {
        guard let activeProject else {
            return []
        }
        return vaultProjects.filter { $0.id != activeProject.id }
    }

    func enterVaultBatchSelection(for kind: UnifiedVaultItemKind) {
        vaultBatchSelectionKind = kind
        selectedVaultBatchItemIDs = selectedVaultBatchItemIDs.intersection(visibleVaultBatchItemIDs(for: kind))
        recordUserActivity()
    }

    @discardableResult
    func createVaultCategory(title: String) throws -> LocalVaultProject {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project = try entryRepository.createProject(title: title)
            vaultProjects.append(project)
            try activateVaultCategory(project, entryRepository: entryRepository)
            entryOperationState = .succeeded(project.title)
            return project
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func switchVaultCategory(projectID: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let project = vaultProjects.first(where: { $0.id == projectID })
            else {
                throw LocalVaultRepositoryError.projectNotFound
            }
            try activateVaultCategory(project, entryRepository: entryRepository)
            entryOperationState = .succeeded(project.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    @discardableResult
    func renameVaultCategory(projectID: String, title: String) throws -> LocalVaultProject {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let renamed = try entryRepository.renameProject(projectID: projectID, title: title)
            vaultProjects = vaultProjects.map { $0.id == projectID ? renamed : $0 }
            if activeProject?.id == projectID {
                activeProject = renamed
                selectedVaultQuickFilterID = "category-\(renamed.id)"
            }
            entryOperationState = .succeeded(renamed.title)
            return renamed
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteVaultCategory(projectID: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            try entryRepository.deleteProject(projectID: projectID)
            vaultProjects.removeAll { $0.id == projectID }
            if activeProject?.id == projectID {
                if let next = vaultProjects.first {
                    try activateVaultCategory(next, entryRepository: entryRepository)
                } else {
                    activeProject = nil
                    clearAllEntryLists()
                    resetVaultQuickFilters()
                }
            }
            entryOperationState = .succeeded("已删除分类")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func clearVaultBatchSelection() {
        vaultBatchSelectionKind = nil
        selectedVaultBatchItemIDs = []
    }

    func toggleVaultBatchItemSelection(_ itemID: String, for kind: UnifiedVaultItemKind) {
        if vaultBatchSelectionKind != kind {
            selectedVaultBatchItemIDs = []
            vaultBatchSelectionKind = kind
        }
        if selectedVaultBatchItemIDs.contains(itemID) {
            selectedVaultBatchItemIDs.remove(itemID)
        } else if visibleVaultBatchItemIDs(for: kind).contains(itemID) {
            selectedVaultBatchItemIDs.insert(itemID)
        }
        recordUserActivity()
    }

    func toggleVaultBatchItemSelection(id itemID: String) {
        guard let kind = vaultBatchSelectionKind else {
            return
        }
        toggleVaultBatchItemSelection(itemID, for: kind)
    }

    func selectAllVisibleVaultBatchItems(for kind: UnifiedVaultItemKind) {
        vaultBatchSelectionKind = kind
        selectedVaultBatchItemIDs = visibleVaultBatchItemIDs(for: kind)
        recordUserActivity()
    }

    func deleteSelectedVaultBatchItems() throws {
        guard let kind = vaultBatchSelectionKind, canDeleteSelectedVaultBatchItems else {
            return
        }
        try mutateSelectedVaultBatchItems(kind: kind, action: .deleted)
    }

    func restoreSelectedVaultBatchItems() throws {
        guard let kind = vaultBatchSelectionKind, canRestoreSelectedVaultBatchItems else {
            return
        }
        try mutateSelectedVaultBatchItems(kind: kind, action: .restored)
    }

    func moveSelectedVaultBatchItems(toProjectID targetProjectID: String) throws {
        guard let kind = vaultBatchSelectionKind, canMoveSelectedVaultBatchItems else {
            return
        }
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let sourceProjectID = activeProject?.id,
                  vaultProjects.contains(where: { $0.id == targetProjectID })
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let orderedIDs = visibleVaultBatchItemOrder(for: kind)
                .filter { selectedVaultBatchItemIDs.contains($0) }
            guard !orderedIDs.isEmpty else {
                clearVaultBatchSelection()
                entryOperationState = .idle
                return
            }

            let events = try moveVaultBatchItems(
                kind: kind,
                ids: orderedIDs,
                fromProjectID: sourceProjectID,
                toProjectID: targetProjectID,
                entryRepository: entryRepository
            )

            try refreshAllEntryLists(projectID: sourceProjectID, entryRepository: entryRepository)
            clearVaultSearchQueries()
            if kind == .login {
                try refreshAutoFillEncryptedIndexIfConfigured()
            }
            for event in events {
                appendOperationTimelineEvent(
                    action: .moved,
                    itemKind: kind,
                    itemID: event.id,
                    itemTitle: event.title
                )
            }
            clearVaultBatchSelection()
            entryOperationState = .succeeded("已移动 \(events.count) 项")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    var vaultDisplayPreferenceRows: [AppVaultDisplayPreferenceRow] {
        [
            AppVaultDisplayPreferenceRow(
                id: "card-density",
                title: "卡片密度",
                value: vaultDisplayPreferences.cardDensity.label,
                detail: "调整密码列表卡片的间距和扫描密度。",
                systemImage: "rectangle.compress.vertical"
            ),
            AppVaultDisplayPreferenceRow(
                id: "login-username",
                title: "账号字段",
                value: vaultDisplayPreferences.showsLoginUsername ? "显示" : "隐藏",
                detail: "控制密码列表是否展示账号摘要。",
                systemImage: "person.text.rectangle"
            ),
            AppVaultDisplayPreferenceRow(
                id: "login-url",
                title: "网址字段",
                value: vaultDisplayPreferences.showsLoginURL ? "显示" : "隐藏",
                detail: "控制密码列表是否展示网站或 URL 摘要。",
                systemImage: "globe"
            ),
            AppVaultDisplayPreferenceRow(
                id: "tab-labels",
                title: "底部导航文字",
                value: vaultDisplayPreferences.showsTabLabels ? "显示" : "隐藏",
                detail: "控制底部导航是否显示文字标签。",
                systemImage: "menubar.rectangle"
            )
        ]
    }

    func updateVaultDisplayPreferences(_ preferences: VaultDisplayPreferences) {
        vaultDisplayPreferences = preferences
        vaultDisplayPreferenceStore.savePreferences(preferences)
        recordUserActivity()
    }

    var appearancePreferenceRows: [AppAppearancePreferenceRow] {
        [
            AppAppearancePreferenceRow(
                id: "color-scheme",
                title: "颜色模式",
                value: appearancePreferences.colorScheme.label,
                detail: "使用系统外观，或固定为浅色/深色。",
                systemImage: "circle.lefthalf.filled"
            ),
            AppAppearancePreferenceRow(
                id: "accent-color",
                title: "强调色",
                value: appearancePreferences.accentColor.label,
                detail: "控制按钮、选择态和系统 tint 色。",
                systemImage: "paintpalette"
            ),
            AppAppearancePreferenceRow(
                id: "password-list-icon",
                title: "密码列表图标",
                value: appearancePreferences.passwordListIconStyle.label,
                detail: "控制密码列表图标的显示方式。",
                systemImage: "app.badge"
            )
        ]
    }

    func updateAppearancePreferences(_ preferences: AppAppearancePreferences) {
        appearancePreferences = preferences
        appearancePreferenceStore.savePreferences(preferences)
        recordUserActivity()
    }

    var plusEntitlementStatusRow: AppPlusEntitlementStatusRow {
        return AppPlusEntitlementStatusRow(
            id: "plus-entitlement",
            title: "Monica Plus",
            value: isPlusActive ? "已激活" : "未激活",
            detail: plusEntitlementDetail(for: plusEntitlementSnapshot),
            systemImage: isPlusActive ? "checkmark.seal.fill" : "seal"
        )
    }

    var isPlusActive: Bool {
        plusEntitlementSnapshot.isActive
    }

    var plusFeatureRows: [AppPlusFeatureRow] {
        return [
            AppPlusFeatureRow(
                id: "premium_themes",
                title: "会员专属主题",
                detail: "解锁 Monica Plus 专属主题配色。",
                systemImage: "paintpalette",
                isUnlocked: isPlusActive
            ),
            AppPlusFeatureRow(
                id: "validator_vibration",
                title: "验证器震动提醒",
                detail: "验证码即将刷新时的本机提醒能力。",
                systemImage: "waveform",
                isUnlocked: isPlusActive
            ),
            AppPlusFeatureRow(
                id: "copy_next_code",
                title: "智能复制下一个验证码",
                detail: "倒计时过短时可切换到下一枚 TOTP。",
                systemImage: "arrow.triangle.2.circlepath",
                isUnlocked: isPlusActive
            ),
            AppPlusFeatureRow(
                id: "bitwarden_sync",
                title: "Bitwarden 同步",
                detail: "对齐 Android Plus 中的 Bitwarden 同步能力开关。",
                systemImage: "cloud",
                isUnlocked: isPlusActive
            )
        ]
    }

    var canActivatePlusFromResource: Bool {
        plusResourceUnlockService != nil
    }

    func activatePlusFromResource(now: Date = Date()) async throws {
        recordUserActivity()
        plusActivationState = .running
        do {
            guard let plusResourceUnlockService else {
                throw AppPlusResourceUnlockError.serviceUnavailable
            }
            guard try await plusResourceUnlockService.unlockPlus() else {
                throw AppPlusResourceUnlockError.activationRejected
            }
            plusEntitlementSnapshot = AppPlusEntitlementSnapshot(source: .resourceUnlock, expiresAt: nil)
            plusEntitlementStore.saveIsResourceUnlocked(true)
            plusActivationState = .activated
            recordUserActivity(at: now)
        } catch {
            plusActivationState = .failed(readablePlusResourceUnlockErrorMessage(for: error))
            throw error
        }
    }

    func deactivatePlus(now: Date = Date()) {
        recordUserActivity()
        plusEntitlementSnapshot = AppPlusEntitlementSnapshot()
        plusEntitlementStore.saveIsResourceUnlocked(false)
        plusActivationState = .deactivated
        recordUserActivity(at: now)
    }

    private func readablePlusResourceUnlockErrorMessage(for error: Error) -> String {
        if let appError = error as? AppPlusResourceUnlockError {
            return appError.localizedDescription
        }
        return "Plus 解锁失败，请稍后重试。"
    }

    var permissionStatusRows: [AppPermissionStatusRow] {
        [
            AppPermissionStatusRow(
                id: "camera",
                title: "相机",
                systemImage: "camera",
                state: cameraPermissionState,
                detail: "用于扫描 TOTP 设置二维码。",
                settingsURL: URL(string: UIApplication.openSettingsURLString)
            ),
            AppPermissionStatusRow(
                id: "autofill",
                title: "AutoFill",
                systemImage: "key.viewfinder",
                state: autoFillIndexStore == nil || autoFillCredentialIdentityStore == nil ? .notConfigured : .configured,
                detail: "Credential Provider、QuickType identity 和加密索引。"
            ),
            AppPermissionStatusRow(
                id: "notifications",
                title: "通知",
                systemImage: "bell",
                state: notificationPermissionState,
                detail: "TOTP 快捷查看会使用 iOS 安全通知替代常驻验证码。",
                settingsURL: URL(string: UIApplication.openSettingsURLString)
            ),
            AppPermissionStatusRow(
                id: "app-group",
                title: "App Group",
                systemImage: "rectangle.connected.to.line.below",
                state: autoFillIndexStore == nil || autoFillCredentialSecretStore == nil ? .notConfigured : .configured,
                detail: "主 App 与 AutoFill Extension 共享加密索引和 secret snapshot。"
            ),
            AppPermissionStatusRow(
                id: "keychain",
                title: "Keychain",
                systemImage: "lock.shield",
                state: vaultKeychainService == nil ? .notConfigured : .configured,
                detail: "保存受系统保护的本地解锁材料，不保存主密码。"
            )
        ]
    }

    var securityCenterRows: [AppSecurityCenterRow] {
        let weakPasswordCount = loginEntries.filter { Self.isWeakPassword($0.password) }.count
        let reusedPasswordCount = reusedPasswordEntryCount(in: loginEntries)
        let breachedPasswordCount = breachedPasswordEntryCount(in: loginEntries)
        let duplicateLoginCount = duplicateLoginEntryCount(in: loginEntries)
        return [
            AppSecurityCenterRow(
                id: "weak-passwords",
                title: "弱密码",
                value: itemCountLabel(weakPasswordCount),
                detail: weakPasswordCount == 0
                    ? "当前登录条目未发现明显弱密码。"
                    : "建议优先为这些登录条目生成更长且包含多类字符的密码。",
                systemImage: "exclamationmark.shield"
            ),
            AppSecurityCenterRow(
                id: "reused-passwords",
                title: "复用密码",
                value: itemCountLabel(reusedPasswordCount),
                detail: reusedPasswordCount == 0
                    ? "当前登录条目未发现密码复用。"
                    : "建议为复用密码的登录条目分别设置唯一密码。",
                systemImage: "rectangle.2.swap"
            ),
            AppSecurityCenterRow(
                id: "breached-passwords",
                title: "泄露风险",
                value: itemCountLabel(breachedPasswordCount),
                detail: breachedPasswordCount == 0
                    ? "当前登录条目未命中本地泄露指纹库。"
                    : "建议立即为命中泄露指纹的登录条目更换唯一密码。",
                systemImage: "bolt.shield"
            ),
            AppSecurityCenterRow(
                id: "duplicate-logins",
                title: "重复项",
                value: itemCountLabel(duplicateLoginCount),
                detail: duplicateLoginCount == 0
                    ? "当前登录条目未发现明显重复项。"
                    : "建议检查这些登录条目，确认是否需要合并或保留。",
                systemImage: "doc.on.doc"
            )
        ]
    }

    var securityCenterRepairSuggestions: [AppSecurityCenterRepairSuggestion] {
        let weakPasswordCount = loginEntries.filter { Self.isWeakPassword($0.password) }.count
        let reusedPasswordCount = reusedPasswordEntryCount(in: loginEntries)
        let breachedPasswordCount = breachedPasswordEntryCount(in: loginEntries)
        let duplicateLoginCount = duplicateLoginEntryCount(in: loginEntries)
        var suggestions: [AppSecurityCenterRepairSuggestion] = []

        if weakPasswordCount > 0 {
            suggestions.append(
                AppSecurityCenterRepairSuggestion(
                    id: "repair-weak-passwords",
                    relatedRowID: "weak-passwords",
                    title: "生成强密码",
                    detail: "为弱密码条目生成更长且包含多类字符的唯一密码。",
                    systemImage: "wand.and.stars"
                )
            )
        }
        if reusedPasswordCount > 0 {
            suggestions.append(
                AppSecurityCenterRepairSuggestion(
                    id: "repair-reused-passwords",
                    relatedRowID: "reused-passwords",
                    title: "拆分复用密码",
                    detail: "逐个为复用密码条目设置不同密码，降低单点泄露影响。",
                    systemImage: "rectangle.2.swap"
                )
            )
        }
        if breachedPasswordCount > 0 {
            suggestions.append(
                AppSecurityCenterRepairSuggestion(
                    id: "repair-breached-passwords",
                    relatedRowID: "breached-passwords",
                    title: "更换泄露密码",
                    detail: "优先处理命中泄露指纹的登录条目，并同步更新对应服务。",
                    systemImage: "bolt.shield"
                )
            )
        }
        if duplicateLoginCount > 0 {
            suggestions.append(
                AppSecurityCenterRepairSuggestion(
                    id: "repair-duplicate-logins",
                    relatedRowID: "duplicate-logins",
                    title: "合并重复项",
                    detail: "检查重复登录预览，确认后保留主条目并清理重复记录。",
                    systemImage: "arrow.triangle.merge"
                )
            )
        }

        return suggestions
    }

    var duplicateLoginMergePreviews: [AppDuplicateLoginMergePreview] {
        let grouped = duplicateLoginGroups(in: loginEntries)
        return grouped.map { key, entries in
            let primary = entries[0]
            let duplicateIDs = entries.dropFirst().map(\.id)
            let title = primary.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = title.isEmpty ? key.title : title
            return AppDuplicateLoginMergePreview(
                id: "duplicate-login-\(primary.id)",
                title: displayTitle,
                username: key.username,
                url: key.url,
                entryCountLabel: itemCountLabel(entries.count),
                primaryEntryID: primary.id,
                duplicateEntryIDs: duplicateIDs,
                detail: "保留 \(displayTitle)，预览合并 \(duplicateIDs.count) 个重复条目。"
            )
        }
    }

    var ignoredDuplicateLoginGroupCount: Int {
        ignoredDuplicateLoginKeys.count
    }

    var canUndoLastDuplicateLoginMerge: Bool {
        lastDuplicateLoginMergeUndo != nil
    }

    var lastDuplicateLoginMergeUndoTitle: String? {
        lastDuplicateLoginMergeUndo?.title
    }

    private static func isWeakPassword(_ password: String) -> Bool {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12 else {
            return true
        }
        let scalars = trimmed.unicodeScalars
        let hasLowercase = scalars.contains { CharacterSet.lowercaseLetters.contains($0) }
        let hasUppercase = scalars.contains { CharacterSet.uppercaseLetters.contains($0) }
        let hasDigit = scalars.contains { CharacterSet.decimalDigits.contains($0) }
        let hasSymbol = scalars.contains {
            !CharacterSet.alphanumerics.contains($0)
                && !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return !(hasLowercase && hasUppercase && hasDigit && hasSymbol)
    }

    private func reusedPasswordEntryCount(in entries: [LocalLoginEntry]) -> Int {
        let grouped = Dictionary(grouping: entries) { entry in
            entry.password.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return grouped
            .filter { password, entries in
                !password.isEmpty && entries.count > 1
            }
            .reduce(0) { count, group in count + group.value.count }
    }

    private func breachedPasswordEntryCount(in entries: [LocalLoginEntry]) -> Int {
        let fingerprints = Set(breachedPasswordSHA256Fingerprints.map { $0.lowercased() })
        guard !fingerprints.isEmpty else {
            return 0
        }
        return entries.filter { entry in
            let password = entry.password.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !password.isEmpty else {
                return false
            }
            return fingerprints.contains(Self.sha256Fingerprint(for: password))
        }.count
    }

    private static func sha256Fingerprint(for value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }

    private func duplicateLoginEntryCount(in entries: [LocalLoginEntry]) -> Int {
        duplicateLoginGroups(in: entries)
            .reduce(0) { count, group in count + group.entries.count }
    }

    private func duplicateLoginGroups(
        in entries: [LocalLoginEntry],
        excludingIgnored: Bool = true
    ) -> [(key: DuplicateLoginEntryKey, entries: [LocalLoginEntry])] {
        var grouped: [DuplicateLoginEntryKey: [LocalLoginEntry]] = [:]
        for entry in entries {
            guard let key = DuplicateLoginEntryKey(entry: entry) else {
                continue
            }
            grouped[key, default: []].append(entry)
        }
        return grouped
            .filter { _, entries in entries.count > 1 }
            .filter { key, _ in
                !excludingIgnored || !ignoredDuplicateLoginKeys.contains(key)
            }
            .map { key, entries in (key: key, entries: entries) }
            .sorted { lhs, rhs in
                lhs.entries[0].id.localizedStandardCompare(rhs.entries[0].id) == .orderedAscending
            }
    }

    private var activeVaultEntryCount: Int {
        loginEntries.count
            + noteEntries.count
            + totpEntries.count
            + cardEntries.count
            + identityEntries.count
            + passkeyEntries.count
            + sshKeyEntries.count
            + apiTokenEntries.count
            + wifiEntries.count
            + sendEntries.count
            + attachmentEntries.count
    }

    private var favoriteVaultEntryCount: Int {
        loginEntries.filter(\.favorite).count
            + noteEntries.filter(\.favorite).count
            + totpEntries.filter(\.favorite).count
            + cardEntries.filter(\.favorite).count
            + identityEntries.filter(\.favorite).count
            + passkeyEntries.filter(\.favorite).count
            + sshKeyEntries.filter(\.favorite).count
            + apiTokenEntries.filter(\.favorite).count
            + wifiEntries.filter(\.favorite).count
            + sendEntries.filter(\.favorite).count
    }

    private var deletedVaultEntryCount: Int {
        deletedLoginEntries.count
            + deletedNoteEntries.count
            + deletedTotpEntries.count
            + deletedCardEntries.count
            + deletedIdentityEntries.count
            + deletedPasskeyEntries.count
            + deletedSshKeyEntries.count
            + deletedApiTokenEntries.count
            + deletedWifiEntries.count
            + deletedSendEntries.count
            + deletedAttachmentEntries.count
    }

    private func itemCountLabel(_ count: Int) -> String {
        "\(count) 项"
    }

    private func plusEntitlementDetail(for snapshot: AppPlusEntitlementSnapshot) -> String {
        switch snapshot.source {
        case .none:
            return "点击资源激活按钮即可解锁 Monica Plus。"
        case .resourceUnlock:
            return "已通过 Android 同口径资源按钮解锁 Monica Plus。"
        }
    }

    private func loginStackedGroupKey(for entry: LocalLoginEntry) -> AppLoginStackedGroupKey {
        if let host = normalizedLoginHost(from: entry.url) {
            return AppLoginStackedGroupKey(
                title: host,
                normalized: host,
                isWebsite: true
            )
        }
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = title.isEmpty ? "未命名" : title
        return AppLoginStackedGroupKey(
            title: fallbackTitle,
            normalized: fallbackTitle.lowercased(),
            isWebsite: false
        )
    }

    private func normalizedLoginHost(from url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let host = URLComponents(string: candidate)?.host?.lowercased() else {
            return nil
        }
        let normalizedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return normalizedHost.isEmpty ? nil : normalizedHost
    }

    private func sharedLoginTitle(from url: URL) -> String {
        let host = url.host()?.lowercased() ?? normalizedLoginHost(from: url.absoluteString)
        let normalizedHost = host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        return normalizedHost?.nonBlankValue ?? "Shared Link"
    }

    private func sharedAttachmentMediaType(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).nonBlankValue ?? "application/octet-stream"
    }

    private func sharedAttachmentLocalPath(fileName: String) -> String {
        sanitizedAttachmentPreviewFileName("share-extension-\(UUID().uuidString)-\(fileName)")
    }

    private func sharedContentHash(_ data: Data) -> String {
        let digest = Data(SHA256.hash(data: data))
            .map { String(format: "%02x", $0) }
            .joined()
        return "sha256:\(digest)"
    }

    var isFirstTimeVaultSetup: Bool {
        rememberedVaultDescriptor == nil
    }

    var isFirstVaultSetupRequired: Bool {
        isFirstTimeVaultSetup
    }

    var hasRememberedVault: Bool {
        rememberedVaultDescriptor != nil && rememberedVaultID != nil
    }

    var biometricUnlockCapability: BiometricUnlockCapability {
        biometricCapabilityProvider()
    }

    var biometricUnlockKind: BiometricUnlockKind? {
        biometricUnlockCapability.kind
    }

    var biometricUnlockDisplayName: String {
        biometricUnlockKind?.displayName ?? "生物识别"
    }

    var biometricUnlockTitle: String {
        "使用 \(biometricUnlockDisplayName) 解锁"
    }

    var biometricUnlockButtonTitle: String {
        "使用 \(biometricUnlockDisplayName)"
    }

    var biometricUnlockSettingsTitle: String {
        "\(biometricUnlockDisplayName) 解锁"
    }

    var biometricUnlockSystemImage: String {
        biometricUnlockKind?.systemImage ?? "person.badge.key"
    }

    private var cameraPermissionState: AppPermissionStatusRow.State {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            .granted
        case .denied, .restricted:
            .denied
        case .notDetermined:
            .notDetermined
        @unknown default:
            .checkable
        }
    }

    func refreshNotificationPermissionStatus() {
        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationPermissionState = Self.notificationPermissionState(
                for: settings.authorizationStatus
            )
        }
    }

    nonisolated private static func notificationPermissionState(
        for authorizationStatus: UNAuthorizationStatus
    ) -> AppPermissionStatusRow.State {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            .granted
        case .denied:
            .denied
        case .notDetermined:
            .notDetermined
        @unknown default:
            .checkable
        }
    }

    var canUseBiometricUnlockHardware: Bool {
        biometricUnlockKind != nil
    }

    var shouldShowBiometricUnlockOnLockScreen: Bool {
        vaultState == .locked
            && isBiometricUnlockEnabled
            && canUseBiometricUnlockHardware
            && canUnlockRememberedVaultWithKeychain
    }

    private func filteredFavoriteEntries<Entry>(
        _ entries: [Entry],
        query: String,
        favoritesOnly: Bool,
        isFavorite: (Entry) -> Bool,
        matches: (Entry, String) -> Bool
    ) -> [Entry] {
        entries.enumerated()
            .filter { _, entry in
                (!favoritesOnly || isFavorite(entry))
                    && (query.isEmpty || matches(entry, query))
            }
            .sorted { lhs, rhs in
                let lhsFavorite = isFavorite(lhs.element)
                let rhsFavorite = isFavorite(rhs.element)
                if lhsFavorite != rhsFavorite {
                    return lhsFavorite
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func visibleVaultBatchItemIDs(for kind: UnifiedVaultItemKind) -> Set<String> {
        Set(visibleVaultBatchItemOrder(for: kind))
    }

    private func visibleVaultBatchItemOrder(for kind: UnifiedVaultItemKind) -> [String] {
        if isTrashQuickFilterSelected {
            switch kind {
            case .login:
                return deletedLoginEntries.map(\.id)
            case .totp:
                return deletedTotpEntries.map(\.id)
            case .note:
                return deletedNoteEntries.map(\.id)
            case .card:
                return deletedCardEntries.map(\.id)
            case .identity:
                return deletedIdentityEntries.map(\.id)
            case .passkey:
                return deletedPasskeyEntries.map(\.id)
            case .sshKey:
                return deletedSshKeyEntries.map(\.id)
            case .apiToken:
                return deletedApiTokenEntries.map(\.id)
            case .wifi:
                return deletedWifiEntries.map(\.id)
            case .send:
                return deletedSendEntries.map(\.id)
            case .attachmentRef:
                return deletedAttachmentEntries.map(\.id)
            }
        }

        switch kind {
        case .login:
            return filteredLoginEntries.map(\.id)
        case .totp:
            return filteredTotpEntries.map(\.id)
        case .note:
            return filteredNoteEntries.map(\.id)
        case .card:
            return filteredCardEntries.map(\.id)
        case .identity:
            return filteredIdentityEntries.map(\.id)
        case .passkey:
            return filteredPasskeyEntries.map(\.id)
        case .sshKey:
            return filteredSshKeyEntries.map(\.id)
        case .apiToken:
            return filteredApiTokenEntries.map(\.id)
        case .wifi:
            return filteredWifiEntries.map(\.id)
        case .send:
            return filteredSendEntries.map(\.id)
        case .attachmentRef:
            return filteredAttachmentEntries.map(\.id)
        }
    }

    private func mutateSelectedVaultBatchItems(
        kind: UnifiedVaultItemKind,
        action: AppOperationTimelineAction
    ) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let orderedIDs = visibleVaultBatchItemOrder(for: kind)
                .filter { selectedVaultBatchItemIDs.contains($0) }
            guard !orderedIDs.isEmpty else {
                clearVaultBatchSelection()
                entryOperationState = .idle
                return
            }

            let events: [(id: String, title: String)]
            switch action {
            case .deleted:
                events = try deleteVaultBatchItems(
                    kind: kind,
                    ids: orderedIDs,
                    projectID: projectID,
                    entryRepository: entryRepository
                )
            case .restored:
                events = try restoreVaultBatchItems(
                    kind: kind,
                    ids: orderedIDs,
                    projectID: projectID,
                    entryRepository: entryRepository
                )
            case .created, .updated, .moved, .viewed:
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            try refreshAllEntryLists(projectID: projectID, entryRepository: entryRepository)
            if kind == .login {
                try refreshAutoFillEncryptedIndexIfConfigured()
            }
            for event in events {
                appendOperationTimelineEvent(
                    action: action,
                    itemKind: kind,
                    itemID: event.id,
                    itemTitle: event.title
                )
            }
            clearVaultBatchSelection()
            let verb = action == .deleted ? "删除" : "恢复"
            entryOperationState = .succeeded("已\(verb) \(events.count) 项")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    private func deleteVaultBatchItems(
        kind: UnifiedVaultItemKind,
        ids: [String],
        projectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> [(id: String, title: String)] {
        var events: [(id: String, title: String)] = []
        for id in ids {
            switch kind {
            case .login:
                guard let entry = loginEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteLoginEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .totp:
                guard let entry = totpEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteTotpEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .note:
                guard let entry = noteEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteNoteEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .card:
                guard let entry = cardEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteCardEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .identity:
                guard let entry = identityEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteIdentityEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .passkey:
                guard let entry = passkeyEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deletePasskeyEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .sshKey:
                guard let entry = sshKeyEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteSshKeyEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .apiToken:
                guard let entry = apiTokenEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteApiTokenEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .wifi:
                guard let entry = wifiEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteWifiEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .send:
                guard let entry = sendEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteSendEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .attachmentRef:
                guard let entry = attachmentEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteAttachmentMetadata(projectID: projectID, attachmentID: id)
                events.append((id, entry.fileName))
            }
        }
        return events
    }

    private func restoreVaultBatchItems(
        kind: UnifiedVaultItemKind,
        ids: [String],
        projectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> [(id: String, title: String)] {
        var events: [(id: String, title: String)] = []
        for id in ids {
            switch kind {
            case .login:
                let entry = try entryRepository.restoreLoginEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .totp:
                let entry = try entryRepository.restoreTotpEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .note:
                let entry = try entryRepository.restoreNoteEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .card:
                let entry = try entryRepository.restoreCardEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .identity:
                let entry = try entryRepository.restoreIdentityEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .passkey:
                let entry = try entryRepository.restorePasskeyEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .sshKey:
                let entry = try entryRepository.restoreSshKeyEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .apiToken:
                let entry = try entryRepository.restoreApiTokenEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .wifi:
                let entry = try entryRepository.restoreWifiEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .send:
                let entry = try entryRepository.restoreSendEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .attachmentRef:
                let entry = try entryRepository.restoreAttachmentMetadata(projectID: projectID, attachmentID: id)
                events.append((id, entry.fileName))
            }
        }
        return events
    }

    private func moveVaultBatchItems(
        kind: UnifiedVaultItemKind,
        ids: [String],
        fromProjectID: String,
        toProjectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> [(id: String, title: String)] {
        var events: [(id: String, title: String)] = []
        for id in ids {
            let moved = try entryRepository.moveEntry(
                kind: kind,
                entryID: id,
                fromProjectID: fromProjectID,
                toProjectID: toProjectID
            )
            events.append((moved.id, moved.title))
        }
        return events
    }

    private func clearVaultSearchQueries() {
        loginSearchQuery = ""
        noteSearchQuery = ""
        totpSearchQuery = ""
        cardSearchQuery = ""
        identitySearchQuery = ""
        passkeySearchQuery = ""
        sshKeySearchQuery = ""
        apiTokenSearchQuery = ""
        wifiSearchQuery = ""
        sendSearchQuery = ""
        attachmentSearchQuery = ""
    }

    private func setAllFavoriteFilters(_ favoritesOnly: Bool) {
        showFavoriteLoginEntriesOnly = favoritesOnly
        showFavoriteNoteEntriesOnly = favoritesOnly
        showFavoriteTotpEntriesOnly = favoritesOnly
        showFavoriteCardEntriesOnly = favoritesOnly
        showFavoriteIdentityEntriesOnly = favoritesOnly
        showFavoritePasskeyEntriesOnly = favoritesOnly
        showFavoriteSshKeyEntriesOnly = favoritesOnly
        showFavoriteApiTokenEntriesOnly = favoritesOnly
        showFavoriteWifiEntriesOnly = favoritesOnly
        showFavoriteSendEntriesOnly = favoritesOnly
    }

    private func resetVaultQuickFilters() {
        selectedVaultQuickFilterID = "all"
        isLoginStackedGroupModeEnabled = false
        clearVaultBatchSelection()
        clearVaultSearchQueries()
        setAllFavoriteFilters(false)
    }

    private var pendingFirstTimePassword = ""

    func beginFirstTimePasswordConfirmation() {
        pendingFirstTimePassword = vaultPassword
        vaultPassword = ""
        firstTimePasswordSetupStep = .confirmPassword
        vaultOperationState = .idle
    }

    func confirmFirstTimePasswordAndCreateVault(
        in directoryURL: URL,
        deviceID: String,
        now: Date = Date()
    ) throws {
        guard pendingFirstTimePassword == vaultPassword else {
            pendingFirstTimePassword = ""
            vaultPassword = ""
            firstTimePasswordSetupStep = .enterPassword
            vaultOperationState = .failed(FirstTimePasswordSetupError.passwordMismatch.localizedDescription)
            throw FirstTimePasswordSetupError.passwordMismatch
        }

        vaultPassword = pendingFirstTimePassword
        pendingFirstTimePassword = ""
        try createLocalVault(in: directoryURL, deviceID: deviceID, now: now)
        firstTimePasswordSetupStep = .enterPassword
    }

    func createLocalVault(
        in directoryURL: URL,
        deviceID: String,
        now: Date = Date()
    ) throws {
        vaultOperationState = .running

        do {
            let displayName = vaultName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Monica"
                : vaultName
            let session = try vaultRepository.createVault(
                named: displayName,
                in: directoryURL,
                password: vaultPassword,
                deviceID: deviceID
            )
            vaultPassword = ""
            isPrivacyShieldVisible = false
            vaultState = .unlocked
            activeVaultName = session.descriptor.displayName
            activeVaultSession = session
            let entryRepository = vaultRepository.entryRepository(for: session)
            activeEntryRepository = entryRepository
            activeProject = nil
            vaultProjects = try entryRepository.listProjects()
            rememberVault(session)
            loginEntries = []
            deletedLoginEntries = []
            noteEntries = []
            deletedNoteEntries = []
            totpEntries = []
            deletedTotpEntries = []
            totpImportURI = ""
            cardEntries = []
            deletedCardEntries = []
            identityEntries = []
            deletedIdentityEntries = []
            passkeyEntries = []
            deletedPasskeyEntries = []
            clearExtendedParityEntries()
            clearOperationTimelineEvents()
            recordUserActivity(at: now)
            try refreshWidgetSnapshotIfConfigured(now: now)
            try refreshShortcutSnapshotIfConfigured()
            vaultOperationState = .succeeded(session.descriptor.displayName)
        } catch {
            clearVaultAccessAfterFailure()
            vaultOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func openLocalVault(
        at fileURL: URL,
        deviceID: String,
        now: Date = Date()
    ) throws {
        vaultOperationState = .running

        do {
            let session = try vaultRepository.openVault(
                at: fileURL,
                password: vaultPassword,
                deviceID: deviceID
            )
            vaultPassword = ""
            isPrivacyShieldVisible = false
            vaultState = .unlocked
            activeVaultName = session.descriptor.displayName
            activeVaultSession = session
            let entryRepository = vaultRepository.entryRepository(for: session)
            activeEntryRepository = entryRepository
            activeProject = nil
            vaultProjects = try entryRepository.listProjects()
            rememberVault(session)
            loginEntries = []
            deletedLoginEntries = []
            noteEntries = []
            deletedNoteEntries = []
            totpEntries = []
            deletedTotpEntries = []
            totpImportURI = ""
            cardEntries = []
            deletedCardEntries = []
            identityEntries = []
            deletedIdentityEntries = []
            passkeyEntries = []
            deletedPasskeyEntries = []
            clearExtendedParityEntries()
            clearOperationTimelineEvents()
            recordUserActivity(at: now)
            try refreshWidgetSnapshotIfConfigured(now: now)
            try refreshShortcutSnapshotIfConfigured()
            vaultOperationState = .succeeded(session.descriptor.displayName)
        } catch {
            clearVaultAccessAfterFailure()
            vaultOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func unlockRememberedVaultWithPassword(
        deviceID: String,
        now: Date = Date(),
        fallbackDirectory: URL? = nil
    ) throws {
        guard let rememberedVaultDescriptor else {
            vaultOperationState = .failed(AppVaultKeychainError.rememberedVaultUnavailable.localizedDescription)
            throw AppVaultKeychainError.rememberedVaultUnavailable
        }

        let descriptor = resolvedRememberedVaultDescriptor(
            rememberedVaultDescriptor,
            fallbackDirectory: fallbackDirectory
        )
        try openLocalVault(
            at: descriptor.fileURL,
            deviceID: deviceID,
            now: now
        )
    }

    func openRememberedLocalVaultWithPassword(
        deviceID: String,
        now: Date = Date()
    ) throws {
        try unlockRememberedVaultWithPassword(deviceID: deviceID, now: now)
    }

    func showForgotPasswordGuidance() {
        recordUserActivity()
        resetForgotPasswordInputs()
        do {
            guard let rememberedVaultID,
                  let setup = try securityQuestionStore.load(vaultID: rememberedVaultID) else {
                vaultOperationState = .failed(
                    "主密码无法找回。可尝试 Keychain 生物识别解锁、打开可记得密码的备份，或新建保险库。"
                )
                return
            }
            forgotPasswordQuestion1Text = setup.question1Text
            forgotPasswordQuestion2Text = setup.question2Text
            forgotPasswordRecoveryStep = .verifySecurityQuestions
            vaultOperationState = .idle
        } catch {
            vaultOperationState = .failed(error.localizedDescription)
        }
    }

    var areSecurityQuestionsSetForActiveVault: Bool {
        guard let activeVaultSession else {
            return false
        }
        return (try? securityQuestionStore.load(vaultID: activeVaultSession.handle.vaultID)) != nil
    }

    func saveSecurityQuestions() throws {
        recordUserActivity()
        do {
            guard let activeVaultSession else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            guard securityQuestion1ID != securityQuestion2ID else {
                throw SecurityQuestionRecoveryError.duplicateQuestions
            }
            let trimmedAnswer1 = securityAnswer1.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedAnswer2 = securityAnswer2.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedAnswer1.isEmpty, !trimmedAnswer2.isEmpty else {
                throw SecurityQuestionRecoveryError.missingAnswers
            }

            let setup = SecurityQuestionRecoverySetup(
                vaultID: activeVaultSession.handle.vaultID,
                question1ID: securityQuestion1ID,
                question1Text: securityQuestionText(for: securityQuestion1ID),
                answer1Hash: securityQuestionAnswerHash(trimmedAnswer1),
                question2ID: securityQuestion2ID,
                question2Text: securityQuestionText(for: securityQuestion2ID),
                answer2Hash: securityQuestionAnswerHash(trimmedAnswer2)
            )
            try securityQuestionStore.save(setup)
            securityAnswer1 = ""
            securityAnswer2 = ""
            securityQuestionState = .succeeded("密保问题已保存。")
        } catch {
            securityQuestionState = .failed(error.localizedDescription)
            throw error
        }
    }

    func verifyForgotPasswordSecurityAnswers(answer1: String, answer2: String) -> Bool {
        guard let rememberedVaultID,
              let setup = try? securityQuestionStore.load(vaultID: rememberedVaultID) else {
            vaultOperationState = .failed(SecurityQuestionRecoveryError.missingSecurityQuestions.localizedDescription)
            return false
        }
        let isMatch = setup.answer1Hash == securityQuestionAnswerHash(answer1)
            && setup.answer2Hash == securityQuestionAnswerHash(answer2)
        if isMatch {
            forgotPasswordRecoveryStep = .resetPassword
            forgotPasswordAttemptCount = 0
            vaultOperationState = .idle
        } else {
            forgotPasswordAttemptCount += 1
            vaultOperationState = .failed(
                forgotPasswordAttemptCount >= 3
                    ? "密保答案错误次数过多，请返回后重试。"
                    : "密保答案不正确。"
            )
        }
        return isMatch
    }

    func resetForgottenPasswordWithVerifiedSecurityAnswers(deviceID: String) async throws {
        recordUserActivity()
        do {
            guard forgotPasswordRecoveryStep == .resetPassword else {
                throw SecurityQuestionRecoveryError.verificationRequired
            }
            guard forgotPasswordNewPassword == forgotPasswordConfirmPassword else {
                throw SecurityQuestionRecoveryError.passwordMismatch
            }
            guard let rememberedVaultDescriptor,
                  let rememberedVaultID else {
                throw AppVaultKeychainError.rememberedVaultUnavailable
            }
            guard let vaultKeychainService else {
                throw AppVaultKeychainError.keychainUnavailable
            }

            vaultOperationState = .running
            let wrappedKey = try await vaultKeychainService.loadWrappedKeyAfterAuthentication(
                vaultID: rememberedVaultID,
                reason: "重设 Monica 主密码"
            )
            guard wrappedKey.vaultID == rememberedVaultID else {
                throw AppVaultKeychainError.vaultMismatch
            }
            let session = try vaultRepository.openVaultWithSecurityKey(
                at: rememberedVaultDescriptor.fileURL,
                securityKeyMaterial: wrappedKey.wrappedKeyMaterial,
                deviceID: deviceID
            )
            guard session.handle.vaultID == rememberedVaultID else {
                vaultRepository.closeVault(for: session)
                throw AppVaultKeychainError.vaultMismatch
            }

            try vaultRepository.resetMasterPassword(
                for: session,
                newPassword: forgotPasswordNewPassword
            )
            vaultRepository.closeVault(for: session)
            resetForgotPasswordInputs()
            vaultState = .locked
            vaultPassword = ""
            vaultOperationState = .succeeded("主密码已重设，请使用新密码解锁。")
        } catch {
            vaultOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func dismissForgotPasswordRecovery() {
        resetForgotPasswordInputs()
    }

    private func resetForgotPasswordInputs() {
        forgotPasswordRecoveryStep = .none
        forgotPasswordQuestion1Text = ""
        forgotPasswordQuestion2Text = ""
        forgotPasswordAnswer1 = ""
        forgotPasswordAnswer2 = ""
        forgotPasswordAttemptCount = 0
        forgotPasswordNewPassword = ""
        forgotPasswordConfirmPassword = ""
    }

    private func securityQuestionText(for id: Int) -> String {
        Self.securityQuestionOptions.first { $0.id == id }?.text ?? "密保问题"
    }

    private func securityQuestionAnswerHash(_ answer: String) -> String {
        let normalized = answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func presentAddEditor(for tab: MonicaAppTab) {
        guard let itemKind = tab.coreItemKind else {
            presentedEditorMode = nil
            isFabMenuPresented = false
            return
        }

        presentedEditorMode = .add(itemKind)
        isFabMenuPresented = false
    }

    func presentAddEditor(forItemKind itemKind: UnifiedVaultItemKind) {
        presentedEditorMode = .add(itemKind)
        isFabMenuPresented = false
    }

    func presentEditEditor(for entry: LocalLoginEntry) {
        selectLoginEntryForEditing(entry)
        presentedEditorMode = .edit(VaultItemRoute(kind: .login, entryID: entry.id))
    }

    func presentEditEditor(for entry: LocalNoteEntry) {
        selectNoteEntryForEditing(entry)
        presentedEditorMode = .edit(VaultItemRoute(kind: .note, entryID: entry.id))
    }

    func presentEditEditor(for entry: LocalTotpEntry) {
        selectTotpEntryForEditing(entry)
        presentedEditorMode = .edit(VaultItemRoute(kind: .totp, entryID: entry.id))
    }

    func presentEditEditor(for entry: LocalCardEntry) {
        selectCardEntryForEditing(entry)
        presentedEditorMode = .edit(VaultItemRoute(kind: .card, entryID: entry.id))
    }

    func presentEditEditor(for entry: LocalIdentityEntry) {
        selectIdentityEntryForEditing(entry)
        presentedEditorMode = .edit(VaultItemRoute(kind: .identity, entryID: entry.id))
    }

    func presentEditEditor(for entry: LocalPasskeyEntry) {
        selectPasskeyEntryForEditing(entry)
        presentedEditorMode = .edit(VaultItemRoute(kind: .passkey, entryID: entry.id))
    }

    func presentEditEditor(for entry: LocalSshKeyEntry) {
        selectSshKeyEntryForEditing(entry)
        presentedEditorMode = .edit(VaultItemRoute(kind: .sshKey, entryID: entry.id))
    }

    func presentEditEditor(for entry: LocalApiTokenEntry) {
        selectApiTokenEntryForEditing(entry)
        presentedEditorMode = .edit(VaultItemRoute(kind: .apiToken, entryID: entry.id))
    }

    func presentEditEditor(for entry: LocalWifiEntry) {
        selectWifiEntryForEditing(entry)
        presentedEditorMode = .edit(VaultItemRoute(kind: .wifi, entryID: entry.id))
    }

    func presentEditEditor(for entry: LocalSendEntry) {
        selectSendEntryForEditing(entry)
        presentedEditorMode = .edit(VaultItemRoute(kind: .send, entryID: entry.id))
    }

    func dismissPresentedEditor() {
        presentedEditorMode = nil
    }

    func savePresentedEditor(projectTitle: String) throws {
        guard let presentedEditorMode else {
            return
        }

        switch presentedEditorMode {
        case .add(let kind):
            try saveNewEntry(kind: kind, projectTitle: projectTitle)
        case .edit(let route):
            try saveEditedEntry(kind: route.kind)
        }
        self.presentedEditorMode = nil
    }

    private func saveNewEntry(kind: UnifiedVaultItemKind, projectTitle: String) throws {
        switch kind {
        case .login:
            try createLoginEntry(projectTitle: projectTitle)
        case .note:
            try createNoteEntry(projectTitle: projectTitle)
        case .totp:
            try createTotpEntry(projectTitle: projectTitle)
        case .card:
            try createCardEntry(projectTitle: projectTitle)
        case .identity:
            try createIdentityEntry(projectTitle: projectTitle)
        case .passkey:
            try createPasskeyEntry(projectTitle: projectTitle)
        case .sshKey:
            try createSshKeyEntry(projectTitle: projectTitle)
        case .apiToken:
            try createApiTokenEntry(projectTitle: projectTitle)
        case .wifi:
            try createWifiEntry(projectTitle: projectTitle)
        case .send:
            try createSendEntry(projectTitle: projectTitle)
        case .attachmentRef:
            throw LocalVaultRepositoryError.unsupportedEntryType(kind)
        }
    }

    private func saveEditedEntry(kind: UnifiedVaultItemKind) throws {
        switch kind {
        case .login:
            try updateSelectedLoginEntry()
        case .note:
            try updateSelectedNoteEntry()
        case .totp:
            try updateSelectedTotpEntry()
        case .card:
            try updateSelectedCardEntry()
        case .identity:
            try updateSelectedIdentityEntry()
        case .passkey:
            try updateSelectedPasskeyEntry()
        case .sshKey:
            try updateSelectedSshKeyEntry()
        case .apiToken:
            try updateSelectedApiTokenEntry()
        case .wifi:
            try updateSelectedWifiEntry()
        case .send:
            try updateSelectedSendEntry()
        case .attachmentRef:
            throw LocalVaultRepositoryError.unsupportedEntryType(kind)
        }
    }

    func createLoginEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project: LocalVaultProject
            if let activeProject {
                project = activeProject
            } else {
                project = try entryRepository.createProject(title: projectTitle)
                activeProject = project
            }
            let entry = try entryRepository.createLoginEntry(
                projectID: project.id,
                draft: LocalLoginEntryDraft(
                    title: loginTitle,
                    username: loginUsername,
                    password: loginPassword,
                    url: loginURL
                )
            )
            loginPassword = ""
            loginEntries = try entryRepository.listLoginEntries(projectID: project.id)
            deletedLoginEntries = try entryRepository.listDeletedLoginEntries(projectID: project.id)
            try refreshAutoFillEncryptedIndexIfConfigured()
            try refreshShortcutSnapshotIfConfigured()
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .login,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func generateLoginPassword() throws {
        recordUserActivity()
        do {
            loginPassword = try passwordGenerator()
            entryOperationState = .succeeded("已生成密码")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func selectLoginEntryForEditing(_ entry: LocalLoginEntry) {
        recordUserActivity()
        editingLoginEntryID = entry.id
        editingLoginTitle = entry.title
        editingLoginUsername = entry.username
        editingLoginPassword = entry.password
        editingLoginURL = entry.url
        editingLoginFavorite = entry.favorite
    }

    func updateSelectedLoginEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingLoginEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let entry = try entryRepository.updateLoginEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalLoginEntryDraft(
                    title: editingLoginTitle,
                    username: editingLoginUsername,
                    password: editingLoginPassword,
                    url: editingLoginURL
                )
            )
            loginEntries = try entryRepository.listLoginEntries(projectID: projectID)
            deletedLoginEntries = try entryRepository.listDeletedLoginEntries(projectID: projectID)
            selectLoginEntryForEditing(entry)
            try refreshAutoFillEncryptedIndexIfConfigured()
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .login,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    @discardableResult
    func importPendingShareExtensionItems(
        inboxStore: AppShareExtensionInboxStore,
        projectTitle: String
    ) throws -> AppShareImportResult {
        let requests = try inboxStore.loadPendingImportRequests()
        guard !requests.isEmpty else {
            return AppShareImportResult(importedCounts: [:], importedTitles: [])
        }
        let result = try importSharedItems(requests, projectTitle: projectTitle)
        try inboxStore.clearPendingImportRequests()
        return result
    }

    @discardableResult
    func importSharedItems(
        _ requests: [AppShareImportRequest],
        projectTitle: String
    ) throws -> AppShareImportResult {
        recordUserActivity()
        entryOperationState = .running

        do {
            let vaultSession = try requireActiveVaultSession()
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project = try ensureActiveProject(projectTitle: projectTitle, entryRepository: entryRepository)
            var importedCounts: [UnifiedVaultItemKind: Int] = [:]
            var importedTitles: [String] = []

            for request in requests {
                switch request {
                case .url(let url):
                    let title = sharedLoginTitle(from: url)
                    let entry = try entryRepository.createLoginEntry(
                        projectID: project.id,
                        draft: LocalLoginEntryDraft(
                            title: title,
                            username: "",
                            password: "",
                            url: url.absoluteString
                        )
                    )
                    importedCounts[.login, default: 0] += 1
                    importedTitles.append(entry.title)
                    appendOperationTimelineEvent(
                        action: .created,
                        itemKind: .login,
                        itemID: entry.id,
                        itemTitle: entry.title
                    )
                case .text(let text):
                    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !body.isEmpty else {
                        continue
                    }
                    let entry = try entryRepository.createNoteEntry(
                        projectID: project.id,
                        draft: LocalNoteEntryDraft(
                            title: "来自分享的文本",
                            body: body
                        )
                    )
                    importedCounts[.note, default: 0] += 1
                    importedTitles.append(entry.title)
                    appendOperationTimelineEvent(
                        action: .created,
                        itemKind: .note,
                        itemID: entry.id,
                        itemTitle: entry.title
                    )
                case .file(let url, let mediaType):
                    let data = try Data(contentsOf: url)
                    let fileName = sanitizedAttachmentPreviewFileName(url.lastPathComponent)
                    let localPath = sharedAttachmentLocalPath(fileName: fileName)
                    let storedPath = try androidBackupAttachmentBlobStore.saveEncryptedBlob(
                        data,
                        vaultID: vaultSession.handle.vaultID,
                        localPath: localPath
                    )
                    let attachment = try entryRepository.createAttachmentMetadata(
                        projectID: project.id,
                        entryID: nil,
                        fileName: fileName,
                        mediaType: sharedAttachmentMediaType(mediaType),
                        originalSize: Int64(data.count),
                        storedSize: Int64(data.count),
                        contentHash: sharedContentHash(data),
                        storageMode: "share-extension-imported-blob",
                        source: "ios-share-extension",
                        downloadState: "downloaded",
                        wrappedContentEncryptionKey: nil,
                        localPath: storedPath
                    )
                    importedCounts[.attachmentRef, default: 0] += 1
                    importedTitles.append(attachment.fileName)
                    appendOperationTimelineEvent(
                        action: .created,
                        itemKind: .attachmentRef,
                        itemID: attachment.id,
                        itemTitle: attachment.fileName
                    )
                }
            }

            try refreshAllEntryLists(projectID: project.id, entryRepository: entryRepository)
            try refreshAutoFillEncryptedIndexIfConfigured()
            let result = AppShareImportResult(
                importedCounts: importedCounts,
                importedTitles: importedTitles
            )
            entryOperationState = .succeeded("Share Extension 已导入 \(result.totalCount) 项")
            return result
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func saveAutoFillCredential(
        _ request: AppAutoFillCredentialSaveRequest,
        projectTitle: String
    ) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let normalizedRequest = try normalizedAutoFillSaveRequest(request)
            let project: LocalVaultProject
            if let activeProject {
                project = activeProject
            } else {
                project = try entryRepository.createProject(title: projectTitle)
                activeProject = project
            }

            if let existing = matchingLoginEntry(for: normalizedRequest, in: loginEntries) {
                let updated = try entryRepository.updateLoginEntry(
                    projectID: project.id,
                    entryID: existing.id,
                    draft: LocalLoginEntryDraft(
                        title: existing.title,
                        username: normalizedRequest.username,
                        password: normalizedRequest.password,
                        url: existing.url,
                        notes: existing.notes
                    )
                )
                loginEntries = try entryRepository.listLoginEntries(projectID: project.id)
                deletedLoginEntries = try entryRepository.listDeletedLoginEntries(projectID: project.id)
                try refreshAutoFillEncryptedIndexIfConfigured()
                appendOperationTimelineEvent(
                    action: .updated,
                    itemKind: .login,
                    itemID: updated.id,
                    itemTitle: updated.title
                )
                entryOperationState = .succeeded("AutoFill 已更新 \(updated.title)")
            } else {
                let title = autoFillSaveTitle(for: normalizedRequest)
                let entry = try entryRepository.createLoginEntry(
                    projectID: project.id,
                    draft: LocalLoginEntryDraft(
                        title: title,
                        username: normalizedRequest.username,
                        password: normalizedRequest.password,
                        url: normalizedRequest.serviceIdentifier
                    )
                )
                loginEntries = try entryRepository.listLoginEntries(projectID: project.id)
                deletedLoginEntries = try entryRepository.listDeletedLoginEntries(projectID: project.id)
                try refreshAutoFillEncryptedIndexIfConfigured()
                appendOperationTimelineEvent(
                    action: .created,
                    itemKind: .login,
                    itemID: entry.id,
                    itemTitle: entry.title
                )
                entryOperationState = .succeeded("AutoFill 已保存 \(entry.title)")
            }
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    @discardableResult
    func importPendingAutoFillSaveRequests(
        inboxStore: AppAutoFillCredentialSaveInboxStore,
        projectTitle: String
    ) throws -> Int {
        let requests = try inboxStore.loadPendingSaveRequests()
        guard !requests.isEmpty else {
            return 0
        }

        for request in requests {
            try saveAutoFillCredential(request, projectTitle: projectTitle)
        }
        try inboxStore.clearPendingSaveRequests()
        entryOperationState = .succeeded("AutoFill 已导入 \(requests.count) 个保存请求")
        return requests.count
    }

    func generateSelectedLoginPassword() throws {
        recordUserActivity()
        do {
            editingLoginPassword = try passwordGenerator()
            entryOperationState = .succeeded("已生成密码")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedLoginFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingLoginEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setLoginEntryFavorite(
                projectID: projectID,
                entryID: entryID,
                favorite: favorite
            )
            loginEntries = try entryRepository.listLoginEntries(projectID: projectID)
            selectLoginEntryForEditing(updated)
            entryOperationState = .succeeded(favorite ? "已收藏 \(updated.title)" : "已取消收藏 \(updated.title)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedLoginEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingLoginEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingLoginTitle
            try entryRepository.deleteLoginEntry(projectID: projectID, entryID: entryID)
            loginEntries = try entryRepository.listLoginEntries(projectID: projectID)
            deletedLoginEntries = try entryRepository.listDeletedLoginEntries(projectID: projectID)
            clearEditingLoginEntry()
            try refreshAutoFillEncryptedIndexIfConfigured()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .login,
                itemID: entryID,
                itemTitle: deletedTitle
            )
            entryOperationState = .succeeded("已删除 \(deletedTitle)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func mergeDuplicateLoginPreview(_ preview: AppDuplicateLoginMergePreview) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            guard let currentPreview = duplicateLoginMergePreviews.first(where: { $0.id == preview.id }) else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            for entryID in currentPreview.duplicateEntryIDs {
                try entryRepository.deleteLoginEntry(projectID: projectID, entryID: entryID)
            }
            lastDuplicateLoginMergeUndo = AppDuplicateLoginMergeUndo(
                title: currentPreview.title,
                restoredEntryIDs: currentPreview.duplicateEntryIDs
            )
            loginEntries = try entryRepository.listLoginEntries(projectID: projectID)
            deletedLoginEntries = try entryRepository.listDeletedLoginEntries(projectID: projectID)
            try refreshAutoFillEncryptedIndexIfConfigured()
            entryOperationState = .succeeded("已合并 \(currentPreview.title)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func undoLastDuplicateLoginMerge() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let undo = lastDuplicateLoginMergeUndo,
                  let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            for entryID in undo.restoredEntryIDs {
                _ = try entryRepository.restoreLoginEntry(projectID: projectID, entryID: entryID)
            }
            loginEntries = try entryRepository.listLoginEntries(projectID: projectID)
            deletedLoginEntries = try entryRepository.listDeletedLoginEntries(projectID: projectID)
            try refreshAutoFillEncryptedIndexIfConfigured()
            lastDuplicateLoginMergeUndo = nil
            entryOperationState = .succeeded("已撤销合并 \(undo.title)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func ignoreDuplicateLoginPreview(_ preview: AppDuplicateLoginMergePreview) {
        recordUserActivity()

        guard let group = duplicateLoginGroups(in: loginEntries, excludingIgnored: false)
            .first(where: { group in
                "duplicate-login-\(group.entries[0].id)" == preview.id
            })
        else {
            return
        }

        ignoredDuplicateLoginKeys.insert(group.key)
        entryOperationState = .succeeded("已忽略 \(preview.title)")
    }

    func clearIgnoredDuplicateLoginPreviews() {
        recordUserActivity()
        ignoredDuplicateLoginKeys.removeAll()
        entryOperationState = .succeeded("已恢复重复项提示")
    }

    func restoreLoginEntry(_ entry: LocalLoginEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreLoginEntry(
                projectID: projectID,
                entryID: entry.id
            )
            loginEntries = try entryRepository.listLoginEntries(projectID: projectID)
            deletedLoginEntries = try entryRepository.listDeletedLoginEntries(projectID: projectID)
            try refreshAutoFillEncryptedIndexIfConfigured()
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .login,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded("已恢复 \(restored.title)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func createNoteEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project: LocalVaultProject
            if let activeProject {
                project = activeProject
            } else {
                project = try entryRepository.createProject(title: projectTitle)
                activeProject = project
            }
            let entry = try entryRepository.createNoteEntry(
                projectID: project.id,
                draft: LocalNoteEntryDraft(title: noteTitle, body: noteBody)
            )
            noteEntries = try entryRepository.listNoteEntries(projectID: project.id)
            deletedNoteEntries = try entryRepository.listDeletedNoteEntries(projectID: project.id)
            try refreshShortcutSnapshotIfConfigured()
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .note,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func selectNoteEntryForEditing(_ entry: LocalNoteEntry) {
        recordUserActivity()
        editingNoteEntryID = entry.id
        editingNoteTitle = entry.title
        editingNoteBody = entry.body
        editingNoteFavorite = entry.favorite
    }

    func updateSelectedNoteEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingNoteEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let entry = try entryRepository.updateNoteEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalNoteEntryDraft(title: editingNoteTitle, body: editingNoteBody)
            )
            noteEntries = try entryRepository.listNoteEntries(projectID: projectID)
            deletedNoteEntries = try entryRepository.listDeletedNoteEntries(projectID: projectID)
            selectNoteEntryForEditing(entry)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .note,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedNoteFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingNoteEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setNoteEntryFavorite(
                projectID: projectID,
                entryID: entryID,
                favorite: favorite
            )
            noteEntries = try entryRepository.listNoteEntries(projectID: projectID)
            selectNoteEntryForEditing(updated)
            entryOperationState = .succeeded(favorite ? "已收藏 \(updated.title)" : "已取消收藏 \(updated.title)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedNoteEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingNoteEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingNoteTitle
            try entryRepository.deleteNoteEntry(projectID: projectID, entryID: entryID)
            noteEntries = try entryRepository.listNoteEntries(projectID: projectID)
            deletedNoteEntries = try entryRepository.listDeletedNoteEntries(projectID: projectID)
            clearEditingNoteEntry()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .note,
                itemID: entryID,
                itemTitle: deletedTitle
            )
            entryOperationState = .succeeded("已删除 \(deletedTitle)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func restoreNoteEntry(_ entry: LocalNoteEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreNoteEntry(
                projectID: projectID,
                entryID: entry.id
            )
            noteEntries = try entryRepository.listNoteEntries(projectID: projectID)
            deletedNoteEntries = try entryRepository.listDeletedNoteEntries(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .note,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded("已恢复 \(restored.title)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func createTotpEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project: LocalVaultProject
            if let activeProject {
                project = activeProject
            } else {
                project = try entryRepository.createProject(title: projectTitle)
                activeProject = project
            }
            let entry = try entryRepository.createTotpEntry(
                projectID: project.id,
                draft: LocalTotpEntryDraft(
                    title: totpTitle,
                    secret: totpSecret,
                    issuer: totpIssuer,
                    accountName: totpAccountName,
                    period: totpPeriod,
                    digits: totpDigits,
                    algorithm: totpAlgorithm,
                    otpType: "TOTP",
                    counter: 0
                )
            )
            totpSecret = ""
            totpEntries = try entryRepository.listTotpEntries(projectID: project.id)
            deletedTotpEntries = try entryRepository.listDeletedTotpEntries(projectID: project.id)
            try refreshShortcutSnapshotIfConfigured()
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .totp,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func importTotpURI(_ value: String) throws {
        try importTotpURI(value, source: .manualURI)
    }

    func importScannedTotpQRCode(_ value: String) throws {
        try importTotpURI(value, source: .scannedQRCode)
    }

    private func importTotpURI(_ value: String, source: TotpImportSource) throws {
        recordUserActivity()

        do {
            let draft = try TotpURIParser.parse(value)
            guard let period = UInt32(exactly: draft.period) else {
                throw TotpError.invalidPeriod
            }
            guard let digits = UInt32(exactly: draft.digits) else {
                throw TotpError.invalidDigits
            }

            totpTitle = draft.title
            totpSecret = draft.secret
            totpIssuer = draft.issuer
            totpAccountName = draft.accountName
            totpPeriod = period
            totpDigits = digits
            totpAlgorithm = draft.algorithm.rawValue
            totpImportURI = ""
            entryOperationState = .succeeded("已导入 \(draft.title)")
        } catch {
            entryOperationState = .failed(readableTotpImportErrorMessage(for: error, source: source))
            throw error
        }
    }

    private func readableTotpImportErrorMessage(for error: Error, source: TotpImportSource) -> String {
        guard let totpError = error as? TotpError else {
            return error.localizedDescription
        }

        switch (source, totpError) {
        case (.scannedQRCode, .invalidURI):
            return "扫描到的二维码不是 TOTP 设置码。"
        case (.manualURI, .invalidURI):
            return "请输入有效的 otpauth:// TOTP 设置 URI。"
        case (.scannedQRCode, .invalidSecret):
            return "扫描到的二维码包含无效的 TOTP 密钥。"
        case (.manualURI, .invalidSecret):
            return "TOTP 设置 URI 包含无效密钥。"
        case (.scannedQRCode, .invalidDigits):
            return "扫描到的二维码使用了不支持的 TOTP 位数。"
        case (.manualURI, .invalidDigits):
            return "TOTP 设置 URI 使用了不支持的位数。"
        case (.scannedQRCode, .invalidPeriod):
            return "扫描到的二维码使用了不支持的 TOTP 周期。"
        case (.manualURI, .invalidPeriod):
            return "TOTP 设置 URI 使用了不支持的周期。"
        case (.scannedQRCode, .invalidAlgorithm):
            return "扫描到的二维码使用了不支持的 TOTP 算法。"
        case (.manualURI, .invalidAlgorithm):
            return "TOTP 设置 URI 使用了不支持的算法。"
        }
    }

    func selectTotpEntryForEditing(_ entry: LocalTotpEntry) {
        recordUserActivity()
        editingTotpEntryID = entry.id
        editingTotpTitle = entry.title
        editingTotpSecret = entry.secret
        editingTotpIssuer = entry.issuer
        editingTotpAccountName = entry.accountName
        editingTotpPeriod = entry.period
        editingTotpDigits = entry.digits
        editingTotpAlgorithm = entry.algorithm
        editingTotpFavorite = entry.favorite
    }

    func updateSelectedTotpEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingTotpEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let entry = try entryRepository.updateTotpEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalTotpEntryDraft(
                    title: editingTotpTitle,
                    secret: editingTotpSecret,
                    issuer: editingTotpIssuer,
                    accountName: editingTotpAccountName,
                    period: editingTotpPeriod,
                    digits: editingTotpDigits,
                    algorithm: editingTotpAlgorithm,
                    otpType: "TOTP",
                    counter: 0
                )
            )
            totpEntries = try entryRepository.listTotpEntries(projectID: projectID)
            deletedTotpEntries = try entryRepository.listDeletedTotpEntries(projectID: projectID)
            selectTotpEntryForEditing(entry)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .totp,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedTotpFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingTotpEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setTotpEntryFavorite(
                projectID: projectID,
                entryID: entryID,
                favorite: favorite
            )
            totpEntries = try entryRepository.listTotpEntries(projectID: projectID)
            selectTotpEntryForEditing(updated)
            entryOperationState = .succeeded(favorite ? "已收藏 \(updated.title)" : "已取消收藏 \(updated.title)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedTotpEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingTotpEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingTotpTitle
            try entryRepository.deleteTotpEntry(projectID: projectID, entryID: entryID)
            totpEntries = try entryRepository.listTotpEntries(projectID: projectID)
            deletedTotpEntries = try entryRepository.listDeletedTotpEntries(projectID: projectID)
            clearEditingTotpEntry()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .totp,
                itemID: entryID,
                itemTitle: deletedTitle
            )
            entryOperationState = .succeeded("已删除 \(deletedTitle)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func restoreTotpEntry(_ entry: LocalTotpEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreTotpEntry(
                projectID: projectID,
                entryID: entry.id
            )
            totpEntries = try entryRepository.listTotpEntries(projectID: projectID)
            deletedTotpEntries = try entryRepository.listDeletedTotpEntries(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .totp,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded("已恢复 \(restored.title)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func createCardEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project: LocalVaultProject
            if let activeProject {
                project = activeProject
            } else {
                project = try entryRepository.createProject(title: projectTitle)
                activeProject = project
            }
            let entry = try entryRepository.createCardEntry(
                projectID: project.id,
                draft: LocalCardEntryDraft(
                    title: cardTitle,
                    cardholderName: cardholderName,
                    number: cardNumber,
                    expiryMonth: cardExpiryMonth,
                    expiryYear: cardExpiryYear,
                    cvv: cardCVV,
                    issuer: cardIssuer,
                    network: cardNetwork,
                    notes: cardNotes
                )
            )
            cardNumber = ""
            cardCVV = ""
            cardEntries = try entryRepository.listCardEntries(projectID: project.id)
            deletedCardEntries = try entryRepository.listDeletedCardEntries(projectID: project.id)
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .card,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            cardNumber = ""
            cardCVV = ""
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func selectCardEntryForEditing(_ entry: LocalCardEntry) {
        recordUserActivity()
        editingCardEntryID = entry.id
        editingCardTitle = entry.title
        editingCardholderName = entry.cardholderName
        editingCardNumber = entry.number
        editingCardExpiryMonth = entry.expiryMonth
        editingCardExpiryYear = entry.expiryYear
        editingCardCVV = entry.cvv
        editingCardIssuer = entry.issuer
        editingCardNetwork = entry.network
        editingCardNotes = entry.notes
        editingCardFavorite = entry.favorite
    }

    func updateSelectedCardEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingCardEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let entry = try entryRepository.updateCardEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalCardEntryDraft(
                    title: editingCardTitle,
                    cardholderName: editingCardholderName,
                    number: editingCardNumber,
                    expiryMonth: editingCardExpiryMonth,
                    expiryYear: editingCardExpiryYear,
                    cvv: editingCardCVV,
                    issuer: editingCardIssuer,
                    network: editingCardNetwork,
                    notes: editingCardNotes
                )
            )
            cardEntries = try entryRepository.listCardEntries(projectID: projectID)
            deletedCardEntries = try entryRepository.listDeletedCardEntries(projectID: projectID)
            selectCardEntryForEditing(entry)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .card,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedCardFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingCardEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setCardEntryFavorite(
                projectID: projectID,
                entryID: entryID,
                favorite: favorite
            )
            cardEntries = try entryRepository.listCardEntries(projectID: projectID)
            selectCardEntryForEditing(updated)
            entryOperationState = .succeeded(favorite ? "已收藏 \(updated.title)" : "已取消收藏 \(updated.title)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedCardEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingCardEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingCardTitle
            try entryRepository.deleteCardEntry(projectID: projectID, entryID: entryID)
            cardEntries = try entryRepository.listCardEntries(projectID: projectID)
            deletedCardEntries = try entryRepository.listDeletedCardEntries(projectID: projectID)
            clearEditingCardEntry()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .card,
                itemID: entryID,
                itemTitle: deletedTitle
            )
            entryOperationState = .succeeded("已删除 \(deletedTitle)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func restoreCardEntry(_ entry: LocalCardEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreCardEntry(
                projectID: projectID,
                entryID: entry.id
            )
            cardEntries = try entryRepository.listCardEntries(projectID: projectID)
            deletedCardEntries = try entryRepository.listDeletedCardEntries(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .card,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded("已恢复 \(restored.title)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func createIdentityEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project: LocalVaultProject
            if let activeProject {
                project = activeProject
            } else {
                project = try entryRepository.createProject(title: projectTitle)
                activeProject = project
            }
            let entry = try entryRepository.createIdentityEntry(
                projectID: project.id,
                draft: LocalIdentityEntryDraft(
                    title: identityTitle,
                    documentType: identityDocumentType,
                    fullName: identityFullName,
                    documentNumber: identityDocumentNumber,
                    issuer: identityIssuer,
                    country: identityCountry,
                    issueDate: identityIssueDate,
                    expiryDate: identityExpiryDate,
                    notes: identityNotes
                )
            )
            identityEntries = try entryRepository.listIdentityEntries(projectID: project.id)
            deletedIdentityEntries = try entryRepository.listDeletedIdentityEntries(projectID: project.id)
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .identity,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func selectIdentityEntryForEditing(_ entry: LocalIdentityEntry) {
        recordUserActivity()
        editingIdentityEntryID = entry.id
        editingIdentityTitle = entry.title
        editingIdentityDocumentType = entry.documentType
        editingIdentityFullName = entry.fullName
        editingIdentityDocumentNumber = entry.documentNumber
        editingIdentityIssuer = entry.issuer
        editingIdentityCountry = entry.country
        editingIdentityIssueDate = entry.issueDate
        editingIdentityExpiryDate = entry.expiryDate
        editingIdentityNotes = entry.notes
        editingIdentityFavorite = entry.favorite
    }

    func updateSelectedIdentityEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingIdentityEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let entry = try entryRepository.updateIdentityEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalIdentityEntryDraft(
                    title: editingIdentityTitle,
                    documentType: editingIdentityDocumentType,
                    fullName: editingIdentityFullName,
                    documentNumber: editingIdentityDocumentNumber,
                    issuer: editingIdentityIssuer,
                    country: editingIdentityCountry,
                    issueDate: editingIdentityIssueDate,
                    expiryDate: editingIdentityExpiryDate,
                    notes: editingIdentityNotes
                )
            )
            identityEntries = try entryRepository.listIdentityEntries(projectID: projectID)
            deletedIdentityEntries = try entryRepository.listDeletedIdentityEntries(projectID: projectID)
            selectIdentityEntryForEditing(entry)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .identity,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedIdentityFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingIdentityEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setIdentityEntryFavorite(
                projectID: projectID,
                entryID: entryID,
                favorite: favorite
            )
            identityEntries = try entryRepository.listIdentityEntries(projectID: projectID)
            selectIdentityEntryForEditing(updated)
            entryOperationState = .succeeded(favorite ? "已收藏 \(updated.title)" : "已取消收藏 \(updated.title)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedIdentityEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingIdentityEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingIdentityTitle
            try entryRepository.deleteIdentityEntry(projectID: projectID, entryID: entryID)
            identityEntries = try entryRepository.listIdentityEntries(projectID: projectID)
            deletedIdentityEntries = try entryRepository.listDeletedIdentityEntries(projectID: projectID)
            clearEditingIdentityEntry()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .identity,
                itemID: entryID,
                itemTitle: deletedTitle
            )
            entryOperationState = .succeeded("已删除 \(deletedTitle)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func restoreIdentityEntry(_ entry: LocalIdentityEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreIdentityEntry(
                projectID: projectID,
                entryID: entry.id
            )
            identityEntries = try entryRepository.listIdentityEntries(projectID: projectID)
            deletedIdentityEntries = try entryRepository.listDeletedIdentityEntries(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .identity,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded("已恢复 \(restored.title)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func createPasskeyEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project: LocalVaultProject
            if let activeProject {
                project = activeProject
            } else {
                project = try entryRepository.createProject(title: projectTitle)
                activeProject = project
            }
            let entry = try entryRepository.createPasskeyEntry(
                projectID: project.id,
                draft: LocalPasskeyEntryDraft(
                    title: passkeyTitle,
                    relyingPartyID: passkeyRelyingPartyID,
                    username: passkeyUsername,
                    userHandle: passkeyUserHandle,
                    credentialID: passkeyCredentialID,
                    publicKeyCOSE: passkeyPublicKeyCOSE,
                    privateKeyReference: passkeyPrivateKeyReference,
                    notes: passkeyNotes
                )
            )
            passkeyPrivateKeyReference = ""
            passkeyEntries = try entryRepository.listPasskeyEntries(projectID: project.id)
            deletedPasskeyEntries = try entryRepository.listDeletedPasskeyEntries(projectID: project.id)
            try refreshAutoFillEncryptedIndexIfConfigured()
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .passkey,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func recordSystemPasskeyRegistration(
        _ result: AppSystemPasskeyRegistrationResult,
        projectTitle: String
    ) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project: LocalVaultProject
            if let activeProject {
                project = activeProject
            } else {
                project = try entryRepository.createProject(title: projectTitle)
                activeProject = project
            }

            let entry = try entryRepository.createPasskeyEntry(
                projectID: project.id,
                draft: result.metadataDraft
            )
            passkeyCredentialID = ""
            passkeyPublicKeyCOSE = ""
            passkeyPrivateKeyReference = ""
            passkeyEntries = try entryRepository.listPasskeyEntries(projectID: project.id)
            deletedPasskeyEntries = try entryRepository.listDeletedPasskeyEntries(projectID: project.id)
            try refreshAutoFillEncryptedIndexIfConfigured()
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .passkey,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded("Passkey 已保存：\(entry.title)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func importPendingSystemPasskeyRegistrations(
        inboxStore: AppSystemPasskeyRegistrationInboxStore,
        projectTitle: String
    ) throws -> Int {
        guard vaultState == .unlocked else {
            throw AppAutoFillIndexError.vaultLocked
        }
        let registrations = try inboxStore.loadPendingRegistrations()
        guard !registrations.isEmpty else {
            return 0
        }

        for registration in registrations {
            try recordSystemPasskeyRegistration(
                registration.registrationResult,
                projectTitle: projectTitle
            )
        }
        try inboxStore.clearPendingRegistrations()
        return registrations.count
    }

    func selectPasskeyEntryForEditing(_ entry: LocalPasskeyEntry) {
        recordUserActivity()
        editingPasskeyEntryID = entry.id
        editingPasskeyTitle = entry.title
        editingPasskeyRelyingPartyID = entry.relyingPartyID
        editingPasskeyUsername = entry.username
        editingPasskeyUserHandle = entry.userHandle
        editingPasskeyCredentialID = entry.credentialID
        editingPasskeyPublicKeyCOSE = entry.publicKeyCOSE
        editingPasskeyPrivateKeyReference = entry.privateKeyReference
        editingPasskeyNotes = entry.notes
        editingPasskeyFavorite = entry.favorite
    }

    func updateSelectedPasskeyEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingPasskeyEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let entry = try entryRepository.updatePasskeyEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalPasskeyEntryDraft(
                    title: editingPasskeyTitle,
                    relyingPartyID: editingPasskeyRelyingPartyID,
                    username: editingPasskeyUsername,
                    userHandle: editingPasskeyUserHandle,
                    credentialID: editingPasskeyCredentialID,
                    publicKeyCOSE: editingPasskeyPublicKeyCOSE,
                    privateKeyReference: editingPasskeyPrivateKeyReference,
                    notes: editingPasskeyNotes
                )
            )
            passkeyEntries = try entryRepository.listPasskeyEntries(projectID: projectID)
            deletedPasskeyEntries = try entryRepository.listDeletedPasskeyEntries(projectID: projectID)
            selectPasskeyEntryForEditing(entry)
            try refreshAutoFillEncryptedIndexIfConfigured()
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .passkey,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedPasskeyFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingPasskeyEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setPasskeyEntryFavorite(
                projectID: projectID,
                entryID: entryID,
                favorite: favorite
            )
            passkeyEntries = try entryRepository.listPasskeyEntries(projectID: projectID)
            selectPasskeyEntryForEditing(updated)
            try refreshAutoFillEncryptedIndexIfConfigured()
            entryOperationState = .succeeded(favorite ? "已收藏 \(updated.title)" : "已取消收藏 \(updated.title)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedPasskeyEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingPasskeyEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingPasskeyTitle
            try entryRepository.deletePasskeyEntry(projectID: projectID, entryID: entryID)
            passkeyEntries = try entryRepository.listPasskeyEntries(projectID: projectID)
            deletedPasskeyEntries = try entryRepository.listDeletedPasskeyEntries(projectID: projectID)
            clearEditingPasskeyEntry()
            try refreshAutoFillEncryptedIndexIfConfigured()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .passkey,
                itemID: entryID,
                itemTitle: deletedTitle
            )
            entryOperationState = .succeeded("已删除 \(deletedTitle)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func restorePasskeyEntry(_ entry: LocalPasskeyEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restorePasskeyEntry(
                projectID: projectID,
                entryID: entry.id
            )
            passkeyEntries = try entryRepository.listPasskeyEntries(projectID: projectID)
            deletedPasskeyEntries = try entryRepository.listDeletedPasskeyEntries(projectID: projectID)
            try refreshAutoFillEncryptedIndexIfConfigured()
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .passkey,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded("已恢复 \(restored.title)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func createSshKeyEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project = try ensureActiveProject(projectTitle: projectTitle, entryRepository: entryRepository)
            let entry = try entryRepository.createSshKeyEntry(
                projectID: project.id,
                draft: LocalSshKeyEntryDraft(
                    title: sshKeyTitle,
                    username: sshKeyUsername,
                    host: sshKeyHost,
                    publicKey: sshKeyPublicKey,
                    privateKeyReference: sshKeyPrivateKeyReference,
                    passphraseHint: sshKeyPassphraseHint,
                    notes: sshKeyNotes
                )
            )
            sshKeyPrivateKeyReference = ""
            sshKeyEntries = try entryRepository.listSshKeyEntries(projectID: project.id)
            deletedSshKeyEntries = try entryRepository.listDeletedSshKeyEntries(projectID: project.id)
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .sshKey,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func selectSshKeyEntryForEditing(_ entry: LocalSshKeyEntry) {
        recordUserActivity()
        editingSshKeyEntryID = entry.id
        editingSshKeyTitle = entry.title
        editingSshKeyUsername = entry.username
        editingSshKeyHost = entry.host
        editingSshKeyPublicKey = entry.publicKey
        editingSshKeyPrivateKeyReference = entry.privateKeyReference
        editingSshKeyPassphraseHint = entry.passphraseHint
        editingSshKeyNotes = entry.notes
        editingSshKeyFavorite = entry.favorite
    }

    func updateSelectedSshKeyEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingSshKeyEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let entry = try entryRepository.updateSshKeyEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalSshKeyEntryDraft(
                    title: editingSshKeyTitle,
                    username: editingSshKeyUsername,
                    host: editingSshKeyHost,
                    publicKey: editingSshKeyPublicKey,
                    privateKeyReference: editingSshKeyPrivateKeyReference,
                    passphraseHint: editingSshKeyPassphraseHint,
                    notes: editingSshKeyNotes
                )
            )
            sshKeyEntries = try entryRepository.listSshKeyEntries(projectID: projectID)
            deletedSshKeyEntries = try entryRepository.listDeletedSshKeyEntries(projectID: projectID)
            selectSshKeyEntryForEditing(entry)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .sshKey,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedSshKeyFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingSshKeyEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setSshKeyEntryFavorite(projectID: projectID, entryID: entryID, favorite: favorite)
            sshKeyEntries = try entryRepository.listSshKeyEntries(projectID: projectID)
            selectSshKeyEntryForEditing(updated)
            entryOperationState = .succeeded(favorite ? "已收藏 \(updated.title)" : "已取消收藏 \(updated.title)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedSshKeyEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingSshKeyEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingSshKeyTitle
            try entryRepository.deleteSshKeyEntry(projectID: projectID, entryID: entryID)
            sshKeyEntries = try entryRepository.listSshKeyEntries(projectID: projectID)
            deletedSshKeyEntries = try entryRepository.listDeletedSshKeyEntries(projectID: projectID)
            clearEditingSshKeyEntry()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .sshKey,
                itemID: entryID,
                itemTitle: deletedTitle
            )
            entryOperationState = .succeeded("已删除 \(deletedTitle)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func restoreSshKeyEntry(_ entry: LocalSshKeyEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreSshKeyEntry(projectID: projectID, entryID: entry.id)
            sshKeyEntries = try entryRepository.listSshKeyEntries(projectID: projectID)
            deletedSshKeyEntries = try entryRepository.listDeletedSshKeyEntries(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .sshKey,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded("已恢复 \(restored.title)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func createApiTokenEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project = try ensureActiveProject(projectTitle: projectTitle, entryRepository: entryRepository)
            let entry = try entryRepository.createApiTokenEntry(
                projectID: project.id,
                draft: LocalApiTokenEntryDraft(
                    title: apiTokenTitle,
                    issuer: apiTokenIssuer,
                    accountName: apiTokenAccountName,
                    token: apiTokenToken,
                    scopes: apiTokenScopes,
                    expiresAt: apiTokenExpiresAt,
                    notes: apiTokenNotes
                )
            )
            apiTokenToken = ""
            apiTokenEntries = try entryRepository.listApiTokenEntries(projectID: project.id)
            deletedApiTokenEntries = try entryRepository.listDeletedApiTokenEntries(projectID: project.id)
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .apiToken,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func selectApiTokenEntryForEditing(_ entry: LocalApiTokenEntry) {
        recordUserActivity()
        editingApiTokenEntryID = entry.id
        editingApiTokenTitle = entry.title
        editingApiTokenIssuer = entry.issuer
        editingApiTokenAccountName = entry.accountName
        editingApiTokenToken = entry.token
        editingApiTokenScopes = entry.scopes
        editingApiTokenExpiresAt = entry.expiresAt
        editingApiTokenNotes = entry.notes
        editingApiTokenFavorite = entry.favorite
    }

    func updateSelectedApiTokenEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingApiTokenEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let entry = try entryRepository.updateApiTokenEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalApiTokenEntryDraft(
                    title: editingApiTokenTitle,
                    issuer: editingApiTokenIssuer,
                    accountName: editingApiTokenAccountName,
                    token: editingApiTokenToken,
                    scopes: editingApiTokenScopes,
                    expiresAt: editingApiTokenExpiresAt,
                    notes: editingApiTokenNotes
                )
            )
            apiTokenEntries = try entryRepository.listApiTokenEntries(projectID: projectID)
            deletedApiTokenEntries = try entryRepository.listDeletedApiTokenEntries(projectID: projectID)
            selectApiTokenEntryForEditing(entry)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .apiToken,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedApiTokenFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingApiTokenEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setApiTokenEntryFavorite(projectID: projectID, entryID: entryID, favorite: favorite)
            apiTokenEntries = try entryRepository.listApiTokenEntries(projectID: projectID)
            selectApiTokenEntryForEditing(updated)
            entryOperationState = .succeeded(favorite ? "已收藏 \(updated.title)" : "已取消收藏 \(updated.title)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedApiTokenEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingApiTokenEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingApiTokenTitle
            try entryRepository.deleteApiTokenEntry(projectID: projectID, entryID: entryID)
            apiTokenEntries = try entryRepository.listApiTokenEntries(projectID: projectID)
            deletedApiTokenEntries = try entryRepository.listDeletedApiTokenEntries(projectID: projectID)
            clearEditingApiTokenEntry()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .apiToken,
                itemID: entryID,
                itemTitle: deletedTitle
            )
            entryOperationState = .succeeded("已删除 \(deletedTitle)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func restoreApiTokenEntry(_ entry: LocalApiTokenEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreApiTokenEntry(projectID: projectID, entryID: entry.id)
            apiTokenEntries = try entryRepository.listApiTokenEntries(projectID: projectID)
            deletedApiTokenEntries = try entryRepository.listDeletedApiTokenEntries(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .apiToken,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded("已恢复 \(restored.title)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func createWifiEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project = try ensureActiveProject(projectTitle: projectTitle, entryRepository: entryRepository)
            let entry = try entryRepository.createWifiEntry(
                projectID: project.id,
                draft: LocalWifiEntryDraft(
                    title: wifiTitle,
                    ssid: wifiSSID,
                    securityType: wifiSecurityType,
                    password: wifiPassword,
                    hidden: wifiHidden,
                    notes: wifiNotes
                )
            )
            wifiPassword = ""
            wifiEntries = try entryRepository.listWifiEntries(projectID: project.id)
            deletedWifiEntries = try entryRepository.listDeletedWifiEntries(projectID: project.id)
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .wifi,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func selectWifiEntryForEditing(_ entry: LocalWifiEntry) {
        recordUserActivity()
        editingWifiEntryID = entry.id
        editingWifiTitle = entry.title
        editingWifiSSID = entry.ssid
        editingWifiSecurityType = entry.securityType
        editingWifiPassword = entry.password
        editingWifiHidden = entry.hidden
        editingWifiNotes = entry.notes
        editingWifiFavorite = entry.favorite
    }

    func updateSelectedWifiEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingWifiEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let entry = try entryRepository.updateWifiEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalWifiEntryDraft(
                    title: editingWifiTitle,
                    ssid: editingWifiSSID,
                    securityType: editingWifiSecurityType,
                    password: editingWifiPassword,
                    hidden: editingWifiHidden,
                    notes: editingWifiNotes
                )
            )
            wifiEntries = try entryRepository.listWifiEntries(projectID: projectID)
            deletedWifiEntries = try entryRepository.listDeletedWifiEntries(projectID: projectID)
            selectWifiEntryForEditing(entry)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .wifi,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedWifiFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingWifiEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setWifiEntryFavorite(projectID: projectID, entryID: entryID, favorite: favorite)
            wifiEntries = try entryRepository.listWifiEntries(projectID: projectID)
            selectWifiEntryForEditing(updated)
            entryOperationState = .succeeded(favorite ? "已收藏 \(updated.title)" : "已取消收藏 \(updated.title)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedWifiEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingWifiEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingWifiTitle
            try entryRepository.deleteWifiEntry(projectID: projectID, entryID: entryID)
            wifiEntries = try entryRepository.listWifiEntries(projectID: projectID)
            deletedWifiEntries = try entryRepository.listDeletedWifiEntries(projectID: projectID)
            clearEditingWifiEntry()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .wifi,
                itemID: entryID,
                itemTitle: deletedTitle
            )
            entryOperationState = .succeeded("已删除 \(deletedTitle)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func restoreWifiEntry(_ entry: LocalWifiEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreWifiEntry(projectID: projectID, entryID: entry.id)
            wifiEntries = try entryRepository.listWifiEntries(projectID: projectID)
            deletedWifiEntries = try entryRepository.listDeletedWifiEntries(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .wifi,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded("已恢复 \(restored.title)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func createSendEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project = try ensureActiveProject(projectTitle: projectTitle, entryRepository: entryRepository)
            let entry = try entryRepository.createSendEntry(
                projectID: project.id,
                draft: LocalSendEntryDraft(
                    title: sendTitle,
                    body: sendBody,
                    expiresAt: sendExpiresAt,
                    maxViews: sendMaxViews,
                    notes: sendNotes
                )
            )
            sendBody = ""
            sendEntries = try entryRepository.listSendEntries(projectID: project.id)
            deletedSendEntries = try entryRepository.listDeletedSendEntries(projectID: project.id)
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .send,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func selectSendEntryForEditing(_ entry: LocalSendEntry) {
        recordUserActivity()
        editingSendEntryID = entry.id
        editingSendTitle = entry.title
        editingSendBody = entry.body
        editingSendExpiresAt = entry.expiresAt
        editingSendMaxViews = entry.maxViews
        editingSendNotes = entry.notes
        editingSendFavorite = entry.favorite
    }

    func updateSelectedSendEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingSendEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let entry = try entryRepository.updateSendEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalSendEntryDraft(
                    title: editingSendTitle,
                    body: editingSendBody,
                    expiresAt: editingSendExpiresAt,
                    maxViews: editingSendMaxViews,
                    notes: editingSendNotes
                )
            )
            sendEntries = try entryRepository.listSendEntries(projectID: projectID)
            deletedSendEntries = try entryRepository.listDeletedSendEntries(projectID: projectID)
            selectSendEntryForEditing(entry)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .send,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedSendFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingSendEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setSendEntryFavorite(projectID: projectID, entryID: entryID, favorite: favorite)
            sendEntries = try entryRepository.listSendEntries(projectID: projectID)
            selectSendEntryForEditing(updated)
            entryOperationState = .succeeded(favorite ? "已收藏 \(updated.title)" : "已取消收藏 \(updated.title)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedSendEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingSendEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingSendTitle
            try entryRepository.deleteSendEntry(projectID: projectID, entryID: entryID)
            sendEntries = try entryRepository.listSendEntries(projectID: projectID)
            deletedSendEntries = try entryRepository.listDeletedSendEntries(projectID: projectID)
            clearEditingSendEntry()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .send,
                itemID: entryID,
                itemTitle: deletedTitle
            )
            entryOperationState = .succeeded("已删除 \(deletedTitle)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func restoreSendEntry(_ entry: LocalSendEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreSendEntry(projectID: projectID, entryID: entry.id)
            sendEntries = try entryRepository.listSendEntries(projectID: projectID)
            deletedSendEntries = try entryRepository.listDeletedSendEntries(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .send,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded("已恢复 \(restored.title)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteAttachmentEntry(_ entry: LocalAttachmentMetadata) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            try entryRepository.deleteAttachmentMetadata(projectID: projectID, attachmentID: entry.id)
            attachmentEntries = try entryRepository.listAttachmentMetadata(projectID: projectID)
            deletedAttachmentEntries = try entryRepository.listDeletedAttachmentMetadata(projectID: projectID)
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .attachmentRef,
                itemID: entry.id,
                itemTitle: entry.fileName
            )
            entryOperationState = .succeeded("已删除 \(entry.fileName)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func restoreAttachmentEntry(_ entry: LocalAttachmentMetadata) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreAttachmentMetadata(projectID: projectID, attachmentID: entry.id)
            attachmentEntries = try entryRepository.listAttachmentMetadata(projectID: projectID)
            deletedAttachmentEntries = try entryRepository.listDeletedAttachmentMetadata(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .attachmentRef,
                itemID: restored.id,
                itemTitle: restored.fileName
            )
            entryOperationState = .succeeded("已恢复 \(restored.fileName)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func refreshExtendedParityEntries() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            sshKeyEntries = try entryRepository.listSshKeyEntries(projectID: projectID)
            deletedSshKeyEntries = try entryRepository.listDeletedSshKeyEntries(projectID: projectID)
            apiTokenEntries = try entryRepository.listApiTokenEntries(projectID: projectID)
            deletedApiTokenEntries = try entryRepository.listDeletedApiTokenEntries(projectID: projectID)
            wifiEntries = try entryRepository.listWifiEntries(projectID: projectID)
            deletedWifiEntries = try entryRepository.listDeletedWifiEntries(projectID: projectID)
            sendEntries = try entryRepository.listSendEntries(projectID: projectID)
            deletedSendEntries = try entryRepository.listDeletedSendEntries(projectID: projectID)
            attachmentEntries = try entryRepository.listAttachmentMetadata(projectID: projectID)
            deletedAttachmentEntries = try entryRepository.listDeletedAttachmentMetadata(projectID: projectID)
            entryOperationState = .succeeded("已刷新扩展通行条目")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func previewCSVImport(_ csv: String) -> CSVImportPreview {
        recordUserActivity()
        let report = VaultCSVCodec.importItems(from: csv)
        let preview = CSVImportPreview(report: report)
        csvImportPreview = preview
        androidBackupImportPreview = nil
        clearKeePassImportState()
        entryOperationState = .succeeded("CSV 预览：\(report.items.count) 项可导入，\(report.issues.count) 个问题")
        return preview
    }

    func previewCSVImport(from fileURL: URL) throws -> CSVImportPreview {
        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        let csv = try String(contentsOf: fileURL, encoding: .utf8)
        return previewCSVImport(csv)
    }

    func confirmCSVImport(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let preview = csvImportPreview else {
                throw LocalVaultRepositoryError.invalidEntryPayload
            }
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let project = try ensureActiveProject(projectTitle: projectTitle, entryRepository: entryRepository)
            for item in preview.items {
                _ = try createCSVImportedItem(item, projectID: project.id, entryRepository: entryRepository)
            }
            try refreshAllEntryLists(projectID: project.id, entryRepository: entryRepository)
            try refreshAutoFillEncryptedIndexIfConfigured()
            csvImportPreview = nil
            entryOperationState = .succeeded("CSV 已导入 \(preview.items.count) 项")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func previewKeePassImport(
        _ data: Data,
        fileName: String? = nil
    ) throws -> KeePassImportPreview {
        recordUserActivity()
        let report = KeePassFormatInspector.inspect(data, sourceName: fileName)
        if let issue = report.issue {
            clearKeePassImportState()
            csvImportPreview = nil
            androidBackupImportPreview = nil
            entryOperationState = .failed(issue.message)
            throw KeePassOperationError(code: issue.code, message: issue.message)
        }

        let preview = KeePassImportPreview(report: report, unlockPreflight: nil)
        keePassImportPreview = preview
        keePassPendingDatabaseData = data
        keePassPendingDatabaseName = fileName
        keePassSourceFileURL = nil
        keePassCloudFileSource = nil
        keePassReadOnlySnapshot = nil
        keePassReadOnlyImportPlan = nil
        keePassLastMetadataImportReferences = []
        keePassUnlockPassword = ""
        keePassKeyFileData = nil
        keePassKeyFileName = ""
        csvImportPreview = nil
        androidBackupImportPreview = nil
        clearPendingAndroidEncryptedBackup()
        entryOperationState = .succeeded("KeePass 预览：\(report.format.displayName) 数据库，等待密码或密钥文件解锁")
        return preview
    }

    func previewKeePassImport(from fileURL: URL) throws -> KeePassImportPreview {
        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: fileURL)
        let preview = try previewKeePassImport(data, fileName: fileURL.lastPathComponent)
        keePassSourceFileURL = fileURL
        return preview
    }

    func previewKeePassImport(
        fromCloudFile download: CloudFileDownload,
        provider kind: CloudFileProviderKind
    ) throws -> KeePassImportPreview {
        let fileName = sanitizedCloudFileName(download.item.name)
        let preview = try previewKeePassImport(download.data, fileName: fileName)
        keePassSourceFileURL = nil
        keePassCloudFileSource = AppKeePassCloudFileSource(
            provider: kind,
            itemID: download.item.id,
            fileName: fileName,
            revision: download.revision
        )
        cloudFileRestorePreview = AppCloudFileRestorePreview(
            provider: kind,
            download: download
        )
        downloadedCloudFileRestore = download
        return preview
    }

    func prepareKeePassUnlockPreflight(
        password: String? = nil,
        keyFile: Data? = nil,
        keyFileName: String? = nil
    ) throws -> KeePassUnlockPreflightReport {
        recordUserActivity()
        guard let databaseData = keePassPendingDatabaseData else {
            let message = "请先选择 KDBX 数据库文件"
            entryOperationState = .failed(message)
            throw KeePassOperationError(code: .formatUnsupported, message: message)
        }

        if let password {
            keePassUnlockPassword = password
        }
        if let keyFile {
            keePassKeyFileData = keyFile
        }
        if let keyFileName {
            keePassKeyFileName = sanitizedKeePassFileName(keyFileName) ?? ""
        }
        keePassReadOnlySnapshot = nil
        keePassReadOnlyImportPlan = nil
        keePassLastSuccessfulUnlockCredentials = nil

        let preflight = KeePassFormatInspector.prepareUnlock(
            databaseData,
            sourceName: keePassPendingDatabaseName,
            password: password ?? keePassUnlockPassword,
            keyFile: keyFile ?? keePassKeyFileData,
            keyFileName: keyFileName ?? keePassKeyFileName
        )

        if let issue = preflight.issue {
            entryOperationState = .failed(issue.message)
            throw KeePassOperationError(code: issue.code, message: issue.message)
        }

        if let preview = keePassImportPreview {
            keePassImportPreview = KeePassImportPreview(
                report: preview.report,
                unlockPreflight: preflight
            )
        }
        let version = preflight.headerSummary?.displayName ?? preflight.format.displayName
        entryOperationState = .succeeded("KeePass 解锁输入已准备：\(version)，\(preflight.credentials.displayName)")
        return preflight
    }

    func previewKeePassReadOnlyTree() throws -> KeePassReadOnlySnapshot {
        recordUserActivity()
        guard let databaseData = keePassPendingDatabaseData else {
            let message = "请先选择 KDBX 数据库文件"
            entryOperationState = .failed(message)
            throw KeePassOperationError(code: .formatUnsupported, message: message)
        }

        do {
            _ = try prepareKeePassUnlockPreflight()
            let (snapshot, successfulCredentials) = try readKeePassSnapshotTryingCredentialCandidates(
                database: databaseData,
                sourceName: keePassPendingDatabaseName,
                credentials: KeePassUnlockCredentials(
                    password: keePassUnlockPassword,
                    keyFile: keePassKeyFileData,
                    keyFileName: keePassKeyFileName
                )
            )
            keePassReadOnlySnapshot = snapshot
            keePassLastSuccessfulUnlockCredentials = successfulCredentials
            keePassReadOnlyImportPlan = nil
            entryOperationState = .succeeded("KeePass 只读预览：\(snapshot.displaySummary)")
            return snapshot
        } catch {
            keePassReadOnlySnapshot = nil
            keePassReadOnlyImportPlan = nil
            keePassLastSuccessfulUnlockCredentials = nil
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func previewKeePassReadOnlyImportPlan() throws -> KeePassReadOnlyImportPlan {
        recordUserActivity()

        do {
            let snapshot: KeePassReadOnlySnapshot
            if let existingSnapshot = keePassReadOnlySnapshot {
                snapshot = existingSnapshot
            } else {
                snapshot = try previewKeePassReadOnlyTree()
            }
            let plan = KeePassReadOnlyImportPlanner.plan(snapshot)
            keePassReadOnlyImportPlan = plan
            entryOperationState = .succeeded("KeePass 导入计划：\(plan.displaySummary)")
            return plan
        } catch {
            keePassReadOnlyImportPlan = nil
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func confirmKeePassReadOnlyImport(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            let plan: KeePassReadOnlyImportPlan
            if let existingPlan = keePassReadOnlyImportPlan {
                plan = existingPlan
            } else {
                plan = try previewKeePassReadOnlyImportPlan()
            }
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let vaultSession = try requireActiveVaultSession()

            var firstImportedProject: LocalVaultProject?
            var importedReferences: [AppKeePassImportedEntryReference] = []
            var importedTotpPlaceholderCount = 0
            var importedDecodedPasswordCount = 0
            var importedDecodedTotpSecretCount = 0
            var importedAttachmentPlaceholderCount = 0
            var importedDecodedAttachmentContentCount = 0
            var importedNotesFieldCount = 0
            var importedDeletedMetadataCount = 0
            for candidate in plan.candidates {
                let project = try ensureKeePassImportProject(
                    baseTitle: projectTitle,
                    groupPath: candidate.groupPath,
                    entryRepository: entryRepository
                )
                if firstImportedProject == nil {
                    firstImportedProject = project
                }
                let importedEntry = try entryRepository.createLoginEntry(
                    projectID: project.id,
                    draft: LocalLoginEntryDraft(
                        title: candidate.title,
                        username: candidate.username,
                        password: candidate.decodedPassword ?? "",
                        url: candidate.url,
                        notes: keePassLoginNotes(for: candidate)
                    )
                )
                if !candidate.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    !candidate.customFields.isEmpty {
                    importedNotesFieldCount += 1
                }
                if candidate.hasPassword && candidate.decodedPassword != nil {
                    importedDecodedPasswordCount += 1
                }
                let importedTotpEntryID: String?
                if candidate.hasTotp {
                    let importedTotpEntry = try entryRepository.createTotpEntry(
                        projectID: project.id,
                        draft: keePassTotpDraft(for: candidate)
                    )
                    importedTotpEntryID = importedTotpEntry.id
                    if candidate.decodedTotp == nil {
                        importedTotpPlaceholderCount += 1
                    } else {
                        importedDecodedTotpSecretCount += 1
                    }
                    if candidate.isDeleted {
                        try entryRepository.deleteTotpEntry(
                            projectID: project.id,
                            entryID: importedTotpEntry.id
                        )
                    }
                } else {
                    importedTotpEntryID = nil
                }
                var importedAttachmentEntryIDs: [String] = []
                for attachment in candidate.attachments {
                    let attachmentFileName = keePassAttachmentFileName(attachment)
                    let decodedAttachmentLocalPath: String?
                    if let decodedContent = attachment.decodedContent {
                        decodedAttachmentLocalPath = try androidBackupAttachmentBlobStore.saveEncryptedBlob(
                            decodedContent,
                            vaultID: vaultSession.handle.vaultID,
                            localPath: keePassDecodedAttachmentLocalPath(
                                attachment,
                                fileName: attachmentFileName
                            )
                        )
                        importedDecodedAttachmentContentCount += 1
                    } else {
                        decodedAttachmentLocalPath = nil
                    }
                    let importedAttachment = try entryRepository.createAttachmentMetadata(
                        projectID: project.id,
                        entryID: importedEntry.id,
                        fileName: attachmentFileName,
                        mediaType: attachment.mediaType,
                        originalSize: attachment.originalSize,
                        storedSize: Int64(attachment.decodedContent?.count ?? 0),
                        contentHash: attachment.contentHash,
                        storageMode: decodedAttachmentLocalPath == nil
                            ? "keepass-kdbx-placeholder"
                            : "keepass-kdbx-decoded-content",
                        source: "KeePass",
                        downloadState: decodedAttachmentLocalPath == nil
                            ? "pending-kdbx-decode"
                            : "downloaded",
                        localPath: decodedAttachmentLocalPath
                    )
                    importedAttachmentEntryIDs.append(importedAttachment.id)
                    if decodedAttachmentLocalPath == nil {
                        importedAttachmentPlaceholderCount += 1
                    }
                    if candidate.isDeleted {
                        try entryRepository.deleteAttachmentMetadata(
                            projectID: project.id,
                            attachmentID: importedAttachment.id
                        )
                    }
                }
                if candidate.isDeleted {
                    try entryRepository.deleteLoginEntry(
                        projectID: project.id,
                        entryID: importedEntry.id
                    )
                    importedDeletedMetadataCount += 1
                }
                importedReferences.append(
                    AppKeePassImportedEntryReference(
                        sourceEntryID: candidate.id,
                        sourceGroupID: candidate.groupID,
                        sourceGroupPath: candidate.groupPath,
                        importedLoginEntryID: importedEntry.id,
                        importedTotpEntryID: importedTotpEntryID,
                        importedProjectID: project.id,
                        importedAsDeleted: candidate.isDeleted,
                        importedAttachmentEntryIDs: importedAttachmentEntryIDs
                    )
                )
            }
            if let firstImportedProject {
                activeProject = firstImportedProject
            }
            if let activeProject {
                try refreshAllEntryLists(projectID: activeProject.id, entryRepository: entryRepository)
                selectedVaultQuickFilterID = "category-\(activeProject.id)"
            }
            try refreshAutoFillEncryptedIndexIfConfigured()
            keePassLastMetadataImportReferences = importedReferences
            clearKeePassImportState(preservingLastMetadataImportReferences: true)
            let pendingSummary = plan.pendingCapabilitySummary
            let importedDecodedContentCount = importedDecodedPasswordCount
                + importedDecodedTotpSecretCount
                + importedDecodedAttachmentContentCount
                + importedNotesFieldCount
            let pendingText = pendingSummary.isEmpty
                ? (importedDecodedContentCount > 0 ? "" : "，秘密字段待 KDBX 解码器接入")
                : "；\(pendingSummary)"
            let totpPlaceholderText = importedTotpPlaceholderCount > 0
                ? "，并创建 \(importedTotpPlaceholderCount) 个 TOTP 占位项"
                : ""
            let decodedPasswordText = importedDecodedPasswordCount > 0
                ? "，并导入 \(importedDecodedPasswordCount) 个密码字段"
                : ""
            let decodedTotpText = importedDecodedTotpSecretCount > 0
                ? "，并导入 \(importedDecodedTotpSecretCount) 个 TOTP 密钥"
                : ""
            let decodedAttachmentText = importedDecodedAttachmentContentCount > 0
                ? "，并导入 \(importedDecodedAttachmentContentCount) 个附件内容"
                : ""
            let notesFieldText = importedNotesFieldCount > 0
                ? "，并导入 \(importedNotesFieldCount) 项备注/自定义字段"
                : ""
            let attachmentPlaceholderText = importedAttachmentPlaceholderCount > 0
                ? "，并创建 \(importedAttachmentPlaceholderCount) 个附件占位项"
                : ""
            let deletedText = importedDeletedMetadataCount > 0
                ? "，并保留 \(importedDeletedMetadataCount) 项回收站元数据"
                : ""
            entryOperationState = .succeeded("KeePass 已导入 \(plan.candidateCount) 项元数据\(decodedPasswordText)\(decodedTotpText)\(decodedAttachmentText)\(notesFieldText)\(totpPlaceholderText)\(attachmentPlaceholderText)\(deletedText)\(pendingText)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func importKeePassKeyFile(from fileURL: URL) throws {
        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        keePassKeyFileData = try Data(contentsOf: fileURL)
        keePassKeyFileName = sanitizedKeePassFileName(fileURL.lastPathComponent) ?? "keyfile"
        keePassReadOnlySnapshot = nil
        keePassReadOnlyImportPlan = nil
        entryOperationState = .succeeded("KeePass 密钥文件已选择：\(keePassKeyFileName)")
    }

    func writeKeePassKdbx4Database(_ result: KeePassKdbx4WritebackResult) throws {
        try writeKeePassKdbxDatabase(AppKeePassKdbxWritebackResult(result))
    }

    private func writeKeePassKdbxDatabase(_ result: AppKeePassKdbxWritebackResult) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let sourceURL = keePassSourceFileURL else {
                throw AppKeePassKdbxWritebackError.sourceFileUnavailable
            }
            let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }
            try keePassKdbxFileWritebackService.replaceFile(
                at: sourceURL,
                with: result.database
            )
            keePassPendingDatabaseData = result.database
            keePassPendingDatabaseName = sourceURL.lastPathComponent
            entryOperationState = .succeeded(
                "KeePass 数据库已写回：\(result.entryCount) 个条目，\(result.attachmentCount) 个附件，\(result.database.count) bytes"
            )
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    private func makeKeePassReadOnlySnapshotWritebackResult() throws -> AppKeePassKdbxWritebackResult {
        let snapshot: KeePassReadOnlySnapshot
        if let existingSnapshot = keePassReadOnlySnapshot {
            snapshot = existingSnapshot
        } else {
            snapshot = try previewKeePassReadOnlyTree()
        }
        switch try currentKeePassKdbxEnvelope().headerSummary.formatVersion {
        case .kdbx3:
            return AppKeePassKdbxWritebackResult(
                try keePassKdbx3WritebackCoordinator.writeDatabase(
                    try makeKeePassKdbx3WritebackRequest(snapshot: snapshot)
                )
            )
        case .kdbx4:
            return AppKeePassKdbxWritebackResult(
                try keePassKdbx4WritebackCoordinator.writeDatabase(
                    try makeKeePassKdbx4WritebackRequest(snapshot: snapshot)
                )
            )
        case .unknown:
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "未知 KDBX 版本写回尚未接入。"
            )
        }
    }

    func writeKeePassReadOnlySnapshotBackToSource() throws -> AppKeePassKdbxWritebackResult {
        recordUserActivity()
        entryOperationState = .running

        do {
            let result = try makeKeePassReadOnlySnapshotWritebackResult()
            try writeKeePassKdbxDatabase(result)
            return result
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func writeKeePassReadOnlySnapshotBackToCloudSource() async throws -> AppKeePassKdbxWritebackResult {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let source = keePassCloudFileSource else {
                throw AppKeePassKdbxWritebackError.cloudSourceUnavailable
            }
            let result = try makeKeePassReadOnlySnapshotWritebackResult()
            cloudFileState = .running(source.provider)
            let provider = try cloudFileProvider(for: source.provider)
            let receipt = try await provider.overwriteFile(
                id: source.itemID,
                data: result.database,
                fileName: source.fileName,
                expectedRevision: source.revision
            )
            let fileName = sanitizedCloudFileName(receipt.name)
            keePassPendingDatabaseData = result.database
            keePassPendingDatabaseName = fileName
            keePassSourceFileURL = nil
            keePassCloudFileSource = AppKeePassCloudFileSource(
                provider: source.provider,
                itemID: source.itemID,
                fileName: fileName,
                revision: receipt.revision ?? source.revision
            )
            cloudFileState = .writeSucceeded(
                provider: source.provider,
                fileName: fileName,
                byteCount: receipt.byteCount
            )
            entryOperationState = .succeeded(
                "KeePass 云文件已写回：\(source.provider.displayName) \(fileName)，\(result.entryCount) 个条目，\(result.attachmentCount) 个附件，\(result.database.count) bytes"
            )
            return result
        } catch {
            if let source = keePassCloudFileSource {
                cloudFileState = .failed(readableCloudFileErrorMessage(for: error, provider: source.provider))
            }
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func keePassAttachmentEditCandidates(
        matching query: String = ""
    ) throws -> [AppKeePassAttachmentEditCandidate] {
        let snapshot: KeePassReadOnlySnapshot
        if let existingSnapshot = keePassReadOnlySnapshot {
            snapshot = existingSnapshot
        } else {
            snapshot = try previewKeePassReadOnlyTree()
        }
        let normalizedQuery = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return snapshot.entries
            .flatMap { entry in
                entry.attachments.map { attachment in
                    let fileName = sanitizedAttachmentPreviewFileName(attachment.fileName)
                    let searchableText = [
                        entry.title,
                        entry.username,
                        entry.groupPath,
                        fileName,
                        attachment.mediaType,
                        attachment.id
                    ]
                    .joined(separator: " ")
                    return AppKeePassAttachmentEditCandidate(
                        id: "\(entry.id)::\(attachment.id)",
                        entryID: entry.id,
                        attachmentID: attachment.id,
                        entryTitle: entry.title,
                        entryUsername: entry.username,
                        groupPath: entry.groupPath,
                        fileName: fileName,
                        mediaType: attachment.mediaType,
                        originalSize: attachment.originalSize,
                        isDeletedEntry: entry.isDeleted,
                        searchableText: searchableText
                    )
                }
            }
            .filter { candidate in
                normalizedQuery.isEmpty || candidate.searchableText.lowercased().contains(normalizedQuery)
            }
    }

    func replaceKeePassReadOnlyAttachmentContent(
        entryID: String,
        attachmentID: String,
        decodedContent content: Data,
        fileName: String? = nil,
        mediaType: String? = nil
    ) throws -> KeePassReadOnlySnapshot {
        recordUserActivity()
        entryOperationState = .running

        do {
            let snapshot: KeePassReadOnlySnapshot
            if let existingSnapshot = keePassReadOnlySnapshot {
                snapshot = existingSnapshot
            } else {
                snapshot = try previewKeePassReadOnlyTree()
            }
            guard let entryIndex = snapshot.entries.firstIndex(where: { $0.id == entryID }) else {
                throw AppKeePassSnapshotEditError.entryUnavailable
            }
            let entry = snapshot.entries[entryIndex]
            guard let attachmentIndex = entry.attachments.firstIndex(where: { $0.id == attachmentID }) else {
                throw AppKeePassSnapshotEditError.attachmentUnavailable
            }
            let attachment = entry.attachments[attachmentIndex]
            let updatedAttachment = KeePassReadOnlyAttachment(
                id: attachment.id,
                fileName: sanitizedAttachmentPreviewFileName(fileName ?? attachment.fileName),
                mediaType: mediaType ?? attachment.mediaType,
                originalSize: Int64(content.count),
                contentHash: "sha256:\(sha256Hex(content))",
                decodedContent: content
            )
            var updatedAttachments = entry.attachments
            updatedAttachments[attachmentIndex] = updatedAttachment
            let updatedEntry = KeePassReadOnlyEntry(
                id: entry.id,
                title: entry.title,
                username: entry.username,
                url: entry.url,
                groupPath: entry.groupPath,
                groupID: entry.groupID,
                originalGroupPath: entry.originalGroupPath,
                originalGroupID: entry.originalGroupID,
                notes: entry.notes,
                customFields: entry.customFields,
                hasPassword: entry.hasPassword,
                decodedPassword: entry.decodedPassword,
                hasTotp: entry.hasTotp,
                decodedTotp: entry.decodedTotp,
                attachmentCount: updatedAttachments.count,
                isDeleted: entry.isDeleted,
                attachments: updatedAttachments
            )
            var updatedEntries = snapshot.entries
            updatedEntries[entryIndex] = updatedEntry
            let updatedSnapshot = KeePassReadOnlySnapshot(
                sourceName: snapshot.sourceName,
                headerSummary: snapshot.headerSummary,
                groups: snapshot.groups,
                entries: updatedEntries
            )
            keePassReadOnlySnapshot = updatedSnapshot
            keePassReadOnlyImportPlan = nil
            entryOperationState = .succeeded(
                "KeePass 附件内容已替换：\(updatedAttachment.fileName) \(content.count) 字节"
            )
            return updatedSnapshot
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func addKeePassReadOnlyAttachmentContent(
        entryID: String,
        decodedContent content: Data,
        fileName: String,
        mediaType: String? = nil
    ) throws -> KeePassReadOnlySnapshot {
        recordUserActivity()
        entryOperationState = .running

        do {
            let snapshot: KeePassReadOnlySnapshot
            if let existingSnapshot = keePassReadOnlySnapshot {
                snapshot = existingSnapshot
            } else {
                snapshot = try previewKeePassReadOnlyTree()
            }
            guard let entryIndex = snapshot.entries.firstIndex(where: { $0.id == entryID }) else {
                throw AppKeePassSnapshotEditError.entryUnavailable
            }
            let entry = snapshot.entries[entryIndex]
            let sanitizedFileName = sanitizedAttachmentPreviewFileName(fileName)
            let attachment = KeePassReadOnlyAttachment(
                id: "ios-added-\(UUID().uuidString)",
                fileName: sanitizedFileName,
                mediaType: mediaType ?? "application/octet-stream",
                originalSize: Int64(content.count),
                contentHash: "sha256:\(sha256Hex(content))",
                decodedContent: content
            )
            let updatedAttachments = entry.attachments + [attachment]
            let updatedEntry = KeePassReadOnlyEntry(
                id: entry.id,
                title: entry.title,
                username: entry.username,
                url: entry.url,
                groupPath: entry.groupPath,
                groupID: entry.groupID,
                originalGroupPath: entry.originalGroupPath,
                originalGroupID: entry.originalGroupID,
                notes: entry.notes,
                customFields: entry.customFields,
                hasPassword: entry.hasPassword,
                decodedPassword: entry.decodedPassword,
                hasTotp: entry.hasTotp,
                decodedTotp: entry.decodedTotp,
                attachmentCount: updatedAttachments.count,
                isDeleted: entry.isDeleted,
                attachments: updatedAttachments
            )
            var updatedEntries = snapshot.entries
            updatedEntries[entryIndex] = updatedEntry
            let updatedSnapshot = KeePassReadOnlySnapshot(
                sourceName: snapshot.sourceName,
                headerSummary: snapshot.headerSummary,
                groups: snapshot.groups,
                entries: updatedEntries
            )
            keePassReadOnlySnapshot = updatedSnapshot
            keePassReadOnlyImportPlan = nil
            entryOperationState = .succeeded(
                "KeePass 附件已添加：\(sanitizedFileName) \(content.count) 字节"
            )
            return updatedSnapshot
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func addKeePassReadOnlyAttachmentContentFromFileAndWriteBack(
        entryID: String,
        fileURL: URL,
        mediaType: String? = nil
    ) throws -> AppKeePassKdbxWritebackResult {
        recordUserActivity()
        entryOperationState = .running

        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let content = try Data(contentsOf: fileURL)
            let fileName = sanitizedAttachmentPreviewFileName(fileURL.lastPathComponent)
            _ = try addKeePassReadOnlyAttachmentContent(
                entryID: entryID,
                decodedContent: content,
                fileName: fileName,
                mediaType: mediaType
            )
            let result = try writeKeePassReadOnlySnapshotBackToSource()
            entryOperationState = .succeeded(
                "KeePass 附件已添加并写回：\(fileName) \(content.count) 字节"
            )
            return result
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteKeePassReadOnlyAttachmentAndWriteBack(
        entryID: String,
        attachmentID: String
    ) throws -> AppKeePassKdbxWritebackResult {
        recordUserActivity()
        entryOperationState = .running

        do {
            let snapshot: KeePassReadOnlySnapshot
            if let existingSnapshot = keePassReadOnlySnapshot {
                snapshot = existingSnapshot
            } else {
                snapshot = try previewKeePassReadOnlyTree()
            }
            guard let entryIndex = snapshot.entries.firstIndex(where: { $0.id == entryID }) else {
                throw AppKeePassSnapshotEditError.entryUnavailable
            }
            let entry = snapshot.entries[entryIndex]
            guard let attachmentIndex = entry.attachments.firstIndex(where: { $0.id == attachmentID }) else {
                throw AppKeePassSnapshotEditError.attachmentUnavailable
            }
            let attachment = entry.attachments[attachmentIndex]
            var updatedAttachments = entry.attachments
            updatedAttachments.remove(at: attachmentIndex)
            let updatedEntry = KeePassReadOnlyEntry(
                id: entry.id,
                title: entry.title,
                username: entry.username,
                url: entry.url,
                groupPath: entry.groupPath,
                groupID: entry.groupID,
                originalGroupPath: entry.originalGroupPath,
                originalGroupID: entry.originalGroupID,
                notes: entry.notes,
                customFields: entry.customFields,
                hasPassword: entry.hasPassword,
                decodedPassword: entry.decodedPassword,
                hasTotp: entry.hasTotp,
                decodedTotp: entry.decodedTotp,
                attachmentCount: updatedAttachments.count,
                isDeleted: entry.isDeleted,
                attachments: updatedAttachments
            )
            var updatedEntries = snapshot.entries
            updatedEntries[entryIndex] = updatedEntry
            let updatedSnapshot = KeePassReadOnlySnapshot(
                sourceName: snapshot.sourceName,
                headerSummary: snapshot.headerSummary,
                groups: snapshot.groups,
                entries: updatedEntries
            )
            keePassReadOnlySnapshot = updatedSnapshot
            keePassReadOnlyImportPlan = nil
            let result = try writeKeePassReadOnlySnapshotBackToSource()
            entryOperationState = .succeeded(
                "KeePass 附件已删除并写回：\(sanitizedAttachmentPreviewFileName(attachment.fileName))"
            )
            return result
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func replaceKeePassReadOnlyAttachmentContentFromFileAndWriteBack(
        entryID: String,
        attachmentID: String,
        fileURL: URL,
        mediaType: String? = nil
    ) throws -> AppKeePassKdbxWritebackResult {
        recordUserActivity()
        entryOperationState = .running

        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let content = try Data(contentsOf: fileURL)
            let fileName = sanitizedAttachmentPreviewFileName(fileURL.lastPathComponent)
            _ = try replaceKeePassReadOnlyAttachmentContent(
                entryID: entryID,
                attachmentID: attachmentID,
                decodedContent: content,
                fileName: fileName,
                mediaType: mediaType
            )
            let result = try writeKeePassReadOnlySnapshotBackToSource()
            entryOperationState = .succeeded(
                "KeePass 附件已替换并写回：\(fileName) \(content.count) 字节"
            )
            return result
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func restoreKeePassReadOnlyRecycleBinEntryAndWriteBack(
        entryID: String,
        targetGroupID: String? = nil
    ) throws -> AppKeePassKdbxWritebackResult {
        recordUserActivity()
        entryOperationState = .running

        do {
            let snapshot: KeePassReadOnlySnapshot
            if let existingSnapshot = keePassReadOnlySnapshot {
                snapshot = existingSnapshot
            } else {
                snapshot = try previewKeePassReadOnlyTree()
            }
            guard let entryIndex = snapshot.entries.firstIndex(where: { $0.id == entryID }) else {
                throw AppKeePassSnapshotEditError.entryUnavailable
            }
            let entry = snapshot.entries[entryIndex]
            guard entry.isDeleted else {
                throw AppKeePassSnapshotEditError.entryNotInRecycleBin
            }
            let recycleBinGroupIDs = Set(snapshot.entries.compactMap { candidate in
                candidate.isDeleted ? candidate.groupID : nil
            })
            let targetGroup: KeePassReadOnlyGroup
            if let originalGroupID = entry.originalGroupID,
               let originalGroup = snapshot.groups.first(where: { group in
                   group.id == originalGroupID && !recycleBinGroupIDs.contains(group.id)
               }) {
                targetGroup = originalGroup
            } else if let originalGroupPath = entry.originalGroupPath,
                      let originalGroup = snapshot.groups.first(where: { group in
                          group.path == originalGroupPath && !recycleBinGroupIDs.contains(group.id)
                      }) {
                targetGroup = originalGroup
            } else if let targetGroupID {
                guard let explicitGroup = snapshot.groups.first(where: { $0.id == targetGroupID }),
                      !recycleBinGroupIDs.contains(explicitGroup.id) else {
                    throw AppKeePassSnapshotEditError.targetGroupUnavailable
                }
                targetGroup = explicitGroup
            } else if let rootGroup = snapshot.groups.first(where: { group in
                group.path == "/" && !recycleBinGroupIDs.contains(group.id)
            }) {
                targetGroup = rootGroup
            } else if let fallbackGroup = snapshot.groups.first(where: { group in
                !recycleBinGroupIDs.contains(group.id)
            }) {
                targetGroup = fallbackGroup
            } else {
                throw AppKeePassSnapshotEditError.targetGroupUnavailable
            }
            let restoredEntry = KeePassReadOnlyEntry(
                id: entry.id,
                title: entry.title,
                username: entry.username,
                url: entry.url,
                groupPath: targetGroup.path,
                groupID: targetGroup.id,
                notes: entry.notes,
                customFields: entry.customFields,
                hasPassword: entry.hasPassword,
                decodedPassword: entry.decodedPassword,
                hasTotp: entry.hasTotp,
                decodedTotp: entry.decodedTotp,
                attachmentCount: entry.attachmentCount,
                isDeleted: false,
                attachments: entry.attachments
            )
            var updatedEntries = snapshot.entries
            updatedEntries[entryIndex] = restoredEntry
            let updatedSnapshot = KeePassReadOnlySnapshot(
                sourceName: snapshot.sourceName,
                headerSummary: snapshot.headerSummary,
                groups: snapshot.groups,
                entries: updatedEntries
            )
            keePassReadOnlySnapshot = updatedSnapshot
            keePassReadOnlyImportPlan = nil
            let result = try writeKeePassReadOnlySnapshotBackToSource()
            let displayTitle = restoredEntry.title.isEmpty ? "未命名条目" : restoredEntry.title
            entryOperationState = .succeeded(
                "KeePass 回收站条目已还原并写回：\(displayTitle) -> \(targetGroup.path)"
            )
            return result
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func previewAndroidBackupImport(
        _ data: Data,
        fileName: String? = nil,
        decryptPassword: String? = nil
    ) throws -> AndroidBackupImportPreview {
        recordUserActivity()
        let report = try AndroidBackupCodec.importItems(
            from: data,
            fileName: fileName,
            decryptPassword: decryptPassword
        )
        if let encryptedIssue = report.issues.first(where: { $0.code == .encryptedBackupUnsupported }) {
            androidBackupImportPreview = nil
            csvImportPreview = nil
            clearKeePassImportState()
            entryOperationState = .failed(encryptedIssue.message)
            throw AppAndroidBackupImportError.unsupportedEncryptedBackup(encryptedIssue.message)
        }
        if let decryptIssue = report.issues.first(where: { $0.code == .encryptedBackupDecryptionFailed }) {
            androidBackupImportPreview = nil
            csvImportPreview = nil
            clearKeePassImportState()
            entryOperationState = .failed(decryptIssue.message)
            throw AppAndroidBackupImportError.encryptedBackupDecryptionFailed(decryptIssue.message)
        }
        let preview = AndroidBackupImportPreview(report: report)
        androidBackupImportPreview = preview
        csvImportPreview = nil
        clearKeePassImportState()
        clearPendingAndroidEncryptedBackup()
        let attachmentText = report.attachments.isEmpty ? "" : "，\(report.attachments.count) 个附件"
        entryOperationState = .succeeded("Android 备份预览：\(report.items.count) 项可导入\(attachmentText)，\(report.issues.count) 个问题")
        return preview
    }

    func previewAndroidBackupImport(from fileURL: URL) throws -> AndroidBackupImportPreview {
        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: fileURL)
        return try previewAndroidBackupImport(data, fileName: fileURL.lastPathComponent)
    }

    func prepareAndroidBackupImport(from fileURL: URL) throws -> AndroidBackupImportPreview? {
        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: fileURL)
        do {
            let preview = try previewAndroidBackupImport(data, fileName: fileURL.lastPathComponent)
            clearPendingAndroidEncryptedBackup()
            return preview
        } catch AppAndroidBackupImportError.unsupportedEncryptedBackup {
            pendingAndroidEncryptedBackupData = data
            pendingAndroidEncryptedBackupFileName = fileURL.lastPathComponent
            androidBackupDecryptPassword = ""
            entryOperationState = .failed("请输入 Android 加密备份密码。")
            return nil
        } catch {
            clearPendingAndroidEncryptedBackup()
            throw error
        }
    }

    func previewPendingAndroidEncryptedBackupImport() throws -> AndroidBackupImportPreview {
        recordUserActivity()
        guard let data = pendingAndroidEncryptedBackupData,
              let fileName = pendingAndroidEncryptedBackupFileName else {
            throw AppAndroidBackupImportError.encryptedBackupUnavailable
        }
        let password = androidBackupDecryptPassword
        androidBackupDecryptPassword = ""

        do {
            let preview = try previewAndroidBackupImport(
                data,
                fileName: fileName,
                decryptPassword: password
            )
            clearPendingAndroidEncryptedBackup()
            return preview
        } catch AppAndroidBackupImportError.encryptedBackupDecryptionFailed(let message) {
            throw AppAndroidBackupImportError.encryptedBackupDecryptionFailed(message)
        } catch {
            clearPendingAndroidEncryptedBackup()
            throw error
        }
    }

    func cancelPendingAndroidEncryptedBackupImport() {
        recordUserActivity()
        clearPendingAndroidEncryptedBackup()
        if androidBackupImportPreview == nil {
            entryOperationState = .idle
        }
    }

    func confirmAndroidBackupImport(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let preview = androidBackupImportPreview else {
                throw LocalVaultRepositoryError.invalidEntryPayload
            }
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let vaultSession = try requireActiveVaultSession()

            let project = try ensureActiveProject(projectTitle: projectTitle, entryRepository: entryRepository)
            var importedLoginIDsByAndroidID: [Int64: String] = [:]
            for importedItem in preview.report.importedItems {
                let createdEntryID = try createCSVImportedItem(
                    importedItem.draft,
                    projectID: project.id,
                    entryRepository: entryRepository
                )
                if case .login = importedItem.draft,
                   let sourceID = importedItem.sourceID,
                   let createdEntryID {
                    importedLoginIDsByAndroidID[sourceID] = createdEntryID
                }
            }
            var savedAttachmentBlobCount = 0
            for attachment in preview.attachments {
                let encryptedBlobLocalPath: String?
                if let encryptedBlob = attachment.encryptedBlob {
                    encryptedBlobLocalPath = try androidBackupAttachmentBlobStore.saveEncryptedBlob(
                        encryptedBlob,
                        vaultID: vaultSession.handle.vaultID,
                        localPath: attachment.localPath
                    )
                    savedAttachmentBlobCount += 1
                } else {
                    encryptedBlobLocalPath = nil
                }
                _ = try entryRepository.createAttachmentMetadata(
                    projectID: project.id,
                    entryID: importedLoginIDsByAndroidID[attachment.parentPasswordID],
                    fileName: attachment.fileName,
                    mediaType: attachment.mediaType,
                    originalSize: attachment.originalSize,
                    storedSize: Int64(attachment.encryptedBlob?.count ?? 0),
                    contentHash: attachment.contentHash,
                    storageMode: encryptedBlobLocalPath == nil ? "android-backup-pending" : "android-backup-encrypted-blob",
                    source: "android-backup-local",
                    downloadState: encryptedBlobLocalPath == nil ? "missing-blob" : "downloaded",
                    wrappedContentEncryptionKey: encryptedBlobLocalPath == nil ? nil : attachment.wrappedContentEncryptionKey,
                    localPath: encryptedBlobLocalPath
                )
            }
            try refreshAllEntryLists(projectID: project.id, entryRepository: entryRepository)
            try refreshAutoFillEncryptedIndexIfConfigured()
            androidBackupImportPreview = nil
            let attachmentText: String
            if preview.attachments.isEmpty {
                attachmentText = ""
            } else if savedAttachmentBlobCount == preview.attachments.count {
                attachmentText = "；\(savedAttachmentBlobCount) 个附件密文待恢复"
            } else if savedAttachmentBlobCount > 0 {
                attachmentText = "；\(savedAttachmentBlobCount) 个附件密文待恢复，\(preview.attachments.count - savedAttachmentBlobCount) 个附件元数据待恢复"
            } else {
                attachmentText = "；\(preview.attachments.count) 个附件元数据待恢复"
            }
            entryOperationState = .succeeded("Android 备份已导入 \(preview.items.count) 项\(attachmentText)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func androidBackupExportDocument() throws -> AndroidBackupExportDocument {
        AndroidBackupExportDocument(data: try exportAndroidBackup())
    }

    func exportAndroidBackup() throws -> Data {
        recordUserActivity()
        entryOperationState = .running

        do {
            _ = try requireActiveVaultSession()
            let drafts = csvExportDrafts()
            let data = try AndroidBackupCodec.exportItems(drafts)
            entryOperationState = .succeeded("Android 备份已导出 \(drafts.count) 项")
            return data
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func csvExportDocument() throws -> CSVExportDocument {
        CSVExportDocument(text: try exportCSV())
    }

    func exportCSV() throws -> String {
        recordUserActivity()
        entryOperationState = .running

        do {
            _ = try requireActiveVaultSession()
            let drafts = csvExportDrafts()
            let csv = VaultCSVCodec.exportItems(drafts)
            entryOperationState = .succeeded("CSV 已导出 \(drafts.count) 项")
            return csv
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func totpCode(for entry: LocalTotpEntry, at date: Date = Date()) throws -> String {
        try TotpGenerator.generate(
            secret: entry.secret,
            algorithm: totpAlgorithm(from: entry.algorithm),
            digits: Int(entry.digits),
            period: Int(entry.period),
            timestamp: date.timeIntervalSince1970
        )
    }

    func totpTimeRemaining(for entry: LocalTotpEntry, at date: Date = Date()) -> Int {
        let period = max(Int(entry.period), 1)
        let elapsed = Int(date.timeIntervalSince1970) % period
        return elapsed == 0 ? period : period - elapsed
    }

    var canPrepareVaultKeychainUnlock: Bool {
        vaultState == .unlocked
            && vaultKeychainService != nil
            && vaultWrappedKeyProvider != nil
    }

    var canUnlockRememberedVaultWithKeychain: Bool {
        vaultState == .locked
            && vaultKeychainService != nil
            && rememberedVaultDescriptor != nil
            && rememberedVaultID != nil
    }

    func prepareVaultKeychainUnlock() async throws {
        recordUserActivity()
        vaultKeychainState = .running

        do {
            guard let activeVaultSession else {
                throw AppVaultKeychainError.vaultLocked
            }
            guard let vaultKeychainService else {
                throw AppVaultKeychainError.keychainUnavailable
            }
            guard let vaultWrappedKeyProvider else {
                throw AppVaultKeychainError.wrappedKeyProviderUnavailable
            }
            if let kind = biometricUnlockKind {
                try await biometricUnlockAuthorizer.authenticate(
                    reason: "启用 \(kind.displayName) 解锁"
                )
            }

            let wrappedKey = try vaultWrappedKeyProvider(activeVaultSession)
            guard wrappedKey.vaultID == activeVaultSession.handle.vaultID else {
                throw AppVaultKeychainError.vaultMismatch
            }

            try vaultRepository.setupLocalSecurityKeyUnlock(
                for: activeVaultSession,
                securityKeyMaterial: wrappedKey.wrappedKeyMaterial
            )
            try await vaultKeychainService.saveWrappedKey(wrappedKey)
            setBiometricUnlockEnabled(true)
            rememberVault(activeVaultSession)
            vaultKeychainState = .saved(wrappedKey.vaultID)
        } catch {
            vaultKeychainState = .failed(readableVaultKeychainErrorMessage(for: error))
            throw error
        }
    }

    func setBiometricUnlockEnabled(_ isEnabled: Bool) {
        isBiometricUnlockEnabled = isEnabled
    }

    func unlockRememberedVaultWithKeychain(
        deviceID: String,
        now: Date = Date(),
        fallbackDirectory: URL? = nil
    ) async throws {
        vaultOperationState = .running
        vaultKeychainState = .running

        do {
            guard vaultState == .locked else {
                throw AppVaultKeychainError.vaultAlreadyUnlocked
            }
            guard let rememberedVaultDescriptor,
                  let rememberedVaultID else {
                throw AppVaultKeychainError.rememberedVaultUnavailable
            }
            guard let vaultKeychainService else {
                throw AppVaultKeychainError.keychainUnavailable
            }

            let wrappedKey = try await vaultKeychainService.loadWrappedKeyAfterAuthentication(
                vaultID: rememberedVaultID,
                reason: "解锁 Monica 保险库"
            )
            guard wrappedKey.vaultID == rememberedVaultID else {
                throw AppVaultKeychainError.vaultMismatch
            }

            let descriptor = resolvedRememberedVaultDescriptor(
                rememberedVaultDescriptor,
                fallbackDirectory: fallbackDirectory
            )
            let session = try vaultRepository.openVaultWithSecurityKey(
                at: descriptor.fileURL,
                securityKeyMaterial: wrappedKey.wrappedKeyMaterial,
                deviceID: deviceID
            )
            guard session.handle.vaultID == rememberedVaultID else {
                vaultRepository.closeVault(for: session)
                throw AppVaultKeychainError.vaultMismatch
            }

            vaultPassword = ""
            isPrivacyShieldVisible = false
            vaultState = .unlocked
            activeVaultName = session.descriptor.displayName
            activeVaultSession = session
            let entryRepository = vaultRepository.entryRepository(for: session)
            activeEntryRepository = entryRepository
            activeProject = nil
            vaultProjects = try entryRepository.listProjects()
            rememberVault(session)
            loginEntries = []
            deletedLoginEntries = []
            noteEntries = []
            deletedNoteEntries = []
            totpEntries = []
            deletedTotpEntries = []
            totpImportURI = ""
            cardEntries = []
            deletedCardEntries = []
            identityEntries = []
            deletedIdentityEntries = []
            passkeyEntries = []
            deletedPasskeyEntries = []
            clearExtendedParityEntries()
            recordUserActivity(at: now)
            vaultOperationState = .succeeded(session.descriptor.displayName)
            vaultKeychainState = .unlocked(session.handle.vaultID)
        } catch {
            clearVaultAccessAfterFailure()
            vaultKeychainState = .failed(readableVaultKeychainErrorMessage(for: error))
            vaultOperationState = .failed(readableVaultKeychainErrorMessage(for: error))
            throw error
        }
    }

    func refreshAutoFillEncryptedIndex(updatedAt: Date = Date()) throws {
        recordUserActivity()
        autoFillIndexState = .running

        do {
            guard vaultState == .unlocked,
                  let activeVaultSession
            else {
                throw AppAutoFillIndexError.vaultLocked
            }
            let shouldWriteEncryptedAutoFillArtifacts = autoFillIndexStore != nil
                || autoFillCredentialSecretStore != nil
            let shouldSyncCredentialIdentities = autoFillCredentialIdentityStore != nil
            guard shouldWriteEncryptedAutoFillArtifacts || shouldSyncCredentialIdentities else {
                throw AppAutoFillIndexError.indexStoreUnavailable
            }

            if shouldWriteEncryptedAutoFillArtifacts {
                guard let autoFillIndexKeyMaterialProvider
                else {
                    throw AppAutoFillIndexError.indexStoreUnavailable
                }
                let keyMaterial = try autoFillIndexKeyMaterialProvider(activeVaultSession.handle.vaultID)
                guard keyMaterial.vaultID == activeVaultSession.handle.vaultID else {
                    throw AppAutoFillIndexError.indexKeyVaultMismatch
                }

                let storageKey = try AutoFillIndexEncryptionKey(rawValue: keyMaterial.keyMaterial)
                if let autoFillIndexStore {
                    let indexRecords = loginEntries.map { entry in
                        AutoFillCredentialIndexRecord(
                            id: entry.id,
                            title: entry.title,
                            username: entry.username,
                            serviceIdentifiers: serviceIdentifiers(for: entry.url)
                        )
                    }
                    let index = try autoFillIndexCodec.encrypt(
                        indexRecords,
                        vaultID: activeVaultSession.handle.vaultID,
                        keyIdentifier: keyMaterial.keyIdentifier,
                        updatedAt: updatedAt,
                        key: storageKey
                    )
                    try autoFillIndexStore.save(index)
                }

                if let autoFillCredentialSecretStore {
                    let secretRecords = loginEntries.map { entry in
                        AutoFillCredentialSecretRecord(
                            id: entry.id,
                            username: entry.username,
                            password: entry.password
                        )
                    }
                    let secretSnapshot = try autoFillCredentialSecretCodec.encrypt(
                        secretRecords,
                        vaultID: activeVaultSession.handle.vaultID,
                        keyIdentifier: keyMaterial.keyIdentifier,
                        updatedAt: updatedAt,
                        key: storageKey
                    )
                    try autoFillCredentialSecretStore.save(secretSnapshot)
                }
            }

            if let autoFillCredentialIdentityStore {
                let identities = loginEntries.flatMap { entry in
                    autoFillCredentialIdentities(for: entry)
                }
                let passkeyIdentities = passkeyEntries.compactMap { entry in
                    autoFillPasskeyCredentialIdentity(for: entry)
                }
                autoFillCredentialIdentityStore.replaceCredentialIdentities(
                    identities,
                    passkeyIdentities: passkeyIdentities
                )
            }
            autoFillIndexState = .succeeded(loginEntries.count)
        } catch {
            autoFillIndexState = .failed(error.localizedDescription)
            throw error
        }
    }

    private func refreshAutoFillEncryptedIndexIfConfigured() throws {
        guard autoFillIndexStore != nil
                || autoFillCredentialSecretStore != nil
                || autoFillCredentialIdentityStore != nil
                || autoFillIndexKeyMaterialProvider != nil else {
            return
        }

        try refreshAutoFillEncryptedIndex()
    }

    func uploadActiveVaultBackup() async throws {
        recordUserActivity()
        webDAVBackupState = .running

        do {
            let session = try requireActiveVaultSession()
            let endpoint = try makeWebDAVEndpoint()
            let fileName = try normalizedWebDAVRemoteFileName(
                fallback: session.descriptor.fileURL.lastPathComponent
            )
            let data = try Data(contentsOf: session.descriptor.fileURL)
            let receipt = try await webDAVBackupService.upload(
                endpoint: endpoint,
                package: WebDAVBackupPackage(fileName: fileName, data: data)
            )
            webDAVPassword = ""
            webDAVRestorePreview = nil
            webDAVBackupState = .backupSucceeded(
                byteCount: receipt.byteCount,
                sha256: receipt.sha256
            )
        } catch {
            webDAVBackupState = .failed(readableWebDAVErrorMessage(for: error))
            throw error
        }
    }

    func refreshCloudFileItems(provider kind: CloudFileProviderKind) async throws -> [CloudFileItem] {
        recordUserActivity()
        cloudFileState = .running(kind)

        do {
            let provider = try cloudFileProvider(for: kind)
            let items = try await provider.listFiles()
            cloudFileItemsByProvider[kind] = items
            cloudFileState = .listed(provider: kind, count: items.count)
            return items
        } catch {
            cloudFileState = .failed(readableCloudFileErrorMessage(for: error, provider: kind))
            throw error
        }
    }

    func signInToOneDrive() async throws -> AppOneDriveAuthenticationSession {
        recordUserActivity()
        guard let oneDriveAuthenticationService else {
            let error = AppOneDriveAuthenticationError.serviceUnavailable
            oneDriveAuthenticationState = .failed(error.localizedDescription)
            throw error
        }
        oneDriveAuthenticationState = .running
        do {
            let session = try await oneDriveAuthenticationService.signIn()
            oneDriveAuthenticationState = .connected(accountLabel: session.accountLabel)
            return session
        } catch {
            oneDriveAuthenticationState = .failed(readableOneDriveAuthenticationErrorMessage(error))
            throw error
        }
    }

    @discardableResult
    func restoreOneDriveAuthenticationSession() async throws -> AppOneDriveAuthenticationSession? {
        guard let oneDriveAuthenticationService else {
            oneDriveAuthenticationState = .disconnected
            return nil
        }

        do {
            guard let session = try await oneDriveAuthenticationService.restoreSession() else {
                oneDriveAuthenticationState = .disconnected
                return nil
            }
            oneDriveAuthenticationState = .connected(accountLabel: session.accountLabel)
            return session
        } catch {
            oneDriveAuthenticationState = .failed(readableOneDriveAuthenticationErrorMessage(error))
            throw error
        }
    }

    func signOutFromOneDrive() async throws {
        recordUserActivity()
        guard let oneDriveAuthenticationService else {
            let error = AppOneDriveAuthenticationError.serviceUnavailable
            oneDriveAuthenticationState = .failed(error.localizedDescription)
            throw error
        }
        oneDriveAuthenticationState = .running
        do {
            try await oneDriveAuthenticationService.signOut()
            cloudFileItemsByProvider[.oneDrive] = nil
            if cloudFileRestorePreview?.provider == .oneDrive {
                cloudFileRestorePreview = nil
                downloadedCloudFileRestore = nil
            }
            oneDriveAuthenticationState = .disconnected
        } catch {
            oneDriveAuthenticationState = .failed(readableOneDriveAuthenticationErrorMessage(error))
            throw error
        }
    }

    func handleOneDriveRedirectURL(_ url: URL) -> Bool {
        guard let oneDriveAuthenticationService,
              oneDriveAuthenticationService.handleRedirectURL(url)
        else {
            return false
        }
        oneDriveAuthenticationState = .redirectHandled
        return true
    }

    @discardableResult
    func signInToBitwarden() async throws -> BitwardenAuthenticationSession {
        recordUserActivity()
        bitwardenSyncState = .running

        do {
            guard let bitwardenPasswordAuthenticationService else {
                throw AppBitwardenSyncError.providerUnavailable
            }
            guard let serverURL = validBitwardenServerURL(bitwardenServerURL) else {
                throw AppBitwardenSyncError.invalidServerURL
            }
            let session = try await bitwardenPasswordAuthenticationService.signIn(
                email: bitwardenEmail,
                masterPassword: bitwardenMasterPassword,
                serverURL: serverURL
            )
            bitwardenMasterPassword = ""
            bitwardenAuthenticationState = .connected(accountLabel: session.accountLabel)
            bitwardenSyncState = .idle
            return session
        } catch {
            let message = readableBitwardenSyncErrorMessage(for: error)
            bitwardenMasterPassword = ""
            bitwardenAuthenticationState = .failed(message)
            bitwardenSyncState = .failed(message)
            throw error
        }
    }

    @discardableResult
    func restoreBitwardenAuthenticationSession() throws -> BitwardenAuthenticationSession? {
        do {
            guard let session = try bitwardenAuthenticationSessionStore.loadSession() else {
                bitwardenAuthenticationState = .disconnected
                return nil
            }
            bitwardenAuthenticationState = .connected(accountLabel: session.accountLabel)
            return session
        } catch {
            bitwardenAuthenticationState = .failed(readableBitwardenSyncErrorMessage(for: error))
            throw error
        }
    }

    func signOutFromBitwarden() throws {
        recordUserActivity()
        do {
            let accountLabel = try bitwardenAuthenticationSessionStore.loadSession()?.accountLabel
            try bitwardenAuthenticationSessionStore.clearSession()
            try bitwardenVaultKeyStore?.clearVaultKey(accountLabel: accountLabel)
            bitwardenAuthenticationState = .disconnected
            bitwardenSyncState = .idle
            bitwardenSyncPreview = nil
        } catch {
            bitwardenAuthenticationState = .failed(readableBitwardenSyncErrorMessage(for: error))
            throw error
        }
    }

    func downloadCloudFileRestorePreview(
        itemID: String,
        provider kind: CloudFileProviderKind
    ) async throws -> CloudFileDownload {
        recordUserActivity()
        cloudFileState = .running(kind)

        do {
            _ = try requireActiveVaultSession()
            let provider = try cloudFileProvider(for: kind)
            let download = try await provider.downloadFile(id: itemID)
            let preview = AppCloudFileRestorePreview(provider: kind, download: download)
            downloadedCloudFileRestore = download
            cloudFileRestorePreview = preview
            cloudFileState = .restorePreviewReady(
                provider: kind,
                fileName: preview.fileName,
                byteCount: preview.byteCount
            )
            return download
        } catch {
            cloudFileState = .failed(readableCloudFileErrorMessage(for: error, provider: kind))
            throw error
        }
    }

    func uploadActiveVaultToCloud(provider kind: CloudFileProviderKind) async throws -> CloudFileWriteReceipt {
        recordUserActivity()
        cloudFileState = .running(kind)

        do {
            let session = try requireActiveVaultSession()
            let provider = try cloudFileProvider(for: kind)
            let data = try Data(contentsOf: session.descriptor.fileURL)
            let receipt = try await provider.uploadFile(
                named: kind.defaultBackupFileName,
                data: data
            )
            cloudFileState = .backupSucceeded(
                provider: kind,
                fileName: sanitizedCloudFileName(receipt.name),
                byteCount: receipt.byteCount
            )
            return receipt
        } catch {
            cloudFileState = .failed(readableCloudFileErrorMessage(for: error, provider: kind))
            throw error
        }
    }

    func overwriteCloudFile(
        provider kind: CloudFileProviderKind,
        itemID: String,
        data: Data,
        fileName: String
    ) async throws -> CloudFileWriteReceipt {
        recordUserActivity()
        cloudFileState = .running(kind)

        do {
            _ = try requireActiveVaultSession()
            let provider = try cloudFileProvider(for: kind)
            let receipt = try await provider.overwriteFile(
                id: itemID,
                data: data,
                fileName: sanitizedCloudFileName(fileName)
            )
            cloudFileState = .writeSucceeded(
                provider: kind,
                fileName: sanitizedCloudFileName(receipt.name),
                byteCount: receipt.byteCount
            )
            return receipt
        } catch {
            cloudFileState = .failed(readableCloudFileErrorMessage(for: error, provider: kind))
            throw error
        }
    }

    func previewBitwardenSync() async throws -> AppBitwardenSyncPreview {
        recordUserActivity()
        bitwardenSyncState = .running

        do {
            _ = try requireActiveVaultSession()
            let provider = try requireBitwardenSyncProvider()
            let snapshot = try await provider.pullSnapshot()
            let preview = AppBitwardenSyncPreview(snapshot: snapshot)
            bitwardenSyncPreview = preview
            bitwardenSyncState = .previewReady(
                itemCount: preview.remoteItemCount,
                sendCount: preview.remoteSendCount
            )
            return preview
        } catch {
            bitwardenSyncState = .failed(readableBitwardenSyncErrorMessage(for: error))
            throw error
        }
    }

    func syncBitwardenVaultData(projectTitle: String) async throws -> AppBitwardenSyncPreview {
        recordUserActivity()
        bitwardenSyncState = .running

        do {
            let session = try requireActiveVaultSession()
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let provider = try requireBitwardenSyncProvider()
            let snapshot = try await provider.pullSnapshot()
            let preview = AppBitwardenSyncPreview(snapshot: snapshot)
            let previousItemStates = try bitwardenItemSyncStateStore.loadStates(vaultID: session.handle.vaultID)
            let previousSendStates = try bitwardenSendSyncStateStore.loadStates(vaultID: session.handle.vaultID)
            try validateBitwardenRemoteSnapshotIsSafe(
                snapshot,
                previousItemStates: previousItemStates,
                previousSendStates: previousSendStates
            )
            let project = try ensureActiveProject(
                projectTitle: projectTitle,
                entryRepository: entryRepository
            )
            try importBitwardenSnapshot(
                snapshot,
                projectID: project.id,
                vaultID: session.handle.vaultID,
                entryRepository: entryRepository
            )
            try refreshAllEntryLists(projectID: project.id, entryRepository: entryRepository)
            try refreshAutoFillEncryptedIndexIfConfigured()
            bitwardenSyncPreview = preview
            bitwardenSyncState = .synced(
                itemCount: preview.remoteItemCount,
                sendCount: preview.remoteSendCount
            )
            return preview
        } catch {
            bitwardenSyncState = .failed(readableBitwardenSyncErrorMessage(for: error))
            throw error
        }
    }

    func pushLocalBitwardenChanges() async throws -> BitwardenSyncPushResult {
        recordUserActivity()
        bitwardenSyncState = .running

        do {
            let session = try requireActiveVaultSession()
            let provider = try requireBitwardenSyncProvider()
            let snapshot = try await provider.pullSnapshot()
            let preview = AppBitwardenSyncPreview(snapshot: snapshot)
            let previousItemStates = try bitwardenItemSyncStateStore.loadStates(vaultID: session.handle.vaultID)
            let previousSendStates = try bitwardenSendSyncStateStore.loadStates(vaultID: session.handle.vaultID)
            let previousFolderStates = try bitwardenFolderSyncStateStore.loadStates(vaultID: session.handle.vaultID)
            try validateBitwardenRemoteSnapshotIsSafe(
                snapshot,
                previousItemStates: previousItemStates,
                previousSendStates: previousSendStates
            )
            bitwardenSyncPreview = preview
            let itemPlan = makeBitwardenItemSyncPlan(
                remoteItems: snapshot.items,
                previousStates: previousItemStates,
                folderStates: previousFolderStates
            )
            let sendPlan = makeBitwardenSendSyncPlan(
                remoteSends: snapshot.sends,
                previousStates: previousSendStates
            )
            let pendingBatches = try bitwardenPendingMutationQueueStore.loadBatches(vaultID: session.handle.vaultID)
            let mutations = itemPlan.mutations + sendPlan.mutations
            let result: BitwardenSyncPushResult
            do {
                result = try await provider.pushMutations(mutations)
            } catch {
                if isRetryableBitwardenPushError(error), !mutations.isEmpty {
                    try queueBitwardenPendingMutations(
                        mutations,
                        vaultID: session.handle.vaultID,
                        existingBatches: pendingBatches,
                        error: error
                    )
                    bitwardenSyncState = .queuedForRetry(mutationCount: mutations.count)
                }
                throw error
            }
            let itemStates = bitwardenItemStates(
                itemPlan.updatedStates.values,
                assigningRemoteIDs: result.assignedRemoteIDs,
                revision: result.revision
            )
            let sendStates = bitwardenSendStates(
                sendPlan.updatedStates.values,
                assigningRemoteIDs: result.assignedRemoteIDs,
                revision: result.revision
            )
            try bitwardenItemSyncStateStore.saveStates(
                sortedBitwardenItemStates(itemStates),
                vaultID: session.handle.vaultID
            )
            try bitwardenSendSyncStateStore.saveStates(
                sendStates.sorted { $0.localID < $1.localID },
                vaultID: session.handle.vaultID
            )
            if !pendingBatches.isEmpty {
                try bitwardenPendingMutationQueueStore.saveBatches([], vaultID: session.handle.vaultID)
            }
            let conflicts = itemPlan.conflicts + sendPlan.conflicts + result.conflicts
            bitwardenSyncState = .pushed(
                acceptedMutationCount: result.acceptedMutationCount,
                conflictCount: conflicts.count
            )
            return BitwardenSyncPushResult(
                acceptedMutationCount: result.acceptedMutationCount,
                conflicts: conflicts,
                revision: result.revision,
                assignedRemoteIDs: result.assignedRemoteIDs
            )
        } catch {
            if case .queuedForRetry = bitwardenSyncState {
                throw error
            }
            bitwardenSyncState = .failed(readableBitwardenSyncErrorMessage(for: error))
            throw error
        }
    }

    private func queueBitwardenPendingMutations(
        _ mutations: [BitwardenSyncMutation],
        vaultID: String,
        existingBatches: [AppBitwardenPendingMutationBatch],
        error: Error
    ) throws {
        let retryCount = (existingBatches.map(\.retryCount).max() ?? 0) + 1
        let batch = AppBitwardenPendingMutationBatch(
            vaultID: vaultID,
            mutationCount: mutations.count,
            redactedSummaries: mutations.map(\.redactedSummary),
            retryCount: retryCount,
            lastErrorSummary: readableBitwardenSyncErrorMessage(for: error)
        )
        try bitwardenPendingMutationQueueStore.saveBatches([batch], vaultID: vaultID)
    }

    private func isRetryableBitwardenPushError(_ error: Error) -> Bool {
        if error is URLError {
            return true
        }
        if case .serverRejected(let statusCode) = error as? BitwardenSyncProviderError {
            return (500...599).contains(statusCode)
        }
        return false
    }

    private func validateBitwardenRemoteSnapshotIsSafe(
        _ snapshot: BitwardenSyncSnapshot,
        previousItemStates: [BitwardenItemSyncState],
        previousSendStates: [BitwardenSendSyncState]
    ) throws {
        guard snapshot.items.isEmpty, snapshot.sends.isEmpty else {
            return
        }
        let activeSyncedItemCount = previousItemStates.filter { state in
            state.remoteID?.nonBlankValue != nil && !state.isDeleted
        }.count
        let activeSyncedSendCount = previousSendStates.filter { state in
            state.remoteID?.nonBlankValue != nil && !state.isDeleted
        }.count
        let localCount = activeSyncedItemCount + activeSyncedSendCount
        guard localCount > 0 else {
            return
        }
        throw AppBitwardenSyncError.emptyRemoteVault(localCount: localCount)
    }

    func downloadWebDAVRestorePreview() async throws {
        recordUserActivity()
        webDAVBackupState = .running

        do {
            _ = try requireActiveVaultSession()
            let endpoint = try makeWebDAVEndpoint()
            let fileName = try normalizedWebDAVRemoteFileName(fallback: nil)
            let downloaded = try await webDAVBackupService.download(
                endpoint: endpoint,
                fileName: fileName
            )
            let preview = try WebDAVRestorePreview(downloaded)
            webDAVPassword = ""
            webDAVRestoreVaultPassword = ""
            webDAVRestorePreview = preview
            downloadedWebDAVRestoreBackup = downloaded
            webDAVBackupState = .restorePreviewReady(
                fileName: preview.fileName,
                byteCount: preview.byteCount
            )
        } catch {
            webDAVBackupState = .failed(readableWebDAVErrorMessage(for: error))
            throw error
        }
    }

    func confirmWebDAVRestore() throws {
        recordUserActivity()
        webDAVBackupState = .running

        do {
            guard let activeVaultSession else {
                throw AppWebDAVBackupError.vaultLocked
            }
            guard let preview = webDAVRestorePreview,
                  let downloaded = downloadedWebDAVRestoreBackup else {
                throw AppWebDAVBackupError.restorePreviewUnavailable
            }
            let restorePassword = webDAVRestoreVaultPassword
            guard !restorePassword.isEmpty else {
                throw AppWebDAVBackupError.emptyRestoreVaultPassword
            }

            let destinationURL = activeVaultSession.descriptor.fileURL
            try validateDownloadedWebDAVRestore(
                downloaded,
                near: destinationURL,
                password: restorePassword,
                deviceID: activeVaultSession.handle.deviceID
            )
            webDAVRestoreVaultPassword = ""
            vaultRepository.closeVault(for: activeVaultSession)
            clearUnlockedVaultSession()
            try replaceVaultFile(
                at: destinationURL,
                with: downloaded.data
            )
            webDAVRestorePreview = nil
            downloadedWebDAVRestoreBackup = nil
            webDAVBackupState = .restoreSucceeded(
                fileName: preview.fileName,
                byteCount: preview.byteCount
            )
        } catch {
            webDAVRestoreVaultPassword = ""
            webDAVBackupState = .failed(readableWebDAVErrorMessage(for: error))
            throw error
        }
    }

    private func readableWebDAVErrorMessage(for error: Error) -> String {
        if let appError = error as? AppWebDAVBackupError {
            return appError.localizedDescription
        }

        if let webDAVError = error as? WebDAVError {
            switch webDAVError {
            case .unexpectedStatus(_, let statusCode) where statusCode == 401 || statusCode == 403:
                return "WebDAV 登录失败，请检查用户名和密码。"
            case .unexpectedStatus("download", 404):
                return "未找到远端备份文件。"
            case .unexpectedStatus(_, let statusCode) where (500...599).contains(statusCode):
                return "WebDAV 服务器暂不可用，请稍后再试。"
            case .unexpectedStatus:
                return "WebDAV 请求失败，请检查服务器设置后重试。"
            case .integrityCheckFailed:
                return "远端备份未通过完整性校验，可能已经损坏。"
            case .nonHTTPResponse:
                return "WebDAV 服务器返回了无效响应。"
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "网络不可用，请检查连接后重试。"
            case .timedOut:
                return "WebDAV 请求超时，请稍后再试。"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "无法连接 WebDAV 服务器，请检查服务器 URL。"
            case .userAuthenticationRequired, .userCancelledAuthentication:
                return "WebDAV 登录失败，请检查用户名和密码。"
            default:
                return "WebDAV 连接失败，请检查网络和服务器设置。"
            }
        }

        return error.localizedDescription
    }

    private func cloudFileProvider(for kind: CloudFileProviderKind) throws -> any CloudFileProvider {
        guard let provider = cloudFileProviders[kind] else {
            throw AppCloudFileError.providerUnavailable(kind)
        }
        return provider
    }

    private func requireBitwardenSyncProvider() throws -> any BitwardenSyncProvider {
        guard let bitwardenSyncProvider else {
            throw AppBitwardenSyncError.providerUnavailable
        }
        return bitwardenSyncProvider
    }

    private func importBitwardenSnapshot(
        _ snapshot: BitwardenSyncSnapshot,
        projectID: String,
        vaultID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws {
        var existingLogins = try entryRepository.listLoginEntries(projectID: projectID)
        var existingNotes = try entryRepository.listNoteEntries(projectID: projectID)
        var existingCards = try entryRepository.listCardEntries(projectID: projectID)
        var existingIdentities = try entryRepository.listIdentityEntries(projectID: projectID)
        var existingPasskeys = try entryRepository.listPasskeyEntries(projectID: projectID)
        var existingTotps = try entryRepository.listTotpEntries(projectID: projectID)
        var existingSends = try entryRepository.listSendEntries(projectID: projectID)
        var itemStates = Dictionary(
            uniqueKeysWithValues: try bitwardenItemSyncStateStore
                .loadStates(vaultID: vaultID)
                .map { ($0.localID, $0) }
        )
        var sendStates = Dictionary(
            uniqueKeysWithValues: try bitwardenSendSyncStateStore
                .loadStates(vaultID: vaultID)
                .map { ($0.localID, $0) }
        )
        var folderStates = Dictionary(
            uniqueKeysWithValues: try bitwardenFolderSyncStateStore
                .loadStates(vaultID: vaultID)
                .map { ($0.localID, $0) }
        )
        var projectIDByFolderRemoteID: [String: String] = [:]
        if !snapshot.folders.isEmpty {
            var projects = try entryRepository.listProjects()
            for folder in snapshot.folders {
                let title = bitwardenImportTitle(folder.name)
                let project: LocalVaultProject
                if let existing = projects.first(where: { $0.title == title }) {
                    project = existing
                } else {
                    project = try entryRepository.createProject(title: title)
                    projects.append(project)
                }
                projectIDByFolderRemoteID[folder.remoteID] = project.id
                folderStates[project.id] = BitwardenFolderSyncState(
                    localID: project.id,
                    remoteID: folder.remoteID,
                    name: title,
                    lastSyncedFingerprint: title,
                    lastRemoteRevision: folder.updatedAt.map { String($0.timeIntervalSince1970) },
                    isDeleted: false
                )
            }
        }

        for item in snapshot.items {
            let targetProjectID = item.folderID.flatMap { projectIDByFolderRemoteID[$0] } ?? projectID
            switch item.kind {
            case .login:
                let localEntry: LocalLoginEntry
                if targetProjectID == projectID,
                   let existing = existingLogins.first(where: { isSameBitwardenLogin($0, item) }) {
                    localEntry = existing
                } else {
                    localEntry = try entryRepository.createLoginEntry(
                        projectID: targetProjectID,
                        draft: LocalLoginEntryDraft(
                            title: bitwardenImportTitle(item.title),
                            username: item.username,
                            password: item.password ?? "",
                            url: item.url,
                            notes: item.notes ?? ""
                        )
                    )
                    if targetProjectID == projectID {
                        existingLogins.append(localEntry)
                    }
                }
                let localItem = bitwardenLocalItem(from: localEntry, folderID: item.folderID, folderName: item.folderName)
                itemStates[localEntry.id] = bitwardenItemSyncState(
                    localItem: localItem,
                    remoteItem: item
                )
                try reconcileBitwardenAttachments(
                    item.attachments,
                    localEntryID: localEntry.id,
                    projectID: targetProjectID,
                    entryRepository: entryRepository
                )
                if let totpSecret = item.totpSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !totpSecret.isEmpty,
                   !existingTotps.contains(where: { $0.title == bitwardenImportTitle(item.title) && $0.secret == totpSecret }) {
                    let created = try entryRepository.createTotpEntry(
                        projectID: projectID,
                        draft: LocalTotpEntryDraft(
                            title: bitwardenImportTitle(item.title),
                            secret: totpSecret,
                            issuer: item.folderName ?? snapshot.accountLabel,
                            accountName: item.username,
                            period: 30,
                            digits: 6,
                            algorithm: "SHA1",
                            otpType: "TOTP",
                            counter: 0
                        )
                    )
                    existingTotps.append(created)
                }
            case .passkey:
                let localEntry: LocalPasskeyEntry
                if targetProjectID == projectID,
                   let existing = existingPasskeys.first(where: { isSameBitwardenPasskey($0, item) }) {
                    localEntry = existing
                } else {
                    localEntry = try entryRepository.createPasskeyEntry(
                        projectID: targetProjectID,
                        draft: LocalPasskeyEntryDraft(
                            title: bitwardenImportTitle(item.title),
                            relyingPartyID: bitwardenPasskeyRelyingPartyID(for: item),
                            username: item.username,
                            userHandle: item.passkeyUserHandle,
                            credentialID: item.passkeyCredentialID,
                            publicKeyCOSE: item.passkeyPublicKeyCOSE,
                            privateKeyReference: item.passkeyPrivateKeyReference,
                            notes: item.notes ?? ""
                        )
                    )
                    if targetProjectID == projectID {
                        existingPasskeys.append(localEntry)
                    }
                }
                let localItem = bitwardenLocalItem(from: localEntry, folderID: item.folderID, folderName: item.folderName)
                itemStates[localEntry.id] = bitwardenItemSyncState(
                    localItem: localItem,
                    remoteItem: item
                )
                try reconcileBitwardenAttachments(
                    item.attachments,
                    localEntryID: localEntry.id,
                    projectID: targetProjectID,
                    entryRepository: entryRepository
                )
            case .secureNote:
                let localEntry: LocalNoteEntry
                if targetProjectID == projectID,
                   let existing = existingNotes.first(where: { $0.title == bitwardenImportTitle(item.title) && $0.body == (item.notes ?? "") }) {
                    localEntry = existing
                } else {
                    localEntry = try entryRepository.createNoteEntry(
                        projectID: targetProjectID,
                        draft: LocalNoteEntryDraft(
                            title: bitwardenImportTitle(item.title),
                            body: item.notes ?? ""
                        )
                    )
                    if targetProjectID == projectID {
                        existingNotes.append(localEntry)
                    }
                }
                let localItem = bitwardenLocalItem(from: localEntry, folderID: item.folderID, folderName: item.folderName)
                itemStates[localEntry.id] = bitwardenItemSyncState(
                    localItem: localItem,
                    remoteItem: item
                )
                try reconcileBitwardenAttachments(
                    item.attachments,
                    localEntryID: localEntry.id,
                    projectID: targetProjectID,
                    entryRepository: entryRepository
                )
            case .card:
                let localEntry: LocalCardEntry
                if targetProjectID == projectID,
                   let existing = existingCards.first(where: { $0.title == bitwardenImportTitle(item.title) && $0.notes == (item.notes ?? "") }) {
                    localEntry = existing
                } else {
                    localEntry = try entryRepository.createCardEntry(
                        projectID: targetProjectID,
                        draft: LocalCardEntryDraft(
                            title: bitwardenImportTitle(item.title),
                            cardholderName: item.cardholderName,
                            number: item.cardNumber,
                            expiryMonth: item.cardExpiryMonth,
                            expiryYear: item.cardExpiryYear,
                            cvv: item.cardCode,
                            issuer: item.folderName ?? "",
                            network: item.cardBrand,
                            notes: item.notes ?? ""
                        )
                    )
                    if targetProjectID == projectID {
                        existingCards.append(localEntry)
                    }
                }
                let localItem = bitwardenLocalItem(from: localEntry, folderID: item.folderID)
                itemStates[localEntry.id] = bitwardenItemSyncState(
                    localItem: localItem,
                    remoteItem: item
                )
                try reconcileBitwardenAttachments(
                    item.attachments,
                    localEntryID: localEntry.id,
                    projectID: targetProjectID,
                    entryRepository: entryRepository
                )
            case .identity:
                let localEntry: LocalIdentityEntry
                if targetProjectID == projectID,
                   let existing = existingIdentities.first(where: { $0.title == bitwardenImportTitle(item.title) && $0.notes == (item.notes ?? "") }) {
                    localEntry = existing
                } else {
                    localEntry = try entryRepository.createIdentityEntry(
                        projectID: targetProjectID,
                        draft: LocalIdentityEntryDraft(
                            title: bitwardenImportTitle(item.title),
                            documentType: "Bitwarden Identity",
                            fullName: item.identityFullName.isEmpty ? item.username : item.identityFullName,
                            documentNumber: item.identityDocumentNumber,
                            issuer: item.identityIssuer.isEmpty ? (item.folderName ?? "") : item.identityIssuer,
                            country: item.identityCountry,
                            issueDate: "",
                            expiryDate: "",
                            notes: item.notes ?? ""
                        )
                    )
                    if targetProjectID == projectID {
                        existingIdentities.append(localEntry)
                    }
                }
                let localItem = bitwardenLocalItem(from: localEntry, folderID: item.folderID)
                itemStates[localEntry.id] = bitwardenItemSyncState(
                    localItem: localItem,
                    remoteItem: item
                )
                try reconcileBitwardenAttachments(
                    item.attachments,
                    localEntryID: localEntry.id,
                    projectID: targetProjectID,
                    entryRepository: entryRepository
                )
            }
        }

        for send in snapshot.sends {
            let remoteFingerprint = BitwardenLocalSendSyncItem(
                localID: send.remoteID,
                title: send.title,
                body: send.body,
                notes: send.notes,
                expiresAt: send.expiresAt,
                maxViews: send.maxViews
            ).syncFingerprint
            if let existing = existingSends.first(where: { isSameBitwardenSend($0, send) }) {
                sendStates[existing.id] = BitwardenSendSyncState(
                    localID: existing.id,
                    remoteID: send.remoteID,
                    lastSyncedFingerprint: remoteFingerprint,
                    lastRemoteRevision: send.updatedAt.map { String($0.timeIntervalSince1970) },
                    isDeleted: false
                )
                continue
            }
            let created = try entryRepository.createSendEntry(
                projectID: projectID,
                draft: LocalSendEntryDraft(
                    title: bitwardenImportTitle(send.title),
                    body: send.body,
                    expiresAt: send.expiresAt,
                    maxViews: send.maxViews,
                    notes: send.notes ?? ""
                )
            )
            existingSends.append(created)
            sendStates[created.id] = BitwardenSendSyncState(
                localID: created.id,
                remoteID: send.remoteID,
                lastSyncedFingerprint: remoteFingerprint,
                lastRemoteRevision: send.updatedAt.map { String($0.timeIntervalSince1970) },
                isDeleted: false
            )
        }

        try bitwardenItemSyncStateStore.saveStates(
            sortedBitwardenItemStates(itemStates.values),
            vaultID: vaultID
        )
        try bitwardenFolderSyncStateStore.saveStates(
            folderStates.values.sorted { $0.localID < $1.localID },
            vaultID: vaultID
        )
        try bitwardenSendSyncStateStore.saveStates(
            sendStates.values.sorted { $0.localID < $1.localID },
            vaultID: vaultID
        )
    }

    private func isSameBitwardenLogin(_ entry: LocalLoginEntry, _ item: BitwardenSyncItem) -> Bool {
        entry.title == bitwardenImportTitle(item.title)
            && entry.username == item.username
            && entry.url == item.url
    }

    private func isSameBitwardenPasskey(_ entry: LocalPasskeyEntry, _ item: BitwardenSyncItem) -> Bool {
        entry.title == bitwardenImportTitle(item.title)
            && entry.relyingPartyID == bitwardenPasskeyRelyingPartyID(for: item)
            && entry.username == item.username
            && entry.credentialID == item.passkeyCredentialID
    }

    private func isSameBitwardenSend(_ entry: LocalSendEntry, _ send: BitwardenSendSyncItem) -> Bool {
        entry.title == bitwardenImportTitle(send.title)
            && entry.body == send.body
            && entry.expiresAt == send.expiresAt
            && entry.maxViews == send.maxViews
            && entry.notes == (send.notes ?? "")
    }

    private func bitwardenImportTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Bitwarden 项目" : trimmed
    }

    private func bitwardenPasskeyRelyingPartyID(for item: BitwardenSyncItem) -> String {
        if let relyingPartyID = item.passkeyRelyingPartyID.nonBlankValue {
            return relyingPartyID
        }
        guard let host = URLComponents(string: item.url)?.host?.nonBlankValue else {
            return ""
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func reconcileBitwardenAttachments(
        _ remoteAttachments: [BitwardenSyncAttachment],
        localEntryID: String,
        projectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws {
        let localAttachments = try entryRepository.listAttachmentMetadata(projectID: projectID)
            .filter { $0.entryID == localEntryID && $0.source == "bitwarden" }
        let remoteByHash = Dictionary(uniqueKeysWithValues: remoteAttachments.map { attachment in
            (bitwardenAttachmentContentHash(attachment), attachment)
        })
        for local in localAttachments where remoteByHash[local.contentHash] == nil {
            try entryRepository.deleteAttachmentMetadata(projectID: projectID, attachmentID: local.id)
        }
        for attachment in remoteAttachments {
            let contentHash = bitwardenAttachmentContentHash(attachment)
            if let existing = localAttachments.first(where: { $0.contentHash == contentHash }) {
                if existing.fileName != bitwardenImportTitle(attachment.fileName)
                    || existing.originalSize != Int64(attachment.byteCount)
                    || existing.wrappedContentEncryptionKey != attachment.encryptedKey {
                    _ = try entryRepository.updateAttachmentMetadata(
                        projectID: projectID,
                        attachmentID: existing.id,
                        entryID: localEntryID,
                        fileName: bitwardenImportTitle(attachment.fileName),
                        mediaType: "application/octet-stream",
                        originalSize: Int64(attachment.byteCount),
                        storedSize: 0,
                        contentHash: contentHash,
                        storageMode: "remote-bitwarden",
                        source: "bitwarden",
                        downloadState: "pending-bitwarden-download",
                        wrappedContentEncryptionKey: attachment.encryptedKey,
                        localPath: nil
                    )
                }
                continue
            }
            _ = try entryRepository.createAttachmentMetadata(
                projectID: projectID,
                entryID: localEntryID,
                fileName: bitwardenImportTitle(attachment.fileName),
                mediaType: "application/octet-stream",
                originalSize: Int64(attachment.byteCount),
                storedSize: 0,
                contentHash: contentHash,
                storageMode: "remote-bitwarden",
                source: "bitwarden",
                downloadState: "pending-bitwarden-download",
                wrappedContentEncryptionKey: attachment.encryptedKey,
                localPath: nil
            )
        }
    }

    private func bitwardenAttachmentContentHash(_ attachment: BitwardenSyncAttachment) -> String {
        let digest = SHA256.hash(data: Data(attachment.syncFingerprint.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func bitwardenItemSyncState(
        localItem: BitwardenLocalItemSyncItem,
        remoteItem: BitwardenSyncItem
    ) -> BitwardenItemSyncState {
        BitwardenItemSyncState(
            localID: localItem.localID,
            remoteID: remoteItem.remoteID,
            kind: localItem.kind,
            lastSyncedFingerprint: localItem.syncFingerprint,
            lastRemoteRevision: remoteItem.updatedAt.map { String($0.timeIntervalSince1970) },
            isDeleted: false
        )
    }

    private func sortedBitwardenItemStates(
        _ states: Dictionary<String, BitwardenItemSyncState>.Values
    ) -> [BitwardenItemSyncState] {
        sortedBitwardenItemStates(Array(states))
    }

    private func sortedBitwardenItemStates(
        _ states: [BitwardenItemSyncState]
    ) -> [BitwardenItemSyncState] {
        states.sorted { lhs, rhs in
            let lhsRemoteID = lhs.remoteID ?? ""
            let rhsRemoteID = rhs.remoteID ?? ""
            if lhsRemoteID != rhsRemoteID {
                return lhsRemoteID < rhsRemoteID
            }
            return lhs.localID < rhs.localID
        }
    }

    private func bitwardenItemStates(
        _ states: Dictionary<String, BitwardenItemSyncState>.Values,
        assigningRemoteIDs assignedRemoteIDs: [String: String],
        revision: String
    ) -> [BitwardenItemSyncState] {
        states.map { state in
            guard let assignedRemoteID = assignedRemoteIDs[state.localID],
                  state.remoteID == nil,
                  !state.isDeleted else {
                return state
            }
            return BitwardenItemSyncState(
                localID: state.localID,
                remoteID: assignedRemoteID,
                kind: state.kind,
                lastSyncedFingerprint: state.lastSyncedFingerprint,
                lastRemoteRevision: revision.isEmpty ? state.lastRemoteRevision : revision,
                isDeleted: false
            )
        }
    }

    private func bitwardenSendStates(
        _ states: Dictionary<String, BitwardenSendSyncState>.Values,
        assigningRemoteIDs assignedRemoteIDs: [String: String],
        revision: String
    ) -> [BitwardenSendSyncState] {
        states.map { state in
            guard let assignedRemoteID = assignedRemoteIDs[state.localID],
                  state.remoteID == nil,
                  !state.isDeleted else {
                return state
            }
            return BitwardenSendSyncState(
                localID: state.localID,
                remoteID: assignedRemoteID,
                lastSyncedFingerprint: state.lastSyncedFingerprint,
                lastRemoteRevision: revision.isEmpty ? state.lastRemoteRevision : revision,
                isDeleted: false
            )
        }
    }

    private func bitwardenLocalItem(from entry: LocalLoginEntry, folderID: String? = nil, folderName: String? = nil) -> BitwardenLocalItemSyncItem {
        BitwardenLocalItemSyncItem(
            localID: entry.id,
            kind: .login,
            title: entry.title,
            username: entry.username,
            url: entry.url,
            password: entry.password,
            notes: entry.notes,
            folderID: folderID,
            folderName: folderName
        )
    }

    private func bitwardenLocalItem(from entry: LocalNoteEntry, folderID: String? = nil, folderName: String? = nil) -> BitwardenLocalItemSyncItem {
        BitwardenLocalItemSyncItem(
            localID: entry.id,
            kind: .secureNote,
            title: entry.title,
            notes: entry.body,
            folderID: folderID,
            folderName: folderName
        )
    }

    private func bitwardenLocalItem(from entry: LocalCardEntry, folderID: String? = nil) -> BitwardenLocalItemSyncItem {
        BitwardenLocalItemSyncItem(
            localID: entry.id,
            kind: .card,
            title: entry.title,
            notes: entry.notes,
            folderID: folderID,
            folderName: entry.issuer.nonBlankValue,
            cardholderName: entry.cardholderName,
            cardNumber: entry.number,
            cardExpiryMonth: entry.expiryMonth,
            cardExpiryYear: entry.expiryYear,
            cardCode: entry.cvv,
            cardBrand: entry.network
        )
    }

    private func bitwardenLocalItem(from entry: LocalIdentityEntry, folderID: String? = nil) -> BitwardenLocalItemSyncItem {
        BitwardenLocalItemSyncItem(
            localID: entry.id,
            kind: .identity,
            title: entry.title,
            username: entry.fullName,
            notes: entry.notes,
            folderID: folderID,
            folderName: entry.issuer.nonBlankValue,
            identityFullName: entry.fullName,
            identityDocumentNumber: entry.documentNumber,
            identityIssuer: entry.issuer,
            identityCountry: entry.country
        )
    }

    private func bitwardenLocalItem(from entry: LocalPasskeyEntry, folderID: String? = nil, folderName: String? = nil) -> BitwardenLocalItemSyncItem {
        let relyingPartyID = entry.relyingPartyID.trimmingCharacters(in: .whitespacesAndNewlines)
        return BitwardenLocalItemSyncItem(
            localID: entry.id,
            kind: .passkey,
            title: entry.title,
            username: entry.username,
            url: relyingPartyID.isEmpty ? "" : "https://\(relyingPartyID)",
            notes: entry.notes,
            folderID: folderID,
            folderName: folderName,
            passkeyRelyingPartyID: relyingPartyID,
            passkeyRelyingPartyName: entry.title,
            passkeyCredentialID: entry.credentialID,
            passkeyUserHandle: entry.userHandle,
            passkeyPublicKeyCOSE: entry.publicKeyCOSE,
            passkeyPrivateKeyReference: entry.privateKeyReference,
            passkeyPublicKeyAlgorithm: "ECDSA",
            passkeyCounter: "0",
            passkeyDiscoverable: true
        )
    }

    private func makeBitwardenItemSyncPlan(
        remoteItems: [BitwardenSyncItem],
        previousStates: [BitwardenItemSyncState],
        folderStates: [BitwardenFolderSyncState] = []
    ) -> BitwardenItemSyncPlan {
        let folderStateByProjectID = Dictionary(uniqueKeysWithValues: folderStates.map { ($0.localID, $0) })
        let localLoginItems: [BitwardenLocalItemSyncItem] = loginEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID, folderName: folderStateByProjectID[$0.projectID]?.name)
        }
        let localNoteItems: [BitwardenLocalItemSyncItem] = noteEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID, folderName: folderStateByProjectID[$0.projectID]?.name)
        }
        let localCardItems: [BitwardenLocalItemSyncItem] = cardEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID)
        }
        let localIdentityItems: [BitwardenLocalItemSyncItem] = identityEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID)
        }
        let localPasskeyItems: [BitwardenLocalItemSyncItem] = passkeyEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID, folderName: folderStateByProjectID[$0.projectID]?.name)
        }
        let deletedLoginItems: [BitwardenLocalItemSyncItem] = deletedLoginEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID, folderName: folderStateByProjectID[$0.projectID]?.name)
        }
        let deletedNoteItems: [BitwardenLocalItemSyncItem] = deletedNoteEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID, folderName: folderStateByProjectID[$0.projectID]?.name)
        }
        let deletedCardItems: [BitwardenLocalItemSyncItem] = deletedCardEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID)
        }
        let deletedIdentityItems: [BitwardenLocalItemSyncItem] = deletedIdentityEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID)
        }
        let deletedPasskeyItems: [BitwardenLocalItemSyncItem] = deletedPasskeyEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID, folderName: folderStateByProjectID[$0.projectID]?.name)
        }
        let localItems = localLoginItems + localNoteItems + localCardItems + localIdentityItems + localPasskeyItems
        let deletedLocalItems = deletedLoginItems + deletedNoteItems + deletedCardItems + deletedIdentityItems + deletedPasskeyItems

        return BitwardenItemSyncPlanner().plan(
            localItems: localItems,
            deletedLocalItems: deletedLocalItems,
            remoteItems: remoteItems,
            previousStates: previousStates
        )
    }

    private func makeBitwardenSendSyncPlan(
        remoteSends: [BitwardenSendSyncItem],
        previousStates: [BitwardenSendSyncState]
    ) -> BitwardenSendSyncPlan {
        BitwardenSendSyncPlanner().plan(
            localSends: sendEntries.map { entry in
                BitwardenLocalSendSyncItem(
                    localID: entry.id,
                    title: entry.title,
                    body: entry.body,
                    notes: entry.notes,
                    expiresAt: entry.expiresAt,
                    maxViews: entry.maxViews
                )
            },
            deletedLocalSends: deletedSendEntries.map { entry in
                BitwardenLocalSendSyncItem(
                    localID: entry.id,
                    title: entry.title,
                    body: entry.body,
                    notes: entry.notes,
                    expiresAt: entry.expiresAt,
                    maxViews: entry.maxViews
                )
            },
            remoteSends: remoteSends,
            previousStates: previousStates
        )
    }

    private func readableCloudFileErrorMessage(
        for error: Error,
        provider kind: CloudFileProviderKind
    ) -> String {
        if let appError = error as? AppCloudFileError {
            return appError.localizedDescription
        }
        if let providerError = error as? CloudFileProviderError {
            return providerError.localizedDescription
        }
        if kind == .oneDrive {
            return readableOneDriveAuthenticationErrorMessage(error)
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "网络不可用，请检查连接后重试。"
            case .timedOut:
                return "\(kind.displayName) 请求超时，请稍后再试。"
            default:
                return "\(kind.displayName) 连接失败，请检查网络后重试。"
            }
        }
        return "\(kind.displayName) 操作失败，请稍后重试。"
    }

    private func readableBitwardenSyncErrorMessage(for error: Error) -> String {
        if let appError = error as? AppBitwardenSyncError {
            return appError.localizedDescription
        }
        if let providerError = error as? BitwardenSyncProviderError {
            return providerError.localizedDescription
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "网络不可用，请检查连接后重试。"
            case .timedOut:
                return "Bitwarden 请求超时，请稍后再试。"
            default:
                return "Bitwarden 连接失败，请检查网络后重试。"
            }
        }
        return "Bitwarden 同步失败，请稍后重试。"
    }

    private func validBitwardenServerURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host,
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return url
    }

    private func sanitizedCloudFileName(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? value
        let sanitized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "未命名文件" : sanitized
    }

    func lockLocalVault() {
        isPrivacyShieldVisible = false
        if let activeVaultSession {
            vaultRepository.closeVault(for: activeVaultSession)
        }
        clearUnlockedVaultSession()
        vaultOperationState = .idle
        autoFillIndexState = .idle
        webDAVBackupState = .idle
        webDAVRestorePreview = nil
        webDAVRestoreVaultPassword = ""
        downloadedWebDAVRestoreBackup = nil
        cloudFileState = .idle
        cloudFileRestorePreview = nil
        downloadedCloudFileRestore = nil
        bitwardenSyncState = .idle
        bitwardenSyncPreview = nil
        clearPendingAndroidEncryptedBackup()
        dismissAttachmentQuickLookPreview()
        try? refreshWidgetSnapshotIfConfigured()
        try? refreshShortcutSnapshotIfConfigured()
    }

    private func rememberVault(_ session: LocalVaultSession) {
        rememberedVaultDescriptor = session.descriptor
        rememberedVaultID = session.handle.vaultID
        try? rememberedVaultStore.save(
            RememberedVaultRecord(
                fileURL: session.descriptor.fileURL,
                displayName: session.descriptor.displayName,
                vaultID: session.handle.vaultID
            )
        )
    }

    private func resolvedRememberedVaultDescriptor(
        _ descriptor: LocalVaultDescriptor,
        fallbackDirectory: URL?
    ) -> LocalVaultDescriptor {
        if FileManager.default.fileExists(atPath: descriptor.fileURL.path) {
            return descriptor
        }

        guard let fallbackDirectory else {
            return descriptor
        }

        let relocatedURL = fallbackDirectory.appendingPathComponent(
            descriptor.fileURL.lastPathComponent,
            isDirectory: false
        )
        guard FileManager.default.fileExists(atPath: relocatedURL.path) else {
            return descriptor
        }

        let relocatedDescriptor = LocalVaultDescriptor(
            fileURL: relocatedURL,
            displayName: descriptor.displayName
        )
        rememberedVaultDescriptor = relocatedDescriptor
        if let rememberedVaultID {
            try? rememberedVaultStore.save(
                RememberedVaultRecord(
                    fileURL: relocatedDescriptor.fileURL,
                    displayName: relocatedDescriptor.displayName,
                    vaultID: rememberedVaultID
                )
            )
        }
        return relocatedDescriptor
    }

    private func readableVaultKeychainErrorMessage(for error: Error) -> String {
        if let appError = error as? AppVaultKeychainError {
            return appError.localizedDescription
        }

        if let securityError = error as? MonicaSecurityError {
            return securityError.localizedDescription
        }

        return error.localizedDescription
    }

    private func readableOneDriveAuthenticationErrorMessage(_ error: Error) -> String {
        if let appError = error as? AppOneDriveAuthenticationError {
            return appError.localizedDescription
        }
        if let providerError = error as? CloudFileProviderError,
           case .authenticationRequired = providerError {
            return "OneDrive 需要先登录。"
        }
        let nsError = error as NSError
        return AppOneDriveAuthenticationError.authenticationFailed(
            domain: nsError.domain,
            code: nsError.code,
            message: DefaultAppOneDriveMSALAuthenticationService.diagnosticMessage(for: nsError)
        ).localizedDescription
    }

    private func clearUnlockedVaultSession() {
        vaultPassword = ""
        vaultState = .locked
        activeVaultName = nil
        activeVaultSession = nil
        activeEntryRepository = nil
        activeProject = nil
        vaultProjects = []
        lastUserActivityAt = nil
        resetVaultQuickFilters()
        loginEntries = []
        deletedLoginEntries = []
        loginPassword = ""
        clearEditingLoginEntry()
        noteEntries = []
        deletedNoteEntries = []
        noteBody = ""
        clearEditingNoteEntry()
        totpEntries = []
        deletedTotpEntries = []
        totpSecret = ""
        totpImportURI = ""
        clearEditingTotpEntry()
        cardEntries = []
        deletedCardEntries = []
        cardNumber = ""
        cardCVV = ""
        clearEditingCardEntry()
        identityEntries = []
        deletedIdentityEntries = []
        identityDocumentNumber = ""
        clearEditingIdentityEntry()
        passkeyEntries = []
        deletedPasskeyEntries = []
        passkeyPrivateKeyReference = ""
        clearEditingPasskeyEntry()
        clearExtendedParityEntries()
        csvImportPreview = nil
        androidBackupImportPreview = nil
        bitwardenSyncState = .idle
        bitwardenSyncPreview = nil
        clearKeePassImportState()
        entryOperationState = .idle
        clearOperationTimelineEvents()
    }

    private func clearVaultAccessAfterFailure() {
        isPrivacyShieldVisible = false
        vaultPassword = ""
        guard activeVaultSession == nil else {
            return
        }

        vaultState = .locked
        activeVaultName = nil
        activeEntryRepository = nil
        activeProject = nil
        vaultProjects = []
        lastUserActivityAt = nil
        resetVaultQuickFilters()
        loginEntries = []
        deletedLoginEntries = []
        loginPassword = ""
        clearEditingLoginEntry()
        noteEntries = []
        deletedNoteEntries = []
        noteBody = ""
        clearEditingNoteEntry()
        totpEntries = []
        deletedTotpEntries = []
        totpSecret = ""
        totpImportURI = ""
        clearEditingTotpEntry()
        cardEntries = []
        deletedCardEntries = []
        cardNumber = ""
        cardCVV = ""
        clearEditingCardEntry()
        identityEntries = []
        deletedIdentityEntries = []
        identityDocumentNumber = ""
        clearEditingIdentityEntry()
        passkeyEntries = []
        deletedPasskeyEntries = []
        passkeyPrivateKeyReference = ""
        clearEditingPasskeyEntry()
        clearExtendedParityEntries()
        entryOperationState = .idle
        autoFillIndexState = .idle
        webDAVBackupState = .idle
        webDAVRestorePreview = nil
        webDAVRestoreVaultPassword = ""
        downloadedWebDAVRestoreBackup = nil
        bitwardenSyncState = .idle
        bitwardenSyncPreview = nil
        clearPendingAndroidEncryptedBackup()
        clearKeePassImportState()
    }

    private func clearPendingAndroidEncryptedBackup() {
        pendingAndroidEncryptedBackupData = nil
        pendingAndroidEncryptedBackupFileName = nil
        androidBackupDecryptPassword = ""
    }

    private func clearKeePassImportState(
        preservingLastMetadataImportReferences: Bool = false
    ) {
        keePassImportPreview = nil
        keePassReadOnlySnapshot = nil
        keePassReadOnlyImportPlan = nil
        keePassPendingDatabaseData = nil
        keePassPendingDatabaseName = nil
        keePassSourceFileURL = nil
        keePassCloudFileSource = nil
        keePassUnlockPassword = ""
        keePassKeyFileData = nil
        keePassKeyFileName = ""
        keePassLastSuccessfulUnlockCredentials = nil
        if !preservingLastMetadataImportReferences {
            keePassLastMetadataImportReferences = []
        }
    }

    private func clearExtendedParityEntries() {
        sshKeyEntries = []
        deletedSshKeyEntries = []
        sshKeySearchQuery = ""
        showFavoriteSshKeyEntriesOnly = false
        sshKeyPrivateKeyReference = ""
        clearEditingSshKeyEntry()
        apiTokenEntries = []
        deletedApiTokenEntries = []
        apiTokenSearchQuery = ""
        showFavoriteApiTokenEntriesOnly = false
        apiTokenToken = ""
        clearEditingApiTokenEntry()
        wifiEntries = []
        deletedWifiEntries = []
        wifiSearchQuery = ""
        showFavoriteWifiEntriesOnly = false
        wifiPassword = ""
        clearEditingWifiEntry()
        sendEntries = []
        deletedSendEntries = []
        sendSearchQuery = ""
        showFavoriteSendEntriesOnly = false
        sendBody = ""
        clearEditingSendEntry()
        attachmentEntries = []
        deletedAttachmentEntries = []
        attachmentSearchQuery = ""
        dismissAttachmentQuickLookPreview()
    }

    private func requireActiveVaultSession() throws -> LocalVaultSession {
        guard vaultState == .unlocked,
              let activeVaultSession else {
            throw AppWebDAVBackupError.vaultLocked
        }
        return activeVaultSession
    }

    private func readKeePassSnapshotTryingCredentialCandidates(
        database: Data,
        sourceName: String?,
        credentials: KeePassUnlockCredentials
    ) throws -> (snapshot: KeePassReadOnlySnapshot, credentials: KeePassUnlockCredentials) {
        let candidates = credentials.credentialCandidates
        guard !candidates.isEmpty else {
            let snapshot = try keePassDatabaseReader.readSnapshot(
                database: database,
                sourceName: sourceName,
                credentials: credentials
            )
            return (snapshot, credentials)
        }

        var attemptedLabels: [String] = []
        for candidate in candidates {
            attemptedLabels.append(candidate.label)
            let attemptCredentials = KeePassUnlockCredentials(
                password: candidate.password,
                keyFile: candidate.keyMaterial,
                keyFileName: credentials.keyFileName,
                candidateLabel: candidate.label
            )
            do {
                let snapshot = try keePassDatabaseReader.readSnapshot(
                    database: database,
                    sourceName: sourceName,
                    credentials: attemptCredentials
                )
                return (snapshot, attemptCredentials)
            } catch let error as KeePassOperationError where error.code == .invalidCredential {
                continue
            }
        }

        throw KeePassOperationError(
            code: .invalidCredential,
            message: KeePassCredentialSupport.invalidCredentialMessage(attemptedLabels: attemptedLabels)
        )
    }

    private func currentKeePassKdbxEnvelope() throws -> KeePassKdbxPayloadEnvelope {
        guard let databaseData = keePassPendingDatabaseData else {
            let message = "请先选择 KDBX 数据库文件"
            throw KeePassOperationError(code: .formatUnsupported, message: message)
        }
        return try KeePassKdbxPayloadEnvelope.parse(databaseData)
    }

    private func keePassKdbxWritebackParameters() throws -> (
        envelope: KeePassKdbxPayloadEnvelope,
        cipher: KeePassKdbxCipherAlgorithm,
        compression: KeePassKdbxCompressionAlgorithm,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs,
        kdfParameters: KeePassKdbxKdfParameters,
        credentials: KeePassUnlockCredentials
    ) {
        let envelope = try currentKeePassKdbxEnvelope()
        guard let cipher = envelope.headerSummary.cryptoSummary?.cipher else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX cipher 参数缺失；请确认文件未损坏。"
            )
        }
        guard let compression = envelope.headerSummary.cryptoSummary?.compression else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX compression 参数缺失；请确认文件未损坏。"
            )
        }
        guard let kdfParameters = envelope.headerSummary.kdfParameters else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "KDBX KDF 参数缺失；请确认文件未损坏。"
            )
        }
        let credentials = keePassLastSuccessfulUnlockCredentials ?? KeePassUnlockCredentials(
            password: keePassUnlockPassword,
            keyFile: keePassKeyFileData,
            keyFileName: keePassKeyFileName
        )
        return (
            envelope,
            cipher,
            compression,
            KeePassFormatInspector.parseKdbxPayloadCryptoInputs(from: envelope),
            kdfParameters,
            credentials
        )
    }

    private func makeKeePassKdbx3WritebackRequest(
        snapshot: KeePassReadOnlySnapshot
    ) throws -> KeePassKdbx3WritebackRequest {
        let parameters = try keePassKdbxWritebackParameters()
        guard parameters.envelope.headerSummary.formatVersion == .kdbx3 else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "当前仅支持 KDBX3 数据库写回。"
            )
        }
        return KeePassKdbx3WritebackRequest(
            snapshot: snapshot,
            credentials: parameters.credentials,
            cipher: parameters.cipher,
            compression: parameters.compression,
            cryptoInputs: parameters.cryptoInputs,
            kdfParameters: parameters.kdfParameters,
            existingHeaderBytes: parameters.envelope.headerBytes
        )
    }

    private func makeKeePassKdbx4WritebackRequest(
        snapshot: KeePassReadOnlySnapshot
    ) throws -> KeePassKdbx4WritebackRequest {
        let parameters = try keePassKdbxWritebackParameters()
        let envelope = parameters.envelope
        guard envelope.headerSummary.formatVersion == .kdbx4 else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: "当前仅支持 KDBX4 数据库写回。"
            )
        }
        return KeePassKdbx4WritebackRequest(
            snapshot: snapshot,
            credentials: parameters.credentials,
            cipher: parameters.cipher,
            compression: parameters.compression,
            cryptoInputs: parameters.cryptoInputs,
            kdfParameters: parameters.kdfParameters,
            existingHeaderBytes: envelope.headerBytes
        )
    }

    private func activateVaultCategory(
        _ project: LocalVaultProject,
        entryRepository: LocalVaultEntryRepository
    ) throws {
        activeProject = project
        try refreshAllEntryLists(projectID: project.id, entryRepository: entryRepository)
        resetVaultQuickFilters()
        selectedVaultQuickFilterID = "category-\(project.id)"
    }

    private func ensureActiveProject(
        projectTitle: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> LocalVaultProject {
        if let activeProject {
            return activeProject
        }
        let project = try entryRepository.createProject(title: projectTitle)
        activeProject = project
        if !vaultProjects.contains(where: { $0.id == project.id }) {
            vaultProjects.append(project)
        }
        return project
    }

    private func ensureKeePassImportProject(
        baseTitle: String,
        groupPath: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> LocalVaultProject {
        let title = keePassImportProjectTitle(baseTitle: baseTitle, groupPath: groupPath)
        if let project = vaultProjects.first(where: { $0.title == title }) {
            return project
        }
        let project = try entryRepository.createProject(title: title)
        vaultProjects.append(project)
        return project
    }

    private func keePassImportProjectTitle(baseTitle: String, groupPath: String) -> String {
        let trimmedBase = baseTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmedBase.isEmpty ? "KeePass" : trimmedBase
        let components = groupPath
            .split(separator: "/")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !components.isEmpty else {
            return base
        }
        return ([base] + components).joined(separator: " / ")
    }

    private func keePassTotpDraft(
        for candidate: KeePassReadOnlyImportCandidate
    ) -> LocalTotpEntryDraft {
        let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseTitle = title.isEmpty ? "KeePass TOTP" : title
        let decodedTotp = candidate.decodedTotp
        return LocalTotpEntryDraft(
            title: keePassTotpPlaceholderTitle(from: baseTitle),
            secret: decodedTotp?.secret ?? "",
            issuer: decodedTotp?.issuer?.nonBlankValue ?? baseTitle,
            accountName: decodedTotp?.accountName?.nonBlankValue ?? candidate.username,
            period: decodedTotp?.period ?? 30,
            digits: decodedTotp?.digits ?? 6,
            algorithm: decodedTotp?.algorithm?.nonBlankValue ?? "SHA1",
            otpType: "TOTP",
            counter: 0
        )
    }

    private func keePassLoginNotes(for candidate: KeePassReadOnlyImportCandidate) -> String {
        var sections: [String] = []
        let notes = candidate.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            sections.append(notes)
        }
        let fieldLines = candidate.customFields
            .filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { field in
                let title = field.title.trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(title): \(field.value)"
            }
        if !fieldLines.isEmpty {
            sections.append((["KeePass 字段："] + fieldLines).joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    private func keePassTotpPlaceholderTitle(from baseTitle: String) -> String {
        let lowercased = baseTitle.lowercased()
        if lowercased.contains("totp") ||
            lowercased.contains("2fa") ||
            lowercased.contains("authenticator") {
            return baseTitle
        }
        return "\(baseTitle) TOTP"
    }

    private func keePassAttachmentFileName(_ attachment: KeePassReadOnlyAttachment) -> String {
        let trimmed = attachment.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "KeePass Attachment"
        }
        return sanitizedAttachmentPreviewFileName(trimmed)
    }

    private func keePassDecodedAttachmentLocalPath(
        _ attachment: KeePassReadOnlyAttachment,
        fileName: String
    ) -> String {
        let rawIdentifier = attachment.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = rawIdentifier.isEmpty ? UUID().uuidString : rawIdentifier
        return sanitizedAttachmentPreviewFileName(
            "keepass-kdbx-attachment-\(identifier)-\(fileName)"
        )
    }

    private func createCSVImportedItem(
        _ item: VaultCSVItemDraft,
        projectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> String? {
        switch item {
        case .login(let draft):
            return try entryRepository.createLoginEntry(projectID: projectID, draft: draft).id
        case .note(let draft):
            return try entryRepository.createNoteEntry(projectID: projectID, draft: draft).id
        case .totp(let draft):
            return try entryRepository.createTotpEntry(projectID: projectID, draft: draft).id
        case .card(let draft):
            return try entryRepository.createCardEntry(projectID: projectID, draft: draft).id
        case .identity(let draft):
            return try entryRepository.createIdentityEntry(projectID: projectID, draft: draft).id
        case .passkey(let draft):
            return try entryRepository.createPasskeyEntry(projectID: projectID, draft: draft).id
        case .sshKey(let draft):
            return try entryRepository.createSshKeyEntry(projectID: projectID, draft: draft).id
        case .apiToken(let draft):
            return try entryRepository.createApiTokenEntry(projectID: projectID, draft: draft).id
        case .wifi(let draft):
            return try entryRepository.createWifiEntry(projectID: projectID, draft: draft).id
        case .send(let draft):
            return try entryRepository.createSendEntry(projectID: projectID, draft: draft).id
        }
    }

    private func refreshAllEntryLists(
        projectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws {
        loginEntries = try entryRepository.listLoginEntries(projectID: projectID)
        deletedLoginEntries = try entryRepository.listDeletedLoginEntries(projectID: projectID)
        noteEntries = try entryRepository.listNoteEntries(projectID: projectID)
        deletedNoteEntries = try entryRepository.listDeletedNoteEntries(projectID: projectID)
        totpEntries = try entryRepository.listTotpEntries(projectID: projectID)
        deletedTotpEntries = try entryRepository.listDeletedTotpEntries(projectID: projectID)
        cardEntries = try entryRepository.listCardEntries(projectID: projectID)
        deletedCardEntries = try entryRepository.listDeletedCardEntries(projectID: projectID)
        identityEntries = try entryRepository.listIdentityEntries(projectID: projectID)
        deletedIdentityEntries = try entryRepository.listDeletedIdentityEntries(projectID: projectID)
        passkeyEntries = try entryRepository.listPasskeyEntries(projectID: projectID)
        deletedPasskeyEntries = try entryRepository.listDeletedPasskeyEntries(projectID: projectID)
        sshKeyEntries = try entryRepository.listSshKeyEntries(projectID: projectID)
        deletedSshKeyEntries = try entryRepository.listDeletedSshKeyEntries(projectID: projectID)
        apiTokenEntries = try entryRepository.listApiTokenEntries(projectID: projectID)
        deletedApiTokenEntries = try entryRepository.listDeletedApiTokenEntries(projectID: projectID)
        wifiEntries = try entryRepository.listWifiEntries(projectID: projectID)
        deletedWifiEntries = try entryRepository.listDeletedWifiEntries(projectID: projectID)
        sendEntries = try entryRepository.listSendEntries(projectID: projectID)
        deletedSendEntries = try entryRepository.listDeletedSendEntries(projectID: projectID)
        attachmentEntries = try entryRepository.listAttachmentMetadata(projectID: projectID)
        deletedAttachmentEntries = try entryRepository.listDeletedAttachmentMetadata(projectID: projectID)
        try refreshWidgetSnapshotIfConfigured()
    }

    private func clearAllEntryLists() {
        loginEntries = []
        deletedLoginEntries = []
        noteEntries = []
        deletedNoteEntries = []
        totpEntries = []
        deletedTotpEntries = []
        cardEntries = []
        deletedCardEntries = []
        identityEntries = []
        deletedIdentityEntries = []
        passkeyEntries = []
        deletedPasskeyEntries = []
        clearExtendedParityEntries()
    }

    private func csvExportDrafts() -> [VaultCSVItemDraft] {
        var drafts: [VaultCSVItemDraft] = []
        drafts += loginEntries.map {
            .login(LocalLoginEntryDraft(
                title: $0.title,
                username: $0.username,
                password: $0.password,
                url: $0.url
            ))
        }
        drafts += noteEntries.map {
            .note(LocalNoteEntryDraft(title: $0.title, body: $0.body))
        }
        drafts += totpEntries.map {
            .totp(LocalTotpEntryDraft(
                title: $0.title,
                secret: $0.secret,
                issuer: $0.issuer,
                accountName: $0.accountName,
                period: $0.period,
                digits: $0.digits,
                algorithm: $0.algorithm,
                otpType: $0.otpType,
                counter: $0.counter
            ))
        }
        drafts += cardEntries.map {
            .card(LocalCardEntryDraft(
                title: $0.title,
                cardholderName: $0.cardholderName,
                number: $0.number,
                expiryMonth: $0.expiryMonth,
                expiryYear: $0.expiryYear,
                cvv: $0.cvv,
                issuer: $0.issuer,
                network: $0.network,
                notes: $0.notes
            ))
        }
        drafts += identityEntries.map {
            .identity(LocalIdentityEntryDraft(
                title: $0.title,
                documentType: $0.documentType,
                fullName: $0.fullName,
                documentNumber: $0.documentNumber,
                issuer: $0.issuer,
                country: $0.country,
                issueDate: $0.issueDate,
                expiryDate: $0.expiryDate,
                notes: $0.notes
            ))
        }
        drafts += passkeyEntries.map {
            .passkey(LocalPasskeyEntryDraft(
                title: $0.title,
                relyingPartyID: $0.relyingPartyID,
                username: $0.username,
                userHandle: $0.userHandle,
                credentialID: $0.credentialID,
                publicKeyCOSE: $0.publicKeyCOSE,
                privateKeyReference: $0.privateKeyReference,
                notes: $0.notes
            ))
        }
        drafts += sshKeyEntries.map {
            .sshKey(LocalSshKeyEntryDraft(
                title: $0.title,
                username: $0.username,
                host: $0.host,
                publicKey: $0.publicKey,
                privateKeyReference: $0.privateKeyReference,
                passphraseHint: $0.passphraseHint,
                notes: $0.notes
            ))
        }
        drafts += apiTokenEntries.map {
            .apiToken(LocalApiTokenEntryDraft(
                title: $0.title,
                issuer: $0.issuer,
                accountName: $0.accountName,
                token: $0.token,
                scopes: $0.scopes,
                expiresAt: $0.expiresAt,
                notes: $0.notes
            ))
        }
        drafts += wifiEntries.map {
            .wifi(LocalWifiEntryDraft(
                title: $0.title,
                ssid: $0.ssid,
                securityType: $0.securityType,
                password: $0.password,
                hidden: $0.hidden,
                notes: $0.notes
            ))
        }
        drafts += sendEntries.map {
            .send(LocalSendEntryDraft(
                title: $0.title,
                body: $0.body,
                expiresAt: $0.expiresAt,
                maxViews: $0.maxViews,
                notes: $0.notes
            ))
        }
        return drafts
    }

    private func makeWebDAVEndpoint() throws -> WebDAVEndpoint {
        let baseURLString = webDAVBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: baseURLString),
              baseURL.scheme != nil,
              baseURL.host() != nil else {
            throw AppWebDAVBackupError.invalidEndpoint
        }

        let username = webDAVUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            throw AppWebDAVBackupError.emptyUsername
        }
        guard !webDAVPassword.isEmpty else {
            throw AppWebDAVBackupError.emptyPassword
        }

        return WebDAVEndpoint(
            baseURL: baseURL,
            username: username,
            password: webDAVPassword
        )
    }

    private func normalizedWebDAVRemoteFileName(fallback: String?) throws -> String {
        let normalized = webDAVRemoteFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty {
            return normalized
        }
        if let fallback, !fallback.isEmpty {
            return fallback
        }
        throw AppWebDAVBackupError.emptyRemoteFileName
    }

    private func replaceVaultFile(at destinationURL: URL, with data: Data) throws {
        let directoryURL = destinationURL.deletingLastPathComponent()
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).restore-\(UUID().uuidString)",
            isDirectory: false
        )
        try data.write(to: temporaryURL, options: [.atomic])
        _ = try FileManager.default.replaceItemAt(
            destinationURL,
            withItemAt: temporaryURL,
            backupItemName: nil,
            options: [.usingNewMetadataOnly]
        )
    }

    private func appendOperationTimelineEvent(
        action: AppOperationTimelineAction,
        itemKind: UnifiedVaultItemKind,
        itemID: String,
        itemTitle: String
    ) {
        nextOperationTimelineEventSequence += 1
        let trimmedTitle = itemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        operationTimelineEvents.insert(
            AppOperationTimelineEvent(
                id: "operation-\(nextOperationTimelineEventSequence)-\(itemID)",
                action: action,
                itemKind: itemKind,
                itemID: itemID,
                itemTitle: trimmedTitle,
                occurredAt: Date()
            ),
            at: 0
        )
        if operationTimelineEvents.count > 50 {
            operationTimelineEvents.removeLast(operationTimelineEvents.count - 50)
        }
    }

    private func sanitizedAttachmentPreviewFileName(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? value
        let sanitized = normalized.unicodeScalars
            .map { scalar -> String in
                switch scalar.value {
                case 48...57, 65...90, 97...122:
                    String(scalar)
                case 45, 46, 95:
                    String(scalar)
                default:
                    "_"
                }
            }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return sanitized.isEmpty ? "attachment-\(UUID().uuidString).bin" : sanitized
    }

    private func sanitizedKeePassFileName(_ value: String) -> String? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? value
        let sanitized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? nil : sanitized
    }

    private func clearOperationTimelineEvents() {
        operationTimelineEvents = []
        nextOperationTimelineEventSequence = 0
    }

    private func validateDownloadedWebDAVRestore(
        _ downloaded: WebDAVDownloadedBackup,
        near destinationURL: URL,
        password: String,
        deviceID: String
    ) throws {
        let directoryURL = destinationURL.deletingLastPathComponent()
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(downloaded.fileName).validate-\(UUID().uuidString).mdbx",
            isDirectory: false
        )

        do {
            try downloaded.data.write(to: temporaryURL, options: [.atomic])
            let validationSession = try vaultRepository.openVault(
                at: temporaryURL,
                password: password,
                deviceID: deviceID
            )
            vaultRepository.closeVault(for: validationSession)
            try? FileManager.default.removeItem(at: temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw AppWebDAVBackupError.restoreValidationFailed
        }
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isPrivacyShieldVisible = false
            refreshNotificationPermissionStatus()
            lockIfIdle()
        case .inactive:
            isPrivacyShieldVisible = vaultState == .unlocked
        case .background:
            guard vaultState == .unlocked else {
                return
            }
            lockLocalVault()
            isPrivacyShieldVisible = true
        @unknown default:
            break
        }
    }

    func recordUserActivity(at date: Date = Date()) {
        guard vaultState == .unlocked else {
            return
        }

        lastUserActivityAt = date
    }

    func updateAutoLockPolicy(_ policy: AppAutoLockPolicy, now: Date = Date()) {
        autoLockPolicy = policy
        recordUserActivity(at: now)
    }

    func lockIfIdle(now: Date = Date()) {
        guard vaultState == .unlocked,
              let lastUserActivityAt,
              now.timeIntervalSince(lastUserActivityAt) >= autoLockPolicy.idleTimeout
        else {
            return
        }

        lockLocalVault()
    }

    func clearEditingLoginEntry() {
        editingLoginEntryID = nil
        editingLoginTitle = ""
        editingLoginUsername = ""
        editingLoginPassword = ""
        editingLoginURL = ""
        editingLoginFavorite = false
    }

    func clearEditingNoteEntry() {
        editingNoteEntryID = nil
        editingNoteTitle = ""
        editingNoteBody = ""
        editingNoteFavorite = false
    }

    func clearEditingTotpEntry() {
        editingTotpEntryID = nil
        editingTotpTitle = ""
        editingTotpSecret = ""
        editingTotpIssuer = ""
        editingTotpAccountName = ""
        editingTotpPeriod = 30
        editingTotpDigits = 6
        editingTotpAlgorithm = "SHA1"
        editingTotpFavorite = false
    }

    func clearEditingCardEntry() {
        editingCardEntryID = nil
        editingCardTitle = ""
        editingCardholderName = ""
        editingCardNumber = ""
        editingCardExpiryMonth = ""
        editingCardExpiryYear = ""
        editingCardCVV = ""
        editingCardIssuer = ""
        editingCardNetwork = ""
        editingCardNotes = ""
        editingCardFavorite = false
    }

    func clearEditingIdentityEntry() {
        editingIdentityEntryID = nil
        editingIdentityTitle = ""
        editingIdentityDocumentType = ""
        editingIdentityFullName = ""
        editingIdentityDocumentNumber = ""
        editingIdentityIssuer = ""
        editingIdentityCountry = ""
        editingIdentityIssueDate = ""
        editingIdentityExpiryDate = ""
        editingIdentityNotes = ""
        editingIdentityFavorite = false
    }

    func clearEditingPasskeyEntry() {
        editingPasskeyEntryID = nil
        editingPasskeyTitle = ""
        editingPasskeyRelyingPartyID = ""
        editingPasskeyUsername = ""
        editingPasskeyUserHandle = ""
        editingPasskeyCredentialID = ""
        editingPasskeyPublicKeyCOSE = ""
        editingPasskeyPrivateKeyReference = ""
        editingPasskeyNotes = ""
        editingPasskeyFavorite = false
    }

    func clearEditingSshKeyEntry() {
        editingSshKeyEntryID = nil
        editingSshKeyTitle = ""
        editingSshKeyUsername = ""
        editingSshKeyHost = ""
        editingSshKeyPublicKey = ""
        editingSshKeyPrivateKeyReference = ""
        editingSshKeyPassphraseHint = ""
        editingSshKeyNotes = ""
        editingSshKeyFavorite = false
    }

    func clearEditingApiTokenEntry() {
        editingApiTokenEntryID = nil
        editingApiTokenTitle = ""
        editingApiTokenIssuer = ""
        editingApiTokenAccountName = ""
        editingApiTokenToken = ""
        editingApiTokenScopes = ""
        editingApiTokenExpiresAt = ""
        editingApiTokenNotes = ""
        editingApiTokenFavorite = false
    }

    func clearEditingWifiEntry() {
        editingWifiEntryID = nil
        editingWifiTitle = ""
        editingWifiSSID = ""
        editingWifiSecurityType = "WPA2"
        editingWifiPassword = ""
        editingWifiHidden = false
        editingWifiNotes = ""
        editingWifiFavorite = false
    }

    func clearEditingSendEntry() {
        editingSendEntryID = nil
        editingSendTitle = ""
        editingSendBody = ""
        editingSendExpiresAt = ""
        editingSendMaxViews = 1
        editingSendNotes = ""
        editingSendFavorite = false
    }

    private func serviceIdentifiers(for urlString: String) -> [String] {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        var identifiers: [String] = []
        if let url = URL(string: trimmed),
           let host = url.host(),
           !host.isEmpty {
            identifiers.append(host)
        }
        identifiers.append(trimmed)
        return Array(NSOrderedSet(array: identifiers)) as? [String] ?? identifiers
    }

    private func normalizedAutoFillSaveRequest(
        _ request: AppAutoFillCredentialSaveRequest
    ) throws -> AppAutoFillCredentialSaveRequest {
        let serviceIdentifier = request.serviceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = request.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = request.password
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serviceIdentifier.isEmpty else {
            throw LocalVaultRepositoryError.emptyEntryTitle
        }
        guard !username.isEmpty else {
            throw LocalVaultRepositoryError.emptyEntryTitle
        }
        guard !password.isEmpty else {
            throw LocalVaultRepositoryError.emptyPassword
        }
        return AppAutoFillCredentialSaveRequest(
            serviceIdentifier: serviceIdentifier,
            username: username,
            password: password,
            title: title
        )
    }

    private func autoFillSaveTitle(
        for request: AppAutoFillCredentialSaveRequest
    ) -> String {
        if !request.title.isEmpty {
            return request.title
        }
        return serviceIdentifiers(for: request.serviceIdentifier).first ?? "AutoFill 登录"
    }

    private func matchingLoginEntry(
        for request: AppAutoFillCredentialSaveRequest,
        in entries: [LocalLoginEntry]
    ) -> LocalLoginEntry? {
        let username = request.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestIdentifiers = Set(serviceIdentifiers(for: request.serviceIdentifier).map(normalizedAutoFillIdentifier))
        guard !username.isEmpty, !requestIdentifiers.isEmpty else {
            return nil
        }

        return entries.first { entry in
            guard entry.username.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(username) == .orderedSame else {
                return false
            }
            let entryIdentifiers = Set(serviceIdentifiers(for: entry.url).map(normalizedAutoFillIdentifier))
            return !entryIdentifiers.isDisjoint(with: requestIdentifiers)
        }
    }

    private func normalizedAutoFillIdentifier(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: trimmed),
           let host = url.host(),
           !host.isEmpty {
            return host.lowercased()
        }
        return trimmed
    }

    private func autoFillCredentialIdentities(
        for entry: LocalLoginEntry
    ) -> [AppAutoFillCredentialIdentity] {
        let username = entry.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            return []
        }

        return serviceIdentifiers(for: entry.url).map { serviceIdentifier in
            AppAutoFillCredentialIdentity(
                recordIdentifier: entry.id,
                serviceIdentifier: serviceIdentifier,
                username: username
            )
        }
    }

    private func autoFillPasskeyCredentialIdentity(
        for entry: LocalPasskeyEntry
    ) -> AppAutoFillPasskeyCredentialIdentity? {
        let relyingPartyIdentifier = entry.relyingPartyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = entry.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !relyingPartyIdentifier.isEmpty,
              !username.isEmpty,
              let credentialID = Data(base64Encoded: entry.credentialID),
              !credentialID.isEmpty,
              let userHandle = Data(base64Encoded: entry.userHandle),
              !userHandle.isEmpty
        else {
            return nil
        }

        return AppAutoFillPasskeyCredentialIdentity(
            recordIdentifier: entry.id,
            relyingPartyIdentifier: relyingPartyIdentifier,
            username: username,
            credentialID: credentialID,
            userHandle: userHandle
        )
    }

    private func totpAlgorithm(from value: String) -> TotpAlgorithm {
        TotpAlgorithm(rawValue: value.uppercased()) ?? .sha1
    }

    func runMDBXVerification() {
        mdbxVerificationState = .running

        Task {
            do {
                let directory = FileManager.default.urls(
                    for: .documentDirectory,
                    in: .userDomainMask
                ).first ?? FileManager.default.temporaryDirectory
                let result = try MonicaMDBXTechnicalVerifier.runProjectScopedLoginRoundTrip(
                    in: directory
                )
                mdbxVerificationState = .passed(
                    "保险库 \(result.vaultID.prefix(8)) / \(result.entryTitle)"
                )
            } catch {
                mdbxVerificationState = .failed(error.localizedDescription)
            }
        }
    }
}

enum MonicaAppTab: Hashable {
    case passwords
    case wallet
    case totp
    case passkeys
    case notes
    case generator
    case settings

    static let phaseOneAndroidParityTabs: [MonicaAppTab] = [
        .passwords,
        .wallet,
        .totp,
        .passkeys,
        .notes,
        .generator,
        .settings
    ]

    var title: String {
        switch self {
        case .passwords:
            return "密码"
        case .totp:
            return "验证"
        case .notes:
            return "笔记"
        case .wallet:
            return "卡包"
        case .passkeys:
            return "通行"
        case .generator:
            return "生成"
        case .settings:
            return "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .passwords:
            return "key.fill"
        case .totp:
            return "timer"
        case .notes:
            return "note.text"
        case .wallet:
            return "creditcard"
        case .passkeys:
            return "key.horizontal.fill"
        case .generator:
            return "sparkles"
        case .settings:
            return "gearshape"
        }
    }

    var coreItemKind: UnifiedVaultItemKind? {
        switch self {
        case .passwords:
            return .login
        case .totp:
            return .totp
        case .notes:
            return .note
        case .wallet:
            return .card
        case .passkeys:
            return .passkey
        case .generator, .settings:
            return nil
        }
    }
}

enum AndroidParityToolbarAction: Hashable, Sendable {
    case folder
    case search
    case more
}

struct VaultItemRoute: Hashable, Sendable {
    let kind: UnifiedVaultItemKind
    let entryID: String
}

enum VaultItemEditorMode: Hashable, Sendable {
    case add(UnifiedVaultItemKind)
    case edit(VaultItemRoute)

    var kind: UnifiedVaultItemKind {
        switch self {
        case .add(let kind):
            return kind
        case .edit(let route):
            return route.kind
        }
    }

    var isAdding: Bool {
        if case .add = self {
            return true
        }
        return false
    }
}

struct VaultItemDisplayModel: Identifiable, Hashable, Sendable {
    let id: String
    let kind: UnifiedVaultItemKind
    let title: String
    let subtitle: String
    let detail: String
    let favorite: Bool
    let accent: String
}

enum VaultState: String, Sendable {
    case locked = "已锁定"
    case unlocked = "已解锁"
    case needsSetup = "需要设置"
}

enum VaultOperationState: Sendable, Equatable {
    case idle
    case running
    case succeeded(String)
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            return "就绪"
        case .running:
            return "处理中"
        case .succeeded(let name):
            return "已创建 \(name)"
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

enum EntryOperationState: Sendable, Equatable {
    case idle
    case running
    case succeeded(String)
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            return "就绪"
        case .running:
            return "处理中"
        case .succeeded(let title):
            return "已保存 \(title)"
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

enum AutoFillIndexState: Sendable, Equatable {
    case idle
    case running
    case succeeded(Int)
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            return "就绪"
        case .running:
            return "处理中"
        case .succeeded(let count):
            return "已索引 \(count)"
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

enum VaultKeychainState: Sendable, Equatable {
    case idle
    case running
    case saved(String)
    case unlocked(String)
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            return "就绪"
        case .running:
            return "处理中"
        case .saved(let vaultID):
            return "已保存 \(vaultID.prefix(8))"
        case .unlocked(let vaultID):
            return "已解锁 \(vaultID.prefix(8))"
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

enum WebDAVBackupState: Sendable, Equatable {
    case idle
    case running
    case backupSucceeded(byteCount: Int, sha256: String)
    case restorePreviewReady(fileName: String, byteCount: Int)
    case restoreSucceeded(fileName: String, byteCount: Int)
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            return "就绪"
        case .running:
            return "处理中"
        case .backupSucceeded(let byteCount, _):
            return "已备份 \(byteCount) 字节"
        case .restorePreviewReady(let fileName, let byteCount):
            return "预览 \(fileName) (\(byteCount) 字节)"
        case .restoreSucceeded(let fileName, let byteCount):
            return "已恢复 \(fileName) (\(byteCount) 字节)"
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
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            return "就绪"
        case .running(let provider):
            return "正在处理 \(provider.displayName)"
        case .listed(let provider, let count):
            return "\(provider.displayName) 已列出 \(count) 个文件"
        case .restorePreviewReady(let provider, let fileName, let byteCount):
            return "\(provider.displayName) 预览 \(fileName) (\(byteCount) 字节)"
        case .backupSucceeded(let provider, let fileName, let byteCount):
            return "\(provider.displayName) 已备份 \(fileName) (\(byteCount) 字节)"
        case .writeSucceeded(let provider, let fileName, let byteCount):
            return "\(provider.displayName) 已写回 \(fileName) (\(byteCount) 字节)"
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

enum OneDriveAuthenticationState: Sendable, Equatable {
    case disconnected
    case running
    case connected(accountLabel: String)
    case redirectHandled
    case failed(String)

    var label: String {
        switch self {
        case .disconnected:
            return "OneDrive 未登录"
        case .running:
            return "正在登录 OneDrive"
        case .connected(let accountLabel):
            let normalized = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? "OneDrive 已登录" : "OneDrive 已登录 \(normalized)"
        case .redirectHandled:
            return "OneDrive 登录回调已处理"
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

enum BitwardenAuthenticationState: Sendable, Equatable {
    case disconnected
    case connected(accountLabel: String)
    case failed(String)

    var label: String {
        switch self {
        case .disconnected:
            return "Bitwarden 未登录"
        case .connected(let accountLabel):
            let normalized = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? "Bitwarden 已登录" : "Bitwarden 已登录 \(normalized)"
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
}

enum BitwardenSyncState: Sendable, Equatable {
    case idle
    case running
    case previewReady(itemCount: Int, sendCount: Int)
    case synced(itemCount: Int, sendCount: Int)
    case pushed(acceptedMutationCount: Int, conflictCount: Int)
    case queuedForRetry(mutationCount: Int)
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            return "就绪"
        case .running:
            return "正在处理 Bitwarden"
        case .previewReady(let itemCount, let sendCount):
            return "Bitwarden 已预览 \(itemCount) 个条目，\(sendCount) 个 Send"
        case .synced(let itemCount, let sendCount):
            return "Bitwarden 已同步 \(itemCount) 个条目，\(sendCount) 个 Send"
        case .pushed(let acceptedMutationCount, let conflictCount):
            return "Bitwarden 已推送 \(acceptedMutationCount) 个变更，\(conflictCount) 个冲突"
        case .queuedForRetry(let mutationCount):
            return "Bitwarden 已暂存 \(mutationCount) 个变更，等待网络恢复后重试"
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

enum PlusActivationState: Sendable, Equatable {
    case idle
    case running
    case activated
    case deactivated
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            return "就绪"
        case .running:
            return "处理中"
        case .activated:
            return "Plus 已激活"
        case .deactivated:
            return "Plus 已关闭"
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

enum AppPlusResourceUnlockError: Error, Sendable, Equatable, LocalizedError {
    case serviceUnavailable
    case activationRejected

    var errorDescription: String? {
        switch self {
        case .serviceUnavailable:
            return "Plus 解锁服务不可用。"
        case .activationRejected:
            return "Plus 解锁未通过。"
        }
    }
}

enum AppVaultKeychainError: Error, Sendable, Equatable, LocalizedError {
    case vaultLocked
    case vaultAlreadyUnlocked
    case keychainUnavailable
    case wrappedKeyProviderUnavailable
    case rememberedVaultUnavailable
    case vaultMismatch

    var errorDescription: String? {
        switch self {
        case .vaultLocked:
            return "请先解锁保险库，再启用 Keychain 解锁。"
        case .vaultAlreadyUnlocked:
            return "保险库已经解锁。"
        case .keychainUnavailable:
            return "Keychain 解锁不可用。"
        case .wrappedKeyProviderUnavailable:
            return "保险库安全密钥提供器不可用。"
        case .rememberedVaultUnavailable:
            return "没有可通过 Keychain 解锁的已记住保险库。"
        case .vaultMismatch:
            return "已保存的保险库密钥与当前保险库不匹配。"
        }
    }
}

private enum TotpImportSource {
    case manualURI
    case scannedQRCode
}

protocol AppVaultKeychainService: Sendable {
    func saveWrappedKey(_ key: WrappedVaultKey) async throws

    func loadWrappedKeyAfterAuthentication(
        vaultID: String,
        reason: String
    ) async throws -> WrappedVaultKey
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
            return "请先解锁保险库，再使用 WebDAV 备份。"
        case .invalidEndpoint:
            return "请输入有效的 WebDAV 服务器 URL。"
        case .emptyUsername:
            return "请输入 WebDAV 用户名。"
        case .emptyPassword:
            return "请输入 WebDAV 密码。"
        case .emptyRemoteFileName:
            return "请输入远端备份文件名。"
        case .restorePreviewUnavailable:
            return "恢复前请先下载恢复预览。"
        case .emptyRestoreVaultPassword:
            return "请输入待恢复保险库的密码。"
        case .restoreValidationFailed:
            return "无法打开恢复备份，请检查保险库密码。"
        }
    }
}

enum AppCloudFileError: Error, Sendable, Equatable, LocalizedError {
    case providerUnavailable(CloudFileProviderKind)

    var errorDescription: String? {
        switch self {
        case .providerUnavailable(let provider):
            return "\(provider.displayName) 云文件源尚未配置。"
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
}

enum AppOneDriveAuthenticationError: Error, Sendable, Equatable, LocalizedError {
    case serviceUnavailable
    case authenticationCancelled
    case presentationUnavailable
    case invalidRedirect
    case tokenUnavailable
    case authenticationFailed(domain: String, code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .serviceUnavailable:
            return "OneDrive 登录服务尚未配置。"
        case .authenticationCancelled:
            return "OneDrive 登录已取消。"
        case .presentationUnavailable:
            return "OneDrive 登录窗口尚未就绪，请稍后重试。"
        case .invalidRedirect:
            return "OneDrive 登录回调无效，请重试。"
        case .tokenUnavailable:
            return "OneDrive 需要先登录。"
        case .authenticationFailed(let domain, let code, let message):
            let cleanMessage = AppOneDriveAuthenticationError.redactedDiagnosticMessage(message)
            return cleanMessage.isEmpty
                ? "OneDrive 登录失败：\(domain) \(code)"
                : "OneDrive 登录失败：\(domain) \(code) \(cleanMessage)"
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

enum AppKeePassKdbxWritebackError: Error, Sendable, Equatable, LocalizedError {
    case sourceFileUnavailable
    case cloudSourceUnavailable

    var errorDescription: String? {
        switch self {
        case .sourceFileUnavailable:
            return "请先从本地文件选择 KeePass KDBX 数据库，再执行写回。"
        case .cloudSourceUnavailable:
            return "请先从云文件源选择 KeePass KDBX 数据库，再执行写回。"
        }
    }
}

enum AppKeePassSnapshotEditError: Error, Sendable, Equatable, LocalizedError {
    case entryUnavailable
    case attachmentUnavailable
    case entryNotInRecycleBin
    case targetGroupUnavailable

    var errorDescription: String? {
        switch self {
        case .entryUnavailable:
            return "未找到可编辑的 KeePass 条目。"
        case .attachmentUnavailable:
            return "未找到可编辑的 KeePass 附件。"
        case .entryNotInRecycleBin:
            return "该 KeePass 条目不在回收站中。"
        case .targetGroupUnavailable:
            return "未找到可还原到的 KeePass 分组。"
        }
    }
}

protocol AppKeePassKdbxFileWritebackService: Sendable {
    func replaceFile(at url: URL, with data: Data) throws
}

struct FileSystemAppKeePassKdbxFileWritebackService: AppKeePassKdbxFileWritebackService {
    func replaceFile(at url: URL, with data: Data) throws {
        let directoryURL = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(url.lastPathComponent).keepass-writeback-\(UUID().uuidString)",
            isDirectory: false
        )
        try data.write(to: temporaryURL, options: [.atomic])
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(
                url,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: url)
        }
    }
}

enum AppAndroidBackupImportError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedEncryptedBackup(String)
    case encryptedBackupDecryptionFailed(String)
    case encryptedBackupUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedEncryptedBackup(let message),
             .encryptedBackupDecryptionFailed(let message):
            return message
        case .encryptedBackupUnavailable:
            return "请先选择 Android 加密备份文件。"
        }
    }
}

enum AppAutoFillIndexError: Error, Sendable, Equatable, LocalizedError {
    case vaultLocked
    case indexStoreUnavailable
    case indexKeyVaultMismatch

    var errorDescription: String? {
        switch self {
        case .vaultLocked:
            return "更新自动填充前必须先解锁保险库。"
        case .indexStoreUnavailable:
            return "自动填充索引存储不可用。"
        case .indexKeyVaultMismatch:
            return "自动填充索引密钥与当前保险库不匹配。"
        }
    }
}

enum MDBXVerificationState: Sendable, Equatable {
    case idle
    case running
    case passed(String)
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            return "就绪"
        case .running:
            return "运行中"
        case .passed(let message):
            return message
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

struct AppAutoLockPolicy: Sendable, Identifiable, Hashable {
    static let oneMinute = AppAutoLockPolicy(id: "one-minute", idleTimeout: 60)
    static let fiveMinutes = AppAutoLockPolicy(id: "five-minutes", idleTimeout: 300)
    static let fifteenMinutes = AppAutoLockPolicy(id: "fifteen-minutes", idleTimeout: 900)
    static let thirtyMinutes = AppAutoLockPolicy(id: "thirty-minutes", idleTimeout: 1_800)
    static let presets: [AppAutoLockPolicy] = [
        .oneMinute,
        .fiveMinutes,
        .fifteenMinutes,
        .thirtyMinutes
    ]
    static let `default` = AppAutoLockPolicy.fiveMinutes

    let id: String
    let idleTimeout: TimeInterval

    init(id: String, idleTimeout: TimeInterval) {
        self.id = id
        self.idleTimeout = idleTimeout
    }

    init(idleTimeout: TimeInterval) {
        self.init(id: "\(Int(idleTimeout))-seconds", idleTimeout: idleTimeout)
    }

    var label: String {
        let minutes = Int(idleTimeout / 60)
        return "\(minutes) 分钟"
    }
}

struct AppRootView: View {
    let environment: MonicaAppEnvironment
    private let coreInfo = MonicaCoreInfo()
    private let mdbxInfo = MonicaMDBXBridgeInfo()
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: AppSessionModel

    init(environment: MonicaAppEnvironment) {
        self.environment = environment
        _session = State(initialValue: AppSessionModel.production(environment: environment))
    }

    var body: some View {
        ZStack {
            if session.vaultState == .locked {
                MonicaLockScreen(
                    session: session,
                    submitPassword: submitLockScreenPassword,
                    unlockWithKeychain: {
                        Task {
                            try? await session.unlockRememberedVaultWithKeychain(
                                deviceID: environment.localDeviceIdentifier,
                                fallbackDirectory: vaultDirectory
                            )
                            importPendingAutoFillSaveRequests()
                        }
                    },
                    createVault: createLocalVault,
                    openVault: openLocalVault,
                    forgotPassword: session.showForgotPasswordGuidance
                )
            } else {
                VStack(spacing: 0) {
                    tabContent(for: session.selectedTab)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    AndroidParityBottomNavigation(
                        tabs: MonicaAppTab.phaseOneAndroidParityTabs,
                        selectedTab: $session.selectedTab
                    )
                }
                .background(AndroidParityPalette.background.ignoresSafeArea())
            }

            if session.isPrivacyShieldVisible {
                PrivacyShieldView()
            }
        }
        .tint(session.appearancePreferences.swiftUIAccentColor)
        .preferredColorScheme(session.appearancePreferences.swiftUIColorScheme)
        .simultaneousGesture(
            TapGesture().onEnded {
                session.recordUserActivity()
            }
        )
        .onChange(of: scenePhase) { _, phase in
            session.handleScenePhaseChange(phase)
            if phase == .active {
                restoreOneDriveAuthenticationSessionIfAvailable()
                restoreBitwardenAuthenticationSessionIfAvailable()
                importPendingAutoFillSaveRequests()
                importPendingSystemPasskeyRegistrations()
            }
        }
        .onOpenURL { url in
            if !session.handleOneDriveRedirectURL(url) {
                _ = session.openShortcutURL(url)
            }
        }
        .task {
            restoreOneDriveAuthenticationSessionIfAvailable()
            restoreBitwardenAuthenticationSessionIfAvailable()
            importPendingAutoFillSaveRequests()
            importPendingSystemPasskeyRegistrations()
        }
        .sheet(isPresented: forgotPasswordSheetBinding) {
            ForgotPasswordRecoverySheet(
                session: session,
                deviceID: environment.localDeviceIdentifier
            )
            .presentationDetents([.medium, .large])
        }
    }

    private var forgotPasswordSheetBinding: Binding<Bool> {
        Binding {
            session.forgotPasswordRecoveryStep != .none
        } set: { isPresented in
            if !isPresented {
                session.dismissForgotPasswordRecovery()
            }
        }
    }

    private func restoreOneDriveAuthenticationSessionIfAvailable() {
        guard !session.oneDriveAuthenticationState.isRunning else {
            return
        }
        Task {
            try? await session.restoreOneDriveAuthenticationSession()
        }
    }

    private func restoreBitwardenAuthenticationSessionIfAvailable() {
        _ = try? session.restoreBitwardenAuthenticationSession()
    }

    private func importPendingAutoFillSaveRequests() {
        guard session.vaultState == .unlocked,
              let inboxStore = AppAutoFillCredentialSaveInboxStore()
        else {
            return
        }
        do {
            try session.importPendingAutoFillSaveRequests(
                inboxStore: inboxStore,
                projectTitle: session.activeVaultName ?? "个人"
            )
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func importPendingSystemPasskeyRegistrations() {
        guard session.vaultState == .unlocked,
              let inboxStore = AppSystemPasskeyRegistrationInboxStore()
        else {
            return
        }
        _ = try? session.importPendingSystemPasskeyRegistrations(
            inboxStore: inboxStore,
            projectTitle: "Personal"
        )
    }

    @ViewBuilder
    private func tabContent(for tab: MonicaAppTab) -> some View {
        NavigationStack {
            if tab == .settings {
                SettingsRootView(
                    environment: environment,
                    session: session,
                    storageStrategy: coreInfo.storageStrategy,
                    mdbxBridge: mdbxInfo.bridge,
                    refreshAutoFillIndex: refreshAutoFillIndex,
                    runVerification: session.runMDBXVerification
                )
            } else if tab == .generator {
                GeneratorRootView()
            } else if let itemKind = tab.coreItemKind {
                AndroidParityVaultHomeView(
                    session: session,
                    tab: tab,
                    moduleTitle: tab.title,
                    itemKind: itemKind,
                    storageStrategy: coreInfo.storageStrategy,
                    mdbxBridge: mdbxInfo.bridge,
                    createVault: createLocalVault,
                    openVault: openLocalVault,
                    lockVault: session.lockLocalVault,
                    createLoginEntry: createLoginEntry,
                    generateLoginPassword: generateLoginPassword,
                    updateLoginEntry: updateLoginEntry,
                    generateSelectedLoginPassword: generateSelectedLoginPassword,
                    setSelectedLoginFavorite: setSelectedLoginFavorite,
                    deleteLoginEntry: deleteLoginEntry,
                    restoreLoginEntry: restoreLoginEntry,
                    createNoteEntry: createNoteEntry,
                    updateNoteEntry: updateNoteEntry,
                    setSelectedNoteFavorite: setSelectedNoteFavorite,
                    deleteNoteEntry: deleteNoteEntry,
                    restoreNoteEntry: restoreNoteEntry,
                    createTotpEntry: createTotpEntry,
                    importTotpURI: importTotpURI,
                    scanTotpQRCode: scanTotpQRCode,
                    updateTotpEntry: updateTotpEntry,
                    setSelectedTotpFavorite: setSelectedTotpFavorite,
                    deleteTotpEntry: deleteTotpEntry,
                    restoreTotpEntry: restoreTotpEntry,
                    createCardEntry: createCardEntry,
                    updateCardEntry: updateCardEntry,
                    setSelectedCardFavorite: setSelectedCardFavorite,
                    deleteCardEntry: deleteCardEntry,
                    restoreCardEntry: restoreCardEntry,
                    createIdentityEntry: createIdentityEntry,
                    updateIdentityEntry: updateIdentityEntry,
                    setSelectedIdentityFavorite: setSelectedIdentityFavorite,
                    deleteIdentityEntry: deleteIdentityEntry,
                    restoreIdentityEntry: restoreIdentityEntry,
                    createPasskeyEntry: createPasskeyEntry,
                    updatePasskeyEntry: updatePasskeyEntry,
                    setSelectedPasskeyFavorite: setSelectedPasskeyFavorite,
                    deletePasskeyEntry: deletePasskeyEntry,
                    restorePasskeyEntry: restorePasskeyEntry,
                    setSelectedSshKeyFavorite: setSelectedSshKeyFavorite,
                    deleteSshKeyEntry: deleteSshKeyEntry,
                    restoreSshKeyEntry: restoreSshKeyEntry,
                    setSelectedApiTokenFavorite: setSelectedApiTokenFavorite,
                    deleteApiTokenEntry: deleteApiTokenEntry,
                    restoreApiTokenEntry: restoreApiTokenEntry,
                    setSelectedWifiFavorite: setSelectedWifiFavorite,
                    deleteWifiEntry: deleteWifiEntry,
                    restoreWifiEntry: restoreWifiEntry,
                    setSelectedSendFavorite: setSelectedSendFavorite,
                    deleteSendEntry: deleteSendEntry,
                    restoreSendEntry: restoreSendEntry,
                    deleteAttachmentEntry: deleteAttachmentEntry,
                    restoreAttachmentEntry: restoreAttachmentEntry,
                    refreshExtendedParityEntries: refreshExtendedParityEntries
                )
            }
        }
        .toolbarBackground(AndroidParityPalette.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private func createLocalVault() {
        do {
            try session.createLocalVault(
                in: vaultDirectory,
                deviceID: environment.localDeviceIdentifier
            )
            importPendingAutoFillSaveRequests()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func submitLockScreenPassword() {
        do {
            if session.isFirstTimeVaultSetup {
                switch session.firstTimePasswordSetupStep {
                case .enterPassword:
                    session.beginFirstTimePasswordConfirmation()
                case .confirmPassword:
                    try session.confirmFirstTimePasswordAndCreateVault(
                        in: vaultDirectory,
                        deviceID: environment.localDeviceIdentifier
                    )
                }
            } else {
                try session.unlockRememberedVaultWithPassword(
                    deviceID: environment.localDeviceIdentifier,
                    fallbackDirectory: vaultDirectory
                )
                importPendingAutoFillSaveRequests()
            }
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func openLocalVault(at fileURL: URL) {
        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try session.openLocalVault(
                at: fileURL,
                deviceID: environment.localDeviceIdentifier
            )
            importPendingAutoFillSaveRequests()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func createLoginEntry() {
        do {
            try session.createLoginEntry(
                projectTitle: session.activeVaultName ?? "个人"
            )
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func generateLoginPassword() {
        do {
            try session.generateLoginPassword()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func updateLoginEntry() {
        do {
            try session.updateSelectedLoginEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func generateSelectedLoginPassword() {
        do {
            try session.generateSelectedLoginPassword()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func setSelectedLoginFavorite(_ favorite: Bool) {
        do {
            try session.setSelectedLoginFavorite(favorite)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func refreshAutoFillIndex() {
        do {
            try session.refreshAutoFillEncryptedIndex()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func deleteLoginEntry() {
        do {
            try session.deleteSelectedLoginEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func restoreLoginEntry(_ entry: LocalLoginEntry) {
        do {
            try session.restoreLoginEntry(entry)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func createNoteEntry() {
        do {
            try session.createNoteEntry(
                projectTitle: session.activeVaultName ?? "个人"
            )
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func updateNoteEntry() {
        do {
            try session.updateSelectedNoteEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func setSelectedNoteFavorite(_ favorite: Bool) {
        do {
            try session.setSelectedNoteFavorite(favorite)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func deleteNoteEntry() {
        do {
            try session.deleteSelectedNoteEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func restoreNoteEntry(_ entry: LocalNoteEntry) {
        do {
            try session.restoreNoteEntry(entry)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func createTotpEntry() {
        do {
            try session.createTotpEntry(
                projectTitle: session.activeVaultName ?? "个人"
            )
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func importTotpURI() {
        do {
            try session.importTotpURI(session.totpImportURI)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func scanTotpQRCode(_ payload: String) -> Bool {
        do {
            try session.importScannedTotpQRCode(payload)
            return true
        } catch {
            // AppSessionModel owns user-visible failure state.
            return false
        }
    }

    private func updateTotpEntry() {
        do {
            try session.updateSelectedTotpEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func setSelectedTotpFavorite(_ favorite: Bool) {
        do {
            try session.setSelectedTotpFavorite(favorite)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func deleteTotpEntry() {
        do {
            try session.deleteSelectedTotpEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func restoreTotpEntry(_ entry: LocalTotpEntry) {
        do {
            try session.restoreTotpEntry(entry)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func createCardEntry() {
        do {
            try session.createCardEntry(
                projectTitle: session.activeVaultName ?? "个人"
            )
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func updateCardEntry() {
        do {
            try session.updateSelectedCardEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func setSelectedCardFavorite(_ favorite: Bool) {
        do {
            try session.setSelectedCardFavorite(favorite)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func deleteCardEntry() {
        do {
            try session.deleteSelectedCardEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func restoreCardEntry(_ entry: LocalCardEntry) {
        do {
            try session.restoreCardEntry(entry)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func createIdentityEntry() {
        do {
            try session.createIdentityEntry(
                projectTitle: session.activeVaultName ?? "个人"
            )
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func updateIdentityEntry() {
        do {
            try session.updateSelectedIdentityEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func setSelectedIdentityFavorite(_ favorite: Bool) {
        do {
            try session.setSelectedIdentityFavorite(favorite)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func deleteIdentityEntry() {
        do {
            try session.deleteSelectedIdentityEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func restoreIdentityEntry(_ entry: LocalIdentityEntry) {
        do {
            try session.restoreIdentityEntry(entry)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func createPasskeyEntry() {
        do {
            try session.createPasskeyEntry(
                projectTitle: session.activeVaultName ?? "个人"
            )
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func updatePasskeyEntry() {
        do {
            try session.updateSelectedPasskeyEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func setSelectedPasskeyFavorite(_ favorite: Bool) {
        do {
            try session.setSelectedPasskeyFavorite(favorite)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func deletePasskeyEntry() {
        do {
            try session.deleteSelectedPasskeyEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func restorePasskeyEntry(_ entry: LocalPasskeyEntry) {
        do {
            try session.restorePasskeyEntry(entry)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func setSelectedSshKeyFavorite(_ favorite: Bool) {
        do {
            try session.setSelectedSshKeyFavorite(favorite)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func deleteSshKeyEntry() {
        do {
            try session.deleteSelectedSshKeyEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func restoreSshKeyEntry(_ entry: LocalSshKeyEntry) {
        do {
            try session.restoreSshKeyEntry(entry)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func setSelectedApiTokenFavorite(_ favorite: Bool) {
        do {
            try session.setSelectedApiTokenFavorite(favorite)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func deleteApiTokenEntry() {
        do {
            try session.deleteSelectedApiTokenEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func restoreApiTokenEntry(_ entry: LocalApiTokenEntry) {
        do {
            try session.restoreApiTokenEntry(entry)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func setSelectedWifiFavorite(_ favorite: Bool) {
        do {
            try session.setSelectedWifiFavorite(favorite)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func deleteWifiEntry() {
        do {
            try session.deleteSelectedWifiEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func restoreWifiEntry(_ entry: LocalWifiEntry) {
        do {
            try session.restoreWifiEntry(entry)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func setSelectedSendFavorite(_ favorite: Bool) {
        do {
            try session.setSelectedSendFavorite(favorite)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func deleteSendEntry() {
        do {
            try session.deleteSelectedSendEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func restoreSendEntry(_ entry: LocalSendEntry) {
        do {
            try session.restoreSendEntry(entry)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func deleteAttachmentEntry(_ entry: LocalAttachmentMetadata) {
        do {
            try session.deleteAttachmentEntry(entry)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func restoreAttachmentEntry(_ entry: LocalAttachmentMetadata) {
        do {
            try session.restoreAttachmentEntry(entry)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func refreshExtendedParityEntries() {
        do {
            try session.refreshExtendedParityEntries()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private var vaultDirectory: URL {
        FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
    }
}

#Preview {
    AppRootView(environment: MonicaAppEnvironment())
}
