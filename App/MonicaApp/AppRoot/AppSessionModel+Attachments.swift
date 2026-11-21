import CryptoKit
import Foundation
import MonicaStorage

// slice B: Attachments 域，从 AppSessionModel.swift 逐字搬移。
extension AppSessionModel {
    func attachmentContentStatus(for entry: LocalAttachmentMetadata) -> AppAttachmentContentStatus {
        guard let vaultID = activeVaultSession?.handle.vaultID else {
            return AppAttachmentContentStatus(
                state: .unavailable,
                value: String(localized: "未解锁"),
                detail: String(localized: "请先解锁保险库，再检查附件内容。")
            )
        }
        guard entry.downloadState == "downloaded",
              let localPath = entry.localPath,
              !localPath.isEmpty else {
            return AppAttachmentContentStatus(
                state: .missing,
                value: String(localized: "待恢复"),
                detail: String(localized: "附件密文尚未保存在本机。")
            )
        }
        guard androidBackupAttachmentBlobStore.encryptedBlobExists(vaultID: vaultID, localPath: localPath) else {
            return AppAttachmentContentStatus(
                state: .missing,
                value: String(localized: "待恢复"),
                detail: String(localized: "附件密文尚未保存在本机。")
            )
        }
        return AppAttachmentContentStatus(
            state: .available,
            value: String(localized: "\(entry.storedSize) 字节"),
            detail: storedAttachmentContentCanPreviewDirectly(entry)
                ? String(localized: "附件内容已保存在本机，可预览。")
                : String(localized: "附件密文已保存在本机，可进入预览恢复流程。")
        )
    }

    func loadAttachmentEncryptedBlob(_ entry: LocalAttachmentMetadata) throws -> Data {
        recordUserActivity()
        do {
            let vaultSession = try requireActiveVaultSession()
            guard let localPath = entry.localPath, !localPath.isEmpty else {
                throw LocalAttachmentContentStoreError.missingLocalPath
            }
            let blob = try androidBackupAttachmentBlobStore.encryptedBlobData(
                vaultID: vaultSession.handle.vaultID,
                localPath: localPath
            )
            entryOperationState = .succeeded(String(localized: "附件密文已读取：\(entry.fileName) \(blob.count) 字节"))
            return blob
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func resolveAttachmentContentEncryptionKey(_ entry: LocalAttachmentMetadata) throws -> Data {
        if let attachmentContentEncryptionKeyProvider {
            return try attachmentContentEncryptionKeyProvider(entry)
        }
        if let wrappedContentEncryptionKey = entry.wrappedContentEncryptionKey,
           wrappedContentEncryptionKey.hasPrefix("IOS-RAWCEK:") {
            let encoded = String(wrappedContentEncryptionKey.dropFirst("IOS-RAWCEK:".count))
            guard let data = Data(base64Encoded: encoded),
                  data.count == LocalAttachmentContentDecryptor.androidContentEncryptionKeyByteCount
            else {
                throw AppAttachmentPreviewError.contentEncryptionKeyUnavailable
            }
            return data
        }
        guard let wrappedContentEncryptionKey = entry.wrappedContentEncryptionKey,
              !wrappedContentEncryptionKey.isEmpty,
              let androidAttachmentWrappingKeyProvider
        else {
            throw AppAttachmentPreviewError.contentEncryptionKeyUnavailable
        }
        return try AndroidWrappedAttachmentContentKeyUnwrapper.unwrap(
            wrappedContentEncryptionKey,
            using: try androidAttachmentWrappingKeyProvider(entry)
        )
    }

    func replaceAttachmentContent(
        _ entry: LocalAttachmentMetadata,
        plaintext: Data,
        mediaType: String? = nil
    ) throws -> LocalAttachmentMetadata {
        recordUserActivity()
        entryOperationState = .running

        do {
            let vaultSession = try requireActiveVaultSession()
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let contentEncryptionKey = try resolveAttachmentContentEncryptionKey(entry)
            guard contentEncryptionKey.count == LocalAttachmentContentDecryptor.androidContentEncryptionKeyByteCount else {
                throw LocalAttachmentContentCryptoError.invalidContentEncryptionKeyLength
            }

            let sealedBox = try AES.GCM.seal(
                plaintext,
                using: SymmetricKey(data: contentEncryptionKey)
            )
            guard let encryptedBlob = sealedBox.combined else {
                throw AppAttachmentPreviewError.contentWriteFailed
            }
            let requestedLocalPath = entry.localPath?.isEmpty == false ? entry.localPath! : "\(entry.id).enc"
            let localPath = try androidBackupAttachmentBlobStore.saveEncryptedBlob(
                encryptedBlob,
                vaultID: vaultSession.handle.vaultID,
                localPath: requestedLocalPath
            )
            let contentHash = Data(SHA256.hash(data: plaintext))
                .map { String(format: "%02x", $0) }
                .joined()
            let updated = try entryRepository.updateAttachmentMetadata(
                projectID: projectID,
                attachmentID: entry.id,
                entryID: entry.entryID,
                fileName: entry.fileName,
                mediaType: mediaType ?? entry.mediaType,
                originalSize: Int64(plaintext.count),
                storedSize: Int64(encryptedBlob.count),
                contentHash: "sha256:\(contentHash)",
                storageMode: "ios-edited-encrypted-blob",
                source: entry.source.isEmpty ? "ios-local-edit" : entry.source,
                downloadState: "downloaded",
                wrappedContentEncryptionKey: entry.wrappedContentEncryptionKey,
                localPath: localPath
            )
            attachmentEntries = try entryRepository.listAttachmentMetadata(projectID: projectID)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .attachmentRef,
                itemID: updated.id,
                itemTitle: sanitizedAttachmentPreviewFileName(updated.fileName)
            )
            entryOperationState = .succeeded(String(localized: "附件内容已替换：\(sanitizedAttachmentPreviewFileName(updated.fileName)) \(plaintext.count) 字节"))
            return updated
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func addLocalAttachmentContent(
        entryID: String?,
        fileURL: URL
    ) throws -> LocalAttachmentMetadata {
        recordUserActivity()
        entryOperationState = .running

        do {
            // 附件编辑与其他功能一样永久免费，不再受 Monica Plus 影响。
            let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }
            let plaintext = try Data(contentsOf: fileURL)
            let mediaType = fileURL.pathExtension.isEmpty
                ? "application/octet-stream"
                : "application/\(fileURL.pathExtension.lowercased())"
            return try addLocalAttachmentContent(
                entryID: entryID,
                fileName: sanitizedAttachmentPreviewFileName(fileURL.lastPathComponent),
                mediaType: mediaType,
                plaintext: plaintext,
                source: "ios-file-importer"
            )
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    /// 直接以内存数据写入加密附件存储；笔记 Markdown 图片与文件导入共用这条路径。
    func addLocalAttachmentContent(
        entryID: String?,
        fileName: String,
        mediaType: String,
        plaintext: Data,
        source: String
    ) throws -> LocalAttachmentMetadata {
        recordUserActivity()
        entryOperationState = .running

        do {
            // 附件编辑与其他功能一样永久免费，不再受 Monica Plus 影响。
            let vaultSession = try requireActiveVaultSession()
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let contentEncryptionKey = Data((0..<LocalAttachmentContentDecryptor.androidContentEncryptionKeyByteCount).map { _ in UInt8.random(in: 0...255) })
            let sealedBox = try AES.GCM.seal(
                plaintext,
                using: SymmetricKey(data: contentEncryptionKey)
            )
            guard let encryptedBlob = sealedBox.combined else {
                throw AppAttachmentPreviewError.contentWriteFailed
            }
            let sanitizedFileName = sanitizedAttachmentPreviewFileName(fileName)
            let localPath = try androidBackupAttachmentBlobStore.saveEncryptedBlob(
                encryptedBlob,
                vaultID: vaultSession.handle.vaultID,
                localPath: "ios-local-\(UUID().uuidString)-\(sanitizedFileName).enc"
            )
            let contentHash = Data(SHA256.hash(data: plaintext)).map { String(format: "%02x", $0) }.joined()
            let attachment = try entryRepository.createAttachmentMetadata(
                projectID: projectID,
                entryID: entryID,
                fileName: sanitizedFileName,
                mediaType: mediaType,
                originalSize: Int64(plaintext.count),
                storedSize: Int64(encryptedBlob.count),
                contentHash: "sha256:\(contentHash)",
                storageMode: "ios-local-encrypted-blob",
                source: source,
                downloadState: "downloaded",
                wrappedContentEncryptionKey: "IOS-RAWCEK:\(contentEncryptionKey.base64EncodedString())",
                localPath: localPath
            )
            attachmentEntries = try entryRepository.listAttachmentMetadata(projectID: projectID)
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .attachmentRef,
                itemID: attachment.id,
                itemTitle: attachment.fileName
            )
            entryOperationState = .succeeded(String(localized: "附件已添加：\(attachment.fileName)"))
            return attachment
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    /// 静默解密附件内容：供图片渲染使用，不写操作状态、不记录日志。
    func attachmentPlaintext(_ entry: LocalAttachmentMetadata) throws -> Data {
        let vaultSession = try requireActiveVaultSession()
        guard let localPath = entry.localPath, !localPath.isEmpty else {
            throw LocalAttachmentContentStoreError.missingLocalPath
        }
        let blob = try androidBackupAttachmentBlobStore.encryptedBlobData(
            vaultID: vaultSession.handle.vaultID,
            localPath: localPath
        )
        let contentEncryptionKey = try resolveAttachmentContentEncryptionKey(entry)
        return try LocalAttachmentContentDecryptor.decryptAndroidLocalBlob(
            blob,
            contentEncryptionKey: contentEncryptionKey
        )
    }

    func attachmentEntries(for entryID: String?) -> [LocalAttachmentMetadata] {
        guard let entryID, !entryID.isEmpty else {
            return []
        }
        return attachmentEntries.filter { $0.entryID == entryID }
    }

    func materializeAttachmentPreview(
        _ entry: LocalAttachmentMetadata,
        contentEncryptionKey: Data
    ) throws -> AppAttachmentPreviewFile {
        recordUserActivity()
        do {
            let encryptedBlob = try loadAttachmentEncryptedBlob(entry)
            let plaintext = try LocalAttachmentContentDecryptor.decryptAndroidLocalBlob(
                encryptedBlob,
                contentEncryptionKey: contentEncryptionKey
            )
            let displayFileName = sanitizedAttachmentPreviewFileName(entry.fileName)
            let directoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MonicaAttachmentPreviews", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let fileURL = directoryURL.appendingPathComponent(displayFileName, isDirectory: false)
            try plaintext.write(to: fileURL, options: [.atomic])
            let preview = AppAttachmentPreviewFile(
                fileURL: fileURL,
                displayFileName: displayFileName,
                byteCount: plaintext.count
            )
            entryOperationState = .succeeded(String(localized: "附件预览已准备：\(displayFileName) \(plaintext.count) 字节"))
            return preview
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func materializeStoredAttachmentContentPreview(
        _ entry: LocalAttachmentMetadata
    ) throws -> AppAttachmentPreviewFile {
        recordUserActivity()
        do {
            let content = try loadAttachmentEncryptedBlob(entry)
            let displayFileName = sanitizedAttachmentPreviewFileName(entry.fileName)
            let directoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MonicaAttachmentPreviews", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let fileURL = directoryURL.appendingPathComponent(displayFileName, isDirectory: false)
            try content.write(to: fileURL, options: [.atomic])
            let preview = AppAttachmentPreviewFile(
                fileURL: fileURL,
                displayFileName: displayFileName,
                byteCount: content.count
            )
            entryOperationState = .succeeded(String(localized: "附件预览已准备：\(displayFileName) \(content.count) 字节"))
            return preview
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func presentAttachmentQuickLookPreview(_ entry: LocalAttachmentMetadata) throws {
        recordUserActivity()
        dismissAttachmentQuickLookPreview()

        if storedAttachmentContentCanPreviewDirectly(entry) {
            do {
                let preview = try materializeStoredAttachmentContentPreview(entry)
                attachmentQuickLookPreviewURL = preview.fileURL
                appendOperationTimelineEvent(
                    action: .viewed,
                    itemKind: .attachmentRef,
                    itemID: entry.id,
                    itemTitle: preview.displayFileName
                )
                entryOperationState = .succeeded(String(localized: "附件预览已准备：\(preview.displayFileName) \(preview.byteCount) 字节"))
                return
            } catch let error as LocalAttachmentContentStoreError {
                entryOperationState = .failed(error.localizedDescription)
                throw error
            } catch {
                let previewError = AppAttachmentPreviewError.previewFailed
                entryOperationState = .failed(previewError.localizedDescription)
                throw previewError
            }
        }

        let contentEncryptionKey: Data
        do {
            contentEncryptionKey = try resolveAttachmentContentEncryptionKey(entry)
        } catch {
            let previewError = AppAttachmentPreviewError.contentEncryptionKeyUnavailable
            entryOperationState = .failed(previewError.localizedDescription)
            throw previewError
        }

        do {
            let preview = try materializeAttachmentPreview(
                entry,
                contentEncryptionKey: contentEncryptionKey
            )
            attachmentQuickLookPreviewURL = preview.fileURL
            appendOperationTimelineEvent(
                action: .viewed,
                itemKind: .attachmentRef,
                itemID: entry.id,
                itemTitle: preview.displayFileName
            )
            entryOperationState = .succeeded(String(localized: "附件预览已准备：\(preview.displayFileName) \(preview.byteCount) 字节"))
        } catch let error as LocalAttachmentContentStoreError {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        } catch let error as LocalAttachmentContentCryptoError {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        } catch let error as AppWebDAVBackupError {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        } catch {
            let previewError = AppAttachmentPreviewError.previewFailed
            entryOperationState = .failed(previewError.localizedDescription)
            throw previewError
        }
    }

    func dismissAttachmentQuickLookPreview() {
        guard let previewURL = attachmentQuickLookPreviewURL else {
            return
        }
        attachmentQuickLookPreviewURL = nil
        try? FileManager.default.removeItem(at: previewURL.deletingLastPathComponent())
    }

    func storedAttachmentContentCanPreviewDirectly(_ entry: LocalAttachmentMetadata) -> Bool {
        switch entry.storageMode {
        case "keepass-kdbx-decoded-content",
            "bitwarden-downloaded-content",
            "share-extension-imported-blob":
            return true
        default:
            return false
        }
    }
}
