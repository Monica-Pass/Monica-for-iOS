import Foundation

// MARK: - Item kinds and typed content

public enum LanSyncItemKind: String, Codable, Sendable, Equatable, CaseIterable {
    case login
    case totp
    case note
    case card
}

public struct LanSyncLoginContent: Codable, Sendable, Equatable {
    public var username: String
    public var password: String
    public var url: String
    public var notes: String

    public init(username: String, password: String, url: String, notes: String) {
        self.username = username
        self.password = password
        self.url = url
        self.notes = notes
    }
}

public struct LanSyncTotpContent: Codable, Sendable, Equatable {
    public var secret: String
    public var issuer: String
    public var accountName: String
    public var period: Int
    public var digits: Int
    public var algorithm: String
    public var otpType: String
    public var counter: Int

    public init(
        secret: String,
        issuer: String,
        accountName: String,
        period: Int,
        digits: Int,
        algorithm: String,
        otpType: String,
        counter: Int
    ) {
        self.secret = secret
        self.issuer = issuer
        self.accountName = accountName
        self.period = period
        self.digits = digits
        self.algorithm = algorithm
        self.otpType = otpType
        self.counter = counter
    }
}

public struct LanSyncNoteContent: Codable, Sendable, Equatable {
    public var body: String

    public init(body: String) {
        self.body = body
    }
}

public struct LanSyncCardContent: Codable, Sendable, Equatable {
    public var cardholderName: String
    public var number: String
    public var expiryMonth: String
    public var expiryYear: String
    public var securityCode: String
    public var brand: String
    public var notes: String

    public init(
        cardholderName: String,
        number: String,
        expiryMonth: String,
        expiryYear: String,
        securityCode: String,
        brand: String,
        notes: String
    ) {
        self.cardholderName = cardholderName
        self.number = number
        self.expiryMonth = expiryMonth
        self.expiryYear = expiryYear
        self.securityCode = securityCode
        self.brand = brand
        self.notes = notes
    }
}

public enum LanSyncItemContent: Sendable, Equatable {
    case login(LanSyncLoginContent)
    case totp(LanSyncTotpContent)
    case note(LanSyncNoteContent)
    case card(LanSyncCardContent)

    public var kind: LanSyncItemKind {
        switch self {
        case .login: .login
        case .totp: .totp
        case .note: .note
        case .card: .card
        }
    }
}

extension LanSyncItemContent: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(LanSyncItemKind.self, forKey: .type)
        switch type {
        case .login:
            self = .login(try container.decode(LanSyncLoginContent.self, forKey: .payload))
        case .totp:
            self = .totp(try container.decode(LanSyncTotpContent.self, forKey: .payload))
        case .note:
            self = .note(try container.decode(LanSyncNoteContent.self, forKey: .payload))
        case .card:
            self = .card(try container.decode(LanSyncCardContent.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .type)
        switch self {
        case .login(let payload):
            try container.encode(payload, forKey: .payload)
        case .totp(let payload):
            try container.encode(payload, forKey: .payload)
        case .note(let payload):
            try container.encode(payload, forKey: .payload)
        case .card(let payload):
            try container.encode(payload, forKey: .payload)
        }
    }
}

// MARK: - Wire item

public struct LanSyncItem: Codable, Sendable, Equatable {
    public var syncID: UUID
    public var kind: LanSyncItemKind
    public var projectTitle: String
    public var title: String
    public var favorite: Bool
    public var content: LanSyncItemContent

    public init(
        syncID: UUID,
        projectTitle: String,
        title: String,
        favorite: Bool,
        content: LanSyncItemContent
    ) {
        self.syncID = syncID
        self.kind = content.kind
        self.projectTitle = projectTitle
        self.title = title
        self.favorite = favorite
        self.content = content
    }

    /// Canonical bytes used for `contentHash`; excludes any local identifiers so
    /// both peers compute the same hash for the same logical item.
    public func canonicalBytes() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public var contentHash: Data {
        (try? LanSyncEncoding.sha256(canonicalBytes())) ?? Data()
    }
}

// MARK: - Tombstone

public struct LanSyncTombstone: Codable, Sendable, Equatable {
    public var syncID: UUID
    public var deletedAt: Date
    public var deletedContentHash: Data?

    public init(syncID: UUID, deletedAt: Date, deletedContentHash: Data? = nil) {
        self.syncID = syncID
        self.deletedAt = deletedAt
        self.deletedContentHash = deletedContentHash
    }
}

// MARK: - Snapshot

public struct LanSyncVaultSnapshot: Codable, Sendable, Equatable {
    public var formatVersion: Int
    public var vaultID: String
    public var senderDeviceID: String
    public var senderDisplayName: String
    public var revision: Int
    public var exportedAt: Date
    public var items: [LanSyncItem]
    public var tombstones: [LanSyncTombstone]
    public var digest: Data

    public init(
        formatVersion: Int = LanSyncProtocolSpec.snapshotFormatVersion,
        vaultID: String,
        senderDeviceID: String,
        senderDisplayName: String,
        revision: Int,
        exportedAt: Date = Date(),
        items: [LanSyncItem],
        tombstones: [LanSyncTombstone],
        digest: Data = Data()
    ) {
        self.formatVersion = formatVersion
        self.vaultID = vaultID
        self.senderDeviceID = senderDeviceID
        self.senderDisplayName = senderDisplayName
        self.revision = revision
        self.exportedAt = exportedAt
        self.items = items
        self.tombstones = tombstones
        self.digest = digest
    }

    /// Builds a snapshot and seals it with its integrity digest.
    public static func make(
        vaultID: String,
        senderDeviceID: String,
        senderDisplayName: String,
        revision: Int,
        exportedAt: Date = Date(),
        items: [LanSyncItem],
        tombstones: [LanSyncTombstone]
    ) throws -> LanSyncVaultSnapshot {
        var snapshot = LanSyncVaultSnapshot(
            vaultID: vaultID,
            senderDeviceID: senderDeviceID,
            senderDisplayName: senderDisplayName,
            revision: revision,
            exportedAt: exportedAt,
            items: items,
            tombstones: tombstones
        )
        try snapshot.validate()
        snapshot.digest = try snapshot.computedDigest()
        return snapshot
    }

    public func validate() throws {
        guard formatVersion == LanSyncProtocolSpec.snapshotFormatVersion else {
            throw LanSyncSnapshotError.unsupportedFormatVersion(formatVersion)
        }
        var seen = Set<UUID>()
        for item in items {
            guard seen.insert(item.syncID).inserted else {
                throw LanSyncSnapshotError.duplicateSyncID(item.syncID)
            }
        }
        for tombstone in tombstones where seen.contains(tombstone.syncID) {
            throw LanSyncSnapshotError.duplicateSyncID(tombstone.syncID)
        }
    }

    /// Digest over every field except `digest` itself.
    public func computedDigest() throws -> Data {
        var copy = self
        copy.digest = Data()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return LanSyncEncoding.sha256(try encoder.encode(copy))
    }

    public var hasValidDigest: Bool {
        guard let computed = try? computedDigest() else { return false }
        return LanSyncEncoding.constantTimeEquals(computed, digest)
    }

    /// Verifies format version, uniqueness and integrity in one step.
    public func verifyIntegrity() throws {
        try validate()
        guard hasValidDigest else {
            throw LanSyncSnapshotError.digestMismatch
        }
    }
}

// MARK: - Local (vault-backed) item

/// A snapshot item plus the identifier of the matching local vault entry.
/// `localEntryID` is never sent over the wire.
public struct LanSyncLocalItem: Sendable, Equatable {
    public var item: LanSyncItem
    public var localEntryID: String

    public init(item: LanSyncItem, localEntryID: String) {
        self.item = item
        self.localEntryID = localEntryID
    }

    public var syncID: UUID { item.syncID }
    public var contentHash: Data { item.contentHash }
}

public enum LanSyncSnapshotError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedFormatVersion(Int)
    case digestMismatch
    case duplicateSyncID(UUID)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormatVersion:
            "对方设备发送的同步数据版本不受支持，请将两台设备都更新到最新版本。"
        case .digestMismatch:
            "同步数据完整性校验失败，数据可能在传输途中被损坏，请重试。"
        case .duplicateSyncID:
            "同步数据中存在重复条目，已中止本次同步。"
        }
    }
}
