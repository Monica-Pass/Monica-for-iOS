//
//  GoogleDriveCloudFileProvider.swift
//  MonicaSync
//
//  Google Drive REST v3 implementation of `CloudFileBrowser` and
//  `CloudFileProvider`. Listing uses `files.list` with `spaces=drive`, the
//  least-privilege `drive.file` scope and opaque `nextPageToken` paging.
//  Uploads are conditional on the Drive revision (`If-Match`) so a stale save
//  is rejected with HTTP 412 instead of overwriting someone else's edit.
//

import Foundation

public struct GoogleDriveCloudFileBrowser: CloudFileBrowser {
    public static let folderMIMEType = "application/vnd.google-apps.folder"
    public static let metadataFields = "id,name,mimeType,size,modifiedTime,version,md5Checksum,parents,trashed"

    public let kind: CloudFileBrowserKind = .googleDrive
    public let configuration: GoogleDriveConfiguration

    private let tokenProvider: any GoogleDriveAccessTokenProvider
    private let transport: any GoogleDriveHTTPTransport
    private let maximumAttempts: Int
    private let retryDelay: @Sendable (Int) async -> Void

    public init(
        configuration: GoogleDriveConfiguration,
        tokenProvider: any GoogleDriveAccessTokenProvider = EmptyGoogleDriveAccessTokenProvider(),
        transport: any GoogleDriveHTTPTransport = URLSessionGoogleDriveHTTPTransport(),
        maximumAttempts: Int = 3,
        retryDelay: @escaping @Sendable (Int) async -> Void = { attempt in
            let seconds = UInt64(min(30, 1 << min(attempt, 5)))
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        }
    ) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.maximumAttempts = max(1, maximumAttempts)
        self.retryDelay = retryDelay
    }

    public var availability: CloudFileBrowserAvailability {
        configuration.isConfigured
            ? .available
            : .notConfigured(reason: configuration.notConfiguredReason)
    }

    public func connectionState() async throws -> CloudFileConnectionState {
        guard configuration.isConfigured else {
            return .disconnected
        }
        do {
            _ = try await tokenProvider.accessToken()
            return .connected(accountLabel: "Google Drive")
        } catch let error as CloudFileProviderError {
            if case .authenticationRequired = error {
                return .disconnected
            }
            throw error
        }
    }

    // MARK: Browse

    public func browse(
        directoryID: String?,
        pageToken: String?,
        pageSize: Int,
        filter: CloudFileBrowserFilter
    ) async throws -> CloudFileBrowserPage {
        try requireConfigured()
        let limit = max(1, min(pageSize, configuration.maximumPageSize))
        var query: [String: String] = [
            "q": Self.query(directoryID: directoryID, filter: filter),
            "pageSize": "\(limit)",
            "fields": "nextPageToken,files(\(Self.metadataFields))",
            "orderBy": "folder,name",
            "spaces": "drive",
            "includeItemsFromAllDrives": "false",
            "supportsAllDrives": "false"
        ]
        if let pageToken, !pageToken.isEmpty {
            query["pageToken"] = pageToken
        }
        let response = try await send(
            method: "GET",
            url: try apiURL(path: "files", query: query),
            accept: "application/json"
        )
        try validate(response, allowedStatusCodes: [200])
        let page = try Self.parsePage(response.body)
        let entries = page.entries.filter { entry in
            entry.isDirectory || filter.includesFile(named: entry.name)
        }
        return CloudFileBrowserPage(entries: entries, nextPageToken: page.nextPageToken)
    }

    public func download(entryID: String) async throws -> CloudFileDownload {
        try requireConfigured()
        let metadataResponse = try await send(
            method: "GET",
            url: try apiURL(path: "files/\(entryID)", query: ["fields": Self.metadataFields]),
            accept: "application/json"
        )
        try validate(metadataResponse, allowedStatusCodes: [200])
        let entry = try Self.parseEntry(metadataResponse.body)
        guard !entry.isDirectory else {
            throw CloudFileBrowserError.notAFile(kind: kind)
        }
        let contentResponse = try await send(
            method: "GET",
            url: try apiURL(path: "files/\(entryID)", query: ["alt": "media"]),
            accept: "application/octet-stream"
        )
        try validate(contentResponse, allowedStatusCodes: [200])
        return CloudFileDownload(
            item: CloudFileItem(
                id: entry.id,
                name: entry.name,
                path: entry.path,
                byteCount: contentResponse.body.count,
                modifiedAt: entry.modifiedAt,
                sha256: nil,
                revision: entry.revision
            ),
            data: contentResponse.body,
            sha256: contentResponse.body.monicaCloudBrowserSHA256Hex,
            revision: entry.revision ?? contentResponse.headerValue("ETag")
        )
    }

    // MARK: Upload

    public func upload(
        named fileName: String,
        data: Data,
        in directoryID: String?,
        expectedRevision: String?
    ) async throws -> CloudFileBrowserWriteReceipt {
        try requireConfigured()
        let safeName = CloudFileKeePassFile.sanitizedName(fileName)
        guard !safeName.isEmpty, CloudFileKeePassFile.isKeePassDatabaseName(safeName) else {
            throw CloudFileBrowserError.invalidFileName(kind: kind)
        }
        if let expectedRevision, !expectedRevision.isEmpty {
            guard let existing = try await findEntry(named: safeName, in: directoryID) else {
                throw CloudFileProviderError.itemNotFound(provider: .googleDrive)
            }
            return try await overwrite(entryID: existing.id, data: data, expectedRevision: expectedRevision)
        }

        let boundary = "monica-kdbx-\(UUID().uuidString)"
        var metadata: [String: Any] = ["name": safeName]
        if let directoryID, !directoryID.isEmpty {
            metadata["parents"] = [directoryID]
        }
        let body = try Self.multipartBody(
            boundary: boundary,
            metadata: metadata,
            fileData: data,
            fileName: safeName
        )
        let response = try await send(
            method: "POST",
            url: try uploadURL(
                path: "files",
                query: [
                    "uploadType": "multipart",
                    "fields": Self.metadataFields
                ]
            ),
            headers: ["Content-Type": "multipart/related; boundary=\(boundary)"],
            body: body,
            accept: "application/json"
        )
        try validate(response, allowedStatusCodes: [200, 201])
        let entry = try Self.parseEntry(response.body)
        return CloudFileBrowserWriteReceipt(
            kind: kind,
            itemID: entry.id,
            name: entry.name.isEmpty ? safeName : entry.name,
            byteCount: data.count,
            sha256: data.monicaCloudBrowserSHA256Hex,
            revision: entry.revision ?? response.headerValue("ETag")
        )
    }

    public func overwrite(
        entryID: String,
        data: Data,
        expectedRevision: String?
    ) async throws -> CloudFileBrowserWriteReceipt {
        try requireConfigured()
        var headers = ["Content-Type": "application/octet-stream"]
        if let expectedRevision, !expectedRevision.isEmpty {
            headers["If-Match"] = expectedRevision
        }
        let response = try await send(
            method: "PATCH",
            url: try uploadURL(
                path: "files/\(entryID)",
                query: [
                    "uploadType": "media",
                    "fields": Self.metadataFields
                ]
            ),
            headers: headers,
            body: data,
            accept: "application/json"
        )
        if response.statusCode == 409 || response.statusCode == 412 {
            throw CloudFileProviderError.conflict(provider: .googleDrive)
        }
        try validate(response, allowedStatusCodes: [200, 201])
        let entry = try Self.parseEntry(response.body)
        return CloudFileBrowserWriteReceipt(
            kind: kind,
            itemID: entry.id.isEmpty ? entryID : entry.id,
            name: entry.name,
            byteCount: data.count,
            sha256: data.monicaCloudBrowserSHA256Hex,
            revision: entry.revision ?? response.headerValue("ETag")
        )
    }

    // MARK: Delete / rename

    public func delete(entryID: String) async throws {
        try requireConfigured()
        let response = try await send(
            method: "DELETE",
            url: try apiURL(path: "files/\(entryID)", query: [:])
        )
        if response.statusCode == 404 {
            throw CloudFileProviderError.itemNotFound(provider: .googleDrive)
        }
        try validate(response, allowedStatusCodes: [200, 204])
    }

    public func rename(entryID: String, to newName: String) async throws -> String {
        try requireConfigured()
        let safeName = CloudFileKeePassFile.sanitizedName(newName)
        guard !safeName.isEmpty else {
            throw CloudFileBrowserError.invalidFileName(kind: kind)
        }
        let payload = try JSONSerialization.data(withJSONObject: ["name": safeName])
        let response = try await send(
            method: "PATCH",
            url: try apiURL(path: "files/\(entryID)", query: ["fields": Self.metadataFields]),
            headers: ["Content-Type": "application/json; charset=UTF-8"],
            body: payload,
            accept: "application/json"
        )
        try validate(response, allowedStatusCodes: [200])
        let entry = try Self.parseEntry(response.body)
        return entry.name.isEmpty ? safeName : entry.name
    }

    // MARK: CloudFileProvider surface

    /// Root listing used by the legacy provider protocol. The KeePass app entry
    /// point uses `browse` so it can navigate folders and show the version
    /// marker for conflict detection.
    public func listFiles(filter: CloudFileBrowserFilter = .keePassOnly) async throws -> [CloudFileItem] {
        var items: [CloudFileItem] = []
        var token: String?
        repeat {
            let page = try await browse(
                directoryID: nil,
                pageToken: token,
                pageSize: CloudFileBrowserBrowserDefaults.pageSize,
                filter: filter
            )
            for entry in page.entries where !entry.isDirectory {
                items.append(
                    CloudFileItem(
                        id: entry.id,
                        name: entry.name,
                        path: entry.path,
                        byteCount: entry.byteCount,
                        modifiedAt: entry.modifiedAt,
                        sha256: entry.sha256,
                        revision: entry.revision
                    )
                )
            }
            token = page.nextPageToken
        } while token?.isEmpty == false
        return items
    }

    // MARK: Requests

    private func requireConfigured() throws {
        guard configuration.isConfigured else {
            throw CloudFileProviderError.notConfigured(provider: .googleDrive)
        }
    }

    private func send(
        method: String,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        accept: String? = nil
    ) async throws -> GoogleDriveHTTPResponse {
        var attempt = 0
        var didRefresh = false
        while true {
            attempt += 1
            let token = try await tokenProvider.accessToken()
            var requestHeaders = headers
            requestHeaders["Authorization"] = "Bearer \(token)"
            if let accept {
                requestHeaders["Accept"] = accept
            }
            do {
                let response = try await transport.send(
                    GoogleDriveHTTPRequest(method: method, url: url, headers: requestHeaders, body: body)
                )
                if response.statusCode == 401, !didRefresh {
                    didRefresh = true
                    _ = try await tokenProvider.refreshAccessToken()
                    continue
                }
                if Self.isRetryableStatus(response.statusCode), attempt < maximumAttempts {
                    await retryDelay(attempt)
                    continue
                }
                return response
            } catch let error as URLError {
                guard Self.isRetryableTransportError(error), attempt < maximumAttempts else {
                    throw error
                }
                await retryDelay(attempt)
            }
        }
    }

    private func validate(_ response: GoogleDriveHTTPResponse, allowedStatusCodes: Set<Int>) throws {
        if response.statusCode == 401 || response.statusCode == 403 {
            throw CloudFileProviderError.authenticationRequired(provider: .googleDrive)
        }
        if response.statusCode == 404 {
            throw CloudFileProviderError.itemNotFound(provider: .googleDrive)
        }
        if response.statusCode == 409 || response.statusCode == 412 {
            throw CloudFileProviderError.conflict(provider: .googleDrive)
        }
        guard allowedStatusCodes.contains(response.statusCode) else {
            throw CloudFileProviderError.unsupportedOperation(provider: .googleDrive)
        }
    }

    private static func isRetryableStatus(_ statusCode: Int) -> Bool {
        [408, 429, 500, 502, 503, 504].contains(statusCode)
    }

    private static func isRetryableTransportError(_ error: URLError) -> Bool {
        [
            .timedOut,
            .networkConnectionLost,
            .notConnectedToInternet,
            .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed,
            .secureConnectionFailed,
            .internationalRoamingOff,
            .dataNotAllowed
        ].contains(error.code)
    }

    // MARK: URLs

    private func apiURL(path: String, query: [String: String]) throws -> URL {
        try Self.url(base: configuration.apiBaseURL, path: path, query: query)
    }

    private func uploadURL(path: String, query: [String: String]) throws -> URL {
        try Self.url(base: configuration.uploadBaseURL, path: path, query: query)
    }

    private static func url(base: URL, path: String, query: [String: String]) throws -> URL {
        let components = path.split(separator: "/").map(String.init)
        var url = base
        for component in components {
            url.appendPathComponent(component)
        }
        guard var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw CloudFileProviderError.unsupportedOperation(provider: .googleDrive)
        }
        if !query.isEmpty {
            urlComponents.queryItems = query
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let result = urlComponents.url else {
            throw CloudFileProviderError.unsupportedOperation(provider: .googleDrive)
        }
        return result
    }

    // MARK: Query building

    static func query(directoryID: String?, filter: CloudFileBrowserFilter) -> String {
        var clauses = ["trashed = false"]
        if let directoryID, !directoryID.isEmpty {
            clauses.append("'\(escape(directoryID))' in parents")
        }
        switch filter {
        case .all:
            break
        case .keePassOnly:
            clauses.append("(mimeType = '\(folderMIMEType)' or name contains '.kdbx')")
        }
        return clauses.joined(separator: " and ")
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    /// Finds an existing file with the given name in the directory; used when a
    /// conditional save is requested without a known entry ID.
    private func findEntry(named name: String, in directoryID: String?) async throws -> CloudFileBrowserEntry? {
        var token: String?
        repeat {
            let page = try await browse(
                directoryID: directoryID,
                pageToken: token,
                pageSize: CloudFileBrowserBrowserDefaults.pageSize,
                filter: .all
            )
            if let match = page.entries.first(where: { !$0.isDirectory && $0.name == name }) {
                return match
            }
            token = page.nextPageToken
        } while token?.isEmpty == false
        return nil
    }

    // MARK: Multipart

    static func multipartBody(boundary: String, metadata: [String: Any], fileData: Data, fileName: String) throws -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(try JSONSerialization.data(withJSONObject: metadata))
        body.append(Data("\r\n--\(boundary)\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    // MARK: Parsing

    struct Page {
        let entries: [CloudFileBrowserEntry]
        let nextPageToken: String?
    }

    static func parsePage(_ data: Data) throws -> Page {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudFileProviderError.unsupportedOperation(provider: .googleDrive)
        }
        let files = root["files"] as? [[String: Any]] ?? []
        let entries = try files.map(parseEntry)
        return Page(entries: entries, nextPageToken: root["nextPageToken"] as? String)
    }

    static func parseEntry(_ data: Data) throws -> CloudFileBrowserEntry {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudFileProviderError.unsupportedOperation(provider: .googleDrive)
        }
        return try parseEntry(json)
    }

    static func parseEntry(_ json: [String: Any]) throws -> CloudFileBrowserEntry {
        guard let id = json["id"] as? String else {
            throw CloudFileProviderError.unsupportedOperation(provider: .googleDrive)
        }
        let name = json["name"] as? String ?? ""
        let mimeType = json["mimeType"] as? String ?? ""
        let isDirectory = mimeType == folderMIMEType
        return CloudFileBrowserEntry(
            id: id,
            name: name,
            path: name,
            isDirectory: isDirectory,
            byteCount: intValue(json["size"]),
            modifiedAt: dateValue(json["modifiedTime"]),
            revision: stringValue(json["version"]),
            sha256: nil
        )
    }

    private static func intValue(_ value: Any?) -> Int {
        if let string = value as? String, let int = Int(string) {
            return int
        }
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return 0
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func dateValue(_ value: Any?) -> Date? {
        guard let string = value as? String, !string.isEmpty else {
            return nil
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}

/// `CloudFileProvider` conformance so the existing app flows (refresh, restore
/// preview, write-back) can use Google Drive like OneDrive.
public struct GoogleDriveCloudFileProvider: CloudFileProvider {
    public let kind: CloudFileProviderKind = .googleDrive
    public let browser: GoogleDriveCloudFileBrowser

    public init(browser: GoogleDriveCloudFileBrowser) {
        self.browser = browser
    }

    public init(
        configuration: GoogleDriveConfiguration,
        tokenProvider: any GoogleDriveAccessTokenProvider = EmptyGoogleDriveAccessTokenProvider(),
        transport: any GoogleDriveHTTPTransport = URLSessionGoogleDriveHTTPTransport()
    ) {
        self.browser = GoogleDriveCloudFileBrowser(
            configuration: configuration,
            tokenProvider: tokenProvider,
            transport: transport
        )
    }

    public func connectionState() async throws -> CloudFileConnectionState {
        try await browser.connectionState()
    }

    public func listFiles() async throws -> [CloudFileItem] {
        try await browser.listFiles()
    }

    public func downloadFile(id: String) async throws -> CloudFileDownload {
        try await browser.download(entryID: id)
    }

    public func uploadFile(named fileName: String, data: Data) async throws -> CloudFileWriteReceipt {
        let receipt = try await browser.upload(named: fileName, data: data, in: nil, expectedRevision: nil)
        return CloudFileWriteReceipt(
            provider: .googleDrive,
            itemID: receipt.itemID,
            name: receipt.name,
            byteCount: receipt.byteCount,
            sha256: receipt.sha256,
            revision: receipt.revision
        )
    }

    public func overwriteFile(
        id: String,
        data: Data,
        fileName: String,
        expectedRevision: String?
    ) async throws -> CloudFileWriteReceipt {
        let receipt = try await browser.overwrite(entryID: id, data: data, expectedRevision: expectedRevision)
        return CloudFileWriteReceipt(
            provider: .googleDrive,
            itemID: receipt.itemID.isEmpty ? id : receipt.itemID,
            name: receipt.name.isEmpty ? CloudFileKeePassFile.sanitizedName(fileName) : receipt.name,
            byteCount: receipt.byteCount,
            sha256: receipt.sha256,
            revision: receipt.revision
        )
    }

    public func deleteFile(id: String) async throws {
        try await browser.delete(entryID: id)
    }

    public func renameFile(id: String, newName: String) async throws -> String {
        try await browser.rename(entryID: id, to: newName)
    }
}
