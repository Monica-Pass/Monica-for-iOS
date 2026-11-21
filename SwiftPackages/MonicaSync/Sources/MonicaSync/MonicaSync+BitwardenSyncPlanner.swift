// MARK: - Bitwarden 同步计划（条目 / Send 的本地-远端比对）

import Foundation

public struct BitwardenSendSyncPlan: Sendable, Equatable {
    public let mutations: [BitwardenSyncMutation]
    public let conflicts: [BitwardenSyncConflict]
    public let updatedStates: [String: BitwardenSendSyncState]

    public init(
        mutations: [BitwardenSyncMutation],
        conflicts: [BitwardenSyncConflict],
        updatedStates: [String: BitwardenSendSyncState]
    ) {
        self.mutations = mutations
        self.conflicts = conflicts
        self.updatedStates = updatedStates
    }
}

public struct BitwardenItemSyncPlan: Sendable, Equatable {
    public let mutations: [BitwardenSyncMutation]
    public let conflicts: [BitwardenSyncConflict]
    public let updatedStates: [String: BitwardenItemSyncState]

    public init(
        mutations: [BitwardenSyncMutation],
        conflicts: [BitwardenSyncConflict],
        updatedStates: [String: BitwardenItemSyncState]
    ) {
        self.mutations = mutations
        self.conflicts = conflicts
        self.updatedStates = updatedStates
    }
}

public struct BitwardenItemSyncPlanner: Sendable {
    public init() {}

    public func plan(
        localItems: [BitwardenLocalItemSyncItem],
        deletedLocalItems: [BitwardenLocalItemSyncItem],
        remoteItems: [BitwardenSyncItem],
        previousStates: [BitwardenItemSyncState]
    ) -> BitwardenItemSyncPlan {
        let statesByLocalID = Dictionary(uniqueKeysWithValues: previousStates.map { ($0.localID, $0) })
        let remoteByID = Dictionary(uniqueKeysWithValues: remoteItems.map { ($0.remoteID, $0) })
        let localIDs = Set(localItems.map(\.localID))
        var mutations: [BitwardenSyncMutation] = []
        var conflicts: [BitwardenSyncConflict] = []
        var updatedStates = statesByLocalID

        for item in localItems {
            let state = statesByLocalID[item.localID]
            let fingerprint = item.syncFingerprint
            let remoteItem = remoteByID[state?.remoteID ?? ""]
            if let remoteID = state?.remoteID,
               remoteByID[remoteID] == nil,
               fingerprint != state?.lastSyncedFingerprint {
                conflicts.append(
                    BitwardenSyncConflict(
                        localID: item.localID,
                        remoteID: remoteID,
                        title: item.title,
                        reason: .remoteDeleted
                    )
                )
                continue
            }

            if state?.isDeleted == true,
               remoteItem?.deletedAt != nil {
                mutations.append(
                    .restoreCipher(
                        localID: item.localID,
                        remoteID: state?.remoteID,
                        kind: state?.kind ?? item.kind,
                        title: item.title
                    )
                )
                if fingerprint != state?.lastSyncedFingerprint {
                    mutations.append(.upsertCipher(item: item, remoteID: state?.remoteID))
                }
                updatedStates[item.localID] = BitwardenItemSyncState(
                    localID: item.localID,
                    remoteID: state?.remoteID,
                    kind: item.kind,
                    lastSyncedFingerprint: fingerprint,
                    lastRemoteRevision: remoteItem?.updatedAt.map { String($0.timeIntervalSince1970) } ?? state?.lastRemoteRevision,
                    isDeleted: false
                )
                continue
            }

            if state?.isDeleted == true || fingerprint != state?.lastSyncedFingerprint {
                mutations.append(.upsertCipher(item: item, remoteID: state?.remoteID))
                updatedStates[item.localID] = BitwardenItemSyncState(
                    localID: item.localID,
                    remoteID: state?.remoteID,
                    kind: item.kind,
                    lastSyncedFingerprint: fingerprint,
                    lastRemoteRevision: remoteItem?.updatedAt.map { String($0.timeIntervalSince1970) } ?? state?.lastRemoteRevision,
                    isDeleted: false
                )
            }
        }

        for item in deletedLocalItems {
            guard let state = statesByLocalID[item.localID] else {
                continue
            }
            mutations.append(
                .deleteCipher(
                    localID: item.localID,
                    remoteID: state.remoteID,
                    kind: state.kind,
                    title: item.title
                )
            )
            updatedStates[item.localID] = BitwardenItemSyncState(
                localID: item.localID,
                remoteID: state.remoteID,
                kind: state.kind,
                lastSyncedFingerprint: item.syncFingerprint,
                lastRemoteRevision: state.lastRemoteRevision,
                isDeleted: true
            )
        }

        for state in previousStates where !localIDs.contains(state.localID) && !state.isDeleted {
            guard let remoteID = state.remoteID,
                  remoteByID[remoteID] == nil,
                  !deletedLocalItems.contains(where: { $0.localID == state.localID })
            else {
                continue
            }
            updatedStates[state.localID] = BitwardenItemSyncState(
                localID: state.localID,
                remoteID: state.remoteID,
                kind: state.kind,
                lastSyncedFingerprint: state.lastSyncedFingerprint,
                lastRemoteRevision: state.lastRemoteRevision,
                isDeleted: true
            )
        }

        return BitwardenItemSyncPlan(
            mutations: mutations,
            conflicts: conflicts,
            updatedStates: updatedStates
        )
    }
}

public struct BitwardenSendSyncPlanner: Sendable {
    public init() {}

    public func plan(
        localSends: [BitwardenLocalSendSyncItem],
        deletedLocalSends: [BitwardenLocalSendSyncItem],
        remoteSends: [BitwardenSendSyncItem],
        previousStates: [BitwardenSendSyncState]
    ) -> BitwardenSendSyncPlan {
        let statesByLocalID = Dictionary(uniqueKeysWithValues: previousStates.map { ($0.localID, $0) })
        let remoteByID = Dictionary(uniqueKeysWithValues: remoteSends.map { ($0.remoteID, $0) })
        var mutations: [BitwardenSyncMutation] = []
        var conflicts: [BitwardenSyncConflict] = []
        var updatedStates = statesByLocalID
        let localIDs = Set(localSends.map(\.localID))

        for item in localSends {
            let state = statesByLocalID[item.localID]
            let fingerprint = item.syncFingerprint
            if let remoteID = state?.remoteID,
               remoteByID[remoteID] == nil,
               fingerprint != state?.lastSyncedFingerprint {
                conflicts.append(
                    BitwardenSyncConflict(
                        localID: item.localID,
                        remoteID: remoteID,
                        title: item.title,
                        reason: .remoteDeleted
                    )
                )
                continue
            }

            if state?.isDeleted == true || fingerprint != state?.lastSyncedFingerprint {
                mutations.append(
                    .upsertSend(
                        localID: item.localID,
                        remoteID: state?.remoteID,
                        title: item.title,
                        body: item.body,
                        notes: item.notes,
                        expiresAt: item.expiresAt,
                        maxViews: item.maxViews
                    )
                )
                updatedStates[item.localID] = BitwardenSendSyncState(
                    localID: item.localID,
                    remoteID: state?.remoteID,
                    lastSyncedFingerprint: fingerprint,
                    lastRemoteRevision: remoteByID[state?.remoteID ?? ""]?.updatedAt.map { String($0.timeIntervalSince1970) } ?? state?.lastRemoteRevision,
                    isDeleted: false
                )
            }
        }

        for item in deletedLocalSends {
            guard let state = statesByLocalID[item.localID] else {
                continue
            }
            mutations.append(
                .deleteSend(
                    localID: item.localID,
                    remoteID: state.remoteID,
                    title: item.title
                )
            )
            updatedStates[item.localID] = BitwardenSendSyncState(
                localID: item.localID,
                remoteID: state.remoteID,
                lastSyncedFingerprint: item.syncFingerprint,
                lastRemoteRevision: state.lastRemoteRevision,
                isDeleted: true
            )
        }

        for state in previousStates where !localIDs.contains(state.localID) && !state.isDeleted {
            guard let remoteID = state.remoteID,
                  remoteByID[remoteID] == nil,
                  !deletedLocalSends.contains(where: { $0.localID == state.localID })
            else {
                continue
            }
            updatedStates[state.localID] = BitwardenSendSyncState(
                localID: state.localID,
                remoteID: state.remoteID,
                lastSyncedFingerprint: state.lastSyncedFingerprint,
                lastRemoteRevision: state.lastRemoteRevision,
                isDeleted: true
            )
        }

        return BitwardenSendSyncPlan(
            mutations: mutations,
            conflicts: conflicts,
            updatedStates: updatedStates
        )
    }
}
