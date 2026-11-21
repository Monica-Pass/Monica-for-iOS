import Foundation
import Security
import Testing
import MonicaSync

/// Trust On First Use tests for the WebDAV certificate pinning.
///
/// Everything here is pure value logic plus one certificate fixture generated
/// once with:
///
///     openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 825 \
///       -keyout /tmp/tofu-key.pem -out /tmp/tofu-cert.pem \
///       -subj "/CN=dav.example.com/O=Monica Test" \
///       -addext "subjectAltName=DNS:dav.example.com"
///
/// The expected fingerprint and validity window come from `openssl x509
/// -fingerprint -sha256` / `-dates`, so the tests compare the implementation
/// against an independent tool, not against itself.
@Suite("WebDAV 证书信任 (TOFU)")
struct WebDAVCertificateTrustTests {
    // MARK: - Fixtures

    static let fixtureFingerprint = "430ae7f0b9de236996cc692958b4c0e8d64ac6d1a1f0c2c7875d36f6d6dc2eb7"
    static let fixtureGroupedFingerprint = "43:0A:E7:F0:B9:DE:23:69:96:CC:69:29:58:B4:C0:E8:D6:4A:C6:D1:A1:F0:C2:C7:87:5D:36:F6:D6:DC:2E:B7"
    static let fixtureNotBefore = Date(timeIntervalSince1970: 1_795_257_752) // 2026-11-21T10:42:32Z
    static let fixtureNotAfter = Date(timeIntervalSince1970: 1_866_537_752) // 2029-02-23T10:42:32Z

    static let fixtureBase64 = """
MIIDPDCCAiSgAwIBAgIUFElTdINFsgA+mH2P7u6CssqO7mowDQYJKoZIhvcNAQELBQAwMDEYMBYGA1UEAwwPZGF2LmV4YW1wbGUu
Y29tMRQwEgYDVQQKDAtNb25pY2EgVGVzdDAeFw0yNjExMjExMDQyMzJaFw0yOTAyMjMxMDQyMzJaMDAxGDAWBgNVBAMMD2Rhdi5l
eGFtcGxlLmNvbTEUMBIGA1UECgwLTW9uaWNhIFRlc3QwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDX2uR2SUf0oddT
GqBz/ApoQ+bsn2l/fSiEzxOwG4u2bX8jfE/fAEaV7BhLLl9kgipQd4+2UKVdgR45+FFgLPJE0ijOJJDR58WcJMySgop0ZZ+VKHmJ
squYkQEVBSC5rBdHfq9HnuMgLwz1K/92tMI0D3XDtfrhD8KVwLWssMiHpmtOC5w4WyI5P6AyfvHJQ5P4t0akP+OPRmbz9cW0iN0M
WkO4YtsCfUDIgWjzSbvpuAPfZxDhjFdPbyBFx7NFP8j5Zdvtw3duMIMsCIqVj6aQdMR4WSzqoD6JXQ80lBmh65JBRIlsCII1MovI
+C53+nHj6wJuspg2DRWUEnDhUsZlAgMBAAGjTjBMMB0GA1UdDgQWBBRUqoF5SiFQ4TrIoPRuBxN9sD2FhzAPBgNVHRMBAf8EBTAD
AQH/MBoGA1UdEQQTMBGCD2Rhdi5leGFtcGxlLmNvbTANBgkqhkiG9w0BAQsFAAOCAQEAVBkNHJMumaA9u3ht/MHCW3BQu+Vl77hc
rrJ0hD9e1wrvW1ZtV4z4TSKULsrjV3kjpEJLD5DkSZsNsysOocChd+7KaacdTjEnd/ojNnP8ZbUkgbVJxzHZ3pevbFI16fU3rLwv
6oxCLFGNKHaSWCUHaRy7QWSuI3pS9wrqGvlcfrZMsIl83iFNxv0+dShSoM65zpB998Ko6LmlzQ+nBgkEpsvRZbCA6HgwFvu57uEz
6mjlir9pKvdQ82TmxRpocNqn/RT+Lqf+alIrgIcN0p6RJTYWsYujlkl7Mg8BZD5bIB+8ZPQ80QYPD7UuZrpB1P904hv6I6FaQvbz
4PeqgPsGgQ==
"""

    static var fixtureCertificate: SecCertificate? {
        guard let der = Data(base64Encoded: fixtureBase64, options: .ignoreUnknownCharacters) else {
            return nil
        }
        return SecCertificateCreateWithData(nil, der as CFData)
    }

    static func identity(
        host: String = "dav.example.com",
        port: Int = 443,
        username: String = "monica"
    ) -> WebDAVTrustIdentity {
        WebDAVTrustIdentity(host: host, port: port, username: username)
    }

    static func certificateInfo(
        fingerprint: String = fixtureFingerprint,
        identity: WebDAVTrustIdentity? = nil
    ) -> WebDAVCertificateInfo {
        WebDAVCertificateInfo(
            identity: identity ?? Self.identity(),
            fingerprint: fingerprint,
            subjectSummary: "CN=dav.example.com, O=Monica Test",
            issuerSummary: "CN=dav.example.com, O=Monica Test",
            isSelfSigned: true,
            notBefore: fixtureNotBefore,
            notAfter: fixtureNotAfter,
            observedAt: fixtureNotBefore
        )
    }

    static func record(
        fingerprint: String = fixtureFingerprint,
        identity: WebDAVTrustIdentity? = nil,
        firstTrustedAt: Date = fixtureNotBefore,
        trustedAt: Date = fixtureNotBefore,
        revokedAt: Date? = nil
    ) -> WebDAVTrustedCertificateRecord {
        WebDAVTrustedCertificateRecord(
            identity: identity ?? Self.identity(),
            fingerprint: fingerprint,
            subjectSummary: "CN=dav.example.com, O=Monica Test",
            issuerSummary: "CN=dav.example.com, O=Monica Test",
            firstTrustedAt: firstTrustedAt,
            trustedAt: trustedAt,
            revokedAt: revokedAt
        )
    }

    static func challenge(
        state: WebDAVCertificateTrustState,
        fingerprint: String = fixtureFingerprint,
        pinnedFingerprint: String? = nil,
        pinnedTrustedAt: Date? = nil
    ) -> WebDAVCertificateChallenge {
        WebDAVCertificateChallenge(
            info: certificateInfo(fingerprint: fingerprint),
            state: state,
            pinnedFingerprint: pinnedFingerprint,
            pinnedTrustedAt: pinnedTrustedAt
        )
    }

    // MARK: - Fingerprint

    @Test("SHA-256 指纹是大写无关的小写十六进制 DER 摘要")
    func fingerprintMatchesSHA256Vector() {
        #expect(
            WebDAVCertificateFingerprint.sha256Hex(ofDER: Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    @Test("指纹比较前会去掉大小写、冒号、连字符与 sha256 前缀")
    func fingerprintNormalizationAcceptsCommonFormats() {
        let policy = WebDAVCertificateTrustPolicy.self
        #expect(policy.normalizeFingerprint(Self.fixtureGroupedFingerprint) == Self.fixtureFingerprint)
        #expect(policy.normalizeFingerprint("  \(Self.fixtureFingerprint.uppercased())  ") == Self.fixtureFingerprint)
        #expect(policy.normalizeFingerprint("SHA256:\(Self.fixtureGroupedFingerprint)") == Self.fixtureFingerprint)
        #expect(
            policy.normalizeFingerprint(Self.fixtureFingerprint.replacingOccurrences(of: "43", with: "43-"))
                == Self.fixtureFingerprint
        )
        #expect(WebDAVCertificateFingerprint.grouped(Self.fixtureFingerprint) == Self.fixtureGroupedFingerprint)
    }

    // MARK: - Trust identity

    @Test("信任范围由 host:port 与用户名组成")
    func identityScopesByHostPortAndUser() {
        let identity = Self.identity()
        #expect(identity.storageKey == "dav.example.com:443#monica")
        #expect(identity.displayAddress == "dav.example.com:443")
        #expect(identity != Self.identity(host: "dav.example.com", port: 8443))
        #expect(identity != Self.identity(host: "other.example.com"))
        #expect(identity != Self.identity(username: "other"))
    }

    @Test("主机名会小写并去掉结尾的点，端口按 scheme 补默认值")
    func identityNormalizesHostAndEndpoint() throws {
        let normalized = WebDAVTrustIdentity(host: "  DAV.Example.com.  ", port: 8443, username: " monica ")
        #expect(normalized.host == "dav.example.com")
        #expect(normalized.port == 8443)
        #expect(normalized.username == "monica")

        let httpsURL = try #require(URL(string: "https://dav.example.com/remote.php/dav/files/monica/"))
        let httpsEndpoint = WebDAVEndpoint(baseURL: httpsURL, username: "monica", password: "secret")
        #expect(WebDAVTrustIdentity(endpoint: httpsEndpoint).port == 443)

        let httpURL = try #require(URL(string: "http://192.168.1.10/dav/"))
        let httpEndpoint = WebDAVEndpoint(baseURL: httpURL, username: "monica", password: "secret")
        #expect(WebDAVTrustIdentity(endpoint: httpEndpoint).port == 80)

        let customPortURL = try #require(URL(string: "https://dav.example.com:8443/dav/"))
        let customPortEndpoint = WebDAVEndpoint(baseURL: customPortURL, username: "monica", password: "secret")
        #expect(WebDAVTrustIdentity(endpoint: customPortEndpoint).port == 8443)
    }

    // MARK: - Real certificate inspection

    @Test("证书解析得到 openssl 给出的 SHA-256、主体与有效期")
    func inspectorReadsRealSelfSignedCertificate() throws {
        let certificate = try #require(Self.fixtureCertificate)
        let info = WebDAVCertificateInspector.info(
            for: certificate,
            identity: Self.identity(),
            observedAt: Self.fixtureNotBefore
        )
        #expect(info.fingerprint == Self.fixtureFingerprint)
        #expect(info.displayFingerprint == Self.fixtureGroupedFingerprint)
        #expect(info.subjectSummary == "CN=dav.example.com, O=Monica Test")
        #expect(info.issuerSummary == "CN=dav.example.com, O=Monica Test")
        #expect(info.isSelfSigned)
        #expect(info.notBefore == Self.fixtureNotBefore)
        #expect(info.notAfter == Self.fixtureNotAfter)
        #expect(info.observedAt == Self.fixtureNotBefore)
        #expect(info.identity == Self.identity())
    }

    @Test("DER 解析失败时只保留指纹，有效期留空而不是崩溃")
    func inspectorToleratesUnparseableCertificate() {
        // Some platforms refuse to build a SecCertificate from a truncated DER
        // body; then there is nothing to inspect and the test is vacuous.
        guard let certificate = SecCertificateCreateWithData(nil, Data([0x30, 0x03, 0x02, 0x01]) as CFData) else {
            return
        }
        let info = WebDAVCertificateInspector.info(for: certificate, identity: Self.identity())
        #expect(info.fingerprint.count == 64)
        #expect(info.notBefore == nil)
        #expect(info.notAfter == nil)
    }

    // MARK: - State machine

    @Test("首次连接未知证书需要用户确认")
    func firstUseIsUnknownAndRequiresConfirmation() {
        let evaluation = WebDAVCertificateTrustPolicy.evaluate(
            systemTrusted: false,
            presentedFingerprint: Self.fixtureFingerprint,
            storedRecord: nil
        )
        #expect(evaluation.state == .unknown)
        #expect(evaluation.isSystemTrusted == false)
        #expect(evaluation.allowsConnection == false)
        #expect(evaluation.requiresUserConfirmation)
        #expect(evaluation.presentedFingerprint == Self.fixtureFingerprint)
        #expect(evaluation.pinnedFingerprint == nil)
    }

    @Test("已保存且匹配的指纹直接放行")
    func matchingPinAllowsConnection() {
        let evaluation = WebDAVCertificateTrustPolicy.evaluate(
            systemTrusted: false,
            presentedFingerprint: Self.fixtureGroupedFingerprint.uppercased(),
            storedRecord: Self.record()
        )
        #expect(evaluation.state == .trusted)
        #expect(evaluation.allowsConnection)
        #expect(evaluation.requiresUserConfirmation == false)
        #expect(evaluation.pinnedFingerprint == Self.fixtureFingerprint)
    }

    @Test("指纹变化必须硬失败，绝不静默接受")
    func changedFingerprintHardFails() {
        let changed = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let evaluation = WebDAVCertificateTrustPolicy.evaluate(
            systemTrusted: false,
            presentedFingerprint: changed,
            storedRecord: Self.record()
        )
        #expect(evaluation.state == .mismatch)
        #expect(evaluation.allowsConnection == false)
        #expect(evaluation.requiresUserConfirmation)
        #expect(evaluation.presentedFingerprint == changed)
        #expect(evaluation.pinnedFingerprint == Self.fixtureFingerprint)
    }

    @Test("撤销信任后需要重新确认")
    func revokedPinRequiresConfirmationAgain() {
        let evaluation = WebDAVCertificateTrustPolicy.evaluate(
            systemTrusted: false,
            presentedFingerprint: Self.fixtureFingerprint,
            storedRecord: Self.record(revokedAt: Self.fixtureNotAfter)
        )
        #expect(evaluation.state == .revoked)
        #expect(evaluation.allowsConnection == false)
        #expect(evaluation.requiresUserConfirmation)
    }

    @Test("系统信任通过时永远放行，不会降级成 TOFU")
    func systemTrustedIsNeverDowngraded() {
        let changed = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let evaluation = WebDAVCertificateTrustPolicy.evaluate(
            systemTrusted: true,
            presentedFingerprint: changed,
            storedRecord: Self.record()
        )
        #expect(evaluation.state == .trusted)
        #expect(evaluation.isSystemTrusted)
        #expect(evaluation.allowsConnection)
        #expect(evaluation.requiresUserConfirmation == false)

        let noPin = WebDAVCertificateTrustPolicy.evaluate(
            systemTrusted: true,
            presentedFingerprint: Self.fixtureFingerprint,
            storedRecord: nil
        )
        #expect(noPin.state == .trusted)
        #expect(noPin.allowsConnection)
    }

    @Test("空白指纹按未知处理")
    func blankPresentedFingerprintIsUnknown() {
        let evaluation = WebDAVCertificateTrustPolicy.evaluate(
            systemTrusted: false,
            presentedFingerprint: "  ",
            storedRecord: Self.record()
        )
        #expect(evaluation.state == .unknown)
        #expect(evaluation.presentedFingerprint == nil)
        #expect(evaluation.allowsConnection == false)
    }

    @Test("信任状态机覆盖未知/已信任/变更/撤销四种状态")
    func stateMachineCoversAllOutcomes() {
        let presented = Self.fixtureFingerprint
        let states = [
            WebDAVCertificateTrustPolicy.evaluate(systemTrusted: false, presentedFingerprint: presented, storedRecord: nil).state,
            WebDAVCertificateTrustPolicy.evaluate(systemTrusted: false, presentedFingerprint: presented, storedRecord: Self.record()).state,
            WebDAVCertificateTrustPolicy.evaluate(systemTrusted: false, presentedFingerprint: "cc", storedRecord: Self.record()).state,
            WebDAVCertificateTrustPolicy.evaluate(systemTrusted: false, presentedFingerprint: presented, storedRecord: Self.record(revokedAt: Self.fixtureNotAfter)).state
        ]
        #expect(states == [.unknown, .trusted, .mismatch, .revoked])
    }

    // MARK: - Challenge / error surface

    @Test("证书挑战区分首次使用与指纹变更")
    func challengeDistinguishesFirstUseFromFingerprintChange() {
        let firstUse = Self.challenge(state: .unknown)
        #expect(firstUse.isFirstUse)
        #expect(firstUse.isFingerprintChange == false)

        let revoked = Self.challenge(state: .revoked, pinnedFingerprint: Self.fixtureFingerprint)
        #expect(revoked.isFirstUse)
        #expect(revoked.isFingerprintChange == false)

        let changed = Self.challenge(
            state: .mismatch,
            fingerprint: "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
            pinnedFingerprint: Self.fixtureGroupedFingerprint,
            pinnedTrustedAt: Self.fixtureNotBefore
        )
        #expect(changed.isFingerprintChange)
        #expect(changed.isFirstUse == false)
        #expect(changed.pinnedFingerprint == Self.fixtureFingerprint)
    }

    @Test("错误描述包含主机与完整指纹，且不含密码")
    func errorDescriptionsExposeHostAndFingerprintOnly() {
        let challenge = Self.challenge(
            state: .mismatch,
            pinnedFingerprint: Self.fixtureFingerprint,
            pinnedTrustedAt: Self.fixtureNotBefore
        )
        let changedMessage = try? #require(WebDAVError.certificateFingerprintChanged(challenge).errorDescription)
        #expect(changedMessage?.contains("dav.example.com:443") == true)
        #expect(changedMessage?.contains(Self.fixtureGroupedFingerprint) == true)

        let firstUseMessage = WebDAVError.untrustedCertificate(challenge).errorDescription ?? ""
        #expect(firstUseMessage.contains("dav.example.com:443"))
        #expect(firstUseMessage.contains(Self.fixtureGroupedFingerprint))

        let storeMessage = WebDAVError.certificateTrustStoreUnavailable.errorDescription ?? ""
        #expect(storeMessage.isEmpty == false)
        #expect(storeMessage.contains("secret") == false)
    }

    // MARK: - Recorder

    @Test("阻断结论是粘性的，不会被后续挑战覆盖")
    func blockedOutcomeIsSticky() {
        let recorder = WebDAVServerTrustOutcomeRecorder()
        let challenge = Self.challenge(state: .unknown)
        recorder.record(.systemTrusted)
        recorder.record(.blocked(challenge))
        recorder.record(.pinned)
        recorder.record(.systemTrusted)
        #expect(recorder.currentOutcome() == .blocked(challenge))
    }

    // MARK: - Persistence

    @Test("信任记录经 JSON 往返后完全一致")
    func recordsRoundTripThroughJSON() throws {
        let records = [
            Self.record(),
            Self.record(identity: Self.identity(port: 8444), revokedAt: Self.fixtureNotAfter)
        ]
        let data = try JSONEncoder().encode(records)
        let decoded = try JSONDecoder().decode([WebDAVTrustedCertificateRecord].self, from: data)
        #expect(decoded == records)
        #expect(decoded.map(\.id) == ["dav.example.com:443#monica", "dav.example.com:8444#monica"])
    }

    @Test("Keychain 存储按身份保存、更新并保留首次信任时间")
    func keychainStoreUpsertsAndKeepsFirstTrustedAt() throws {
        let storage = MemoryTrustStorage()
        let store = KeychainWebDAVCertificateTrustStore(storage: storage)
        try store.save(Self.record())

        let changed = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
        try store.save(
            Self.record(
                fingerprint: changed,
                firstTrustedAt: Self.fixtureNotAfter,
                trustedAt: Self.fixtureNotAfter
            )
        )

        let reloaded = try KeychainWebDAVCertificateTrustStore(storage: storage).allRecords()
        #expect(reloaded.count == 1)
        let record = try #require(reloaded.first)
        #expect(record.fingerprint == changed)
        #expect(record.firstTrustedAt == Self.fixtureNotBefore)
        #expect(record.trustedAt == Self.fixtureNotAfter)
        #expect(storage.saveCount == 2)
    }

    @Test("撤销保留墓碑指纹，重新确认后清除")
    func revokeIsReversibleOnlyByExplicitSave() throws {
        let store = KeychainWebDAVCertificateTrustStore(storage: MemoryTrustStorage())
        try store.save(Self.record())
        try store.revoke(identity: Self.identity(), at: Self.fixtureNotAfter)

        let revoked = try #require(try store.record(for: Self.identity()))
        #expect(revoked.isTrusted == false)
        #expect(revoked.revokedAt == Self.fixtureNotAfter)
        #expect(revoked.fingerprint == Self.fixtureFingerprint)
        #expect(try store.trustedRecords().isEmpty)

        let evaluation = WebDAVCertificateTrustPolicy.evaluate(
            systemTrusted: false,
            presentedFingerprint: Self.fixtureFingerprint,
            storedRecord: revoked
        )
        #expect(evaluation.state == .revoked)

        try store.save(Self.record(trustedAt: Self.fixtureNotAfter))
        let reconfirmed = try #require(try store.record(for: Self.identity()))
        #expect(reconfirmed.isTrusted)
        #expect(reconfirmed.revokedAt == nil)
        #expect(reconfirmed.firstTrustedAt == Self.fixtureNotBefore)
        #expect(try store.trustedRecords().count == 1)
    }

    @Test("多个主机的信任记录互相独立，可按地址排序")
    func storeKeepsHostsIndependent() throws {
        let store = KeychainWebDAVCertificateTrustStore(storage: MemoryTrustStorage())
        try store.save(Self.record(identity: Self.identity(host: "b.example.com")))
        try store.save(Self.record(identity: Self.identity(host: "a.example.com")))
        try store.save(Self.record(identity: Self.identity(host: "a.example.com", username: "other")))

        let trusted = try store.trustedRecords()
        #expect(trusted.map(\.identity.displayAddress) == [
            "a.example.com:443",
            "a.example.com:443",
            "b.example.com:443"
        ])
        #expect(try store.record(for: Self.identity(host: "c.example.com")) == nil)
        #expect(try store.record(for: Self.identity(host: "a.example.com", username: "other"))?.identity.username == "other")
    }

    @Test("存储损坏时报错并拒绝信任，不静默放行")
    func corruptedStorageFailsClosed() {
        let storage = MemoryTrustStorage(data: Data("not-json".utf8))
        let store = KeychainWebDAVCertificateTrustStore(storage: storage)
        #expect(throws: WebDAVCertificateTrustStoreError.corruptedRecords) {
            try store.allRecords()
        }
    }

    @Test("内存存储与 Keychain 存储的撤销语义一致")
    func inMemoryStoreMatchesKeychainSemantics() throws {
        let store = InMemoryWebDAVCertificateTrustStore()
        try store.save(Self.record())
        try store.revoke(identity: Self.identity(), at: Self.fixtureNotAfter)
        #expect(try store.trustedRecords().isEmpty)
        try store.save(Self.record(trustedAt: Self.fixtureNotAfter))
        let record = try #require(try store.record(for: Self.identity()))
        #expect(record.isTrusted)
        #expect(record.revokedAt == nil)
        #expect(record.firstTrustedAt == Self.fixtureNotBefore)
    }
}

/// Storage double: keeps the JSON document in memory instead of the Keychain so
/// the store logic is testable without entitlements or a real Keychain.
final class MemoryTrustStorage: WebDAVCertificateTrustStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    private var saves = 0

    init(data: Data? = nil) {
        self.stored = data
    }

    var saveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return saves
    }

    func load() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func save(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        stored = data
        saves += 1
    }
}
