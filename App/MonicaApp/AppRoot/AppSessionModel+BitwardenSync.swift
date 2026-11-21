//
//  AppSessionModel+BitwardenSync.swift
//  Monica
//
//  slice C2：Bitwarden 登录 / 双因素 / 同步 / 快照导入，从 AppSessionModel.swift 逐字搬移。
//

import Foundation
import MonicaCore
import MonicaStorage
import MonicaSync
import CryptoKit

extension AppSessionModel {
    var bitwardenTwoFactorProviders: [BitwardenTwoFactorProvider] {
        pendingBitwardenTwoFactorChallenge?.providers ?? []
    }

    var canRequestBitwardenEmailTwoFactorCode: Bool {
        pendingBitwardenTwoFactorChallenge?.supportsEmailCodeRequest ?? false
    }

    @discardableResult
    func signInToBitwarden() async throws -> BitwardenAuthenticationSession {
        recordUserActivity()
        bitwardenSyncState = .running

        do {
            guard let bitwardenPasswordAuthenticationService else {
                throw AppBitwardenSyncError.providerUnavailable
            }
            guard let serverURL = validBitwardenServerURL(bitwardenServerURL) else {
                throw AppBitwardenSyncError.invalidServerURL
            }
            let result = try await bitwardenPasswordAuthenticationService.beginSignIn(
                email: bitwardenEmail,
                masterPassword: bitwardenMasterPassword,
                serverURL: serverURL
            )
            switch result {
            case .authenticated(let session):
                clearBitwardenTwoFactorState()
                bitwardenMasterPassword = ""
                bitwardenAuthenticationState = .connected(accountLabel: session.accountLabel)
                bitwardenSyncState = .idle
                return session
            case .twoFactorRequired(let challenge):
                pendingBitwardenTwoFactorChallenge = challenge
                bitwardenTwoFactorProviderID = challenge.providers.first?.providerID ?? 0
                bitwardenMasterPassword = ""
                bitwardenAuthenticationState = .twoFactorRequired(
                    accountLabel: challenge.accountLabel,
                    providers: challenge.providers
                )
                bitwardenSyncState = .failed(String(localized: "Bitwarden 需要两步验证"))
                throw BitwardenSyncProviderError.twoFactorRequired
            }
        } catch {
            if case BitwardenSyncProviderError.twoFactorRequired = error {
                throw error
            }
            let message = readableBitwardenSyncErrorMessage(for: error)
            clearBitwardenTwoFactorState()
            bitwardenMasterPassword = ""
            bitwardenAuthenticationState = .failed(message)
            bitwardenSyncState = .failed(message)
            throw error
        }
    }

    @discardableResult
    func restoreBitwardenAuthenticationSession() throws -> BitwardenAuthenticationSession? {
        do {
            guard let session = try bitwardenAuthenticationSessionStore.loadSession() else {
                bitwardenAuthenticationState = .disconnected
                return nil
            }
            bitwardenAuthenticationState = .connected(accountLabel: session.accountLabel)
            return session
        } catch {
            bitwardenAuthenticationState = .failed(readableBitwardenSyncErrorMessage(for: error))
            throw error
        }
    }

    func signOutFromBitwarden() throws {
        recordUserActivity()
        do {
            let accountLabel = try bitwardenAuthenticationSessionStore.loadSession()?.accountLabel
            try bitwardenAuthenticationSessionStore.clearSession()
            try bitwardenVaultKeyStore?.clearVaultKey(accountLabel: accountLabel)
            clearBitwardenTwoFactorState()
            bitwardenAuthenticationState = .disconnected
            bitwardenSyncState = .idle
            bitwardenSyncPreview = nil
            bitwardenPendingMutationBatches = []
        } catch {
            bitwardenAuthenticationState = .failed(readableBitwardenSyncErrorMessage(for: error))
            throw error
        }
    }

    func completeBitwardenTwoFactorSignIn() async throws -> BitwardenAuthenticationSession {
        recordUserActivity()
        guard let challenge = pendingBitwardenTwoFactorChallenge else {
            throw AppBitwardenSyncError.providerUnavailable
        }
        guard let bitwardenPasswordAuthenticationService else {
            throw AppBitwardenSyncError.providerUnavailable
        }
        do {
            let session = try await bitwardenPasswordAuthenticationService.completeTwoFactorSignIn(
                challenge,
                code: bitwardenTwoFactorCode,
                providerID: bitwardenTwoFactorProviderID,
                rememberDevice: bitwardenRememberTwoFactorDevice
            )
            bitwardenMasterPassword = ""
            clearBitwardenTwoFactorState()
            bitwardenAuthenticationState = .connected(accountLabel: session.accountLabel)
            bitwardenSyncState = .idle
            return session
        } catch {
            let message = readableBitwardenSyncErrorMessage(for: error)
            bitwardenAuthenticationState = .failed(message)
            bitwardenSyncState = .failed(message)
            throw error
        }
    }

    func requestBitwardenEmailTwoFactorCode() async throws {
        recordUserActivity()
        guard let challenge = pendingBitwardenTwoFactorChallenge else {
            throw AppBitwardenSyncError.providerUnavailable
        }
        guard let bitwardenPasswordAuthenticationService else {
            throw AppBitwardenSyncError.providerUnavailable
        }
        do {
            try await bitwardenPasswordAuthenticationService.requestEmailTwoFactorCode(for: challenge)
            bitwardenSyncState = .twoFactorEmailSent
        } catch {
            let message = readableBitwardenSyncErrorMessage(for: error)
            bitwardenAuthenticationState = .failed(message)
            bitwardenSyncState = .failed(message)
            throw error
        }
    }

    func clearBitwardenTwoFactorState() {
        pendingBitwardenTwoFactorChallenge = nil
        bitwardenTwoFactorCode = ""
        bitwardenRememberTwoFactorDevice = false
        bitwardenTwoFactorProviderID = 0
    }

    @discardableResult
    func refreshBitwardenPendingMutationQueue() throws -> [AppBitwardenPendingMutationBatch] {
        let session = try requireActiveVaultSession()
        let batches = try bitwardenPendingMutationQueueStore.loadBatches(vaultID: session.handle.vaultID)
        bitwardenPendingMutationBatches = batches
        return batches
    }

    func clearBitwardenPendingMutationQueue() throws {
        recordUserActivity()
        do {
            let session = try requireActiveVaultSession()
            try bitwardenPendingMutationQueueStore.saveBatches([], vaultID: session.handle.vaultID)
            bitwardenPendingMutationBatches = []
            bitwardenSyncState = .queueCleared
        } catch {
            bitwardenSyncState = .failed(readableBitwardenSyncErrorMessage(for: error))
            throw error
        }
    }

    @discardableResult
    func retryBitwardenPendingMutationQueue() async throws -> BitwardenSyncPushResult {
        recordUserActivity()
        do {
            let pendingBatches = try refreshBitwardenPendingMutationQueue()
            guard !pendingBatches.isEmpty else {
                bitwardenSyncState = .queueCleared
                return BitwardenSyncPushResult(acceptedMutationCount: 0)
            }
            return try await pushLocalBitwardenChanges()
        } catch {
            if case .queuedForRetry = bitwardenSyncState {
                throw error
            }
            bitwardenSyncState = .failed(readableBitwardenSyncErrorMessage(for: error))
            throw error
        }
    }

    func previewBitwardenSync() async throws -> AppBitwardenSyncPreview {
        recordUserActivity()
        bitwardenSyncState = .running

        do {
            let session = try requireActiveVaultSession()
            let provider = try requireBitwardenSyncProvider()
            let snapshot = try await provider.pullSnapshot()
            var preview = AppBitwardenSyncPreview(snapshot: snapshot)
            preview.mergeSummary = bitwardenSyncMergeSummary(
                snapshot: snapshot,
                vaultID: session.handle.vaultID
            )
            bitwardenSyncPreview = preview
            bitwardenSyncState = .previewReady(
                itemCount: preview.remoteItemCount,
                sendCount: preview.remoteSendCount
            )
            return preview
        } catch {
            bitwardenSyncState = .failed(readableBitwardenSyncErrorMessage(for: error))
            throw error
        }
    }

    func syncBitwardenVaultData(projectTitle: String) async throws -> AppBitwardenSyncPreview {
        recordUserActivity()
        bitwardenSyncState = .running

        do {
            let session = try requireActiveVaultSession()
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let provider = try requireBitwardenSyncProvider()
            let priorCheckpoint = try? bitwardenSyncCheckpointStore.loadCheckpoint(vaultID: session.handle.vaultID)
            let pullOutcome = try await provider.pullSnapshot(ifChangedSince: priorCheckpoint?.revision)
            let snapshot: BitwardenSyncSnapshot
            var pulledRevision: BitwardenSyncRevision?
            switch pullOutcome {
            case let .unchanged(revision):
                pulledRevision = revision
                if let cachedPreview = bitwardenSyncPreview {
                    // 远端修订号未变：直接复用上次预览，避免整库重复导入产生重复条目。
                    saveBitwardenSyncCheckpoint(revision: revision, vaultID: session.handle.vaultID)
                    bitwardenSyncState = .synced(
                        itemCount: cachedPreview.remoteItemCount,
                        sendCount: cachedPreview.remoteSendCount
                    )
                    return cachedPreview
                }
                snapshot = try await provider.pullSnapshot()
            case let .changed(pulledSnapshot, revision):
                snapshot = pulledSnapshot
                pulledRevision = revision
            }
            var preview = AppBitwardenSyncPreview(snapshot: snapshot)
            let previousItemStates = try bitwardenItemSyncStateStore.loadStates(vaultID: session.handle.vaultID)
            let previousSendStates = try bitwardenSendSyncStateStore.loadStates(vaultID: session.handle.vaultID)
            preview.mergeSummary = bitwardenSyncMergeSummary(
                snapshot: snapshot,
                vaultID: session.handle.vaultID
            )
            try validateBitwardenRemoteSnapshotIsSafe(
                snapshot,
                previousItemStates: previousItemStates,
                previousSendStates: previousSendStates
            )
            let project = try ensureActiveProject(
                projectTitle: projectTitle,
                entryRepository: entryRepository
            )
            try importBitwardenSnapshot(
                snapshot,
                projectID: project.id,
                vaultID: session.handle.vaultID,
                entryRepository: entryRepository
            )
            try refreshAllEntryLists(projectID: project.id, entryRepository: entryRepository)
            try refreshAutoFillEncryptedIndexIfConfigured()
            if pulledRevision == nil {
                pulledRevision = try? await provider.latestRevision()
            }
            saveBitwardenSyncCheckpoint(revision: pulledRevision, vaultID: session.handle.vaultID)
            bitwardenSyncPreview = preview
            bitwardenSyncState = .synced(
                itemCount: preview.remoteItemCount,
                sendCount: preview.remoteSendCount
            )
            return preview
        } catch {
            bitwardenSyncState = .failed(readableBitwardenSyncErrorMessage(for: error))
            throw error
        }
    }

    func pushLocalBitwardenChanges() async throws -> BitwardenSyncPushResult {
        recordUserActivity()
        bitwardenSyncState = .running

        do {
            let session = try requireActiveVaultSession()
            let provider = try requireBitwardenSyncProvider()
            let snapshot = try await provider.pullSnapshot()
            let preview = AppBitwardenSyncPreview(snapshot: snapshot)
            let previousItemStates = try bitwardenItemSyncStateStore.loadStates(vaultID: session.handle.vaultID)
            let previousSendStates = try bitwardenSendSyncStateStore.loadStates(vaultID: session.handle.vaultID)
            let previousFolderStates = try bitwardenFolderSyncStateStore.loadStates(vaultID: session.handle.vaultID)
            try validateBitwardenRemoteSnapshotIsSafe(
                snapshot,
                previousItemStates: previousItemStates,
                previousSendStates: previousSendStates
            )
            bitwardenSyncPreview = preview
            let itemPlan = makeBitwardenItemSyncPlan(
                remoteItems: snapshot.items,
                previousStates: previousItemStates,
                folderStates: previousFolderStates
            )
            let sendPlan = makeBitwardenSendSyncPlan(
                remoteSends: snapshot.sends,
                previousStates: previousSendStates
            )
            let pendingBatches = try bitwardenPendingMutationQueueStore.loadBatches(vaultID: session.handle.vaultID)
            bitwardenPendingMutationBatches = pendingBatches
            let mutations = itemPlan.mutations + sendPlan.mutations
            let result: BitwardenSyncPushResult
            do {
                result = try await provider.pushMutations(mutations)
            } catch {
                if isRetryableBitwardenPushError(error), !mutations.isEmpty {
                    try queueBitwardenPendingMutations(
                        mutations,
                        vaultID: session.handle.vaultID,
                        existingBatches: pendingBatches,
                        error: error
                    )
                    bitwardenSyncState = .queuedForRetry(mutationCount: mutations.count)
                }
                throw error
            }
            let itemStates = bitwardenItemStates(
                itemPlan.updatedStates.values,
                assigningRemoteIDs: result.assignedRemoteIDs,
                revision: result.revision
            )
            let sendStates = bitwardenSendStates(
                sendPlan.updatedStates.values,
                assigningRemoteIDs: result.assignedRemoteIDs,
                revision: result.revision
            )
            try bitwardenItemSyncStateStore.saveStates(
                sortedBitwardenItemStates(itemStates),
                vaultID: session.handle.vaultID
            )
            try bitwardenSendSyncStateStore.saveStates(
                sendStates.sorted { $0.localID < $1.localID },
                vaultID: session.handle.vaultID
            )
            if !pendingBatches.isEmpty {
                try bitwardenPendingMutationQueueStore.saveBatches([], vaultID: session.handle.vaultID)
            }
            bitwardenPendingMutationBatches = []
            let conflicts = itemPlan.conflicts + sendPlan.conflicts + result.conflicts
            bitwardenSyncState = .pushed(
                acceptedMutationCount: result.acceptedMutationCount,
                conflictCount: conflicts.count
            )
            return BitwardenSyncPushResult(
                acceptedMutationCount: result.acceptedMutationCount,
                conflicts: conflicts,
                revision: result.revision,
                assignedRemoteIDs: result.assignedRemoteIDs
            )
        } catch {
            if case .queuedForRetry = bitwardenSyncState {
                throw error
            }
            bitwardenSyncState = .failed(readableBitwardenSyncErrorMessage(for: error))
            throw error
        }
    }

    @discardableResult
    func downloadBitwardenAttachmentContent(
        _ entry: LocalAttachmentMetadata
    ) async throws -> LocalAttachmentMetadata {
        recordUserActivity()
        entryOperationState = .running

        do {
            let session = try requireActiveVaultSession()
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            guard entry.source == "bitwarden",
                  entry.downloadState == "pending-bitwarden-download",
                  let localEntryID = entry.entryID,
                  !localEntryID.isEmpty
            else {
                throw AppBitwardenSyncError.attachmentUnavailable
            }
            let provider = try requireBitwardenSyncProvider()
            let itemStates = try bitwardenItemSyncStateStore.loadStates(vaultID: session.handle.vaultID)
            guard let remoteCipherID = itemStates
                .first(where: { $0.localID == localEntryID })?
                .remoteID?
                .nonBlankValue
            else {
                throw AppBitwardenSyncError.attachmentUnavailable
            }
            let snapshot = try await provider.pullSnapshot()
            guard let remoteItem = snapshot.items.first(where: { $0.remoteID == remoteCipherID }),
                  let remoteAttachment = remoteItem.attachments.first(where: {
                      bitwardenAttachmentContentHash($0) == entry.contentHash
                  })
            else {
                throw AppBitwardenSyncError.attachmentUnavailable
            }

            let download = try await provider.downloadAttachment(
                BitwardenAttachmentDownloadRequest(
                    cipherRemoteID: remoteAttachment.cipherRemoteID,
                    attachmentRemoteID: remoteAttachment.remoteID
                )
            )
            let fileName = sanitizedAttachmentPreviewFileName(entry.fileName)
            let localPath = try androidBackupAttachmentBlobStore.saveEncryptedBlob(
                download.encryptedContent,
                vaultID: session.handle.vaultID,
                localPath: bitwardenDownloadedAttachmentLocalPath(entry, fileName: fileName)
            )
            let updated = try entryRepository.updateAttachmentMetadata(
                projectID: projectID,
                attachmentID: entry.id,
                entryID: entry.entryID,
                fileName: fileName,
                mediaType: entry.mediaType.isEmpty ? "application/octet-stream" : entry.mediaType,
                originalSize: Int64(remoteAttachment.byteCount),
                storedSize: Int64(download.encryptedContent.count),
                contentHash: entry.contentHash,
                storageMode: "bitwarden-downloaded-content",
                source: "bitwarden",
                downloadState: "downloaded",
                wrappedContentEncryptionKey: remoteAttachment.encryptedKey ?? entry.wrappedContentEncryptionKey,
                localPath: localPath
            )
            attachmentEntries = try entryRepository.listAttachmentMetadata(projectID: projectID)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .attachmentRef,
                itemID: updated.id,
                itemTitle: updated.fileName
            )
            entryOperationState = .succeeded(String(localized: "Bitwarden 附件已下载：\(updated.fileName) \(download.encryptedContent.count) 字节"))
            return updated
        } catch {
            entryOperationState = .failed(readableBitwardenSyncErrorMessage(for: error))
            throw error
        }
    }

    func queueBitwardenPendingMutations(
        _ mutations: [BitwardenSyncMutation],
        vaultID: String,
        existingBatches: [AppBitwardenPendingMutationBatch],
        error: Error
    ) throws {
        let retryCount = (existingBatches.map(\.retryCount).max() ?? 0) + 1
        let batch = AppBitwardenPendingMutationBatch(
            vaultID: vaultID,
            mutationCount: mutations.count,
            redactedSummaries: mutations.map(\.redactedSummary),
            retryCount: retryCount,
            lastErrorSummary: readableBitwardenSyncErrorMessage(for: error)
        )
        try bitwardenPendingMutationQueueStore.saveBatches([batch], vaultID: vaultID)
        bitwardenPendingMutationBatches = [batch]
    }

    func isRetryableBitwardenPushError(_ error: Error) -> Bool {
        if error is URLError {
            return true
        }
        if case .serverRejected(let statusCode) = error as? BitwardenSyncProviderError {
            return (500...599).contains(statusCode)
        }
        return false
    }

    func validateBitwardenRemoteSnapshotIsSafe(
        _ snapshot: BitwardenSyncSnapshot,
        previousItemStates: [BitwardenItemSyncState],
        previousSendStates: [BitwardenSendSyncState]
    ) throws {
        guard snapshot.items.isEmpty, snapshot.sends.isEmpty else {
            return
        }
        let activeSyncedItemCount = previousItemStates.filter { state in
            state.remoteID?.nonBlankValue != nil && !state.isDeleted
        }.count
        let activeSyncedSendCount = previousSendStates.filter { state in
            state.remoteID?.nonBlankValue != nil && !state.isDeleted
        }.count
        let localCount = activeSyncedItemCount + activeSyncedSendCount
        guard localCount > 0 else {
            return
        }
        throw AppBitwardenSyncError.emptyRemoteVault(localCount: localCount)
    }

    func requireBitwardenSyncProvider() throws -> any BitwardenSyncProvider {
        guard let bitwardenSyncProvider else {
            throw AppBitwardenSyncError.providerUnavailable
        }
        return bitwardenSyncProvider
    }

    func importBitwardenSnapshot(
        _ snapshot: BitwardenSyncSnapshot,
        projectID: String,
        vaultID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws {
        var existingLogins = try entryRepository.listLoginEntries(projectID: projectID)
        var existingNotes = try entryRepository.listNoteEntries(projectID: projectID)
        var existingCards = try entryRepository.listCardEntries(projectID: projectID)
        var existingIdentities = try entryRepository.listIdentityEntries(projectID: projectID)
        var existingPasskeys = try entryRepository.listPasskeyEntries(projectID: projectID)
        var existingSshKeys = try entryRepository.listSshKeyEntries(projectID: projectID)
        var existingTotps = try entryRepository.listTotpEntries(projectID: projectID)
        var existingSends = try entryRepository.listSendEntries(projectID: projectID)
        var itemStates = Dictionary(
            uniqueKeysWithValues: try bitwardenItemSyncStateStore
                .loadStates(vaultID: vaultID)
                .map { ($0.localID, $0) }
        )
        var sendStates = Dictionary(
            uniqueKeysWithValues: try bitwardenSendSyncStateStore
                .loadStates(vaultID: vaultID)
                .map { ($0.localID, $0) }
        )
        var folderStates = Dictionary(
            uniqueKeysWithValues: try bitwardenFolderSyncStateStore
                .loadStates(vaultID: vaultID)
                .map { ($0.localID, $0) }
        )
        var projectIDByFolderRemoteID: [String: String] = [:]
        if !snapshot.folders.isEmpty {
            var projects = try entryRepository.listProjects()
            for folder in snapshot.folders {
                let title = bitwardenImportTitle(folder.name)
                let project: LocalVaultProject
                if let existing = projects.first(where: { $0.title == title }) {
                    project = existing
                } else {
                    project = try createOrReuseVaultProject(title: title, entryRepository: entryRepository)
                    projects.append(project)
                }
                projectIDByFolderRemoteID[folder.remoteID] = project.id
                folderStates[project.id] = BitwardenFolderSyncState(
                    localID: project.id,
                    remoteID: folder.remoteID,
                    name: title,
                    lastSyncedFingerprint: title,
                    lastRemoteRevision: folder.updatedAt.map { String($0.timeIntervalSince1970) },
                    isDeleted: false
                )
            }
        }

        for item in snapshot.items {
            let targetProjectID = item.folderID.flatMap { projectIDByFolderRemoteID[$0] } ?? projectID
            switch item.kind {
            case .login:
                var localEntry: LocalLoginEntry
                if targetProjectID == projectID,
                   let existing = existingLogins.first(where: { isSameBitwardenLogin($0, item) }) {
                    localEntry = existing
                } else {
                    localEntry = try entryRepository.createLoginEntry(
                        projectID: targetProjectID,
                        draft: LocalLoginEntryDraft(
                            title: bitwardenImportTitle(item.title),
                            username: item.username,
                            password: item.password ?? "",
                            url: item.url,
                            notes: item.notes ?? ""
                        )
                    )
                }
                localEntry = try applyBitwardenRemoteState(
                    item,
                    to: localEntry,
                    projectID: targetProjectID,
                    entryRepository: entryRepository
                )
                if targetProjectID == projectID {
                    existingLogins.removeAll { $0.id == localEntry.id }
                    if item.deletedAt == nil {
                        existingLogins.append(localEntry)
                    }
                }
                let localItem = bitwardenLocalItem(from: localEntry, folderID: item.folderID, folderName: item.folderName)
                itemStates[localEntry.id] = bitwardenItemSyncState(
                    localItem: localItem,
                    remoteItem: item
                )
                try reconcileBitwardenAttachments(
                    item.attachments,
                    localEntryID: localEntry.id,
                    projectID: targetProjectID,
                    entryRepository: entryRepository
                )
                if let totpSecret = item.totpSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !totpSecret.isEmpty,
                   !existingTotps.contains(where: { $0.title == bitwardenImportTitle(item.title) && $0.secret == totpSecret }) {
                    let created = try entryRepository.createTotpEntry(
                        projectID: projectID,
                        draft: LocalTotpEntryDraft(
                            title: bitwardenImportTitle(item.title),
                            secret: totpSecret,
                            issuer: item.folderName ?? snapshot.accountLabel,
                            accountName: item.username,
                            period: 30,
                            digits: 6,
                            algorithm: "SHA1",
                            otpType: "TOTP",
                            counter: 0
                        )
                    )
                    existingTotps.append(created)
                }
            case .passkey:
                var localEntry: LocalPasskeyEntry
                if targetProjectID == projectID,
                   let existing = existingPasskeys.first(where: { isSameBitwardenPasskey($0, item) }) {
                    localEntry = existing
                } else {
                    localEntry = try entryRepository.createPasskeyEntry(
                        projectID: targetProjectID,
                        draft: LocalPasskeyEntryDraft(
                            title: bitwardenImportTitle(item.title),
                            relyingPartyID: bitwardenPasskeyRelyingPartyID(for: item),
                            username: item.username,
                            userHandle: item.passkeyUserHandle,
                            credentialID: item.passkeyCredentialID,
                            publicKeyCOSE: item.passkeyPublicKeyCOSE,
                            privateKeyReference: item.passkeyPrivateKeyReference,
                            notes: item.notes ?? ""
                        )
                    )
                }
                localEntry = try applyBitwardenRemoteState(
                    item,
                    to: localEntry,
                    projectID: targetProjectID,
                    entryRepository: entryRepository
                )
                if targetProjectID == projectID {
                    existingPasskeys.removeAll { $0.id == localEntry.id }
                    if item.deletedAt == nil {
                        existingPasskeys.append(localEntry)
                    }
                }
                let localItem = bitwardenLocalItem(from: localEntry, folderID: item.folderID, folderName: item.folderName)
                itemStates[localEntry.id] = bitwardenItemSyncState(
                    localItem: localItem,
                    remoteItem: item
                )
                try reconcileBitwardenAttachments(
                    item.attachments,
                    localEntryID: localEntry.id,
                    projectID: targetProjectID,
                    entryRepository: entryRepository
                )
            case .sshKey:
                var localEntry: LocalSshKeyEntry
                if targetProjectID == projectID,
                   let existing = existingSshKeys.first(where: { isSameBitwardenSshKey($0, item) }) {
                    localEntry = existing
                } else {
                    localEntry = try entryRepository.createSshKeyEntry(
                        projectID: targetProjectID,
                        draft: LocalSshKeyEntryDraft(
                            title: bitwardenImportTitle(item.title),
                            username: item.username,
                            host: item.url,
                            publicKey: item.sshPublicKey,
                            privateKeyReference: item.sshPrivateKey,
                            passphraseHint: item.sshKeyFingerprint,
                            notes: item.notes ?? ""
                        )
                    )
                }
                localEntry = try applyBitwardenRemoteState(
                    item,
                    to: localEntry,
                    projectID: targetProjectID,
                    entryRepository: entryRepository
                )
                if targetProjectID == projectID {
                    existingSshKeys.removeAll { $0.id == localEntry.id }
                    if item.deletedAt == nil {
                        existingSshKeys.append(localEntry)
                    }
                }
                let localItem = bitwardenLocalItem(from: localEntry, folderID: item.folderID, folderName: item.folderName)
                itemStates[localEntry.id] = bitwardenItemSyncState(
                    localItem: localItem,
                    remoteItem: item
                )
                try reconcileBitwardenAttachments(
                    item.attachments,
                    localEntryID: localEntry.id,
                    projectID: targetProjectID,
                    entryRepository: entryRepository
                )
            case .secureNote:
                var localEntry: LocalNoteEntry
                if targetProjectID == projectID,
                   let existing = existingNotes.first(where: { $0.title == bitwardenImportTitle(item.title) && $0.body == (item.notes ?? "") }) {
                    localEntry = existing
                } else {
                    localEntry = try entryRepository.createNoteEntry(
                        projectID: targetProjectID,
                        draft: LocalNoteEntryDraft(
                            title: bitwardenImportTitle(item.title),
                            body: item.notes ?? ""
                        )
                    )
                }
                localEntry = try applyBitwardenRemoteState(
                    item,
                    to: localEntry,
                    projectID: targetProjectID,
                    entryRepository: entryRepository
                )
                if targetProjectID == projectID {
                    existingNotes.removeAll { $0.id == localEntry.id }
                    if item.deletedAt == nil {
                        existingNotes.append(localEntry)
                    }
                }
                let localItem = bitwardenLocalItem(from: localEntry, folderID: item.folderID, folderName: item.folderName)
                itemStates[localEntry.id] = bitwardenItemSyncState(
                    localItem: localItem,
                    remoteItem: item
                )
                try reconcileBitwardenAttachments(
                    item.attachments,
                    localEntryID: localEntry.id,
                    projectID: targetProjectID,
                    entryRepository: entryRepository
                )
            case .card:
                var localEntry: LocalCardEntry
                if targetProjectID == projectID,
                   let existing = existingCards.first(where: { $0.title == bitwardenImportTitle(item.title) && $0.notes == (item.notes ?? "") }) {
                    localEntry = existing
                } else {
                    localEntry = try entryRepository.createCardEntry(
                        projectID: targetProjectID,
                        draft: LocalCardEntryDraft(
                            title: bitwardenImportTitle(item.title),
                            cardholderName: item.cardholderName,
                            number: item.cardNumber,
                            expiryMonth: item.cardExpiryMonth,
                            expiryYear: item.cardExpiryYear,
                            cvv: item.cardCode,
                            issuer: item.folderName ?? "",
                            network: item.cardBrand,
                            notes: item.notes ?? ""
                        )
                    )
                }
                localEntry = try applyBitwardenRemoteState(
                    item,
                    to: localEntry,
                    projectID: targetProjectID,
                    entryRepository: entryRepository
                )
                if targetProjectID == projectID {
                    existingCards.removeAll { $0.id == localEntry.id }
                    if item.deletedAt == nil {
                        existingCards.append(localEntry)
                    }
                }
                let localItem = bitwardenLocalItem(from: localEntry, folderID: item.folderID)
                itemStates[localEntry.id] = bitwardenItemSyncState(
                    localItem: localItem,
                    remoteItem: item
                )
                try reconcileBitwardenAttachments(
                    item.attachments,
                    localEntryID: localEntry.id,
                    projectID: targetProjectID,
                    entryRepository: entryRepository
                )
            case .identity:
                var localEntry: LocalIdentityEntry
                if targetProjectID == projectID,
                   let existing = existingIdentities.first(where: { $0.title == bitwardenImportTitle(item.title) && $0.notes == (item.notes ?? "") }) {
                    localEntry = existing
                } else {
                    localEntry = try entryRepository.createIdentityEntry(
                        projectID: targetProjectID,
                        draft: LocalIdentityEntryDraft(
                            title: bitwardenImportTitle(item.title),
                            documentType: "Bitwarden Identity",
                            fullName: item.identityFullName.isEmpty ? item.username : item.identityFullName,
                            documentNumber: item.identityDocumentNumber,
                            issuer: item.identityIssuer.isEmpty ? (item.folderName ?? "") : item.identityIssuer,
                            country: item.identityCountry,
                            issueDate: "",
                            expiryDate: "",
                            notes: item.notes ?? ""
                        )
                    )
                }
                localEntry = try applyBitwardenRemoteState(
                    item,
                    to: localEntry,
                    projectID: targetProjectID,
                    entryRepository: entryRepository
                )
                if targetProjectID == projectID {
                    existingIdentities.removeAll { $0.id == localEntry.id }
                    if item.deletedAt == nil {
                        existingIdentities.append(localEntry)
                    }
                }
                let localItem = bitwardenLocalItem(from: localEntry, folderID: item.folderID)
                itemStates[localEntry.id] = bitwardenItemSyncState(
                    localItem: localItem,
                    remoteItem: item
                )
                try reconcileBitwardenAttachments(
                    item.attachments,
                    localEntryID: localEntry.id,
                    projectID: targetProjectID,
                    entryRepository: entryRepository
                )
            }
        }

        for send in snapshot.sends {
            let remoteFingerprint = BitwardenLocalSendSyncItem(
                localID: send.remoteID,
                title: send.title,
                body: send.body,
                notes: send.notes,
                expiresAt: send.expiresAt,
                maxViews: send.maxViews
            ).syncFingerprint
            if let existing = existingSends.first(where: { isSameBitwardenSend($0, send) }) {
                sendStates[existing.id] = BitwardenSendSyncState(
                    localID: existing.id,
                    remoteID: send.remoteID,
                    lastSyncedFingerprint: remoteFingerprint,
                    lastRemoteRevision: send.updatedAt.map { String($0.timeIntervalSince1970) },
                    isDeleted: false
                )
                continue
            }
            let created = try entryRepository.createSendEntry(
                projectID: projectID,
                draft: LocalSendEntryDraft(
                    title: bitwardenImportTitle(send.title),
                    body: send.body,
                    expiresAt: send.expiresAt,
                    maxViews: send.maxViews,
                    notes: send.notes ?? ""
                )
            )
            existingSends.append(created)
            sendStates[created.id] = BitwardenSendSyncState(
                localID: created.id,
                remoteID: send.remoteID,
                lastSyncedFingerprint: remoteFingerprint,
                lastRemoteRevision: send.updatedAt.map { String($0.timeIntervalSince1970) },
                isDeleted: false
            )
        }

        try bitwardenItemSyncStateStore.saveStates(
            sortedBitwardenItemStates(itemStates.values),
            vaultID: vaultID
        )
        try bitwardenFolderSyncStateStore.saveStates(
            folderStates.values.sorted { $0.localID < $1.localID },
            vaultID: vaultID
        )
        try bitwardenSendSyncStateStore.saveStates(
            sendStates.values.sorted { $0.localID < $1.localID },
            vaultID: vaultID
        )
    }

    func isSameBitwardenLogin(_ entry: LocalLoginEntry, _ item: BitwardenSyncItem) -> Bool {
        entry.title == bitwardenImportTitle(item.title)
            && entry.username == item.username
            && entry.url == item.url
    }

    func isSameBitwardenPasskey(_ entry: LocalPasskeyEntry, _ item: BitwardenSyncItem) -> Bool {
        entry.title == bitwardenImportTitle(item.title)
            && entry.relyingPartyID == bitwardenPasskeyRelyingPartyID(for: item)
            && entry.username == item.username
            && entry.credentialID == item.passkeyCredentialID
    }

    func isSameBitwardenSshKey(_ entry: LocalSshKeyEntry, _ item: BitwardenSyncItem) -> Bool {
        entry.title == bitwardenImportTitle(item.title)
            && entry.username == item.username
            && entry.host == item.url
            && entry.publicKey == item.sshPublicKey
    }

    func isSameBitwardenSend(_ entry: LocalSendEntry, _ send: BitwardenSendSyncItem) -> Bool {
        entry.title == bitwardenImportTitle(send.title)
            && entry.body == send.body
            && entry.expiresAt == send.expiresAt
            && entry.maxViews == send.maxViews
            && entry.notes == (send.notes ?? "")
    }

    func bitwardenImportTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Bitwarden 项目") : trimmed
    }

    func bitwardenPasskeyRelyingPartyID(for item: BitwardenSyncItem) -> String {
        if let relyingPartyID = item.passkeyRelyingPartyID.nonBlankValue {
            return relyingPartyID
        }
        guard let host = URLComponents(string: item.url)?.host?.nonBlankValue else {
            return ""
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func applyBitwardenRemoteState(
        _ item: BitwardenSyncItem,
        to entry: LocalLoginEntry,
        projectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> LocalLoginEntry {
        var current = entry
        if current.favorite != item.favorite {
            current = try entryRepository.setLoginEntryFavorite(
                projectID: projectID,
                entryID: current.id,
                favorite: item.favorite
            )
        }
        if item.deletedAt != nil {
            try entryRepository.deleteLoginEntry(projectID: projectID, entryID: current.id)
        }
        return current
    }

    func applyBitwardenRemoteState(
        _ item: BitwardenSyncItem,
        to entry: LocalNoteEntry,
        projectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> LocalNoteEntry {
        var current = entry
        if current.favorite != item.favorite {
            current = try entryRepository.setNoteEntryFavorite(
                projectID: projectID,
                entryID: current.id,
                favorite: item.favorite
            )
        }
        if item.deletedAt != nil {
            try entryRepository.deleteNoteEntry(projectID: projectID, entryID: current.id)
        }
        return current
    }

    func applyBitwardenRemoteState(
        _ item: BitwardenSyncItem,
        to entry: LocalCardEntry,
        projectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> LocalCardEntry {
        var current = entry
        if current.favorite != item.favorite {
            current = try entryRepository.setCardEntryFavorite(
                projectID: projectID,
                entryID: current.id,
                favorite: item.favorite
            )
        }
        if item.deletedAt != nil {
            try entryRepository.deleteCardEntry(projectID: projectID, entryID: current.id)
        }
        return current
    }

    func applyBitwardenRemoteState(
        _ item: BitwardenSyncItem,
        to entry: LocalIdentityEntry,
        projectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> LocalIdentityEntry {
        var current = entry
        if current.favorite != item.favorite {
            current = try entryRepository.setIdentityEntryFavorite(
                projectID: projectID,
                entryID: current.id,
                favorite: item.favorite
            )
        }
        if item.deletedAt != nil {
            try entryRepository.deleteIdentityEntry(projectID: projectID, entryID: current.id)
        }
        return current
    }

    func applyBitwardenRemoteState(
        _ item: BitwardenSyncItem,
        to entry: LocalPasskeyEntry,
        projectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> LocalPasskeyEntry {
        var current = entry
        if current.favorite != item.favorite {
            current = try entryRepository.setPasskeyEntryFavorite(
                projectID: projectID,
                entryID: current.id,
                favorite: item.favorite
            )
        }
        if item.deletedAt != nil {
            try entryRepository.deletePasskeyEntry(projectID: projectID, entryID: current.id)
        }
        return current
    }

    func applyBitwardenRemoteState(
        _ item: BitwardenSyncItem,
        to entry: LocalSshKeyEntry,
        projectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> LocalSshKeyEntry {
        var current = entry
        if current.favorite != item.favorite {
            current = try entryRepository.setSshKeyEntryFavorite(
                projectID: projectID,
                entryID: current.id,
                favorite: item.favorite
            )
        }
        if item.deletedAt != nil {
            try entryRepository.deleteSshKeyEntry(projectID: projectID, entryID: current.id)
        }
        return current
    }

    func reconcileBitwardenAttachments(
        _ remoteAttachments: [BitwardenSyncAttachment],
        localEntryID: String,
        projectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws {
        let localAttachments = try entryRepository.listAttachmentMetadata(projectID: projectID)
            .filter { $0.entryID == localEntryID && $0.source == "bitwarden" }
        let remoteByHash = Dictionary(uniqueKeysWithValues: remoteAttachments.map { attachment in
            (bitwardenAttachmentContentHash(attachment), attachment)
        })
        for local in localAttachments where remoteByHash[local.contentHash] == nil {
            try entryRepository.deleteAttachmentMetadata(projectID: projectID, attachmentID: local.id)
        }
        for attachment in remoteAttachments {
            let contentHash = bitwardenAttachmentContentHash(attachment)
            if let existing = localAttachments.first(where: { $0.contentHash == contentHash }) {
                if existing.fileName != bitwardenAttachmentFileName(attachment)
                    || existing.originalSize != Int64(attachment.byteCount)
                    || existing.wrappedContentEncryptionKey != attachment.encryptedKey {
                    _ = try entryRepository.updateAttachmentMetadata(
                        projectID: projectID,
                        attachmentID: existing.id,
                        entryID: localEntryID,
                        fileName: bitwardenAttachmentFileName(attachment),
                        mediaType: "application/octet-stream",
                        originalSize: Int64(attachment.byteCount),
                        storedSize: 0,
                        contentHash: contentHash,
                        storageMode: "remote-bitwarden",
                        source: "bitwarden",
                        downloadState: "pending-bitwarden-download",
                        wrappedContentEncryptionKey: attachment.encryptedKey,
                        localPath: nil
                    )
                }
                continue
            }
            _ = try entryRepository.createAttachmentMetadata(
                projectID: projectID,
                entryID: localEntryID,
                fileName: bitwardenAttachmentFileName(attachment),
                mediaType: "application/octet-stream",
                originalSize: Int64(attachment.byteCount),
                storedSize: 0,
                contentHash: contentHash,
                storageMode: "remote-bitwarden",
                source: "bitwarden",
                downloadState: "pending-bitwarden-download",
                wrappedContentEncryptionKey: attachment.encryptedKey,
                localPath: nil
            )
        }
    }

    func bitwardenAttachmentContentHash(_ attachment: BitwardenSyncAttachment) -> String {
        let digest = SHA256.hash(data: Data(attachment.syncFingerprint.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func bitwardenAttachmentFileName(_ attachment: BitwardenSyncAttachment) -> String {
        sanitizedAttachmentPreviewFileName(bitwardenImportTitle(attachment.fileName))
    }

    func bitwardenItemSyncState(
        localItem: BitwardenLocalItemSyncItem,
        remoteItem: BitwardenSyncItem
    ) -> BitwardenItemSyncState {
        BitwardenItemSyncState(
            localID: localItem.localID,
            remoteID: remoteItem.remoteID,
            kind: localItem.kind,
            lastSyncedFingerprint: localItem.syncFingerprint,
            lastRemoteRevision: remoteItem.updatedAt.map { String($0.timeIntervalSince1970) },
            isDeleted: remoteItem.deletedAt != nil
        )
    }

    func sortedBitwardenItemStates(
        _ states: Dictionary<String, BitwardenItemSyncState>.Values
    ) -> [BitwardenItemSyncState] {
        sortedBitwardenItemStates(Array(states))
    }

    func sortedBitwardenItemStates(
        _ states: [BitwardenItemSyncState]
    ) -> [BitwardenItemSyncState] {
        states.sorted { lhs, rhs in
            let lhsRemoteID = lhs.remoteID ?? ""
            let rhsRemoteID = rhs.remoteID ?? ""
            if lhsRemoteID != rhsRemoteID {
                return lhsRemoteID < rhsRemoteID
            }
            return lhs.localID < rhs.localID
        }
    }

    func bitwardenItemStates(
        _ states: Dictionary<String, BitwardenItemSyncState>.Values,
        assigningRemoteIDs assignedRemoteIDs: [String: String],
        revision: String
    ) -> [BitwardenItemSyncState] {
        states.map { state in
            guard let assignedRemoteID = assignedRemoteIDs[state.localID],
                  state.remoteID == nil,
                  !state.isDeleted else {
                return state
            }
            return BitwardenItemSyncState(
                localID: state.localID,
                remoteID: assignedRemoteID,
                kind: state.kind,
                lastSyncedFingerprint: state.lastSyncedFingerprint,
                lastRemoteRevision: revision.isEmpty ? state.lastRemoteRevision : revision,
                isDeleted: false
            )
        }
    }

    func bitwardenSendStates(
        _ states: Dictionary<String, BitwardenSendSyncState>.Values,
        assigningRemoteIDs assignedRemoteIDs: [String: String],
        revision: String
    ) -> [BitwardenSendSyncState] {
        states.map { state in
            guard let assignedRemoteID = assignedRemoteIDs[state.localID],
                  state.remoteID == nil,
                  !state.isDeleted else {
                return state
            }
            return BitwardenSendSyncState(
                localID: state.localID,
                remoteID: assignedRemoteID,
                lastSyncedFingerprint: state.lastSyncedFingerprint,
                lastRemoteRevision: revision.isEmpty ? state.lastRemoteRevision : revision,
                isDeleted: false
            )
        }
    }

    func bitwardenTextSendFingerprint(
        title: String,
        body: String,
        notes: String?,
        expiresAt: String,
        maxViews: Int
    ) -> String {
        [
            "text",
            title,
            body,
            notes ?? "",
            expiresAt,
            String(maxViews)
        ].joined(separator: "\u{1F}")
    }

    func bitwardenFileSendFingerprint(
        title: String,
        fileName: String,
        byteCount: Int,
        notes: String?,
        expiresAt: String,
        maxViews: Int,
        hideEmail: Bool
    ) -> String {
        [
            "file",
            title,
            fileName,
            String(byteCount),
            notes ?? "",
            expiresAt,
            String(maxViews),
            String(hideEmail)
        ].joined(separator: "\u{1F}")
    }

    func bitwardenLocalItem(from entry: LocalLoginEntry, folderID: String? = nil, folderName: String? = nil) -> BitwardenLocalItemSyncItem {
        BitwardenLocalItemSyncItem(
            localID: entry.id,
            kind: .login,
            title: entry.title,
            username: entry.username,
            url: entry.url,
            password: entry.password,
            notes: entry.notes,
            folderID: folderID,
            folderName: folderName,
            favorite: entry.favorite
        )
    }

    func bitwardenLocalItem(from entry: LocalNoteEntry, folderID: String? = nil, folderName: String? = nil) -> BitwardenLocalItemSyncItem {
        BitwardenLocalItemSyncItem(
            localID: entry.id,
            kind: .secureNote,
            title: entry.title,
            notes: entry.body,
            folderID: folderID,
            folderName: folderName,
            favorite: entry.favorite
        )
    }

    func bitwardenLocalItem(from entry: LocalTotpEntry, folderID: String? = nil, folderName: String? = nil) -> BitwardenLocalItemSyncItem {
        BitwardenLocalItemSyncItem(
            localID: entry.id,
            kind: .login,
            title: entry.title,
            username: entry.accountName,
            url: bitwardenTotpURLHint(from: entry),
            totpSecret: bitwardenTotpPayload(from: entry),
            folderID: folderID,
            folderName: folderName,
            favorite: entry.favorite
        )
    }

    func bitwardenLocalItem(from entry: LocalCardEntry, folderID: String? = nil) -> BitwardenLocalItemSyncItem {
        BitwardenLocalItemSyncItem(
            localID: entry.id,
            kind: .card,
            title: entry.title,
            notes: entry.notes,
            folderID: folderID,
            folderName: entry.issuer.nonBlankValue,
            favorite: entry.favorite,
            cardholderName: entry.cardholderName,
            cardNumber: entry.number,
            cardExpiryMonth: entry.expiryMonth,
            cardExpiryYear: entry.expiryYear,
            cardCode: entry.cvv,
            cardBrand: entry.network
        )
    }

    func bitwardenLocalItem(from entry: LocalIdentityEntry, folderID: String? = nil) -> BitwardenLocalItemSyncItem {
        BitwardenLocalItemSyncItem(
            localID: entry.id,
            kind: .identity,
            title: entry.title,
            username: entry.fullName,
            notes: entry.notes,
            folderID: folderID,
            folderName: entry.issuer.nonBlankValue,
            favorite: entry.favorite,
            identityFullName: entry.fullName,
            identityDocumentNumber: entry.documentNumber,
            identityIssuer: entry.issuer,
            identityCountry: entry.country
        )
    }

    func bitwardenLocalItem(from entry: LocalPasskeyEntry, folderID: String? = nil, folderName: String? = nil) -> BitwardenLocalItemSyncItem {
        let relyingPartyID = entry.relyingPartyID.trimmingCharacters(in: .whitespacesAndNewlines)
        return BitwardenLocalItemSyncItem(
            localID: entry.id,
            kind: .passkey,
            title: entry.title,
            username: entry.username,
            url: relyingPartyID.isEmpty ? "" : "https://\(relyingPartyID)",
            notes: entry.notes,
            folderID: folderID,
            folderName: folderName,
            favorite: entry.favorite,
            passkeyRelyingPartyID: relyingPartyID,
            passkeyRelyingPartyName: entry.title,
            passkeyCredentialID: entry.credentialID,
            passkeyUserHandle: entry.userHandle,
            passkeyPublicKeyCOSE: entry.publicKeyCOSE,
            passkeyPrivateKeyReference: entry.privateKeyReference,
            passkeyPublicKeyAlgorithm: "ECDSA",
            passkeyCounter: "0",
            passkeyDiscoverable: true
        )
    }

    func bitwardenLocalItem(from entry: LocalSshKeyEntry, folderID: String? = nil, folderName: String? = nil) -> BitwardenLocalItemSyncItem {
        BitwardenLocalItemSyncItem(
            localID: entry.id,
            kind: .sshKey,
            title: entry.title,
            username: entry.username,
            url: entry.host,
            notes: entry.notes,
            folderID: folderID,
            folderName: folderName,
            favorite: entry.favorite,
            sshPublicKey: entry.publicKey,
            sshPrivateKey: entry.privateKeyReference,
            sshKeyFingerprint: entry.passphraseHint
        )
    }

    func bitwardenTotpURLHint(from entry: LocalTotpEntry) -> String {
        let label = entry.issuer.nonBlankValue ?? entry.title
        return "otpauth://\(bitwardenOtpAuthKind(from: entry))/\(bitwardenPercentEncode(label))"
    }

    func bitwardenTotpPayload(from entry: LocalTotpEntry) -> String {
        let issuer = entry.issuer.nonBlankValue ?? entry.title
        let account = entry.accountName.nonBlankValue ?? ""
        let encodedLabel = account.isEmpty
            ? bitwardenPercentEncode(issuer)
            : "\(bitwardenPercentEncode(issuer)):\(bitwardenPercentEncode(account))"
        var query = [
            ("secret", entry.secret)
        ]
        if let explicitIssuer = entry.issuer.nonBlankValue {
            query.append(("issuer", explicitIssuer))
        }
        query.append(("period", "\(entry.period)"))
        query.append(("digits", "\(entry.digits)"))
        if let algorithm = entry.algorithm.nonBlankValue {
            query.append(("algorithm", algorithm.uppercased()))
        }
        if bitwardenOtpAuthKind(from: entry) == "hotp" {
            query.append(("counter", "\(entry.counter)"))
        }
        return "otpauth://\(bitwardenOtpAuthKind(from: entry))/\(encodedLabel)?"
            + query.map { "\(bitwardenPercentEncode($0.0))=\(bitwardenPercentEncode($0.1))" }.joined(separator: "&")
    }

    func bitwardenOtpAuthKind(from entry: LocalTotpEntry) -> String {
        entry.otpType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "hotp" ? "hotp" : "totp"
    }

    func bitwardenPercentEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    func makeBitwardenItemSyncPlan(
        remoteItems: [BitwardenSyncItem],
        previousStates: [BitwardenItemSyncState],
        folderStates: [BitwardenFolderSyncState] = []
    ) -> BitwardenItemSyncPlan {
        let localSync = makeBitwardenLocalSyncItems(folderStates: folderStates)
        return BitwardenItemSyncPlanner().plan(
            localItems: localSync.localItems,
            deletedLocalItems: localSync.deletedLocalItems,
            remoteItems: remoteItems,
            previousStates: previousStates
        )
    }

    /// 把当前保险库里的各类条目转换成 Bitwarden 侧的合并输入。
    /// 预览计数与推送计划共用这一份映射，避免两处字段顺序漂移。
    func makeBitwardenLocalSyncItems(
        folderStates: [BitwardenFolderSyncState] = []
    ) -> (localItems: [BitwardenLocalItemSyncItem], deletedLocalItems: [BitwardenLocalItemSyncItem]) {
        let folderStateByProjectID = Dictionary(uniqueKeysWithValues: folderStates.map { ($0.localID, $0) })
        let localLoginItems: [BitwardenLocalItemSyncItem] = loginEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID, folderName: folderStateByProjectID[$0.projectID]?.name)
        }
        let localNoteItems: [BitwardenLocalItemSyncItem] = noteEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID, folderName: folderStateByProjectID[$0.projectID]?.name)
        }
        let localTotpItems: [BitwardenLocalItemSyncItem] = totpEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID, folderName: folderStateByProjectID[$0.projectID]?.name)
        }
        let localCardItems: [BitwardenLocalItemSyncItem] = cardEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID)
        }
        let localIdentityItems: [BitwardenLocalItemSyncItem] = identityEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID)
        }
        let localPasskeyItems: [BitwardenLocalItemSyncItem] = passkeyEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID, folderName: folderStateByProjectID[$0.projectID]?.name)
        }
        let localSshKeyItems: [BitwardenLocalItemSyncItem] = sshKeyEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID, folderName: folderStateByProjectID[$0.projectID]?.name)
        }
        let deletedLoginItems: [BitwardenLocalItemSyncItem] = deletedLoginEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID, folderName: folderStateByProjectID[$0.projectID]?.name)
        }
        let deletedNoteItems: [BitwardenLocalItemSyncItem] = deletedNoteEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID, folderName: folderStateByProjectID[$0.projectID]?.name)
        }
        let deletedTotpItems: [BitwardenLocalItemSyncItem] = deletedTotpEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID, folderName: folderStateByProjectID[$0.projectID]?.name)
        }
        let deletedCardItems: [BitwardenLocalItemSyncItem] = deletedCardEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID)
        }
        let deletedIdentityItems: [BitwardenLocalItemSyncItem] = deletedIdentityEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID)
        }
        let deletedPasskeyItems: [BitwardenLocalItemSyncItem] = deletedPasskeyEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID, folderName: folderStateByProjectID[$0.projectID]?.name)
        }
        let deletedSshKeyItems: [BitwardenLocalItemSyncItem] = deletedSshKeyEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID, folderName: folderStateByProjectID[$0.projectID]?.name)
        }
        let localItems = localLoginItems + localTotpItems + localNoteItems + localCardItems + localIdentityItems + localPasskeyItems + localSshKeyItems
        let deletedLocalItems = deletedLoginItems + deletedTotpItems + deletedNoteItems + deletedCardItems + deletedIdentityItems + deletedPasskeyItems + deletedSshKeyItems
        return (localItems, deletedLocalItems)
    }

    /// 预览用的字段级合并计数：新增/更新/冲突/删除数量与集合清单。
    func bitwardenSyncMergeSummary(
        snapshot: BitwardenSyncSnapshot,
        vaultID: String
    ) -> BitwardenSyncPreviewSummary {
        let previousItemStates = (try? bitwardenItemSyncStateStore.loadStates(vaultID: vaultID)) ?? []
        let folderStates = (try? bitwardenFolderSyncStateStore.loadStates(vaultID: vaultID)) ?? []
        let localSync = makeBitwardenLocalSyncItems(folderStates: folderStates)
        return BitwardenSyncPreviewBuilder().summary(
            remote: snapshot,
            localItems: localSync.localItems,
            deletedLocalItems: localSync.deletedLocalItems,
            previousStates: previousItemStates
        )
    }

    /// 只存修订号与时间，不含任何 token 或条目内容。
    func saveBitwardenSyncCheckpoint(revision: BitwardenSyncRevision?, vaultID: String) {
        guard let revision else { return }
        try? bitwardenSyncCheckpointStore.saveCheckpoint(
            AppBitwardenSyncCheckpoint(revision: revision, vaultID: vaultID, syncedAt: Date()),
            vaultID: vaultID
        )
    }

    func makeBitwardenSendSyncPlan(
        remoteSends: [BitwardenSendSyncItem],
        previousStates: [BitwardenSendSyncState]
    ) -> BitwardenSendSyncPlan {
        BitwardenSendSyncPlanner().plan(
            localSends: sendEntries.map { entry in
                BitwardenLocalSendSyncItem(
                    localID: entry.id,
                    title: entry.title,
                    body: entry.body,
                    notes: entry.notes,
                    expiresAt: entry.expiresAt,
                    maxViews: entry.maxViews
                )
            },
            deletedLocalSends: deletedSendEntries.map { entry in
                BitwardenLocalSendSyncItem(
                    localID: entry.id,
                    title: entry.title,
                    body: entry.body,
                    notes: entry.notes,
                    expiresAt: entry.expiresAt,
                    maxViews: entry.maxViews
                )
            },
            remoteSends: remoteSends,
            previousStates: previousStates
        )
    }

    func readableBitwardenSyncErrorMessage(for error: Error) -> String {
        if let appError = error as? AppBitwardenSyncError {
            return appError.localizedDescription
        }
        if let providerError = error as? BitwardenSyncProviderError {
            return providerError.localizedDescription
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return String(localized: "网络不可用，请检查连接后重试。")
            case .timedOut:
                return String(localized: "Bitwarden 请求超时，请稍后再试。")
            default:
                return String(localized: "Bitwarden 连接失败，请检查网络后重试。")
            }
        }
        return String(localized: "Bitwarden 同步失败，请稍后重试。")
    }

    func validBitwardenServerURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host,
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return url
    }

    func bitwardenDownloadedAttachmentLocalPath(
        _ attachment: LocalAttachmentMetadata,
        fileName: String
    ) -> String {
        let rawIdentifier = attachment.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = rawIdentifier.isEmpty ? UUID().uuidString : rawIdentifier
        return sanitizedAttachmentPreviewFileName(
            "bitwarden-attachment-\(identifier)-\(fileName)"
        )
    }
}
