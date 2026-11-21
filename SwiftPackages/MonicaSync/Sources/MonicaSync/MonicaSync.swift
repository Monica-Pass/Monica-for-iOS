import CommonCrypto
import CryptoKit
import Foundation
import Security
import argon2

public enum MonicaSyncBaseline {
    public static let firstBackupProvider = "WebDAV"
}

public struct BitwardenTokenRefreshRequest: Sendable, Equatable {
    public let identityURL: URL
    public let refreshToken: String

    public init(identityURL: URL, refreshToken: String) {
        self.identityURL = identityURL
        self.refreshToken = refreshToken
    }
}

public struct BitwardenTokenRefreshResult: Sendable, Equatable, Codable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: TimeInterval

    public init(accessToken: String, refreshToken: String?, expiresIn: TimeInterval) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
    }
}

public protocol BitwardenIdentityTokenTransport: Sendable {
    func refreshAccessToken(_ request: BitwardenTokenRefreshRequest) async throws -> BitwardenTokenRefreshResult
}

public struct RefreshingBitwardenAccessTokenProvider: Sendable {
    private let sessionStore: any BitwardenAuthenticationSessionStore
    private let identityTransport: any BitwardenIdentityTokenTransport
    private let now: @Sendable () -> Date

    public init(
        sessionStore: any BitwardenAuthenticationSessionStore,
        identityTransport: any BitwardenIdentityTokenTransport = URLSessionBitwardenIdentityTokenTransport(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sessionStore = sessionStore
        self.identityTransport = identityTransport
        self.now = now
    }

    public func accessToken() async throws -> String {
        guard let session = try sessionStore.loadSession() else {
            throw BitwardenSyncProviderError.authenticationRequired
        }
        guard session.isAccessTokenExpired(now: now()) else {
            return session.accessToken
        }
        guard let refreshToken = session.refreshToken, !refreshToken.isEmpty else {
            throw BitwardenSyncProviderError.authenticationRequired
        }
        let result = try await identityTransport.refreshAccessToken(
            BitwardenTokenRefreshRequest(identityURL: session.identityURL, refreshToken: refreshToken)
        )
        let refreshed = session.refreshed(
            accessToken: result.accessToken,
            refreshToken: result.refreshToken,
            expiresIn: result.expiresIn,
            now: now()
        )
        try sessionStore.saveSession(refreshed)
        return refreshed.accessToken
    }
}

public final class URLSessionBitwardenIdentityTokenTransport: BitwardenIdentityTokenTransport, @unchecked Sendable {
    private let session: URLSession
    private let decoder: JSONDecoder

    public init(session: URLSession = .shared, decoder: JSONDecoder = JSONDecoder()) {
        self.session = session
        self.decoder = decoder
    }

    public func refreshAccessToken(_ request: BitwardenTokenRefreshRequest) async throws -> BitwardenTokenRefreshResult {
        var components = URLComponents(url: request.identityURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = ([basePath, "connect/token"].filter { !$0.isEmpty }).joined(separator: "/")
        guard let url = components?.url else {
            throw BitwardenSyncProviderError.unsupportedOperation
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("desktop", forHTTPHeaderField: "Bitwarden-Client-Name")
        urlRequest.setValue("2025.9.1", forHTTPHeaderField: "Bitwarden-Client-Version")
        urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = formURLEncodedBody([
            ("grant_type", "refresh_token"),
            ("refresh_token", request.refreshToken),
            ("client_id", "desktop")
        ])
        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BitwardenSyncProviderError.unsupportedOperation
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw BitwardenSyncProviderError.authenticationRequired
        }
        let payload = try decoder.decode(BitwardenTokenRefreshPayload.self, from: data)
        return BitwardenTokenRefreshResult(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiresIn: TimeInterval(payload.expiresIn)
        )
    }

    private func formURLEncodedBody(_ pairs: [(String, String)]) -> Data {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))
        let encoded = pairs.map { key, value in
            let safeKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let safeValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(safeKey)=\(safeValue)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }
}

private struct BitwardenTokenRefreshPayload: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

public struct BitwardenVaultSyncRequest: Sendable, Equatable {
    public let method: String
    public let url: URL
    public let headers: [String: String]
    public let body: Data?

    public init(method: String, url: URL, headers: [String: String], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct BitwardenVaultSyncResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public struct BitwardenAttachmentUploadRequest: Sendable, Equatable {
    public let cipherRemoteID: String
    public let encryptedFileName: String
    public let encryptedKey: String
    public let encryptedContent: Data
    public let originalByteCount: Int
    public let mediaType: String

    public init(
        cipherRemoteID: String,
        encryptedFileName: String,
        encryptedKey: String,
        encryptedContent: Data,
        originalByteCount: Int,
        mediaType: String
    ) {
        self.cipherRemoteID = cipherRemoteID
        self.encryptedFileName = encryptedFileName
        self.encryptedKey = encryptedKey
        self.encryptedContent = encryptedContent
        self.originalByteCount = originalByteCount
        self.mediaType = mediaType
    }

    public var redactedSummary: String {
        "Bitwarden 附件待上传 \(encryptedContent.count) 字节"
    }
}

public struct BitwardenAttachmentUploadResult: Sendable, Equatable {
    public let attachmentRemoteID: String
    public let encryptedByteCount: Int

    public init(attachmentRemoteID: String, encryptedByteCount: Int) {
        self.attachmentRemoteID = attachmentRemoteID
        self.encryptedByteCount = encryptedByteCount
    }

    public var redactedSummary: String {
        "Bitwarden 附件已上传 \(encryptedByteCount) 字节"
    }
}

public struct BitwardenAttachmentDownloadRequest: Sendable, Equatable {
    public let cipherRemoteID: String
    public let attachmentRemoteID: String

    public init(cipherRemoteID: String, attachmentRemoteID: String) {
        self.cipherRemoteID = cipherRemoteID
        self.attachmentRemoteID = attachmentRemoteID
    }
}

public struct BitwardenAttachmentDownloadResult: Sendable, Equatable {
    public let encryptedContent: Data

    public init(encryptedContent: Data) {
        self.encryptedContent = encryptedContent
    }

    public var redactedSummary: String {
        "Bitwarden 附件已下载 \(encryptedContent.count) 字节"
    }
}

public protocol BitwardenSyncProvider: Sendable {
    func pullSnapshot() async throws -> BitwardenSyncSnapshot
    /// 远端最新修订标记；不支持增量查询的实现返回 nil。
    func latestRevision() async throws -> BitwardenSyncRevision?
    /// 带增量判断的拉取：远端修订没有变化时返回 `.unchanged`，避免整库重复导入。
    func pullSnapshot(ifChangedSince revision: BitwardenSyncRevision?) async throws -> BitwardenSyncPullOutcome
    func pushMutations(_ mutations: [BitwardenSyncMutation]) async throws -> BitwardenSyncPushResult
    func uploadAttachment(_ request: BitwardenAttachmentUploadRequest) async throws -> BitwardenAttachmentUploadResult
    func downloadAttachment(_ request: BitwardenAttachmentDownloadRequest) async throws -> BitwardenAttachmentDownloadResult
    /// 匿名接收一个 Send（不需要登录），用于「打开别人发来的链接」。
    func fetchSend(_ request: BitwardenSendFetchRequest) async throws -> BitwardenReceivedSend
    /// 创建文本型 Send，并返回可分享链接（链接里携带 key material）。
    func createTextSend(_ request: BitwardenTextSendCreateRequest) async throws -> BitwardenTextSendCreateResult
}

public extension BitwardenSyncProvider {
    func latestRevision() async throws -> BitwardenSyncRevision? {
        nil
    }

    func pullSnapshot(ifChangedSince revision: BitwardenSyncRevision?) async throws -> BitwardenSyncPullOutcome {
        .changed(snapshot: try await pullSnapshot(), revision: nil)
    }

    func uploadAttachment(_ request: BitwardenAttachmentUploadRequest) async throws -> BitwardenAttachmentUploadResult {
        throw BitwardenSyncProviderError.unsupportedOperation
    }

    func downloadAttachment(_ request: BitwardenAttachmentDownloadRequest) async throws -> BitwardenAttachmentDownloadResult {
        throw BitwardenSyncProviderError.unsupportedOperation
    }

    func fetchSend(_ request: BitwardenSendFetchRequest) async throws -> BitwardenReceivedSend {
        throw BitwardenSyncProviderError.unsupportedOperation
    }

    func createTextSend(_ request: BitwardenTextSendCreateRequest) async throws -> BitwardenTextSendCreateResult {
        throw BitwardenSyncProviderError.unsupportedOperation
    }
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
    case unsupportedKDF(Int)
    case twoFactorRequired
    case serverRejected(statusCode: Int)
    case invalidServerURL
    case invalidResponse
    /// Send 链接无效、已过期或已被查看次数耗尽。
    case sendUnavailable

    public var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            "Bitwarden 需要先登录。"
        case .unsupportedOperation:
            "Bitwarden 同步暂时无法执行该操作。"
        case .unsupportedKDF(let rawValue):
            "Bitwarden KDF \(rawValue) 暂时无法使用。"
        case .twoFactorRequired:
            "Bitwarden 需要两步验证，请完成验证后重试。"
        case .serverRejected(let statusCode):
            "Bitwarden 同步失败：服务器返回 \(statusCode)。"
        case .sendUnavailable:
            "Send 链接无效、已过期或已达最大查看次数。"
        case .invalidServerURL:
            "Bitwarden 服务器 URL 无效，仅支持 http/https。"
        case .invalidResponse:
            "Bitwarden 同步响应无法解析。"
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

func sanitizedBitwardenTitle(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "未命名" : trimmed
}

func sanitizedBitwardenText(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
}

func normalizedBitwardenAccountLabel(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

func jsonString(_ json: [String: Any], _ keys: String...) -> String? {
    for key in keys {
        if let value = json[key] as? String {
            return value
        }
        if let number = json[key] as? NSNumber {
            return number.stringValue
        }
    }
    return nil
}

func jsonInt(_ json: [String: Any], _ keys: String...) -> Int? {
    for key in keys {
        if let value = json[key] as? Int {
            return value
        }
        if let value = json[key] as? Double {
            return Int(value)
        }
        if let value = json[key] as? NSNumber {
            return value.intValue
        }
        if let value = json[key] as? String, let intValue = Int(value) {
            return intValue
        }
    }
    return nil
}

extension Data {
    init?(bitwardenBase64Encoded value: String) {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        self.init(base64Encoded: padded)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension URL {
    func appendingBitwardenPath(_ path: String) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = "/" + ([basePath, path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))]
            .filter { !$0.isEmpty }
            .joined(separator: "/"))
        components?.queryItems = nil
        return components?.url ?? self
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

public struct CloudFileDeleteReceipt: Sendable, Equatable {
    public let provider: CloudFileProviderKind
    public let itemID: String

    public init(provider: CloudFileProviderKind, itemID: String) {
        self.provider = provider
        self.itemID = itemID
    }

    public var redactedSummary: String {
        "\(provider.displayName) 已删除远端文件"
    }
}

public protocol CloudFileProvider: Sendable {
    var kind: CloudFileProviderKind { get }

    func connectionState() async throws -> CloudFileConnectionState
    func listFiles() async throws -> [CloudFileItem]
    func downloadFile(id: String) async throws -> CloudFileDownload
    func uploadFile(named fileName: String, data: Data) async throws -> CloudFileWriteReceipt
    func overwriteFile(id: String, data: Data, fileName: String, expectedRevision: String?) async throws -> CloudFileWriteReceipt
    func deleteFile(id: String) async throws -> CloudFileDeleteReceipt
    func renameFile(id: String, newName: String) async throws -> CloudFileWriteReceipt
}

public extension CloudFileProvider {
    func overwriteFile(id: String, data: Data, fileName: String) async throws -> CloudFileWriteReceipt {
        try await overwriteFile(id: id, data: data, fileName: fileName, expectedRevision: nil)
    }

    func deleteFile(id: String) async throws -> CloudFileDeleteReceipt {
        throw CloudFileProviderError.unsupportedOperation(provider: kind)
    }

    func renameFile(id: String, newName: String) async throws -> CloudFileWriteReceipt {
        throw CloudFileProviderError.unsupportedOperation(provider: kind)
    }
}

public enum CloudFileProviderError: Error, Sendable, Equatable, LocalizedError {
    case authenticationRequired(provider: CloudFileProviderKind)
    case itemNotFound(provider: CloudFileProviderKind)
    case unsupportedOperation(provider: CloudFileProviderKind)
    case conflict(provider: CloudFileProviderKind)
    case invalidDirectoryName(provider: CloudFileProviderKind)
    /// The provider needs developer-portal configuration (client ID, URL
    /// scheme). The UI disables the provider instead of failing the whole list.
    case notConfigured(provider: CloudFileProviderKind)

    public var errorDescription: String? {
        switch self {
        case .authenticationRequired(let provider):
            "\(provider.displayName) 需要先登录。"
        case .itemNotFound(let provider):
            "\(provider.displayName) 未找到远端文件。"
        case .unsupportedOperation(let provider):
            "\(provider.displayName) 暂时无法执行该操作。"
        case .conflict(let provider):
            "\(provider.displayName) 远端文件已变化，请重新下载后再写回。"
        case .invalidDirectoryName(let provider):
            "\(provider.displayName) 目录名称无效，请使用字母、数字或空格。"
        case .notConfigured(let provider):
            "\(provider.displayName) 未配置，请先填写客户端 ID 与回调 scheme。"
        }
    }
}

func sanitizedCloudFileName(_ value: String) -> String {
    let normalized = value
        .replacingOccurrences(of: "\\", with: "/")
        .split(separator: "/")
        .last
        .map(String.init) ?? value
    let sanitized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    return sanitized.isEmpty ? "未命名文件" : sanitized
}

extension Data {
    var monicaSHA256Hex: String {
        SHA256.hash(data: self).map { byte in
            String(format: "%02x", byte)
        }.joined()
    }
}
