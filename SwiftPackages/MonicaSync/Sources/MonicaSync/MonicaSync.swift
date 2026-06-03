import CryptoKit
import Foundation

public enum MonicaSyncBaseline {
    public static let firstBackupProvider = "WebDAV"
}

public enum BitwardenSyncItemKind: String, Sendable, Equatable, Hashable {
    case login
    case secureNote
    case card
    case identity

    public var displayName: String {
        switch self {
        case .login:
            "login"
        case .secureNote:
            "note"
        case .card:
            "card"
        case .identity:
            "identity"
        }
    }
}

public struct BitwardenSyncItem: Sendable, Equatable, Identifiable {
    public var id: String { remoteID }

    public let remoteID: String
    public let kind: BitwardenSyncItemKind
    public let title: String
    public let username: String
    public let url: String
    public let password: String?
    public let totpSecret: String?
    public let notes: String?
    public let folderName: String?
    public let collectionNames: [String]
    public let attachmentByteCount: Int
    public let updatedAt: Date?

    public init(
        remoteID: String,
        kind: BitwardenSyncItemKind,
        title: String,
        username: String = "",
        url: String = "",
        password: String? = nil,
        totpSecret: String? = nil,
        notes: String? = nil,
        folderName: String? = nil,
        collectionNames: [String] = [],
        attachmentByteCount: Int = 0,
        updatedAt: Date? = nil
    ) {
        self.remoteID = remoteID
        self.kind = kind
        self.title = title
        self.username = username
        self.url = url
        self.password = password
        self.totpSecret = totpSecret
        self.notes = notes
        self.folderName = folderName
        self.collectionNames = collectionNames
        self.attachmentByteCount = attachmentByteCount
        self.updatedAt = updatedAt
    }

    public var redactedSummary: String {
        [
            kind.displayName,
            sanitizedBitwardenTitle(title),
            sanitizedBitwardenText(username),
            attachmentByteCount > 0 ? "\(attachmentByteCount) 字节附件" : ""
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }
}

public struct BitwardenSendSyncItem: Sendable, Equatable, Identifiable {
    public var id: String { remoteID }

    public let remoteID: String
    public let title: String
    public let body: String
    public let notes: String?
    public let expiresAt: String
    public let maxViews: Int
    public let attachmentByteCount: Int
    public let updatedAt: Date?

    public init(
        remoteID: String,
        title: String,
        body: String,
        notes: String? = nil,
        expiresAt: String = "",
        maxViews: Int = 1,
        attachmentByteCount: Int = 0,
        updatedAt: Date? = nil
    ) {
        self.remoteID = remoteID
        self.title = title
        self.body = body
        self.notes = notes
        self.expiresAt = expiresAt
        self.maxViews = maxViews
        self.attachmentByteCount = attachmentByteCount
        self.updatedAt = updatedAt
    }

    public var redactedSummary: String {
        [
            "Send",
            sanitizedBitwardenTitle(title),
            "\(maxViews) 次",
            attachmentByteCount > 0 ? "\(attachmentByteCount) 字节附件" : ""
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }
}

public struct BitwardenSyncSnapshot: Sendable, Equatable {
    public let accountLabel: String
    public let revision: String
    public let items: [BitwardenSyncItem]
    public let sends: [BitwardenSendSyncItem]

    public init(
        accountLabel: String,
        revision: String,
        items: [BitwardenSyncItem] = [],
        sends: [BitwardenSendSyncItem] = []
    ) {
        self.accountLabel = accountLabel
        self.revision = revision
        self.items = items
        self.sends = sends
    }

    public var redactedSummary: String {
        "Bitwarden \(sanitizedBitwardenText(accountLabel))：\(items.count) 个条目，\(sends.count) 个 Send"
    }
}

public enum BitwardenSyncMutation: Sendable, Equatable {
    case upsertSend(
        localID: String,
        remoteID: String?,
        title: String,
        body: String,
        notes: String?,
        expiresAt: String,
        maxViews: Int
    )
    case deleteSend(localID: String, remoteID: String?, title: String)

    public var redactedSummary: String {
        switch self {
        case .upsertSend(_, _, let title, _, _, _, let maxViews):
            "upsert Send \(sanitizedBitwardenTitle(title)) \(maxViews) 次"
        case .deleteSend(_, _, let title):
            "delete Send \(sanitizedBitwardenTitle(title))"
        }
    }
}

public enum BitwardenSyncConflictReason: Sendable, Equatable {
    case bothModified
    case remoteDeleted
    case localDeleted

    public var displayName: String {
        switch self {
        case .bothModified:
            "本地和远端都已修改"
        case .remoteDeleted:
            "远端已删除"
        case .localDeleted:
            "本地已删除"
        }
    }
}

public struct BitwardenSyncConflict: Sendable, Equatable {
    public let localID: String?
    public let remoteID: String?
    public let title: String
    public let reason: BitwardenSyncConflictReason

    public init(
        localID: String? = nil,
        remoteID: String? = nil,
        title: String,
        reason: BitwardenSyncConflictReason
    ) {
        self.localID = localID
        self.remoteID = remoteID
        self.title = title
        self.reason = reason
    }

    public var redactedSummary: String {
        "冲突 \(sanitizedBitwardenTitle(title))：\(reason.displayName)"
    }
}

public struct BitwardenSyncPushResult: Sendable, Equatable {
    public let acceptedMutationCount: Int
    public let conflicts: [BitwardenSyncConflict]
    public let revision: String

    public init(
        acceptedMutationCount: Int,
        conflicts: [BitwardenSyncConflict] = [],
        revision: String = ""
    ) {
        self.acceptedMutationCount = acceptedMutationCount
        self.conflicts = conflicts
        self.revision = revision
    }

    public var redactedSummary: String {
        "Bitwarden 已推送 \(acceptedMutationCount) 个变更，\(conflicts.count) 个冲突"
    }
}

public protocol BitwardenSyncProvider: Sendable {
    func pullSnapshot() async throws -> BitwardenSyncSnapshot
    func pushMutations(_ mutations: [BitwardenSyncMutation]) async throws -> BitwardenSyncPushResult
}

public struct DefaultBitwardenSyncProvider: BitwardenSyncProvider {
    public init() {}

    public func pullSnapshot() async throws -> BitwardenSyncSnapshot {
        throw BitwardenSyncProviderError.authenticationRequired
    }

    public func pushMutations(_ mutations: [BitwardenSyncMutation]) async throws -> BitwardenSyncPushResult {
        throw BitwardenSyncProviderError.authenticationRequired
    }
}

public enum BitwardenSyncProviderError: Error, Sendable, Equatable, LocalizedError {
    case authenticationRequired
    case unsupportedOperation

    public var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            "Bitwarden 需要先登录。"
        case .unsupportedOperation:
            "Bitwarden 同步当前操作尚未接入。"
        }
    }
}

public enum CloudFileProviderKind: String, Sendable, Equatable, Hashable, CaseIterable {
    case oneDrive
    case googleDrive

    public var displayName: String {
        switch self {
        case .oneDrive:
            "OneDrive"
        case .googleDrive:
            "Google Drive"
        }
    }

    public var defaultBackupFileName: String {
        switch self {
        case .oneDrive:
            "monica-onedrive.mdbx"
        case .googleDrive:
            "monica-google-drive.mdbx"
        }
    }
}

private func sanitizedBitwardenTitle(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "未命名" : trimmed
}

private func sanitizedBitwardenText(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
}

public enum CloudFileConnectionState: Sendable, Equatable {
    case disconnected
    case connected(accountLabel: String)
}

public struct CloudFileItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let path: String
    public let byteCount: Int
    public let modifiedAt: Date?
    public let sha256: String?
    public let revision: String?

    public init(
        id: String,
        name: String,
        path: String,
        byteCount: Int,
        modifiedAt: Date? = nil,
        sha256: String? = nil,
        revision: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.sha256 = sha256
        self.revision = revision
    }

    public var redactedSummary: String {
        "\(sanitizedCloudFileName(name)) \(byteCount) 字节"
    }
}

public struct CloudFileDownload: Sendable, Equatable {
    public let item: CloudFileItem
    public let data: Data
    public let sha256: String
    public let revision: String?

    public init(item: CloudFileItem, data: Data, sha256: String? = nil, revision: String? = nil) {
        self.item = item
        self.data = data
        self.sha256 = sha256 ?? data.monicaSHA256Hex
        self.revision = revision ?? item.revision
    }

    public var redactedSummary: String {
        "\(sanitizedCloudFileName(item.name)) \(data.count) 字节"
    }
}

public struct CloudFileWriteReceipt: Sendable, Equatable {
    public let provider: CloudFileProviderKind
    public let itemID: String
    public let name: String
    public let byteCount: Int
    public let sha256: String
    public let revision: String?

    public init(
        provider: CloudFileProviderKind,
        itemID: String,
        name: String,
        byteCount: Int,
        sha256: String,
        revision: String? = nil
    ) {
        self.provider = provider
        self.itemID = itemID
        self.name = name
        self.byteCount = byteCount
        self.sha256 = sha256
        self.revision = revision
    }

    public var redactedSummary: String {
        "\(provider.displayName) \(sanitizedCloudFileName(name)) \(byteCount) 字节"
    }
}

public protocol CloudFileProvider: Sendable {
    var kind: CloudFileProviderKind { get }

    func connectionState() async throws -> CloudFileConnectionState
    func listFiles() async throws -> [CloudFileItem]
    func downloadFile(id: String) async throws -> CloudFileDownload
    func uploadFile(named fileName: String, data: Data) async throws -> CloudFileWriteReceipt
    func overwriteFile(id: String, data: Data, fileName: String, expectedRevision: String?) async throws -> CloudFileWriteReceipt
}

public extension CloudFileProvider {
    func overwriteFile(id: String, data: Data, fileName: String) async throws -> CloudFileWriteReceipt {
        try await overwriteFile(id: id, data: data, fileName: fileName, expectedRevision: nil)
    }
}

public struct OneDriveCloudFileConfiguration: Sendable, Equatable {
    public let clientID: String
    public let redirectURI: URL
    public let scopes: [String]

    public init(
        clientID: String,
        redirectURI: URL,
        scopes: [String] = ["Files.ReadWrite.AppFolder"]
    ) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
    }

    public static let monicaProduction = OneDriveCloudFileConfiguration(
        clientID: "2aaf8c2c-b817-4085-9517-586a4a113dfc",
        redirectURI: URL(string: "msauth.com.monica-pass.monica://auth")!
    )

    public var redirectScheme: String {
        redirectURI.scheme ?? ""
    }

    public var redactedSummary: String {
        "OneDrive MSAL \(redirectScheme)"
    }
}

public struct OneDriveCloudFileProvider: CloudFileProvider {
    public let kind: CloudFileProviderKind = .oneDrive
    public let configuration: OneDriveCloudFileConfiguration

    public init(configuration: OneDriveCloudFileConfiguration = .monicaProduction) {
        self.configuration = configuration
    }

    public func connectionState() async throws -> CloudFileConnectionState {
        .disconnected
    }

    public func listFiles() async throws -> [CloudFileItem] {
        throw CloudFileProviderError.authenticationRequired(provider: kind)
    }

    public func downloadFile(id: String) async throws -> CloudFileDownload {
        throw CloudFileProviderError.authenticationRequired(provider: kind)
    }

    public func uploadFile(named fileName: String, data: Data) async throws -> CloudFileWriteReceipt {
        throw CloudFileProviderError.authenticationRequired(provider: kind)
    }

    public func overwriteFile(id: String, data: Data, fileName: String, expectedRevision: String? = nil) async throws -> CloudFileWriteReceipt {
        throw CloudFileProviderError.authenticationRequired(provider: kind)
    }
}

public struct GoogleDriveCloudFileProvider: CloudFileProvider {
    public let kind: CloudFileProviderKind = .googleDrive

    public init() {}

    public func connectionState() async throws -> CloudFileConnectionState {
        .disconnected
    }

    public func listFiles() async throws -> [CloudFileItem] {
        throw CloudFileProviderError.unsupportedOperation(provider: kind)
    }

    public func downloadFile(id: String) async throws -> CloudFileDownload {
        throw CloudFileProviderError.unsupportedOperation(provider: kind)
    }

    public func uploadFile(named fileName: String, data: Data) async throws -> CloudFileWriteReceipt {
        throw CloudFileProviderError.unsupportedOperation(provider: kind)
    }

    public func overwriteFile(id: String, data: Data, fileName: String, expectedRevision: String? = nil) async throws -> CloudFileWriteReceipt {
        throw CloudFileProviderError.unsupportedOperation(provider: kind)
    }
}

public enum CloudFileProviderError: Error, Sendable, Equatable, LocalizedError {
    case authenticationRequired(provider: CloudFileProviderKind)
    case itemNotFound(provider: CloudFileProviderKind)
    case unsupportedOperation(provider: CloudFileProviderKind)
    case conflict(provider: CloudFileProviderKind)

    public var errorDescription: String? {
        switch self {
        case .authenticationRequired(let provider):
            "\(provider.displayName) 需要先登录。"
        case .itemNotFound(let provider):
            "\(provider.displayName) 未找到远端文件。"
        case .unsupportedOperation(let provider):
            "\(provider.displayName) 当前操作尚未接入。"
        case .conflict(let provider):
            "\(provider.displayName) 远端文件已变化，请重新下载后再写回。"
        }
    }
}

public struct WebDAVEndpoint: Sendable, Equatable {
    public let baseURL: URL
    public let username: String
    public let password: String

    public init(
        baseURL: URL,
        username: String,
        password: String
    ) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
    }

    func url(for fileName: String) -> URL {
        baseURL.appendingPathComponent(fileName)
    }

    var authorizationHeader: String {
        let credentials = "\(username):\(password)"
        return "Basic \(Data(credentials.utf8).base64EncodedString())"
    }
}

public struct WebDAVBackupPackage: Sendable, Equatable {
    public let fileName: String
    public let data: Data
    public let sha256: String

    public init(fileName: String, data: Data) {
        self.fileName = fileName
        self.data = data
        self.sha256 = data.monicaSHA256Hex
    }
}

public struct WebDAVBackupReceipt: Sendable, Equatable {
    public let remoteURL: URL
    public let byteCount: Int
    public let sha256: String

    public init(remoteURL: URL, byteCount: Int, sha256: String) {
        self.remoteURL = remoteURL
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct WebDAVDownloadedBackup: Sendable, Equatable {
    public let fileName: String
    public let remoteURL: URL
    public let data: Data
    public let sha256: String

    public init(fileName: String, remoteURL: URL, data: Data, sha256: String) {
        self.fileName = fileName
        self.remoteURL = remoteURL
        self.data = data
        self.sha256 = sha256
    }
}

public struct WebDAVRestorePreview: Sendable, Equatable {
    public let fileName: String
    public let byteCount: Int
    public let sha256: String

    public init(_ backup: WebDAVDownloadedBackup) throws {
        self.fileName = backup.fileName
        self.byteCount = backup.data.count
        self.sha256 = backup.sha256
    }
}

public struct WebDAVTransportRequest: Sendable, Equatable {
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

public struct WebDAVTransportResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public protocol WebDAVTransport {
    func send(_ request: WebDAVTransportRequest) async throws -> WebDAVTransportResponse
}

public struct WebDAVClient {
    private let endpoint: WebDAVEndpoint
    private let transport: any WebDAVTransport

    public init(endpoint: WebDAVEndpoint, transport: any WebDAVTransport = URLSessionWebDAVTransport()) {
        self.endpoint = endpoint
        self.transport = transport
    }

    public func upload(_ package: WebDAVBackupPackage) async throws -> WebDAVBackupReceipt {
        let remoteURL = endpoint.url(for: package.fileName)
        let response = try await transport.send(
            WebDAVTransportRequest(
                method: "PUT",
                url: remoteURL,
                headers: [
                    "Authorization": endpoint.authorizationHeader,
                    "Content-Type": "application/octet-stream",
                    "X-Monica-Backup-SHA256": package.sha256
                ],
                body: package.data
            )
        )

        guard [200, 201, 204].contains(response.statusCode) else {
            throw WebDAVError.unexpectedStatus(operation: "upload", statusCode: response.statusCode)
        }

        let checksumResponse = try await transport.send(
            WebDAVTransportRequest(
                method: "PUT",
                url: endpoint.url(for: package.sidecarFileName),
                headers: [
                    "Authorization": endpoint.authorizationHeader,
                    "Content-Type": "text/plain; charset=utf-8"
                ],
                body: Data("\(package.sha256)\n".utf8)
            )
        )
        guard [200, 201, 204].contains(checksumResponse.statusCode) else {
            throw WebDAVError.unexpectedStatus(
                operation: "upload checksum",
                statusCode: checksumResponse.statusCode
            )
        }

        return WebDAVBackupReceipt(
            remoteURL: remoteURL,
            byteCount: package.data.count,
            sha256: package.sha256
        )
    }

    public func download(fileName: String) async throws -> WebDAVDownloadedBackup {
        let remoteURL = endpoint.url(for: fileName)
        let response = try await transport.send(
            WebDAVTransportRequest(
                method: "GET",
                url: remoteURL,
                headers: [
                    "Authorization": endpoint.authorizationHeader,
                    "Accept": "application/octet-stream"
                ]
            )
        )

        guard response.statusCode == 200 else {
            throw WebDAVError.unexpectedStatus(operation: "download", statusCode: response.statusCode)
        }

        let computedSHA256 = response.body.monicaSHA256Hex
        let expectedSHA256: String
        if let headerSHA256 = response.headerValue("X-Monica-Backup-SHA256") {
            expectedSHA256 = headerSHA256.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            expectedSHA256 = try await downloadSidecarChecksum(fileName: fileName)
        }

        if expectedSHA256.lowercased() != computedSHA256 {
            throw WebDAVError.integrityCheckFailed
        }

        return WebDAVDownloadedBackup(
            fileName: fileName,
            remoteURL: remoteURL,
            data: response.body,
            sha256: computedSHA256
        )
    }

    private func downloadSidecarChecksum(fileName: String) async throws -> String {
        let response = try await transport.send(
            WebDAVTransportRequest(
                method: "GET",
                url: endpoint.url(for: WebDAVBackupPackage.sidecarFileName(for: fileName)),
                headers: [
                    "Authorization": endpoint.authorizationHeader,
                    "Accept": "text/plain"
                ]
            )
        )

        guard response.statusCode == 200 else {
            throw WebDAVError.unexpectedStatus(
                operation: "download checksum",
                statusCode: response.statusCode
            )
        }

        guard let checksum = String(data: response.body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !checksum.isEmpty
        else {
            throw WebDAVError.integrityCheckFailed
        }

        return checksum
    }
}

private extension WebDAVBackupPackage {
    var sidecarFileName: String {
        Self.sidecarFileName(for: fileName)
    }

    static func sidecarFileName(for fileName: String) -> String {
        "\(fileName).sha256"
    }
}

public final class URLSessionWebDAVTransport: WebDAVTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: WebDAVTransportRequest) async throws -> WebDAVTransportResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        request.headers.forEach { key, value in
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVError.nonHTTPResponse
        }

        var headers: [String: String] = [:]
        httpResponse.allHeaderFields.forEach { key, value in
            guard let key = key as? String else {
                return
            }
            headers[key] = "\(value)"
        }

        return WebDAVTransportResponse(
            statusCode: httpResponse.statusCode,
            headers: headers,
            body: data
        )
    }
}

public enum WebDAVError: Error, Sendable, Equatable, LocalizedError {
    case unexpectedStatus(operation: String, statusCode: Int)
    case integrityCheckFailed
    case nonHTTPResponse

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let operation, let statusCode):
            return "WebDAV \(operation) 失败，HTTP 状态码 \(statusCode)。"
        case .integrityCheckFailed:
            return "WebDAV 备份完整性校验失败。"
        case .nonHTTPResponse:
            return "WebDAV 服务器返回了非 HTTP 响应。"
        }
    }
}

private extension WebDAVTransportResponse {
    func headerValue(_ name: String) -> String? {
        headers.first { key, _ in
            key.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }
}

private func sanitizedCloudFileName(_ value: String) -> String {
    let normalized = value
        .replacingOccurrences(of: "\\", with: "/")
        .split(separator: "/")
        .last
        .map(String.init) ?? value
    let sanitized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    return sanitized.isEmpty ? "未命名文件" : sanitized
}

private extension Data {
    var monicaSHA256Hex: String {
        SHA256.hash(data: self).map { byte in
            String(format: "%02x", byte)
        }.joined()
    }
}
