// MARK: - Android 备份导入导出（.zip / 加密备份信封 / Bitwarden 兼容映射）

import Foundation
import CryptoKit
import ZIPFoundation

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
