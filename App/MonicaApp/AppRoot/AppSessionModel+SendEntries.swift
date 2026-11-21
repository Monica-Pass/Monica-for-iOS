import Foundation
import MonicaCore
import MonicaStorage
import MonicaSync
import UniformTypeIdentifiers

// slice C1: SendEntries 域（Bitwarden Send 条目 CRUD、接收、删除与恢复），从 AppSessionModel.swift 逐字搬移。
extension AppSessionModel {
    var filteredSendEntries: [LocalSendEntry] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = sendSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return filteredFavoriteEntries(
            sendEntries,
            query: query,
            favoritesOnly: showFavoriteSendEntriesOnly,
            isFavorite: { $0.favorite }
        ) { entry, query in
            entry.title.localizedCaseInsensitiveContains(query)
                || entry.body.localizedCaseInsensitiveContains(query)
                || entry.expiresAt.localizedCaseInsensitiveContains(query)
                || entry.notes.localizedCaseInsensitiveContains(query)
        }
    }

    func createSendEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project = try ensureActiveProject(projectTitle: projectTitle, entryRepository: entryRepository)
            let entry = try entryRepository.createSendEntry(
                projectID: project.id,
                draft: LocalSendEntryDraft(
                    title: sendTitle,
                    body: sendBody,
                    expiresAt: sendExpiresAt,
                    maxViews: sendMaxViews,
                    notes: sendNotes
                )
            )
            sendBody = ""
            sendEntries = try entryRepository.listSendEntries(projectID: project.id)
            deletedSendEntries = try entryRepository.listDeletedSendEntries(projectID: project.id)
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .send,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    @discardableResult
    func createBitwardenFileSend(
        title: String,
        fileName: String,
        fileContent: Data,
        mediaType: String,
        notes: String,
        expiresAt: String,
        maxViews: Int,
        password: String?,
        hideEmail: Bool
    ) async throws -> BitwardenSyncPushResult {
        recordUserActivity()
        bitwardenSyncState = .running
        entryOperationState = .running

        do {
            let session = try requireActiveVaultSession()
            let provider = try requireBitwardenSyncProvider()
            let snapshot = try await provider.pullSnapshot()
            let preview = AppBitwardenSyncPreview(snapshot: snapshot)
            let previousItemStates = try bitwardenItemSyncStateStore.loadStates(vaultID: session.handle.vaultID)
            let previousSendStates = try bitwardenSendSyncStateStore.loadStates(vaultID: session.handle.vaultID)
            try validateBitwardenRemoteSnapshotIsSafe(
                snapshot,
                previousItemStates: previousItemStates,
                previousSendStates: previousSendStates
            )
            bitwardenSyncPreview = preview
            let localID = bitwardenFileSendLocalIDProvider()
            let sanitizedFileName = sanitizedAttachmentPreviewFileName(fileName)
            let mutation = BitwardenSyncMutation.upsertFileSend(
                localID: localID,
                remoteID: nil,
                title: title,
                fileName: sanitizedFileName,
                fileContent: fileContent,
                mediaType: mediaType.nonBlankValue ?? "application/octet-stream",
                notes: notes.nonBlankValue,
                expiresAt: expiresAt,
                maxViews: maxViews,
                password: password?.nonBlankValue,
                hideEmail: hideEmail
            )
            let result: BitwardenSyncPushResult
            do {
                result = try await provider.pushMutations([mutation])
            } catch {
                throw error
            }

            var statesByLocalID = Dictionary(uniqueKeysWithValues: previousSendStates.map { ($0.localID, $0) })
            statesByLocalID[localID] = BitwardenSendSyncState(
                localID: localID,
                remoteID: result.assignedRemoteIDs[localID],
                lastSyncedFingerprint: bitwardenFileSendFingerprint(
                    title: title,
                    fileName: sanitizedFileName,
                    byteCount: fileContent.count,
                    notes: notes.nonBlankValue,
                    expiresAt: expiresAt,
                    maxViews: maxViews,
                    hideEmail: hideEmail
                ),
                lastRemoteRevision: result.revision.nonBlankValue,
                isDeleted: false
            )
            try bitwardenSendSyncStateStore.saveStates(
                statesByLocalID.values.sorted { $0.localID < $1.localID },
                vaultID: session.handle.vaultID
            )
            bitwardenSyncState = .pushed(
                acceptedMutationCount: result.acceptedMutationCount,
                conflictCount: result.conflicts.count
            )
            entryOperationState = .succeeded(title)
            return result
        } catch {
            if case .queuedForRetry = bitwardenSyncState {
                entryOperationState = .failed(readableBitwardenSyncErrorMessage(for: error))
                throw error
            }
            let message = readableBitwardenSyncErrorMessage(for: error)
            bitwardenSyncState = .failed(message)
            entryOperationState = .failed(message)
            throw error
        }
    }

    /// 创建文本型 Bitwarden Send 并保留分享链接。
    /// 与文件型相同，先 pull 一次做安全检查，再推送到远端。
    @discardableResult
    func createBitwardenTextSend(
        title: String,
        text: String,
        notes: String,
        expiresAt: String,
        maxViews: Int,
        password: String?,
        hideEmail: Bool
    ) async throws -> BitwardenTextSendCreateResult {
        recordUserActivity()
        bitwardenSyncState = .running
        entryOperationState = .running

        do {
            let session = try requireActiveVaultSession()
            let provider = try requireBitwardenSyncProvider()
            let snapshot = try await provider.pullSnapshot()
            let previousItemStates = try bitwardenItemSyncStateStore.loadStates(vaultID: session.handle.vaultID)
            let previousSendStates = try bitwardenSendSyncStateStore.loadStates(vaultID: session.handle.vaultID)
            try validateBitwardenRemoteSnapshotIsSafe(
                snapshot,
                previousItemStates: previousItemStates,
                previousSendStates: previousSendStates
            )

            let result = try await provider.createTextSend(
                BitwardenTextSendCreateRequest(
                    title: title,
                    text: text,
                    notes: notes.nonBlankValue,
                    expiresAt: expiresAt,
                    maxViews: maxViews,
                    password: password?.nonBlankValue,
                    hideEmail: hideEmail
                )
            )

            // 记录同步状态，让后续同步不会把它当成新条目重复上传。
            let localID = bitwardenTextSendLocalIDProvider()
            var statesByLocalID = Dictionary(uniqueKeysWithValues: previousSendStates.map { ($0.localID, $0) })
            statesByLocalID[localID] = BitwardenSendSyncState(
                localID: localID,
                remoteID: result.remoteID,
                lastSyncedFingerprint: bitwardenTextSendFingerprint(
                    title: title,
                    body: text,
                    notes: notes.nonBlankValue,
                    expiresAt: expiresAt,
                    maxViews: maxViews
                ),
                lastRemoteRevision: result.revision.isEmpty ? nil : result.revision
            )
            try bitwardenSendSyncStateStore.saveStates(
                Array(statesByLocalID.values),
                vaultID: session.handle.vaultID
            )

            // 链接只在创建时可得；顺带把内容也落成本地 Send 条目，方便在列表里回看。
            if let entryRepository = activeEntryRepository,
               let projectID = activeProject?.id {
                _ = try? entryRepository.createSendEntry(
                    projectID: projectID,
                    draft: LocalSendEntryDraft(
                        title: title,
                        body: text,
                        expiresAt: expiresAt,
                        maxViews: maxViews,
                        notes: notes
                    )
                )
                sendEntries = (try? entryRepository.listSendEntries(projectID: projectID)) ?? sendEntries
            }

            bitwardenSendShareLink = result.link.flatMap { link in
                bitwardenSendLinkURL(link)
            }
            bitwardenSyncState = .idle
            entryOperationState = .succeeded(result.redactedSummary)
            sendTitle = ""
            sendBody = ""
            sendNotes = ""
            sendPassword = ""
            sendMaxViews = 1
            return result
        } catch {
            bitwardenSyncState = .failed(readableBitwardenSyncErrorMessage(for: error))
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    /// 用 web vault 地址拼出完整链接；API 地址与 web 域名不同，需从 session 推导。
    func bitwardenSendLinkURL(_ link: BitwardenSendLink) -> String? {
        // Bitwarden 约定：api.bitwarden.com ↔ vault.bitwarden.com。
        // 自托管时 serverURL 与 apiURL 通常同源，直接用 serverURL。
        guard let serverURL = bitwardenSendWebVaultURL() else { return nil }
        return link.url(serverBaseURL: serverURL)?.absoluteString
    }

    /// web vault 地址：Bitwarden 官方约定 api.bitwarden.com ↔ vault.bitwarden.com；
    /// 自托管时 serverURL 与 apiURL 同源，直接用 serverURL。
    func bitwardenSendWebVaultURL() -> URL? {
        guard let session = try? bitwardenAuthenticationSessionStore.loadSession() else {
            return URL(string: "https://vault.bitwarden.com")
        }
        let serverURL = session.serverURL
        if let host = serverURL.host(), !host.isEmpty {
            if host.hasPrefix("api.") {
                return URL(string: "https://vault." + host.dropFirst("api.".count))
            }
            return serverURL
        }
        return URL(string: "https://vault.bitwarden.com")
    }

    /// 匿名接收 Send：不需要登录，只需要链接（和可能的访问密码）。
    @discardableResult
    func receiveBitwardenSend(linkInput: String, password: String) async throws -> BitwardenReceivedSend {
        recordUserActivity()
        bitwardenReceiveState = .running

        do {
            let trimmed = linkInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw AppBitwardenSyncError.invalidSendLink
            }
            guard let serverURL = bitwardenSendWebVaultURL(),
                  let apiURL = bitwardenSendAPIURL()
            else {
                throw AppBitwardenSyncError.invalidSendLink
            }
            guard let link = BitwardenSendLink.parse(urlString: trimmed, serverBaseURL: serverURL) else {
                throw AppBitwardenSyncError.invalidSendLink
            }
            // 接收端不依赖登录态；provider 若未装配就用默认实现（仍可匿名 GET）。
            let provider = bitwardenSyncProvider ?? DefaultBitwardenSyncProvider()
            let received = try await provider.fetchSend(
                BitwardenSendFetchRequest(
                    link: link,
                    password: password.nonBlankValue,
                    apiURL: apiURL
                )
            )
            bitwardenReceivedSend = received
            bitwardenReceiveState = .succeeded(received.title)
            bitwardenReceivePassword = ""
            return received
        } catch {
            bitwardenReceivedSend = nil
            bitwardenReceiveState = .failed(readableBitwardenSyncErrorMessage(for: error))
            throw error
        }
    }

    func bitwardenSendAPIURL() -> URL? {
        if let session = try? bitwardenAuthenticationSessionStore.loadSession() {
            return session.apiURL
        }
        return URL(string: "https://api.bitwarden.com")
    }

    func clearBitwardenReceiveResult() {
        bitwardenReceivedSend = nil
        bitwardenReceiveState = .idle
        bitwardenReceiveLinkInput = ""
        bitwardenReceivePassword = ""
    }

    func createSelectedBitwardenFileSend() async throws -> BitwardenSyncPushResult {
        guard let fileContent = sendFileContent,
              !sendFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AppBitwardenSyncError.fileSendUnavailable
        }
        let result = try await createBitwardenFileSend(
            title: sendTitle,
            fileName: sendFileName,
            fileContent: fileContent,
            mediaType: sendFileMediaType,
            notes: sendNotes,
            expiresAt: sendExpiresAt,
            maxViews: sendMaxViews,
            password: sendPassword,
            hideEmail: sendHideEmail
        )
        sendFileName = ""
        sendFileContent = nil
        sendFileMediaType = "application/octet-stream"
        sendPassword = ""
        return result
    }

    func selectBitwardenSendFile(url: URL) throws {
        recordUserActivity()
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        sendFileContent = try Data(contentsOf: url)
        sendFileName = sanitizedAttachmentPreviewFileName(url.lastPathComponent)
        sendFileMediaType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        if sendTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sendTitle = sendFileName
        }
    }

    func selectSendEntryForEditing(_ entry: LocalSendEntry) {
        recordUserActivity()
        editingSendEntryID = entry.id
        editingSendTitle = entry.title
        editingSendBody = entry.body
        editingSendExpiresAt = entry.expiresAt
        editingSendMaxViews = entry.maxViews
        editingSendNotes = entry.notes
        editingSendFavorite = entry.favorite
    }

    func updateSelectedSendEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingSendEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let entry = try entryRepository.updateSendEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalSendEntryDraft(
                    title: editingSendTitle,
                    body: editingSendBody,
                    expiresAt: editingSendExpiresAt,
                    maxViews: editingSendMaxViews,
                    notes: editingSendNotes
                )
            )
            sendEntries = try entryRepository.listSendEntries(projectID: projectID)
            deletedSendEntries = try entryRepository.listDeletedSendEntries(projectID: projectID)
            selectSendEntryForEditing(entry)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .send,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedSendFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingSendEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setSendEntryFavorite(projectID: projectID, entryID: entryID, favorite: favorite)
            sendEntries = try entryRepository.listSendEntries(projectID: projectID)
            selectSendEntryForEditing(updated)
            entryOperationState = .succeeded(favorite ? String(localized: "已收藏 \(updated.title)") : String(localized: "已取消收藏 \(updated.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedSendEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingSendEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingSendTitle
            try entryRepository.deleteSendEntry(projectID: projectID, entryID: entryID)
            sendEntries = try entryRepository.listSendEntries(projectID: projectID)
            deletedSendEntries = try entryRepository.listDeletedSendEntries(projectID: projectID)
            clearEditingSendEntry()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .send,
                itemID: entryID,
                itemTitle: deletedTitle
            )
            entryOperationState = .succeeded(String(localized: "已删除 \(deletedTitle)"))
            haptics.play(.error)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            haptics.play(.error)
            throw error
        }
    }

    func restoreSendEntry(_ entry: LocalSendEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreSendEntry(projectID: projectID, entryID: entry.id)
            sendEntries = try entryRepository.listSendEntries(projectID: projectID)
            deletedSendEntries = try entryRepository.listDeletedSendEntries(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .send,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded(String(localized: "已恢复 \(restored.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func clearEditingSendEntry() {
        editingSendEntryID = nil
        editingSendTitle = ""
        editingSendBody = ""
        editingSendExpiresAt = ""
        editingSendMaxViews = 1
        editingSendNotes = ""
        editingSendFavorite = false
    }
}
