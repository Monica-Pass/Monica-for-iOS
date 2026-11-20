import Testing
import MonicaSync
import Foundation

private final class BackupDirectoryTestTokenProvider: OneDriveAccessTokenProvider {
    let token: String

    init(token: String = "onedrive-access-token-secret") {
        self.token = token
    }

    func accessToken() async throws -> String {
        token
    }
}

private final class BackupDirectoryTestTransport: OneDriveGraphTransport, @unchecked Sendable {
    private(set) var requests: [OneDriveGraphRequest] = []
    private var responses: [OneDriveGraphResponse] = []

    func enqueue(statusCode: Int, body: String, headers: [String: String] = [:]) {
        responses.append(
            OneDriveGraphResponse(
                statusCode: statusCode,
                headers: headers,
                body: Data(body.utf8)
            )
        )
    }

    func send(_ request: OneDriveGraphRequest) async throws -> OneDriveGraphResponse {
        requests.append(request)
        return responses.removeFirst()
    }
}

private func makeProvider(
    transport: BackupDirectoryTestTransport,
    simpleUploadLimitBytes: Int = 4 * 1024 * 1024
) -> OneDriveCloudFileProvider {
    OneDriveCloudFileProvider(
        configuration: OneDriveCloudFileConfiguration(
            clientID: "test-client-id",
            redirectURI: URL(string: "msauth.com.monicapass.monica://auth")!,
            simpleUploadLimitBytes: simpleUploadLimitBytes,
            uploadChunkSizeBytes: 320 * 1024,
            uploadRetryLimit: 2,
            uploadRetryDelay: 0
        ),
        tokenProvider: BackupDirectoryTestTokenProvider(),
        graphTransport: transport
    )
}

private func folderJSON(id: String, name: String, parentPath: String = "/drive/special/approot:") -> String {
    """
    {
      "id": "\(id)",
      "name": "\(name)",
      "size": 0,
      "folder": {},
      "parentReference": { "path": "\(parentPath)" }
    }
    """
}

private func fileJSON(
    id: String,
    name: String,
    size: Int = 24,
    parentPath: String = "/drive/special/approot:",
    etag: String = "etag-secret"
) -> String {
    """
    {
      "id": "\(id)",
      "name": "\(name)",
      "size": \(size),
      "eTag": "\\"\(etag)\\"",
      "file": {},
      "parentReference": { "path": "\(parentPath)" }
    }
    """
}

@Test func oneDriveBackupDirectoryListsRootAndFollowsNextLink() async throws {
    let transport = BackupDirectoryTestTransport()
    let provider = makeProvider(transport: transport)
    transport.enqueue(
        statusCode: 200,
        body: """
        {
          "value": [
            \(folderJSON(id: "folder-backups", name: "Backups")),
            \(fileJSON(id: "file-root", name: "Monica.kdbx"))
          ],
          "@odata.nextLink": "https://graph.microsoft.com/v1.0/me/drive/special/approot/children?$skiptoken=page-two"
        }
        """
    )
    transport.enqueue(
        statusCode: 200,
        body: """
        {
          "value": [
            \(folderJSON(id: "folder-archive", name: "Archive"))
          ]
        }
        """
    )

    let listing = try await provider.listBackupDirectory(id: nil)

    #expect(listing.directory == nil)
    #expect(listing.directories.map(\.name) == ["Backups", "Archive"])
    #expect(listing.directories.map(\.displayPath) == ["Backups", "Archive"])
    #expect(listing.files.map(\.name) == ["Monica.kdbx"])
    #expect(transport.requests.map(\.method) == ["GET", "GET"])
    #expect(transport.requests[0].url.absoluteString == "https://graph.microsoft.com/v1.0/me/drive/special/approot/children")
    #expect(transport.requests[1].url.absoluteString == "https://graph.microsoft.com/v1.0/me/drive/special/approot/children?$skiptoken=page-two")
    #expect(transport.requests.allSatisfy { $0.headers["Authorization"] == "Bearer onedrive-access-token-secret" })
}

@Test func oneDriveBackupDirectoryRejectsNextLinkOnAnotherHost() async throws {
    let transport = BackupDirectoryTestTransport()
    let provider = makeProvider(transport: transport)
    transport.enqueue(
        statusCode: 200,
        body: """
        {
          "value": [],
          "@odata.nextLink": "https://attacker.example.com/steal-token"
        }
        """
    )

    await #expect(throws: CloudFileProviderError.unsupportedOperation(provider: .oneDrive)) {
        _ = try await provider.listBackupDirectory(id: nil)
    }
    #expect(transport.requests.count == 1)
}

@Test func oneDriveBackupDirectoryLoadsSelectedFolderAndNestedDirectories() async throws {
    let transport = BackupDirectoryTestTransport()
    let provider = makeProvider(transport: transport)
    transport.enqueue(
        statusCode: 200,
        body: folderJSON(id: "folder-backups", name: "Backups")
    )
    transport.enqueue(
        statusCode: 200,
        body: """
        {
          "value": [
            \(folderJSON(id: "folder-2026", name: "2026", parentPath: "/drive/special/approot:/Backups")),
            \(fileJSON(id: "file-backup", name: "monica-onedrive.mdbx", parentPath: "/drive/special/approot:/Backups"))
          ]
        }
        """
    )

    let listing = try await provider.listBackupDirectory(id: "folder-backups")

    #expect(listing.directory?.id == "folder-backups")
    #expect(listing.directory?.displayPath == "Backups")
    #expect(listing.directories.map(\.displayPath) == ["Backups/2026"])
    #expect(listing.files.map(\.name) == ["monica-onedrive.mdbx"])
    #expect(transport.requests.map(\.method) == ["GET", "GET"])
    #expect(transport.requests[0].url.absoluteString == "https://graph.microsoft.com/v1.0/me/drive/items/folder-backups")
    #expect(transport.requests[1].url.absoluteString == "https://graph.microsoft.com/v1.0/me/drive/items/folder-backups/children")
}

@Test func oneDriveBackupDirectoryRejectsFilesAsDirectories() async throws {
    let transport = BackupDirectoryTestTransport()
    let provider = makeProvider(transport: transport)
    transport.enqueue(
        statusCode: 200,
        body: fileJSON(id: "file-not-folder", name: "monica-onedrive.mdbx")
    )

    await #expect(throws: CloudFileProviderError.itemNotFound(provider: .oneDrive)) {
        _ = try await provider.listBackupDirectory(id: "file-not-folder")
    }
}

@Test func oneDriveCreateBackupDirectoryPostsFolderWithoutConflictBehaviorOverwrite() async throws {
    let transport = BackupDirectoryTestTransport()
    let provider = makeProvider(transport: transport)
    transport.enqueue(
        statusCode: 201,
        body: folderJSON(id: "new-folder-id", name: "Backups 2026")
    )

    let directory = try await provider.createBackupDirectory(named: "  Backups 2026  ", parentID: nil)

    #expect(directory.id == "new-folder-id")
    #expect(directory.name == "Backups 2026")
    #expect(directory.displayPath == "Backups 2026")
    #expect(transport.requests.count == 1)
    #expect(transport.requests[0].method == "POST")
    #expect(transport.requests[0].url.absoluteString == "https://graph.microsoft.com/v1.0/me/drive/special/approot/children")
    let body = try #require(transport.requests[0].body)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["name"] as? String == "Backups 2026")
    #expect(json["folder"] != nil)
    #expect(json["@microsoft.graph.conflictBehavior"] as? String == "fail")
}

@Test func oneDriveCreateBackupDirectoryMapsConflictAndValidatesNames() async throws {
    let transport = BackupDirectoryTestTransport()
    let provider = makeProvider(transport: transport)

    for invalidName in ["", "   ", ".", "..", "a/b", "a:b", "a*", "backup."] {
        await #expect(throws: CloudFileProviderError.invalidDirectoryName(provider: .oneDrive)) {
            _ = try await provider.createBackupDirectory(named: invalidName, parentID: nil)
        }
    }
    #expect(transport.requests.isEmpty)

    transport.enqueue(statusCode: 409, body: "{}")
    await #expect(throws: CloudFileProviderError.conflict(provider: .oneDrive)) {
        _ = try await provider.createBackupDirectory(named: "Backups", parentID: nil)
    }
}

@Test func oneDriveTimestampedBackupNamesRoundTripAndPruneOldest() throws {
    let baseName = "monica-onedrive.mdbx"
    let firstDate = try #require(ISO8601DateFormatter().date(from: "2026-01-01T01:02:03Z"))
    let secondDate = try #require(ISO8601DateFormatter().date(from: "2026-01-02T01:02:03Z"))
    let thirdDate = try #require(ISO8601DateFormatter().date(from: "2026-01-03T01:02:03Z"))

    let first = CloudFileBackupFileNameFormatter.timestampedFileName(baseName: baseName, date: firstDate)
    let second = CloudFileBackupFileNameFormatter.timestampedFileName(baseName: baseName, date: secondDate)
    let third = CloudFileBackupFileNameFormatter.timestampedFileName(baseName: baseName, date: thirdDate)

    #expect(first == "monica-onedrive-20260101-010203.mdbx")
    #expect(second == "monica-onedrive-20260102-010203.mdbx")
    #expect(CloudFileBackupFileNameFormatter.timestamp(fromTimestampedFileName: second, baseName: baseName) == secondDate)
    #expect(CloudFileBackupFileNameFormatter.timestamp(fromTimestampedFileName: baseName, baseName: baseName) == nil)
    #expect(CloudFileBackupFileNameFormatter.timestamp(fromTimestampedFileName: "other-20260101-010203.mdbx", baseName: baseName) == nil)

    let files = [first, second, third].enumerated().map { index, name in
        CloudFileItem(id: "id-\(index)", name: name, path: name, byteCount: 10)
    } + [
        CloudFileItem(id: "id-static", name: baseName, path: baseName, byteCount: 10)
    ]

    let pruned = CloudFileBackupRetention.filesToPrune(from: files, baseName: baseName, retainedVersions: 2)
    #expect(pruned.map(\.name) == [first])
    let retained = CloudFileBackupRetention.retainedFiles(from: files, baseName: baseName, retainedVersions: 2)
    #expect(Set(retained.map(\.name)) == Set([second, third, baseName]))
}

@Test func oneDriveUploadsIntoSelectedDirectoryWithConflictProtection() async throws {
    let transport = BackupDirectoryTestTransport()
    let provider = makeProvider(transport: transport)
    transport.enqueue(
        statusCode: 201,
        body: fileJSON(id: "uploaded-in-folder", name: "monica-onedrive.mdbx", parentPath: "/drive/special/approot:/Backups")
    )

    let receipt = try await provider.uploadFile(
        named: "monica-onedrive.mdbx",
        data: Data("vault-bytes".utf8),
        inDirectory: "folder-backups",
        conflictBehavior: .fail
    )

    #expect(receipt.itemID == "uploaded-in-folder")
    #expect(transport.requests.count == 1)
    #expect(transport.requests[0].method == "PUT")
    #expect(transport.requests[0].url.absoluteString == "https://graph.microsoft.com/v1.0/me/drive/items/folder-backups:/monica-onedrive.mdbx:/content")
    #expect(transport.requests[0].headers["If-None-Match"] == "*")
    #expect(transport.requests[0].headers["Authorization"] == "Bearer onedrive-access-token-secret")

    transport.enqueue(statusCode: 409, body: "{}")
    await #expect(throws: CloudFileProviderError.conflict(provider: .oneDrive)) {
        _ = try await provider.uploadFile(
            named: "monica-onedrive.mdbx",
            data: Data("vault-bytes".utf8),
            inDirectory: "folder-backups",
            conflictBehavior: .fail
        )
    }
}

@Test func oneDriveLargeUploadUsesAnUnauthenticatedChunkedSession() async throws {
    let transport = BackupDirectoryTestTransport()
    let provider = makeProvider(transport: transport, simpleUploadLimitBytes: 10)
    let data = Data(repeating: 7, count: 700 * 1024)
    transport.enqueue(
        statusCode: 200,
        body: """
        { "uploadUrl": "https://upload.example.com/session-token-secret" }
        """
    )
    transport.enqueue(statusCode: 202, body: "{}")
    transport.enqueue(statusCode: 202, body: "{}")
    transport.enqueue(
        statusCode: 201,
        body: fileJSON(id: "large-upload-id", name: "monica-onedrive.mdbx", size: data.count)
    )

    let receipt = try await provider.uploadFile(
        named: "monica-onedrive.mdbx",
        data: data,
        inDirectory: nil,
        conflictBehavior: .fail
    )

    #expect(receipt.itemID == "large-upload-id")
    #expect(transport.requests.map(\.method) == ["POST", "PUT", "PUT", "PUT"])
    #expect(transport.requests[0].url.absoluteString == "https://graph.microsoft.com/v1.0/me/drive/special/approot:/monica-onedrive.mdbx:/createUploadSession")
    #expect(transport.requests[0].headers["Authorization"] == "Bearer onedrive-access-token-secret")
    #expect(transport.requests[0].headers["Content-Type"] == "application/json")

    let uploadRequests = Array(transport.requests.dropFirst())
    #expect(uploadRequests.allSatisfy { $0.url.absoluteString == "https://upload.example.com/session-token-secret" })
    #expect(uploadRequests.allSatisfy { $0.headers["Authorization"] == nil })
    #expect(uploadRequests.map { $0.headers["Content-Range"] } == [
        "bytes 0-327679/716800",
        "bytes 327680-655359/716800",
        "bytes 655360-716799/716800"
    ])
    #expect(uploadRequests.map { $0.headers["Content-Length"] } == ["327680", "327680", "61440"])
    #expect(uploadRequests.allSatisfy { $0.body?.count == Int($0.headers["Content-Length"] ?? "") })
}

@Test func oneDriveLargeUploadRetriesRetryableChunkResponses() async throws {
    let transport = BackupDirectoryTestTransport()
    let provider = makeProvider(transport: transport, simpleUploadLimitBytes: 10)
    let data = Data(repeating: 3, count: 400 * 1024)
    transport.enqueue(
        statusCode: 200,
        body: """
        { "uploadUrl": "https://upload.example.com/session" }
        """
    )
    transport.enqueue(statusCode: 503, body: "{}")
    transport.enqueue(statusCode: 202, body: "{}")
    transport.enqueue(
        statusCode: 201,
        body: fileJSON(id: "retried-upload-id", name: "monica-onedrive.mdbx", size: data.count)
    )

    _ = try await provider.uploadFile(
        named: "monica-onedrive.mdbx",
        data: data,
        inDirectory: nil,
        conflictBehavior: .fail
    )

    #expect(transport.requests.map(\.method) == ["POST", "PUT", "PUT", "PUT"])
    #expect(transport.requests[1].headers["Content-Range"] == "bytes 0-327679/409600")
    #expect(transport.requests[2].headers["Content-Range"] == "bytes 0-327679/409600")
    #expect(transport.requests[3].headers["Content-Range"] == "bytes 327680-409599/409600")
}

@Test func oneDriveLargeUploadMapsSessionConflictsToConflict() async throws {
    let transport = BackupDirectoryTestTransport()
    let provider = makeProvider(transport: transport, simpleUploadLimitBytes: 10)
    transport.enqueue(statusCode: 409, body: "{}")

    await #expect(throws: CloudFileProviderError.conflict(provider: .oneDrive)) {
        _ = try await provider.uploadFile(
            named: "monica-onedrive.mdbx",
            data: Data(repeating: 1, count: 11),
            inDirectory: nil,
            conflictBehavior: .fail
        )
    }
    #expect(transport.requests.count == 1)
}

@Test func oneDriveLargeOverwriteSendsRevisionOnUploadSession() async throws {
    let transport = BackupDirectoryTestTransport()
    let provider = makeProvider(transport: transport, simpleUploadLimitBytes: 10)
    transport.enqueue(
        statusCode: 200,
        body: """
        { "uploadUrl": "https://upload.example.com/session" }
        """
    )
    transport.enqueue(
        statusCode: 201,
        body: fileJSON(id: "existing-item-id", name: "monica-onedrive.mdbx", size: 11)
    )

    _ = try await provider.overwriteFile(
        id: "existing-item-id",
        data: Data(repeating: 1, count: 11),
        fileName: "monica-onedrive.mdbx",
        expectedRevision: "\"stale-etag\""
    )

    #expect(transport.requests.count == 2)
    #expect(transport.requests[0].url.absoluteString == "https://graph.microsoft.com/v1.0/me/drive/items/existing-item-id/createUploadSession")
    #expect(transport.requests[0].headers["If-Match"] == "\"stale-etag\"")
    let body = try #require(transport.requests[0].body)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    let item = try #require(json["item"] as? [String: Any])
    #expect(item["@microsoft.graph.conflictBehavior"] as? String == "replace")
}

@Test func oneDriveLargeUploadRejectsNonHTTPSUploadURL() async throws {
    let transport = BackupDirectoryTestTransport()
    let provider = makeProvider(transport: transport, simpleUploadLimitBytes: 10)
    transport.enqueue(
        statusCode: 200,
        body: """
        { "uploadUrl": "http://upload.example.com/plain-text-session" }
        """
    )

    await #expect(throws: CloudFileProviderError.unsupportedOperation(provider: .oneDrive)) {
        _ = try await provider.uploadFile(
            named: "monica-onedrive.mdbx",
            data: Data(repeating: 1, count: 11),
            inDirectory: nil,
            conflictBehavior: .fail
        )
    }
}
