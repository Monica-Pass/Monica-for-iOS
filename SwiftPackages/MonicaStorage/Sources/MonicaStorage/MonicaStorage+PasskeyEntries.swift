// MARK: - 通行密钥条目（LocalPasskeyEntry / LocalPasskeyEntryDraft）

import Foundation
import MonicaMDBX

public struct LocalPasskeyEntryDraft: Sendable, Equatable {
    public let title: String
    public let relyingPartyID: String
    public let username: String
    public let userHandle: String
    public let credentialID: String
    public let publicKeyCOSE: String
    public let privateKeyReference: String
    public let notes: String

    public let metadata: VaultEntryMetadata

    public init(
        title: String,
        relyingPartyID: String,
        username: String,
        userHandle: String,
        credentialID: String,
        publicKeyCOSE: String,
        privateKeyReference: String,
        notes: String
    ,
        metadata: VaultEntryMetadata = .empty) {
        self.title = title
        self.relyingPartyID = relyingPartyID
        self.username = username
        self.userHandle = userHandle
        self.credentialID = credentialID
        self.publicKeyCOSE = publicKeyCOSE
        self.privateKeyReference = privateKeyReference
        self.notes = notes
        self.metadata = metadata
    }
}

public struct LocalPasskeyEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let relyingPartyID: String
    public let username: String
    public let userHandle: String
    public let credentialID: String
    public let publicKeyCOSE: String
    public let privateKeyReference: String
    public let notes: String
    public let favorite: Bool
    public let metadata: VaultEntryMetadata

    public init(
        id: String,
        projectID: String,
        title: String,
        relyingPartyID: String,
        username: String,
        userHandle: String,
        credentialID: String,
        publicKeyCOSE: String,
        privateKeyReference: String,
        notes: String,
        favorite: Bool = false,
        metadata: VaultEntryMetadata = .empty
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.relyingPartyID = relyingPartyID
        self.username = username
        self.userHandle = userHandle
        self.credentialID = credentialID
        self.publicKeyCOSE = publicKeyCOSE
        self.privateKeyReference = privateKeyReference
        self.notes = notes
        self.favorite = favorite
        self.metadata = metadata
    }
}

extension LocalVaultEntryRepository {
    public func createPasskeyEntry(projectID: String, draft: LocalPasskeyEntryDraft) throws -> LocalPasskeyEntry {
        try engine.createPasskeyEntry(in: session.handle, projectID: projectID, draft: normalizedPasskeyEntryDraft(draft))
    }

    public func listPasskeyEntries(projectID: String) throws -> [LocalPasskeyEntry] {
        try engine.listPasskeyEntries(in: session.handle, projectID: projectID)
    }

    public func updatePasskeyEntry(projectID: String, entryID: String, draft: LocalPasskeyEntryDraft) throws -> LocalPasskeyEntry {
        try engine.updatePasskeyEntry(in: session.handle, projectID: projectID, entryID: entryID, draft: normalizedPasskeyEntryDraft(draft))
    }

    public func setPasskeyEntryFavorite(projectID: String, entryID: String, favorite: Bool) throws -> LocalPasskeyEntry {
        try engine.setPasskeyEntryFavorite(in: session.handle, projectID: projectID, entryID: entryID, favorite: favorite)
    }

    public func deletePasskeyEntry(projectID: String, entryID: String) throws {
        try engine.deletePasskeyEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func listDeletedPasskeyEntries(projectID: String) throws -> [LocalPasskeyEntry] {
        try engine.listDeletedPasskeyEntries(in: session.handle, projectID: projectID)
    }

    public func restorePasskeyEntry(projectID: String, entryID: String) throws -> LocalPasskeyEntry {
        try engine.restorePasskeyEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    private func normalizedPasskeyEntryDraft(_ draft: LocalPasskeyEntryDraft) throws -> LocalPasskeyEntryDraft {
        let normalizedTitle = try normalizedEntryTitle(draft.title)
        return LocalPasskeyEntryDraft(
            title: normalizedTitle,
            relyingPartyID: draft.relyingPartyID,
            username: draft.username,
            userHandle: draft.userHandle,
            credentialID: draft.credentialID,
            publicKeyCOSE: draft.publicKeyCOSE,
            privateKeyReference: draft.privateKeyReference,
            notes: draft.notes
        )
    }
}

extension MDBXLocalVaultEngine {
    public func createPasskeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalPasskeyEntryDraft
    ) throws -> LocalPasskeyEntry {
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "passkey",
            kind: "passkey",
            title: draft.title,
            payload: [
                "relyingPartyID": draft.relyingPartyID,
                "username": draft.username,
                "userHandle": draft.userHandle,
                "credentialID": draft.credentialID,
                "publicKeyCOSE": draft.publicKeyCOSE,
                "privateKeyReference": draft.privateKeyReference,
                "notes": draft.notes
            ]
        )
        return try LocalPasskeyEntry(entry)
    }

    public func listPasskeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalPasskeyEntry] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "passkey", kind: "passkey").map(LocalPasskeyEntry.init)
    }

    public func updatePasskeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalPasskeyEntryDraft) throws -> LocalPasskeyEntry {
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: entryID,
            entryType: "passkey",
            kind: "passkey",
            title: draft.title,
            payload: [
                "relyingPartyID": draft.relyingPartyID,
                "username": draft.username,
                "userHandle": draft.userHandle,
                "credentialID": draft.credentialID,
                "publicKeyCOSE": draft.publicKeyCOSE,
                "privateKeyReference": draft.privateKeyReference,
                "notes": draft.notes
            ]
        )
        return try LocalPasskeyEntry(entry)
    }

    public func setPasskeyEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalPasskeyEntry {
        try LocalPasskeyEntry(setParityEntryFavorite(in: handle, projectID: projectID, entryID: entryID, entryType: "passkey", kind: "passkey", favorite: favorite))
    }

    public func deletePasskeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        try deleteParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "passkey", kind: "passkey")
    }

    public func listDeletedPasskeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalPasskeyEntry] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "passkey", kind: "passkey").map(LocalPasskeyEntry.init)
    }

    public func restorePasskeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalPasskeyEntry {
        try LocalPasskeyEntry(restoreParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "passkey", kind: "passkey"))
    }
}

private extension LocalPasskeyEntry {
    init(_ entry: MonicaMDBXParityEntry) throws {
        let payload = try entry.payloadDictionary()
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            relyingPartyID: payload.string("relyingPartyID"),
            username: payload.string("username"),
            userHandle: payload.string("userHandle"),
            credentialID: payload.string("credentialID"),
            publicKeyCOSE: payload.string("publicKeyCOSE"),
            privateKeyReference: payload.string("privateKeyReference"),
            notes: payload.string("notes"),
            favorite: entry.favorite,
            metadata: VaultEntryMetadata(entry.metadata)
        )
    }
}
