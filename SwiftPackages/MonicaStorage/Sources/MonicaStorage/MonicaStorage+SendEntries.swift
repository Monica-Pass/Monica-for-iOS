// MARK: - Send 条目（LocalSendEntry / LocalSendEntryDraft）

import Foundation
import MonicaMDBX

public struct LocalSendEntryDraft: Sendable, Equatable {
    public let title: String
    public let body: String
    public let expiresAt: String
    public let maxViews: Int
    public let notes: String

    public let metadata: VaultEntryMetadata

    public init(
        title: String,
        body: String,
        expiresAt: String,
        maxViews: Int,
        notes: String
    ,
        metadata: VaultEntryMetadata = .empty) {
        self.title = title
        self.body = body
        self.expiresAt = expiresAt
        self.maxViews = maxViews
        self.notes = notes
        self.metadata = metadata
    }
}

public struct LocalSendEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let body: String
    public let expiresAt: String
    public let maxViews: Int
    public let notes: String
    public let favorite: Bool
    public let metadata: VaultEntryMetadata

    public init(
        id: String,
        projectID: String,
        title: String,
        body: String,
        expiresAt: String,
        maxViews: Int,
        notes: String,
        favorite: Bool = false,
        metadata: VaultEntryMetadata = .empty
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.body = body
        self.expiresAt = expiresAt
        self.maxViews = maxViews
        self.notes = notes
        self.favorite = favorite
        self.metadata = metadata
    }
}

extension LocalVaultEntryRepository {
    public func createSendEntry(projectID: String, draft: LocalSendEntryDraft) throws -> LocalSendEntry {
        try engine.createSendEntry(in: session.handle, projectID: projectID, draft: normalizedSendEntryDraft(draft))
    }

    public func listSendEntries(projectID: String) throws -> [LocalSendEntry] {
        try engine.listSendEntries(in: session.handle, projectID: projectID)
    }

    public func updateSendEntry(projectID: String, entryID: String, draft: LocalSendEntryDraft) throws -> LocalSendEntry {
        try engine.updateSendEntry(in: session.handle, projectID: projectID, entryID: entryID, draft: normalizedSendEntryDraft(draft))
    }

    public func setSendEntryFavorite(projectID: String, entryID: String, favorite: Bool) throws -> LocalSendEntry {
        try engine.setSendEntryFavorite(in: session.handle, projectID: projectID, entryID: entryID, favorite: favorite)
    }

    public func deleteSendEntry(projectID: String, entryID: String) throws {
        try engine.deleteSendEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func listDeletedSendEntries(projectID: String) throws -> [LocalSendEntry] {
        try engine.listDeletedSendEntries(in: session.handle, projectID: projectID)
    }

    public func restoreSendEntry(projectID: String, entryID: String) throws -> LocalSendEntry {
        try engine.restoreSendEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    private func normalizedSendEntryDraft(_ draft: LocalSendEntryDraft) throws -> LocalSendEntryDraft {
        let normalizedTitle = try normalizedEntryTitle(draft.title)
        return LocalSendEntryDraft(
            title: normalizedTitle,
            body: draft.body,
            expiresAt: draft.expiresAt,
            maxViews: draft.maxViews,
            notes: draft.notes
        )
    }
}

extension MDBXLocalVaultEngine {
    public func createSendEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalSendEntryDraft) throws -> LocalSendEntry {
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "document-ref",
            kind: "send",
            title: draft.title,
            payload: [
                "body": draft.body,
                "expiresAt": draft.expiresAt,
                "maxViews": draft.maxViews,
                "notes": draft.notes
            ]
        )
        return try LocalSendEntry(entry)
    }

    public func listSendEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSendEntry] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "send").map(LocalSendEntry.init)
    }

    public func updateSendEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalSendEntryDraft) throws -> LocalSendEntry {
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: entryID,
            entryType: "document-ref",
            kind: "send",
            title: draft.title,
            payload: [
                "body": draft.body,
                "expiresAt": draft.expiresAt,
                "maxViews": draft.maxViews,
                "notes": draft.notes
            ]
        )
        return try LocalSendEntry(entry)
    }

    public func setSendEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalSendEntry {
        try LocalSendEntry(setParityEntryFavorite(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "send", favorite: favorite))
    }

    public func deleteSendEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        try deleteParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "send")
    }

    public func listDeletedSendEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSendEntry] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "send").map(LocalSendEntry.init)
    }

    public func restoreSendEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalSendEntry {
        try LocalSendEntry(restoreParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "send"))
    }
}

private extension LocalSendEntry {
    init(_ entry: MonicaMDBXParityEntry) throws {
        let payload = try entry.payloadDictionary()
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            body: payload.string("body"),
            expiresAt: payload.string("expiresAt"),
            maxViews: payload.int("maxViews"),
            notes: payload.string("notes"),
            favorite: entry.favorite,
            metadata: VaultEntryMetadata(entry.metadata)
        )
    }
}
