import Testing
import MonicaSync
import Foundation

@Test func syncBaselineDocumentsWebDAVAsFirstBackupProvider() {
    #expect(MonicaSyncBaseline.firstBackupProvider == "WebDAV")
}

@Test func cloudFileProviderKindsExposeOneDriveAndGoogleDriveAdapters() {
    #expect(CloudFileProviderKind.oneDrive.displayName == "OneDrive")
    #expect(CloudFileProviderKind.googleDrive.displayName == "Google Drive")
    #expect(CloudFileProviderKind.oneDrive.defaultBackupFileName == "monica-onedrive.mdbx")
    #expect(CloudFileProviderKind.googleDrive.defaultBackupFileName == "monica-google-drive.mdbx")
}

@Test func oneDriveConfigurationCarriesMSALClientAndRedirectWithoutLeakingSecrets() throws {
    let configuration = OneDriveCloudFileConfiguration.monicaProduction

    #expect(configuration.clientID == "2aaf8c2c-b817-4085-9517-586a4a113dfc")
    #expect(configuration.redirectURI == URL(string: "msauth.com.monica-pass.monica://auth"))
    #expect(configuration.redirectScheme == "msauth.com.monica-pass.monica")
    #expect(configuration.redactedSummary == "OneDrive MSAL msauth.com.monica-pass.monica")
    #expect(!configuration.redactedSummary.contains(configuration.clientID))
    #expect(!configuration.redactedSummary.contains(configuration.redirectURI.absoluteString))
    #expect(!configuration.redactedSummary.contains("://auth"))
}

@Test func googleDriveProviderIsDeferredUntilExplicitlyEnabled() async throws {
    let provider = GoogleDriveCloudFileProvider()

    #expect(try await provider.connectionState() == .disconnected)
    await #expect(throws: CloudFileProviderError.unsupportedOperation(provider: .googleDrive)) {
        _ = try await provider.listFiles()
    }
}

@Test func oneDriveGraphProviderListsDownloadsUploadsAndConditionallyOverwritesAppFolderFilesWithoutLeakingSecrets() async throws {
    let tokenProvider = RecordingOneDriveAccessTokenProvider(token: "onedrive-access-token-secret")
    let transport = RecordingOneDriveGraphTransport()
    let provider = OneDriveCloudFileProvider(
        tokenProvider: tokenProvider,
        graphTransport: transport
    )
    transport.enqueue(
        statusCode: 200,
        body: """
        {
          "value": [
            {
              "id": "remote-item-secret-id",
              "name": "Mobile.kdbx",
              "size": 25,
              "eTag": "\\"etag-list-secret\\"",
              "lastModifiedDateTime": "2026-06-03T14:00:00Z",
              "parentReference": { "path": "/drive/special/approot:/MonicaPrivate" },
              "file": {}
            },
            {
              "id": "folder-secret-id",
              "name": "Folder",
              "size": 0,
              "folder": {}
            }
          ]
        }
        """
    )
    transport.enqueue(
        statusCode: 200,
        body: """
        {
          "id": "remote-item-secret-id",
          "name": "Mobile.kdbx",
          "size": 25,
          "eTag": "\\"etag-download-secret\\"",
          "parentReference": { "path": "/drive/special/approot:" },
          "file": {}
        }
        """
    )
    transport.enqueue(statusCode: 200, bodyData: Data("downloaded-kdbx-secret".utf8))
    transport.enqueue(
        statusCode: 201,
        body: """
        {
          "id": "uploaded-item-secret-id",
          "name": "Upload.kdbx",
          "size": 18,
          "eTag": "\\"etag-upload-secret\\"",
          "file": {}
        }
        """
    )
    transport.enqueue(
        statusCode: 200,
        body: """
        {
          "id": "remote-item-secret-id",
          "name": "Mobile.kdbx",
          "size": 19,
          "eTag": "\\"etag-overwrite-secret\\"",
          "file": {}
        }
        """
    )
    transport.enqueue(statusCode: 412, body: "{}")

    #expect(try await provider.connectionState() == .connected(accountLabel: "OneDrive"))
    let listed = try await provider.listFiles()
    let downloaded = try await provider.downloadFile(id: "remote-item-secret-id")
    let uploadReceipt = try await provider.uploadFile(
        named: "Upload.kdbx",
        data: Data("uploaded-kdbx-secret".utf8)
    )
    let overwriteReceipt = try await provider.overwriteFile(
        id: "remote-item-secret-id",
        data: Data("overwritten-kdbx-secret".utf8),
        fileName: "Mobile.kdbx",
        expectedRevision: "\"etag-download-secret\""
    )
    await #expect(throws: CloudFileProviderError.conflict(provider: .oneDrive)) {
        _ = try await provider.overwriteFile(
            id: "remote-item-secret-id",
            data: Data("conflicting-kdbx-secret".utf8),
            fileName: "Mobile.kdbx",
            expectedRevision: "\"stale-etag-secret\""
        )
    }

    #expect(listed.map(\.name) == ["Mobile.kdbx"])
    #expect(listed.first?.revision == "\"etag-list-secret\"")
    #expect(downloaded.data == Data("downloaded-kdbx-secret".utf8))
    #expect(downloaded.revision == "\"etag-download-secret\"")
    #expect(uploadReceipt.itemID == "uploaded-item-secret-id")
    #expect(uploadReceipt.revision == "\"etag-upload-secret\"")
    #expect(overwriteReceipt.revision == "\"etag-overwrite-secret\"")
    #expect(transport.requests.map(\.method) == ["GET", "GET", "GET", "PUT", "PUT", "PUT"])
    #expect(transport.requests[0].url.absoluteString == "https://graph.microsoft.com/v1.0/me/drive/special/approot/children")
    #expect(transport.requests[1].url.absoluteString == "https://graph.microsoft.com/v1.0/me/drive/items/remote-item-secret-id")
    #expect(transport.requests[2].url.absoluteString == "https://graph.microsoft.com/v1.0/me/drive/items/remote-item-secret-id/content")
    #expect(transport.requests[3].url.absoluteString == "https://graph.microsoft.com/v1.0/me/drive/special/approot:/Upload.kdbx:/content")
    #expect(transport.requests[4].headers["If-Match"] == "\"etag-download-secret\"")
    #expect(transport.requests[5].headers["If-Match"] == "\"stale-etag-secret\"")
    #expect(transport.requests.allSatisfy { $0.headers["Authorization"] == "Bearer onedrive-access-token-secret" })

    let visibleText = [
        listed.first?.redactedSummary ?? "",
        downloaded.redactedSummary,
        uploadReceipt.redactedSummary,
        overwriteReceipt.redactedSummary
    ].joined(separator: " ")
    [
        "onedrive-access-token-secret",
        "remote-item-secret-id",
        "uploaded-item-secret-id",
        "etag-list-secret",
        "etag-download-secret",
        "etag-upload-secret",
        "etag-overwrite-secret",
        "MonicaPrivate",
        "downloaded-kdbx-secret",
        "uploaded-kdbx-secret",
        "overwritten-kdbx-secret"
    ].forEach { secret in
        #expect(!visibleText.contains(secret))
    }
}

@Test func cloudFileProviderSummariesAvoidProviderSecretsAndRemoteIdentifiers() throws {
    let item = CloudFileItem(
        id: "remote-item-secret-id",
        name: "Mobile.mdbx",
        path: "/Apps/Monica/private-folder/Mobile.mdbx",
        byteCount: 11,
        modifiedAt: Date(timeIntervalSince1970: 1_804_000_000),
        sha256: "remote-sha-secret",
        revision: "remote-etag-secret"
    )
    let downloaded = CloudFileDownload(
        item: item,
        data: Data("remote-vault-secret-bytes".utf8),
        sha256: "download-sha-secret",
        revision: "download-etag-secret"
    )
    let receipt = CloudFileWriteReceipt(
        provider: .oneDrive,
        itemID: "uploaded-item-secret-id",
        name: "Mobile.mdbx",
        byteCount: 11,
        sha256: "upload-sha-secret",
        revision: "write-etag-secret"
    )

    #expect(item.redactedSummary == "Mobile.mdbx 11 字节")
    #expect(downloaded.redactedSummary == "Mobile.mdbx 25 字节")
    #expect(receipt.redactedSummary == "OneDrive Mobile.mdbx 11 字节")
    #expect(downloaded.revision == "download-etag-secret")
    #expect(receipt.revision == "write-etag-secret")

    let visibleText = [item.redactedSummary, downloaded.redactedSummary, receipt.redactedSummary]
        .joined(separator: " ")
    #expect(!visibleText.contains("remote-item-secret-id"))
    #expect(!visibleText.contains("private-folder"))
    #expect(!visibleText.contains("remote-sha-secret"))
    #expect(!visibleText.contains("remote-etag-secret"))
    #expect(!visibleText.contains("download-etag-secret"))
    #expect(!visibleText.contains("remote-vault-secret-bytes"))
    #expect(!visibleText.contains("uploaded-item-secret-id"))
    #expect(!visibleText.contains("upload-sha-secret"))
    #expect(!visibleText.contains("write-etag-secret"))
    #expect(CloudFileProviderError.conflict(provider: .oneDrive).errorDescription == "OneDrive 远端文件已变化，请重新下载后再写回。")
}

@Test func bitwardenSyncSnapshotAndMutationSummariesAvoidSecrets() throws {
    let snapshot = BitwardenSyncSnapshot(
        accountLabel: "alice@example.com",
        revision: "bw-revision-secret",
        items: [
            BitwardenSyncItem(
                remoteID: "remote-login-secret-id",
                kind: .login,
                title: "GitHub",
                username: "alice",
                url: "https://github.com/session?token=query-secret",
                password: "login-password-secret",
                totpSecret: "totp-secret",
                notes: "login-note-secret",
                folderName: "Engineering",
                collectionNames: ["Private"],
                attachmentByteCount: 19,
                updatedAt: Date(timeIntervalSince1970: 1_804_020_000)
            )
        ],
        sends: [
            BitwardenSendSyncItem(
                remoteID: "remote-send-secret-id",
                title: "Deploy link",
                body: "send-body-secret",
                notes: "send-note-secret",
                expiresAt: "2026-06-03",
                maxViews: 2,
                attachmentByteCount: 23,
                updatedAt: Date(timeIntervalSince1970: 1_804_020_001)
            )
        ]
    )
    let mutation = BitwardenSyncMutation.upsertSend(
        localID: "local-send-secret-id",
        remoteID: "remote-send-secret-id",
        title: "Deploy link",
        body: "rotated-send-body-secret",
        notes: "rotated-send-note-secret",
        expiresAt: "2026-06-03",
        maxViews: 3
    )
    let conflict = BitwardenSyncConflict(
        localID: "local-send-secret-id",
        remoteID: "remote-send-secret-id",
        title: "Deploy link",
        reason: .bothModified
    )

    #expect(snapshot.redactedSummary == "Bitwarden alice@example.com：1 个条目，1 个 Send")
    #expect(snapshot.items[0].redactedSummary == "login GitHub alice 19 字节附件")
    #expect(snapshot.sends[0].redactedSummary == "Send Deploy link 2 次 23 字节附件")
    #expect(mutation.redactedSummary == "upsert Send Deploy link 3 次")
    #expect(conflict.redactedSummary == "冲突 Deploy link：本地和远端都已修改")

    let visibleText = [
        snapshot.redactedSummary,
        snapshot.items[0].redactedSummary,
        snapshot.sends[0].redactedSummary,
        mutation.redactedSummary,
        conflict.redactedSummary
    ].joined(separator: " ")
    #expect(!visibleText.contains("bw-revision-secret"))
    #expect(!visibleText.contains("remote-login-secret-id"))
    #expect(!visibleText.contains("remote-send-secret-id"))
    #expect(!visibleText.contains("local-send-secret-id"))
    #expect(!visibleText.contains("query-secret"))
    #expect(!visibleText.contains("login-password-secret"))
    #expect(!visibleText.contains("totp-secret"))
    #expect(!visibleText.contains("login-note-secret"))
    #expect(!visibleText.contains("send-body-secret"))
    #expect(!visibleText.contains("send-note-secret"))
    #expect(!visibleText.contains("rotated-send-body-secret"))
    #expect(!visibleText.contains("rotated-send-note-secret"))
}

@Test func bitwardenSendSyncPlannerBuildsUpdateDeleteAndConflictPlanWithoutLeakingSecrets() throws {
    let previousStates = [
        BitwardenSendSyncState(
            localID: "local-update-secret-id",
            remoteID: "remote-update-secret-id",
            lastSyncedFingerprint: "stale-fingerprint",
            lastRemoteRevision: "remote-revision-secret"
        ),
        BitwardenSendSyncState(
            localID: "local-delete-secret-id",
            remoteID: "remote-delete-secret-id",
            lastSyncedFingerprint: "delete-fingerprint",
            lastRemoteRevision: "delete-revision-secret"
        ),
        BitwardenSendSyncState(
            localID: "local-remote-deleted-secret-id",
            remoteID: "remote-missing-secret-id",
            lastSyncedFingerprint: "missing-fingerprint",
            lastRemoteRevision: "missing-revision-secret"
        )
    ]
    let localSends = [
        BitwardenLocalSendSyncItem(
            localID: "local-update-secret-id",
            title: "Deploy link",
            body: "rotated-body-secret",
            notes: "rotated-note-secret",
            expiresAt: "2026-06-03",
            maxViews: 3
        ),
        BitwardenLocalSendSyncItem(
            localID: "local-new-secret-id",
            title: "Incident runbook",
            body: "new-body-secret",
            notes: "new-note-secret",
            expiresAt: "2026-06-04",
            maxViews: 1
        ),
        BitwardenLocalSendSyncItem(
            localID: "local-remote-deleted-secret-id",
            title: "Remote deleted",
            body: "locally-edited-body-secret",
            notes: "locally-edited-note-secret",
            expiresAt: "2026-06-05",
            maxViews: 2
        )
    ]
    let deletedLocalSends = [
        BitwardenLocalSendSyncItem(
            localID: "local-delete-secret-id",
            title: "Old link",
            body: "deleted-body-secret",
            notes: "deleted-note-secret",
            expiresAt: "2026-06-01",
            maxViews: 1
        )
    ]
    let remoteSends = [
        BitwardenSendSyncItem(
            remoteID: "remote-update-secret-id",
            title: "Deploy link",
            body: "old-body-secret",
            notes: "old-note-secret",
            expiresAt: "2026-06-03",
            maxViews: 2,
            updatedAt: Date(timeIntervalSince1970: 1_804_020_001)
        )
    ]

    let plan = BitwardenSendSyncPlanner().plan(
        localSends: localSends,
        deletedLocalSends: deletedLocalSends,
        remoteSends: remoteSends,
        previousStates: previousStates
    )

    #expect(plan.mutations.map(\.redactedSummary) == [
        "upsert Send Deploy link 3 次",
        "upsert Send Incident runbook 1 次",
        "delete Send Old link"
    ])
    #expect(plan.conflicts.map(\.redactedSummary) == [
        "冲突 Remote deleted：远端已删除"
    ])
    #expect(plan.updatedStates["local-update-secret-id"]?.remoteID == "remote-update-secret-id")
    #expect(plan.updatedStates["local-delete-secret-id"]?.isDeleted == true)
    #expect(plan.updatedStates["local-remote-deleted-secret-id"]?.remoteID == "remote-missing-secret-id")

    let visibleText = (
        plan.mutations.map(\.redactedSummary)
            + plan.conflicts.map(\.redactedSummary)
            + plan.updatedStates.values.map(\.redactedSummary)
    ).joined(separator: " ")
    #expect(!visibleText.contains("secret-id"))
    #expect(!visibleText.contains("body-secret"))
    #expect(!visibleText.contains("note-secret"))
    #expect(!visibleText.contains("revision-secret"))
}

@Test func bitwardenRefreshTokenProviderRefreshesSessionWithoutLeakingSecrets() async throws {
    let transport = RecordingBitwardenIdentityTransport()
    transport.result = BitwardenTokenRefreshResult(
        accessToken: "new-access-token-secret",
        refreshToken: "new-refresh-token-secret",
        expiresIn: 3600
    )
    let store = MemoryBitwardenAuthenticationSessionStore(
        session: BitwardenAuthenticationSession(
            accountLabel: "alice@example.com",
            serverURL: URL(string: "https://vault.bitwarden.com")!,
            identityURL: URL(string: "https://identity.bitwarden.com")!,
            apiURL: URL(string: "https://api.bitwarden.com")!,
            accessToken: "old-access-token-secret",
            refreshToken: "old-refresh-token-secret",
            expiresAt: Date(timeIntervalSince1970: 1_804_000_000)
        )
    )
    let provider = RefreshingBitwardenAccessTokenProvider(
        sessionStore: store,
        identityTransport: transport,
        now: { Date(timeIntervalSince1970: 1_804_000_100) }
    )

    let token = try await provider.accessToken()
    let saved = try #require(try store.loadSession())

    #expect(token == "new-access-token-secret")
    #expect(transport.requests == [
        BitwardenTokenRefreshRequest(
            identityURL: URL(string: "https://identity.bitwarden.com")!,
            refreshToken: "old-refresh-token-secret"
        )
    ])
    #expect(saved.accessToken == "new-access-token-secret")
    #expect(saved.refreshToken == "new-refresh-token-secret")
    #expect(saved.expiresAt == Date(timeIntervalSince1970: 1_804_003_700))
    #expect(saved.redactedSummary == "Bitwarden alice@example.com 已登录")
    let visibleText = [saved.redactedSummary].joined(separator: " ")
    #expect(!visibleText.contains("access-token-secret"))
    #expect(!visibleText.contains("refresh-token-secret"))
    #expect(!visibleText.contains("api.bitwarden.com"))
}

@Test func bitwardenRefreshTokenProviderRequiresSessionAndRefreshToken() async throws {
    let missingStore = MemoryBitwardenAuthenticationSessionStore()
    let provider = RefreshingBitwardenAccessTokenProvider(
        sessionStore: missingStore,
        identityTransport: RecordingBitwardenIdentityTransport()
    )
    await #expect(throws: BitwardenSyncProviderError.authenticationRequired) {
        _ = try await provider.accessToken()
    }

    let noRefreshStore = MemoryBitwardenAuthenticationSessionStore(
        session: BitwardenAuthenticationSession(
            accountLabel: "alice@example.com",
            serverURL: URL(string: "https://vault.bitwarden.com")!,
            identityURL: URL(string: "https://identity.bitwarden.com")!,
            apiURL: URL(string: "https://api.bitwarden.com")!,
            accessToken: "access-token-secret",
            refreshToken: nil,
            expiresAt: Date(timeIntervalSince1970: 1_804_000_000)
        )
    )
    let noRefreshProvider = RefreshingBitwardenAccessTokenProvider(
        sessionStore: noRefreshStore,
        identityTransport: RecordingBitwardenIdentityTransport(),
        now: { Date(timeIntervalSince1970: 1_804_000_100) }
    )
    await #expect(throws: BitwardenSyncProviderError.authenticationRequired) {
        _ = try await noRefreshProvider.accessToken()
    }
}

@Test func bitwardenPasswordAuthenticatorLogsInWithPBKDF2AndStoresDecryptionSession() async throws {
    let transport = RecordingBitwardenPasswordAuthenticationTransport()
    transport.enqueuePrelogin(
        statusCode: 200,
        body: #"{"Kdf":0,"KdfIterations":1000}"#
    )
    transport.enqueueToken(
        statusCode: 200,
        body: """
        {
          "access_token": "bitwarden-access-token-secret",
          "refresh_token": "bitwarden-refresh-token-secret",
          "expires_in": 3600,
          "Key": "2.AAECAwQFBgcICQoLDA0ODw==|bNW5Cs/xXNANXQtJ2ANJ+ZGT+Am0HFQ2QCSW1ojvZ+8peMsiFJJsM3HNXENFKcKmnyRIDVS8KbGBcIfyeRfzNm1TjUcSXZGrkB+R3famzG4=|5l1Q9FFGqTJViCO4tcJkphzXxhR31DWD143x2EUeRyo="
        }
        """
    )
    let sessionStore = MemoryBitwardenAuthenticationSessionStore()
    let keyStore = MemoryBitwardenVaultKeyStore()
    let authenticator = BitwardenPasswordAuthenticator(
        sessionStore: sessionStore,
        vaultKeyStore: keyStore,
        transport: transport,
        deviceIdentifier: { "ios-device-id" },
        now: { Date(timeIntervalSince1970: 1_804_000_000) }
    )

    let session = try await authenticator.signIn(
        email: "Alice@Example.com",
        masterPassword: "correct horse battery staple",
        serverURL: URL(string: "https://vault.bitwarden.com")!
    )

    #expect(session.accountLabel == "Alice@Example.com")
    #expect(session.accessToken == "bitwarden-access-token-secret")
    #expect(session.refreshToken == "bitwarden-refresh-token-secret")
    #expect(session.expiresAt == Date(timeIntervalSince1970: 1_804_003_600))
    #expect(try sessionStore.loadSession() == session)
    let vaultKey = try #require(try keyStore.loadVaultKey(accountLabel: "Alice@Example.com"))
    #expect(vaultKey.encryptionKey == Data((1...32).map(UInt8.init)))
    #expect(vaultKey.macKey == Data((33...64).map(UInt8.init)))

    let prelogin = try #require(transport.preloginRequests.first)
    #expect(prelogin.url.absoluteString == "https://identity.bitwarden.com/accounts/prelogin")
    #expect(prelogin.email == "Alice@Example.com")
    let token = try #require(transport.tokenRequests.first)
    #expect(token.url.absoluteString == "https://identity.bitwarden.com/connect/token")
    #expect(token.headers["Auth-Email"] == "QWxpY2VARXhhbXBsZS5jb20")
    #expect(token.headers["device-type"] == "8")
    #expect(token.form["grant_type"] == "password")
    #expect(token.form["username"] == "Alice@Example.com")
    #expect(token.form["password"] == "nidpx1SblZnybnMO5LIGKfdtOqx3HxJra2/cdFR2lNc=")
    #expect(token.form["scope"] == "api offline_access")
    #expect(token.form["client_id"] == "desktop")
    #expect(token.form["deviceIdentifier"] == "ios-device-id")
    #expect(token.form["deviceType"] == "8")
    #expect(token.form["deviceName"] == "linux")

    let visibleText = [session.redactedSummary, vaultKey.redactedSummary].joined(separator: " ")
    [
        "bitwarden-access-token-secret",
        "bitwarden-refresh-token-secret",
        "correct horse battery staple",
        "nidpx1SblZnybnMO5LIGKfdtOqx3HxJra2/cdFR2lNc",
        "bNW5Cs"
    ].forEach { secret in
        #expect(!visibleText.contains(secret))
    }
}

@Test func bitwardenPasswordAuthenticatorMapsObjectShapedTwoFactorChallenge() async throws {
    let transport = RecordingBitwardenPasswordAuthenticationTransport()
    transport.enqueuePrelogin(
        statusCode: 200,
        body: #"{"Kdf":0,"KdfIterations":1000}"#
    )
    transport.enqueueToken(
        statusCode: 400,
        body: #"{"TwoFactorProviders":{"0":{"Name":"Authenticator app"}}}"#
    )
    let authenticator = BitwardenPasswordAuthenticator(
        sessionStore: MemoryBitwardenAuthenticationSessionStore(),
        vaultKeyStore: MemoryBitwardenVaultKeyStore(),
        transport: transport,
        deviceIdentifier: { "ios-device-id" }
    )

    await #expect(throws: BitwardenSyncProviderError.twoFactorRequired) {
        try await authenticator.signIn(
            email: "alice@example.com",
            masterPassword: "master-password-secret",
            serverURL: URL(string: "https://vault.bitwarden.com")!
        )
    }
}

@Test func bitwardenVaultSyncProviderDecryptsEncryptedCipherAndSendPayloadsWithStoredVaultKey() async throws {
    let sessionStore = MemoryBitwardenAuthenticationSessionStore(
        session: BitwardenAuthenticationSession(
            accountLabel: "alice@example.com",
            serverURL: URL(string: "https://vault.bitwarden.com")!,
            identityURL: URL(string: "https://identity.bitwarden.com")!,
            apiURL: URL(string: "https://api.bitwarden.com")!,
            accessToken: "bitwarden-access-token-secret",
            refreshToken: "bitwarden-refresh-token-secret",
            expiresAt: Date(timeIntervalSince1970: 1_804_010_000)
        )
    )
    let keyStore = MemoryBitwardenVaultKeyStore()
    try keyStore.saveVaultKey(
        BitwardenVaultKey(
            encryptionKey: Data((1...32).map(UInt8.init)),
            macKey: Data((33...64).map(UInt8.init))
        ),
        accountLabel: "alice@example.com"
    )
    let vaultTransport = RecordingBitwardenVaultSyncTransport()
    vaultTransport.enqueue(
        statusCode: 200,
        body: """
        {
          "Profile": {
            "Email": "alice@example.com",
            "SecurityStamp": "server-security-stamp-secret"
          },
          "Ciphers": [
            {
              "Id": "cipher-login-secret-id",
              "Type": 1,
              "Name": "2.EBESExQVFhcYGRobHB0eHw==|tErnruiS0V91kFY96RcwiA==|FrzpnxOsjE5S1wEN6mko4Ko+jqufmBWrSkrVWZE5A8M=",
              "Notes": "2.UFFSU1RVVldYWVpbXF1eXw==|QQ5DX0KF9Pc3O9/VS8tSIg==|ZI3LDlknuqYxK6OzC+oXihDqked7fuhC6rGBwrQq76w=",
              "Login": {
                "Username": "2.ICEiIyQlJicoKSorLC0uLw==|7K7Q6bqqbfpfPX1EsLbFhw==|nRj2A6im5QwgywbZKDQ3uj+FCaMNkmKlcFqcyUZR8JQ=",
                "Password": "2.MDEyMzQ1Njc4OTo7PD0+Pw==|4WF696+21sCfxpKGHKVzcQ==|02+1QzcwdUveiuQmueel7W+0ioEEqVgUe/JfJbakNQo=",
                "Uris": [
                  { "Uri": "2.QEFCQ0RFRkdISUpLTE1OTw==|ivAIgHIp7FnPAb2W4tiMNUhvSqKCnM06Th+Z5SxNhiE=|8vALtNjALLR3t8EvALaiS38Eesu+W9rHHQpOyYSLMSE=" }
                ]
              }
            }
          ],
          "Sends": [
            {
              "Id": "send-text-secret-id",
              "Type": 0,
              "Key": "2.YGFiY2RlZmdoaWprbG1ubw==|zq7JJ4hjkg0cvWU50DKxDmCwuT4Y0WkNtDBgGN3j8a8=|PgLoRXs3hxeF6nybc/xWXGw7xbQtCBaKwO3tuFRsQM0=",
              "Name": "2.cHFyc3R1dnd4eXp7fH1+fw==|X0Ed5P+CcI4lsQLbWykoqA==|BOu5b1zccScdKnMfmmeCD9h3WPLH0cEV9T2ybc/+m2Y=",
              "Notes": "2.kJGSk5SVlpeYmZqbnJ2enw==|q805U9xwKY4A+FawL/QEqQ==|NegYGLj7SbS9jT+IHcuXsZTG8VYa7io8BkRuyArDG9I=",
              "Text": {
                "Text": "2.gIGCg4SFhoeIiYqLjI2Ojw==|g8HzlYI9yDNeJeNKIDtYOEz+sv9cN+MBf51xAcRmoMc=|6qZuQ04w5y3zufyNIrj0l5Ul5EZ8xLwSHpZiekQLt3I="
              },
              "MaxAccessCount": 2
            }
          ]
        }
        """
    )
    let provider = BitwardenVaultSyncProvider(
        sessionStore: sessionStore,
        identityTransport: RecordingBitwardenIdentityTransport(),
        vaultTransport: vaultTransport,
        vaultKeyStore: keyStore,
        now: { Date(timeIntervalSince1970: 1_804_000_100) }
    )

    let snapshot = try await provider.pullSnapshot()

    let login = try #require(snapshot.items.first)
    #expect(login.title == "GitHub")
    #expect(login.username == "alice")
    #expect(login.password == "p@ssw0rd!")
    #expect(login.url == "https://github.com/login")
    #expect(login.notes == "recovery note")
    let send = try #require(snapshot.sends.first)
    #expect(send.title == "Deploy link")
    #expect(send.body == "https://deploy.example/secret")
    #expect(send.notes == "send note")
    #expect(send.maxViews == 2)
}

@Test func bitwardenVaultSyncProviderPullsFullSnapshotThroughRefreshedTokenWithoutLeakingSecrets() async throws {
    let identityTransport = RecordingBitwardenIdentityTransport()
    identityTransport.result = BitwardenTokenRefreshResult(
        accessToken: "fresh-bitwarden-access-token-secret",
        refreshToken: "fresh-bitwarden-refresh-token-secret",
        expiresIn: 3600
    )
    let sessionStore = MemoryBitwardenAuthenticationSessionStore(
        session: BitwardenAuthenticationSession(
            accountLabel: "alice@example.com",
            serverURL: URL(string: "https://vault.bitwarden.com")!,
            identityURL: URL(string: "https://identity.bitwarden.com")!,
            apiURL: URL(string: "https://api.bitwarden.com")!,
            accessToken: "expired-bitwarden-access-token-secret",
            refreshToken: "old-bitwarden-refresh-token-secret",
            expiresAt: Date(timeIntervalSince1970: 1_804_000_000)
        )
    )
    let vaultTransport = RecordingBitwardenVaultSyncTransport()
    vaultTransport.enqueue(
        statusCode: 200,
        body: """
        {
          "Profile": {
            "Id": "profile-secret-id",
            "Name": "Alice",
            "Email": "alice@example.com",
            "Premium": true,
            "SecurityStamp": "server-security-stamp-secret"
          },
          "Folders": [
            {
              "Id": "folder-work-secret-id",
              "Name": "Work",
              "RevisionDate": "2026-06-03T12:00:00Z"
            }
          ],
          "Ciphers": [
            {
              "Id": "cipher-login-secret-id",
              "FolderId": "folder-work-secret-id",
              "Type": 1,
              "Name": "GitHub",
              "Notes": "login-note-secret",
              "RevisionDate": "2026-06-03T12:30:00Z",
              "Login": {
                "Username": "alice",
                "Password": "password-secret",
                "Totp": "totp-secret",
                "Uris": [{ "Uri": "https://github.com/session?token=query-secret" }]
              },
              "Attachments": [
                { "Id": "attachment-secret-id", "FileName": "deploy.txt", "Size": "42" }
              ]
            },
            {
              "Id": "cipher-note-secret-id",
              "Type": 2,
              "Name": "Recovery",
              "Notes": "recovery-note-secret",
              "RevisionDate": "2026-06-03T13:00:00Z",
              "SecureNote": { "Type": 0 }
            },
            {
              "Id": "cipher-card-secret-id",
              "Type": 3,
              "Name": "Everyday Visa",
              "Notes": "card-note-secret",
              "RevisionDate": "2026-06-03T13:10:00Z",
              "Card": {
                "CardholderName": "Alice Example",
                "Brand": "Visa",
                "Number": "4111111111111111",
                "ExpMonth": "12",
                "ExpYear": "2031",
                "Code": "123"
              }
            },
            {
              "Id": "cipher-identity-secret-id",
              "Type": 4,
              "Name": "Passport",
              "Notes": "identity-note-secret",
              "RevisionDate": "2026-06-03T13:20:00Z",
              "Identity": {
                "Title": "Dr.",
                "FirstName": "Alice",
                "MiddleName": "Q",
                "LastName": "Example",
                "PassportNumber": "P1234567",
                "Company": "Monica Authority",
                "Country": "US"
              }
            },
            {
              "Id": "cipher-deleted-secret-id",
              "Type": 1,
              "Name": "Deleted login",
              "DeletedDate": "2026-06-03T13:30:00Z",
              "Login": { "Username": "deleted-user-secret" }
            }
          ],
          "Sends": [
            {
              "Id": "send-text-secret-id",
              "Type": 0,
              "Name": "Deploy link",
              "Notes": "send-note-secret",
              "Text": { "Text": "send-body-secret" },
              "MaxAccessCount": 3,
              "ExpirationDate": "2026-06-05T00:00:00Z",
              "RevisionDate": "2026-06-03T14:00:00Z"
            },
            {
              "Id": "send-file-secret-id",
              "Type": 1,
              "Name": "Build artifact",
              "File": { "FileName": "artifact.zip", "Size": "1024" },
              "RevisionDate": "2026-06-03T14:05:00Z"
            }
          ]
        }
        """
    )
    let provider = BitwardenVaultSyncProvider(
        sessionStore: sessionStore,
        identityTransport: identityTransport,
        vaultTransport: vaultTransport,
        now: { Date(timeIntervalSince1970: 1_804_000_100) }
    )

    let snapshot = try await provider.pullSnapshot()
    let savedSession = try #require(try sessionStore.loadSession())

    #expect(identityTransport.requests == [
        BitwardenTokenRefreshRequest(
            identityURL: URL(string: "https://identity.bitwarden.com")!,
            refreshToken: "old-bitwarden-refresh-token-secret"
        )
    ])
    #expect(vaultTransport.requests.count == 1)
    #expect(vaultTransport.requests[0].method == "GET")
    #expect(vaultTransport.requests[0].url.absoluteString == "https://api.bitwarden.com/sync?excludeDomains=true")
    #expect(vaultTransport.requests[0].headers["Authorization"] == "Bearer fresh-bitwarden-access-token-secret")
    #expect(vaultTransport.requests[0].headers["Accept"] == "application/json")
    #expect(savedSession.accessToken == "fresh-bitwarden-access-token-secret")
    #expect(savedSession.refreshToken == "fresh-bitwarden-refresh-token-secret")

    #expect(snapshot.accountLabel == "Alice")
    #expect(snapshot.revision == "server-security-stamp-secret")
    #expect(snapshot.items.map(\.remoteID) == [
        "cipher-login-secret-id",
        "cipher-note-secret-id",
        "cipher-card-secret-id",
        "cipher-identity-secret-id"
    ])
    #expect(snapshot.items.map(\.kind) == [.login, .secureNote, .card, .identity])
    #expect(snapshot.items[0].title == "GitHub")
    #expect(snapshot.items[0].username == "alice")
    #expect(snapshot.items[0].url == "https://github.com/session?token=query-secret")
    #expect(snapshot.items[0].password == "password-secret")
    #expect(snapshot.items[0].totpSecret == "totp-secret")
    #expect(snapshot.items[0].notes == "login-note-secret")
    #expect(snapshot.items[0].folderName == "Work")
    #expect(snapshot.items[0].attachmentByteCount == 42)
    #expect(snapshot.items[1].title == "Recovery")
    #expect(snapshot.items[1].notes == "recovery-note-secret")
    #expect(snapshot.items[2].cardholderName == "Alice Example")
    #expect(snapshot.items[2].cardNumber == "4111111111111111")
    #expect(snapshot.items[2].cardExpiryMonth == "12")
    #expect(snapshot.items[2].cardExpiryYear == "2031")
    #expect(snapshot.items[2].cardCode == "123")
    #expect(snapshot.items[2].cardBrand == "Visa")
    #expect(snapshot.items[3].identityFullName == "Dr. Alice Q Example")
    #expect(snapshot.items[3].identityDocumentNumber == "P1234567")
    #expect(snapshot.items[3].identityIssuer == "Monica Authority")
    #expect(snapshot.items[3].identityCountry == "US")
    #expect(snapshot.sends.map(\.remoteID) == ["send-text-secret-id", "send-file-secret-id"])
    #expect(snapshot.sends[0].title == "Deploy link")
    #expect(snapshot.sends[0].body == "send-body-secret")
    #expect(snapshot.sends[0].maxViews == 3)
    #expect(snapshot.sends[0].expiresAt == "2026-06-05T00:00:00Z")
    #expect(snapshot.sends[1].title == "Build artifact")
    #expect(snapshot.sends[1].body == "artifact.zip")
    #expect(snapshot.sends[1].attachmentByteCount == 1024)

    let visibleText = (
        [snapshot.redactedSummary]
            + snapshot.items.map(\.redactedSummary)
            + snapshot.sends.map(\.redactedSummary)
            + [savedSession.redactedSummary]
    ).joined(separator: " ")
    [
        "bitwarden-access-token-secret",
        "bitwarden-refresh-token-secret",
        "profile-secret-id",
        "folder-work-secret-id",
        "cipher-login-secret-id",
        "cipher-note-secret-id",
        "cipher-card-secret-id",
        "cipher-identity-secret-id",
        "cipher-deleted-secret-id",
        "attachment-secret-id",
        "query-secret",
        "password-secret",
        "totp-secret",
        "login-note-secret",
        "recovery-note-secret",
        "card-note-secret",
        "4111111111111111",
        "P1234567",
        "identity-note-secret",
        "deleted-user-secret",
        "send-text-secret-id",
        "send-file-secret-id",
        "send-body-secret",
        "send-note-secret",
        "server-security-stamp-secret"
    ].forEach { secret in
        #expect(!visibleText.contains(secret))
    }
}

@Test func bitwardenVaultSyncProviderPushesEncryptedSendMutationsThroughRealRestEndpoints() async throws {
    let sessionStore = MemoryBitwardenAuthenticationSessionStore(
        session: BitwardenAuthenticationSession(
            accountLabel: "alice@example.com",
            serverURL: URL(string: "https://vault.bitwarden.com")!,
            identityURL: URL(string: "https://identity.bitwarden.com")!,
            apiURL: URL(string: "https://api.bitwarden.com")!,
            accessToken: "fresh-access-token-secret",
            refreshToken: "refresh-token-secret",
            expiresAt: Date(timeIntervalSince1970: 1_804_010_000)
        )
    )
    let vaultTransport = RecordingBitwardenVaultSyncTransport()
    vaultTransport.enqueue(
        statusCode: 200,
        body: #"{"Id":"created-send-secret-id","RevisionDate":"2026-06-04T09:00:00Z"}"#
    )
    vaultTransport.enqueue(
        statusCode: 200,
        body: #"{"Id":"updated-send-secret-id","RevisionDate":"2026-06-04T09:05:00Z"}"#
    )
    vaultTransport.enqueue(statusCode: 204, body: "")
    let provider = BitwardenVaultSyncProvider(
        sessionStore: sessionStore,
        identityTransport: RecordingBitwardenIdentityTransport(),
        vaultTransport: vaultTransport,
        now: { Date(timeIntervalSince1970: 1_804_000_100) }
    )

    let result = try await provider.pushMutations([
        .upsertEncryptedSend(
            localID: "local-create-secret-id",
            remoteID: nil,
            key: "2.encrypted-key-secret",
            name: "2.encrypted-name-secret",
            notes: "2.encrypted-notes-secret",
            text: "2.encrypted-text-secret",
            deletionDate: "2026-06-11T00:00:00Z",
            expirationDate: "2026-06-05T00:00:00Z",
            maxAccessCount: 3
        ),
        .upsertEncryptedSend(
            localID: "local-update-secret-id",
            remoteID: "remote-update-secret-id",
            key: "2.encrypted-update-key-secret",
            name: "2.encrypted-update-name-secret",
            notes: nil,
            text: "2.encrypted-update-text-secret",
            deletionDate: "2026-06-12T00:00:00Z",
            expirationDate: nil,
            maxAccessCount: nil
        ),
        .deleteSend(
            localID: "local-delete-secret-id",
            remoteID: "remote-delete-secret-id",
            title: "Deleted Send Secret"
        )
    ])

    #expect(result.acceptedMutationCount == 3)
    #expect(result.conflicts.isEmpty)
    #expect(result.revision == "2026-06-04T09:05:00Z")
    #expect(vaultTransport.requests.map(\.method) == ["POST", "PUT", "DELETE"])
    #expect(vaultTransport.requests.map { $0.url.absoluteString } == [
        "https://api.bitwarden.com/sends",
        "https://api.bitwarden.com/sends/remote-update-secret-id",
        "https://api.bitwarden.com/sends/remote-delete-secret-id"
    ])
    vaultTransport.requests.forEach { request in
        #expect(request.headers["Authorization"] == "Bearer fresh-access-token-secret")
        #expect(request.headers["Accept"] == "application/json")
    }
    #expect(vaultTransport.requests[0].headers["Content-Type"] == "application/json")
    #expect(vaultTransport.requests[1].headers["Content-Type"] == "application/json")
    #expect(vaultTransport.requests[2].body == nil)

    let createBody = try decodedJSONDictionary(vaultTransport.requests[0].body)
    #expect(createBody["key"] as? String == "2.encrypted-key-secret")
    #expect(createBody["name"] as? String == "2.encrypted-name-secret")
    #expect(createBody["notes"] as? String == "2.encrypted-notes-secret")
    #expect(createBody["type"] as? Int == 0)
    #expect(createBody["deletionDate"] as? String == "2026-06-11T00:00:00Z")
    #expect(createBody["expirationDate"] as? String == "2026-06-05T00:00:00Z")
    #expect(createBody["maxAccessCount"] as? Int == 3)
    let createText = try #require(createBody["text"] as? [String: Any])
    #expect(createText["text"] as? String == "2.encrypted-text-secret")
    #expect(createText["hidden"] as? Bool == false)

    let updateBody = try decodedJSONDictionary(vaultTransport.requests[1].body)
    #expect(updateBody["key"] as? String == "2.encrypted-update-key-secret")
    #expect(updateBody["name"] as? String == "2.encrypted-update-name-secret")
    #expect(updateBody["notes"] is NSNull)
    #expect(updateBody["expirationDate"] is NSNull)
    #expect(updateBody["maxAccessCount"] is NSNull)
    let updateText = try #require(updateBody["text"] as? [String: Any])
    #expect(updateText["text"] as? String == "2.encrypted-update-text-secret")

    let visibleText = (
        [result.redactedSummary]
            + [
                BitwardenSyncMutation.upsertEncryptedSend(
                    localID: "local-create-secret-id",
                    remoteID: nil,
                    key: "2.encrypted-key-secret",
                    name: "2.encrypted-name-secret",
                    notes: "2.encrypted-notes-secret",
                    text: "2.encrypted-text-secret",
                    deletionDate: "2026-06-11T00:00:00Z",
                    expirationDate: "2026-06-05T00:00:00Z",
                    maxAccessCount: 3
                ).redactedSummary
            ]
    ).joined(separator: " ")
    [
        "fresh-access-token-secret",
        "local-create-secret-id",
        "encrypted-key-secret",
        "encrypted-name-secret",
        "encrypted-text-secret",
        "remote-update-secret-id"
    ].forEach { secret in
        #expect(!visibleText.contains(secret))
    }
}

@Test func bitwardenVaultSyncProviderProtectsPlaintextSendMutationsAndMapsPushFailures() async throws {
    let sessionStore = MemoryBitwardenAuthenticationSessionStore(
        session: BitwardenAuthenticationSession(
            accountLabel: "alice@example.com",
            serverURL: URL(string: "https://vault.bitwarden.com")!,
            identityURL: URL(string: "https://identity.bitwarden.com")!,
            apiURL: URL(string: "https://api.bitwarden.com")!,
            accessToken: "fresh-access-token-secret",
            refreshToken: "refresh-token-secret",
            expiresAt: Date(timeIntervalSince1970: 1_804_010_000)
        )
    )
    let plaintextTransport = RecordingBitwardenVaultSyncTransport()
    let plaintextProvider = BitwardenVaultSyncProvider(
        sessionStore: sessionStore,
        identityTransport: RecordingBitwardenIdentityTransport(),
        vaultTransport: plaintextTransport,
        now: { Date(timeIntervalSince1970: 1_804_000_100) }
    )
    await #expect(throws: BitwardenSyncProviderError.unsupportedOperation) {
        _ = try await plaintextProvider.pushMutations([
            .upsertSend(
                localID: "local-send-secret-id",
                remoteID: nil,
                title: "Plaintext Title",
                body: "plaintext-body-secret",
                notes: nil,
                expiresAt: "",
                maxViews: 1
            )
        ])
    }
    #expect(plaintextTransport.requests.isEmpty)

    let unauthorizedTransport = RecordingBitwardenVaultSyncTransport()
    unauthorizedTransport.enqueue(statusCode: 403, body: "{}")
    let unauthorizedProvider = BitwardenVaultSyncProvider(
        sessionStore: sessionStore,
        identityTransport: RecordingBitwardenIdentityTransport(),
        vaultTransport: unauthorizedTransport,
        now: { Date(timeIntervalSince1970: 1_804_000_100) }
    )
    await #expect(throws: BitwardenSyncProviderError.authenticationRequired) {
        _ = try await unauthorizedProvider.pushMutations([
            .deleteSend(localID: "local-delete-secret-id", remoteID: "remote-delete-secret-id", title: "Delete")
        ])
    }

    let failingTransport = RecordingBitwardenVaultSyncTransport()
    failingTransport.enqueue(statusCode: 500, body: "{}")
    let failingProvider = BitwardenVaultSyncProvider(
        sessionStore: sessionStore,
        identityTransport: RecordingBitwardenIdentityTransport(),
        vaultTransport: failingTransport,
        now: { Date(timeIntervalSince1970: 1_804_000_100) }
    )
    await #expect(throws: BitwardenSyncProviderError.serverRejected(statusCode: 500)) {
        _ = try await failingProvider.pushMutations([
            .deleteSend(localID: "local-delete-secret-id", remoteID: "remote-delete-secret-id", title: "Delete")
        ])
    }

    let alreadyDeletedTransport = RecordingBitwardenVaultSyncTransport()
    alreadyDeletedTransport.enqueue(statusCode: 404, body: "{}")
    let alreadyDeletedProvider = BitwardenVaultSyncProvider(
        sessionStore: sessionStore,
        identityTransport: RecordingBitwardenIdentityTransport(),
        vaultTransport: alreadyDeletedTransport,
        now: { Date(timeIntervalSince1970: 1_804_000_100) }
    )
    let result = try await alreadyDeletedProvider.pushMutations([
        .deleteSend(localID: "local-delete-secret-id", remoteID: "remote-delete-secret-id", title: "Delete")
    ])
    #expect(result.acceptedMutationCount == 1)
}

@Test func bitwardenVaultSyncProviderMapsAuthenticationAndServerFailures() async throws {
    let missingStore = MemoryBitwardenAuthenticationSessionStore()
    let missingProvider = BitwardenVaultSyncProvider(
        sessionStore: missingStore,
        identityTransport: RecordingBitwardenIdentityTransport(),
        vaultTransport: RecordingBitwardenVaultSyncTransport()
    )
    await #expect(throws: BitwardenSyncProviderError.authenticationRequired) {
        _ = try await missingProvider.pullSnapshot()
    }

    let sessionStore = MemoryBitwardenAuthenticationSessionStore(
        session: BitwardenAuthenticationSession(
            accountLabel: "alice@example.com",
            serverURL: URL(string: "https://vault.bitwarden.com")!,
            identityURL: URL(string: "https://identity.bitwarden.com")!,
            apiURL: URL(string: "https://api.bitwarden.com")!,
            accessToken: "access-token-secret",
            refreshToken: "refresh-token-secret",
            expiresAt: Date(timeIntervalSince1970: 1_804_010_000)
        )
    )
    let unauthorizedTransport = RecordingBitwardenVaultSyncTransport()
    unauthorizedTransport.enqueue(statusCode: 401, body: "{}")
    let unauthorizedProvider = BitwardenVaultSyncProvider(
        sessionStore: sessionStore,
        identityTransport: RecordingBitwardenIdentityTransport(),
        vaultTransport: unauthorizedTransport,
        now: { Date(timeIntervalSince1970: 1_804_000_100) }
    )
    await #expect(throws: BitwardenSyncProviderError.authenticationRequired) {
        _ = try await unauthorizedProvider.pullSnapshot()
    }

    let failingTransport = RecordingBitwardenVaultSyncTransport()
    failingTransport.enqueue(statusCode: 500, body: "{}")
    let failingProvider = BitwardenVaultSyncProvider(
        sessionStore: sessionStore,
        identityTransport: RecordingBitwardenIdentityTransport(),
        vaultTransport: failingTransport,
        now: { Date(timeIntervalSince1970: 1_804_000_100) }
    )
    await #expect(throws: BitwardenSyncProviderError.serverRejected(statusCode: 500)) {
        _ = try await failingProvider.pullSnapshot()
    }
}

@Test func webDAVClientUploadsBackupWithBasicAuthAndIntegrityHeader() async throws {
    let transport = RecordingWebDAVTransport(
        responses: [
            WebDAVTransportResponse(statusCode: 201, body: Data()),
            WebDAVTransportResponse(statusCode: 201, body: Data())
        ]
    )
    let client = WebDAVClient(
        endpoint: WebDAVEndpoint(
            baseURL: try #require(URL(string: "https://dav.example.com/backups/")),
            username: "alice",
            password: "secret"
        ),
        transport: transport
    )
    let package = WebDAVBackupPackage(
        fileName: "mobile.mdbx",
        data: Data("vault-bytes".utf8)
    )

    let receipt = try await client.upload(package)

    let vaultRequest = try #require(transport.requests.first)
    #expect(vaultRequest.method == "PUT")
    #expect(vaultRequest.url.absoluteString == "https://dav.example.com/backups/mobile.mdbx")
    #expect(vaultRequest.headers["Authorization"] == "Basic YWxpY2U6c2VjcmV0")
    #expect(vaultRequest.headers["Content-Type"] == "application/octet-stream")
    #expect(vaultRequest.headers["X-Monica-Backup-SHA256"] == "66598ecd7f81b8ccc3720ae7befedfb296a9caf47e1af3627ed8e0fe9346e4f4")
    #expect(vaultRequest.body == Data("vault-bytes".utf8))
    let sidecarRequest = try #require(transport.requests.dropFirst().first)
    #expect(sidecarRequest.method == "PUT")
    #expect(sidecarRequest.url.absoluteString == "https://dav.example.com/backups/mobile.mdbx.sha256")
    #expect(sidecarRequest.headers["Authorization"] == "Basic YWxpY2U6c2VjcmV0")
    #expect(sidecarRequest.headers["Content-Type"] == "text/plain; charset=utf-8")
    #expect(sidecarRequest.body == Data("66598ecd7f81b8ccc3720ae7befedfb296a9caf47e1af3627ed8e0fe9346e4f4\n".utf8))
    #expect(receipt.remoteURL.absoluteString == "https://dav.example.com/backups/mobile.mdbx")
    #expect(receipt.byteCount == 11)
    #expect(receipt.sha256 == "66598ecd7f81b8ccc3720ae7befedfb296a9caf47e1af3627ed8e0fe9346e4f4")
}

@Test func webDAVClientRejectsUnexpectedSidecarUploadStatus() async throws {
    let transport = RecordingWebDAVTransport(
        responses: [
            WebDAVTransportResponse(statusCode: 201, body: Data()),
            WebDAVTransportResponse(statusCode: 500, body: Data("Server error".utf8))
        ]
    )
    let client = WebDAVClient(
        endpoint: WebDAVEndpoint(
            baseURL: try #require(URL(string: "https://dav.example.com/backups/")),
            username: "alice",
            password: "secret"
        ),
        transport: transport
    )

    await #expect(throws: WebDAVError.unexpectedStatus(operation: "upload checksum", statusCode: 500)) {
        try await client.upload(
            WebDAVBackupPackage(fileName: "mobile.mdbx", data: Data("vault-bytes".utf8))
        )
    }
}

@Test func webDAVClientRejectsUnexpectedUploadStatusWithReadableError() async throws {
    let transport = RecordingWebDAVTransport(
        responses: [
            WebDAVTransportResponse(statusCode: 401, body: Data("Unauthorized".utf8))
        ]
    )
    let client = WebDAVClient(
        endpoint: WebDAVEndpoint(
            baseURL: try #require(URL(string: "https://dav.example.com/backups/")),
            username: "alice",
            password: "wrong"
        ),
        transport: transport
    )

    await #expect(throws: WebDAVError.unexpectedStatus(operation: "upload", statusCode: 401)) {
        try await client.upload(
            WebDAVBackupPackage(fileName: "mobile.mdbx", data: Data("vault-bytes".utf8))
        )
    }
}

@Test func webDAVClientDownloadsBackupAndBuildsRestorePreview() async throws {
    let data = Data("restored-vault".utf8)
    let transport = RecordingWebDAVTransport(
        responses: [
            WebDAVTransportResponse(
                statusCode: 200,
                headers: ["X-Monica-Backup-SHA256": "4792d85ee2580d20b09571d13647f616d487b2bb885e4a61c70480bb7ab032fe"],
                body: data
            )
        ]
    )
    let client = WebDAVClient(
        endpoint: WebDAVEndpoint(
            baseURL: try #require(URL(string: "https://dav.example.com/backups/")),
            username: "alice",
            password: "secret"
        ),
        transport: transport
    )

    let downloaded = try await client.download(fileName: "mobile.mdbx")
    let preview = try WebDAVRestorePreview(downloaded)

    let request = try #require(transport.requests.first)
    #expect(request.method == "GET")
    #expect(request.url.absoluteString == "https://dav.example.com/backups/mobile.mdbx")
    #expect(downloaded.data == data)
    #expect(downloaded.sha256 == "4792d85ee2580d20b09571d13647f616d487b2bb885e4a61c70480bb7ab032fe")
    #expect(preview.fileName == "mobile.mdbx")
    #expect(preview.byteCount == 14)
    #expect(preview.sha256 == "4792d85ee2580d20b09571d13647f616d487b2bb885e4a61c70480bb7ab032fe")
}

@Test func webDAVClientDownloadsSidecarChecksumWhenIntegrityHeaderIsMissing() async throws {
    let data = Data("restored-vault".utf8)
    let transport = RecordingWebDAVTransport(
        responses: [
            WebDAVTransportResponse(statusCode: 200, body: data),
            WebDAVTransportResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/plain"],
                body: Data("4792d85ee2580d20b09571d13647f616d487b2bb885e4a61c70480bb7ab032fe\n".utf8)
            )
        ]
    )
    let client = WebDAVClient(
        endpoint: WebDAVEndpoint(
            baseURL: try #require(URL(string: "https://dav.example.com/backups/")),
            username: "alice",
            password: "secret"
        ),
        transport: transport
    )

    let downloaded = try await client.download(fileName: "mobile.mdbx")

    #expect(transport.requests.map(\.url.absoluteString) == [
        "https://dav.example.com/backups/mobile.mdbx",
        "https://dav.example.com/backups/mobile.mdbx.sha256"
    ])
    #expect(downloaded.data == data)
    #expect(downloaded.sha256 == "4792d85ee2580d20b09571d13647f616d487b2bb885e4a61c70480bb7ab032fe")
}

@Test func webDAVClientRejectsDownloadWhenSidecarChecksumDoesNotMatch() async throws {
    let transport = RecordingWebDAVTransport(
        responses: [
            WebDAVTransportResponse(statusCode: 200, body: Data("restored-vault".utf8)),
            WebDAVTransportResponse(statusCode: 200, body: Data("0000\n".utf8))
        ]
    )
    let client = WebDAVClient(
        endpoint: WebDAVEndpoint(
            baseURL: try #require(URL(string: "https://dav.example.com/backups/")),
            username: "alice",
            password: "secret"
        ),
        transport: transport
    )

    await #expect(throws: WebDAVError.integrityCheckFailed) {
        try await client.download(fileName: "mobile.mdbx")
    }
}

@Test func webDAVClientRejectsDownloadWhenIntegrityHeaderDoesNotMatch() async throws {
    let transport = RecordingWebDAVTransport(
        responses: [
            WebDAVTransportResponse(
                statusCode: 200,
                headers: ["X-Monica-Backup-SHA256": "0000"],
                body: Data("restored-vault".utf8)
            )
        ]
    )
    let client = WebDAVClient(
        endpoint: WebDAVEndpoint(
            baseURL: try #require(URL(string: "https://dav.example.com/backups/")),
            username: "alice",
            password: "secret"
        ),
        transport: transport
    )

    await #expect(throws: WebDAVError.integrityCheckFailed) {
        try await client.download(fileName: "mobile.mdbx")
    }
}

private final class RecordingWebDAVTransport: WebDAVTransport {
    private var responses: [WebDAVTransportResponse]
    private(set) var requests: [WebDAVTransportRequest] = []

    init(responses: [WebDAVTransportResponse]) {
        self.responses = responses
    }

    func send(_ request: WebDAVTransportRequest) async throws -> WebDAVTransportResponse {
        requests.append(request)
        return responses.removeFirst()
    }
}

private final class RecordingBitwardenIdentityTransport: BitwardenIdentityTokenTransport, @unchecked Sendable {
    var result = BitwardenTokenRefreshResult(
        accessToken: "access-token-secret",
        refreshToken: "refresh-token-secret",
        expiresIn: 3600
    )
    private(set) var requests: [BitwardenTokenRefreshRequest] = []

    func refreshAccessToken(_ request: BitwardenTokenRefreshRequest) async throws -> BitwardenTokenRefreshResult {
        requests.append(request)
        return result
    }
}

private final class RecordingBitwardenPasswordAuthenticationTransport: BitwardenPasswordAuthenticationTransport, @unchecked Sendable {
    private(set) var preloginRequests: [BitwardenPreloginHTTPRequest] = []
    private(set) var tokenRequests: [BitwardenTokenHTTPRequest] = []
    private var preloginResponses: [BitwardenPasswordAuthenticationHTTPResponse] = []
    private var tokenResponses: [BitwardenPasswordAuthenticationHTTPResponse] = []

    func enqueuePrelogin(statusCode: Int, body: String) {
        preloginResponses.append(
            BitwardenPasswordAuthenticationHTTPResponse(statusCode: statusCode, body: Data(body.utf8))
        )
    }

    func enqueueToken(statusCode: Int, body: String) {
        tokenResponses.append(
            BitwardenPasswordAuthenticationHTTPResponse(statusCode: statusCode, body: Data(body.utf8))
        )
    }

    func prelogin(_ request: BitwardenPreloginHTTPRequest) async throws -> BitwardenPasswordAuthenticationHTTPResponse {
        preloginRequests.append(request)
        return preloginResponses.removeFirst()
    }

    func token(_ request: BitwardenTokenHTTPRequest) async throws -> BitwardenPasswordAuthenticationHTTPResponse {
        tokenRequests.append(request)
        return tokenResponses.removeFirst()
    }
}

private final class RecordingBitwardenVaultSyncTransport: BitwardenVaultSyncTransport, @unchecked Sendable {
    private(set) var requests: [BitwardenVaultSyncRequest] = []
    private var responses: [BitwardenVaultSyncResponse] = []

    func enqueue(statusCode: Int, body: String, headers: [String: String] = [:]) {
        responses.append(
            BitwardenVaultSyncResponse(
                statusCode: statusCode,
                headers: headers,
                body: Data(body.utf8)
            )
        )
    }

    func send(_ request: BitwardenVaultSyncRequest) async throws -> BitwardenVaultSyncResponse {
        requests.append(request)
        return responses.removeFirst()
    }
}

private func decodedJSONDictionary(_ data: Data?) throws -> [String: Any] {
    let data = try #require(data)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private final class RecordingOneDriveAccessTokenProvider: OneDriveAccessTokenProvider {
    let token: String?

    init(token: String?) {
        self.token = token
    }

    func accessToken() async throws -> String {
        guard let token else {
            throw CloudFileProviderError.authenticationRequired(provider: .oneDrive)
        }
        return token
    }
}

private final class RecordingOneDriveGraphTransport: OneDriveGraphTransport, @unchecked Sendable {
    private(set) var requests: [OneDriveGraphRequest] = []
    private var responses: [OneDriveGraphResponse] = []

    func enqueue(statusCode: Int, body: String, headers: [String: String] = [:]) {
        enqueue(statusCode: statusCode, bodyData: Data(body.utf8), headers: headers)
    }

    func enqueue(statusCode: Int, bodyData: Data, headers: [String: String] = [:]) {
        responses.append(
            OneDriveGraphResponse(
                statusCode: statusCode,
                headers: headers,
                body: bodyData
            )
        )
    }

    func send(_ request: OneDriveGraphRequest) async throws -> OneDriveGraphResponse {
        requests.append(request)
        return responses.removeFirst()
    }
}
