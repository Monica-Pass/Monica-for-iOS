import Foundation

// MARK: - iCloud (CloudKit) cloud vault support (issue #76)
//
// This is the model layer for a second cloud transport on top of the existing
// `CloudVaultRemoteStore` seam. Nothing here talks to CloudKit directly: the
// `CloudKitVaultTransport` protocol is the only place that does, which keeps the
// sync engine, the manifest/revision rules and every encryption invariant exactly
// as they are for WebDAV and OneDrive.
//
// Storage layout (private database, one custom zone):
//
//   zone  : `MonicaVaultZone`
//   record: `monica-vault-<vault-id>`   record type `MonicaVault`
//
// The record is deliberately almost content free. Every field it carries is
// either an opaque identifier, a count, a digest or the encrypted vault itself:
//
//   schemaVersion : Int64   – layout version of this record (not a secret)
//   vaultID       : String  – opaque MDBX vault id (random, not a name)
//   revision      : Int64   – monotonic revision from `CloudVaultManifest`
//   byteCount     : Int64   – ciphertext length
//   contentSHA256 : String  – lowercase hex digest of the ciphertext
//   updatedAt     : Date    – capture time of the revision
//   vaultAsset    : CKAsset – the complete encrypted MDBX vault file
//
// What the record must never contain: the vault display name, the device name,
// an entry title/URL/username/password/TOTP seed/note, or any Passkey material.
// Everything secret lives inside the vault asset, which is the same encrypted
// envelope the app keeps on disk; the fields above are only enough to answer
// "which revision is the cloud holding, and is it intact?".
//
// CloudKit's `recordChangeTag` is the optimistic concurrency token and is mapped
// onto `CloudVaultRemoteFile.revision`; it is opaque, so the store never parses
// it, only compares it.

/// Constants that describe the CloudKit record layout.
public enum CloudKitVaultSpec {
    /// Layout version stored in `schemaVersion`; bump only for an incompatible change.
    public static let schemaVersion = 1
    /// CloudKit record type used for vault records.
    public static let recordType = "MonicaVault"
    /// Placeholder container. The real Team must create this container (or point
    /// the entitlements at an existing one) before iCloud sync can work.
    public static let defaultContainerIdentifier = "iCloud.ru.takagi.monica"
    /// Custom zone inside the private database. CloudKit's default zone cannot be
    /// used because it does not support `recordZoneChanges`.
    public static let defaultZoneName = "MonicaVaultZone"
    /// Field keys, kept in one place so tests can assert the allowlist.
    public static let schemaVersionKey = "schemaVersion"
    public static let vaultIDKey = "vaultID"
    public static let revisionKey = "revision"
    public static let byteCountKey = "byteCount"
    public static let contentSHA256Key = "contentSHA256"
    public static let updatedAtKey = "updatedAt"
    public static let assetKey = "vaultAsset"
    /// Every key a written record may contain. Anything else would be a privacy bug.
    public static let allowedRecordKeys: [String] = [
        schemaVersionKey, vaultIDKey, revisionKey, byteCountKey,
        contentSHA256Key, updatedAtKey, assetKey
    ]
    /// CloudKit allows 255 ASCII bytes for zone and record names.
    public static let maxRecordNameBytes = 255
    /// Server messages are collapsed before they reach a `CloudVaultError`.
    public static let maxFailureMessageLength = 200
    /// A conflict copy is a separate record so it never overwrites the live one.
    public static let conflictCopyPrefix = "monica-cloud-conflict-"
    /// Placeholders used to synthesise a `CloudVaultManifest` from record metadata.
    /// They are fixed strings on purpose: the real vault and device names stay
    /// local, so a CloudKit record cannot be used to identify the vault contents.
    public static let redactedVaultName = "Monica 加密保险库"
    public static let redactedDeviceName = "iCloud"
    public static let redactedDeviceID = "icloud"
}

/// Where a vault lives inside CloudKit: container, zone and record name.
public struct CloudKitVaultConfiguration: Sendable, Equatable, Hashable {
    public let containerIdentifier: String
    public let zoneName: String
    public let recordName: String

    public init(containerIdentifier: String, zoneName: String, recordName: String) throws {
        self.containerIdentifier = containerIdentifier
        self.zoneName = zoneName
        self.recordName = recordName
        try validate()
    }

    /// Convenience initialiser for the normal single-vault case.
    public static func vault(
        containerIdentifier: String = CloudKitVaultSpec.defaultContainerIdentifier,
        zoneName: String = CloudKitVaultSpec.defaultZoneName,
        vaultID: String
    ) throws -> CloudKitVaultConfiguration {
        try CloudKitVaultConfiguration(
            containerIdentifier: containerIdentifier,
            zoneName: zoneName,
            recordName: recordName(forVaultID: vaultID)
        )
    }

    /// Deterministic, ASCII-only record name for a vault id. Vault ids are opaque
    /// random strings; anything outside `[a-z0-9-]` is replaced by a digest so the
    /// name stays stable across devices and inside CloudKit's character rules.
    public static func recordName(forVaultID vaultID: String) -> String {
        let lowered = vaultID.lowercased()
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let token: String
        if !lowered.isEmpty, lowered.allSatisfy({ allowed.contains($0) }) {
            token = String(lowered.prefix(180))
        } else {
            let digest = LanSyncEncoding.hex(LanSyncEncoding.sha256(Data(vaultID.utf8)))
            token = String(digest.prefix(40))
        }
        return "monica-vault-\(token)"
    }

    /// Stable identifier for the sync ledger and the UI. Never carries the vault
    /// name, only the container/zone/record coordinates.
    public var remotePath: String {
        "icloud://\(containerIdentifier)/\(zoneName)/\(recordName)"
    }

    /// Validates every part against CloudKit's documented naming rules.
    public func validate() throws {
        let lowered = containerIdentifier.lowercased()
        guard lowered.hasPrefix("icloud."), containerIdentifier.utf8.count <= CloudKitVaultSpec.maxRecordNameBytes else {
            throw CloudVaultError.notConfigured(reason: "iCloud 容器标识无效（需要形如 iCloud.example.monica 的标识）")
        }
        guard containerIdentifier.unicodeScalars.allSatisfy({ $0.isASCII && !$0.properties.isWhitespace }) else {
            throw CloudVaultError.notConfigured(reason: "iCloud 容器标识必须是 ASCII 字符")
        }
        try Self.validateCloudKitName(zoneName, label: "iCloud 记录区名称")
        try Self.validateCloudKitName(recordName, label: "iCloud 记录名称")
    }

    private static func validateCloudKitName(_ name: String, label: String) throws {
        guard !name.isEmpty, name.utf8.count <= CloudKitVaultSpec.maxRecordNameBytes else {
            throw CloudVaultError.notConfigured(reason: "\(label)不能为空且不能超过 255 字节")
        }
        guard name.unicodeScalars.allSatisfy({ $0.isASCII && !$0.properties.isWhitespace }) else {
            throw CloudVaultError.notConfigured(reason: "\(label)必须是 ASCII 字符")
        }
        guard !name.hasPrefix("_") else {
            throw CloudVaultError.notConfigured(reason: "\(label)不能以下划线开头")
        }
    }
}

/// Result of asking CloudKit whether an iCloud account can be used.
public enum CloudKitAccountAvailability: String, Sendable, Equatable {
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable
    case couldNotDetermine

    /// Only a signed-in, unrestricted account can read or write the private database.
    public var isUsable: Bool { self == .available }
}

/// The plaintext metadata of a CloudKit vault record. This is exactly the set of
/// non-asset fields; see `CloudKitVaultSpec.allowedRecordKeys`.
public struct CloudKitRecordPayload: Sendable, Equatable {
    public let schemaVersion: Int
    public let vaultID: String
    public let revision: Int
    public let byteCount: Int
    public let contentSHA256: String
    public let updatedAt: Date

    public init(
        schemaVersion: Int = CloudKitVaultSpec.schemaVersion,
        vaultID: String,
        revision: Int,
        byteCount: Int,
        contentSHA256: String,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.vaultID = vaultID
        self.revision = revision
        self.byteCount = byteCount
        self.contentSHA256 = contentSHA256
        self.updatedAt = updatedAt
    }

    /// Builds the payload from an already validated manifest.
    public init(manifest: CloudVaultManifest) {
        self.schemaVersion = CloudKitVaultSpec.schemaVersion
        self.vaultID = manifest.vaultID
        self.revision = manifest.revision
        self.byteCount = manifest.byteCount
        self.contentSHA256 = manifest.contentSHA256
        self.updatedAt = manifest.updatedAt
    }

    public func validate() throws {
        guard schemaVersion == CloudKitVaultSpec.schemaVersion else {
            throw CloudVaultError.manifestInvalid(reason: "CloudKit 记录版本 \(schemaVersion) 不受支持")
        }
        guard !vaultID.isEmpty else {
            throw CloudVaultError.manifestInvalid(reason: "CloudKit 记录缺少保险库标识")
        }
        guard revision >= 1 else {
            throw CloudVaultError.manifestInvalid(reason: "CloudKit 记录版本号无效")
        }
        guard byteCount > 0, byteCount <= CloudVaultProtocolSpec.maxVaultBytes else {
            throw CloudVaultError.manifestInvalid(reason: "CloudKit 记录字节数无效")
        }
        guard CloudVaultNaming.isLowercaseHex(contentSHA256, count: 64) else {
            throw CloudVaultError.manifestInvalid(reason: "CloudKit 记录缺少有效的 SHA-256")
        }
    }

    /// The manifest that represents this record locally. Only opaque metadata is
    /// real; names are fixed placeholders so the cloud never learns them.
    public var redactedManifest: CloudVaultManifest {
        CloudVaultManifest(
            formatVersion: CloudVaultProtocolSpec.formatVersion,
            vaultID: vaultID,
            vaultName: CloudKitVaultSpec.redactedVaultName,
            revision: revision,
            contentSHA256: contentSHA256,
            byteCount: byteCount,
            updatedAt: updatedAt,
            updatedByDeviceID: CloudKitVaultSpec.redactedDeviceID,
            updatedByDeviceName: CloudKitVaultSpec.redactedDeviceName
        )
    }
}

/// A vault record as CloudKit reports it: metadata plus the opaque change tag.
public struct CloudKitVaultRecord: Sendable, Equatable {
    public let recordName: String
    /// CloudKit `recordChangeTag`; opaque, used only for optimistic concurrency.
    public let changeTag: String
    public let payload: CloudKitRecordPayload

    public init(recordName: String, changeTag: String, payload: CloudKitRecordPayload) {
        self.recordName = recordName
        self.changeTag = changeTag
        self.payload = payload
    }

    public var revision: Int { payload.revision }
    public var contentSHA256: String { payload.contentSHA256 }
    public var byteCount: Int { payload.byteCount }
    public var vaultID: String { payload.vaultID }
    public var updatedAt: Date { payload.updatedAt }
    public var schemaVersion: Int { payload.schemaVersion }
}

/// How a save is allowed to interact with the record already on the server.
public enum CloudKitSaveCondition: Sendable, Equatable {
    /// Fail if any record already exists under this name (new vault, conflict copy).
    case createOnly
    /// Fail unless the server still holds this change tag (normal update).
    case ifUnchanged(changeTag: String)
    /// Overwrite whatever is on the server. Only used for an explicit user choice.
    case replaceAll
}

/// One batch of zone changes returned by `CKFetchRecordZoneChangesOperation`.
public struct CloudKitZoneChangeSet: Sendable, Equatable {
    public let changed: [CloudKitVaultRecord]
    public let deletedRecordNames: [String]
    /// Opaque `CKServerChangeToken` bytes for the next poll.
    public let changeToken: Data?
    /// True when CloudKit expired the token and this set restarts from scratch.
    public let didReset: Bool

    public init(
        changed: [CloudKitVaultRecord],
        deletedRecordNames: [String],
        changeToken: Data?,
        didReset: Bool
    ) {
        self.changed = changed
        self.deletedRecordNames = deletedRecordNames
        self.changeToken = changeToken
        self.didReset = didReset
    }

    public var isEmpty: Bool { changed.isEmpty && deletedRecordNames.isEmpty }
}

/// CloudKit failures, already translated out of `CKError` so the store (and the
/// tests) never depend on CloudKit itself.
public enum CloudKitVaultFailure: Error, Sendable, Equatable {
    /// No iCloud account signed in on this device.
    case notAuthenticated
    /// The account is temporarily unusable (e.g. signed in but offline-locked).
    case accountTemporarilyUnavailable
    /// `com.apple.developer.icloud-services` / container entitlements are missing.
    case missingEntitlement
    /// The container identifier is not usable for this Team.
    case badContainer
    /// The user's iCloud storage is full.
    case quotaExceeded
    /// The record / asset exceeds a size CloudKit accepts.
    case limitExceeded
    case networkUnavailable(String)
    case transient(String)
    case zoneNotFound
    case userDeletedZone
    case recordNotFound
    case conflict(serverChangeTag: String?)
    case assetUnavailable(String)
    case permissionDenied
    case rejected(String)
    case malformed(String)
    /// CloudKit expired the zone change token; the next poll restarts from scratch.
    case changeTokenExpired

    /// Whether a plain retry can plausibly succeed without user interaction.
    public var isRetryable: Bool {
        switch self {
        case .networkUnavailable, .transient:
            return true
        default:
            return false
        }
    }

    /// A short, redaction-safe description used in `CloudVaultError` values.
    public var redactedMessage: String {
        switch self {
        case .notAuthenticated:
            return "没有登录 iCloud 账号"
        case .accountTemporarilyUnavailable:
            return "iCloud 账号暂时不可用"
        case .missingEntitlement:
            return "当前构建没有启用 iCloud 能力（缺少 CloudKit entitlement）"
        case .badContainer:
            return "iCloud 容器不存在或未在开发者后台配置"
        case .quotaExceeded:
            return "iCloud 存储空间不足"
        case .limitExceeded:
            return "记录超过 CloudKit 的大小限制"
        case .networkUnavailable(let message), .transient(let message):
            return CloudKitVaultFailure.truncate(message)
        case .zoneNotFound, .userDeletedZone:
            return "iCloud 记录区不存在"
        case .recordNotFound:
            return "iCloud 云端记录不存在"
        case .conflict:
            return "云端记录已被其他设备更新"
        case .assetUnavailable(let message):
            return CloudKitVaultFailure.truncate(message)
        case .permissionDenied:
            return "iCloud 拒绝访问该记录"
        case .rejected(let message), .malformed(let message):
            return CloudKitVaultFailure.truncate(message)
        case .changeTokenExpired:
            return "iCloud 变更令牌已过期，需要重新完整检查"
        }
    }

    static func truncate(_ message: String) -> String {
        let collapsed = message
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.utf8.count > CloudKitVaultSpec.maxFailureMessageLength else { return collapsed }
        var value = collapsed
        while value.utf8.count > CloudKitVaultSpec.maxFailureMessageLength, !value.isEmpty {
            value.removeLast()
        }
        return value
    }
}

/// The only seam between the iCloud store and CloudKit. Tests implement this with
/// an in-memory fake; production uses `CloudKitContainerVaultTransport`.
///
/// `fetchRecord` must never download the asset: a status check has to stay cheap
/// and must not pull a multi-hundred-megabyte vault.
public protocol CloudKitVaultTransport: Sendable {
    func accountAvailability() async throws -> CloudKitAccountAvailability
    func ensureZone(_ configuration: CloudKitVaultConfiguration) async throws
    func fetchRecord(
        _ configuration: CloudKitVaultConfiguration,
        recordName: String
    ) async throws -> CloudKitVaultRecord?
    func downloadAsset(
        _ configuration: CloudKitVaultConfiguration,
        recordName: String
    ) async throws -> Data
    func saveRecord(
        _ configuration: CloudKitVaultConfiguration,
        recordName: String,
        payload: CloudKitRecordPayload,
        vaultData: Data,
        condition: CloudKitSaveCondition
    ) async throws -> CloudKitVaultRecord
    func fetchZoneChanges(
        _ configuration: CloudKitVaultConfiguration,
        since changeToken: Data?
    ) async throws -> CloudKitZoneChangeSet
}
