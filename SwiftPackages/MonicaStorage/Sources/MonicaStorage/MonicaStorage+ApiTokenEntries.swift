// MARK: - API Token 条目：类型、仓库与 MDBX 引擎实现

import Foundation
import MonicaMDBX

public struct LocalApiTokenEntryDraft: Sendable, Equatable {
    public let title: String
    public let issuer: String
    public let accountName: String
    public let token: String
    public let scopes: String
    public let expiresAt: String
    public let notes: String

    public let metadata: VaultEntryMetadata

    public init(
        title: String,
        issuer: String,
        accountName: String,
        token: String,
        scopes: String,
        expiresAt: String,
        notes: String
    ,
        metadata: VaultEntryMetadata = .empty) {
        self.title = title
        self.issuer = issuer
        self.accountName = accountName
        self.token = token
        self.scopes = scopes
        self.expiresAt = expiresAt
        self.notes = notes
        self.metadata = metadata
    }
}

public struct LocalApiTokenEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let issuer: String
    public let accountName: String
    public let token: String
    public let scopes: String
    public let expiresAt: String
    public let notes: String
    public let favorite: Bool
    public let metadata: VaultEntryMetadata

    public init(
        id: String,
        projectID: String,
        title: String,
        issuer: String,
        accountName: String,
        token: String,
        scopes: String,
        expiresAt: String,
        notes: String,
        favorite: Bool = false,
        metadata: VaultEntryMetadata = .empty
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.issuer = issuer
        self.accountName = accountName
        self.token = token
        self.scopes = scopes
        self.expiresAt = expiresAt
        self.notes = notes
        self.favorite = favorite
        self.metadata = metadata
    }
}

extension LocalVaultEntryRepository {
    public func createApiTokenEntry(projectID: String, draft: LocalApiTokenEntryDraft) throws -> LocalApiTokenEntry {
        try engine.createApiTokenEntry(in: session.handle, projectID: projectID, draft: normalizedApiTokenEntryDraft(draft))
    }

    public func listApiTokenEntries(projectID: String) throws -> [LocalApiTokenEntry] {
        try engine.listApiTokenEntries(in: session.handle, projectID: projectID)
    }

    public func updateApiTokenEntry(projectID: String, entryID: String, draft: LocalApiTokenEntryDraft) throws -> LocalApiTokenEntry {
        try engine.updateApiTokenEntry(in: session.handle, projectID: projectID, entryID: entryID, draft: normalizedApiTokenEntryDraft(draft))
    }

    public func setApiTokenEntryFavorite(projectID: String, entryID: String, favorite: Bool) throws -> LocalApiTokenEntry {
        try engine.setApiTokenEntryFavorite(in: session.handle, projectID: projectID, entryID: entryID, favorite: favorite)
    }

    public func deleteApiTokenEntry(projectID: String, entryID: String) throws {
        try engine.deleteApiTokenEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func listDeletedApiTokenEntries(projectID: String) throws -> [LocalApiTokenEntry] {
        try engine.listDeletedApiTokenEntries(in: session.handle, projectID: projectID)
    }

    public func restoreApiTokenEntry(projectID: String, entryID: String) throws -> LocalApiTokenEntry {
        try engine.restoreApiTokenEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    private func normalizedApiTokenEntryDraft(_ draft: LocalApiTokenEntryDraft) throws -> LocalApiTokenEntryDraft {
        let normalizedTitle = try normalizedEntryTitle(draft.title)
        return LocalApiTokenEntryDraft(
            title: normalizedTitle,
            issuer: draft.issuer,
            accountName: draft.accountName,
            token: draft.token,
            scopes: draft.scopes,
            expiresAt: draft.expiresAt,
            notes: draft.notes
        )
    }
}

extension MDBXLocalVaultEngine {
    public func createApiTokenEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalApiTokenEntryDraft) throws -> LocalApiTokenEntry {
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "api-token",
            kind: "api-token",
            title: draft.title,
            payload: [
                "issuer": draft.issuer,
                "accountName": draft.accountName,
                "token": draft.token,
                "scopes": draft.scopes,
                "expiresAt": draft.expiresAt,
                "notes": draft.notes
            ]
        )
        return try LocalApiTokenEntry(entry)
    }

    public func listApiTokenEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalApiTokenEntry] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "api-token", kind: "api-token").map(LocalApiTokenEntry.init)
    }

    public func updateApiTokenEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalApiTokenEntryDraft) throws -> LocalApiTokenEntry {
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: entryID,
            entryType: "api-token",
            kind: "api-token",
            title: draft.title,
            payload: [
                "issuer": draft.issuer,
                "accountName": draft.accountName,
                "token": draft.token,
                "scopes": draft.scopes,
                "expiresAt": draft.expiresAt,
                "notes": draft.notes
            ]
        )
        return try LocalApiTokenEntry(entry)
    }

    public func setApiTokenEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalApiTokenEntry {
        try LocalApiTokenEntry(setParityEntryFavorite(in: handle, projectID: projectID, entryID: entryID, entryType: "api-token", kind: "api-token", favorite: favorite))
    }

    public func deleteApiTokenEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        try deleteParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "api-token", kind: "api-token")
    }

    public func listDeletedApiTokenEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalApiTokenEntry] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "api-token", kind: "api-token").map(LocalApiTokenEntry.init)
    }

    public func restoreApiTokenEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalApiTokenEntry {
        try LocalApiTokenEntry(restoreParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "api-token", kind: "api-token"))
    }
}

private extension LocalApiTokenEntry {
    init(_ entry: MonicaMDBXParityEntry) throws {
        let payload = try entry.payloadDictionary()
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            issuer: payload.string("issuer"),
            accountName: payload.string("accountName"),
            token: payload.string("token"),
            scopes: payload.string("scopes"),
            expiresAt: payload.string("expiresAt"),
            notes: payload.string("notes"),
            favorite: entry.favorite,
            metadata: VaultEntryMetadata(entry.metadata)
        )
    }
}
