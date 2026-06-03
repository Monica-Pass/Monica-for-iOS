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
