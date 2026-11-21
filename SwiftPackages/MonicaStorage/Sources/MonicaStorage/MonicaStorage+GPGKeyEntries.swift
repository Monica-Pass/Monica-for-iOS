// MARK: - GPG 密钥条目：仓库与 MDBX 引擎实现（类型见 GPGKeyEntry.swift）

import Foundation
import MonicaMDBX

extension LocalVaultEntryRepository {
    public func createGPGKeyEntry(projectID: String, draft: LocalGPGKeyEntryDraft) throws -> LocalGPGKeyEntry {
        try engine.createGPGKeyEntry(in: session.handle, projectID: projectID, draft: normalizedGPGKeyEntryDraft(draft))
    }

    public func listGPGKeyEntries(projectID: String) throws -> [LocalGPGKeyEntry] {
        try engine.listGPGKeyEntries(in: session.handle, projectID: projectID)
    }

    public func updateGPGKeyEntry(projectID: String, entryID: String, draft: LocalGPGKeyEntryDraft) throws -> LocalGPGKeyEntry {
        try engine.updateGPGKeyEntry(in: session.handle, projectID: projectID, entryID: entryID, draft: normalizedGPGKeyEntryDraft(draft))
    }

    public func setGPGKeyEntryFavorite(projectID: String, entryID: String, favorite: Bool) throws -> LocalGPGKeyEntry {
        try engine.setGPGKeyEntryFavorite(in: session.handle, projectID: projectID, entryID: entryID, favorite: favorite)
    }

    public func deleteGPGKeyEntry(projectID: String, entryID: String) throws {
        try engine.deleteGPGKeyEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func listDeletedGPGKeyEntries(projectID: String) throws -> [LocalGPGKeyEntry] {
        try engine.listDeletedGPGKeyEntries(in: session.handle, projectID: projectID)
    }

    public func restoreGPGKeyEntry(projectID: String, entryID: String) throws -> LocalGPGKeyEntry {
        try engine.restoreGPGKeyEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    private func normalizedGPGKeyEntryDraft(_ draft: LocalGPGKeyEntryDraft) throws -> LocalGPGKeyEntryDraft {
        let normalizedTitle = try normalizedEntryTitle(draft.title)
        let publicKey = draft.armoredPublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let privateKey = draft.armoredPrivateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // 没有密钥材料就没有可展示/可复制的指纹，拒绝写入半成品条目。
        // 只导入私钥块时公钥可以为空：私钥块本身已包含公钥 packet，指纹也来自它。
        guard !publicKey.isEmpty || !privateKey.isEmpty, !draft.metadata.fingerprint.isEmpty else {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        return LocalGPGKeyEntryDraft(
            title: normalizedTitle,
            notes: draft.notes,
            armoredPublicKey: publicKey,
            armoredPrivateKey: privateKey,
            metadata: draft.metadata,
            importedAt: draft.importedAt
        )
    }
}

extension MDBXLocalVaultEngine {
    public func createGPGKeyEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalGPGKeyEntryDraft) throws -> LocalGPGKeyEntry {
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "document-ref",
            kind: "gpg-key",
            title: draft.title,
            payload: draft.parityPayload
        )
        return try LocalGPGKeyEntry(entry)
    }

    public func listGPGKeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalGPGKeyEntry] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "gpg-key").map(LocalGPGKeyEntry.init)
    }

    public func updateGPGKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalGPGKeyEntryDraft) throws -> LocalGPGKeyEntry {
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: entryID,
            entryType: "document-ref",
            kind: "gpg-key",
            title: draft.title,
            payload: draft.parityPayload
        )
        return try LocalGPGKeyEntry(entry)
    }

    public func setGPGKeyEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalGPGKeyEntry {
        try LocalGPGKeyEntry(setParityEntryFavorite(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "gpg-key", favorite: favorite))
    }

    public func deleteGPGKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        try deleteParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "gpg-key")
    }

    public func listDeletedGPGKeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalGPGKeyEntry] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "gpg-key").map(LocalGPGKeyEntry.init)
    }

    public func restoreGPGKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalGPGKeyEntry {
        try LocalGPGKeyEntry(restoreParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "gpg-key"))
    }
}

private extension LocalGPGKeyEntry {
    init(_ entry: MonicaMDBXParityEntry) throws {
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            favorite: entry.favorite,
            payload: try entry.payloadDictionary()
        )
    }
}

extension LocalGPGKeyEntry {
    /// 从 parity payload 还原条目（storage 内部与编解码测试共用）。
    ///
    /// 键名统一走 `GPGKeyPayload`，避免写入侧与读取侧字段漂移；
    /// `keyExpiresAt` 用 0 表示「无过期时间」，因为 JSON 不能存 nil。
    init(id: String, projectID: String, title: String, favorite: Bool, payload: [String: Any]) {
        let expiresAt = payload.int64(GPGKeyPayload.keyExpiresAt)
        self.init(
            id: id,
            projectID: projectID,
            title: title,
            ownerName: payload.string(GPGKeyPayload.ownerName),
            ownerEmail: payload.string(GPGKeyPayload.ownerEmail),
            userID: payload.string(GPGKeyPayload.userID),
            fingerprint: payload.string(GPGKeyPayload.fingerprint),
            keyID: payload.string(GPGKeyPayload.keyID),
            algorithm: payload.string(GPGKeyPayload.algorithm),
            keyVersion: payload.int(GPGKeyPayload.keyVersion),
            algorithmID: UInt8(truncatingIfNeeded: payload.int64(GPGKeyPayload.algorithmID)),
            keyCreatedAt: Date(timeIntervalSince1970: TimeInterval(payload.int64(GPGKeyPayload.keyCreatedAt))),
            keyExpiresAt: expiresAt > 0 ? Date(timeIntervalSince1970: TimeInterval(expiresAt)) : nil,
            isRevoked: payload.bool(GPGKeyPayload.isRevoked),
            isSecretKey: payload.bool(GPGKeyPayload.isSecretKey),
            secretKeyIsEncrypted: payload.bool(GPGKeyPayload.secretKeyIsEncrypted),
            notes: payload.string(GPGKeyPayload.notes),
            armoredPublicKey: payload.string(GPGKeyPayload.armoredPublicKey),
            armoredPrivateKey: payload.string(GPGKeyPayload.armoredPrivateKey),
            importedAt: Date(timeIntervalSince1970: TimeInterval(payload.int64(GPGKeyPayload.importedAt))),
            favorite: favorite
        )
    }
}
