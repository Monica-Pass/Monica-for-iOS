@testable import Monica
import AuthenticationServices
import CryptoKit
import MonicaCore
import MonicaStorage
import XCTest

final class CredentialExchangePasskeyTests: XCTestCase {
    private func repositoryFileURL(_ relativePath: String) throws -> URL {
        #if os(iOS) && !targetEnvironment(simulator)
        throw XCTSkip("Repository files are not available inside the real-device test sandbox.")
        #else
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Repository file missing: \(relativePath)")
        }
        return url
        #endif
    }

    /// Fixed scalar so the PKCS#8 envelope below stays byte-stable across runs.
    private static func fixedPrivateKey() throws -> P256.Signing.PrivateKey {
        try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
    }

    @available(iOS 26.0, *)
    private static func passkeyCredential() throws -> ASImportableCredential {
        .passkey(ASImportableCredential.Passkey(
            credentialID: Data([0x01, 0x02, 0x03]),
            relyingPartyIdentifier: "example.com",
            userName: "alice@example.com",
            userDisplayName: "Alice",
            userHandle: Data([0x04, 0x05]),
            key: try fixedPrivateKey().derRepresentation
        ))
    }

    @available(iOS 26.0, *)
    func testCredentialExchangeBridgeRoundTripsPasskeyPrivateKey() throws {
        let der = try Self.fixedPrivateKey().derRepresentation
        let account = ASImportableAccount(
            id: Data([0x10]),
            userName: "alice@example.com",
            email: "alice@example.com",
            fullName: "Alice",
            collections: [],
            items: [
                ASImportableItem(
                    id: Data([0x11]),
                    created: Date(timeIntervalSince1970: 1000),
                    lastModified: Date(timeIntervalSince1970: 2000),
                    title: "Example",
                    subtitle: nil,
                    favorite: true,
                    scope: ASImportableCredentialScope(
                        urls: [URL(string: "https://example.com/login")!],
                        androidApps: []
                    ),
                    credentials: [try Self.passkeyCredential()],
                    tags: []
                )
            ]
        )
        let data = ASExportedCredentialData(
            accounts: [account],
            formatVersion: .v1,
            exporterRelyingPartyIdentifier: "com.example.exporter",
            exporterDisplayName: "Example",
            timestamp: Date(timeIntervalSince1970: 3000)
        )

        let accounts = AppCredentialExchangeBridge.accounts(from: data)
        XCTAssertEqual(accounts.count, 1)
        let credentials = accounts.first?.items.first?.credentials ?? []
        XCTAssertEqual(credentials.count, 1)
        guard case let .passkey(passkey)? = credentials.first else {
            return XCTFail("Passkey should survive the CXF bridge instead of degrading to unsupported")
        }
        XCTAssertEqual(passkey.credentialID, Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(passkey.relyingPartyIdentifier, "example.com")
        XCTAssertEqual(passkey.userName, "alice@example.com")
        XCTAssertEqual(passkey.userDisplayName, "Alice")
        XCTAssertEqual(passkey.userHandle, Data([0x04, 0x05]))
        XCTAssertEqual(passkey.privateKey, der)

        let plan = CredentialExchangeCodec.exportPlan(
            loginEntries: [],
            totpEntries: [],
            passkeyExports: [
                CredentialExchangePasskeyExport(
                    title: "Example",
                    favorite: true,
                    credential: passkey
                )
            ]
        )
        XCTAssertEqual(plan.passkeyCount, 1)
        XCTAssertFalse(plan.isEmpty)

        let exported = AppCredentialExchangeBridge.exportedData(from: plan)
        XCTAssertEqual(exported.formatVersion.rawValue, "1.0")
        let exportedCredentials = exported.accounts.first?.items.first?.credentials ?? []
        guard case let .passkey(exportedPasskey)? = exportedCredentials.first else {
            return XCTFail("Exported plan should carry the passkey credential")
        }
        XCTAssertEqual(exportedPasskey.credentialID, Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(exportedPasskey.relyingPartyIdentifier, "example.com")
        XCTAssertEqual(exportedPasskey.userName, "alice@example.com")
        XCTAssertEqual(exportedPasskey.userHandle, Data([0x04, 0x05]))
        XCTAssertEqual(exportedPasskey.key, der)
    }

    func testCredentialExchangePasskeyExportCandidatesSkipMalformedVaultEntries() {
        let validID = Data([0x01, 0x02, 0x03]).base64EncodedString()
        let validHandle = Data([0x04, 0x05]).base64EncodedString()
        let valid = LocalPasskeyEntry(
            id: "entry-1",
            projectID: "project-1",
            title: "Example",
            relyingPartyID: "example.com",
            username: "alice@example.com",
            userHandle: validHandle,
            credentialID: validID,
            publicKeyCOSE: "",
            privateKeyReference: "monica-passkey://AQID",
            notes: "",
            favorite: false
        )
        let malformed = LocalPasskeyEntry(
            id: "entry-2",
            projectID: "project-1",
            title: "Broken",
            relyingPartyID: "",
            username: "",
            userHandle: "not-base64",
            credentialID: "also-not-base64",
            publicKeyCOSE: "",
            privateKeyReference: "",
            notes: "",
            favorite: false
        )

        let candidates = AppCredentialExchangePasskeys.exportCandidates(from: [valid, malformed])
        XCTAssertEqual(candidates.entries.map(\.id), ["entry-1"])
        XCTAssertEqual(candidates.issues.count, 1)
        XCTAssertEqual(candidates.issues.first?.reason, .invalidData)
        XCTAssertEqual(candidates.issues.first?.displayTitle, "Broken")
    }

    func testCredentialExchangeIssuesDescribePermissionAndRevocationFailures() {
        let denied = AppCredentialExchangeIssue(
            error: PasskeyExchangeError.privateKeyAccessDenied,
            title: "Example",
            relyingPartyIdentifier: "example.com"
        )
        XCTAssertEqual(denied.reason, .accessDenied)
        XCTAssertFalse(denied.message.isEmpty)
        XCTAssertEqual(denied.displayTitle, "Example")

        let revoked = AppCredentialExchangeIssue(
            error: PasskeyExchangeError.privateKeyNotFound,
            title: "Example",
            relyingPartyIdentifier: "example.com"
        )
        XCTAssertEqual(revoked.reason, .missingPrivateKey)

        let keychain = AppCredentialExchangeIssue(
            error: PasskeyExchangeError.keychainUnexpectedStatus(-25308),
            title: "Example",
            relyingPartyIdentifier: "example.com"
        )
        XCTAssertEqual(keychain.reason, .storageFailure)

        let badData = AppCredentialExchangeIssue(
            error: PasskeyExchangeError.invalidPrivateKey,
            title: "Example",
            relyingPartyIdentifier: "example.com"
        )
        XCTAssertEqual(badData.reason, .invalidData)

        let duplicate = AppCredentialExchangeIssue(storageIssue: CredentialExchangePasskeyIssue(
            title: "Example",
            relyingPartyIdentifier: "example.com",
            reason: .duplicate
        ))
        XCTAssertEqual(duplicate.reason, .duplicate)
    }

    func testCredentialExchangeExportConfirmsDeviceOwnerBeforeReadingPrivateKeys() throws {
        let session = try String(
            contentsOf: try repositoryFileURL("App/MonicaApp/AppRoot/AppSessionModel.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(session.range(of: "func performCredentialExchangeExport() async -> Bool"))
        let remainder = session[start.upperBound...]
        let end = try XCTUnwrap(remainder.range(of: "func cancelCredentialExchangeExport()"))
        let body = remainder[..<end.lowerBound]

        let confirmation = try XCTUnwrap(body.range(of: "deviceOwnerAuthenticator.authenticate("))
        let keyAccess = try XCTUnwrap(body.range(of: "passkeyExchangeService.exportCredential("))
        XCTAssertLessThan(
            body.distance(from: body.startIndex, to: confirmation.lowerBound),
            body.distance(from: body.startIndex, to: keyAccess.lowerBound),
            "Device-owner confirmation must run before any private key is read"
        )
        XCTAssertTrue(body.contains("未通过设备确认，未导出任何数据。"))
        XCTAssertFalse(body.contains("NSLog("))

        // 只有确实要读私钥时才要求设备确认：纯密码/TOTP 导出保持旧行为，无密码设备也不会被拦住。
        let metadataPhase = try XCTUnwrap(
            body.range(of: "AppCredentialExchangePasskeys.exportCandidates(from: passkeyEntries)")
        )
        XCTAssertLessThan(
            body.distance(from: body.startIndex, to: metadataPhase.lowerBound),
            body.distance(from: body.startIndex, to: confirmation.lowerBound)
        )
        XCTAssertTrue(body.contains("if !candidates.entries.isEmpty {"))
    }

    func testCredentialExchangePasskeyRevocationBlocksLaterExport() throws {
        let store = MemoryPasskeyPrivateKeyStore()
        let service = PasskeyExchangeService(privateKeyStore: store)
        let der = try Self.fixedPrivateKey().derRepresentation
        let credential = PasskeyExchangeCredential(
            credentialID: Data([0x01, 0x02, 0x03]),
            relyingPartyID: "example.com",
            userName: "alice@example.com",
            userDisplayName: "Alice",
            userHandle: Data([0x04, 0x05]),
            privateKey: der
        )

        let prepared = try service.prepareImport(credential, title: "Example")
        XCTAssertNil(
            try store.loadPrivateKey(credentialID: Data([0x01, 0x02, 0x03])),
            "Preparing an import must not touch the keychain"
        )
        let reference = try service.commitImport(prepared)
        XCTAssertEqual(reference, prepared.privateKeyReference)

        let exported = try service.exportCredential(
            credentialID: Data([0x01, 0x02, 0x03]),
            relyingPartyID: "example.com",
            userName: "alice@example.com",
            userHandle: Data([0x04, 0x05])
        )
        XCTAssertEqual(exported.privateKey, der)

        // Revocation: once the key is gone the item degrades to a per-item issue
        // instead of exporting or crashing the whole batch.
        try service.deletePrivateKey(credentialID: Data([0x01, 0x02, 0x03]))
        XCTAssertThrowsError(try service.exportCredential(
            credentialID: Data([0x01, 0x02, 0x03]),
            relyingPartyID: "example.com",
            userName: "alice@example.com",
            userHandle: Data([0x04, 0x05])
        )) { error in
            XCTAssertEqual(error as? PasskeyExchangeError, .privateKeyNotFound)
        }
        let issue = AppCredentialExchangeIssue(
            error: PasskeyExchangeError.privateKeyNotFound,
            title: "Example",
            relyingPartyIdentifier: "example.com"
        )
        XCTAssertEqual(issue.reason, .missingPrivateKey)
    }
}
