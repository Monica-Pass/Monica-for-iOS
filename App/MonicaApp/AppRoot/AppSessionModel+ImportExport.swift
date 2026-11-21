import Foundation
import MonicaCore
import MonicaStorage
import UniformTypeIdentifiers

// slice C3: ImportExport 域（CSV / 传输文件 / 加密格式 / Android 备份导入导出、导出文档构造），从 AppSessionModel.swift 逐字搬移。
extension AppSessionModel {
    func previewCSVImport(_ csv: String) -> CSVImportPreview {
        recordUserActivity()
        let report = VaultCSVCodec.importItems(from: csv)
        let preview = CSVImportPreview(report: report)
        csvImportPreview = preview
        androidBackupImportPreview = nil
        clearKeePassImportState()
        entryOperationState = .succeeded(String(localized: "CSV 预览：\(report.items.count) 项可导入，\(report.issues.count) 个问题"))
        return preview
    }

    func previewCSVImport(from fileURL: URL) throws -> CSVImportPreview {
        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        let csv = try String(contentsOf: fileURL, encoding: .utf8)
        return previewCSVImport(csv)
    }

    func confirmCSVImport(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let preview = csvImportPreview else {
                throw LocalVaultRepositoryError.invalidEntryPayload
            }
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let project = try ensureActiveProject(projectTitle: projectTitle, entryRepository: entryRepository)
            for item in preview.items {
                _ = try createCSVImportedItem(item, projectID: project.id, entryRepository: entryRepository)
            }
            try refreshAllEntryLists(projectID: project.id, entryRepository: entryRepository)
            try refreshAutoFillEncryptedIndexIfConfigured()
            csvImportPreview = nil
            entryOperationState = .succeeded(String(localized: "CSV 已导入 \(preview.items.count) 项"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    /// 只解析、不写库：format sniffing 与逐条错误都来自 Storage 层。
    func previewTransferImport(
        data: Data,
        fileName: String?,
        contentType: String?,
        password: String? = nil
    ) -> VaultImportResult {
        VaultImportEngine.preview(
            data: data,
            fileName: fileName,
            contentType: contentType,
            options: VaultImportOptions(
                password: password,
                existingLoginEntries: loginEntries,
                existingTotpEntries: totpEntries
            )
        )
    }

    /// 用户确认后逐条写入；自定义字段跟随条目写入侧表。
    func importTransferItems(_ items: [VaultTransferItem], projectTitle: String) throws -> Int {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project = try ensureActiveProject(projectTitle: projectTitle, entryRepository: entryRepository)

            var importedCount = 0
            for item in items {
                guard let itemID = try createCSVImportedItem(
                    item.draft,
                    projectID: project.id,
                    entryRepository: entryRepository
                ) else {
                    continue
                }
                if !item.customFields.isEmpty {
                    _ = try entryRepository.saveItemExtras(
                        projectID: project.id,
                        extras: VaultItemExtras(
                            itemID: itemID,
                            itemKind: item.draft.kind,
                            customFields: item.customFields
                        )
                    )
                }
                importedCount += 1
            }

            try refreshAllEntryLists(projectID: project.id, entryRepository: entryRepository)
            try refreshAutoFillEncryptedIndexIfConfigured()
            entryOperationState = .succeeded(String(localized: "已导入 \(importedCount) 项"))
            return importedCount
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    /// 导出用的统一模型：条目 + 自定义字段；`sourceID` 只会写进导出的 JSON，不写日志。
    func transferItems(includeCustomFields: Bool) -> [VaultTransferItem] {
        let rows = csvExportRows()
        var extrasByItemID: [String: VaultItemExtras] = [:]
        if includeCustomFields,
           let entryRepository = activeEntryRepository,
           let project = activeProject {
            extrasByItemID = (try? entryRepository.listItemExtras(projectID: project.id)) ?? [:]
        }
        return rows.enumerated().map { index, row in
            VaultTransferItem(
                draft: row.draft,
                customFields: includeCustomFields ? (extrasByItemID[row.itemID]?.customFields ?? []) : [],
                sourceIndex: index,
                sourceID: row.itemID
            )
        }
    }

    /// 从文件选择器拿到的 URL 读取数据；只预览，不写库。
    @discardableResult
    func beginFormatImport(from fileURL: URL) throws -> FormatImportPreview {
        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: fileURL)
        let contentType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
        return beginFormatImport(
            data: data,
            fileName: fileURL.lastPathComponent,
            contentType: contentType
        )
    }

    /// 解析并缓存预览；密码只留在内存里，不写日志。
    @discardableResult
    func beginFormatImport(
        data: Data,
        fileName: String?,
        contentType: String?,
        password: String? = nil
    ) -> FormatImportPreview {
        recordUserActivity()
        let result = previewTransferImport(
            data: data,
            fileName: fileName,
            contentType: contentType,
            password: password
        )
        let preview = FormatImportPreview(result: result, fileName: fileName)
        formatImportPreview = preview
        csvImportPreview = nil
        androidBackupImportPreview = nil
        clearKeePassImportState()
        pendingFormatImportData = data
        pendingFormatImportFileName = fileName
        pendingFormatImportContentType = contentType
        entryOperationState = .succeeded(
            String(localized: "格式预览：可导入 \(preview.itemCount) 项，\(preview.issues.count) 个问题")
        )
        return preview
    }

    /// 加密文件：用界面上输入的密码重试一次，输入后立即清空密码。
    @discardableResult
    func previewEncryptedFormatImport() -> FormatImportPreview? {
        guard let data = pendingFormatImportData else {
            return nil
        }
        let password = formatImportPassword
        formatImportPassword = ""
        return beginFormatImport(
            data: data,
            fileName: pendingFormatImportFileName,
            contentType: pendingFormatImportContentType,
            password: password
        )
    }

    func cancelFormatImport() {
        formatImportPreview = nil
        formatImportPassword = ""
        pendingFormatImportData = nil
        pendingFormatImportFileName = nil
        pendingFormatImportContentType = nil
    }

    /// 用户确认后逐条写入；自定义字段跟随条目写入侧表。
    @discardableResult
    func confirmFormatImport(projectTitle: String) throws -> Int {
        guard let preview = formatImportPreview, preview.canImport else {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        let importedCount = try importTransferItems(preview.result.items, projectTitle: projectTitle)
        cancelFormatImport()
        entryOperationState = .succeeded(String(localized: "已导入 \(importedCount) 项"))
        return importedCount
    }

    /// 导出：CSV / JSON，可选自定义字段与加密密码；明文确认由界面负责。
    func exportTransferArtifact(
        format: VaultExportFormat,
        includeCustomFields: Bool,
        encryptionPassword: String?
    ) throws -> VaultExportArtifact {
        recordUserActivity()
        let items = transferItems(includeCustomFields: includeCustomFields)
        return try VaultExportEngine.export(
            items: items,
            options: VaultExportOptions(
                format: format,
                includeCustomFields: includeCustomFields,
                encryptionPassword: encryptionPassword
            )
        )
    }

    func previewAndroidBackupImport(
        _ data: Data,
        fileName: String? = nil,
        decryptPassword: String? = nil
    ) throws -> AndroidBackupImportPreview {
        recordUserActivity()
        let report = try AndroidBackupCodec.importItems(
            from: data,
            fileName: fileName,
            decryptPassword: decryptPassword
        )
        if let encryptedIssue = report.issues.first(where: { $0.code == .encryptedBackupUnsupported }) {
            androidBackupImportPreview = nil
            csvImportPreview = nil
            clearKeePassImportState()
            entryOperationState = .failed(encryptedIssue.message)
            throw AppAndroidBackupImportError.unsupportedEncryptedBackup(encryptedIssue.message)
        }
        if let decryptIssue = report.issues.first(where: { $0.code == .encryptedBackupDecryptionFailed }) {
            androidBackupImportPreview = nil
            csvImportPreview = nil
            clearKeePassImportState()
            entryOperationState = .failed(decryptIssue.message)
            throw AppAndroidBackupImportError.encryptedBackupDecryptionFailed(decryptIssue.message)
        }
        let preview = AndroidBackupImportPreview(report: report)
        androidBackupImportPreview = preview
        csvImportPreview = nil
        clearKeePassImportState()
        clearPendingAndroidEncryptedBackup()
        let trashText = report.deletedItems.isEmpty ? "" : String(localized: "，\(report.deletedItems.count) 项回收站")
        let attachmentText = report.attachments.isEmpty ? "" : String(localized: "，\(report.attachments.count) 个附件")
        entryOperationState = .succeeded(String(localized: "移动端备份预览：\(report.items.count) 项可导入\(trashText)\(attachmentText)，\(report.issues.count) 个问题"))
        return preview
    }

    func previewAndroidBackupImport(from fileURL: URL) throws -> AndroidBackupImportPreview {
        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: fileURL)
        return try previewAndroidBackupImport(data, fileName: fileURL.lastPathComponent)
    }

    func prepareAndroidBackupImport(from fileURL: URL) throws -> AndroidBackupImportPreview? {
        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: fileURL)
        do {
            let preview = try previewAndroidBackupImport(data, fileName: fileURL.lastPathComponent)
            clearPendingAndroidEncryptedBackup()
            return preview
        } catch AppAndroidBackupImportError.unsupportedEncryptedBackup {
            pendingAndroidEncryptedBackupData = data
            pendingAndroidEncryptedBackupFileName = fileURL.lastPathComponent
            androidBackupDecryptPassword = ""
            entryOperationState = .failed(String(localized: "请输入移动端加密备份密码。"))
            return nil
        } catch {
            clearPendingAndroidEncryptedBackup()
            throw error
        }
    }

    func previewPendingAndroidEncryptedBackupImport() throws -> AndroidBackupImportPreview {
        recordUserActivity()
        guard let data = pendingAndroidEncryptedBackupData,
              let fileName = pendingAndroidEncryptedBackupFileName else {
            throw AppAndroidBackupImportError.encryptedBackupUnavailable
        }
        let password = androidBackupDecryptPassword
        androidBackupDecryptPassword = ""

        do {
            let preview = try previewAndroidBackupImport(
                data,
                fileName: fileName,
                decryptPassword: password
            )
            clearPendingAndroidEncryptedBackup()
            return preview
        } catch AppAndroidBackupImportError.encryptedBackupDecryptionFailed(let message) {
            throw AppAndroidBackupImportError.encryptedBackupDecryptionFailed(message)
        } catch {
            clearPendingAndroidEncryptedBackup()
            throw error
        }
    }

    func cancelPendingAndroidEncryptedBackupImport() {
        recordUserActivity()
        clearPendingAndroidEncryptedBackup()
        if androidBackupImportPreview == nil {
            entryOperationState = .idle
        }
    }

    func confirmAndroidBackupImport(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let preview = androidBackupImportPreview else {
                throw LocalVaultRepositoryError.invalidEntryPayload
            }
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let vaultSession = try requireActiveVaultSession()

            let project = try ensureActiveProject(projectTitle: projectTitle, entryRepository: entryRepository)
            var importedLoginIDsByAndroidID: [Int64: String] = [:]
            for importedItem in preview.report.importedItems {
                let createdEntryID = try createCSVImportedItem(
                    importedItem.draft,
                    projectID: project.id,
                    entryRepository: entryRepository
                )
                if let createdEntryID {
                    try applyImportedEntryMetadata(
                        importedItem.metadata,
                        entryID: createdEntryID,
                        projectID: project.id,
                        entryRepository: entryRepository
                    )
                }
                if case .login = importedItem.draft,
                   let sourceID = importedItem.sourceID,
                   let createdEntryID {
                    importedLoginIDsByAndroidID[sourceID] = createdEntryID
                }
            }
            var deletedItemCount = 0
            for importedItem in preview.deletedItems {
                guard let createdEntryID = try createCSVImportedItem(
                    importedItem.draft,
                    projectID: project.id,
                    entryRepository: entryRepository
                ) else {
                    continue
                }
                try deleteCSVImportedItem(
                    importedItem.draft,
                    entryID: createdEntryID,
                    projectID: project.id,
                    entryRepository: entryRepository
                )
                deletedItemCount += 1
            }
            var savedAttachmentBlobCount = 0
            for attachment in preview.attachments {
                let encryptedBlobLocalPath: String?
                if let encryptedBlob = attachment.encryptedBlob {
                    encryptedBlobLocalPath = try androidBackupAttachmentBlobStore.saveEncryptedBlob(
                        encryptedBlob,
                        vaultID: vaultSession.handle.vaultID,
                        localPath: attachment.localPath
                    )
                    savedAttachmentBlobCount += 1
                } else {
                    encryptedBlobLocalPath = nil
                }
                _ = try entryRepository.createAttachmentMetadata(
                    projectID: project.id,
                    entryID: importedLoginIDsByAndroidID[attachment.parentPasswordID],
                    fileName: attachment.fileName,
                    mediaType: attachment.mediaType,
                    originalSize: attachment.originalSize,
                    storedSize: Int64(attachment.encryptedBlob?.count ?? 0),
                    contentHash: attachment.contentHash,
                    storageMode: encryptedBlobLocalPath == nil ? "android-backup-pending" : "android-backup-encrypted-blob",
                    source: "android-backup-local",
                    downloadState: encryptedBlobLocalPath == nil ? "missing-blob" : "downloaded",
                    wrappedContentEncryptionKey: encryptedBlobLocalPath == nil ? nil : attachment.wrappedContentEncryptionKey,
                    localPath: encryptedBlobLocalPath
                )
            }
            try refreshAllEntryLists(projectID: project.id, entryRepository: entryRepository)
            try refreshAutoFillEncryptedIndexIfConfigured()
            androidBackupImportPreview = nil
            let attachmentText: String
            if preview.attachments.isEmpty {
                attachmentText = ""
            } else if savedAttachmentBlobCount == preview.attachments.count {
                attachmentText = String(localized: "；\(savedAttachmentBlobCount) 个附件密文待恢复")
            } else if savedAttachmentBlobCount > 0 {
                attachmentText = String(localized: "；\(savedAttachmentBlobCount) 个附件密文待恢复，\(preview.attachments.count - savedAttachmentBlobCount) 个附件元数据待恢复")
            } else {
                attachmentText = String(localized: "；\(preview.attachments.count) 个附件元数据待恢复")
            }
            let trashText = deletedItemCount == 0 ? "" : String(localized: "；\(deletedItemCount) 项进入回收站")
            entryOperationState = .succeeded(String(localized: "移动端备份已导入 \(preview.items.count) 项\(attachmentText)\(trashText)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    /// 备份里的标签与归档标记写回到新建条目（旧备份没有这些字段时为元数据为空）。
    func applyImportedEntryMetadata(
        _ metadata: VaultEntryMetadata,
        entryID: String,
        projectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws {
        guard metadata.isArchived || !metadata.tags.isEmpty else { return }
        if !metadata.tags.isEmpty {
            try entryRepository.setEntryTags(
                projectID: projectID,
                entryID: entryID,
                tags: metadata.tags
            )
        }
        if metadata.isArchived {
            try entryRepository.setEntryArchived(
                projectID: projectID,
                entryID: entryID,
                archived: true
            )
        }
    }

    func androidBackupExportDocument() throws -> AndroidBackupExportDocument {
        AndroidBackupExportDocument(data: try exportAndroidBackup())
    }

    func exportAndroidBackup() throws -> Data {
        recordUserActivity()
        entryOperationState = .running

        do {
            _ = try requireActiveVaultSession()
            let drafts = csvExportDrafts()
            let data = try AndroidBackupCodec.exportItems(drafts)
            entryOperationState = .succeeded(String(localized: "移动端备份已导出 \(drafts.count) 项"))
            return data
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func csvExportDocument() throws -> CSVExportDocument {
        CSVExportDocument(text: try exportCSV())
    }

    func exportCSV() throws -> String {
        recordUserActivity()
        entryOperationState = .running

        do {
            _ = try requireActiveVaultSession()
            let drafts = csvExportDrafts()
            let csv = VaultCSVCodec.exportItems(drafts)
            entryOperationState = .succeeded(String(localized: "CSV 已导出 \(drafts.count) 项"))
            return csv
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func csvExportDrafts() -> [VaultCSVItemDraft] {
        csvExportRows().map(\.draft)
    }

    /// 导出用的条目行：保留本地条目 ID，便于把自定义字段侧表一起带走。
    func csvExportRows() -> [(itemID: String, draft: VaultCSVItemDraft)] {
        var rows: [(itemID: String, draft: VaultCSVItemDraft)] = []
        rows += loginEntries.map {
            (itemID: $0.id, draft: .login(LocalLoginEntryDraft(
                title: $0.title,
                username: $0.username,
                account: $0.account,
                password: $0.password,
                url: $0.url,
                notes: $0.notes,
                urls: $0.effectiveURLs,
                metadata: $0.metadata
            )))
        }
        rows += noteEntries.map {
            (itemID: $0.id, draft: .note(LocalNoteEntryDraft(
                title: $0.title,
                body: $0.body,
                metadata: $0.metadata
            )))
        }
        rows += totpEntries.map {
            (itemID: $0.id, draft: .totp(LocalTotpEntryDraft(
                title: $0.title,
                secret: $0.secret,
                issuer: $0.issuer,
                accountName: $0.accountName,
                period: $0.period,
                digits: $0.digits,
                algorithm: $0.algorithm,
                otpType: $0.otpType,
                counter: $0.counter,
                metadata: $0.metadata
            )))
        }
        rows += cardEntries.map {
            (itemID: $0.id, draft: .card(LocalCardEntryDraft(
                title: $0.title,
                cardholderName: $0.cardholderName,
                number: $0.number,
                expiryMonth: $0.expiryMonth,
                expiryYear: $0.expiryYear,
                cvv: $0.cvv,
                issuer: $0.issuer,
                network: $0.network,
                iban: $0.iban,
                swiftCode: $0.swiftCode,
                billingAddress: $0.billingAddress,
                cardArtwork: $0.cardArtwork,
                notes: $0.notes,
                metadata: $0.metadata
            )))
        }
        rows += identityEntries.map {
            (itemID: $0.id, draft: .identity(LocalIdentityEntryDraft(
                title: $0.title,
                documentType: $0.documentType,
                fullName: $0.fullName,
                documentNumber: $0.documentNumber,
                issuer: $0.issuer,
                country: $0.country,
                issueDate: $0.issueDate,
                expiryDate: $0.expiryDate,
                notes: $0.notes,
                metadata: $0.metadata
            )))
        }
        rows += passkeyEntries.map {
            (itemID: $0.id, draft: .passkey(LocalPasskeyEntryDraft(
                title: $0.title,
                relyingPartyID: $0.relyingPartyID,
                username: $0.username,
                userHandle: $0.userHandle,
                credentialID: $0.credentialID,
                publicKeyCOSE: $0.publicKeyCOSE,
                privateKeyReference: $0.privateKeyReference,
                notes: $0.notes,
                metadata: $0.metadata
            )))
        }
        rows += sshKeyEntries.map {
            (itemID: $0.id, draft: .sshKey(LocalSshKeyEntryDraft(
                title: $0.title,
                username: $0.username,
                host: $0.host,
                publicKey: $0.publicKey,
                privateKeyReference: $0.privateKeyReference,
                passphraseHint: $0.passphraseHint,
                notes: $0.notes,
                metadata: $0.metadata
            )))
        }
        rows += apiTokenEntries.map {
            (itemID: $0.id, draft: .apiToken(LocalApiTokenEntryDraft(
                title: $0.title,
                issuer: $0.issuer,
                accountName: $0.accountName,
                token: $0.token,
                scopes: $0.scopes,
                expiresAt: $0.expiresAt,
                notes: $0.notes,
                metadata: $0.metadata
            )))
        }
        rows += wifiEntries.map {
            (itemID: $0.id, draft: .wifi(LocalWifiEntryDraft(
                title: $0.title,
                ssid: $0.ssid,
                securityType: $0.securityType,
                password: $0.password,
                hidden: $0.hidden,
                notes: $0.notes,
                metadata: $0.metadata
            )))
        }
        rows += ssoEntries.map {
            (itemID: $0.id, draft: .sso(LocalSSOEntryDraft(
                title: $0.title,
                provider: $0.provider,
                providerName: $0.providerName,
                issuer: $0.issuer,
                accountName: $0.accountName,
                loginURL: $0.loginURL,
                linkedLoginEntryID: $0.linkedLoginEntryID,
                notes: $0.notes,
                secret: $0.secret,
                metadata: $0.metadata
            )))
        }
        rows += barcodeEntries.map {
            (itemID: $0.id, draft: .barcode(LocalBarcodeEntryDraft(
                title: $0.title,
                symbology: $0.symbology,
                payload: $0.payload,
                label: $0.label,
                notes: $0.notes
            )))
        }
        rows += sendEntries.map {
            (itemID: $0.id, draft: .send(LocalSendEntryDraft(
                title: $0.title,
                body: $0.body,
                expiresAt: $0.expiresAt,
                maxViews: $0.maxViews,
                notes: $0.notes,
                metadata: $0.metadata
            )))
        }
        rows += steamEntries.map {
            (itemID: $0.id, draft: .steam(LocalSteamEntryDraft(
                title: $0.title,
                accountName: $0.accountName,
                steamID: $0.steamID,
                sharedSecret: $0.sharedSecret,
                issuer: $0.issuer,
                notes: $0.notes,
                metadata: $0.metadata
            )))
        }
        rows += billingAddressEntries.map {
            (itemID: $0.id, draft: .billingAddress(LocalBillingAddressEntryDraft(
                title: $0.title,
                fullName: $0.fullName,
                streetAddress: $0.streetAddress,
                apartment: $0.apartment,
                city: $0.city,
                stateProvince: $0.stateProvince,
                postalCode: $0.postalCode,
                country: $0.country,
                phone: $0.phone,
                notes: $0.notes,
                linkedCardIDs: $0.linkedCardIDs
            )))
        }
        rows += paymentAccountEntries.map {
            (itemID: $0.id, draft: .paymentAccount(LocalPaymentAccountEntryDraft(
                title: $0.title,
                kind: $0.kind,
                provider: $0.provider,
                accountName: $0.accountName,
                accountHolderName: $0.accountHolderName,
                iban: $0.iban,
                swiftBIC: $0.swiftBIC,
                routingNumber: $0.routingNumber,
                accountNumber: $0.accountNumber,
                currency: $0.currency,
                notes: $0.notes,
                linkedCardID: $0.linkedCardID,
                billingAddressID: $0.billingAddressID
            )))
        }
        return rows
    }
}
