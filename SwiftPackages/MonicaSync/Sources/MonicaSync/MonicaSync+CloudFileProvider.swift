// MARK: - 云文件供应商核心（种类 / 错误 / 条目模型 / 协议）

import Foundation

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
