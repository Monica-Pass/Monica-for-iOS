// MARK: - 身份（Identity）条目：类型、仓库与 MDBX 引擎实现

import Foundation
import MonicaMDBX

public struct LocalIdentityEntryDraft: Sendable, Equatable {
    public let title: String
    public let documentType: String
    public let fullName: String
    public let documentNumber: String
    public let issuer: String
    public let country: String
    public let issueDate: String
    public let expiryDate: String
    public let notes: String

    public let metadata: VaultEntryMetadata

    public init(
        title: String,
        documentType: String,
        fullName: String,
        documentNumber: String,
        issuer: String,
        country: String,
        issueDate: String,
        expiryDate: String,
        notes: String
    ,
        metadata: VaultEntryMetadata = .empty) {
        self.title = title
        self.documentType = documentType
        self.fullName = fullName
        self.documentNumber = documentNumber
        self.issuer = issuer
        self.country = country
        self.issueDate = issueDate
        self.expiryDate = expiryDate
        self.notes = notes
        self.metadata = metadata
    }
}

public struct LocalIdentityEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let documentType: String
    public let fullName: String
    public let documentNumber: String
    public let issuer: String
    public let country: String
    public let issueDate: String
    public let expiryDate: String
    public let notes: String
    public let favorite: Bool
    public let metadata: VaultEntryMetadata

    public init(
        id: String,
        projectID: String,
        title: String,
        documentType: String,
        fullName: String,
        documentNumber: String,
        issuer: String,
        country: String,
        issueDate: String,
        expiryDate: String,
        notes: String,
        favorite: Bool = false,
        metadata: VaultEntryMetadata = .empty
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.documentType = documentType
        self.fullName = fullName
        self.documentNumber = documentNumber
        self.issuer = issuer
        self.country = country
        self.issueDate = issueDate
        self.expiryDate = expiryDate
        self.notes = notes
        self.favorite = favorite
        self.metadata = metadata
    }
}

extension LocalVaultEntryRepository {
    public func createIdentityEntry(
        projectID: String,
        draft: LocalIdentityEntryDraft
    ) throws -> LocalIdentityEntry {
        let normalizedDraft = try normalizedIdentityEntryDraft(draft)
        return try engine.createIdentityEntry(
            in: session.handle,
            projectID: projectID,
            draft: normalizedDraft
        )
    }

    public func listIdentityEntries(projectID: String) throws -> [LocalIdentityEntry] {
        try engine.listIdentityEntries(in: session.handle, projectID: projectID)
    }

    public func updateIdentityEntry(
        projectID: String,
        entryID: String,
        draft: LocalIdentityEntryDraft
    ) throws -> LocalIdentityEntry {
        let normalizedDraft = try normalizedIdentityEntryDraft(draft)
        return try engine.updateIdentityEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            draft: normalizedDraft
        )
    }

    public func setIdentityEntryFavorite(
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalIdentityEntry {
        try engine.setIdentityEntryFavorite(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
    }

    public func deleteIdentityEntry(projectID: String, entryID: String) throws {
        try engine.deleteIdentityEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    public func listDeletedIdentityEntries(projectID: String) throws -> [LocalIdentityEntry] {
        try engine.listDeletedIdentityEntries(in: session.handle, projectID: projectID)
    }

    public func restoreIdentityEntry(
        projectID: String,
        entryID: String
    ) throws -> LocalIdentityEntry {
        try engine.restoreIdentityEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    private func normalizedIdentityEntryDraft(_ draft: LocalIdentityEntryDraft) throws -> LocalIdentityEntryDraft {
        let normalizedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw LocalVaultRepositoryError.emptyEntryTitle
        }
        return LocalIdentityEntryDraft(
            title: normalizedTitle,
            documentType: draft.documentType,
            fullName: draft.fullName,
            documentNumber: draft.documentNumber,
            issuer: draft.issuer,
            country: draft.country,
            issueDate: draft.issueDate,
            expiryDate: draft.expiryDate,
            notes: draft.notes
        )
    }
}

extension MDBXLocalVaultEngine {
    public func createIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalIdentityEntryDraft
    ) throws -> LocalIdentityEntry {
        let entry = try vault(for: handle).createIdentityEntry(
            projectID: projectID,
            title: draft.title,
            documentType: draft.documentType,
            fullName: draft.fullName,
            documentNumber: draft.documentNumber,
            issuer: draft.issuer,
            country: draft.country,
            issueDate: draft.issueDate,
            expiryDate: draft.expiryDate,
            notes: draft.notes
        )
        return LocalIdentityEntry(entry)
    }

    public func listIdentityEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalIdentityEntry] {
        try vault(for: handle)
            .listIdentityEntries(projectID: projectID)
            .map(LocalIdentityEntry.init)
    }

    public func updateIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalIdentityEntryDraft
    ) throws -> LocalIdentityEntry {
        let entry = try vault(for: handle).updateIdentityEntry(
            projectID: projectID,
            entryID: entryID,
            title: draft.title,
            documentType: draft.documentType,
            fullName: draft.fullName,
            documentNumber: draft.documentNumber,
            issuer: draft.issuer,
            country: draft.country,
            issueDate: draft.issueDate,
            expiryDate: draft.expiryDate,
            notes: draft.notes
        )
        return LocalIdentityEntry(entry)
    }

    public func setIdentityEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalIdentityEntry {
        let entry = try vault(for: handle).setIdentityEntryFavorite(
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
        return LocalIdentityEntry(entry)
    }

    public func deleteIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        try vault(for: handle).deleteIdentityEntry(projectID: projectID, entryID: entryID)
    }

    public func listDeletedIdentityEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalIdentityEntry] {
        try vault(for: handle)
            .listDeletedIdentityEntries(projectID: projectID)
            .map(LocalIdentityEntry.init)
    }

    public func restoreIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalIdentityEntry {
        let entry = try vault(for: handle).restoreIdentityEntry(
            projectID: projectID,
            entryID: entryID
        )
        return LocalIdentityEntry(entry)
    }
}

private extension LocalIdentityEntry {
    init(_ entry: MonicaMDBXIdentityEntry) {
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            documentType: entry.documentType,
            fullName: entry.fullName,
            documentNumber: entry.documentNumber,
            issuer: entry.issuer,
            country: entry.country,
            issueDate: entry.issueDate,
            expiryDate: entry.expiryDate,
            notes: entry.notes,
            favorite: entry.favorite,
            metadata: VaultEntryMetadata(entry.metadata)
        )
    }
}
