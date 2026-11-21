import Foundation
import Testing
@testable import MonicaSync

// MARK: - Stubs

private final class BrowserDriveTokenProvider: GoogleDriveAccessTokenProvider, @unchecked Sendable {
    private(set) var accessTokenCallCount = 0
    private(set) var refreshCallCount = 0
    var token = "drive-access-token-secret"
    var refreshedToken = "drive-refreshed-token-secret"
    var accessTokenError: Error?

    func accessToken() async throws -> String {
        accessTokenCallCount += 1
        if let accessTokenError {
            throw accessTokenError
        }
        return token
    }

    func refreshAccessToken() async throws -> String {
        refreshCallCount += 1
        token = refreshedToken
        return token
    }
}

private final class BrowserDriveTransport: GoogleDriveHTTPTransport, @unchecked Sendable {
    private(set) var requests: [GoogleDriveHTTPRequest] = []
    private var responses: [Result<GoogleDriveHTTPResponse, Error>] = []

    func enqueue(_ response: GoogleDriveHTTPResponse) {
        responses.append(.success(response))
    }

    func enqueue(statusCode: Int, body: String = "{}", headers: [String: String] = [:]) {
        enqueue(GoogleDriveHTTPResponse(statusCode: statusCode, headers: headers, body: Data(body.utf8)))
    }

    func enqueue(error: Error) {
        responses.append(.failure(error))
    }

    func send(_ request: GoogleDriveHTTPRequest) async throws -> GoogleDriveHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw URLError(.unknown)
        }
        return try responses.removeFirst().get()
    }
}

private final class BrowserGraphTransport: OneDriveGraphTransport, @unchecked Sendable {
    private(set) var requests: [OneDriveGraphRequest] = []
    private var responses: [OneDriveGraphResponse] = []

    func enqueue(statusCode: Int, body: String = "{}", headers: [String: String] = [:]) {
        responses.append(
            OneDriveGraphResponse(statusCode: statusCode, headers: headers, body: Data(body.utf8))
        )
    }

    func send(_ request: OneDriveGraphRequest) async throws -> OneDriveGraphResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw URLError(.unknown)
        }
        return responses.removeFirst()
    }
}

private final class BrowserWebDAVTransport: WebDAVTransport, @unchecked Sendable {
    private(set) var requests: [WebDAVTransportRequest] = []
    private var responses: [WebDAVTransportResponse] = []

    func enqueue(statusCode: Int, body: String = "", headers: [String: String] = [:]) {
        responses.append(
            WebDAVTransportResponse(statusCode: statusCode, headers: headers, body: Data(body.utf8))
        )
    }

    func send(_ request: WebDAVTransportRequest) async throws -> WebDAVTransportResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw URLError(.unknown)
        }
        return responses.removeFirst()
    }
}

private final class BrowserTokenProvider: OneDriveAccessTokenProvider, @unchecked Sendable {
    func accessToken() async throws -> String {
        "onedrive-access-token-secret"
    }
}

private final class BrowserDrivePresenter: GoogleDriveAuthorizationPresenting, @unchecked Sendable {
    private(set) var presentedURLs: [URL] = []
    var transform: (URL) -> URL

    init(transform: @escaping (URL) -> URL = { _ in URL(string: "com.googleusercontent.apps.test:/oauth2redirect?code=code-1")! }) {
        self.transform = transform
    }

    func presentAuthorization(url: URL, callbackURLScheme: String) async throws -> URL {
        presentedURLs.append(url)
        return transform(url)
    }
}

// MARK: - Helpers

private let driveClientID = "test-client-id.apps.googleusercontent.com"
private let driveScheme = "com.googleusercontent.apps.test"

private func makeDriveConfiguration() -> GoogleDriveConfiguration {
    GoogleDriveConfiguration(clientID: driveClientID, redirectScheme: driveScheme)
}

private func makeDriveBrowser(
    transport: BrowserDriveTransport,
    tokenProvider: BrowserDriveTokenProvider = BrowserDriveTokenProvider(),
    configuration: GoogleDriveConfiguration = makeDriveConfiguration()
) -> GoogleDriveCloudFileBrowser {
    GoogleDriveCloudFileBrowser(
        configuration: configuration,
        tokenProvider: tokenProvider,
        transport: transport,
        maximumAttempts: 3,
        retryDelay: { _ in }
    )
}

private func formFields(_ body: Data?) -> [String: String] {
    guard let body, let text = String(data: body, encoding: .utf8) else {
        return [:]
    }
    var fields: [String: String] = [:]
    for pair in text.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            continue
        }
        let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
        let value = String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            ?? String(parts[1])
        fields[key] = value
    }
    return fields
}

private func queryItems(_ url: URL) -> [String: String] {
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    var items: [String: String] = [:]
    for item in components?.queryItems ?? [] {
        items[item.name] = item.value
    }
    return items
}

private func driveFileJSON(
    id: String,
    name: String,
    mimeType: String = "application/octet-stream",
    size: Int = 24,
    version: String = "17",
    modifiedTime: String = "2025-01-01T00:00:00.000Z"
) -> String {
    """
    {
      "id": "\(id)",
      "name": "\(name)",
      "mimeType": "\(mimeType)",
      "size": "\(size)",
      "version": "\(version)",
      "modifiedTime": "\(modifiedTime)"
    }
    """
}

private let webDAVListing = """
<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/keepass/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/keepass/KeePass/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/keepass/vault.kdbx</D:href>
    <D:propstat><D:prop>
      <D:getcontentlength>2048</D:getcontentlength>
      <D:getlastmodified>Wed, 01 Jan 2025 10:00:00 GMT</D:getlastmodified>
      <D:getetag>"etag-1"</D:getetag>
      <D:resourcetype/>
    </D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/keepass/notes.txt</D:href>
    <D:propstat><D:prop><D:getcontentlength>12</D:getcontentlength><D:resourcetype/></D:prop></D:propstat>
  </D:response>
</D:multistatus>
"""

// MARK: - OneDrive browser

@Suite("CloudFileBrowser OneDrive")
struct OneDriveCloudFileBrowserTests {
    @Test("目录分页跟随 @odata.nextLink 并保留目录、过滤非 .kdbx 文件")
    func paginatesAndFilters() async throws {
        let transport = BrowserGraphTransport()
        let nextLink = "https://graph.microsoft.com/v1.0/me/drive/special/approot/children?$skiptoken=page-2"
        transport.enqueue(
            statusCode: 200,
            body: """
            {
              "value": [
                \(fileJSON(id: "folder-1", name: "KeePass", isFolder: true)),
                \(fileJSON(id: "file-1", name: "vault.kdbx", size: 2048)),
                \(fileJSON(id: "file-2", name: "notes.txt", size: 12))
              ],
              "@odata.nextLink": "\(nextLink)"
            }
            """
        )
        transport.enqueue(
            statusCode: 200,
            body: """
            {
              "value": [\(fileJSON(id: "file-3", name: "second.kdbx", size: 512))]
            }
            """
        )

        let browser = OneDriveCloudFileBrowser(
            configuration: OneDriveCloudFileConfiguration(clientID: "test", redirectURI: URL(string: "msauth://auth")!),
            tokenProvider: BrowserTokenProvider(),
            transport: transport
        )

        let first = try await browser.browse(directoryID: nil, pageToken: nil, pageSize: 2, filter: .keePassOnly)
        #expect(first.hasMore)
        #expect(first.directories.map(\.name) == ["KeePass"])
        #expect(first.keePassDatabases.map(\.name) == ["vault.kdbx"])
        #expect(first.keePassDatabases.first?.byteCount == 2048)
        #expect(first.keePassDatabases.first?.revision == "\"etag-file-1\"")
        #expect(first.entries.contains { $0.name == "notes.txt" } == false)
        #expect(queryItems(transport.requests[0].url)["$top"] == "2")
        #expect(transport.requests[0].headers["Authorization"] == "Bearer onedrive-access-token-secret")

        let token = try #require(first.nextPageToken)
        let second = try await browser.browse(directoryID: nil, pageToken: token, pageSize: 2, filter: .keePassOnly)
        #expect(second.hasMore == false)
        #expect(second.entries.map(\.name) == ["second.kdbx"])
        #expect(transport.requests[1].url.absoluteString == nextLink)

        #expect(
            await #expect(throws: CloudFileBrowserError.invalidPageToken(kind: .oneDrive)) {
                try await browser.browse(directoryID: nil, pageToken: "not-base64", pageSize: 2, filter: .all)
            } != nil
        )
    }

    @Test("上传使用 If-None-Match 创建、If-Match 覆盖，412 映射为冲突")
    func conditionalUpload() async throws {
        let transport = BrowserGraphTransport()
        transport.enqueue(
            statusCode: 201,
            body: fileJSON(id: "file-9", name: "vault.kdbx", etag: "etag-new")
        )
        let browser = OneDriveCloudFileBrowser(
            configuration: OneDriveCloudFileConfiguration(clientID: "test", redirectURI: URL(string: "msauth://auth")!),
            tokenProvider: BrowserTokenProvider(),
            transport: transport
        )

        let receipt = try await browser.upload(named: "../vault.kdbx", data: Data("kdbx".utf8), in: nil, expectedRevision: nil)
        #expect(receipt.name == "vault.kdbx")
        #expect(receipt.kind == .oneDrive)
        #expect(receipt.revision == "\"etag-new\"")
        #expect(transport.requests[0].method == "PUT")
        #expect(transport.requests[0].headers["If-None-Match"] == "*")
        #expect(transport.requests[0].url.absoluteString.contains(":/vault.kdbx:/content"))

        transport.enqueue(statusCode: 412, body: "{}")
        await #expect(throws: CloudFileProviderError.conflict(provider: .oneDrive)) {
            try await browser.upload(
                named: "vault.kdbx",
                data: Data("kdbx".utf8),
                in: nil,
                expectedRevision: "\"etag-old\""
            )
        }
        #expect(transport.requests[1].headers["If-Match"] == "\"etag-old\"")
    }

    @Test("按 ID 条件覆盖保留 If-Match")
    func conditionalOverwrite() async throws {
        let transport = BrowserGraphTransport()
        transport.enqueue(statusCode: 200, body: fileJSON(id: "file-1", name: "vault.kdbx", etag: "etag-2"))
        let browser = OneDriveCloudFileBrowser(
            configuration: OneDriveCloudFileConfiguration(clientID: "test", redirectURI: URL(string: "msauth://auth")!),
            tokenProvider: BrowserTokenProvider(),
            transport: transport
        )

        let receipt = try await browser.overwrite(entryID: "file-1", data: Data("kdbx".utf8), expectedRevision: "\"etag-1\"")
        #expect(receipt.revision == "\"etag-2\"")
        #expect(transport.requests[0].method == "PUT")
        #expect(transport.requests[0].headers["If-Match"] == "\"etag-1\"")
        #expect(transport.requests[0].url.absoluteString.hasSuffix("/me/drive/items/file-1/content"))
    }
}

private func fileJSON(
    id: String,
    name: String,
    size: Int = 24,
    isFolder: Bool = false,
    etag: String? = nil
) -> String {
    let resolvedETag = etag ?? "etag-\(id)"
    let payload = isFolder
        ? "\"folder\": {}"
        : "\"file\": {}"
    return """
    {
      "id": "\(id)",
      "name": "\(name)",
      "size": \(size),
      \(payload),
      "eTag": "\\"\(resolvedETag)\\"",
      "parentReference": { "path": "/drive/special/approot:" }
    }
    """
}

// MARK: - WebDAV browser

@Suite("CloudFileBrowser WebDAV")
struct WebDAVCloudFileBrowserTests {
    private func makeBrowser(_ transport: BrowserWebDAVTransport) -> WebDAVCloudFileBrowser {
        WebDAVCloudFileBrowser(
            endpoint: WebDAVEndpoint(
                baseURL: URL(string: "https://dav.example.com/keepass/")!,
                username: "monica",
                password: "secret"
            ),
            transport: transport
        )
    }

    @Test("PROPFIND 解析目录/大小/ETag，并按页切片")
    func parsesAndPaginates() async throws {
        let transport = BrowserWebDAVTransport()
        transport.enqueue(statusCode: 207, body: webDAVListing)
        transport.enqueue(statusCode: 207, body: webDAVListing)
        transport.enqueue(statusCode: 207, body: webDAVListing)
        let browser = makeBrowser(transport)

        let first = try await browser.browse(directoryID: nil, pageToken: nil, pageSize: 1, filter: .keePassOnly)
        #expect(first.totalCount == 2)
        #expect(first.entries.map(\.name) == ["KeePass"])
        #expect(first.hasMore)
        #expect(transport.requests[0].method == "PROPFIND")
        #expect(transport.requests[0].headers["Depth"] == "1")
        #expect(transport.requests[0].headers["Authorization"]?.hasPrefix("Basic ") == true)

        let token = try #require(first.nextPageToken)
        let second = try await browser.browse(directoryID: nil, pageToken: token, pageSize: 1, filter: .keePassOnly)
        #expect(second.entries.map(\.name) == ["vault.kdbx"])
        #expect(second.hasMore == false)
        #expect(second.entries[0].byteCount == 2048)
        #expect(second.entries[0].revision == "\"etag-1\"")
        #expect(second.entries[0].modifiedAt != nil)

        let all = try await browser.browse(directoryID: nil, pageToken: nil, pageSize: 10, filter: .all)
        #expect(all.entries.contains { $0.name == "notes.txt" })
    }

    @Test("上传与覆盖带条件头，412 映射为冲突")
    func conditionalWrites() async throws {
        let transport = BrowserWebDAVTransport()
        transport.enqueue(statusCode: 201, headers: ["ETag": "\"etag-9\""])
        transport.enqueue(statusCode: 412)
        transport.enqueue(statusCode: 204, headers: ["ETag": "\"etag-10\""])
        let browser = makeBrowser(transport)

        let created = try await browser.upload(named: "vault.kdbx", data: Data("kdbx".utf8), in: nil, expectedRevision: nil)
        #expect(created.revision == "\"etag-9\"")
        #expect(transport.requests[0].method == "PUT")
        #expect(transport.requests[0].headers["If-None-Match"] == "*")
        #expect(transport.requests[0].url.absoluteString == "https://dav.example.com/keepass/vault.kdbx")

        await #expect(throws: CloudFileProviderError.conflict(provider: .oneDrive)) {
            try await browser.upload(named: "vault.kdbx", data: Data("kdbx".utf8), in: nil, expectedRevision: "\"etag-9\"")
        }
        #expect(transport.requests[1].headers["If-Match"] == "\"etag-9\"")

        let overwritten = try await browser.overwrite(entryID: "vault.kdbx", data: Data("kdbx".utf8), expectedRevision: "\"etag-9\"")
        #expect(overwritten.revision == "\"etag-10\"")
        #expect(transport.requests[2].headers["If-Match"] == "\"etag-9\"")
    }

    @Test("连接探测使用 Depth 0，401 冒泡为状态错误")
    func connectionState() async throws {
        let transport = BrowserWebDAVTransport()
        transport.enqueue(statusCode: 207)
        let browser = makeBrowser(transport)
        let state = try await browser.connectionState()
        #expect(state == .connected(accountLabel: "WebDAV"))
        #expect(transport.requests[0].headers["Depth"] == "0")

        let failing = BrowserWebDAVTransport()
        failing.enqueue(statusCode: 401)
        await #expect(throws: WebDAVError.unexpectedStatus(operation: "connect", statusCode: 401)) {
            try await makeBrowser(failing).connectionState()
        }
    }
}

// MARK: - Google Drive browser

@Suite("CloudFileBrowser Google Drive")
struct GoogleDriveCloudFileBrowserTests {
    @Test("列目录拼接 .kdbx 过滤与分页参数")
    func browseQueryAndPaging() async throws {
        let transport = BrowserDriveTransport()
        transport.enqueue(
            statusCode: 200,
            body: """
            {
              "files": [
                \(driveFileJSON(id: "folder-1", name: "KeePass", mimeType: GoogleDriveCloudFileBrowser.folderMIMEType, size: 0)),
                \(driveFileJSON(id: "file-1", name: "vault.kdbx")),
                \(driveFileJSON(id: "file-2", name: "notes.txt"))
              ],
              "nextPageToken": "page-2"
            }
            """
        )
        transport.enqueue(statusCode: 200, body: #"{"files": []}"#)

        let browser = makeDriveBrowser(transport: transport)
        let first = try await browser.browse(directoryID: nil, pageToken: nil, pageSize: 25, filter: .keePassOnly)
        #expect(first.directories.map(\.name) == ["KeePass"])
        #expect(first.keePassDatabases.map(\.name) == ["vault.kdbx"])
        #expect(first.keePassDatabases.first?.revision == "17")
        #expect(first.nextPageToken == "page-2")

        let query = try #require(queryItems(transport.requests[0].url)["q"])
        #expect(query.contains("trashed = false"))
        #expect(query.contains("name contains '.kdbx'"))
        #expect(query.contains("'\(GoogleDriveCloudFileBrowser.folderMIMEType)'"))
        #expect(queryItems(transport.requests[0].url)["pageSize"] == "25")
        #expect(queryItems(transport.requests[0].url)["fields"]?.contains("nextPageToken") == true)
        #expect(transport.requests[0].headers["Authorization"] == "Bearer drive-access-token-secret")
        #expect(transport.requests[0].url.path.hasSuffix("/drive/v3/files"))

        _ = try await browser.browse(directoryID: "folder-1", pageToken: "page-2", pageSize: 10, filter: .all)
        let secondQuery = try #require(queryItems(transport.requests[1].url)["q"])
        #expect(secondQuery.contains("'folder-1' in parents"))
        #expect(queryItems(transport.requests[1].url)["pageToken"] == "page-2")
    }

    @Test("创建走 multipart 上传，覆盖带 If-Match，412 映射为冲突")
    func uploadAndOverwrite() async throws {
        let transport = BrowserDriveTransport()
        transport.enqueue(statusCode: 200, body: driveFileJSON(id: "file-1", name: "vault.kdbx", version: "18"))
        transport.enqueue(statusCode: 412, body: #"{"error": {"code": 412}}"#)
        transport.enqueue(statusCode: 200, body: driveFileJSON(id: "file-1", name: "vault.kdbx", version: "19"))

        let browser = makeDriveBrowser(transport: transport)
        let receipt = try await browser.upload(named: "vault.kdbx", data: Data("kdbx-bytes".utf8), in: "folder-1", expectedRevision: nil)
        #expect(receipt.itemID == "file-1")
        #expect(receipt.revision == "18")
        #expect(receipt.sha256.count == 64)
        #expect(transport.requests[0].method == "POST")
        #expect(transport.requests[0].url.path.contains("/upload/drive/v3/files"))
        #expect(queryItems(transport.requests[0].url)["uploadType"] == "multipart")
        let body = String(data: try #require(transport.requests[0].body), encoding: .utf8) ?? ""
        #expect(body.contains("vault.kdbx"))
        #expect(body.contains("kdbx-bytes"))
        #expect(body.contains("\"parents\":[\"folder-1\"]"))

        await #expect(throws: CloudFileProviderError.conflict(provider: .googleDrive)) {
            try await browser.overwrite(entryID: "file-1", data: Data("kdbx".utf8), expectedRevision: "18")
        }
        #expect(transport.requests[1].method == "PATCH")
        #expect(transport.requests[1].headers["If-Match"] == "18")

        let overwritten = try await browser.overwrite(entryID: "file-1", data: Data("kdbx".utf8), expectedRevision: "18")
        #expect(overwritten.revision == "19")
    }

    @Test("401 触发一次刷新后重试，403 直接要求登录")
    func authRetry() async throws {
        let transport = BrowserDriveTransport()
        transport.enqueue(statusCode: 401)
        transport.enqueue(statusCode: 200, body: #"{"files": []}"#)
        let tokenProvider = BrowserDriveTokenProvider()
        let browser = makeDriveBrowser(transport: transport, tokenProvider: tokenProvider)

        _ = try await browser.browse(directoryID: nil, pageToken: nil, pageSize: 10, filter: .keePassOnly)
        #expect(tokenProvider.refreshCallCount == 1)
        #expect(transport.requests.count == 2)
        #expect(transport.requests[1].headers["Authorization"] == "Bearer drive-refreshed-token-secret")

        let forbidden = BrowserDriveTransport()
        forbidden.enqueue(statusCode: 403)
        await #expect(throws: CloudFileProviderError.authenticationRequired(provider: .googleDrive)) {
            try await makeDriveBrowser(transport: forbidden).browse(directoryID: nil, pageToken: nil, pageSize: 10, filter: .all)
        }
    }

    @Test("网络错误重试后成功，超过次数后抛出")
    func retriesTransportErrors() async throws {
        let transport = BrowserDriveTransport()
        transport.enqueue(error: URLError(.timedOut))
        transport.enqueue(statusCode: 200, body: #"{"files": []}"#)
        let browser = makeDriveBrowser(transport: transport)
        _ = try await browser.browse(directoryID: nil, pageToken: nil, pageSize: 10, filter: .all)
        #expect(transport.requests.count == 2)

        let failing = BrowserDriveTransport()
        failing.enqueue(error: URLError(.notConnectedToInternet))
        failing.enqueue(error: URLError(.notConnectedToInternet))
        failing.enqueue(error: URLError(.notConnectedToInternet))
        await #expect(throws: URLError.self) {
            try await makeDriveBrowser(transport: failing).browse(directoryID: nil, pageToken: nil, pageSize: 10, filter: .all)
        }
        #expect(failing.requests.count == 3)
    }

    @Test("未配置 client ID 时禁用 provider 且不影响其他路径")
    func unconfiguredProvider() async throws {
        let transport = BrowserDriveTransport()
        let browser = makeDriveBrowser(
            transport: transport,
            configuration: GoogleDriveConfiguration()
        )
        #expect(browser.availability.isAvailable == false)
        #expect(browser.availability.unavailableReason?.contains("未配置") == true)
        #expect(try await browser.connectionState() == .disconnected)
        await #expect(throws: CloudFileProviderError.notConfigured(provider: .googleDrive)) {
            try await browser.browse(directoryID: nil, pageToken: nil, pageSize: 10, filter: .all)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("版本标记按 revision 优先比较")
    func versionMarkerConflicts() {
        let base = CloudFileVersionMarker(itemID: "file-1", revision: "17", modifiedAt: nil, byteCount: 10)
        #expect(base.conflicts(with: CloudFileVersionMarker(itemID: "file-1", revision: "18", modifiedAt: nil, byteCount: 10)))
        #expect(base.conflicts(with: CloudFileVersionMarker(itemID: "file-1", revision: "17", modifiedAt: nil, byteCount: 10)) == false)
        let date = Date(timeIntervalSince1970: 1_735_689_600)
        let dated = CloudFileVersionMarker(itemID: "f", revision: nil, modifiedAt: date, byteCount: 1)
        #expect(dated.conflicts(with: CloudFileVersionMarker(itemID: "f", revision: nil, modifiedAt: date.addingTimeInterval(5), byteCount: 1)))
        #expect(dated.conflicts(with: CloudFileVersionMarker(itemID: "f", revision: nil, modifiedAt: date, byteCount: 1)) == false)
    }
}

// MARK: - PKCE and OAuth

@Suite("GoogleDrive OAuth")
struct GoogleDriveOAuthTests {
    @Test("PKCE 使用 RFC 7636 S256 向量并校验 verifier")
    func pkceVector() throws {
        let pkce = try GoogleDrivePKCE(codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.codeChallenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(GoogleDrivePKCE.method == "S256")
        #expect(throws: GoogleDriveAuthError.invalidCodeVerifier) {
            try GoogleDrivePKCE(codeVerifier: "too-short")
        }
        #expect(throws: GoogleDriveAuthError.invalidCodeVerifier) {
            try GoogleDrivePKCE(codeVerifier: String(repeating: "a", count: 64) + "!")
        }

        let generated = GoogleDrivePKCE.generate()
        #expect(generated.codeVerifier.count == 64)
        #expect(GoogleDrivePKCE.challenge(for: generated.codeVerifier) == generated.codeChallenge)
        #expect(generated.codeChallenge != generated.codeVerifier)
        #expect(generated.codeChallenge.contains("=") == false)
    }

    @Test("授权 URL 带最小 scope 与 PKCE，state 回调校验")
    func authorizationURLAndCallback() throws {
        let service = GoogleDriveOAuthService(
            configuration: makeDriveConfiguration(),
            tokenStore: InMemoryGoogleDriveTokenStore(),
            transport: BrowserDriveTransport(),
            presenter: BrowserDrivePresenter()
        )
        let pkce = GoogleDrivePKCE.generate()
        let url = try #require(service.authorizationURL(pkce: pkce, state: "state-1"))
        let items = queryItems(url)
        #expect(items["client_id"] == driveClientID)
        #expect(items["redirect_uri"] == "\(driveScheme):/oauth2redirect")
        #expect(items["response_type"] == "code")
        #expect(items["code_challenge"] == pkce.codeChallenge)
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"] == "state-1")
        #expect(items["scope"] == "https://www.googleapis.com/auth/drive.file")
        #expect(items["access_type"] == "offline")

        let code = try service.authorizationCode(
            from: URL(string: "\(driveScheme):/oauth2redirect?code=abc&state=state-1")!,
            expectedState: "state-1"
        )
        #expect(code == "abc")

        #expect(throws: GoogleDriveAuthError.stateMismatch) {
            try service.authorizationCode(
                from: URL(string: "\(driveScheme):/oauth2redirect?code=abc&state=other")!,
                expectedState: "state-1"
            )
        }
        #expect(throws: GoogleDriveAuthError.authorizationDenied) {
            try service.authorizationCode(
                from: URL(string: "\(driveScheme):/oauth2redirect?error=access_denied&state=state-1")!,
                expectedState: "state-1"
            )
        }
    }

    @Test("登录交换 code_verifier 并把 token 写入注入的存储")
    func signInExchangesVerifier() async throws {
        let transport = BrowserDriveTransport()
        transport.enqueue(
            statusCode: 200,
            body: #"{"access_token":"access-1","refresh_token":"refresh-1","expires_in":3600,"scope":"drive.file","token_type":"Bearer"}"#
        )
        let store = InMemoryGoogleDriveTokenStore()
        let presenter = BrowserDrivePresenter { url in
            let state = queryItems(url)["state"] ?? ""
            return URL(string: "\(driveScheme):/oauth2redirect?code=code-1&state=\(state)")!
        }
        let service = GoogleDriveOAuthService(
            configuration: makeDriveConfiguration(),
            tokenStore: store,
            transport: transport,
            presenter: presenter,
            now: { Date(timeIntervalSince1970: 1_735_689_600) }
        )

        let token = try await service.signIn()
        #expect(token.accessToken == "access-1")
        #expect(token.refreshToken == "refresh-1")
        #expect(try store.loadToken()?.accessToken == "access-1")

        let presented = try #require(presenter.presentedURLs.first)
        let challenge = try #require(queryItems(presented)["code_challenge"])
        let fields = formFields(transport.requests[0].body)
        #expect(fields["grant_type"] == "authorization_code")
        #expect(fields["code"] == "code-1")
        #expect(fields["redirect_uri"] == "\(driveScheme):/oauth2redirect")
        let verifier = try #require(fields["code_verifier"])
        #expect(GoogleDrivePKCE.challenge(for: verifier) == challenge)
        #expect(token.redactedDescription.contains("access-1") == false)
        #expect(token.redactedDescription.contains("refresh-1") == false)
    }

    @Test("过期 token 自动刷新，撤销后清空并要求重新登录")
    func refreshAndRevoke() async throws {
        let expired = GoogleDriveOAuthToken(
            accessToken: "stale-access",
            refreshToken: "refresh-1",
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )
        let store = InMemoryGoogleDriveTokenStore(token: expired)
        let transport = BrowserDriveTransport()
        transport.enqueue(
            statusCode: 200,
            body: #"{"access_token":"fresh-access","expires_in":3600,"token_type":"Bearer"}"#
        )
        let service = GoogleDriveOAuthService(
            configuration: makeDriveConfiguration(),
            tokenStore: store,
            transport: transport,
            presenter: BrowserDrivePresenter(),
            now: { Date(timeIntervalSince1970: 2_000) }
        )

        let token = try await service.accessToken()
        #expect(token == "fresh-access")
        #expect(formFields(transport.requests[0].body)["grant_type"] == "refresh_token")
        #expect(formFields(transport.requests[0].body)["refresh_token"] == "refresh-1")
        #expect(try store.loadToken()?.accessToken == "fresh-access")
        #expect(try store.loadToken()?.refreshToken == "refresh-1")

        let revokedStore = InMemoryGoogleDriveTokenStore(token: expired)
        let revokedTransport = BrowserDriveTransport()
        revokedTransport.enqueue(statusCode: 400, body: #"{"error":"invalid_grant"}"#)
        let revoked = GoogleDriveOAuthService(
            configuration: makeDriveConfiguration(),
            tokenStore: revokedStore,
            transport: revokedTransport,
            presenter: BrowserDrivePresenter(),
            now: { Date(timeIntervalSince1970: 2_000) }
        )
        await #expect(throws: CloudFileProviderError.authenticationRequired(provider: .googleDrive)) {
            try await revoked.accessToken()
        }
        #expect(try revokedStore.loadToken() == nil)

        let missing = GoogleDriveOAuthService(
            configuration: makeDriveConfiguration(),
            tokenStore: InMemoryGoogleDriveTokenStore(),
            transport: BrowserDriveTransport(),
            presenter: BrowserDrivePresenter()
        )
        await #expect(throws: CloudFileProviderError.authenticationRequired(provider: .googleDrive)) {
            try await missing.accessToken()
        }
    }

    @Test("未配置时 signIn 抛出 notConfigured")
    func unconfiguredSignIn() async throws {
        let service = GoogleDriveOAuthService(
            configuration: GoogleDriveConfiguration(),
            tokenStore: InMemoryGoogleDriveTokenStore(),
            transport: BrowserDriveTransport(),
            presenter: BrowserDrivePresenter()
        )
        await #expect(throws: GoogleDriveAuthError.notConfigured) {
            try await service.signIn()
        }
    }
}

// MARK: - Shared helpers

@Suite("CloudFileBrowser helpers")
struct CloudFileBrowserHelperTests {
    @Test(".kdbx 过滤大小写无关并清理路径")
    func keePassFilenameHelpers() {
        #expect(CloudFileKeePassFile.isKeePassDatabaseName("vault.kdbx"))
        #expect(CloudFileKeePassFile.isKeePassDatabaseName("VAULT.KDBX"))
        #expect(CloudFileKeePassFile.isKeePassDatabaseName("vault.kdbx ") )
        #expect(CloudFileKeePassFile.isKeePassDatabaseName("vault.kdbx.bak") == false)
        #expect(CloudFileKeePassFile.isKeePassDatabaseName("vault.txt") == false)
        #expect(CloudFileKeePassFile.sanitizedName("../dir/vault.kdbx") == "vault.kdbx")
        #expect(CloudFileKeePassFile.sanitizedName("  ") == "未命名文件")

        let entry = CloudFileBrowserEntry(id: "1", name: "vault.kdbx", path: "vault.kdbx", isDirectory: false, byteCount: 10)
        #expect(entry.isKeePassDatabase)
        #expect(entry.redactedSummary == "vault.kdbx 10 字节")
    }
}
