import CryptoKit
import Foundation
import Security

// MARK: - Trust scope

/// Stable identity of one WebDAV trust decision.
///
/// A certificate pin is scoped to the server address *and* the user account that
/// talked to it: two accounts on the same host can legitimately see different
/// certificates (per-vhost or per-user front ends), and revoking one must not
/// silently change the other.
public struct WebDAVTrustIdentity: Sendable, Hashable, Codable {
    /// Lowercased host name without a trailing dot, e.g. `dav.example.com`.
    public let host: String
    public let port: Int
    public let username: String

    public init(host: String, port: Int, username: String) {
        var normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalizedHost.hasSuffix(".") {
            normalizedHost.removeLast()
        }
        self.host = normalizedHost
        self.port = port
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds the trust scope for a configured endpoint.
    ///
    /// The port defaults mirror `URL` semantics (`https` → 443, everything else
    /// → 80) so an endpoint written as `https://dav.example.com/` and the
    /// protection space reported by URLSession (`dav.example.com:443`) map to the
    /// same record.
    public init(endpoint: WebDAVEndpoint) {
        let scheme = endpoint.baseURL.scheme?.lowercased()
        let defaultPort = scheme == "https" ? 443 : 80
        self.init(
            host: endpoint.baseURL.host() ?? endpoint.baseURL.absoluteString,
            port: endpoint.baseURL.port ?? defaultPort,
            username: endpoint.username
        )
    }

    /// Key used for persistence and for SwiftUI identity.
    public var storageKey: String {
        "\(host):\(port)#\(username)"
    }

    /// Human readable address, never includes the password.
    public var displayAddress: String {
        "\(host):\(port)"
    }
}

// MARK: - Presented certificate

/// Everything the app is allowed to remember about a presented certificate.
///
/// Only public fields: the SHA-256 fingerprint of the DER encoding plus the
/// subject/issuer names and validity window that the system already shows in any
/// certificate viewer. No private key material and no full certificate body is
/// retained.
public struct WebDAVCertificateInfo: Sendable, Equatable {
    public let identity: WebDAVTrustIdentity
    /// Lowercase hex SHA-256 of the DER encoded certificate.
    public let fingerprint: String
    public let subjectSummary: String
    public let issuerSummary: String?
    /// Whether the certificate names itself as its own issuer (the usual shape of
    /// a self-signed certificate or a private CA). Name equality only: the
    /// signature itself is not verified here.
    public let isSelfSigned: Bool
    public let notBefore: Date?
    public let notAfter: Date?
    public let observedAt: Date

    public init(
        identity: WebDAVTrustIdentity,
        fingerprint: String,
        subjectSummary: String,
        issuerSummary: String?,
        isSelfSigned: Bool,
        notBefore: Date?,
        notAfter: Date?,
        observedAt: Date
    ) {
        self.identity = identity
        self.fingerprint = fingerprint
        self.subjectSummary = subjectSummary
        self.issuerSummary = issuerSummary
        self.isSelfSigned = isSelfSigned
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.observedAt = observedAt
    }

    /// Uppercase, colon separated form (`AB:CD:…`) used for display.
    public var displayFingerprint: String {
        WebDAVCertificateFingerprint.grouped(fingerprint)
    }
}

// MARK: - Persisted pin

/// One user-confirmed (or revoked) host → fingerprint mapping.
public struct WebDAVTrustedCertificateRecord: Sendable, Equatable, Codable, Identifiable {
    public let identity: WebDAVTrustIdentity
    /// Lowercase hex SHA-256 of the DER encoding that the user confirmed.
    public let fingerprint: String
    public let subjectSummary: String
    public let issuerSummary: String?
    public let firstTrustedAt: Date
    public var trustedAt: Date
    /// Set when the user revoked trust. The fingerprint is kept as a tombstone so
    /// the next connection can report "revoked" instead of silently forgetting it.
    public var revokedAt: Date?

    public var id: String {
        identity.storageKey
    }

    public var isTrusted: Bool {
        revokedAt == nil
    }

    public init(
        identity: WebDAVTrustIdentity,
        fingerprint: String,
        subjectSummary: String,
        issuerSummary: String?,
        firstTrustedAt: Date,
        trustedAt: Date,
        revokedAt: Date? = nil
    ) {
        self.identity = identity
        self.fingerprint = WebDAVCertificateTrustPolicy.normalizeFingerprint(fingerprint)
        self.subjectSummary = subjectSummary
        self.issuerSummary = issuerSummary
        self.firstTrustedAt = firstTrustedAt
        self.trustedAt = trustedAt
        self.revokedAt = revokedAt
    }
}

// MARK: - State machine

/// Outcome of comparing a presented certificate with the stored pin.
public enum WebDAVCertificateTrustState: String, Sendable, Equatable, Codable {
    /// No pin on file: the system did not trust the chain and the user was never asked.
    case unknown
    /// The chain is system trusted, or the fingerprint matches the saved pin.
    case trusted
    /// A pin exists and the presented fingerprint differs: hard fail, never accept silently.
    case mismatch
    /// The user revoked trust for this host. The next connection must ask again.
    case revoked
}

/// Result of one trust evaluation. Pure value: no I/O, no side effects.
public struct WebDAVCertificateTrustEvaluation: Sendable, Equatable {
    public let state: WebDAVCertificateTrustState
    /// True when `SecTrustEvaluateWithError` accepted the chain. System trust is
    /// never downgraded to TOFU: a system-trusted chain is always allowed even if
    /// the stored pin differs.
    public let isSystemTrusted: Bool
    public let presentedFingerprint: String?
    public let pinnedFingerprint: String?

    public init(
        state: WebDAVCertificateTrustState,
        isSystemTrusted: Bool,
        presentedFingerprint: String?,
        pinnedFingerprint: String?
    ) {
        self.state = state
        self.isSystemTrusted = isSystemTrusted
        self.presentedFingerprint = presentedFingerprint
        self.pinnedFingerprint = pinnedFingerprint
    }

    public var allowsConnection: Bool {
        isSystemTrusted || state == .trusted
    }

    /// The user has to look at the fingerprint before this connection may proceed.
    public var requiresUserConfirmation: Bool {
        !allowsConnection
    }
}

/// The TOFU decision function, kept free of URLSession and Keychain so it can be
/// unit tested directly.
public enum WebDAVCertificateTrustPolicy {
    public static func evaluate(
        systemTrusted: Bool,
        presentedFingerprint: String?,
        storedRecord: WebDAVTrustedCertificateRecord?
    ) -> WebDAVCertificateTrustEvaluation {
        let presented = presentedFingerprint.map(normalizeFingerprint)
        let pinned = storedRecord.map { normalizeFingerprint($0.fingerprint) }

        // Trust On First Use is only a fallback for chains the system rejects.
        if systemTrusted {
            return WebDAVCertificateTrustEvaluation(
                state: .trusted,
                isSystemTrusted: true,
                presentedFingerprint: presented,
                pinnedFingerprint: pinned
            )
        }

        guard let presented, !presented.isEmpty else {
            return WebDAVCertificateTrustEvaluation(
                state: .unknown,
                isSystemTrusted: false,
                presentedFingerprint: nil,
                pinnedFingerprint: pinned
            )
        }

        guard let storedRecord else {
            return WebDAVCertificateTrustEvaluation(
                state: .unknown,
                isSystemTrusted: false,
                presentedFingerprint: presented,
                pinnedFingerprint: nil
            )
        }

        if storedRecord.revokedAt != nil {
            return WebDAVCertificateTrustEvaluation(
                state: .revoked,
                isSystemTrusted: false,
                presentedFingerprint: presented,
                pinnedFingerprint: pinned
            )
        }

        if normalizeFingerprint(storedRecord.fingerprint) == presented {
            return WebDAVCertificateTrustEvaluation(
                state: .trusted,
                isSystemTrusted: false,
                presentedFingerprint: presented,
                pinnedFingerprint: pinned
            )
        }

        return WebDAVCertificateTrustEvaluation(
            state: .mismatch,
            isSystemTrusted: false,
            presentedFingerprint: presented,
            pinnedFingerprint: pinned
        )
    }

    /// Accepts the shapes fingerprints come in: lowercase/uppercase, `:` or
    /// whitespace separated, with an optional `sha256` prefix.
    public static func normalizeFingerprint(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleaned.hasPrefix("sha256") {
            cleaned.removeFirst("sha256".count)
        }
        cleaned.removeAll { character in
            character == ":" || character == "-" || character == " " || character == "\t" || character == "\n"
        }
        return cleaned
    }
}

// MARK: - Fingerprint

public enum WebDAVCertificateFingerprint {
    /// SHA-256 over the raw DER (`SecCertificateCopyData`) bytes.
    public static func sha256Hex(ofDER data: Data) -> String {
        SHA256.hash(data: data).map { byte in
            String(format: "%02x", byte)
        }.joined()
    }

    public static func sha256Hex(of certificate: SecCertificate) -> String {
        sha256Hex(ofDER: SecCertificateCopyData(certificate) as Data)
    }

    /// `AB:CD:EF…` for display; the stored value stays plain lowercase hex.
    public static func grouped(_ fingerprint: String) -> String {
        let normalized = WebDAVCertificateTrustPolicy.normalizeFingerprint(fingerprint).uppercased()
        guard !normalized.isEmpty else {
            return ""
        }
        var pairs: [String] = []
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let end = normalized.index(index, offsetBy: 2, limitedBy: normalized.endIndex) ?? normalized.endIndex
            pairs.append(String(normalized[index..<end]))
            index = end
        }
        return pairs.joined(separator: ":")
    }
}

// MARK: - Inspector

public enum WebDAVCertificateInspector {
    /// Builds the public description shown to the user for one leaf certificate.
    public static func info(
        for certificate: SecCertificate,
        identity: WebDAVTrustIdentity,
        observedAt: Date = Date()
    ) -> WebDAVCertificateInfo {
        let der = SecCertificateCopyData(certificate) as Data
        let parsed = X509CertificateParser.parse(der: der)
        let systemSummary = SecCertificateCopySubjectSummary(certificate) as String?
        let subject = parsed?.subject.summary ?? systemSummary ?? "—"
        return WebDAVCertificateInfo(
            identity: identity,
            fingerprint: WebDAVCertificateFingerprint.sha256Hex(ofDER: der),
            subjectSummary: subject,
            issuerSummary: parsed?.issuer.summary,
            isSelfSigned: parsed?.isSelfSigned ?? false,
            notBefore: parsed?.notBefore,
            notAfter: parsed?.notAfter,
            observedAt: observedAt
        )
    }
}

// MARK: - User-facing challenge

/// What the app shows when a connection was blocked by the certificate policy.
public struct WebDAVCertificateChallenge: Sendable, Equatable {
    public let info: WebDAVCertificateInfo
    public let state: WebDAVCertificateTrustState
    public let pinnedFingerprint: String?
    public let pinnedTrustedAt: Date?

    public init(
        info: WebDAVCertificateInfo,
        state: WebDAVCertificateTrustState,
        pinnedFingerprint: String?,
        pinnedTrustedAt: Date?
    ) {
        self.info = info
        self.state = state
        self.pinnedFingerprint = pinnedFingerprint.map(WebDAVCertificateTrustPolicy.normalizeFingerprint)
        self.pinnedTrustedAt = pinnedTrustedAt
    }

    /// True when the server presented a different certificate than the saved pin.
    public var isFingerprintChange: Bool {
        state == .mismatch
    }

    public var isFirstUse: Bool {
        state == .unknown || state == .revoked
    }
}

// MARK: - Persistence

public enum WebDAVCertificateTrustStoreError: Error, Sendable, Equatable {
    /// Keychain returned a non-success status. The status code is kept for
    /// diagnostics; no secret is included.
    case keychainStatus(OSStatus)
    case corruptedRecords
}

/// Byte storage behind the trust store. Injectable so tests never touch Keychain.
public protocol WebDAVCertificateTrustStorage: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

public struct KeychainWebDAVCertificateTrustStorage: WebDAVCertificateTrustStorage {
    /// Matches the service naming used by the other Monica Keychain stores.
    public static let defaultService = "com.monicapass.monica.webdav.certificate-trust"
    public static let defaultAccount = "trusted-certificates"

    public let service: String
    public let account: String
    public let accessGroup: String?

    public init(
        service: String = KeychainWebDAVCertificateTrustStorage.defaultService,
        account: String = KeychainWebDAVCertificateTrustStorage.defaultAccount,
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func load() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw WebDAVCertificateTrustStoreError.corruptedRecords
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw WebDAVCertificateTrustStoreError.keychainStatus(status)
        }
    }

    public func save(_ data: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Fingerprints are public data, but background backups run while the
            // device is locked, so "after first unlock" is the narrowest
            // accessibility that keeps that feature working.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw WebDAVCertificateTrustStoreError.keychainStatus(updateStatus)
        }

        var addQuery = baseQuery
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw WebDAVCertificateTrustStoreError.keychainStatus(addStatus)
        }
    }

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}

public protocol WebDAVCertificateTrustStore: Sendable {
    func allRecords() throws -> [WebDAVTrustedCertificateRecord]
    func record(for identity: WebDAVTrustIdentity) throws -> WebDAVTrustedCertificateRecord?
    /// Inserts or updates the pin. `firstTrustedAt` of an existing record is kept
    /// and a previous revocation is cleared: this is the explicit user confirmation.
    func save(_ record: WebDAVTrustedCertificateRecord) throws
    func revoke(identity: WebDAVTrustIdentity, at date: Date) throws
}

public extension WebDAVCertificateTrustStore {
    func trustedRecords() throws -> [WebDAVTrustedCertificateRecord] {
        try allRecords()
            .filter(\.isTrusted)
            .sorted { $0.identity.displayAddress < $1.identity.displayAddress }
    }
}

/// JSON document (one Keychain item) keyed by trust identity.
public final class KeychainWebDAVCertificateTrustStore: WebDAVCertificateTrustStore, @unchecked Sendable {
    private let storage: any WebDAVCertificateTrustStorage
    private let lock = NSLock()

    public init(
        storage: any WebDAVCertificateTrustStorage = KeychainWebDAVCertificateTrustStorage()
    ) {
        self.storage = storage
    }

    public func allRecords() throws -> [WebDAVTrustedCertificateRecord] {
        lock.lock()
        defer { lock.unlock() }
        return try loadRecords()
    }

    public func record(for identity: WebDAVTrustIdentity) throws -> WebDAVTrustedCertificateRecord? {
        lock.lock()
        defer { lock.unlock() }
        return try loadRecords().first { $0.identity == identity }
    }

    public func save(_ record: WebDAVTrustedCertificateRecord) throws {
        lock.lock()
        defer { lock.unlock() }

        var records = try loadRecords()
        let existing = records.first { $0.identity == record.identity }
        let updated = WebDAVTrustedCertificateRecord(
            identity: record.identity,
            fingerprint: record.fingerprint,
            subjectSummary: record.subjectSummary,
            issuerSummary: record.issuerSummary,
            firstTrustedAt: existing?.firstTrustedAt ?? record.firstTrustedAt,
            trustedAt: record.trustedAt,
            revokedAt: nil
        )
        if let index = records.firstIndex(where: { $0.identity == record.identity }) {
            records[index] = updated
        } else {
            records.append(updated)
        }
        records.sort { $0.identity.storageKey < $1.identity.storageKey }
        try persist(records)
    }

    public func revoke(identity: WebDAVTrustIdentity, at date: Date) throws {
        lock.lock()
        defer { lock.unlock() }

        var records = try loadRecords()
        guard let index = records.firstIndex(where: { $0.identity == identity }) else {
            return
        }
        records[index].revokedAt = date
        try persist(records)
    }

    private func loadRecords() throws -> [WebDAVTrustedCertificateRecord] {
        guard let data = try storage.load(), !data.isEmpty else {
            return []
        }
        do {
            return try JSONDecoder().decode([WebDAVTrustedCertificateRecord].self, from: data)
        } catch {
            throw WebDAVCertificateTrustStoreError.corruptedRecords
        }
    }

    private func persist(_ records: [WebDAVTrustedCertificateRecord]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(records)
        try storage.save(data)
    }
}

/// Process-local store for tests and previews. Never used by the app.
public final class InMemoryWebDAVCertificateTrustStore: WebDAVCertificateTrustStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [WebDAVTrustedCertificateRecord]

    public init(records: [WebDAVTrustedCertificateRecord] = []) {
        self.records = records
    }

    public func allRecords() throws -> [WebDAVTrustedCertificateRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    public func record(for identity: WebDAVTrustIdentity) throws -> WebDAVTrustedCertificateRecord? {
        lock.lock()
        defer { lock.unlock() }
        return records.first { $0.identity == identity }
    }

    public func save(_ record: WebDAVTrustedCertificateRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        let existing = records.first { $0.identity == record.identity }
        let updated = WebDAVTrustedCertificateRecord(
            identity: record.identity,
            fingerprint: record.fingerprint,
            subjectSummary: record.subjectSummary,
            issuerSummary: record.issuerSummary,
            firstTrustedAt: existing?.firstTrustedAt ?? record.firstTrustedAt,
            trustedAt: record.trustedAt,
            revokedAt: nil
        )
        records.removeAll { $0.identity == record.identity }
        records.append(updated)
    }

    public func revoke(identity: WebDAVTrustIdentity, at date: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let index = records.firstIndex(where: { $0.identity == identity }) else {
            return
        }
        records[index].revokedAt = date
    }
}

// MARK: - Server trust decision recorder

/// Result of one TLS server trust challenge.
public enum WebDAVServerTrustOutcome: Sendable, Equatable {
    case systemTrusted
    case pinned
    case blocked(WebDAVCertificateChallenge)
    /// Reading the pin failed (for example a locked Keychain): fail closed.
    case trustStoreUnavailable
    /// The leaf certificate could not be inspected: fail closed.
    case inspectionFailed
}

/// Thread-safe slot the URLSession delegate writes the last decision into, so
/// `send(_:)` can translate a cancelled TLS handshake into a diagnosable error.
public final class WebDAVServerTrustOutcomeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: WebDAVServerTrustOutcome?

    public init() {}

    public func record(_ outcome: WebDAVServerTrustOutcome) {
        lock.lock()
        defer { lock.unlock() }
        // A blocked decision is final for this request: later challenges (for
        // example a redirect) must not mask it.
        if case .blocked = self.outcome {
            return
        }
        if case .trustStoreUnavailable = self.outcome {
            return
        }
        if case .inspectionFailed = self.outcome {
            return
        }
        self.outcome = outcome
    }

    public func currentOutcome() -> WebDAVServerTrustOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }
}

// MARK: - URLSession delegate

/// Handles only `NSURLAuthenticationMethodServerTrust` for the WebDAV session it
/// belongs to. Every other challenge falls back to the default handling, so no
/// global ATS or URLSession behaviour is changed.
final class WebDAVServerTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let username: String
    private let trustStore: any WebDAVCertificateTrustStore
    private let recorder: WebDAVServerTrustOutcomeRecorder
    private let now: @Sendable () -> Date

    init(
        username: String,
        trustStore: any WebDAVCertificateTrustStore,
        recorder: WebDAVServerTrustOutcomeRecorder,
        now: @escaping @Sendable () -> Date
    ) {
        self.username = username
        self.trustStore = trustStore
        self.recorder = recorder
        self.now = now
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        var evaluationError: CFError?
        let systemTrusted = SecTrustEvaluateWithError(trust, &evaluationError)

        // System trust wins. Never downgrade a valid chain to fingerprint trust.
        if systemTrusted {
            recorder.record(.systemTrusted)
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else {
            recorder.record(.inspectionFailed)
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let identity = WebDAVTrustIdentity(
            host: challenge.protectionSpace.host,
            port: challenge.protectionSpace.port,
            username: username
        )
        let info = WebDAVCertificateInspector.info(
            for: leaf,
            identity: identity,
            observedAt: now()
        )

        let storedRecord: WebDAVTrustedCertificateRecord?
        do {
            storedRecord = try trustStore.record(for: identity)
        } catch {
            recorder.record(.trustStoreUnavailable)
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let evaluation = WebDAVCertificateTrustPolicy.evaluate(
            systemTrusted: false,
            presentedFingerprint: info.fingerprint,
            storedRecord: storedRecord
        )

        if evaluation.allowsConnection {
            recorder.record(.pinned)
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        let certificateChallenge = WebDAVCertificateChallenge(
            info: info,
            state: evaluation.state,
            pinnedFingerprint: storedRecord?.fingerprint,
            pinnedTrustedAt: storedRecord?.trustedAt
        )
        recorder.record(.blocked(certificateChallenge))
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

// MARK: - X.509 DER reader

/// Minimal DER walker. It only needs to reach the issuer, subject and validity
/// fields of an X.509 certificate; anything unexpected makes it return `nil`
/// instead of guessing, and the caller falls back to the system's one-line
/// subject summary.
struct X509CertificateParser {
    struct Name: Sendable, Equatable {
        let commonName: String?
        let organization: String?

        /// `CN=…, O=…` with whatever parts are present.
        var summary: String? {
            var parts: [String] = []
            if let commonName, !commonName.isEmpty {
                parts.append("CN=\(commonName)")
            }
            if let organization, !organization.isEmpty {
                parts.append("O=\(organization)")
            }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
    }

    struct Parsed: Sendable, Equatable {
        let subject: Name
        let issuer: Name
        let notBefore: Date?
        let notAfter: Date?
        let isSelfSigned: Bool
    }

    private struct Element {
        let tag: UInt8
        let content: Data
    }

    private struct Reader {
        private let bytes: [UInt8]
        private var index = 0

        init(_ data: Data) {
            bytes = [UInt8](data)
        }

        mutating func next() -> Element? {
            guard index < bytes.count else {
                return nil
            }
            let tag = bytes[index]
            index += 1

            // High tag numbers never appear at the certificate structure level.
            guard tag & 0x1F != 0x1F, index < bytes.count else {
                return nil
            }

            var length = Int(bytes[index])
            index += 1
            if length & 0x80 != 0 {
                let byteCount = length & 0x7F
                guard byteCount > 0, byteCount <= 3, index + byteCount <= bytes.count else {
                    return nil
                }
                length = 0
                for _ in 0..<byteCount {
                    length = (length << 8) | Int(bytes[index])
                    index += 1
                }
            }
            guard length >= 0, index + length <= bytes.count else {
                return nil
            }
            let content = Data(bytes[index..<(index + length)])
            index += length
            return Element(tag: tag, content: content)
        }
    }

    static func parse(der data: Data) -> Parsed? {
        var outer = Reader(data)
        guard let certificate = outer.next(), certificate.tag == 0x30 else {
            return nil
        }

        var certificateReader = Reader(certificate.content)
        guard let tbsElement = certificateReader.next(), tbsElement.tag == 0x30 else {
            return nil
        }

        var tbs = Reader(tbsElement.content)
        guard var cursor = tbs.next() else {
            return nil
        }
        if cursor.tag == 0xA0 {
            // version [0] EXPLICIT
            guard let serial = tbs.next() else {
                return nil
            }
            cursor = serial
        }
        // cursor is now the serial number INTEGER.
        guard cursor.tag == 0x02 else {
            return nil
        }
        // signature AlgorithmIdentifier
        guard tbs.next()?.tag == 0x30 else {
            return nil
        }
        guard let issuerElement = tbs.next(), issuerElement.tag == 0x30 else {
            return nil
        }
        guard let validityElement = tbs.next(), validityElement.tag == 0x30 else {
            return nil
        }
        guard let subjectElement = tbs.next(), subjectElement.tag == 0x30 else {
            return nil
        }

        let issuer = name(from: issuerElement)
        let subject = name(from: subjectElement)
        let validity = times(in: validityElement)

        return Parsed(
            subject: subject,
            issuer: issuer,
            notBefore: validity.notBefore,
            notAfter: validity.notAfter,
            isSelfSigned: issuerElement.content == subjectElement.content
        )
    }

    private static func name(from element: Element) -> Name {
        var commonName: String?
        var organization: String?
        var reader = Reader(element.content)

        while let set = reader.next(), set.tag == 0x31 {
            var setReader = Reader(set.content)
            while let attribute = setReader.next(), attribute.tag == 0x30 {
                var attributeReader = Reader(attribute.content)
                guard let oidElement = attributeReader.next(), oidElement.tag == 0x06,
                      let valueElement = attributeReader.next(),
                      let value = string(from: valueElement)
                else {
                    continue
                }
                switch decodeOID(oidElement.content) {
                case "2.5.4.3":
                    commonName = commonName ?? value
                case "2.5.4.10":
                    organization = organization ?? value
                default:
                    break
                }
            }
        }
        return Name(commonName: commonName, organization: organization)
    }

    private static func times(in validity: Element) -> (notBefore: Date?, notAfter: Date?) {
        var reader = Reader(validity.content)
        let first = reader.next()
        let second = reader.next()
        return (
            first.flatMap { date(from: $0) },
            second.flatMap { date(from: $0) }
        )
    }

    private static func date(from element: Element) -> Date? {
        guard element.tag == 0x17 || element.tag == 0x18,
              let raw = String(data: element.content, encoding: .ascii)
        else {
            return nil
        }

        let digits = raw.utf8.prefix { byte in
            byte >= 0x30 && byte <= 0x39
        }
        let value = String(decoding: digits, as: UTF8.self)

        let year: Int
        let remainder: String
        switch element.tag {
        case 0x17:
            // UTCTime: YYMMDDHHMMSSZ. RFC 5280 requires the YY < 50 → 20YY rule.
            guard value.count >= 12, let shortYear = Int(value.prefix(2)) else {
                return nil
            }
            year = shortYear < 50 ? 2000 + shortYear : 1900 + shortYear
            remainder = String(value.dropFirst(2))
        case 0x18:
            // GeneralizedTime: YYYYMMDDHHMMSSZ.
            guard value.count >= 14, let longYear = Int(value.prefix(4)) else {
                return nil
            }
            year = longYear
            remainder = String(value.dropFirst(4))
        default:
            return nil
        }

        guard remainder.count >= 10 else {
            return nil
        }
        let start = remainder.startIndex
        func number(at offset: Int, length: Int) -> Int? {
            guard let lower = remainder.index(start, offsetBy: offset, limitedBy: remainder.endIndex),
                  let upper = remainder.index(lower, offsetBy: length, limitedBy: remainder.endIndex)
            else {
                return nil
            }
            return Int(remainder[lower..<upper])
        }

        guard let month = number(at: 0, length: 2),
              let day = number(at: 2, length: 2),
              let hour = number(at: 4, length: 2),
              let minute = number(at: 6, length: 2),
              let second = number(at: 8, length: 2)
        else {
            return nil
        }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.date(from: components)
    }

    private static func string(from element: Element) -> String? {
        switch element.tag {
        case 0x0C: // UTF8String
            return String(data: element.content, encoding: .utf8)
        case 0x13, 0x16: // PrintableString, IA5String
            return String(data: element.content, encoding: .utf8)
        case 0x14: // TeletexString (treated as Latin-1, the common approximation)
            return String(data: element.content, encoding: .isoLatin1)
        case 0x1E: // BMPString
            return String(data: element.content, encoding: .utf16BigEndian)
        case 0x1C: // UniversalString
            return String(data: element.content, encoding: .utf32BigEndian)
        default:
            return nil
        }
    }

    private static func decodeOID(_ data: Data) -> String {
        let bytes = [UInt8](data)
        guard let first = bytes.first else {
            return ""
        }
        var components: [Int] = [Int(first) / 40, Int(first) % 40]
        var value = 0
        for byte in bytes.dropFirst() {
            value = (value << 7) | Int(byte & 0x7F)
            if byte & 0x80 == 0 {
                components.append(value)
                value = 0
            }
        }
        return components.map(String.init).joined(separator: ".")
    }
}
