//
//  AppSecurityCenterDashboardView.swift
//  Monica
//
//  安全分析仪表盘（issue #56）。
//
//  设计约束：
//  - 全部指标在本机离线计算，页面不发起任何网络请求；
//  - 「疑似泄露」只能由用户手动标记，不假装存在在线泄露查询；
//  - 页面只读：给出复制账号与跳转条目两种修复入口，绝不在这里改条目；
//  - 锁定态只显示一条解锁提示，不暴露条目数量、分数或命中。
//

import MonicaCore
import MonicaStorage
import SwiftUI

struct AppSecurityCenterDashboardView: View {
    let session: AppSessionModel

    @State private var selectedIssue: SecurityInsightIssue?
    @State private var isBreachMarkListExpanded = false
    @State private var copyFeedbackMessage: String?

    private var snapshot: SecurityInsightDashboardSnapshot {
        session.securityInsightDashboardSnapshot
    }

    private var report: SecurityInsightReport? {
        session.vaultState == .unlocked ? snapshot.report : nil
    }

    var body: some View {
        AndroidParityScreen {
            if let report {
                if let copyFeedbackMessage {
                    feedbackCard(copyFeedbackMessage)
                }
                scoreCard(report)
                issueFilterSection(report)
                findingsSection(report)
                ageDistributionSection(report)
                trendSection
                breachMarkSection(report)
                offlineNoticeCard
            } else {
                lockedCard
            }
        }
        .navigationTitle(String(localized: "安全分析"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await session.refreshSecurityInsightState()
        }
    }

    // MARK: - 评分

    private func scoreCard(_ report: SecurityInsightReport) -> some View {
        let band = session.securityInsightScoreBand(for: report.score)
        return AndroidParitySection(title: String(localized: "安全评分")) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(report.score)")
                        .font(AndroidParityTypography.displayTitle())
                        .foregroundStyle(scoreColor(for: band))
                    Text("/ \(SecurityInsightScoring.maximumScore)")
                        .font(.subheadline)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                    Spacer()
                    Text(scoreBandTitle(band))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(scoreColor(for: band))
                }
                Text(scoreBandDetail(band))
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                AndroidParityDivider()
                AndroidParityInfoRow(
                    title: String(localized: "登录条目"),
                    value: itemCountLabel(report.totalItemCount)
                )
                AndroidParityInfoRow(
                    title: String(localized: "命中条目"),
                    value: itemCountLabel(report.findingItemCount)
                )
                if !penaltyRows(report).isEmpty {
                    AndroidParityDivider()
                    Text("扣分明细")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                    ForEach(penaltyRows(report), id: \.issue.id) { penalty in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(issueTitle(penalty.issue))
                                .font(.footnote)
                            Spacer()
                            Text("−\(penalty.points)")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(AndroidParityPalette.textSecondary)
                        }
                    }
                }
            }
        }
    }

    private func penaltyRows(_ report: SecurityInsightReport) -> [SecurityInsightPenalty] {
        report.penalties.filter { $0.points > 0 }
    }

    // MARK: - 分类筛选

    private func issueFilterSection(_ report: SecurityInsightReport) -> some View {
        AndroidParitySection(title: String(localized: "按问题筛选")) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        filterChip(
                            title: String(localized: "全部"),
                            count: report.findings.count,
                            issue: nil
                        )
                        ForEach(SecurityInsightIssue.allCases) { issue in
                            filterChip(
                                title: issueTitle(issue),
                                count: report.count(for: issue),
                                issue: issue
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                Text("选一个分类即可只看对应条目；分数与统计始终包含全部问题。")
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }
    }

    private func filterChip(title: String, count: Int, issue: SecurityInsightIssue?) -> some View {
        let isSelected = selectedIssue == issue
        return Button {
            selectedIssue = issue
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                Text("\(count)")
                    .font(.footnote)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .foregroundStyle(isSelected ? AndroidParityPalette.onPrimary : AndroidParityPalette.textPrimary)
            .background(
                isSelected ? AndroidParityPalette.primary : AndroidParityPalette.surface,
                in: Capsule(style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - 命中条目

    @ViewBuilder
    private func findingsSection(_ report: SecurityInsightReport) -> some View {
        let findings = report.findings(matching: selectedIssue)
        AndroidParitySection(title: String(localized: "命中条目")) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                if findings.isEmpty {
                    Text(report.isEmpty
                        ? "仓库里还没有登录条目。"
                        : "当前筛选下没有需要处理的条目。")
                        .font(.footnote)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                } else {
                    ForEach(findings) { finding in
                        findingRow(finding)
                        if finding.id != findings.last?.id {
                            AndroidParityDivider()
                        }
                    }
                }
            }
        }
    }

    private func findingRow(_ finding: SecurityInsightFinding) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(finding.title.isEmpty ? entryFallbackTitle : finding.title)
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 6) {
                ForEach(finding.issues) { issue in
                    Text(issueTitle(issue))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(AndroidParityPalette.secondaryContainer, in: Capsule(style: .continuous))
                }
            }
            if let host = finding.host {
                Text(host)
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
            if let ageDays = finding.ageDays {
                Text(ageDaysLabel(ageDays))
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
            HStack(spacing: 8) {
                Button {
                    session.presentSecurityInsightFinding(finding)
                } label: {
                    Label("查看条目", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                if !finding.username.isEmpty {
                    Button {
                        copy(username: finding.username)
                    } label: {
                        Label("复制用户名", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 年龄分布

    private func ageDistributionSection(_ report: SecurityInsightReport) -> some View {
        AndroidParitySection(title: String(localized: "密码年龄分布")) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                let total = max(1, report.totalItemCount)
                ForEach(SecurityPasswordAgeBucket.allCases) { bucket in
                    let count = report.ageCount(for: bucket)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(ageBucketTitle(bucket))
                                .font(.footnote)
                            Spacer()
                            Text(itemCountLabel(count))
                                .font(.footnote)
                                .foregroundStyle(AndroidParityPalette.textSecondary)
                        }
                        ProgressView(value: Double(count), total: Double(total))
                            .tint(bucket == .atLeast365Days ? .orange : AndroidParityPalette.primary)
                    }
                }
                Text("年龄来自密码历史里最近一次更换时间；本机没有记录的条目归入“未知”。")
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }
    }

    // MARK: - 趋势

    @ViewBuilder
    private var trendSection: some View {
        let trend = session.securityInsightTrend
        AndroidParitySection(title: String(localized: "总量趋势")) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                if let latest = trend.latest {
                    AndroidParityInfoRow(title: String(localized: "最近一次"), value: latest.dayKey)
                    AndroidParityInfoRow(
                        title: String(localized: "分数"),
                        value: "\(latest.score) / \(SecurityInsightScoring.maximumScore)"
                    )
                    AndroidParityInfoRow(
                        title: String(localized: "条目总量"),
                        value: itemCountLabel(latest.totalItemCount)
                    )
                    if let scoreDelta = trend.scoreDeltaFromEarliest,
                       let itemDelta = trend.totalItemDeltaFromEarliest {
                        Text(trendDeltaText(scoreDelta: scoreDelta, itemDelta: itemDelta, dayCount: trend.points.count))
                            .font(.footnote)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }
                    AndroidParityDivider()
                    ForEach(trend.points.suffix(7).reversed()) { point in
                        HStack {
                            Text(point.dayKey)
                                .font(.footnote)
                                .monospacedDigit()
                            Spacer()
                            Text("\(point.score)")
                                .font(.footnote.weight(.semibold))
                                .monospacedDigit()
                            Text(itemCountLabel(point.totalItemCount))
                                .font(.footnote)
                                .foregroundStyle(AndroidParityPalette.textSecondary)
                        }
                    }
                } else {
                    Text("还没有趋势数据。保持解锁并打开本页，每天会记录一个聚合快照（不含任何条目内容）。")
                        .font(.footnote)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
                Button {
                    Task {
                        await session.refreshSecurityInsightState()
                    }
                } label: {
                    Label("记录今天的快照", systemImage: "calendar.badge.clock")
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
            }
        }
    }

    private func trendDeltaText(scoreDelta: Int, itemDelta: Int, dayCount: Int) -> String {
        let scoreSign = scoreDelta >= 0 ? "+" : ""
        let itemSign = itemDelta >= 0 ? "+" : ""
        return String(localized: "与 \(dayCount) 天前的记录相比：分数 \(scoreSign)\(scoreDelta)，条目 \(itemSign)\(itemDelta)。")
    }

    // MARK: - 泄露标记

    @ViewBuilder
    private func breachMarkSection(_ report: SecurityInsightReport) -> some View {
        let markedCount = session.securityInsightBreachMarkCount
        AndroidParitySection(title: String(localized: "泄露标记")) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                Text("“疑似已泄露”完全由你手动标记，本 App 不做在线泄露查询，也不会把密码发给任何服务。")
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                AndroidParityInfoRow(
                    title: String(localized: "已标记"),
                    value: markedCount == 0 ? String(localized: "未标记") : itemCountLabel(markedCount)
                )
                if report.count(for: .flaggedBreach) > 0 {
                    Text("已标记条目会排在命中列表最前面，优先处理。")
                        .font(.footnote)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
                Button {
                    isBreachMarkListExpanded.toggle()
                } label: {
                    Label(
                        isBreachMarkListExpanded ? "收起条目列表" : "选择要标记的条目",
                        systemImage: isBreachMarkListExpanded ? "chevron.up" : "chevron.down"
                    )
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                if isBreachMarkListExpanded {
                    if session.loginEntries.isEmpty {
                        Text("仓库里还没有登录条目。")
                            .font(.footnote)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    } else {
                        ForEach(session.loginEntries) { entry in
                            breachMarkRow(entry)
                            if entry.id != session.loginEntries.last?.id {
                                AndroidParityDivider()
                            }
                        }
                    }
                }
            }
        }
    }

    private func breachMarkRow(_ entry: LocalLoginEntry) -> some View {
        let isMarked = session.isSecurityBreachMarked(entryID: entry.id)
        return Button {
            session.setSecurityBreachMark(!isMarked, forLoginEntryID: entry.id)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isMarked ? "checkmark.circle.fill" : "circle")
                    .font(AndroidParityTypography.smallIcon())
                    .foregroundStyle(isMarked ? AndroidParityPalette.primary : AndroidParityPalette.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title.isEmpty ? entryFallbackTitle : entry.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textPrimary)
                    if !entry.username.isEmpty {
                        Text(entry.username)
                            .font(.caption)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }
                }
                Spacer()
                Text(isMarked ? String(localized: "已标记") : String(localized: "标记"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isMarked ? .isSelected : [])
    }

    // MARK: - 说明与锁定态

    private var offlineNoticeCard: some View {
        AndroidParitySection(title: String(localized: "计算方式")) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                Text("评分 = 100 − 各分类扣分之和，每类扣分 = min(命中数 × 权重, 上限)。全部分析只在本机内存中完成。")
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                AndroidParityInfoRow(
                    title: String(localized: "弱密码权重"),
                    value: scoreWeightLabel(.weakPassword)
                )
                AndroidParityInfoRow(
                    title: String(localized: "复用密码权重"),
                    value: scoreWeightLabel(.reusedPassword)
                )
                AndroidParityInfoRow(
                    title: String(localized: "未开启 2FA 权重"),
                    value: scoreWeightLabel(.missingTwoFactor)
                )
                AndroidParityInfoRow(
                    title: String(localized: "重复条目权重"),
                    value: scoreWeightLabel(.duplicateEntry)
                )
                AndroidParityInfoRow(
                    title: String(localized: "长期未改权重"),
                    value: scoreWeightLabel(.stalePassword)
                )
                AndroidParityInfoRow(
                    title: String(localized: "泄露标记权重"),
                    value: scoreWeightLabel(.flaggedBreach)
                )
            }
        }
    }

    private var lockedCard: some View {
        AndroidParitySection(title: String(localized: "安全分析")) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                Label("需先解锁", systemImage: "lock.shield")
                    .font(.subheadline.weight(.semibold))
                Text("解锁后会在本机完成统计。锁定状态下本页不显示任何条目信息、分数或命中数量。")
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }
    }

    private func feedbackCard(_ message: String) -> some View {
        AndroidParityCard(fill: AndroidParityPalette.secondaryContainer) {
            Label(message, systemImage: "checkmark.circle")
                .font(.footnote)
        }
    }

    // MARK: - 文案与格式

    private var entryFallbackTitle: String {
        String(localized: "未命名条目")
    }

    private func itemCountLabel(_ count: Int) -> String {
        String(localized: "\(count) 项")
    }

    private func ageDaysLabel(_ ageDays: Int) -> String {
        String(localized: "已使用 \(ageDays) 天")
    }

    private func scoreWeightLabel(_ issue: SecurityInsightIssue) -> String {
        "\(SecurityInsightScoring.weight(for: issue)) / \(SecurityInsightScoring.cap(for: issue))"
    }

    private func issueTitle(_ issue: SecurityInsightIssue) -> String {
        switch issue {
        case .flaggedBreach:
            return String(localized: "疑似泄露")
        case .weakPassword:
            return String(localized: "弱密码")
        case .reusedPassword:
            return String(localized: "复用密码")
        case .missingTwoFactor:
            return String(localized: "未开启 2FA")
        case .duplicateEntry:
            return String(localized: "重复条目")
        case .stalePassword:
            return String(localized: "长期未改")
        }
    }

    private func ageBucketTitle(_ bucket: SecurityPasswordAgeBucket) -> String {
        switch bucket {
        case .unknown:
            return String(localized: "未知")
        case .under90Days:
            return String(localized: "90 天内")
        case .days90To179:
            return String(localized: "90–179 天")
        case .days180To364:
            return String(localized: "180–364 天")
        case .atLeast365Days:
            return String(localized: "365 天以上")
        }
    }

    private func scoreBandTitle(_ band: SecurityInsightScoreBand) -> String {
        switch band {
        case .excellent:
            return String(localized: "优秀")
        case .good:
            return String(localized: "良好")
        case .fair:
            return String(localized: "需要改进")
        case .atRisk:
            return String(localized: "风险较高")
        }
    }

    private func scoreBandDetail(_ band: SecurityInsightScoreBand) -> String {
        switch band {
        case .excellent:
            return String(localized: "当前没有需要立即处理的严重问题。")
        case .good:
            return String(localized: "整体不错，仍有少量问题可以优化。")
        case .fair:
            return String(localized: "建议集中处理下面的问题后再评估。")
        case .atRisk:
            return String(localized: "问题较多，建议优先处理泄露与弱密码。")
        }
    }

    private func scoreColor(for band: SecurityInsightScoreBand) -> Color {
        switch band {
        case .excellent, .good:
            return AndroidParityPalette.primary
        case .fair:
            return .orange
        case .atRisk:
            return .red
        }
    }

    // MARK: - 复制

    private func copy(username: String) {
        let feedback = session.copySensitiveValueToPasteboard(username)
        copyFeedbackMessage = feedback.message
        Task {
            try? await Task.sleep(for: .seconds(3))
            if copyFeedbackMessage == feedback.message {
                copyFeedbackMessage = nil
            }
        }
    }
}
