import CryptoKit
import Foundation
import Security

/// One passkey entry as it travels through Credential Exchange (CXF v1.0).
///
/// The CXF payload carries the private key in `key` (PKCS#8 DER in the binary form,
/// Base64URL-encoded when serialized to JSON). The system type has no separate public key
/// field, so the public key is always derived from the private key on import. Older payloads
/// that carry a raw 32-byte private key are accepted as well, because rejecting them would
/// silently drop credentials that Apple's own importer still accepts.
public struct PasskeyExchangeCredential: Sendable, Equatable {
    public let credentialID: Data
    public let relyingPartyID: String
    public let userName: String
    public let userDisplayName: String
    public let userHandle: Data
    public let privateKey: Data

    public init(
        credentialID: Data,
        relyingPartyID: String,
        userName: String,
        userDisplayName: String = "",
        userHandle: Data,
        privateKey: Data
    ) {
        self.credentialID = credentialID
        self.relyingPartyID = relyingPartyID
        self.userName = userName
        self.userDisplayName = userDisplayName
        self.userHandle = userHandle
        self.privateKey = privateKey
    }
}

/// A validated import that has **not** been written to secure storage yet.
///
/// Building one is side-effect free, so the import preview can call
/// ``PasskeyExchangeService/prepareImport(_:title:notes:)`` without touching the keychain and a
/// cancelled import leaves nothing behind.
public struct PasskeyExchangeImport: Sendable, Equatable {
    public let relyingPartyID: String
    public let credentialID: Data
    public let username: String
    public let userHandle: Data
    public let publicKeyCOSE: Data
    public let privateKeyReference: String
    /// The vault metadata shared with the system passkey registration path.
    public let metadata: PasskeyVaultMetadataDraft

    /// The P-256 private key in the representation the keychain store uses. Never log this value.
    let rawPrivateKey: Data

    init(
        relyingPartyID: String,
        credentialID: Data,
        username: String,
        userHandle: Data,
        publicKeyCOSE: Data,
        privateKeyReference: String,
        rawPrivateKey: Data,
        metadata: PasskeyVaultMetadataDraft
    ) {
        self.relyingPartyID = relyingPartyID
        self.credentialID = credentialID
        self.username = username
        self.userHandle = userHandle
        self.publicKeyCOSE = publicKeyCOSE
        self.privateKeyReference = privateKeyReference
        self.rawPrivateKey = rawPrivateKey
        self.metadata = metadata
    }
}

/// Failure reasons that the import and export surfaces turn into a per-credential, readable
/// issue list. One bad credential never aborts the whole exchange.
public enum PasskeyExchangeError: Error, Sendable, Equatable {
    case invalidCredentialID
    case invalidRelyingPartyID
    case invalidUsername
    case invalidUserHandle
    case invalidPrivateKey
    case privateKeyNotFound
    /// The key exists but the device owner refused (or could not complete) the keychain prompt.
    case privateKeyAccessDenied
    /// The store returned a reference that does not match the credential; writing it would leave
    /// an orphaned key behind.
    case privateKeyReferenceMismatch
    case privateKeyStoreFailure
    case keychainUnexpectedStatus(OSStatus)
}

/// Converts between the CXF passkey payload and Monica's keychain-backed passkey storage.
///
/// The service deliberately does not know about `AuthenticationServices`: the app maps
/// `ASImportableCredential.Passkey` onto ``PasskeyExchangeCredential`` so that the validation,
/// PKCS#8 handling and keychain bookkeeping stay testable on any platform.
public struct PasskeyExchangeService: Sendable {
    private let privateKeyStore: any PasskeyPrivateKeyStore

    public init(privateKeyStore: any PasskeyPrivateKeyStore) {
        self.privateKeyStore = privateKeyStore
    }

    // MARK: - Import

    /// Validates an incoming passkey and derives everything the vault row needs.
    ///
    /// - Parameters:
    ///   - credential: The CXF payload.
    ///   - title: Display title for the new vault row.
    ///   - notes: Optional notes stored next to the metadata.
    /// - Returns: A prepared import. Nothing is persisted yet.
    public func prepareImport(
        _ credential: PasskeyExchangeCredential,
        title: String,
        notes: String = ""
    ) throws -> PasskeyExchangeImport {
        guard !credential.credentialID.isEmpty else {
            throw PasskeyExchangeError.invalidCredentialID
        }
        guard let normalizedRelyingPartyID = PasskeyRelyingPartyIDNormalizer.normalize(credential.relyingPartyID) else {
            throw PasskeyExchangeError.invalidRelyingPartyID
        }
        let username = credential.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            throw PasskeyExchangeError.invalidUsername
        }
        guard !credential.userHandle.isEmpty else {
            throw PasskeyExchangeError.invalidUserHandle
        }

        let rawPrivateKey = try Self.rawPrivateKey(from: credential.privateKey)
        let publicKey: P256.Signing.PublicKey
        do {
            publicKey = try P256.Signing.PrivateKey(rawRepresentation: rawPrivateKey).publicKey
        } catch {
            throw PasskeyExchangeError.invalidPrivateKey
        }
        let publicKeyCOSE: Data
        do {
            publicKeyCOSE = try MonicaPasskeyCredentialManager.coseKey(for: publicKey)
        } catch {
            throw PasskeyExchangeError.invalidPrivateKey
        }

        let reference = PasskeyCredentialReference.reference(for: credential.credentialID)
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let metadata = PasskeyVaultMetadataDraft(
            title: normalizedTitle.isEmpty ? normalizedRelyingPartyID : normalizedTitle,
            relyingPartyID: normalizedRelyingPartyID,
            username: username,
            userHandle: credential.userHandle.base64EncodedString(),
            credentialID: credential.credentialID.base64EncodedString(),
            publicKeyCOSE: publicKeyCOSE.base64EncodedString(),
            privateKeyReference: reference,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        return PasskeyExchangeImport(
            relyingPartyID: normalizedRelyingPartyID,
            credentialID: credential.credentialID,
            username: username,
            userHandle: credential.userHandle,
            publicKeyCOSE: publicKeyCOSE,
            privateKeyReference: reference,
            rawPrivateKey: rawPrivateKey,
            metadata: metadata
        )
    }

    /// Writes the private key to secure storage. Call only after the user confirmed the import.
    ///
    /// - Returns: The keychain reference stored in the vault row.
    @discardableResult
    public func commitImport(_ prepared: PasskeyExchangeImport) throws -> String {
        let reference: String
        do {
            reference = try privateKeyStore.savePrivateKey(
                prepared.rawPrivateKey,
                credentialID: prepared.credentialID
            )
        } catch {
            throw Self.mapStoreError(error)
        }
        guard reference == prepared.privateKeyReference else {
            // Do not leave a key behind that the vault row would not point at.
            try? privateKeyStore.deletePrivateKey(credentialID: prepared.credentialID)
            throw PasskeyExchangeError.privateKeyReferenceMismatch
        }
        return reference
    }

    /// Removes a key written by ``commitImport(_:)``. Used to undo a failed vault insert and to
    /// clean up after the vault row itself was deleted. Deleting a missing key is a no-op.
    public func rollbackImport(_ prepared: PasskeyExchangeImport) throws {
        try deletePrivateKey(credentialID: prepared.credentialID)
    }

    /// Removes the private key of a credential that is being dropped or revoked.
    public func deletePrivateKey(credentialID: Data) throws {
        do {
            try privateKeyStore.deletePrivateKey(credentialID: credentialID)
        } catch {
            throw Self.mapStoreError(error)
        }
    }

    // MARK: - Export

    /// Loads the private key from secure storage and encodes it in the CXF form.
    ///
    /// Missing, unreadable or revoked keys throw a ``PasskeyExchangeError`` so the caller can list
    /// the affected credential and keep exporting everything else.
    public func exportCredential(
        credentialID: Data,
        relyingPartyID: String,
        userName: String,
        userDisplayName: String = "",
        userHandle: Data
    ) throws -> PasskeyExchangeCredential {
        guard !credentialID.isEmpty else {
            throw PasskeyExchangeError.invalidCredentialID
        }
        guard let normalizedRelyingPartyID = PasskeyRelyingPartyIDNormalizer.normalize(relyingPartyID) else {
            throw PasskeyExchangeError.invalidRelyingPartyID
        }
        guard !userHandle.isEmpty else {
            throw PasskeyExchangeError.invalidUserHandle
        }

        let storedPrivateKey: Data?
        do {
            storedPrivateKey = try privateKeyStore.loadPrivateKey(credentialID: credentialID)
        } catch {
            throw Self.mapStoreError(error)
        }
        guard let storedPrivateKey else {
            throw PasskeyExchangeError.privateKeyNotFound
        }
        let rawPrivateKey = try Self.rawPrivateKey(from: storedPrivateKey)
        let pkcs8: Data
        do {
            pkcs8 = try P256.Signing.PrivateKey(rawRepresentation: rawPrivateKey).derRepresentation
        } catch {
            throw PasskeyExchangeError.invalidPrivateKey
        }

        return PasskeyExchangeCredential(
            credentialID: credentialID,
            relyingPartyID: normalizedRelyingPartyID,
            userName: userName,
            userDisplayName: userDisplayName,
            userHandle: userHandle,
            privateKey: pkcs8
        )
    }

    // MARK: - Private key envelopes

    /// Decodes the CXF `key` payload into the P-256 raw private key Monica stores.
    ///
    /// Accepts a PKCS#8 (or SEC1) DER envelope, which is what CXF requires, and also a bare
    /// 32-byte scalar for payloads produced by older exporters.
    static func rawPrivateKey(from exchangeKey: Data) throws -> Data {
        guard !exchangeKey.isEmpty else {
            throw PasskeyExchangeError.invalidPrivateKey
        }
        if exchangeKey.count == 32,
           (try? P256.Signing.PrivateKey(rawRepresentation: exchangeKey)) != nil {
            return exchangeKey
        }
        if let key = try? P256.Signing.PrivateKey(derRepresentation: exchangeKey) {
            return key.rawRepresentation
        }
        throw PasskeyExchangeError.invalidPrivateKey
    }

    static func mapStoreError(_ error: Error) -> PasskeyExchangeError {
        guard let passkeyError = error as? PasskeyCredentialError else {
            return .privateKeyStoreFailure
        }
        switch passkeyError {
        case .keychainUnexpectedStatus(let status):
            switch status {
            case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled, errSecNotAvailable:
                return .privateKeyAccessDenied
            default:
                return .keychainUnexpectedStatus(status)
            }
        case .privateKeyNotFound:
            return .privateKeyNotFound
        case .invalidPrivateKey, .invalidPublicKey, .invalidCOSEKey, .invalidCredentialID:
            return .invalidPrivateKey
        default:
            return .privateKeyStoreFailure
        }
    }
}
