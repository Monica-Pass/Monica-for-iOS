//
//  AppAccountTemplateSupport.swift
//  Monica
//
//  issue #127：常用账号模板的 UI 派生类型（导入预览、导出文档）。
//

import Foundation
import MonicaStorage
import SwiftUI
import UniformTypeIdentifiers

/// 模板导入预览：把 Storage 的校验摘要收敛成界面要展示的行。
struct AccountTemplateImportPreview: Identifiable, Sendable {
    let id = UUID()
    let summary: AccountTemplateImportSummary
    let fileName: String?

    var templates: [AccountTemplate] { summary.templates }
    var issues: [VaultImportIssue] { summary.issues }
    var canImport: Bool { summary.canImport }
    var itemCount: Int { summary.templates.count }
    var sourceItemCount: Int { summary.sourceTemplateCount }
    var skippedCount: Int { summary.skippedTemplateCount }
    var conflictCount: Int { summary.conflictCount }
    var isEmptyFile: Bool { summary.isEmptyFile }

    /// 文件声明的格式版本，用来在界面上显示「模板文件 v1」。
    var versionText: String {
        guard let version = summary.formatVersion else {
            return String(localized: "未知版本")
        }
        return "v\(version)"
    }

    /// 有冲突时让用户显式决定要不要覆盖。
    var hasConflicts: Bool { summary.conflictCount > 0 }
}

/// 模板导出文件包装：JSON 文档，和 #37 的 `VaultExportDocument` 同写法。
struct AccountTemplateExportDocument: FileDocument, Sendable {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
