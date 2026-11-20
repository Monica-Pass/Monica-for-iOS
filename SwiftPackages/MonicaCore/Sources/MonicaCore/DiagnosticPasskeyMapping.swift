import Foundation

extension PasskeyCredentialError: DiagnosticCodedError {
    /// Maps the passkey failure to a stable code. The associated `OSStatus` and
    /// any error text are deliberately dropped: only the code and a closed tag
    /// leave this mapping, and `invalidClientDataHashLength` never carries the
    /// hash itself.
    public var diagnosticCode: DiagnosticCode {
        switch self {
        case .invalidRelyingPartyID:
            return .passkeyInvalidRelyingPartyID
        case .invalidClientDataHashLength:
            return .passkeyInvalidClientDataHash
        case .invalidUsername, .invalidUserHandle, .invalidCredentialID, .invalidPublicKey, .invalidCOSEKey:
            return .passkeyInvalidCredential
        case .privateKeyNotFound:
            return .passkeyIdentityUnavailable
        case .invalidPrivateKey, .randomFailure, .keychainUnexpectedStatus:
            return .passkeyKeychainFailure
        }
    }

    public var diagnosticReason: DiagnosticTag {
        switch self {
        case .invalidRelyingPartyID, .invalidClientDataHashLength, .invalidUsername, .invalidUserHandle,
             .invalidCredentialID, .invalidPublicKey, .invalidCOSEKey:
            return .invalidInput
        case .privateKeyNotFound:
            return .keychain
        case .invalidPrivateKey, .randomFailure, .keychainUnexpectedStatus:
            return .keychain
        }
    }

    /// The OSStatus is a number, not a message, so it is safe as `status`
    /// metadata. Every other case reports no numeric detail.
    public var diagnosticMetadata: DiagnosticMetadata {
        switch self {
        case .keychainUnexpectedStatus(let status):
            return .status(Int(status))
        default:
            return .reason(diagnosticReason)
        }
    }
}
