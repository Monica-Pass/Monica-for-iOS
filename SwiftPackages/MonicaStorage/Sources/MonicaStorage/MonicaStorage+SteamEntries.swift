// MARK: - Steam 条目：仓库与 MDBX 引擎实现（类型见 MonicaSteamEntry.swift）

import Foundation
import MonicaMDBX

extension LocalVaultEntryRepository {
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
}

extension MDBXLocalVaultEngine {
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
