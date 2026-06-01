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

protocol AndroidBackupAttachmentBlobStore {
    func saveEncryptedBlob(_ data: Data, vaultID: String, localPath: String) throws -> String
}

struct FileAndroidBackupAttachmentBlobStore: AndroidBackupAttachmentBlobStore {
    private let baseDirectory: URL?
    private let fileManager: FileManager

    init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    func saveEncryptedBlob(_ data: Data, vaultID: String, localPath: String) throws -> String {
        let vaultDirectory = try storageRoot()
            .appendingPathComponent(sanitizedPathComponent(vaultID), isDirectory: true)
        try fileManager.createDirectory(at: vaultDirectory, withIntermediateDirectories: true)

        let relativePath = sanitizedPathComponent(localPath)
        let fileURL = vaultDirectory.appendingPathComponent(relativePath, isDirectory: false)
        try data.write(to: fileURL, options: [.atomic])
        return relativePath
    }

    private func storageRoot() throws -> URL {
        if let baseDirectory {
            return baseDirectory
        }
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("MonicaAndroidBackupAttachments", isDirectory: true)
        }
        return applicationSupport
            .appendingPathComponent("Monica", isDirectory: true)
            .appendingPathComponent("AndroidBackupAttachments", isDirectory: true)
    }

    private func sanitizedPathComponent(_ value: String) -> String {
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
        return sanitized.isEmpty ? UUID().uuidString + ".enc" : sanitized
    }
}

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
    var loginEntries: [LocalLoginEntry] = []
    var deletedLoginEntries: [LocalLoginEntry] = []
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
    var mdbxVerificationState: MDBXVerificationState = .idle
    var isPrivacyShieldVisible = false
    var autoLockPolicy: AppAutoLockPolicy
    var autoFillIndexState: AutoFillIndexState = .idle
    var notificationPermissionState: AppPermissionStatusRow.State = .checkable
    var vaultKeychainState: VaultKeychainState = .idle
    var webDAVBaseURL = ""
    var webDAVUsername = ""
    var webDAVPassword = ""
    var webDAVRemoteFileName = ""
    var webDAVRestoreVaultPassword = ""
    var webDAVBackupState: WebDAVBackupState = .idle
    var webDAVRestorePreview: WebDAVRestorePreview?
    var csvImportPreview: CSVImportPreview?
    var androidBackupImportPreview: AndroidBackupImportPreview?
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

    private let vaultRepository: LocalVaultRepository
    private let vaultKeychainService: (any AppVaultKeychainService)?
    private let vaultWrappedKeyProvider: ((LocalVaultSession) throws -> WrappedVaultKey)?
    private let rememberedVaultStore: any RememberedVaultStore
    private let biometricUnlockPreferenceStore: any BiometricUnlockPreferenceStore
    private let biometricUnlockAuthorizer: any BiometricUnlockAuthorizer
    private let biometricCapabilityProvider: () -> BiometricUnlockCapability
    private let securityQuestionStore: any SecurityQuestionRecoveryStore
    private let webDAVBackupService: any AppWebDAVBackupService
    private let autoFillIndexStore: (any AutoFillEncryptedIndexStore)?
    private let autoFillCredentialSecretStore: (any AutoFillCredentialSecretStore)?
    private let autoFillCredentialIdentityStore: (any AppAutoFillCredentialIdentityStore)?
    private let autoFillIndexKeyMaterialProvider: ((String) throws -> AutoFillIndexKeyMaterial)?
    private let autoFillIndexCodec: AutoFillEncryptedIndexCodec
    private let autoFillCredentialSecretCodec: AutoFillCredentialSecretCodec
    private let androidBackupAttachmentBlobStore: any AndroidBackupAttachmentBlobStore
    private let passwordGenerator: () throws -> String
    private var activeVaultSession: LocalVaultSession?
    private var activeEntryRepository: LocalVaultEntryRepository?
    private var activeProject: LocalVaultProject?
    private var rememberedVaultDescriptor: LocalVaultDescriptor?
    private var rememberedVaultID: String?
    private var lastUserActivityAt: Date?
    private var pendingAndroidEncryptedBackupData: Data?

    init(
        vaultRepository: LocalVaultRepository = LocalVaultRepository(),
        vaultKeychainService: (any AppVaultKeychainService)? = nil,
        vaultWrappedKeyProvider: ((LocalVaultSession) throws -> WrappedVaultKey)? = nil,
        rememberedVaultStore: any RememberedVaultStore = MemoryRememberedVaultStore(),
        biometricUnlockPreferenceStore: any BiometricUnlockPreferenceStore = MemoryBiometricUnlockPreferenceStore(),
        biometricUnlockAuthorizer: any BiometricUnlockAuthorizer = DeviceBiometricUnlockAuthorizer(),
        biometricCapabilityProvider: @escaping () -> BiometricUnlockCapability = { .unavailable },
        securityQuestionStore: any SecurityQuestionRecoveryStore = UserDefaultsSecurityQuestionRecoveryStore(),
        webDAVBackupService: any AppWebDAVBackupService = URLSessionAppWebDAVBackupService(),
        autoFillIndexStore: (any AutoFillEncryptedIndexStore)? = nil,
        autoFillCredentialSecretStore: (any AutoFillCredentialSecretStore)? = nil,
        autoFillCredentialIdentityStore: (any AppAutoFillCredentialIdentityStore)? = nil,
        autoFillIndexKeyMaterialProvider: ((String) throws -> AutoFillIndexKeyMaterial)? = nil,
        autoFillIndexCodec: AutoFillEncryptedIndexCodec = AutoFillEncryptedIndexCodec(),
        autoFillCredentialSecretCodec: AutoFillCredentialSecretCodec = AutoFillCredentialSecretCodec(),
        androidBackupAttachmentBlobStore: any AndroidBackupAttachmentBlobStore = FileAndroidBackupAttachmentBlobStore(),
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
        self.biometricUnlockAuthorizer = biometricUnlockAuthorizer
        self.biometricCapabilityProvider = biometricCapabilityProvider
        self.securityQuestionStore = securityQuestionStore
        self.webDAVBackupService = webDAVBackupService
        self.autoFillIndexStore = autoFillIndexStore
        self.autoFillCredentialSecretStore = autoFillCredentialSecretStore
        self.autoFillCredentialIdentityStore = autoFillCredentialIdentityStore
        self.autoFillIndexKeyMaterialProvider = autoFillIndexKeyMaterialProvider
        self.autoFillIndexCodec = autoFillIndexCodec
        self.autoFillCredentialSecretCodec = autoFillCredentialSecretCodec
        self.androidBackupAttachmentBlobStore = androidBackupAttachmentBlobStore
        self.passwordGenerator = passwordGenerator
        self.autoLockPolicy = autoLockPolicy
        self.notificationPermissionState = notificationPermissionStatusProvider()
        self.isBiometricUnlockEnabled = biometricUnlockPreferenceStore.loadIsEnabled()
        if let remembered = try? rememberedVaultStore.load() {
            self.rememberedVaultDescriptor = LocalVaultDescriptor(
                fileURL: remembered.fileURL,
                displayName: remembered.displayName
            )
            self.rememberedVaultID = remembered.vaultID
        }
    }

    var filteredLoginEntries: [LocalLoginEntry] {
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

    var filteredNoteEntries: [LocalNoteEntry] {
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

    private func duplicateLoginEntryCount(in entries: [LocalLoginEntry]) -> Int {
        duplicateLoginGroups(in: entries)
            .reduce(0) { count, group in count + group.entries.count }
    }

    private func duplicateLoginGroups(in entries: [LocalLoginEntry]) -> [(key: DuplicateLoginEntryKey, entries: [LocalLoginEntry])] {
        var grouped: [DuplicateLoginEntryKey: [LocalLoginEntry]] = [:]
        for entry in entries {
            guard let key = DuplicateLoginEntryKey(entry: entry) else {
                continue
            }
            grouped[key, default: []].append(entry)
        }
        return grouped
            .filter { _, entries in entries.count > 1 }
            .map { key, entries in (key: key, entries: entries) }
            .sorted { lhs, rhs in
                lhs.entries[0].id.localizedStandardCompare(rhs.entries[0].id) == .orderedAscending
            }
    }

    private func itemCountLabel(_ count: Int) -> String {
        "\(count) 项"
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
            activeEntryRepository = vaultRepository.entryRepository(for: session)
            activeProject = nil
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
            activeEntryRepository = vaultRepository.entryRepository(for: session)
            activeProject = nil
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
        } catch {
            clearVaultAccessAfterFailure()
            vaultOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func unlockRememberedVaultWithPassword(
        deviceID: String,
        now: Date = Date()
    ) throws {
        guard let rememberedVaultDescriptor else {
            vaultOperationState = .failed(AppVaultKeychainError.rememberedVaultUnavailable.localizedDescription)
            throw AppVaultKeychainError.rememberedVaultUnavailable
        }

        try openLocalVault(
            at: rememberedVaultDescriptor.fileURL,
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
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
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
            entryOperationState = .succeeded("已删除 \(deletedTitle)")
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
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
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
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
            entryOperationState = .failed(encryptedIssue.message)
            throw AppAndroidBackupImportError.unsupportedEncryptedBackup(encryptedIssue.message)
        }
        if let decryptIssue = report.issues.first(where: { $0.code == .encryptedBackupDecryptionFailed }) {
            androidBackupImportPreview = nil
            csvImportPreview = nil
            entryOperationState = .failed(decryptIssue.message)
            throw AppAndroidBackupImportError.encryptedBackupDecryptionFailed(decryptIssue.message)
        }
        let preview = AndroidBackupImportPreview(report: report)
        androidBackupImportPreview = preview
        csvImportPreview = nil
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
        now: Date = Date()
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

            let session = try vaultRepository.openVaultWithSecurityKey(
                at: rememberedVaultDescriptor.fileURL,
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
            activeEntryRepository = vaultRepository.entryRepository(for: session)
            activeProject = nil
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
                autoFillCredentialIdentityStore.replaceCredentialIdentities(identities)
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
        clearPendingAndroidEncryptedBackup()
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

    private func readableVaultKeychainErrorMessage(for error: Error) -> String {
        if let appError = error as? AppVaultKeychainError {
            return appError.localizedDescription
        }

        if let securityError = error as? MonicaSecurityError {
            return securityError.localizedDescription
        }

        return error.localizedDescription
    }

    private func clearUnlockedVaultSession() {
        vaultPassword = ""
        vaultState = .locked
        activeVaultName = nil
        activeVaultSession = nil
        activeEntryRepository = nil
        activeProject = nil
        lastUserActivityAt = nil
        loginEntries = []
        deletedLoginEntries = []
        loginSearchQuery = ""
        showFavoriteLoginEntriesOnly = false
        loginPassword = ""
        clearEditingLoginEntry()
        noteEntries = []
        deletedNoteEntries = []
        noteSearchQuery = ""
        showFavoriteNoteEntriesOnly = false
        noteBody = ""
        clearEditingNoteEntry()
        totpEntries = []
        deletedTotpEntries = []
        totpSearchQuery = ""
        showFavoriteTotpEntriesOnly = false
        totpSecret = ""
        totpImportURI = ""
        clearEditingTotpEntry()
        cardEntries = []
        deletedCardEntries = []
        cardSearchQuery = ""
        showFavoriteCardEntriesOnly = false
        cardNumber = ""
        cardCVV = ""
        clearEditingCardEntry()
        identityEntries = []
        deletedIdentityEntries = []
        identitySearchQuery = ""
        showFavoriteIdentityEntriesOnly = false
        identityDocumentNumber = ""
        clearEditingIdentityEntry()
        passkeyEntries = []
        deletedPasskeyEntries = []
        passkeySearchQuery = ""
        showFavoritePasskeyEntriesOnly = false
        passkeyPrivateKeyReference = ""
        clearEditingPasskeyEntry()
        clearExtendedParityEntries()
        csvImportPreview = nil
        androidBackupImportPreview = nil
        entryOperationState = .idle
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
        lastUserActivityAt = nil
        loginEntries = []
        deletedLoginEntries = []
        loginSearchQuery = ""
        showFavoriteLoginEntriesOnly = false
        loginPassword = ""
        clearEditingLoginEntry()
        noteEntries = []
        deletedNoteEntries = []
        noteSearchQuery = ""
        showFavoriteNoteEntriesOnly = false
        noteBody = ""
        clearEditingNoteEntry()
        totpEntries = []
        deletedTotpEntries = []
        totpSearchQuery = ""
        showFavoriteTotpEntriesOnly = false
        totpSecret = ""
        totpImportURI = ""
        clearEditingTotpEntry()
        cardEntries = []
        deletedCardEntries = []
        cardSearchQuery = ""
        showFavoriteCardEntriesOnly = false
        cardNumber = ""
        cardCVV = ""
        clearEditingCardEntry()
        identityEntries = []
        deletedIdentityEntries = []
        identitySearchQuery = ""
        showFavoriteIdentityEntriesOnly = false
        identityDocumentNumber = ""
        clearEditingIdentityEntry()
        passkeyEntries = []
        deletedPasskeyEntries = []
        passkeySearchQuery = ""
        showFavoritePasskeyEntriesOnly = false
        passkeyPrivateKeyReference = ""
        clearEditingPasskeyEntry()
        clearExtendedParityEntries()
        entryOperationState = .idle
        autoFillIndexState = .idle
        webDAVBackupState = .idle
        webDAVRestorePreview = nil
        webDAVRestoreVaultPassword = ""
        downloadedWebDAVRestoreBackup = nil
        clearPendingAndroidEncryptedBackup()
    }

    private func clearPendingAndroidEncryptedBackup() {
        pendingAndroidEncryptedBackupData = nil
        pendingAndroidEncryptedBackupFileName = nil
        androidBackupDecryptPassword = ""
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
    }

    private func requireActiveVaultSession() throws -> LocalVaultSession {
        guard vaultState == .unlocked,
              let activeVaultSession else {
            throw AppWebDAVBackupError.vaultLocked
        }
        return activeVaultSession
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
        return project
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
                                deviceID: environment.localDeviceIdentifier
                            )
                        }
                    },
                    createVault: createLocalVault,
                    openVault: openLocalVault,
                    forgotPassword: session.showForgotPasswordGuidance
                )
            } else {
                TabView(selection: $session.selectedTab) {
                    ForEach(MonicaAppTab.phaseOneAndroidParityTabs, id: \.self) { tab in
                        tabContent(for: tab)
                            .tabItem {
                                Label(tab.title, systemImage: tab.systemImage)
                            }
                            .tag(tab)
                    }
                }
            }

            if session.isPrivacyShieldVisible {
                PrivacyShieldView()
            }
        }
        .tint(AndroidParityPalette.primary)
        .simultaneousGesture(
            TapGesture().onEnded {
                session.recordUserActivity()
            }
        )
        .onChange(of: scenePhase) { _, phase in
            session.handleScenePhaseChange(phase)
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
                    deviceID: environment.localDeviceIdentifier
                )
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
