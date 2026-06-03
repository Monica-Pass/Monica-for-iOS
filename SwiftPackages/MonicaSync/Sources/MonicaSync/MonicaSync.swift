import CryptoKit
import Foundation

public enum MonicaSyncBaseline {
    public static let firstBackupProvider = "WebDAV"
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

    public init(
        id: String,
        name: String,
        path: String,
        byteCount: Int,
        modifiedAt: Date? = nil,
        sha256: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.sha256 = sha256
    }

    public var redactedSummary: String {
        "\(sanitizedCloudFileName(name)) \(byteCount) 字节"
    }
}

public struct CloudFileDownload: Sendable, Equatable {
    public let item: CloudFileItem
    public let data: Data
    public let sha256: String

    public init(item: CloudFileItem, data: Data, sha256: String? = nil) {
        self.item = item
        self.data = data
        self.sha256 = sha256 ?? data.monicaSHA256Hex
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

    public init(
        provider: CloudFileProviderKind,
        itemID: String,
        name: String,
        byteCount: Int,
        sha256: String
    ) {
        self.provider = provider
        self.itemID = itemID
        self.name = name
        self.byteCount = byteCount
        self.sha256 = sha256
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
    func overwriteFile(id: String, data: Data, fileName: String) async throws -> CloudFileWriteReceipt
}

public struct OneDriveCloudFileProvider: CloudFileProvider {
    public let kind: CloudFileProviderKind = .oneDrive

    public init() {}

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

    public func overwriteFile(id: String, data: Data, fileName: String) async throws -> CloudFileWriteReceipt {
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
        throw CloudFileProviderError.authenticationRequired(provider: kind)
    }

    public func downloadFile(id: String) async throws -> CloudFileDownload {
        throw CloudFileProviderError.authenticationRequired(provider: kind)
    }

    public func uploadFile(named fileName: String, data: Data) async throws -> CloudFileWriteReceipt {
        throw CloudFileProviderError.authenticationRequired(provider: kind)
    }

    public func overwriteFile(id: String, data: Data, fileName: String) async throws -> CloudFileWriteReceipt {
        throw CloudFileProviderError.authenticationRequired(provider: kind)
    }
}

public enum CloudFileProviderError: Error, Sendable, Equatable, LocalizedError {
    case authenticationRequired(provider: CloudFileProviderKind)
    case itemNotFound(provider: CloudFileProviderKind)
    case unsupportedOperation(provider: CloudFileProviderKind)

    public var errorDescription: String? {
        switch self {
        case .authenticationRequired(let provider):
            "\(provider.displayName) 需要先登录。"
        case .itemNotFound(let provider):
            "\(provider.displayName) 未找到远端文件。"
        case .unsupportedOperation(let provider):
            "\(provider.displayName) 当前操作尚未接入。"
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
