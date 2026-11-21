//
//  AppSessionModel+CloudBackup.swift
//  Monica
//
//  slice C2：云备份（OneDrive / WebDAV / 云文件），从 AppSessionModel.swift 逐字搬移。
//

import Foundation
import MonicaCore
import MonicaStorage
import MonicaSync

extension AppSessionModel {
    func uploadActiveVaultBackup() async throws {
        recordUserActivity()
        webDAVBackupState = .running

        do {
            let session = try requireActiveVaultSession()
            let endpoint = try makeWebDAVEndpoint()
            let fileName = try normalizedWebDAVRemoteFileName(
                fallback: session.descriptor.fileURL.lastPathComponent
            )
            let data = try Data(contentsOf: session.descriptor.fileURL)
            let receipt = try await webDAVBackupService.upload(
                endpoint: endpoint,
                package: WebDAVBackupPackage(fileName: fileName, data: data)
            )
            webDAVPassword = ""
            webDAVRestorePreview = nil
            webDAVBackupState = .backupSucceeded(
                byteCount: receipt.byteCount,
                sha256: receipt.sha256
            )
            appendOperationTimelineEvent(
                action: .backedUp,
                itemKind: .attachmentRef,
                itemID: "webdav-upload",
                itemTitle: "WebDAV \(fileName)"
            )
        } catch {
            handleWebDAVFailure(error)
            appendOperationTimelineEvent(
                action: .backedUp,
                itemKind: .attachmentRef,
                itemID: "webdav-upload",
                itemTitle: "WebDAV backup",
                result: "failed",
                errorCategory: "WebDAV"
            )
            throw error
        }
    }

    func refreshCloudFileItems(provider kind: CloudFileProviderKind) async throws -> [CloudFileItem] {
        recordUserActivity()
        cloudFileState = .running(kind)

        do {
            let provider = try cloudFileProvider(for: kind)
            if kind == .oneDrive,
               let directoryProvider = provider as? any CloudFileBackupDirectoryProviding {
                return try await refreshOneDriveBackupDirectory(using: directoryProvider)
            }
            let items = try await provider.listFiles()
            cloudFileItemsByProvider[kind] = items
            cloudFileState = .listed(provider: kind, count: items.count)
            return items
        } catch {
            cloudFileState = .failed(readableCloudFileErrorMessage(for: error, provider: kind))
            throw error
        }
    }

    func refreshOneDriveBackupDirectory(
        using provider: any CloudFileBackupDirectoryProviding
    ) async throws -> [CloudFileItem] {
        let selectedDirectoryID = oneDriveBackupPreferences.directory?.id
        do {
            let listing = try await provider.listBackupDirectory(id: selectedDirectoryID)
            if let directory = listing.directory {
                if oneDriveBackupPreferences.directory != directory {
                    oneDriveBackupPreferences.directory = directory
                    persistOneDriveBackupPreferences()
                }
                oneDriveBackupDirectoryState = .available(directory.displayPath)
                await loadOneDriveDefaultLocationFiles(using: provider)
            } else {
                oneDriveBackupDirectoryState = .unknown
                oneDriveDefaultLocationFiles = []
            }
            cloudFileItemsByProvider[.oneDrive] = listing.files
            cloudFileState = .listed(provider: .oneDrive, count: listing.files.count)
            return listing.files
        } catch let error as CloudFileProviderError
            where error == .itemNotFound(provider: .oneDrive) {
            oneDriveBackupDirectoryState = .missing
            cloudFileItemsByProvider[.oneDrive] = []
            await loadOneDriveDefaultLocationFiles(using: provider)
            throw error
        }
    }

    func loadOneDriveDefaultLocationFiles(
        using provider: any CloudFileBackupDirectoryProviding
    ) async {
        guard let listing = try? await provider.listBackupDirectory(id: nil) else {
            return
        }
        oneDriveDefaultLocationFiles = listing.files
    }

    func refreshWebDAVBackupItems() async throws -> [WebDAVBackupItem] {
        recordUserActivity()
        webDAVBackupState = .running
        do {
            _ = try requireActiveVaultSession()
            let endpoint = try makeWebDAVEndpoint()
            let backups = try await webDAVBackupService.listBackups(endpoint: endpoint)
            webDAVBackupItems = backups
            webDAVPassword = ""
            webDAVBackupState = .listed(count: backups.count)
            return backups
        } catch {
            handleWebDAVFailure(error)
            throw error
        }
    }

    func deleteWebDAVBackupItem(_ item: WebDAVBackupItem) async throws {
        recordUserActivity()
        webDAVBackupState = .running
        do {
            _ = try requireActiveVaultSession()
            let endpoint = try makeWebDAVEndpoint()
            try await webDAVBackupService.deleteBackup(endpoint: endpoint, fileName: item.fileName)
            webDAVBackupItems.removeAll { $0.id == item.id }
            webDAVPassword = ""
            webDAVBackupState = .deleted(fileName: item.fileName)
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .attachmentRef,
                itemID: "webdav-\(item.id)",
                itemTitle: "WebDAV \(item.fileName)"
            )
        } catch {
            handleWebDAVFailure(error)
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .attachmentRef,
                itemID: "webdav-delete",
                itemTitle: "WebDAV backup",
                result: "failed",
                errorCategory: "WebDAV"
            )
            throw error
        }
    }

    func setWebDAVBackupItemPermanent(_ item: WebDAVBackupItem, isPermanent: Bool) async throws {
        recordUserActivity()
        webDAVBackupState = .running
        do {
            _ = try requireActiveVaultSession()
            let endpoint = try makeWebDAVEndpoint()
            let updated = try await webDAVBackupService.setBackupPermanent(
                endpoint: endpoint,
                fileName: item.fileName,
                isPermanent: isPermanent
            )
            if let index = webDAVBackupItems.firstIndex(where: { $0.id == item.id }) {
                webDAVBackupItems[index] = WebDAVBackupItem(
                    fileName: updated.fileName,
                    byteCount: item.byteCount,
                    modifiedAt: item.modifiedAt
                )
            }
            webDAVPassword = ""
            webDAVBackupState = .permanentUpdated(fileName: updated.fileName, isPermanent: isPermanent)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .attachmentRef,
                itemID: "webdav-\(updated.id)",
                itemTitle: "WebDAV \(updated.fileName)"
            )
        } catch {
            handleWebDAVFailure(error)
            throw error
        }
    }

    func cleanupExpiredWebDAVBackups() async throws {
        recordUserActivity()
        webDAVBackupState = .running
        do {
            _ = try requireActiveVaultSession()
            let endpoint = try makeWebDAVEndpoint()
            let cutoff = Calendar.current.date(
                byAdding: .day,
                value: -max(1, webDAVBackupRetentionDays),
                to: Date()
            ) ?? Date(timeIntervalSinceNow: -30 * 24 * 60 * 60)
            let deleted = try await webDAVBackupService.cleanupBackups(
                endpoint: endpoint,
                backups: webDAVBackupItems,
                olderThan: cutoff
            )
            let deletedIDs = Set(deleted.map(\.id))
            webDAVBackupItems.removeAll { deletedIDs.contains($0.id) }
            webDAVPassword = ""
            webDAVBackupState = .cleanupSucceeded(count: deleted.count)
            appendOperationTimelineEvent(
                action: .cleanedUp,
                itemKind: .attachmentRef,
                itemID: "webdav-cleanup",
                itemTitle: "WebDAV \(deleted.count) backups"
            )
        } catch {
            handleWebDAVFailure(error)
            throw error
        }
    }

    func scheduleBackgroundWebDAVBackup() async {
        webDAVBackgroundBackupEnabled = true
        webDAVBackgroundBackupSchedulerState = await backgroundBackupScheduler.scheduleNextBackup(after: 12 * 60 * 60)
        appendOperationTimelineEvent(
            action: .updated,
            itemKind: .attachmentRef,
            itemID: "webdav-background",
            itemTitle: String(localized: "自动备份")
        )
    }

    func disableBackgroundWebDAVBackup() {
        webDAVBackgroundBackupEnabled = false
        webDAVBackgroundBackupSchedulerState = .idle
        appendOperationTimelineEvent(
            action: .updated,
            itemKind: .attachmentRef,
            itemID: "webdav-background",
            itemTitle: String(localized: "自动备份")
        )
    }

    func signInToOneDrive() async throws -> AppOneDriveAuthenticationSession {
        recordUserActivity()
        guard let oneDriveAuthenticationService else {
            let error = AppOneDriveAuthenticationError.serviceUnavailable
            oneDriveAuthenticationState = .failed(error.localizedDescription)
            throw error
        }
        oneDriveAuthenticationState = .running
        clearOneDriveSessionState()
        do {
            let session = try await oneDriveAuthenticationService.signIn()
            oneDriveAuthenticationState = .connected(accountLabel: session.accountLabel)
            applyOneDriveSession(session)
            await loadOneDriveAccounts()
            return session
        } catch {
            oneDriveAuthenticationState = .failed(readableOneDriveAuthenticationErrorMessage(error))
            throw error
        }
    }

    @discardableResult
    func restoreOneDriveAuthenticationSession() async throws -> AppOneDriveAuthenticationSession? {
        guard let oneDriveAuthenticationService else {
            clearOneDriveSessionState()
            oneDriveAuthenticationState = .disconnected
            return nil
        }

        do {
            let session = try await oneDriveAuthenticationService.restoreSession()
            clearOneDriveSessionState()
            guard let session else {
                oneDriveAuthenticationState = .disconnected
                oneDriveAccounts = []
                return nil
            }
            oneDriveAuthenticationState = .connected(accountLabel: session.accountLabel)
            applyOneDriveSession(session)
            await loadOneDriveAccounts()
            return session
        } catch {
            oneDriveAuthenticationState = .failed(readableOneDriveAuthenticationErrorMessage(error))
            throw error
        }
    }

    func signOutFromOneDrive() async throws {
        recordUserActivity()
        guard let oneDriveAuthenticationService else {
            let error = AppOneDriveAuthenticationError.serviceUnavailable
            oneDriveAuthenticationState = .failed(error.localizedDescription)
            throw error
        }
        oneDriveAuthenticationState = .running
        do {
            try await oneDriveAuthenticationService.signOut()
            clearOneDriveSessionState()
            oneDriveAuthenticationState = .disconnected
            if let remaining = try? await oneDriveAuthenticationService.restoreSession() {
                oneDriveAuthenticationState = .connected(accountLabel: remaining.accountLabel)
                applyOneDriveSession(remaining)
            } else {
                oneDriveAccounts = []
            }
            await loadOneDriveAccounts()
        } catch {
            oneDriveAuthenticationState = .failed(readableOneDriveAuthenticationErrorMessage(error))
            throw error
        }
    }

    @discardableResult
    func switchOneDriveAccount(identifier: String) async throws -> AppOneDriveAuthenticationSession {
        recordUserActivity()
        guard let oneDriveAuthenticationService else {
            let error = AppOneDriveAuthenticationError.serviceUnavailable
            oneDriveAuthenticationState = .failed(error.localizedDescription)
            throw error
        }
        oneDriveAuthenticationState = .running
        clearOneDriveSessionState()
        do {
            let session = try await oneDriveAuthenticationService.switchAccount(identifier: identifier)
            oneDriveAuthenticationState = .connected(accountLabel: session.accountLabel)
            applyOneDriveSession(session)
            await loadOneDriveAccounts()
            _ = try? await refreshCloudFileItems(provider: .oneDrive)
            return session
        } catch {
            oneDriveAuthenticationState = .failed(readableOneDriveAuthenticationErrorMessage(error))
            throw error
        }
    }

    func loadOneDriveAccounts() async {
        guard let oneDriveAuthenticationService else {
            oneDriveAccounts = []
            return
        }
        oneDriveAccounts = (try? await oneDriveAuthenticationService.availableAccounts()) ?? []
    }

    func applyOneDriveSession(_ session: AppOneDriveAuthenticationSession) {
        currentOneDriveAccountIdentifier = session.accountIdentifier
        oneDriveBackupPreferences = oneDriveBackupPreferencesStore.loadPreferences(
            accountIdentifier: session.accountIdentifier
        )
        oneDriveBackupDirectoryState = .unknown
        oneDriveBackupNotice = nil
    }

    func clearOneDriveSessionState() {
        cloudFileItemsByProvider[.oneDrive] = nil
        cloudFileSelectedBackupItemByProvider[.oneDrive] = nil
        if cloudFileRestorePreview?.provider == .oneDrive {
            cloudFileRestorePreview = nil
            downloadedCloudFileRestore = nil
        }
        if cloudFileState.providerKind == .oneDrive {
            cloudFileState = .idle
        }
        oneDriveDefaultLocationFiles = []
        oneDriveBackupNotice = nil
        oneDriveBackupPreferences = CloudFileBackupPreferences()
        oneDriveBackupDirectoryState = .unknown
        currentOneDriveAccountIdentifier = ""
    }

    func handleOneDriveRedirectURL(_ url: URL) -> Bool {
        guard let oneDriveAuthenticationService,
              oneDriveAuthenticationService.handleRedirectURL(url)
        else {
            return false
        }
        oneDriveAuthenticationState = .redirectHandled
        return true
    }

    func downloadCloudFileRestorePreview(
        itemID: String,
        provider kind: CloudFileProviderKind
    ) async throws -> CloudFileDownload {
        recordUserActivity()
        cloudFileState = .running(kind)

        do {
            _ = try requireActiveVaultSession()
            let provider = try cloudFileProvider(for: kind)
            let download = try await provider.downloadFile(id: itemID)
            let preview = AppCloudFileRestorePreview(provider: kind, download: download)
            downloadedCloudFileRestore = download
            cloudFileRestorePreview = preview
            cloudFileState = .restorePreviewReady(
                provider: kind,
                fileName: preview.fileName,
                byteCount: preview.byteCount
            )
            cloudFileSelectedBackupItemByProvider[kind] = download.item
            return download
        } catch {
            cloudFileState = .failed(readableCloudFileErrorMessage(for: error, provider: kind))
            throw error
        }
    }

    func uploadActiveVaultToCloud(provider kind: CloudFileProviderKind) async throws -> CloudFileWriteReceipt {
        recordUserActivity()
        cloudFileState = .running(kind)

        do {
            let session = try requireActiveVaultSession()
            let provider = try cloudFileProvider(for: kind)
            let data = try Data(contentsOf: session.descriptor.fileURL)
            let receipt: CloudFileWriteReceipt
            if kind == .oneDrive,
               let directoryProvider = provider as? any CloudFileBackupDirectoryProviding {
                receipt = try await uploadOneDriveVault(
                    data: data,
                    cloudProvider: provider,
                    directoryProvider: directoryProvider,
                    baseName: kind.defaultBackupFileName
                )
            } else {
                receipt = try await provider.uploadFile(
                    named: kind.defaultBackupFileName,
                    data: data
                )
            }
            cloudFileState = .backupSucceeded(
                provider: kind,
                fileName: sanitizedCloudFileName(receipt.name),
                byteCount: receipt.byteCount
            )
            appendOperationTimelineEvent(
                action: .backedUp,
                itemKind: .attachmentRef,
                itemID: "\(kind.rawValue)-upload",
                itemTitle: "\(kind.displayName) \(sanitizedCloudFileName(receipt.name))"
            )
            return receipt
        } catch {
            cloudFileState = .failed(readableCloudFileErrorMessage(for: error, provider: kind))
            appendOperationTimelineEvent(
                action: .backedUp,
                itemKind: .attachmentRef,
                itemID: "\(kind.rawValue)-upload",
                itemTitle: "\(kind.displayName) backup",
                result: "failed",
                errorCategory: kind.displayName
            )
            throw error
        }
    }

    func uploadOneDriveVault(
        data: Data,
        cloudProvider: any CloudFileProvider,
        directoryProvider: any CloudFileBackupDirectoryProviding,
        baseName: String
    ) async throws -> CloudFileWriteReceipt {
        let directoryID = oneDriveBackupPreferences.directory?.id
        let listing: CloudFileBackupDirectoryListing
        do {
            listing = try await directoryProvider.listBackupDirectory(id: directoryID)
        } catch let error as CloudFileProviderError
            where error == .itemNotFound(provider: .oneDrive) {
            oneDriveBackupDirectoryState = .missing
            oneDriveBackupNotice = "备份目录已不存在，请重建目录或选择新的位置。"
            throw error
        }
        if let directory = listing.directory {
            oneDriveBackupDirectoryState = .available(directory.displayPath)
        }
        cloudFileItemsByProvider[.oneDrive] = listing.files

        do {
            let receipt: CloudFileWriteReceipt
            if oneDriveBackupPreferences.usesTimestampedFileNames {
                let fileName = CloudFileBackupFileNameFormatter.timestampedFileName(
                    baseName: baseName,
                    date: oneDriveNow()
                )
                receipt = try await directoryProvider.uploadFile(
                    named: fileName,
                    data: data,
                    inDirectory: directoryID,
                    conflictBehavior: .fail
                )
                return try await pruneOneDriveBackups(
                    cloudProvider: cloudProvider,
                    directoryProvider: directoryProvider,
                    directoryID: directoryID,
                    baseName: baseName,
                    uploadedReceipt: receipt
                )
            }

            if let existing = listing.files.first(where: { $0.name == baseName }) {
                receipt = try await cloudProvider.overwriteFile(
                    id: existing.id,
                    data: data,
                    fileName: baseName,
                    expectedRevision: existing.revision
                )
            } else {
                receipt = try await directoryProvider.uploadFile(
                    named: baseName,
                    data: data,
                    inDirectory: directoryID,
                    conflictBehavior: .fail
                )
            }
            var items = cloudFileItemsByProvider[.oneDrive] ?? []
            let uploadedItem = CloudFileItem(
                id: receipt.itemID,
                name: receipt.name,
                path: receipt.name,
                byteCount: receipt.byteCount,
                modifiedAt: oneDriveNow(),
                sha256: receipt.sha256,
                revision: receipt.revision
            )
            if let existingIndex = items.firstIndex(where: {
                $0.name == receipt.name || $0.id == receipt.itemID
            }) {
                items[existingIndex] = uploadedItem
            } else {
                items.append(uploadedItem)
            }
            cloudFileItemsByProvider[.oneDrive] = items
            return receipt
        } catch let error as CloudFileProviderError
            where error == .itemNotFound(provider: .oneDrive) {
            oneDriveBackupDirectoryState = .missing
            oneDriveBackupNotice = "备份目录已不存在，请重建目录或选择新的位置。"
            throw error
        }
    }

    func pruneOneDriveBackups(
        cloudProvider: any CloudFileProvider,
        directoryProvider: any CloudFileBackupDirectoryProviding,
        directoryID: String?,
        baseName: String,
        uploadedReceipt: CloudFileWriteReceipt
    ) async throws -> CloudFileWriteReceipt {
        guard let listing = try? await directoryProvider.listBackupDirectory(id: directoryID) else {
            oneDriveBackupNotice = "备份已上传，但暂时无法读取目录以清理旧版本。"
            return uploadedReceipt
        }
        var files = listing.files
        if !files.contains(where: { $0.id == uploadedReceipt.itemID }) {
            files.append(
                CloudFileItem(
                    id: uploadedReceipt.itemID,
                    name: uploadedReceipt.name,
                    path: uploadedReceipt.name,
                    byteCount: uploadedReceipt.byteCount,
                    modifiedAt: oneDriveNow(),
                    sha256: uploadedReceipt.sha256,
                    revision: uploadedReceipt.revision
                )
            )
        }
        let pruned = CloudFileBackupRetention.filesToPrune(
            from: files,
            baseName: baseName,
            retainedVersions: oneDriveBackupPreferences.retainedVersionCount
        )
        var removedIDs = Set<String>()
        var failureCount = 0
        for item in pruned {
            do {
                _ = try await cloudProvider.deleteFile(id: item.id)
                removedIDs.insert(item.id)
            } catch let error as CloudFileProviderError
                where error == .itemNotFound(provider: .oneDrive) {
                removedIDs.insert(item.id)
            } catch {
                failureCount += 1
            }
        }
        if let items = cloudFileItemsByProvider[.oneDrive] {
            cloudFileItemsByProvider[.oneDrive] = items.filter { !removedIDs.contains($0.id) }
        }
        if failureCount > 0 {
            oneDriveBackupNotice = "备份已上传，但有 \(failureCount) 个旧版本未能清理。"
        } else if !pruned.isEmpty {
            oneDriveBackupNotice = "已清理 \(pruned.count) 个旧版本备份。"
        }
        return uploadedReceipt
    }

    func selectOneDriveBackupDirectory(_ directory: CloudFileBackupDirectory) {
        oneDriveBackupPreferences.directory = directory
        oneDriveBackupDirectoryState = .available(directory.displayPath)
        oneDriveBackupNotice = nil
        cloudFileItemsByProvider[.oneDrive] = nil
        persistOneDriveBackupPreferences()
    }

    func useDefaultOneDriveBackupLocation() {
        oneDriveBackupPreferences.directory = nil
        oneDriveBackupDirectoryState = .unknown
        oneDriveBackupNotice = nil
        cloudFileItemsByProvider[.oneDrive] = nil
        persistOneDriveBackupPreferences()
    }

    func updateOneDriveBackupFileNamePolicy(
        usesTimestampedFileNames: Bool,
        retainedVersionCount: Int? = nil
    ) {
        oneDriveBackupPreferences.usesTimestampedFileNames = usesTimestampedFileNames
        if let retainedVersionCount {
            oneDriveBackupPreferences.retainedVersionCount = retainedVersionCount
        }
        persistOneDriveBackupPreferences()
    }

    func loadOneDriveBackupDirectory(id: String?) async throws -> CloudFileBackupDirectoryListing {
        recordUserActivity()
        let provider = try cloudFileProvider(for: .oneDrive)
        guard let directoryProvider = provider as? any CloudFileBackupDirectoryProviding else {
            throw AppCloudFileError.directoryUnavailable
        }
        return try await directoryProvider.listBackupDirectory(id: id)
    }

    @discardableResult
    func createOneDriveBackupDirectory(
        named name: String,
        parentID: String?
    ) async throws -> CloudFileBackupDirectory {
        recordUserActivity()
        let provider = try cloudFileProvider(for: .oneDrive)
        guard let directoryProvider = provider as? any CloudFileBackupDirectoryProviding else {
            throw AppCloudFileError.directoryUnavailable
        }
        do {
            let directory = try await directoryProvider.createBackupDirectory(named: name, parentID: parentID)
            selectOneDriveBackupDirectory(directory)
            _ = try? await refreshCloudFileItems(provider: .oneDrive)
            return directory
        } catch {
            oneDriveBackupDirectoryState = .failed(
                readableCloudFileErrorMessage(for: error, provider: .oneDrive)
            )
            throw error
        }
    }

    func recreateOneDriveBackupDirectory() async throws {
        recordUserActivity()
        let provider = try cloudFileProvider(for: .oneDrive)
        guard let directoryProvider = provider as? any CloudFileBackupDirectoryProviding else {
            throw AppCloudFileError.directoryUnavailable
        }
        let path = (oneDriveBackupPreferences.directory?.displayPath ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let components = path
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        guard !components.isEmpty else {
            oneDriveBackupNotice = nil
            _ = try? await refreshCloudFileItems(provider: .oneDrive)
            return
        }

        var parentID: String?
        do {
            for component in components {
                let listing = try await directoryProvider.listBackupDirectory(id: parentID)
                if let existing = listing.directories.first(where: { $0.name == component }) {
                    parentID = existing.id
                    continue
                }
                do {
                    let created = try await directoryProvider.createBackupDirectory(
                        named: component,
                        parentID: parentID
                    )
                    parentID = created.id
                } catch let error as CloudFileProviderError
                    where error == .conflict(provider: .oneDrive) {
                    let refreshed = try await directoryProvider.listBackupDirectory(id: parentID)
                    guard let existing = refreshed.directories.first(where: { $0.name == component }) else {
                        throw error
                    }
                    parentID = existing.id
                }
            }
            if let directory = try await directoryProvider.listBackupDirectory(id: parentID).directory {
                selectOneDriveBackupDirectory(directory)
            }
            oneDriveBackupNotice = "已重建备份目录。"
            _ = try? await refreshCloudFileItems(provider: .oneDrive)
        } catch {
            oneDriveBackupDirectoryState = .failed(
                readableCloudFileErrorMessage(for: error, provider: .oneDrive)
            )
            throw error
        }
    }

    func persistOneDriveBackupPreferences() {
        let identifier = currentOneDriveAccountIdentifier
        guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        oneDriveBackupPreferencesStore.savePreferences(
            oneDriveBackupPreferences,
            accountIdentifier: identifier
        )
    }

    func overwriteCloudFile(
        provider kind: CloudFileProviderKind,
        itemID: String,
        data: Data,
        fileName: String
    ) async throws -> CloudFileWriteReceipt {
        recordUserActivity()
        cloudFileState = .running(kind)

        do {
            _ = try requireActiveVaultSession()
            let provider = try cloudFileProvider(for: kind)
            let receipt = try await provider.overwriteFile(
                id: itemID,
                data: data,
                fileName: sanitizedCloudFileName(fileName)
            )
            cloudFileState = .writeSucceeded(
                provider: kind,
                fileName: sanitizedCloudFileName(receipt.name),
                byteCount: receipt.byteCount
            )
            appendOperationTimelineEvent(
                action: .synced,
                itemKind: .attachmentRef,
                itemID: "\(kind.rawValue)-overwrite",
                itemTitle: "\(kind.displayName) \(sanitizedCloudFileName(receipt.name))"
            )
            return receipt
        } catch {
            cloudFileState = .failed(readableCloudFileErrorMessage(for: error, provider: kind))
            throw error
        }
    }

    func deleteCloudFileBackupItem(
        provider kind: CloudFileProviderKind,
        item: CloudFileItem
    ) async throws {
        recordUserActivity()
        cloudFileState = .running(kind)
        do {
            _ = try requireActiveVaultSession()
            let provider = try cloudFileProvider(for: kind)
            _ = try await provider.deleteFile(id: item.id)
            cloudFileItemsByProvider[kind]?.removeAll { $0.id == item.id }
            oneDriveDefaultLocationFiles.removeAll { $0.id == item.id }
            cloudFileState = .deleted(provider: kind, fileName: sanitizedCloudFileName(item.name))
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .attachmentRef,
                itemID: "\(kind.rawValue)-delete",
                itemTitle: "\(kind.displayName) \(sanitizedCloudFileName(item.name))"
            )
        } catch {
            cloudFileState = .failed(readableCloudFileErrorMessage(for: error, provider: kind))
            throw error
        }
    }

    func setCloudFileBackupItemPermanent(
        provider kind: CloudFileProviderKind,
        item: CloudFileItem,
        isPermanent: Bool
    ) async throws {
        recordUserActivity()
        cloudFileState = .running(kind)
        do {
            _ = try requireActiveVaultSession()
            let provider = try cloudFileProvider(for: kind)
            let newName = permanentBackupFileName(for: item.name, isPermanent: isPermanent)
            let receipt = try await provider.renameFile(id: item.id, newName: newName)
            let updated = CloudFileItem(
                id: receipt.itemID,
                name: receipt.name,
                path: receipt.name,
                byteCount: item.byteCount,
                modifiedAt: item.modifiedAt,
                sha256: item.sha256,
                revision: receipt.revision ?? item.revision
            )
            if let index = cloudFileItemsByProvider[kind]?.firstIndex(where: { $0.id == item.id }) {
                cloudFileItemsByProvider[kind]?[index] = updated
            }
            if let defaultIndex = oneDriveDefaultLocationFiles.firstIndex(where: { $0.id == item.id }) {
                oneDriveDefaultLocationFiles[defaultIndex] = updated
            }
            cloudFileState = .permanentUpdated(
                provider: kind,
                fileName: sanitizedCloudFileName(receipt.name),
                isPermanent: isPermanent
            )
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .attachmentRef,
                itemID: "\(kind.rawValue)-permanent",
                itemTitle: "\(kind.displayName) \(sanitizedCloudFileName(receipt.name))"
            )
        } catch {
            cloudFileState = .failed(readableCloudFileErrorMessage(for: error, provider: kind))
            throw error
        }
    }

    func permanentBackupFileName(for fileName: String, isPermanent: Bool) -> String {
        let sanitized = sanitizedCloudFileName(fileName)
        let marker = "_permanent"
        let ext = ".mdbx"
        guard sanitized.lowercased().hasSuffix(ext) else {
            return isPermanent && !sanitized.hasSuffix(marker)
                ? sanitized + marker
                : sanitized.replacingOccurrences(of: marker, with: "")
        }
        let base = String(sanitized.dropLast(ext.count))
        if isPermanent {
            return base.hasSuffix(marker) ? sanitized : "\(base)\(marker)\(ext)"
        }
        return "\(base.replacingOccurrences(of: marker, with: ""))\(ext)"
    }

    func downloadWebDAVRestorePreview() async throws {
        recordUserActivity()
        webDAVBackupState = .running

        do {
            _ = try requireActiveVaultSession()
            let endpoint = try makeWebDAVEndpoint()
            let fileName = try normalizedWebDAVRemoteFileName(fallback: nil)
            let downloaded = try await webDAVBackupService.download(
                endpoint: endpoint,
                fileName: fileName
            )
            let preview = try WebDAVRestorePreview(downloaded)
            webDAVPassword = ""
            webDAVRestoreVaultPassword = ""
            webDAVRestorePreview = preview
            downloadedWebDAVRestoreBackup = downloaded
            webDAVBackupState = .restorePreviewReady(
                fileName: preview.fileName,
                byteCount: preview.byteCount
            )
        } catch {
            handleWebDAVFailure(error)
            throw error
        }
    }

    func confirmWebDAVRestore() throws {
        recordUserActivity()
        webDAVBackupState = .running

        do {
            guard let activeVaultSession else {
                throw AppWebDAVBackupError.vaultLocked
            }
            guard let preview = webDAVRestorePreview,
                  let downloaded = downloadedWebDAVRestoreBackup else {
                throw AppWebDAVBackupError.restorePreviewUnavailable
            }
            let restorePassword = webDAVRestoreVaultPassword
            guard !restorePassword.isEmpty else {
                throw AppWebDAVBackupError.emptyRestoreVaultPassword
            }

            let destinationURL = activeVaultSession.descriptor.fileURL
            try validateDownloadedWebDAVRestore(
                downloaded,
                near: destinationURL,
                password: restorePassword,
                deviceID: activeVaultSession.handle.deviceID
            )
            webDAVRestoreVaultPassword = ""
            vaultRepository.closeVault(for: activeVaultSession)
            clearUnlockedVaultSession()
            try replaceVaultFile(
                at: destinationURL,
                with: downloaded.data
            )
            webDAVRestorePreview = nil
            downloadedWebDAVRestoreBackup = nil
            webDAVBackupState = .restoreSucceeded(
                fileName: preview.fileName,
                byteCount: preview.byteCount
            )
            appendOperationTimelineEvent(
                action: .restoredBackup,
                itemKind: .attachmentRef,
                itemID: "webdav-restore",
                itemTitle: "WebDAV \(preview.fileName)"
            )
        } catch {
            webDAVRestoreVaultPassword = ""
            handleWebDAVFailure(error)
            appendOperationTimelineEvent(
                action: .restoredBackup,
                itemKind: .attachmentRef,
                itemID: "webdav-restore",
                itemTitle: "WebDAV backup",
                result: "failed",
                errorCategory: "WebDAV"
            )
            throw error
        }
    }

    /// 统一处理 WebDAV 失败：证书类错误保留可操作的挑战（主机、指纹、状态），
    /// 供设置页展示确认入口；其余错误只落一条可读文案。
    func handleWebDAVFailure(_ error: Error) {
        if let webDAVError = error as? WebDAVError {
            switch webDAVError {
            case .untrustedCertificate(let challenge), .certificateFingerprintChanged(let challenge):
                webDAVPendingCertificateChallenge = challenge
            case .unexpectedStatus, .integrityCheckFailed, .nonHTTPResponse,
                 .certificateTrustStoreUnavailable, .certificateInspectionFailed:
                break
            }
        }
        webDAVBackupState = .failed(readableWebDAVErrorMessage(for: error))
    }

    func readableWebDAVErrorMessage(for error: Error) -> String {
        if let appError = error as? AppWebDAVBackupError {
            return appError.localizedDescription
        }

        if let webDAVError = error as? WebDAVError {
            switch webDAVError {
            case .unexpectedStatus(_, let statusCode) where statusCode == 401 || statusCode == 403:
                return String(localized: "WebDAV 登录失败，请检查用户名和密码。")
            case .unexpectedStatus("download", 404):
                return String(localized: "未找到远端备份文件。")
            case .unexpectedStatus(_, let statusCode) where (500...599).contains(statusCode):
                return String(localized: "WebDAV 服务器当前不可用，请稍后再试。")
            case .unexpectedStatus:
                return String(localized: "WebDAV 请求失败，请检查服务器设置后重试。")
            case .integrityCheckFailed:
                return String(localized: "远端备份未通过完整性校验，可能已经损坏。")
            case .nonHTTPResponse:
                return String(localized: "WebDAV 服务器返回了无效响应。")
            case .untrustedCertificate:
                return String(localized: "WebDAV 服务器证书尚未信任，请在下方查看 SHA-256 指纹并确认信任。")
            case .certificateFingerprintChanged:
                return String(localized: "WebDAV 服务器证书指纹已变更，连接已被阻止，请确认新指纹后再信任。")
            case .certificateTrustStoreUnavailable:
                return String(localized: "无法读取 WebDAV 证书信任记录，已阻止连接。")
            case .certificateInspectionFailed:
                return String(localized: "无法读取 WebDAV 服务器证书，已阻止连接。")
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return String(localized: "网络不可用，请检查连接后重试。")
            case .timedOut:
                return String(localized: "WebDAV 请求超时，请稍后再试。")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return String(localized: "无法连接 WebDAV 服务器，请检查服务器 URL。")
            case .userAuthenticationRequired, .userCancelledAuthentication:
                return String(localized: "WebDAV 登录失败，请检查用户名和密码。")
            default:
                return String(localized: "WebDAV 连接失败，请检查网络和服务器设置。")
            }
        }

        return error.localizedDescription
    }

    func cloudFileProvider(for kind: CloudFileProviderKind) throws -> any CloudFileProvider {
        guard let provider = cloudFileProviders[kind] else {
            throw AppCloudFileError.providerUnavailable(kind)
        }
        return provider
    }

    func readableCloudFileErrorMessage(
        for error: Error,
        provider kind: CloudFileProviderKind
    ) -> String {
        if let appError = error as? AppCloudFileError {
            return appError.localizedDescription
        }
        if let providerError = error as? CloudFileProviderError {
            return providerError.localizedDescription
        }
        if kind == .oneDrive {
            return readableOneDriveAuthenticationErrorMessage(error)
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return String(localized: "网络不可用，请检查连接后重试。")
            case .timedOut:
                return String(localized: "\(kind.displayName) 请求超时，请稍后再试。")
            default:
                return String(localized: "\(kind.displayName) 连接失败，请检查网络后重试。")
            }
        }
        return String(localized: "\(kind.displayName) 操作失败，请稍后重试。")
    }

    func sanitizedCloudFileName(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? value
        let sanitized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? String(localized: "未命名文件") : sanitized
    }

    func readableOneDriveAuthenticationErrorMessage(_ error: Error) -> String {
        if let appError = error as? AppOneDriveAuthenticationError {
            return appError.localizedDescription
        }
        if let providerError = error as? CloudFileProviderError,
           case .authenticationRequired = providerError {
            return String(localized: "OneDrive 需要先登录。")
        }
        let nsError = error as NSError
        return AppOneDriveAuthenticationError.authenticationFailed(
            domain: nsError.domain,
            code: nsError.code,
            message: DefaultAppOneDriveMSALAuthenticationService.diagnosticMessage(for: nsError)
        ).localizedDescription
    }

    func makeWebDAVEndpoint() throws -> WebDAVEndpoint {
        let baseURLString = webDAVBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: baseURLString),
              baseURL.scheme != nil,
              baseURL.host() != nil else {
            throw AppWebDAVBackupError.invalidEndpoint
        }

        let username = webDAVUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            throw AppWebDAVBackupError.emptyUsername
        }
        guard !webDAVPassword.isEmpty else {
            throw AppWebDAVBackupError.emptyPassword
        }

        return WebDAVEndpoint(
            baseURL: baseURL,
            username: username,
            password: webDAVPassword
        )
    }

    func normalizedWebDAVRemoteFileName(fallback: String?) throws -> String {
        let normalized = webDAVRemoteFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty {
            return normalized
        }
        if let fallback, !fallback.isEmpty {
            return fallback
        }
        throw AppWebDAVBackupError.emptyRemoteFileName
    }

    func validateDownloadedWebDAVRestore(
        _ downloaded: WebDAVDownloadedBackup,
        near destinationURL: URL,
        password: String,
        deviceID: String
    ) throws {
        let directoryURL = destinationURL.deletingLastPathComponent()
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(downloaded.fileName).validate-\(UUID().uuidString).mdbx",
            isDirectory: false
        )

        do {
            try downloaded.data.write(to: temporaryURL, options: [.atomic])
            let validationSession = try vaultRepository.openVault(
                at: temporaryURL,
                password: password,
                deviceID: deviceID
            )
            vaultRepository.closeVault(for: validationSession)
            try? FileManager.default.removeItem(at: temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw AppWebDAVBackupError.restoreValidationFailed
        }
    }
}
