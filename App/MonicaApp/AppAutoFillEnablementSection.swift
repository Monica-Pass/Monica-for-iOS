import MonicaCore
import SwiftUI
import UIKit

/// 设置页「自动填充」区的系统启用引导与扩展诊断摘要（#39）。
///
/// 只复用 `AppAutoFillDiagnostics` 的只读状态，不重复实现发布/诊断逻辑；
/// 系统设置步骤与测试说明仍由 `AppAutoFillDefaultManagerGuideView` 承载，
/// 完整诊断仍由 `AppAutoFillCenterView` 承载。
struct AppAutoFillEnablementSection: View {
    @Bindable var session: AppSessionModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        AndroidParitySection(title: String(localized: "启用 Monica 作为密码管理器")) {
            stepsCard
            extensionStatusCard
            destinationsCard
        }
        .task {
            await session.autoFillDiagnostics.refresh()
        }
    }

    private var stepsCard: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
            Text("iOS 只允许你在系统设置里选择自动填充来源，Monica 不能替你打开这个开关。")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(passwordSettingsPathText)
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(AndroidParityPalette.primary)
                .fixedSize(horizontal: false, vertical: true)

            AndroidParityDivider()

            ForEach(Array(systemSteps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Text(String(index + 1))
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(AndroidParityPalette.onPrimary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(AndroidParityPalette.primary))
                    Text(step)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                if let settingsURL = appSettingsURL {
                    openURL(settingsURL)
                }
            } label: {
                Label("打开 Monica 的系统设置", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .filled))
            .disabled(appSettingsURL == nil)

            Text("这里只会打开本 App 的设置页；系统的「密码选项 › 自动填充密码」需要你自己进入。Monica 不能读取或设置系统默认密码管理器是谁。")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var extensionStatusCard: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
            AppAutoFillExtensionDiagnosticsSummary(diagnostics: session.autoFillDiagnostics)
            Text("已安装扩展不代表已在系统里启用；系统未识别的输入框不会显示 Monica 建议，QuickType 是否出现由 iOS 决定。")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var destinationsCard: some View {
        AndroidParityCard {
            NavigationLink {
                AppAutoFillDefaultManagerGuideView(title: String(localized: "系统自动填充说明"))
            } label: {
                destinationRow(
                    title: "系统自动填充说明",
                    subtitle: "设置路径、测试步骤、能力矩阵与 iOS 限制",
                    systemImage: "questionmark.circle"
                )
            }
            .buttonStyle(.plain)

            AndroidParityDivider()

            NavigationLink {
                AppAutoFillCenterView(session: session)
            } label: {
                destinationRow(
                    title: "自动填充诊断",
                    subtitle: "发布状态、系统侧身份条目与本地守护开关",
                    systemImage: "stethoscope"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func destinationRow(title: String, subtitle: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AndroidParityPalette.primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                Text(subtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
        }
        .contentShape(Rectangle())
    }

    private var appSettingsURL: URL? {
        URL(string: UIApplication.openSettingsURLString)
    }

    private var passwordSettingsPathText: String {
        if #available(iOS 18.0, *) {
            return String(localized: "设置 › 密码 › 密码选项 › 自动填充密码")
        }
        return String(localized: "设置 › 密码 › 密码选项 › 自动填充密码（iOS 17）")
    }

    private var systemSteps: [String] {
        [
            String(localized: "打开系统「设置」，进入密码相关入口（iOS 18 起密码独立成 App，也可能在「设置 › App › 密码」）。"),
            String(localized: "进入「密码选项 › 自动填充密码」，在来源列表里把 Monica 打开。"),
            String(localized: "回到 Monica 解锁保险库，身份条目会发布给系统。"),
            String(localized: "在系统识别的用户名 / 密码输入框里选择 Monica 建议；未识别的输入框不会出现建议。"),
        ]
    }
}

/// 扩展安装与系统状态摘要；真实状态全部来自 `AppAutoFillDiagnosticsModel`。
private struct AppAutoFillExtensionDiagnosticsSummary: View {
    @ObservedObject var diagnostics: AppAutoFillDiagnosticsModel

    var body: some View {
        let snapshot = diagnostics.snapshot
        VStack(alignment: .leading, spacing: 8) {
            AndroidParityInfoRow(
                title: String(localized: "扩展版本"),
                value: snapshot.extensionVersion ?? String(localized: "未找到扩展")
            )
            AndroidParityInfoRow(
                title: String(localized: "系统侧身份条目"),
                value: identityCountText(snapshot)
            )
            AndroidParityInfoRow(
                title: String(localized: "上次成功发布"),
                value: lastPublishText(snapshot.log)
            )
            if snapshot.statusReadFailed {
                Text("读取系统状态失败；模拟器或未配置 App Group 时通常读不到凭证身份库。")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                Task { await diagnostics.refresh() }
            } label: {
                Label("刷新状态", systemImage: "arrow.clockwise")
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
            .disabled(diagnostics.isRefreshing)
        }
    }

    private func identityCountText(_ snapshot: AppAutoFillDiagnosticsModel.Snapshot) -> String {
        guard let status = snapshot.status else {
            return String(localized: "无法读取")
        }
        guard status.isEnabled else {
            return String(localized: "未启用")
        }
        guard let identityCount = status.identityCount else {
            return String(localized: "系统未提供计数")
        }
        return String(identityCount) + " " + String(localized: "条身份")
    }

    private func lastPublishText(_ log: AppAutoFillPublishLog) -> String {
        guard let succeededAt = log.lastSucceededAt else {
            return String(localized: "暂无记录")
        }
        return succeededAt.formatted(date: .numeric, time: .shortened)
            + " · " + String(log.lastSucceededCount ?? 0) + " " + String(localized: "条身份")
    }
}
