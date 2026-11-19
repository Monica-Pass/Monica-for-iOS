import Foundation

// MARK: - Transfer identifiers and receipts

public enum LanSyncTransferID {
    public static func make() -> String {
        UUID().uuidString.lowercased()
    }

    public static func isCanonical(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }
}

public struct LanSyncTransferReceipt: Codable, Sendable, Equatable {
    public var transferID: String
    public var snapshotDigest: Data
    public var receiverDeviceID: String
    public var created: Int
    public var updated: Int
    public var deleted: Int
    public var conflicts: Int
    public var alreadyApplied: Bool
    public var completedAt: Date

    public init(
        transferID: String,
        snapshotDigest: Data,
        receiverDeviceID: String,
        created: Int,
        updated: Int,
        deleted: Int,
        conflicts: Int,
        alreadyApplied: Bool,
        completedAt: Date = Date()
    ) {
        self.transferID = transferID
        self.snapshotDigest = snapshotDigest
        self.receiverDeviceID = receiverDeviceID
        self.created = created
        self.updated = updated
        self.deleted = deleted
        self.conflicts = conflicts
        self.alreadyApplied = alreadyApplied
        self.completedAt = completedAt
    }

    public var summary: LanSyncMergeSummary {
        LanSyncMergeSummary(
            created: created,
            updated: updated,
            deleted: deleted,
            conflicts: conflicts
        )
    }
}

// MARK: - Idempotency ledger

public struct LanSyncTransferRecord: Codable, Sendable, Equatable {
    public var transferID: String
    public var snapshotDigest: Data
    public var receiverDeviceID: String
    public var created: Int
    public var updated: Int
    public var deleted: Int
    public var conflicts: Int
    public var appliedAt: Date

    public init(
        transferID: String,
        snapshotDigest: Data,
        receiverDeviceID: String,
        summary: LanSyncMergeSummary,
        appliedAt: Date = Date()
    ) {
        self.transferID = transferID
        self.snapshotDigest = snapshotDigest
        self.receiverDeviceID = receiverDeviceID
        created = summary.created
        updated = summary.updated
        deleted = summary.deleted
        conflicts = summary.conflicts
        self.appliedAt = appliedAt
    }

    public func receipt(alreadyApplied: Bool) -> LanSyncTransferReceipt {
        LanSyncTransferReceipt(
            transferID: transferID,
            snapshotDigest: snapshotDigest,
            receiverDeviceID: receiverDeviceID,
            created: created,
            updated: updated,
            deleted: deleted,
            conflicts: conflicts,
            alreadyApplied: alreadyApplied,
            completedAt: appliedAt
        )
    }
}

/// Remembers the most recent transfers so a retried transfer (for example after
/// the connection drops before the peer receives the receipt) is not applied
/// twice.
public struct LanSyncTransferLedger: Codable, Sendable, Equatable {
    public static let maxRecords = 32
    public var records: [LanSyncTransferRecord]

    public init(records: [LanSyncTransferRecord] = []) {
        self.records = records
    }

    public func record(forTransferID transferID: String) -> LanSyncTransferRecord? {
        records.first { $0.transferID == transferID }
    }

    /// Returns the previous application of exactly this transfer, or `nil`.
    public func previousApplication(transferID: String, digest: Data) -> LanSyncTransferRecord? {
        guard let existing = record(forTransferID: transferID) else { return nil }
        return LanSyncEncoding.constantTimeEquals(existing.snapshotDigest, digest) ? existing : nil
    }

    public func hasConflictingTransfer(transferID: String, digest: Data) -> Bool {
        guard let existing = record(forTransferID: transferID) else { return false }
        return !LanSyncEncoding.constantTimeEquals(existing.snapshotDigest, digest)
    }

    public mutating func remember(_ record: LanSyncTransferRecord) {
        records.removeAll { $0.transferID == record.transferID }
        records.append(record)
        if records.count > Self.maxRecords {
            records.removeFirst(records.count - Self.maxRecords)
        }
    }
}

// MARK: - Peer records and entry mapping

public struct LanSyncPeerRecord: Codable, Sendable, Equatable {
    public var deviceID: String
    public var displayName: String
    public var signingPublicKey: Data
    public var firstPairedAt: Date
    public var lastSyncedAt: Date?
    public var lastSessionFingerprint: String?

    public init(
        deviceID: String,
        displayName: String,
        signingPublicKey: Data,
        firstPairedAt: Date = Date(),
        lastSyncedAt: Date? = nil,
        lastSessionFingerprint: String? = nil
    ) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.signingPublicKey = signingPublicKey
        self.firstPairedAt = firstPairedAt
        self.lastSyncedAt = lastSyncedAt
        self.lastSessionFingerprint = lastSessionFingerprint
    }
}

/// Maps a local vault entry identifier to the stable sync identifier shared
/// between devices. Local entry identifiers are never sent over the wire.
public struct LanSyncEntryMapping: Codable, Sendable, Equatable {
    public var localEntryID: String
    public var syncID: UUID
    public var kind: LanSyncItemKind
    public var lastKnownContentHash: Data?

    public init(
        localEntryID: String,
        syncID: UUID,
        kind: LanSyncItemKind,
        lastKnownContentHash: Data? = nil
    ) {
        self.localEntryID = localEntryID
        self.syncID = syncID
        self.kind = kind
        self.lastKnownContentHash = lastKnownContentHash
    }
}

// MARK: - Persisted sync state

public struct LanSyncSyncState: Codable, Sendable, Equatable {
    public var formatVersion: Int
    public var localDeviceID: String
    public var localVaultID: String
    public var peers: [String: LanSyncPeerRecord]
    public var bases: [String: LanSyncMergeBase]
    public var mappings: [String: LanSyncEntryMapping]
    public var ledger: LanSyncTransferLedger
    public var updatedAt: Date

    public init(localDeviceID: String, localVaultID: String) {
        formatVersion = LanSyncProtocolSpec.syncStateFormatVersion
        self.localDeviceID = localDeviceID
        self.localVaultID = localVaultID
        peers = [:]
        bases = [:]
        mappings = [:]
        ledger = LanSyncTransferLedger()
        updatedAt = Date()
    }

    public func mapping(forLocalEntryID localEntryID: String) -> LanSyncEntryMapping? {
        mappings[localEntryID]
    }

    public func mapping(forSyncID syncID: UUID) -> LanSyncEntryMapping? {
        mappings.values.first { $0.syncID == syncID }
    }

    public mutating func setMapping(_ mapping: LanSyncEntryMapping) {
        mappings[mapping.localEntryID] = mapping
    }

    public mutating func removeMapping(forLocalEntryID localEntryID: String) {
        mappings[localEntryID] = nil
    }

    public func base(forPeer deviceID: String) -> LanSyncMergeBase? {
        bases[deviceID]
    }

    public mutating func setBase(_ base: LanSyncMergeBase, forPeer deviceID: String) {
        bases[deviceID] = base
    }

    public func peer(_ deviceID: String) -> LanSyncPeerRecord? {
        peers[deviceID]
    }

    public mutating func upsertPeer(_ record: LanSyncPeerRecord) {
        if let existing = peers[record.deviceID] {
            var merged = record
            merged.firstPairedAt = existing.firstPairedAt
            peers[record.deviceID] = merged
        } else {
            peers[record.deviceID] = record
        }
    }

    /// Pinned identity for handshake authentication of a previously paired peer.
    public func expectedPeer(for deviceID: String) -> LanSyncExpectedPeer? {
        guard let peer = peers[deviceID] else { return nil }
        return LanSyncExpectedPeer(
            deviceID: peer.deviceID,
            signingPublicKey: peer.signingPublicKey,
            displayName: peer.displayName
        )
    }

    /// Local-only tombstone bookkeeping for items deleted since the last sync.
    public var knownSyncIDs: Set<UUID> {
        Set(mappings.values.map(\.syncID))
    }
}

// MARK: - Persistence codec

public enum LanSyncSyncStateCodec {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }()

    public static func encode(_ state: LanSyncSyncState) throws -> Data {
        try encoder.encode(state)
    }

    public static func decode(_ data: Data) throws -> LanSyncSyncState {
        let state: LanSyncSyncState
        do {
            state = try JSONDecoder().decode(LanSyncSyncState.self, from: data)
        } catch {
            throw LanSyncStateError.corruptedState
        }
        guard state.formatVersion == LanSyncProtocolSpec.syncStateFormatVersion else {
            throw LanSyncStateError.unsupportedFormatVersion(state.formatVersion)
        }
        return state
    }

    public static func load(from url: URL) throws -> LanSyncSyncState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try decode(Data(contentsOf: url))
        } catch let error as LanSyncStateError {
            throw error
        } catch {
            throw LanSyncStateError.corruptedState
        }
    }

    public static func save(_ state: LanSyncSyncState, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encode(state)
        try data.write(to: url, options: [.atomic])
    }
}

public enum LanSyncStateError: Error, Sendable, Equatable, LocalizedError {
    case corruptedState
    case unsupportedFormatVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .corruptedState:
            "局域网同步状态文件已损坏。可以在设置中重置同步状态后重新配对（不会删除保险库数据）。"
        case .unsupportedFormatVersion:
            "局域网同步状态版本不受支持，请更新 Monica 后重试。"
        }
    }
}
