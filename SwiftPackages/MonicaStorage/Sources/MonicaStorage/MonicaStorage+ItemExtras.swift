// MARK: - 条目自定义字段 / 关联条目（item extras）：仓库与 MDBX 引擎实现

import Foundation
import MonicaMDBX

extension LocalVaultEntryRepository {
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
}

extension MDBXLocalVaultEngine {
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

    private func itemExtrasEntry(_ entry: MonicaMDBXParityEntry, matchesItemID itemID: String) -> Bool {
        if let extras = VaultItemExtras(payloadJSON: entry.payloadJSON, fallbackItemID: entry.title) {
            return extras.itemID == itemID
        }
        return entry.title == itemID
    }
}
