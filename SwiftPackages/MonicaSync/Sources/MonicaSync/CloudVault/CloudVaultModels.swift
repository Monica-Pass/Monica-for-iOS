import Foundation

/// Cloud vault sync (issue #31) is the opt-in, manual counterpart to the
/// local-network sync in `LanSync/`. The remote side stores two objects per vault:
///
/// - `<vault-file-name>` – the complete encrypted MDBX vault file (the same file
///   the local app holds on disk, byte-for-byte);
/// - `<vault-file-name>.monica-cloud.json` – a small `CloudVaultManifest` that
///   pins the vault identity, a monotonically increasing revision, the SHA-256
///   of the vault bytes and the device that produced the revision.
///
/// The manifest is the commit marker: it is written *after* the vault bytes, and
/// a manifest whose `contentSHA256` does not match the downloaded vault file is
/// treated as corrupt remote state instead of silently trusting either side.
public enum CloudVaultProtocolSpec {
    public static let formatVersion = 1
    public static let manifestFileSuffix = ".monica-cloud.json"
    public static let syncStateFileName = "cloud-vault-sync-state-v1.json"
    public static let conflictCopyPrefix = "monica-cloud-conflict-"
    /// Manifests are tiny; anything larger is treated as a corrupted remote file.
    public static let maxManifestBytes = 256 * 1024
    /// MDBX vault files are expected to stay far below this; the guard exists so
    /// a hostile or broken remote cannot make the app allocate unbounded memory.
    public static let maxVaultBytes = 512 * 1024 * 1024
}

public enum CloudVaultRemoteKind: String, Codable, Sendable, Equatable, CaseIterable {
    case webDAV
    case oneDrive

    public var displayName: String {
        switch self {
        case .webDAV: return "WebDAV"
        case .oneDrive: return "OneDrive"
        }
    }

    public var identifier: String { rawValue }
}

public enum CloudVaultJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }
}

/// Small, device-agnostic description of the exact encrypted vault file currently
/// uploaded. The local vault file is already encrypted at rest, so the manifest
/// never needs to carry secrets — only identity, revision and integrity data.
public struct CloudVaultManifest: Codable, Sendable, Equatable {
    public let formatVersion: Int
    public let vaultID: String
    public let vaultName: String
    public let revision: Int
    public let contentSHA256: String
    public let byteCount: Int
    public let updatedAt: Date
    public let updatedByDeviceID: String
    public let updatedByDeviceName: String

    public init(
        formatVersion: Int = CloudVaultProtocolSpec.formatVersion,
        vaultID: String,
        vaultName: String,
        revision: Int,
        contentSHA256: String,
        byteCount: Int,
        updatedAt: Date,
        updatedByDeviceID: String,
        updatedByDeviceName: String
    ) {
        self.formatVersion = formatVersion
        self.vaultID = vaultID
        self.vaultName = vaultName
        self.revision = revision
        self.contentSHA256 = contentSHA256
        self.byteCount = max(0, byteCount)
        self.updatedAt = updatedAt
        self.updatedByDeviceID = updatedByDeviceID
        self.updatedByDeviceName = updatedByDeviceName
    }

    public static func make(
        local: CloudVaultLocalSnapshot,
        revision: Int
    ) -> CloudVaultManifest {
        CloudVaultManifest(
            vaultID: local.vaultID,
            vaultName: local.vaultName,
            revision: max(1, revision),
            contentSHA256: local.sha256,
            byteCount: local.byteCount,
            updatedAt: local.capturedAt,
            updatedByDeviceID: local.deviceID,
            updatedByDeviceName: local.deviceName
        )
    }

    public func validate() throws {
        guard formatVersion == CloudVaultProtocolSpec.formatVersion else {
            throw CloudVaultError.manifestInvalid(
                reason: "清单版本 \(formatVersion) 不受支持（当前 \(CloudVaultProtocolSpec.formatVersion)）"
            )
        }
        guard !vaultID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudVaultError.manifestInvalid(reason: "清单缺少保险库标识")
        }
        guard !vaultName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudVaultError.manifestInvalid(reason: "清单缺少保险库名称")
        }
        guard revision >= 1 else {
            throw CloudVaultError.manifestInvalid(reason: "清单 revision 必须大于 0")
        }
        guard CloudVaultNaming.isLowercaseHex(contentSHA256, count: 64) else {
            throw CloudVaultError.manifestInvalid(reason: "清单内容摘要格式不正确")
        }
        guard byteCount > 0, byteCount <= CloudVaultProtocolSpec.maxVaultBytes else {
            throw CloudVaultError.manifestInvalid(reason: "清单中的保险库大小不合理")
        }
        guard !updatedByDeviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudVaultError.manifestInvalid(reason: "清单缺少上传设备标识")
        }
    }

    public func encodedData() throws -> Data {
        try CloudVaultJSON.encode(self)
    }

    public static func decode(_ data: Data) throws -> CloudVaultManifest {
        guard data.count <= CloudVaultProtocolSpec.maxManifestBytes else {
            throw CloudVaultError.manifestInvalid(reason: "清单文件过大")
        }
        do {
            let manifest = try CloudVaultJSON.decode(CloudVaultManifest.self, from: data)
            try manifest.validate()
            return manifest
        } catch let error as CloudVaultError {
            throw error
        } catch {
            throw CloudVaultError.manifestInvalid(reason: "清单不是有效的 JSON：\(error.localizedDescription)")
        }
    }
}

/// Snapshot of the local vault file taken on the main actor while no vault write
/// is in flight. The bytes are the already-encrypted MDBX file, so the package
/// never needs the vault password: remote uploads and downloads move ciphertext.
public struct CloudVaultLocalSnapshot: Sendable, Equatable {
    public let vaultID: String
    public let vaultName: String
    public let data: Data
    public let byteCount: Int
    public let sha256: String
    public let deviceID: String
    public let deviceName: String
    public let capturedAt: Date

    public init(
        vaultID: String,
        vaultName: String,
        data: Data,
        sha256: String,
        deviceID: String,
        deviceName: String,
        capturedAt: Date
    ) {
        self.vaultID = vaultID
        self.vaultName = vaultName
        self.data = data
        self.byteCount = data.count
        self.sha256 = sha256
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.capturedAt = capturedAt
    }

    public static func make(
        vaultID: String,
        vaultName: String,
        data: Data,
        deviceID: String,
        deviceName: String,
        capturedAt: Date = Date()
    ) throws -> CloudVaultLocalSnapshot {
        let normalizedVaultID = vaultID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedVaultName = vaultName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedVaultID.isEmpty else {
            throw CloudVaultError.invalidLocalVault(reason: "当前保险库缺少标识")
        }
        guard !normalizedVaultName.isEmpty else {
            throw CloudVaultError.invalidLocalVault(reason: "当前保险库缺少名称")
        }
        guard !data.isEmpty else {
            throw CloudVaultError.invalidLocalVault(reason: "当前保险库文件为空")
        }
        guard data.count <= CloudVaultProtocolSpec.maxVaultBytes else {
            throw CloudVaultError.vaultTooLarge(byteCount: data.count)
        }
        let digest = LanSyncEncoding.hex(LanSyncEncoding.sha256(data))
        return CloudVaultLocalSnapshot(
            vaultID: normalizedVaultID,
            vaultName: normalizedVaultName,
            data: data,
            sha256: digest,
            deviceID: deviceID,
            deviceName: deviceName,
            capturedAt: capturedAt
        )
    }
}

/// Remote description returned by `CloudVaultRemoteStore.readRemote()`.
public struct CloudVaultRemoteFile: Sendable, Equatable {
    public let kind: CloudVaultRemoteKind
    /// Stable key shared by manifest and vault file (usually the vault file name).
    public let remotePath: String
    public let fileName: String
    public let manifestFileName: String
    public let itemID: String?
    /// Server side revision/ETag of the vault file, when the provider exposes one.
    public let revision: String?
    public let manifestRevision: String?
    public let manifest: CloudVaultManifest

    public init(
        kind: CloudVaultRemoteKind,
        remotePath: String,
        fileName: String,
        manifestFileName: String,
        itemID: String?,
        revision: String?,
        manifestRevision: String?,
        manifest: CloudVaultManifest
    ) {
        self.kind = kind
        self.remotePath = remotePath
        self.fileName = fileName
        self.manifestFileName = manifestFileName
        self.itemID = itemID
        self.revision = revision
        self.manifestRevision = manifestRevision
        self.manifest = manifest
    }

    public var byteCount: Int { manifest.byteCount }

    public var redactedSummary: String {
        "\(kind.displayName) \(fileName) 第 \(manifest.revision) 版 \(manifest.byteCount) 字节"
    }
}

public struct CloudVaultWriteReceipt: Sendable, Equatable {
    public let kind: CloudVaultRemoteKind
    public let remotePath: String
    public let fileName: String
    public let manifestFileName: String
    public let itemID: String?
    public let revision: String?
    public let manifestRevision: String?
    public let manifest: CloudVaultManifest

    public init(
        kind: CloudVaultRemoteKind,
        remotePath: String,
        fileName: String,
        manifestFileName: String,
        itemID: String?,
        revision: String?,
        manifestRevision: String?,
        manifest: CloudVaultManifest
    ) {
        self.kind = kind
        self.remotePath = remotePath
        self.fileName = fileName
        self.manifestFileName = manifestFileName
        self.itemID = itemID
        self.revision = revision
        self.manifestRevision = manifestRevision
        self.manifest = manifest
    }
}

/// Remote storage contract. Implementations own all HTTP/Graph specifics and must
/// never trust remote bytes: downloads are checked against the manifest digest,
/// writes are conditional whenever the provider exposes a revision.
public protocol CloudVaultRemoteStore: Sendable {
    var kind: CloudVaultRemoteKind { get }
    /// Stable user-facing name, e.g. `WebDAV 备份目录` or `OneDrive 应用文件夹`.
    var displayName: String { get }
    /// Stable key for the vault file (also the identity of the sync record).
    var remotePath: String { get }

    /// Reads the manifest and file metadata. Returns `nil` when no manifest exists.
    /// A manifest without its vault file is reported as corrupt remote state.
    func readRemote() async throws -> CloudVaultRemoteFile?

    /// Downloads the vault file and verifies byte count and SHA-256 from `remote`.
    func downloadVault(_ remote: CloudVaultRemoteFile) async throws -> Data

    /// Creates both remote objects (vault first, manifest last). Throws
    /// `preconditionFailed` when remote state appeared since the last read.
    func createRemote(vaultData: Data, manifest: CloudVaultManifest) async throws -> CloudVaultWriteReceipt

    /// Replaces both remote objects (vault first, manifest last) using
    /// `remote.revision` as `If-Match`. Implementations without ETag support must
    /// re-read the manifest and refuse the write when its revision changed.
    func updateRemote(
        vaultData: Data,
        manifest: CloudVaultManifest,
        remote: CloudVaultRemoteFile
    ) async throws -> CloudVaultWriteReceipt

    /// Writes a separate, never-overwriting copy of the local vault file so a
    /// destructive conflict resolution can lose nothing.
    func writeConflictCopy(
        vaultData: Data,
        manifest: CloudVaultManifest,
        deviceName: String,
        now: Date
    ) async throws -> CloudVaultWriteReceipt
}

public struct CloudVaultSyncRecord: Codable, Sendable, Equatable {
    public let key: String
    public let vaultID: String
    public let remoteKind: CloudVaultRemoteKind
    public let remotePath: String
    public var lastRemoteRevision: String?
    public var lastRemoteManifestRevision: Int?
    public var lastRemoteContentSHA256: String?
    public var lastLocalContentSHA256: String?
    public var lastSyncedAt: Date?
    public var pendingUpload: Bool
    public var lastFailureMessage: String?

    public init(
        key: String,
        vaultID: String,
        remoteKind: CloudVaultRemoteKind,
        remotePath: String,
        lastRemoteRevision: String? = nil,
        lastRemoteManifestRevision: Int? = nil,
        lastRemoteContentSHA256: String? = nil,
        lastLocalContentSHA256: String? = nil,
        lastSyncedAt: Date? = nil,
        pendingUpload: Bool = false,
        lastFailureMessage: String? = nil
    ) {
        self.key = key
        self.vaultID = vaultID
        self.remoteKind = remoteKind
        self.remotePath = remotePath
        self.lastRemoteRevision = lastRemoteRevision
        self.lastRemoteManifestRevision = lastRemoteManifestRevision
        self.lastRemoteContentSHA256 = lastRemoteContentSHA256
        self.lastLocalContentSHA256 = lastLocalContentSHA256
        self.lastSyncedAt = lastSyncedAt
        self.pendingUpload = pendingUpload
        self.lastFailureMessage = lastFailureMessage
    }

    public static func key(
        remoteKind: CloudVaultRemoteKind,
        remotePath: String,
        vaultID: String
    ) -> String {
        "\(remoteKind.identifier)|\(remotePath)|\(vaultID)"
    }

    public var hasBaseline: Bool {
        lastRemoteManifestRevision != nil || lastRemoteContentSHA256 != nil
    }
}

public struct CloudVaultSyncState: Codable, Sendable, Equatable {
    public var formatVersion: Int
    public var records: [String: CloudVaultSyncRecord]

    public init(formatVersion: Int = CloudVaultProtocolSpec.formatVersion, records: [String: CloudVaultSyncRecord] = [:]) {
        self.formatVersion = formatVersion
        self.records = records
    }

    public func record(forKey key: String) -> CloudVaultSyncRecord? {
        records[key]
    }

    public mutating func setRecord(_ record: CloudVaultSyncRecord) {
        records[record.key] = record
    }

    public mutating func removeRecord(forKey key: String) {
        records.removeValue(forKey: key)
    }
}

public enum CloudVaultConflictReason: String, Codable, Sendable, Equatable {
    case bothChanged
    case noBaseline
    case remoteRemoved
    case vaultIdentityMismatch

    public var localizedSummary: String {
        switch self {
        case .bothChanged:
            return "本机与云端在上次同步后都发生了变化"
        case .noBaseline:
            return "本机从未与该云端保险库同步过，且两边内容不同"
        case .remoteRemoved:
            return "云端保险库已被移除，但本机上次同步后仍有修改"
        case .vaultIdentityMismatch:
            return "云端文件属于另一个保险库，无法直接覆盖本机保险库"
        }
    }
}

public struct CloudVaultConflict: Sendable, Equatable {
    public let reason: CloudVaultConflictReason
    public let localChanged: Bool
    public let remoteChanged: Bool
    public let baselineManifestRevision: Int?
    public let remoteManifestRevision: Int
    public let remoteRevision: String?
    public let localContentSHA256: String?
    public let remoteContentSHA256: String?

    public init(
        reason: CloudVaultConflictReason,
        localChanged: Bool,
        remoteChanged: Bool,
        baselineManifestRevision: Int?,
        remoteManifestRevision: Int,
        remoteRevision: String?,
        localContentSHA256: String?,
        remoteContentSHA256: String?
    ) {
        self.reason = reason
        self.localChanged = localChanged
        self.remoteChanged = remoteChanged
        self.baselineManifestRevision = baselineManifestRevision
        self.remoteManifestRevision = remoteManifestRevision
        self.remoteRevision = remoteRevision
        self.localContentSHA256 = localContentSHA256
        self.remoteContentSHA256 = remoteContentSHA256
    }
}

public enum CloudVaultSyncDecision: Sendable, Equatable {
    /// Nothing to do: both sides match the last synced state.
    case upToDate
    /// No remote vault yet; the local vault can be published as revision 1.
    case pushNew
    /// Only the local vault changed; upload as the next revision.
    case pushUpdate
    /// Only the remote vault changed; download and apply it.
    case pullRemoteNewer
    /// Both sides diverged; the user must choose a resolution.
    case conflict(CloudVaultConflict)
}

public enum CloudVaultConflictResolution: String, Sendable, Equatable, CaseIterable {
    case keepLocal
    case keepRemote
    case createConflictCopy

    public var localizedTitle: String {
        switch self {
        case .keepLocal: return "保留本机版本并覆盖云端"
        case .keepRemote: return "保留云端版本并覆盖本机"
        case .createConflictCopy: return "先上传本机冲突副本，再采用云端版本"
        }
    }
}

public struct CloudVaultPushOutcome: Sendable, Equatable {
    public let receipt: CloudVaultWriteReceipt
    public let record: CloudVaultSyncRecord

    public init(receipt: CloudVaultWriteReceipt, record: CloudVaultSyncRecord) {
        self.receipt = receipt
        self.record = record
    }
}

public struct CloudVaultPullOutcome: Sendable, Equatable {
    public let remote: CloudVaultRemoteFile
    public let vaultData: Data
    public let record: CloudVaultSyncRecord

    public init(remote: CloudVaultRemoteFile, vaultData: Data, record: CloudVaultSyncRecord) {
        self.remote = remote
        self.vaultData = vaultData
        self.record = record
    }
}

public struct CloudVaultConflictOutcome: Sendable, Equatable {
    public let resolution: CloudVaultConflictResolution
    public let conflictCopyReceipt: CloudVaultWriteReceipt?
    public let pushOutcome: CloudVaultPushOutcome?
    public let pullOutcome: CloudVaultPullOutcome?

    public init(
        resolution: CloudVaultConflictResolution,
        conflictCopyReceipt: CloudVaultWriteReceipt? = nil,
        pushOutcome: CloudVaultPushOutcome? = nil,
        pullOutcome: CloudVaultPullOutcome? = nil
    ) {
        self.resolution = resolution
        self.conflictCopyReceipt = conflictCopyReceipt
        self.pushOutcome = pushOutcome
        self.pullOutcome = pullOutcome
    }
}

public enum CloudVaultError: Error, Sendable, Equatable, LocalizedError {
    case invalidLocalVault(reason: String)
    case vaultTooLarge(byteCount: Int)
    case notConfigured(reason: String)
    case unsupportedProvider(CloudVaultRemoteKind)
    case unauthorized(CloudVaultRemoteKind)
    case forbidden(CloudVaultRemoteKind)
    case preconditionFailed(remoteRevision: String?)
    case remoteManifestMissing
    case remoteVaultMissing
    case manifestInvalid(reason: String)
    case integrityMismatch(expectedSHA256: String, actualSHA256: String)
    case vaultIDMismatch(expectedVaultID: String, actualVaultID: String)
    case conflictRequiresResolution(CloudVaultConflict)
    case network(String)
    case server(statusCode: Int, message: String)
    case stateCorrupted(reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidLocalVault(let reason):
            return "本地保险库不完整：\(reason)"
        case .vaultTooLarge(let byteCount):
            return "保险库文件过大（\(byteCount) 字节），请先清理附件后再上传"
        case .notConfigured(let reason):
            return "云端未配置：\(reason)"
        case .unsupportedProvider(let kind):
            return "当前暂不支持 \(kind.displayName) 云端保险库同步"
        case .unauthorized(let kind):
            return "\(kind.displayName) 登录已失效，请重新登录后再同步"
        case .forbidden(let kind):
            return "\(kind.displayName) 拒绝访问，请检查账号权限或目录写入权限"
        case .preconditionFailed:
            return "云端版本已被其他设备更新，已暂停本次上传，请重新检查并处理冲突"
        case .remoteManifestMissing:
            return "云端缺少保险库清单，请重新检查云端文件"
        case .remoteVaultMissing:
            return "云端缺少保险库文件，请重新检查云端文件"
        case .manifestInvalid(let reason):
            return "云端保险库清单无效：\(reason)"
        case .integrityMismatch:
            return "云端保险库完整性校验失败（文件可能损坏或被篡改），已停止覆盖本机"
        case .vaultIDMismatch:
            return "云端文件属于另一个保险库，已停止覆盖本机"
        case .conflictRequiresResolution:
            return "本机与云端都有修改，请选择保留版本或生成冲突副本"
        case .network(let message):
            return "网络错误：\(message)（请检查连接后重试）"
        case .server(let statusCode, let message):
            return "云端服务器错误 \(statusCode)：\(message)"
        case .stateCorrupted(let reason):
            return "云端同步记录损坏：\(reason)"
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .network, .server:
            return true
        case .unauthorized, .forbidden:
            return false
        default:
            return false
        }
    }
}

public enum CloudVaultNaming {
    public static func manifestFileName(forVaultFileName name: String) -> String {
        name + CloudVaultProtocolSpec.manifestFileSuffix
    }

    public static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        guard value.count == count else { return false }
        return value.allSatisfy { ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") }
    }

    /// Strips path separators and characters that cloud providers refuse in file
    /// names, then bounds the UTF-8 length without splitting a scalar.
    public static func sanitizedFileName(_ raw: String, fallback: String = "monica-vault.mdbx") -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
            .union(.controlCharacters)
        let scalars = raw.unicodeScalars.map { forbidden.contains($0) || $0 == "\n" || $0 == "\r" ? "-" : Character($0) }
        var value = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if value.isEmpty { value = fallback }
        while value.utf8.count > 120, !value.isEmpty {
            value.removeLast()
        }
        return value
    }

    public static func conflictCopyFileName(
        vaultFileName: String,
        deviceName: String,
        date: Date,
        shortToken: String
    ) -> String {
        let base = (vaultFileName as NSString).deletingPathExtension
        let suffix = (vaultFileName as NSString).pathExtension.isEmpty ? "mdbx" : (vaultFileName as NSString).pathExtension
        let stamp = timestampString(date)
        let device = sanitizedFileName(deviceName, fallback: "device")
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
        let token = shortToken.filter { $0.isHexDigit }.lowercased()
        return "\(CloudVaultProtocolSpec.conflictCopyPrefix)\(stamp)-\(device)-\(token.isEmpty ? "copy" : token).\(base).\(suffix)"
    }

    public static func timestampString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// Deterministic short token used in conflict copy names; derived from the
    /// vault digest and the capture time so retries produce the same file name
    /// instead of spamming the cloud folder.
    public static func conflictCopyToken(sha256: String, date: Date) -> String {
        let input = Data((sha256 + timestampString(date)).utf8)
        return String(LanSyncEncoding.hex(LanSyncEncoding.sha256(input)).prefix(8))
    }
}
