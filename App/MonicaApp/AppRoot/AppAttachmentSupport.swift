//
//  AppAttachmentSupport.swift
//  Monica
//
//  附件内容状态、预览文件描述与预览错误。
//

import Foundation

struct AppAttachmentContentStatus: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case available
        case missing
        case unavailable
    }

    let state: State
    let value: String
    let detail: String
}

struct AppAttachmentPreviewFile: Sendable, Equatable {
    let fileURL: URL
    let displayFileName: String
    let byteCount: Int
}

enum AppAttachmentPreviewError: Error, Sendable, Equatable, LocalizedError {
    case contentEncryptionKeyUnavailable
    case previewFailed
    case contentWriteFailed

    var errorDescription: String? {
        switch self {
        case .contentEncryptionKeyUnavailable:
            return String(localized: "附件内容密钥尚未可用。")
        case .previewFailed:
            return String(localized: "附件预览准备失败。")
        case .contentWriteFailed:
            return String(localized: "附件内容写回失败。")
        }
    }
}
