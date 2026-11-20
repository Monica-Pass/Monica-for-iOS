import Foundation

// MARK: - Merge base

public struct LanSyncMergeBaseItem: Codable, Sendable, Equatable {
    public var contentHash: Data
    public var localEntryID: String?
    public var kind: LanSyncItemKind

    public init(contentHash: Data, localEntryID: String?, kind: LanSyncItemKind) {
        self.contentHash = contentHash
        self.localEntryID = localEntryID
        self.kind = kind
    }
}

public struct LanSyncMergeBaseTombstone: Codable, Sendable, Equatable {
    public var deletedAt: Date
    public var lastContentHash: Data?

    public init(deletedAt: Date, lastContentHash: Data?) {
        self.deletedAt = deletedAt
        self.lastContentHash = lastContentHash
    }
}

/// Per-peer record of the last content both devices are known to share. This is
/// the "common ancestor" of the three-way merge. Dictionary keys are canonical
/// uppercase UUID strings.
public struct LanSyncMergeBase: Codable, Sendable, Equatable {
    public var formatVersion: Int
    public var peerDeviceID: String
    public var lastSyncedAt: Date
    public var syncedItems: [String: LanSyncMergeBaseItem]
    public var syncedTombstones: [String: LanSyncMergeBaseTombstone]

    public init(
        peerDeviceID: String,
        lastSyncedAt: Date = Date(),
        syncedItems: [String: LanSyncMergeBaseItem] = [:],
        syncedTombstones: [String: LanSyncMergeBaseTombstone] = [:]
    ) {
        formatVersion = LanSyncProtocolSpec.syncStateFormatVersion
        self.peerDeviceID = peerDeviceID
        self.lastSyncedAt = lastSyncedAt
        self.syncedItems = syncedItems
        self.syncedTombstones = syncedTombstones
    }

    public func item(for syncID: UUID) -> LanSyncMergeBaseItem? {
        syncedItems[SyncKey.key(for: syncID)]
    }

    public func tombstone(for syncID: UUID) -> LanSyncMergeBaseTombstone? {
        syncedTombstones[SyncKey.key(for: syncID)]
    }

    public mutating func setItem(_ item: LanSyncMergeBaseItem, for syncID: UUID) {
        syncedItems[SyncKey.key(for: syncID)] = item
        syncedTombstones[SyncKey.key(for: syncID)] = nil
    }

    public mutating func setTombstone(_ tombstone: LanSyncMergeBaseTombstone, for syncID: UUID) {
        syncedTombstones[SyncKey.key(for: syncID)] = tombstone
        syncedItems[SyncKey.key(for: syncID)] = nil
    }

    public mutating func removeRecord(for syncID: UUID) {
        syncedItems[SyncKey.key(for: syncID)] = nil
        syncedTombstones[SyncKey.key(for: syncID)] = nil
    }

    /// Records the local vault identifier created for a freshly synced item.
    public mutating func recordLocalEntryID(_ localEntryID: String, for syncID: UUID) {
        let key = SyncKey.key(for: syncID)
        guard var item = syncedItems[key] else { return }
        item.localEntryID = localEntryID
        syncedItems[key] = item
    }

    /// True when the peer is known to have the same content as `item`.
    public func isSynchronized(_ item: LanSyncItem, localEntryID: String?) -> Bool {
        guard let base = self.item(for: item.syncID) else { return false }
        return LanSyncEncoding.constantTimeEquals(base.contentHash, item.contentHash)
            && (localEntryID == nil || base.localEntryID == nil || base.localEntryID == localEntryID)
    }
}

enum SyncKey {
    static func key(for syncID: UUID) -> String {
        syncID.uuidString
    }

    static func uuid(_ key: String) -> UUID? {
        UUID(uuidString: key)
    }
}

// MARK: - Merge outputs

public enum LanSyncMergeAction: Sendable, Equatable {
    case create(item: LanSyncItem)
    case update(item: LanSyncItem, localEntryID: String)
    case delete(syncID: UUID, localEntryID: String)

    public var ordersBeforeDeletes: Int {
        switch self {
        case .create, .update: 0
        case .delete: 1
        }
    }
}

public enum LanSyncMergeConflictReason: String, Codable, Sendable, Equatable {
    case bothModified
    case remoteDeletedLocalModified
    case localDeletedRemoteModified
    case divergentItem
    case remoteMissingItem
    case localEntryMissing

    public var localizedSummary: String {
        switch self {
        case .bothModified:
            "两台设备都修改了这一项，已保留本机版本，请在两端确认后手动合并。"
        case .remoteDeletedLocalModified:
            "对方已删除这一项，但本机在删除后修改过它，已保留本机版本。"
        case .localDeletedRemoteModified:
            "本机已删除这一项，但对方修改过它，已保持删除状态。"
        case .divergentItem:
            "这一项在两端的来源不一致，已保留本机数据，请人工核对。"
        case .remoteMissingItem:
            "本机有条目在对方库中不存在，已保留本机版本。"
        case .localEntryMissing:
            "本机条目在同步过程中丢失，已保留对方版本而不自动重建，请检查本机保险库。"
        }
    }
}

public struct LanSyncMergeConflict: Sendable, Equatable {
    public var syncID: UUID
    public var kind: LanSyncItemKind
    public var title: String
    public var localEntryID: String?
    public var reason: LanSyncMergeConflictReason
    public var localContentHash: Data?
    public var remoteContentHash: Data?

    public init(
        syncID: UUID,
        kind: LanSyncItemKind,
        title: String,
        localEntryID: String?,
        reason: LanSyncMergeConflictReason,
        localContentHash: Data?,
        remoteContentHash: Data?
    ) {
        self.syncID = syncID
        self.kind = kind
        self.title = title
        self.localEntryID = localEntryID
        self.reason = reason
        self.localContentHash = localContentHash
        self.remoteContentHash = remoteContentHash
    }
}

public struct LanSyncMergeSummary: Sendable, Equatable {
    public var created = 0
    public var updated = 0
    public var deleted = 0
    public var conflicts = 0

    public var totalApplied: Int { created + updated + deleted }
}

public struct LanSyncMergeResult: Sendable {
    public var actions: [LanSyncMergeAction]
    public var conflicts: [LanSyncMergeConflict]
    public var base: LanSyncMergeBase

    public var summary: LanSyncMergeSummary {
        var summary = LanSyncMergeSummary()
        for action in actions {
            switch action {
            case .create: summary.created += 1
            case .update: summary.updated += 1
            case .delete: summary.deleted += 1
            }
        }
        summary.conflicts = conflicts.count
        return summary
    }

    public init(actions: [LanSyncMergeAction], conflicts: [LanSyncMergeConflict], base: LanSyncMergeBase) {
        self.actions = actions
        self.conflicts = conflicts
        self.base = base
    }
}

// MARK: - Merge engine

/// Deterministic three-way merge between an incoming snapshot and the local
/// vault. The engine never deletes or overwrites data that changed locally since
/// the last successful sync; such cases surface as conflicts instead.
public struct LanSyncMergeEngine: Sendable {
    public init() {}

    public func merge(
        remote: LanSyncVaultSnapshot,
        localItems: [LanSyncLocalItem],
        localTombstones: [LanSyncTombstone],
        base: LanSyncMergeBase?,
        now: Date = Date()
    ) -> LanSyncMergeResult {
        let effectiveBase = base?.peerDeviceID == remote.senderDeviceID ? base : nil

        let remoteItems = Dictionary(
            remote.items.map { (SyncKey.key(for: $0.syncID), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let remoteTombstones = Dictionary(
            remote.tombstones.map { (SyncKey.key(for: $0.syncID), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let localItemsByKey = Dictionary(
            localItems.map { (SyncKey.key(for: $0.syncID), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let localTombstonesByKey = Dictionary(
            localTombstones.map { (SyncKey.key(for: $0.syncID), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var allKeys = Set<String>()
        allKeys.formUnion(remoteItems.keys)
        allKeys.formUnion(remoteTombstones.keys)
        allKeys.formUnion(localItemsByKey.keys)
        allKeys.formUnion(localTombstonesByKey.keys)
        if let effectiveBase {
            allKeys.formUnion(effectiveBase.syncedItems.keys)
            allKeys.formUnion(effectiveBase.syncedTombstones.keys)
        }

        var result = LanSyncMergeResult(
            actions: [],
            conflicts: [],
            base: LanSyncMergeBase(peerDeviceID: remote.senderDeviceID, lastSyncedAt: now)
        )
        let newBasePeerID = remote.senderDeviceID
        // Work on a mutable base builder that already carries the peer identity.
        var builder = traitMergeBaseBuilder(peerDeviceID: newBasePeerID, now: now)

        for key in allKeys.sorted() {
            guard let syncID = SyncKey.uuid(key) else { continue }
            let remoteItem = remoteItems[key]
            let remoteTombstone = remoteTombstones[key]
            let localItem = localItemsByKey[key]
            let localTombstone = localTombstonesByKey[key]
            let baseItem = effectiveBase?.syncedItems[key]
            let baseTombstone = effectiveBase?.syncedTombstones[key]

            if let remoteItem {
                handleRemoteItem(
                    remoteItem: remoteItem,
                    localItem: localItem,
                    localTombstone: localTombstone,
                    baseItem: baseItem,
                    baseTombstone: baseTombstone,
                    syncID: syncID,
                    actions: &result.actions,
                    conflicts: &result.conflicts,
                    builder: &builder
                )
            } else if let remoteTombstone {
                handleRemoteTombstone(
                    remoteTombstone: remoteTombstone,
                    localItem: localItem,
                    localTombstone: localTombstone,
                    baseItem: baseItem,
                    baseTombstone: baseTombstone,
                    syncID: syncID,
                    actions: &result.actions,
                    conflicts: &result.conflicts,
                    builder: &builder
                )
            } else {
                handleAbsentRemotely(
                    localItem: localItem,
                    localTombstone: localTombstone,
                    baseItem: baseItem,
                    baseTombstone: baseTombstone,
                    syncID: syncID,
                    conflicts: &result.conflicts,
                    builder: &builder
                )
            }
        }

        result.base = builder
        return result
    }

    // MARK: - Case handlers

    private func handleRemoteItem(
        remoteItem: LanSyncItem,
        localItem: LanSyncLocalItem?,
        localTombstone: LanSyncTombstone?,
        baseItem: LanSyncMergeBaseItem?,
        baseTombstone: LanSyncMergeBaseTombstone?,
        syncID: UUID,
        actions: inout [LanSyncMergeAction],
        conflicts: inout [LanSyncMergeConflict],
        builder: inout LanSyncMergeBase
    ) {
        let remoteHash = remoteItem.contentHash

        if let localItem {
            let localHash = localItem.contentHash
            if let baseItem {
                let remoteChanged = !LanSyncEncoding.constantTimeEquals(remoteHash, baseItem.contentHash)
                let localChanged = !LanSyncEncoding.constantTimeEquals(localHash, baseItem.contentHash)

                if !remoteChanged {
                    // Peer unchanged; keep local edits (they will be sent later).
                    builder.setItem(
                        LanSyncMergeBaseItem(
                            contentHash: baseItem.contentHash,
                            localEntryID: localItem.localEntryID,
                            kind: baseItem.kind
                        ),
                        for: syncID
                    )
                } else if !localChanged {
                    actions.append(.update(item: remoteItem, localEntryID: localItem.localEntryID))
                    builder.setItem(
                        LanSyncMergeBaseItem(
                            contentHash: remoteHash,
                            localEntryID: localItem.localEntryID,
                            kind: remoteItem.kind
                        ),
                        for: syncID
                    )
                } else if LanSyncEncoding.constantTimeEquals(remoteHash, localHash) {
                    builder.setItem(
                        LanSyncMergeBaseItem(
                            contentHash: remoteHash,
                            localEntryID: localItem.localEntryID,
                            kind: remoteItem.kind
                        ),
                        for: syncID
                    )
                } else {
                    conflicts.append(
                        conflict(
                            remoteItem,
                            localEntryID: localItem.localEntryID,
                            reason: .bothModified,
                            localHash: localHash
                        )
                    )
                    builder.setItem(baseItem, for: syncID)
                }
                return
            }

            if baseTombstone != nil {
                // Both sides had previously agreed the item was deleted, but the
                // peer resurrected it; never silently re-add deleted data.
                conflicts.append(
                    conflict(
                        remoteItem,
                        localEntryID: localItem.localEntryID,
                        reason: .divergentItem,
                        localHash: localHash
                    )
                )
                builder.setTombstone(baseTombstone!, for: syncID)
                return
            }

            if LanSyncEncoding.constantTimeEquals(remoteHash, localHash) {
                builder.setItem(
                    LanSyncMergeBaseItem(
                        contentHash: remoteHash,
                        localEntryID: localItem.localEntryID,
                        kind: remoteItem.kind
                    ),
                    for: syncID
                )
            } else {
                conflicts.append(
                    conflict(
                        remoteItem,
                        localEntryID: localItem.localEntryID,
                        reason: .divergentItem,
                        localHash: localHash
                    )
                )
            }
            return
        }

        if let localTombstone {
            // Local deletion must win over an unchanged peer item. The tombstone
            // keeps being advertised until the peer acknowledges the deletion.
            if let baseItem,
               !LanSyncEncoding.constantTimeEquals(remoteHash, baseItem.contentHash)
            {
                conflicts.append(
                    conflict(
                        remoteItem,
                        localEntryID: nil,
                        reason: .localDeletedRemoteModified,
                        localHash: nil
                    )
                )
                builder.setItem(baseItem, for: syncID)
            } else if let baseItem {
                builder.setItem(baseItem, for: syncID)
            } else if LanSyncEncoding.constantTimeEquals(
                remoteHash,
                localTombstone.deletedContentHash ?? Data()
            ) {
                // Same content the user deleted; safe to keep deletion.
                builder.setTombstone(
                    LanSyncMergeBaseTombstone(
                        deletedAt: localTombstone.deletedAt,
                        lastContentHash: remoteHash
                    ),
                    for: syncID
                )
            } else if baseTombstone == nil {
                conflicts.append(
                    conflict(
                        remoteItem,
                        localEntryID: nil,
                        reason: .divergentItem,
                        localHash: nil
                    )
                )
            }
            return
        }

        // No local item and no local tombstone.
        if let baseTombstone {
            // Peer resurrected an item both sides had deleted.
            conflicts.append(
                conflict(remoteItem, localEntryID: nil, reason: .divergentItem, localHash: nil)
            )
            builder.setTombstone(baseTombstone, for: syncID)
            return
        }
        if let baseItem {
            // The local vault lost the entry without recording a deletion.
            conflicts.append(
                conflict(
                    remoteItem,
                    localEntryID: baseItem.localEntryID,
                    reason: .localEntryMissing,
                    localHash: nil
                )
            )
            builder.setItem(baseItem, for: syncID)
            return
        }

        actions.append(.create(item: remoteItem))
        builder.setItem(
            LanSyncMergeBaseItem(
                contentHash: remoteHash,
                localEntryID: nil,
                kind: remoteItem.kind
            ),
            for: syncID
        )
    }

    private func handleRemoteTombstone(
        remoteTombstone: LanSyncTombstone,
        localItem: LanSyncLocalItem?,
        localTombstone: LanSyncTombstone?,
        baseItem: LanSyncMergeBaseItem?,
        baseTombstone: LanSyncMergeBaseTombstone?,
        syncID: UUID,
        actions: inout [LanSyncMergeAction],
        conflicts: inout [LanSyncMergeConflict],
        builder: inout LanSyncMergeBase
    ) {
        if let localItem {
            let localHash = localItem.contentHash
            if let baseItem {
                let localChanged = !LanSyncEncoding.constantTimeEquals(localHash, baseItem.contentHash)
                if localChanged {
                    conflicts.append(
                        conflict(
                            nil,
                            syncID: syncID,
                            kind: localItem.item.kind,
                            title: localItem.item.title,
                            localEntryID: localItem.localEntryID,
                            reason: .remoteDeletedLocalModified,
                            localHash: localHash,
                            remoteHash: remoteTombstone.deletedContentHash
                        )
                    )
                    builder.setItem(baseItem, for: syncID)
                } else {
                    actions.append(.delete(syncID: syncID, localEntryID: localItem.localEntryID))
                    builder.setTombstone(
                        LanSyncMergeBaseTombstone(
                            deletedAt: remoteTombstone.deletedAt,
                            lastContentHash: baseItem.contentHash
                        ),
                        for: syncID
                    )
                }
                return
            }

            if baseTombstone != nil {
                conflicts.append(
                    conflict(
                        nil,
                        syncID: syncID,
                        kind: localItem.item.kind,
                        title: localItem.item.title,
                        localEntryID: localItem.localEntryID,
                        reason: .divergentItem,
                        localHash: localHash,
                        remoteHash: remoteTombstone.deletedContentHash
                    )
                )
                builder.setTombstone(baseTombstone!, for: syncID)
                return
            }

            if let deletedHash = remoteTombstone.deletedContentHash,
               LanSyncEncoding.constantTimeEquals(deletedHash, localHash)
            {
                actions.append(.delete(syncID: syncID, localEntryID: localItem.localEntryID))
                builder.setTombstone(
                    LanSyncMergeBaseTombstone(
                        deletedAt: remoteTombstone.deletedAt,
                        lastContentHash: localHash
                    ),
                    for: syncID
                )
            } else {
                conflicts.append(
                    conflict(
                        nil,
                        syncID: syncID,
                        kind: localItem.item.kind,
                        title: localItem.item.title,
                        localEntryID: localItem.localEntryID,
                        reason: .divergentItem,
                        localHash: localHash,
                        remoteHash: remoteTombstone.deletedContentHash
                    )
                )
            }
            return
        }

        let deletedAt = earliest(remoteTombstone.deletedAt, localTombstone?.deletedAt)
        let lastHash = remoteTombstone.deletedContentHash
            ?? baseItem?.contentHash
            ?? localTombstone?.deletedContentHash
        builder.setTombstone(
            LanSyncMergeBaseTombstone(deletedAt: deletedAt, lastContentHash: lastHash),
            for: syncID
        )
    }

    private func handleAbsentRemotely(
        localItem: LanSyncLocalItem?,
        localTombstone: LanSyncTombstone?,
        baseItem: LanSyncMergeBaseItem?,
        baseTombstone: LanSyncMergeBaseTombstone?,
        syncID: UUID,
        conflicts: inout [LanSyncMergeConflict],
        builder: inout LanSyncMergeBase
    ) {
        if let localItem {
            if baseItem != nil {
                conflicts.append(
                    conflict(
                        nil,
                        syncID: syncID,
                        kind: localItem.item.kind,
                        title: localItem.item.title,
                        localEntryID: localItem.localEntryID,
                        reason: .remoteMissingItem,
                        localHash: localItem.contentHash,
                        remoteHash: nil
                    )
                )
                builder.setItem(baseItem!, for: syncID)
            } else if baseTombstone != nil {
                conflicts.append(
                    conflict(
                        nil,
                        syncID: syncID,
                        kind: localItem.item.kind,
                        title: localItem.item.title,
                        localEntryID: localItem.localEntryID,
                        reason: .divergentItem,
                        localHash: localItem.contentHash,
                        remoteHash: nil
                    )
                )
                builder.setTombstone(baseTombstone!, for: syncID)
            }
            // Otherwise the item has simply never been exchanged; keep it.
            return
        }

        if let localTombstone {
            builder.setTombstone(
                LanSyncMergeBaseTombstone(
                    deletedAt: localTombstone.deletedAt,
                    lastContentHash: localTombstone.deletedContentHash ?? baseItem?.contentHash
                ),
                for: syncID
            )
        }
        // If neither side has the item, nothing to do.
    }

    // MARK: - Helpers

    private func traitMergeBaseBuilder(peerDeviceID: String, now: Date) -> LanSyncMergeBase {
        LanSyncMergeBase(peerDeviceID: peerDeviceID, lastSyncedAt: now)
    }

    private func conflict(
        _ remoteItem: LanSyncItem,
        localEntryID: String?,
        reason: LanSyncMergeConflictReason,
        localHash: Data?
    ) -> LanSyncMergeConflict {
        conflict(
            remoteItem,
            syncID: remoteItem.syncID,
            kind: remoteItem.kind,
            title: remoteItem.title,
            localEntryID: localEntryID,
            reason: reason,
            localHash: localHash,
            remoteHash: remoteItem.contentHash
        )
    }

    private func conflict(
        _ remoteItem: LanSyncItem?,
        syncID: UUID,
        kind: LanSyncItemKind,
        title: String,
        localEntryID: String?,
        reason: LanSyncMergeConflictReason,
        localHash: Data?,
        remoteHash: Data?
    ) -> LanSyncMergeConflict {
        LanSyncMergeConflict(
            syncID: syncID,
            kind: kind,
            title: title,
            localEntryID: localEntryID,
            reason: reason,
            localContentHash: localHash,
            remoteContentHash: remoteHash
        )
    }

    private func earliest(_ lhs: Date, _ rhs: Date?) -> Date {
        guard let rhs else { return lhs }
        return min(lhs, rhs)
    }
}
