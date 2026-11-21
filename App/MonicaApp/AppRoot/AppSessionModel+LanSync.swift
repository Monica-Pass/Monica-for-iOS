//
//  AppSessionModel+LanSync.swift
//  Monica
//
//  会话模型的局域网同步桥接（见原文件 MARK: 局域网同步桥接）。
//

import MonicaStorage
import MonicaSync
import Foundation
import UIKit

extension AppSessionModel {
    /// 当前解锁保险库的标识，用于局域网同步页面展示。
    var lanSyncVaultID: String {
        activeVaultSession?.handle.vaultID ?? ""
    }

    /// 创建局域网同步协调器。只能在保险库解锁状态下调用；协议、加密与合并
    /// 逻辑都在 MonicaSync 包内，这里只负责把保险库条目映射成快照并应用合并结果。
    @MainActor
    func makeLanSyncCoordinator() throws -> AppLanSyncCoordinator {
        guard vaultState == .unlocked,
              let unlockedSession = activeVaultSession,
              let entryRepository = activeEntryRepository
        else {
            throw AppLanSyncError.vaultLocked
        }

        let stateFileURL = unlockedSession.descriptor.fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(LanSyncProtocolSpec.syncStateFileName, isDirectory: false)
        let bridge = AppLanSyncVaultBridge(
            vaultID: unlockedSession.handle.vaultID,
            localDeviceID: unlockedSession.handle.deviceID,
            displayName: UIDevice.current.name,
            stateFileURL: stateFileURL,
            loadEntries: { [weak self] in
                guard let self else { throw AppLanSyncError.vaultLocked }
                return try self.loadLanSyncEntries(entryRepository: entryRepository)
            },
            loadDeletedEntryIDs: { [weak self] in
                guard let self else { throw AppLanSyncError.vaultLocked }
                return try self.loadLanSyncDeletedEntryIDs(entryRepository: entryRepository)
            },
            apply: { [weak self] actions, existingMappings in
                guard let self else { throw AppLanSyncError.vaultLocked }
                return try self.applyLanSyncActions(
                    actions,
                    existingMappings: existingMappings,
                    entryRepository: entryRepository
                )
            },
            refresh: { [weak self] in
                guard let self else { throw AppLanSyncError.vaultLocked }
                try self.refreshAfterLanSync(entryRepository: entryRepository)
            }
        )
        return AppLanSyncCoordinator(bridge: bridge)
    }

    // MARK: 读取本机条目

    @MainActor
    private func loadLanSyncEntries(
        entryRepository: LocalVaultEntryRepository
    ) throws -> [AppLanSyncEntryDraft] {
        let projects = try entryRepository.listProjects()
        var drafts: [AppLanSyncEntryDraft] = []
        for project in projects {
            for entry in try entryRepository.listLoginEntries(projectID: project.id) {
                drafts.append(
                    AppLanSyncEntryDraft(
                        localEntryID: entry.id,
                        projectTitle: project.title,
                        title: entry.title,
                        favorite: entry.favorite,
                        content: .login(
                            LanSyncLoginContent(
                                username: entry.username,
                                password: entry.password,
                                url: entry.url,
                                notes: entry.notes
                            )
                        ),
                        kind: .login
                    )
                )
            }
            for entry in try entryRepository.listNoteEntries(projectID: project.id) {
                drafts.append(
                    AppLanSyncEntryDraft(
                        localEntryID: entry.id,
                        projectTitle: project.title,
                        title: entry.title,
                        favorite: entry.favorite,
                        content: .note(LanSyncNoteContent(body: entry.body)),
                        kind: .note
                    )
                )
            }
            for entry in try entryRepository.listTotpEntries(projectID: project.id) {
                drafts.append(
                    AppLanSyncEntryDraft(
                        localEntryID: entry.id,
                        projectTitle: project.title,
                        title: entry.title,
                        favorite: entry.favorite,
                        content: .totp(
                            LanSyncTotpContent(
                                secret: entry.secret,
                                issuer: entry.issuer,
                                accountName: entry.accountName,
                                period: Int(entry.period),
                                digits: Int(entry.digits),
                                algorithm: entry.algorithm,
                                otpType: entry.otpType,
                                counter: Int(entry.counter)
                            )
                        ),
                        kind: .totp
                    )
                )
            }
        }
        return drafts
    }

    @MainActor
    private func loadLanSyncDeletedEntryIDs(
        entryRepository: LocalVaultEntryRepository
    ) throws -> [String] {
        var deletedIDs: [String] = []
        for project in try entryRepository.listProjects() {
            deletedIDs.append(contentsOf: try entryRepository.listDeletedLoginEntries(projectID: project.id).map(\.id))
            deletedIDs.append(contentsOf: try entryRepository.listDeletedNoteEntries(projectID: project.id).map(\.id))
            deletedIDs.append(contentsOf: try entryRepository.listDeletedTotpEntries(projectID: project.id).map(\.id))
        }
        return deletedIDs
    }

    // MARK: 应用合并结果

    @MainActor
    private func applyLanSyncActions(
        _ actions: [LanSyncMergeAction],
        existingMappings: [UUID: String],
        entryRepository: LocalVaultEntryRepository
    ) throws -> AppLanSyncApplyOutcome {
        _ = existingMappings
        var outcome = AppLanSyncApplyOutcome()
        for action in actions {
            do {
                switch action {
                case .create(let item):
                    if case .card = item.content {
                        outcome.failures.append("「\(item.title)」：当前版本暂不支持同步银行卡条目。")
                        continue
                    }
                    let project = try lanSyncEnsureProject(
                        named: item.projectTitle,
                        entryRepository: entryRepository
                    )
                    let localEntryID = try lanSyncCreateEntry(
                        from: item,
                        project: project,
                        entryRepository: entryRepository
                    )
                    outcome.createdLocalEntryIDs[item.syncID] = localEntryID
                    outcome.succeededSyncIDs.insert(item.syncID)
                case .update(let item, let localEntryID):
                    if case .card = item.content {
                        outcome.failures.append("「\(item.title)」：当前版本暂不支持同步银行卡条目。")
                        continue
                    }
                    guard let projectID = try lanSyncProjectID(
                        containing: localEntryID,
                        kind: item.kind,
                        entryRepository: entryRepository
                    ) else {
                        outcome.failures.append("「\(item.title)」：本机找不到对应条目，已跳过。")
                        continue
                    }
                    try lanSyncUpdateEntry(
                        item,
                        localEntryID: localEntryID,
                        projectID: projectID,
                        entryRepository: entryRepository
                    )
                    outcome.succeededSyncIDs.insert(item.syncID)
                case .delete(let syncID, let localEntryID):
                    // 条目可能已经在本地被删除，找不到时视为已经完成，保持幂等。
                    _ = try lanSyncDeleteEntry(
                        localEntryID: localEntryID,
                        entryRepository: entryRepository
                    )
                    outcome.succeededSyncIDs.insert(syncID)
                }
            } catch {
                outcome.failures.append("「\(lanSyncTitle(for: action))」：\(error.localizedDescription)")
            }
        }
        return outcome
    }

    @MainActor
    private func lanSyncCreateEntry(
        from item: LanSyncItem,
        project: LocalVaultProject,
        entryRepository: LocalVaultEntryRepository
    ) throws -> String {
        switch item.content {
        case .login(let content):
            let entry = try entryRepository.createLoginEntry(
                projectID: project.id,
                draft: LocalLoginEntryDraft(
                    title: item.title,
                    username: content.username,
                    password: content.password,
                    url: content.url,
                    notes: content.notes
                )
            )
            try entryRepository.setLoginEntryFavorite(
                projectID: project.id,
                entryID: entry.id,
                favorite: item.favorite
            )
            return entry.id
        case .note(let content):
            let entry = try entryRepository.createNoteEntry(
                projectID: project.id,
                draft: LocalNoteEntryDraft(title: item.title, body: content.body)
            )
            try entryRepository.setNoteEntryFavorite(
                projectID: project.id,
                entryID: entry.id,
                favorite: item.favorite
            )
            return entry.id
        case .totp(let content):
            let entry = try entryRepository.createTotpEntry(
                projectID: project.id,
                draft: LocalTotpEntryDraft(
                    title: item.title,
                    secret: content.secret,
                    issuer: content.issuer,
                    accountName: content.accountName,
                    period: UInt32(clamping: content.period),
                    digits: UInt32(clamping: content.digits),
                    algorithm: content.algorithm,
                    otpType: content.otpType,
                    counter: UInt64(clamping: content.counter)
                )
            )
            try entryRepository.setTotpEntryFavorite(
                projectID: project.id,
                entryID: entry.id,
                favorite: item.favorite
            )
            return entry.id
        case .card:
            throw AppLanSyncError.identityUnavailable
        }
    }

    @MainActor
    private func lanSyncUpdateEntry(
        _ item: LanSyncItem,
        localEntryID: String,
        projectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws {
        switch item.content {
        case .login(let content):
            try entryRepository.updateLoginEntry(
                projectID: projectID,
                entryID: localEntryID,
                draft: LocalLoginEntryDraft(
                    title: item.title,
                    username: content.username,
                    password: content.password,
                    url: content.url,
                    notes: content.notes
                )
            )
            try entryRepository.setLoginEntryFavorite(
                projectID: projectID,
                entryID: localEntryID,
                favorite: item.favorite
            )
        case .note(let content):
            try entryRepository.updateNoteEntry(
                projectID: projectID,
                entryID: localEntryID,
                draft: LocalNoteEntryDraft(title: item.title, body: content.body)
            )
            try entryRepository.setNoteEntryFavorite(
                projectID: projectID,
                entryID: localEntryID,
                favorite: item.favorite
            )
        case .totp(let content):
            try entryRepository.updateTotpEntry(
                projectID: projectID,
                entryID: localEntryID,
                draft: LocalTotpEntryDraft(
                    title: item.title,
                    secret: content.secret,
                    issuer: content.issuer,
                    accountName: content.accountName,
                    period: UInt32(clamping: content.period),
                    digits: UInt32(clamping: content.digits),
                    algorithm: content.algorithm,
                    otpType: content.otpType,
                    counter: UInt64(clamping: content.counter)
                )
            )
            try entryRepository.setTotpEntryFavorite(
                projectID: projectID,
                entryID: localEntryID,
                favorite: item.favorite
            )
        case .card:
            throw AppLanSyncError.identityUnavailable
        }
    }

    // MARK: 定位与刷新

    @MainActor
    private func lanSyncEnsureProject(
        named title: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> LocalVaultProject {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetTitle = trimmed.isEmpty ? "个人" : trimmed
        if let existing = try entryRepository.listProjects().first(where: { $0.title == targetTitle }) {
            return existing
        }
        return try createOrReuseVaultProject(title: targetTitle, entryRepository: entryRepository)
    }

    @MainActor
    private func lanSyncProjectID(
        containing localEntryID: String,
        kind: LanSyncItemKind,
        entryRepository: LocalVaultEntryRepository
    ) throws -> String? {
        for project in try entryRepository.listProjects() {
            let matches: Bool
            switch kind {
            case .login:
                matches = try entryRepository.listLoginEntries(projectID: project.id)
                    .contains(where: { $0.id == localEntryID })
            case .note:
                matches = try entryRepository.listNoteEntries(projectID: project.id)
                    .contains(where: { $0.id == localEntryID })
            case .totp:
                matches = try entryRepository.listTotpEntries(projectID: project.id)
                    .contains(where: { $0.id == localEntryID })
            case .card:
                matches = false
            }
            if matches {
                return project.id
            }
        }
        return nil
    }

    @MainActor
    @discardableResult
    private func lanSyncDeleteEntry(
        localEntryID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> Bool {
        for project in try entryRepository.listProjects() {
            if try entryRepository.listLoginEntries(projectID: project.id)
                .contains(where: { $0.id == localEntryID }) {
                try entryRepository.deleteLoginEntry(projectID: project.id, entryID: localEntryID)
                return true
            }
            if try entryRepository.listNoteEntries(projectID: project.id)
                .contains(where: { $0.id == localEntryID }) {
                try entryRepository.deleteNoteEntry(projectID: project.id, entryID: localEntryID)
                return true
            }
            if try entryRepository.listTotpEntries(projectID: project.id)
                .contains(where: { $0.id == localEntryID }) {
                try entryRepository.deleteTotpEntry(projectID: project.id, entryID: localEntryID)
                return true
            }
        }
        return false
    }

    private func lanSyncTitle(for action: LanSyncMergeAction) -> String {
        switch action {
        case .create(let item):
            item.title.isEmpty ? "未命名条目" : item.title
        case .update(let item, _):
            item.title.isEmpty ? "未命名条目" : item.title
        case .delete(_, _):
            "已删除条目"
        }
    }

    @MainActor
    private func refreshAfterLanSync(
        entryRepository: LocalVaultEntryRepository
    ) throws {
        let projects = try entryRepository.listProjects()
        vaultProjects = projects
        if activeProject == nil {
            activeProject = projects.first
        }
        if let project = activeProject {
            try refreshAllEntryLists(projectID: project.id, entryRepository: entryRepository)
        }
        try? refreshAutoFillEncryptedIndexIfConfigured()
    }
}
