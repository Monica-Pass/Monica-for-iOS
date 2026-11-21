//
//  CloudFileBrowser.swift
//  MonicaSync
//
//  Unified cloud file browsing for KeePass `.kdbx` databases.
//
//  The browser abstraction is intentionally thinner than `CloudFileProvider`: it
//  exposes directory listing with pagination, `.kdbx` filtering, downloads and
//  conditional uploads that carry the provider-specific version marker (ETag,
//  cTag or Google Drive revision). Adapters reuse the existing provider
//  transports and login state instead of re-implementing authentication.
//

import Foundation

/// Identifies a cloud file browser. WebDAV is browser-only: the legacy
/// `CloudFileProviderKind` enum keeps its OneDrive / Google Drive contract.
public enum CloudFileBrowserKind: String, Sendable, CaseIterable, Equatable {
    case oneDrive
    case googleDrive
    case webDAV

    public var displayName: String {
        switch self {
        case .oneDrive:
            return "OneDrive"
        case .googleDrive:
            return "Google Drive"
        case .webDAV:
            return "WebDAV"
        }
    }

    /// The matching `CloudFileProvider` when the browser can also save through
    /// the provider write-back path.
    public var cloudFileProviderKind: CloudFileProviderKind? {
        switch self {
        case .oneDrive:
            return .oneDrive
        case .googleDrive:
            return .googleDrive
        case .webDAV:
            return nil
        }
    }
}

/// Whether a browser can be used right now. Providers that need developer
/// portal configuration (Google Drive today) report `.notConfigured` and the UI
/// disables them without touching the working OneDrive / WebDAV paths.
public enum CloudFileBrowserAvailability: Sendable, Equatable {
    case available
    case notConfigured(reason: String)

    public var isAvailable: Bool {
        if case .available = self {
            return true
        }
        return false
    }

    public var unavailableReason: String? {
        if case .notConfigured(let reason) = self {
            return reason
        }
        return nil
    }
}

/// Which entries a page keeps. `keePassOnly` still returns directories so the
/// user can navigate; it only drops non-`.kdbx` files.
public enum CloudFileBrowserFilter: Sendable, Equatable {
    case all
    case keePassOnly

    func includesFile(named name: String) -> Bool {
        switch self {
        case .all:
            return true
        case .keePassOnly:
            return CloudFileKeePassFile.isKeePassDatabaseName(name)
        }
    }
}

public enum CloudFileKeePassFile {
    public static let fileExtension = "kdbx"

    public static func isKeePassDatabaseName(_ name: String) -> Bool {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasSuffix(".\(fileExtension)")
    }

    /// Providers reject paths, so keep only the last component.
    public static func sanitizedName(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? value
        let sanitized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "未命名文件" : sanitized
    }
}

public struct CloudFileBrowserEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let byteCount: Int
    public let modifiedAt: Date?
    public let revision: String?
    public let sha256: String?

    public init(
        id: String,
        name: String,
        path: String,
        isDirectory: Bool,
        byteCount: Int = 0,
        modifiedAt: Date? = nil,
        revision: String? = nil,
        sha256: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.byteCount = max(0, byteCount)
        self.modifiedAt = modifiedAt
        self.revision = revision
        self.sha256 = sha256
    }

    public var isKeePassDatabase: Bool {
        !isDirectory && CloudFileKeePassFile.isKeePassDatabaseName(name)
    }

    public var redactedSummary: String {
        if isDirectory {
            return "目录"
        }
        return "\(CloudFileKeePassFile.sanitizedName(name)) \(byteCount) 字节"
    }

    public var versionMarker: CloudFileVersionMarker {
        CloudFileVersionMarker(
            itemID: id,
            revision: revision,
            modifiedAt: modifiedAt,
            byteCount: byteCount
        )
    }
}

public struct CloudFileBrowserPage: Sendable, Equatable {
    public let entries: [CloudFileBrowserEntry]
    public let nextPageToken: String?
    public let totalCount: Int?

    public init(
        entries: [CloudFileBrowserEntry],
        nextPageToken: String? = nil,
        totalCount: Int? = nil
    ) {
        self.entries = entries
        self.nextPageToken = nextPageToken
        self.totalCount = totalCount
    }

    public var hasMore: Bool {
        guard let nextPageToken else {
            return false
        }
        return !nextPageToken.isEmpty
    }

    public var directories: [CloudFileBrowserEntry] {
        entries.filter(\.isDirectory)
    }

    public var keePassDatabases: [CloudFileBrowserEntry] {
        entries.filter(\.isKeePassDatabase)
    }

    public var files: [CloudFileBrowserEntry] {
        entries.filter { !$0.isDirectory }
    }
}

/// Version marker used to detect that a remote file changed between download
/// and upload. ETag / cTag / Drive revision are compared first; modified time
/// and size are fallbacks for providers without a strong validator.
public struct CloudFileVersionMarker: Sendable, Equatable {
    public let itemID: String
    public let revision: String?
    public let modifiedAt: Date?
    public let byteCount: Int

    public init(itemID: String, revision: String?, modifiedAt: Date?, byteCount: Int) {
        self.itemID = itemID
        self.revision = revision
        self.modifiedAt = modifiedAt
        self.byteCount = max(0, byteCount)
    }

    public init(item: CloudFileItem) {
        self.init(
            itemID: item.id,
            revision: item.revision,
            modifiedAt: item.modifiedAt,
            byteCount: item.byteCount
        )
    }

    public var isComparable: Bool {
        revision?.isEmpty == false || modifiedAt != nil
    }

    public func conflicts(with other: CloudFileVersionMarker) -> Bool {
        if let lhs = revision?.trimmingCharacters(in: .whitespacesAndNewlines),
           let rhs = other.revision?.trimmingCharacters(in: .whitespacesAndNewlines),
           !lhs.isEmpty,
           !rhs.isEmpty {
            return lhs != rhs
        }
        if let lhs = modifiedAt, let rhs = other.modifiedAt {
            return abs(lhs.timeIntervalSince(rhs)) >= 1
        }
        if byteCount > 0, other.byteCount > 0 {
            return byteCount != other.byteCount
        }
        return false
    }
}

public struct CloudFileBrowserWriteReceipt: Sendable, Equatable {
    public let kind: CloudFileBrowserKind
    public let itemID: String
    public let name: String
    public let byteCount: Int
    public let sha256: String
    public let revision: String?

    public init(
        kind: CloudFileBrowserKind,
        itemID: String,
        name: String,
        byteCount: Int,
        sha256: String,
        revision: String?
    ) {
        self.kind = kind
        self.itemID = itemID
        self.name = name
        self.byteCount = byteCount
        self.sha256 = sha256
        self.revision = revision
    }

    public var redactedSummary: String {
        "\(kind.displayName) \(CloudFileKeePassFile.sanitizedName(name)) \(byteCount) 字节"
    }
}

public enum CloudFileBrowserError: Error, Sendable, Equatable, LocalizedError {
    case invalidPageToken(kind: CloudFileBrowserKind)
    case notAFile(kind: CloudFileBrowserKind)
    case invalidFileName(kind: CloudFileBrowserKind)
    case unsupportedOperation(kind: CloudFileBrowserKind)

    public var errorDescription: String? {
        switch self {
        case .invalidPageToken(let kind):
            return "\(kind.displayName) 返回了无法识别的分页标记，请刷新目录。"
        case .notAFile(let kind):
            return "\(kind.displayName) 该条目不是文件，无法下载。"
        case .invalidFileName(let kind):
            return "\(kind.displayName) 文件名称无效，请使用字母、数字、空格或 .kdbx 后缀。"
        case .unsupportedOperation(let kind):
            return "\(kind.displayName) 不支持该操作。"
        }
    }
}

public protocol CloudFileBrowser: Sendable {
    var kind: CloudFileBrowserKind { get }
    var availability: CloudFileBrowserAvailability { get }

    func connectionState() async throws -> CloudFileConnectionState

    /// One page of a directory. `directoryID == nil` means the provider root.
    /// `pageToken` is the opaque `nextPageToken` of the previous page.
    func browse(
        directoryID: String?,
        pageToken: String?,
        pageSize: Int,
        filter: CloudFileBrowserFilter
    ) async throws -> CloudFileBrowserPage

    func download(entryID: String) async throws -> CloudFileDownload

    /// Conditional upload. When `expectedRevision` is non-nil the provider must
    /// reject the write with `CloudFileProviderError.conflict` if the remote
    /// version moved on (HTTP 412 / 409).
    func upload(
        named fileName: String,
        data: Data,
        in directoryID: String?,
        expectedRevision: String?
    ) async throws -> CloudFileBrowserWriteReceipt

    /// Conditional in-place update of an existing entry. This is the save path
    /// for a `.kdbx` the user opened: `expectedRevision` is the version marker
    /// captured at download time, and a mismatch must surface
    /// `CloudFileProviderError.conflict` (HTTP 412).
    func overwrite(
        entryID: String,
        data: Data,
        expectedRevision: String?
    ) async throws -> CloudFileBrowserWriteReceipt
}

public extension CloudFileBrowser {
    func browse(
        directoryID: String? = nil,
        pageToken: String? = nil,
        filter: CloudFileBrowserFilter = .keePassOnly
    ) async throws -> CloudFileBrowserPage {
        try await browse(
            directoryID: directoryID,
            pageToken: pageToken,
            pageSize: CloudFileBrowserBrowserDefaults.pageSize,
            filter: filter
        )
    }

    func upload(
        named fileName: String,
        data: Data,
        in directoryID: String? = nil,
        expectedRevision: String? = nil
    ) async throws -> CloudFileBrowserWriteReceipt {
        try await upload(
            named: fileName,
            data: data,
            in: directoryID,
            expectedRevision: expectedRevision
        )
    }
}

public enum CloudFileBrowserBrowserDefaults {
    public static let pageSize = 100
    public static let maximumPageSize = 1000
}

// MARK: - OneDrive adapter

/// Browses the OneDrive application folder through Microsoft Graph. Listing
/// pagination follows `@odata.nextLink`; uploads are conditional on the item
/// `eTag`.
public struct OneDriveCloudFileBrowser: CloudFileBrowser {
    public let kind: CloudFileBrowserKind = .oneDrive
    public let configuration: OneDriveCloudFileConfiguration

    private let tokenProvider: any OneDriveAccessTokenProvider
    private let transport: any OneDriveGraphTransport

    public init(
        configuration: OneDriveCloudFileConfiguration = .monicaProduction,
        tokenProvider: any OneDriveAccessTokenProvider = EmptyOneDriveAccessTokenProvider(),
        transport: any OneDriveGraphTransport = URLSessionOneDriveGraphTransport()
    ) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        self.transport = transport
    }

    public var availability: CloudFileBrowserAvailability {
        .available
    }

    public func connectionState() async throws -> CloudFileConnectionState {
        do {
            _ = try await tokenProvider.accessToken()
            return .connected(accountLabel: kind.displayName)
        } catch let error as CloudFileProviderError {
            if case .authenticationRequired = error {
                return .disconnected
            }
            throw error
        }
    }

    public func browse(
        directoryID: String?,
        pageToken: String?,
        pageSize: Int,
        filter: CloudFileBrowserFilter
    ) async throws -> CloudFileBrowserPage {
        let requestURL: URL
        if let pageToken, !pageToken.isEmpty {
            requestURL = try Self.decodePageToken(pageToken, configuration: configuration)
        } else {
            var components = URLComponents(
                url: try Self.childrenURL(directoryID: directoryID, configuration: configuration),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "$top", value: "\(max(1, min(pageSize, CloudFileBrowserBrowserDefaults.maximumPageSize)))")
            ]
            guard let url = components?.url else {
                throw CloudFileProviderError.unsupportedOperation(provider: .oneDrive)
            }
            requestURL = url
        }

        let response = try await send(
            method: "GET",
            url: requestURL,
            accept: "application/json"
        )
        try validate(response, allowedStatusCodes: [200])
        let page = try Self.parsePage(response.body)
        let filtered = page.entries.filter { entry in
            entry.isDirectory || filter.includesFile(named: entry.name)
        }
        return CloudFileBrowserPage(
            entries: filtered,
            nextPageToken: page.nextLink.map { Self.encodePageToken($0) }
        )
    }

    public func download(entryID: String) async throws -> CloudFileDownload {
        let metadataResponse = try await send(
            method: "GET",
            url: try Self.itemURL(for: entryID, configuration: configuration),
            accept: "application/json"
        )
        try validate(metadataResponse, allowedStatusCodes: [200])
        let entry = try Self.parseEntry(metadataResponse.body)
        guard !entry.isDirectory else {
            throw CloudFileBrowserError.notAFile(kind: kind)
        }

        let contentResponse = try await send(
            method: "GET",
            url: try Self.itemURL(for: entryID, configuration: configuration)
                .appendingPathComponent("content"),
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
            revision: entry.revision
        )
    }

    public func upload(
        named fileName: String,
        data: Data,
        in directoryID: String?,
        expectedRevision: String?
    ) async throws -> CloudFileBrowserWriteReceipt {
        let safeName = CloudFileKeePassFile.sanitizedName(fileName)
        guard !safeName.isEmpty, CloudFileKeePassFile.isKeePassDatabaseName(safeName) else {
            throw CloudFileBrowserError.invalidFileName(kind: .oneDrive)
        }

        var headers = ["Content-Type": "application/octet-stream"]
        if let expectedRevision, !expectedRevision.isEmpty {
            headers["If-Match"] = expectedRevision
        } else {
            headers["If-None-Match"] = "*"
        }
        let response = try await send(
            method: "PUT",
            url: try Self.uploadURL(
                directoryID: directoryID,
                fileName: safeName,
                configuration: configuration
            ),
            headers: headers
        )
        if response.statusCode == 409 || response.statusCode == 412 {
            throw CloudFileProviderError.conflict(provider: .oneDrive)
        }
        try validate(response, allowedStatusCodes: [200, 201])
        let entry = try Self.parseEntry(response.body)
        return CloudFileBrowserWriteReceipt(
            kind: kind,
            itemID: entry.id,
            name: entry.name.isEmpty ? safeName : entry.name,
            byteCount: data.count,
            sha256: data.monicaCloudBrowserSHA256Hex,
            revision: entry.revision
        )
    }

    public func overwrite(
        entryID: String,
        data: Data,
        expectedRevision: String?
    ) async throws -> CloudFileBrowserWriteReceipt {
        var headers = ["Content-Type": "application/octet-stream"]
        if let expectedRevision, !expectedRevision.isEmpty {
            headers["If-Match"] = expectedRevision
        }
        let response = try await send(
            method: "PUT",
            url: try Self.itemURL(for: entryID, configuration: configuration)
                .appendingPathComponent("content"),
            headers: headers,
            body: data
        )
        if response.statusCode == 409 || response.statusCode == 412 {
            throw CloudFileProviderError.conflict(provider: .oneDrive)
        }
        try validate(response, allowedStatusCodes: [200, 201])
        let entry = try Self.parseEntry(response.body)
        return CloudFileBrowserWriteReceipt(
            kind: kind,
            itemID: entry.id.isEmpty ? entryID : entry.id,
            name: entry.name,
            byteCount: data.count,
            sha256: data.monicaCloudBrowserSHA256Hex,
            revision: entry.revision ?? response.headerValue(named: "ETag")
        )
    }

    private func send(
        method: String,
        url: URL,
        headers: [String: String] = [:],
        accept: String? = nil,
        body: Data? = nil
    ) async throws -> OneDriveGraphResponse {
        let token = try await tokenProvider.accessToken()
        var requestHeaders = headers
        requestHeaders["Authorization"] = "Bearer \(token)"
        if let accept {
            requestHeaders["Accept"] = accept
        }
        return try await transport.send(
            OneDriveGraphRequest(method: method, url: url, headers: requestHeaders, body: body)
        )
    }

    private func validate(_ response: OneDriveGraphResponse, allowedStatusCodes: Set<Int>) throws {
        if response.statusCode == 401 || response.statusCode == 403 {
            throw CloudFileProviderError.authenticationRequired(provider: .oneDrive)
        }
        if response.statusCode == 404 {
            throw CloudFileProviderError.itemNotFound(provider: .oneDrive)
        }
        if response.statusCode == 412 {
            throw CloudFileProviderError.conflict(provider: .oneDrive)
        }
        guard allowedStatusCodes.contains(response.statusCode) else {
            throw CloudFileProviderError.unsupportedOperation(provider: .oneDrive)
        }
    }

    // MARK: URL construction

    private static func childrenURL(
        directoryID: String?,
        configuration: OneDriveCloudFileConfiguration
    ) throws -> URL {
        let path: String
        if let directoryID, !directoryID.isEmpty {
            path = "/me/drive/items/\(percentEncodePathComponent(directoryID))/children"
        } else {
            path = "/me/drive/special/approot/children"
        }
        guard let url = URL(string: graphBase(configuration) + path) else {
            throw CloudFileProviderError.unsupportedOperation(provider: .oneDrive)
        }
        return url
    }

    private static func itemURL(for itemID: String, configuration: OneDriveCloudFileConfiguration) throws -> URL {
        guard let url = URL(string: graphBase(configuration) + "/me/drive/items/\(percentEncodePathComponent(itemID))") else {
            throw CloudFileProviderError.unsupportedOperation(provider: .oneDrive)
        }
        return url
    }

    private static func uploadURL(
        directoryID: String?,
        fileName: String,
        configuration: OneDriveCloudFileConfiguration
    ) throws -> URL {
        let encodedName = percentEncodeGraphPath(fileName)
        let path: String
        if let directoryID, !directoryID.isEmpty {
            path = "/me/drive/items/\(percentEncodePathComponent(directoryID)):/\(encodedName):/content"
        } else {
            path = "/me/drive/special/approot:/\(encodedName):/content"
        }
        guard let url = URL(string: graphBase(configuration) + path) else {
            throw CloudFileProviderError.unsupportedOperation(provider: .oneDrive)
        }
        return url
    }

    private static func graphBase(_ configuration: OneDriveCloudFileConfiguration) -> String {
        configuration.graphBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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

    // MARK: Page tokens

    private static func encodePageToken(_ url: URL) -> String {
        Data(url.absoluteString.utf8).base64EncodedString()
    }

    private static func decodePageToken(
        _ token: String,
        configuration: OneDriveCloudFileConfiguration
    ) throws -> URL {
        guard let data = Data(base64Encoded: token),
              let value = String(data: data, encoding: .utf8),
              let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == configuration.graphBaseURL.host?.lowercased(),
              url.port == configuration.graphBaseURL.port
        else {
            throw CloudFileBrowserError.invalidPageToken(kind: .oneDrive)
        }
        return url
    }

    // MARK: Parsing

    private struct Page {
        let entries: [CloudFileBrowserEntry]
        let nextLink: URL?
    }

    private static func parsePage(_ data: Data) throws -> Page {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = root["value"] as? [[String: Any]]
        else {
            throw CloudFileProviderError.unsupportedOperation(provider: .oneDrive)
        }
        let entries = try values.map(parseEntry)
        let nextLink = (root["@odata.nextLink"] as? String).flatMap(URL.init(string:))
        return Page(entries: entries, nextLink: nextLink)
    }

    private static func parseEntry(_ data: Data) throws -> CloudFileBrowserEntry {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudFileProviderError.unsupportedOperation(provider: .oneDrive)
        }
        return try parseEntry(json)
    }

    private static func parseEntry(_ json: [String: Any]) throws -> CloudFileBrowserEntry {
        guard let id = json["id"] as? String else {
            throw CloudFileProviderError.unsupportedOperation(provider: .oneDrive)
        }
        let name = json["name"] as? String ?? ""
        let parentPath = (json["parentReference"] as? [String: Any])?["path"] as? String ?? ""
        let isDirectory = json["folder"] != nil && json["file"] == nil
        let revision = (json["eTag"] as? String) ?? (json["cTag"] as? String)
        let modifiedAt = (json["lastModifiedDateTime"] as? String).flatMap(ISO8601DateFormatter().date(from:))
        return CloudFileBrowserEntry(
            id: id,
            name: name,
            path: displayPath(parentPath: parentPath, name: name),
            isDirectory: isDirectory,
            byteCount: intValue(json["size"]),
            modifiedAt: modifiedAt,
            revision: revision
        )
    }

    private static func displayPath(parentPath: String, name: String) -> String {
        var parent = parentPath
        for prefix in ["/drive/special/approot:", "/drive/root:"] where parent.hasPrefix(prefix) {
            parent.removeFirst(prefix.count)
            break
        }
        if parent.contains("/drive/") {
            parent = ""
        }
        let trimmed = parent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty {
            return name
        }
        return trimmed + "/" + name
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
}

// MARK: - WebDAV adapter

/// Browses a WebDAV collection. WebDAV returns a whole directory in one PROPFIND
/// response, so pages are sliced locally while still exposing the same
/// `nextPageToken` contract as the cloud providers.
public struct WebDAVCloudFileBrowser: CloudFileBrowser, @unchecked Sendable {
    public let kind: CloudFileBrowserKind = .webDAV
    public let endpoint: WebDAVEndpoint

    private let transport: any WebDAVTransport

    public init(
        endpoint: WebDAVEndpoint,
        transport: any WebDAVTransport = URLSessionWebDAVTransport()
    ) {
        self.endpoint = endpoint
        self.transport = transport
    }

    public var availability: CloudFileBrowserAvailability {
        .available
    }

    public func connectionState() async throws -> CloudFileConnectionState {
        // Basic authentication is carried per request; probe the root so a wrong
        // password fails during connect instead of on first download.
        let response = try await transport.send(
            WebDAVTransportRequest(
                method: "PROPFIND",
                url: endpoint.baseURL,
                headers: [
                    "Authorization": endpoint.authorizationHeader,
                    "Depth": "0",
                    "Accept": "application/xml,text/xml"
                ]
            )
        )
        guard response.statusCode == 207 || response.statusCode == 200 else {
            throw WebDAVError.unexpectedStatus(operation: "connect", statusCode: response.statusCode)
        }
        return .connected(accountLabel: kind.displayName)
    }

    public func browse(
        directoryID: String?,
        pageToken: String?,
        pageSize: Int,
        filter: CloudFileBrowserFilter
    ) async throws -> CloudFileBrowserPage {
        let entries = try await loadEntries(directoryID: directoryID, filter: filter)
        let pageSize = max(1, min(pageSize, CloudFileBrowserBrowserDefaults.maximumPageSize))
        let offset: Int
        if let pageToken, !pageToken.isEmpty {
            guard let parsed = Int(pageToken), parsed >= 0 else {
                throw CloudFileBrowserError.invalidPageToken(kind: kind)
            }
            offset = min(parsed, entries.count)
        } else {
            offset = 0
        }
        let end = min(offset + pageSize, entries.count)
        let page = Array(entries[offset..<end])
        let nextToken = end < entries.count ? String(end) : nil
        return CloudFileBrowserPage(entries: page, nextPageToken: nextToken, totalCount: entries.count)
    }

    public func download(entryID: String) async throws -> CloudFileDownload {
        let fileName = CloudFileKeePassFile.sanitizedName(entryID)
        let url = try fileURL(relativePath: entryID, fallbackName: fileName)
        let response = try await transport.send(
            WebDAVTransportRequest(
                method: "GET",
                url: url,
                headers: [
                    "Authorization": endpoint.authorizationHeader,
                    "Accept": "application/octet-stream"
                ]
            )
        )
        guard response.statusCode == 200 else {
            throw WebDAVError.unexpectedStatus(operation: "download", statusCode: response.statusCode)
        }
        let revision = response.headerValue(named: "ETag")
        return CloudFileDownload(
            item: CloudFileItem(
                id: entryID,
                name: fileName,
                path: entryID,
                byteCount: response.body.count,
                modifiedAt: nil,
                sha256: nil,
                revision: revision
            ),
            data: response.body,
            sha256: response.body.monicaCloudBrowserSHA256Hex,
            revision: revision
        )
    }

    public func upload(
        named fileName: String,
        data: Data,
        in directoryID: String?,
        expectedRevision: String?
    ) async throws -> CloudFileBrowserWriteReceipt {
        let safeName = CloudFileKeePassFile.sanitizedName(fileName)
        guard !safeName.isEmpty, CloudFileKeePassFile.isKeePassDatabaseName(safeName) else {
            throw CloudFileBrowserError.invalidFileName(kind: .webDAV)
        }
        let relativePath = [directoryID, safeName]
            .compactMap { $0?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        let url = try fileURL(relativePath: relativePath, fallbackName: safeName)
        var headers = [
            "Authorization": endpoint.authorizationHeader,
            "Content-Type": "application/octet-stream"
        ]
        if let expectedRevision, !expectedRevision.isEmpty {
            headers["If-Match"] = expectedRevision
        } else {
            headers["If-None-Match"] = "*"
        }
        let response = try await transport.send(
            WebDAVTransportRequest(method: "PUT", url: url, headers: headers, body: data)
        )
        if response.statusCode == 409 || response.statusCode == 412 {
            // The conditional write lost the race: surface the shared conflict
            // error so the app offers "save a copy" instead of overwriting.
            throw CloudFileProviderError.conflict(provider: .oneDrive)
        }
        guard [200, 201, 204].contains(response.statusCode) else {
            throw WebDAVError.unexpectedStatus(operation: "upload", statusCode: response.statusCode)
        }
        return CloudFileBrowserWriteReceipt(
            kind: kind,
            itemID: relativePath,
            name: safeName,
            byteCount: data.count,
            sha256: data.monicaCloudBrowserSHA256Hex,
            revision: response.headerValue(named: "ETag")
        )
    }

    public func overwrite(
        entryID: String,
        data: Data,
        expectedRevision: String?
    ) async throws -> CloudFileBrowserWriteReceipt {
        let safeName = CloudFileKeePassFile.sanitizedName(entryID)
        guard !safeName.isEmpty, CloudFileKeePassFile.isKeePassDatabaseName(safeName) else {
            throw CloudFileBrowserError.invalidFileName(kind: kind)
        }
        let url = try fileURL(relativePath: entryID, fallbackName: safeName)
        var headers = [
            "Authorization": endpoint.authorizationHeader,
            "Content-Type": "application/octet-stream"
        ]
        if let expectedRevision, !expectedRevision.isEmpty {
            headers["If-Match"] = expectedRevision
        }
        let response = try await transport.send(
            WebDAVTransportRequest(method: "PUT", url: url, headers: headers, body: data)
        )
        if response.statusCode == 409 || response.statusCode == 412 {
            throw CloudFileProviderError.conflict(provider: .oneDrive)
        }
        guard [200, 201, 204].contains(response.statusCode) else {
            throw WebDAVError.unexpectedStatus(operation: "overwrite", statusCode: response.statusCode)
        }
        return CloudFileBrowserWriteReceipt(
            kind: kind,
            itemID: entryID,
            name: safeName,
            byteCount: data.count,
            sha256: data.monicaCloudBrowserSHA256Hex,
            revision: response.headerValue(named: "ETag")
        )
    }

    private func loadEntries(
        directoryID: String?,
        filter: CloudFileBrowserFilter
    ) async throws -> [CloudFileBrowserEntry] {
        let url = try directoryURL(relativePath: directoryID)
        let response = try await transport.send(
            WebDAVTransportRequest(
                method: "PROPFIND",
                url: url,
                headers: [
                    "Authorization": endpoint.authorizationHeader,
                    "Depth": "1",
                    "Accept": "application/xml,text/xml"
                ]
            )
        )
        guard response.statusCode == 207 || response.statusCode == 200 else {
            throw WebDAVError.unexpectedStatus(operation: "list", statusCode: response.statusCode)
        }
        let basePath = directoryID?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        return Self.parseEntries(from: response.body, basePath: basePath, requestedPath: url.path)
            .filter { $0.isDirectory || filter.includesFile(named: $0.name) }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private func directoryURL(relativePath: String?) throws -> URL {
        guard let relativePath, !relativePath.isEmpty else {
            return endpoint.baseURL
        }
        return relativePath
            .split(separator: "/")
            .reduce(endpoint.baseURL) { url, component in
                url.appendingPathComponent(String(component))
            }
    }

    private func fileURL(relativePath: String, fallbackName: String) throws -> URL {
        let components = relativePath
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !components.isEmpty else {
            throw CloudFileBrowserError.invalidFileName(kind: kind)
        }
        return components.reduce(endpoint.baseURL) { url, component in
            url.appendingPathComponent(component)
        }
    }

    // MARK: Parsing

    static func parseEntries(from data: Data, basePath: String, requestedPath: String = "") -> [CloudFileBrowserEntry] {
        let normalizedRequestedPath = requestedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let xml = String(data: data, encoding: .utf8) else {
            return []
        }
        return cloudBrowserRegexMatches(
            in: xml,
            pattern: #"<[^:>]*:?response\b[\s\S]*?</[^:>]*:?response>"#
        ).compactMap { response in
            guard let href = cloudBrowserFirstMatch(
                in: response,
                pattern: #"<[^:>]*:?href[^>]*>([\s\S]*?)</[^:>]*:?href>"#
            ) else {
                return nil
            }
            let decodedHref = href.removingPercentEncoding ?? href
            let name = decodedHref
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .split(separator: "/")
                .last
                .map(String.init) ?? decodedHref
            guard !name.isEmpty else {
                return nil
            }
            let isDirectory = cloudBrowserFirstMatch(
                in: response,
                pattern: #"<[^:>]*:?collection[\s/>]"#
            ) != nil || decodedHref.hasSuffix("/")
            // PROPFIND Depth 1 includes the requested collection itself.
            if decodedHref.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == normalizedRequestedPath {
                return nil
            }
            let relative = basePath.isEmpty ? name : basePath + "/" + name
            if !basePath.isEmpty, relative == basePath {
                return nil
            }
            let byteCount = cloudBrowserFirstMatch(
                in: response,
                pattern: #"<[^:>]*:?getcontentlength[^>]*>([\s\S]*?)</[^:>]*:?getcontentlength>"#
            ).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
            let modifiedAt = cloudBrowserFirstMatch(
                in: response,
                pattern: #"<[^:>]*:?getlastmodified[^>]*>([\s\S]*?)</[^:>]*:?getlastmodified>"#
            ).flatMap(cloudBrowserHTTPDate)
            let revision = cloudBrowserFirstMatch(
                in: response,
                pattern: #"<[^:>]*:?getetag[^>]*>([\s\S]*?)</[^:>]*:?getetag>"#
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            return CloudFileBrowserEntry(
                id: relative,
                name: isDirectory ? name : CloudFileKeePassFile.sanitizedName(name),
                path: relative,
                isDirectory: isDirectory,
                byteCount: byteCount,
                modifiedAt: modifiedAt,
                revision: revision
            )
        }
    }
}

// MARK: - Shared helpers

extension OneDriveGraphResponse {
    func headerValue(named name: String) -> String? {
        headers.first { key, _ in
            key.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }
}

private extension WebDAVTransportResponse {
    func headerValue(named name: String) -> String? {
        headers.first { key, _ in
            key.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }
}

private func cloudBrowserRegexMatches(in text: String, pattern: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return []
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: range).compactMap { result in
        guard let matchRange = Range(result.range, in: text) else {
            return nil
        }
        return String(text[matchRange])
    }
}

private func cloudBrowserFirstMatch(in text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return nil
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let result = regex.firstMatch(in: text, range: range),
          result.numberOfRanges > 1,
          let matchRange = Range(result.range(at: 1), in: text)
    else {
        return nil
    }
    return String(text[matchRange])
}

private func cloudBrowserHTTPDate(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: value.trimmingCharacters(in: .whitespacesAndNewlines))
}

extension Data {
    /// Stable checksum used for in-memory cloud file receipts.
    var monicaCloudBrowserSHA256Hex: String {
        CloudFileSHA256.hexDigest(self)
    }
}
