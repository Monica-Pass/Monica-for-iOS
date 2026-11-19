import Foundation
import Testing
@testable import MonicaSync

// MARK: - Fixtures

private let adapterTestEndpoint = WebDAVEndpoint(
    baseURL: URL(string: "https://dav.example.com/vaults/")!,
    username: "monica",
    password: "secret"
)
private let adapterTestVaultFileName = "monica-vault.mdbx"
private let adapterTestManifestFileName = "monica-vault.mdbx.monica-cloud.json"
private let adapterTestReferenceDate = Date(timeIntervalSince1970: 1_700_000_000)

private func adapterTestBasicAuthorization() -> String {
    "Basic " + Data("monica:secret".utf8).base64EncodedString()
}

private func adapterTestVaultData() -> Data {
    Data("monica-vault-ciphertext".utf8)
}

private func adapterTestManifest(
    for data: Data,
    revision: Int = 3,
    vaultID: String = "vault-1"
) -> CloudVaultManifest {
    CloudVaultManifest(
        vaultID: vaultID,
        vaultName: "Monica",
        revision: revision,
        contentSHA256: LanSyncEncoding.hex(LanSyncEncoding.sha256(data)),
        byteCount: data.count,
        updatedAt: adapterTestReferenceDate,
        updatedByDeviceID: "device-1",
        updatedByDeviceName: "Test Device"
    )
}

private func adapterTestRemote(
    kind: CloudVaultRemoteKind = .webDAV,
    manifest: CloudVaultManifest,
    itemID: String? = nil,
    revision: String? = nil,
    manifestRevision: String? = nil
) -> CloudVaultRemoteFile {
    CloudVaultRemoteFile(
        kind: kind,
        remotePath: adapterTestVaultFileName,
        fileName: adapterTestVaultFileName,
        manifestFileName: adapterTestManifestFileName,
        itemID: itemID,
        revision: revision,
        manifestRevision: manifestRevision,
        manifest: manifest
    )
}

private func adapterTestWebDAVStore(
    transport: FakeWebDAVTransport,
    vaultFileName: String = adapterTestVaultFileName
) -> WebDAVCloudVaultRemoteStore {
    WebDAVCloudVaultRemoteStore(
        endpoint: adapterTestEndpoint,
        vaultFileName: vaultFileName,
        transport: transport
    )
}

private func adapterTestCloudFileStore(
    provider: FakeCloudFileProvider,
    vaultFileName: String = adapterTestVaultFileName
) -> CloudFileCloudVaultRemoteStore {
    CloudFileCloudVaultRemoteStore(provider: provider, vaultFileName: vaultFileName)
}

/// Runs `operation` and returns the `CloudVaultError` it threw, recording an issue
/// for anything else (including "no error thrown").
private func captureCloudVaultError(
    _ operation: () async throws -> Void
) async -> CloudVaultError? {
    do {
        try await operation()
        return nil
    } catch let error as CloudVaultError {
        return error
    } catch {
        Issue.record("unexpected error type: \(error)")
        return nil
    }
}

private func isManifestInvalid(_ error: CloudVaultError?) -> Bool {
    if case .manifestInvalid = error { return true }
    return false
}

private func isUnsupportedProvider(_ error: CloudVaultError?) -> Bool {
    if case .unsupportedProvider = error { return true }
    return false
}

// MARK: - Fake WebDAV transport

private final class FakeWebDAVTransport: WebDAVTransport, @unchecked Sendable {
    struct RecordedRequest: Sendable, Equatable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data?
    }

    typealias Handler = @Sendable (RecordedRequest) throws -> WebDAVTransportResponse

    private let lock = NSLock()
    private var recordedRequests: [RecordedRequest] = []
    private var handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var requests: [RecordedRequest] {
        withLockedState { recordedRequests }
    }

    func setHandler(_ handler: @escaping Handler) {
        withLockedState { self.handler = handler }
    }

    func send(_ request: WebDAVTransportRequest) async throws -> WebDAVTransportResponse {
        let recorded = RecordedRequest(
            method: request.method,
            url: request.url,
            headers: request.headers,
            body: request.body
        )
        // NSLock may only be used from a synchronous context, so the locked
        // section lives in this helper rather than directly in `send`.
        let handler: Handler = withLockedState {
            recordedRequests.append(recorded)
            return self.handler
        }
        return try handler(recorded)
    }

    private func withLockedState<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

// MARK: - Fake CloudFileProvider

private final class FakeCloudFileProvider: CloudFileProvider, @unchecked Sendable {
    enum Call: Sendable, Equatable {
        case listFiles
        case downloadFile(id: String)
        case uploadFile(name: String, byteCount: Int)
        case overwriteFile(id: String, name: String, expectedRevision: String?)
    }

    private struct StoredFile {
        let id: String
        var data: Data
        var revision: String
    }

    let kind: CloudFileProviderKind

    private let lock = NSLock()
    private var filesByName: [String: StoredFile] = [:]
    private var recordedCalls: [Call] = []
    private var nextFileNumber = 1
    private var revisionCounter = 0

    init(kind: CloudFileProviderKind = .oneDrive) {
        self.kind = kind
    }

    // MARK: Test helpers

    var calls: [Call] {
        withLockedState { recordedCalls }
    }

    var uploadCalls: [Call] {
        calls.filter { call in
            if case .uploadFile = call { return true }
            return false
        }
    }

    var overwriteCalls: [Call] {
        calls.filter { call in
            if case .overwriteFile = call { return true }
            return false
        }
    }

    var fileNames: [String] {
        withLockedState { filesByName.keys.sorted() }
    }

    func data(named name: String) -> Data? {
        withLockedState { filesByName[name]?.data }
    }

    func revision(named name: String) -> String? {
        withLockedState { filesByName[name]?.revision }
    }

    func itemID(named name: String) -> String? {
        withLockedState { filesByName[name]?.id }
    }

    @discardableResult
    func seedFile(named name: String, data: Data, revision: String? = nil) -> String {
        withLockedState {
            let id = filesByName[name]?.id ?? nextFileIDLocked()
            let resolvedRevision = revision ?? nextRevisionLocked()
            filesByName[name] = StoredFile(id: id, data: data, revision: resolvedRevision)
            return id
        }
    }

    // MARK: CloudFileProvider

    func connectionState() async throws -> CloudFileConnectionState {
        .connected(accountLabel: "Fake \(kind.displayName)")
    }

    func listFiles() async throws -> [CloudFileItem] {
        withLockedState {
            recordedCalls.append(.listFiles)
            return filesByName.map { name, stored in
                CloudFileItem(
                    id: stored.id,
                    name: name,
                    path: name,
                    byteCount: stored.data.count,
                    revision: stored.revision
                )
            }
            .sorted { $0.name < $1.name }
        }
    }

    func downloadFile(id: String) async throws -> CloudFileDownload {
        let match: (key: String, value: StoredFile)? = withLockedState {
            recordedCalls.append(.downloadFile(id: id))
            return filesByName.first { $0.value.id == id }
        }
        guard let match else {
            throw CloudFileProviderError.itemNotFound(provider: kind)
        }
        let item = CloudFileItem(
            id: match.value.id,
            name: match.key,
            path: match.key,
            byteCount: match.value.data.count,
            revision: match.value.revision
        )
        return CloudFileDownload(item: item, data: match.value.data, revision: match.value.revision)
    }

    func uploadFile(named fileName: String, data: Data) async throws -> CloudFileWriteReceipt {
        let stored: StoredFile = withLockedState {
            recordedCalls.append(.uploadFile(name: fileName, byteCount: data.count))
            let revision = nextRevisionLocked()
            let id = filesByName[fileName]?.id ?? nextFileIDLocked()
            let file = StoredFile(id: id, data: data, revision: revision)
            filesByName[fileName] = file
            return file
        }
        return CloudFileWriteReceipt(
            provider: kind,
            itemID: stored.id,
            name: fileName,
            byteCount: data.count,
            sha256: LanSyncEncoding.hex(LanSyncEncoding.sha256(data)),
            revision: stored.revision
        )
    }

    func overwriteFile(
        id: String,
        data: Data,
        fileName: String,
        expectedRevision: String?
    ) async throws -> CloudFileWriteReceipt {
        let outcome: Result<StoredFile, CloudFileProviderError> = withLockedState {
            recordedCalls.append(
                .overwriteFile(id: id, name: fileName, expectedRevision: expectedRevision)
            )
            guard let current = filesByName.first(where: { $0.value.id == id }) else {
                return .failure(.itemNotFound(provider: kind))
            }
            if let expectedRevision, expectedRevision != current.value.revision {
                return .failure(.conflict(provider: kind))
            }
            let revision = nextRevisionLocked()
            let file = StoredFile(id: id, data: data, revision: revision)
            filesByName[current.key] = file
            return .success(file)
        }
        let stored = try outcome.get()
        return CloudFileWriteReceipt(
            provider: kind,
            itemID: stored.id,
            name: fileName,
            byteCount: data.count,
            sha256: LanSyncEncoding.hex(LanSyncEncoding.sha256(data)),
            revision: stored.revision
        )
    }

    func deleteFile(id: String) async throws -> CloudFileDeleteReceipt {
        throw CloudFileProviderError.unsupportedOperation(provider: kind)
    }

    func renameFile(id: String, newName: String) async throws -> CloudFileWriteReceipt {
        throw CloudFileProviderError.unsupportedOperation(provider: kind)
    }

    /// NSLock may only be used from synchronous contexts, so every locked
    /// critical section goes through this helper.
    private func withLockedState<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func nextFileIDLocked() -> String {
        defer { nextFileNumber += 1 }
        return "file-\(nextFileNumber)"
    }

    private func nextRevisionLocked() -> String {
        revisionCounter += 1
        return "rev-\(revisionCounter)"
    }
}

// MARK: - WebDAV adapter

@Suite("CloudVaultAdapterTests")
struct CloudVaultAdapterTests {

    // MARK: readRemote

    @Test func webDAVReadRemoteReturnsNilWhenManifestIsMissing() async throws {
        let transport = FakeWebDAVTransport { _ in
            WebDAVTransportResponse(statusCode: 404, body: Data("missing".utf8))
        }
        let store = adapterTestWebDAVStore(transport: transport)

        let remote = try await store.readRemote()

        #expect(remote == nil)
        #expect(store.kind == .webDAV)
        #expect(store.displayName == "WebDAV 备份目录")
        #expect(store.remotePath == adapterTestVaultFileName)
        #expect(transport.requests.map { $0.method } == ["GET"])
        #expect(transport.requests.first?.url.lastPathComponent == adapterTestManifestFileName)
        #expect(transport.requests.first?.headers["Authorization"] == adapterTestBasicAuthorization())
    }

    @Test func webDAVReadRemoteDecodesManifestAndExposesETagsVerbatim() async throws {
        let vaultData = adapterTestVaultData()
        let manifest = adapterTestManifest(for: vaultData, revision: 4)
        let manifestData = try manifest.encodedData()
        let vaultETag = "\"vault-etag-42\""
        let manifestETag = "\"manifest-etag-42\""

        let transport = FakeWebDAVTransport { request in
            if request.method == "HEAD" {
                return WebDAVTransportResponse(
                    statusCode: 200,
                    headers: ["ETag": vaultETag, "Content-Length": "\(vaultData.count)"],
                    body: Data()
                )
            }
            return WebDAVTransportResponse(
                statusCode: 200,
                headers: ["ETag": manifestETag],
                body: manifestData
            )
        }
        let store = adapterTestWebDAVStore(transport: transport)

        let maybeRemote = try await store.readRemote()
        let remote = try #require(maybeRemote)

        #expect(remote.manifest == manifest)
        #expect(remote.revision == vaultETag)
        #expect(remote.manifestRevision == manifestETag)
        #expect(remote.kind == .webDAV)
        #expect(remote.remotePath == adapterTestVaultFileName)
        #expect(remote.fileName == adapterTestVaultFileName)
        #expect(remote.manifestFileName == adapterTestManifestFileName)
        #expect(remote.itemID == nil)
        #expect(remote.byteCount == vaultData.count)
        #expect(transport.requests.map { $0.method } == ["GET", "HEAD"])
        #expect(transport.requests.allSatisfy { $0.headers["Authorization"] == adapterTestBasicAuthorization() })
        #expect(transport.requests.last?.url.lastPathComponent == adapterTestVaultFileName)
    }

    @Test func webDAVReadRemoteMapsMissingVaultFileToRemoteVaultMissing() async throws {
        let vaultData = adapterTestVaultData()
        let manifestData = try adapterTestManifest(for: vaultData).encodedData()
        let transport = FakeWebDAVTransport { request in
            if request.method == "HEAD" {
                return WebDAVTransportResponse(statusCode: 404, body: Data())
            }
            return WebDAVTransportResponse(statusCode: 200, body: manifestData)
        }
        let store = adapterTestWebDAVStore(transport: transport)

        let error = await captureCloudVaultError {
            _ = try await store.readRemote()
        }

        #expect(error == .remoteVaultMissing)
        #expect(transport.requests.map { $0.method } == ["GET", "HEAD"])
    }

    @Test func webDAVReadRemoteRejectsContentLengthMismatch() async throws {
        let vaultData = adapterTestVaultData()
        let manifestData = try adapterTestManifest(for: vaultData).encodedData()
        let transport = FakeWebDAVTransport { request in
            if request.method == "HEAD" {
                return WebDAVTransportResponse(
                    statusCode: 200,
                    headers: ["Content-Length": "\(vaultData.count + 5)"],
                    body: Data()
                )
            }
            return WebDAVTransportResponse(statusCode: 200, body: manifestData)
        }
        let store = adapterTestWebDAVStore(transport: transport)

        let error = await captureCloudVaultError {
            _ = try await store.readRemote()
        }

        #expect(isManifestInvalid(error))
    }

    // MARK: downloadVault

    @Test func webDAVDownloadVaultReturnsVerifiedBytes() async throws {
        let vaultData = adapterTestVaultData()
        let manifest = adapterTestManifest(for: vaultData)
        let remote = adapterTestRemote(manifest: manifest, revision: "\"vault-etag\"")
        let transport = FakeWebDAVTransport { _ in
            WebDAVTransportResponse(statusCode: 200, headers: [:], body: vaultData)
        }
        let store = adapterTestWebDAVStore(transport: transport)

        let downloaded = try await store.downloadVault(remote)

        #expect(downloaded == vaultData)
        #expect(transport.requests.map { $0.method } == ["GET"])
        #expect(transport.requests.first?.url.lastPathComponent == adapterTestVaultFileName)
        #expect(transport.requests.first?.headers["Authorization"] == adapterTestBasicAuthorization())
    }

    @Test func webDAVDownloadVaultRejectsTamperedBody() async throws {
        let vaultData = adapterTestVaultData()
        let manifest = adapterTestManifest(for: vaultData)
        let remote = adapterTestRemote(manifest: manifest)

        var tamperedBytes = vaultData
        tamperedBytes[tamperedBytes.startIndex] ^= 0x01
        let tamperedBody = tamperedBytes
        #expect(tamperedBody.count == vaultData.count)
        #expect(tamperedBody != vaultData)

        let transport = FakeWebDAVTransport { _ in
            WebDAVTransportResponse(statusCode: 200, headers: [:], body: tamperedBody)
        }
        let store = adapterTestWebDAVStore(transport: transport)

        let error = await captureCloudVaultError {
            _ = try await store.downloadVault(remote)
        }

        #expect(
            error == .integrityMismatch(
                expectedSHA256: manifest.contentSHA256,
                actualSHA256: LanSyncEncoding.hex(LanSyncEncoding.sha256(tamperedBody))
            )
        )
    }

    // MARK: createRemote

    @Test func webDAVCreateRemoteSendsIfNoneMatchOnBothWritesInOrder() async throws {
        let vaultData = adapterTestVaultData()
        let manifest = adapterTestManifest(for: vaultData, revision: 1)
        let vaultETag = "\"vault-created\""
        let manifestETag = "\"manifest-created\""

        let transport = FakeWebDAVTransport { request in
            if request.url.lastPathComponent == adapterTestManifestFileName {
                return WebDAVTransportResponse(
                    statusCode: 201,
                    headers: ["ETag": manifestETag],
                    body: Data()
                )
            }
            return WebDAVTransportResponse(
                statusCode: 201,
                headers: ["ETag": vaultETag],
                body: Data()
            )
        }
        let store = adapterTestWebDAVStore(transport: transport)

        let receipt = try await store.createRemote(vaultData: vaultData, manifest: manifest)

        try #require(transport.requests.count == 2)
        let vaultRequest = transport.requests[0]
        let manifestRequest = transport.requests[1]

        #expect(vaultRequest.method == "PUT")
        #expect(vaultRequest.url.lastPathComponent == adapterTestVaultFileName)
        #expect(vaultRequest.headers["If-None-Match"] == "*")
        #expect(vaultRequest.headers["Content-Type"] == "application/octet-stream")
        #expect(vaultRequest.body == vaultData)

        #expect(manifestRequest.method == "PUT")
        #expect(manifestRequest.url.lastPathComponent == adapterTestManifestFileName)
        #expect(manifestRequest.headers["If-None-Match"] == "*")
        #expect(manifestRequest.headers["Content-Type"] == "application/json")
        let uploadedManifestData = try #require(manifestRequest.body)
        let uploadedManifest = try CloudVaultManifest.decode(uploadedManifestData)
        #expect(uploadedManifest == manifest)

        #expect(transport.requests.allSatisfy { $0.headers["Authorization"] == adapterTestBasicAuthorization() })

        #expect(receipt.kind == .webDAV)
        #expect(receipt.fileName == adapterTestVaultFileName)
        #expect(receipt.manifestFileName == adapterTestManifestFileName)
        #expect(receipt.remotePath == adapterTestVaultFileName)
        #expect(receipt.revision == vaultETag)
        #expect(receipt.manifestRevision == manifestETag)
        #expect(receipt.itemID == nil)
        #expect(receipt.manifest == manifest)
    }

    @Test func webDAVCreateRemoteMapsPreexistingVaultToPreconditionFailed() async throws {
        let vaultData = adapterTestVaultData()
        let manifest = adapterTestManifest(for: vaultData, revision: 1)
        let transport = FakeWebDAVTransport { _ in
            WebDAVTransportResponse(
                statusCode: 412,
                headers: ["ETag": "\"already-there\""],
                body: Data()
            )
        }
        let store = adapterTestWebDAVStore(transport: transport)

        let error = await captureCloudVaultError {
            _ = try await store.createRemote(vaultData: vaultData, manifest: manifest)
        }

        #expect(error == .preconditionFailed(remoteRevision: "\"already-there\""))
        // The manifest must not be written when the vault PUT lost the race.
        try #require(transport.requests.count == 1)
        #expect(transport.requests.first?.url.lastPathComponent == adapterTestVaultFileName)
    }

    // MARK: updateRemote

    @Test func webDAVUpdateRemoteSendsIfMatchAndWritesManifestLast() async throws {
        let oldVaultData = adapterTestVaultData()
        let newVaultData = Data("monica-vault-ciphertext-v2".utf8)
        let oldManifest = adapterTestManifest(for: oldVaultData, revision: 3)
        let newManifest = adapterTestManifest(for: newVaultData, revision: 4)
        let remote = adapterTestRemote(
            manifest: oldManifest,
            revision: "\"vault-etag-3\"",
            manifestRevision: "\"manifest-etag-3\""
        )
        let transport = FakeWebDAVTransport { request in
            if request.url.lastPathComponent == adapterTestManifestFileName {
                return WebDAVTransportResponse(
                    statusCode: 204,
                    headers: ["ETag": "\"manifest-etag-4\""],
                    body: Data()
                )
            }
            return WebDAVTransportResponse(
                statusCode: 200,
                headers: ["ETag": "\"vault-etag-4\""],
                body: Data()
            )
        }
        let store = adapterTestWebDAVStore(transport: transport)

        let receipt = try await store.updateRemote(
            vaultData: newVaultData,
            manifest: newManifest,
            remote: remote
        )

        try #require(transport.requests.count == 2)
        let vaultRequest = transport.requests[0]
        let manifestRequest = transport.requests[1]

        #expect(vaultRequest.url.lastPathComponent == adapterTestVaultFileName)
        #expect(vaultRequest.headers["If-Match"] == "\"vault-etag-3\"")
        #expect(vaultRequest.body == newVaultData)

        #expect(manifestRequest.url.lastPathComponent == adapterTestManifestFileName)
        #expect(manifestRequest.headers["If-Match"] == "\"manifest-etag-3\"")
        let uploadedManifestData = try #require(manifestRequest.body)
        let uploadedManifest = try CloudVaultManifest.decode(uploadedManifestData)
        #expect(uploadedManifest == newManifest)

        #expect(receipt.kind == .webDAV)
        #expect(receipt.fileName == adapterTestVaultFileName)
        #expect(receipt.manifestFileName == adapterTestManifestFileName)
        #expect(receipt.revision == "\"vault-etag-4\"")
        #expect(receipt.manifestRevision == "\"manifest-etag-4\"")
        #expect(receipt.manifest == newManifest)
    }

    @Test func webDAVUpdateRemoteMapsPreconditionFailureToRemoteETag() async throws {
        let oldVaultData = adapterTestVaultData()
        let newVaultData = Data("monica-vault-ciphertext-v2".utf8)
        let oldManifest = adapterTestManifest(for: oldVaultData, revision: 3)
        let newManifest = adapterTestManifest(for: newVaultData, revision: 4)
        let remote = adapterTestRemote(manifest: oldManifest, revision: "\"vault-etag-3\"")
        let transport = FakeWebDAVTransport { _ in
            WebDAVTransportResponse(
                statusCode: 412,
                headers: ["ETag": "\"vault-current\""],
                body: Data()
            )
        }
        let store = adapterTestWebDAVStore(transport: transport)

        let error = await captureCloudVaultError {
            _ = try await store.updateRemote(
                vaultData: newVaultData,
                manifest: newManifest,
                remote: remote
            )
        }

        #expect(error == .preconditionFailed(remoteRevision: "\"vault-current\""))
        try #require(transport.requests.count == 1)
        #expect(transport.requests.first?.url.lastPathComponent == adapterTestVaultFileName)
        #expect(transport.requests.first?.headers["If-Match"] == "\"vault-etag-3\"")
    }

    @Test func webDAVUpdateRemoteWithoutETagRefusesWhenManifestRevisionChanged() async throws {
        let oldVaultData = adapterTestVaultData()
        let newVaultData = Data("monica-vault-ciphertext-v2".utf8)
        let oldManifest = adapterTestManifest(for: oldVaultData, revision: 3)
        let newManifest = adapterTestManifest(for: newVaultData, revision: 4)
        let remote = adapterTestRemote(manifest: oldManifest, revision: nil, manifestRevision: nil)

        let newerManifest = adapterTestManifest(for: oldVaultData, revision: 7)
        let newerManifestData = try newerManifest.encodedData()
        let transport = FakeWebDAVTransport { _ in
            WebDAVTransportResponse(
                statusCode: 200,
                headers: ["ETag": "\"manifest-etag-7\""],
                body: newerManifestData
            )
        }
        let store = adapterTestWebDAVStore(transport: transport)

        let error = await captureCloudVaultError {
            _ = try await store.updateRemote(
                vaultData: newVaultData,
                manifest: newManifest,
                remote: remote
            )
        }

        #expect(error == .preconditionFailed(remoteRevision: "\"manifest-etag-7\""))
        // Only the manifest re-read happened: neither object was written.
        #expect(transport.requests.map { $0.method } == ["GET"])
        #expect(transport.requests.first?.url.lastPathComponent == adapterTestManifestFileName)
    }

    @Test func webDAVUpdateRemoteWithoutETagProceedsWhenManifestRevisionUnchanged() async throws {
        let oldVaultData = adapterTestVaultData()
        let newVaultData = Data("monica-vault-ciphertext-v2".utf8)
        let oldManifest = adapterTestManifest(for: oldVaultData, revision: 3)
        let newManifest = adapterTestManifest(for: newVaultData, revision: 4)
        let oldManifestData = try oldManifest.encodedData()
        let remote = adapterTestRemote(manifest: oldManifest, revision: nil, manifestRevision: nil)

        let transport = FakeWebDAVTransport { request in
            if request.method == "GET" {
                return WebDAVTransportResponse(
                    statusCode: 200,
                    headers: ["ETag": "\"manifest-etag-3\""],
                    body: oldManifestData
                )
            }
            if request.url.lastPathComponent == adapterTestManifestFileName {
                return WebDAVTransportResponse(
                    statusCode: 201,
                    headers: ["ETag": "\"manifest-etag-4\""],
                    body: Data()
                )
            }
            return WebDAVTransportResponse(
                statusCode: 201,
                headers: ["ETag": "\"vault-etag-4\""],
                body: Data()
            )
        }
        let store = adapterTestWebDAVStore(transport: transport)

        let receipt = try await store.updateRemote(
            vaultData: newVaultData,
            manifest: newManifest,
            remote: remote
        )

        try #require(transport.requests.count == 3)
        #expect(transport.requests.map { $0.method } == ["GET", "PUT", "PUT"])
        #expect(transport.requests[0].url.lastPathComponent == adapterTestManifestFileName)
        #expect(transport.requests[1].url.lastPathComponent == adapterTestVaultFileName)
        #expect(transport.requests[1].headers["If-Match"] == nil)
        #expect(transport.requests[1].body == newVaultData)
        #expect(transport.requests[2].url.lastPathComponent == adapterTestManifestFileName)
        // No manifest ETag was exposed by the caller's read, so the re-checked
        // manifest write stays unconditional as well.
        #expect(transport.requests[2].headers["If-Match"] == nil)

        #expect(receipt.revision == "\"vault-etag-4\"")
        #expect(receipt.manifestRevision == "\"manifest-etag-4\"")
        #expect(receipt.manifest == newManifest)
    }

    @Test func webDAVUpdateRemoteWithoutVaultETagKeepsManifestWriteConditional() async throws {
        let oldVaultData = adapterTestVaultData()
        let newVaultData = Data("monica-vault-ciphertext-v2".utf8)
        let oldManifest = adapterTestManifest(for: oldVaultData, revision: 3)
        let newManifest = adapterTestManifest(for: newVaultData, revision: 4)
        let oldManifestData = try oldManifest.encodedData()
        // The server exposes no vault ETag but does expose a manifest ETag.
        let remote = adapterTestRemote(
            manifest: oldManifest,
            revision: nil,
            manifestRevision: "\"manifest-etag-3\""
        )

        let transport = FakeWebDAVTransport { request in
            if request.method == "GET" {
                return WebDAVTransportResponse(
                    statusCode: 200,
                    headers: ["ETag": "\"manifest-etag-3\""],
                    body: oldManifestData
                )
            }
            if request.url.lastPathComponent == adapterTestManifestFileName {
                return WebDAVTransportResponse(
                    statusCode: 201,
                    headers: ["ETag": "\"manifest-etag-4\""],
                    body: Data()
                )
            }
            return WebDAVTransportResponse(
                statusCode: 201,
                headers: ["ETag": "\"vault-etag-4\""],
                body: Data()
            )
        }
        let store = adapterTestWebDAVStore(transport: transport)

        _ = try await store.updateRemote(
            vaultData: newVaultData,
            manifest: newManifest,
            remote: remote
        )

        try #require(transport.requests.count == 3)
        #expect(transport.requests[1].url.lastPathComponent == adapterTestVaultFileName)
        #expect(transport.requests[1].headers["If-Match"] == nil)
        #expect(transport.requests[2].url.lastPathComponent == adapterTestManifestFileName)
        #expect(transport.requests[2].headers["If-Match"] == "\"manifest-etag-3\"")
    }

    // MARK: status mapping

    @Test(arguments: [401, 403, 500])
    func webDAVDownloadMapsHTTPStatusCodes(statusCode: Int) async throws {
        let vaultData = adapterTestVaultData()
        let manifest = adapterTestManifest(for: vaultData)
        let remote = adapterTestRemote(manifest: manifest)
        let body = statusCode == 500 ? Data("boom".utf8) : Data()
        let transport = FakeWebDAVTransport { _ in
            WebDAVTransportResponse(statusCode: statusCode, body: body)
        }
        let store = adapterTestWebDAVStore(transport: transport)

        let error = await captureCloudVaultError {
            _ = try await store.downloadVault(remote)
        }

        switch statusCode {
        case 401:
            #expect(error == .unauthorized(.webDAV))
        case 403:
            #expect(error == .forbidden(.webDAV))
        case 500:
            #expect(error == .server(statusCode: 500, message: "boom"))
        default:
            Issue.record("unexpected status code \(statusCode)")
        }
    }

    // MARK: conflict copies

    @Test func webDAVWriteConflictCopyUsesDeterministicNameAndNeverOverwrites() async throws {
        let vaultData = adapterTestVaultData()
        let manifest = adapterTestManifest(for: vaultData)
        let date = adapterTestReferenceDate
        let deviceName = "Test Device"
        let token = CloudVaultNaming.conflictCopyToken(sha256: manifest.contentSHA256, date: date)
        let expectedName = CloudVaultNaming.conflictCopyFileName(
            vaultFileName: adapterTestVaultFileName,
            deviceName: deviceName,
            date: date,
            shortToken: token
        )

        let transport = FakeWebDAVTransport { _ in
            WebDAVTransportResponse(
                statusCode: 201,
                headers: ["ETag": "\"copy-etag\""],
                body: Data()
            )
        }
        let store = adapterTestWebDAVStore(transport: transport)

        let receipt = try await store.writeConflictCopy(
            vaultData: vaultData,
            manifest: manifest,
            deviceName: deviceName,
            now: date
        )

        #expect(expectedName.hasPrefix(CloudVaultProtocolSpec.conflictCopyPrefix))
        #expect(expectedName != adapterTestVaultFileName)
        // Exactly one PUT: the copy is not accompanied by a manifest upload.
        try #require(transport.requests.count == 1)
        let request = try #require(transport.requests.first)
        #expect(request.method == "PUT")
        #expect(request.url.lastPathComponent == expectedName)
        #expect(request.headers["If-None-Match"] == "*")
        #expect(request.headers["Authorization"] == adapterTestBasicAuthorization())
        #expect(request.body == vaultData)

        #expect(receipt.kind == .webDAV)
        #expect(receipt.fileName == expectedName)
        #expect(receipt.remotePath == adapterTestVaultFileName)
        #expect(receipt.manifestFileName == adapterTestManifestFileName)
        #expect(receipt.manifest == manifest)
        #expect(receipt.revision == "\"copy-etag\"")
        #expect(receipt.manifestRevision == nil)
    }

    @Test func webDAVWriteConflictCopyMapsPreconditionFailure() async throws {
        let vaultData = adapterTestVaultData()
        let manifest = adapterTestManifest(for: vaultData)
        let transport = FakeWebDAVTransport { _ in
            WebDAVTransportResponse(
                statusCode: 412,
                headers: ["ETag": "\"existing-copy\""],
                body: Data()
            )
        }
        let store = adapterTestWebDAVStore(transport: transport)

        let error = await captureCloudVaultError {
            _ = try await store.writeConflictCopy(
                vaultData: vaultData,
                manifest: manifest,
                deviceName: "Test Device",
                now: adapterTestReferenceDate
            )
        }

        #expect(error == .preconditionFailed(remoteRevision: "\"existing-copy\""))
    }

    // MARK: - OneDrive adapter (CloudFileProvider)

    @Test func oneDriveReadRemoteFindsManifestAndVaultWithRevision() async throws {
        let vaultData = adapterTestVaultData()
        let manifest = adapterTestManifest(for: vaultData, revision: 7)
        let manifestData = try manifest.encodedData()
        let provider = FakeCloudFileProvider()
        let vaultID = provider.seedFile(
            named: adapterTestVaultFileName,
            data: vaultData,
            revision: "\"vault-etag-7\""
        )
        provider.seedFile(
            named: adapterTestManifestFileName,
            data: manifestData,
            revision: "\"manifest-etag-7\""
        )
        let store = adapterTestCloudFileStore(provider: provider)

        let maybeRemote = try await store.readRemote()
        let remote = try #require(maybeRemote)

        #expect(store.kind == .oneDrive)
        #expect(store.displayName == "OneDrive 应用文件夹")
        #expect(store.remotePath == adapterTestVaultFileName)
        #expect(remote.kind == .oneDrive)
        #expect(remote.itemID == vaultID)
        #expect(remote.revision == "\"vault-etag-7\"")
        #expect(remote.manifestRevision == "\"manifest-etag-7\"")
        #expect(remote.manifest == manifest)
        #expect(remote.fileName == adapterTestVaultFileName)
        #expect(remote.manifestFileName == adapterTestManifestFileName)
        #expect(provider.calls.contains(.listFiles))
    }

    @Test func oneDriveReadRemoteReportsMissingRemoteObjects() async throws {
        let provider = FakeCloudFileProvider()
        let store = adapterTestCloudFileStore(provider: provider)

        // No manifest at all -> no remote vault.
        let emptyRemote = try await store.readRemote()
        #expect(emptyRemote == nil)

        // Manifest present but the vault file is gone -> corrupt remote state.
        let vaultData = adapterTestVaultData()
        let manifest = adapterTestManifest(for: vaultData)
        provider.seedFile(named: adapterTestManifestFileName, data: try manifest.encodedData())
        let error = await captureCloudVaultError {
            _ = try await store.readRemote()
        }
        #expect(error == .remoteVaultMissing)
    }

    @Test func oneDriveDownloadVaultVerifiesIntegrity() async throws {
        let vaultData = adapterTestVaultData()
        let manifest = adapterTestManifest(for: vaultData)
        let provider = FakeCloudFileProvider()
        let vaultID = provider.seedFile(named: adapterTestVaultFileName, data: vaultData)
        provider.seedFile(named: adapterTestManifestFileName, data: try manifest.encodedData())
        let store = adapterTestCloudFileStore(provider: provider)

        let maybeRemote = try await store.readRemote()
        let remote = try #require(maybeRemote)
        #expect(remote.itemID == vaultID)

        let downloaded = try await store.downloadVault(remote)
        #expect(downloaded == vaultData)

        // Same byte count, different bytes: only the digest can catch this.
        var tamperedBytes = vaultData
        tamperedBytes[tamperedBytes.startIndex] ^= 0x01
        let tamperedBody = tamperedBytes
        provider.seedFile(named: adapterTestVaultFileName, data: tamperedBody)

        let error = await captureCloudVaultError {
            _ = try await store.downloadVault(remote)
        }
        #expect(
            error == .integrityMismatch(
                expectedSHA256: manifest.contentSHA256,
                actualSHA256: LanSyncEncoding.hex(LanSyncEncoding.sha256(tamperedBody))
            )
        )
    }

    @Test func oneDriveCreateRemoteRefusesWhenRemoteObjectsExist() async throws {
        let existingVaultData = adapterTestVaultData()
        let newVaultData = Data("brand-new-vault".utf8)
        let newManifest = adapterTestManifest(for: newVaultData, revision: 1)
        let provider = FakeCloudFileProvider()
        provider.seedFile(
            named: adapterTestVaultFileName,
            data: existingVaultData,
            revision: "\"vault-existing\""
        )
        let store = adapterTestCloudFileStore(provider: provider)

        let error = await captureCloudVaultError {
            _ = try await store.createRemote(vaultData: newVaultData, manifest: newManifest)
        }

        #expect(error == .preconditionFailed(remoteRevision: "\"vault-existing\""))
        #expect(provider.data(named: adapterTestVaultFileName) == existingVaultData)
        #expect(provider.uploadCalls.isEmpty)
    }

    @Test func oneDriveCreateRemoteUploadsVaultBeforeManifest() async throws {
        let vaultData = adapterTestVaultData()
        let manifest = adapterTestManifest(for: vaultData, revision: 1)
        let provider = FakeCloudFileProvider()
        let store = adapterTestCloudFileStore(provider: provider)

        let receipt = try await store.createRemote(vaultData: vaultData, manifest: manifest)

        #expect(
            provider.uploadCalls == [
                .uploadFile(name: adapterTestVaultFileName, byteCount: vaultData.count),
                .uploadFile(name: adapterTestManifestFileName, byteCount: try manifest.encodedData().count)
            ]
        )
        #expect(provider.calls.first == .listFiles)
        #expect(provider.data(named: adapterTestVaultFileName) == vaultData)
        let storedManifestData = try #require(provider.data(named: adapterTestManifestFileName))
        let storedManifest = try CloudVaultManifest.decode(storedManifestData)
        #expect(storedManifest == manifest)

        #expect(receipt.kind == .oneDrive)
        #expect(receipt.fileName == adapterTestVaultFileName)
        #expect(receipt.manifestFileName == adapterTestManifestFileName)
        #expect(receipt.remotePath == adapterTestVaultFileName)
        #expect(receipt.itemID == provider.itemID(named: adapterTestVaultFileName))
        #expect(receipt.revision == provider.revision(named: adapterTestVaultFileName))
        #expect(receipt.manifestRevision == provider.revision(named: adapterTestManifestFileName))
        #expect(receipt.manifest == manifest)
    }

    @Test func oneDriveUpdateRemotePassesExpectedRevisionsAndWritesManifestLast() async throws {
        let oldVaultData = adapterTestVaultData()
        let newVaultData = Data("monica-vault-ciphertext-v2".utf8)
        let oldManifest = adapterTestManifest(for: oldVaultData, revision: 3)
        let newManifest = adapterTestManifest(for: newVaultData, revision: 4)
        let provider = FakeCloudFileProvider()
        let vaultID = provider.seedFile(
            named: adapterTestVaultFileName,
            data: oldVaultData,
            revision: "\"vault-etag-3\""
        )
        let manifestID = provider.seedFile(
            named: adapterTestManifestFileName,
            data: try oldManifest.encodedData(),
            revision: "\"manifest-etag-3\""
        )
        let store = adapterTestCloudFileStore(provider: provider)
        let maybeRemote = try await store.readRemote()
        let remote = try #require(maybeRemote)

        let receipt = try await store.updateRemote(
            vaultData: newVaultData,
            manifest: newManifest,
            remote: remote
        )

        #expect(
            provider.overwriteCalls == [
                .overwriteFile(
                    id: vaultID,
                    name: adapterTestVaultFileName,
                    expectedRevision: "\"vault-etag-3\""
                ),
                .overwriteFile(
                    id: manifestID,
                    name: adapterTestManifestFileName,
                    expectedRevision: "\"manifest-etag-3\""
                )
            ]
        )
        #expect(provider.data(named: adapterTestVaultFileName) == newVaultData)
        let storedManifestData = try #require(provider.data(named: adapterTestManifestFileName))
        let storedManifest = try CloudVaultManifest.decode(storedManifestData)
        #expect(storedManifest == newManifest)

        #expect(receipt.kind == .oneDrive)
        #expect(receipt.revision == provider.revision(named: adapterTestVaultFileName))
        #expect(receipt.manifestRevision == provider.revision(named: adapterTestManifestFileName))
        #expect(receipt.manifest == newManifest)
    }

    @Test func oneDriveUpdateRemoteMapsConflictToPreconditionFailed() async throws {
        let oldVaultData = adapterTestVaultData()
        let newVaultData = Data("monica-vault-ciphertext-v2".utf8)
        let oldManifest = adapterTestManifest(for: oldVaultData, revision: 3)
        let newManifest = adapterTestManifest(for: newVaultData, revision: 4)
        let provider = FakeCloudFileProvider()
        let vaultID = provider.seedFile(
            named: adapterTestVaultFileName,
            data: oldVaultData,
            revision: "\"vault-etag-3\""
        )
        provider.seedFile(
            named: adapterTestManifestFileName,
            data: try oldManifest.encodedData(),
            revision: "\"manifest-etag-3\""
        )
        let store = adapterTestCloudFileStore(provider: provider)
        // The caller's read is stale: the provider now holds a different vault ETag.
        let remote = adapterTestRemote(
            kind: .oneDrive,
            manifest: oldManifest,
            itemID: vaultID,
            revision: "\"vault-etag-2\"",
            manifestRevision: "\"manifest-etag-3\""
        )

        let error = await captureCloudVaultError {
            _ = try await store.updateRemote(
                vaultData: newVaultData,
                manifest: newManifest,
                remote: remote
            )
        }

        #expect(error == .preconditionFailed(remoteRevision: nil))
        // The manifest must not be rewritten after the vault write was refused.
        #expect(provider.overwriteCalls.count == 1)
        #expect(provider.data(named: adapterTestManifestFileName) == (try oldManifest.encodedData()))
    }

    @Test func oneDriveWriteConflictCopyGetsUniqueName() async throws {
        let vaultData = adapterTestVaultData()
        let manifest = adapterTestManifest(for: vaultData)
        let date = adapterTestReferenceDate
        let deviceName = "Test Device"
        let token = CloudVaultNaming.conflictCopyToken(sha256: manifest.contentSHA256, date: date)
        let baseName = CloudVaultNaming.conflictCopyFileName(
            vaultFileName: adapterTestVaultFileName,
            deviceName: deviceName,
            date: date,
            shortToken: token
        )
        let existingCopyData = Data("existing-conflict-copy".utf8)
        let provider = FakeCloudFileProvider()
        provider.seedFile(
            named: baseName,
            data: existingCopyData,
            revision: "\"existing-copy-rev\""
        )
        let store = adapterTestCloudFileStore(provider: provider)

        let receipt = try await store.writeConflictCopy(
            vaultData: vaultData,
            manifest: manifest,
            deviceName: deviceName,
            now: date
        )

        let expectedName = baseName + "-1"
        #expect(receipt.fileName == expectedName)
        #expect(receipt.remotePath == adapterTestVaultFileName)
        #expect(receipt.manifest == manifest)
        #expect(receipt.manifestRevision == nil)
        #expect(receipt.revision == provider.revision(named: expectedName))
        #expect(
            provider.uploadCalls == [
                .uploadFile(name: expectedName, byteCount: vaultData.count)
            ]
        )
        // The pre-existing copy is untouched.
        #expect(provider.data(named: baseName) == existingCopyData)
        #expect(provider.revision(named: baseName) == "\"existing-copy-rev\"")
        #expect(provider.data(named: expectedName) == vaultData)
    }

    @Test func unsupportedCloudFileProviderIsRefusedByEveryMethod() async throws {
        let vaultData = adapterTestVaultData()
        let manifest = adapterTestManifest(for: vaultData)
        let remote = adapterTestRemote(
            kind: .oneDrive,
            manifest: manifest,
            itemID: "file-1",
            revision: "rev-1",
            manifestRevision: "rev-2"
        )
        let provider = FakeCloudFileProvider(kind: .googleDrive)
        let store = adapterTestCloudFileStore(provider: provider)

        #expect(
            isUnsupportedProvider(
                await captureCloudVaultError { _ = try await store.readRemote() }
            )
        )
        #expect(
            isUnsupportedProvider(
                await captureCloudVaultError { _ = try await store.downloadVault(remote) }
            )
        )
        #expect(
            isUnsupportedProvider(
                await captureCloudVaultError {
                    _ = try await store.createRemote(vaultData: vaultData, manifest: manifest)
                }
            )
        )
        #expect(
            isUnsupportedProvider(
                await captureCloudVaultError {
                    _ = try await store.updateRemote(
                        vaultData: vaultData,
                        manifest: manifest,
                        remote: remote
                    )
                }
            )
        )
        #expect(
            isUnsupportedProvider(
                await captureCloudVaultError {
                    _ = try await store.writeConflictCopy(
                        vaultData: vaultData,
                        manifest: manifest,
                        deviceName: "Device",
                        now: adapterTestReferenceDate
                    )
                }
            )
        )
        // Nothing reached the provider.
        #expect(provider.calls.isEmpty)
    }
}
