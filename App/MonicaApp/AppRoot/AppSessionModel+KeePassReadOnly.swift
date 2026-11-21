//
//  AppSessionModel+KeePassReadOnly.swift
//  Monica
//
//  slice C2：KeePass 只读库导入 / 写回 / 附件 / 回收站，从 AppSessionModel.swift 逐字搬移。
//

import Foundation
import MonicaCore
import MonicaStorage
import MonicaSync

extension AppSessionModel {
    func previewKeePassImport(
        _ data: Data,
        fileName: String? = nil
    ) throws -> KeePassImportPreview {
        recordUserActivity()
        let report = KeePassFormatInspector.inspect(data, sourceName: fileName)
        if let issue = report.issue {
            clearKeePassImportState()
            csvImportPreview = nil
            androidBackupImportPreview = nil
            entryOperationState = .failed(issue.message)
            throw KeePassOperationError(code: issue.code, message: issue.message)
        }

        let preview = KeePassImportPreview(report: report, unlockPreflight: nil)
        keePassImportPreview = preview
        keePassPendingDatabaseData = data
        keePassPendingDatabaseName = fileName
        keePassSourceFileURL = nil
        keePassCloudFileSource = nil
        keePassReadOnlySnapshot = nil
        keePassReadOnlyImportPlan = nil
        keePassLastMetadataImportReferences = []
        keePassUnlockPassword = ""
        keePassKeyFileData = nil
        keePassKeyFileName = ""
        csvImportPreview = nil
        androidBackupImportPreview = nil
        clearPendingAndroidEncryptedBackup()
        entryOperationState = .succeeded(String(localized: "KeePass 预览：\(report.format.localizedDisplayName) 数据库，等待密码或密钥文件解锁"))
        return preview
    }

    func previewKeePassImport(from fileURL: URL) throws -> KeePassImportPreview {
        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: fileURL)
        let preview = try previewKeePassImport(data, fileName: fileURL.lastPathComponent)
        keePassSourceFileURL = fileURL
        return preview
    }

    func previewKeePassImport(
        fromCloudFile download: CloudFileDownload,
        provider kind: CloudFileProviderKind
    ) throws -> KeePassImportPreview {
        let fileName = sanitizedCloudFileName(download.item.name)
        let preview = try previewKeePassImport(download.data, fileName: fileName)
        keePassSourceFileURL = nil
        keePassCloudFileSource = AppKeePassCloudFileSource(
            provider: kind,
            itemID: download.item.id,
            fileName: fileName,
            revision: download.revision
        )
        cloudFileRestorePreview = AppCloudFileRestorePreview(
            provider: kind,
            download: download
        )
        downloadedCloudFileRestore = download
        return preview
    }

    func prepareKeePassUnlockPreflight(
        password: String? = nil,
        keyFile: Data? = nil,
        keyFileName: String? = nil
    ) throws -> KeePassUnlockPreflightReport {
        recordUserActivity()
        guard let databaseData = keePassPendingDatabaseData else {
            let message = String(localized: "请先选择 KDBX 数据库文件")
            entryOperationState = .failed(message)
            throw KeePassOperationError(code: .formatUnsupported, message: message)
        }

        if let password {
            keePassUnlockPassword = password
        }
        if let keyFile {
            keePassKeyFileData = keyFile
        }
        if let keyFileName {
            keePassKeyFileName = sanitizedKeePassFileName(keyFileName) ?? ""
        }
        keePassReadOnlySnapshot = nil
        keePassReadOnlyImportPlan = nil
        keePassLastSuccessfulUnlockCredentials = nil

        let preflight = KeePassFormatInspector.prepareUnlock(
            databaseData,
            sourceName: keePassPendingDatabaseName,
            password: password ?? keePassUnlockPassword,
            keyFile: keyFile ?? keePassKeyFileData,
            keyFileName: keyFileName ?? keePassKeyFileName
        )

        if let issue = preflight.issue {
            entryOperationState = .failed(issue.message)
            throw KeePassOperationError(code: issue.code, message: issue.message)
        }

        if let preview = keePassImportPreview {
            keePassImportPreview = KeePassImportPreview(
                report: preview.report,
                unlockPreflight: preflight
            )
        }
        let version = preflight.headerSummary?.displayName ?? preflight.format.localizedDisplayName
        entryOperationState = .succeeded(String(localized: "KeePass 解锁输入已准备：\(version)，\(preflight.credentials.localizedDisplayName)"))
        return preflight
    }

    func previewKeePassReadOnlyTree() throws -> KeePassReadOnlySnapshot {
        recordUserActivity()
        guard let databaseData = keePassPendingDatabaseData else {
            let message = String(localized: "请先选择 KDBX 数据库文件")
            entryOperationState = .failed(message)
            throw KeePassOperationError(code: .formatUnsupported, message: message)
        }

        do {
            _ = try prepareKeePassUnlockPreflight()
            let (snapshot, successfulCredentials) = try readKeePassSnapshotTryingCredentialCandidates(
                database: databaseData,
                sourceName: keePassPendingDatabaseName,
                credentials: KeePassUnlockCredentials(
                    password: keePassUnlockPassword,
                    keyFile: keePassKeyFileData,
                    keyFileName: keePassKeyFileName
                )
            )
            keePassReadOnlySnapshot = snapshot
            keePassLastSuccessfulUnlockCredentials = successfulCredentials
            keePassReadOnlyImportPlan = nil
            entryOperationState = .succeeded(String(localized: "KeePass 只读预览：\(snapshot.displaySummary)"))
            return snapshot
        } catch {
            keePassReadOnlySnapshot = nil
            keePassReadOnlyImportPlan = nil
            keePassLastSuccessfulUnlockCredentials = nil
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func previewKeePassReadOnlyImportPlan() throws -> KeePassReadOnlyImportPlan {
        recordUserActivity()

        do {
            let snapshot: KeePassReadOnlySnapshot
            if let existingSnapshot = keePassReadOnlySnapshot {
                snapshot = existingSnapshot
            } else {
                snapshot = try previewKeePassReadOnlyTree()
            }
            let plan = KeePassReadOnlyImportPlanner.plan(snapshot)
            keePassReadOnlyImportPlan = plan
            entryOperationState = .succeeded(String(localized: "KeePass 导入计划：\(plan.displaySummary)"))
            return plan
        } catch {
            keePassReadOnlyImportPlan = nil
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func confirmKeePassReadOnlyImport(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            let plan: KeePassReadOnlyImportPlan
            if let existingPlan = keePassReadOnlyImportPlan {
                plan = existingPlan
            } else {
                plan = try previewKeePassReadOnlyImportPlan()
            }
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let vaultSession = try requireActiveVaultSession()

            var firstImportedProject: LocalVaultProject?
            var importedReferences: [AppKeePassImportedEntryReference] = []
            var importedTotpPlaceholderCount = 0
            var importedDecodedPasswordCount = 0
            var importedDecodedTotpSecretCount = 0
            var importedAttachmentPlaceholderCount = 0
            var importedDecodedAttachmentContentCount = 0
            var importedNotesFieldCount = 0
            var importedDeletedMetadataCount = 0
            for candidate in plan.candidates {
                let project = try ensureKeePassImportProject(
                    baseTitle: projectTitle,
                    groupPath: candidate.groupPath,
                    entryRepository: entryRepository
                )
                if firstImportedProject == nil {
                    firstImportedProject = project
                }
                let importedEntry = try entryRepository.createLoginEntry(
                    projectID: project.id,
                    draft: LocalLoginEntryDraft(
                        title: candidate.title,
                        username: candidate.username,
                        password: candidate.decodedPassword ?? "",
                        url: candidate.url,
                        notes: keePassLoginNotes(for: candidate)
                    )
                )
                if !candidate.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    !candidate.customFields.isEmpty {
                    importedNotesFieldCount += 1
                }
                if candidate.hasPassword && candidate.decodedPassword != nil {
                    importedDecodedPasswordCount += 1
                }
                let importedTotpEntryID: String?
                if candidate.hasTotp {
                    let importedTotpEntry = try entryRepository.createTotpEntry(
                        projectID: project.id,
                        draft: keePassTotpDraft(for: candidate)
                    )
                    importedTotpEntryID = importedTotpEntry.id
                    if candidate.decodedTotp == nil {
                        importedTotpPlaceholderCount += 1
                    } else {
                        importedDecodedTotpSecretCount += 1
                    }
                    if candidate.isDeleted {
                        try entryRepository.deleteTotpEntry(
                            projectID: project.id,
                            entryID: importedTotpEntry.id
                        )
                    }
                } else {
                    importedTotpEntryID = nil
                }
                var importedAttachmentEntryIDs: [String] = []
                for attachment in candidate.attachments {
                    let attachmentFileName = keePassAttachmentFileName(attachment)
                    let decodedAttachmentLocalPath: String?
                    if let decodedContent = attachment.decodedContent {
                        decodedAttachmentLocalPath = try androidBackupAttachmentBlobStore.saveEncryptedBlob(
                            decodedContent,
                            vaultID: vaultSession.handle.vaultID,
                            localPath: keePassDecodedAttachmentLocalPath(
                                attachment,
                                fileName: attachmentFileName
                            )
                        )
                        importedDecodedAttachmentContentCount += 1
                    } else {
                        decodedAttachmentLocalPath = nil
                    }
                    let importedAttachment = try entryRepository.createAttachmentMetadata(
                        projectID: project.id,
                        entryID: importedEntry.id,
                        fileName: attachmentFileName,
                        mediaType: attachment.mediaType,
                        originalSize: attachment.originalSize,
                        storedSize: Int64(attachment.decodedContent?.count ?? 0),
                        contentHash: attachment.contentHash,
                        storageMode: decodedAttachmentLocalPath == nil
                            ? "keepass-kdbx-placeholder"
                            : "keepass-kdbx-decoded-content",
                        source: "KeePass",
                        downloadState: decodedAttachmentLocalPath == nil
                            ? "pending-kdbx-decode"
                            : "downloaded",
                        localPath: decodedAttachmentLocalPath
                    )
                    importedAttachmentEntryIDs.append(importedAttachment.id)
                    if decodedAttachmentLocalPath == nil {
                        importedAttachmentPlaceholderCount += 1
                    }
                    if candidate.isDeleted {
                        try entryRepository.deleteAttachmentMetadata(
                            projectID: project.id,
                            attachmentID: importedAttachment.id
                        )
                    }
                }
                if candidate.isDeleted {
                    try entryRepository.deleteLoginEntry(
                        projectID: project.id,
                        entryID: importedEntry.id
                    )
                    importedDeletedMetadataCount += 1
                }
                importedReferences.append(
                    AppKeePassImportedEntryReference(
                        sourceEntryID: candidate.id,
                        sourceGroupID: candidate.groupID,
                        sourceGroupPath: candidate.groupPath,
                        importedLoginEntryID: importedEntry.id,
                        importedTotpEntryID: importedTotpEntryID,
                        importedProjectID: project.id,
                        importedAsDeleted: candidate.isDeleted,
                        importedAttachmentEntryIDs: importedAttachmentEntryIDs
                    )
                )
            }
            if let firstImportedProject {
                activeProject = firstImportedProject
            }
            if let activeProject {
                try refreshAllEntryLists(projectID: activeProject.id, entryRepository: entryRepository)
                selectedVaultQuickFilterID = "category-\(activeProject.id)"
            }
            try refreshAutoFillEncryptedIndexIfConfigured()
            keePassLastMetadataImportReferences = importedReferences
            clearKeePassImportState(preservingLastMetadataImportReferences: true)
            let pendingSummary = plan.pendingCapabilitySummary
            let importedDecodedContentCount = importedDecodedPasswordCount
                + importedDecodedTotpSecretCount
                + importedDecodedAttachmentContentCount
                + importedNotesFieldCount
            let pendingText = pendingSummary.isEmpty
                ? (importedDecodedContentCount > 0 ? "" : String(localized: "，秘密字段待 KDBX 解码器接入"))
                : "；\(pendingSummary)"
            let totpPlaceholderText = importedTotpPlaceholderCount > 0
                ? String(localized: "，并创建 \(importedTotpPlaceholderCount) 个 TOTP 占位项")
                : ""
            let decodedPasswordText = importedDecodedPasswordCount > 0
                ? String(localized: "，并导入 \(importedDecodedPasswordCount) 个密码字段")
                : ""
            let decodedTotpText = importedDecodedTotpSecretCount > 0
                ? String(localized: "，并导入 \(importedDecodedTotpSecretCount) 个 TOTP 密钥")
                : ""
            let decodedAttachmentText = importedDecodedAttachmentContentCount > 0
                ? String(localized: "，并导入 \(importedDecodedAttachmentContentCount) 个附件内容")
                : ""
            let notesFieldText = importedNotesFieldCount > 0
                ? String(localized: "，并导入 \(importedNotesFieldCount) 项备注/自定义字段")
                : ""
            let attachmentPlaceholderText = importedAttachmentPlaceholderCount > 0
                ? String(localized: "，并创建 \(importedAttachmentPlaceholderCount) 个附件占位项")
                : ""
            let deletedText = importedDeletedMetadataCount > 0
                ? String(localized: "，并保留 \(importedDeletedMetadataCount) 项回收站元数据")
                : ""
            entryOperationState = .succeeded(String(localized: "KeePass 已导入 \(plan.candidateCount) 项元数据\(decodedPasswordText)\(decodedTotpText)\(decodedAttachmentText)\(notesFieldText)\(totpPlaceholderText)\(attachmentPlaceholderText)\(deletedText)\(pendingText)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func importKeePassKeyFile(from fileURL: URL) throws {
        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        keePassKeyFileData = try Data(contentsOf: fileURL)
        keePassKeyFileName = sanitizedKeePassFileName(fileURL.lastPathComponent) ?? "keyfile"
        keePassReadOnlySnapshot = nil
        keePassReadOnlyImportPlan = nil
        entryOperationState = .succeeded(String(localized: "KeePass 密钥文件已选择：\(keePassKeyFileName)"))
    }

    func writeKeePassKdbx4Database(_ result: KeePassKdbx4WritebackResult) throws {
        try writeKeePassKdbxDatabase(AppKeePassKdbxWritebackResult(result))
    }

    func writeKeePassKdbxDatabase(_ result: AppKeePassKdbxWritebackResult) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let sourceURL = keePassSourceFileURL else {
                throw AppKeePassKdbxWritebackError.sourceFileUnavailable
            }
            let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }
            try keePassKdbxFileWritebackService.replaceFile(
                at: sourceURL,
                with: result.database
            )
            keePassPendingDatabaseData = result.database
            keePassPendingDatabaseName = sourceURL.lastPathComponent
            entryOperationState = .succeeded(
                String(localized: "KeePass 数据库已写回：\(result.entryCount) 个条目，\(result.attachmentCount) 个附件，\(result.database.count) bytes")
            )
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func makeKeePassReadOnlySnapshotWritebackResult() throws -> AppKeePassKdbxWritebackResult {
        let snapshot: KeePassReadOnlySnapshot
        if let existingSnapshot = keePassReadOnlySnapshot {
            snapshot = existingSnapshot
        } else {
            snapshot = try previewKeePassReadOnlyTree()
        }
        switch try currentKeePassKdbxEnvelope().headerSummary.formatVersion {
        case .kdbx3:
            return AppKeePassKdbxWritebackResult(
                try keePassKdbx3WritebackCoordinator.writeDatabase(
                    try makeKeePassKdbx3WritebackRequest(snapshot: snapshot)
                )
            )
        case .kdbx4:
            return AppKeePassKdbxWritebackResult(
                try keePassKdbx4WritebackCoordinator.writeDatabase(
                    try makeKeePassKdbx4WritebackRequest(snapshot: snapshot)
                )
            )
        case .unknown:
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: String(localized: "无法写回未知版本的 KDBX 文件。")
            )
        }
    }

    func writeKeePassReadOnlySnapshotBackToSource() throws -> AppKeePassKdbxWritebackResult {
        recordUserActivity()
        entryOperationState = .running

        do {
            let result = try makeKeePassReadOnlySnapshotWritebackResult()
            try writeKeePassKdbxDatabase(result)
            return result
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func writeKeePassReadOnlySnapshotBackToCloudSource() async throws -> AppKeePassKdbxWritebackResult {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let source = keePassCloudFileSource else {
                throw AppKeePassKdbxWritebackError.cloudSourceUnavailable
            }
            let result = try makeKeePassReadOnlySnapshotWritebackResult()
            cloudFileState = .running(source.provider)
            let provider = try cloudFileProvider(for: source.provider)
            let receipt = try await provider.overwriteFile(
                id: source.itemID,
                data: result.database,
                fileName: source.fileName,
                expectedRevision: source.revision
            )
            let fileName = sanitizedCloudFileName(receipt.name)
            keePassPendingDatabaseData = result.database
            keePassPendingDatabaseName = fileName
            keePassSourceFileURL = nil
            keePassCloudFileSource = AppKeePassCloudFileSource(
                provider: source.provider,
                itemID: source.itemID,
                fileName: fileName,
                revision: receipt.revision ?? source.revision
            )
            cloudFileState = .writeSucceeded(
                provider: source.provider,
                fileName: fileName,
                byteCount: receipt.byteCount
            )
            entryOperationState = .succeeded(
                String(localized: "KeePass 云文件已写回：\(source.provider.displayName) \(fileName)，\(result.entryCount) 个条目，\(result.attachmentCount) 个附件，\(result.database.count) bytes")
            )
            return result
        } catch {
            if let source = keePassCloudFileSource {
                cloudFileState = .failed(readableCloudFileErrorMessage(for: error, provider: source.provider))
            }
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func keePassAttachmentEditCandidates(
        matching query: String = ""
    ) throws -> [AppKeePassAttachmentEditCandidate] {
        let snapshot: KeePassReadOnlySnapshot
        if let existingSnapshot = keePassReadOnlySnapshot {
            snapshot = existingSnapshot
        } else {
            snapshot = try previewKeePassReadOnlyTree()
        }
        let normalizedQuery = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return snapshot.entries
            .flatMap { entry in
                entry.attachments.map { attachment in
                    let fileName = sanitizedAttachmentPreviewFileName(attachment.fileName)
                    let searchableText = [
                        entry.title,
                        entry.username,
                        entry.groupPath,
                        fileName,
                        attachment.mediaType,
                        attachment.id
                    ]
                    .joined(separator: " ")
                    return AppKeePassAttachmentEditCandidate(
                        id: "\(entry.id)::\(attachment.id)",
                        entryID: entry.id,
                        attachmentID: attachment.id,
                        entryTitle: entry.title,
                        entryUsername: entry.username,
                        groupPath: entry.groupPath,
                        fileName: fileName,
                        mediaType: attachment.mediaType,
                        originalSize: attachment.originalSize,
                        isDeletedEntry: entry.isDeleted,
                        searchableText: searchableText
                    )
                }
            }
            .filter { candidate in
                normalizedQuery.isEmpty || candidate.searchableText.lowercased().contains(normalizedQuery)
            }
    }

    func replaceKeePassReadOnlyAttachmentContent(
        entryID: String,
        attachmentID: String,
        decodedContent content: Data,
        fileName: String? = nil,
        mediaType: String? = nil
    ) throws -> KeePassReadOnlySnapshot {
        recordUserActivity()
        entryOperationState = .running

        do {
            let snapshot: KeePassReadOnlySnapshot
            if let existingSnapshot = keePassReadOnlySnapshot {
                snapshot = existingSnapshot
            } else {
                snapshot = try previewKeePassReadOnlyTree()
            }
            guard let entryIndex = snapshot.entries.firstIndex(where: { $0.id == entryID }) else {
                throw AppKeePassSnapshotEditError.entryUnavailable
            }
            let entry = snapshot.entries[entryIndex]
            guard let attachmentIndex = entry.attachments.firstIndex(where: { $0.id == attachmentID }) else {
                throw AppKeePassSnapshotEditError.attachmentUnavailable
            }
            let attachment = entry.attachments[attachmentIndex]
            let updatedAttachment = KeePassReadOnlyAttachment(
                id: attachment.id,
                fileName: sanitizedAttachmentPreviewFileName(fileName ?? attachment.fileName),
                mediaType: mediaType ?? attachment.mediaType,
                originalSize: Int64(content.count),
                contentHash: "sha256:\(sha256Hex(content))",
                decodedContent: content
            )
            var updatedAttachments = entry.attachments
            updatedAttachments[attachmentIndex] = updatedAttachment
            let updatedEntry = KeePassReadOnlyEntry(
                id: entry.id,
                title: entry.title,
                username: entry.username,
                url: entry.url,
                groupPath: entry.groupPath,
                groupID: entry.groupID,
                originalGroupPath: entry.originalGroupPath,
                originalGroupID: entry.originalGroupID,
                notes: entry.notes,
                customFields: entry.customFields,
                hasPassword: entry.hasPassword,
                decodedPassword: entry.decodedPassword,
                hasTotp: entry.hasTotp,
                decodedTotp: entry.decodedTotp,
                attachmentCount: updatedAttachments.count,
                isDeleted: entry.isDeleted,
                attachments: updatedAttachments
            )
            var updatedEntries = snapshot.entries
            updatedEntries[entryIndex] = updatedEntry
            let updatedSnapshot = KeePassReadOnlySnapshot(
                sourceName: snapshot.sourceName,
                headerSummary: snapshot.headerSummary,
                groups: snapshot.groups,
                entries: updatedEntries
            )
            keePassReadOnlySnapshot = updatedSnapshot
            keePassReadOnlyImportPlan = nil
            entryOperationState = .succeeded(
                String(localized: "KeePass 附件内容已替换：\(updatedAttachment.fileName) \(content.count) 字节")
            )
            return updatedSnapshot
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func addKeePassReadOnlyAttachmentContent(
        entryID: String,
        decodedContent content: Data,
        fileName: String,
        mediaType: String? = nil
    ) throws -> KeePassReadOnlySnapshot {
        recordUserActivity()
        entryOperationState = .running

        do {
            let snapshot: KeePassReadOnlySnapshot
            if let existingSnapshot = keePassReadOnlySnapshot {
                snapshot = existingSnapshot
            } else {
                snapshot = try previewKeePassReadOnlyTree()
            }
            guard let entryIndex = snapshot.entries.firstIndex(where: { $0.id == entryID }) else {
                throw AppKeePassSnapshotEditError.entryUnavailable
            }
            let entry = snapshot.entries[entryIndex]
            let sanitizedFileName = sanitizedAttachmentPreviewFileName(fileName)
            let attachment = KeePassReadOnlyAttachment(
                id: "ios-added-\(UUID().uuidString)",
                fileName: sanitizedFileName,
                mediaType: mediaType ?? "application/octet-stream",
                originalSize: Int64(content.count),
                contentHash: "sha256:\(sha256Hex(content))",
                decodedContent: content
            )
            let updatedAttachments = entry.attachments + [attachment]
            let updatedEntry = KeePassReadOnlyEntry(
                id: entry.id,
                title: entry.title,
                username: entry.username,
                url: entry.url,
                groupPath: entry.groupPath,
                groupID: entry.groupID,
                originalGroupPath: entry.originalGroupPath,
                originalGroupID: entry.originalGroupID,
                notes: entry.notes,
                customFields: entry.customFields,
                hasPassword: entry.hasPassword,
                decodedPassword: entry.decodedPassword,
                hasTotp: entry.hasTotp,
                decodedTotp: entry.decodedTotp,
                attachmentCount: updatedAttachments.count,
                isDeleted: entry.isDeleted,
                attachments: updatedAttachments
            )
            var updatedEntries = snapshot.entries
            updatedEntries[entryIndex] = updatedEntry
            let updatedSnapshot = KeePassReadOnlySnapshot(
                sourceName: snapshot.sourceName,
                headerSummary: snapshot.headerSummary,
                groups: snapshot.groups,
                entries: updatedEntries
            )
            keePassReadOnlySnapshot = updatedSnapshot
            keePassReadOnlyImportPlan = nil
            entryOperationState = .succeeded(
                String(localized: "KeePass 附件已添加：\(sanitizedFileName) \(content.count) 字节")
            )
            return updatedSnapshot
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func addKeePassReadOnlyAttachmentContentFromFileAndWriteBack(
        entryID: String,
        fileURL: URL,
        mediaType: String? = nil
    ) throws -> AppKeePassKdbxWritebackResult {
        recordUserActivity()
        entryOperationState = .running

        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let content = try Data(contentsOf: fileURL)
            let fileName = sanitizedAttachmentPreviewFileName(fileURL.lastPathComponent)
            _ = try addKeePassReadOnlyAttachmentContent(
                entryID: entryID,
                decodedContent: content,
                fileName: fileName,
                mediaType: mediaType
            )
            let result = try writeKeePassReadOnlySnapshotBackToSource()
            entryOperationState = .succeeded(
                String(localized: "KeePass 附件已添加并写回：\(fileName) \(content.count) 字节")
            )
            return result
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteKeePassReadOnlyAttachmentAndWriteBack(
        entryID: String,
        attachmentID: String
    ) throws -> AppKeePassKdbxWritebackResult {
        recordUserActivity()
        entryOperationState = .running

        do {
            let snapshot: KeePassReadOnlySnapshot
            if let existingSnapshot = keePassReadOnlySnapshot {
                snapshot = existingSnapshot
            } else {
                snapshot = try previewKeePassReadOnlyTree()
            }
            guard let entryIndex = snapshot.entries.firstIndex(where: { $0.id == entryID }) else {
                throw AppKeePassSnapshotEditError.entryUnavailable
            }
            let entry = snapshot.entries[entryIndex]
            guard let attachmentIndex = entry.attachments.firstIndex(where: { $0.id == attachmentID }) else {
                throw AppKeePassSnapshotEditError.attachmentUnavailable
            }
            let attachment = entry.attachments[attachmentIndex]
            var updatedAttachments = entry.attachments
            updatedAttachments.remove(at: attachmentIndex)
            let updatedEntry = KeePassReadOnlyEntry(
                id: entry.id,
                title: entry.title,
                username: entry.username,
                url: entry.url,
                groupPath: entry.groupPath,
                groupID: entry.groupID,
                originalGroupPath: entry.originalGroupPath,
                originalGroupID: entry.originalGroupID,
                notes: entry.notes,
                customFields: entry.customFields,
                hasPassword: entry.hasPassword,
                decodedPassword: entry.decodedPassword,
                hasTotp: entry.hasTotp,
                decodedTotp: entry.decodedTotp,
                attachmentCount: updatedAttachments.count,
                isDeleted: entry.isDeleted,
                attachments: updatedAttachments
            )
            var updatedEntries = snapshot.entries
            updatedEntries[entryIndex] = updatedEntry
            let updatedSnapshot = KeePassReadOnlySnapshot(
                sourceName: snapshot.sourceName,
                headerSummary: snapshot.headerSummary,
                groups: snapshot.groups,
                entries: updatedEntries
            )
            keePassReadOnlySnapshot = updatedSnapshot
            keePassReadOnlyImportPlan = nil
            let result = try writeKeePassReadOnlySnapshotBackToSource()
            entryOperationState = .succeeded(
                String(localized: "KeePass 附件已删除并写回：\(sanitizedAttachmentPreviewFileName(attachment.fileName))")
            )
            return result
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func replaceKeePassReadOnlyAttachmentContentFromFileAndWriteBack(
        entryID: String,
        attachmentID: String,
        fileURL: URL,
        mediaType: String? = nil
    ) throws -> AppKeePassKdbxWritebackResult {
        recordUserActivity()
        entryOperationState = .running

        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let content = try Data(contentsOf: fileURL)
            let fileName = sanitizedAttachmentPreviewFileName(fileURL.lastPathComponent)
            _ = try replaceKeePassReadOnlyAttachmentContent(
                entryID: entryID,
                attachmentID: attachmentID,
                decodedContent: content,
                fileName: fileName,
                mediaType: mediaType
            )
            let result = try writeKeePassReadOnlySnapshotBackToSource()
            entryOperationState = .succeeded(
                String(localized: "KeePass 附件已替换并写回：\(fileName) \(content.count) 字节")
            )
            return result
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func restoreKeePassReadOnlyRecycleBinEntryAndWriteBack(
        entryID: String,
        targetGroupID: String? = nil
    ) throws -> AppKeePassKdbxWritebackResult {
        recordUserActivity()
        entryOperationState = .running

        do {
            let snapshot: KeePassReadOnlySnapshot
            if let existingSnapshot = keePassReadOnlySnapshot {
                snapshot = existingSnapshot
            } else {
                snapshot = try previewKeePassReadOnlyTree()
            }
            guard let entryIndex = snapshot.entries.firstIndex(where: { $0.id == entryID }) else {
                throw AppKeePassSnapshotEditError.entryUnavailable
            }
            let entry = snapshot.entries[entryIndex]
            guard entry.isDeleted else {
                throw AppKeePassSnapshotEditError.entryNotInRecycleBin
            }
            let recycleBinGroupIDs = Set(snapshot.entries.compactMap { candidate in
                candidate.isDeleted ? candidate.groupID : nil
            })
            let targetGroup: KeePassReadOnlyGroup
            if let originalGroupID = entry.originalGroupID,
               let originalGroup = snapshot.groups.first(where: { group in
                   group.id == originalGroupID && !recycleBinGroupIDs.contains(group.id)
               }) {
                targetGroup = originalGroup
            } else if let originalGroupPath = entry.originalGroupPath,
                      let originalGroup = snapshot.groups.first(where: { group in
                          group.path == originalGroupPath && !recycleBinGroupIDs.contains(group.id)
                      }) {
                targetGroup = originalGroup
            } else if let targetGroupID {
                guard let explicitGroup = snapshot.groups.first(where: { $0.id == targetGroupID }),
                      !recycleBinGroupIDs.contains(explicitGroup.id) else {
                    throw AppKeePassSnapshotEditError.targetGroupUnavailable
                }
                targetGroup = explicitGroup
            } else if let rootGroup = snapshot.groups.first(where: { group in
                group.path == "/" && !recycleBinGroupIDs.contains(group.id)
            }) {
                targetGroup = rootGroup
            } else if let fallbackGroup = snapshot.groups.first(where: { group in
                !recycleBinGroupIDs.contains(group.id)
            }) {
                targetGroup = fallbackGroup
            } else {
                throw AppKeePassSnapshotEditError.targetGroupUnavailable
            }
            let restoredEntry = KeePassReadOnlyEntry(
                id: entry.id,
                title: entry.title,
                username: entry.username,
                url: entry.url,
                groupPath: targetGroup.path,
                groupID: targetGroup.id,
                notes: entry.notes,
                customFields: entry.customFields,
                hasPassword: entry.hasPassword,
                decodedPassword: entry.decodedPassword,
                hasTotp: entry.hasTotp,
                decodedTotp: entry.decodedTotp,
                attachmentCount: entry.attachmentCount,
                isDeleted: false,
                attachments: entry.attachments
            )
            var updatedEntries = snapshot.entries
            updatedEntries[entryIndex] = restoredEntry
            let updatedSnapshot = KeePassReadOnlySnapshot(
                sourceName: snapshot.sourceName,
                headerSummary: snapshot.headerSummary,
                groups: snapshot.groups,
                entries: updatedEntries
            )
            keePassReadOnlySnapshot = updatedSnapshot
            keePassReadOnlyImportPlan = nil
            let result = try writeKeePassReadOnlySnapshotBackToSource()
            let displayTitle = restoredEntry.title.isEmpty ? String(localized: "未命名条目") : restoredEntry.title
            entryOperationState = .succeeded(
                String(localized: "KeePass 回收站条目已还原并写回：\(displayTitle) -> \(targetGroup.path)")
            )
            return result
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func clearKeePassImportState(
        preservingLastMetadataImportReferences: Bool = false
    ) {
        keePassImportPreview = nil
        keePassReadOnlySnapshot = nil
        keePassReadOnlyImportPlan = nil
        keePassPendingDatabaseData = nil
        keePassPendingDatabaseName = nil
        keePassSourceFileURL = nil
        keePassCloudFileSource = nil
        keePassUnlockPassword = ""
        keePassKeyFileData = nil
        keePassKeyFileName = ""
        keePassLastSuccessfulUnlockCredentials = nil
        if !preservingLastMetadataImportReferences {
            keePassLastMetadataImportReferences = []
        }
    }

    func readKeePassSnapshotTryingCredentialCandidates(
        database: Data,
        sourceName: String?,
        credentials: KeePassUnlockCredentials
    ) throws -> (snapshot: KeePassReadOnlySnapshot, credentials: KeePassUnlockCredentials) {
        let candidates = credentials.credentialCandidates
        guard !candidates.isEmpty else {
            let snapshot = try keePassDatabaseReader.readSnapshot(
                database: database,
                sourceName: sourceName,
                credentials: credentials
            )
            return (snapshot, credentials)
        }

        var attemptedLabels: [String] = []
        for candidate in candidates {
            attemptedLabels.append(candidate.label)
            let attemptCredentials = KeePassUnlockCredentials(
                password: candidate.password,
                keyFile: candidate.keyMaterial,
                keyFileName: credentials.keyFileName,
                candidateLabel: candidate.label
            )
            do {
                let snapshot = try keePassDatabaseReader.readSnapshot(
                    database: database,
                    sourceName: sourceName,
                    credentials: attemptCredentials
                )
                return (snapshot, attemptCredentials)
            } catch let error as KeePassOperationError where error.code == .invalidCredential {
                continue
            }
        }

        throw KeePassOperationError(
            code: .invalidCredential,
            message: KeePassCredentialSupport.invalidCredentialMessage(attemptedLabels: attemptedLabels)
        )
    }

    func currentKeePassKdbxEnvelope() throws -> KeePassKdbxPayloadEnvelope {
        guard let databaseData = keePassPendingDatabaseData else {
            let message = String(localized: "请先选择 KDBX 数据库文件")
            throw KeePassOperationError(code: .formatUnsupported, message: message)
        }
        return try KeePassKdbxPayloadEnvelope.parse(databaseData)
    }

    func keePassKdbxWritebackParameters() throws -> (
        envelope: KeePassKdbxPayloadEnvelope,
        cipher: KeePassKdbxCipherAlgorithm,
        compression: KeePassKdbxCompressionAlgorithm,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs,
        kdfParameters: KeePassKdbxKdfParameters,
        credentials: KeePassUnlockCredentials
    ) {
        let envelope = try currentKeePassKdbxEnvelope()
        guard let cipher = envelope.headerSummary.cryptoSummary?.cipher else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: String(localized: "KDBX cipher 参数缺失；请确认文件未损坏。")
            )
        }
        guard let compression = envelope.headerSummary.cryptoSummary?.compression else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: String(localized: "KDBX compression 参数缺失；请确认文件未损坏。")
            )
        }
        guard let kdfParameters = envelope.headerSummary.kdfParameters else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: String(localized: "KDBX KDF 参数缺失；请确认文件未损坏。")
            )
        }
        let credentials = keePassLastSuccessfulUnlockCredentials ?? KeePassUnlockCredentials(
            password: keePassUnlockPassword,
            keyFile: keePassKeyFileData,
            keyFileName: keePassKeyFileName
        )
        return (
            envelope,
            cipher,
            compression,
            KeePassFormatInspector.parseKdbxPayloadCryptoInputs(from: envelope),
            kdfParameters,
            credentials
        )
    }

    func makeKeePassKdbx3WritebackRequest(
        snapshot: KeePassReadOnlySnapshot
    ) throws -> KeePassKdbx3WritebackRequest {
        let parameters = try keePassKdbxWritebackParameters()
        guard parameters.envelope.headerSummary.formatVersion == .kdbx3 else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: String(localized: "当前仅支持 KDBX3 数据库写回。")
            )
        }
        return KeePassKdbx3WritebackRequest(
            snapshot: snapshot,
            credentials: parameters.credentials,
            cipher: parameters.cipher,
            compression: parameters.compression,
            cryptoInputs: parameters.cryptoInputs,
            kdfParameters: parameters.kdfParameters,
            existingHeaderBytes: parameters.envelope.headerBytes
        )
    }

    func makeKeePassKdbx4WritebackRequest(
        snapshot: KeePassReadOnlySnapshot
    ) throws -> KeePassKdbx4WritebackRequest {
        let parameters = try keePassKdbxWritebackParameters()
        let envelope = parameters.envelope
        guard envelope.headerSummary.formatVersion == .kdbx4 else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: String(localized: "当前仅支持 KDBX4 数据库写回。")
            )
        }
        return KeePassKdbx4WritebackRequest(
            snapshot: snapshot,
            credentials: parameters.credentials,
            cipher: parameters.cipher,
            compression: parameters.compression,
            cryptoInputs: parameters.cryptoInputs,
            kdfParameters: parameters.kdfParameters,
            existingHeaderBytes: envelope.headerBytes
        )
    }

    func ensureKeePassImportProject(
        baseTitle: String,
        groupPath: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> LocalVaultProject {
        // 每个 KeePass 组路径对应一个扁平分类；层级只保留在标题里，用 " · " 连接，
        // 避免 "/" 触发文件夹名校验，也让同一个组的所有条目落在同一个分类中。
        let title = keePassImportProjectTitle(baseTitle: baseTitle, groupPath: groupPath)
        // 用项目（而不是文件夹记录）承载导入分类：KeePass 的组路径只是扁平标签，
        // 不参与层级校验；下次读取森林时 #27 的旧库导入会把它补成根文件夹。
        if let existing = try? entryRepository.listProjects().first(where: { $0.title == title }) {
            if !vaultProjects.contains(where: { $0.id == existing.id }) {
                vaultProjects.append(existing)
            }
            return existing
        }
        let project = try entryRepository.createProject(title: title)
        if !vaultProjects.contains(where: { $0.id == project.id }) {
            vaultProjects.append(project)
        }
        return project
    }

    func keePassImportProjectTitle(baseTitle: String, groupPath: String) -> String {
        let trimmedBase = baseTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmedBase.isEmpty ? "KeePass" : trimmedBase
        let components = groupPath
            .split(separator: "/")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return ([base] + components).joined(separator: " · ")
    }

    func keePassTotpDraft(
        for candidate: KeePassReadOnlyImportCandidate
    ) -> LocalTotpEntryDraft {
        let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseTitle = title.isEmpty ? "KeePass TOTP" : title
        let decodedTotp = candidate.decodedTotp
        return LocalTotpEntryDraft(
            title: keePassTotpPlaceholderTitle(from: baseTitle),
            secret: decodedTotp?.secret ?? "",
            issuer: decodedTotp?.issuer?.nonBlankValue ?? baseTitle,
            accountName: decodedTotp?.accountName?.nonBlankValue ?? candidate.username,
            period: decodedTotp?.period ?? 30,
            digits: decodedTotp?.digits ?? 6,
            algorithm: decodedTotp?.algorithm?.nonBlankValue ?? "SHA1",
            otpType: "TOTP",
            counter: 0
        )
    }

    func keePassLoginNotes(for candidate: KeePassReadOnlyImportCandidate) -> String {
        var sections: [String] = []
        let notes = candidate.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            sections.append(notes)
        }
        let fieldLines = candidate.customFields
            .filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { field in
                let title = field.title.trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(title): \(field.value)"
            }
        if !fieldLines.isEmpty {
            sections.append(([String(localized: "KeePass 字段：")] + fieldLines).joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    func keePassTotpPlaceholderTitle(from baseTitle: String) -> String {
        let lowercased = baseTitle.lowercased()
        if lowercased.contains("totp") ||
            lowercased.contains("2fa") ||
            lowercased.contains("authenticator") {
            return baseTitle
        }
        return "\(baseTitle) TOTP"
    }

    func keePassAttachmentFileName(_ attachment: KeePassReadOnlyAttachment) -> String {
        let trimmed = attachment.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "KeePass Attachment"
        }
        return sanitizedAttachmentPreviewFileName(trimmed)
    }

    func keePassDecodedAttachmentLocalPath(
        _ attachment: KeePassReadOnlyAttachment,
        fileName: String
    ) -> String {
        let rawIdentifier = attachment.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = rawIdentifier.isEmpty ? UUID().uuidString : rawIdentifier
        return sanitizedAttachmentPreviewFileName(
            "keepass-kdbx-attachment-\(identifier)-\(fileName)"
        )
    }

    func sanitizedKeePassFileName(_ value: String) -> String? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? value
        let sanitized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? nil : sanitized
    }
}
