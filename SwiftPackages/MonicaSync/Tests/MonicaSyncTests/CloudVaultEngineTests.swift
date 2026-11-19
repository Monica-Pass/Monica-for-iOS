import Foundation
import Testing
@testable import MonicaSync

// MARK: - Fixtures

private let engineReferenceDate = Date(timeIntervalSince1970: 1_750_000_000)
private let engineRemotePath = "Monica.mdbx"

private func engineSnapshot(
    _ contents: String,
    vaultID: String = "vault-1",
    vaultName: String = "Personal",
    deviceID: String = "device-a",
    deviceName: String = "iPhone",
    capturedAt: Date = engineReferenceDate
) throws -> CloudVaultLocalSnapshot {
    try CloudVaultLocalSnapshot.make(
        vaultID: vaultID,
        vaultName: vaultName,
        data: Data(contents.utf8),
        deviceID: deviceID,
        deviceName: deviceName,
        capturedAt: capturedAt
    )
}

private func engineManifest(
    for local: CloudVaultLocalSnapshot,
    revision: Int
) -> CloudVaultManifest {
    CloudVaultManifest.make(local: local, revision: revision)
}

private func engineRemoteFile(
    manifest: CloudVaultManifest,
    revision: String? = "etag-1",
    manifestRevision: String? = "metag-1",
    kind: CloudVaultRemoteKind = .webDAV,
    remotePath: String = engineRemotePath
) -> CloudVaultRemoteFile {
    CloudVaultRemoteFile(
        kind: kind,
        remotePath: remotePath,
        fileName: remotePath,
        manifestFileName: CloudVaultNaming.manifestFileName(forVaultFileName: remotePath),
        itemID: "item-1",
        revision: revision,
        manifestRevision: manifestRevision,
        manifest: manifest
    )
}

private func engineRecord(
    local: CloudVaultLocalSnapshot,
    remoteRevision: String? = nil,
    manifestRevision: Int? = nil,
    remoteContentSHA256: String? = nil,
    localContentSHA256: String? = nil,
    pendingUpload: Bool = false,
    lastFailureMessage: String? = nil,
    kind: CloudVaultRemoteKind = .webDAV,
    remotePath: String = engineRemotePath
) -> CloudVaultSyncRecord {
    CloudVaultSyncRecord(
        key: CloudVaultSyncRecord.key(
            remoteKind: kind,
            remotePath: remotePath,
            vaultID: local.vaultID
        ),
        vaultID: local.vaultID,
        remoteKind: kind,
        remotePath: remotePath,
        lastRemoteRevision: remoteRevision,
        lastRemoteManifestRevision: manifestRevision,
        lastRemoteContentSHA256: remoteContentSHA256,
        lastLocalContentSHA256: localContentSHA256,
        lastSyncedAt: engineReferenceDate,
        pendingUpload: pendingUpload,
        lastFailureMessage: lastFailureMessage
    )
}

/// Record describing a completed sync of `local` against remote revision 1.
private func engineBaselineRecord(
    for local: CloudVaultLocalSnapshot,
    remoteRevision: String? = "etag-1",
    manifestRevision: Int? = 1
) -> CloudVaultSyncRecord {
    engineRecord(
        local: local,
        remoteRevision: remoteRevision,
        manifestRevision: manifestRevision,
        remoteContentSHA256: local.sha256,
        localContentSHA256: local.sha256
    )
}

private func engineConflict(_ decision: CloudVaultSyncDecision) -> CloudVaultConflict? {
    guard case .conflict(let conflict) = decision else { return nil }
    return conflict
}

private func engineExpectStateCorrupted(
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () throws -> CloudVaultSyncState
) {
    do {
        _ = try body()
        Issue.record("expected CloudVaultError.stateCorrupted", sourceLocation: sourceLocation)
    } catch let error as CloudVaultError {
        guard case .stateCorrupted = error else {
            Issue.record("expected stateCorrupted, got \(error)", sourceLocation: sourceLocation)
            return
        }
    } catch {
        Issue.record("expected CloudVaultError, got \(error)", sourceLocation: sourceLocation)
    }
}

// MARK: - In-memory remote store

/// Minimal `CloudVaultRemoteStore` that records the ordered call log and mimics
/// the integrity/conditional-write behaviour the real providers must implement.
private final class EngineFakeRemoteStore: CloudVaultRemoteStore, @unchecked Sendable {
    struct UpdateCall: Equatable {
        let expectedRevision: String?
        let manifestRevision: Int
    }

    struct ConflictCopyCall {
        let vaultData: Data
        let manifest: CloudVaultManifest
        let deviceName: String
        let now: Date
    }

    let kind: CloudVaultRemoteKind
    let displayName: String
    let remotePath: String

    private let lock = NSLock()
    private let revisionExposed: Bool
    private var remoteManifest: CloudVaultManifest?
    private var remoteVaultData: Data?
    private var callLog: [String] = []
    private var updateCallLog: [UpdateCall] = []
    private var conflictCopyLog: [ConflictCopyCall] = []
    private var pendingUpdateFailure: CloudVaultError?

    init(
        kind: CloudVaultRemoteKind = .webDAV,
        remotePath: String = engineRemotePath,
        exposesRevisions: Bool = true
    ) {
        self.kind = kind
        self.displayName = "测试 \(kind.displayName)"
        self.remotePath = remotePath
        self.revisionExposed = exposesRevisions
    }

    // MARK: Inspection

    var recordedCalls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return callLog
    }

    var storedManifest: CloudVaultManifest? {
        lock.lock()
        defer { lock.unlock() }
        return remoteManifest
    }

    var storedVaultData: Data? {
        lock.lock()
        defer { lock.unlock() }
        return remoteVaultData
    }

    var storedRevision: String? {
        lock.lock()
        defer { lock.unlock() }
        guard let manifest = remoteManifest else { return nil }
        return revisionExposed ? "etag-\(manifest.revision)" : nil
    }

    var updateCalls: [UpdateCall] {
        lock.lock()
        defer { lock.unlock() }
        return updateCallLog
    }

    var conflictCopies: [ConflictCopyCall] {
        lock.lock()
        defer { lock.unlock() }
        return conflictCopyLog
    }

    // MARK: Seeding

    func seed(manifest: CloudVaultManifest, vaultData: Data) {
        lock.lock()
        defer { lock.unlock() }
        remoteManifest = manifest
        remoteVaultData = vaultData
    }

    func removeRemote() {
        lock.lock()
        defer { lock.unlock() }
        remoteManifest = nil
        remoteVaultData = nil
    }

    func failNextUpdate(with error: CloudVaultError) {
        lock.lock()
        defer { lock.unlock() }
        pendingUpdateFailure = error
    }

    // MARK: CloudVaultRemoteStore

    func readRemote() async throws -> CloudVaultRemoteFile? {
        lock.withLock { () -> CloudVaultRemoteFile? in
            callLog.append("readRemote")
            guard let manifest = remoteManifest else { return nil }
            return makeRemote(manifest)
        }
    }

    func downloadVault(_ remote: CloudVaultRemoteFile) async throws -> Data {
        let storedVaultData: Data? = lock.withLock {
            callLog.append("downloadVault")
            return remoteVaultData
        }
        guard let vaultData = storedVaultData else {
            throw CloudVaultError.remoteVaultMissing
        }
        let digest = LanSyncEncoding.hex(LanSyncEncoding.sha256(vaultData))
        guard digest == remote.manifest.contentSHA256 else {
            throw CloudVaultError.integrityMismatch(
                expectedSHA256: remote.manifest.contentSHA256,
                actualSHA256: digest
            )
        }
        return vaultData
    }

    func createRemote(
        vaultData: Data,
        manifest: CloudVaultManifest
    ) async throws -> CloudVaultWriteReceipt {
        try lock.withLock {
            callLog.append("createRemote")
            guard remoteManifest == nil else {
                throw CloudVaultError.preconditionFailed(
                    remoteRevision: remoteManifest.map { "etag-\($0.revision)" }
                )
            }
            remoteManifest = manifest
            remoteVaultData = vaultData
            return makeReceipt(manifest)
        }
    }

    func updateRemote(
        vaultData: Data,
        manifest: CloudVaultManifest,
        remote: CloudVaultRemoteFile
    ) async throws -> CloudVaultWriteReceipt {
        try lock.withLock {
            callLog.append("updateRemote")
            updateCallLog.append(
                UpdateCall(expectedRevision: remote.revision, manifestRevision: manifest.revision)
            )
            if let failure = pendingUpdateFailure {
                pendingUpdateFailure = nil
                throw failure
            }
            guard let currentManifest = remoteManifest else {
                throw CloudVaultError.remoteManifestMissing
            }
            if revisionExposed, let expected = remote.revision,
               expected != "etag-\(currentManifest.revision)" {
                throw CloudVaultError.preconditionFailed(remoteRevision: "etag-\(currentManifest.revision)")
            }
            remoteManifest = manifest
            remoteVaultData = vaultData
            return makeReceipt(manifest)
        }
    }

    func writeConflictCopy(
        vaultData: Data,
        manifest: CloudVaultManifest,
        deviceName: String,
        now: Date
    ) async throws -> CloudVaultWriteReceipt {
        lock.withLock {
            callLog.append("writeConflictCopy")
            conflictCopyLog.append(
                ConflictCopyCall(vaultData: vaultData, manifest: manifest, deviceName: deviceName, now: now)
            )
            let fileName = CloudVaultNaming.conflictCopyFileName(
                vaultFileName: remotePath,
                deviceName: deviceName,
                date: now,
                shortToken: CloudVaultNaming.conflictCopyToken(sha256: manifest.contentSHA256, date: now)
            )
            return CloudVaultWriteReceipt(
                kind: kind,
                remotePath: "\(remotePath)/\(fileName)",
                fileName: fileName,
                manifestFileName: CloudVaultNaming.manifestFileName(forVaultFileName: fileName),
                itemID: "conflict-copy-item",
                revision: revisionExposed ? "copy-etag" : nil,
                manifestRevision: revisionExposed ? "copy-metag" : nil,
                manifest: manifest
            )
        }
    }

    // MARK: Helpers

    private func makeRemote(_ manifest: CloudVaultManifest) -> CloudVaultRemoteFile {
        CloudVaultRemoteFile(
            kind: kind,
            remotePath: remotePath,
            fileName: remotePath,
            manifestFileName: CloudVaultNaming.manifestFileName(forVaultFileName: remotePath),
            itemID: "item-1",
            revision: revisionExposed ? "etag-\(manifest.revision)" : nil,
            manifestRevision: revisionExposed ? "metag-\(manifest.revision)" : nil,
            manifest: manifest
        )
    }

    private func makeReceipt(_ manifest: CloudVaultManifest) -> CloudVaultWriteReceipt {
        CloudVaultWriteReceipt(
            kind: kind,
            remotePath: remotePath,
            fileName: remotePath,
            manifestFileName: CloudVaultNaming.manifestFileName(forVaultFileName: remotePath),
            itemID: "item-1",
            revision: revisionExposed ? "etag-\(manifest.revision)" : nil,
            manifestRevision: revisionExposed ? "metag-\(manifest.revision)" : nil,
            manifest: manifest
        )
    }
}

// MARK: - Tests

@Suite("CloudVaultSyncEngine")
struct CloudVaultEngineTests {
    private var engine: CloudVaultSyncEngine {
        CloudVaultSyncEngine(now: { engineReferenceDate })
    }

    // MARK: Planning

    @Test func planWithoutRemoteOrRecordPublishesNewVault() throws {
        let local = try engineSnapshot("v1")
        #expect(engine.plan(local: local, record: nil, remote: nil) == .pushNew)
    }

    @Test func planWithoutRemoteButWithRecordReportsRemoteRemoved() throws {
        let v1 = try engineSnapshot("v1")
        let v2 = try engineSnapshot("v2")
        let record = engineBaselineRecord(for: v1)

        let changed = try #require(engineConflict(engine.plan(local: v2, record: record, remote: nil)))
        #expect(changed.reason == .remoteRemoved)
        #expect(changed.localChanged)
        #expect(changed.remoteChanged)
        #expect(changed.remoteManifestRevision == 0)
        #expect(changed.remoteRevision == nil)
        #expect(changed.baselineManifestRevision == 1)
        #expect(changed.localContentSHA256 == v2.sha256)
        // Nothing is left upstream; the last known digest is reported for context.
        #expect(changed.remoteContentSHA256 == v1.sha256)

        let unchangedLocal = try #require(
            engineConflict(engine.plan(local: v1, record: record, remote: nil))
        )
        #expect(unchangedLocal.reason == .remoteRemoved)
        #expect(unchangedLocal.localChanged == false)
    }

    @Test func planReportsUpToDateWhenBothSidesMatchRecordedBaseline() throws {
        let local = try engineSnapshot("v1")
        let remote = engineRemoteFile(
            manifest: engineManifest(for: local, revision: 1),
            revision: "etag-1"
        )
        #expect(engine.plan(local: local, record: engineBaselineRecord(for: local), remote: remote) == .upToDate)
    }

    @Test func planReportsUpToDateWithoutServerRevisions() throws {
        let local = try engineSnapshot("v1")
        let remote = engineRemoteFile(
            manifest: engineManifest(for: local, revision: 2),
            revision: nil,
            manifestRevision: nil
        )
        let record = engineRecord(
            local: local,
            remoteRevision: nil,
            manifestRevision: 2,
            remoteContentSHA256: local.sha256,
            localContentSHA256: local.sha256
        )
        #expect(engine.plan(local: local, record: record, remote: remote) == .upToDate)
    }

    @Test func planUploadsUpdateWhenOnlyLocalContentChanged() throws {
        let v1 = try engineSnapshot("v1")
        let v2 = try engineSnapshot("v2")
        let remote = engineRemoteFile(
            manifest: engineManifest(for: v1, revision: 1),
            revision: "etag-1"
        )
        #expect(engine.plan(local: v2, record: engineBaselineRecord(for: v1), remote: remote) == .pushUpdate)
    }

    @Test func planPullsWhenOnlyRemoteMoved() throws {
        let v1 = try engineSnapshot("v1")
        let v2 = try engineSnapshot("v2")
        let remote = engineRemoteFile(
            manifest: engineManifest(for: v2, revision: 2),
            revision: "etag-2",
            manifestRevision: "metag-2"
        )
        #expect(engine.plan(local: v1, record: engineBaselineRecord(for: v1), remote: remote) == .pullRemoteNewer)
    }

    @Test func planTreatsRemoteAsChangedWhenOnlyTheManifestRevisionMoved() throws {
        let v1 = try engineSnapshot("v1")
        // Same bytes upstream, but another device re-published the vault: the
        // manifest revision is the authoritative commit marker.
        let remote = engineRemoteFile(
            manifest: engineManifest(for: v1, revision: 2),
            revision: nil,
            manifestRevision: nil
        )
        let record = engineRecord(
            local: v1,
            remoteRevision: nil,
            manifestRevision: 1,
            remoteContentSHA256: v1.sha256,
            localContentSHA256: v1.sha256
        )
        #expect(engine.plan(local: v1, record: record, remote: remote) == .pullRemoteNewer)
    }

    @Test func planReportsBothChangedWhenLocalAndRemoteDiverged() throws {
        let v1 = try engineSnapshot("v1")
        let v2 = try engineSnapshot("v2")
        let v3 = try engineSnapshot("v3")
        let remote = engineRemoteFile(
            manifest: engineManifest(for: v3, revision: 2),
            revision: "etag-2",
            manifestRevision: "metag-2"
        )
        let conflict = try #require(
            engineConflict(engine.plan(local: v2, record: engineBaselineRecord(for: v1), remote: remote))
        )
        #expect(conflict.reason == .bothChanged)
        #expect(conflict.localChanged)
        #expect(conflict.remoteChanged)
        #expect(conflict.baselineManifestRevision == 1)
        #expect(conflict.remoteManifestRevision == 2)
        #expect(conflict.remoteRevision == "etag-2")
        #expect(conflict.localContentSHA256 == v2.sha256)
        #expect(conflict.remoteContentSHA256 == v3.sha256)
    }

    @Test func planReportsNoBaselineWhenRemoteExistsWithoutRecord() throws {
        let local = try engineSnapshot("v1")
        let remoteVault = try engineSnapshot("remote-only")
        let remote = engineRemoteFile(
            manifest: engineManifest(for: remoteVault, revision: 3),
            revision: "etag-3",
            manifestRevision: "metag-3"
        )
        let conflict = try #require(engineConflict(engine.plan(local: local, record: nil, remote: remote)))
        #expect(conflict.reason == .noBaseline)
        #expect(conflict.localChanged)
        #expect(conflict.remoteChanged)
        #expect(conflict.baselineManifestRevision == nil)
        #expect(conflict.remoteManifestRevision == 3)
        #expect(conflict.remoteContentSHA256 == remoteVault.sha256)

        // Identical bytes on both sides need no user decision.
        let identical = engineRemoteFile(manifest: engineManifest(for: local, revision: 1))
        #expect(engine.plan(local: local, record: nil, remote: identical) == .upToDate)
    }

    @Test func planReportsVaultIdentityMismatchForForeignRemoteVault() throws {
        let local = try engineSnapshot("v1")
        let foreign = try engineSnapshot("other-vault", vaultID: "vault-2")
        let remote = engineRemoteFile(
            manifest: engineManifest(for: foreign, revision: 4),
            revision: "etag-4",
            manifestRevision: "metag-4"
        )

        let withRecord = try #require(
            engineConflict(engine.plan(local: local, record: engineBaselineRecord(for: local), remote: remote))
        )
        #expect(withRecord.reason == .vaultIdentityMismatch)
        #expect(withRecord.localChanged)
        #expect(withRecord.remoteChanged)
        #expect(withRecord.remoteManifestRevision == 4)
        #expect(withRecord.remoteContentSHA256 == foreign.sha256)

        let withoutRecord = try #require(engineConflict(engine.plan(local: local, record: nil, remote: remote)))
        #expect(withoutRecord.reason == .vaultIdentityMismatch)
        #expect(withoutRecord.baselineManifestRevision == nil)
    }

    // MARK: Push

    @Test func pushCreatesRevisionOneManifestAndRecordsBaseline() async throws {
        let store = EngineFakeRemoteStore()
        let local = try engineSnapshot("v1")

        let outcome = try await engine.push(local: local, store: store, record: nil)
        let push = try #require(outcome)

        #expect(store.recordedCalls == ["readRemote", "createRemote"])
        #expect(push.receipt.manifest.revision == 1)
        #expect(push.receipt.manifest.vaultID == local.vaultID)
        #expect(push.receipt.manifest.contentSHA256 == local.sha256)
        #expect(push.receipt.manifest.byteCount == local.byteCount)
        #expect(push.receipt.manifest.updatedByDeviceID == local.deviceID)
        #expect(push.receipt.manifest.updatedByDeviceName == local.deviceName)

        // The store received a manifest that pins the uploaded bytes.
        let storedManifest = try #require(store.storedManifest)
        #expect(storedManifest.contentSHA256 == local.sha256)
        #expect(storedManifest.byteCount == local.byteCount)
        #expect(store.storedVaultData == local.data)

        #expect(push.record.key == CloudVaultSyncRecord.key(
            remoteKind: store.kind,
            remotePath: store.remotePath,
            vaultID: local.vaultID
        ))
        #expect(push.record.vaultID == local.vaultID)
        #expect(push.record.remoteKind == .webDAV)
        #expect(push.record.remotePath == store.remotePath)
        #expect(push.record.lastRemoteRevision == "etag-1")
        #expect(push.record.lastRemoteManifestRevision == 1)
        #expect(push.record.lastRemoteContentSHA256 == local.sha256)
        #expect(push.record.lastLocalContentSHA256 == local.sha256)
        #expect(push.record.lastSyncedAt == engineReferenceDate)
        #expect(push.record.pendingUpload == false)
        #expect(push.record.lastFailureMessage == nil)
    }

    @Test func pushUpdateIncrementsRevisionAndMovesBaseline() async throws {
        let store = EngineFakeRemoteStore()
        let v1 = try engineSnapshot("v1")
        let v2 = try engineSnapshot("v2")
        store.seed(manifest: engineManifest(for: v1, revision: 3), vaultData: v1.data)
        let record = engineBaselineRecord(for: v1, remoteRevision: "etag-3", manifestRevision: 3)

        let outcome = try await engine.push(local: v2, store: store, record: record)
        let push = try #require(outcome)

        #expect(store.recordedCalls == ["readRemote", "updateRemote"])
        #expect(store.updateCalls == [EngineFakeRemoteStore.UpdateCall(
            expectedRevision: "etag-3",
            manifestRevision: 4
        )])
        #expect(push.receipt.manifest.revision == 4)
        #expect(push.receipt.manifest.contentSHA256 == v2.sha256)
        #expect(store.storedManifest?.revision == 4)
        #expect(store.storedVaultData == v2.data)

        #expect(push.record.lastRemoteRevision == "etag-4")
        #expect(push.record.lastRemoteManifestRevision == 4)
        #expect(push.record.lastRemoteContentSHA256 == v2.sha256)
        #expect(push.record.lastLocalContentSHA256 == v2.sha256)
        #expect(push.record.lastSyncedAt == engineReferenceDate)
        #expect(push.record.pendingUpload == false)
    }

    @Test func pushIsNoOpWhenBothSidesAreUpToDate() async throws {
        let store = EngineFakeRemoteStore()
        let local = try engineSnapshot("v1")
        store.seed(manifest: engineManifest(for: local, revision: 1), vaultData: local.data)

        let outcome = try await engine.push(
            local: local,
            store: store,
            record: engineBaselineRecord(for: local)
        )
        #expect(outcome == nil)
        #expect(store.recordedCalls == ["readRemote"])
    }

    @Test func pushRefusesToOverwriteWhenOnlyRemoteChanged() async throws {
        let store = EngineFakeRemoteStore()
        let v1 = try engineSnapshot("v1")
        let v2 = try engineSnapshot("v2")
        store.seed(manifest: engineManifest(for: v2, revision: 2), vaultData: v2.data)

        await #expect(throws: CloudVaultError.preconditionFailed(remoteRevision: "etag-2")) {
            try await engine.push(local: v1, store: store, record: engineBaselineRecord(for: v1))
        }
        // Nothing was uploaded.
        #expect(store.recordedCalls == ["readRemote"])
        #expect(store.storedManifest?.revision == 2)
    }

    @Test func pushSurfacesConflictAsRequiresResolutionError() async throws {
        let store = EngineFakeRemoteStore()
        let v1 = try engineSnapshot("v1")
        let v2 = try engineSnapshot("v2")
        let v3 = try engineSnapshot("v3")
        store.seed(manifest: engineManifest(for: v3, revision: 2), vaultData: v3.data)
        let record = engineBaselineRecord(for: v1)

        do {
            _ = try await engine.push(local: v2, store: store, record: record)
            Issue.record("expected conflictRequiresResolution")
        } catch let error as CloudVaultError {
            guard case .conflictRequiresResolution(let conflict) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(conflict.reason == .bothChanged)
        }
    }

    @Test func pushPropagatesStorePreconditionFailureFromUpdateRemote() async throws {
        let store = EngineFakeRemoteStore()
        let v1 = try engineSnapshot("v1")
        let v2 = try engineSnapshot("v2")
        store.seed(manifest: engineManifest(for: v1, revision: 1), vaultData: v1.data)
        store.failNextUpdate(with: .preconditionFailed(remoteRevision: "etag-9"))

        await #expect(throws: CloudVaultError.preconditionFailed(remoteRevision: "etag-9")) {
            try await engine.push(
                local: v2,
                store: store,
                record: engineBaselineRecord(for: v1)
            )
        }
    }

    // MARK: Pull

    @Test func pullDownloadsRemoteAndLeavesLocalBaselineUntouched() async throws {
        let store = EngineFakeRemoteStore()
        let v1 = try engineSnapshot("v1")
        let v2 = try engineSnapshot("v2")
        store.seed(manifest: engineManifest(for: v2, revision: 2), vaultData: v2.data)
        let record = engineBaselineRecord(for: v1)

        let outcome = try await engine.pull(store: store, record: record)
        let pull = try #require(outcome)

        #expect(store.recordedCalls == ["readRemote", "downloadVault"])
        #expect(pull.vaultData == v2.data)
        #expect(pull.remote.manifest.revision == 2)
        #expect(pull.record.vaultID == v2.vaultID)
        #expect(pull.record.key == CloudVaultSyncRecord.key(
            remoteKind: store.kind,
            remotePath: store.remotePath,
            vaultID: v2.vaultID
        ))
        #expect(pull.record.lastRemoteRevision == "etag-2")
        #expect(pull.record.lastRemoteManifestRevision == 2)
        #expect(pull.record.lastRemoteContentSHA256 == v2.sha256)
        #expect(pull.record.lastSyncedAt == engineReferenceDate)
        // The app has not written the bytes yet, so the local side still differs.
        #expect(pull.record.lastLocalContentSHA256 == v1.sha256)
        #expect(pull.record.lastLocalContentSHA256 != v2.sha256)
    }

    @Test func pullReturnsNilWhenRemoteDigestMatchesBaseline() async throws {
        let store = EngineFakeRemoteStore()
        let v1 = try engineSnapshot("v1")
        store.seed(manifest: engineManifest(for: v1, revision: 1), vaultData: v1.data)

        let outcome = try await engine.pull(store: store, record: engineBaselineRecord(for: v1))
        #expect(outcome == nil)
        #expect(store.recordedCalls == ["readRemote"])
    }

    @Test func pullThrowsWhenRemoteManifestIsMissing() async throws {
        let store = EngineFakeRemoteStore()
        await #expect(throws: CloudVaultError.remoteManifestMissing) {
            try await engine.pull(store: store, record: nil)
        }
    }

    @Test func pullPropagatesIntegrityFailureFromStore() async throws {
        let store = EngineFakeRemoteStore()
        let v1 = try engineSnapshot("v1")
        let v2 = try engineSnapshot("v2")
        // Manifest claims v2 bytes but the stored file is still v1: the store
        // must reject the download and the engine must not hand the bytes back.
        store.seed(manifest: engineManifest(for: v2, revision: 2), vaultData: v1.data)

        do {
            _ = try await engine.pull(store: store, record: engineBaselineRecord(for: v1, manifestRevision: 0))
            Issue.record("expected integrityMismatch")
        } catch let error as CloudVaultError {
            guard case .integrityMismatch(let expected, let actual) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(expected == v2.sha256)
            #expect(actual == v1.sha256)
        }
    }

    @Test func pullRefusesToAdoptAnotherVaultsBytes() async throws {
        let store = EngineFakeRemoteStore()
        let local = try engineSnapshot("v1")
        let foreign = try engineSnapshot("other-vault", vaultID: "vault-2")
        store.seed(manifest: engineManifest(for: foreign, revision: 5), vaultData: foreign.data)

        await #expect(throws: CloudVaultError.vaultIDMismatch(
            expectedVaultID: local.vaultID,
            actualVaultID: foreign.vaultID
        )) {
            try await engine.pull(store: store, record: engineBaselineRecord(for: local))
        }
        #expect(store.recordedCalls == ["readRemote"])
    }

    @Test func confirmPullAppliedRecordsDigestOfPulledBytes() throws {
        let v1 = try engineSnapshot("v1")
        let v2 = try engineSnapshot("v2")
        let record = engineBaselineRecord(for: v1)
        let outcome = CloudVaultPullOutcome(
            remote: engineRemoteFile(manifest: engineManifest(for: v2, revision: 2), revision: "etag-2"),
            vaultData: v2.data,
            record: engineRecord(
                local: v1,
                remoteRevision: "etag-2",
                manifestRevision: 2,
                remoteContentSHA256: v2.sha256,
                localContentSHA256: v1.sha256
            )
        )

        let confirmed = try engine.confirmPullApplied(outcome)
        #expect(confirmed.lastLocalContentSHA256 == v2.sha256)
        #expect(confirmed.lastLocalContentSHA256 == LanSyncEncoding.hex(
            LanSyncEncoding.sha256(v2.data)
        ))
        #expect(confirmed.lastRemoteContentSHA256 == v2.sha256)
        #expect(confirmed.lastSyncedAt == engineReferenceDate)
        #expect(confirmed.pendingUpload == false)
        #expect(confirmed.lastFailureMessage == nil)
        #expect(record.lastLocalContentSHA256 == v1.sha256)

        // Re-planning after the apply reports "nothing to do".
        let remote = engineRemoteFile(manifest: engineManifest(for: v2, revision: 2), revision: "etag-2")
        #expect(engine.plan(local: v2, record: confirmed, remote: remote) == .upToDate)
    }

    // MARK: Conflict resolution

    @Test func resolveConflictKeepRemoteDownloadsRemoteBytes() async throws {
        let store = EngineFakeRemoteStore()
        let v1 = try engineSnapshot("v1")
        let v2 = try engineSnapshot("v2")
        store.seed(manifest: engineManifest(for: v2, revision: 2), vaultData: v2.data)

        let outcome = try await engine.resolveConflict(
            .keepRemote,
            local: v1,
            store: store,
            record: engineBaselineRecord(for: v1)
        )

        #expect(outcome.resolution == .keepRemote)
        #expect(outcome.conflictCopyReceipt == nil)
        #expect(outcome.pushOutcome == nil)
        let pull = try #require(outcome.pullOutcome)
        #expect(pull.vaultData == v2.data)
        #expect(pull.record.lastRemoteManifestRevision == 2)
        // Still pending application: the local digest remains the old one.
        #expect(pull.record.lastLocalContentSHA256 == v1.sha256)
        #expect(store.recordedCalls == ["readRemote", "downloadVault"])
    }

    @Test func resolveConflictCreateCopyWritesCopyBeforePulling() async throws {
        let store = EngineFakeRemoteStore()
        let v1 = try engineSnapshot("v1")
        let v2 = try engineSnapshot("v2")
        store.seed(manifest: engineManifest(for: v2, revision: 2), vaultData: v2.data)
        let record = engineBaselineRecord(for: v1)

        let outcome = try await engine.resolveConflict(
            .createConflictCopy,
            local: v1,
            store: store,
            record: record
        )

        #expect(outcome.resolution == .createConflictCopy)
        #expect(outcome.pushOutcome == nil)
        let receipt = try #require(outcome.conflictCopyReceipt)
        let pull = try #require(outcome.pullOutcome)
        #expect(pull.vaultData == v2.data)

        // Order matters: the local bytes are preserved upstream before the remote
        // version replaces them locally.
        #expect(store.recordedCalls == ["readRemote", "writeConflictCopy", "readRemote", "downloadVault"])
        let calls = store.recordedCalls
        let copyIndex = try #require(calls.firstIndex(of: "writeConflictCopy"))
        let downloadIndex = try #require(calls.firstIndex(of: "downloadVault"))
        #expect(copyIndex < downloadIndex)

        let copyCalls = store.conflictCopies
        #expect(copyCalls.count == 1)
        let copyCall = try #require(copyCalls.first)
        #expect(copyCall.vaultData == v1.data)
        #expect(copyCall.manifest.contentSHA256 == v1.sha256)
        #expect(copyCall.manifest.revision == 2) // side artefact, never newer
        #expect(copyCall.manifest.vaultID == v1.vaultID)
        #expect(copyCall.deviceName == "iPhone")
        #expect(copyCall.now == engineReferenceDate)
        #expect(receipt.manifest.contentSHA256 == v1.sha256)
        #expect(receipt.fileName.hasPrefix(CloudVaultProtocolSpec.conflictCopyPrefix))

        // The conflict copy is a side artefact: the vault slot still holds v2.
        #expect(store.storedManifest?.revision == 2)
        #expect(store.storedVaultData == v2.data)
    }

    @Test func resolveConflictKeepLocalOverwritesRemoteWithNextRevision() async throws {
        let store = EngineFakeRemoteStore()
        let v1 = try engineSnapshot("v1")
        let v2 = try engineSnapshot("v2")
        let remoteVault = try engineSnapshot("remote")
        store.seed(manifest: engineManifest(for: remoteVault, revision: 4), vaultData: remoteVault.data)
        let record = engineBaselineRecord(for: v1, remoteRevision: "etag-4", manifestRevision: 4)

        let outcome = try await engine.resolveConflict(
            .keepLocal,
            local: v2,
            store: store,
            record: record
        )

        #expect(outcome.resolution == .keepLocal)
        #expect(outcome.conflictCopyReceipt == nil)
        #expect(outcome.pullOutcome == nil)
        #expect(store.recordedCalls == ["readRemote", "updateRemote"])
        #expect(store.updateCalls == [EngineFakeRemoteStore.UpdateCall(
            expectedRevision: "etag-4",
            manifestRevision: 5
        )])
        #expect(store.storedManifest?.revision == 5)
        #expect(store.storedVaultData == v2.data)
        #expect(store.storedManifest?.contentSHA256 == v2.sha256)

        let push = try #require(outcome.pushOutcome)
        #expect(push.receipt.manifest.revision == 5)
        #expect(push.record.lastLocalContentSHA256 == v2.sha256)
        #expect(push.record.lastRemoteContentSHA256 == v2.sha256)
        #expect(push.record.lastRemoteManifestRevision == 5)
        #expect(push.record.lastRemoteRevision == "etag-5")
        #expect(push.record.lastSyncedAt == engineReferenceDate)
        #expect(push.record.pendingUpload == false)
    }

    @Test func resolveConflictKeepRemoteRefusesAForeignVault() async throws {
        let store = EngineFakeRemoteStore()
        let local = try engineSnapshot("v1")
        let foreign = try engineSnapshot("other", vaultID: "vault-2")
        store.seed(manifest: engineManifest(for: foreign, revision: 3), vaultData: foreign.data)

        await #expect(throws: CloudVaultError.vaultIDMismatch(
            expectedVaultID: local.vaultID,
            actualVaultID: foreign.vaultID
        )) {
            try await engine.resolveConflict(.keepRemote, local: local, store: store, record: nil)
        }
    }

    // MARK: Failure bookkeeping

    @Test func recordFailureMarksRetryableFailuresAsPendingUpload() throws {
        let local = try engineSnapshot("v1")
        let record = engineBaselineRecord(for: local)

        let network = engine.recordFailure(CloudVaultError.network("连接超时"), in: record)
        #expect(network.pendingUpload)
        #expect(network.lastFailureMessage == CloudVaultError.network("连接超时").localizedDescription)
        #expect(network.lastLocalContentSHA256 == record.lastLocalContentSHA256)
        #expect(network.key == record.key)

        let server = engine.recordFailure(CloudVaultError.server(statusCode: 503, message: "稍后重试"), in: record)
        #expect(server.pendingUpload)
        #expect(server.lastFailureMessage != nil)

        let precondition = engine.recordFailure(
            CloudVaultError.preconditionFailed(remoteRevision: "etag-2"),
            in: record
        )
        #expect(precondition.pendingUpload)
        #expect(precondition.lastFailureMessage == CloudVaultError.preconditionFailed(remoteRevision: "etag-2").localizedDescription)

        // Non-retryable failures keep the existing pending flag untouched.
        let unauthorized = engine.recordFailure(CloudVaultError.unauthorized(.oneDrive), in: record)
        #expect(unauthorized.pendingUpload == false)
        #expect(unauthorized.lastFailureMessage != nil)

        var pendingRecord = record
        pendingRecord.pendingUpload = true
        let integrity = engine.recordFailure(
            CloudVaultError.integrityMismatch(expectedSHA256: "aa", actualSHA256: "bb"),
            in: pendingRecord
        )
        #expect(integrity.pendingUpload) // unchanged
        #expect(integrity.lastFailureMessage != nil)

        // Non-CloudVaultError failures still record a message.
        struct PlainError: Error, LocalizedError {
            var errorDescription: String? { "plain failure" }
        }
        let plain = engine.recordFailure(PlainError(), in: record)
        #expect(plain.lastFailureMessage == "plain failure")
        #expect(plain.pendingUpload == false)
    }

    // MARK: State store

    @Test func stateStoreRoundTripsAndCreatesItsDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudvault-state-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent(CloudVaultProtocolSpec.syncStateFileName)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CloudVaultStateStore(fileURL: fileURL)

        // Missing file means "never synced": an empty ledger, not an error.
        let initial = try store.load()
        #expect(initial == CloudVaultSyncState())
        #expect(initial.records.isEmpty)
        #expect(initial.formatVersion == CloudVaultProtocolSpec.formatVersion)

        let local = try engineSnapshot("v1")
        var state = CloudVaultSyncState()
        let record = engineBaselineRecord(for: local)
        state.setRecord(record)
        state.setRecord(engineRecord(
            local: local,
            remoteRevision: nil,
            manifestRevision: 7,
            remoteContentSHA256: local.sha256,
            localContentSHA256: local.sha256,
            pendingUpload: true,
            lastFailureMessage: "上次上传失败",
            kind: .oneDrive,
            remotePath: "backup/Monica.mdbx"
        ))

        try store.save(state)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        let reloaded = try store.load()
        #expect(reloaded == state)
        #expect(reloaded.record(forKey: record.key) == record)

        // Pretty-printed JSON with sorted keys keeps the file diffable.
        let raw = try Data(contentsOf: fileURL)
        let text = String(decoding: raw, as: UTF8.self)
        #expect(text.contains("\n"))
        let formatVersionKey = try #require(text.range(of: "\"formatVersion\""))
        let recordsKey = try #require(text.range(of: "\"records\""))
        #expect(formatVersionKey.lowerBound < recordsKey.lowerBound)
    }

    @Test func stateStoreReportsCorruptJSONAsStateCorrupted() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudvault-state-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent(CloudVaultProtocolSpec.syncStateFileName)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CloudVaultStateStore(fileURL: fileURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try Data("this is not json".utf8).write(to: fileURL)
        engineExpectStateCorrupted { try store.load() }

        try Data().write(to: fileURL)
        engineExpectStateCorrupted { try store.load() }
    }

    @Test func stateStoreRejectsUnsupportedFormatVersion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloudvault-state-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent(CloudVaultProtocolSpec.syncStateFileName)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CloudVaultStateStore(fileURL: fileURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let futureState = CloudVaultSyncState(
            formatVersion: CloudVaultProtocolSpec.formatVersion + 1,
            records: [:]
        )
        try CloudVaultJSON.encode(futureState).write(to: fileURL)
        engineExpectStateCorrupted { try store.load() }

        // A state that still decodes with the supported version loads fine.
        try store.save(CloudVaultSyncState())
        #expect(try store.load() == CloudVaultSyncState())
    }
}
