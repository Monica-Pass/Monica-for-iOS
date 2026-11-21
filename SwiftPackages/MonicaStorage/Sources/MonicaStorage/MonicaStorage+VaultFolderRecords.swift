// MARK: - 文件夹记录侧表：MDBX 引擎实现（Domain 逻辑见 VaultFolderHierarchy.swift）

import Foundation
import MonicaMDBX

extension MDBXLocalVaultEngine {
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

    private func vaultFolderEntry(_ entry: MonicaMDBXParityEntry, matchesFolderID folderID: String) -> Bool {
        if let record = VaultFolderRecord(payloadJSON: entry.payloadJSON, fallbackFolderID: entry.title) {
            return record.folderID == folderID
        }
        return entry.title == folderID
    }
}
