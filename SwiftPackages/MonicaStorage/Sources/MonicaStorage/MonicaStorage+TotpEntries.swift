// MARK: - 验证码条目（LocalTotpEntry / LocalTotpEntryDraft）

import Foundation
import MonicaMDBX

public struct LocalTotpEntryDraft: Sendable, Equatable {
    public let title: String
    public let secret: String
    public let issuer: String
    public let accountName: String
    public let period: UInt32
    public let digits: UInt32
    public let algorithm: String
    public let otpType: String
    public let counter: UInt64
    public let iconName: String

    public let metadata: VaultEntryMetadata

    public init(
        title: String,
        secret: String,
        issuer: String,
        accountName: String,
        period: UInt32,
        digits: UInt32,
        algorithm: String,
        otpType: String,
        counter: UInt64,
        iconName: String = "",
        metadata: VaultEntryMetadata = .empty
    ) {
        self.title = title
        self.secret = secret
        self.issuer = issuer
        self.accountName = accountName
        self.period = period
        self.digits = digits
        self.algorithm = algorithm
        self.otpType = otpType
        self.counter = counter
        self.iconName = iconName
        self.metadata = metadata
    }
}

public struct LocalTotpEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let secret: String
    public let issuer: String
    public let accountName: String
    public let period: UInt32
    public let digits: UInt32
    public let algorithm: String
    public let otpType: String
    public let counter: UInt64
    public let favorite: Bool
    public let iconName: String
    public let metadata: VaultEntryMetadata

    public init(
        id: String,
        projectID: String,
        title: String,
        secret: String,
        issuer: String,
        accountName: String,
        period: UInt32,
        digits: UInt32,
        algorithm: String,
        otpType: String,
        counter: UInt64,
        favorite: Bool = false,
        iconName: String = "",
        metadata: VaultEntryMetadata = .empty
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.secret = secret
        self.issuer = issuer
        self.accountName = accountName
        self.period = period
        self.digits = digits
        self.algorithm = algorithm
        self.otpType = otpType
        self.counter = counter
        self.favorite = favorite
        self.iconName = iconName
        self.metadata = metadata
    }
}

extension LocalVaultEntryRepository {
    public func createTotpEntry(
        projectID: String,
        draft: LocalTotpEntryDraft
    ) throws -> LocalTotpEntry {
        let normalizedDraft = try normalizedTotpEntryDraft(draft)
        return try engine.createTotpEntry(
            in: session.handle,
            projectID: projectID,
            draft: normalizedDraft
        )
    }

    public func listTotpEntries(projectID: String) throws -> [LocalTotpEntry] {
        try engine.listTotpEntries(in: session.handle, projectID: projectID)
    }

    public func updateTotpEntry(
        projectID: String,
        entryID: String,
        draft: LocalTotpEntryDraft
    ) throws -> LocalTotpEntry {
        let normalizedDraft = try normalizedTotpEntryDraft(draft)
        return try engine.updateTotpEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            draft: normalizedDraft
        )
    }

    public func setTotpEntryFavorite(
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalTotpEntry {
        try engine.setTotpEntryFavorite(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
    }

    public func deleteTotpEntry(projectID: String, entryID: String) throws {
        try engine.deleteTotpEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    public func listDeletedTotpEntries(projectID: String) throws -> [LocalTotpEntry] {
        try engine.listDeletedTotpEntries(in: session.handle, projectID: projectID)
    }

    public func restoreTotpEntry(
        projectID: String,
        entryID: String
    ) throws -> LocalTotpEntry {
        try engine.restoreTotpEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    private func normalizedTotpEntryDraft(_ draft: LocalTotpEntryDraft) throws -> LocalTotpEntryDraft {
        let normalizedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw LocalVaultRepositoryError.emptyEntryTitle
        }
        return LocalTotpEntryDraft(
            title: normalizedTitle,
            secret: draft.secret,
            issuer: draft.issuer,
            accountName: draft.accountName,
            period: draft.period,
            digits: draft.digits,
            algorithm: draft.algorithm,
            otpType: draft.otpType,
            counter: draft.counter,
            iconName: draft.iconName.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

extension MDBXLocalVaultEngine {
    public func createTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalTotpEntryDraft
    ) throws -> LocalTotpEntry {
        let entry = try vault(for: handle).createTotpEntry(
            projectID: projectID,
            title: draft.title,
            secret: draft.secret,
            issuer: draft.issuer,
            accountName: draft.accountName,
            period: draft.period,
            digits: draft.digits,
            algorithm: draft.algorithm,
            otpType: draft.otpType,
            counter: draft.counter,
            iconName: draft.iconName
        )
        return LocalTotpEntry(entry)
    }

    public func listTotpEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalTotpEntry] {
        try vault(for: handle)
            .listTotpEntries(projectID: projectID)
            .map(LocalTotpEntry.init)
    }

    public func updateTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalTotpEntryDraft
    ) throws -> LocalTotpEntry {
        let entry = try vault(for: handle).updateTotpEntry(
            projectID: projectID,
            entryID: entryID,
            title: draft.title,
            secret: draft.secret,
            issuer: draft.issuer,
            accountName: draft.accountName,
            period: draft.period,
            digits: draft.digits,
            algorithm: draft.algorithm,
            otpType: draft.otpType,
            counter: draft.counter,
            iconName: draft.iconName
        )
        return LocalTotpEntry(entry)
    }

    public func setTotpEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalTotpEntry {
        let entry = try vault(for: handle).setTotpEntryFavorite(
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
        return LocalTotpEntry(entry)
    }

    public func deleteTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        try vault(for: handle).deleteTotpEntry(projectID: projectID, entryID: entryID)
    }

    public func listDeletedTotpEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalTotpEntry] {
        try vault(for: handle)
            .listDeletedTotpEntries(projectID: projectID)
            .map(LocalTotpEntry.init)
    }

    public func restoreTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalTotpEntry {
        let entry = try vault(for: handle).restoreTotpEntry(
            projectID: projectID,
            entryID: entryID
        )
        return LocalTotpEntry(entry)
    }
}

private extension LocalTotpEntry {
    init(_ entry: MonicaMDBXTotpEntry) {
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            secret: entry.secret,
            issuer: entry.issuer,
            accountName: entry.accountName,
            period: entry.period,
            digits: entry.digits,
            algorithm: entry.algorithm,
            otpType: entry.otpType,
            counter: entry.counter,
            favorite: entry.favorite,
            iconName: entry.iconName,
            metadata: VaultEntryMetadata(entry.metadata)
        )
    }
}
