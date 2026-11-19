import Foundation

// MARK: - Durable sync ledger

/// JSON persistence for the per-device cloud-vault sync ledger.
///
/// The store owns exactly one file (`CloudVaultProtocolSpec.syncStateFileName` in
/// the app's support directory) and never touches the network. Reads are total:
/// a missing file means "this device never synced yet", while an unreadable or
/// version-skewed file is reported as `stateCorrupted` instead of silently
/// resetting the ledger. A silent reset would make the next upload look like a
/// first-time publish and could clobber a newer remote revision.
public struct CloudVaultStateStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> CloudVaultSyncState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return CloudVaultSyncState()
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw CloudVaultError.stateCorrupted(reason: "无法读取同步记录文件：\(error.localizedDescription)")
        }
        do {
            let state = try CloudVaultJSON.decode(CloudVaultSyncState.self, from: data)
            guard state.formatVersion == CloudVaultProtocolSpec.formatVersion else {
                throw CloudVaultError.stateCorrupted(
                    reason: "同步记录版本 \(state.formatVersion) 不受支持（当前 \(CloudVaultProtocolSpec.formatVersion)）"
                )
            }
            return state
        } catch let error as CloudVaultError {
            throw error
        } catch {
            throw CloudVaultError.stateCorrupted(reason: "同步记录不是有效的 JSON：\(error.localizedDescription)")
        }
    }

    /// Writes the ledger atomically, creating the containing directory when needed.
    /// Persistence failures are surfaced as `stateCorrupted` so callers only have
    /// to understand one error family for "the ledger could not be used".
    public func save(_ state: CloudVaultSyncState) throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw CloudVaultError.stateCorrupted(reason: "无法创建同步记录目录：\(error.localizedDescription)")
        }
        let encoder = CloudVaultJSON.encoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(state)
        } catch {
            throw CloudVaultError.stateCorrupted(reason: "无法编码同步记录：\(error.localizedDescription)")
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw CloudVaultError.stateCorrupted(reason: "无法写入同步记录文件：\(error.localizedDescription)")
        }
    }
}

// MARK: - Sync engine

/// Pure decision logic plus the orchestration that turns a decision into remote
/// calls. The engine never touches the local vault file: callers hand in an
/// immutable `CloudVaultLocalSnapshot` and persist/apply the returned bytes.
///
/// Error policy:
/// - `push` refuses to overwrite when the remote moved and only throws
///   `.preconditionFailed` in that case, so the app can tell "re-check and pull"
///   apart from "user must choose a resolution" (`.conflictRequiresResolution`);
/// - `pull` returns `nil` when the remote digest already equals the recorded one,
///   which makes repeated pulls idempotent;
/// - conflict resolution is explicit (`.keepLocal`, `.keepRemote`,
///   `.createConflictCopy`) because the engine cannot know which side the user
///   considers authoritative.
public struct CloudVaultSyncEngine: Sendable {
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    // MARK: Planning

    public func plan(
        local: CloudVaultLocalSnapshot,
        record: CloudVaultSyncRecord?,
        remote: CloudVaultRemoteFile?
    ) -> CloudVaultSyncDecision {
        guard let remote else {
            guard let record else { return .pushNew }
            // The remote vault vanished. If the local snapshot matches the last
            // synced digest the user only needs to re-publish; otherwise the
            // deletion happened after local edits and the user must decide.
            return .conflict(
                CloudVaultConflict(
                    reason: .remoteRemoved,
                    localChanged: record.lastLocalContentSHA256 != local.sha256,
                    remoteChanged: true,
                    baselineManifestRevision: record.lastRemoteManifestRevision,
                    remoteManifestRevision: 0,
                    remoteRevision: nil,
                    localContentSHA256: local.sha256,
                    remoteContentSHA256: record.lastRemoteContentSHA256
                )
            )
        }

        let manifest = remote.manifest
        // A remote file that belongs to another vault is never merged or
        // overwritten silently: both sides are reported as changed so the user
        // gets an explicit choice.
        guard manifest.vaultID == local.vaultID else {
            return .conflict(
                CloudVaultConflict(
                    reason: .vaultIdentityMismatch,
                    localChanged: true,
                    remoteChanged: true,
                    baselineManifestRevision: record?.lastRemoteManifestRevision,
                    remoteManifestRevision: manifest.revision,
                    remoteRevision: remote.revision,
                    localContentSHA256: local.sha256,
                    remoteContentSHA256: manifest.contentSHA256
                )
            )
        }

        guard let record else {
            // Same bytes on both sides: the vault was most likely restored from
            // this remote, so adopt it as the baseline instead of asking.
            guard manifest.contentSHA256 != local.sha256 else { return .upToDate }
            return .conflict(
                CloudVaultConflict(
                    reason: .noBaseline,
                    localChanged: true,
                    remoteChanged: true,
                    baselineManifestRevision: nil,
                    remoteManifestRevision: manifest.revision,
                    remoteRevision: remote.revision,
                    localContentSHA256: local.sha256,
                    remoteContentSHA256: manifest.contentSHA256
                )
            )
        }

        let localChanged = record.lastLocalContentSHA256 != local.sha256
        let remoteChanged = Self.remoteChanged(record: record, remote: remote)

        switch (localChanged, remoteChanged) {
        case (false, false):
            return .upToDate
        case (true, false):
            return .pushUpdate
        case (false, true):
            return .pullRemoteNewer
        case (true, true):
            return .conflict(
                CloudVaultConflict(
                    reason: .bothChanged,
                    localChanged: true,
                    remoteChanged: true,
                    baselineManifestRevision: record.lastRemoteManifestRevision,
                    remoteManifestRevision: manifest.revision,
                    remoteRevision: remote.revision,
                    localContentSHA256: local.sha256,
                    remoteContentSHA256: manifest.contentSHA256
                )
            )
        }
    }

    // MARK: Push

    public func push(
        local: CloudVaultLocalSnapshot,
        store: any CloudVaultRemoteStore,
        record: CloudVaultSyncRecord?
    ) async throws -> CloudVaultPushOutcome? {
        let remote = try await store.readRemote()
        switch plan(local: local, record: record, remote: remote) {
        case .upToDate:
            return nil
        case .conflict(let conflict):
            throw CloudVaultError.conflictRequiresResolution(conflict)
        case .pullRemoteNewer:
            // The remote moved while this device stayed still. Uploading now
            // would discard the other device's revision, so the caller must pull
            // first (then re-plan). This is deliberately *not* a conflict: no
            // user decision is required.
            throw CloudVaultError.preconditionFailed(remoteRevision: remote?.revision)
        case .pushNew:
            let manifest = CloudVaultManifest.make(local: local, revision: 1)
            let receipt = try await store.createRemote(vaultData: local.data, manifest: manifest)
            return CloudVaultPushOutcome(
                receipt: receipt,
                record: Self.recordAfterPush(local: local, store: store, receipt: receipt, now: now())
            )
        case .pushUpdate:
            guard let remote else { throw CloudVaultError.remoteManifestMissing }
            let manifest = CloudVaultManifest.make(local: local, revision: remote.manifest.revision + 1)
            let receipt = try await store.updateRemote(vaultData: local.data, manifest: manifest, remote: remote)
            return CloudVaultPushOutcome(
                receipt: receipt,
                record: Self.recordAfterPush(local: local, store: store, receipt: receipt, now: now())
            )
        }
    }

    /// Baseline record for a successful upload. `lastLocalContentSHA256` is the
    /// digest of the bytes that were just uploaded, so the next plan call sees an
    /// unchanged local side.
    public static func recordAfterPush(
        local: CloudVaultLocalSnapshot,
        store: any CloudVaultRemoteStore,
        receipt: CloudVaultWriteReceipt,
        now: Date
    ) -> CloudVaultSyncRecord {
        CloudVaultSyncRecord(
            key: CloudVaultSyncRecord.key(
                remoteKind: store.kind,
                remotePath: store.remotePath,
                vaultID: local.vaultID
            ),
            vaultID: local.vaultID,
            remoteKind: store.kind,
            remotePath: store.remotePath,
            lastRemoteRevision: receipt.revision,
            lastRemoteManifestRevision: receipt.manifest.revision,
            lastRemoteContentSHA256: receipt.manifest.contentSHA256,
            lastLocalContentSHA256: local.sha256,
            lastSyncedAt: now,
            pendingUpload: false,
            lastFailureMessage: nil
        )
    }

    // MARK: Pull

    /// Downloads the remote vault bytes. The returned record deliberately keeps
    /// the previous `lastLocalContentSHA256`: the caller has not applied the bytes
    /// yet, so the local side must still count as changed until
    /// `confirmPullApplied` is called. Returns `nil` when the remote digest equals
    /// the recorded baseline (nothing new to pull).
    public func pull(
        store: any CloudVaultRemoteStore,
        record: CloudVaultSyncRecord?
    ) async throws -> CloudVaultPullOutcome? {
        guard let remote = try await store.readRemote() else {
            throw CloudVaultError.remoteManifestMissing
        }
        // Refuse to hand back bytes that would replace the local vault with a
        // different vault's contents.
        if let record, record.vaultID != remote.manifest.vaultID {
            throw CloudVaultError.vaultIDMismatch(
                expectedVaultID: record.vaultID,
                actualVaultID: remote.manifest.vaultID
            )
        }
        if let record, record.lastRemoteContentSHA256 == remote.manifest.contentSHA256 {
            return nil
        }
        let vaultData = try await store.downloadVault(remote)
        let updatedRecord = CloudVaultSyncRecord(
            key: CloudVaultSyncRecord.key(
                remoteKind: store.kind,
                remotePath: store.remotePath,
                vaultID: remote.manifest.vaultID
            ),
            vaultID: remote.manifest.vaultID,
            remoteKind: store.kind,
            remotePath: store.remotePath,
            lastRemoteRevision: remote.revision,
            lastRemoteManifestRevision: remote.manifest.revision,
            lastRemoteContentSHA256: remote.manifest.contentSHA256,
            lastLocalContentSHA256: record?.lastLocalContentSHA256,
            lastSyncedAt: now(),
            pendingUpload: record?.pendingUpload ?? false,
            lastFailureMessage: nil
        )
        return CloudVaultPullOutcome(remote: remote, vaultData: vaultData, record: updatedRecord)
    }

    /// Called once the app has written the pulled bytes to the local vault file.
    /// Only now does the local side become the baseline again.
    public func confirmPullApplied(_ outcome: CloudVaultPullOutcome) throws -> CloudVaultSyncRecord {
        var record = outcome.record
        record.lastLocalContentSHA256 = LanSyncEncoding.hex(LanSyncEncoding.sha256(outcome.vaultData))
        record.lastSyncedAt = now()
        record.pendingUpload = false
        record.lastFailureMessage = nil
        return record
    }

    // MARK: Conflict resolution

    public func resolveConflict(
        _ resolution: CloudVaultConflictResolution,
        local: CloudVaultLocalSnapshot,
        store: any CloudVaultRemoteStore,
        record: CloudVaultSyncRecord?
    ) async throws -> CloudVaultConflictOutcome {
        switch resolution {
        case .keepRemote:
            // Adopting the remote rewrites the local vault, so a remote that
            // belongs to another vault is refused instead of silently replacing
            // the user's vault.
            guard let pullOutcome = try await pull(store: store, record: record) else {
                throw CloudVaultError.remoteManifestMissing
            }
            try Self.requireSameVaultIdentity(local: local, remote: pullOutcome.remote)
            return CloudVaultConflictOutcome(resolution: .keepRemote, pullOutcome: pullOutcome)

        case .createConflictCopy:
            guard let remote = try await store.readRemote() else {
                throw CloudVaultError.remoteManifestMissing
            }
            try Self.requireSameVaultIdentity(local: local, remote: remote)
            // The copy reuses the remote revision number: it is a side artefact,
            // not a new revision of the vault, and must never look newer.
            let copyManifest = CloudVaultManifest.make(
                local: local,
                revision: max(1, remote.manifest.revision)
            )
            let receipt = try await store.writeConflictCopy(
                vaultData: local.data,
                manifest: copyManifest,
                deviceName: local.deviceName,
                now: now()
            )
            guard let pullOutcome = try await pull(store: store, record: record) else {
                throw CloudVaultError.remoteManifestMissing
            }
            return CloudVaultConflictOutcome(
                resolution: .createConflictCopy,
                conflictCopyReceipt: receipt,
                pullOutcome: pullOutcome
            )

        case .keepLocal:
            guard let remote = try await store.readRemote() else {
                throw CloudVaultError.remoteManifestMissing
            }
            let manifest = CloudVaultManifest.make(
                local: local,
                revision: remote.manifest.revision + 1
            )
            let receipt = try await store.updateRemote(
                vaultData: local.data,
                manifest: manifest,
                remote: remote
            )
            return CloudVaultConflictOutcome(
                resolution: .keepLocal,
                pushOutcome: CloudVaultPushOutcome(
                    receipt: receipt,
                    record: Self.recordAfterPush(local: local, store: store, receipt: receipt, now: now())
                )
            )
        }
    }

    // MARK: Failure bookkeeping

    /// Stamps a failure onto the ledger. Retryable transport failures (and a lost
    /// If-Match race) keep the upload pending so the next sync retries it;
    /// everything else (auth, integrity, invalid manifest) leaves the pending flag
    /// untouched because retrying cannot fix it.
    public func recordFailure(_ error: Error, in record: CloudVaultSyncRecord) -> CloudVaultSyncRecord {
        var updated = record
        updated.lastFailureMessage = error.localizedDescription
        if let cloudError = error as? CloudVaultError {
            switch cloudError {
            case .preconditionFailed, .network, .server:
                updated.pendingUpload = true
            default:
                break
            }
        }
        return updated
    }

    // MARK: Helpers

    /// OR of every comparable baseline signal. When the record carries no
    /// revision/digest at all the remote is treated as changed, because assuming
    /// "unchanged" would let a push overwrite a remote nobody has looked at.
    private static func remoteChanged(
        record: CloudVaultSyncRecord,
        remote: CloudVaultRemoteFile
    ) -> Bool {
        var hasComparableBaseline = false
        if let baselineRevision = record.lastRemoteRevision, let currentRevision = remote.revision {
            hasComparableBaseline = true
            if baselineRevision != currentRevision { return true }
        }
        if let baselineManifestRevision = record.lastRemoteManifestRevision {
            hasComparableBaseline = true
            if baselineManifestRevision != remote.manifest.revision { return true }
        }
        if let baselineDigest = record.lastRemoteContentSHA256 {
            hasComparableBaseline = true
            if baselineDigest != remote.manifest.contentSHA256 { return true }
        }
        return !hasComparableBaseline
    }

    private static func requireSameVaultIdentity(
        local: CloudVaultLocalSnapshot,
        remote: CloudVaultRemoteFile
    ) throws {
        guard remote.manifest.vaultID == local.vaultID else {
            throw CloudVaultError.vaultIDMismatch(
                expectedVaultID: local.vaultID,
                actualVaultID: remote.manifest.vaultID
            )
        }
    }
}
