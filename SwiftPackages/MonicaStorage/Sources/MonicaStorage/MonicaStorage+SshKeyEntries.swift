// MARK: - SSH 密钥条目：类型、仓库与 MDBX 引擎实现

import Foundation
import MonicaMDBX

public struct LocalSshKeyEntryDraft: Sendable, Equatable {
    public let title: String
    public let username: String
    public let host: String
    public let publicKey: String
    public let privateKeyReference: String
    public let passphraseHint: String
    public let notes: String
    /// 生成器写入的算法（`ED25519` / `RSA`，与 Android `MonicaSshAlgorithm` 一致）；手工条目为空。
    public let algorithm: String
    /// 生成器写入的位数（256 / 2048 / 3072 / 4096）；手工条目为 0。
    public let keySize: Int
    /// 生成器写入的 `SHA256:...` 指纹；手工条目为空。
    public let fingerprint: String

    public let metadata: VaultEntryMetadata

    public init(
        title: String,
        username: String,
        host: String,
        publicKey: String,
        privateKeyReference: String,
        passphraseHint: String,
        notes: String,
        algorithm: String = "",
        keySize: Int = 0,
        fingerprint: String = "",
        metadata: VaultEntryMetadata = .empty) {
        self.title = title
        self.username = username
        self.host = host
        self.publicKey = publicKey
        self.privateKeyReference = privateKeyReference
        self.passphraseHint = passphraseHint
        self.notes = notes
        self.algorithm = algorithm
        self.keySize = keySize
        self.fingerprint = fingerprint
        self.metadata = metadata
    }
}

public struct LocalSshKeyEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let username: String
    public let host: String
    public let publicKey: String
    public let privateKeyReference: String
    public let passphraseHint: String
    public let notes: String
    public let algorithm: String
    public let keySize: Int
    public let fingerprint: String
    public let favorite: Bool
    public let metadata: VaultEntryMetadata

    public init(
        id: String,
        projectID: String,
        title: String,
        username: String,
        host: String,
        publicKey: String,
        privateKeyReference: String,
        passphraseHint: String,
        notes: String,
        algorithm: String = "",
        keySize: Int = 0,
        fingerprint: String = "",
        favorite: Bool = false,
        metadata: VaultEntryMetadata = .empty
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.username = username
        self.host = host
        self.publicKey = publicKey
        self.privateKeyReference = privateKeyReference
        self.passphraseHint = passphraseHint
        self.notes = notes
        self.algorithm = algorithm
        self.keySize = keySize
        self.fingerprint = fingerprint
        self.favorite = favorite
        self.metadata = metadata
    }
}

extension LocalVaultEntryRepository {
    public func createSshKeyEntry(projectID: String, draft: LocalSshKeyEntryDraft) throws -> LocalSshKeyEntry {
        try engine.createSshKeyEntry(in: session.handle, projectID: projectID, draft: normalizedSshKeyEntryDraft(draft))
    }

    public func listSshKeyEntries(projectID: String) throws -> [LocalSshKeyEntry] {
        try engine.listSshKeyEntries(in: session.handle, projectID: projectID)
    }

    public func updateSshKeyEntry(projectID: String, entryID: String, draft: LocalSshKeyEntryDraft) throws -> LocalSshKeyEntry {
        try engine.updateSshKeyEntry(in: session.handle, projectID: projectID, entryID: entryID, draft: normalizedSshKeyEntryDraft(draft))
    }

    public func setSshKeyEntryFavorite(projectID: String, entryID: String, favorite: Bool) throws -> LocalSshKeyEntry {
        try engine.setSshKeyEntryFavorite(in: session.handle, projectID: projectID, entryID: entryID, favorite: favorite)
    }

    public func deleteSshKeyEntry(projectID: String, entryID: String) throws {
        try engine.deleteSshKeyEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func listDeletedSshKeyEntries(projectID: String) throws -> [LocalSshKeyEntry] {
        try engine.listDeletedSshKeyEntries(in: session.handle, projectID: projectID)
    }

    public func restoreSshKeyEntry(projectID: String, entryID: String) throws -> LocalSshKeyEntry {
        try engine.restoreSshKeyEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    private func normalizedSshKeyEntryDraft(_ draft: LocalSshKeyEntryDraft) throws -> LocalSshKeyEntryDraft {
        let normalizedTitle = try normalizedEntryTitle(draft.title)
        return LocalSshKeyEntryDraft(
            title: normalizedTitle,
            username: draft.username,
            host: draft.host,
            publicKey: draft.publicKey,
            privateKeyReference: draft.privateKeyReference,
            passphraseHint: draft.passphraseHint,
            notes: draft.notes,
            algorithm: draft.algorithm,
            keySize: draft.keySize,
            fingerprint: draft.fingerprint
        )
    }
}

extension MDBXLocalVaultEngine {
    public func createSshKeyEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalSshKeyEntryDraft) throws -> LocalSshKeyEntry {
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "ssh-key",
            kind: "ssh-key",
            title: draft.title,
            payload: [
                "username": draft.username,
                "host": draft.host,
                "publicKey": draft.publicKey,
                "privateKeyReference": draft.privateKeyReference,
                "passphraseHint": draft.passphraseHint,
                "notes": draft.notes,
                "algorithm": draft.algorithm,
                "keySize": draft.keySize > 0 ? String(draft.keySize) : "",
                "fingerprint": draft.fingerprint
            ]
        )
        return try LocalSshKeyEntry(entry)
    }

    public func listSshKeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSshKeyEntry] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "ssh-key", kind: "ssh-key").map(LocalSshKeyEntry.init)
    }

    public func updateSshKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalSshKeyEntryDraft) throws -> LocalSshKeyEntry {
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: entryID,
            entryType: "ssh-key",
            kind: "ssh-key",
            title: draft.title,
            payload: [
                "username": draft.username,
                "host": draft.host,
                "publicKey": draft.publicKey,
                "privateKeyReference": draft.privateKeyReference,
                "passphraseHint": draft.passphraseHint,
                "notes": draft.notes,
                "algorithm": draft.algorithm,
                "keySize": draft.keySize > 0 ? String(draft.keySize) : "",
                "fingerprint": draft.fingerprint
            ]
        )
        return try LocalSshKeyEntry(entry)
    }

    public func setSshKeyEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalSshKeyEntry {
        try LocalSshKeyEntry(setParityEntryFavorite(in: handle, projectID: projectID, entryID: entryID, entryType: "ssh-key", kind: "ssh-key", favorite: favorite))
    }

    public func deleteSshKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        try deleteParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "ssh-key", kind: "ssh-key")
    }

    public func listDeletedSshKeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSshKeyEntry] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "ssh-key", kind: "ssh-key").map(LocalSshKeyEntry.init)
    }

    public func restoreSshKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalSshKeyEntry {
        try LocalSshKeyEntry(restoreParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "ssh-key", kind: "ssh-key"))
    }
}

private extension LocalSshKeyEntry {
    init(_ entry: MonicaMDBXParityEntry) throws {
        let payload = try entry.payloadDictionary()
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            username: payload.string("username"),
            host: payload.string("host"),
            publicKey: payload.string("publicKey"),
            privateKeyReference: payload.string("privateKeyReference"),
            passphraseHint: payload.string("passphraseHint"),
            notes: payload.string("notes"),
            algorithm: payload.string("algorithm"),
            keySize: Int(payload.string("keySize")) ?? 0,
            fingerprint: payload.string("fingerprint"),
            favorite: entry.favorite,
            metadata: VaultEntryMetadata(entry.metadata)
        )
    }
}
