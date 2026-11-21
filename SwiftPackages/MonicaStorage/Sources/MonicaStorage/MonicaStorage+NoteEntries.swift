// MARK: - 笔记条目（LocalNoteEntry / LocalNoteEntryDraft）

import Foundation
import MonicaMDBX

public struct LocalNoteEntryDraft: Sendable, Equatable {
    public let title: String
    public let body: String

    public let metadata: VaultEntryMetadata

    public init(title: String, body: String, metadata: VaultEntryMetadata = .empty) {
        self.title = title
        self.body = body
        self.metadata = metadata
    }
}

public struct LocalNoteEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let body: String
    public let favorite: Bool
    public let metadata: VaultEntryMetadata

    public init(
        id: String,
        projectID: String,
        title: String,
        body: String,
        favorite: Bool = false,
        metadata: VaultEntryMetadata = .empty
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.body = body
        self.favorite = favorite
        self.metadata = metadata
    }
}

extension LocalVaultEntryRepository {
    public func createNoteEntry(
        projectID: String,
        draft: LocalNoteEntryDraft
    ) throws -> LocalNoteEntry {
        let normalizedDraft = try normalizedNoteEntryDraft(draft)
        return try engine.createNoteEntry(
            in: session.handle,
            projectID: projectID,
            draft: normalizedDraft
        )
    }

    public func listNoteEntries(projectID: String) throws -> [LocalNoteEntry] {
        try engine.listNoteEntries(in: session.handle, projectID: projectID)
    }

    public func updateNoteEntry(
        projectID: String,
        entryID: String,
        draft: LocalNoteEntryDraft
    ) throws -> LocalNoteEntry {
        let normalizedDraft = try normalizedNoteEntryDraft(draft)
        return try engine.updateNoteEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            draft: normalizedDraft
        )
    }

    public func setNoteEntryFavorite(
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalNoteEntry {
        try engine.setNoteEntryFavorite(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
    }

    public func deleteNoteEntry(projectID: String, entryID: String) throws {
        try engine.deleteNoteEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    public func listDeletedNoteEntries(projectID: String) throws -> [LocalNoteEntry] {
        try engine.listDeletedNoteEntries(in: session.handle, projectID: projectID)
    }

    public func restoreNoteEntry(
        projectID: String,
        entryID: String
    ) throws -> LocalNoteEntry {
        try engine.restoreNoteEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    private func normalizedNoteEntryDraft(_ draft: LocalNoteEntryDraft) throws -> LocalNoteEntryDraft {
        let normalizedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw LocalVaultRepositoryError.emptyEntryTitle
        }
        return LocalNoteEntryDraft(title: normalizedTitle, body: draft.body)
    }
}

extension MDBXLocalVaultEngine {
    public func createNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalNoteEntryDraft
    ) throws -> LocalNoteEntry {
        let entry = try vault(for: handle).createNoteEntry(
            projectID: projectID,
            title: draft.title,
            body: draft.body
        )
        return LocalNoteEntry(entry)
    }

    public func listNoteEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalNoteEntry] {
        try vault(for: handle)
            .listNoteEntries(projectID: projectID)
            .map(LocalNoteEntry.init)
    }

    public func updateNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalNoteEntryDraft
    ) throws -> LocalNoteEntry {
        let entry = try vault(for: handle).updateNoteEntry(
            projectID: projectID,
            entryID: entryID,
            title: draft.title,
            body: draft.body
        )
        return LocalNoteEntry(entry)
    }

    public func setNoteEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalNoteEntry {
        let entry = try vault(for: handle).setNoteEntryFavorite(
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
        return LocalNoteEntry(entry)
    }

    public func deleteNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        try vault(for: handle).deleteNoteEntry(projectID: projectID, entryID: entryID)
    }

    public func listDeletedNoteEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalNoteEntry] {
        try vault(for: handle)
            .listDeletedNoteEntries(projectID: projectID)
            .map(LocalNoteEntry.init)
    }

    public func restoreNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalNoteEntry {
        let entry = try vault(for: handle).restoreNoteEntry(
            projectID: projectID,
            entryID: entryID
        )
        return LocalNoteEntry(entry)
    }
}

private extension LocalNoteEntry {
    init(_ entry: MonicaMDBXNoteEntry) {
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            body: entry.body,
            favorite: entry.favorite,
            metadata: VaultEntryMetadata(entry.metadata)
        )
    }
}
