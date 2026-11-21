//
//  AppSecurityInsightsSupport.swift
//  Monica
//
//  安全分析（issue #56）的会话侧支撑：
//  - 把登录条目映射成 MonicaCore 的只读审计输入（不外发、不落盘、不改条目）；
//  - 手动“疑似已泄露”标记（纯本地，不做在线查询）；
//  - 每日趋势点与状态文件读写；
//  - 仪表盘 → 条目详情的跳转。
//

import Foundation
import MonicaCore
import MonicaStorage

/// 安全分析状态的落盘位置：`Application Support/SecurityInsights`。
enum AppSecurityInsightsStoreLocation {
    static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("SecurityInsights", isDirectory: true)
    }

    /// 生产环境使用文件存储；读写失败时上层只拿到 `.empty`，不会阻断解锁流程。
    static func productionStore() -> any SecurityInsightPersisting {
        FileSecurityInsightStore(directoryURL: defaultDirectoryURL())
    }
}

@MainActor
extension AppSessionModel {
    // MARK: - 审计输入

    /// 条目 ID → 密码修订标识。修订只由密码历史的条数与最新变更时间派生，不含任何密码材料。
    var securityInsightRevisionByEntryID: [String: String] {
        var revisions: [String: String] = [:]
        revisions.reserveCapacity(loginEntries.count)
        for entry in loginEntries {
            revisions[entry.id] = securityInsightRevision(forLoginEntry: entry)
        }
        return revisions
    }

    func securityInsightRevision(forLoginEntry entry: LocalLoginEntry) -> String {
        // 密码历史的 `first` 就是当前密码被设置的时刻；没有历史 = 本机不知道当前密码多旧。
        SecurityInsightRevision.token(
            historyCount: entry.passwordHistory.count,
            latestChangeAt: entry.passwordHistory.first?.changedAt
        )
    }

    private var securityInsightAuthenticatorIdentities: [SecurityInsightTwoFactorMatcher.AuthenticatorIdentity] {
        totpEntries.map { entry in
            SecurityInsightTwoFactorMatcher.AuthenticatorIdentity(
                accountName: entry.accountName,
                issuer: entry.issuer,
                title: entry.title
            )
        }
    }

    /// 只读输入快照：条目本身不会被修改，密码只在内存里参与本地计算。
    var securityInsightSubjects: [SecurityInsightSubject] {
        let authenticators = securityInsightAuthenticatorIdentities
        let revisions = securityInsightRevisionByEntryID
        let ignoredDuplicateIDs = ignoredDuplicateLoginEntryIDs
        return loginEntries.map { entry in
            let revision = revisions[entry.id] ?? ""
            return SecurityInsightSubject(
                id: entry.id,
                title: entry.title,
                username: entry.username,
                url: entry.url,
                password: entry.password,
                passwordChangedAt: entry.passwordHistory.first?.changedAt,
                hasLinkedAuthenticator: !authenticators.isEmpty
                    && SecurityInsightTwoFactorMatcher.isLinked(
                        username: entry.username,
                        urls: entry.effectiveURLs,
                        title: entry.title,
                        authenticators: authenticators
                    ),
                isMarkedBreached: !revision.isEmpty
                    && securityInsightState.isMarkedBreached(entryID: entry.id, revision: revision),
                isIgnoredForDuplicateGrouping: ignoredDuplicateIDs.contains(entry.id)
            )
        }
    }

    /// 每次读取都重新计算，条目一改，安全中心与仪表盘看到的就是新数字。
    var securityInsightReport: SecurityInsightReport {
        makeSecurityInsightReport(now: securityInsightNow())
    }

    func makeSecurityInsightReport(now: Date) -> SecurityInsightReport {
        SecurityInsightAnalyzer.analyze(subjects: securityInsightSubjects, now: now)
    }

    // MARK: - 锁定态

    /// 锁定态固定返回 `.locked`：不携带分数、条目数量、命中列表或年龄分布。
    var securityInsightDashboardSnapshot: SecurityInsightDashboardSnapshot {
        guard vaultState == .unlocked else {
            return .locked
        }
        return .unlocked(securityInsightReport)
    }

    var securityInsightTrend: SecurityAuditTrend {
        guard vaultState == .unlocked else {
            return SecurityAuditTrend()
        }
        return securityInsightState.trend
    }

    /// 当前仍然有效的泄露标记数量（密码已改、条目已删的标记不算）。
    var securityInsightBreachMarkCount: Int {
        let revisions = securityInsightRevisionByEntryID
        return securityInsightState.breachMarks.reduce(into: 0) { count, mark in
            if revisions[mark.key] == mark.value {
                count += 1
            }
        }
    }

    // MARK: - 状态载入与落盘

    /// 载入当前 Vault 的安全分析状态，并记录当天趋势点（每天最多一个）。
    func refreshSecurityInsightState() async {
        guard let vaultID = activeVaultHistoryScope else {
            securityInsightLoadedVaultID = nil
            return
        }
        if securityInsightLoadedVaultID != vaultID {
            let loaded = (try? await securityInsightStore.load(vaultID: vaultID)) ?? .empty
            securityInsightState = loaded
            securityInsightLoadedVaultID = vaultID
        }

        var updated = securityInsightState
        updated.pruneBreachMarks(keeping: securityInsightRevisionByEntryID)
        let report = makeSecurityInsightReport(now: securityInsightNow())
        if report.totalItemCount > 0 {
            updated.recordAudit(report, now: securityInsightNow())
        }
        guard updated != securityInsightState else {
            return
        }
        securityInsightState = updated
        persistSecurityInsightState()
    }

    /// 手动标记 / 取消“疑似已泄露”。只写本地标记，不联网、不改条目内容。
    func setSecurityBreachMark(_ marked: Bool, forLoginEntryID entryID: String) {
        guard let entry = loginEntries.first(where: { $0.id == entryID }) else {
            return
        }
        let revision = securityInsightRevision(forLoginEntry: entry)
        securityInsightState.setBreachMark(marked, entryID: entryID, revision: revision)
        persistSecurityInsightState()
    }

    func isSecurityBreachMarked(entryID: String) -> Bool {
        guard let entry = loginEntries.first(where: { $0.id == entryID }) else {
            return false
        }
        return securityInsightState.isMarkedBreached(
            entryID: entryID,
            revision: securityInsightRevision(forLoginEntry: entry)
        )
    }

    private func persistSecurityInsightState() {
        guard let vaultID = activeVaultHistoryScope else {
            return
        }
        let state = securityInsightState
        let store = securityInsightStore
        securityInsightSaveTask?.cancel()
        securityInsightSaveTask = Task {
            try? await store.save(state, vaultID: vaultID)
        }
    }

    // MARK: - 界面派生

    /// 0–100 分对应的分档（阈值定义在 MonicaCore，可被单测复核）。
    func securityInsightScoreBand(for score: Int) -> SecurityInsightScoreBand {
        SecurityInsightScoreBand.band(for: score)
    }

    /// 从仪表盘跳到条目详情：切到密码页并弹出只读详情，绝不在这里改条目。
    func presentSecurityInsightFinding(_ finding: SecurityInsightFinding) {
        selectedTab = .passwords
        passwordModule = .login
        presentDetail(kind: .login, entryID: finding.id)
    }
}
