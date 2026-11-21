import Foundation
#if canImport(CloudKit)
import CloudKit

// MARK: - CloudKit transport (issue #76)
//
// The only file in the package that imports CloudKit. Everything above it
// (`CloudKitCloudVaultRemoteStore`, the sync engine, the app) works against
// `CloudKitVaultTransport`, which is why the tests never need a signed-in account
// or a real container.
//
// Implementation notes that matter:
//
// * the private database is used, never the public or shared one: the vault is
//   only ever visible to the signed-in Apple ID;
// * a **custom zone** is required — CloudKit's default zone does not support
//   `recordZoneChanges`, which is how incremental pulls work;
// * `records(for:desiredKeys:)` fetches metadata only, so "check the cloud" never
//   downloads the asset;
// * every write is conditional. `.ifServerRecordUnchanged` is the only save
//   policy that compares `recordChangeTag`, so two devices cannot silently
//   overwrite each other — the loser gets `serverRecordChanged`;
// * `CKContainer(identifier:)` is created lazily on first real use. An app whose
//   build does not declare the iCloud entitlement cannot even construct a
//   container (CloudKit traps inside the framework), so nothing here may run at
//   launch, in `init`, or while a settings screen is merely rendered.

/// CloudKit-backed `CloudKitVaultTransport` over the private database.
///
/// `CKContainer`/`CKDatabase` are documented as thread safe; the single lazy
/// container is guarded by a lock so concurrent first calls cannot race.
public final class CloudKitContainerVaultTransport: CloudKitVaultTransport, @unchecked Sendable {
    public let containerIdentifier: String

    private let lock = NSLock()
    private var cachedContainer: CKContainer?
    private var cachedDatabase: CKDatabase?

    /// Field keys fetched for metadata-only reads. Deliberately excludes the asset.
    private static let metadataKeys: [CKRecord.FieldKey] = [
        CloudKitVaultSpec.schemaVersionKey,
        CloudKitVaultSpec.vaultIDKey,
        CloudKitVaultSpec.revisionKey,
        CloudKitVaultSpec.byteCountKey,
        CloudKitVaultSpec.contentSHA256Key,
        CloudKitVaultSpec.updatedAtKey
    ]

    /// How many `moreComing` pages a single change poll may follow.
    private static let maxChangePages = 5

    public init(containerIdentifier: String = CloudKitVaultSpec.defaultContainerIdentifier) {
        self.containerIdentifier = containerIdentifier
    }

    // MARK: - Account

    public func accountAvailability() async throws -> CloudKitAccountAvailability {
        let container = resolvedContainer()
        return try await withCheckedThrowingContinuation { continuation in
            container.accountStatus { status, error in
                if let error {
                    continuation.resume(throwing: Self.failure(from: error))
                    return
                }
                switch status {
                case .available:
                    continuation.resume(returning: .available)
                case .noAccount:
                    continuation.resume(returning: .noAccount)
                case .restricted:
                    continuation.resume(returning: .restricted)
                case .temporarilyUnavailable:
                    continuation.resume(returning: .temporarilyUnavailable)
                default:
                    continuation.resume(returning: .couldNotDetermine)
                }
            }
        }
    }

    // MARK: - Zone

    public func ensureZone(_ configuration: CloudKitVaultConfiguration) async throws {
        let zoneID = Self.zoneID(configuration)
        do {
            _ = try await database().save(CKRecordZone(zoneID: zoneID))
        } catch {
            let failure = Self.failure(from: error)
            // Re-saving an existing zone is harmless; only report real failures.
            if case .conflict = failure { return }
            throw failure
        }
    }

    // MARK: - Reading

    public func fetchRecord(
        _ configuration: CloudKitVaultConfiguration,
        recordName: String
    ) async throws -> CloudKitVaultRecord? {
        let recordID = CKRecord.ID(recordName: recordName, zoneID: Self.zoneID(configuration))
        let results: [CKRecord.ID: Result<CKRecord, Error>]
        do {
            results = try await database().records(for: [recordID], desiredKeys: Self.metadataKeys)
        } catch {
            throw Self.failure(from: error)
        }
        guard let result = results[recordID] else { return nil }
        switch result {
        case .success(let record):
            return try Self.metadataRecord(from: record)
        case .failure(let error):
            throw Self.failure(from: error)
        }
    }

    /// Raw metadata fetch used by the conditional-write path. Never downloads the
    /// asset, so it stays cheap even for a large vault.
    private func fetchRecordObject(_ recordID: CKRecord.ID) async throws -> CKRecord? {
        let results: [CKRecord.ID: Result<CKRecord, Error>]
        do {
            results = try await database().records(for: [recordID], desiredKeys: Self.metadataKeys)
        } catch {
            throw Self.failure(from: error)
        }
        guard let result = results[recordID] else { return nil }
        switch result {
        case .success(let record):
            return record
        case .failure(let error):
            throw Self.failure(from: error)
        }
    }

    public func downloadAsset(
        _ configuration: CloudKitVaultConfiguration,
        recordName: String
    ) async throws -> Data {
        let recordID = CKRecord.ID(recordName: recordName, zoneID: Self.zoneID(configuration))
        let record: CKRecord
        do {
            record = try await database().record(for: recordID)
        } catch {
            throw Self.failure(from: error)
        }
        guard let asset = record[CloudKitVaultSpec.assetKey] as? CKAsset, let url = asset.fileURL else {
            throw CloudKitVaultFailure.assetUnavailable("云端记录缺少保险库文件")
        }
        do {
            // The asset's temporary file disappears with the CKRecord, so it is read
            // right here; the bytes are still the encrypted vault, never plaintext.
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw CloudKitVaultFailure.assetUnavailable(CloudKitVaultFailure.truncate(error.localizedDescription))
        }
    }

    // MARK: - Writing

    public func saveRecord(
        _ configuration: CloudKitVaultConfiguration,
        recordName: String,
        payload: CloudKitRecordPayload,
        vaultData: Data,
        condition: CloudKitSaveCondition
    ) async throws -> CloudKitVaultRecord {
        let recordID = CKRecord.ID(recordName: recordName, zoneID: Self.zoneID(configuration))

        // `recordChangeTag` is read-only, so a conditional update must start from the
        // record CloudKit actually holds. Fetching it with `desiredKeys` gives us the
        // change tag *without* downloading the asset, which keeps an update cheap.
        let record: CKRecord
        let savePolicy: CKModifyRecordsOperation.RecordSavePolicy
        switch condition {
        case .createOnly:
            // No change tag ⇒ "the record must not exist yet"; an existing record
            // comes back as `serverRecordChanged` instead of being overwritten.
            record = CKRecord(recordType: CloudKitVaultSpec.recordType, recordID: recordID)
            savePolicy = .ifServerRecordUnchanged
        case .ifUnchanged(let changeTag):
            guard let existing = try await fetchRecordObject(recordID) else {
                throw CloudKitVaultFailure.recordNotFound
            }
            guard existing.recordChangeTag == changeTag else {
                throw CloudKitVaultFailure.conflict(serverChangeTag: existing.recordChangeTag)
            }
            record = existing
            // The tag from the fetch above is what makes this an optimistic write: if
            // another device saves between the fetch and this call, CloudKit answers
            // `serverRecordChanged` and the app resolves the conflict.
            savePolicy = .ifServerRecordUnchanged
        case .replaceAll:
            record = CKRecord(recordType: CloudKitVaultSpec.recordType, recordID: recordID)
            savePolicy = .allKeys
        }

        record[CloudKitVaultSpec.schemaVersionKey] = Int64(payload.schemaVersion)
        record[CloudKitVaultSpec.vaultIDKey] = payload.vaultID
        record[CloudKitVaultSpec.revisionKey] = Int64(payload.revision)
        record[CloudKitVaultSpec.byteCountKey] = Int64(payload.byteCount)
        record[CloudKitVaultSpec.contentSHA256Key] = payload.contentSHA256
        record[CloudKitVaultSpec.updatedAtKey] = payload.updatedAt

        let (assetURL, cleanup) = try Self.writeTemporaryAsset(vaultData)
        defer { cleanup() }
        record[CloudKitVaultSpec.assetKey] = CKAsset(fileURL: assetURL)

        let results: [CKRecord.ID: Result<CKRecord, Error>]
        do {
            results = try await database().modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: savePolicy,
                atomically: true
            ).saveResults
        } catch {
            throw Self.failure(from: error)
        }
        guard let result = results[recordID] else {
            throw CloudKitVaultFailure.transient("CloudKit 未返回保存结果")
        }
        switch result {
        case .success(let saved):
            return try Self.metadataRecord(from: saved)
        case .failure(let error):
            throw Self.failure(from: error)
        }
    }

    // MARK: - Incremental pull

    public func fetchZoneChanges(
        _ configuration: CloudKitVaultConfiguration,
        since changeToken: Data?
    ) async throws -> CloudKitZoneChangeSet {
        let zoneID = Self.zoneID(configuration)
        var token: CKServerChangeToken?
        if let changeToken {
            token = Self.decodeChangeToken(changeToken)
        }
        var changed: [CloudKitVaultRecord] = []
        var deleted: [String] = []
        var didReset = false
        var page = 0
        while page < Self.maxChangePages {
            page += 1
            do {
                let response = try await database().recordZoneChanges(
                    inZoneWith: zoneID,
                    since: token,
                    desiredKeys: Self.metadataKeys,
                    resultsLimit: nil
                )
                for (_, result) in response.modificationResultsByID {
                    switch result {
                    case .success(let modification):
                        changed.append(try Self.metadataRecord(from: modification.record))
                    case .failure(let error):
                        let failure = Self.failure(from: error)
                        // A record that vanished between the change and the fetch is
                        // reported as a deletion by the next page; nothing to do.
                        switch failure {
                        case .recordNotFound, .zoneNotFound, .userDeletedZone:
                            continue
                        default:
                            throw failure
                        }
                    }
                }
                for deletion in response.deletions {
                    deleted.append(deletion.recordID.recordName)
                }
                token = response.changeToken
                if !response.moreComing { break }
            } catch {
                let failure = Self.failure(from: error)
                // An expired token is recoverable once: restart from the beginning and
                // tell the caller so it can drop its cached token. A second expiry in
                // the same call is a real failure.
                if case .changeTokenExpired = failure, !didReset {
                    token = nil
                    didReset = true
                    page = 0
                    changed.removeAll()
                    deleted.removeAll()
                    continue
                }
                throw failure
            }
        }
        return CloudKitZoneChangeSet(
            changed: changed,
            deletedRecordNames: deleted,
            changeToken: token.flatMap { Self.encodeChangeToken($0) },
            didReset: didReset
        )
    }

    // MARK: - Container plumbing

    /// Creates the container on first real use. CloudKit traps inside the
    /// framework when the build has no iCloud entitlement, so this must never run
    /// eagerly (not in `init`, not at launch, not while a screen renders).
    private func resolvedContainer() -> CKContainer {
        lock.lock()
        defer { lock.unlock() }
        if let cachedContainer { return cachedContainer }
        let created = CKContainer(identifier: containerIdentifier)
        cachedContainer = created
        cachedDatabase = created.privateCloudDatabase
        return created
    }

    private func database() -> CKDatabase {
        _ = resolvedContainer()
        lock.lock()
        defer { lock.unlock() }
        // `resolvedContainer()` always fills both; the fallback keeps the compiler happy.
        return cachedDatabase ?? resolvedContainer().privateCloudDatabase
    }

    private static func zoneID(_ configuration: CloudKitVaultConfiguration) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: configuration.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    // MARK: - Record conversion

    private static func metadataRecord(from record: CKRecord) throws -> CloudKitVaultRecord {
        let unexpected = Set(record.allKeys()).subtracting(CloudKitVaultSpec.allowedRecordKeys)
        guard unexpected.isEmpty else {
            // A record carrying extra fields could be leaking plaintext; refuse it
            // instead of trusting local state to a record we do not understand.
            throw CloudKitVaultFailure.malformed("云端记录包含未预期的字段")
        }
        guard let schemaVersion = intValue(record[CloudKitVaultSpec.schemaVersionKey]),
              let vaultID = record[CloudKitVaultSpec.vaultIDKey] as? String,
              let revision = intValue(record[CloudKitVaultSpec.revisionKey]),
              let byteCount = intValue(record[CloudKitVaultSpec.byteCountKey]),
              let contentSHA256 = record[CloudKitVaultSpec.contentSHA256Key] as? String,
              let updatedAt = record[CloudKitVaultSpec.updatedAtKey] as? Date,
              let changeTag = record.recordChangeTag, !changeTag.isEmpty
        else {
            throw CloudKitVaultFailure.malformed("云端记录缺少必要的元数据")
        }
        let payload = CloudKitRecordPayload(
            schemaVersion: schemaVersion,
            vaultID: vaultID,
            revision: revision,
            byteCount: byteCount,
            contentSHA256: contentSHA256,
            updatedAt: updatedAt
        )
        return CloudKitVaultRecord(
            recordName: record.recordID.recordName,
            changeTag: changeTag,
            payload: payload
        )
    }

    private static func intValue(_ value: CKRecordValue?) -> Int? {
        if let number = value as? Int64 { return Int(number) }
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    /// Writes the encrypted vault to a temporary file for `CKAsset` and hands back
    /// the cleanup closure. The file is ciphertext and is removed immediately after
    /// the save completes.
    private static func writeTemporaryAsset(_ data: Data) throws -> (URL, () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-cloudkit-asset", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString).mdbx")
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            throw CloudKitVaultFailure.malformed("无法写入 iCloud 上传临时文件")
        }
        return (url, { try? FileManager.default.removeItem(at: url) })
    }

    // MARK: - Change token persistence

    private static func encodeChangeToken(_ token: CKServerChangeToken) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    private static func decodeChangeToken(_ data: Data) -> CKServerChangeToken? {
        guard !data.isEmpty else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    // MARK: - Error translation

    private static func failure(from error: Error) -> CloudKitVaultFailure {
        guard let cloudError = error as? CKError else {
            return .transient(CloudKitVaultFailure.truncate(error.localizedDescription))
        }
        if cloudError.code == .partialFailure || cloudError.code == .batchRequestFailed {
            if let partial = cloudError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
                for value in partial.values {
                    let nested = failure(from: value)
                    if case .transient = nested { continue }
                    return nested
                }
            }
        }
        switch cloudError.code {
        case .notAuthenticated:
            return .notAuthenticated
        case .accountTemporarilyUnavailable:
            return .accountTemporarilyUnavailable
        case .missingEntitlement:
            return .missingEntitlement
        case .badContainer, .invalidArguments:
            return .badContainer
        case .quotaExceeded:
            return .quotaExceeded
        case .limitExceeded:
            return .limitExceeded
        case .networkUnavailable, .networkFailure:
            return .networkUnavailable(CloudKitVaultFailure.truncate(cloudError.localizedDescription))
        case .serviceUnavailable, .requestRateLimited, .zoneBusy, .internalError, .operationCancelled:
            return .transient(CloudKitVaultFailure.truncate(cloudError.localizedDescription))
        case .serverRecordChanged:
            let serverRecord = cloudError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord
            return .conflict(serverChangeTag: serverRecord?.recordChangeTag)
        case .zoneNotFound:
            return .zoneNotFound
        case .userDeletedZone:
            return .userDeletedZone
        case .unknownItem, .assetFileNotFound:
            return .recordNotFound
        case .assetFileModified:
            return .assetUnavailable("云端保险库文件在下载过程中被修改")
        case .permissionFailure:
            return .permissionDenied
        case .serverRejectedRequest, .constraintViolation, .incompatibleVersion, .badDatabase:
            return .rejected(CloudKitVaultFailure.truncate(cloudError.localizedDescription))
        case .changeTokenExpired:
            return .changeTokenExpired
        default:
            return .transient(CloudKitVaultFailure.truncate(cloudError.localizedDescription))
        }
    }
}
#endif
