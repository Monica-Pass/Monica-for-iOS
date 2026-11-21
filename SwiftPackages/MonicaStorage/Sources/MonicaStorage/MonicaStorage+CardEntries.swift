// MARK: - 卡片条目（LocalCardEntry / LocalCardEntryDraft）

import Foundation
import MonicaMDBX

public struct LocalCardEntryDraft: Sendable, Equatable {
    public let title: String
    public let cardholderName: String
    public let number: String
    public let expiryMonth: String
    public let expiryYear: String
    public let cvv: String
    public let issuer: String
    public let network: String
    /// #17 可选扩展字段；旧库/旧备份缺失时取空串。
    public let iban: String
    public let swiftCode: String
    public let billingAddress: String
    public let cardArtwork: String
    public let notes: String

    public let metadata: VaultEntryMetadata

    public init(
        title: String,
        cardholderName: String,
        number: String,
        expiryMonth: String,
        expiryYear: String,
        cvv: String,
        issuer: String,
        network: String,
        iban: String = "",
        swiftCode: String = "",
        billingAddress: String = "",
        cardArtwork: String = "",
        notes: String
    ,
        metadata: VaultEntryMetadata = .empty) {
        self.title = title
        self.cardholderName = cardholderName
        self.number = number
        self.expiryMonth = expiryMonth
        self.expiryYear = expiryYear
        self.cvv = cvv
        self.issuer = issuer
        self.network = network
        self.iban = iban
        self.swiftCode = swiftCode
        self.billingAddress = billingAddress
        self.cardArtwork = cardArtwork
        self.notes = notes
        self.metadata = metadata
    }
}

public struct LocalCardEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let cardholderName: String
    public let number: String
    public let expiryMonth: String
    public let expiryYear: String
    public let cvv: String
    public let issuer: String
    public let network: String
    /// #17 可选扩展字段；旧库/旧备份缺失时取空串。
    public let iban: String
    public let swiftCode: String
    public let billingAddress: String
    public let cardArtwork: String
    public let notes: String
    public let favorite: Bool
    public let metadata: VaultEntryMetadata

    public init(
        id: String,
        projectID: String,
        title: String,
        cardholderName: String,
        number: String,
        expiryMonth: String,
        expiryYear: String,
        cvv: String,
        issuer: String,
        network: String,
        iban: String = "",
        swiftCode: String = "",
        billingAddress: String = "",
        cardArtwork: String = "",
        notes: String,
        favorite: Bool = false,
        metadata: VaultEntryMetadata = .empty
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.cardholderName = cardholderName
        self.number = number
        self.expiryMonth = expiryMonth
        self.expiryYear = expiryYear
        self.cvv = cvv
        self.issuer = issuer
        self.network = network
        self.iban = iban
        self.swiftCode = swiftCode
        self.billingAddress = billingAddress
        self.cardArtwork = cardArtwork
        self.notes = notes
        self.favorite = favorite
        self.metadata = metadata
    }
}

extension LocalVaultEntryRepository {
    public func createCardEntry(
        projectID: String,
        draft: LocalCardEntryDraft
    ) throws -> LocalCardEntry {
        let normalizedDraft = try normalizedCardEntryDraft(draft)
        return try engine.createCardEntry(
            in: session.handle,
            projectID: projectID,
            draft: normalizedDraft
        )
    }

    public func listCardEntries(projectID: String) throws -> [LocalCardEntry] {
        try engine.listCardEntries(in: session.handle, projectID: projectID)
    }

    public func updateCardEntry(
        projectID: String,
        entryID: String,
        draft: LocalCardEntryDraft
    ) throws -> LocalCardEntry {
        let normalizedDraft = try normalizedCardEntryDraft(draft)
        return try engine.updateCardEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            draft: normalizedDraft
        )
    }

    public func setCardEntryFavorite(
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalCardEntry {
        try engine.setCardEntryFavorite(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
    }

    public func deleteCardEntry(projectID: String, entryID: String) throws {
        try engine.deleteCardEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    public func listDeletedCardEntries(projectID: String) throws -> [LocalCardEntry] {
        try engine.listDeletedCardEntries(in: session.handle, projectID: projectID)
    }

    public func restoreCardEntry(
        projectID: String,
        entryID: String
    ) throws -> LocalCardEntry {
        try engine.restoreCardEntry(
            in: session.handle,
            projectID: projectID,
            entryID: entryID
        )
    }

    private func normalizedCardEntryDraft(_ draft: LocalCardEntryDraft) throws -> LocalCardEntryDraft {
        let normalizedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw LocalVaultRepositoryError.emptyEntryTitle
        }
        return LocalCardEntryDraft(
            title: normalizedTitle,
            cardholderName: draft.cardholderName,
            number: draft.number,
            expiryMonth: draft.expiryMonth,
            expiryYear: draft.expiryYear,
            cvv: draft.cvv,
            issuer: draft.issuer,
            network: draft.network,
            iban: draft.iban,
            swiftCode: draft.swiftCode,
            billingAddress: draft.billingAddress,
            cardArtwork: draft.cardArtwork,
            notes: draft.notes
        )
    }
}

extension MDBXLocalVaultEngine {
    public func createCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalCardEntryDraft
    ) throws -> LocalCardEntry {
        let entry = try vault(for: handle).createCardEntry(
            projectID: projectID,
            title: draft.title,
            cardholderName: draft.cardholderName,
            number: draft.number,
            expiryMonth: draft.expiryMonth,
            expiryYear: draft.expiryYear,
            cvv: draft.cvv,
            issuer: draft.issuer,
            network: draft.network,
            iban: draft.iban,
            swiftCode: draft.swiftCode,
            billingAddress: draft.billingAddress,
            cardArtwork: draft.cardArtwork,
            notes: draft.notes
        )
        return LocalCardEntry(entry)
    }

    public func listCardEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalCardEntry] {
        try vault(for: handle)
            .listCardEntries(projectID: projectID)
            .map(LocalCardEntry.init)
    }

    public func updateCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalCardEntryDraft
    ) throws -> LocalCardEntry {
        let entry = try vault(for: handle).updateCardEntry(
            projectID: projectID,
            entryID: entryID,
            title: draft.title,
            cardholderName: draft.cardholderName,
            number: draft.number,
            expiryMonth: draft.expiryMonth,
            expiryYear: draft.expiryYear,
            cvv: draft.cvv,
            issuer: draft.issuer,
            network: draft.network,
            iban: draft.iban,
            swiftCode: draft.swiftCode,
            billingAddress: draft.billingAddress,
            cardArtwork: draft.cardArtwork,
            notes: draft.notes
        )
        return LocalCardEntry(entry)
    }

    public func setCardEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalCardEntry {
        let entry = try vault(for: handle).setCardEntryFavorite(
            projectID: projectID,
            entryID: entryID,
            favorite: favorite
        )
        return LocalCardEntry(entry)
    }

    public func deleteCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        try vault(for: handle).deleteCardEntry(projectID: projectID, entryID: entryID)
    }

    public func listDeletedCardEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalCardEntry] {
        try vault(for: handle)
            .listDeletedCardEntries(projectID: projectID)
            .map(LocalCardEntry.init)
    }

    public func restoreCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalCardEntry {
        let entry = try vault(for: handle).restoreCardEntry(
            projectID: projectID,
            entryID: entryID
        )
        return LocalCardEntry(entry)
    }
}

private extension LocalCardEntry {
    init(_ entry: MonicaMDBXCardEntry) {
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            cardholderName: entry.cardholderName,
            number: entry.number,
            expiryMonth: entry.expiryMonth,
            expiryYear: entry.expiryYear,
            cvv: entry.cvv,
            issuer: entry.issuer,
            network: entry.network,
            iban: entry.iban,
            swiftCode: entry.swiftCode,
            billingAddress: entry.billingAddress,
            cardArtwork: entry.cardArtwork,
            notes: entry.notes,
            favorite: entry.favorite,
            metadata: VaultEntryMetadata(entry.metadata)
        )
    }
}
