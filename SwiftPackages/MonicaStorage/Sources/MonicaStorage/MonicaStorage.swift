import Foundation
import CryptoKit
import MonicaMDBX
import MonicaStorageTwofish
import ZIPFoundation
import argon2
import zlib

public enum MonicaStorageBaseline {
    public static let primaryStore = "MDBX"
}

public enum LocalAttachmentContentStoreError: Error, Sendable, Equatable, LocalizedError {
    case missingLocalPath
    case missingBlob(String)

    public var errorDescription: String? {
        switch self {
        case .missingLocalPath:
            return "附件缺少本地密文路径。"
        case .missingBlob:
            return "附件密文尚未保存在本机。"
        }
    }
}

public protocol LocalAttachmentContentStore: Sendable {
    func saveEncryptedBlob(_ data: Data, vaultID: String, localPath: String) throws -> String
    func encryptedBlobExists(vaultID: String, localPath: String) -> Bool
    func encryptedBlobData(vaultID: String, localPath: String) throws -> Data
}

public enum LocalAttachmentContentCryptoError: Error, Sendable, Equatable, LocalizedError {
    case invalidContentEncryptionKeyLength
    case invalidEncryptedBlob
    case authenticationFailed
    case unsupportedWrappedContentEncryptionKey

    public var errorDescription: String? {
        switch self {
        case .invalidContentEncryptionKeyLength:
            return "附件内容密钥长度无效。"
        case .invalidEncryptedBlob:
            return "附件密文格式无效。"
        case .authenticationFailed:
            return "附件解密认证失败。"
        case .unsupportedWrappedContentEncryptionKey:
            return "无法打开该附件内容。"
        }
    }
}

public enum AndroidAttachmentContentWrappingKey: Sendable, Equatable {
    case mdk(Data)
    case legacyKey(Data)
    case legacyMasterKeyDescription(String)

    fileprivate var keyMaterial: Data {
        switch self {
        case .mdk(let data), .legacyKey(let data):
            return data
        case .legacyMasterKeyDescription(let description):
            var bytes = Array(description.utf8)
            if bytes.count < LocalAttachmentContentDecryptor.androidContentEncryptionKeyByteCount {
                bytes.append(
                    contentsOf: Array(
                        repeating: 0,
                        count: LocalAttachmentContentDecryptor.androidContentEncryptionKeyByteCount - bytes.count
                    )
                )
            }
            return Data(bytes.prefix(LocalAttachmentContentDecryptor.androidContentEncryptionKeyByteCount))
        }
    }
}

public enum AndroidWrappedAttachmentContentKeyUnwrapper {
    private static let mdkPrefix = "MDK|"
    private static let v2Prefix = "V2|"

    public static func unwrap(
        _ wrappedContentEncryptionKey: String,
        using wrappingKey: AndroidAttachmentContentWrappingKey
    ) throws -> Data {
        let trimmed = wrappedContentEncryptionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalAttachmentContentCryptoError.invalidEncryptedBlob
        }
        if trimmed.hasPrefix(v2Prefix) {
            throw LocalAttachmentContentCryptoError.unsupportedWrappedContentEncryptionKey
        }

        let payloadBase64: String
        if trimmed.hasPrefix(mdkPrefix) {
            payloadBase64 = String(trimmed.dropFirst(mdkPrefix.count))
        } else {
            payloadBase64 = trimmed
        }

        let keyMaterial = wrappingKey.keyMaterial
        guard keyMaterial.count == LocalAttachmentContentDecryptor.androidContentEncryptionKeyByteCount else {
            throw LocalAttachmentContentCryptoError.invalidContentEncryptionKeyLength
        }
        guard let combined = Data(base64Encoded: payloadBase64, options: [.ignoreUnknownCharacters]),
              combined.count >= LocalAttachmentContentDecryptor.androidIVByteCount
                + LocalAttachmentContentDecryptor.androidAuthenticationTagByteCount
        else {
            throw LocalAttachmentContentCryptoError.invalidEncryptedBlob
        }

        let nonceData = combined.prefix(LocalAttachmentContentDecryptor.androidIVByteCount)
        let sealedPayload = combined.dropFirst(LocalAttachmentContentDecryptor.androidIVByteCount)
        let ciphertext = sealedPayload.dropLast(LocalAttachmentContentDecryptor.androidAuthenticationTagByteCount)
        let tag = sealedPayload.suffix(LocalAttachmentContentDecryptor.androidAuthenticationTagByteCount)

        let decryptedBase64: Data
        do {
            let sealedBox = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonceData),
                ciphertext: Data(ciphertext),
                tag: Data(tag)
            )
            decryptedBase64 = try AES.GCM.open(
                sealedBox,
                using: SymmetricKey(data: keyMaterial)
            )
        } catch is CryptoKitError {
            throw LocalAttachmentContentCryptoError.authenticationFailed
        } catch {
            throw LocalAttachmentContentCryptoError.invalidEncryptedBlob
        }

        guard let base64String = String(data: decryptedBase64, encoding: .utf8),
              let cek = Data(base64Encoded: base64String, options: [.ignoreUnknownCharacters]),
              cek.count == LocalAttachmentContentDecryptor.androidContentEncryptionKeyByteCount
        else {
            throw LocalAttachmentContentCryptoError.invalidContentEncryptionKeyLength
        }
        return cek
    }
}

public enum LocalAttachmentContentDecryptor {
    public static let androidIVByteCount = 12
    public static let androidContentEncryptionKeyByteCount = 32
    public static let androidAuthenticationTagByteCount = 16

    public static func decryptAndroidLocalBlob(
        _ encryptedBlob: Data,
        contentEncryptionKey: Data
    ) throws -> Data {
        guard contentEncryptionKey.count == androidContentEncryptionKeyByteCount else {
            throw LocalAttachmentContentCryptoError.invalidContentEncryptionKeyLength
        }
        guard encryptedBlob.count >= androidIVByteCount + androidAuthenticationTagByteCount else {
            throw LocalAttachmentContentCryptoError.invalidEncryptedBlob
        }

        let nonceData = encryptedBlob.prefix(androidIVByteCount)
        let sealedPayload = encryptedBlob.dropFirst(androidIVByteCount)
        guard sealedPayload.count >= androidAuthenticationTagByteCount else {
            throw LocalAttachmentContentCryptoError.invalidEncryptedBlob
        }

        let ciphertext = sealedPayload.dropLast(androidAuthenticationTagByteCount)
        let tag = sealedPayload.suffix(androidAuthenticationTagByteCount)

        do {
            let sealedBox = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonceData),
                ciphertext: Data(ciphertext),
                tag: Data(tag)
            )
            return try AES.GCM.open(
                sealedBox,
                using: SymmetricKey(data: contentEncryptionKey)
            )
        } catch is CryptoKitError {
            throw LocalAttachmentContentCryptoError.authenticationFailed
        } catch {
            throw LocalAttachmentContentCryptoError.invalidEncryptedBlob
        }
    }
}

public struct FileLocalAttachmentContentStore: LocalAttachmentContentStore, @unchecked Sendable {
    private let baseDirectory: URL?
    private let fileManager: FileManager

    public init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    public func saveEncryptedBlob(_ data: Data, vaultID: String, localPath: String) throws -> String {
        let vaultDirectory = try storageRoot()
            .appendingPathComponent(sanitizedPathComponent(vaultID), isDirectory: true)
        try fileManager.createDirectory(at: vaultDirectory, withIntermediateDirectories: true)

        let relativePath = sanitizedPathComponent(localPath)
        let fileURL = vaultDirectory.appendingPathComponent(relativePath, isDirectory: false)
        try data.write(to: fileURL, options: [.atomic])
        return relativePath
    }

    public func encryptedBlobExists(vaultID: String, localPath: String) -> Bool {
        guard let fileURL = try? encryptedBlobURL(vaultID: vaultID, localPath: localPath) else {
            return false
        }
        return fileManager.isReadableFile(atPath: fileURL.path)
    }

    public func encryptedBlobData(vaultID: String, localPath: String) throws -> Data {
        let fileURL = try encryptedBlobURL(vaultID: vaultID, localPath: localPath)
        guard fileManager.isReadableFile(atPath: fileURL.path) else {
            throw LocalAttachmentContentStoreError.missingBlob(localPath)
        }
        return try Data(contentsOf: fileURL)
    }

    private func encryptedBlobURL(vaultID: String, localPath: String) throws -> URL {
        let relativePath = sanitizedPathComponent(localPath)
        guard !relativePath.isEmpty else {
            throw LocalAttachmentContentStoreError.missingLocalPath
        }
        return try storageRoot()
            .appendingPathComponent(sanitizedPathComponent(vaultID), isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: false)
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
                .appendingPathComponent("Monica", isDirectory: true)
                .appendingPathComponent("AttachmentContent", isDirectory: true)
        }
        return applicationSupport
            .appendingPathComponent("Monica", isDirectory: true)
            .appendingPathComponent("AttachmentContent", isDirectory: true)
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

public enum VaultSource: String, Sendable, Equatable, CaseIterable {
    case mdbx
    case keepass
    case bitwarden
    case androidBackup
    case csvImport

    public var displayName: String {
        switch self {
        case .mdbx:
            return "MDBX"
        case .keepass:
            return "KeePass"
        case .bitwarden:
            return "Bitwarden"
        case .androidBackup:
            return "移动端备份"
        case .csvImport:
            return "CSV 导入"
        }
    }

    public static let phaseOneSources: [VaultSource] = [.mdbx]
    public static let longTermSources: [VaultSource] = [
        .mdbx,
        .keepass,
        .bitwarden,
        .androidBackup,
        .csvImport
    ]
}

public enum UnifiedVaultItemKind: String, Sendable, Equatable, Hashable, CaseIterable {
    case login
    case totp
    case note
    case card
    case identity
    case passkey
    case sshKey
    case apiToken
    case wifi
    case sso
    case send
    case attachmentRef
    case steam
    case barcode
    case billingAddress
    case paymentAccount
    case gpgKey

    public var displayName: String {
        switch self {
        case .login:
            return "密码"
        case .totp:
            return "验证器"
        case .note:
            return "笔记"
        case .card:
            return "银行卡"
        case .identity:
            return "证件"
        case .passkey:
            return "通行密钥"
        case .sshKey:
            return "SSH 密钥"
        case .apiToken:
            return "API Token"
        case .wifi:
            return "Wi-Fi"
        case .sso:
            return "SSO"
        case .send:
            return "安全发送"
        case .attachmentRef:
            return "附件"
        case .steam:
            return "Steam"
        case .barcode:
            return "条码"
        case .billingAddress:
            return "账单地址"
        case .paymentAccount:
            return "支付账户"
        case .gpgKey:
            return "GPG 密钥"
        }
    }

    public static let phaseOneKinds: [UnifiedVaultItemKind] = [
        .login,
        .totp,
        .note,
        .card,
        .identity
    ]

    public static let fullAndroidParityKinds: [UnifiedVaultItemKind] = [
        .login,
        .card,
        .identity,
        .totp,
        .passkey,
        .note,
        .sshKey,
        .apiToken,
        .wifi,
        .sso,
        .send,
        .attachmentRef,
        .steam,
        .barcode,
        .billingAddress,
        .paymentAccount,
        .gpgKey
    ]
}

public struct UnifiedVaultItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let source: VaultSource
    public let kind: UnifiedVaultItemKind
    public let title: String
    public let subtitle: String
    public let searchableText: String
    public let isFavorite: Bool
    public let isDeleted: Bool

    public init(
        id: String,
        source: VaultSource,
        kind: UnifiedVaultItemKind,
        title: String,
        subtitle: String,
        searchableText: String,
        isFavorite: Bool,
        isDeleted: Bool
    ) {
        self.id = id
        self.source = source
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.searchableText = searchableText
        self.isFavorite = isFavorite
        self.isDeleted = isDeleted
    }

    public var listTitle: String { title }
    public var listSubtitle: String { subtitle }

    public func matches(_ query: String) -> Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return true
        }
        return searchableText.localizedCaseInsensitiveContains(trimmedQuery)
    }
}

public protocol ItemRepository {
    func listItems(
        source: VaultSource?,
        kinds: [UnifiedVaultItemKind],
        includeDeleted: Bool
    ) throws -> [UnifiedVaultItem]

    func deleteItem(_ item: UnifiedVaultItem) throws
    func restoreItem(_ item: UnifiedVaultItem) throws
    func setFavorite(_ favorite: Bool, for item: UnifiedVaultItem) throws -> UnifiedVaultItem
}

public enum LocalVaultState: Sendable, Equatable {
    case unlocked
    case locked
}

public enum LocalVaultRepositoryError: Error, Sendable, Equatable, LocalizedError {
    case emptyVaultName
    case emptyPassword
    case emptySecurityKeyMaterial
    case currentPasswordMismatch
    case passwordUnchanged
    case emptyProjectTitle
    case emptyEntryTitle
    case vaultUnavailable
    case projectNotFound
    case projectNotEmpty
    case unsupportedEntryType(UnifiedVaultItemKind)
    case invalidEntryPayload

    public var errorDescription: String? {
        switch self {
        case .emptyVaultName:
            return "保险库名称不能为空。"
        case .emptyPassword:
            return "保险库密码不能为空。"
        case .emptySecurityKeyMaterial:
            return "保险库安全密钥材料不能为空。"
        case .currentPasswordMismatch:
            return "当前主密码不正确。"
        case .passwordUnchanged:
            return "新主密码不能与当前主密码相同。"
        case .emptyProjectTitle:
            return "项目标题不能为空。"
        case .emptyEntryTitle:
            return "条目标题不能为空。"
        case .vaultUnavailable:
            return "保险库会话已不可用。"
        case .projectNotFound:
            return "分类不存在。"
        case .projectNotEmpty:
            return "分类内仍有条目，无法直接删除。"
        case .unsupportedEntryType(let kind):
            return "\(kind.displayName) 还没有接入当前 MDBX 引擎。"
        case .invalidEntryPayload:
            return "保险库条目 payload 无法解析。"
        }
    }
}

public struct LocalVaultDescriptor: Sendable, Equatable {
    public let fileURL: URL
    public let displayName: String

    public init(fileURL: URL, displayName: String) {
        self.fileURL = fileURL
        self.displayName = displayName
    }
}

public struct LocalVaultHandle: Sendable, Equatable {
    public let vaultID: String
    public let deviceID: String

    public init(vaultID: String, deviceID: String) {
        self.vaultID = vaultID
        self.deviceID = deviceID
    }
}

public struct LocalVaultSession: Sendable, Equatable {
    public let descriptor: LocalVaultDescriptor
    public let handle: LocalVaultHandle
    public let state: LocalVaultState

    public init(
        descriptor: LocalVaultDescriptor,
        handle: LocalVaultHandle,
        state: LocalVaultState
    ) {
        self.descriptor = descriptor
        self.handle = handle
        self.state = state
    }
}

public protocol LocalVaultEngine {
    func createVault(
        at fileURL: URL,
        password: String,
        deviceID: String
    ) throws -> LocalVaultHandle

    func openVault(
        at fileURL: URL,
        password: String,
        deviceID: String
    ) throws -> LocalVaultHandle

    func openVaultWithSecurityKey(
        at fileURL: URL,
        securityKeyMaterial: Data,
        deviceID: String
    ) throws -> LocalVaultHandle

    func setupLocalSecurityKeyUnlock(
        in handle: LocalVaultHandle,
        securityKeyMaterial: Data
    ) throws

    /// 只校验主密码，不登记新会话，也不改变已经在使用的句柄。
    ///
    /// 修改主密码前需要先确认旧口令；实现必须在一个独立的临时连接上验证，
    /// 让正在使用的会话在验证失败时保持原样。
    func verifyMasterPassword(
        at fileURL: URL,
        password: String,
        deviceID: String
    ) throws -> LocalVaultHandle

    func resetMasterPassword(
        in handle: LocalVaultHandle,
        newPassword: String
    ) throws

    func closeVault(_ handle: LocalVaultHandle)

    func createProject(
        in handle: LocalVaultHandle,
        title: String
    ) throws -> LocalVaultProject

    func listProjects(
        in handle: LocalVaultHandle
    ) throws -> [LocalVaultProject]

    func renameProject(
        in handle: LocalVaultHandle,
        projectID: String,
        title: String
    ) throws -> LocalVaultProject

    func deleteProject(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws

    func createLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalLoginEntryDraft
    ) throws -> LocalLoginEntry

    func listLoginEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalLoginEntry]

    func updateLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalLoginEntryDraft
    ) throws -> LocalLoginEntry

    func setLoginEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalLoginEntry

    func setLoginEntryIcon(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        icon: String?
    ) throws -> LocalLoginEntry

    func deleteLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedLoginEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalLoginEntry]

    func restoreLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalLoginEntry

    func createNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalNoteEntryDraft
    ) throws -> LocalNoteEntry

    func listNoteEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalNoteEntry]

    func updateNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalNoteEntryDraft
    ) throws -> LocalNoteEntry

    func setNoteEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalNoteEntry

    func deleteNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedNoteEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalNoteEntry]

    func restoreNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalNoteEntry

    func createTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalTotpEntryDraft
    ) throws -> LocalTotpEntry

    func listTotpEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalTotpEntry]

    func updateTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalTotpEntryDraft
    ) throws -> LocalTotpEntry

    func setTotpEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalTotpEntry

    func deleteTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedTotpEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalTotpEntry]

    func restoreTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalTotpEntry

    func createCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalCardEntryDraft
    ) throws -> LocalCardEntry

    func listCardEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalCardEntry]

    func updateCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalCardEntryDraft
    ) throws -> LocalCardEntry

    func setCardEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalCardEntry

    func deleteCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedCardEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalCardEntry]

    func restoreCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalCardEntry

    func createIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalIdentityEntryDraft
    ) throws -> LocalIdentityEntry

    func listIdentityEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalIdentityEntry]

    func updateIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalIdentityEntryDraft
    ) throws -> LocalIdentityEntry

    func setIdentityEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalIdentityEntry

    func deleteIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedIdentityEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalIdentityEntry]

    func restoreIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalIdentityEntry

    func createPasskeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalPasskeyEntryDraft
    ) throws -> LocalPasskeyEntry

    func listPasskeyEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalPasskeyEntry]

    func updatePasskeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalPasskeyEntryDraft
    ) throws -> LocalPasskeyEntry

    func setPasskeyEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalPasskeyEntry

    func deletePasskeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedPasskeyEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalPasskeyEntry]

    func restorePasskeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalPasskeyEntry

    func createSshKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalSshKeyEntryDraft
    ) throws -> LocalSshKeyEntry

    func listSshKeyEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSshKeyEntry]

    func updateSshKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalSshKeyEntryDraft
    ) throws -> LocalSshKeyEntry

    func setSshKeyEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalSshKeyEntry

    func deleteSshKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedSshKeyEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSshKeyEntry]

    func restoreSshKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalSshKeyEntry

    func createGPGKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalGPGKeyEntryDraft
    ) throws -> LocalGPGKeyEntry

    func listGPGKeyEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalGPGKeyEntry]

    func updateGPGKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalGPGKeyEntryDraft
    ) throws -> LocalGPGKeyEntry

    func setGPGKeyEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalGPGKeyEntry

    func deleteGPGKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedGPGKeyEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalGPGKeyEntry]

    func restoreGPGKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalGPGKeyEntry

    func createApiTokenEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalApiTokenEntryDraft
    ) throws -> LocalApiTokenEntry

    func listApiTokenEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalApiTokenEntry]

    func updateApiTokenEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalApiTokenEntryDraft
    ) throws -> LocalApiTokenEntry

    func setApiTokenEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalApiTokenEntry

    func deleteApiTokenEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedApiTokenEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalApiTokenEntry]

    func restoreApiTokenEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalApiTokenEntry

    func createWifiEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalWifiEntryDraft
    ) throws -> LocalWifiEntry

    func listWifiEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalWifiEntry]

    func updateWifiEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalWifiEntryDraft
    ) throws -> LocalWifiEntry

    func setWifiEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalWifiEntry

    func deleteWifiEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedWifiEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalWifiEntry]

    func restoreWifiEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalWifiEntry

    func createSSOEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalSSOEntryDraft
    ) throws -> LocalSSOEntry

    func listSSOEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSSOEntry]

    func updateSSOEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalSSOEntryDraft
    ) throws -> LocalSSOEntry

    func setSSOEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalSSOEntry

    func createBarcodeEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalBarcodeEntryDraft
    ) throws -> LocalBarcodeEntry

    func listBarcodeEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalBarcodeEntry]

    func updateBarcodeEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalBarcodeEntryDraft
    ) throws -> LocalBarcodeEntry

    func setBarcodeEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalBarcodeEntry

    func deleteSSOEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func deleteBarcodeEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedSSOEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSSOEntry]

    func restoreSSOEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalSSOEntry

    func createSteamEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalSteamEntryDraft
    ) throws -> LocalSteamEntry

    func listSteamEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSteamEntry]

    func updateSteamEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalSteamEntryDraft
    ) throws -> LocalSteamEntry

    func setSteamEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalSteamEntry

    func deleteSteamEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedSteamEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSteamEntry]

    func restoreSteamEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalSteamEntry

    func listDeletedBarcodeEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalBarcodeEntry]

    func restoreBarcodeEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalBarcodeEntry

    func createSendEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalSendEntryDraft
    ) throws -> LocalSendEntry

    func listSendEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSendEntry]

    func updateSendEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalSendEntryDraft
    ) throws -> LocalSendEntry

    func setSendEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalSendEntry

    func deleteSendEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedSendEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSendEntry]

    func restoreSendEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalSendEntry

    func createAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String?,
        fileName: String,
        mediaType: String,
        originalSize: Int64,
        storedSize: Int64,
        contentHash: String,
        storageMode: String,
        source: String,
        downloadState: String,
        wrappedContentEncryptionKey: String?,
        localPath: String?
    ) throws -> LocalAttachmentMetadata

    func listAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalAttachmentMetadata]

    func updateAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String,
        attachmentID: String,
        entryID: String?,
        fileName: String,
        mediaType: String,
        originalSize: Int64,
        storedSize: Int64,
        contentHash: String,
        storageMode: String,
        source: String,
        downloadState: String,
        wrappedContentEncryptionKey: String?,
        localPath: String?
    ) throws -> LocalAttachmentMetadata

    func deleteAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String,
        attachmentID: String
    ) throws

    func listDeletedAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalAttachmentMetadata]

    func restoreAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String,
        attachmentID: String
    ) throws -> LocalAttachmentMetadata

    func createBillingAddressEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalBillingAddressEntryDraft
    ) throws -> LocalBillingAddressEntry

    func listBillingAddressEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalBillingAddressEntry]

    func updateBillingAddressEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalBillingAddressEntryDraft
    ) throws -> LocalBillingAddressEntry

    func setBillingAddressEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalBillingAddressEntry

    func deleteBillingAddressEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedBillingAddressEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalBillingAddressEntry]

    func restoreBillingAddressEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalBillingAddressEntry

    func createPaymentAccountEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalPaymentAccountEntryDraft
    ) throws -> LocalPaymentAccountEntry

    func listPaymentAccountEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalPaymentAccountEntry]

    func updatePaymentAccountEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalPaymentAccountEntryDraft
    ) throws -> LocalPaymentAccountEntry

    func setPaymentAccountEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalPaymentAccountEntry

    func deletePaymentAccountEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedPaymentAccountEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalPaymentAccountEntry]

    func restorePaymentAccountEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalPaymentAccountEntry

    func moveEntry(
        in handle: LocalVaultHandle,
        kind: UnifiedVaultItemKind,
        entryID: String,
        fromProjectID: String,
        toProjectID: String
    ) throws -> LocalVaultMovedEntry

    /// 读取一个分类里所有条目的自定义字段/关联侧表，键是条目的稳定 itemID。
    func listItemExtras(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [String: VaultItemExtras]

    /// 写入（或更新）单个条目的侧表。返回归一化后的结果，调用方可以据此回填编辑器。
    func saveItemExtras(
        in handle: LocalVaultHandle,
        projectID: String,
        extras: VaultItemExtras
    ) throws -> VaultItemExtras

    /// 清空单个条目的侧表；条目本身不受影响。
    func deleteItemExtras(
        in handle: LocalVaultHandle,
        projectID: String,
        itemID: String
    ) throws

    /// 条目换分类时让侧表跟随，避免自定义字段/关联在移动后丢失。
    func moveItemExtras(
        in handle: LocalVaultHandle,
        itemID: String,
        fromProjectID: String,
        toProjectID: String
    ) throws

    /// 列出锚点工程里的文件夹层级记录（issue #27）。
    func listVaultFolderRecords(
        in handle: LocalVaultHandle,
        anchorProjectID: String
    ) throws -> [VaultFolderRecord]

    /// 写入（新增或覆盖）一条文件夹层级记录（issue #27）。
    func saveVaultFolderRecord(
        in handle: LocalVaultHandle,
        anchorProjectID: String,
        record: VaultFolderRecord
    ) throws

    /// 删除一条文件夹层级记录（issue #27）。
    func deleteVaultFolderRecord(
        in handle: LocalVaultHandle,
        anchorProjectID: String,
        folderID: String
    ) throws

    /// 列出锚点工程里的常用账号模板记录（issue #127）。
    func listAccountTemplates(
        in handle: LocalVaultHandle,
        anchorProjectID: String
    ) throws -> [AccountTemplate]

    /// 写入（新增或覆盖）一条常用账号模板记录（issue #127）。
    func saveAccountTemplate(
        in handle: LocalVaultHandle,
        anchorProjectID: String,
        template: AccountTemplate
    ) throws

    /// 删除一条常用账号模板记录（issue #127）。
    func deleteAccountTemplate(
        in handle: LocalVaultHandle,
        anchorProjectID: String,
        templateID: String
    ) throws
}

public extension LocalVaultEngine {
    func moveEntry(in handle: LocalVaultHandle, kind: UnifiedVaultItemKind, entryID: String, fromProjectID: String, toProjectID: String) throws -> LocalVaultMovedEntry { throw LocalVaultRepositoryError.unsupportedEntryType(kind) }

    func createBillingAddressEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalBillingAddressEntryDraft) throws -> LocalBillingAddressEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.billingAddress) }
    func listBillingAddressEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalBillingAddressEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.billingAddress) }
    func updateBillingAddressEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalBillingAddressEntryDraft) throws -> LocalBillingAddressEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.billingAddress) }
    func setBillingAddressEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalBillingAddressEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.billingAddress) }
    func deleteBillingAddressEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.billingAddress) }
    func listDeletedBillingAddressEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalBillingAddressEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.billingAddress) }
    func restoreBillingAddressEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalBillingAddressEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.billingAddress) }

    func createPaymentAccountEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalPaymentAccountEntryDraft) throws -> LocalPaymentAccountEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.paymentAccount) }
    func listPaymentAccountEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalPaymentAccountEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.paymentAccount) }
    func updatePaymentAccountEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalPaymentAccountEntryDraft) throws -> LocalPaymentAccountEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.paymentAccount) }
    func setPaymentAccountEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalPaymentAccountEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.paymentAccount) }
    func deletePaymentAccountEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.paymentAccount) }
    func listDeletedPaymentAccountEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalPaymentAccountEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.paymentAccount) }
    func restorePaymentAccountEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalPaymentAccountEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.paymentAccount) }

    func createPasskeyEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalPasskeyEntryDraft) throws -> LocalPasskeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.passkey) }
    func listPasskeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalPasskeyEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.passkey) }
    func updatePasskeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalPasskeyEntryDraft) throws -> LocalPasskeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.passkey) }
    func setPasskeyEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalPasskeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.passkey) }
    func deletePasskeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.passkey) }
    func listDeletedPasskeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalPasskeyEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.passkey) }
    func restorePasskeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalPasskeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.passkey) }

    func createSshKeyEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalSshKeyEntryDraft) throws -> LocalSshKeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.sshKey) }
    func listSshKeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSshKeyEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.sshKey) }
    func updateSshKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalSshKeyEntryDraft) throws -> LocalSshKeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.sshKey) }
    func setSshKeyEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalSshKeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.sshKey) }
    func deleteSshKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.sshKey) }
    func listDeletedSshKeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSshKeyEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.sshKey) }
    func restoreSshKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalSshKeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.sshKey) }
    func createGPGKeyEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalGPGKeyEntryDraft) throws -> LocalGPGKeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.gpgKey) }
    func listGPGKeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalGPGKeyEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.gpgKey) }
    func updateGPGKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalGPGKeyEntryDraft) throws -> LocalGPGKeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.gpgKey) }
    func setGPGKeyEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalGPGKeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.gpgKey) }
    func deleteGPGKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.gpgKey) }
    func listDeletedGPGKeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalGPGKeyEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.gpgKey) }
    func restoreGPGKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalGPGKeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.gpgKey) }

    func createApiTokenEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalApiTokenEntryDraft) throws -> LocalApiTokenEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.apiToken) }
    func listApiTokenEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalApiTokenEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.apiToken) }
    func updateApiTokenEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalApiTokenEntryDraft) throws -> LocalApiTokenEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.apiToken) }
    func setApiTokenEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalApiTokenEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.apiToken) }
    func deleteApiTokenEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.apiToken) }
    func listDeletedApiTokenEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalApiTokenEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.apiToken) }
    func restoreApiTokenEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalApiTokenEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.apiToken) }

    func createWifiEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalWifiEntryDraft) throws -> LocalWifiEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.wifi) }
    func listWifiEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalWifiEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.wifi) }
    func updateWifiEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalWifiEntryDraft) throws -> LocalWifiEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.wifi) }
    func setWifiEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalWifiEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.wifi) }
    func deleteWifiEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.wifi) }
    func listDeletedWifiEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalWifiEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.wifi) }
    func restoreWifiEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalWifiEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.wifi) }

    func createSSOEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalSSOEntryDraft) throws -> LocalSSOEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.sso) }
    func listSSOEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSSOEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.sso) }
    func updateSSOEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalSSOEntryDraft) throws -> LocalSSOEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.sso) }
    func setSSOEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalSSOEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.sso) }
    func deleteSSOEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.sso) }
    func listDeletedSSOEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSSOEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.sso) }
    func restoreSSOEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalSSOEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.sso) }
    func createSteamEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalSteamEntryDraft) throws -> LocalSteamEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.steam) }
    func listSteamEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSteamEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.steam) }
    func updateSteamEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalSteamEntryDraft) throws -> LocalSteamEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.steam) }
    func setSteamEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalSteamEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.steam) }
    func deleteSteamEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.steam) }
    func listDeletedSteamEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSteamEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.steam) }
    func restoreSteamEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalSteamEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.steam) }

    func createBarcodeEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalBarcodeEntryDraft) throws -> LocalBarcodeEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.barcode) }
    func listBarcodeEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalBarcodeEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.barcode) }
    func updateBarcodeEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalBarcodeEntryDraft) throws -> LocalBarcodeEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.barcode) }
    func setBarcodeEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalBarcodeEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.barcode) }
    func deleteBarcodeEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.barcode) }
    func listDeletedBarcodeEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalBarcodeEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.barcode) }
    func restoreBarcodeEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalBarcodeEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.barcode) }

    func createSendEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalSendEntryDraft) throws -> LocalSendEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.send) }
    func listSendEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSendEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.send) }
    func updateSendEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalSendEntryDraft) throws -> LocalSendEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.send) }
    func setSendEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalSendEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.send) }
    func deleteSendEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.send) }
    func listDeletedSendEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSendEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.send) }
    func restoreSendEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalSendEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.send) }

    func createAttachmentMetadata(in handle: LocalVaultHandle, projectID: String, entryID: String?, fileName: String, mediaType: String, originalSize: Int64, storedSize: Int64, contentHash: String, storageMode: String, source: String = "", downloadState: String = "", wrappedContentEncryptionKey: String? = nil, localPath: String? = nil) throws -> LocalAttachmentMetadata { throw LocalVaultRepositoryError.unsupportedEntryType(.attachmentRef) }
    func listAttachmentMetadata(in handle: LocalVaultHandle, projectID: String) throws -> [LocalAttachmentMetadata] { throw LocalVaultRepositoryError.unsupportedEntryType(.attachmentRef) }
    func updateAttachmentMetadata(in handle: LocalVaultHandle, projectID: String, attachmentID: String, entryID: String?, fileName: String, mediaType: String, originalSize: Int64, storedSize: Int64, contentHash: String, storageMode: String, source: String = "", downloadState: String = "", wrappedContentEncryptionKey: String? = nil, localPath: String? = nil) throws -> LocalAttachmentMetadata { throw LocalVaultRepositoryError.unsupportedEntryType(.attachmentRef) }
    func deleteAttachmentMetadata(in handle: LocalVaultHandle, projectID: String, attachmentID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.attachmentRef) }
    func listDeletedAttachmentMetadata(in handle: LocalVaultHandle, projectID: String) throws -> [LocalAttachmentMetadata] { throw LocalVaultRepositoryError.unsupportedEntryType(.attachmentRef) }
    func restoreAttachmentMetadata(in handle: LocalVaultHandle, projectID: String, attachmentID: String) throws -> LocalAttachmentMetadata { throw LocalVaultRepositoryError.unsupportedEntryType(.attachmentRef) }
}

public struct LocalVaultProject: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct LocalVaultMovedEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let kind: UnifiedVaultItemKind

    public init(id: String, title: String, kind: UnifiedVaultItemKind) {
        self.id = id
        self.title = title
        self.kind = kind
    }
}

// MARK: - Billing addresses & payment accounts

/// 账单地址的展示行拼装规则（国家/地区差异只影响排版，不做任何有效性判断）。
public enum BillingAddressLines {
    public static func lines(
        streetAddress: String,
        apartment: String,
        city: String,
        stateProvince: String,
        postalCode: String,
        country: String
    ) -> [String] {
        var lines: [String] = []
        let street = streetAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = apartment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !street.isEmpty {
            lines.append(street)
        }
        if !unit.isEmpty {
            lines.append(unit)
        }
        let region = [city, stateProvince]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let zone = [postalCode, country]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let locality = [region, zone].filter { !$0.isEmpty }.joined(separator: " ")
        if !locality.isEmpty {
            lines.append(locality)
        }
        return lines
    }

    public static func singleLine(
        streetAddress: String,
        apartment: String,
        city: String,
        stateProvince: String,
        postalCode: String,
        country: String
    ) -> String {
        lines(
            streetAddress: streetAddress,
            apartment: apartment,
            city: city,
            stateProvince: stateProvince,
            postalCode: postalCode,
            country: country
        ).joined(separator: ", ")
    }
}

public struct LocalBillingAddressEntryDraft: Sendable, Equatable {
    public let title: String
    public let fullName: String
    public let streetAddress: String
    public let apartment: String
    public let city: String
    public let stateProvince: String
    public let postalCode: String
    public let country: String
    public let phone: String
    public let notes: String
    public let metadata: VaultEntryMetadata
    /// 引用该地址的银行卡条目 ID（稳定 ID，不使用卡片展示名）。
    public let linkedCardIDs: [String]

    public init(
        title: String,
        fullName: String = "",
        streetAddress: String = "",
        apartment: String = "",
        city: String = "",
        stateProvince: String = "",
        postalCode: String = "",
        country: String = "",
        phone: String = "",
        notes: String = "",
        metadata: VaultEntryMetadata = .empty,
        linkedCardIDs: [String] = []
    ) {
        self.title = title
        self.fullName = fullName
        self.streetAddress = streetAddress
        self.apartment = apartment
        self.city = city
        self.stateProvince = stateProvince
        self.postalCode = postalCode
        self.country = country
        self.phone = phone
        self.notes = notes
        self.metadata = metadata
        self.linkedCardIDs = linkedCardIDs
    }
}

public struct LocalBillingAddressEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let fullName: String
    public let streetAddress: String
    public let apartment: String
    public let city: String
    public let stateProvince: String
    public let postalCode: String
    public let country: String
    public let phone: String
    public let notes: String
    public let linkedCardIDs: [String]
    public let favorite: Bool

    public init(
        id: String,
        projectID: String,
        title: String,
        fullName: String = "",
        streetAddress: String = "",
        apartment: String = "",
        city: String = "",
        stateProvince: String = "",
        postalCode: String = "",
        country: String = "",
        phone: String = "",
        notes: String = "",
        linkedCardIDs: [String] = [],
        favorite: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.fullName = fullName
        self.streetAddress = streetAddress
        self.apartment = apartment
        self.city = city
        self.stateProvince = stateProvince
        self.postalCode = postalCode
        self.country = country
        self.phone = phone
        self.notes = notes
        self.linkedCardIDs = linkedCardIDs
        self.favorite = favorite
    }
}

public extension LocalBillingAddressEntry {
    var addressLines: [String] {
        BillingAddressLines.lines(
            streetAddress: streetAddress,
            apartment: apartment,
            city: city,
            stateProvince: stateProvince,
            postalCode: postalCode,
            country: country
        )
    }

    var formattedAddress: String {
        addressLines.joined(separator: "\n")
    }

    var addressSummary: String {
        BillingAddressLines.singleLine(
            streetAddress: streetAddress,
            apartment: apartment,
            city: city,
            stateProvince: stateProvince,
            postalCode: postalCode,
            country: country
        )
    }

    var searchableText: String {
        [
            title,
            fullName,
            streetAddress,
            apartment,
            city,
            stateProvince,
            postalCode,
            country,
            phone,
            notes
        ].joined(separator: " ")
    }

    /// 解析引用的银行卡条目；已被删除的引用会被忽略，由 UI 通过 `missingLinkedCardIDs(in:)` 提示。
    func linkedCards(in cards: [LocalCardEntry]) -> [LocalCardEntry] {
        linkedCardIDs.compactMap { id in cards.first { $0.id == id } }
    }

    func missingLinkedCardIDs(in cards: [LocalCardEntry]) -> [String] {
        linkedCardIDs.filter { id in cards.contains { $0.id == id } == false }
    }
}

public enum LocalPaymentAccountKind: String, Sendable, Equatable, CaseIterable {
    case digitalWallet = "digital-wallet"
    case bankAccount = "bank-account"
    case paymentApp = "payment-app"
    case buyNowPayLater = "buy-now-pay-later"
    case cryptoWallet = "crypto-wallet"
    case other

    /// 兼容 Android 备份中的枚举名（`BANK_ACCOUNT`）与 iOS 私有导出值（`bank-account`）。
    public init(androidName: String) {
        let trimmed = androidName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored = LocalPaymentAccountKind(rawValue: trimmed.lowercased()) {
            self = stored
            return
        }
        switch trimmed.uppercased() {
        case "DIGITAL_WALLET":
            self = .digitalWallet
        case "BANK_ACCOUNT":
            self = .bankAccount
        case "PAYMENT_APP":
            self = .paymentApp
        case "BUY_NOW_PAY_LATER":
            self = .buyNowPayLater
        case "CRYPTO_WALLET":
            self = .cryptoWallet
        default:
            self = .other
        }
    }

    public var androidName: String {
        switch self {
        case .digitalWallet:
            return "DIGITAL_WALLET"
        case .bankAccount:
            return "BANK_ACCOUNT"
        case .paymentApp:
            return "PAYMENT_APP"
        case .buyNowPayLater:
            return "BUY_NOW_PAY_LATER"
        case .cryptoWallet:
            return "CRYPTO_WALLET"
        case .other:
            return "OTHER"
        }
    }

    public var displayName: String {
        switch self {
        case .digitalWallet:
            return "数字钱包"
        case .bankAccount:
            return "银行账户"
        case .paymentApp:
            return "支付应用"
        case .buyNowPayLater:
            return "先买后付"
        case .cryptoWallet:
            return "加密钱包"
        case .other:
            return "其他"
        }
    }
}

public struct LocalPaymentAccountEntryDraft: Sendable, Equatable {
    public let title: String
    public let kind: LocalPaymentAccountKind
    public let provider: String
    public let accountName: String
    public let accountHolderName: String
    public let iban: String
    public let swiftBIC: String
    public let routingNumber: String
    public let accountNumber: String
    public let currency: String
    public let notes: String
    public let metadata: VaultEntryMetadata
    /// 关联的银行卡条目 ID（稳定 ID）。
    public let linkedCardID: String
    /// 关联的账单地址条目 ID（稳定 ID）。
    public let billingAddressID: String

    public init(
        title: String,
        kind: LocalPaymentAccountKind = .other,
        provider: String = "",
        accountName: String = "",
        accountHolderName: String = "",
        iban: String = "",
        swiftBIC: String = "",
        routingNumber: String = "",
        accountNumber: String = "",
        currency: String = "",
        notes: String = "",
        metadata: VaultEntryMetadata = .empty,
        linkedCardID: String = "",
        billingAddressID: String = ""
    ) {
        self.title = title
        self.kind = kind
        self.provider = provider
        self.accountName = accountName
        self.accountHolderName = accountHolderName
        self.iban = iban
        self.swiftBIC = swiftBIC
        self.routingNumber = routingNumber
        self.accountNumber = accountNumber
        self.currency = currency
        self.notes = notes
        self.metadata = metadata
        self.linkedCardID = linkedCardID
        self.billingAddressID = billingAddressID
    }
}

public struct LocalPaymentAccountEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let kind: LocalPaymentAccountKind
    public let provider: String
    public let accountName: String
    public let accountHolderName: String
    public let iban: String
    public let swiftBIC: String
    public let routingNumber: String
    public let accountNumber: String
    public let currency: String
    public let notes: String
    public let linkedCardID: String
    public let billingAddressID: String
    public let favorite: Bool

    public init(
        id: String,
        projectID: String,
        title: String,
        kind: LocalPaymentAccountKind = .other,
        provider: String = "",
        accountName: String = "",
        accountHolderName: String = "",
        iban: String = "",
        swiftBIC: String = "",
        routingNumber: String = "",
        accountNumber: String = "",
        currency: String = "",
        notes: String = "",
        linkedCardID: String = "",
        billingAddressID: String = "",
        favorite: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.kind = kind
        self.provider = provider
        self.accountName = accountName
        self.accountHolderName = accountHolderName
        self.iban = iban
        self.swiftBIC = swiftBIC
        self.routingNumber = routingNumber
        self.accountNumber = accountNumber
        self.currency = currency
        self.notes = notes
        self.linkedCardID = linkedCardID
        self.billingAddressID = billingAddressID
        self.favorite = favorite
    }
}

/// 关联引用的解析状态：未关联 / 已关联 / 目标条目已删除（失效关联）。
public enum VaultEntryReferenceStatus: String, Sendable, Equatable {
    case none
    case linked
    case missing
}

public extension LocalPaymentAccountEntry {
    var searchableText: String {
        [
            title,
            kind.displayName,
            provider,
            accountName,
            accountHolderName,
            iban,
            swiftBIC,
            routingNumber,
            currency,
            notes
        ].joined(separator: " ")
    }

    func billingAddress(in billingAddresses: [LocalBillingAddressEntry]) -> LocalBillingAddressEntry? {
        let reference = billingAddressID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reference.isEmpty == false else {
            return nil
        }
        return billingAddresses.first { $0.id == reference }
    }

    func billingAddressReferenceStatus(in billingAddresses: [LocalBillingAddressEntry]) -> VaultEntryReferenceStatus {
        let reference = billingAddressID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reference.isEmpty == false else {
            return .none
        }
        return billingAddresses.contains { $0.id == reference } ? .linked : .missing
    }

    func linkedCard(in cards: [LocalCardEntry]) -> LocalCardEntry? {
        let reference = linkedCardID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reference.isEmpty == false else {
            return nil
        }
        return cards.first { $0.id == reference }
    }

    func linkedCardReferenceStatus(in cards: [LocalCardEntry]) -> VaultEntryReferenceStatus {
        let reference = linkedCardID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reference.isEmpty == false else {
            return .none
        }
        return cards.contains { $0.id == reference } ? .linked : .missing
    }
}

public enum BillingFieldValidationIssue: Sendable, Equatable {
    case ibanCharacters
    case ibanLength
    case ibanChecksum
    case swiftCharacters
    case swiftLength
    case routingNumberFormat
    case postalCodeFormat
    case currencyFormat
}

/// 温和格式校验：只提示格式/长度层面的可疑输入，不判断账户或地址在现实中是否有效，
/// 也不做 US-only 的 IBAN/routing number 强制约束。
public enum BillingFieldValidator {
    public static let minimumIBANLength = 15
    public static let maximumIBANLength = 34
    public static let minimumSWIFTLIength = 8
    public static let maximumSWIFTLength = 11
    public static let maximumReferenceLength = 34
    public static let maximumPostalCodeLength = 16

    public static func normalizedIBAN(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .uppercased()
    }

    public static func normalizedSWIFT(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    public static func ibanIssue(_ value: String) -> BillingFieldValidationIssue? {
        let normalized = normalizedIBAN(value)
        guard normalized.isEmpty == false else {
            return nil
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        guard normalized.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return .ibanCharacters
        }
        guard (minimumIBANLength...maximumIBANLength).contains(normalized.count) else {
            return .ibanLength
        }
        guard isValidIBANChecksum(normalized) else {
            return .ibanChecksum
        }
        return nil
    }

    public static func swiftBICIssue(_ value: String) -> BillingFieldValidationIssue? {
        let normalized = normalizedSWIFT(value)
        guard normalized.isEmpty == false else {
            return nil
        }
        guard normalized.count == minimumSWIFTLIength || normalized.count == maximumSWIFTLength else {
            return .swiftLength
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        guard normalized.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return .swiftCharacters
        }
        return nil
    }

    /// 路由号/清算号：只要求是字母、数字、空格或连字符，长度合理，不套用任何国家的固定长度。
    public static func routingNumberIssue(_ value: String) -> BillingFieldValidationIssue? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 -")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return .routingNumberFormat
        }
        guard trimmed.count <= maximumReferenceLength else {
            return .routingNumberFormat
        }
        return nil
    }

    public static func postalCodeIssue(_ value: String) -> BillingFieldValidationIssue? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 -")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return .postalCodeFormat
        }
        guard trimmed.count <= maximumPostalCodeLength else {
            return .postalCodeFormat
        }
        return nil
    }

    public static func currencyIssue(_ value: String) -> BillingFieldValidationIssue? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }
        guard trimmed.count == 3 else {
            return .currencyFormat
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return .currencyFormat
        }
        return nil
    }

    /// 账号/IBAN 的掩码展示：保留末 4 位，其余用圆点占位。
    public static func maskedAccountNumber(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return ""
        }
        guard trimmed.count > 4 else {
            return String(repeating: "•", count: trimmed.count)
        }
        return String(repeating: "•", count: trimmed.count - 4) + trimmed.suffix(4)
    }

    private static func isValidIBANChecksum(_ iban: String) -> Bool {
        let rearranged = String(iban.dropFirst(4)) + String(iban.prefix(4))
        var remainder = 0
        for scalar in rearranged.unicodeScalars {
            let value: Int
            if scalar.value >= 48, scalar.value <= 57 {
                value = Int(scalar.value - 48)
            } else if scalar.value >= 65, scalar.value <= 90 {
                value = Int(scalar.value - 65) + 10
            } else {
                return false
            }
            remainder = value >= 10 ? (remainder * 100 + value) % 97 : (remainder * 10 + value) % 97
        }
        return remainder == 1
    }
}

public struct LocalAttachmentMetadata: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let entryID: String?
    public let fileName: String
    public let mediaType: String
    public let originalSize: Int64
    public let storedSize: Int64
    public let contentHash: String
    public let storageMode: String
    public let source: String
    public let downloadState: String
    public let wrappedContentEncryptionKey: String?
    public let localPath: String?
    public let deleted: Bool
    public let metadata: VaultEntryMetadata

    public init(
        id: String,
        projectID: String,
        entryID: String?,
        fileName: String,
        mediaType: String,
        originalSize: Int64,
        storedSize: Int64,
        contentHash: String,
        storageMode: String,
        source: String = "",
        downloadState: String = "",
        wrappedContentEncryptionKey: String? = nil,
        localPath: String? = nil,
        deleted: Bool,
        metadata: VaultEntryMetadata = .empty
    ) {
        self.id = id
        self.projectID = projectID
        self.entryID = entryID
        self.fileName = fileName
        self.mediaType = mediaType
        self.originalSize = originalSize
        self.storedSize = storedSize
        self.contentHash = contentHash
        self.storageMode = storageMode
        self.source = source
        self.downloadState = downloadState
        self.wrappedContentEncryptionKey = wrappedContentEncryptionKey
        self.localPath = localPath
        self.deleted = deleted
        self.metadata = metadata
    }
}

public struct AutoFillEncryptedIndexRecord: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let nonce: Data
    public let ciphertext: Data
    public let authenticationTag: Data

    public init(
        id: String,
        nonce: Data,
        ciphertext: Data,
        authenticationTag: Data
    ) {
        self.id = id
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.authenticationTag = authenticationTag
    }
}

public struct AutoFillCredentialIndexRecord: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let username: String
    public let serviceIdentifiers: [String]

    public init(
        id: String,
        title: String,
        username: String,
        serviceIdentifiers: [String]
    ) {
        self.id = id
        self.title = title
        self.username = username
        self.serviceIdentifiers = serviceIdentifiers
    }
}

public struct AutoFillCredentialSecretRecord: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let username: String
    public let password: String

    public init(id: String, username: String, password: String) {
        self.id = id
        self.username = username
        self.password = password
    }
}

public enum AutoFillEncryptedIndexCodecError: Error, Sendable, Equatable, LocalizedError {
    case invalidKeyLength(expected: Int, actual: Int)
    case vaultIdentifierMismatch(expected: String, actual: String)
    case keyIdentifierMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .invalidKeyLength(let expected, let actual):
            return "自动填充索引密钥必须是 \(expected) 字节，当前为 \(actual) 字节。"
        case .vaultIdentifierMismatch(let expected, let actual):
            return "自动填充索引保险库不匹配。预期 \(expected)，当前 \(actual)。"
        case .keyIdentifierMismatch(let expected, let actual):
            return "自动填充索引密钥不匹配。预期 \(expected)，当前 \(actual)。"
        }
    }
}

public struct AutoFillIndexEncryptionKey: Sendable, Equatable {
    public static let requiredByteCount = 32

    public let rawValue: Data

    public init(rawValue: Data) throws {
        guard rawValue.count == AutoFillIndexEncryptionKey.requiredByteCount else {
            throw AutoFillEncryptedIndexCodecError.invalidKeyLength(
                expected: AutoFillIndexEncryptionKey.requiredByteCount,
                actual: rawValue.count
            )
        }

        self.rawValue = rawValue
    }
}

public struct AutoFillEncryptedIndexCodec: Sendable {
    public init() {}

    public func encrypt(
        _ records: [AutoFillCredentialIndexRecord],
        vaultID: String,
        keyIdentifier: String,
        updatedAt: Date,
        key: AutoFillIndexEncryptionKey
    ) throws -> AutoFillEncryptedIndex {
        let symmetricKey = SymmetricKey(data: key.rawValue)
        let encryptedRecords = try records.map { record in
            let plaintext = try Self.payloadEncoder.encode(record)
            let sealedBox = try AES.GCM.seal(plaintext, using: symmetricKey)
            return AutoFillEncryptedIndexRecord(
                id: record.id,
                nonce: Data(sealedBox.nonce),
                ciphertext: sealedBox.ciphertext,
                authenticationTag: sealedBox.tag
            )
        }

        return AutoFillEncryptedIndex(
            vaultID: vaultID,
            keyIdentifier: keyIdentifier,
            updatedAt: updatedAt,
            records: encryptedRecords
        )
    }

    public func decrypt(
        _ index: AutoFillEncryptedIndex,
        key: AutoFillIndexEncryptionKey
    ) throws -> [AutoFillCredentialIndexRecord] {
        let symmetricKey = SymmetricKey(data: key.rawValue)
        return try index.records.map { record in
            let nonce = try AES.GCM.Nonce(data: record.nonce)
            let sealedBox = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: record.ciphertext,
                tag: record.authenticationTag
            )
            let plaintext = try AES.GCM.open(sealedBox, using: symmetricKey)
            return try Self.payloadDecoder.decode(
                AutoFillCredentialIndexRecord.self,
                from: plaintext
            )
        }
    }

    private static let payloadEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let payloadDecoder = JSONDecoder()
}

public struct AutoFillEncryptedIndex: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let vaultID: String
    public let keyIdentifier: String
    public let updatedAt: Date
    public let records: [AutoFillEncryptedIndexRecord]

    public init(
        schemaVersion: Int = AutoFillEncryptedIndex.currentSchemaVersion,
        vaultID: String,
        keyIdentifier: String,
        updatedAt: Date,
        records: [AutoFillEncryptedIndexRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.vaultID = vaultID
        self.keyIdentifier = keyIdentifier
        self.updatedAt = updatedAt
        self.records = records
    }
}

public struct AutoFillEncryptedCredentialSecretRecord: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let nonce: Data
    public let ciphertext: Data
    public let authenticationTag: Data

    public init(
        id: String,
        nonce: Data,
        ciphertext: Data,
        authenticationTag: Data
    ) {
        self.id = id
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.authenticationTag = authenticationTag
    }
}

public struct AutoFillCredentialSecretSnapshot: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let vaultID: String
    public let keyIdentifier: String
    public let updatedAt: Date
    public let records: [AutoFillEncryptedCredentialSecretRecord]

    public init(
        schemaVersion: Int = AutoFillCredentialSecretSnapshot.currentSchemaVersion,
        vaultID: String,
        keyIdentifier: String,
        updatedAt: Date,
        records: [AutoFillEncryptedCredentialSecretRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.vaultID = vaultID
        self.keyIdentifier = keyIdentifier
        self.updatedAt = updatedAt
        self.records = records
    }
}

public protocol AutoFillEncryptedIndexStore: Sendable {
    func save(_ index: AutoFillEncryptedIndex) throws
    func load() throws -> AutoFillEncryptedIndex?
    func delete() throws
}

public protocol AutoFillCredentialSecretStore: Sendable {
    func save(_ snapshot: AutoFillCredentialSecretSnapshot) throws
    func load() throws -> AutoFillCredentialSecretSnapshot?
    func delete() throws
}

public struct AutoFillUnlockedCredentialIndex: Sendable, Equatable {
    public let vaultID: String
    public let keyIdentifier: String
    public let updatedAt: Date
    public let records: [AutoFillCredentialIndexRecord]

    public init(
        vaultID: String,
        keyIdentifier: String,
        updatedAt: Date,
        records: [AutoFillCredentialIndexRecord]
    ) {
        self.vaultID = vaultID
        self.keyIdentifier = keyIdentifier
        self.updatedAt = updatedAt
        self.records = records
    }

    public func search(_ query: String) -> [AutoFillCredentialIndexRecord] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else {
            return records
        }

        return records.filter { record in
            record.title.localizedCaseInsensitiveContains(normalizedQuery)
                || record.username.localizedCaseInsensitiveContains(normalizedQuery)
                || record.serviceIdentifiers.contains {
                    $0.localizedCaseInsensitiveContains(normalizedQuery)
                }
        }
    }

    public func records(
        matchingServiceIdentifier serviceIdentifier: String
    ) -> [AutoFillCredentialIndexRecord] {
        guard let requestedHost = Self.normalizedHost(from: serviceIdentifier) else {
            return []
        }

        return records.filter { record in
            record.serviceIdentifiers.contains { candidate in
                guard let candidateHost = Self.normalizedHost(from: candidate) else {
                    return false
                }
                return requestedHost == candidateHost
                    || requestedHost.hasSuffix(".\(candidateHost)")
                    || candidateHost.hasSuffix(".\(requestedHost)")
            }
        }
    }

    private static func normalizedHost(from serviceIdentifier: String) -> String? {
        let trimmed = serviceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let host = URL(string: trimmed)?.host(), !host.isEmpty {
            return host.lowercased()
        }

        if let host = URL(string: "https://\(trimmed)")?.host(), !host.isEmpty {
            return host.lowercased()
        }

        return nil
    }
}

public struct AutoFillCredentialIndexUnlocker: Sendable {
    private let codec: AutoFillEncryptedIndexCodec

    public init(codec: AutoFillEncryptedIndexCodec = AutoFillEncryptedIndexCodec()) {
        self.codec = codec
    }

    public func unlock(
        _ index: AutoFillEncryptedIndex,
        vaultID: String,
        keyIdentifier: String,
        key: AutoFillIndexEncryptionKey
    ) throws -> AutoFillUnlockedCredentialIndex {
        guard index.vaultID == vaultID else {
            throw AutoFillEncryptedIndexCodecError.vaultIdentifierMismatch(
                expected: vaultID,
                actual: index.vaultID
            )
        }
        guard index.keyIdentifier == keyIdentifier else {
            throw AutoFillEncryptedIndexCodecError.keyIdentifierMismatch(
                expected: keyIdentifier,
                actual: index.keyIdentifier
            )
        }

        return AutoFillUnlockedCredentialIndex(
            vaultID: index.vaultID,
            keyIdentifier: index.keyIdentifier,
            updatedAt: index.updatedAt,
            records: try codec.decrypt(index, key: key)
        )
    }
}

public struct AutoFillCredentialSecretCodec: Sendable {
    public init() {}

    public func encrypt(
        _ records: [AutoFillCredentialSecretRecord],
        vaultID: String,
        keyIdentifier: String,
        updatedAt: Date,
        key: AutoFillIndexEncryptionKey
    ) throws -> AutoFillCredentialSecretSnapshot {
        let symmetricKey = SymmetricKey(data: key.rawValue)
        let encryptedRecords = try records.map { record in
            let plaintext = try Self.payloadEncoder.encode(record)
            let sealedBox = try AES.GCM.seal(plaintext, using: symmetricKey)
            return AutoFillEncryptedCredentialSecretRecord(
                id: record.id,
                nonce: Data(sealedBox.nonce),
                ciphertext: sealedBox.ciphertext,
                authenticationTag: sealedBox.tag
            )
        }

        return AutoFillCredentialSecretSnapshot(
            vaultID: vaultID,
            keyIdentifier: keyIdentifier,
            updatedAt: updatedAt,
            records: encryptedRecords
        )
    }

    public func decrypt(
        _ snapshot: AutoFillCredentialSecretSnapshot,
        key: AutoFillIndexEncryptionKey
    ) throws -> [AutoFillCredentialSecretRecord] {
        let symmetricKey = SymmetricKey(data: key.rawValue)
        return try snapshot.records.map { record in
            let nonce = try AES.GCM.Nonce(data: record.nonce)
            let sealedBox = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: record.ciphertext,
                tag: record.authenticationTag
            )
            let plaintext = try AES.GCM.open(sealedBox, using: symmetricKey)
            return try Self.payloadDecoder.decode(
                AutoFillCredentialSecretRecord.self,
                from: plaintext
            )
        }
    }

    private static let payloadEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let payloadDecoder = JSONDecoder()
}

public struct AutoFillUnlockedCredentialSecretSnapshot: Sendable, Equatable {
    public let vaultID: String
    public let keyIdentifier: String
    public let updatedAt: Date
    public let records: [AutoFillCredentialSecretRecord]

    public init(
        vaultID: String,
        keyIdentifier: String,
        updatedAt: Date,
        records: [AutoFillCredentialSecretRecord]
    ) {
        self.vaultID = vaultID
        self.keyIdentifier = keyIdentifier
        self.updatedAt = updatedAt
        self.records = records
    }

    public func secret(id: String) -> AutoFillCredentialSecretRecord? {
        records.first { $0.id == id }
    }
}

public struct AutoFillCredentialSecretUnlocker: Sendable {
    private let codec: AutoFillCredentialSecretCodec

    public init(codec: AutoFillCredentialSecretCodec = AutoFillCredentialSecretCodec()) {
        self.codec = codec
    }

    public func unlock(
        _ snapshot: AutoFillCredentialSecretSnapshot,
        vaultID: String,
        keyIdentifier: String,
        key: AutoFillIndexEncryptionKey
    ) throws -> AutoFillUnlockedCredentialSecretSnapshot {
        guard snapshot.vaultID == vaultID else {
            throw AutoFillEncryptedIndexCodecError.vaultIdentifierMismatch(
                expected: vaultID,
                actual: snapshot.vaultID
            )
        }
        guard snapshot.keyIdentifier == keyIdentifier else {
            throw AutoFillEncryptedIndexCodecError.keyIdentifierMismatch(
                expected: keyIdentifier,
                actual: snapshot.keyIdentifier
            )
        }

        return AutoFillUnlockedCredentialSecretSnapshot(
            vaultID: snapshot.vaultID,
            keyIdentifier: snapshot.keyIdentifier,
            updatedAt: snapshot.updatedAt,
            records: try codec.decrypt(snapshot, key: key)
        )
    }
}

public enum AutoFillCredentialResolverError: Error, Sendable, Equatable, LocalizedError {
    case credentialUnavailable
    case credentialSecretUnavailable

    public var errorDescription: String? {
        switch self {
        case .credentialUnavailable:
            return "自动填充凭据不可用。"
        case .credentialSecretUnavailable:
            return "自动填充凭据密钥不可用。"
        }
    }
}

public struct AutoFillCredentialResolver: Sendable {
    public let index: AutoFillUnlockedCredentialIndex
    public let secrets: AutoFillUnlockedCredentialSecretSnapshot

    public init(
        index: AutoFillUnlockedCredentialIndex,
        secrets: AutoFillUnlockedCredentialSecretSnapshot
    ) {
        self.index = index
        self.secrets = secrets
    }

    public func records(
        matchingServiceIdentifiers serviceIdentifiers: [String]
    ) -> [AutoFillCredentialIndexRecord] {
        guard !serviceIdentifiers.isEmpty else {
            return index.records
        }

        var matchedRecords: [AutoFillCredentialIndexRecord] = []
        for serviceIdentifier in serviceIdentifiers {
            matchedRecords.append(
                contentsOf: index.records(
                    matchingServiceIdentifier: serviceIdentifier
                )
            )
        }

        return deduplicated(matchedRecords)
    }

    public func search(
        _ query: String,
        within records: [AutoFillCredentialIndexRecord]
    ) -> [AutoFillCredentialIndexRecord] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return records
        }

        let recordIDs = Set(records.map(\.id))
        return index.search(trimmedQuery).filter { recordIDs.contains($0.id) }
    }

    public func credential(
        recordIdentifier: String
    ) throws -> AutoFillCredentialSecretRecord {
        let trimmedIdentifier = recordIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard index.records.contains(where: { $0.id == trimmedIdentifier }) else {
            throw AutoFillCredentialResolverError.credentialUnavailable
        }
        guard let secret = secrets.secret(id: trimmedIdentifier) else {
            throw AutoFillCredentialResolverError.credentialSecretUnavailable
        }
        return secret
    }

    public func credential(
        for record: AutoFillCredentialIndexRecord
    ) throws -> AutoFillCredentialSecretRecord {
        try credential(recordIdentifier: record.id)
    }

    private func deduplicated(
        _ records: [AutoFillCredentialIndexRecord]
    ) -> [AutoFillCredentialIndexRecord] {
        var seen = Set<String>()
        return records.filter { record in
            seen.insert(record.id).inserted
        }
    }
}

public struct FileAutoFillEncryptedIndexStore: AutoFillEncryptedIndexStore {
    public static let indexFileName = "autofill-index-v1.json"

    public let appGroupContainerURL: URL
    public let indexFileURL: URL

    public init(appGroupContainerURL: URL) {
        self.appGroupContainerURL = appGroupContainerURL
        self.indexFileURL = appGroupContainerURL.appendingPathComponent(
            FileAutoFillEncryptedIndexStore.indexFileName,
            isDirectory: false
        )
    }

    public func save(_ index: AutoFillEncryptedIndex) throws {
        try FileManager.default.createDirectory(
            at: appGroupContainerURL,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(index)
        try data.write(to: indexFileURL, options: fileWritingOptions)
    }

    public func load() throws -> AutoFillEncryptedIndex? {
        guard FileManager.default.fileExists(atPath: indexFileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: indexFileURL)
        return try JSONDecoder().decode(AutoFillEncryptedIndex.self, from: data)
    }

    public func delete() throws {
        guard FileManager.default.fileExists(atPath: indexFileURL.path) else {
            return
        }

        try FileManager.default.removeItem(at: indexFileURL)
    }

    private var fileWritingOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtection]
        #else
        [.atomic]
        #endif
    }
}

public struct FileAutoFillCredentialSecretStore: AutoFillCredentialSecretStore {
    public static let secretFileName = "autofill-secrets-v1.json"

    public let appGroupContainerURL: URL
    public let secretFileURL: URL

    public init(appGroupContainerURL: URL) {
        self.appGroupContainerURL = appGroupContainerURL
        self.secretFileURL = appGroupContainerURL.appendingPathComponent(
            FileAutoFillCredentialSecretStore.secretFileName,
            isDirectory: false
        )
    }

    public func save(_ snapshot: AutoFillCredentialSecretSnapshot) throws {
        try FileManager.default.createDirectory(
            at: appGroupContainerURL,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: secretFileURL, options: fileWritingOptions)
    }

    public func load() throws -> AutoFillCredentialSecretSnapshot? {
        guard FileManager.default.fileExists(atPath: secretFileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: secretFileURL)
        return try JSONDecoder().decode(AutoFillCredentialSecretSnapshot.self, from: data)
    }

    public func delete() throws {
        guard FileManager.default.fileExists(atPath: secretFileURL.path) else {
            return
        }

        try FileManager.default.removeItem(at: secretFileURL)
    }

    private var fileWritingOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtection]
        #else
        [.atomic]
        #endif
    }
}

public struct LocalVaultRepository {
    private let engine: any LocalVaultEngine

    public init(engine: any LocalVaultEngine = MDBXLocalVaultEngine()) {
        self.engine = engine
    }

    public func entryRepository(for session: LocalVaultSession) -> LocalVaultEntryRepository {
        LocalVaultEntryRepository(session: session, engine: engine)
    }

    public func closeVault(for session: LocalVaultSession) {
        engine.closeVault(session.handle)
    }

    public func createVault(
        named name: String,
        in directoryURL: URL,
        password: String,
        deviceID: String
    ) throws -> LocalVaultSession {
        let displayName = try normalizedVaultName(name)
        try validatePassword(password)

        let fileURL = directoryURL.appendingPathComponent(
            "\(displayName).mdbx",
            isDirectory: false
        )
        let handle = try engine.createVault(
            at: fileURL,
            password: password,
            deviceID: deviceID
        )
        return LocalVaultSession(
            descriptor: LocalVaultDescriptor(fileURL: fileURL, displayName: displayName),
            handle: handle,
            state: .unlocked
        )
    }

    public func openVault(
        at fileURL: URL,
        password: String,
        deviceID: String
    ) throws -> LocalVaultSession {
        try validatePassword(password)

        let handle = try engine.openVault(
            at: fileURL,
            password: password,
            deviceID: deviceID
        )
        return LocalVaultSession(
            descriptor: LocalVaultDescriptor(
                fileURL: fileURL,
                displayName: fileURL.deletingPathExtension().lastPathComponent
            ),
            handle: handle,
            state: .unlocked
        )
    }

    public func openVaultWithSecurityKey(
        at fileURL: URL,
        securityKeyMaterial: Data,
        deviceID: String
    ) throws -> LocalVaultSession {
        try validateSecurityKeyMaterial(securityKeyMaterial)

        let handle = try engine.openVaultWithSecurityKey(
            at: fileURL,
            securityKeyMaterial: securityKeyMaterial,
            deviceID: deviceID
        )
        return LocalVaultSession(
            descriptor: LocalVaultDescriptor(
                fileURL: fileURL,
                displayName: fileURL.deletingPathExtension().lastPathComponent
            ),
            handle: handle,
            state: .unlocked
        )
    }

    public func setupLocalSecurityKeyUnlock(
        for session: LocalVaultSession,
        securityKeyMaterial: Data
    ) throws {
        try validateSecurityKeyMaterial(securityKeyMaterial)
        try engine.setupLocalSecurityKeyUnlock(
            in: session.handle,
            securityKeyMaterial: securityKeyMaterial
        )
    }

    public func resetMasterPassword(
        for session: LocalVaultSession,
        newPassword: String
    ) throws {
        try validatePassword(newPassword)
        try engine.resetMasterPassword(
            in: session.handle,
            newPassword: newPassword
        )
    }

    /// 在独立临时连接上校验主密码，不改变当前会话状态。
    ///
    /// 供「按数据类型清空」等高风险操作做二次确认：校验失败会抛
    /// `LocalVaultRepositoryError.currentPasswordMismatch`，调用方必须放弃删除。
    public func verifyMasterPassword(
        for session: LocalVaultSession,
        password: String
    ) throws {
        guard session.state == .unlocked else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        try validatePassword(password)
        let verifiedHandle = try engine.verifyMasterPassword(
            at: session.descriptor.fileURL,
            password: password,
            deviceID: session.handle.deviceID
        )
        guard verifiedHandle.vaultID == session.handle.vaultID else {
            throw LocalVaultRepositoryError.currentPasswordMismatch
        }
    }

    /// 修改主密码：先校验旧口令，再在同一个已解锁会话上重包裹 vault key。
    ///
    /// 设计要点：
    /// - 主密码只是 KEK，MDBX 里的记录/附件仍然由同一个随机 vault key 加密，所以这里
    ///   只替换 `unlock_methods` 里的 KDF 参数与 `wrapped_vault_key`，不做全库重加密。
    /// - 旧口令在**独立临时连接**上验证，失败时不触碰正在使用的句柄；引擎实现必须保证
    ///   临时连接不会被登记为当前会话（见 `verifyMasterPassword`）。
    /// - 真正的重包裹由引擎在单个事务里完成；中途掉电由 SQLite 回滚，旧口令仍然有效。
    /// - 注意：当前 FFI 的 `resetMasterPassword` 使用默认 KDF 档位（Multi），与「忘记密码」
    ///   重置路径一致；这只会影响新建 wrapped key 的 KDF 参数，不影响既有数据。
    public func changeMasterPassword(
        for session: LocalVaultSession,
        currentPassword: String,
        newPassword: String
    ) throws {
        guard session.state == .unlocked else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        try validatePassword(currentPassword)
        try validatePassword(newPassword)
        guard !newPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalVaultRepositoryError.emptyPassword
        }
        guard currentPassword != newPassword else {
            throw LocalVaultRepositoryError.passwordUnchanged
        }

        try verifyMasterPassword(for: session, password: currentPassword)

        try engine.resetMasterPassword(
            in: session.handle,
            newPassword: newPassword
        )
    }

    private func normalizedVaultName(_ name: String) throws -> String {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw LocalVaultRepositoryError.emptyVaultName
        }
        return normalized
    }

    private func validatePassword(_ password: String) throws {
        guard !password.isEmpty else {
            throw LocalVaultRepositoryError.emptyPassword
        }
    }

    private func validateSecurityKeyMaterial(_ securityKeyMaterial: Data) throws {
        guard !securityKeyMaterial.isEmpty else {
            throw LocalVaultRepositoryError.emptySecurityKeyMaterial
        }
    }
}

public struct LocalVaultEntryRepository {
    let session: LocalVaultSession
    let engine: any LocalVaultEngine

    public init(
        session: LocalVaultSession,
        engine: any LocalVaultEngine
    ) {
        self.session = session
        self.engine = engine
    }

    public func createProject(title: String) throws -> LocalVaultProject {
        let normalizedTitle = try normalizedProjectTitle(title)
        return try engine.createProject(
            in: session.handle,
            title: normalizedTitle
        )
    }

    public func listProjects() throws -> [LocalVaultProject] {
        try engine.listProjects(in: session.handle)
    }

    public func renameProject(
        projectID: String,
        title: String
    ) throws -> LocalVaultProject {
        let normalizedTitle = try normalizedProjectTitle(title)
        return try engine.renameProject(
            in: session.handle,
            projectID: projectID,
            title: normalizedTitle
        )
    }

    public func deleteProject(projectID: String) throws {
        try engine.deleteProject(
            in: session.handle,
            projectID: projectID
        )
    }

    public func moveEntry(
        kind: UnifiedVaultItemKind,
        entryID: String,
        fromProjectID: String,
        toProjectID: String
    ) throws -> LocalVaultMovedEntry {
        let moved = try engine.moveEntry(
            in: session.handle,
            kind: kind,
            entryID: entryID,
            fromProjectID: fromProjectID,
            toProjectID: toProjectID
        )
        // 侧表用稳定 itemID 关联，跟着条目一起换分类，避免移动后自定义字段/关联丢失。
        try engine.moveItemExtras(
            in: session.handle,
            itemID: entryID,
            fromProjectID: fromProjectID,
            toProjectID: toProjectID
        )
        return moved
    }

    public func listItemExtras(projectID: String) throws -> [String: VaultItemExtras] {
        try engine.listItemExtras(in: session.handle, projectID: projectID)
    }

    public func saveItemExtras(
        projectID: String,
        extras: VaultItemExtras
    ) throws -> VaultItemExtras {
        guard !extras.itemID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        return try engine.saveItemExtras(
            in: session.handle,
            projectID: projectID,
            extras: extras
        )
    }

    public func deleteItemExtras(projectID: String, itemID: String) throws {
        try engine.deleteItemExtras(
            in: session.handle,
            projectID: projectID,
            itemID: itemID
        )
    }

    public func createBillingAddressEntry(projectID: String, draft: LocalBillingAddressEntryDraft) throws -> LocalBillingAddressEntry {
        try engine.createBillingAddressEntry(in: session.handle, projectID: projectID, draft: normalizedBillingAddressEntryDraft(draft))
    }

    public func listBillingAddressEntries(projectID: String) throws -> [LocalBillingAddressEntry] {
        try engine.listBillingAddressEntries(in: session.handle, projectID: projectID)
    }

    public func updateBillingAddressEntry(projectID: String, entryID: String, draft: LocalBillingAddressEntryDraft) throws -> LocalBillingAddressEntry {
        try engine.updateBillingAddressEntry(in: session.handle, projectID: projectID, entryID: entryID, draft: normalizedBillingAddressEntryDraft(draft))
    }

    public func setBillingAddressEntryFavorite(projectID: String, entryID: String, favorite: Bool) throws -> LocalBillingAddressEntry {
        try engine.setBillingAddressEntryFavorite(in: session.handle, projectID: projectID, entryID: entryID, favorite: favorite)
    }

    public func deleteBillingAddressEntry(projectID: String, entryID: String) throws {
        try engine.deleteBillingAddressEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func listDeletedBillingAddressEntries(projectID: String) throws -> [LocalBillingAddressEntry] {
        try engine.listDeletedBillingAddressEntries(in: session.handle, projectID: projectID)
    }

    public func restoreBillingAddressEntry(projectID: String, entryID: String) throws -> LocalBillingAddressEntry {
        try engine.restoreBillingAddressEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func createPaymentAccountEntry(projectID: String, draft: LocalPaymentAccountEntryDraft) throws -> LocalPaymentAccountEntry {
        try engine.createPaymentAccountEntry(in: session.handle, projectID: projectID, draft: normalizedPaymentAccountEntryDraft(draft))
    }

    public func listPaymentAccountEntries(projectID: String) throws -> [LocalPaymentAccountEntry] {
        try engine.listPaymentAccountEntries(in: session.handle, projectID: projectID)
    }

    public func updatePaymentAccountEntry(projectID: String, entryID: String, draft: LocalPaymentAccountEntryDraft) throws -> LocalPaymentAccountEntry {
        try engine.updatePaymentAccountEntry(in: session.handle, projectID: projectID, entryID: entryID, draft: normalizedPaymentAccountEntryDraft(draft))
    }

    public func setPaymentAccountEntryFavorite(projectID: String, entryID: String, favorite: Bool) throws -> LocalPaymentAccountEntry {
        try engine.setPaymentAccountEntryFavorite(in: session.handle, projectID: projectID, entryID: entryID, favorite: favorite)
    }

    public func deletePaymentAccountEntry(projectID: String, entryID: String) throws {
        try engine.deletePaymentAccountEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func listDeletedPaymentAccountEntries(projectID: String) throws -> [LocalPaymentAccountEntry] {
        try engine.listDeletedPaymentAccountEntries(in: session.handle, projectID: projectID)
    }

    public func restorePaymentAccountEntry(projectID: String, entryID: String) throws -> LocalPaymentAccountEntry {
        try engine.restorePaymentAccountEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func createGPGKeyEntry(projectID: String, draft: LocalGPGKeyEntryDraft) throws -> LocalGPGKeyEntry {
        try engine.createGPGKeyEntry(in: session.handle, projectID: projectID, draft: normalizedGPGKeyEntryDraft(draft))
    }

    public func listGPGKeyEntries(projectID: String) throws -> [LocalGPGKeyEntry] {
        try engine.listGPGKeyEntries(in: session.handle, projectID: projectID)
    }

    public func updateGPGKeyEntry(projectID: String, entryID: String, draft: LocalGPGKeyEntryDraft) throws -> LocalGPGKeyEntry {
        try engine.updateGPGKeyEntry(in: session.handle, projectID: projectID, entryID: entryID, draft: normalizedGPGKeyEntryDraft(draft))
    }

    public func setGPGKeyEntryFavorite(projectID: String, entryID: String, favorite: Bool) throws -> LocalGPGKeyEntry {
        try engine.setGPGKeyEntryFavorite(in: session.handle, projectID: projectID, entryID: entryID, favorite: favorite)
    }

    public func deleteGPGKeyEntry(projectID: String, entryID: String) throws {
        try engine.deleteGPGKeyEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func listDeletedGPGKeyEntries(projectID: String) throws -> [LocalGPGKeyEntry] {
        try engine.listDeletedGPGKeyEntries(in: session.handle, projectID: projectID)
    }

    public func restoreGPGKeyEntry(projectID: String, entryID: String) throws -> LocalGPGKeyEntry {
        try engine.restoreGPGKeyEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func createSteamEntry(projectID: String, draft: LocalSteamEntryDraft) throws -> LocalSteamEntry {
        try engine.createSteamEntry(in: session.handle, projectID: projectID, draft: normalizedSteamEntryDraft(draft))
    }

    public func listSteamEntries(projectID: String) throws -> [LocalSteamEntry] {
        try engine.listSteamEntries(in: session.handle, projectID: projectID)
    }

    public func updateSteamEntry(projectID: String, entryID: String, draft: LocalSteamEntryDraft) throws -> LocalSteamEntry {
        try engine.updateSteamEntry(in: session.handle, projectID: projectID, entryID: entryID, draft: normalizedSteamEntryDraft(draft))
    }

    public func setSteamEntryFavorite(projectID: String, entryID: String, favorite: Bool) throws -> LocalSteamEntry {
        try engine.setSteamEntryFavorite(in: session.handle, projectID: projectID, entryID: entryID, favorite: favorite)
    }

    public func deleteSteamEntry(projectID: String, entryID: String) throws {
        try engine.deleteSteamEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func listDeletedSteamEntries(projectID: String) throws -> [LocalSteamEntry] {
        try engine.listDeletedSteamEntries(in: session.handle, projectID: projectID)
    }

    public func restoreSteamEntry(projectID: String, entryID: String) throws -> LocalSteamEntry {
        try engine.restoreSteamEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func createAttachmentMetadata(
        projectID: String,
        entryID: String?,
        fileName: String,
        mediaType: String,
        originalSize: Int64,
        storedSize: Int64,
        contentHash: String,
        storageMode: String,
        source: String = "",
        downloadState: String = "",
        wrappedContentEncryptionKey: String? = nil,
        localPath: String? = nil
    ) throws -> LocalAttachmentMetadata {
        let normalizedFileName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFileName.isEmpty else {
            throw LocalVaultRepositoryError.emptyEntryTitle
        }
        return try engine.createAttachmentMetadata(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            fileName: normalizedFileName,
            mediaType: mediaType,
            originalSize: originalSize,
            storedSize: storedSize,
            contentHash: contentHash,
            storageMode: storageMode,
            source: source,
            downloadState: downloadState,
            wrappedContentEncryptionKey: wrappedContentEncryptionKey,
            localPath: localPath
        )
    }

    public func listAttachmentMetadata(projectID: String) throws -> [LocalAttachmentMetadata] {
        try engine.listAttachmentMetadata(in: session.handle, projectID: projectID)
    }

    public func updateAttachmentMetadata(
        projectID: String,
        attachmentID: String,
        entryID: String?,
        fileName: String,
        mediaType: String,
        originalSize: Int64,
        storedSize: Int64,
        contentHash: String,
        storageMode: String,
        source: String = "",
        downloadState: String = "",
        wrappedContentEncryptionKey: String? = nil,
        localPath: String? = nil
    ) throws -> LocalAttachmentMetadata {
        let normalizedFileName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFileName.isEmpty else {
            throw LocalVaultRepositoryError.emptyEntryTitle
        }
        return try engine.updateAttachmentMetadata(
            in: session.handle,
            projectID: projectID,
            attachmentID: attachmentID,
            entryID: entryID,
            fileName: normalizedFileName,
            mediaType: mediaType,
            originalSize: originalSize,
            storedSize: storedSize,
            contentHash: contentHash,
            storageMode: storageMode,
            source: source,
            downloadState: downloadState,
            wrappedContentEncryptionKey: wrappedContentEncryptionKey,
            localPath: localPath
        )
    }

    public func deleteAttachmentMetadata(projectID: String, attachmentID: String) throws {
        try engine.deleteAttachmentMetadata(in: session.handle, projectID: projectID, attachmentID: attachmentID)
    }

    public func listDeletedAttachmentMetadata(projectID: String) throws -> [LocalAttachmentMetadata] {
        try engine.listDeletedAttachmentMetadata(in: session.handle, projectID: projectID)
    }

    public func restoreAttachmentMetadata(projectID: String, attachmentID: String) throws -> LocalAttachmentMetadata {
        try engine.restoreAttachmentMetadata(in: session.handle, projectID: projectID, attachmentID: attachmentID)
    }

    private func normalizedProjectTitle(_ title: String) throws -> String {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw LocalVaultRepositoryError.emptyProjectTitle
        }
        return normalized
    }

    private func normalizedBillingAddressEntryDraft(_ draft: LocalBillingAddressEntryDraft) throws -> LocalBillingAddressEntryDraft {
        let normalizedTitle = try normalizedEntryTitle(draft.title)
        return LocalBillingAddressEntryDraft(
            title: normalizedTitle,
            fullName: draft.fullName.trimmingCharacters(in: .whitespacesAndNewlines),
            streetAddress: draft.streetAddress.trimmingCharacters(in: .whitespacesAndNewlines),
            apartment: draft.apartment.trimmingCharacters(in: .whitespacesAndNewlines),
            city: draft.city.trimmingCharacters(in: .whitespacesAndNewlines),
            stateProvince: draft.stateProvince.trimmingCharacters(in: .whitespacesAndNewlines),
            postalCode: draft.postalCode.trimmingCharacters(in: .whitespacesAndNewlines),
            country: draft.country.trimmingCharacters(in: .whitespacesAndNewlines),
            phone: draft.phone.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: draft.notes,
            linkedCardIDs: normalizedReferenceIdentifiers(draft.linkedCardIDs)
        )
    }

    private func normalizedPaymentAccountEntryDraft(_ draft: LocalPaymentAccountEntryDraft) throws -> LocalPaymentAccountEntryDraft {
        let normalizedTitle = try normalizedEntryTitle(draft.title)
        return LocalPaymentAccountEntryDraft(
            title: normalizedTitle,
            kind: draft.kind,
            provider: draft.provider.trimmingCharacters(in: .whitespacesAndNewlines),
            accountName: draft.accountName.trimmingCharacters(in: .whitespacesAndNewlines),
            accountHolderName: draft.accountHolderName.trimmingCharacters(in: .whitespacesAndNewlines),
            iban: BillingFieldValidator.normalizedIBAN(draft.iban),
            swiftBIC: BillingFieldValidator.normalizedSWIFT(draft.swiftBIC),
            routingNumber: draft.routingNumber.trimmingCharacters(in: .whitespacesAndNewlines),
            accountNumber: draft.accountNumber.trimmingCharacters(in: .whitespacesAndNewlines),
            currency: draft.currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            notes: draft.notes,
            linkedCardID: draft.linkedCardID.trimmingCharacters(in: .whitespacesAndNewlines),
            billingAddressID: draft.billingAddressID.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func normalizedReferenceIdentifiers(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for identifier in identifiers {
            let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false, seen.insert(trimmed).inserted else {
                continue
            }
            result.append(trimmed)
        }
        return result
    }

    private func normalizedGPGKeyEntryDraft(_ draft: LocalGPGKeyEntryDraft) throws -> LocalGPGKeyEntryDraft {
        let normalizedTitle = try normalizedEntryTitle(draft.title)
        let publicKey = draft.armoredPublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let privateKey = draft.armoredPrivateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // 没有密钥材料就没有可展示/可复制的指纹，拒绝写入半成品条目。
        // 只导入私钥块时公钥可以为空：私钥块本身已包含公钥 packet，指纹也来自它。
        guard !publicKey.isEmpty || !privateKey.isEmpty, !draft.metadata.fingerprint.isEmpty else {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        return LocalGPGKeyEntryDraft(
            title: normalizedTitle,
            notes: draft.notes,
            armoredPublicKey: publicKey,
            armoredPrivateKey: privateKey,
            metadata: draft.metadata,
            importedAt: draft.importedAt
        )
    }

    private func normalizedSteamEntryDraft(_ draft: LocalSteamEntryDraft) throws -> LocalSteamEntryDraft {
        let normalizedTitle = try normalizedEntryTitle(draft.title)
        guard SteamSharedSecretValidator.isValid(draft.sharedSecret) else {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        let issuer = draft.issuer.trimmingCharacters(in: .whitespacesAndNewlines)
        return LocalSteamEntryDraft(
            title: normalizedTitle,
            accountName: draft.accountName.trimmingCharacters(in: .whitespacesAndNewlines),
            steamID: draft.steamID.trimmingCharacters(in: .whitespacesAndNewlines),
            sharedSecret: SteamSharedSecretValidator.normalizedBase64(draft.sharedSecret),
            issuer: issuer.isEmpty ? "Steam" : issuer,
            notes: draft.notes
        )
    }

    func normalizedEntryTitle(_ title: String) throws -> String {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw LocalVaultRepositoryError.emptyEntryTitle
        }
        return normalizedTitle
    }
}

public final class MDBXLocalVaultEngine: LocalVaultEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var vaults: [String: MonicaMDBXVault] = [:]
    private var projects: [String: [LocalVaultProject]] = [:]

    public init() {}

    public func createVault(
        at fileURL: URL,
        password: String,
        deviceID: String
    ) throws -> LocalVaultHandle {
        let vault = try MonicaMDBXRuntime.createVault(
            at: fileURL,
            password: password,
            deviceID: deviceID
        )
        let info = vault.info()
        store(vault, vaultID: info.vaultID)
        return LocalVaultHandle(vaultID: info.vaultID, deviceID: info.deviceID)
    }

    public func openVault(
        at fileURL: URL,
        password: String,
        deviceID: String
    ) throws -> LocalVaultHandle {
        let vault = try MonicaMDBXRuntime.openVault(
            at: fileURL,
            password: password,
            deviceID: deviceID
        )
        let info = vault.info()
        store(vault, vaultID: info.vaultID)
        return LocalVaultHandle(vaultID: info.vaultID, deviceID: info.deviceID)
    }

    public func openVaultWithSecurityKey(
        at fileURL: URL,
        securityKeyMaterial: Data,
        deviceID: String
    ) throws -> LocalVaultHandle {
        let vault = try MonicaMDBXRuntime.openVaultWithSecurityKey(
            at: fileURL,
            securityKeyMaterial: securityKeyMaterial,
            deviceID: deviceID
        )
        let info = vault.info()
        store(vault, vaultID: info.vaultID)
        return LocalVaultHandle(vaultID: info.vaultID, deviceID: info.deviceID)
    }

    /// 用临时连接校验主密码。
    ///
    /// 这里刻意**不**把这个连接登记进 `vaults`：同一个保险库的 vaultID 不变，一旦登记就会
    /// 覆盖正在使用的句柄，随后 `closeVault` 会把用户的活会话一起关掉。临时连接在函数返回
    /// 时随 ARC 释放，SQLite 的 WAL 允许它与现有连接并存。
    public func verifyMasterPassword(
        at fileURL: URL,
        password: String,
        deviceID: String
    ) throws -> LocalVaultHandle {
        do {
            let vault = try MonicaMDBXRuntime.openVault(
                at: fileURL,
                password: password,
                deviceID: deviceID
            )
            let info = vault.info()
            return LocalVaultHandle(vaultID: info.vaultID, deviceID: info.deviceID)
        } catch {
            throw Self.verificationError(from: error)
        }
    }

    private static func verificationError(from error: Error) -> Error {
        #if canImport(mdbx_ffiFFI)
        if let ffiError = error as? MdbxFfiError, case .Storage(let message) = ffiError {
            // 引擎对错误口令返回 StorageError::Validation("incorrect credential")，
            // 只有这种情形才转换成「当前主密码不正确」，其余错误（IO、schema 等）原样抛出。
            if message.localizedCaseInsensitiveContains("credential") {
                return LocalVaultRepositoryError.currentPasswordMismatch
            }
        }
        #endif
        return error
    }

    public func setupLocalSecurityKeyUnlock(
        in handle: LocalVaultHandle,
        securityKeyMaterial: Data
    ) throws {
        try vault(for: handle).setupLocalSecurityKeyUnlock(securityKeyMaterial)
    }

    public func resetMasterPassword(
        in handle: LocalVaultHandle,
        newPassword: String
    ) throws {
        try vault(for: handle).resetMasterPassword(newPassword)
    }

    public func closeVault(_ handle: LocalVaultHandle) {
        lock.lock()
        defer { lock.unlock() }
        vaults.removeValue(forKey: handle.vaultID)
        projects.removeValue(forKey: handle.vaultID)
    }

    public func createProject(
        in handle: LocalVaultHandle,
        title: String
    ) throws -> LocalVaultProject {
        let project = try vault(for: handle).createProject(title: title)
        let localProject = LocalVaultProject(id: project.id, title: project.title)
        lock.lock()
        projects[handle.vaultID, default: []].append(localProject)
        lock.unlock()
        return localProject
    }

    public func listProjects(in handle: LocalVaultHandle) throws -> [LocalVaultProject] {
        _ = try vault(for: handle)
        lock.lock()
        defer { lock.unlock() }
        return projects[handle.vaultID, default: []]
    }

    public func renameProject(
        in handle: LocalVaultHandle,
        projectID: String,
        title: String
    ) throws -> LocalVaultProject {
        _ = try vault(for: handle)
        lock.lock()
        defer { lock.unlock() }
        guard let index = projects[handle.vaultID, default: []].firstIndex(where: { $0.id == projectID }) else {
            throw LocalVaultRepositoryError.projectNotFound
        }
        let renamed = LocalVaultProject(id: projectID, title: title)
        projects[handle.vaultID, default: []][index] = renamed
        return renamed
    }

    public func deleteProject(in handle: LocalVaultHandle, projectID: String) throws {
        _ = try vault(for: handle)
        guard try !projectContainsEntries(handle: handle, projectID: projectID) else {
            throw LocalVaultRepositoryError.projectNotEmpty
        }
        lock.lock()
        defer { lock.unlock() }
        guard projects[handle.vaultID, default: []].contains(where: { $0.id == projectID }) else {
            throw LocalVaultRepositoryError.projectNotFound
        }
        projects[handle.vaultID, default: []].removeAll { $0.id == projectID }
    }

    public func moveEntry(
        in handle: LocalVaultHandle,
        kind: UnifiedVaultItemKind,
        entryID: String,
        fromProjectID: String,
        toProjectID: String
    ) throws -> LocalVaultMovedEntry {
        switch kind {
        case .login:
            let entry = try vault(for: handle).moveLoginEntry(
                projectID: fromProjectID,
                entryID: entryID,
                targetProjectID: toProjectID
            )
            return LocalVaultMovedEntry(id: entry.id, title: entry.title, kind: kind)
        case .note:
            let entry = try vault(for: handle).moveNoteEntry(
                projectID: fromProjectID,
                entryID: entryID,
                targetProjectID: toProjectID
            )
            return LocalVaultMovedEntry(id: entry.id, title: entry.title, kind: kind)
        case .totp:
            let entry = try vault(for: handle).moveTotpEntry(
                projectID: fromProjectID,
                entryID: entryID,
                targetProjectID: toProjectID
            )
            return LocalVaultMovedEntry(id: entry.id, title: entry.title, kind: kind)
        case .card:
            let entry = try vault(for: handle).moveCardEntry(
                projectID: fromProjectID,
                entryID: entryID,
                targetProjectID: toProjectID
            )
            return LocalVaultMovedEntry(id: entry.id, title: entry.title, kind: kind)
        case .identity:
            let entry = try vault(for: handle).moveIdentityEntry(
                projectID: fromProjectID,
                entryID: entryID,
                targetProjectID: toProjectID
            )
            return LocalVaultMovedEntry(id: entry.id, title: entry.title, kind: kind)
        case .passkey, .sshKey, .apiToken, .wifi, .sso, .barcode, .send, .attachmentRef, .steam, .billingAddress, .paymentAccount, .gpgKey:
            let mapping = parityMoveMapping(for: kind)
            let entry = try moveParityEntry(
                in: handle,
                projectID: fromProjectID,
                entryID: entryID,
                entryType: mapping.entryType,
                kind: mapping.kind,
                targetProjectID: toProjectID
            )
            return LocalVaultMovedEntry(id: entry.id, title: entry.title, kind: kind)
        }
    }

    public func createBillingAddressEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalBillingAddressEntryDraft) throws -> LocalBillingAddressEntry {
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "document-ref",
            kind: "billing-address",
            title: draft.title,
            payload: billingAddressPayload(draft)
        )
        return try LocalBillingAddressEntry(entry)
    }

    public func listBillingAddressEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalBillingAddressEntry] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "billing-address").map(LocalBillingAddressEntry.init)
    }

    public func updateBillingAddressEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalBillingAddressEntryDraft) throws -> LocalBillingAddressEntry {
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: entryID,
            entryType: "document-ref",
            kind: "billing-address",
            title: draft.title,
            payload: billingAddressPayload(draft)
        )
        return try LocalBillingAddressEntry(entry)
    }

    public func setBillingAddressEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalBillingAddressEntry {
        try LocalBillingAddressEntry(setParityEntryFavorite(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "billing-address", favorite: favorite))
    }

    public func deleteBillingAddressEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        try deleteParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "billing-address")
    }

    public func listDeletedBillingAddressEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalBillingAddressEntry] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "billing-address").map(LocalBillingAddressEntry.init)
    }

    public func restoreBillingAddressEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalBillingAddressEntry {
        try LocalBillingAddressEntry(restoreParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "billing-address"))
    }

    public func createPaymentAccountEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalPaymentAccountEntryDraft) throws -> LocalPaymentAccountEntry {
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "document-ref",
            kind: "payment-account",
            title: draft.title,
            payload: paymentAccountPayload(draft)
        )
        return try LocalPaymentAccountEntry(entry)
    }

    public func listPaymentAccountEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalPaymentAccountEntry] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "payment-account").map(LocalPaymentAccountEntry.init)
    }

    public func updatePaymentAccountEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalPaymentAccountEntryDraft) throws -> LocalPaymentAccountEntry {
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: entryID,
            entryType: "document-ref",
            kind: "payment-account",
            title: draft.title,
            payload: paymentAccountPayload(draft)
        )
        return try LocalPaymentAccountEntry(entry)
    }

    public func setPaymentAccountEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalPaymentAccountEntry {
        try LocalPaymentAccountEntry(setParityEntryFavorite(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "payment-account", favorite: favorite))
    }

    public func deletePaymentAccountEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        try deleteParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "payment-account")
    }

    public func listDeletedPaymentAccountEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalPaymentAccountEntry] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "payment-account").map(LocalPaymentAccountEntry.init)
    }

    public func restorePaymentAccountEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalPaymentAccountEntry {
        try LocalPaymentAccountEntry(restoreParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "payment-account"))
    }

    private func billingAddressPayload(_ draft: LocalBillingAddressEntryDraft) -> [String: Any] {
        [
            "schemaVersion": 1,
            "fullName": draft.fullName,
            "streetAddress": draft.streetAddress,
            "apartment": draft.apartment,
            "city": draft.city,
            "stateProvince": draft.stateProvince,
            "postalCode": draft.postalCode,
            "country": draft.country,
            "phone": draft.phone,
            "notes": draft.notes,
            "linkedCardIDs": draft.linkedCardIDs
        ]
    }

    private func paymentAccountPayload(_ draft: LocalPaymentAccountEntryDraft) -> [String: Any] {
        [
            "schemaVersion": 1,
            "paymentType": draft.kind.rawValue,
            "provider": draft.provider,
            "accountName": draft.accountName,
            "accountHolderName": draft.accountHolderName,
            "iban": draft.iban,
            "swiftBic": draft.swiftBIC,
            "routingNumber": draft.routingNumber,
            "accountNumber": draft.accountNumber,
            "currency": draft.currency,
            "notes": draft.notes,
            "linkedCardID": draft.linkedCardID,
            "billingAddressID": draft.billingAddressID
        ]
    }

    public func createGPGKeyEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalGPGKeyEntryDraft) throws -> LocalGPGKeyEntry {
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "document-ref",
            kind: "gpg-key",
            title: draft.title,
            payload: draft.parityPayload
        )
        return try LocalGPGKeyEntry(entry)
    }

    public func listGPGKeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalGPGKeyEntry] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "gpg-key").map(LocalGPGKeyEntry.init)
    }

    public func updateGPGKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalGPGKeyEntryDraft) throws -> LocalGPGKeyEntry {
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: entryID,
            entryType: "document-ref",
            kind: "gpg-key",
            title: draft.title,
            payload: draft.parityPayload
        )
        return try LocalGPGKeyEntry(entry)
    }

    public func setGPGKeyEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalGPGKeyEntry {
        try LocalGPGKeyEntry(setParityEntryFavorite(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "gpg-key", favorite: favorite))
    }

    public func deleteGPGKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        try deleteParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "gpg-key")
    }

    public func listDeletedGPGKeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalGPGKeyEntry] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "gpg-key").map(LocalGPGKeyEntry.init)
    }

    public func restoreGPGKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalGPGKeyEntry {
        try LocalGPGKeyEntry(restoreParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "gpg-key"))
    }

    public func createSteamEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalSteamEntryDraft) throws -> LocalSteamEntry {
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "document-ref",
            kind: "steam",
            title: draft.title,
            payload: SteamEntryPayloadCodec.encoded(draft)
        )
        return try LocalSteamEntry(entry)
    }

    public func listSteamEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSteamEntry] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "steam").map(LocalSteamEntry.init)
    }

    public func updateSteamEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalSteamEntryDraft) throws -> LocalSteamEntry {
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: entryID,
            entryType: "document-ref",
            kind: "steam",
            title: draft.title,
            payload: SteamEntryPayloadCodec.encoded(draft)
        )
        return try LocalSteamEntry(entry)
    }

    public func setSteamEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalSteamEntry {
        try LocalSteamEntry(setParityEntryFavorite(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "steam", favorite: favorite))
    }

    public func deleteSteamEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        try deleteParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "steam")
    }

    public func listDeletedSteamEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSteamEntry] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "steam").map(LocalSteamEntry.init)
    }

    public func restoreSteamEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalSteamEntry {
        try LocalSteamEntry(restoreParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "steam"))
    }

    public func createAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String?,
        fileName: String,
        mediaType: String,
        originalSize: Int64,
        storedSize: Int64,
        contentHash: String,
        storageMode: String,
        source: String = "",
        downloadState: String = "",
        wrappedContentEncryptionKey: String? = nil,
        localPath: String? = nil
    ) throws -> LocalAttachmentMetadata {
        var payload: [String: Any] = [
            "fileName": fileName,
            "mediaType": mediaType,
            "originalSize": originalSize,
            "storedSize": storedSize,
            "contentHash": contentHash,
            "storageMode": storageMode,
            "source": source,
            "downloadState": downloadState
        ]
        if let entryID {
            payload["entryID"] = entryID
        }
        if let wrappedContentEncryptionKey {
            payload["wrappedContentEncryptionKey"] = wrappedContentEncryptionKey
        }
        if let localPath {
            payload["localPath"] = localPath
        }
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "document-ref",
            kind: "attachment-ref",
            title: fileName,
            payload: payload
        )
        return try LocalAttachmentMetadata(entry, deleted: false)
    }

    public func listAttachmentMetadata(in handle: LocalVaultHandle, projectID: String) throws -> [LocalAttachmentMetadata] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "attachment-ref")
            .map { try LocalAttachmentMetadata($0, deleted: false) }
    }

    public func updateAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String,
        attachmentID: String,
        entryID: String?,
        fileName: String,
        mediaType: String,
        originalSize: Int64,
        storedSize: Int64,
        contentHash: String,
        storageMode: String,
        source: String = "",
        downloadState: String = "",
        wrappedContentEncryptionKey: String? = nil,
        localPath: String? = nil
    ) throws -> LocalAttachmentMetadata {
        var payload: [String: Any] = [
            "fileName": fileName,
            "mediaType": mediaType,
            "originalSize": originalSize,
            "storedSize": storedSize,
            "contentHash": contentHash,
            "storageMode": storageMode,
            "source": source,
            "downloadState": downloadState
        ]
        if let entryID {
            payload["entryID"] = entryID
        }
        if let wrappedContentEncryptionKey {
            payload["wrappedContentEncryptionKey"] = wrappedContentEncryptionKey
        }
        if let localPath {
            payload["localPath"] = localPath
        }
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: attachmentID,
            entryType: "document-ref",
            kind: "attachment-ref",
            title: fileName,
            payload: payload
        )
        return try LocalAttachmentMetadata(entry, deleted: false)
    }

    public func deleteAttachmentMetadata(in handle: LocalVaultHandle, projectID: String, attachmentID: String) throws {
        try deleteParityEntry(
            in: handle,
            projectID: projectID,
            entryID: attachmentID,
            entryType: "document-ref",
            kind: "attachment-ref"
        )
    }

    public func listDeletedAttachmentMetadata(in handle: LocalVaultHandle, projectID: String) throws -> [LocalAttachmentMetadata] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "attachment-ref")
            .map { try LocalAttachmentMetadata($0, deleted: true) }
    }

    public func restoreAttachmentMetadata(in handle: LocalVaultHandle, projectID: String, attachmentID: String) throws -> LocalAttachmentMetadata {
        let entry = try restoreParityEntry(
            in: handle,
            projectID: projectID,
            entryID: attachmentID,
            entryType: "document-ref",
            kind: "attachment-ref"
        )
        return try LocalAttachmentMetadata(entry, deleted: false)
    }

    private func store(_ vault: MonicaMDBXVault, vaultID: String) {
        lock.lock()
        defer { lock.unlock() }
        vaults[vaultID] = vault
        projects[vaultID, default: []] = projects[vaultID, default: []]
    }

    func vault(for handle: LocalVaultHandle) throws -> MonicaMDBXVault {
        lock.lock()
        defer { lock.unlock() }
        guard let vault = vaults[handle.vaultID] else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        return vault
    }

    private func projectContainsEntries(handle: LocalVaultHandle, projectID: String) throws -> Bool {
        try !listLoginEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedLoginEntries(in: handle, projectID: projectID).isEmpty
            || !listNoteEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedNoteEntries(in: handle, projectID: projectID).isEmpty
            || !listTotpEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedTotpEntries(in: handle, projectID: projectID).isEmpty
            || !listCardEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedCardEntries(in: handle, projectID: projectID).isEmpty
            || !listIdentityEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedIdentityEntries(in: handle, projectID: projectID).isEmpty
            || !listPasskeyEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedPasskeyEntries(in: handle, projectID: projectID).isEmpty
            || !listSshKeyEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedSshKeyEntries(in: handle, projectID: projectID).isEmpty
            || !listApiTokenEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedApiTokenEntries(in: handle, projectID: projectID).isEmpty
            || !listWifiEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedWifiEntries(in: handle, projectID: projectID).isEmpty
            || !listSSOEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedSSOEntries(in: handle, projectID: projectID).isEmpty
            || !listBarcodeEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedBarcodeEntries(in: handle, projectID: projectID).isEmpty
            || !listSendEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedSendEntries(in: handle, projectID: projectID).isEmpty
            || !listAttachmentMetadata(in: handle, projectID: projectID).isEmpty
            || !listDeletedAttachmentMetadata(in: handle, projectID: projectID).isEmpty
            || !listGPGKeyEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedGPGKeyEntries(in: handle, projectID: projectID).isEmpty
    }

    func createParityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryType: String,
        kind: String,
        title: String,
        payload: [String: Any]
    ) throws -> MonicaMDBXParityEntry {
        try vault(for: handle).createParityEntry(
            projectID: projectID,
            entryType: entryType,
            kind: kind,
            title: title,
            payloadJSON: parityPayloadJSON(payload)
        )
    }

    func listParityEntries(
        in handle: LocalVaultHandle,
        projectID: String,
        entryType: String,
        kind: String
    ) throws -> [MonicaMDBXParityEntry] {
        try vault(for: handle).listParityEntries(projectID: projectID, entryType: entryType, kind: kind)
    }

    func listDeletedParityEntries(
        in handle: LocalVaultHandle,
        projectID: String,
        entryType: String,
        kind: String
    ) throws -> [MonicaMDBXParityEntry] {
        try vault(for: handle).listDeletedParityEntries(projectID: projectID, entryType: entryType, kind: kind)
    }

    func updateParityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        entryType: String,
        kind: String,
        title: String,
        payload: [String: Any]
    ) throws -> MonicaMDBXParityEntry {
        try vault(for: handle).updateParityEntry(
            projectID: projectID,
            entryID: entryID,
            entryType: entryType,
            kind: kind,
            title: title,
            payloadJSON: parityPayloadJSON(payload)
        )
    }

    func setParityEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        entryType: String,
        kind: String,
        favorite: Bool
    ) throws -> MonicaMDBXParityEntry {
        try vault(for: handle).setParityEntryFavorite(
            projectID: projectID,
            entryID: entryID,
            entryType: entryType,
            kind: kind,
            favorite: favorite
        )
    }

    func deleteParityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        entryType: String,
        kind: String
    ) throws {
        try vault(for: handle).deleteParityEntry(
            projectID: projectID,
            entryID: entryID,
            entryType: entryType,
            kind: kind
        )
    }

    func restoreParityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        entryType: String,
        kind: String
    ) throws -> MonicaMDBXParityEntry {
        try vault(for: handle).restoreParityEntry(
            projectID: projectID,
            entryID: entryID,
            entryType: entryType,
            kind: kind
        )
    }

    private func moveParityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        entryType: String,
        kind: String,
        targetProjectID: String
    ) throws -> MonicaMDBXParityEntry {
        try vault(for: handle).moveParityEntry(
            projectID: projectID,
            entryID: entryID,
            entryType: entryType,
            kind: kind,
            targetProjectID: targetProjectID
        )
    }

    private func parityMoveMapping(for kind: UnifiedVaultItemKind) -> (entryType: String, kind: String) {
        switch kind {
        case .passkey:
            return ("passkey", "passkey")
        case .sshKey:
            return ("ssh-key", "ssh-key")
        case .apiToken:
            return ("api-token", "api-token")
        case .wifi:
            return ("document-ref", "wifi")
        case .sso:
            return ("document-ref", "sso")
        case .barcode:
            return ("document-ref", "barcode")
        case .send:
            return ("document-ref", "send")
        case .attachmentRef:
            return ("document-ref", "attachment-ref")
        case .steam:
            return ("document-ref", "steam")
        case .billingAddress:
            return ("document-ref", "billing-address")
        case .paymentAccount:
            return ("document-ref", "payment-account")
        case .gpgKey:
            return ("document-ref", "gpg-key")
        case .login, .totp, .note, .card, .identity:
            preconditionFailure("Core entry kinds do not use parity move mapping.")
        }
    }

    private func parityPayloadJSON(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        return json
    }

    // MARK: - Item extras (自定义字段 + 关联条目)

    public func listItemExtras(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [String: VaultItemExtras] {
        let entries = try vault(for: handle).listParityEntries(
            projectID: projectID,
            entryType: VaultItemExtrasStorage.entryType,
            kind: VaultItemExtrasStorage.entryKind
        )
        var extrasByItemID: [String: VaultItemExtras] = [:]
        for entry in entries {
            guard let extras = VaultItemExtras(
                payloadJSON: entry.payloadJSON,
                fallbackItemID: entry.title
            ) else {
                continue
            }
            extrasByItemID[extras.itemID] = extras
        }
        return extrasByItemID
    }

    public func saveItemExtras(
        in handle: LocalVaultHandle,
        projectID: String,
        extras: VaultItemExtras
    ) throws -> VaultItemExtras {
        let normalized = extras.normalized()
        guard !normalized.itemID.isEmpty else {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        let payloadJSON = try normalized.payloadJSONString()
        let vault = try vault(for: handle)

        let activeEntries = try vault.listParityEntries(
            projectID: projectID,
            entryType: VaultItemExtrasStorage.entryType,
            kind: VaultItemExtrasStorage.entryKind
        )
        if let existing = activeEntries.first(where: { itemExtrasEntry($0, matchesItemID: normalized.itemID) }) {
            _ = try vault.updateParityEntry(
                projectID: projectID,
                entryID: existing.id,
                entryType: VaultItemExtrasStorage.entryType,
                kind: VaultItemExtrasStorage.entryKind,
                title: normalized.itemID,
                payloadJSON: payloadJSON
            )
            return normalized
        }

        // 同 itemID 的侧表可能还在回收站里（例如先清空又加回字段），优先恢复它，
        // 避免同一个条目留下多条互不一致的隐藏记录。
        let deletedEntries = try vault.listDeletedParityEntries(
            projectID: projectID,
            entryType: VaultItemExtrasStorage.entryType,
            kind: VaultItemExtrasStorage.entryKind
        )
        if let restorable = deletedEntries.first(where: { itemExtrasEntry($0, matchesItemID: normalized.itemID) }) {
            _ = try vault.restoreParityEntry(
                projectID: projectID,
                entryID: restorable.id,
                entryType: VaultItemExtrasStorage.entryType,
                kind: VaultItemExtrasStorage.entryKind
            )
            _ = try vault.updateParityEntry(
                projectID: projectID,
                entryID: restorable.id,
                entryType: VaultItemExtrasStorage.entryType,
                kind: VaultItemExtrasStorage.entryKind,
                title: normalized.itemID,
                payloadJSON: payloadJSON
            )
            return normalized
        }

        _ = try vault.createParityEntry(
            projectID: projectID,
            entryType: VaultItemExtrasStorage.entryType,
            kind: VaultItemExtrasStorage.entryKind,
            title: normalized.itemID,
            payloadJSON: payloadJSON
        )
        return normalized
    }

    public func deleteItemExtras(
        in handle: LocalVaultHandle,
        projectID: String,
        itemID: String
    ) throws {
        let targetItemID = itemID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetItemID.isEmpty else {
            return
        }
        let vault = try vault(for: handle)
        let entries = try vault.listParityEntries(
            projectID: projectID,
            entryType: VaultItemExtrasStorage.entryType,
            kind: VaultItemExtrasStorage.entryKind
        )
        guard let entry = entries.first(where: { itemExtrasEntry($0, matchesItemID: targetItemID) }) else {
            return
        }
        try vault.deleteParityEntry(
            projectID: projectID,
            entryID: entry.id,
            entryType: VaultItemExtrasStorage.entryType,
            kind: VaultItemExtrasStorage.entryKind
        )
    }

    public func moveItemExtras(
        in handle: LocalVaultHandle,
        itemID: String,
        fromProjectID: String,
        toProjectID: String
    ) throws {
        let targetItemID = itemID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetItemID.isEmpty, fromProjectID != toProjectID else {
            return
        }
        let vault = try vault(for: handle)
        let entries = try vault.listParityEntries(
            projectID: fromProjectID,
            entryType: VaultItemExtrasStorage.entryType,
            kind: VaultItemExtrasStorage.entryKind
        )
        guard let entry = entries.first(where: { itemExtrasEntry($0, matchesItemID: targetItemID) }) else {
            return
        }
        _ = try vault.moveParityEntry(
            projectID: fromProjectID,
            entryID: entry.id,
            entryType: VaultItemExtrasStorage.entryType,
            kind: VaultItemExtrasStorage.entryKind,
            targetProjectID: toProjectID
        )
    }

    // MARK: - 文件夹层级侧表（issue #27）
    //
    // 文件夹的 parentID 等元数据放在一个隐藏的「锚点工程」里，每条记录一个
    // ParityEntry；记录随保险库加密，且不需要知道每个文件夹的 projectID
    // 就能一次列出整棵树。

    public func listVaultFolderRecords(
        in handle: LocalVaultHandle,
        anchorProjectID: String
    ) throws -> [VaultFolderRecord] {
        let entries = try vault(for: handle).listParityEntries(
            projectID: anchorProjectID,
            entryType: VaultFolderRecord.entryType,
            kind: VaultFolderRecord.entryKind
        )
        return entries.compactMap { entry in
            VaultFolderRecord(payloadJSON: entry.payloadJSON, fallbackFolderID: entry.title)
        }
    }

    public func saveVaultFolderRecord(
        in handle: LocalVaultHandle,
        anchorProjectID: String,
        record: VaultFolderRecord
    ) throws {
        guard !record.folderID.isEmpty else {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        let payloadJSON = try record.payloadJSONString()
        let vault = try vault(for: handle)
        let existingEntries = try vault.listParityEntries(
            projectID: anchorProjectID,
            entryType: VaultFolderRecord.entryType,
            kind: VaultFolderRecord.entryKind
        )
        if let existing = existingEntries.first(where: { vaultFolderEntry($0, matchesFolderID: record.folderID) }) {
            _ = try vault.updateParityEntry(
                projectID: anchorProjectID,
                entryID: existing.id,
                entryType: VaultFolderRecord.entryType,
                kind: VaultFolderRecord.entryKind,
                title: record.folderID,
                payloadJSON: payloadJSON
            )
            return
        }
        // 同 folderID 的记录可能还在回收站（先删文件夹又恢复），优先恢复它，
        // 避免同一文件夹在侧表里留下两条互相矛盾的记录。
        let deletedEntries = try vault.listDeletedParityEntries(
            projectID: anchorProjectID,
            entryType: VaultFolderRecord.entryType,
            kind: VaultFolderRecord.entryKind
        )
        if let deletedEntry = deletedEntries.first(where: { vaultFolderEntry($0, matchesFolderID: record.folderID) }) {
            _ = try vault.restoreParityEntry(
                projectID: anchorProjectID,
                entryID: deletedEntry.id,
                entryType: VaultFolderRecord.entryType,
                kind: VaultFolderRecord.entryKind
            )
            _ = try vault.updateParityEntry(
                projectID: anchorProjectID,
                entryID: deletedEntry.id,
                entryType: VaultFolderRecord.entryType,
                kind: VaultFolderRecord.entryKind,
                title: record.folderID,
                payloadJSON: payloadJSON
            )
            return
        }
        _ = try vault.createParityEntry(
            projectID: anchorProjectID,
            entryType: VaultFolderRecord.entryType,
            kind: VaultFolderRecord.entryKind,
            title: record.folderID,
            payloadJSON: payloadJSON
        )
    }

    public func deleteVaultFolderRecord(
        in handle: LocalVaultHandle,
        anchorProjectID: String,
        folderID: String
    ) throws {
        let vault = try vault(for: handle)
        let entries = try vault.listParityEntries(
            projectID: anchorProjectID,
            entryType: VaultFolderRecord.entryType,
            kind: VaultFolderRecord.entryKind
        )
        guard let entry = entries.first(where: { vaultFolderEntry($0, matchesFolderID: folderID) }) else {
            return
        }
        try vault.deleteParityEntry(
            projectID: anchorProjectID,
            entryID: entry.id,
            entryType: VaultFolderRecord.entryType,
            kind: VaultFolderRecord.entryKind
        )
    }

    // MARK: - 常用账号模板侧表（issue #127）
    //
    // 模板和文件夹记录共用隐藏锚点工程（同一个 project），但用独立的 entryKind。
    // 侧表记录的 title 存的是 templateID，正文才是模板 JSON——和文件夹侧表一致。

    public func listAccountTemplates(
        in handle: LocalVaultHandle,
        anchorProjectID: String
    ) throws -> [AccountTemplate] {
        let entries = try vault(for: handle).listParityEntries(
            projectID: anchorProjectID,
            entryType: AccountTemplate.entryType,
            kind: AccountTemplate.entryKind
        )
        return entries.compactMap { entry in
            AccountTemplate(payloadJSON: entry.payloadJSON, fallbackTemplateID: entry.title)
        }
    }

    public func saveAccountTemplate(
        in handle: LocalVaultHandle,
        anchorProjectID: String,
        template: AccountTemplate
    ) throws {
        guard !template.templateID.isEmpty else {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        let payloadJSON = try template.payloadJSONString()
        let vault = try vault(for: handle)
        let existingEntries = try vault.listParityEntries(
            projectID: anchorProjectID,
            entryType: AccountTemplate.entryType,
            kind: AccountTemplate.entryKind
        )
        if let existing = existingEntries.first(where: { accountTemplateEntry($0, matchesTemplateID: template.templateID) }) {
            _ = try vault.updateParityEntry(
                projectID: anchorProjectID,
                entryID: existing.id,
                entryType: AccountTemplate.entryType,
                kind: AccountTemplate.entryKind,
                title: template.templateID,
                payloadJSON: payloadJSON
            )
            return
        }
        // 同一个 templateID 可能还在回收站（导入覆盖时先删后写），优先恢复旧记录。
        let deletedEntries = try vault.listDeletedParityEntries(
            projectID: anchorProjectID,
            entryType: AccountTemplate.entryType,
            kind: AccountTemplate.entryKind
        )
        if let deletedEntry = deletedEntries.first(where: { accountTemplateEntry($0, matchesTemplateID: template.templateID) }) {
            _ = try vault.restoreParityEntry(
                projectID: anchorProjectID,
                entryID: deletedEntry.id,
                entryType: AccountTemplate.entryType,
                kind: AccountTemplate.entryKind
            )
            _ = try vault.updateParityEntry(
                projectID: anchorProjectID,
                entryID: deletedEntry.id,
                entryType: AccountTemplate.entryType,
                kind: AccountTemplate.entryKind,
                title: template.templateID,
                payloadJSON: payloadJSON
            )
            return
        }
        _ = try vault.createParityEntry(
            projectID: anchorProjectID,
            entryType: AccountTemplate.entryType,
            kind: AccountTemplate.entryKind,
            title: template.templateID,
            payloadJSON: payloadJSON
        )
    }

    public func deleteAccountTemplate(
        in handle: LocalVaultHandle,
        anchorProjectID: String,
        templateID: String
    ) throws {
        let vault = try vault(for: handle)
        let entries = try vault.listParityEntries(
            projectID: anchorProjectID,
            entryType: AccountTemplate.entryType,
            kind: AccountTemplate.entryKind
        )
        guard let entry = entries.first(where: { accountTemplateEntry($0, matchesTemplateID: templateID) }) else {
            return
        }
        _ = try vault.deleteParityEntry(
            projectID: anchorProjectID,
            entryID: entry.id,
            entryType: AccountTemplate.entryType,
            kind: AccountTemplate.entryKind
        )
    }

    private func accountTemplateEntry(_ entry: MonicaMDBXParityEntry, matchesTemplateID templateID: String) -> Bool {
        if let record = AccountTemplate(payloadJSON: entry.payloadJSON, fallbackTemplateID: entry.title) {
            return record.templateID == templateID
        }
        return entry.title == templateID
    }

    private func vaultFolderEntry(_ entry: MonicaMDBXParityEntry, matchesFolderID folderID: String) -> Bool {
        if let record = VaultFolderRecord(payloadJSON: entry.payloadJSON, fallbackFolderID: entry.title) {
            return record.folderID == folderID
        }
        return entry.title == folderID
    }

    private func itemExtrasEntry(_ entry: MonicaMDBXParityEntry, matchesItemID itemID: String) -> Bool {
        if let extras = VaultItemExtras(payloadJSON: entry.payloadJSON, fallbackItemID: entry.title) {
            return extras.itemID == itemID
        }
        return entry.title == itemID
    }
}

private extension LocalBillingAddressEntry {
    init(_ entry: MonicaMDBXParityEntry) throws {
        let payload = try entry.payloadDictionary()
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            fullName: payload.string("fullName"),
            streetAddress: payload.string("streetAddress"),
            apartment: payload.string("apartment"),
            city: payload.string("city"),
            stateProvince: payload.string("stateProvince"),
            postalCode: payload.string("postalCode"),
            country: payload.string("country"),
            phone: payload.string("phone"),
            notes: payload.string("notes"),
            linkedCardIDs: payload.stringArray("linkedCardIDs"),
            favorite: entry.favorite
        )
    }
}

private extension LocalPaymentAccountEntry {
    init(_ entry: MonicaMDBXParityEntry) throws {
        let payload = try entry.payloadDictionary()
        let storedKindValue = payload.string("paymentType")
        let storedKind = storedKindValue.isEmpty ? "OTHER" : storedKindValue
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            kind: LocalPaymentAccountKind(androidName: storedKind),
            provider: payload.string("provider"),
            accountName: payload.string("accountName"),
            accountHolderName: payload.string("accountHolderName"),
            iban: payload.string("iban"),
            swiftBIC: payload.string("swiftBic"),
            routingNumber: payload.string("routingNumber"),
            accountNumber: payload.string("accountNumber"),
            currency: payload.string("currency"),
            notes: payload.string("notes"),
            linkedCardID: payload.string("linkedCardID"),
            billingAddressID: payload.string("billingAddressID"),
            favorite: entry.favorite
        )
    }
}

private extension LocalGPGKeyEntry {
    init(_ entry: MonicaMDBXParityEntry) throws {
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            favorite: entry.favorite,
            payload: try entry.payloadDictionary()
        )
    }
}

extension LocalGPGKeyEntry {
    /// 从 parity payload 还原条目（storage 内部与编解码测试共用）。
    ///
    /// 键名统一走 `GPGKeyPayload`，避免写入侧与读取侧字段漂移；
    /// `keyExpiresAt` 用 0 表示「无过期时间」，因为 JSON 不能存 nil。
    init(id: String, projectID: String, title: String, favorite: Bool, payload: [String: Any]) {
        let expiresAt = payload.int64(GPGKeyPayload.keyExpiresAt)
        self.init(
            id: id,
            projectID: projectID,
            title: title,
            ownerName: payload.string(GPGKeyPayload.ownerName),
            ownerEmail: payload.string(GPGKeyPayload.ownerEmail),
            userID: payload.string(GPGKeyPayload.userID),
            fingerprint: payload.string(GPGKeyPayload.fingerprint),
            keyID: payload.string(GPGKeyPayload.keyID),
            algorithm: payload.string(GPGKeyPayload.algorithm),
            keyVersion: payload.int(GPGKeyPayload.keyVersion),
            algorithmID: UInt8(truncatingIfNeeded: payload.int64(GPGKeyPayload.algorithmID)),
            keyCreatedAt: Date(timeIntervalSince1970: TimeInterval(payload.int64(GPGKeyPayload.keyCreatedAt))),
            keyExpiresAt: expiresAt > 0 ? Date(timeIntervalSince1970: TimeInterval(expiresAt)) : nil,
            isRevoked: payload.bool(GPGKeyPayload.isRevoked),
            isSecretKey: payload.bool(GPGKeyPayload.isSecretKey),
            secretKeyIsEncrypted: payload.bool(GPGKeyPayload.secretKeyIsEncrypted),
            notes: payload.string(GPGKeyPayload.notes),
            armoredPublicKey: payload.string(GPGKeyPayload.armoredPublicKey),
            armoredPrivateKey: payload.string(GPGKeyPayload.armoredPrivateKey),
            importedAt: Date(timeIntervalSince1970: TimeInterval(payload.int64(GPGKeyPayload.importedAt))),
            favorite: favorite
        )
    }
}

private extension LocalAttachmentMetadata {
    init(_ entry: MonicaMDBXParityEntry, deleted: Bool) throws {
        let payload = try entry.payloadDictionary()
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            entryID: payload.optionalString("entryID"),
            fileName: payload.string("fileName"),
            mediaType: payload.string("mediaType"),
            originalSize: payload.int64("originalSize"),
            storedSize: payload.int64("storedSize"),
            contentHash: payload.string("contentHash"),
            storageMode: payload.string("storageMode"),
            source: payload.string("source"),
            downloadState: payload.string("downloadState"),
            wrappedContentEncryptionKey: payload.optionalString("wrappedContentEncryptionKey"),
            localPath: payload.optionalString("localPath"),
            deleted: deleted,
            metadata: VaultEntryMetadata(entry.metadata)
        )
    }
}

extension MonicaMDBXParityEntry {
    func payloadDictionary() throws -> [String: Any] {
        guard let data = payloadJSON.data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        return payload
    }
}

/// 跨条目引用（卡片/地址 ID）在 CSV 与备份里用分号连接成字符串，避免依赖数组解析。
func joinedVaultReferenceIdentifiers(_ identifiers: [String]) -> String {
    identifiers
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { $0.isEmpty == false }
        .joined(separator: ";")
}

func splitVaultReferenceIdentifiers(_ value: String) -> [String] {
    value
        .split(separator: ";")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { $0.isEmpty == false }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String {
        self[key] as? String ?? ""
    }

    func optionalString(_ key: String) -> String? {
        self[key] as? String
    }

    func bool(_ key: String) -> Bool {
        self[key] as? Bool ?? false
    }

    func int(_ key: String) -> Int {
        if let value = self[key] as? Int {
            return value
        }
        if let value = self[key] as? NSNumber {
            return value.intValue
        }
        return 0
    }

    func stringArray(_ key: String) -> [String] {
        if let values = self[key] as? [Any] {
            return values.compactMap { $0 as? String }.filter { $0.isEmpty == false }
        }
        if let joined = self[key] as? String {
            return splitVaultReferenceIdentifiers(joined)
        }
        return []
    }

    func int64(_ key: String) -> Int64 {
        if let value = self[key] as? Int64 {
            return value
        }
        if let value = self[key] as? Int {
            return Int64(value)
        }
        if let value = self[key] as? NSNumber {
            return value.int64Value
        }
        return 0
    }
}

private extension LocalSteamEntry {
    init(_ entry: MonicaMDBXParityEntry) throws {
        let payload = try entry.payloadDictionary()
        let decoded = SteamEntryPayloadCodec.decoded(
            payload,
            entryID: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            favorite: entry.favorite,
            metadata: VaultEntryMetadata(entry.metadata)
        )
        self = decoded
    }
}
