// MARK: - 自动填充索引：加密索引 / 凭据密钥记录 / 解锁器 / 解析器与文件存储

import Foundation
import CryptoKit

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
