import Foundation
import MonicaCore

extension CloudVaultError: DiagnosticCodedError {
    /// A stable code per failure kind. Associated values are never carried: a
    /// revision, a SHA-256, a vault ID or a server message could all contain
    /// user data, so only the code, a closed reason tag and (where it is a plain
    /// number) an HTTP status or byte count survive.
    public var diagnosticCode: DiagnosticCode {
        switch self {
        case .invalidLocalVault:
            return .cloudSyncInvalidLocalVault
        case .vaultTooLarge:
            return .cloudSyncVaultTooLarge
        case .notConfigured:
            return .cloudSyncNotConfigured
        case .unsupportedProvider:
            return .cloudSyncUnsupportedProvider
        case .unauthorized:
            return .cloudSyncUnauthorized
        case .forbidden:
            return .cloudSyncForbidden
        case .preconditionFailed:
            return .cloudSyncPreconditionFailed
        case .remoteManifestMissing:
            return .cloudSyncRemoteManifestMissing
        case .remoteVaultMissing:
            return .cloudSyncRemoteVaultMissing
        case .manifestInvalid:
            return .cloudSyncManifestInvalid
        case .integrityMismatch:
            return .cloudSyncIntegrityMismatch
        case .vaultIDMismatch:
            return .cloudSyncVaultIDMismatch
        case .conflictRequiresResolution:
            return .cloudSyncConflict
        case .cloudAccountUnavailable:
            return .cloudSyncUnauthorized
        case .cloudQuotaExceeded:
            return .cloudSyncServerFailure
        case .network:
            return .cloudSyncNetworkFailure
        case .server:
            return .cloudSyncServerFailure
        case .stateCorrupted:
            return .cloudSyncStateCorrupted
        }
    }

    public var diagnosticReason: DiagnosticTag {
        switch self {
        case .invalidLocalVault:
            return .corrupted
        case .vaultTooLarge:
            return .tooLarge
        case .notConfigured:
            return .notConfigured
        case .unsupportedProvider:
            return .unsupported
        case .unauthorized:
            return .unauthorized
        case .forbidden:
            return .forbidden
        case .preconditionFailed:
            return .precondition
        case .remoteManifestMissing, .remoteVaultMissing:
            return .remoteMissing
        case .manifestInvalid:
            return .manifestInvalid
        case .integrityMismatch:
            return .integrity
        case .vaultIDMismatch:
            return .vaultIDMismatch
        case .conflictRequiresResolution:
            return .conflict
        case .cloudAccountUnavailable:
            return .unauthorized
        case .cloudQuotaExceeded:
            return .storage
        case .network:
            return .network
        case .server:
            return .server
        case .stateCorrupted:
            return .stateCorrupted
        }
    }

    /// The only extra metadata these errors are allowed to contribute.
    public var diagnosticMetadata: DiagnosticMetadata {
        switch self {
        case .vaultTooLarge(let byteCount):
            return .bytes(byteCount)
        case .server(let statusCode, _):
            return .status(statusCode)
        case .unauthorized(let kind), .forbidden(let kind), .unsupportedProvider(let kind),
             .cloudAccountUnavailable(let kind), .cloudQuotaExceeded(let kind):
            return .provider(kind.diagnosticProviderTag)
        default:
            return DiagnosticMetadata()
        }
    }
}

extension CloudVaultRemoteKind {
    /// Maps the remote kind onto the closed provider tag set.
    public var diagnosticProviderTag: DiagnosticTag {
        switch self {
        case .webDAV: return .webDAV
        case .oneDrive: return .oneDrive
        case .iCloud: return .iCloud
        }
    }
}
