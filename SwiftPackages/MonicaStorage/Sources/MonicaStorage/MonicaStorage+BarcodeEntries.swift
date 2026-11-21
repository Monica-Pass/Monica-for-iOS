// MARK: - 条码条目：仓库与 MDBX 引擎实现（类型见 MonicaBarcodeEntry.swift）

import Foundation
import MonicaMDBX

extension LocalVaultEntryRepository {
    public func createBarcodeEntry(projectID: String, draft: LocalBarcodeEntryDraft) throws -> LocalBarcodeEntry {
        try engine.createBarcodeEntry(in: session.handle, projectID: projectID, draft: normalizedBarcodeEntryDraft(draft))
    }

    public func listBarcodeEntries(projectID: String) throws -> [LocalBarcodeEntry] {
        try engine.listBarcodeEntries(in: session.handle, projectID: projectID)
    }

    public func updateBarcodeEntry(projectID: String, entryID: String, draft: LocalBarcodeEntryDraft) throws -> LocalBarcodeEntry {
        try engine.updateBarcodeEntry(in: session.handle, projectID: projectID, entryID: entryID, draft: normalizedBarcodeEntryDraft(draft))
    }

    public func setBarcodeEntryFavorite(projectID: String, entryID: String, favorite: Bool) throws -> LocalBarcodeEntry {
        try engine.setBarcodeEntryFavorite(in: session.handle, projectID: projectID, entryID: entryID, favorite: favorite)
    }

    public func deleteBarcodeEntry(projectID: String, entryID: String) throws {
        try engine.deleteBarcodeEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func listDeletedBarcodeEntries(projectID: String) throws -> [LocalBarcodeEntry] {
        try engine.listDeletedBarcodeEntries(in: session.handle, projectID: projectID)
    }

    public func restoreBarcodeEntry(projectID: String, entryID: String) throws -> LocalBarcodeEntry {
        try engine.restoreBarcodeEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    private func normalizedBarcodeEntryDraft(_ draft: LocalBarcodeEntryDraft) throws -> LocalBarcodeEntryDraft {
        let normalizedTitle = try normalizedEntryTitle(draft.title)
        let validatedDraft = try draft.validated()
        return LocalBarcodeEntryDraft(
            title: normalizedTitle,
            symbology: validatedDraft.symbology,
            payload: validatedDraft.payload,
            label: draft.label,
            notes: draft.notes
        )
    }
}

extension MDBXLocalVaultEngine {
    public func createBarcodeEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalBarcodeEntryDraft) throws -> LocalBarcodeEntry {
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "document-ref",
            kind: "barcode",
            title: draft.title,
            payload: BarcodeEntryPayloadCodec.encoded(draft)
        )
        return try LocalBarcodeEntry(entry)
    }

    public func listBarcodeEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalBarcodeEntry] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "barcode").map(LocalBarcodeEntry.init)
    }

    public func updateBarcodeEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalBarcodeEntryDraft) throws -> LocalBarcodeEntry {
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: entryID,
            entryType: "document-ref",
            kind: "barcode",
            title: draft.title,
            payload: BarcodeEntryPayloadCodec.encoded(draft)
        )
        return try LocalBarcodeEntry(entry)
    }

    public func setBarcodeEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalBarcodeEntry {
        try LocalBarcodeEntry(setParityEntryFavorite(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "barcode", favorite: favorite))
    }

    public func deleteBarcodeEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        try deleteParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "barcode")
    }

    public func listDeletedBarcodeEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalBarcodeEntry] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "barcode").map(LocalBarcodeEntry.init)
    }

    public func restoreBarcodeEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalBarcodeEntry {
        try LocalBarcodeEntry(restoreParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "barcode"))

    }
}

private extension LocalBarcodeEntry {
    init(_ entry: MonicaMDBXParityEntry) throws {
        let payload = try entry.payloadDictionary()
        self = BarcodeEntryPayloadCodec.decoded(
            payload,
            entryID: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            favorite: entry.favorite
        )
    }
}
