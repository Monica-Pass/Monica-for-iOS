import Foundation
import Testing
import MonicaCore
@testable import MonicaSync

private let expectedSHA256 = "9f2c7d1e8b3a40516f7e8d9c0b1a2f3e4d5c6b7a8f9e0d1c2b3a4f5e6d7c8b9a"
private let actualSHA256 = "0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9"
private let remoteRevision = "rev-9f8e7d6c5b4a"
private let expectedVaultID = "vault-1234-secret"
private let actualVaultID = "vault-9999-secret"
private let serverMessage = "Forbidden: token=eyJhbGciOiJIUzI1NiJ9.secret"

private var allErrors: [CloudVaultError] {
    [
        .invalidLocalVault(reason: "manifest missing"),
        .vaultTooLarge(byteCount: 104_857_600),
        .notConfigured(reason: "WebDAV 服务器地址、账号或密码尚未配置"),
        .unsupportedProvider(.webDAV),
        .unauthorized(.oneDrive),
        .forbidden(.webDAV),
        .preconditionFailed(remoteRevision: remoteRevision),
        .remoteManifestMissing,
        .remoteVaultMissing,
        .manifestInvalid(reason: "version unsupported"),
        .integrityMismatch(expectedSHA256: expectedSHA256, actualSHA256: actualSHA256),
        .vaultIDMismatch(expectedVaultID: expectedVaultID, actualVaultID: actualVaultID),
        .conflictRequiresResolution(CloudVaultConflict(
            reason: .bothChanged,
            localChanged: true,
            remoteChanged: true,
            baselineManifestRevision: 1,
            remoteManifestRevision: 2,
            remoteRevision: remoteRevision,
            localContentSHA256: expectedSHA256,
            remoteContentSHA256: actualSHA256
        )),
        .network("The request timed out"),
        .server(statusCode: 403, message: serverMessage),
        .stateCorrupted(reason: "record decode failed")
    ]
}

@Test func everyCloudVaultErrorMapsToADistinctStableCode() {
    let codes = allErrors.map(\.diagnosticCode)
    #expect(Set(codes).count == allErrors.count)
    #expect(codes.allSatisfy { $0.rawValue.hasPrefix("SYNC-") })
}

@Test func cloudVaultErrorMetadataCarriesOnlyNumbersAndClosedTags() {
    let tooLarge = CloudVaultError.vaultTooLarge(byteCount: 104_857_600)
    #expect(tooLarge.diagnosticMetadata.renderedFields == "bytes=104857600")
    #expect(tooLarge.diagnosticReason == .tooLarge)

    let server = CloudVaultError.server(statusCode: 403, message: serverMessage)
    #expect(server.diagnosticMetadata.renderedFields == "status=403")

    let forbidden = CloudVaultError.forbidden(.webDAV)
    #expect(forbidden.diagnosticMetadata.renderedFields == "provider=webDAV")

    let unauthorized = CloudVaultError.unauthorized(.oneDrive)
    #expect(unauthorized.diagnosticMetadata.renderedFields == "provider=oneDrive")

    // Payload-bearing cases contribute nothing beyond the reason tag.
    #expect(CloudVaultError.integrityMismatch(expectedSHA256: expectedSHA256, actualSHA256: actualSHA256).diagnosticMetadata.isEmpty)
    #expect(CloudVaultError.vaultIDMismatch(expectedVaultID: expectedVaultID, actualVaultID: actualVaultID).diagnosticMetadata.isEmpty)
    #expect(CloudVaultError.preconditionFailed(remoteRevision: remoteRevision).diagnosticMetadata.isEmpty)
    #expect(CloudVaultError.network("query?token=abc").diagnosticMetadata.isEmpty)
}

@Test func renderedEventForEveryCloudVaultErrorLeaksNoPayload() throws {
    let log = DiagnosticLog(configuration: .init(minimumLevel: .debug, mirrorsToSystemLog: false))
    for error in allErrors {
        log.record(
            error.diagnosticCode,
            level: .error,
            module: .cloudSync,
            metadata: error.diagnosticMetadata.merging(.reason(error.diagnosticReason), .provider(.webDAV))
        )
    }
    let report = try log.exportReport(minimumLevel: .debug, vaultIsUnlocked: true)

    for secret in [expectedSHA256, actualSHA256, remoteRevision, expectedVaultID, actualVaultID, serverMessage, "eyJhbGciOiJIUzI1NiJ9"] {
        #expect(!report.contains(secret))
    }
    #expect(report.contains("SYNC-1019"))
    #expect(report.contains("reason=integrity"))
    #expect(report.contains("bytes=104857600"))
    #expect(report.contains("status=403"))
}

@Test func remoteKindMapsToTheClosedProviderTagSet() {
    #expect(CloudVaultRemoteKind.webDAV.diagnosticProviderTag == .webDAV)
    #expect(CloudVaultRemoteKind.oneDrive.diagnosticProviderTag == .oneDrive)
}
