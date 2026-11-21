//
//  AppImportExportFormatsSupport.swift
//  Monica
//
//  issue #37：CSV / JSON / Bitwarden / Aegis / Stratum 导入导出的预览与文档类型。
//

import MonicaStorage
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 格式导入预览：把 Storage 的解析结果收敛成 UI 需要的派生字段。
struct FormatImportPreview: Identifiable, Sendable {
    let id = UUID()
    let result: VaultImportResult
    let fileName: String?

    var formatName: String {
        result.detection.detectedFormat?.displayName ?? String(localized: "未知格式")
    }

    var items: [VaultTransferItem] { result.items }
    var itemCount: Int { result.items.count }
    var sourceItemCount: Int { result.sourceItemCount }
    var skippedItemCount: Int { result.skippedItemCount }
    var skippedDuplicateCount: Int { result.skippedDuplicateCount }
    var issues: [VaultImportIssue] { result.issues }
    var canImport: Bool { result.canImport }

    /// 加密文件：要么还没输入密码，要么刚才输错了密码。
    var needsPassword: Bool {
        if case .passwordRequired = result.detection.outcome {
            return true
        }
        return result.issues.contains { $0.code == .decryptionFailed }
    }

    var warnings: [String] { result.detection.warnings }
}

/// 导出文件包装：CSV 与 JSON 共用，内容已在 Storage 层转好（可能已加密）。
struct VaultExportDocument: FileDocument, Sendable {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .json] }

    var data: Data
    var contentType: UTType

    init(data: Data = Data(), contentType: UTType = .json) {
        self.data = data
        self.contentType = contentType
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        contentType = .json
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension VaultExportFormat {
    var contentType: UTType {
        switch self {
        case .csv:
            return .commaSeparatedText
        case .json:
            return .json
        }
    }
}
