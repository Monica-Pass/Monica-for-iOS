// MARK: - OneDrive 云文件适配器（配置 / Graph 传输 / 分片上传 / 目录）

import Foundation

public struct OneDriveCloudFileConfiguration: Sendable, Equatable {
    public let clientID: String
    public let redirectURI: URL
    public let scopes: [String]
    public let graphBaseURL: URL
    /// Files at or below this size use a single `PUT /content` request.
    public let simpleUploadLimitBytes: Int
    /// Upload-session chunk size. Microsoft Graph requires a multiple of 320 KiB.
    public let uploadChunkSizeBytes: Int
    public let uploadRetryLimit: Int
    public let uploadRetryDelay: TimeInterval
    public let maximumDirectoryPageCount: Int

    public init(
        clientID: String,
        redirectURI: URL,
        scopes: [String] = ["Files.ReadWrite.AppFolder"],
        graphBaseURL: URL = URL(string: "https://graph.microsoft.com/v1.0")!,
        simpleUploadLimitBytes: Int = 4 * 1024 * 1024,
        uploadChunkSizeBytes: Int = 10 * 320 * 1024,
        uploadRetryLimit: Int = 3,
        uploadRetryDelay: TimeInterval = 1,
        maximumDirectoryPageCount: Int = 100
    ) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.graphBaseURL = graphBaseURL
        self.simpleUploadLimitBytes = max(simpleUploadLimitBytes, 1)
        let chunkGranularity = 320 * 1024
        self.uploadChunkSizeBytes = max(chunkGranularity, (uploadChunkSizeBytes / chunkGranularity) * chunkGranularity)
        self.uploadRetryLimit = max(uploadRetryLimit, 0)
        self.uploadRetryDelay = max(uploadRetryDelay, 0)
        self.maximumDirectoryPageCount = max(maximumDirectoryPageCount, 1)
    }

    public static let monicaProduction = OneDriveCloudFileConfiguration(
        clientID: "2aaf8c2c-b817-4085-9517-586a4a113dfc",
        redirectURI: URL(string: "msauth.com.monicapass.monica://auth")!
    )

    public var redirectScheme: String {
        redirectURI.scheme ?? ""
    }

    public var redactedSummary: String {
        "OneDrive MSAL \(redirectScheme)"
    }
}

public protocol OneDriveAccessTokenProvider: Sendable {
    func accessToken() async throws -> String
}

public struct EmptyOneDriveAccessTokenProvider: OneDriveAccessTokenProvider {
    public init() {}

    public func accessToken() async throws -> String {
        throw CloudFileProviderError.authenticationRequired(provider: .oneDrive)
    }
}

public struct OneDriveGraphRequest: Sendable, Equatable {
    public let method: String
    public let url: URL
    public let headers: [String: String]
    public let body: Data?

    public init(
        method: String,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct OneDriveGraphResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public protocol OneDriveGraphTransport: Sendable {
    func send(_ request: OneDriveGraphRequest) async throws -> OneDriveGraphResponse
}

public struct OneDriveCloudFileProvider: CloudFileProvider, CloudFileBackupDirectoryProviding {
    public let kind: CloudFileProviderKind = .oneDrive
    public let configuration: OneDriveCloudFileConfiguration
    private let tokenProvider: any OneDriveAccessTokenProvider
    private let graphTransport: any OneDriveGraphTransport

    public init(
        configuration: OneDriveCloudFileConfiguration = .monicaProduction,
        tokenProvider: any OneDriveAccessTokenProvider = EmptyOneDriveAccessTokenProvider(),
        graphTransport: any OneDriveGraphTransport = URLSessionOneDriveGraphTransport()
    ) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        self.graphTransport = graphTransport
    }

    public func connectionState() async throws -> CloudFileConnectionState {
        do {
            _ = try await tokenProvider.accessToken()
            return .connected(accountLabel: "OneDrive")
        } catch let error as CloudFileProviderError {
            if case .authenticationRequired = error {
                return .disconnected
            }
            throw error
        }
    }

    public func listFiles() async throws -> [CloudFileItem] {
        try await loadAllChildren(path: childrenPath(for: nil))
            .filter { $0.isFile }
            .map { $0.cloudFileItem }
    }

    public func listBackupDirectory(id: String?) async throws -> CloudFileBackupDirectoryListing {
        let directory: CloudFileBackupDirectory?
        if let id {
            let metadata = try await loadDriveItem(id: id)
            guard !metadata.isFile else {
                throw CloudFileProviderError.itemNotFound(provider: kind)
            }
            directory = CloudFileBackupDirectory(
                id: metadata.id,
                name: metadata.name,
                parentID: nil,
                path: metadata.appFolderRelativePath
            )
        } else {
            directory = nil
        }

        let items = try await loadAllChildren(path: childrenPath(for: id))
        let basePath = directory?.displayPath ?? ""
        var directories: [CloudFileBackupDirectory] = []
        var files: [CloudFileItem] = []
        for item in items {
            if item.isFile {
                files.append(item.cloudFileItem)
            } else {
                directories.append(item.backupDirectory(parentID: id, parentPath: basePath))
            }
        }
        return CloudFileBackupDirectoryListing(
            directory: directory,
            directories: directories,
            files: files
        )
    }

    public func createBackupDirectory(named name: String, parentID: String?) async throws -> CloudFileBackupDirectory {
        let validName = try CloudFileBackupDirectoryName.validated(name, provider: kind)
        let body = try JSONSerialization.data(withJSONObject: [
            "name": validName,
            "folder": [String: Any](),
            "@microsoft.graph.conflictBehavior": "fail"
        ])
        let response = try await sendGraphRequest(
            method: "POST",
            path: childrenPath(for: parentID),
            headers: ["Content-Type": "application/json"],
            accept: "application/json",
            body: body
        )
        if response.statusCode == 409 {
            throw CloudFileProviderError.conflict(provider: kind)
        }
        try validateSuccess(response, allowedStatusCodes: [200, 201])
        let item = try OneDriveDriveItem(response.body)
        guard !item.isFile else {
            throw CloudFileProviderError.unsupportedOperation(provider: kind)
        }
        return CloudFileBackupDirectory(
            id: item.id,
            name: item.name,
            parentID: parentID,
            path: item.appFolderRelativePath
        )
    }

    public func uploadFile(
        named fileName: String,
        data: Data,
        inDirectory directoryID: String?,
        conflictBehavior: CloudFileUploadConflictBehavior
    ) async throws -> CloudFileWriteReceipt {
        let safeName = sanitizedCloudFileName(fileName)
        if data.count > configuration.simpleUploadLimitBytes {
            return try await uploadLargeFile(
                named: safeName,
                data: data,
                sessionPath: fileItemPath(directoryID: directoryID, fileName: safeName) + ":/createUploadSession",
                conflictBehavior: conflictBehavior,
                expectedRevision: nil
            )
        }

        var headers = ["Content-Type": "application/octet-stream"]
        if conflictBehavior == .fail {
            headers["If-None-Match"] = "*"
        }
        let response = try await sendGraphRequest(
            method: "PUT",
            path: fileItemPath(directoryID: directoryID, fileName: safeName) + ":/content",
            headers: headers,
            body: data
        )
        if response.statusCode == 409 || response.statusCode == 412 {
            throw CloudFileProviderError.conflict(provider: kind)
        }
        try validateSuccess(response, allowedStatusCodes: [200, 201])
        let item = try OneDriveDriveItem(response.body)
        return writeReceipt(from: item, data: data, fallbackFileName: safeName)
    }

    public func downloadFile(id: String) async throws -> CloudFileDownload {
        let metadata = try await loadDriveItem(id: id)
        let response = try await sendGraphRequest(
            method: "GET",
            path: "/me/drive/items/\(Self.percentEncodePathComponent(id))/content",
            accept: "application/octet-stream"
        )
        try validateSuccess(response, allowedStatusCodes: [200])
        return CloudFileDownload(
            item: metadata.cloudFileItem,
            data: response.body,
            sha256: response.body.monicaSHA256Hex,
            revision: metadata.revision
        )
    }

    public func uploadFile(named fileName: String, data: Data) async throws -> CloudFileWriteReceipt {
        let safeName = sanitizedCloudFileName(fileName)
        if data.count > configuration.simpleUploadLimitBytes {
            return try await uploadLargeFile(
                named: safeName,
                data: data,
                sessionPath: fileItemPath(directoryID: nil, fileName: safeName) + ":/createUploadSession",
                conflictBehavior: .replace,
                expectedRevision: nil
            )
        }
        let response = try await sendGraphRequest(
            method: "PUT",
            path: "/me/drive/special/approot:/\(Self.percentEncodeGraphPath(fileName)):/content",
            headers: ["Content-Type": "application/octet-stream"],
            body: data
        )
        try validateSuccess(response, allowedStatusCodes: [200, 201])
        let item = try OneDriveDriveItem(response.body)
        return writeReceipt(from: item, data: data, fallbackFileName: fileName)
    }

    public func overwriteFile(id: String, data: Data, fileName: String, expectedRevision: String? = nil) async throws -> CloudFileWriteReceipt {
        if data.count > configuration.simpleUploadLimitBytes {
            return try await uploadLargeFile(
                named: fileName,
                data: data,
                sessionPath: "/me/drive/items/\(Self.percentEncodePathComponent(id))/createUploadSession",
                conflictBehavior: .replace,
                expectedRevision: expectedRevision
            )
        }
        var headers = ["Content-Type": "application/octet-stream"]
        if let expectedRevision, !expectedRevision.isEmpty {
            headers["If-Match"] = expectedRevision
        }
        let response = try await sendGraphRequest(
            method: "PUT",
            path: "/me/drive/items/\(Self.percentEncodePathComponent(id))/content",
            headers: headers,
            body: data
        )
        if response.statusCode == 412 {
            throw CloudFileProviderError.conflict(provider: kind)
        }
        try validateSuccess(response, allowedStatusCodes: [200, 201])
        let item = try OneDriveDriveItem(response.body)
        return writeReceipt(from: item, data: data, fallbackFileName: fileName)
    }

    public func deleteFile(id: String) async throws -> CloudFileDeleteReceipt {
        let response = try await sendGraphRequest(
            method: "DELETE",
            path: "/me/drive/items/\(Self.percentEncodePathComponent(id))"
        )
        try validateSuccess(response, allowedStatusCodes: [200, 202, 204])
        return CloudFileDeleteReceipt(provider: kind, itemID: id)
    }

    public func renameFile(id: String, newName: String) async throws -> CloudFileWriteReceipt {
        let body = try JSONSerialization.data(withJSONObject: ["name": sanitizedCloudFileName(newName)])
        let response = try await sendGraphRequest(
            method: "PATCH",
            path: "/me/drive/items/\(Self.percentEncodePathComponent(id))",
            headers: ["Content-Type": "application/json"],
            accept: "application/json",
            body: body
        )
        try validateSuccess(response, allowedStatusCodes: [200])
        let item = try OneDriveDriveItem(response.body)
        return writeReceipt(from: item, data: Data(repeating: 0, count: item.byteCount), fallbackFileName: newName)
    }

    private func loadDriveItem(id: String) async throws -> OneDriveDriveItem {
        let response = try await sendGraphRequest(
            method: "GET",
            path: "/me/drive/items/\(Self.percentEncodePathComponent(id))",
            accept: "application/json"
        )
        try validateSuccess(response, allowedStatusCodes: [200])
        return try OneDriveDriveItem(response.body)
    }

    private func loadAllChildren(path: String) async throws -> [OneDriveDriveItem] {
        var items: [OneDriveDriveItem] = []
        var response = try await sendGraphRequest(
            method: "GET",
            path: path,
            accept: "application/json"
        )
        var pageCount = 1
        while true {
            try validateSuccess(response, allowedStatusCodes: [200])
            let page = try OneDriveDriveItemListResponse(response.body)
            items.append(contentsOf: page.items)
            guard let nextLink = page.nextLink else {
                return items
            }
            guard pageCount < configuration.maximumDirectoryPageCount else {
                throw CloudFileProviderError.unsupportedOperation(provider: kind)
            }
            response = try await sendGraphRequest(
                url: try validatedGraphURL(nextLink),
                method: "GET",
                accept: "application/json"
            )
            pageCount += 1
        }
    }

    private func uploadLargeFile(
        named fileName: String,
        data: Data,
        sessionPath: String,
        conflictBehavior: CloudFileUploadConflictBehavior,
        expectedRevision: String?
    ) async throws -> CloudFileWriteReceipt {
        var headers = ["Content-Type": "application/json"]
        if let expectedRevision, !expectedRevision.isEmpty {
            headers["If-Match"] = expectedRevision
        }
        let sessionBody = try JSONSerialization.data(withJSONObject: [
            "item": [
                "@microsoft.graph.conflictBehavior": conflictBehavior.rawValue
            ]
        ])
        let sessionResponse = try await sendGraphRequest(
            method: "POST",
            path: sessionPath,
            headers: headers,
            accept: "application/json",
            body: sessionBody
        )
        if sessionResponse.statusCode == 409 || sessionResponse.statusCode == 412 {
            throw CloudFileProviderError.conflict(provider: kind)
        }
        try validateSuccess(sessionResponse, allowedStatusCodes: [200, 201])
        guard let object = try JSONSerialization.jsonObject(with: sessionResponse.body) as? [String: Any],
              let uploadURLString = object["uploadUrl"] as? String,
              let uploadURL = URL(string: uploadURLString),
              uploadURL.scheme?.lowercased() == "https",
              uploadURL.host != nil
        else {
            throw CloudFileProviderError.unsupportedOperation(provider: kind)
        }

        let item = try await uploadChunks(data: data, to: uploadURL)
        return writeReceipt(from: item, data: data, fallbackFileName: fileName)
    }

    private func uploadChunks(data: Data, to uploadURL: URL) async throws -> OneDriveDriveItem {
        let chunkSize = configuration.uploadChunkSizeBytes
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            let end = min(offset + chunkSize, data.count) - 1
            let chunk = data.subdata(in: offset..<(end + 1))
            let response = try await sendUploadChunk(
                url: uploadURL,
                headers: [
                    "Content-Length": "\(chunk.count)",
                    "Content-Range": "bytes \(offset)-\(end)/\(data.count)"
                ],
                body: chunk
            )
            switch response.statusCode {
            case 200, 201:
                return try OneDriveDriveItem(response.body)
            case 202:
                offset = end + 1
            case 400, 404, 409, 412, 416:
                throw CloudFileProviderError.conflict(provider: kind)
            default:
                throw CloudFileProviderError.unsupportedOperation(provider: kind)
            }
        }
        throw CloudFileProviderError.unsupportedOperation(provider: kind)
    }

    /// Upload-session chunk `PUT`s are sent to a pre-authorized URL and must not
    /// carry the Graph bearer token.
    private func sendUploadChunk(
        url: URL,
        headers: [String: String],
        body: Data
    ) async throws -> OneDriveGraphResponse {
        var attempt = 0
        while true {
            do {
                let response = try await graphTransport.send(
                    OneDriveGraphRequest(method: "PUT", url: url, headers: headers, body: body)
                )
                guard Self.isRetryableStatus(response.statusCode),
                      attempt < configuration.uploadRetryLimit
                else {
                    return response
                }
                attempt += 1
                try await Self.waitBeforeRetry(
                    attempt: attempt,
                    response: response,
                    baseDelay: configuration.uploadRetryDelay
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard Self.isRetryableTransportError(error),
                      attempt < configuration.uploadRetryLimit
                else {
                    throw error
                }
                attempt += 1
                try await Self.waitBeforeRetry(
                    attempt: attempt,
                    response: nil,
                    baseDelay: configuration.uploadRetryDelay
                )
            }
        }
    }

    private static func isRetryableStatus(_ statusCode: Int) -> Bool {
        switch statusCode {
        case 408, 429, 500, 502, 503, 504:
            return true
        default:
            return false
        }
    }

    private static func isRetryableTransportError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else {
            return false
        }
        switch urlError.code {
        case .timedOut,
             .networkConnectionLost,
             .notConnectedToInternet,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .secureConnectionFailed,
             .internationalRoamingOff,
             .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    private static func waitBeforeRetry(
        attempt: Int,
        response: OneDriveGraphResponse?,
        baseDelay: TimeInterval
    ) async throws {
        var retryAfter: TimeInterval?
        if let headers = response?.headers,
           let header = headers.first(where: { $0.key.lowercased() == "retry-after" }) {
            retryAfter = Double(header.value)
        }
        let delay: TimeInterval
        if let retryAfter {
            delay = min(max(retryAfter, 0), 30)
        } else {
            delay = min(max(baseDelay, 0) * pow(2, Double(max(attempt - 1, 0))), 30)
        }
        guard delay > 0 else {
            return
        }
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    private func childrenPath(for directoryID: String?) -> String {
        if let directoryID {
            return "/me/drive/items/\(Self.percentEncodePathComponent(directoryID))/children"
        }
        return "/me/drive/special/approot/children"
    }

    /// Returns `.../approot:/name` or `.../items/{id}:/name`, without the trailing
    /// `:/content` or `:/createUploadSession` suffix.
    private func fileItemPath(directoryID: String?, fileName: String) -> String {
        let encodedName = Self.percentEncodeGraphPath(fileName)
        if let directoryID {
            return "/me/drive/items/\(Self.percentEncodePathComponent(directoryID)):/\(encodedName)"
        }
        return "/me/drive/special/approot:/\(encodedName)"
    }

    private func validatedGraphURL(_ url: URL) throws -> URL {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == configuration.graphBaseURL.host?.lowercased(),
              url.port == configuration.graphBaseURL.port
        else {
            throw CloudFileProviderError.unsupportedOperation(provider: kind)
        }
        return url
    }

    private func sendGraphRequest(
        method: String,
        path: String,
        headers: [String: String] = [:],
        accept: String? = nil,
        body: Data? = nil
    ) async throws -> OneDriveGraphResponse {
        let token = try await tokenProvider.accessToken()
        return try await sendGraphRequest(
            method: method,
            url: configuration.graphBaseURL.appendingGraphPath(path),
            headers: headers,
            accept: accept,
            body: body,
            token: token
        )
    }

    private func sendGraphRequest(
        url: URL,
        method: String,
        headers: [String: String] = [:],
        accept: String? = nil,
        body: Data? = nil
    ) async throws -> OneDriveGraphResponse {
        let token = try await tokenProvider.accessToken()
        return try await sendGraphRequest(
            method: method,
            url: url,
            headers: headers,
            accept: accept,
            body: body,
            token: token
        )
    }

    private func sendGraphRequest(
        method: String,
        url: URL,
        headers: [String: String],
        accept: String?,
        body: Data?,
        token: String
    ) async throws -> OneDriveGraphResponse {
        var requestHeaders = headers
        requestHeaders["Authorization"] = "Bearer \(token)"
        if let accept {
            requestHeaders["Accept"] = accept
        }
        return try await graphTransport.send(
            OneDriveGraphRequest(
                method: method,
                url: url,
                headers: requestHeaders,
                body: body
            )
        )
    }

    private func validateSuccess(
        _ response: OneDriveGraphResponse,
        allowedStatusCodes: Set<Int>
    ) throws {
        if response.statusCode == 401 || response.statusCode == 403 {
            throw CloudFileProviderError.authenticationRequired(provider: kind)
        }
        if response.statusCode == 404 {
            throw CloudFileProviderError.itemNotFound(provider: kind)
        }
        if response.statusCode == 412 {
            throw CloudFileProviderError.conflict(provider: kind)
        }
        guard allowedStatusCodes.contains(response.statusCode) else {
            throw CloudFileProviderError.unsupportedOperation(provider: kind)
        }
    }

    private func writeReceipt(
        from item: OneDriveDriveItem,
        data: Data,
        fallbackFileName: String
    ) -> CloudFileWriteReceipt {
        CloudFileWriteReceipt(
            provider: kind,
            itemID: item.id,
            name: item.name.isEmpty ? fallbackFileName : item.name,
            byteCount: data.count,
            sha256: data.monicaSHA256Hex,
            revision: item.revision
        )
    }

    private static func percentEncodeGraphPath(_ value: String) -> String {
        value
            .split(separator: "/")
            .map { percentEncodePathComponent(String($0)) }
            .joined(separator: "/")
    }

    private static func percentEncodePathComponent(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

public final class URLSessionOneDriveGraphTransport: OneDriveGraphTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: OneDriveGraphRequest) async throws -> OneDriveGraphResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        request.headers.forEach { key, value in
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudFileProviderError.unsupportedOperation(provider: .oneDrive)
        }
        var headers: [String: String] = [:]
        httpResponse.allHeaderFields.forEach { key, value in
            guard let key = key as? String else { return }
            headers[key] = "\(value)"
        }
        return OneDriveGraphResponse(
            statusCode: httpResponse.statusCode,
            headers: headers,
            body: data
        )
    }
}

private struct OneDriveDriveItemListResponse {
    let items: [OneDriveDriveItem]
    let nextLink: URL?

    init(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = root["value"] as? [[String: Any]]
        else {
            throw CloudFileProviderError.unsupportedOperation(provider: .oneDrive)
        }
        self.items = try values.map(OneDriveDriveItem.init)
        self.nextLink = (root["@odata.nextLink"] as? String).flatMap(URL.init(string:))
    }
}

private struct OneDriveDriveItem {
    let id: String
    let name: String
    let path: String
    let byteCount: Int
    let modifiedAt: Date?
    let revision: String?
    let isFile: Bool

    init(_ data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudFileProviderError.unsupportedOperation(provider: .oneDrive)
        }
        try self.init(json)
    }

    init(_ json: [String: Any]) throws {
        guard let id = json["id"] as? String else {
            throw CloudFileProviderError.unsupportedOperation(provider: .oneDrive)
        }
        let name = json["name"] as? String ?? ""
        let parentPath = (json["parentReference"] as? [String: Any])?["path"] as? String ?? ""
        self.id = id
        self.name = name
        self.path = Self.combinedPath(parentPath: parentPath, name: name)
        self.byteCount = Self.intValue(json["size"])
        self.modifiedAt = (json["lastModifiedDateTime"] as? String).flatMap(Self.dateValue)
        self.revision = (json["eTag"] as? String) ?? (json["cTag"] as? String)
        self.isFile = json["file"] != nil && json["folder"] == nil
    }

    var cloudFileItem: CloudFileItem {
        CloudFileItem(
            id: id,
            name: name,
            path: path,
            byteCount: byteCount,
            modifiedAt: modifiedAt,
            sha256: nil,
            revision: revision
        )
    }

    /// Path relative to the OneDrive application folder, safe to show in the UI.
    var appFolderRelativePath: String {
        Self.appFolderRelativePath(from: path)
    }

    func backupDirectory(parentID: String?, parentPath: String) -> CloudFileBackupDirectory {
        let childPath = parentPath.isEmpty ? name : parentPath + "/" + name
        return CloudFileBackupDirectory(id: id, name: name, parentID: parentID, path: childPath)
    }

    private static func appFolderRelativePath(from combinedPath: String) -> String {
        var value = combinedPath
        for prefix in ["/drive/special/approot:", "/drive/root:"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
            break
        }
        if value.contains("/drive/") || value.contains(":") {
            value = ""
        }
        return CloudFileBackupDirectory.normalizedPath(value)
    }

    private static func combinedPath(parentPath: String, name: String) -> String {
        let trimmedParent = parentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedParent.isEmpty else { return name }
        if trimmedParent.hasSuffix("/") || trimmedParent.hasSuffix(":") {
            return trimmedParent + name
        }
        return trimmedParent + "/" + name
    }

    private static func intValue(_ value: Any?) -> Int {
        if let int = value as? Int {
            return int
        }
        if let double = value as? Double {
            return Int(double)
        }
        if let string = value as? String, let int = Int(string) {
            return int
        }
        return 0
    }

    private static func dateValue(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}

private extension URL {
    func appendingGraphPath(_ path: String) -> URL {
        let base = absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.hasPrefix("/") ? path : "/" + path
        return URL(string: base + suffix) ?? self
    }
}
