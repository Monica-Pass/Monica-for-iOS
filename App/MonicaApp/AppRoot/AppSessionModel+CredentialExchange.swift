import AuthenticationServices
import Foundation
import MonicaCore
import MonicaStorage

// slice C3: CredentialExchange 域（iOS 26 凭据交换导入 / 导出、回滚与提示文案），从 AppSessionModel.swift 逐字搬移。
extension AppSessionModel {
    /// 系统完成导入握手后通过 NSUserActivity 调用；令牌只保留在内存里。
    func handleCredentialExchangeActivity(_ activity: NSUserActivity) {
        guard #available(iOS 26.0, *) else { return }
        guard activity.activityType == ASCredentialExchangeActivity else { return }
        guard let token = activity.userInfo?[ASCredentialImportToken] as? UUID else {
            credentialExchange.importError = "系统没有提供可用的凭据导入令牌，本地保险库未做改动。"
            return
        }
        recordUserActivity()
        credentialExchange.importError = nil
        guard vaultState == .unlocked else {
            credentialExchange.pendingImportToken = token
            return
        }
        Task { await fetchCredentialExchangeImport(token: token) }
    }

    /// 解锁完成后继续处理系统已经交给 App 的导入令牌。
    func continuePendingCredentialExchangeImportIfAvailable() {
        guard #available(iOS 26.0, *) else { return }
        guard vaultState == .unlocked, let token = credentialExchange.pendingImportToken else { return }
        credentialExchange.pendingImportToken = nil
        Task { await fetchCredentialExchangeImport(token: token) }
    }

    func fetchCredentialExchangeImport(token: UUID) async {
        guard #available(iOS 26.0, *), vaultState == .unlocked else {
            credentialExchange.pendingImportToken = token
            return
        }
        if credentialExchange.isFetchingImport {
            credentialExchange.pendingImportToken = token
            return
        }
        credentialExchange.isFetchingImport = true
        credentialExchange.importError = nil
        credentialExchange.importIssues = []
        credentialExchange.importIsFinished = false
        credentialExchange.importMessage = nil
        entryOperationState = .running
        defer { credentialExchange.isFetchingImport = false }

        do {
            let data = try await ASCredentialImportManager().importCredentials(token: token)
            guard data.formatVersion.rawValue == CredentialExchangeFormat.supportedVersion else {
                credentialExchange.importError = "不支持的凭据交换版本 \(data.formatVersion.rawValue)。本地保险库未做改动。"
                entryOperationState = .failed("不支持的凭据交换版本")
                return
            }
            let sourcePlan = CredentialExchangeCodec.importPlan(
                accounts: AppCredentialExchangeBridge.accounts(from: data),
                existingLoginEntries: loginEntries,
                existingTOTPEntries: totpEntries,
                existingPasskeyEntries: passkeyEntries
            )
            // 通行密钥在写入钥匙串之前先做一次加密层预检：只校验和派生公钥，不产生任何副作用。
            var issues = sourcePlan.passkeyIssues.map(AppCredentialExchangeIssue.init(storageIssue:))
            var preparedPasskeys: [PasskeyExchangeImport] = []
            for item in sourcePlan.passkeys {
                do {
                    preparedPasskeys.append(try passkeyExchangeService.prepareImport(
                        PasskeyExchangeCredential(item.credential),
                        title: item.title,
                        notes: ""
                    ))
                } catch {
                    issues.append(AppCredentialExchangeIssue(
                        error: error,
                        title: item.title,
                        relyingPartyIdentifier: item.credential.relyingPartyIdentifier
                    ))
                }
            }
            let plan = adjustedCredentialExchangeImportPlan(
                sourcePlan,
                preparedPasskeys: preparedPasskeys
            )
            // 全部条目都不可用时也打开预览，让用户看到逐条降级原因，而不是只弹一条错误。
            guard !plan.isEmpty || !issues.isEmpty else {
                credentialExchange.importError = emptyCredentialExchangeMessage(plan)
                entryOperationState = .failed("没有可导入的凭据")
                return
            }
            credentialExchange.importIssues = issues
            credentialExchange.importPreview = AppCredentialExchangeImportPreview(
                plan: plan,
                passkeys: preparedPasskeys,
                exporterDisplayName: data.exporterDisplayName,
                formatVersion: data.formatVersion.rawValue
            )
            entryOperationState = .idle
        } catch {
            credentialExchange.importError = credentialExchangeFailureMessage(
                prefix: "无法读取系统提供的凭据",
                error: error
            )
            entryOperationState = .failed("系统凭据读取失败")
        }
    }

    /// 预检失败的通行密钥从可导入列表里剔除，并计入无效数据，避免确认时整批失败。
    func adjustedCredentialExchangeImportPlan(
        _ plan: CredentialExchangeImportPlan,
        preparedPasskeys: [PasskeyExchangeImport]
    ) -> CredentialExchangeImportPlan {
        let validCredentialIDs = Set(preparedPasskeys.map(\.credentialID))
        let acceptedItems = plan.passkeys.filter { validCredentialIDs.contains($0.credential.credentialID) }
        guard acceptedItems.count != plan.passkeys.count else { return plan }
        return CredentialExchangeImportPlan(
            drafts: plan.drafts,
            passkeys: acceptedItems,
            passkeyIssues: plan.passkeyIssues,
            sourceAccountCount: plan.sourceAccountCount,
            sourceItemCount: plan.sourceItemCount,
            passwordCount: plan.passwordCount,
            totpCount: plan.totpCount,
            skippedDuplicateCount: plan.skippedDuplicateCount,
            unsupportedCredentialCount: plan.unsupportedCredentialCount,
            invalidCredentialCount: plan.invalidCredentialCount
                + (plan.passkeys.count - acceptedItems.count)
        )
    }

    func confirmCredentialExchangeImport() throws {
        recordUserActivity()
        guard let preview = credentialExchange.importPreview else {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        guard let entryRepository = activeEntryRepository else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }

        credentialExchange.isImporting = true
        credentialExchange.importError = nil
        entryOperationState = .running
        defer { credentialExchange.isImporting = false }

        var projectID: String?
        var created: [(VaultCSVItemDraft, String)] = []
        var committedPasskeys: [PasskeyExchangeImport] = []
        var issues = credentialExchange.importIssues
        var importedCount = 0
        do {
            let project = try ensureActiveProject(projectTitle: "凭据交换", entryRepository: entryRepository)
            projectID = project.id
            for item in preview.plan.drafts {
                if let entryID = try createCSVImportedItem(
                    item,
                    projectID: project.id,
                    entryRepository: entryRepository
                ) {
                    created.append((item, entryID))
                    importedCount += 1
                }
            }
            // 通行密钥逐条写入：单条钥匙串或落库失败只记录问题并继续，最后统一汇总。
            for prepared in preview.passkeys {
                do {
                    try passkeyExchangeService.commitImport(prepared)
                    committedPasskeys.append(prepared)
                    let metadata = prepared.metadata
                    let draft = LocalPasskeyEntryDraft(
                        title: metadata.title,
                        relyingPartyID: metadata.relyingPartyID,
                        username: metadata.username,
                        userHandle: metadata.userHandle,
                        credentialID: metadata.credentialID,
                        publicKeyCOSE: metadata.publicKeyCOSE,
                        privateKeyReference: metadata.privateKeyReference,
                        notes: metadata.notes
                    )
                    if let entryID = try createCSVImportedItem(
                        .passkey(draft),
                        projectID: project.id,
                        entryRepository: entryRepository
                    ) {
                        created.append((.passkey(draft), entryID))
                        importedCount += 1
                    } else {
                        try? passkeyExchangeService.rollbackImport(prepared)
                        issues.append(AppCredentialExchangeIssue(
                            title: metadata.title,
                            relyingPartyIdentifier: metadata.relyingPartyID,
                            reason: .duplicate
                        ))
                    }
                } catch {
                    try? passkeyExchangeService.rollbackImport(prepared)
                    issues.append(AppCredentialExchangeIssue(
                        error: error,
                        title: prepared.metadata.title,
                        relyingPartyIdentifier: prepared.metadata.relyingPartyID
                    ))
                }
            }
            try refreshAllEntryLists(projectID: project.id, entryRepository: entryRepository)
            try refreshAutoFillEncryptedIndexIfConfigured()
            credentialExchange.importIssues = issues
            credentialExchange.importIsFinished = true
            credentialExchange.importMessage = importedCredentialMessage(
                importedCount: importedCount,
                issueCount: issues.count
            )
            credentialExchange.importError = nil
            if issues.isEmpty {
                credentialExchange.importPreview = nil
            }
            entryOperationState = .succeeded("凭据已导入 \(importedCount) 项")
        } catch {
            rollbackCredentialExchangeImportPasskeys(committedPasskeys)
            let rollbackIncomplete = rollbackCredentialExchangeImport(
                created,
                projectID: projectID,
                entryRepository: entryRepository
            )
            credentialExchange.importError = rollbackIncomplete
                ? "导入失败，且部分条目未能回滚，请检查「凭据交换」项目：\(error.localizedDescription)"
                : "导入失败，已回滚本次改动：\(error.localizedDescription)"
            entryOperationState = .failed("凭据导入失败")
            throw error
        }
    }

    func rollbackCredentialExchangeImportPasskeys(_ prepared: [PasskeyExchangeImport]) {
        for item in prepared.reversed() {
            try? passkeyExchangeService.rollbackImport(item)
        }
    }

    func importedCredentialMessage(importedCount: Int, issueCount: Int) -> String {
        if issueCount == 0 {
            return String(localized: "已导入 \(importedCount) 项。")
        }
        return String(localized: "已导入 \(importedCount) 项，另有 \(issueCount) 项已跳过。")
    }

    func cancelCredentialExchangeImport() {
        credentialExchange.importPreview = nil
        credentialExchange.importError = nil
        credentialExchange.importIssues = []
        credentialExchange.importIsFinished = false
        credentialExchange.importMessage = nil
        credentialExchange.isImporting = false
        credentialExchange.pendingImportToken = nil
    }

    @discardableResult
    func rollbackCredentialExchangeImport(
        _ created: [(VaultCSVItemDraft, String)],
        projectID: String?,
        entryRepository: LocalVaultEntryRepository
    ) -> Bool {
        guard let projectID else {
            return !created.isEmpty
        }
        var incomplete = false
        for (item, entryID) in created.reversed() {
            do {
                try deleteCSVImportedItem(
                    item,
                    entryID: entryID,
                    projectID: projectID,
                    entryRepository: entryRepository
                )
            } catch {
                incomplete = true
            }
        }
        try? refreshAllEntryLists(projectID: projectID, entryRepository: entryRepository)
        try? refreshAutoFillEncryptedIndexIfConfigured()
        return incomplete
    }

    func emptyCredentialExchangeMessage(_ plan: CredentialExchangeImportPlan) -> String {
        if plan.skippedDuplicateCount > 0,
           plan.unsupportedCredentialCount == 0,
           plan.invalidCredentialCount == 0 {
            return "这些凭据已经存在于本地保险库，没有新增任何条目。"
        }
        if plan.unsupportedCredentialCount > 0,
           plan.skippedDuplicateCount == 0,
           plan.invalidCredentialCount == 0 {
            return "系统提供的条目暂不支持迁移，本地保险库未做改动。"
        }
        return "没有找到可导入的密码、TOTP 或通行密钥，本地保险库未做改动。"
    }

    /// 系统错误只暴露 domain/code，避免把凭据内容带进日志或界面。
    func credentialExchangeFailureMessage(prefix: String, error: Error) -> String {
        let nsError = error as NSError
        return "\(prefix)（\(nsError.domain) \(nsError.code)）。本地保险库未做改动。"
    }

    @discardableResult
    func prepareCredentialExchangeExport() -> Bool {
        guard #available(iOS 26.0, *) else {
            credentialExchange.exportError = "凭据交换需要 iOS 26 或更新版本。"
            return false
        }
        guard vaultState == .unlocked else {
            credentialExchange.exportError = "请先解锁保险库再导出。"
            return false
        }
        credentialExchange.exportError = nil
        credentialExchange.exportMessage = nil
        credentialExchange.exportIsFinished = false

        // 导出前只检查通行密钥元数据（不读私钥），明显无效的条目先列成问题。
        let candidates = AppCredentialExchangePasskeys.exportCandidates(from: passkeyEntries)
        let plan = CredentialExchangeCodec.exportPlan(
            loginEntries: loginEntries,
            totpEntries: totpEntries
        )
        credentialExchange.exportIssues = candidates.issues
        guard !plan.isEmpty || !candidates.entries.isEmpty else {
            credentialExchange.exportPasskeyCount = 0
            let invalidCount = plan.skippedCount + candidates.issues.count
            credentialExchange.exportError = invalidCount > 0
                ? String(localized: "没有可导出的密码、TOTP 或通行密钥；另有 \(invalidCount) 条条目无效。")
                : "没有可导出的密码、TOTP 或通行密钥。"
            return false
        }
        credentialExchange.exportPlan = plan
        credentialExchange.exportPasskeyCount = candidates.entries.count
        return true
    }

    @discardableResult
    func performCredentialExchangeExport() async -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        guard credentialExchange.exportPlan != nil else { return false }
        guard let anchor = AppCredentialExchangePresenter.keyWindow() else {
            credentialExchange.exportError = "找不到可用于系统导出面板的窗口。"
            return false
        }

        credentialExchange.isExporting = true
        credentialExchange.exportError = nil
        defer { credentialExchange.isExporting = false }

        // 先做纯元数据筛选，避免把密码/TOTP 导出也拖进设备确认（无密码设备会直接失败）。
        let candidates = AppCredentialExchangePasskeys.exportCandidates(from: passkeyEntries)
        if !candidates.entries.isEmpty {
            // 读私钥之前先要求生物识别/设备密码确认；被拒绝时完全不接触钥匙串。
            do {
                try await deviceOwnerAuthenticator.authenticate(
                    reason: String(localized: "导出通行密钥前需要确认你的身份")
                )
            } catch {
                credentialExchange.exportError = "未通过设备确认，未导出任何数据。"
                entryOperationState = .failed("设备确认未通过")
                return false
            }
        }

        var issues = candidates.issues
        var passkeyExports: [CredentialExchangePasskeyExport] = []
        for entry in candidates.entries {
            guard let credentialID = Data(base64Encoded: entry.credentialID),
                  let userHandle = Data(base64Encoded: entry.userHandle) else {
                issues.append(AppCredentialExchangeIssue(
                    title: entry.title,
                    relyingPartyIdentifier: entry.relyingPartyID,
                    reason: .invalidData
                ))
                continue
            }
            do {
                let credential = try passkeyExchangeService.exportCredential(
                    credentialID: credentialID,
                    relyingPartyID: entry.relyingPartyID,
                    userName: entry.username,
                    userHandle: userHandle
                )
                passkeyExports.append(CredentialExchangePasskeyExport(
                    title: entry.title,
                    favorite: entry.favorite,
                    credential: CredentialExchangePasskey(credential)
                ))
            } catch {
                issues.append(AppCredentialExchangeIssue(
                    error: error,
                    title: entry.title,
                    relyingPartyIdentifier: entry.relyingPartyID
                ))
            }
        }
        credentialExchange.exportIssues = issues

        let plan = CredentialExchangeCodec.exportPlan(
            loginEntries: loginEntries,
            totpEntries: totpEntries,
            passkeyExports: passkeyExports
        )
        guard !plan.isEmpty else {
            credentialExchange.exportError = "没有可导出的条目。"
            credentialExchange.exportIsFinished = true
            entryOperationState = .failed("没有可导出的条目")
            return false
        }

        do {
            let manager = ASCredentialExportManager(presentationAnchor: anchor)
            let options = try await manager.requestExport(for: nil)
            guard options.formatVersion.rawValue == CredentialExchangeFormat.supportedVersion else {
                credentialExchange.exportError = "接收方请求了不支持的版本 \(options.formatVersion.rawValue)。"
                return false
            }
            try await manager.exportCredentials(AppCredentialExchangeBridge.exportedData(from: plan))
            credentialExchange.exportMessage = "已导出 \(plan.passwordCount) 条密码、\(plan.totpCount) 条 TOTP、\(plan.passkeyCount) 条通行密钥。"
            credentialExchange.exportIsFinished = true
            if issues.isEmpty {
                credentialExchange.exportPlan = nil
            }
            entryOperationState = .idle
            return issues.isEmpty
        } catch {
            credentialExchange.exportError = credentialExchangeFailureMessage(
                prefix: "导出没有完成",
                error: error
            )
            return false
        }
    }

    func cancelCredentialExchangeExport() {
        credentialExchange.exportPlan = nil
        credentialExchange.exportError = nil
        credentialExchange.exportMessage = nil
        credentialExchange.exportPasskeyCount = 0
        credentialExchange.exportIssues = []
        credentialExchange.exportIsFinished = false
        credentialExchange.isExporting = false
    }
}
