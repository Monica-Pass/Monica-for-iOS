// MARK: - Bitwarden 保险库同步传输模型（请求 / 响应 / 附件 / Send 拉取）

import Foundation

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
