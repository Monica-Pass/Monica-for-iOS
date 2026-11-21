//
//  NoteDraftStore.swift
//  MonicaStorage
//
//  笔记草稿的加密落盘。
//
//  要求（issue #22）：
//  - 取消编辑后可以恢复草稿，用户明确放弃后草稿必须彻底删除；
//  - 草稿绝不能明文写入 Documents / UserDefaults；
//  - 密文用 AES-GCM 封装，密钥由调用方（App 层从 Keychain 取）注入，
//    MonicaStorage 不持有也不打印密钥；
//  - 文件损坏、密钥不匹配都只返回可读错误，不崩溃。
//
//  文件格式：ASCII 魔数 "MNDRAFT1" + AES.GCM combined（nonce|密文|tag），
//  载荷是 NoteDraft 的 JSON。
//

import CryptoKit
import Foundation

/// 一条笔记草稿。`noteID` 为 nil 表示“新建笔记”的草稿。
public struct NoteDraft: Codable, Sendable, Equatable, Identifiable {
    /// 当前草稿格式版本。
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let draftID: String
    public let noteID: String?
    public let title: String
    public let body: String
    public let updatedAt: Date

    public var id: String {
        draftID
    }

    public init(
        draftID: String,
        noteID: String?,
        title: String,
        body: String,
        updatedAt: Date = Date(),
        schemaVersion: Int = NoteDraft.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.draftID = draftID
        self.noteID = noteID
        self.title = title
        self.body = body
        self.updatedAt = updatedAt
    }
}

/// 草稿密钥来源。App 层从 Keychain 读取 32 字节随机密钥。
public protocol NoteDraftKeyProviding: Sendable {
    func noteDraftKey() throws -> Data
}

/// 固定密钥的提供者，供测试和小工具使用。
public struct StaticNoteDraftKeyProvider: NoteDraftKeyProviding {
    public let key: Data

    public init(key: Data) {
        self.key = key
    }

    public func noteDraftKey() throws -> Data {
        key
    }
}

public enum NoteDraftKeyGenerator {
    /// 生成 32 字节随机密钥。
    public static func makeKey() -> Data {
        Data((0..<NoteDraftStore.keyByteCount).map { _ in UInt8.random(in: 0...255) })
    }
}

public enum NoteDraftStoreError: Error, LocalizedError, Sendable, Equatable {
    case invalidDraftID
    case invalidKey
    case corruptedDraft
    case writeFailed
    case directoryUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidDraftID:
            return "草稿标识不合法"
        case .invalidKey:
            return "草稿密钥不可用"
        case .corruptedDraft:
            return "草稿已损坏或无法解密"
        case .writeFailed:
            return "无法写入草稿"
        case .directoryUnavailable:
            return "无法访问草稿目录"
        }
    }
}

/// 笔记草稿仓库：一条草稿一个加密文件。
public struct NoteDraftStore: Sendable {
    /// 密钥长度（AES-256）。
    public static let keyByteCount = 32
    /// 草稿文件后缀。
    public static let fileExtension = "notedraft"
    /// 文件魔数。
    static let magic = Data("MNDRAFT1".utf8)

    public let directoryURL: URL
    private let keyProvider: any NoteDraftKeyProviding

    /// `FileManager.default` 文档保证线程安全，这里只做计算属性，避免把非 Sendable 的实例存进结构体。
    private var fileManager: FileManager {
        .default
    }

    public init(directoryURL: URL, keyProvider: any NoteDraftKeyProviding) {
        self.directoryURL = directoryURL
        self.keyProvider = keyProvider
    }

    /// 默认目录：Application Support/Monica/NoteDrafts。
    public static func defaultDirectoryURL(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("Monica", isDirectory: true)
            .appendingPathComponent("NoteDrafts", isDirectory: true)
    }

    /// 草稿 ID 只能是文件名安全的 ASCII 片段。
    public static func isSupportedDraftID(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.count <= 128, raw != ".", raw != ".." else {
            return false
        }
        return raw.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
        }
    }

    /// 草稿文件地址。
    public func fileURL(forDraftID draftID: String) -> URL {
        directoryURL
            .appendingPathComponent(draftID, isDirectory: false)
            .appendingPathExtension(Self.fileExtension)
    }

    /// 是否存在草稿（不校验能否解密）。
    public func draftExists(draftID: String) -> Bool {
        guard Self.isSupportedDraftID(draftID) else {
            return false
        }
        return fileManager.fileExists(atPath: fileURL(forDraftID: draftID).path)
    }

    /// 写入或覆盖草稿。目录会在需要时创建。
    public func saveDraft(_ draft: NoteDraft) throws {
        guard Self.isSupportedDraftID(draft.draftID) else {
            throw NoteDraftStoreError.invalidDraftID
        }
        let key = try resolvedKey()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(draft)
        let sealedBox = try AES.GCM.seal(payload, using: SymmetricKey(data: key))
        guard let combined = sealedBox.combined else {
            throw NoteDraftStoreError.writeFailed
        }
        var fileData = Self.magic
        fileData.append(combined)

        do {
            try ensureDirectory()
            let url = fileURL(forDraftID: draft.draftID)
            try fileData.write(to: url, options: [.atomic])
            applyFileProtection(to: url)
        } catch let error as NoteDraftStoreError {
            throw error
        } catch {
            throw NoteDraftStoreError.writeFailed
        }
    }

    /// 读取草稿；不存在返回 nil，损坏返回 `corruptedDraft`。
    public func loadDraft(draftID: String) throws -> NoteDraft? {
        guard Self.isSupportedDraftID(draftID) else {
            throw NoteDraftStoreError.invalidDraftID
        }
        let url = fileURL(forDraftID: draftID)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        let rawData: Data
        do {
            rawData = try Data(contentsOf: url)
        } catch {
            throw NoteDraftStoreError.corruptedDraft
        }
        guard rawData.count > Self.magic.count, rawData.prefix(Self.magic.count) == Self.magic else {
            throw NoteDraftStoreError.corruptedDraft
        }
        let key = try resolvedKey()
        let sealedData = rawData.dropFirst(Self.magic.count)
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.SealedBox(combined: sealedData)
        } catch {
            throw NoteDraftStoreError.corruptedDraft
        }
        let payload: Data
        do {
            payload = try AES.GCM.open(sealedBox, using: SymmetricKey(data: key))
        } catch {
            // 密钥不对或内容被改动都走这里，绝不把密文写进日志。
            throw NoteDraftStoreError.corruptedDraft
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let draft = try? decoder.decode(NoteDraft.self, from: payload),
              draft.draftID == draftID else {
            throw NoteDraftStoreError.corruptedDraft
        }
        return draft
    }

    /// 删除草稿（不存在也算成功）。
    public func deleteDraft(draftID: String) throws {
        guard Self.isSupportedDraftID(draftID) else {
            throw NoteDraftStoreError.invalidDraftID
        }
        let url = fileURL(forDraftID: draftID)
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw NoteDraftStoreError.writeFailed
        }
    }

    /// 列出所有可解密草稿，按更新时间倒序；损坏的草稿会被跳过。
    public func listDrafts() throws -> [NoteDraft] {
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }
        var drafts: [NoteDraft] = []
        for url in urls where url.pathExtension == Self.fileExtension {
            let draftID = url.deletingPathExtension().lastPathComponent
            guard let draft = try? loadDraft(draftID: draftID) else {
                continue
            }
            drafts.append(draft)
        }
        return drafts.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 删除目录内全部草稿（锁库、退出登录时兜底）。
    public func deleteAllDrafts() throws {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return
        }
        do {
            let urls = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for url in urls where url.pathExtension == Self.fileExtension {
                try? fileManager.removeItem(at: url)
            }
        } catch {
            throw NoteDraftStoreError.writeFailed
        }
    }

    // MARK: 内部

    private func resolvedKey() throws -> Data {
        let key: Data
        do {
            key = try keyProvider.noteDraftKey()
        } catch {
            throw NoteDraftStoreError.invalidKey
        }
        guard key.count == Self.keyByteCount else {
            throw NoteDraftStoreError.invalidKey
        }
        return key
    }

    private func ensureDirectory() throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw NoteDraftStoreError.directoryUnavailable
            }
            return
        }
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDirectory = directoryURL
            try? mutableDirectory.setResourceValues(values)
        } catch {
            throw NoteDraftStoreError.directoryUnavailable
        }
    }

    private func applyFileProtection(to url: URL) {
        #if os(iOS)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        #endif
    }
}
