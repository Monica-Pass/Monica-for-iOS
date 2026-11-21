import CryptoKit
import Foundation
import ImageIO
import MonicaStorage
import Security
import SwiftUI
import UIKit

// MARK: - 笔记草稿策略

/// 笔记草稿的纯逻辑：草稿槽位、是否需要保存、图片引用移除。
/// 抽成独立类型便于在没有 SwiftUI 会话的情况下做单元测试。
enum AppNoteDraftPolicy {
    /// 新增笔记时的固定草稿槽位；编辑已有笔记时直接用条目 ID。
    static let newNoteDraftID = "new-note"

    static func draftID(noteID: String?) -> String {
        guard let noteID, !noteID.isEmpty, NoteDraftStore.isSupportedDraftID(noteID) else {
            return newNoteDraftID
        }
        return noteID
    }

    static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 只有用户真的写了内容、且和已保存版本不同时才值得留草稿。
    static func shouldSaveDraft(
        title: String,
        body: String,
        baselineTitle: String?,
        baselineBody: String?
    ) -> Bool {
        guard !isBlank(title) || !isBlank(body) else {
            return false
        }
        if let baselineTitle, let baselineBody, title == baselineTitle, body == baselineBody {
            return false
        }
        return true
    }

    /// 从正文里移除指向某张附件图片的所有 Markdown 片段，用于「移除引用」。
    static func removingImageReferences(attachmentID: String, from body: String) -> String {
        guard !attachmentID.isEmpty else {
            return body
        }
        let token = NoteMarkdownAttachmentReference.urlPrefix + attachmentID
        guard body.contains(token) else {
            return body
        }
        let escapedToken = NSRegularExpression.escapedPattern(for: token)
        let pattern = #"!?\[[^\]\n]*\]\(\#(escapedToken)\)"#
        let regex = try? NSRegularExpression(pattern: pattern)
        var keptLines: [String] = []
        for line in body.components(separatedBy: "\n") {
            guard line.contains(token) else {
                keptLines.append(line)
                continue
            }
            var cleaned = line
            if let regex {
                cleaned = regex.stringByReplacingMatches(
                    in: cleaned,
                    range: NSRange(cleaned.startIndex..., in: cleaned),
                    withTemplate: ""
                )
            }
            cleaned = cleaned.replacingOccurrences(of: token, with: "")
            if cleaned.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            keptLines.append(cleaned)
        }
        var result = keptLines.joined(separator: "\n")
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 图片文件名只保留安全字符，并按媒体类型补齐扩展名。
    static func sanitizedImageFileName(_ rawName: String, mediaType: String) -> String {
        let fallbackExtension = NoteMarkdownImageInspector.supportedFileExtensions(for: mediaType).first ?? "img"
        let lastComponent = rawName
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? ""
        let sanitized = lastComponent.unicodeScalars
            .map { scalar -> String in
                switch scalar.value {
                case 48...57, 65...90, 97...122, 45, 46, 95:
                    return String(scalar)
                default:
                    return "-"
                }
            }
            .joined()
        let nsName = sanitized as NSString
        let currentExtension = nsName.pathExtension.lowercased()
        var stem = nsName.deletingPathExtension
            .trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        if stem.isEmpty {
            stem = "note-image"
        }
        if stem.count > 100 {
            stem = String(stem.prefix(100))
        }
        let extensionToUse = NoteMarkdownImageInspector
            .supportedFileExtensions(for: mediaType)
            .contains(currentExtension) ? currentExtension : fallbackExtension
        return "\(stem).\(extensionToUse)"
    }
}

// MARK: - Keychain 草稿密钥

enum AppNoteDraftKeyError: Error, LocalizedError {
    case keychainUnavailable(OSStatus)
    case invalidKeyLength

    var errorDescription: String? {
        switch self {
        case .keychainUnavailable:
            return String(localized: "无法从钥匙串读取笔记草稿密钥，草稿暂时无法保存。")
        case .invalidKeyLength:
            return String(localized: "笔记草稿密钥长度不正确，已拒绝使用。")
        }
    }
}

/// 草稿密钥只保存在本机钥匙串（解锁后可用、不随备份迁移），不写入 UserDefaults。
struct AppNoteDraftKeychainKeyProvider: NoteDraftKeyProviding {
    static let service = "ru.takagi.monica.note-draft-key"
    static let account = "note-draft-v1"

    func noteDraftKey() throws -> Data {
        if let existing = try Self.readKey() {
            guard existing.count == NoteDraftStore.keyByteCount else {
                throw AppNoteDraftKeyError.invalidKeyLength
            }
            return existing
        }
        let key = NoteDraftKeyGenerator.makeKey()
        try Self.storeKey(key)
        return key
    }

    private static func readKey() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw AppNoteDraftKeyError.keychainUnavailable(status)
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw AppNoteDraftKeyError.keychainUnavailable(status)
        }
    }

    private static func storeKey(_ key: Data) throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: key,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw AppNoteDraftKeyError.keychainUnavailable(status)
        }
    }
}

// MARK: - 解密后的图片缓存

/// 只缓存解密后的缩略图，锁库时必须清空；不写磁盘、不写日志。
@MainActor
final class AppNoteImageCache {
    static let shared = AppNoteImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 24
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func cachedImage(for attachmentID: String) -> UIImage? {
        cache.object(forKey: attachmentID as NSString)
    }

    func image(
        for attachment: LocalAttachmentMetadata,
        session: AppSessionModel
    ) throws -> UIImage {
        if let cached = cachedImage(for: attachment.id) {
            return cached
        }
        let plaintext = try session.attachmentPlaintext(attachment)
        guard let image = Self.downsampledImage(plaintext, maxPixelSize: 1600) else {
            throw NoteMarkdownImageError.unreadableImage
        }
        cache.setObject(image, forKey: attachment.id as NSString, cost: plaintext.count)
        return image
    }

    func removeImage(for attachmentID: String) {
        cache.removeObject(forKey: attachmentID as NSString)
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    /// 用 ImageIO 生成缩略图，避免把整张大图解码进内存。
    static func downsampledImage(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - 会话扩展

extension AppSessionModel {
    /// 草稿存储：目录在 Application Support 下，密钥在钥匙串里。
    var noteDraftStore: NoteDraftStore? {
        guard let directory = try? NoteDraftStore.defaultDirectoryURL() else {
            return nil
        }
        return NoteDraftStore(directoryURL: directory, keyProvider: AppNoteDraftKeychainKeyProvider())
    }

    func noteDraft(forDraftID draftID: String) -> NoteDraft? {
        guard let store = noteDraftStore else {
            return nil
        }
        return try? store.loadDraft(draftID: draftID)
    }

    @discardableResult
    func saveNoteDraft(title: String, body: String, draftID: String, noteID: String?) -> Bool {
        guard let store = noteDraftStore else {
            return false
        }
        let draft = NoteDraft(draftID: draftID, noteID: noteID, title: title, body: body)
        do {
            try store.saveDraft(draft)
            return true
        } catch {
            return false
        }
    }

    /// 关闭编辑器（返回键 / 下滑）时把未保存内容留成加密草稿。
    @discardableResult
    func autosaveNoteDraftIfNeeded() -> Bool {
        guard let mode = presentedEditorMode, mode.kind == .note else {
            return false
        }
        let isAdding = mode.isAdding
        let noteID = isAdding ? nil : editingNoteEntryID
        let title = isAdding ? noteTitle : editingNoteTitle
        let body = isAdding ? noteBody : editingNoteBody
        let baseline: (title: String, body: String)?
        if let noteID, let entry = noteEntries.first(where: { $0.id == noteID }) {
            baseline = (entry.title, entry.body)
        } else {
            baseline = nil
        }
        guard AppNoteDraftPolicy.shouldSaveDraft(
            title: title,
            body: body,
            baselineTitle: baseline?.title,
            baselineBody: baseline?.body
        ) else {
            return false
        }
        return saveNoteDraft(
            title: title,
            body: body,
            draftID: AppNoteDraftPolicy.draftID(noteID: noteID),
            noteID: noteID
        )
    }

    func dismissPresentedEditorSavingNoteDraft() {
        autosaveNoteDraftIfNeeded()
        dismissPresentedEditor()
    }

    /// 用户明确「放弃草稿」：删除草稿文件，并清掉只被该草稿引用的孤儿图片附件。
    func discardNoteDraft(draftID: String) {
        if let draft = noteDraft(forDraftID: draftID) {
            discardOrphanNoteImages(referencedIn: draft.body)
        }
        guard let store = noteDraftStore else {
            return
        }
        try? store.deleteDraft(draftID: draftID)
    }

    /// 笔记保存成功后：把草稿里引用的图片重新挂到笔记上，并删除草稿文件。
    func completeNoteDraftCommit(noteID: String, body: String) {
        relinkNoteImages(noteID: noteID, body: body)
        guard let store = noteDraftStore else {
            return
        }
        try? store.deleteDraft(draftID: AppNoteDraftPolicy.draftID(noteID: noteID))
        try? store.deleteDraft(draftID: AppNoteDraftPolicy.newNoteDraftID)
    }

    /// 新增笔记时图片先以「无归属」附件保存，保存正文后再按引用挂到笔记上。
    func relinkNoteImages(noteID: String, body: String) {
        let referencedIDs = Set(NoteMarkdownAttachmentReference.attachmentIDs(in: body))
        guard !referencedIDs.isEmpty,
              let repository = activeEntryRepository,
              let projectID = activeProject?.id
        else {
            return
        }
        let attachments = (try? repository.listAttachmentMetadata(projectID: projectID)) ?? attachmentEntries
        var didChange = false
        for attachment in attachments where referencedIDs.contains(attachment.id) && attachment.entryID != noteID {
            _ = try? repository.updateAttachmentMetadata(
                projectID: projectID,
                attachmentID: attachment.id,
                entryID: noteID,
                fileName: attachment.fileName,
                mediaType: attachment.mediaType,
                originalSize: attachment.originalSize,
                storedSize: attachment.storedSize,
                contentHash: attachment.contentHash,
                storageMode: attachment.storageMode,
                source: attachment.source,
                downloadState: attachment.downloadState,
                wrappedContentEncryptionKey: attachment.wrappedContentEncryptionKey,
                localPath: attachment.localPath
            )
            didChange = true
        }
        if didChange {
            attachmentEntries = (try? repository.listAttachmentMetadata(projectID: projectID)) ?? attachmentEntries
        }
    }

    /// 插入一张笔记图片：先做格式 / 体积 / 像素校验，再走既有加密附件存储。
    func addNoteImageAttachment(
        noteID: String?,
        fileName: String,
        plaintext: Data,
        existingImageCount: Int
    ) throws -> LocalAttachmentMetadata {
        let properties = try NoteMarkdownImageInspector.inspect(plaintext)
        guard existingImageCount < NoteMarkdownImageLimits.maximumImagesPerNote else {
            throw NoteMarkdownImageError.imageLimitReached(limit: NoteMarkdownImageLimits.maximumImagesPerNote)
        }
        if activeProject == nil, let repository = activeEntryRepository {
            activeProject = try createOrReuseVaultProject(title: String(localized: "个人"), entryRepository: repository)
        }
        let sanitizedFileName = AppNoteDraftPolicy.sanitizedImageFileName(fileName, mediaType: properties.mediaType)
        return try addLocalAttachmentContent(
            entryID: noteID,
            fileName: sanitizedFileName,
            mediaType: properties.mediaType,
            plaintext: plaintext,
            source: "ios-note-markdown-image"
        )
    }

    func noteImageAttachment(withID attachmentID: String) -> LocalAttachmentMetadata? {
        attachmentEntries.first { $0.id == attachmentID && $0.mediaType.hasPrefix("image/") }
    }

    func clearNoteImageCache() {
        AppNoteImageCache.shared.removeAll()
    }

    private func discardOrphanNoteImages(referencedIn body: String) {
        let referencedIDs = Set(NoteMarkdownAttachmentReference.attachmentIDs(in: body))
        guard !referencedIDs.isEmpty else {
            return
        }
        let savedReferenceIDs = Set(noteEntries.flatMap {
            NoteMarkdownAttachmentReference.attachmentIDs(in: $0.body)
        })
        for attachment in attachmentEntries where referencedIDs.contains(attachment.id) {
            // 只删除仍然没有归属、且没有被任何已保存笔记引用的图片。
            guard attachment.entryID == nil, !savedReferenceIDs.contains(attachment.id) else {
                continue
            }
            try? deleteAttachmentEntry(attachment)
            AppNoteImageCache.shared.removeImage(for: attachment.id)
        }
    }
}
