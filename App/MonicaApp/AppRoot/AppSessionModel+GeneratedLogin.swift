import Foundation
import MonicaCore
import MonicaStorage

/// 生成器保存登录项时的参数校验错误。
enum AppGeneratedLoginSaveError: LocalizedError, Equatable {
    case missingTitle
    case missingPassword
    case vaultLocked

    var errorDescription: String? {
        switch self {
        case .missingTitle:
            return String(localized: "请填写登录项标题。")
        case .missingPassword:
            return String(localized: "密码不能为空。")
        case .vaultLocked:
            return String(localized: "请先解锁保险库再保存登录项。")
        }
    }
}

extension AppSessionModel {
    /// 把生成器里的结果保存为登录项（#39）。
    ///
    /// 与 `createLoginEntry(projectTitle:)` 使用同一条仓储写入、自动填充索引刷新与操作时间线，
    /// 但显式接收生成器的值，避免覆盖「新建登录」表单里尚未提交的输入。
    @discardableResult
    func saveGeneratedLogin(
        title: String,
        username: String,
        password: String,
        url: String,
        notes: String = "",
        projectTitle: String? = nil
    ) throws -> LocalLoginEntry {
        recordUserActivity()
        entryOperationState = .running

        do {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else {
                throw AppGeneratedLoginSaveError.missingTitle
            }
            guard !password.isEmpty else {
                throw AppGeneratedLoginSaveError.missingPassword
            }
            guard vaultState == .unlocked, let entryRepository = activeEntryRepository else {
                throw AppGeneratedLoginSaveError.vaultLocked
            }

            let resolvedProjectTitle = projectTitle ?? activeVaultName ?? String(localized: "个人")
            let project: LocalVaultProject
            if let activeProject {
                project = activeProject
            } else {
                project = try entryRepository.createProject(title: resolvedProjectTitle)
                activeProject = project
            }

            let entry = try entryRepository.createLoginEntry(
                projectID: project.id,
                draft: LocalLoginEntryDraft(
                    title: trimmedTitle,
                    username: username,
                    password: password,
                    url: url,
                    notes: notes,
                    urls: url.isEmpty ? [] : [url]
                )
            )

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
            return entry
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }
}
