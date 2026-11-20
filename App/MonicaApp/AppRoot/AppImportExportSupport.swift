//
//  AppImportExportSupport.swift
//  Monica
//
//  导入导出（CSV / Android 备份 / KeePass）的预览、文档与写入服务类型。
//

import MonicaStorage
import MonicaSync
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct AppShareImportResult: Sendable, Equatable {
    let importedCounts: [UnifiedVaultItemKind: Int]
    let importedTitles: [String]

    var totalCount: Int {
        importedCounts.values.reduce(0, +)
    }
}

struct CSVImportPreview: Sendable, Equatable {
    let report: VaultCSVImportReport

    var items: [VaultCSVItemDraft] { report.items }
    var issues: [VaultCSVImportIssue] { report.issues }
}

struct AndroidBackupImportPreview: Sendable, Equatable {
    let report: AndroidBackupImportReport

    var items: [VaultCSVItemDraft] { report.items }
    var deletedItems: [AndroidBackupImportedItem] { report.deletedItems }
    var attachments: [AndroidBackupAttachmentMetadata] { report.attachments }
    var issues: [AndroidBackupImportIssue] { report.issues }
}

struct KeePassImportPreview: Sendable, Equatable {
    let report: KeePassImportPreviewReport
    let unlockPreflight: KeePassUnlockPreflightReport?

    var format: KeePassContainerFormat { report.format }
    var status: KeePassImportStatus { report.status }
    var headerSummary: KeePassHeaderSummary? { report.headerSummary }
    var issue: KeePassImportIssue? { report.issue }
}

struct AppKeePassImportedEntryReference: Sendable, Equatable {
    let sourceEntryID: String
    let sourceGroupID: String?
    let sourceGroupPath: String
    let importedLoginEntryID: String
    let importedTotpEntryID: String?
    let importedProjectID: String
    let importedAsDeleted: Bool
    let importedAttachmentEntryIDs: [String]

    init(
        sourceEntryID: String,
        sourceGroupID: String?,
        sourceGroupPath: String,
        importedLoginEntryID: String,
        importedTotpEntryID: String? = nil,
        importedProjectID: String,
        importedAsDeleted: Bool = false,
        importedAttachmentEntryIDs: [String] = []
    ) {
        self.sourceEntryID = sourceEntryID
        self.sourceGroupID = sourceGroupID
        self.sourceGroupPath = sourceGroupPath
        self.importedLoginEntryID = importedLoginEntryID
        self.importedTotpEntryID = importedTotpEntryID
        self.importedProjectID = importedProjectID
        self.importedAsDeleted = importedAsDeleted
        self.importedAttachmentEntryIDs = importedAttachmentEntryIDs
    }
}

struct AppKeePassAttachmentEditCandidate: Sendable, Equatable, Identifiable {
    let id: String
    let entryID: String
    let attachmentID: String
    let entryTitle: String
    let entryUsername: String
    let groupPath: String
    let fileName: String
    let mediaType: String
    let originalSize: Int64
    let isDeletedEntry: Bool
    let searchableText: String
}

struct AppKeePassKdbxWritebackResult: Sendable, Equatable {
    let database: Data
    let entryCount: Int
    let attachmentCount: Int

    init(database: Data, entryCount: Int, attachmentCount: Int) {
        self.database = database
        self.entryCount = entryCount
        self.attachmentCount = attachmentCount
    }

    init(_ result: KeePassKdbx3WritebackResult) {
        self.init(
            database: result.database,
            entryCount: result.entryCount,
            attachmentCount: result.attachmentCount
        )
    }

    init(_ result: KeePassKdbx4WritebackResult) {
        self.init(
            database: result.database,
            entryCount: result.entryCount,
            attachmentCount: result.attachmentCount
        )
    }
}

struct AppKeePassCloudFileSource: Sendable, Equatable {
    let provider: CloudFileProviderKind
    let itemID: String
    let fileName: String
    let revision: String?
}

struct CSVExportDocument: FileDocument, Sendable {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }

    var text: String

    init(text: String = "") {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8)
        else {
            self.text = ""
            return
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct AndroidBackupExportDocument: FileDocument, Sendable {
    static var readableContentTypes: [UTType] { [.zip] }

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

typealias AndroidBackupAttachmentBlobStore = LocalAttachmentContentStore
typealias FileAndroidBackupAttachmentBlobStore = FileLocalAttachmentContentStore

enum TotpImportSource {
    case manualURI
    case scannedQRCode
}

enum AppKeePassKdbxWritebackError: Error, Sendable, Equatable, LocalizedError {
    case sourceFileUnavailable
    case cloudSourceUnavailable

    var errorDescription: String? {
        switch self {
        case .sourceFileUnavailable:
            return String(localized: "请先从本地文件选择 KeePass KDBX 数据库，再执行写回。")
        case .cloudSourceUnavailable:
            return String(localized: "请先从云文件源选择 KeePass KDBX 数据库，再执行写回。")
        }
    }
}

enum AppKeePassSnapshotEditError: Error, Sendable, Equatable, LocalizedError {
    case entryUnavailable
    case attachmentUnavailable
    case entryNotInRecycleBin
    case targetGroupUnavailable

    var errorDescription: String? {
        switch self {
        case .entryUnavailable:
            return String(localized: "未找到可编辑的 KeePass 条目。")
        case .attachmentUnavailable:
            return String(localized: "未找到可编辑的 KeePass 附件。")
        case .entryNotInRecycleBin:
            return String(localized: "该 KeePass 条目不在回收站中。")
        case .targetGroupUnavailable:
            return String(localized: "未找到可还原到的 KeePass 分组。")
        }
    }
}

protocol AppKeePassKdbxFileWritebackService: Sendable {
    func replaceFile(at url: URL, with data: Data) throws
}

struct FileSystemAppKeePassKdbxFileWritebackService: AppKeePassKdbxFileWritebackService {
    func replaceFile(at url: URL, with data: Data) throws {
        let directoryURL = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(url.lastPathComponent).keepass-writeback-\(UUID().uuidString)",
            isDirectory: false
        )
        try data.write(to: temporaryURL, options: [.atomic])
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(
                url,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: url)
        }
    }
}

enum AppAndroidBackupImportError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedEncryptedBackup(String)
    case encryptedBackupDecryptionFailed(String)
    case encryptedBackupUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedEncryptedBackup(let message),
             .encryptedBackupDecryptionFailed(let message):
            return message
        case .encryptedBackupUnavailable:
            return String(localized: "请先选择移动端加密备份文件。")
        }
    }
}
