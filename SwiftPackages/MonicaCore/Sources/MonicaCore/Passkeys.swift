import CryptoKit
import Foundation
import Security

public enum PasskeyCredentialError: Error, Sendable, Equatable {
    case invalidRelyingPartyID
    case invalidUsername
    case invalidUserHandle
    case invalidClientDataHashLength
    case invalidCredentialID
    case privateKeyNotFound
    case invalidPrivateKey
    case invalidPublicKey
    case invalidCOSEKey
    case randomFailure
    case keychainUnexpectedStatus(OSStatus)
}

public enum PasskeyRelyingPartyIDNormalizer {
    public static func normalize(_ relyingPartyID: String?) -> String? {
        guard var value = relyingPartyID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        while value.hasSuffix(".") {
            value.removeLast()
        }
        guard !value.isEmpty,
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else {
            return nil
        }

        let lowercased = value.lowercased()
        let disallowedCharacters = CharacterSet(charactersIn: ":/?#[]@\\%")
        guard lowercased.rangeOfCharacter(from: disallowedCharacters) == nil,
              let host = URL(string: "https://\(lowercased)")?.host?.lowercased()
        else {
            return nil
        }

        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard normalized.count <= 253,
              normalized.isValidPasskeyRelyingPartyHost
        else {
            return nil
        }
        return normalized
    }

    public static func host(_ host: String, isAllowedFor relyingPartyID: String) -> Bool {
        guard let normalizedHost = normalize(host),
              let normalizedRelyingPartyID = normalize(relyingPartyID)
        else {
            return false
        }
        return normalizedHost == normalizedRelyingPartyID
            || normalizedHost.hasSuffix(".\(normalizedRelyingPartyID)")
    }
}

private extension String {
    var isValidPasskeyRelyingPartyHost: Bool {
        let labels = split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else {
            return false
        }
        return labels.allSatisfy { label in
            guard !label.isEmpty,
                  label.count <= 63,
                  label.first != "-",
                  label.last != "-"
            else {
                return false
            }
            return label.unicodeScalars.allSatisfy { scalar in
                (scalar.value >= 0x61 && scalar.value <= 0x7A)
                    || (scalar.value >= 0x30 && scalar.value <= 0x39)
                    || scalar.value == 0x2D
            }
        }
    }
}

public protocol PasskeyPrivateKeyStore: Sendable {
    func savePrivateKey(_ privateKey: Data, credentialID: Data) throws -> String
    func loadPrivateKey(credentialID: Data) throws -> Data?
    /// Removes the private key. Deleting a missing key is not an error: rollback and revocation
    /// cleanup must be idempotent.
    func deletePrivateKey(credentialID: Data) throws
}

public final class MemoryPasskeyPrivateKeyStore: PasskeyPrivateKeyStore, @unchecked Sendable {
    private var privateKeys: [Data: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func savePrivateKey(_ privateKey: Data, credentialID: Data) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        privateKeys[credentialID] = privateKey
        return PasskeyCredentialReference.reference(for: credentialID)
    }

    public func loadPrivateKey(credentialID: Data) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return privateKeys[credentialID]
    }

    public func deletePrivateKey(credentialID: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        privateKeys.removeValue(forKey: credentialID)
    }
}

public final class KeychainPasskeyPrivateKeyStore: PasskeyPrivateKeyStore, @unchecked Sendable {
    private let service: String
    private let accessGroup: String?
    private let synchronizable: Bool

    /// - Parameter synchronizable: Store the key in iCloud Keychain so the credential can be
    ///   restored on another device. This is what makes the WebAuthn `BE`/`BS` backup flags
    ///   truthful; `ThisDeviceOnly` accessibility is incompatible with synchronizing, so the
    ///   protection class downgrades to `AfterFirstUnlock` when synchronizing.
    public init(
        service: String = "com.monicapass.monica.passkeys",
        accessGroup: String? = nil,
        synchronizable: Bool = true
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.synchronizable = synchronizable
    }

    public func savePrivateKey(_ privateKey: Data, credentialID: Data) throws -> String {
        var query = baseQuery(credentialID: credentialID)
        // Remove both the syncing and the device-local variant so an upgrade does not leave a
        // stale key behind.
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(query as CFDictionary)

        query = baseQuery(credentialID: credentialID)
        query[kSecValueData as String] = privateKey
        if synchronizable {
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        } else {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw PasskeyCredentialError.keychainUnexpectedStatus(status)
        }
        return PasskeyCredentialReference.reference(for: credentialID)
    }

    public func loadPrivateKey(credentialID: Data) throws -> Data? {
        var query = baseQuery(credentialID: credentialID)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw PasskeyCredentialError.keychainUnexpectedStatus(status)
        }
        guard let data = item as? Data else {
            throw PasskeyCredentialError.privateKeyNotFound
        }
        return data
    }

    public func deletePrivateKey(credentialID: Data) throws {
        var query = baseQuery(credentialID: credentialID)
        // Match both the syncing and the device-local variant.
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PasskeyCredentialError.keychainUnexpectedStatus(status)
        }
    }

    private func baseQuery(credentialID: Data) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: PasskeyCredentialReference.urlSafeBase64(credentialID)
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}

public struct PasskeyVaultMetadataDraft: Sendable, Equatable {
    public let title: String
    public let relyingPartyID: String
    public let username: String
    public let userHandle: String
    public let credentialID: String
    public let publicKeyCOSE: String
    public let privateKeyReference: String
    public let notes: String
}

public struct MonicaPasskeyRegistrationResult: Sendable, Equatable {
    public let relyingPartyID: String
    public let username: String
    public let userHandle: Data
    public let credentialID: Data
    public let publicKeyCOSE: Data
    public let attestationObject: Data
    public let privateKeyReference: String

    public func vaultMetadataDraft(title: String) -> PasskeyVaultMetadataDraft {
        PasskeyVaultMetadataDraft(
            title: title,
            relyingPartyID: relyingPartyID,
            username: username,
            userHandle: userHandle.base64EncodedString(),
            credentialID: credentialID.base64EncodedString(),
            publicKeyCOSE: publicKeyCOSE.base64EncodedString(),
            privateKeyReference: privateKeyReference,
            notes: "由系统通行密钥注册创建。"
        )
    }
}

public struct MonicaPasskeyAssertionResult: Sendable, Equatable {
    public let relyingPartyID: String
    public let credentialID: Data
    public let userHandle: Data
    public let clientDataHash: Data
    public let authenticatorData: Data
    public let signature: Data
}

public struct MonicaPasskeyCredentialManager: Sendable {
    private let privateKeyStore: any PasskeyPrivateKeyStore
    private let randomBytes: @Sendable (Int) throws -> [UInt8]

    public init(
        privateKeyStore: any PasskeyPrivateKeyStore,
        randomBytes: @escaping @Sendable (Int) throws -> [UInt8] = MonicaPasskeyCredentialManager.secureRandomBytes(count:)
    ) {
        self.privateKeyStore = privateKeyStore
        self.randomBytes = randomBytes
    }

    /// - Parameter userVerified: Whether the caller actually performed user verification
    ///   (biometrics or device passcode). The authenticator data must not claim the UV flag
    ///   when the device owner was not verified.
    public func createRegistration(
        relyingPartyID: String,
        username: String,
        userHandle: Data,
        clientDataHash: Data,
        userVerified: Bool = true,
        backupEligible: Bool = false,
        backupState: Bool = false
    ) throws -> MonicaPasskeyRegistrationResult {
        guard let normalizedRelyingPartyID = PasskeyRelyingPartyIDNormalizer.normalize(relyingPartyID) else {
            throw PasskeyCredentialError.invalidRelyingPartyID
        }
        let normalizedUsername = try normalizeRequired(username, error: .invalidUsername)
        guard !userHandle.isEmpty else {
            throw PasskeyCredentialError.invalidUserHandle
        }
        try validateClientDataHash(clientDataHash)

        let credentialID = Data(try randomBytes(32))
        guard credentialID.count == 32 else {
            throw PasskeyCredentialError.invalidCredentialID
        }

        let privateKey = P256.Signing.PrivateKey()
        let publicKeyCOSE = try Self.coseKey(for: privateKey.publicKey)
        let privateKeyReference = try privateKeyStore.savePrivateKey(
            privateKey.rawRepresentation,
            credentialID: credentialID
        )
        let attestationObject = try Self.attestationObject(
            relyingPartyID: normalizedRelyingPartyID,
            credentialID: credentialID,
            publicKeyCOSE: publicKeyCOSE,
            userVerified: userVerified,
            backupEligible: backupEligible,
            backupState: backupState
        )

        return MonicaPasskeyRegistrationResult(
            relyingPartyID: normalizedRelyingPartyID,
            username: normalizedUsername,
            userHandle: userHandle,
            credentialID: credentialID,
            publicKeyCOSE: publicKeyCOSE,
            attestationObject: attestationObject,
            privateKeyReference: privateKeyReference
        )
    }

    public func createAssertion(
        relyingPartyID: String,
        credentialID: Data,
        userHandle: Data,
        clientDataHash: Data,
        userVerified: Bool = true,
        backupEligible: Bool = false,
        backupState: Bool = false
    ) throws -> MonicaPasskeyAssertionResult {
        guard let normalizedRelyingPartyID = PasskeyRelyingPartyIDNormalizer.normalize(relyingPartyID) else {
            throw PasskeyCredentialError.invalidRelyingPartyID
        }
        guard !credentialID.isEmpty else {
            throw PasskeyCredentialError.invalidCredentialID
        }
        guard !userHandle.isEmpty else {
            throw PasskeyCredentialError.invalidUserHandle
        }
        try validateClientDataHash(clientDataHash)

        guard let privateKeyData = try privateKeyStore.loadPrivateKey(credentialID: credentialID) else {
            throw PasskeyCredentialError.privateKeyNotFound
        }
        let privateKey: P256.Signing.PrivateKey
        do {
            privateKey = try P256.Signing.PrivateKey(rawRepresentation: privateKeyData)
        } catch {
            throw PasskeyCredentialError.invalidPrivateKey
        }

        // WebAuthn L2 §7.2: relying parties that observe a non-zero signature counter
        // MUST reject assertions that do not strictly increase it. Platform passkeys
        // therefore always report a zero counter, which every conforming RP accepts.
        let authenticatorData = Self.authenticatorData(
            relyingPartyID: normalizedRelyingPartyID,
            flags: Self.flags(
                userVerified: userVerified,
                backupEligible: backupEligible,
                backupState: backupState
            ),
            counter: 0
        )
        let signedData = authenticatorData + clientDataHash
        let signature = try privateKey.signature(for: signedData).derRepresentation

        return MonicaPasskeyAssertionResult(
            relyingPartyID: normalizedRelyingPartyID,
            credentialID: credentialID,
            userHandle: userHandle,
            clientDataHash: clientDataHash,
            authenticatorData: authenticatorData,
            signature: signature
        )
    }

    public func verifyAssertion(
        _ assertion: MonicaPasskeyAssertionResult,
        publicKeyCOSE: Data
    ) throws -> Bool {
        let publicKey = try Self.publicKey(fromCOSEKey: publicKeyCOSE)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: assertion.signature)
        return publicKey.isValidSignature(
            signature,
            for: assertion.authenticatorData + assertion.clientDataHash
        )
    }

    private func normalizeRequired(_ value: String, error: PasskeyCredentialError) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw error
        }
        return trimmed
    }

    private func validateClientDataHash(_ value: Data) throws {
        guard value.count == 32 else {
            throw PasskeyCredentialError.invalidClientDataHashLength
        }
    }

    public static func secureRandomBytes(count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw PasskeyCredentialError.randomFailure
        }
        return bytes
    }

    /// Encodes the P-256 public key as the WebAuthn COSE_Key map Monica stores in the vault
    /// (`publicKeyCOSE`). Also used when importing a CXF passkey: only the private key travels in
    /// the exchange payload, so the public key has to be derived locally.
    static func coseKey(for publicKey: P256.Signing.PublicKey) throws -> Data {
        let representation = publicKey.x963Representation
        guard representation.count == 65, representation.first == 0x04 else {
            throw PasskeyCredentialError.invalidPublicKey
        }

        return CBOR.map([
            (.int(1), .int(2)),
            (.int(3), .int(-7)),
            (.int(-1), .int(1)),
            (.int(-2), .bytes(representation[1..<33])),
            (.int(-3), .bytes(representation[33..<65]))
        ])
    }

    private static func publicKey(fromCOSEKey coseKey: Data) throws -> P256.Signing.PublicKey {
        guard let components = CBOR.parseP256COSEKey(coseKey),
              components.x.count == 32,
              components.y.count == 32
        else {
            throw PasskeyCredentialError.invalidCOSEKey
        }
        return try P256.Signing.PublicKey(x963Representation: Data([0x04]) + components.x + components.y)
    }

    private static func attestationObject(
        relyingPartyID: String,
        credentialID: Data,
        publicKeyCOSE: Data,
        userVerified: Bool,
        backupEligible: Bool,
        backupState: Bool
    ) throws -> Data {
        var attestedCredentialData = Data(repeating: 0, count: 16)
        attestedCredentialData.append(UInt8((credentialID.count >> 8) & 0xff))
        attestedCredentialData.append(UInt8(credentialID.count & 0xff))
        attestedCredentialData.append(credentialID)
        attestedCredentialData.append(publicKeyCOSE)

        var authData = authenticatorData(
            relyingPartyID: relyingPartyID,
            flags: flags(
                userVerified: userVerified,
                backupEligible: backupEligible,
                backupState: backupState
            ) | 0x40, // AT: attested credential data follows
            counter: 0
        )
        authData.append(attestedCredentialData)

        return CBOR.map([
            (.text("fmt"), .text("none")),
            (.text("attStmt"), .map([])),
            (.text("authData"), .bytes(authData))
        ])
    }

    /// UP is always set because a user action triggered the ceremony. UV, BE and BS follow
    /// what the caller actually performed: BS may only be claimed together with BE.
    static func flags(
        userVerified: Bool,
        backupEligible: Bool,
        backupState: Bool
    ) -> UInt8 {
        var flags: UInt8 = 0x01
        if userVerified {
            flags |= 0x04
        }
        if backupEligible {
            flags |= 0x08
        }
        if backupEligible && backupState {
            flags |= 0x10
        }
        return flags
    }

    /// Reads the authenticator data flags back out of an attestation object. Used by tests and
    /// by the extension when it needs to verify what it is about to hand to the platform.
    public static func authenticatorDataFlags(fromAttestationObject attestationObject: Data) -> UInt8? {
        CBOR.authenticatorDataFlags(attestationObject)
    }

    private static func authenticatorData(
        relyingPartyID: String,
        flags: UInt8,
        counter: UInt32
    ) -> Data {
        var data = Data(SHA256.hash(data: Data(relyingPartyID.utf8)))
        data.append(flags)
        data.append(UInt8((counter >> 24) & 0xff))
        data.append(UInt8((counter >> 16) & 0xff))
        data.append(UInt8((counter >> 8) & 0xff))
        data.append(UInt8(counter & 0xff))
        return data
    }
}

public enum PasskeyCredentialReference {
    public static func reference(for credentialID: Data) -> String {
        "monica-passkey://\(urlSafeBase64(credentialID))"
    }

    static func urlSafeBase64(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private enum CBORKey: Comparable {
    case int(Int)
    case text(String)

    static func < (lhs: CBORKey, rhs: CBORKey) -> Bool {
        switch (lhs, rhs) {
        case (.int(let lhs), .int(let rhs)):
            return lhs < rhs
        case (.int, .text):
            return true
        case (.text, .int):
            return false
        case (.text(let lhs), .text(let rhs)):
            return lhs < rhs
        }
    }
}

private indirect enum CBOR {
    case int(Int)
    case text(String)
    case bytes(Data)
    case map([(CBORKey, CBOR)])

    static func map(_ pairs: [(CBORKey, CBOR)]) -> Data {
        encode(.map(pairs))
    }

    static func parseP256COSEKey(_ data: Data) -> (x: Data, y: Data)? {
        var cursor = data.startIndex
        guard readByte(data, &cursor) == 0xA5 else {
            return nil
        }

        var x: Data?
        var y: Data?
        for _ in 0..<5 {
            guard let key = readSignedInteger(data, &cursor),
                  let value = readValue(data, &cursor)
            else {
                return nil
            }
            if key == -2 {
                x = value.bytes
            } else if key == -3 {
                y = value.bytes
            }
        }
        guard let x, let y else {
            return nil
        }
        return (x, y)
    }

    static func authenticatorDataFlags(_ attestationObject: Data) -> UInt8? {
        var cursor = attestationObject.startIndex
        guard readByte(attestationObject, &cursor) == 0xA3 else {
            return nil
        }
        for _ in 0..<3 {
            guard let key = readText(attestationObject, &cursor) else {
                return nil
            }
            if key == "authData" {
                guard let bytes = readByteString(attestationObject, &cursor),
                      bytes.count > 32
                else {
                    return nil
                }
                return bytes[bytes.startIndex + 32]
            }
            guard skipValue(attestationObject, &cursor) else {
                return nil
            }
        }
        return nil
    }

    private static func readByteString(_ data: Data, _ cursor: inout Data.Index) -> Data? {
        guard cursor < data.endIndex else {
            return nil
        }
        let initial = data[cursor]
        guard initial >> 5 == 2 else {
            return nil
        }
        cursor = data.index(after: cursor)
        guard let length = readLength(additionalInfo: initial & 0x1f, data, &cursor),
              cursor + length <= data.endIndex
        else {
            return nil
        }
        let value = Data(data[cursor..<cursor + length])
        cursor += length
        return value
    }

    private static func skipValue(_ data: Data, _ cursor: inout Data.Index) -> Bool {
        guard cursor < data.endIndex else {
            return false
        }
        let initial = data[cursor]
        let majorType = initial >> 5
        if majorType == 7 {
            cursor = data.index(after: cursor)
            return true
        }
        cursor = data.index(after: cursor)
        guard let length = readLength(additionalInfo: initial & 0x1f, data, &cursor) else {
            return false
        }
        switch majorType {
        case 0, 1:
            return true
        case 2, 3:
            guard cursor + length <= data.endIndex else {
                return false
            }
            cursor += length
            return true
        case 4:
            for _ in 0..<length where !skipValue(data, &cursor) {
                return false
            }
            return true
        case 5:
            for _ in 0..<length {
                guard skipValue(data, &cursor), skipValue(data, &cursor) else {
                    return false
                }
            }
            return true
        default:
            return false
        }
    }

    private static func readText(_ data: Data, _ cursor: inout Data.Index) -> String? {
        guard cursor < data.endIndex else {
            return nil
        }
        let initial = data[cursor]
        guard initial >> 5 == 3 else {
            return nil
        }
        cursor = data.index(after: cursor)
        guard let length = readLength(additionalInfo: initial & 0x1f, data, &cursor),
              cursor + length <= data.endIndex
        else {
            return nil
        }
        let value = String(decoding: data[cursor..<cursor + length], as: UTF8.self)
        cursor += length
        return value
    }

    private static func encode(_ value: CBOR) -> Data {
        switch value {
        case .int(let int):
            return encodeInt(int)
        case .text(let text):
            var data = encodeLength(majorType: 3, count: text.utf8.count)
            data.append(Data(text.utf8))
            return data
        case .bytes(let bytes):
            var data = encodeLength(majorType: 2, count: bytes.count)
            data.append(bytes)
            return data
        case .map(let pairs):
            let sortedPairs = pairs.sorted { $0.0 < $1.0 }
            var data = encodeLength(majorType: 5, count: sortedPairs.count)
            for (key, value) in sortedPairs {
                switch key {
                case .int(let int):
                    data.append(encodeInt(int))
                case .text(let text):
                    data.append(encode(.text(text)))
                }
                data.append(encode(value))
            }
            return data
        }
    }

    private static func encodeInt(_ value: Int) -> Data {
        if value >= 0 {
            return encodeLength(majorType: 0, count: value)
        }
        return encodeLength(majorType: 1, count: -1 - value)
    }

    private static func encodeLength(majorType: UInt8, count: Int) -> Data {
        let prefix = majorType << 5
        if count < 24 {
            return Data([prefix | UInt8(count)])
        }
        if count <= UInt8.max {
            return Data([prefix | 24, UInt8(count)])
        }
        if count <= UInt16.max {
            return Data([
                prefix | 25,
                UInt8((count >> 8) & 0xff),
                UInt8(count & 0xff)
            ])
        }
        return Data([
            prefix | 26,
            UInt8((count >> 24) & 0xff),
            UInt8((count >> 16) & 0xff),
            UInt8((count >> 8) & 0xff),
            UInt8(count & 0xff)
        ])
    }

    private struct ParsedValue {
        let bytes: Data?
    }

    private static func readValue(_ data: Data, _ cursor: inout Data.Index) -> ParsedValue? {
        guard cursor < data.endIndex else {
            return nil
        }
        let initial = data[cursor]
        let majorType = initial >> 5
        guard majorType == 2 else {
            _ = readSignedInteger(data, &cursor)
            return ParsedValue(bytes: nil)
        }
        cursor = data.index(after: cursor)
        guard let length = readLength(additionalInfo: initial & 0x1f, data, &cursor),
              cursor + length <= data.endIndex
        else {
            return nil
        }
        let value = Data(data[cursor..<cursor + length])
        cursor += length
        return ParsedValue(bytes: value)
    }

    private static func readSignedInteger(_ data: Data, _ cursor: inout Data.Index) -> Int? {
        guard cursor < data.endIndex else {
            return nil
        }
        let initial = data[cursor]
        let majorType = initial >> 5
        guard majorType == 0 || majorType == 1 else {
            return nil
        }
        cursor = data.index(after: cursor)
        guard let value = readLength(additionalInfo: initial & 0x1f, data, &cursor) else {
            return nil
        }
        return majorType == 0 ? value : -1 - value
    }

    private static func readLength(
        additionalInfo: UInt8,
        _ data: Data,
        _ cursor: inout Data.Index
    ) -> Int? {
        if additionalInfo < 24 {
            return Int(additionalInfo)
        }
        if additionalInfo == 24 {
            guard cursor < data.endIndex else {
                return nil
            }
            defer { cursor = data.index(after: cursor) }
            return Int(data[cursor])
        }
        if additionalInfo == 25 {
            guard cursor + 2 <= data.endIndex else {
                return nil
            }
            let value = (Int(data[cursor]) << 8) | Int(data[cursor + 1])
            cursor += 2
            return value
        }
        return nil
    }

    private static func readByte(_ data: Data, _ cursor: inout Data.Index) -> UInt8? {
        guard cursor < data.endIndex else {
            return nil
        }
        defer { cursor = data.index(after: cursor) }
        return data[cursor]
    }
}
