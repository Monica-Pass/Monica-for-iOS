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

public enum VaultCSVItemDraft: Sendable, Equatable {
    case login(LocalLoginEntryDraft)
    case note(LocalNoteEntryDraft)
    case totp(LocalTotpEntryDraft)
    case card(LocalCardEntryDraft)
    case identity(LocalIdentityEntryDraft)
    case passkey(LocalPasskeyEntryDraft)
    case sshKey(LocalSshKeyEntryDraft)
    case apiToken(LocalApiTokenEntryDraft)
    case wifi(LocalWifiEntryDraft)
    case sso(LocalSSOEntryDraft)
    case send(LocalSendEntryDraft)
    case steam(LocalSteamEntryDraft)
    case barcode(LocalBarcodeEntryDraft)
    case billingAddress(LocalBillingAddressEntryDraft)
    case paymentAccount(LocalPaymentAccountEntryDraft)

    public var kind: UnifiedVaultItemKind {
        switch self {
        case .login: return .login
        case .note: return .note
        case .totp: return .totp
        case .card: return .card
        case .identity: return .identity
        case .passkey: return .passkey
        case .sshKey: return .sshKey
        case .apiToken: return .apiToken
        case .wifi: return .wifi
        case .sso: return .sso
        case .send: return .send
        case .steam: return .steam
        case .barcode: return .barcode
        case .billingAddress: return .billingAddress
        case .paymentAccount: return .paymentAccount
        }
    }

    /// 备份导出时随条目一起写入的标签与归档状态。
    public var metadata: VaultEntryMetadata {
        switch self {
        case .login(let draft): return draft.metadata
        case .note(let draft): return draft.metadata
        case .totp(let draft): return draft.metadata
        case .card(let draft): return draft.metadata
        case .identity(let draft): return draft.metadata
        case .passkey(let draft): return draft.metadata
        case .sshKey(let draft): return draft.metadata
        case .apiToken(let draft): return draft.metadata
        case .wifi(let draft): return draft.metadata
        case .sso(let draft): return draft.metadata
        case .send(let draft): return draft.metadata
        case .steam(let draft): return draft.metadata
        case .barcode(let draft): return draft.metadata
        case .billingAddress(let draft): return draft.metadata
        case .paymentAccount(let draft): return draft.metadata
        }
    }
}

public struct AndroidBackupImportedItem: Sendable, Equatable {
    public let sourceID: Int64?
    public let deletedAt: Int64?
    public let draft: VaultCSVItemDraft
    /// 备份中携带的标签与归档状态；旧备份没有这些字段时为 `.empty`。
    public let metadata: VaultEntryMetadata

    public init(
        sourceID: Int64?,
        deletedAt: Int64? = nil,
        draft: VaultCSVItemDraft,
        metadata: VaultEntryMetadata = .empty
    ) {
        self.sourceID = sourceID
        self.deletedAt = deletedAt
        self.draft = draft
        self.metadata = metadata
    }
}

public enum VaultCSVImportIssueCode: Sendable, Equatable {
    case emptyCSV
    case missingKindColumn
    case unsupportedKind
    case missingRequiredField
    case invalidNumber
    case invalidBoolean
    case malformedCSV
    case invalidFieldFormat
}

public struct VaultCSVImportIssue: Sendable, Equatable {
    public let row: Int
    public let code: VaultCSVImportIssueCode
    public let field: String?
    public let message: String

    public init(row: Int, code: VaultCSVImportIssueCode, field: String?, message: String) {
        self.row = row
        self.code = code
        self.field = field
        self.message = message
    }
}

public struct VaultCSVImportReport: Sendable, Equatable {
    public let items: [VaultCSVItemDraft]
    public let issues: [VaultCSVImportIssue]

    public init(items: [VaultCSVItemDraft], issues: [VaultCSVImportIssue]) {
        self.items = items
        self.issues = issues
    }
}

public enum AndroidBackupIssueCode: Sendable, Equatable {
    case malformedZip
    case encryptedBackupUnsupported
    case encryptedBackupDecryptionFailed
    case unsafeEntryPath
    case unsupportedEntry
    case malformedJSON
}

public struct AndroidBackupImportIssue: Sendable, Equatable {
    public let entryPath: String
    public let code: AndroidBackupIssueCode
    public let message: String

    public init(entryPath: String, code: AndroidBackupIssueCode, message: String) {
        self.entryPath = entryPath
        self.code = code
        self.message = message
    }
}

public struct AndroidBackupAttachmentMetadata: Sendable, Equatable, Identifiable {
    public let id: String
    public let parentPasswordID: Int64
    public let fileName: String
    public let mediaType: String
    public let originalSize: Int64
    public let contentHash: String
    public let wrappedContentEncryptionKey: String
    public let localPath: String
    public let blobEntryPath: String?
    public let encryptedBlob: Data?
    public let createdAt: Int64
    public let updatedAt: Int64

    public init(
        id: String,
        parentPasswordID: Int64,
        fileName: String,
        mediaType: String,
        originalSize: Int64,
        contentHash: String,
        wrappedContentEncryptionKey: String,
        localPath: String,
        blobEntryPath: String?,
        encryptedBlob: Data? = nil,
        createdAt: Int64,
        updatedAt: Int64
    ) {
        self.id = id
        self.parentPasswordID = parentPasswordID
        self.fileName = fileName
        self.mediaType = mediaType
        self.originalSize = originalSize
        self.contentHash = contentHash
        self.wrappedContentEncryptionKey = wrappedContentEncryptionKey
        self.localPath = localPath
        self.blobEntryPath = blobEntryPath
        self.encryptedBlob = encryptedBlob
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct AndroidBackupImportReport: Sendable, Equatable {
    public let items: [VaultCSVItemDraft]
    public let importedItems: [AndroidBackupImportedItem]
    public let deletedItems: [AndroidBackupImportedItem]
    public let attachments: [AndroidBackupAttachmentMetadata]
    public let issues: [AndroidBackupImportIssue]

    public init(
        items: [VaultCSVItemDraft],
        importedItems: [AndroidBackupImportedItem]? = nil,
        deletedItems: [AndroidBackupImportedItem] = [],
        attachments: [AndroidBackupAttachmentMetadata] = [],
        issues: [AndroidBackupImportIssue]
    ) {
        self.items = items
        self.importedItems = importedItems ?? items.map { AndroidBackupImportedItem(sourceID: nil, draft: $0) }
        self.deletedItems = deletedItems
        self.attachments = attachments
        self.issues = issues
    }
}

public enum AndroidBackupCodec {
    private static let encryptedBackupMagic = Data("MONICA_ENC_V1".utf8)
    private static let encryptedBackupSaltLength = 32
    private static let encryptedBackupIVLength = 12
    private static let encryptedBackupPBKDF2Iterations = 100_000
    private static let encryptedBackupKeyLength = 32
    private static let aesGCMTagLength = 16
    public static let encryptedBackupUnsupportedMessage = "移动端加密备份暂未支持解密，请先导出未加密 .zip 后再导入。"
    public static let encryptedBackupDecryptionFailedMessage = "移动端加密备份解密失败，请检查密码或文件是否损坏。"

    public static func importItems(
        from zipData: Data,
        fileName: String? = nil,
        decryptPassword: String? = nil
    ) throws -> AndroidBackupImportReport {
        if isEncryptedBackup(zipData, fileName: fileName) {
            guard let decryptPassword, !decryptPassword.isEmpty else {
                return AndroidBackupImportReport(
                    items: [],
                    issues: [
                        AndroidBackupImportIssue(
                            entryPath: fileName ?? "backup",
                            code: .encryptedBackupUnsupported,
                            message: encryptedBackupUnsupportedMessage
                        )
                    ]
                )
            }

            do {
                let decryptedZip = try decryptAndroidEncryptedBackup(zipData, password: decryptPassword)
                return try importItems(from: decryptedZip)
            } catch {
                return AndroidBackupImportReport(
                    items: [],
                    issues: [
                        AndroidBackupImportIssue(
                            entryPath: fileName ?? "backup",
                            code: .encryptedBackupDecryptionFailed,
                            message: encryptedBackupDecryptionFailedMessage
                        )
                    ]
                )
            }
        }

        let archive = try Archive(data: zipData, accessMode: .read)
        return try importItems(from: archive)
    }

    private static func importItems(from archive: Archive) throws -> AndroidBackupImportReport {
        var orderedItems: [(order: Int, index: Int, importedItem: AndroidBackupImportedItem)] = []
        var issues: [AndroidBackupImportIssue] = []
        var legacyCSVFiles: [(path: String, data: Data, index: Int)] = []
        var jsonBackedKinds = Set<BackupKind>()
        var attachmentManifest: (path: String, data: Data)?
        var attachmentBlobDataByPath: [String: Data] = [:]
        var deletedItems: [AndroidBackupImportedItem] = []
        var index = 0

        for entry in archive where entry.type == .file {
            let path = normalizedPath(entry.path)
            guard isSafeEntryPath(path) else {
                issues.append(issue(entryPath: entry.path, code: .unsafeEntryPath, detail: "ZIP 条目路径不安全"))
                continue
            }
            if isAttachmentBlob(path) {
                var data = Data()
                _ = try archive.extract(entry) { chunk in
                    data.append(chunk)
                }
                attachmentBlobDataByPath[path] = data
                index += 1
                continue
            }
            guard path.hasSuffix(".json") || path.hasSuffix(".csv") else {
                continue
            }

            var data = Data()
            _ = try archive.extract(entry) { chunk in
                data.append(chunk)
            }

            if isAttachmentManifest(path) {
                attachmentManifest = (path: path, data: data)
                index += 1
                continue
            }

            if path.lowercased() == "trash/trash_passwords.json" {
                deletedItems.append(contentsOf: parseTrashPasswords(data: data, path: path, issues: &issues))
                index += 1
                continue
            }

            if path.lowercased() == "trash/trash_secure_items.json" {
                deletedItems.append(contentsOf: parseTrashSecureItems(data: data, path: path, issues: &issues))
                index += 1
                continue
            }

            if path.hasSuffix(".csv") {
                legacyCSVFiles.append((path: path, data: data, index: index))
                index += 1
                continue
            }

            guard let kind = kind(for: path) else {
                continue
            }
            guard let importedItem = parseItem(kind: kind, data: data, path: path, issues: &issues) else {
                continue
            }
            jsonBackedKinds.insert(kind)
            orderedItems.append((order: order(for: path, kind: kind), index: index, importedItem: importedItem))
            index += 1
        }

        for csvFile in legacyCSVFiles {
            let parsedItems = parseLegacyCSVItems(
                path: csvFile.path,
                data: csvFile.data,
                jsonBackedKinds: jsonBackedKinds,
                issues: &issues
            )
            for item in parsedItems {
                let kind = backupKind(for: item)
                orderedItems.append(
                    (
                        order: kindPriority(kind),
                        index: index,
                        importedItem: AndroidBackupImportedItem(sourceID: nil, draft: item)
                    )
                )
                index += 1
            }
        }

        let importedItems = orderedItems
            .sorted { lhs, rhs in
                if lhs.order == rhs.order {
                    return lhs.index < rhs.index
                }
                return lhs.order < rhs.order
            }
            .map(\.importedItem)
        let items = importedItems.map(\.draft)
        let attachments = parseAttachmentManifest(
            attachmentManifest,
            blobDataByPath: attachmentBlobDataByPath,
            issues: &issues
        )
        return AndroidBackupImportReport(
            items: items,
            importedItems: importedItems,
            deletedItems: deletedItems,
            attachments: attachments,
            issues: issues
        )
    }

    private static func decryptAndroidEncryptedBackup(_ data: Data, password: String) throws -> Data {
        let headerLength = encryptedBackupMagic.count
        let minimumLength = headerLength
            + encryptedBackupSaltLength
            + encryptedBackupIVLength
            + aesGCMTagLength
        guard data.count >= minimumLength, data.starts(with: encryptedBackupMagic) else {
            throw AndroidBackupEncryptedArchiveError.invalidFormat
        }

        var offset = headerLength
        let salt = Data(data[offset..<offset + encryptedBackupSaltLength])
        offset += encryptedBackupSaltLength
        let nonceData = Data(data[offset..<offset + encryptedBackupIVLength])
        offset += encryptedBackupIVLength
        let encryptedPayload = Data(data[offset...])
        guard encryptedPayload.count >= aesGCMTagLength else {
            throw AndroidBackupEncryptedArchiveError.invalidFormat
        }

        let keyData = try pbkdf2SHA256(
            password: Data(password.utf8),
            salt: salt,
            iterations: encryptedBackupPBKDF2Iterations,
            keyLength: encryptedBackupKeyLength
        )
        let ciphertext = encryptedPayload.prefix(encryptedPayload.count - aesGCMTagLength)
        let tag = encryptedPayload.suffix(aesGCMTagLength)
        let sealedBox = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonceData),
            ciphertext: Data(ciphertext),
            tag: Data(tag)
        )
        return try AES.GCM.open(sealedBox, using: SymmetricKey(data: keyData))
    }

    private static func pbkdf2SHA256(
        password: Data,
        salt: Data,
        iterations: Int,
        keyLength: Int
    ) throws -> Data {
        guard iterations > 0, keyLength > 0 else {
            throw AndroidBackupEncryptedArchiveError.invalidFormat
        }

        let passwordKey = SymmetricKey(data: password)
        let hmacLength = SHA256.byteCount
        let blockCount = Int(ceil(Double(keyLength) / Double(hmacLength)))
        var derivedKey = Data()

        for blockIndex in 1...blockCount {
            var blockInput = salt
            blockInput.append(UInt8((blockIndex >> 24) & 0xff))
            blockInput.append(UInt8((blockIndex >> 16) & 0xff))
            blockInput.append(UInt8((blockIndex >> 8) & 0xff))
            blockInput.append(UInt8(blockIndex & 0xff))

            var u = Data(HMAC<SHA256>.authenticationCode(for: blockInput, using: passwordKey))
            var t = u
            if iterations > 1 {
                for _ in 2...iterations {
                    u = Data(HMAC<SHA256>.authenticationCode(for: u, using: passwordKey))
                    for index in t.indices {
                        t[index] ^= u[index]
                    }
                }
            }
            derivedKey.append(t)
        }

        return derivedKey.prefix(keyLength)
    }

    private enum AndroidBackupEncryptedArchiveError: Error {
        case invalidFormat
    }

    /// 用与移动端加密备份相同的信封（`MONICA_ENC_V1` + PBKDF2-SHA256 10 万次 + AES-GCM）
    /// 保护导出文件；信封本身与 zip 无关，CSV/JSON 也能复用同一套参数。
    public static func encryptPayload(_ payload: Data, password: String) throws -> Data {
        guard !password.isEmpty else {
            throw AndroidBackupEncryptedArchiveError.invalidFormat
        }
        let salt = Data((0..<encryptedBackupSaltLength).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
        let iv = Data((0..<encryptedBackupIVLength).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
        let keyData = try pbkdf2SHA256(
            password: Data(password.utf8),
            salt: salt,
            iterations: encryptedBackupPBKDF2Iterations,
            keyLength: encryptedBackupKeyLength
        )
        let sealedBox = try AES.GCM.seal(
            payload,
            using: SymmetricKey(data: keyData),
            nonce: AES.GCM.Nonce(data: iv)
        )
        var output = encryptedBackupMagic
        output.append(salt)
        output.append(iv)
        output.append(sealedBox.ciphertext)
        output.append(sealedBox.tag)
        return output
    }

    public static func decryptPayload(_ data: Data, password: String) throws -> Data {
        try decryptAndroidEncryptedBackup(data, password: password)
    }

    public static func isEncryptedPayload(_ data: Data) -> Bool {
        data.starts(with: encryptedBackupMagic)
    }

    private static func isEncryptedBackup(_ data: Data, fileName: String?) -> Bool {
        if fileName?.lowercased().hasSuffix(".enc.zip") == true {
            return true
        }
        return data.starts(with: encryptedBackupMagic)
    }

    public static func exportItems(_ items: [VaultCSVItemDraft], folderName: String = "Imported") throws -> Data {
        var entries: [String: String] = [:]
        for (index, item) in items.enumerated() {
            let id = index + 1
            let timestamp = 1_797_000_000_000 + id
            let path = entryPath(for: item, folderName: folderName, id: id, timestamp: timestamp)
            entries[path] = try jsonString(for: item, id: id, timestamp: timestamp, folderName: folderName)
        }
        return try exportZip(entries: entries)
    }

    public static func exportZip(entries: [String: String]) throws -> Data {
        let archive = try Archive(data: Data(), accessMode: .create)
        for path in entries.keys.sorted() {
            guard let content = entries[path] else { continue }
            let data = Data(content.utf8)
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate
            ) { position, size in
                let start = Int(position)
                guard start < data.count else { return Data() }
                let end = min(start + size, data.count)
                return data.subdata(in: start..<end)
            }
        }
        return archive.data ?? Data()
    }

    public static func inspectEntryNames(in zipData: Data) throws -> [String] {
        let archive = try Archive(data: zipData, accessMode: .read)
        return archive.map(\.path)
    }

    private enum BackupKind: Hashable {
        case password
        case totp
        case note
        case card
        case identity
        case passkey
        case billingAddress
        case paymentAccount
    }

    private static func kind(for path: String) -> BackupKind? {
        switch true {
        case path.contains("/passwords/") || path.hasPrefix("passwords/"):
            return .password
        case path.contains("/authenticators/") || path.hasPrefix("authenticators/") || path.contains("/totp/") || path.hasPrefix("totp/"):
            return .totp
        case path.contains("/notes/") || path.hasPrefix("notes/"):
            return .note
        case path.contains("/bank_cards/") || path.hasPrefix("bank_cards/"):
            return .card
        case path.contains("/documents/") || path.hasPrefix("documents/"):
            return .identity
        case path.contains("/passkeys/") || path.hasPrefix("passkeys/"):
            return .passkey
        case path.contains("/billing_addresses/") || path.hasPrefix("billing_addresses/"):
            return .billingAddress
        case path.contains("/payment_accounts/") || path.hasPrefix("payment_accounts/"):
            return .paymentAccount
        default:
            return nil
        }
    }

    private enum LegacySecureCSVRole {
        case generic
        case notesOnly
        case totpOnly
        case cardsAndDocumentsOnly
    }

    private struct AttachmentManifest: Decodable {
        let version: Int
        let entries: [AttachmentEntry]
    }

    private struct AttachmentEntry: Decodable {
        let parentPasswordId: Int64
        let fileName: String
        let mimeType: String
        let sizeBytes: Int64
        let sha256Hex: String?
        let wrappedCek: String
        let localPath: String
        let createdAt: Int64
        let updatedAt: Int64
    }

    private static func order(for path: String, kind: BackupKind) -> Int {
        let fileName = path.split(separator: "/").last.map(String.init) ?? path
        if let firstNumber = fileName.split(whereSeparator: { !$0.isNumber }).compactMap({ Int($0) }).first {
            return firstNumber
        }
        return 1_000_000 + kindPriority(kind)
    }

    private static func kindPriority(_ kind: BackupKind) -> Int {
        switch kind {
        case .password: return 0
        case .totp: return 1
        case .note: return 2
        case .card: return 3
        case .identity: return 4
        case .passkey: return 5
        case .billingAddress: return 6
        case .paymentAccount: return 7
        }
    }

    private static func backupKind(for item: VaultCSVItemDraft) -> BackupKind {
        switch item {
        case .login, .sshKey, .apiToken, .wifi, .sso, .barcode:
            return .password
        case .totp, .steam:
            return .totp
        case .note, .send:
            return .note
        case .card:
            return .card
        case .identity:
            return .identity
        case .passkey:
            return .passkey
        case .billingAddress:
            return .billingAddress
        case .paymentAccount:
            return .paymentAccount
        }
    }

    private static func parseAttachmentManifest(
        _ manifest: (path: String, data: Data)?,
        blobDataByPath: [String: Data],
        issues: inout [AndroidBackupImportIssue]
    ) -> [AndroidBackupAttachmentMetadata] {
        guard let manifest else { return [] }
        do {
            let decoded = try JSONDecoder().decode(AttachmentManifest.self, from: manifest.data)
            guard decoded.version == 1 else {
                issues.append(issue(entryPath: manifest.path, code: .unsupportedEntry, detail: "不支持的附件清单版本"))
                return []
            }
            return decoded.entries.enumerated().map { offset, entry in
                let blob = attachmentBlob(for: entry.localPath, in: blobDataByPath)
                return AndroidBackupAttachmentMetadata(
                    id: "android-attachment-\(entry.parentPasswordId)-\(offset)",
                    parentPasswordID: entry.parentPasswordId,
                    fileName: entry.fileName,
                    mediaType: entry.mimeType,
                    originalSize: entry.sizeBytes,
                    contentHash: entry.sha256Hex ?? "",
                    wrappedContentEncryptionKey: entry.wrappedCek,
                    localPath: entry.localPath,
                    blobEntryPath: blob?.path,
                    encryptedBlob: blob?.data,
                    createdAt: entry.createdAt,
                    updatedAt: entry.updatedAt
                )
            }
        } catch {
            issues.append(issue(entryPath: manifest.path, code: .malformedJSON, detail: "移动端备份附件清单无法解析"))
            return []
        }
    }

    private static func isAttachmentManifest(_ path: String) -> Bool {
        path.lowercased() == "attachments/attachments_meta.json"
    }

    private static func isAttachmentBlob(_ path: String) -> Bool {
        let lowercased = path.lowercased()
        return lowercased.hasPrefix("attachments/")
            && lowercased != "attachments/attachments_meta.json"
            && !path.hasSuffix("/")
    }

    private static func attachmentBlob(for localPath: String, in blobDataByPath: [String: Data]) -> (path: String, data: Data)? {
        let fileName = localPath.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? localPath
        let expectedPath = "attachments/\(fileName)"
        if let data = blobDataByPath[expectedPath] {
            return (expectedPath, data)
        }
        guard let matchedPath = blobDataByPath.keys.first(where: { path in
            path.split(separator: "/").last.map(String.init) == fileName
        }) else {
            return nil
        }
        return (matchedPath, blobDataByPath[matchedPath] ?? Data())
    }

    private static func parseTrashPasswords(
        data: Data,
        path: String,
        issues: inout [AndroidBackupImportIssue]
    ) -> [AndroidBackupImportedItem] {
        do {
            return try JSONObject.array(data: data).map { object in
                AndroidBackupImportedItem(
                    sourceID: object.contains("id") ? Int64(object.int("id", defaultValue: 0)) : nil,
                    deletedAt: object.contains("deletedAt") ? Int64(object.int("deletedAt", defaultValue: 0)) : nil,
                    draft: object.string("loginType").trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "BARCODE"
                        ? barcodeDraft(from: object, payload: object.string("password"))
                        : .login(LocalLoginEntryDraft(
                            title: object.string("title"),
                            username: object.string("username"),
                            account: object.string("account"),
                            password: object.string("password"),
                            url: object.string("website"),
                            notes: object.string("notes")
                        ))
                )
            }
        } catch {
            issues.append(issue(entryPath: path, code: .malformedJSON, detail: "移动端备份回收站密码数据无法解析"))
            return []
        }
    }

    private static func parseTrashSecureItems(
        data: Data,
        path: String,
        issues: inout [AndroidBackupImportIssue]
    ) -> [AndroidBackupImportedItem] {
        do {
            return try JSONObject.array(data: data).compactMap { object in
                let itemData = object.string("itemData")
                let kind = trashSecureKind(from: object.string("itemType"), itemData: itemData)
                guard let kind,
                      let draft = parseLegacySecureItem(
                        kind: kind,
                        title: object.string("title"),
                        itemData: itemData,
                        notes: object.string("notes")
                      )
                else {
                    return nil
                }
                return AndroidBackupImportedItem(
                    sourceID: object.contains("id") ? Int64(object.int("id", defaultValue: 0)) : nil,
                    deletedAt: object.contains("deletedAt") ? Int64(object.int("deletedAt", defaultValue: 0)) : nil,
                    draft: draft
                )
            }
        } catch {
            issues.append(issue(entryPath: path, code: .malformedJSON, detail: "移动端备份回收站安全条目数据无法解析"))
            return []
        }
    }

    private static func trashSecureKind(from itemType: String, itemData: String) -> BackupKind? {
        switch itemType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "totp", "authenticator", "two_factor", "2fa":
            return .totp
        case "note", "secure_note", "secure-note":
            return .note
        case "bank_card", "bank-card", "card", "credit_card", "credit-card":
            return .card
        case "document", "identity", "id_card", "id-card":
            return .identity
        case "billing_address", "billing-address", "billingaddress":
            return .billingAddress
        case "payment_account", "payment-account", "paymentaccount":
            return .paymentAccount
        default:
            return inferSecureKind(from: itemData) ?? .note
        }
    }

    private static func parseLegacyCSVItems(
        path: String,
        data: Data,
        jsonBackedKinds: Set<BackupKind>,
        issues: inout [AndroidBackupImportIssue]
    ) -> [VaultCSVItemDraft] {
        guard let csv = String(data: data, encoding: .utf8) else {
            issues.append(issue(entryPath: path, code: .unsupportedEntry, detail: "旧版 CSV 不是 UTF-8 编码"))
            return []
        }
        do {
            let rows = try parseCSVRows(csv)
            guard let header = rows.first else { return [] }
            let normalizedHeader = header.map { normalizedCSVHeader($0) }
            if isLegacyPasswordCSV(path: path, header: normalizedHeader) {
                guard !jsonBackedKinds.contains(.password) else { return [] }
                return parseLegacyPasswordCSVRows(rows: rows, header: normalizedHeader)
            }
            guard let role = legacySecureCSVRole(path: path, header: normalizedHeader) else {
                return []
            }
            return parseLegacySecureCSVRows(rows: rows, role: role, jsonBackedKinds: jsonBackedKinds, path: path, issues: &issues)
        } catch {
            issues.append(issue(entryPath: path, code: .unsupportedEntry, detail: "旧版 CSV 格式无法解析"))
            return []
        }
    }

    private static func isLegacyPasswordCSV(path: String, header: [String]) -> Bool {
        let fileName = path.split(separator: "/").last.map(String.init) ?? path
        let lowerFileName = fileName.lowercased()
        let headerSet = Set(header)
        return lowerFileName == "passwords.csv"
            || lowerFileName.hasSuffix("_password.csv")
            || (headerSet.contains("name") && headerSet.contains("url") && headerSet.contains("username") && headerSet.contains("password"))
            || (headerSet.contains("title") && headerSet.contains("password"))
    }

    private static func legacySecureCSVRole(path: String, header: [String]) -> LegacySecureCSVRole? {
        let headerSet = Set(header)
        guard headerSet.contains("id"),
              headerSet.contains("type"),
              headerSet.contains("title"),
              headerSet.contains("data")
        else { return nil }

        let fileName = (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
        if fileName.hasSuffix("_notes.csv") {
            return .notesOnly
        }
        if fileName.hasSuffix("_totp.csv") {
            return .totpOnly
        }
        if fileName.hasSuffix("_cards_docs.csv") {
            return .cardsAndDocumentsOnly
        }
        return .generic
    }

    private static func parseLegacyPasswordCSVRows(rows: [[String]], header: [String]) -> [VaultCSVItemDraft] {
        let headerIndex = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($0.element, $0.offset) })
        return rows.dropFirst().compactMap { row in
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return nil
            }
            let title = csvValue("name", row: row, headerIndex: headerIndex, fallback: csvValue("title", row: row, headerIndex: headerIndex))
            let url = csvValue("url", row: row, headerIndex: headerIndex, fallback: csvValue("website", row: row, headerIndex: headerIndex))
            let username = csvValue("username", row: row, headerIndex: headerIndex, fallback: csvValue("user name", row: row, headerIndex: headerIndex))
            let password = csvValue("password", row: row, headerIndex: headerIndex)
            let notes = csvValue("notes", row: row, headerIndex: headerIndex, fallback: csvValue("note", row: row, headerIndex: headerIndex))

            guard !title.isEmpty || !url.isEmpty || !username.isEmpty else {
                return nil
            }

            return .login(LocalLoginEntryDraft(
                title: title.isEmpty ? url.isEmpty ? username : url : title,
                username: username,
                password: password,
                url: url,
                notes: notes
            ))
        }
    }

    private static func parseLegacySecureCSVRows(
        rows: [[String]],
        role: LegacySecureCSVRole,
        jsonBackedKinds: Set<BackupKind>,
        path: String,
        issues: inout [AndroidBackupImportIssue]
    ) -> [VaultCSVItemDraft] {
        guard let header = rows.first else { return [] }
        let headerIndex = Dictionary(uniqueKeysWithValues: header.map(normalizedCSVHeader).enumerated().map { ($0.element, $0.offset) })
        var items: [VaultCSVItemDraft] = []

        for (rowOffset, row) in rows.dropFirst().enumerated() {
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                continue
            }
            let rawType = csvValue("type", row: row, headerIndex: headerIndex)
            let title = csvValue("title", row: row, headerIndex: headerIndex)
            let itemData = csvValue("data", row: row, headerIndex: headerIndex)
            let notes = csvValue("notes", row: row, headerIndex: headerIndex)

            guard let kind = resolveLegacySecureKind(rawType: rawType, itemData: itemData, role: role) else {
                if role == .cardsAndDocumentsOnly {
                    issues.append(issue(entryPath: path, code: .unsupportedEntry, detail: "第 \(rowOffset + 2) 行无法识别为卡片或证件"))
                }
                continue
            }
            guard !jsonBackedKinds.contains(kind) else {
                continue
            }
            guard let item = parseLegacySecureItem(kind: kind, title: title, itemData: itemData, notes: notes) else {
                issues.append(issue(entryPath: path, code: .unsupportedEntry, detail: "第 \(rowOffset + 2) 行旧版安全项无法解析"))
                continue
            }
            items.append(item)
        }
        return items
    }

    private static func resolveLegacySecureKind(
        rawType: String,
        itemData: String,
        role: LegacySecureCSVRole
    ) -> BackupKind? {
        switch role {
        case .notesOnly:
            return .note
        case .totpOnly:
            return .totp
        case .cardsAndDocumentsOnly:
            guard let kind = backupKindAlias(rawType) ?? inferSecureKind(from: itemData),
                  kind == .card || kind == .identity
            else { return nil }
            return kind
        case .generic:
            return backupKindAlias(rawType) ?? inferSecureKind(from: itemData)
        }
    }

    private static func backupKindAlias(_ rawType: String) -> BackupKind? {
        let normalized = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "-", with: "_")
        switch normalized {
        case "TOTP", "AUTHENTICATOR", "AUTHENTICATORS", "验证器":
            return .totp
        case "BANK_CARD", "BANKCARD", "BANK_CARDS", "BANKCARDS", "CARD", "CARDS", "CREDIT_CARD", "DEBIT_CARD", "卡片", "银行卡":
            return .card
        case "DOCUMENT", "DOCUMENTS", "DOC", "DOCS", "IDENTITY", "ID_CARD", "IDCARD", "PASSPORT", "DRIVER_LICENSE", "证件", "身份":
            return .identity
        case "NOTE", "NOTES", "SECURE_NOTE", "笔记":
            return .note
        default:
            return nil
        }
    }

    private static func inferSecureKind(from itemData: String) -> BackupKind? {
        guard let object = try? JSONObject(jsonString: itemData) else {
            return nil
        }
        if object.contains("secret") || object.contains("otpType") || (object.contains("issuer") && object.contains("accountName")) {
            return .totp
        }
        if object.contains("cardNumber") || object.contains("cardholderName") || object.contains("cvv") || (object.contains("number") && object.contains("expMonth")) {
            return .card
        }
        if object.contains("documentNumber") || object.contains("documentType") || object.contains("passportNumber") || object.contains("licenseNumber") || object.contains("issuedBy") || object.contains("issuingAuthority") {
            return .identity
        }
        if object.contains("content") || object.contains("markdown") || object.contains("tags") {
            return .note
        }
        return nil
    }

    private static func parseLegacySecureItem(
        kind: BackupKind,
        title: String,
        itemData: String,
        notes: String
    ) -> VaultCSVItemDraft? {
        switch kind {
        case .totp:
            let object = (try? JSONObject(jsonString: itemData)) ?? JSONObject.empty()
            if let steamDraft = LocalSteamEntryDraft.steamDraft(
                title: title,
                issuer: object.string("issuer"),
                accountName: object.string("accountName"),
                itemData: object.dictionaryRepresentation
            ) {
                return .steam(steamDraft)
            }
            return .totp(LocalTotpEntryDraft(
                title: title,
                secret: object.string("secret"),
                issuer: object.string("issuer"),
                accountName: object.string("accountName"),
                period: UInt32(object.int("period", defaultValue: 30)),
                digits: UInt32(object.int("digits", defaultValue: 6)),
                algorithm: object.string("algorithm", defaultValue: "SHA1"),
                otpType: object.string("otpType", defaultValue: "TOTP"),
                counter: UInt64(object.int("counter", defaultValue: 0))
            ))
        case .note:
            return .note(LocalNoteEntryDraft(title: title, body: itemData.isEmpty ? notes : itemData))
        case .card:
            let object = (try? JSONObject(jsonString: itemData)) ?? JSONObject.empty()
            return .card(LocalCardEntryDraft(
                title: title,
                cardholderName: object.string("cardholderName"),
                number: object.string("cardNumber", defaultValue: object.string("number")),
                expiryMonth: object.string("expiryMonth", defaultValue: object.string("expMonth")),
                expiryYear: object.string("expiryYear", defaultValue: object.string("expYear")),
                cvv: object.string("cvv", defaultValue: object.string("code")),
                issuer: object.string("bankName"),
                network: object.string("brand"),
                iban: object.string("iban"),
                swiftCode: object.string("swiftCode"),
                billingAddress: object.string("billingAddress"),
                cardArtwork: object.string("cardArtwork"),
                notes: notes
            ))
        case .identity:
            let object = (try? JSONObject(jsonString: itemData)) ?? JSONObject.empty()
            return .identity(LocalIdentityEntryDraft(
                title: title,
                documentType: object.string("documentType"),
                fullName: object.string("fullName"),
                documentNumber: object.string("documentNumber", defaultValue: object.string("passportNumber", defaultValue: object.string("licenseNumber"))),
                issuer: object.string("issuedBy", defaultValue: object.string("issuingAuthority")),
                country: object.string("country", defaultValue: object.string("nationality")),
                issueDate: object.string("issuedDate", defaultValue: object.string("issueDate")),
                expiryDate: object.string("expiryDate"),
                notes: notes
            ))
        case .billingAddress:
            let object = (try? JSONObject(jsonString: itemData)) ?? JSONObject.empty()
            return .billingAddress(billingAddressDraft(title: title, itemData: object, notes: notes))
        case .paymentAccount:
            let object = (try? JSONObject(jsonString: itemData)) ?? JSONObject.empty()
            return .paymentAccount(paymentAccountDraft(title: title, itemData: object, notes: notes))
        case .password, .passkey:
            return nil
        }
    }

    private static func parseItem(
        kind: BackupKind,
        data: Data,
        path: String,
        issues: inout [AndroidBackupImportIssue]
    ) -> AndroidBackupImportedItem? {
        do {
            let object = try JSONObject(data: data)
            let sourceID = object.contains("id") ? Int64(object.int("id", defaultValue: 0)) : nil
            let draft: VaultCSVItemDraft
            switch kind {
            case .password:
                let loginType = object.string("loginType", defaultValue: "PASSWORD").uppercased()
                if loginType == "SSO" {
                    let metadata = (try? object.nestedObject("ssoMetadata")) ?? JSONObject.empty()
                    let storedProvider = object.string("ssoProvider")
                    let metadataProvider = metadata.string("provider")
                    let linkedID = metadata.string("linkedLoginEntryID")
                    draft = .sso(LocalSSOEntryDraft(
                        title: object.string("title"),
                        provider: metadataProvider.isEmpty
                            ? SSOProvider.fromAndroidName(storedProvider)
                            : SSOProvider.fromStoredValue(metadataProvider),
                        providerName: metadata.string("providerName"),
                        issuer: metadata.string("issuer"),
                        accountName: object.string("username"),
                        loginURL: object.string("website"),
                        linkedLoginEntryID: linkedID.isEmpty ? nil : linkedID,
                        notes: object.string("notes"),
                        secret: metadata.string("secret")
                    ))
                } else if loginType == "BARCODE" {
                    draft = barcodeDraft(from: object, payload: object.string("password"))
                } else {
                    draft = .login(LocalLoginEntryDraft(
                        title: object.string("title"),
                        username: object.string("username"),
                        account: object.string("account"),
                        password: object.string("password"),
                        url: object.string("website"),
                        notes: object.string("notes")
                    ))
                }
            case .totp:
                let itemData = try object.nestedObject("itemData")
                if let steamDraft = LocalSteamEntryDraft.steamDraft(
                    title: object.string("title"),
                    issuer: itemData.string("issuer"),
                    accountName: itemData.string("accountName"),
                    itemData: itemData.dictionaryRepresentation
                ) {
                    draft = .steam(steamDraft)
                    break
                }
                draft = .totp(LocalTotpEntryDraft(
                    title: object.string("title"),
                    secret: itemData.string("secret"),
                    issuer: itemData.string("issuer"),
                    accountName: itemData.string("accountName"),
                    period: UInt32(itemData.int("period", defaultValue: 30)),
                    digits: UInt32(itemData.int("digits", defaultValue: 6)),
                    algorithm: itemData.string("algorithm", defaultValue: "SHA1"),
                    otpType: itemData.string("otpType", defaultValue: "TOTP"),
                    counter: UInt64(itemData.int("counter", defaultValue: 0))
                ))
            case .note:
                draft = .note(LocalNoteEntryDraft(
                    title: object.string("title"),
                    body: object.string("itemData", defaultValue: object.string("notes"))
                ))
            case .card:
                let itemData = try object.nestedObject("itemData")
                draft = .card(LocalCardEntryDraft(
                    title: object.string("title"),
                    cardholderName: itemData.string("cardholderName"),
                    number: itemData.string("cardNumber", defaultValue: itemData.string("number")),
                    expiryMonth: itemData.string("expiryMonth", defaultValue: itemData.string("expMonth")),
                    expiryYear: itemData.string("expiryYear", defaultValue: itemData.string("expYear")),
                    cvv: itemData.string("cvv", defaultValue: itemData.string("code")),
                    issuer: itemData.string("bankName", defaultValue: object.string("issuer")),
                    network: itemData.string("brand"),
                    iban: itemData.string("iban"),
                    swiftCode: itemData.string("swiftCode"),
                    billingAddress: itemData.string("billingAddress"),
                    cardArtwork: itemData.string("cardArtwork"),
                    notes: object.string("notes")
                ))
            case .identity:
                let itemData = try object.nestedObject("itemData")
                draft = .identity(LocalIdentityEntryDraft(
                    title: object.string("title"),
                    documentType: itemData.string("documentType"),
                    fullName: itemData.string("fullName"),
                    documentNumber: itemData.string("documentNumber", defaultValue: itemData.string("passportNumber", defaultValue: itemData.string("licenseNumber"))),
                    issuer: itemData.string("issuedBy", defaultValue: itemData.string("issuingAuthority")),
                    country: itemData.string("country", defaultValue: itemData.string("nationality")),
                    issueDate: itemData.string("issuedDate", defaultValue: itemData.string("issueDate")),
                    expiryDate: itemData.string("expiryDate"),
                    notes: object.string("notes")
                ))
            case .passkey:
                draft = .passkey(LocalPasskeyEntryDraft(
                    title: object.string("rpName", defaultValue: object.string("rpId")),
                    relyingPartyID: object.string("rpId"),
                    username: object.string("userName", defaultValue: object.string("userDisplayName")),
                    userHandle: object.string("userId"),
                    credentialID: object.string("credentialId"),
                    publicKeyCOSE: object.string("publicKey"),
                    privateKeyReference: object.string("privateKeyAlias"),
                    notes: object.string("notes")
                ))
            case .billingAddress:
                let itemData = try object.nestedObject("itemData")
                draft = .billingAddress(billingAddressDraft(
                    title: object.string("title"),
                    itemData: itemData,
                    notes: object.string("notes")
                ))
            case .paymentAccount:
                let itemData = try object.nestedObject("itemData")
                draft = .paymentAccount(paymentAccountDraft(
                    title: object.string("title"),
                    itemData: itemData,
                    notes: object.string("notes")
                ))
            }
            return AndroidBackupImportedItem(
                sourceID: sourceID,
                draft: draft,
                metadata: metadata(from: object)
            )
        } catch {
            issues.append(issue(entryPath: path, code: .malformedJSON, detail: "移动端备份数据无法解析"))
            return nil
        }
    }

    /// 兼容读取备份里的标签与归档状态；旧备份没有这些字段时返回空元数据。
    private static func metadata(from object: JSONObject) -> VaultEntryMetadata {
        var tags: [VaultEntryTag] = []
        for rawTag in object.dictionaryArray("tags") {
            guard let name = rawTag["name"] as? String else { continue }
            let trimmed = try? VaultTagName.normalize(name)
            guard let normalizedName = trimmed else { continue }
            let id = (rawTag["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
            tags.append(VaultEntryTag(id: id, name: normalizedName))
        }
        if let deduplicated = try? LocalVaultEntryRepository.normalizedTagList(tags) {
            tags = deduplicated
        }
        return VaultEntryMetadata(
            isArchived: object.bool("isArchived", defaultValue: false),
            tags: tags
        )
    }

    private static func entryPath(for item: VaultCSVItemDraft, folderName: String, id: Int, timestamp: Int) -> String {
        let folder = safeFolderName(folderName)
        switch item {
        case .login:
            return "folders/\(folder)/passwords/password_\(id)_\(timestamp).json"
        case .totp, .steam:
            return "folders/\(folder)/authenticators/totp_\(id)_\(timestamp).json"
        case .note:
            return "folders/\(folder)/notes/note_\(id)_\(timestamp).json"
        case .card:
            return "folders/\(folder)/bank_cards/bank_card_\(id)_\(timestamp).json"
        case .identity:
            return "folders/\(folder)/documents/document_\(id)_\(timestamp).json"
        case .passkey(let draft):
            return "folders/\(folder)/passkeys/passkey_\(safeFileComponent(draft.credentialID.isEmpty ? String(id) : draft.credentialID)).json"
        case .sshKey:
            return "folders/\(folder)/passwords/password_\(id)_\(timestamp).json"
        case .apiToken:
            return "folders/\(folder)/passwords/password_\(id)_\(timestamp).json"
        case .wifi:
            return "folders/\(folder)/passwords/password_\(id)_\(timestamp).json"
        case .sso:
            return "folders/\(folder)/passwords/password_\(id)_\(timestamp).json"
        case .barcode:
            return "folders/\(folder)/passwords/password_\(id)_\(timestamp).json"
        case .send:
            return "folders/\(folder)/notes/note_\(id)_\(timestamp).json"
        case .billingAddress:
            return "folders/\(folder)/billing_addresses/billing_address_\(id)_\(timestamp).json"
        case .paymentAccount:
            return "folders/\(folder)/payment_accounts/payment_account_\(id)_\(timestamp).json"
        }
    }

    private static func jsonString(for item: VaultCSVItemDraft, id: Int, timestamp: Int, folderName: String) throws -> String {
        let object: [String: Any]
        switch item {
        case .login(let draft):
            object = passwordObject(id: id, timestamp: timestamp, folderName: folderName, title: draft.title, username: draft.username, account: draft.account, password: draft.password, website: draft.url)
        case .totp(let draft):
            object = [
                "id": id,
                "title": draft.title,
                "itemData": jsonStringObject([
                    "secret": draft.secret,
                    "issuer": draft.issuer,
                    "accountName": draft.accountName,
                    "period": Int(draft.period),
                    "digits": Int(draft.digits),
                    "algorithm": draft.algorithm,
                    "otpType": draft.otpType,
                    "counter": Int(draft.counter)
                ]),
                "notes": "",
                "isFavorite": false,
                "createdAt": timestamp,
                "updatedAt": timestamp,
                "categoryName": folderName
            ]
        case .steam(let draft):
            object = [
                "id": id,
                "title": draft.title,
                "itemData": jsonStringObject(LocalSteamEntryDraft.backupItemData(from: draft)),
                "notes": draft.notes,
                "isFavorite": false,
                "createdAt": timestamp,
                "updatedAt": timestamp,
                "categoryName": folderName
            ]
        case .note(let draft):
            object = secureItemObject(id: id, timestamp: timestamp, folderName: folderName, itemType: "NOTE", title: draft.title, itemData: draft.body, notes: "")
        case .card(let draft):
            object = secureItemObject(
                id: id,
                timestamp: timestamp,
                folderName: folderName,
                itemType: "BANK_CARD",
                title: draft.title,
                itemData: jsonStringObject([
                    "cardNumber": draft.number,
                    "cardholderName": draft.cardholderName,
                    "expiryMonth": draft.expiryMonth,
                    "expiryYear": draft.expiryYear,
                    "cvv": draft.cvv,
                    "bankName": draft.issuer,
                    "brand": draft.network,
                    "iban": draft.iban,
                    "swiftCode": draft.swiftCode,
                    "billingAddress": draft.billingAddress,
                    "cardArtwork": draft.cardArtwork
                ]),
                notes: draft.notes
            )
        case .identity(let draft):
            object = secureItemObject(
                id: id,
                timestamp: timestamp,
                folderName: folderName,
                itemType: "DOCUMENT",
                title: draft.title,
                itemData: jsonStringObject([
                    "documentType": draft.documentType,
                    "documentNumber": draft.documentNumber,
                    "fullName": draft.fullName,
                    "issuedDate": draft.issueDate,
                    "expiryDate": draft.expiryDate,
                    "issuedBy": draft.issuer,
                    "country": draft.country
                ]),
                notes: draft.notes
            )
        case .passkey(let draft):
            object = [
                "credentialId": draft.credentialID,
                "rpId": draft.relyingPartyID,
                "rpName": draft.title,
                "userId": draft.userHandle,
                "userName": draft.username,
                "userDisplayName": draft.username,
                "publicKeyAlgorithm": -7,
                "publicKey": draft.publicKeyCOSE,
                "privateKeyAlias": draft.privateKeyReference,
                "createdAt": timestamp,
                "lastUsedAt": timestamp,
                "useCount": 0,
                "isDiscoverable": true,
                "isUserVerificationRequired": true,
                "transports": "internal",
                "aaguid": "",
                "signCount": 0,
                "notes": draft.notes,
                "passkeyMode": "LEGACY",
                "categoryName": folderName
            ]
        case .sshKey(let draft):
            object = passwordObject(id: id, timestamp: timestamp, folderName: folderName, title: draft.title, username: draft.username, password: draft.privateKeyReference, website: draft.host, notes: draft.notes, sshKeyData: draft.publicKey)
        case .apiToken(let draft):
            object = passwordObject(id: id, timestamp: timestamp, folderName: folderName, title: draft.title, username: draft.accountName, password: draft.token, website: draft.issuer, notes: draft.notes, loginType: "API_TOKEN")
        case .wifi(let draft):
            object = passwordObject(id: id, timestamp: timestamp, folderName: folderName, title: draft.title, username: draft.ssid, password: draft.password, website: "", notes: draft.notes, loginType: "WIFI", wifiMetadata: jsonStringObject(["ssid": draft.ssid, "securityType": draft.securityType, "hidden": draft.hidden]))
        case .sso(let draft):
            // Android 把 SSO 建模为登录条目子类型：loginType=SSO + ssoProvider。
            // iOS 额外字段（自定义 IdP 名称、issuer、关联条目、可选凭据）放在 ssoMetadata，
            // Android 侧会忽略未知键，但 iOS 自己可以无损读回。
            object = passwordObject(
                id: id,
                timestamp: timestamp,
                folderName: folderName,
                title: draft.title,
                username: draft.accountName,
                password: "",
                website: draft.loginURL,
                notes: draft.notes,
                loginType: "SSO",
                ssoProvider: draft.provider.androidName,
                ssoMetadata: jsonStringObject([
                    "provider": draft.provider.rawValue,
                    "providerName": draft.providerName,
                    "issuer": draft.issuer,
                    "linkedLoginEntryID": draft.linkedLoginEntryID ?? "",
                    "secret": draft.secret
                ])
            )
        case .barcode(let draft):
            object = passwordObject(
                id: id,
                timestamp: timestamp,
                folderName: folderName,
                title: draft.title,
                username: "",
                password: draft.payload,
                website: "",
                notes: draft.notes,
                loginType: "BARCODE",
                barcodeMetadata: jsonStringObject(["symbology": draft.symbology.rawValue, "label": draft.label])
            )
        case .send(let draft):
            object = secureItemObject(id: id, timestamp: timestamp, folderName: folderName, itemType: "NOTE", title: draft.title, itemData: draft.body, notes: draft.notes)
        case .billingAddress(let draft):
            object = secureItemObject(
                id: id,
                timestamp: timestamp,
                folderName: folderName,
                itemType: "BILLING_ADDRESS",
                title: draft.title,
                itemData: jsonStringObject([
                    "schemaVersion": 1,
                    "fullName": draft.fullName,
                    "streetAddress": draft.streetAddress,
                    "apartment": draft.apartment,
                    "city": draft.city,
                    "stateProvince": draft.stateProvince,
                    "postalCode": draft.postalCode,
                    "country": draft.country,
                    "phone": draft.phone,
                    "linkedCardIDs": joinedVaultReferenceIdentifiers(draft.linkedCardIDs)
                ]),
                notes: draft.notes
            )
        case .paymentAccount(let draft):
            object = secureItemObject(
                id: id,
                timestamp: timestamp,
                folderName: folderName,
                itemType: "PAYMENT_ACCOUNT",
                title: draft.title,
                itemData: jsonStringObject([
                    "schemaVersion": 1,
                    "paymentType": draft.kind.androidName,
                    "provider": draft.provider,
                    "accountName": draft.accountName,
                    "accountHolderName": draft.accountHolderName,
                    "iban": draft.iban,
                    "swiftBic": draft.swiftBIC,
                    "routingNumber": draft.routingNumber,
                    "accountNumber": draft.accountNumber,
                    "maskedAccountNumber": BillingFieldValidator.maskedAccountNumber(draft.accountNumber),
                    "currency": draft.currency,
                    "linkedCardID": draft.linkedCardID,
                    "billingAddressID": draft.billingAddressID
                ]),
                notes: draft.notes
            )
        }
        var enriched = object
        if item.metadata.isArchived {
            enriched["isArchived"] = true
        }
        if !item.metadata.tags.isEmpty {
            enriched["tags"] = item.metadata.tags.map { ["id": $0.id, "name": $0.name] }
        }
        return jsonStringObject(enriched)
    }

    private static func billingAddressDraft(
        title: String,
        itemData: JSONObject,
        notes: String
    ) -> LocalBillingAddressEntryDraft {
        LocalBillingAddressEntryDraft(
            title: title,
            fullName: itemData.string("fullName"),
            streetAddress: itemData.string("streetAddress", defaultValue: itemData.string("addressLine1")),
            apartment: itemData.string("apartment", defaultValue: itemData.string("addressLine2", defaultValue: itemData.string("addressLine3"))),
            city: itemData.string("city"),
            stateProvince: itemData.string("stateProvince", defaultValue: itemData.string("state")),
            postalCode: itemData.string("postalCode", defaultValue: itemData.string("zip")),
            country: itemData.string("country"),
            phone: itemData.string("phone"),
            notes: notes.isEmpty ? itemData.string("notes") : notes,
            linkedCardIDs: splitVaultReferenceIdentifiers(itemData.string("linkedCardIDs"))
        )
    }

    private static func paymentAccountDraft(
        title: String,
        itemData: JSONObject,
        notes: String
    ) -> LocalPaymentAccountEntryDraft {
        let addressReference = itemData.string("billingAddressID")
        var resolvedNotes = notes.isEmpty ? itemData.string("notes") : notes
        if addressReference.isEmpty {
            // Android 侧账单地址内嵌在支付账户里：iOS 导入时没有独立地址条目可关联，
            // 把地址文本并进备注，避免备份恢复丢字段。
            let embedded = embeddedBillingAddressText(itemData.string("billingAddress"))
            if embedded.isEmpty == false {
                resolvedNotes = resolvedNotes.isEmpty ? embedded : resolvedNotes + "\n" + embedded
            }
        }
        return LocalPaymentAccountEntryDraft(
            title: title,
            kind: LocalPaymentAccountKind(androidName: itemData.string("paymentType")),
            provider: itemData.string("provider"),
            accountName: itemData.string("accountName", defaultValue: itemData.string("username")),
            accountHolderName: itemData.string("accountHolderName"),
            iban: itemData.string("iban"),
            swiftBIC: itemData.string("swiftBic", defaultValue: itemData.string("swift")),
            routingNumber: itemData.string("routingNumber"),
            accountNumber: itemData.string("accountNumber", defaultValue: itemData.string("maskedAccountNumber")),
            currency: itemData.string("currency"),
            notes: resolvedNotes,
            linkedCardID: itemData.string("linkedCardID"),
            billingAddressID: addressReference
        )
    }

    private static func embeddedBillingAddressText(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, let object = try? JSONObject(jsonString: trimmed) else {
            return ""
        }
        var lines = BillingAddressLines.lines(
            streetAddress: object.string("streetAddress"),
            apartment: object.string("apartment"),
            city: object.string("city"),
            stateProvince: object.string("stateProvince"),
            postalCode: object.string("postalCode"),
            country: object.string("country")
        )
        let recipient = [object.string("fullName"), object.string("company")]
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
        if recipient.isEmpty == false {
            lines.insert(recipient, at: 0)
        }
        return lines.joined(separator: "\n")
    }

    private static func passwordObject(
        id: Int,
        timestamp: Int,
        folderName: String,
        title: String,
        username: String,
        account: String = "",
        password: String,
        website: String,
        notes: String = "",
        loginType: String = "PASSWORD",
        sshKeyData: String = "",
        wifiMetadata: String = "",
        ssoProvider: String = "",
        ssoMetadata: String = "",
        barcodeMetadata: String = ""
    ) -> [String: Any] {
        var object: [String: Any] = [
            "id": id,
            "title": title,
            "username": username,
            "password": password,
            "website": website,
            "notes": notes,
            "isFavorite": false,
            "categoryName": folderName,
            "createdAt": timestamp,
            "updatedAt": timestamp,
            "authenticatorKey": "",
            "passkeyBindings": "",
            "sshKeyData": sshKeyData,
            "loginType": loginType,
            "wifiMetadata": wifiMetadata,
            "ssoProvider": ssoProvider,
            "ssoMetadata": ssoMetadata,
            "barcodeMetadata": barcodeMetadata,
            "customFields": []
        ]
        // issue #151：账号为可选字段；为空时不写键，旧版 Android 备份读取方不受影响。
        if !account.isEmpty {
            object["account"] = account
        }
        return object
    }

    /// 条码在 Android 备份中复用密码对象：`loginType == "BARCODE"`，原文放在
    /// `password` 字段，制式与展示标签放在 `barcodeMetadata`（JSON 字符串）。
    /// 缺少元数据时按 QR 回读，保证 Android 端导出的条码仍可导入。
    private static func barcodeDraft(from object: JSONObject, payload: String) -> VaultCSVItemDraft {
        let metadataData = Data(object.string("barcodeMetadata").utf8)
        let metadata = (try? JSONSerialization.jsonObject(with: metadataData)) as? [String: Any] ?? [:]
        let symbology = (metadata["symbology"] as? String)
            .flatMap(BarcodeSymbology.init(rawValue:)) ?? .qr
        let label = metadata["label"] as? String ?? ""
        return .barcode(LocalBarcodeEntryDraft(
            title: object.string("title"),
            symbology: symbology,
            payload: payload,
            label: label,
            notes: object.string("notes")
        ))
    }

    private static func secureItemObject(
        id: Int,
        timestamp: Int,
        folderName: String,
        itemType: String,
        title: String,
        itemData: String,
        notes: String
    ) -> [String: Any] {
        [
            "id": id,
            "itemType": itemType,
            "title": title,
            "itemData": itemData,
            "notes": notes,
            "isFavorite": false,
            "imagePaths": "",
            "createdAt": timestamp,
            "updatedAt": timestamp,
            "categoryName": folderName
        ]
    }

    private static func jsonStringObject(_ object: [String: Any]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func parseCSVRows(_ csv: String) throws -> [[String]] {
        let input = csv.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return [] }
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isQuoted = false
        var index = input.startIndex

        while index < input.endIndex {
            let character = input[index]
            if isQuoted {
                if character == "\"" {
                    let next = input.index(after: index)
                    if next < input.endIndex, input[next] == "\"" {
                        field.append("\"")
                        index = input.index(after: next)
                    } else {
                        isQuoted = false
                        index = next
                    }
                } else {
                    field.append(character)
                    index = input.index(after: index)
                }
            } else {
                switch character {
                case "\"":
                    isQuoted = true
                    index = input.index(after: index)
                case ",":
                    row.append(normalizedCSVField(field))
                    field = ""
                    index = input.index(after: index)
                case "\n":
                    row.append(normalizedCSVField(field))
                    rows.append(row)
                    row = []
                    field = ""
                    index = input.index(after: index)
                case "\r":
                    index = input.index(after: index)
                default:
                    field.append(character)
                    index = input.index(after: index)
                }
            }
        }
        if isQuoted {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        row.append(normalizedCSVField(field))
        rows.append(row)
        return rows
    }

    private static func normalizedCSVField(_ field: String) -> String {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("\u{FEFF}") ? String(trimmed.dropFirst()) : trimmed
    }

    private static func normalizedCSVHeader(_ field: String) -> String {
        normalizedCSVField(field).lowercased()
    }

    private static func csvValue(_ field: String, row: [String], headerIndex: [String: Int], fallback: String = "") -> String {
        guard let index = headerIndex[field], index < row.count else {
            return fallback
        }
        let value = row[index]
        return value.isEmpty ? fallback : value
    }

    private static func normalizedPath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
    }

    private static func isSafeEntryPath(_ path: String) -> Bool {
        !path.split(separator: "/").contains("..") && !path.hasPrefix("/")
    }

    private static func safeFolderName(_ value: String) -> String {
        safeFileComponent(value.isEmpty ? "Imported" : value)
    }

    private static func safeFileComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ ."))
        return String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    private static func issue(entryPath: String, code: AndroidBackupIssueCode, detail: String) -> AndroidBackupImportIssue {
        AndroidBackupImportIssue(entryPath: entryPath, code: code, message: "\(entryPath)：\(detail)")
    }
}

private struct JSONObject {
    private let values: [String: Any]
    static func empty() -> JSONObject {
        JSONObject(values: [:])
    }

    init(data: Data) throws {
        let decoded = try JSONSerialization.jsonObject(with: data)
        guard let values = decoded as? [String: Any] else {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        self.values = values
    }

    init(jsonString: String) throws {
        try self.init(data: Data(jsonString.utf8))
    }

    static func array(data: Data) throws -> [JSONObject] {
        let decoded = try JSONSerialization.jsonObject(with: data)
        guard let values = decoded as? [[String: Any]] else {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        return values.map { JSONObject(values: $0) }
    }

    func string(_ key: String, defaultValue: String = "") -> String {
        switch values[key] {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        default:
            return defaultValue
        }
    }

    func int(_ key: String, defaultValue: Int) -> Int {
        switch values[key] {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value) ?? defaultValue
        default:
            return defaultValue
        }
    }

    func contains(_ key: String) -> Bool {
        values[key] != nil
    }

    func bool(_ key: String, defaultValue: Bool = false) -> Bool {
        switch values[key] {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        case let value as String:
            return ["true", "1", "yes"].contains(value.lowercased())
        default:
            return defaultValue
        }
    }

    func dictionaryArray(_ key: String) -> [[String: Any]] {
        values[key] as? [[String: Any]] ?? []
    }

    func nestedObject(_ key: String) throws -> JSONObject {
        switch values[key] {
        case let value as [String: Any]:
            return JSONObject(values: value)
        case let value as String:
            return try JSONObject(jsonString: value)
        default:
            return JSONObject(values: [:])
        }
    }

    var dictionaryRepresentation: [String: Any] { values }

    private init(values: [String: Any]) {
        self.values = values
    }
}

public enum VaultCSVCodec {
    public static let columns: [String] = [
        "kind",
        "title",
        "username",
        "password",
        "url",
        "body",
        "secret",
        "issuer",
        "accountName",
        "period",
        "digits",
        "algorithm",
        "otpType",
        "counter",
        "cardholderName",
        "number",
        "expiryMonth",
        "expiryYear",
        "cvv",
        "network",
        "iban",
        "swiftCode",
        "billingAddress",
        "cardArtwork",
        "documentType",
        "fullName",
        "documentNumber",
        "country",
        "issueDate",
        "expiryDate",
        "relyingPartyID",
        "userHandle",
        "credentialID",
        "publicKeyCOSE",
        "privateKeyReference",
        "host",
        "publicKey",
        "passphraseHint",
        "token",
        "scopes",
        "expiresAt",
        "ssid",
        "securityType",
        "hidden",
        "maxViews",
        "ssoProvider",
        "ssoProviderName",
        "linkedLoginEntryID",
        "streetAddress",
        "apartment",
        "city",
        "stateProvince",
        "postalCode",
        "phone",
        "linkedCardIDs",
        "paymentType",
        "provider",
        "accountHolderName",
        "swiftBic",
        "routingNumber",
        "accountNumber",
        "currency",
        "linkedCardID",
        "billingAddressID",
        "notes",
        // 追加列：旧 CSV 没有这些列时按空值回落，保证旧文件仍可导入。
        "urls",
        "customFields",
        "payload",
        "symbology",
        "label",
        // issue #151：登录账号（邮箱 / 手机号 / 账号 ID），追加在末尾，不打乱既有列顺序。
        "account"
    ]

    public static let headerLine = columns.joined(separator: ",")

    public static func importItems(from csv: String) -> VaultCSVImportReport {
        do {
            let rows = try parseRows(csv)
            guard let header = rows.first else {
                return VaultCSVImportReport(
                    items: [],
                    issues: [issue(row: 1, code: .emptyCSV, field: nil, detail: "CSV 文件为空")]
                )
            }
            let headerIndex = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($0.element, $0.offset) })
            guard headerIndex["kind"] != nil else {
                return VaultCSVImportReport(
                    items: [],
                    issues: [issue(row: 1, code: .missingKindColumn, field: "kind", detail: "CSV 缺少 kind 列")]
                )
            }

            var items: [VaultCSVItemDraft] = []
            var issues: [VaultCSVImportIssue] = []
            for (offset, row) in rows.dropFirst().enumerated() {
                let rowNumber = offset + 2
                if row.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    continue
                }
                var record = CSVRecord(row: row, headerIndex: headerIndex)
                if let item = parseItem(record: &record, rowNumber: rowNumber, issues: &issues) {
                    items.append(item)
                }
            }
            return VaultCSVImportReport(items: items, issues: issues)
        } catch {
            return VaultCSVImportReport(
                items: [],
                issues: [issue(row: 1, code: .malformedCSV, field: nil, detail: "CSV 格式无法解析")]
            )
        }
    }

    public static func exportItems(_ items: [VaultCSVItemDraft]) -> String {
        let rows = [columns] + items.map(row(for:))
        return rows.map { row in row.map(escape).joined(separator: ",") }.joined(separator: "\n")
    }

    /// 带自定义字段的 CSV 导出：列顺序与 `columns` 一致，旧读取端会忽略多出来的列。
    public static func exportTransferItems(_ items: [VaultTransferItem]) -> String {
        let rows = [columns] + items.map { item -> [String] in
            var values = rowValues(for: item.draft)
            if !item.customFields.isEmpty {
                values["customFields"] = VaultCustomFieldPayload.encode(item.customFields)
            }
            return columns.map { values[$0] ?? "" }
        }
        return rows.map { row in row.map(escape).joined(separator: ",") }.joined(separator: "\n")
    }

    static func parseItem(
        record: inout CSVRecord,
        rowNumber: Int,
        issues: inout [VaultCSVImportIssue]
    ) -> VaultCSVItemDraft? {
        let kindValue = record.value("kind")
        guard let kind = UnifiedVaultItemKind(rawValue: kindValue) else {
            issues.append(issue(row: rowNumber, code: .unsupportedKind, field: "kind", detail: "不支持的条目类型"))
            return nil
        }
        let title = record.value("title")
        guard !title.isEmpty else {
            issues.append(issue(row: rowNumber, code: .missingRequiredField, field: "title", detail: "缺少必填字段 title"))
            return nil
        }

        switch kind {
        case .login:
            return .login(LocalLoginEntryDraft(
                title: title,
                username: record.value("username"),
                // 旧 CSV 没有 account 列时按空字符串回落。
                account: record.value("account"),
                password: record.value("password"),
                url: record.value("url"),
                notes: record.value("notes"),
                urls: urlList(record.value("urls"))
            ))
        case .note:
            return .note(LocalNoteEntryDraft(title: title, body: record.value("body")))
        case .totp:
            guard let period = uint32(record.value("period"), defaultValue: 30, row: rowNumber, field: "period", issues: &issues),
                  let digits = uint32(record.value("digits"), defaultValue: 6, row: rowNumber, field: "digits", issues: &issues),
                  let counter = uint64(record.value("counter"), defaultValue: 0, row: rowNumber, field: "counter", issues: &issues)
            else { return nil }
            return .totp(LocalTotpEntryDraft(
                title: title,
                secret: record.value("secret"),
                issuer: record.value("issuer"),
                accountName: record.value("accountName"),
                period: period,
                digits: digits,
                algorithm: record.value("algorithm", fallback: "SHA1"),
                otpType: record.value("otpType", fallback: "totp"),
                counter: counter
            ))
        case .steam:
            return .steam(LocalSteamEntryDraft(
                title: title,
                accountName: record.value("accountName"),
                steamID: record.value("steamID"),
                sharedSecret: record.value("secret"),
                issuer: record.value("issuer", fallback: "Steam"),
                notes: record.value("notes")
            ))
        case .card:
            return .card(LocalCardEntryDraft(
                title: title,
                cardholderName: record.value("cardholderName"),
                number: record.value("number"),
                expiryMonth: record.value("expiryMonth"),
                expiryYear: record.value("expiryYear"),
                cvv: record.value("cvv"),
                issuer: record.value("issuer"),
                network: record.value("network"),
                iban: record.value("iban"),
                swiftCode: record.value("swiftCode"),
                billingAddress: record.value("billingAddress"),
                cardArtwork: record.value("cardArtwork"),
                notes: record.value("notes")
            ))
        case .identity:
            return .identity(LocalIdentityEntryDraft(
                title: title,
                documentType: record.value("documentType"),
                fullName: record.value("fullName"),
                documentNumber: record.value("documentNumber"),
                issuer: record.value("issuer"),
                country: record.value("country"),
                issueDate: record.value("issueDate"),
                expiryDate: record.value("expiryDate"),
                notes: record.value("notes")
            ))
        case .passkey:
            return .passkey(LocalPasskeyEntryDraft(
                title: title,
                relyingPartyID: record.value("relyingPartyID"),
                username: record.value("username"),
                userHandle: record.value("userHandle"),
                credentialID: record.value("credentialID"),
                publicKeyCOSE: record.value("publicKeyCOSE"),
                privateKeyReference: record.value("privateKeyReference"),
                notes: record.value("notes")
            ))
        case .sshKey:
            return .sshKey(LocalSshKeyEntryDraft(
                title: title,
                username: record.value("username"),
                host: record.value("host"),
                publicKey: record.value("publicKey"),
                privateKeyReference: record.value("privateKeyReference"),
                passphraseHint: record.value("passphraseHint"),
                notes: record.value("notes"),
                algorithm: record.value("algorithm"),
                keySize: Int(record.value("keySize")) ?? 0,
                fingerprint: record.value("fingerprint")
            ))
        case .apiToken:
            return .apiToken(LocalApiTokenEntryDraft(
                title: title,
                issuer: record.value("issuer"),
                accountName: record.value("accountName"),
                token: record.value("token"),
                scopes: record.value("scopes"),
                expiresAt: record.value("expiresAt"),
                notes: record.value("notes")
            ))
        case .wifi:
            guard let hidden = bool(record.value("hidden"), defaultValue: false, row: rowNumber, field: "hidden", issues: &issues) else {
                return nil
            }
            return .wifi(LocalWifiEntryDraft(
                title: title,
                ssid: record.value("ssid"),
                securityType: record.value("securityType"),
                password: record.value("password"),
                hidden: hidden,
                notes: record.value("notes")
            ))
        case .sso:
            let provider = SSOProvider.fromStoredValue(record.value("ssoProvider"))
            let linkedID = record.value("linkedLoginEntryID")
            let loginURL = record.value("url")
            if !loginURL.isEmpty, SSOEntryURLValidator.error(for: loginURL) != nil {
                issues.append(issue(row: rowNumber, code: .invalidNumber, field: "url", detail: "SSO 登录地址不是合法的 http/https 地址"))
                return nil
            }
            return .sso(LocalSSOEntryDraft(
                title: title,
                provider: provider,
                providerName: record.value("ssoProviderName"),
                issuer: record.value("issuer"),
                accountName: record.value("username"),
                loginURL: loginURL,
                linkedLoginEntryID: linkedID.isEmpty ? nil : linkedID,
                notes: record.value("notes"),
                secret: record.value("secret")
            ))
        case .barcode:
            let symbologyValue = record.value("symbology", fallback: BarcodeSymbology.qr.rawValue)
            guard let symbology = BarcodeSymbology(rawValue: symbologyValue) else {
                issues.append(issue(row: rowNumber, code: .unsupportedKind, field: "symbology", detail: "不支持的条码制式"))
                return nil
            }
            return .barcode(LocalBarcodeEntryDraft(
                title: title,
                symbology: symbology,
                payload: record.value("payload"),
                label: record.value("label"),
                notes: record.value("notes")
            ))
        case .send:
            guard let maxViews = int(record.value("maxViews"), defaultValue: 1, row: rowNumber, field: "maxViews", issues: &issues) else {
                return nil
            }
            return .send(LocalSendEntryDraft(
                title: title,
                body: record.value("body"),
                expiresAt: record.value("expiresAt"),
                maxViews: maxViews,
                notes: record.value("notes")
            ))
        case .billingAddress:
            let addressDraft = LocalBillingAddressEntryDraft(
                title: title,
                fullName: record.value("fullName"),
                streetAddress: record.value("streetAddress"),
                apartment: record.value("apartment"),
                city: record.value("city"),
                stateProvince: record.value("stateProvince"),
                postalCode: record.value("postalCode"),
                country: record.value("country"),
                phone: record.value("phone"),
                notes: record.value("notes"),
                linkedCardIDs: splitVaultReferenceIdentifiers(record.value("linkedCardIDs"))
            )
            if let field = formatIssueField(for: addressDraft) {
                issues.append(issue(row: rowNumber, code: .invalidFieldFormat, field: field, detail: "字段格式可能不正确（仅提示，不影响导入）"))
            }
            return .billingAddress(addressDraft)
        case .paymentAccount:
            let accountDraft = LocalPaymentAccountEntryDraft(
                title: title,
                kind: LocalPaymentAccountKind(androidName: record.value("paymentType")),
                provider: record.value("provider"),
                accountName: record.value("accountName"),
                accountHolderName: record.value("accountHolderName"),
                iban: record.value("iban"),
                swiftBIC: record.value("swiftBic"),
                routingNumber: record.value("routingNumber"),
                accountNumber: record.value("accountNumber"),
                currency: record.value("currency"),
                notes: record.value("notes"),
                linkedCardID: record.value("linkedCardID"),
                billingAddressID: record.value("billingAddressID")
            )
            if let field = formatIssueField(for: accountDraft) {
                issues.append(issue(row: rowNumber, code: .invalidFieldFormat, field: field, detail: "字段格式可能不正确（仅提示，不影响导入）"))
            }
            return .paymentAccount(accountDraft)
        case .attachmentRef:
            issues.append(issue(row: rowNumber, code: .unsupportedKind, field: "kind", detail: "CSV 未包含可导入的附件内容"))
            return nil
        case .gpgKey:
            // armored 公钥体量大、且私钥不应经过 CSV 明文通道，因此 GPG 条目暂不支持 CSV 导入导出。
            issues.append(issue(row: rowNumber, code: .unsupportedKind, field: "kind", detail: "GPG 密钥条目暂不支持 CSV 导入导出"))
            return nil
        }
    }

    static func rowValues(for item: VaultCSVItemDraft) -> [String: String] {
        var values = Dictionary(uniqueKeysWithValues: columns.map { ($0, "") })
        values["kind"] = item.kind.rawValue
        switch item {
        case .login(let draft):
            values["title"] = draft.title
            values["username"] = draft.username
            values["account"] = draft.account
            values["password"] = draft.password
            values["url"] = draft.url
            values["notes"] = draft.notes
            // 主 URL 永远在第一项；只有存在额外链接时才写 urls 列，保证单 URL 条目原样往返。
            let normalizedURLs = LoginEntryURLRules.normalizedURLs(primary: draft.url, additional: draft.urls)
            if normalizedURLs.count > 1 || (normalizedURLs.count == 1 && normalizedURLs[0] != draft.url) {
                values["urls"] = normalizedURLs.joined(separator: "\n")
            }
        case .note(let draft):
            values["title"] = draft.title
            values["body"] = draft.body
        case .totp(let draft):
            values["title"] = draft.title
            values["secret"] = draft.secret
            values["issuer"] = draft.issuer
            values["accountName"] = draft.accountName
            values["period"] = String(draft.period)
            values["digits"] = String(draft.digits)
            values["algorithm"] = draft.algorithm
            values["otpType"] = draft.otpType
            values["counter"] = String(draft.counter)
        case .steam(let draft):
            values["title"] = draft.title
            values["accountName"] = draft.accountName
            values["steamID"] = draft.steamID
            values["secret"] = SteamSharedSecretValidator.normalizedBase64(draft.sharedSecret)
            values["issuer"] = draft.issuer
            values["notes"] = draft.notes
        case .card(let draft):
            values["title"] = draft.title
            values["cardholderName"] = draft.cardholderName
            values["number"] = draft.number
            values["expiryMonth"] = draft.expiryMonth
            values["expiryYear"] = draft.expiryYear
            values["cvv"] = draft.cvv
            values["issuer"] = draft.issuer
            values["network"] = draft.network
            values["iban"] = draft.iban
            values["swiftCode"] = draft.swiftCode
            values["billingAddress"] = draft.billingAddress
            values["cardArtwork"] = draft.cardArtwork
            values["notes"] = draft.notes
        case .identity(let draft):
            values["title"] = draft.title
            values["documentType"] = draft.documentType
            values["fullName"] = draft.fullName
            values["documentNumber"] = draft.documentNumber
            values["issuer"] = draft.issuer
            values["country"] = draft.country
            values["issueDate"] = draft.issueDate
            values["expiryDate"] = draft.expiryDate
            values["notes"] = draft.notes
        case .passkey(let draft):
            values["title"] = draft.title
            values["username"] = draft.username
            values["relyingPartyID"] = draft.relyingPartyID
            values["userHandle"] = draft.userHandle
            values["credentialID"] = draft.credentialID
            values["publicKeyCOSE"] = draft.publicKeyCOSE
            values["privateKeyReference"] = draft.privateKeyReference
            values["notes"] = draft.notes
        case .sshKey(let draft):
            values["title"] = draft.title
            values["username"] = draft.username
            values["host"] = draft.host
            values["publicKey"] = draft.publicKey
            values["privateKeyReference"] = draft.privateKeyReference
            values["passphraseHint"] = draft.passphraseHint
            values["notes"] = draft.notes
            // 生成器写入的元数据只在存在时导出，手工条目保持原有空列。
            if !draft.algorithm.isEmpty { values["algorithm"] = draft.algorithm }
            if draft.keySize > 0 { values["keySize"] = String(draft.keySize) }
            if !draft.fingerprint.isEmpty { values["fingerprint"] = draft.fingerprint }
        case .apiToken(let draft):
            values["title"] = draft.title
            values["issuer"] = draft.issuer
            values["accountName"] = draft.accountName
            values["token"] = draft.token
            values["scopes"] = draft.scopes
            values["expiresAt"] = draft.expiresAt
            values["notes"] = draft.notes
        case .wifi(let draft):
            values["title"] = draft.title
            values["ssid"] = draft.ssid
            values["securityType"] = draft.securityType
            values["password"] = draft.password
            values["hidden"] = String(draft.hidden)
            values["notes"] = draft.notes
        case .sso(let draft):
            values["title"] = draft.title
            values["username"] = draft.accountName
            values["url"] = draft.loginURL
            values["issuer"] = draft.issuer
            values["secret"] = draft.secret
            values["ssoProvider"] = draft.provider.rawValue
            values["ssoProviderName"] = draft.providerName
            values["linkedLoginEntryID"] = draft.linkedLoginEntryID ?? ""
            values["notes"] = draft.notes
        case .barcode(let draft):
            values["title"] = draft.title
            values["payload"] = draft.payload
            values["symbology"] = draft.symbology.rawValue
            values["label"] = draft.label
            values["notes"] = draft.notes
        case .send(let draft):
            values["title"] = draft.title
            values["body"] = draft.body
            values["expiresAt"] = draft.expiresAt
            values["maxViews"] = String(draft.maxViews)
            values["notes"] = draft.notes
        case .billingAddress(let draft):
            values["title"] = draft.title
            values["fullName"] = draft.fullName
            values["streetAddress"] = draft.streetAddress
            values["apartment"] = draft.apartment
            values["city"] = draft.city
            values["stateProvince"] = draft.stateProvince
            values["postalCode"] = draft.postalCode
            values["country"] = draft.country
            values["phone"] = draft.phone
            values["linkedCardIDs"] = joinedVaultReferenceIdentifiers(draft.linkedCardIDs)
            values["notes"] = draft.notes
        case .paymentAccount(let draft):
            values["title"] = draft.title
            values["paymentType"] = draft.kind.androidName
            values["provider"] = draft.provider
            values["accountName"] = draft.accountName
            values["accountHolderName"] = draft.accountHolderName
            values["iban"] = draft.iban
            values["swiftBic"] = draft.swiftBIC
            values["routingNumber"] = draft.routingNumber
            values["accountNumber"] = draft.accountNumber
            values["currency"] = draft.currency
            values["linkedCardID"] = draft.linkedCardID
            values["billingAddressID"] = draft.billingAddressID
            values["notes"] = draft.notes
        }
        return values
    }

    private static func row(for item: VaultCSVItemDraft) -> [String] {
        let values = rowValues(for: item)
        return columns.map { values[$0] ?? "" }
    }

    private static func formatIssueField(for draft: LocalBillingAddressEntryDraft) -> String? {
        if BillingFieldValidator.postalCodeIssue(draft.postalCode) != nil {
            return "postalCode"
        }
        return nil
    }

    private static func formatIssueField(for draft: LocalPaymentAccountEntryDraft) -> String? {
        if BillingFieldValidator.ibanIssue(draft.iban) != nil {
            return "iban"
        }
        if BillingFieldValidator.swiftBICIssue(draft.swiftBIC) != nil {
            return "swiftBic"
        }
        if BillingFieldValidator.routingNumberIssue(draft.routingNumber) != nil {
            return "routingNumber"
        }
        if BillingFieldValidator.currencyIssue(draft.currency) != nil {
            return "currency"
        }
        return nil
    }

    static func parseRows(_ csv: String) throws -> [[String]] {
        let input = csv.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return [] }
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isQuoted = false
        var index = input.startIndex

        while index < input.endIndex {
            let character = input[index]
            if isQuoted {
                if character == "\"" {
                    let next = input.index(after: index)
                    if next < input.endIndex, input[next] == "\"" {
                        field.append("\"")
                        index = input.index(after: next)
                    } else {
                        isQuoted = false
                        index = next
                    }
                } else {
                    field.append(character)
                    index = input.index(after: index)
                }
            } else {
                switch character {
                case "\"":
                    isQuoted = true
                    index = input.index(after: index)
                case ",":
                    row.append(normalizedField(field))
                    field = ""
                    index = input.index(after: index)
                case "\n":
                    row.append(normalizedField(field))
                    rows.append(row)
                    row = []
                    field = ""
                    index = input.index(after: index)
                case "\r":
                    index = input.index(after: index)
                default:
                    field.append(character)
                    index = input.index(after: index)
                }
            }
        }
        if isQuoted { throw LocalVaultRepositoryError.vaultUnavailable }
        row.append(normalizedField(field))
        rows.append(row)
        return rows
    }

    private static func normalizedField(_ field: String) -> String {
        field.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 多 URL 单元格：换行分隔；同时兼容手写文件里用 `|` 分隔的情况。
    private static func urlList(_ value: String) -> [String] {
        value
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "|" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func escape(_ value: String) -> String {
        if value.contains(",") || value.contains("\n") || value.contains("\"") || value.contains("\r") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    private static func uint32(
        _ value: String,
        defaultValue: UInt32,
        row: Int,
        field: String,
        issues: inout [VaultCSVImportIssue]
    ) -> UInt32? {
        guard !value.isEmpty else { return defaultValue }
        guard let parsed = UInt32(value) else {
            issues.append(issue(row: row, code: .invalidNumber, field: field, detail: "数字字段格式错误"))
            return nil
        }
        return parsed
    }

    private static func uint64(
        _ value: String,
        defaultValue: UInt64,
        row: Int,
        field: String,
        issues: inout [VaultCSVImportIssue]
    ) -> UInt64? {
        guard !value.isEmpty else { return defaultValue }
        guard let parsed = UInt64(value) else {
            issues.append(issue(row: row, code: .invalidNumber, field: field, detail: "数字字段格式错误"))
            return nil
        }
        return parsed
    }

    private static func int(
        _ value: String,
        defaultValue: Int,
        row: Int,
        field: String,
        issues: inout [VaultCSVImportIssue]
    ) -> Int? {
        guard !value.isEmpty else { return defaultValue }
        guard let parsed = Int(value) else {
            issues.append(issue(row: row, code: .invalidNumber, field: field, detail: "数字字段格式错误"))
            return nil
        }
        return parsed
    }

    private static func bool(
        _ value: String,
        defaultValue: Bool,
        row: Int,
        field: String,
        issues: inout [VaultCSVImportIssue]
    ) -> Bool? {
        guard !value.isEmpty else { return defaultValue }
        switch value.lowercased() {
        case "true", "1", "yes", "y": return true
        case "false", "0", "no", "n": return false
        default:
            issues.append(issue(row: row, code: .invalidBoolean, field: field, detail: "布尔字段格式错误"))
            return nil
        }
    }

    private static func issue(row: Int, code: VaultCSVImportIssueCode, field: String?, detail: String) -> VaultCSVImportIssue {
        let fieldText = field.map { " 字段 \($0)" } ?? ""
        return VaultCSVImportIssue(row: row, code: code, field: field, message: "第 \(row) 行\(fieldText)：\(detail)")
    }
}

struct CSVRecord {
    let row: [String]
    let headerIndex: [String: Int]

    func value(_ field: String, fallback: String = "") -> String {
        guard let index = headerIndex[field], index < row.count else {
            return fallback
        }
        let value = row[index]
        return value.isEmpty ? fallback : value
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

public struct LocalIdentityEntryDraft: Sendable, Equatable {
    public let title: String
    public let documentType: String
    public let fullName: String
    public let documentNumber: String
    public let issuer: String
    public let country: String
    public let issueDate: String
    public let expiryDate: String
    public let notes: String

    public let metadata: VaultEntryMetadata

    public init(
        title: String,
        documentType: String,
        fullName: String,
        documentNumber: String,
        issuer: String,
        country: String,
        issueDate: String,
        expiryDate: String,
        notes: String
    ,
        metadata: VaultEntryMetadata = .empty) {
        self.title = title
        self.documentType = documentType
        self.fullName = fullName
        self.documentNumber = documentNumber
        self.issuer = issuer
        self.country = country
        self.issueDate = issueDate
        self.expiryDate = expiryDate
        self.notes = notes
        self.metadata = metadata
    }
}

public struct LocalIdentityEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let documentType: String
    public let fullName: String
    public let documentNumber: String
    public let issuer: String
    public let country: String
    public let issueDate: String
    public let expiryDate: String
    public let notes: String
    public let favorite: Bool
    public let metadata: VaultEntryMetadata

    public init(
        id: String,
        projectID: String,
        title: String,
        documentType: String,
        fullName: String,
        documentNumber: String,
        issuer: String,
        country: String,
        issueDate: String,
        expiryDate: String,
        notes: String,
        favorite: Bool = false,
        metadata: VaultEntryMetadata = .empty
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.documentType = documentType
        self.fullName = fullName
        self.documentNumber = documentNumber
        self.issuer = issuer
        self.country = country
        self.issueDate = issueDate
        self.expiryDate = expiryDate
        self.notes = notes
        self.favorite = favorite
        self.metadata = metadata
    }
}

public struct LocalSshKeyEntryDraft: Sendable, Equatable {
    public let title: String
    public let username: String
    public let host: String
    public let publicKey: String
    public let privateKeyReference: String
    public let passphraseHint: String
    public let notes: String
    /// 生成器写入的算法（`ED25519` / `RSA`，与 Android `MonicaSshAlgorithm` 一致）；手工条目为空。
    public let algorithm: String
    /// 生成器写入的位数（256 / 2048 / 3072 / 4096）；手工条目为 0。
    public let keySize: Int
    /// 生成器写入的 `SHA256:...` 指纹；手工条目为空。
    public let fingerprint: String

    public let metadata: VaultEntryMetadata

    public init(
        title: String,
        username: String,
        host: String,
        publicKey: String,
        privateKeyReference: String,
        passphraseHint: String,
        notes: String,
        algorithm: String = "",
        keySize: Int = 0,
        fingerprint: String = "",
        metadata: VaultEntryMetadata = .empty) {
        self.title = title
        self.username = username
        self.host = host
        self.publicKey = publicKey
        self.privateKeyReference = privateKeyReference
        self.passphraseHint = passphraseHint
        self.notes = notes
        self.algorithm = algorithm
        self.keySize = keySize
        self.fingerprint = fingerprint
        self.metadata = metadata
    }
}

public struct LocalSshKeyEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let username: String
    public let host: String
    public let publicKey: String
    public let privateKeyReference: String
    public let passphraseHint: String
    public let notes: String
    public let algorithm: String
    public let keySize: Int
    public let fingerprint: String
    public let favorite: Bool
    public let metadata: VaultEntryMetadata

    public init(
        id: String,
        projectID: String,
        title: String,
        username: String,
        host: String,
        publicKey: String,
        privateKeyReference: String,
        passphraseHint: String,
        notes: String,
        algorithm: String = "",
        keySize: Int = 0,
        fingerprint: String = "",
        favorite: Bool = false,
        metadata: VaultEntryMetadata = .empty
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.username = username
        self.host = host
        self.publicKey = publicKey
        self.privateKeyReference = privateKeyReference
        self.passphraseHint = passphraseHint
        self.notes = notes
        self.algorithm = algorithm
        self.keySize = keySize
        self.fingerprint = fingerprint
        self.favorite = favorite
        self.metadata = metadata
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

public struct LocalApiTokenEntryDraft: Sendable, Equatable {
    public let title: String
    public let issuer: String
    public let accountName: String
    public let token: String
    public let scopes: String
    public let expiresAt: String
    public let notes: String

    public let metadata: VaultEntryMetadata

    public init(
        title: String,
        issuer: String,
        accountName: String,
        token: String,
        scopes: String,
        expiresAt: String,
        notes: String
    ,
        metadata: VaultEntryMetadata = .empty) {
        self.title = title
        self.issuer = issuer
        self.accountName = accountName
        self.token = token
        self.scopes = scopes
        self.expiresAt = expiresAt
        self.notes = notes
        self.metadata = metadata
    }
}

public struct LocalApiTokenEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let issuer: String
    public let accountName: String
    public let token: String
    public let scopes: String
    public let expiresAt: String
    public let notes: String
    public let favorite: Bool
    public let metadata: VaultEntryMetadata

    public init(
        id: String,
        projectID: String,
        title: String,
        issuer: String,
        accountName: String,
        token: String,
        scopes: String,
        expiresAt: String,
        notes: String,
        favorite: Bool = false,
        metadata: VaultEntryMetadata = .empty
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.issuer = issuer
        self.accountName = accountName
        self.token = token
        self.scopes = scopes
        self.expiresAt = expiresAt
        self.notes = notes
        self.favorite = favorite
        self.metadata = metadata
    }
}

public struct LocalWifiEntryDraft: Sendable, Equatable {
    public let title: String
    public let ssid: String
    public let securityType: String
    public let password: String
    public let hidden: Bool
    public let notes: String

    public let metadata: VaultEntryMetadata

    public init(
        title: String,
        ssid: String,
        securityType: String,
        password: String,
        hidden: Bool,
        notes: String
    ,
        metadata: VaultEntryMetadata = .empty) {
        self.title = title
        self.ssid = ssid
        self.securityType = securityType
        self.password = password
        self.hidden = hidden
        self.notes = notes
        self.metadata = metadata
    }
}

public struct LocalWifiEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let ssid: String
    public let securityType: String
    public let password: String
    public let hidden: Bool
    public let notes: String
    public let favorite: Bool
    public let metadata: VaultEntryMetadata

    public init(
        id: String,
        projectID: String,
        title: String,
        ssid: String,
        securityType: String,
        password: String,
        hidden: Bool,
        notes: String,
        favorite: Bool = false,
        metadata: VaultEntryMetadata = .empty
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.ssid = ssid
        self.securityType = securityType
        self.password = password
        self.hidden = hidden
        self.notes = notes
        self.favorite = favorite
        self.metadata = metadata
    }
}

public extension LocalWifiEntry {
    var qrCodePayload: String {
        let type = normalizedQRCodeSecurityType
        let passwordSegment = type == "nopass" ? "" : "P:\(Self.qrEscaped(password));"
        return "WIFI:T:\(type);S:\(Self.qrEscaped(ssid));\(passwordSegment)H:\(hidden ? "true" : "false");;"
    }

    private var normalizedQRCodeSecurityType: String {
        let normalized = securityType.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if normalized.isEmpty || normalized == "OPEN" || normalized == "NONE" || normalized == "NOPASS" {
            return "nopass"
        }
        if normalized.contains("WEP") {
            return "WEP"
        }
        return "WPA"
    }

    private static func qrEscaped(_ value: String) -> String {
        value.reduce(into: "") { result, character in
            if "\\;,:\"".contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
    }
}

/// SSO 条目记录的身份提供方。
///
/// 这里只保存「用户手动录入的 SSO 配置元数据」，不涉及任何 OAuth/OIDC 令牌交换：
/// Monica 不会、也无法从第三方网站自动提取 SSO 会话或 cookie。
public enum SSOProvider: String, Sendable, CaseIterable, Equatable, Hashable {
    case google
    case microsoft
    case apple
    case github
    case okta
    case auth0
    case onelogin
    case keycloak
    case custom

    public var displayName: String {
        switch self {
        case .google:
            return "Google"
        case .microsoft:
            return "Microsoft"
        case .apple:
            return "Apple"
        case .github:
            return "GitHub"
        case .okta:
            return "Okta"
        case .auth0:
            return "Auth0"
        case .onelogin:
            return "OneLogin"
        case .keycloak:
            return "Keycloak"
        case .custom:
            return "自建 / 其他 IdP"
        }
    }

    /// Android 端 `SsoProvider` 枚举名，用于备份互通（Android `LoginType.kt`）。
    public var androidName: String {
        switch self {
        case .google:
            return "GOOGLE"
        case .microsoft:
            return "MICROSOFT"
        case .apple:
            return "APPLE"
        case .github:
            return "GITHUB"
        case .okta:
            return "OKTA"
        case .auth0:
            return "AUTH0"
        case .onelogin:
            return "ONELOGIN"
        case .keycloak:
            return "KEYCLOAK"
        case .custom:
            return "OTHER"
        }
    }

    /// OIDC issuer 的常见默认值；为空表示该提供方没有统一的 issuer。
    public var defaultIssuer: String {
        switch self {
        case .google:
            return "https://accounts.google.com"
        case .microsoft:
            return "https://login.microsoftonline.com/common/v2.0"
        case .apple:
            return "https://appleid.apple.com"
        case .github:
            return "https://github.com"
        case .okta, .auth0, .onelogin, .keycloak, .custom:
            return ""
        }
    }

    /// 各提供方的登录入口，仅作为「打开正规登录地址」的默认值。
    public var defaultLoginURL: String {
        switch self {
        case .google:
            return "https://accounts.google.com/"
        case .microsoft:
            return "https://login.microsoftonline.com/"
        case .apple:
            return "https://appleid.apple.com/"
        case .github:
            return "https://github.com/login"
        case .okta, .auth0, .onelogin, .keycloak, .custom:
            return ""
        }
    }

    public var systemImageName: String {
        switch self {
        case .google:
            return "g.circle.fill"
        case .microsoft:
            return "square.grid.2x2.fill"
        case .apple:
            return "apple.logo"
        case .github:
            return "chevron.left.forwardslash.chevron.right"
        case .okta, .auth0, .onelogin, .keycloak:
            return "key.fill"
        case .custom:
            return "building.2.fill"
        }
    }

    /// 未知的备份值一律回落到 `.custom`，保证旧/新备份互读不会失败。
    public static func fromAndroidName(_ rawValue: String) -> SSOProvider {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return SSOProvider.allCases.first { $0.androidName == normalized } ?? .custom
    }

    /// 解析自身存储的 rawValue（parity payload / CSV 列）。
    public static func fromStoredValue(_ rawValue: String) -> SSOProvider {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let provider = SSOProvider(rawValue: normalized) {
            return provider
        }
        return fromAndroidName(normalized)
    }
}

/// SSO 登录地址校验错误。
public enum SSOEntryURLError: Error, Sendable, Equatable, LocalizedError {
    case empty
    case malformed
    case unsupportedScheme(String)
    case missingHost
    case insecureScheme

    public var errorDescription: String? {
        message
    }

    public var message: String {
        switch self {
        case .empty:
            return String(localized: "登录地址不能为空")
        case .malformed:
            return String(localized: "登录地址格式不正确")
        case let .unsupportedScheme(scheme):
            return String(localized: "不支持的地址协议：\(scheme)")
        case .missingHost:
            return String(localized: "登录地址缺少主机名")
        case .insecureScheme:
            return String(localized: "该字段只允许 https 地址")
        }
    }
}

/// 只做「记录与展示」的 SSO 条目，外部跳转前必须经过这里的校验。
///
/// 规则：只放行 `http` / `https`，且必须带主机名；空串、`javascript:`、
/// `file:`、`data:` 以及任何其它 scheme 一律拒绝。issuer 额外要求 https。
public enum SSOEntryURLValidator {
    public static let allowedSchemes: Set<String> = ["http", "https"]

    public static func error(for rawValue: String) -> SSOEntryURLError? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .empty
        }
        guard !containsForbiddenCharacters(trimmed) else {
            return .malformed
        }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme,
              !scheme.isEmpty
        else {
            return .malformed
        }
        let normalizedScheme = scheme.lowercased()
        guard allowedSchemes.contains(normalizedScheme) else {
            return .unsupportedScheme(normalizedScheme)
        }
        let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !host.isEmpty else {
            return .missingHost
        }
        return nil
    }

    public static func sanitizedURL(from rawValue: String) -> URL? {
        guard error(for: rawValue) == nil,
              let components = URLComponents(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return nil
        }
        return components.url
    }

    public static func normalizedString(from rawValue: String) -> String? {
        sanitizedURL(from: rawValue)?.absoluteString
    }

    /// issuer 只接受 https（OIDC issuer 规范要求）。
    public static func isSecureIssuer(_ rawValue: String) -> Bool {
        guard let url = sanitizedURL(from: rawValue) else {
            return false
        }
        return url.scheme?.lowercased() == "https"
    }

    public static func issuerError(for rawValue: String) -> SSOEntryURLError? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if let error = error(for: trimmed) {
            return error
        }
        return isSecureIssuer(trimmed) ? nil : .insecureScheme
    }

    private static func containsForbiddenCharacters(_ value: String) -> Bool {
        if value.contains("\n") || value.contains("\r") || value.contains("\t") {
            return true
        }
        if value.contains(" ") {
            return true
        }
        return value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F
        }
    }
}

public struct LocalSSOEntryDraft: Sendable, Equatable {
    public let title: String
    public let provider: SSOProvider
    /// 自建 / 自定义 IdP 的显示名称，覆盖 `provider.displayName`。
    public let providerName: String
    public let issuer: String
    public let accountName: String
    public let loginURL: String
    /// 关联的登录条目 ID；条目被真删除后这里会残留，读取方必须能平稳降级。
    public let linkedLoginEntryID: String?
    public let notes: String
    /// 可选的附加凭据（client secret / 备注型凭据）。加密后随条目一起落库。
    public let secret: String

    public let metadata: VaultEntryMetadata

    public init(
        title: String,
        provider: SSOProvider = .custom,
        providerName: String = "",
        issuer: String = "",
        accountName: String = "",
        loginURL: String = "",
        linkedLoginEntryID: String? = nil,
        notes: String = "",
        secret: String = "",
        metadata: VaultEntryMetadata = .empty
    ) {
        self.title = title
        self.provider = provider
        self.providerName = providerName
        self.issuer = issuer
        self.accountName = accountName
        self.loginURL = loginURL
        self.linkedLoginEntryID = linkedLoginEntryID
        self.notes = notes
        self.secret = secret
        self.metadata = metadata
    }
}

public struct LocalSSOEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let provider: SSOProvider
    public let providerName: String
    public let issuer: String
    public let accountName: String
    public let loginURL: String
    public let linkedLoginEntryID: String?
    public let notes: String
    public let secret: String
    public let favorite: Bool
    public let metadata: VaultEntryMetadata

    public init(
        id: String,
        projectID: String,
        title: String,
        provider: SSOProvider = .custom,
        providerName: String = "",
        issuer: String = "",
        accountName: String = "",
        loginURL: String = "",
        linkedLoginEntryID: String? = nil,
        notes: String = "",
        secret: String = "",
        favorite: Bool = false,
        metadata: VaultEntryMetadata = .empty
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.provider = provider
        self.providerName = providerName
        self.issuer = issuer
        self.accountName = accountName
        self.loginURL = loginURL
        self.linkedLoginEntryID = linkedLoginEntryID
        self.notes = notes
        self.secret = secret
        self.favorite = favorite
        self.metadata = metadata
    }

    public var displayProviderName: String {
        let trimmed = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? provider.displayName : trimmed
    }

    /// 只有通过校验的地址才会返回，UI 用它决定「打开登录页」是否可点。
    public var sanitizedLoginURL: URL? {
        SSOEntryURLValidator.sanitizedURL(from: loginURL)
    }

    public var sanitizedIssuerURL: URL? {
        SSOEntryURLValidator.isSecureIssuer(issuer) ? SSOEntryURLValidator.sanitizedURL(from: issuer) : nil
    }

    /// 关联登录项已删除时返回 nil，调用方据此展示「关联项已删除」而不是丢数据。
    public func resolvedLinkedLoginEntry(in entries: [LocalLoginEntry]) -> LocalLoginEntry? {
        guard let linkedLoginEntryID, !linkedLoginEntryID.isEmpty else {
            return nil
        }
        return entries.first { $0.id == linkedLoginEntryID }
    }

    public var searchableText: String {
        [title, displayProviderName, accountName, loginURL, issuer, notes]
            .joined(separator: " ")
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

    public func createIdentityEntry(
        projectID: String,
        draft: LocalIdentityEntryDraft
    ) throws -> LocalIdentityEntry {
        let normalizedDraft = try normalizedIdentityEntryDraft(draft)
        return try engine.createIdentityEntry(
            in: session.handle,
            projectID: projectID,
            draft: normalizedDraft
        )
    }

    public func listIdentityEntries(projectID: String) throws -> [LocalIdentityEntry] {
        try engine.listIdentityEntries(in: session.handle, projectID: projectID)
    }

    public func updateIdentityEntry(
        projectID: String,
        entryID: String,
        draft: LocalIdentityEntryDraft
    ) throws -> LocalIdentityEntry {
        let normalizedDraft = try normalizedIdentityEntryDraft(draft)
        return try engine.updateIdentityEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            draft: normalizedDraft
        )
    }

    public func setIdentityEntryFavorite(
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalIdentityEntry {
        try engine.setIdentityEntryFavorite(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
    }

    public func deleteIdentityEntry(projectID: String, entryID: String) throws {
        try engine.deleteIdentityEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    public func listDeletedIdentityEntries(projectID: String) throws -> [LocalIdentityEntry] {
        try engine.listDeletedIdentityEntries(in: session.handle, projectID: projectID)
    }

    public func restoreIdentityEntry(
        projectID: String,
        entryID: String
    ) throws -> LocalIdentityEntry {
        try engine.restoreIdentityEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    public func createSshKeyEntry(projectID: String, draft: LocalSshKeyEntryDraft) throws -> LocalSshKeyEntry {
        try engine.createSshKeyEntry(in: session.handle, projectID: projectID, draft: normalizedSshKeyEntryDraft(draft))
    }

    public func listSshKeyEntries(projectID: String) throws -> [LocalSshKeyEntry] {
        try engine.listSshKeyEntries(in: session.handle, projectID: projectID)
    }

    public func updateSshKeyEntry(projectID: String, entryID: String, draft: LocalSshKeyEntryDraft) throws -> LocalSshKeyEntry {
        try engine.updateSshKeyEntry(in: session.handle, projectID: projectID, entryID: entryID, draft: normalizedSshKeyEntryDraft(draft))
    }

    public func setSshKeyEntryFavorite(projectID: String, entryID: String, favorite: Bool) throws -> LocalSshKeyEntry {
        try engine.setSshKeyEntryFavorite(in: session.handle, projectID: projectID, entryID: entryID, favorite: favorite)
    }

    public func deleteSshKeyEntry(projectID: String, entryID: String) throws {
        try engine.deleteSshKeyEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func listDeletedSshKeyEntries(projectID: String) throws -> [LocalSshKeyEntry] {
        try engine.listDeletedSshKeyEntries(in: session.handle, projectID: projectID)
    }

    public func restoreSshKeyEntry(projectID: String, entryID: String) throws -> LocalSshKeyEntry {
        try engine.restoreSshKeyEntry(in: session.handle, projectID: projectID, entryID: entryID)
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

    public func createApiTokenEntry(projectID: String, draft: LocalApiTokenEntryDraft) throws -> LocalApiTokenEntry {
        try engine.createApiTokenEntry(in: session.handle, projectID: projectID, draft: normalizedApiTokenEntryDraft(draft))
    }

    public func listApiTokenEntries(projectID: String) throws -> [LocalApiTokenEntry] {
        try engine.listApiTokenEntries(in: session.handle, projectID: projectID)
    }

    public func updateApiTokenEntry(projectID: String, entryID: String, draft: LocalApiTokenEntryDraft) throws -> LocalApiTokenEntry {
        try engine.updateApiTokenEntry(in: session.handle, projectID: projectID, entryID: entryID, draft: normalizedApiTokenEntryDraft(draft))
    }

    public func setApiTokenEntryFavorite(projectID: String, entryID: String, favorite: Bool) throws -> LocalApiTokenEntry {
        try engine.setApiTokenEntryFavorite(in: session.handle, projectID: projectID, entryID: entryID, favorite: favorite)
    }

    public func deleteApiTokenEntry(projectID: String, entryID: String) throws {
        try engine.deleteApiTokenEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func listDeletedApiTokenEntries(projectID: String) throws -> [LocalApiTokenEntry] {
        try engine.listDeletedApiTokenEntries(in: session.handle, projectID: projectID)
    }

    public func restoreApiTokenEntry(projectID: String, entryID: String) throws -> LocalApiTokenEntry {
        try engine.restoreApiTokenEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func createWifiEntry(projectID: String, draft: LocalWifiEntryDraft) throws -> LocalWifiEntry {
        try engine.createWifiEntry(in: session.handle, projectID: projectID, draft: normalizedWifiEntryDraft(draft))
    }

    public func listWifiEntries(projectID: String) throws -> [LocalWifiEntry] {
        try engine.listWifiEntries(in: session.handle, projectID: projectID)
    }

    public func updateWifiEntry(projectID: String, entryID: String, draft: LocalWifiEntryDraft) throws -> LocalWifiEntry {
        try engine.updateWifiEntry(in: session.handle, projectID: projectID, entryID: entryID, draft: normalizedWifiEntryDraft(draft))
    }

    public func setWifiEntryFavorite(projectID: String, entryID: String, favorite: Bool) throws -> LocalWifiEntry {
        try engine.setWifiEntryFavorite(in: session.handle, projectID: projectID, entryID: entryID, favorite: favorite)
    }

    public func deleteWifiEntry(projectID: String, entryID: String) throws {
        try engine.deleteWifiEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func listDeletedWifiEntries(projectID: String) throws -> [LocalWifiEntry] {
        try engine.listDeletedWifiEntries(in: session.handle, projectID: projectID)
    }

    public func restoreWifiEntry(projectID: String, entryID: String) throws -> LocalWifiEntry {
        try engine.restoreWifiEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func createSSOEntry(projectID: String, draft: LocalSSOEntryDraft) throws -> LocalSSOEntry {
        try engine.createSSOEntry(in: session.handle, projectID: projectID, draft: normalizedSSOEntryDraft(draft))
    }

    public func listSSOEntries(projectID: String) throws -> [LocalSSOEntry] {
        try engine.listSSOEntries(in: session.handle, projectID: projectID)
    }

    public func updateSSOEntry(projectID: String, entryID: String, draft: LocalSSOEntryDraft) throws -> LocalSSOEntry {
        try engine.updateSSOEntry(in: session.handle, projectID: projectID, entryID: entryID, draft: normalizedSSOEntryDraft(draft))
    }

    public func setSSOEntryFavorite(projectID: String, entryID: String, favorite: Bool) throws -> LocalSSOEntry {
        try engine.setSSOEntryFavorite(in: session.handle, projectID: projectID, entryID: entryID, favorite: favorite)
    }

    public func deleteSSOEntry(projectID: String, entryID: String) throws {
        try engine.deleteSSOEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func listDeletedSSOEntries(projectID: String) throws -> [LocalSSOEntry] {
        try engine.listDeletedSSOEntries(in: session.handle, projectID: projectID)
    }

    public func restoreSSOEntry(projectID: String, entryID: String) throws -> LocalSSOEntry {
        try engine.restoreSSOEntry(in: session.handle, projectID: projectID, entryID: entryID)
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

    public func createBarcodeEntry(projectID: String, draft: LocalBarcodeEntryDraft) throws -> LocalBarcodeEntry {
        try engine.createBarcodeEntry(in: session.handle, projectID: projectID, draft: normalizedBarcodeEntryDraft(draft))
    }

    public func listBarcodeEntries(projectID: String) throws -> [LocalBarcodeEntry] {
        try engine.listBarcodeEntries(in: session.handle, projectID: projectID)
    }

    public func updateBarcodeEntry(projectID: String, entryID: String, draft: LocalBarcodeEntryDraft) throws -> LocalBarcodeEntry {
        try engine.updateBarcodeEntry(in: session.handle, projectID: projectID, entryID: entryID, draft: normalizedBarcodeEntryDraft(draft))
    }

    public func setBarcodeEntryFavorite(projectID: String, entryID: String, favorite: Bool) throws -> LocalBarcodeEntry {
        try engine.setBarcodeEntryFavorite(in: session.handle, projectID: projectID, entryID: entryID, favorite: favorite)
    }

    public func deleteBarcodeEntry(projectID: String, entryID: String) throws {
        try engine.deleteBarcodeEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func listDeletedBarcodeEntries(projectID: String) throws -> [LocalBarcodeEntry] {
        try engine.listDeletedBarcodeEntries(in: session.handle, projectID: projectID)
    }

    public func restoreBarcodeEntry(projectID: String, entryID: String) throws -> LocalBarcodeEntry {
        try engine.restoreBarcodeEntry(in: session.handle, projectID: projectID, entryID: entryID)
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

    private func normalizedIdentityEntryDraft(_ draft: LocalIdentityEntryDraft) throws -> LocalIdentityEntryDraft {
        let normalizedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw LocalVaultRepositoryError.emptyEntryTitle
        }
        return LocalIdentityEntryDraft(
            title: normalizedTitle,
            documentType: draft.documentType,
            fullName: draft.fullName,
            documentNumber: draft.documentNumber,
            issuer: draft.issuer,
            country: draft.country,
            issueDate: draft.issueDate,
            expiryDate: draft.expiryDate,
            notes: draft.notes
        )
    }

    private func normalizedSshKeyEntryDraft(_ draft: LocalSshKeyEntryDraft) throws -> LocalSshKeyEntryDraft {
        let normalizedTitle = try normalizedEntryTitle(draft.title)
        return LocalSshKeyEntryDraft(
            title: normalizedTitle,
            username: draft.username,
            host: draft.host,
            publicKey: draft.publicKey,
            privateKeyReference: draft.privateKeyReference,
            passphraseHint: draft.passphraseHint,
            notes: draft.notes,
            algorithm: draft.algorithm,
            keySize: draft.keySize,
            fingerprint: draft.fingerprint
        )
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

    private func normalizedApiTokenEntryDraft(_ draft: LocalApiTokenEntryDraft) throws -> LocalApiTokenEntryDraft {
        let normalizedTitle = try normalizedEntryTitle(draft.title)
        return LocalApiTokenEntryDraft(
            title: normalizedTitle,
            issuer: draft.issuer,
            accountName: draft.accountName,
            token: draft.token,
            scopes: draft.scopes,
            expiresAt: draft.expiresAt,
            notes: draft.notes
        )
    }

    private func normalizedWifiEntryDraft(_ draft: LocalWifiEntryDraft) throws -> LocalWifiEntryDraft {
        let normalizedTitle = try normalizedEntryTitle(draft.title)
        return LocalWifiEntryDraft(
            title: normalizedTitle,
            ssid: draft.ssid,
            securityType: draft.securityType,
            password: draft.password,
            hidden: draft.hidden,
            notes: draft.notes
        )
    }

    private func normalizedSSOEntryDraft(_ draft: LocalSSOEntryDraft) throws -> LocalSSOEntryDraft {
        let normalizedTitle = try normalizedEntryTitle(draft.title)
        let loginURL = draft.loginURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !loginURL.isEmpty, SSOEntryURLValidator.error(for: loginURL) != nil {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        let issuer = draft.issuer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !issuer.isEmpty, SSOEntryURLValidator.issuerError(for: issuer) != nil {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        let linkedID = draft.linkedLoginEntryID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return LocalSSOEntryDraft(
            title: normalizedTitle,
            provider: draft.provider,
            providerName: draft.providerName.trimmingCharacters(in: .whitespacesAndNewlines),
            issuer: issuer,
            accountName: draft.accountName.trimmingCharacters(in: .whitespacesAndNewlines),
            loginURL: loginURL,
            linkedLoginEntryID: (linkedID?.isEmpty ?? true) ? nil : linkedID,
            notes: draft.notes,
            secret: draft.secret
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

    private func normalizedBarcodeEntryDraft(_ draft: LocalBarcodeEntryDraft) throws -> LocalBarcodeEntryDraft {
        let normalizedTitle = try normalizedEntryTitle(draft.title)
        let validatedDraft = try draft.validated()
        return LocalBarcodeEntryDraft(
            title: normalizedTitle,
            symbology: validatedDraft.symbology,
            payload: validatedDraft.payload,
            label: draft.label,
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

    public func createIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalIdentityEntryDraft
    ) throws -> LocalIdentityEntry {
        let entry = try vault(for: handle).createIdentityEntry(
            projectID: projectID,
            title: draft.title,
            documentType: draft.documentType,
            fullName: draft.fullName,
            documentNumber: draft.documentNumber,
            issuer: draft.issuer,
            country: draft.country,
            issueDate: draft.issueDate,
            expiryDate: draft.expiryDate,
            notes: draft.notes
        )
        return LocalIdentityEntry(entry)
    }

    public func listIdentityEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalIdentityEntry] {
        try vault(for: handle)
            .listIdentityEntries(projectID: projectID)
            .map(LocalIdentityEntry.init)
    }

    public func updateIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalIdentityEntryDraft
    ) throws -> LocalIdentityEntry {
        let entry = try vault(for: handle).updateIdentityEntry(
            projectID: projectID,
            entryID: entryID,
            title: draft.title,
            documentType: draft.documentType,
            fullName: draft.fullName,
            documentNumber: draft.documentNumber,
            issuer: draft.issuer,
            country: draft.country,
            issueDate: draft.issueDate,
            expiryDate: draft.expiryDate,
            notes: draft.notes
        )
        return LocalIdentityEntry(entry)
    }

    public func setIdentityEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalIdentityEntry {
        let entry = try vault(for: handle).setIdentityEntryFavorite(
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
        return LocalIdentityEntry(entry)
    }

    public func deleteIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        try vault(for: handle).deleteIdentityEntry(projectID: projectID, entryID: entryID)
    }

    public func listDeletedIdentityEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalIdentityEntry] {
        try vault(for: handle)
            .listDeletedIdentityEntries(projectID: projectID)
            .map(LocalIdentityEntry.init)
    }

    public func restoreIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalIdentityEntry {
        let entry = try vault(for: handle).restoreIdentityEntry(
            projectID: projectID,
            entryID: entryID
        )
        return LocalIdentityEntry(entry)
    }

    public func createSshKeyEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalSshKeyEntryDraft) throws -> LocalSshKeyEntry {
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "ssh-key",
            kind: "ssh-key",
            title: draft.title,
            payload: [
                "username": draft.username,
                "host": draft.host,
                "publicKey": draft.publicKey,
                "privateKeyReference": draft.privateKeyReference,
                "passphraseHint": draft.passphraseHint,
                "notes": draft.notes,
                "algorithm": draft.algorithm,
                "keySize": draft.keySize > 0 ? String(draft.keySize) : "",
                "fingerprint": draft.fingerprint
            ]
        )
        return try LocalSshKeyEntry(entry)
    }

    public func listSshKeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSshKeyEntry] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "ssh-key", kind: "ssh-key").map(LocalSshKeyEntry.init)
    }

    public func updateSshKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalSshKeyEntryDraft) throws -> LocalSshKeyEntry {
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: entryID,
            entryType: "ssh-key",
            kind: "ssh-key",
            title: draft.title,
            payload: [
                "username": draft.username,
                "host": draft.host,
                "publicKey": draft.publicKey,
                "privateKeyReference": draft.privateKeyReference,
                "passphraseHint": draft.passphraseHint,
                "notes": draft.notes,
                "algorithm": draft.algorithm,
                "keySize": draft.keySize > 0 ? String(draft.keySize) : "",
                "fingerprint": draft.fingerprint
            ]
        )
        return try LocalSshKeyEntry(entry)
    }

    public func setSshKeyEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalSshKeyEntry {
        try LocalSshKeyEntry(setParityEntryFavorite(in: handle, projectID: projectID, entryID: entryID, entryType: "ssh-key", kind: "ssh-key", favorite: favorite))
    }

    public func deleteSshKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        try deleteParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "ssh-key", kind: "ssh-key")
    }

    public func listDeletedSshKeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSshKeyEntry] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "ssh-key", kind: "ssh-key").map(LocalSshKeyEntry.init)
    }

    public func restoreSshKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalSshKeyEntry {
        try LocalSshKeyEntry(restoreParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "ssh-key", kind: "ssh-key"))
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

    public func createApiTokenEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalApiTokenEntryDraft) throws -> LocalApiTokenEntry {
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "api-token",
            kind: "api-token",
            title: draft.title,
            payload: [
                "issuer": draft.issuer,
                "accountName": draft.accountName,
                "token": draft.token,
                "scopes": draft.scopes,
                "expiresAt": draft.expiresAt,
                "notes": draft.notes
            ]
        )
        return try LocalApiTokenEntry(entry)
    }

    public func listApiTokenEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalApiTokenEntry] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "api-token", kind: "api-token").map(LocalApiTokenEntry.init)
    }

    public func updateApiTokenEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalApiTokenEntryDraft) throws -> LocalApiTokenEntry {
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: entryID,
            entryType: "api-token",
            kind: "api-token",
            title: draft.title,
            payload: [
                "issuer": draft.issuer,
                "accountName": draft.accountName,
                "token": draft.token,
                "scopes": draft.scopes,
                "expiresAt": draft.expiresAt,
                "notes": draft.notes
            ]
        )
        return try LocalApiTokenEntry(entry)
    }

    public func setApiTokenEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalApiTokenEntry {
        try LocalApiTokenEntry(setParityEntryFavorite(in: handle, projectID: projectID, entryID: entryID, entryType: "api-token", kind: "api-token", favorite: favorite))
    }

    public func deleteApiTokenEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        try deleteParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "api-token", kind: "api-token")
    }

    public func listDeletedApiTokenEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalApiTokenEntry] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "api-token", kind: "api-token").map(LocalApiTokenEntry.init)
    }

    public func restoreApiTokenEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalApiTokenEntry {
        try LocalApiTokenEntry(restoreParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "api-token", kind: "api-token"))
    }

    public func createWifiEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalWifiEntryDraft) throws -> LocalWifiEntry {
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "document-ref",
            kind: "wifi",
            title: draft.title,
            payload: [
                "ssid": draft.ssid,
                "securityType": draft.securityType,
                "password": draft.password,
                "hidden": draft.hidden,
                "notes": draft.notes
            ]
        )
        return try LocalWifiEntry(entry)
    }

    public func listWifiEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalWifiEntry] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "wifi").map(LocalWifiEntry.init)
    }

    public func updateWifiEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalWifiEntryDraft) throws -> LocalWifiEntry {
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: entryID,
            entryType: "document-ref",
            kind: "wifi",
            title: draft.title,
            payload: [
                "ssid": draft.ssid,
                "securityType": draft.securityType,
                "password": draft.password,
                "hidden": draft.hidden,
                "notes": draft.notes
            ]
        )
        return try LocalWifiEntry(entry)
    }

    public func setWifiEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalWifiEntry {
        try LocalWifiEntry(setParityEntryFavorite(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "wifi", favorite: favorite))
    }

    public func deleteWifiEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        try deleteParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "wifi")
    }

    public func listDeletedWifiEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalWifiEntry] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "wifi").map(LocalWifiEntry.init)
    }

    public func restoreWifiEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalWifiEntry {
        try LocalWifiEntry(restoreParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "wifi"))
    }

    public func createSSOEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalSSOEntryDraft) throws -> LocalSSOEntry {
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "document-ref",
            kind: "sso",
            title: draft.title,
            payload: Self.ssoPayload(for: draft)
        )
        return try LocalSSOEntry(entry)
    }

    public func listSSOEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSSOEntry] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "sso").map(LocalSSOEntry.init)
    }

    public func updateSSOEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalSSOEntryDraft) throws -> LocalSSOEntry {
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: entryID,
            entryType: "document-ref",
            kind: "sso",
            title: draft.title,
            payload: Self.ssoPayload(for: draft)
        )
        return try LocalSSOEntry(entry)
    }

    public func setSSOEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalSSOEntry {
        try LocalSSOEntry(setParityEntryFavorite(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "sso", favorite: favorite))
    }

    public func deleteSSOEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        try deleteParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "sso")
    }

    public func listDeletedSSOEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSSOEntry] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "sso").map(LocalSSOEntry.init)
    }

    public func restoreSSOEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalSSOEntry {
        try LocalSSOEntry(restoreParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "sso"))
    }

    /// SSO 条目的加密载荷：secret 与备注同其它 parity 条目一样落在加密后的 payload 中，
    /// 不会写入 UserDefaults、日志或任何明文索引。
    private static func ssoPayload(for draft: LocalSSOEntryDraft) -> [String: Any] {
        [
            "provider": draft.provider.rawValue,
            "providerName": draft.providerName,
            "issuer": draft.issuer,
            "accountName": draft.accountName,
            "loginURL": draft.loginURL,
            "linkedLoginEntryID": draft.linkedLoginEntryID ?? "",
            "notes": draft.notes,
            "secret": draft.secret
        ]
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

    public func createBarcodeEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalBarcodeEntryDraft) throws -> LocalBarcodeEntry {
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "document-ref",
            kind: "barcode",
            title: draft.title,
            payload: BarcodeEntryPayloadCodec.encoded(draft)
        )
        return try LocalBarcodeEntry(entry)
    }

    public func listBarcodeEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalBarcodeEntry] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "barcode").map(LocalBarcodeEntry.init)
    }

    public func updateBarcodeEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalBarcodeEntryDraft) throws -> LocalBarcodeEntry {
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: entryID,
            entryType: "document-ref",
            kind: "barcode",
            title: draft.title,
            payload: BarcodeEntryPayloadCodec.encoded(draft)
        )
        return try LocalBarcodeEntry(entry)
    }

    public func setBarcodeEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalBarcodeEntry {
        try LocalBarcodeEntry(setParityEntryFavorite(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "barcode", favorite: favorite))
    }

    public func deleteBarcodeEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        try deleteParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "barcode")
    }

    public func listDeletedBarcodeEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalBarcodeEntry] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "barcode").map(LocalBarcodeEntry.init)
    }

    public func restoreBarcodeEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalBarcodeEntry {
        try LocalBarcodeEntry(restoreParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "barcode"))

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

private extension LocalIdentityEntry {
    init(_ entry: MonicaMDBXIdentityEntry) {
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            documentType: entry.documentType,
            fullName: entry.fullName,
            documentNumber: entry.documentNumber,
            issuer: entry.issuer,
            country: entry.country,
            issueDate: entry.issueDate,
            expiryDate: entry.expiryDate,
            notes: entry.notes,
            favorite: entry.favorite,
            metadata: VaultEntryMetadata(entry.metadata)
        )
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

private extension LocalSshKeyEntry {
    init(_ entry: MonicaMDBXParityEntry) throws {
        let payload = try entry.payloadDictionary()
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            username: payload.string("username"),
            host: payload.string("host"),
            publicKey: payload.string("publicKey"),
            privateKeyReference: payload.string("privateKeyReference"),
            passphraseHint: payload.string("passphraseHint"),
            notes: payload.string("notes"),
            algorithm: payload.string("algorithm"),
            keySize: Int(payload.string("keySize")) ?? 0,
            fingerprint: payload.string("fingerprint"),
            favorite: entry.favorite,
            metadata: VaultEntryMetadata(entry.metadata)
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

private extension LocalApiTokenEntry {
    init(_ entry: MonicaMDBXParityEntry) throws {
        let payload = try entry.payloadDictionary()
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            issuer: payload.string("issuer"),
            accountName: payload.string("accountName"),
            token: payload.string("token"),
            scopes: payload.string("scopes"),
            expiresAt: payload.string("expiresAt"),
            notes: payload.string("notes"),
            favorite: entry.favorite,
            metadata: VaultEntryMetadata(entry.metadata)
        )
    }
}

private extension LocalWifiEntry {
    init(_ entry: MonicaMDBXParityEntry) throws {
        let payload = try entry.payloadDictionary()
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            ssid: payload.string("ssid"),
            securityType: payload.string("securityType"),
            password: payload.string("password"),
            hidden: payload.bool("hidden"),
            notes: payload.string("notes"),
            favorite: entry.favorite,
            metadata: VaultEntryMetadata(entry.metadata)
        )
    }
}

private extension LocalBarcodeEntry {
    init(_ entry: MonicaMDBXParityEntry) throws {
        let payload = try entry.payloadDictionary()
        self = BarcodeEntryPayloadCodec.decoded(
            payload,
            entryID: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            favorite: entry.favorite
        )
    }
}

private extension LocalSSOEntry {
    init(_ entry: MonicaMDBXParityEntry) throws {
        let payload = try entry.payloadDictionary()
        let linkedID = payload.string("linkedLoginEntryID")
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            provider: SSOProvider.fromStoredValue(payload.string("provider")),
            providerName: payload.string("providerName"),
            issuer: payload.string("issuer"),
            accountName: payload.string("accountName"),
            loginURL: payload.string("loginURL"),
            linkedLoginEntryID: linkedID.isEmpty ? nil : linkedID,
            notes: payload.string("notes"),
            secret: payload.string("secret"),
            favorite: entry.favorite,
            metadata: VaultEntryMetadata(entry.metadata)
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
