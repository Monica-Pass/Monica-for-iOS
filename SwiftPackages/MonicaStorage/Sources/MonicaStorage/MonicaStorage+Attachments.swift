// MARK: - 附件：内容加解密与文件存储、元数据条目、仓库与 MDBX 引擎实现

import Foundation
import CryptoKit
import MonicaMDBX

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

extension LocalVaultEntryRepository {
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
}

extension MDBXLocalVaultEngine {
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
