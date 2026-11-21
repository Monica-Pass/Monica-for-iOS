@testable import MonicaSync
import Foundation
import Testing

// MARK: - 固定向量

private func makeRemoteItem(
    remoteID: String = "cipher-1",
    kind: BitwardenSyncItemKind = .login,
    title: String = "GitHub",
    username: String = "alice",
    url: String = "https://github.com",
    password: String? = "remote-password-secret",
    totpSecret: String? = nil,
    notes: String? = nil,
    folderID: String? = "folder-1",
    folderName: String? = "Work",
    collectionNames: [String] = [],
    organizationID: String? = nil,
    collectionIDs: [String] = [],
    customFields: [BitwardenSyncCustomField] = [],
    updatedAt: Date? = Date(timeIntervalSince1970: 1_790_000_000),
    favorite: Bool = false,
    deletedAt: Date? = nil
) -> BitwardenSyncItem {
    BitwardenSyncItem(
        remoteID: remoteID,
        kind: kind,
        title: title,
        username: username,
        url: url,
        password: password,
        totpSecret: totpSecret,
        notes: notes,
        folderID: folderID,
        folderName: folderName,
        collectionNames: collectionNames,
        organizationID: organizationID,
        collectionIDs: collectionIDs,
        customFields: customFields,
        updatedAt: updatedAt,
        favorite: favorite,
        deletedAt: deletedAt
    )
}

private func makeLocalItem(
    from item: BitwardenSyncItem,
    localID: String = "local-1"
) -> BitwardenLocalItemSyncItem {
    BitwardenLocalItemSyncItem(
        localID: localID,
        kind: item.kind,
        title: item.title,
        username: item.username,
        url: item.url,
        password: item.password,
        totpSecret: item.totpSecret,
        notes: item.notes,
        folderID: item.folderID,
        folderName: item.folderName,
        favorite: item.favorite,
        organizationID: item.organizationID,
        collectionIDs: item.collectionIDs,
        cardholderName: item.cardholderName,
        cardNumber: item.cardNumber,
        cardExpiryMonth: item.cardExpiryMonth,
        cardExpiryYear: item.cardExpiryYear,
        cardCode: item.cardCode,
        cardBrand: item.cardBrand,
        identityFullName: item.identityFullName,
        identityDocumentNumber: item.identityDocumentNumber,
        identityIssuer: item.identityIssuer,
        identityCountry: item.identityCountry,
        passkeyRelyingPartyID: item.passkeyRelyingPartyID,
        passkeyRelyingPartyName: item.passkeyRelyingPartyName,
        passkeyCredentialID: item.passkeyCredentialID,
        passkeyUserHandle: item.passkeyUserHandle,
        passkeyPublicKeyCOSE: item.passkeyPublicKeyCOSE,
        passkeyPrivateKeyReference: item.passkeyPrivateKeyReference,
        passkeyPublicKeyAlgorithm: item.passkeyPublicKeyAlgorithm,
        passkeyCounter: item.passkeyCounter,
        passkeyDiscoverable: item.passkeyDiscoverable,
        passkeyCreationDate: item.passkeyCreationDate,
        sshPublicKey: item.sshPublicKey,
        sshPrivateKey: item.sshPrivateKey,
        sshKeyFingerprint: item.sshKeyFingerprint
    )
}

private func makeState(
    local: BitwardenLocalItemSyncItem,
    remote: BitwardenSyncItem,
    lastRemoteRepresents: BitwardenSyncItem? = nil,
    isDeleted: Bool = false
) -> BitwardenItemSyncState {
    let baselineRemote = lastRemoteRepresents ?? remote
    return BitwardenItemSyncState(
        localID: local.localID,
        remoteID: remote.remoteID,
        kind: remote.kind,
        lastSyncedFingerprint: local.syncFingerprint,
        lastRemoteRevision: BitwardenItemMergeEngine.revisionToken(for: baselineRemote),
        isDeleted: isDeleted,
        lastRemoteFingerprint: baselineRemote.syncFingerprint,
        organizationID: remote.organizationID,
        collectionIDs: remote.collectionIDs
    )
}

// MARK: - 字段级合并

@Test func bitwardenMergeEngineTreatsRemoteOnlyFieldChangeAsRemoteUpdate() throws {
    let base = makeRemoteItem()
    let local = makeLocalItem(from: base)
    let state = makeState(local: local, remote: base)
    let changedRemote = makeRemoteItem(title: "GitHub 工作账号")

    let outcome = BitwardenItemMergeEngine().outcome(remote: changedRemote, local: local, state: state)

    #expect(outcome == .remoteUpdate(fields: [.title]))
    #expect(outcome.appliesRemoteContent)
    #expect(outcome.redactedSummary == "更新：远端改动 标题")
}

@Test func bitwardenMergeEngineTreatsLocalOnlyFieldChangeAsPendingUpload() throws {
    let base = makeRemoteItem()
    let local = makeLocalItem(from: base)
    let state = makeState(local: local, remote: base)
    let editedLocal = makeLocalItem(
        from: makeRemoteItem(password: "locally-edited-password-secret"),
        localID: local.localID
    )

    let outcome = BitwardenItemMergeEngine().outcome(remote: base, local: editedLocal, state: state)

    #expect(outcome == .localUpdate(fields: [.password]))
    #expect(!outcome.appliesRemoteContent)
}

@Test func bitwardenMergeEngineReportsConflictOnlyWithFieldNames() throws {
    let base = makeRemoteItem(totpSecret: nil)
    let local = makeLocalItem(from: base)
    let state = makeState(local: local, remote: base)
    let editedLocal = makeLocalItem(
        from: makeRemoteItem(password: "locally-edited-password-secret"),
        localID: local.localID
    )
    let changedRemote = makeRemoteItem(totpSecret: "remote-totp-secret-value", notes: "remote-note-secret")

    let outcome = BitwardenItemMergeEngine().outcome(remote: changedRemote, local: editedLocal, state: state)

    #expect(outcome == .conflict(fields: [.password, .totp, .notes]))
    #expect(outcome.needsAttention)
    let summary = outcome.redactedSummary
    #expect(summary.contains("密码"))
    #expect(summary.contains("验证码密钥"))
    #expect(!summary.contains("locally-edited-password-secret"))
    #expect(!summary.contains("remote-totp-secret-value"))
    #expect(!summary.contains("remote-note-secret"))
}

@Test func bitwardenMergeEngineConvergesWhenBothSidesMatch() throws {
    let base = makeRemoteItem()
    let local = makeLocalItem(from: base)
    let state = makeState(local: local, remote: base)

    let outcome = BitwardenItemMergeEngine().outcome(remote: makeRemoteItem(), local: local, state: state)

    #expect(outcome == .unchanged)
}

@Test func bitwardenMergeEngineAllowsDeletingLocallyUntouchedItemAfterRemoteDeletion() throws {
    let base = makeRemoteItem()
    let local = makeLocalItem(from: base)
    let state = makeState(local: local, remote: base)

    let outcome = BitwardenItemMergeEngine().outcome(remote: nil, local: local, state: state)

    #expect(outcome == .remoteDeletion)
    #expect(outcome.appliesRemoteDeletion)
}

@Test func bitwardenMergeEngineProtectsLocallyEditedItemFromRemoteDeletion() throws {
    let base = makeRemoteItem()
    let local = makeLocalItem(from: base)
    let state = makeState(local: local, remote: base)
    let editedLocal = makeLocalItem(
        from: makeRemoteItem(password: "locally-edited-password-secret"),
        localID: local.localID
    )

    let outcome = BitwardenItemMergeEngine().outcome(remote: nil, local: editedLocal, state: state)

    #expect(outcome == .remoteDeletionConflict(fields: []))
    #expect(outcome.needsAttention)
    #expect(!outcome.appliesRemoteDeletion)
}

@Test func bitwardenMergeEngineTreatsRemoteTrashEntryAsDeletion() throws {
    let base = makeRemoteItem()
    let local = makeLocalItem(from: base)
    let state = makeState(local: local, remote: base)
    let trashedRemote = makeRemoteItem(deletedAt: Date(timeIntervalSince1970: 1_790_000_500))

    let outcome = BitwardenItemMergeEngine().outcome(remote: trashedRemote, local: local, state: state)

    #expect(outcome == .remoteDeletion)
}

@Test func bitwardenMergeEngineKeepsLocalDeletionWhenRemoteIsClean() throws {
    let base = makeRemoteItem()
    let local = makeLocalItem(from: base)
    let state = makeState(local: local, remote: base)

    let outcome = BitwardenItemMergeEngine().outcome(
        remote: base,
        local: local,
        state: state,
        localIsDeleted: true
    )

    #expect(outcome == .localDeletion)
    #expect(!outcome.needsAttention)
}

@Test func bitwardenMergeEngineFlagsLocalDeletionWhenRemoteChangedMeanwhile() throws {
    let base = makeRemoteItem()
    let local = makeLocalItem(from: base)
    let state = makeState(local: local, remote: base)
    let changedRemote = makeRemoteItem(notes: "remote-note-secret")

    let outcome = BitwardenItemMergeEngine().outcome(
        remote: changedRemote,
        local: local,
        state: state,
        localIsDeleted: true
    )

    #expect(outcome == .localDeletionConflict(fields: [.notes]))
    #expect(outcome.needsAttention)
}

@Test func bitwardenMergeEngineFallsBackToRevisionWhenLegacyStateHasNoRemoteFingerprint() throws {
    let base = makeRemoteItem()
    let local = makeLocalItem(from: base)
    let legacyState = BitwardenItemSyncState(
        localID: local.localID,
        remoteID: base.remoteID,
        kind: base.kind,
        lastSyncedFingerprint: local.syncFingerprint,
        lastRemoteRevision: BitwardenItemMergeEngine.revisionToken(for: base)
    )

    let unchanged = BitwardenItemMergeEngine().outcome(remote: base, local: local, state: legacyState)
    #expect(unchanged == .unchanged)

    // 旧状态只有 updatedAt 作为远端版本：远端改写内容时 updatedAt 之外无法判断字段，
    // 但因为指纹不同且本地没动，仍然归为「远端更新」。
    let changedRemote = makeRemoteItem(title: "Renamed", updatedAt: Date(timeIntervalSince1970: 1_790_000_900))
    let changed = BitwardenItemMergeEngine().outcome(remote: changedRemote, local: local, state: legacyState)
    #expect(changed == .remoteUpdate(fields: [.title]))
}

// MARK: - 预览计数

@Test func bitwardenSyncPreviewBuilderCountsNewUpdatedConflictAndDeletion() throws {
    let unchangedRemote = makeRemoteItem(remoteID: "cipher-unchanged")
    let unchangedLocal = makeLocalItem(from: unchangedRemote, localID: "local-unchanged")
    let unchangedState = makeState(local: unchangedLocal, remote: unchangedRemote)

    let updatedRemote = makeRemoteItem(remoteID: "cipher-updated")
    let updatedLocal = makeLocalItem(from: updatedRemote, localID: "local-updated")
    let updatedState = makeState(local: updatedLocal, remote: updatedRemote)

    let conflictedRemote = makeRemoteItem(remoteID: "cipher-conflict")
    let conflictedLocal = makeLocalItem(from: conflictedRemote, localID: "local-conflict")
    let conflictedState = makeState(local: conflictedLocal, remote: conflictedRemote)
    let editedConflictedLocal = makeLocalItem(
        from: makeRemoteItem(remoteID: "cipher-conflict", password: "locally-edited-password-secret"),
        localID: conflictedLocal.localID
    )

    let deletedRemote = makeRemoteItem(remoteID: "cipher-deleted")
    let deletedLocal = makeLocalItem(from: deletedRemote, localID: "local-deleted")
    let deletedState = makeState(local: deletedLocal, remote: deletedRemote)

    let snapshot = BitwardenSyncSnapshot(
        accountLabel: "alice@example.com",
        revision: "server-security-stamp-secret",
        collections: [
            BitwardenSyncCollection(remoteID: "collection-1", name: "Shared", organizationID: "org-1")
        ],
        items: [
            makeRemoteItem(remoteID: "cipher-unchanged"),
            makeRemoteItem(remoteID: "cipher-updated", title: "GitHub 工作账号"),
            makeRemoteItem(remoteID: "cipher-conflict", notes: "remote-note-secret"),
            makeRemoteItem(remoteID: "cipher-brand-new"),
            makeRemoteItem(remoteID: "cipher-org", organizationID: "org-1", collectionIDs: ["collection-1"])
        ]
    )
    let localItems = [
        unchangedLocal,
        updatedLocal,
        editedConflictedLocal,
        BitwardenLocalItemSyncItem(localID: "local-only", kind: .login, title: "本地新建")
    ]
    let previousStates = [unchangedState, updatedState, conflictedState, deletedState]
    let deletedLocalItems = [deletedLocal]

    let summary = BitwardenSyncPreviewBuilder().summary(
        remote: snapshot,
        localItems: localItems,
        deletedLocalItems: deletedLocalItems,
        previousStates: previousStates
    )

    #expect(summary.newItemCount == 2)          // cipher-brand-new + cipher-org
    #expect(summary.updatedItemCount == 1)      // cipher-updated
    #expect(summary.conflictItemCount == 1)     // cipher-conflict
    #expect(summary.unchangedItemCount == 1)    // cipher-unchanged
    #expect(summary.remoteDeletionCount == 1)   // cipher-deleted 已从远端消失
    #expect(summary.localDeletionCount == 1)    // local-deleted 等待推送
    #expect(summary.localOnlyItemCount == 1)    // local-only
    #expect(summary.collectionCount == 1)
    #expect(summary.organizationItemCount == 1)
    #expect(summary.conflictFieldNames.contains("密码"))
    #expect(!summary.redactedSummary.contains("remote-note-secret"))
    #expect(!summary.redactedSummary.contains("locally-edited-password-secret"))
}

@Test func bitwardenSyncPreviewBuilderFiltersByCollectionAndCountsDuplicates() throws {
    let snapshot = BitwardenSyncSnapshot(
        accountLabel: "alice@example.com",
        revision: "revision",
        collections: [
            BitwardenSyncCollection(remoteID: "collection-1", name: "Shared", organizationID: "org-1"),
            BitwardenSyncCollection(remoteID: "collection-2", name: "Personal", organizationID: "org-1")
        ],
        items: [
            makeRemoteItem(remoteID: "cipher-shared", organizationID: "org-1", collectionIDs: ["collection-1"]),
            makeRemoteItem(remoteID: "cipher-shared", organizationID: "org-1", collectionIDs: ["collection-1"]),
            makeRemoteItem(remoteID: "cipher-personal", organizationID: "org-1", collectionIDs: ["collection-2"])
        ]
    )

    let filtered = BitwardenSyncPreviewBuilder().summary(
        remote: snapshot,
        collectionFilter: ["collection-1"]
    )

    #expect(filtered.duplicateItemCount == 1)
    #expect(filtered.newItemCount == 1)
    #expect(filtered.skippedItemCount == 1)
    #expect(filtered.collectionCount == 2)
    #expect(filtered.collectionNames == ["Personal", "Shared"])
}

// MARK: - 解析：集合 / 组织 / 自定义字段

private final class ScriptedBitwardenVaultSyncTransport: BitwardenVaultSyncTransport, @unchecked Sendable {
    private(set) var requests: [BitwardenVaultSyncRequest] = []
    private var responses: [BitwardenVaultSyncResponse] = []

    func enqueue(statusCode: Int, body: String) {
        responses.append(
            BitwardenVaultSyncResponse(statusCode: statusCode, headers: [:], body: Data(body.utf8))
        )
    }

    func send(_ request: BitwardenVaultSyncRequest) async throws -> BitwardenVaultSyncResponse {
        requests.append(request)
        return responses.removeFirst()
    }
}

private func makeProvider(
    transport: ScriptedBitwardenVaultSyncTransport,
    vaultKeyStore: (any BitwardenVaultKeyStore)? = nil
) -> BitwardenVaultSyncProvider {
    let sessionStore = MemoryBitwardenAuthenticationSessionStore(
        session: BitwardenAuthenticationSession(
            accountLabel: "alice@example.com",
            serverURL: URL(string: "https://vault.bitwarden.com")!,
            identityURL: URL(string: "https://identity.bitwarden.com")!,
            apiURL: URL(string: "https://api.bitwarden.com")!,
            accessToken: "fresh-access-token-secret",
            refreshToken: "refresh-token-secret",
            expiresAt: Date(timeIntervalSince1970: 1_804_010_000)
        )
    )
    return BitwardenVaultSyncProvider(
        sessionStore: sessionStore,
        vaultTransport: transport,
        vaultKeyStore: vaultKeyStore,
        now: { Date(timeIntervalSince1970: 1_804_000_100) }
    )
}

private let organizationSyncBody = """
{
  "Profile": {
    "Email": "alice@example.com",
    "SecurityStamp": "server-security-stamp-secret"
  },
  "Collections": [
    {
      "Id": "collection-1",
      "Name": "Shared",
      "OrganizationId": "org-1",
      "Default": true
    }
  ],
  "Ciphers": [
    {
      "Id": "cipher-org",
      "OrganizationId": "org-1",
      "CollectionIds": ["collection-1"],
      "Type": 1,
      "Name": "Organization Login",
      "Login": {
        "Username": "alice",
        "Password": "organization-password-secret",
        "Uris": [{ "Uri": "https://example.com" }]
      },
      "Fields": [
        { "Name": "API Key", "Value": "custom-field-secret", "Type": 1 },
        { "Name": "Environment", "Value": "Production", "Type": 0 },
        { "Name": "monica_login_type", "Value": "SSH_KEY", "Type": 0 }
      ],
      "RevisionDate": "2026-06-03T12:30:00Z"
    }
  ]
}
"""

@Test func bitwardenVaultSyncProviderParsesCollectionsOrganizationAndCustomFields() async throws {
    let transport = ScriptedBitwardenVaultSyncTransport()
    transport.enqueue(statusCode: 200, body: organizationSyncBody)
    let provider = makeProvider(transport: transport)

    let snapshot = try await provider.pullSnapshot()

    #expect(snapshot.collections.map(\.remoteID) == ["collection-1"])
    #expect(snapshot.collections.map(\.name) == ["Shared"])
    #expect(snapshot.collections.first?.organizationID == "org-1")
    #expect(snapshot.collections.first?.isDefault == true)

    let item = try #require(snapshot.items.first)
    #expect(item.organizationID == "org-1")
    #expect(item.collectionIDs == ["collection-1"])
    #expect(item.collectionNames == ["Shared"])
    #expect(item.customFields.map(\.name) == ["API Key", "Environment"])
    #expect(item.customFields.first?.type == .hidden)
    #expect(item.customFields.first?.displayValue == "••••••")
    #expect(item.customFields.last?.type == .text)
    #expect(item.collectionSummary == "组织条目 · Shared")
    #expect(!item.customFields.map(\.redactedSummary).joined().contains("custom-field-secret"))
}

@Test func bitwardenVaultSyncProviderPreservesOrganizationAndCollectionsWhenPushingCipher() async throws {
    let keyStore = MemoryBitwardenVaultKeyStore()
    try keyStore.saveVaultKey(
        BitwardenVaultKey(
            encryptionKey: Data((1...32).map(UInt8.init)),
            macKey: Data((33...64).map(UInt8.init))
        ),
        accountLabel: "alice@example.com"
    )
    let transport = ScriptedBitwardenVaultSyncTransport()
    transport.enqueue(statusCode: 200, body: #"{"Id":"created-cipher-id","RevisionDate":"2026-06-04T08:00:00Z"}"#)
    let provider = makeProvider(transport: transport, vaultKeyStore: keyStore)

    let localItem = BitwardenLocalItemSyncItem(
        localID: "local-org-login",
        kind: .login,
        title: "Organization Login",
        username: "alice",
        password: "organization-password-secret",
        organizationID: "org-1",
        collectionIDs: ["collection-1"]
    )
    let result = try await provider.pushMutations([.upsertCipher(item: localItem, remoteID: nil)])

    #expect(result.acceptedMutationCount == 1)
    #expect(result.assignedRemoteIDs == ["local-org-login": "created-cipher-id"])
    let body = try #require(transport.requests.first?.body)
    let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(payload["organizationId"] as? String == "org-1")
    #expect(payload["collectionIds"] as? [String] == ["collection-1"])
    #expect(payload["name"] as? String != "Organization Login")
    #expect(!String(decoding: body, as: UTF8.self).contains("organization-password-secret"))
}

// MARK: - 增量同步修订

@Test func bitwardenVaultSyncProviderSkipsPullWhenRevisionIsUnchanged() async throws {
    let transport = ScriptedBitwardenVaultSyncTransport()
    transport.enqueue(statusCode: 200, body: #"{"object":"template","data":1790000000000}"#)
    let provider = makeProvider(transport: transport)

    let outcome = try await provider.pullSnapshot(
        ifChangedSince: BitwardenSyncRevision(value: "1790000000000")
    )

    #expect(outcome == .unchanged(revision: BitwardenSyncRevision(value: "1790000000000", capturedAt: Date(timeIntervalSince1970: 1_790_000_000))))
    #expect(transport.requests.count == 1)
    #expect(transport.requests[0].url.absoluteString == "https://api.bitwarden.com/accounts/revision-date")
}

@Test func bitwardenVaultSyncProviderPullsWhenRevisionChanged() async throws {
    let transport = ScriptedBitwardenVaultSyncTransport()
    transport.enqueue(statusCode: 200, body: #"{"object":"template","data":1790000900000}"#)
    transport.enqueue(statusCode: 200, body: organizationSyncBody)
    let provider = makeProvider(transport: transport)

    let outcome = try await provider.pullSnapshot(
        ifChangedSince: BitwardenSyncRevision(value: "1790000000000")
    )

    guard case let .changed(snapshot, revision) = outcome else {
        Issue.record("预期远端有变化")
        return
    }
    #expect(snapshot.items.count == 1)
    #expect(revision?.value == "1790000900000")
    #expect(transport.requests.map(\.url.absoluteString) == [
        "https://api.bitwarden.com/accounts/revision-date",
        "https://api.bitwarden.com/sync?excludeDomains=true"
    ])
}

@Test func bitwardenVaultSyncProviderMapsRevisionErrorsToTypedFailures() async throws {
    let unauthorizedTransport = ScriptedBitwardenVaultSyncTransport()
    unauthorizedTransport.enqueue(statusCode: 401, body: "{}")
    await #expect(throws: BitwardenSyncProviderError.authenticationRequired) {
        _ = try await makeProvider(transport: unauthorizedTransport).latestRevision()
    }

    let throttledTransport = ScriptedBitwardenVaultSyncTransport()
    throttledTransport.enqueue(statusCode: 429, body: "{}")
    await #expect(throws: BitwardenSyncProviderError.serverRejected(statusCode: 429)) {
        _ = try await makeProvider(transport: throttledTransport).latestRevision()
    }
}

@Test func bitwardenVaultSyncProviderReturnsNilRevisionForUnparsableBody() async throws {
    let transport = ScriptedBitwardenVaultSyncTransport()
    transport.enqueue(statusCode: 200, body: "not-json")
    let provider = makeProvider(transport: transport)

    let revision = try await provider.latestRevision()

    #expect(revision == nil)
}
