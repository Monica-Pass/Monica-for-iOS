import Foundation
import OSLog

/// Severity of a diagnostic event. The stored threshold decides what is kept:
/// `.info` is the default, so detailed (`.debug`) tracing is off unless a user
/// explicitly lowers the level in the developer section.
public enum DiagnosticLevel: String, CaseIterable, Codable, Sendable, Comparable {
    case debug
    case info
    case warning
    case error

    public var severity: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    public static func < (lhs: DiagnosticLevel, rhs: DiagnosticLevel) -> Bool {
        lhs.severity < rhs.severity
    }

    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        }
    }
}

/// Coarse product area that produced an event. Closed on purpose: an arbitrary
/// string could carry a user name, a host or a token into the log.
public enum DiagnosticModule: String, CaseIterable, Codable, Sendable {
    case app
    case cloudSync
    case oneDriveAuth
    case passkey
    case vault
    case database
    case diagnostics
}

/// A closed vocabulary for the non-numeric metadata values. Every value is a
/// compile-time constant, so no caller-supplied text can reach the log through
/// `provider`, `stage` or `reason`.
public enum DiagnosticTag: String, CaseIterable, Codable, Sendable {
    // Providers / stores
    case oneDrive
    case webDAV
    case localFile
    case iCloud
    case bitwarden
    case systemKeychain
    case autoFillExtension

    // Stages
    case check
    case upload
    case download
    case resolve
    case reset
    case configure
    case signIn
    case silentToken
    case restore
    case open
    case create
    case unlock
    case register
    case assert
    case importInbox
    case export
    case verifyDeviceOwner

    // Reasons / outcomes
    case locked
    case unlocked
    case unauthorized
    case forbidden
    case network
    case server
    case integrity
    case conflict
    case corrupted
    case tooLarge
    case precondition
    case unsupported
    case remoteMissing
    case notConfigured
    case cancelled
    case interactionRequired
    case invalidInput
    case identityUnavailable
    case vaultIDMismatch
    case manifestInvalid
    case mdbxUnavailable
    case verificationFailed
    case commandFailed
    case stateCorrupted
    case emptyResult
    case policyBlocked
    case keychain
    case storage
    case malformed

    // Log levels, used when a level change is itself recorded
    case debugLevel = "debug"
    case infoLevel = "info"
    case warningLevel = "warning"
    case errorLevel = "error"
}

/// A closed set of known storage artifacts. Diagnostics never record a real
/// file name, because a caller could then put user data (a password, a token) in
/// the name; only the constants below can be logged.
public enum DiagnosticArtifact: String, CaseIterable, Codable, Sendable {
    case vaultFile = "vault.mdbx"
    case manifest = "manifest.json"
    case syncRecord = "sync-record.json"
    case backupArchive = "backup.zip"
    case attachmentStore = "attachments"
    case extensionSpool = "extension-diagnostics.jsonl"
    case database = "mdbx"
}

/// Stable, greppable event codes. The raw value is what a support request can
/// quote; the Swift case name is what call sites switch on.
public enum DiagnosticCode: String, CaseIterable, Codable, Sendable {
    // Diagnostics itself (DIAG)
    case diagnosticsDeveloperModeUnlocked = "DIAG-0001"
    case diagnosticsDeveloperModeHidden = "DIAG-0002"
    case diagnosticsCleared = "DIAG-0003"
    case diagnosticsExported = "DIAG-0004"
    case diagnosticsExportBlockedLocked = "DIAG-0005"
    case diagnosticsLevelChanged = "DIAG-0006"
    case diagnosticsPreviewFlagChanged = "DIAG-0007"
    case diagnosticsExtensionEventsImported = "DIAG-0008"

    // Cloud vault sync (SYNC)
    case cloudSyncCheckStarted = "SYNC-1000"
    case cloudSyncUploadStarted = "SYNC-1001"
    case cloudSyncDownloadStarted = "SYNC-1002"
    case cloudSyncConflictResolveStarted = "SYNC-1003"
    case cloudSyncResetStarted = "SYNC-1004"
    case cloudSyncOperationFinished = "SYNC-1005"
    case cloudSyncInvalidLocalVault = "SYNC-1011"
    case cloudSyncVaultTooLarge = "SYNC-1012"
    case cloudSyncUnauthorized = "SYNC-1013"
    case cloudSyncForbidden = "SYNC-1014"
    case cloudSyncPreconditionFailed = "SYNC-1015"
    case cloudSyncRemoteManifestMissing = "SYNC-1016"
    case cloudSyncRemoteVaultMissing = "SYNC-1017"
    case cloudSyncManifestInvalid = "SYNC-1018"
    case cloudSyncIntegrityMismatch = "SYNC-1019"
    case cloudSyncVaultIDMismatch = "SYNC-1020"
    case cloudSyncConflict = "SYNC-1021"
    case cloudSyncNetworkFailure = "SYNC-1022"
    case cloudSyncServerFailure = "SYNC-1023"
    case cloudSyncStateCorrupted = "SYNC-1024"
    case cloudSyncUnsupportedProvider = "SYNC-1025"
    case cloudSyncNotConfigured = "SYNC-1026"
    case cloudSyncUnknownFailure = "SYNC-1027"

    // OneDrive / MSAL authentication (AUTH)
    case oneDriveSignInCancelled = "AUTH-2000"
    case oneDriveSignInFailed = "AUTH-2001"
    case oneDriveSilentTokenFailed = "AUTH-2002"
    case oneDriveSessionRestoreFailed = "AUTH-2003"
    case oneDriveAccountUnavailable = "AUTH-2004"
    case oneDriveSignOutFailed = "AUTH-2005"

    // Passkey (PASS)
    case passkeyRegistrationStarted = "PASS-3000"
    case passkeyRegistrationSucceeded = "PASS-3001"
    case passkeyRegistrationFailed = "PASS-3002"
    case passkeyAssertionStarted = "PASS-3003"
    case passkeyAssertionSucceeded = "PASS-3004"
    case passkeyAssertionFailed = "PASS-3005"
    case passkeyInboxImportFailed = "PASS-3006"
    case passkeyInboxPersistFailed = "PASS-3007"
    case passkeyIdentityUnavailable = "PASS-3008"
    case passkeyDeviceOwnerVerificationFailed = "PASS-3009"
    case passkeyInvalidRelyingPartyID = "PASS-3010"
    case passkeyInvalidClientDataHash = "PASS-3011"
    case passkeyInvalidCredential = "PASS-3012"
    case passkeyKeychainFailure = "PASS-3013"

    // Vault lifecycle (VAULT) and the MDBX bridge (MDBX)
    case vaultCreateStarted = "VAULT-4000"
    case vaultCreateFailed = "VAULT-4001"
    case vaultOpenStarted = "VAULT-4002"
    case vaultOpenFailed = "VAULT-4003"
    case vaultUnlockFailed = "VAULT-4004"
    case vaultRepositoryUnavailable = "VAULT-4005"
    case vaultMDBXUnavailable = "MDBX-5000"
    case vaultMDBXVerificationFailed = "MDBX-5001"
}

// MARK: - Metadata

/// A structural allowlist of the only fields a diagnostic event may carry.
///
/// There is intentionally no initializer that takes a free-form dictionary, a
/// `String` message, an `Error` or a `URL`'s query. The builders below either
/// accept a closed enum / an integer / a `UUID`, or sanitise a URL down to its
/// host or to a single validated file name. Rejected input produces an empty
/// metadata value instead of an unsafe one.
public struct DiagnosticMetadata: Sendable, Equatable, Codable {
    public enum Field: String, Codable, Sendable, CaseIterable {
        case flow
        case provider
        case stage
        case reason
        case status
        case count
        case bytes
        case durationMilliseconds = "duration_ms"
        case host
        case file
        case flag
    }

    public enum Value: Sendable, Equatable, Codable {
        case token(UUID)
        case tag(DiagnosticTag)
        case number(Int)
        case host(String)
        case artifact(DiagnosticArtifact)
        case flag(Bool)

        var rendered: String {
            switch self {
            case .token(let token): return token.uuidString.lowercased()
            case .tag(let tag): return tag.rawValue
            case .number(let number): return String(number)
            case .host(let host): return host
            case .artifact(let artifact): return artifact.rawValue
            case .flag(let flag): return flag ? "true" : "false"
            }
        }
    }

    private var storage: [Field: Value]

    public init() {
        storage = [:]
    }

    public var isEmpty: Bool { storage.isEmpty }

    public func value(for field: Field) -> Value? { storage[field] }

    /// Later builders win for the same field, so `metadata.merging(...)` reads
    /// left to right like a normal argument list.
    public func merging(_ others: DiagnosticMetadata...) -> DiagnosticMetadata {
        var merged = self
        for other in others {
            for (field, value) in other.storage {
                merged.storage[field] = value
            }
        }
        return merged
    }

    /// Convenience for the common `metadata: .merged(...)` call shape.
    public static func merged(_ others: DiagnosticMetadata...) -> DiagnosticMetadata {
        var merged = DiagnosticMetadata()
        for other in others {
            for (field, value) in other.storage {
                merged.storage[field] = value
            }
        }
        return merged
    }

    /// `flow` correlates the events of one user-triggered operation. It is a
    /// freshly generated UUID, never a credential.
    public static func flow(_ identifier: UUID) -> DiagnosticMetadata {
        var metadata = DiagnosticMetadata()
        metadata.storage[.flow] = .token(identifier)
        return metadata
    }

    public static func provider(_ tag: DiagnosticTag) -> DiagnosticMetadata {
        tagMetadata(.provider, tag)
    }

    public static func stage(_ tag: DiagnosticTag) -> DiagnosticMetadata {
        tagMetadata(.stage, tag)
    }

    public static func reason(_ tag: DiagnosticTag) -> DiagnosticMetadata {
        tagMetadata(.reason, tag)
    }

    public static func flag(_ enabled: Bool) -> DiagnosticMetadata {
        var metadata = DiagnosticMetadata()
        metadata.storage[.flag] = .flag(enabled)
        return metadata
    }

    /// HTTP status codes, MSAL/OSStatus style signed codes, or a phase number.
    /// Values outside a plausible range are dropped rather than clamped.
    public static func status(_ code: Int) -> DiagnosticMetadata {
        numberMetadata(.status, code, allowed: -99_999...99_999)
    }

    public static func count(_ value: Int) -> DiagnosticMetadata {
        numberMetadata(.count, value, allowed: 0...Int.max)
    }

    public static func bytes(_ value: Int) -> DiagnosticMetadata {
        numberMetadata(.bytes, value, allowed: 0...Int.max)
    }

    public static func duration(milliseconds: Int) -> DiagnosticMetadata {
        numberMetadata(.durationMilliseconds, milliseconds, allowed: 0...86_400_000)
    }

    /// Sanitises a URL down to its lowercased DNS host: user info, path, query
    /// and fragment are dropped, so `https://alice:secret@host/x?token=y`
    /// contributes `host` only. Invalid hosts produce empty metadata.
    public static func host(of url: URL?) -> DiagnosticMetadata {
        guard let rawHost = url?.host, let host = sanitizedHost(rawHost) else {
            return DiagnosticMetadata()
        }
        var metadata = DiagnosticMetadata()
        metadata.storage[.host] = .host(host)
        return metadata
    }

    /// Names a known artifact from the closed `DiagnosticArtifact` set. There
    /// is deliberately no builder that takes an arbitrary file name or URL.
    public static func artifact(_ artifact: DiagnosticArtifact) -> DiagnosticMetadata {
        var metadata = DiagnosticMetadata()
        metadata.storage[.file] = .artifact(artifact)
        return metadata
    }

    /// Drops only the host field, keeping every other allowlisted field.
    func withoutHost() -> DiagnosticMetadata {
        guard storage[.host] != nil else { return self }
        var result = self
        result.storage[.host] = nil
        return result
    }

    /// Re-validates text-bearing fields after crossing a trust boundary (the
    /// extension spool). Enum and integer fields are already constrained by
    /// `Codable`; a host is text, so it is checked again here.
    func sanitizedForIngestion() -> DiagnosticMetadata {
        var result = DiagnosticMetadata()
        for (field, value) in storage {
            switch (field, value) {
            case (.host, .host(let host)):
                if let sanitized = Self.sanitizedHost(host) {
                    result.storage[.host] = .host(sanitized)
                }
            case (.status, .number(let number)):
                if (-99_999...99_999).contains(number) {
                    result.storage[.status] = .number(number)
                }
            case (.count, .number(let number)), (.bytes, .number(let number)):
                if number >= 0 {
                    result.storage[field] = .number(number)
                }
            case (.durationMilliseconds, .number(let number)):
                if (0...86_400_000).contains(number) {
                    result.storage[.durationMilliseconds] = .number(number)
                }
            default:
                result.storage[field] = value
            }
        }
        return result
    }

    public var renderedFields: String {
        Field.allCases
            .compactMap { field -> String? in
                guard let value = storage[field] else { return nil }
                return "\(field.rawValue)=\(value.rendered)"
            }
            .joined(separator: " ")
    }

    private static func tagMetadata(_ field: Field, _ tag: DiagnosticTag) -> DiagnosticMetadata {
        var metadata = DiagnosticMetadata()
        metadata.storage[field] = .tag(tag)
        return metadata
    }

    private static func numberMetadata(_ field: Field, _ value: Int, allowed: ClosedRange<Int>) -> DiagnosticMetadata {
        guard allowed.contains(value) else {
            return DiagnosticMetadata()
        }
        var metadata = DiagnosticMetadata()
        metadata.storage[field] = .number(value)
        return metadata
    }

    static func sanitizedHost(_ rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasSuffix(".") {
            value.removeLast()
        }
        guard (1...253).contains(value.utf8.count) else {
            return nil
        }
        // DNS label characters only. A password, token or query string cannot
        // survive this check, and even a syntactically valid single label is
        // only ever a value a URL produced.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !value.hasPrefix("-"),
              !value.hasSuffix("-"),
              !value.contains("..")
        else {
            return nil
        }
        return value
    }
}

// MARK: - Event

/// One immutable diagnostic record. It deliberately has no `message`, no
/// `error` and no free-form payload: what is not in the type cannot leak.
public struct DiagnosticEvent: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public let timestamp: Date
    public let level: DiagnosticLevel
    public let module: DiagnosticModule
    public let code: DiagnosticCode
    public let metadata: DiagnosticMetadata

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        level: DiagnosticLevel,
        module: DiagnosticModule,
        code: DiagnosticCode,
        metadata: DiagnosticMetadata = DiagnosticMetadata()
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.module = module
        self.code = code
        self.metadata = metadata
    }

    /// Tab-separated: timestamp, level, module, code, allowlisted fields.
    public func renderLine(using formatter: ISO8601DateFormatter) -> String {
        var columns = [
            formatter.string(from: timestamp),
            level.rawValue,
            module.rawValue,
            code.rawValue
        ]
        let fields = metadata.renderedFields
        if !fields.isEmpty {
            columns.append(fields)
        }
        return columns.joined(separator: "\t")
    }
}

// MARK: - Access control

public enum DiagnosticAccessError: Error, Equatable, Sendable {
    case vaultLocked
}

// MARK: - Log

/// A bounded, in-memory ring buffer of redacted diagnostic events.
///
/// - Capacity and retention are both hard limits: the oldest events are evicted
///   on every write, so the buffer never grows past `configuration.capacity`.
/// - The default threshold is `.info`; detailed (`.debug`) events are dropped
///   before they are stored, which keeps the cost of a disabled record call to
///   one lock acquisition.
/// - Reading or exporting while the vault is locked throws
///   `DiagnosticAccessError.vaultLocked`, so the protection does not depend on
///   the UI remembering to hide a button.
/// - Every stored event is also mirrored to `os_log` with the code and module
///   public and the allowlisted fields private, so the two log locations share
///   exactly the same redaction.
public final class DiagnosticLog: @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        public var capacity: Int
        public var retention: TimeInterval
        public var minimumLevel: DiagnosticLevel
        public var includesHostNames: Bool
        public var mirrorsToSystemLog: Bool

        public init(
            capacity: Int = 500,
            retention: TimeInterval = 7 * 24 * 60 * 60,
            minimumLevel: DiagnosticLevel = .info,
            includesHostNames: Bool = true,
            mirrorsToSystemLog: Bool = true
        ) {
            self.capacity = max(1, capacity)
            self.retention = max(0, retention)
            self.minimumLevel = minimumLevel
            self.includesHostNames = includesHostNames
            self.mirrorsToSystemLog = mirrorsToSystemLog
        }
    }

    public static let shared = DiagnosticLog()

    private let lock = NSLock()
    private let subsystem: String
    private var configuration: Configuration
    private var storage: [DiagnosticEvent]

    public init(configuration: Configuration = Configuration(), subsystem: String = "com.monicapass.monica") {
        self.subsystem = subsystem
        self.configuration = configuration
        self.storage = []
        self.storage.reserveCapacity(configuration.capacity)
    }

    public var config: Configuration {
        lock.lock()
        defer { lock.unlock() }
        return configuration
    }

    public var minimumLevel: DiagnosticLevel { config.minimumLevel }

    public var isDetailedLoggingEnabled: Bool { config.minimumLevel == .debug }

    public var includesHostNames: Bool { config.includesHostNames }

    /// Number of retained events. Also prunes expired events so the value is
    /// the same number a developer section would show.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked(now: Date())
        return storage.count
    }

    public var capacity: Int { config.capacity }

    public var retention: TimeInterval { config.retention }

    public func setMinimumLevel(_ level: DiagnosticLevel) {
        lock.lock()
        configuration.minimumLevel = level
        lock.unlock()
    }

    public func setIncludesHostNames(_ enabled: Bool) {
        lock.lock()
        configuration.includesHostNames = enabled
        if !enabled {
            // Existing events must obey the new policy immediately.
            for index in storage.indices {
                storage[index] = storage[index].withoutHostField()
            }
        }
        lock.unlock()
    }

    public func setMirrorsToSystemLog(_ enabled: Bool) {
        lock.lock()
        configuration.mirrorsToSystemLog = enabled
        lock.unlock()
    }

    /// Stores one event. Returns `true` when it was kept.
    @discardableResult
    public func record(
        _ code: DiagnosticCode,
        level: DiagnosticLevel = .info,
        module: DiagnosticModule,
        metadata: DiagnosticMetadata = DiagnosticMetadata(),
        at timestamp: Date = Date()
    ) -> Bool {
        lock.lock()
        let threshold = configuration.minimumLevel
        guard level >= threshold else {
            lock.unlock()
            return false
        }
        var stored = DiagnosticEvent(
            timestamp: timestamp,
            level: level,
            module: module,
            code: code,
            metadata: metadata
        )
        if !configuration.includesHostNames {
            stored = stored.withoutHostField()
        }
        storage.append(stored)
        pruneLocked(now: timestamp)
        let mirror = configuration.mirrorsToSystemLog
        lock.unlock()

        if mirror {
            mirrorToSystemLog(stored)
        }
        return true
    }

    /// The events a developer section may show. Throws while the vault is
    /// locked so locked-state browsing is blocked below the UI.
    public func events(
        minimumLevel: DiagnosticLevel = .debug,
        vaultIsUnlocked: Bool,
        now: Date = Date()
    ) throws -> [DiagnosticEvent] {
        guard vaultIsUnlocked else {
            throw DiagnosticAccessError.vaultLocked
        }
        lock.lock()
        defer { lock.unlock() }
        pruneLocked(now: now)
        return storage.filter { $0.level >= minimumLevel }
    }

    /// Blocks export while the vault is locked. The header states what the file
    /// may contain so a confirmation dialog can quote the same facts.
    public func exportReport(
        minimumLevel: DiagnosticLevel = .debug,
        vaultIsUnlocked: Bool,
        generatedAt: Date = Date()
    ) throws -> String {
        guard vaultIsUnlocked else {
            throw DiagnosticAccessError.vaultLocked
        }
        let events: [DiagnosticEvent]
        let configurationSnapshot: Configuration
        lock.lock()
        pruneLocked(now: generatedAt)
        events = storage.filter { $0.level >= minimumLevel }
        configurationSnapshot = configuration
        lock.unlock()

        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var lines = [
            "# Monica 诊断日志 v1",
            "# 生成时间: \(formatter.string(from: generatedAt))",
            "# 条目: \(events.count)/\(configurationSnapshot.capacity)",
            "# 保留窗口: \(Int(configurationSnapshot.retention / 86_400)) 天",
            "# 级别下限: \(configurationSnapshot.minimumLevel.rawValue)",
            "# 说明: 每行为 时间/级别/模块/事件码/白名单字段，不含密码、验证码、令牌、密钥或完整 URL。",
            "# 该文件由本机生成，不会自动上传到任何服务器。",
            ""
        ]
        if events.isEmpty {
            lines.append("# 暂无事件")
        } else {
            lines.append(contentsOf: events.map { $0.renderLine(using: formatter) })
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Clearing only removes data, so it does not require an unlocked vault.
    public func clear() {
        lock.lock()
        storage.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// Used by the app to fold events recorded by the AutoFill extension into
    /// this buffer without ever trusting the file's contents.
    public func ingest(_ events: [DiagnosticEvent]) {
        guard !events.isEmpty else { return }
        lock.lock()
        for event in events where event.level >= configuration.minimumLevel {
            storage.append(configuration.includesHostNames ? event : event.withoutHostField())
        }
        pruneLocked(now: Date())
        lock.unlock()
    }

    private func pruneLocked(now: Date) {
        if configuration.capacity >= 1, storage.count > configuration.capacity {
            storage.removeFirst(storage.count - configuration.capacity)
        }
        guard configuration.retention > 0 else {
            storage.removeAll(keepingCapacity: true)
            return
        }
        let cutoff = now.addingTimeInterval(-configuration.retention)
        var firstRetained = 0
        while firstRetained < storage.count, storage[firstRetained].timestamp < cutoff {
            firstRetained += 1
        }
        if firstRetained > 0 {
            storage.removeFirst(firstRetained)
        }
    }

    private func mirrorToSystemLog(_ event: DiagnosticEvent) {
        let logger = Logger(subsystem: subsystem, category: event.module.rawValue)
        let fields = event.metadata.renderedFields
        logger.log(
            level: event.level.osLogType,
            "\(event.code.rawValue, privacy: .public) level=\(event.level.rawValue, privacy: .public) details=\(fields, privacy: .private)"
        )
    }
}

private extension DiagnosticEvent {
    func withoutHostField() -> DiagnosticEvent {
        guard metadata.value(for: .host) != nil else { return self }
        return DiagnosticEvent(
            id: id,
            timestamp: timestamp,
            level: level,
            module: module,
            code: code,
            metadata: metadata.withoutHost()
        )
    }
}
