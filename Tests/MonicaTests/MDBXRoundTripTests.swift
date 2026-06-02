import MonicaMDBX
import MonicaStorage
import XCTest

final class MDBXRoundTripTests: XCTestCase {
    func testProjectScopedLoginRoundTripThroughUniFFI() throws {
        let result = try MonicaMDBXTechnicalVerifier.runProjectScopedLoginRoundTrip(
            in: FileManager.default.temporaryDirectory,
            password: "中文 password 12345!",
            deviceID: "ios-xctest-device"
        )

        XCTAssertFalse(result.vaultID.isEmpty)
        XCTAssertEqual(result.deviceID, "ios-xctest-device")
        XCTAssertEqual(result.projectTitle, "GitHub")
        XCTAssertEqual(result.entryTitle, "GitHub main login")
    }

    func testStorageEntryRepositoryRoundTripThroughRealMDBXEngine() throws {
        let repository = LocalVaultRepository()
        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-storage-\(UUID().uuidString).mdbx")
        defer {
            try? FileManager.default.removeItem(at: vaultURL)
        }

        let session = try repository.createVault(
            named: vaultURL.deletingPathExtension().lastPathComponent,
            in: vaultURL.deletingLastPathComponent(),
            password: "中文 password 12345!",
            deviceID: "ios-storage-xctest-device"
        )
        let entries = repository.entryRepository(for: session)
        let project = try entries.createProject(title: "Personal")
        let created = try entries.createLoginEntry(
            projectID: project.id,
            draft: LocalLoginEntryDraft(
                title: "GitHub",
                username: "alice",
                password: "correct horse battery staple",
                url: "https://github.com"
            )
        )

        let listed = try entries.listLoginEntries(projectID: project.id)

        XCTAssertEqual(listed, [created])
        XCTAssertEqual(listed.first?.title, "GitHub")
        XCTAssertEqual(listed.first?.username, "alice")
    }

    func testStorageEntryRepositoryMovesEntriesThroughRealMDBXEngine() throws {
        let repository = LocalVaultRepository()
        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-move-\(UUID().uuidString).mdbx")
        defer {
            try? FileManager.default.removeItem(at: vaultURL)
        }

        let session = try repository.createVault(
            named: vaultURL.deletingPathExtension().lastPathComponent,
            in: vaultURL.deletingLastPathComponent(),
            password: "中文 password 12345!",
            deviceID: "ios-move-xctest-device"
        )
        let entries = repository.entryRepository(for: session)
        let personal = try entries.createProject(title: "Personal")
        let work = try entries.createProject(title: "Work")
        let login = try entries.createLoginEntry(
            projectID: personal.id,
            draft: LocalLoginEntryDraft(
                title: "GitHub",
                username: "alice",
                password: "correct horse battery staple",
                url: "https://github.com"
            )
        )
        let note = try entries.createNoteEntry(
            projectID: personal.id,
            draft: LocalNoteEntryDraft(title: "Recovery Codes", body: "github recovery")
        )
        let totp = try entries.createTotpEntry(
            projectID: personal.id,
            draft: LocalTotpEntryDraft(
                title: "GitHub 2FA",
                secret: "JBSWY3DPEHPK3PXP",
                issuer: "GitHub",
                accountName: "alice",
                period: 30,
                digits: 6,
                algorithm: "SHA1",
                otpType: "TOTP",
                counter: 0
            )
        )
        let card = try entries.createCardEntry(
            projectID: personal.id,
            draft: LocalCardEntryDraft(
                title: "Everyday Visa",
                cardholderName: "Alice Example",
                number: "4111111111111111",
                expiryMonth: "12",
                expiryYear: "2031",
                cvv: "123",
                issuer: "Monica Bank",
                network: "Visa",
                notes: "main card"
            )
        )
        let identity = try entries.createIdentityEntry(
            projectID: personal.id,
            draft: LocalIdentityEntryDraft(
                title: "Passport",
                documentType: "PASSPORT",
                fullName: "Alice Example",
                documentNumber: "P1234567",
                issuer: "Monica Authority",
                country: "US",
                issueDate: "2024-01-01",
                expiryDate: "2034-01-01",
                notes: "travel"
            )
        )
        let passkey = try entries.createPasskeyEntry(
            projectID: personal.id,
            draft: LocalPasskeyEntryDraft(
                title: "GitHub Passkey",
                relyingPartyID: "github.com",
                username: "alice",
                userHandle: "user-handle",
                credentialID: "credential-id",
                publicKeyCOSE: "public-key",
                privateKeyReference: "keychain-ref",
                notes: "AuthenticationServices metadata"
            )
        )
        let attachment = try entries.createAttachmentMetadata(
            projectID: personal.id,
            entryID: login.id,
            fileName: "passkey-note.txt",
            mediaType: "text/plain",
            originalSize: 128,
            storedSize: 128,
            contentHash: "sha256:attachment",
            storageMode: "embedded-inline"
        )

        let movedLogin = try entries.moveEntry(kind: .login, entryID: login.id, fromProjectID: personal.id, toProjectID: work.id)
        let movedNote = try entries.moveEntry(kind: .note, entryID: note.id, fromProjectID: personal.id, toProjectID: work.id)
        let movedTotp = try entries.moveEntry(kind: .totp, entryID: totp.id, fromProjectID: personal.id, toProjectID: work.id)
        let movedCard = try entries.moveEntry(kind: .card, entryID: card.id, fromProjectID: personal.id, toProjectID: work.id)
        let movedIdentity = try entries.moveEntry(kind: .identity, entryID: identity.id, fromProjectID: personal.id, toProjectID: work.id)
        let movedPasskey = try entries.moveEntry(kind: .passkey, entryID: passkey.id, fromProjectID: personal.id, toProjectID: work.id)
        let movedAttachment = try entries.moveEntry(kind: .attachmentRef, entryID: attachment.id, fromProjectID: personal.id, toProjectID: work.id)

        XCTAssertEqual(movedLogin, LocalVaultMovedEntry(id: login.id, title: "GitHub", kind: .login))
        XCTAssertEqual(movedNote, LocalVaultMovedEntry(id: note.id, title: "Recovery Codes", kind: .note))
        XCTAssertEqual(movedTotp, LocalVaultMovedEntry(id: totp.id, title: "GitHub 2FA", kind: .totp))
        XCTAssertEqual(movedCard, LocalVaultMovedEntry(id: card.id, title: "Everyday Visa", kind: .card))
        XCTAssertEqual(movedIdentity, LocalVaultMovedEntry(id: identity.id, title: "Passport", kind: .identity))
        XCTAssertEqual(movedPasskey, LocalVaultMovedEntry(id: passkey.id, title: "GitHub Passkey", kind: .passkey))
        XCTAssertEqual(movedAttachment, LocalVaultMovedEntry(id: attachment.id, title: "passkey-note.txt", kind: .attachmentRef))
        XCTAssertTrue(try entries.listLoginEntries(projectID: personal.id).isEmpty)
        XCTAssertTrue(try entries.listNoteEntries(projectID: personal.id).isEmpty)
        XCTAssertTrue(try entries.listTotpEntries(projectID: personal.id).isEmpty)
        XCTAssertTrue(try entries.listCardEntries(projectID: personal.id).isEmpty)
        XCTAssertTrue(try entries.listIdentityEntries(projectID: personal.id).isEmpty)
        XCTAssertTrue(try entries.listPasskeyEntries(projectID: personal.id).isEmpty)
        XCTAssertTrue(try entries.listAttachmentMetadata(projectID: personal.id).isEmpty)
        XCTAssertEqual(try entries.listLoginEntries(projectID: work.id).first?.id, login.id)
        XCTAssertEqual(try entries.listLoginEntries(projectID: work.id).first?.projectID, work.id)
        XCTAssertEqual(try entries.listNoteEntries(projectID: work.id).first?.id, note.id)
        XCTAssertEqual(try entries.listNoteEntries(projectID: work.id).first?.projectID, work.id)
        XCTAssertEqual(try entries.listTotpEntries(projectID: work.id).first?.id, totp.id)
        XCTAssertEqual(try entries.listTotpEntries(projectID: work.id).first?.projectID, work.id)
        XCTAssertEqual(try entries.listCardEntries(projectID: work.id).first?.id, card.id)
        XCTAssertEqual(try entries.listCardEntries(projectID: work.id).first?.projectID, work.id)
        XCTAssertEqual(try entries.listIdentityEntries(projectID: work.id).first?.id, identity.id)
        XCTAssertEqual(try entries.listIdentityEntries(projectID: work.id).first?.projectID, work.id)
        XCTAssertEqual(try entries.listPasskeyEntries(projectID: work.id).first?.id, passkey.id)
        XCTAssertEqual(try entries.listPasskeyEntries(projectID: work.id).first?.projectID, work.id)
        XCTAssertEqual(try entries.listAttachmentMetadata(projectID: work.id).first?.id, attachment.id)
        XCTAssertEqual(try entries.listAttachmentMetadata(projectID: work.id).first?.projectID, work.id)
    }

    func testAndroidParityEntriesRoundTripThroughRealMDBXEngine() throws {
        let repository = LocalVaultRepository()
        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-parity-\(UUID().uuidString).mdbx")
        defer {
            try? FileManager.default.removeItem(at: vaultURL)
        }

        let session = try repository.createVault(
            named: vaultURL.deletingPathExtension().lastPathComponent,
            in: vaultURL.deletingLastPathComponent(),
            password: "中文 password 12345!",
            deviceID: "ios-parity-xctest-device"
        )
        let entries = repository.entryRepository(for: session)
        let project = try entries.createProject(title: "Android Parity")

        let passkey = try entries.createPasskeyEntry(
            projectID: project.id,
            draft: LocalPasskeyEntryDraft(
                title: "GitHub Passkey",
                relyingPartyID: "github.com",
                username: "alice",
                userHandle: "user-handle",
                credentialID: "credential-id",
                publicKeyCOSE: "public-key",
                privateKeyReference: "keychain-ref",
                notes: "AuthenticationServices metadata"
            )
        )
        let sshKey = try entries.createSshKeyEntry(
            projectID: project.id,
            draft: LocalSshKeyEntryDraft(
                title: "Production SSH",
                username: "deploy",
                host: "prod.example.com",
                publicKey: "ssh-ed25519 AAAA",
                privateKeyReference: "keychain-ssh",
                passphraseHint: "vault protected",
                notes: "rotate quarterly"
            )
        )
        let apiToken = try entries.createApiTokenEntry(
            projectID: project.id,
            draft: LocalApiTokenEntryDraft(
                title: "OpenAI",
                issuer: "OpenAI",
                accountName: "alice@example.com",
                token: "sk-secret",
                scopes: "responses.read",
                expiresAt: "2026-12-31",
                notes: "local-only"
            )
        )
        let wifi = try entries.createWifiEntry(
            projectID: project.id,
            draft: LocalWifiEntryDraft(
                title: "Studio Wi-Fi",
                ssid: "MonicaLab",
                securityType: "WPA3",
                password: "wifi-secret",
                hidden: false,
                notes: "office"
            )
        )
        let send = try entries.createSendEntry(
            projectID: project.id,
            draft: LocalSendEntryDraft(
                title: "One-time secret",
                body: "share once",
                expiresAt: "2026-06-02T00:00:00Z",
                maxViews: 1,
                notes: "local metadata"
            )
        )

        XCTAssertEqual(try entries.setPasskeyEntryFavorite(projectID: project.id, entryID: passkey.id, favorite: true).username, "alice")
        XCTAssertEqual(try entries.setSshKeyEntryFavorite(projectID: project.id, entryID: sshKey.id, favorite: true).host, "prod.example.com")
        XCTAssertEqual(try entries.setApiTokenEntryFavorite(projectID: project.id, entryID: apiToken.id, favorite: true).token, "sk-secret")
        XCTAssertEqual(try entries.setWifiEntryFavorite(projectID: project.id, entryID: wifi.id, favorite: true).password, "wifi-secret")
        XCTAssertEqual(try entries.setSendEntryFavorite(projectID: project.id, entryID: send.id, favorite: true).body, "share once")

        let reopenedSession = try repository.openVault(
            at: vaultURL,
            password: "中文 password 12345!",
            deviceID: "ios-parity-xctest-device"
        )
        let reopenedEntries = repository.entryRepository(for: reopenedSession)

        XCTAssertEqual(try reopenedEntries.listPasskeyEntries(projectID: project.id).first?.relyingPartyID, "github.com")
        XCTAssertEqual(try reopenedEntries.listSshKeyEntries(projectID: project.id).first?.privateKeyReference, "keychain-ssh")
        XCTAssertEqual(try reopenedEntries.listApiTokenEntries(projectID: project.id).first?.scopes, "responses.read")
        XCTAssertEqual(try reopenedEntries.listWifiEntries(projectID: project.id).first?.ssid, "MonicaLab")
        XCTAssertEqual(try reopenedEntries.listSendEntries(projectID: project.id).first?.maxViews, 1)
    }

    func testAttachmentMetadataRoundTripThroughRealMDBXEngine() throws {
        let repository = LocalVaultRepository()
        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-attachment-\(UUID().uuidString).mdbx")
        defer {
            try? FileManager.default.removeItem(at: vaultURL)
        }

        let session = try repository.createVault(
            named: vaultURL.deletingPathExtension().lastPathComponent,
            in: vaultURL.deletingLastPathComponent(),
            password: "中文 password 12345!",
            deviceID: "ios-attachment-xctest-device"
        )
        let entries = repository.entryRepository(for: session)
        let project = try entries.createProject(title: "Attachments")
        let login = try entries.createLoginEntry(
            projectID: project.id,
            draft: LocalLoginEntryDraft(
                title: "GitHub",
                username: "alice",
                password: "correct horse battery staple",
                url: "https://github.com"
            )
        )

        let attachment = try entries.createAttachmentMetadata(
            projectID: project.id,
            entryID: login.id,
            fileName: "passkey-note.txt",
            mediaType: "text/plain",
            originalSize: 128,
            storedSize: 128,
            contentHash: "sha256:attachment",
            storageMode: "embedded-inline"
        )

        XCTAssertEqual(try entries.listAttachmentMetadata(projectID: project.id), [attachment])

        try entries.deleteAttachmentMetadata(projectID: project.id, attachmentID: attachment.id)
        XCTAssertTrue(try entries.listAttachmentMetadata(projectID: project.id).isEmpty)
        XCTAssertEqual(try entries.listDeletedAttachmentMetadata(projectID: project.id).first?.deleted, true)

        let restored = try entries.restoreAttachmentMetadata(
            projectID: project.id,
            attachmentID: attachment.id
        )
        let reopenedSession = try repository.openVault(
            at: vaultURL,
            password: "中文 password 12345!",
            deviceID: "ios-attachment-xctest-device"
        )
        let reopenedEntries = repository.entryRepository(for: reopenedSession)

        XCTAssertEqual(restored, attachment)
        XCTAssertEqual(try reopenedEntries.listAttachmentMetadata(projectID: project.id), [attachment])
    }

    func testVaultOpensWithLocalSecurityKeyMaterialWithoutPassword() throws {
        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-security-key-\(UUID().uuidString).mdbx")
        let securityKeyMaterial = Data(repeating: 0x2A, count: 32)
        defer {
            try? FileManager.default.removeItem(at: vaultURL)
        }

        let vault = try MonicaMDBXRuntime.createVault(
            at: vaultURL,
            password: "中文 password 12345!",
            deviceID: "ios-security-key-xctest-device"
        )
        let project = try vault.createProject(title: "Personal")
        let created = try vault.createLoginEntry(
            projectID: project.id,
            title: "GitHub",
            username: "alice",
            password: "correct horse battery staple",
            url: "https://github.com"
        )
        try vault.setupLocalSecurityKeyUnlock(securityKeyMaterial)

        let reopened = try MonicaMDBXRuntime.openVaultWithSecurityKey(
            at: vaultURL,
            securityKeyMaterial: securityKeyMaterial,
            deviceID: "ios-security-key-xctest-device"
        )
        let entries = try reopened.listLoginEntries(projectID: project.id)

        XCTAssertEqual(entries, [created])
        XCTAssertThrowsError(
            try MonicaMDBXRuntime.openVaultWithSecurityKey(
                at: vaultURL,
                securityKeyMaterial: Data(repeating: 0x07, count: 32),
                deviceID: "ios-security-key-xctest-device"
            )
        )
    }

    func testProjectScopedNoteRoundTripThroughUniFFI() throws {
        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-note-\(UUID().uuidString).mdbx")
        defer {
            try? FileManager.default.removeItem(at: vaultURL)
        }

        let vault = try MonicaMDBXRuntime.createVault(
            at: vaultURL,
            password: "中文 password 12345!",
            deviceID: "ios-note-xctest-device"
        )
        let project = try vault.createProject(title: "Personal")
        let created = try vault.createNoteEntry(
            projectID: project.id,
            title: "Recovery codes",
            body: "code-1\ncode-2"
        )
        let updated = try vault.updateNoteEntry(
            projectID: project.id,
            entryID: created.id,
            title: "Recovery codes updated",
            body: "code-3\ncode-4"
        )
        try vault.deleteNoteEntry(projectID: project.id, entryID: created.id)

        XCTAssertTrue(try vault.listNoteEntries(projectID: project.id).isEmpty)
        XCTAssertEqual(try vault.listDeletedNoteEntries(projectID: project.id), [updated])

        let restored = try vault.restoreNoteEntry(projectID: project.id, entryID: created.id)
        let reopened = try MonicaMDBXRuntime.openVault(
            at: vaultURL,
            password: "中文 password 12345!",
            deviceID: "ios-note-xctest-device"
        )
        let entries = try reopened.listNoteEntries(projectID: project.id)

        XCTAssertEqual(restored, updated)
        XCTAssertEqual(entries, [updated])
    }

    func testProjectScopedTotpRoundTripThroughUniFFI() throws {
        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-totp-\(UUID().uuidString).mdbx")
        defer {
            try? FileManager.default.removeItem(at: vaultURL)
        }

        let vault = try MonicaMDBXRuntime.createVault(
            at: vaultURL,
            password: "中文 password 12345!",
            deviceID: "ios-totp-xctest-device"
        )
        let project = try vault.createProject(title: "GitHub")
        let created = try vault.createTotpEntry(
            projectID: project.id,
            title: "GitHub TOTP",
            secret: "JBSWY3DPEHPK3PXP",
            issuer: "GitHub",
            accountName: "alice",
            period: 30,
            digits: 6,
            algorithm: "SHA1",
            otpType: "TOTP",
            counter: 0
        )
        let updated = try vault.updateTotpEntry(
            projectID: project.id,
            entryID: created.id,
            title: "GitHub Work TOTP",
            secret: "JBSWY3DPEHPK3PXQ",
            issuer: "GitHub",
            accountName: "alice@example.com",
            period: 60,
            digits: 8,
            algorithm: "SHA256",
            otpType: "TOTP",
            counter: 0
        )
        try vault.deleteTotpEntry(projectID: project.id, entryID: created.id)

        XCTAssertTrue(try vault.listTotpEntries(projectID: project.id).isEmpty)
        XCTAssertEqual(try vault.listDeletedTotpEntries(projectID: project.id), [updated])

        let restored = try vault.restoreTotpEntry(projectID: project.id, entryID: created.id)
        let reopened = try MonicaMDBXRuntime.openVault(
            at: vaultURL,
            password: "中文 password 12345!",
            deviceID: "ios-totp-xctest-device"
        )
        let entries = try reopened.listTotpEntries(projectID: project.id)

        XCTAssertEqual(restored, updated)
        XCTAssertEqual(entries, [updated])
    }

    func testProjectScopedCardRoundTripThroughUniFFI() throws {
        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-card-\(UUID().uuidString).mdbx")
        defer {
            try? FileManager.default.removeItem(at: vaultURL)
        }

        let vault = try MonicaMDBXRuntime.createVault(
            at: vaultURL,
            password: "中文 password 12345!",
            deviceID: "ios-card-xctest-device"
        )
        let project = try vault.createProject(title: "Bank")
        let created = try vault.createCardEntry(
            projectID: project.id,
            title: "Everyday Visa",
            cardholderName: "Alice Example",
            number: "4111111111111111",
            expiryMonth: "12",
            expiryYear: "2031",
            cvv: "123",
            issuer: "Monica Bank",
            network: "Visa",
            notes: "Primary checking card"
        )
        let updated = try vault.updateCardEntry(
            projectID: project.id,
            entryID: created.id,
            title: "Travel Mastercard",
            cardholderName: "Alice Q. Example",
            number: "5555555555554444",
            expiryMonth: "01",
            expiryYear: "2032",
            cvv: "456",
            issuer: "Monica Credit Union",
            network: "Mastercard",
            notes: "No foreign transaction fee"
        )
        try vault.deleteCardEntry(projectID: project.id, entryID: created.id)

        XCTAssertTrue(try vault.listCardEntries(projectID: project.id).isEmpty)
        XCTAssertEqual(try vault.listDeletedCardEntries(projectID: project.id), [updated])

        let restored = try vault.restoreCardEntry(projectID: project.id, entryID: created.id)
        let reopened = try MonicaMDBXRuntime.openVault(
            at: vaultURL,
            password: "中文 password 12345!",
            deviceID: "ios-card-xctest-device"
        )
        let entries = try reopened.listCardEntries(projectID: project.id)

        XCTAssertEqual(restored, updated)
        XCTAssertEqual(entries, [updated])
        XCTAssertEqual(entries.first?.number, "5555555555554444")
        XCTAssertEqual(entries.first?.cvv, "456")
    }

    func testProjectScopedIdentityRoundTripThroughUniFFI() throws {
        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-identity-\(UUID().uuidString).mdbx")
        defer {
            try? FileManager.default.removeItem(at: vaultURL)
        }

        let vault = try MonicaMDBXRuntime.createVault(
            at: vaultURL,
            password: "中文 password 12345!",
            deviceID: "ios-identity-xctest-device"
        )
        let project = try vault.createProject(title: "Identity")
        let created = try vault.createIdentityEntry(
            projectID: project.id,
            title: "Passport",
            documentType: "passport",
            fullName: "Alice Example",
            documentNumber: "P1234567",
            issuer: "Monica Authority",
            country: "US",
            issueDate: "2026-01-02",
            expiryDate: "2036-01-01",
            notes: "Primary travel document"
        )
        let updated = try vault.updateIdentityEntry(
            projectID: project.id,
            entryID: created.id,
            title: "Driver License",
            documentType: "driver_license",
            fullName: "Alice Q. Example",
            documentNumber: "D7654321",
            issuer: "Monica DMV",
            country: "US-CA",
            issueDate: "2026-05-31",
            expiryDate: "2031-05-30",
            notes: "State license metadata"
        )
        try vault.deleteIdentityEntry(projectID: project.id, entryID: created.id)

        XCTAssertTrue(try vault.listIdentityEntries(projectID: project.id).isEmpty)
        XCTAssertEqual(try vault.listDeletedIdentityEntries(projectID: project.id), [updated])

        let restored = try vault.restoreIdentityEntry(projectID: project.id, entryID: created.id)
        let reopened = try MonicaMDBXRuntime.openVault(
            at: vaultURL,
            password: "中文 password 12345!",
            deviceID: "ios-identity-xctest-device"
        )
        let entries = try reopened.listIdentityEntries(projectID: project.id)

        XCTAssertEqual(restored, updated)
        XCTAssertEqual(entries, [updated])
        XCTAssertEqual(entries.first?.documentNumber, "D7654321")
        XCTAssertEqual(entries.first?.country, "US-CA")
    }
}
