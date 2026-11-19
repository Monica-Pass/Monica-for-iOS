import CryptoKit
import Foundation

// MARK: - Randomness and encoding helpers

enum LanSyncRandom {
    static func bytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        var output = Data(capacity: count)
        for _ in 0..<count {
            output.append(UInt8.random(in: 0...255, using: &generator))
        }
        return output
    }

    static func shortCodeDigits(count: Int = LanSyncProtocolSpec.shortCodeDigits) -> String {
        precondition(count > 0 && count <= 9)
        var generator = SystemRandomNumberGenerator()
        var value = ""
        for _ in 0..<count {
            value.append(String(UInt8.random(in: 0...9, using: &generator)))
        }
        return value
    }
}

public enum LanSyncEncoding {
    public static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func data(base64URL string: String) -> Data? {
        var normalized = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: normalized)
    }

    public static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<lhs.count {
            difference |= lhs[lhs.startIndex + index] ^ rhs[rhs.startIndex + index]
        }
        return difference == 0
    }

    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    public static func hmacSHA256(key: Data, data: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(mac)
    }

    /// Grouped uppercase fingerprint of an Ed25519 identity public key.
    public static func fingerprint(publicKey: Data) -> String {
        let hex = hex(publicKey).uppercased()
        var groups: [String] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 4, limitedBy: hex.endIndex) ?? hex.endIndex
            groups.append(String(hex[index..<end]))
            index = end
        }
        return groups.joined(separator: " ")
    }

    public static func hkdf(
        inputKeyMaterial: Data,
        salt: Data,
        info: Data,
        outputByteCount: Int
    ) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: inputKeyMaterial),
            salt: salt,
            info: info,
            outputByteCount: outputByteCount
        )
        return key.withUnsafeBytes { Data($0) }
    }
}

// MARK: - Device identity

/// Long-lived device identity used for pairing records and handshake
/// authentication. The private material lives in the Keychain on device; the
/// package only knows how to derive and use it.
public struct LanSyncDeviceIdentity: Sendable {
    private let signingKey: Curve25519.Signing.PrivateKey
    private let agreementKey: Curve25519.KeyAgreement.PrivateKey

    public var signingPublicKey: Data { signingKey.publicKey.rawRepresentation }
    public var agreementPublicKey: Data { agreementKey.publicKey.rawRepresentation }

    /// Stable, non-secret identifier derived from the signing public key.
    public var deviceID: String {
        String(LanSyncEncoding.hex(LanSyncEncoding.sha256(signingPublicKey)).prefix(16))
    }

    /// Human-comparable fingerprint of the identity key (grouped hex).
    public var fingerprint: String {
        LanSyncEncoding.fingerprint(publicKey: signingPublicKey)
    }

    public init() {
        signingKey = Curve25519.Signing.PrivateKey()
        agreementKey = Curve25519.KeyAgreement.PrivateKey()
    }

    /// Deterministic identity for unit tests only.
    public init(deterministicSeed: Data) throws {
        let material = LanSyncEncoding.hkdf(
            inputKeyMaterial: LanSyncEncoding.sha256(deterministicSeed),
            salt: Data("monica-lan-sync-device-identity".utf8),
            info: Data("identity-v1".utf8),
            outputByteCount: 64
        )
        let bytes = [UInt8](material)
        signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(bytes[0..<32]))
        agreementKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(bytes[32..<64]))
    }

    /// Restores an identity from the 64-byte private material kept in Keychain.
    public init(privateMaterial: Data) throws {
        guard privateMaterial.count == 64 else {
            throw LanSyncIdentityError.invalidPrivateMaterial
        }
        let bytes = [UInt8](privateMaterial)
        signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(bytes[0..<32]))
        agreementKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(bytes[32..<64]))
    }

    public func exportPrivateMaterial() -> Data {
        var data = Data()
        data.append(signingKey.rawRepresentation)
        data.append(agreementKey.rawRepresentation)
        return data
    }

    public func sign(_ data: Data) throws -> Data {
        try signingKey.signature(for: data)
    }

    public static func verifySignature(_ signature: Data, data: Data, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            return false
        }
        return key.isValidSignature(signature, for: data)
    }
}

public enum LanSyncIdentityError: Error, Sendable, Equatable, LocalizedError {
    case invalidPrivateMaterial

    public var errorDescription: String? {
        "本机局域网同步身份密钥已损坏，请在设置中重置局域网同步身份。"
    }
}

// MARK: - Pairing secret

/// The low-entropy secret that authenticates the Diffie-Hellman exchange.
/// `.shortCode` is typed on the joining device; `.qrToken` is a 256-bit token
/// carried out-of-band by the pairing QR code.
public enum LanSyncPairingSecret: Sendable, Equatable {
    case shortCode(String)
    case qrToken(Data)

    public var kind: LanSyncPairingSecretKind {
        switch self {
        case .shortCode: .shortCode
        case .qrToken: .qrToken
        }
    }

    /// Domain-separated KDF input; prevents a code from being confused with a token.
    public var kdfInput: Data {
        switch self {
        case .shortCode(let code):
            Data("code:".utf8) + Data(Self.normalizedCode(code).utf8)
        case .qrToken(let token):
            Data("qr:".utf8) + token
        }
    }

    public static func generateShortCode() -> LanSyncPairingSecret {
        .shortCode(LanSyncRandom.shortCodeDigits())
    }

    public static func generateQRToken() -> LanSyncPairingSecret {
        .qrToken(LanSyncRandom.bytes(32))
    }

    public static func normalizedCode(_ code: String) -> String {
        code.filter(\.isNumber)
    }

    public static func validateShortCode(_ code: String) -> Bool {
        normalizedCode(code).count == LanSyncProtocolSpec.shortCodeDigits
    }
}

public enum LanSyncPairingSecretKind: String, Codable, Sendable, Equatable {
    case shortCode
    case qrToken
}

// MARK: - Session keys

public struct LanSyncSessionKeys: Sendable {
    public let sessionID: String
    public let shortAuthenticationCode: String
    public let transcriptHash: Data
    public let peerDeviceID: String
    public let peerDisplayName: String
    public let peerSigningPublicKey: Data
    public let role: LanSyncRole
    let sessionKey: Data

    init(
        sessionID: String,
        role: LanSyncRole,
        peerDeviceID: String,
        peerDisplayName: String,
        peerSigningPublicKey: Data,
        transcriptHash: Data,
        sessionKey: Data
    ) {
        self.sessionID = sessionID
        self.role = role
        self.peerDeviceID = peerDeviceID
        self.peerDisplayName = peerDisplayName
        self.peerSigningPublicKey = peerSigningPublicKey
        self.transcriptHash = transcriptHash
        self.sessionKey = sessionKey
        self.shortAuthenticationCode = Self.makeSAS(
            sessionKey: sessionKey,
            transcriptHash: transcriptHash
        )
    }

    public var shortAuthenticationCodeDisplay: String {
        let code = shortAuthenticationCode
        guard code.count == LanSyncProtocolSpec.shortCodeDigits else { return code }
        let middle = code.index(code.startIndex, offsetBy: 3)
        return "\(code[..<middle]) \(code[middle...])"
    }

    public func keyConfirmationProof() -> Data {
        LanSyncEncoding.hmacSHA256(
            key: sessionKey,
            data: Data("confirm:\(role.rawValue):".utf8) + transcriptHash
        )
    }

    /// Session-fingerprint shown in diagnostics; safe to display, not the key.
    public var sessionFingerprint: String {
        String(LanSyncEncoding.hex(LanSyncEncoding.sha256(sessionKey)).prefix(16))
    }

    /// Creates the post-handshake encrypted channel. Exposed so the app layer can
    /// run the session over Network.framework without reimplementing the crypto.
    public func makeSecureChannel() -> LanSyncSecureChannel {
        LanSyncSecureChannel(keys: self)
    }

    private static func makeSAS(sessionKey: Data, transcriptHash: Data) -> String {
        let digest = LanSyncEncoding.hmacSHA256(
            key: sessionKey,
            data: Data("sas:".utf8) + transcriptHash
        )
        let value = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return String(format: "%06u", value % 1_000_000)
    }

    static func derive(
        role: LanSyncRole,
        sessionID: String,
        sharedSecret: Data,
        pairingSecret: LanSyncPairingSecret,
        transcriptHash: Data,
        peerDeviceID: String,
        peerDisplayName: String,
        peerSigningPublicKey: Data
    ) -> LanSyncSessionKeys {
        let sessionKey = LanSyncEncoding.hkdf(
            inputKeyMaterial: sharedSecret,
            salt: transcriptHash + pairingSecret.kdfInput,
            info: Data("monica-lan-sync-v1:session".utf8),
            outputByteCount: 32
        )
        return LanSyncSessionKeys(
            sessionID: sessionID,
            role: role,
            peerDeviceID: peerDeviceID,
            peerDisplayName: peerDisplayName,
            peerSigningPublicKey: peerSigningPublicKey,
            transcriptHash: transcriptHash,
            sessionKey: sessionKey
        )
    }
}

// MARK: - Secure channel

public enum LanSyncRole: String, Codable, Sendable, Equatable {
    case host
    case guest

    var noncePrefix: UInt8 {
        switch self {
        case .host: 1
        case .guest: 2
        }
    }

    var peerRoleNoncePrefix: UInt8 {
        switch self {
        case .host: 2
        case .guest: 1
        }
    }
}

public enum LanSyncSecureMessageKind: String, Codable, Sendable, Equatable {
    case snapshot
    case receipt
    case error
    case syncComplete
}

public struct LanSyncSecureMessage: Codable, Sendable, Equatable {
    public var kind: LanSyncSecureMessageKind
    public var payload: Data

    public init(kind: LanSyncSecureMessageKind, payload: Data) {
        self.kind = kind
        self.payload = payload
    }
}

/// AES-GCM transport for post-pairing messages. Direction keys are derived
/// separately so a host/guest pair never reuses a nonce; the receive counter is
/// strictly sequential, which rejects replay, reordering and dropped frames.
public final class LanSyncSecureChannel: @unchecked Sendable {
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private let sendNoncePrefix: Data
    private let receiveNoncePrefix: Data
    private let lock = NSLock()
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    init(keys: LanSyncSessionKeys) {
        let derived = keys.withDerivedKeys
        sendKey = SymmetricKey(data: keys.role == .host ? derived.hostToGuest : derived.guestToHost)
        receiveKey = SymmetricKey(data: keys.role == .host ? derived.guestToHost : derived.hostToGuest)
        sendNoncePrefix = Self.noncePrefix(for: keys.role.noncePrefix)
        receiveNoncePrefix = Self.noncePrefix(for: keys.role.peerRoleNoncePrefix)
    }

    public var sentFrameCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return sendCounter
    }

    public var receivedFrameCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return receiveCounter
    }

    public func seal(_ message: LanSyncSecureMessage) throws -> LanSyncFrame {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(message)

        lock.lock()
        defer { lock.unlock() }
        sendCounter += 1
        let counter = sendCounter
        let sequence = Self.sequenceBase + counter
        let nonce = try Self.nonce(prefix: sendNoncePrefix, counter: counter)
        let aad = Self.additionalAuthenticatedData(sequence: sequence)
        let box = try AES.GCM.seal(plaintext, using: sendKey, nonce: nonce, authenticating: aad)
        guard let combined = box.combined else {
            throw LanSyncWireError.decryptionFailed
        }
        return LanSyncFrame(kind: .sealed, sequence: sequence, payload: combined)
    }

    public func open(_ frame: LanSyncFrame) throws -> LanSyncSecureMessage {
        guard frame.kind == .sealed else {
            throw LanSyncWireError.unexpectedFrameKind(expected: "sealed", received: frame.kind)
        }
        guard frame.sequence >= Self.sequenceBase else {
            throw LanSyncWireError.replayedSequence(
                expected: Self.sequenceBase + 1,
                received: frame.sequence
            )
        }
        lock.lock()
        defer { lock.unlock() }
        let expected = Self.sequenceBase + receiveCounter + 1
        guard frame.sequence == expected else {
            throw LanSyncWireError.replayedSequence(expected: expected, received: frame.sequence)
        }
        let counter = frame.sequence - Self.sequenceBase
        let expectedNonce = try Self.nonce(prefix: receiveNoncePrefix, counter: counter)
        let aad = Self.additionalAuthenticatedData(sequence: frame.sequence)
        do {
            let box = try AES.GCM.SealedBox(combined: frame.payload)
            guard Data(box.nonce) == Data(expectedNonce) else {
                throw LanSyncWireError.authenticationFailed
            }
            let plaintext = try AES.GCM.open(box, using: receiveKey, authenticating: aad)
            let message = try JSONDecoder().decode(LanSyncSecureMessage.self, from: plaintext)
            receiveCounter += 1
            return message
        } catch {
            throw LanSyncWireError.authenticationFailed
        }
    }

    private static let sequenceBase: UInt64 = 1_000

    private static func noncePrefix(for byte: UInt8) -> Data {
        Data([byte, 0, 0, 0])
    }

    private static func nonce(prefix: Data, counter: UInt64) throws -> AES.GCM.Nonce {
        var nonce = prefix
        var bigEndian = counter.bigEndian
        withUnsafeBytes(of: &bigEndian) { nonce.append(contentsOf: $0) }
        return try AES.GCM.Nonce(data: nonce)
    }

    private static func additionalAuthenticatedData(sequence: UInt64) -> Data {
        var data = LanSyncProtocolSpec.magic
        var version = LanSyncProtocolSpec.version.bigEndian
        withUnsafeBytes(of: &version) { data.append(contentsOf: $0) }
        var sequence = sequence.bigEndian
        withUnsafeBytes(of: &sequence) { data.append(contentsOf: $0) }
        return data
    }
}

extension LanSyncSessionKeys {
    var withDerivedKeys: (hostToGuest: Data, guestToHost: Data) {
        let hostToGuest = LanSyncEncoding.hkdf(
            inputKeyMaterial: sessionKey,
            salt: transcriptHash,
            info: Data("monica-lan-sync-v1:host-to-guest".utf8),
            outputByteCount: 32
        )
        let guestToHost = LanSyncEncoding.hkdf(
            inputKeyMaterial: sessionKey,
            salt: transcriptHash,
            info: Data("monica-lan-sync-v1:guest-to-host".utf8),
            outputByteCount: 32
        )
        return (hostToGuest, guestToHost)
    }
}
