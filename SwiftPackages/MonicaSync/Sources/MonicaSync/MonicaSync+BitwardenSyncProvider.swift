// MARK: - Bitwarden 同步提供者抽象（协议 / 默认实现 / 错误）

import Foundation

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
