import Foundation
import MonicaCore
import MonicaStorage

// slice C1: LoginEntries 域（登录条目 CRUD、编辑态、收藏、重复条目合并），从 AppSessionModel.swift 逐字搬移。
extension AppSessionModel {
    var filteredLoginEntries: [LocalLoginEntry] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = loginSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return filteredFavoriteEntries(
            loginEntries,
            query: query,
            favoritesOnly: showFavoriteLoginEntriesOnly,
            isFavorite: { $0.favorite }
        ) { entry, query in
            entry.title.localizedCaseInsensitiveContains(query)
                || entry.username.localizedCaseInsensitiveContains(query)
                || entry.url.localizedCaseInsensitiveContains(query)
        }
    }

    var loginStackedGroups: [AppLoginStackedGroup] {
        let grouped = Dictionary(grouping: filteredLoginEntries) { entry in
            loginStackedGroupKey(for: entry)
        }
        return grouped.map { key, entries in
            let titles = entries
                .map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let usernames = entries
                .map { $0.username.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return AppLoginStackedGroup(
                id: "login-stack-\(key.normalized)",
                title: key.title,
                value: itemCountLabel(entries.count),
                detail: usernames.prefix(3).joined(separator: " / "),
                preview: titles.prefix(3).joined(separator: " / "),
                systemImage: key.isWebsite ? "globe" : "textformat",
                entryIDs: entries.map(\.id)
            )
        }
        .sorted { lhs, rhs in
            if lhs.entryIDs.count != rhs.entryIDs.count {
                return lhs.entryIDs.count > rhs.entryIDs.count
            }
            if lhs.systemImage != rhs.systemImage {
                return lhs.systemImage == "globe"
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    func loginStackedGroupKey(for entry: LocalLoginEntry) -> AppLoginStackedGroupKey {
        if let host = normalizedLoginHost(from: entry.url) {
            return AppLoginStackedGroupKey(
                title: host,
                normalized: host,
                isWebsite: true
            )
        }
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = title.isEmpty ? String(localized: "未命名") : title
        return AppLoginStackedGroupKey(
            title: fallbackTitle,
            normalized: fallbackTitle.lowercased(),
            isWebsite: false
        )
    }

    func createLoginEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project: LocalVaultProject
            if let activeProject {
                project = activeProject
            } else {
                project = try createOrReuseVaultProject(title: projectTitle, entryRepository: entryRepository)
                activeProject = project
            }
            var entry = try entryRepository.createLoginEntry(
                projectID: project.id,
                draft: LocalLoginEntryDraft(
                    title: loginTitle,
                    username: loginUsername,
                    account: loginAccount,
                    password: loginPassword,
                    url: loginURL,
                    notes: loginNotes,
                    urls: [loginURL] + loginAdditionalURLs,
                    appBundleID: loginAppBundleID,
                    appName: loginAppName
                )
            )
            if let loginIcon {
                entry = try entryRepository.setLoginEntryIcon(
                    projectID: project.id,
                    entryID: entry.id,
                    icon: loginIcon
                )
            }
            loginPassword = ""
            loginAdditionalURLs = []
            loginAppBundleID = ""
            loginAppName = ""
            loginNotes = ""
            loginEntries = try entryRepository.listLoginEntries(projectID: project.id)
            deletedLoginEntries = try entryRepository.listDeletedLoginEntries(projectID: project.id)
            try refreshAutoFillEncryptedIndexIfConfigured()
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .login,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            AppDiagnosticEmission.passkeyFailure(error, stage: .create)
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func generateLoginPassword() throws {
        recordUserActivity()
        do {
            loginPassword = try passwordGenerator()
            entryOperationState = .succeeded(String(localized: "已生成密码"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func selectLoginEntryForEditing(_ entry: LocalLoginEntry) {
        recordUserActivity()
        editingLoginEntryID = entry.id
        editingLoginTitle = entry.title
        editingLoginUsername = entry.username
        editingLoginAccount = entry.account
        editingLoginPassword = entry.password
        editingLoginURL = entry.url
        editingLoginFavorite = entry.favorite
        editingLoginIcon = entry.icon
        let urls = entry.effectiveURLs
        editingLoginAdditionalURLs = urls.count > 1 ? Array(urls.dropFirst()) : []
        editingLoginAppBundleID = entry.appBundleID
        editingLoginAppName = entry.appName
        editingLoginNotes = entry.notes
        editingLoginPasswordHistory = entry.passwordHistory
    }

    func updateSelectedLoginEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingLoginEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            var entry = try entryRepository.updateLoginEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalLoginEntryDraft(
                    title: editingLoginTitle,
                    username: editingLoginUsername,
                    account: editingLoginAccount,
                    password: editingLoginPassword,
                    url: editingLoginURL,
                    notes: editingLoginNotes,
                    urls: [editingLoginURL] + editingLoginAdditionalURLs,
                    appBundleID: editingLoginAppBundleID,
                    appName: editingLoginAppName,
                    passwordHistory: editingLoginPasswordHistory
                )
            )
            // 图标不属于编辑表单字段：只有用户显式改过才回写，避免把旧值当成变更。
            if entry.icon != editingLoginIcon {
                entry = try entryRepository.setLoginEntryIcon(
                    projectID: projectID,
                    entryID: entryID,
                    icon: editingLoginIcon
                )
            }
            loginEntries = try entryRepository.listLoginEntries(projectID: projectID)
            deletedLoginEntries = try entryRepository.listDeletedLoginEntries(projectID: projectID)
            selectLoginEntryForEditing(entry)
            try refreshAutoFillEncryptedIndexIfConfigured()
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .login,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    /// 删除详情页里的一条旧密码；密码本身不变，因此不会再被自动补回。
    func deleteLoginPasswordHistoryEntry(entryID: String, historyEntryID: String) throws {
        try mutateLoginPasswordHistory(entryID: entryID) { history in
            LoginPasswordHistoryPolicy.removing(id: historyEntryID, from: history)
        }
    }

    /// 清空详情页里展示的密码历史。
    func clearLoginPasswordHistory(entryID: String) throws {
        try mutateLoginPasswordHistory(entryID: entryID) { _ in [] }
    }

    func mutateLoginPasswordHistory(
        entryID: String,
        transform: ([LocalLoginPasswordHistoryEntry]) -> [LocalLoginPasswordHistoryEntry]
    ) throws {
        recordUserActivity()
        guard let entryRepository = activeEntryRepository,
              let projectID = activeProject?.id,
              let entry = loginEntries.first(where: { $0.id == entryID })
        else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }

        do {
            let updated = try entryRepository.updateLoginEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalLoginEntryDraft(
                    title: entry.title,
                    username: entry.username,
                    account: entry.account,
                    password: entry.password,
                    url: entry.url,
                    notes: entry.notes,
                    urls: entry.effectiveURLs,
                    appBundleID: entry.appBundleID,
                    appName: entry.appName,
                    passwordHistory: transform(entry.passwordHistory)
                )
            )
            loginEntries = try entryRepository.listLoginEntries(projectID: projectID)
            if editingLoginEntryID == entryID {
                selectLoginEntryForEditing(updated)
            }
            entryOperationState = .succeeded(updated.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func generateSelectedLoginPassword() throws {
        recordUserActivity()
        do {
            editingLoginPassword = try passwordGenerator()
            entryOperationState = .succeeded(String(localized: "已生成密码"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedLoginFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingLoginEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setLoginEntryFavorite(
                projectID: projectID,
                entryID: entryID,
                favorite: favorite
            )
            loginEntries = try entryRepository.listLoginEntries(projectID: projectID)
            selectLoginEntryForEditing(updated)
            entryOperationState = .succeeded(favorite ? String(localized: "已收藏 \(updated.title)") : String(localized: "已取消收藏 \(updated.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedLoginEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingLoginEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingLoginTitle
            try entryRepository.deleteLoginEntry(projectID: projectID, entryID: entryID)
            loginEntries = try entryRepository.listLoginEntries(projectID: projectID)
            deletedLoginEntries = try entryRepository.listDeletedLoginEntries(projectID: projectID)
            clearEditingLoginEntry()
            try refreshAutoFillEncryptedIndexIfConfigured()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .login,
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

    func mergeDuplicateLoginPreview(_ preview: AppDuplicateLoginMergePreview) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            guard let currentPreview = duplicateLoginMergePreviews.first(where: { $0.id == preview.id }) else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            for entryID in currentPreview.duplicateEntryIDs {
                try entryRepository.deleteLoginEntry(projectID: projectID, entryID: entryID)
            }
            lastDuplicateLoginMergeUndo = AppDuplicateLoginMergeUndo(
                title: currentPreview.title,
                restoredEntryIDs: currentPreview.duplicateEntryIDs
            )
            loginEntries = try entryRepository.listLoginEntries(projectID: projectID)
            deletedLoginEntries = try entryRepository.listDeletedLoginEntries(projectID: projectID)
            try refreshAutoFillEncryptedIndexIfConfigured()
            entryOperationState = .succeeded(String(localized: "已合并 \(currentPreview.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func undoLastDuplicateLoginMerge() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let undo = lastDuplicateLoginMergeUndo,
                  let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            for entryID in undo.restoredEntryIDs {
                _ = try entryRepository.restoreLoginEntry(projectID: projectID, entryID: entryID)
            }
            loginEntries = try entryRepository.listLoginEntries(projectID: projectID)
            deletedLoginEntries = try entryRepository.listDeletedLoginEntries(projectID: projectID)
            try refreshAutoFillEncryptedIndexIfConfigured()
            lastDuplicateLoginMergeUndo = nil
            entryOperationState = .succeeded(String(localized: "已撤销合并 \(undo.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func ignoreDuplicateLoginPreview(_ preview: AppDuplicateLoginMergePreview) {
        recordUserActivity()

        guard let group = duplicateLoginGroups(in: loginEntries, excludingIgnored: false)
            .first(where: { group in
                "duplicate-login-\(group.entries[0].id)" == preview.id
            })
        else {
            return
        }

        ignoredDuplicateLoginKeys.insert(group.key)
        entryOperationState = .succeeded(String(localized: "已忽略 \(preview.title)"))
    }

    func clearIgnoredDuplicateLoginPreviews() {
        recordUserActivity()
        ignoredDuplicateLoginKeys.removeAll()
        entryOperationState = .succeeded(String(localized: "已恢复重复项提示"))
    }

    func restoreLoginEntry(_ entry: LocalLoginEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreLoginEntry(
                projectID: projectID,
                entryID: entry.id
            )
            loginEntries = try entryRepository.listLoginEntries(projectID: projectID)
            deletedLoginEntries = try entryRepository.listDeletedLoginEntries(projectID: projectID)
            try refreshAutoFillEncryptedIndexIfConfigured()
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .login,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded(String(localized: "已恢复 \(restored.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func clearEditingLoginEntry() {
        editingLoginEntryID = nil
        editingLoginTitle = ""
        editingLoginUsername = ""
        editingLoginAccount = ""
        editingLoginPassword = ""
        editingLoginURL = ""
        editingLoginFavorite = false
        editingLoginAdditionalURLs = []
        editingLoginAppBundleID = ""
        editingLoginAppName = ""
        editingLoginNotes = ""
        editingLoginPasswordHistory = []
    }
}
