import Foundation

// MARK: - iCloud (CloudKit) cloud vault store (issue #76)
//
// `CloudKitCloudVaultRemoteStore` is a `CloudVaultRemoteStore`, exactly like the
// WebDAV and OneDrive adapters: `CloudVaultSyncEngine` keeps owning the revision
// plan, the conflict rules and the sync ledger. The only thing this file adds is
// the CloudKit object model — one `MonicaVault` record per vault in a custom zone
// of the private database, whose asset is the complete encrypted MDBX file.
//
// Rules inherited from `CloudVaultAdapters.swift` and kept here:
//
// 1. the encrypted bytes are written before the record metadata is trusted: the
//    digest and byte count in the record must match the downloaded asset, and a
//    mismatch is reported as `.integrityMismatch` instead of being applied;
// 2. writes are conditional: create uses "record must not exist", update uses the
//    `recordChangeTag` that was read, so two devices cannot silently overwrite
//    each other (CloudKit answers `.serverRecordChanged`);
// 3. conflict copies are separate records with a deterministic name derived from
//    the ciphertext digest and the capture time, so a retry does not spam the zone;
// 4. nothing here downloads the asset for a status check, and no vault bytes,
//    digests of plaintext, credentials or manifest contents are ever logged.

/// The iCloud private-database adapter for `CloudVaultRemoteStore`.
public struct CloudKitCloudVaultRemoteStore: CloudVaultRemoteStore {
    public var kind: CloudVaultRemoteKind { .iCloud }
    public let displayName: String = "iCloud"
    public let remotePath: String

    public let configuration: CloudKitVaultConfiguration

    private let transport: any CloudKitVaultTransport

    public init(configuration: CloudKitVaultConfiguration, transport: any CloudKitVaultTransport) {
        self.configuration = configuration
        self.remotePath = configuration.remotePath
        self.transport = transport
    }

    // MARK: - Reading

    /// Reads metadata only. The asset is not downloaded here: a "check the cloud"
    /// action must not pull the whole vault.
    public func readRemote() async throws -> CloudVaultRemoteFile? {
        let record: CloudKitVaultRecord?
        do {
            record = try await transport.fetchRecord(configuration, recordName: configuration.recordName)
        } catch let failure as CloudKitVaultFailure {
            // A missing zone or record is "no cloud vault yet", not an error: the
            // engine turns that into a first push.
            switch failure {
            case .zoneNotFound, .userDeletedZone, .recordNotFound:
                return nil
            default:
                throw map(failure, operation: .read)
            }
        } catch {
            throw CloudVaultError.network(CloudKitVaultFailure.truncate(error.localizedDescription))
        }
        guard let record else { return nil }
        try validate(record)
        return remoteFile(for: record)
    }

    /// Downloads the encrypted asset and verifies it against the record digest.
    public func downloadVault(_ remote: CloudVaultRemoteFile) async throws -> Data {
        let recordName = remote.itemID ?? configuration.recordName
        let data: Data
        do {
            data = try await transport.downloadAsset(configuration, recordName: recordName)
        } catch let failure as CloudKitVaultFailure {
            throw map(failure, operation: .download)
        } catch {
            throw CloudVaultError.network(CloudKitVaultFailure.truncate(error.localizedDescription))
        }
        guard data.count <= CloudVaultProtocolSpec.maxVaultBytes else {
            throw CloudVaultError.vaultTooLarge(byteCount: data.count)
        }
        try verifyCloudVaultIntegrity(data, manifest: remote.manifest)
        return data
    }

    // MARK: - Writing

    public func createRemote(vaultData: Data, manifest: CloudVaultManifest) async throws -> CloudVaultWriteReceipt {
        let payload = try makePayload(vaultData: vaultData, manifest: manifest)
        // A fresh vault is the one place where a missing zone is expected.
        do {
            try await transport.ensureZone(configuration)
        } catch let failure as CloudKitVaultFailure {
            throw map(failure, operation: .save)
        }
        let record = try await save(
            recordName: configuration.recordName,
            payload: payload,
            vaultData: vaultData,
            condition: .createOnly
        )
        return receipt(for: record)
    }

    public func updateRemote(
        vaultData: Data,
        manifest: CloudVaultManifest,
        remote: CloudVaultRemoteFile
    ) async throws -> CloudVaultWriteReceipt {
        guard let changeTag = remote.revision, !changeTag.isEmpty else {
            // Without the tag a conditional write is impossible; refuse instead of
            // overwriting whatever another device stored in the meantime.
            throw CloudVaultError.preconditionFailed(remoteRevision: nil)
        }
        let payload = try makePayload(vaultData: vaultData, manifest: manifest)
        let record = try await save(
            recordName: remote.itemID ?? configuration.recordName,
            payload: payload,
            vaultData: vaultData,
            condition: .ifUnchanged(changeTag: changeTag)
        )
        return receipt(for: record)
    }

    public func writeConflictCopy(
        vaultData: Data,
        manifest: CloudVaultManifest,
        deviceName: String,
        now: Date
    ) async throws -> CloudVaultWriteReceipt {
        _ = deviceName // never stored: a device name would be plaintext in the cloud
        let payload = try makePayload(vaultData: vaultData, manifest: manifest)
        let stamp = CloudVaultNaming.timestampString(now)
        let token = CloudVaultNaming.conflictCopyToken(sha256: manifest.contentSHA256, date: now)
        let baseName = "\(CloudKitVaultSpec.conflictCopyPrefix)\(stamp)-\(token)"
        var lastFailure: CloudKitVaultFailure = .conflict(serverChangeTag: nil)
        for attempt in 0...8 {
            let recordName = attempt == 0 ? baseName : "\(baseName)-\(attempt)"
            do {
                let record = try await save(
                    recordName: recordName,
                    payload: payload,
                    vaultData: vaultData,
                    condition: .createOnly
                )
                return receipt(for: record)
            } catch let failure as CloudKitVaultFailure {
                lastFailure = failure
                if case .conflict = failure { continue }
                throw map(failure, operation: .conflictCopy)
            } catch let error as CloudVaultError {
                // `save` already maps transport failures, so a name collision
                // arrives here as `.preconditionFailed` rather than a raw failure.
                guard case .preconditionFailed = error else { throw error }
                // Retrying the same conflict resolution must not duplicate the
                // copy: when the existing record already holds this ciphertext,
                // its receipt is the answer.
                if let existing = try? await transport.fetchRecord(configuration, recordName: recordName),
                   existing.payload.contentSHA256 == payload.contentSHA256,
                   existing.payload.byteCount == payload.byteCount {
                    return receipt(for: existing)
                }
                continue
            } catch {
                throw CloudVaultError.network(CloudKitVaultFailure.truncate(error.localizedDescription))
            }
        }
        throw map(lastFailure, operation: .conflictCopy)
    }

    // MARK: - Account state and incremental changes

    /// Asks CloudKit whether this device can use the private database right now.
    public func accountAvailability() async throws -> CloudKitAccountAvailability {
        do {
            return try await transport.accountAvailability()
        } catch let failure as CloudKitVaultFailure {
            throw map(failure, operation: .availability)
        } catch {
            throw CloudVaultError.network(CloudKitVaultFailure.truncate(error.localizedDescription))
        }
    }

    /// Pulls the zone changes that happened since `changeToken`. Used by the manual
    /// "check iCloud changes" action; the token is opaque and only ever compared.
    public func pollChanges(since changeToken: Data?) async throws -> CloudKitZoneChangeSet {
        do {
            return try await transport.fetchZoneChanges(configuration, since: changeToken)
        } catch let failure as CloudKitVaultFailure {
            throw map(failure, operation: .changes)
        } catch {
            throw CloudVaultError.network(CloudKitVaultFailure.truncate(error.localizedDescription))
        }
    }

    // MARK: - Helpers

    private enum Operation {
        case read
        case download
        case save
        case conflictCopy
        case changes
        case availability
    }

    /// Builds the record metadata and checks that the bytes really are the
    /// encrypted vault the manifest describes before anything leaves the device.
    private func makePayload(vaultData: Data, manifest: CloudVaultManifest) throws -> CloudKitRecordPayload {
        guard vaultData.count <= CloudVaultProtocolSpec.maxVaultBytes else {
            throw CloudVaultError.vaultTooLarge(byteCount: vaultData.count)
        }
        try verifyCloudVaultIntegrity(vaultData, manifest: manifest)
        let payload = CloudKitRecordPayload(manifest: manifest)
        try payload.validate()
        return payload
    }

    private func save(
        recordName: String,
        payload: CloudKitRecordPayload,
        vaultData: Data,
        condition: CloudKitSaveCondition
    ) async throws -> CloudKitVaultRecord {
        do {
            return try await transport.saveRecord(
                configuration,
                recordName: recordName,
                payload: payload,
                vaultData: vaultData,
                condition: condition
            )
        } catch let failure as CloudKitVaultFailure where failure == .limitExceeded {
            throw CloudVaultError.vaultTooLarge(byteCount: vaultData.count)
        } catch let failure as CloudKitVaultFailure {
            throw map(failure, operation: .save)
        } catch {
            throw CloudVaultError.network(CloudKitVaultFailure.truncate(error.localizedDescription))
        }
    }

    private func validate(_ record: CloudKitVaultRecord) throws {
        guard record.recordName == configuration.recordName else {
            throw CloudVaultError.manifestInvalid(reason: "CloudKit 返回了非预期的记录")
        }
        try record.payload.validate()
        guard !record.changeTag.isEmpty else {
            throw CloudVaultError.manifestInvalid(reason: "CloudKit 记录缺少变更标记")
        }
    }

    private func remoteFile(for record: CloudKitVaultRecord) -> CloudVaultRemoteFile {
        CloudVaultRemoteFile(
            kind: .iCloud,
            remotePath: configuration.remotePath,
            fileName: record.recordName,
            manifestFileName: record.recordName,
            itemID: record.recordName,
            revision: record.changeTag,
            manifestRevision: String(record.revision),
            manifest: record.payload.redactedManifest
        )
    }

    private func receipt(for record: CloudKitVaultRecord) -> CloudVaultWriteReceipt {
        CloudVaultWriteReceipt(
            kind: .iCloud,
            remotePath: configuration.remotePath,
            fileName: record.recordName,
            manifestFileName: record.recordName,
            itemID: record.recordName,
            revision: record.changeTag,
            manifestRevision: String(record.revision),
            manifest: record.payload.redactedManifest
        )
    }

    /// Translates a CloudKit failure into the shared error vocabulary so the app
    /// can show one status model for every provider.
    private func map(_ failure: CloudKitVaultFailure, operation: Operation) -> CloudVaultError {
        switch failure {
        case .notAuthenticated, .accountTemporarilyUnavailable:
            return .cloudAccountUnavailable(.iCloud)
        case .missingEntitlement, .badContainer:
            return .notConfigured(reason: failure.redactedMessage)
        case .quotaExceeded:
            return .cloudQuotaExceeded(.iCloud)
        case .limitExceeded:
            return .server(statusCode: 413, message: failure.redactedMessage)
        case .networkUnavailable(let message), .transient(let message):
            return .network(CloudKitVaultFailure.truncate(message))
        case .zoneNotFound, .userDeletedZone:
            switch operation {
            case .read, .changes:
                return .remoteManifestMissing
            default:
                return .remoteVaultMissing
            }
        case .recordNotFound:
            return operation == .read ? .remoteManifestMissing : .remoteVaultMissing
        case .conflict(let serverChangeTag):
            return .preconditionFailed(remoteRevision: serverChangeTag)
        case .assetUnavailable:
            return .remoteVaultMissing
        case .permissionDenied:
            return .forbidden(.iCloud)
        case .rejected(let message):
            return .server(statusCode: 400, message: CloudKitVaultFailure.truncate(message))
        case .malformed(let message):
            return .manifestInvalid(reason: CloudKitVaultFailure.truncate(message))
        case .changeTokenExpired:
            return .network(failure.redactedMessage)
        }
    }
}

extension CloudKitVaultFailure: LocalizedError {
    public var errorDescription: String? { redactedMessage }
}
