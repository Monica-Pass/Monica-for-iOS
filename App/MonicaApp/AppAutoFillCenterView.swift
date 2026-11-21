import MonicaCore
import SwiftUI

/// 自动填充中心：默认密码管理器引导、本地守护开关、真实状态诊断。
///
/// 页面只描述 iOS 允许的能力：Monica 可以把自己注册为自动填充来源，并在解锁后把身份条目
/// 发布给系统；但它读不到系统默认密码管理器是谁，也不会声称「已接管系统自动填充」。
struct AppAutoFillCenterView: View {
    @Bindable var session: AppSessionModel

    private struct DiagnosticRow: Identifiable {
        let id: String
        let title: String
        let value: String
    }

    var body: some View {
        AndroidParityScreen {
            defaultManagerSection
            guardSection
            diagnosticsSection
        }
        .navigationTitle("自动填充")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await session.autoFillDiagnostics.refresh()
        }
    }

    // MARK: - 默认密码管理器

    private var defaultManagerSection: some View {
        AndroidParitySection(title: appLocalized("默认密码管理器")) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                AndroidParityInfoRow(
                    title: appLocalized("Monica 自动填充"),
                    value: providerStatusText
                )
                AndroidParityInfoRow(
                    title: appLocalized("系统侧身份条目"),
                    value: identityCountText
                )
                Text("iOS 不允许 App 读取或设置「系统默认密码管理器」是谁，也不允许 App 监听其它 App 里出现的密码输入框。Monica 只能把自己注册为自动填充来源，是否启用由你在系统设置里决定。")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AndroidParityCard {
                NavigationLink {
                    AppAutoFillDefaultManagerGuideView()
                } label: {
                    navigationRow(
                        title: appLocalized("设为自动填充来源"),
                        subtitle: appLocalized("查看系统设置路径、测试步骤与 iOS 限制")
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 自动填充守护

    private var guardSection: some View {
        AndroidParitySection(title: appLocalized("自动填充守护")) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                AndroidParityInfoRow(
                    title: appLocalized("仅在保险库解锁时发布"),
                    value: appLocalized("始终开启")
                )
                Text("身份条目由解密后的条目生成，锁定状态下无法发布。这一项由架构保证，不能关闭。")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                AndroidParityDivider()

                Toggle(
                    "仅生物识别解锁后发布身份",
                    isOn: Binding(
                        get: { session.autoFillGuardPolicy.publishesOnlyAfterBiometricUnlock },
                        set: { session.setAutoFillGuardPublishesOnlyAfterBiometricUnlock($0) }
                    )
                )
                .font(.subheadline.weight(.semibold))
                .tint(AndroidParityPalette.primary)

                Text("开启后，用主密码解锁的会话不会把身份写入系统凭据列表，避免别人知道主密码后立刻拿到自动填充建议。")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                AndroidParityDivider()

                Toggle(
                    "锁定后清空已发布身份",
                    isOn: Binding(
                        get: { session.autoFillGuardPolicy.clearsPublishedIdentitiesWhenVaultLocks },
                        set: { session.setAutoFillGuardClearsIdentitiesOnLock($0) }
                    )
                )
                .font(.subheadline.weight(.semibold))
                .tint(AndroidParityPalette.primary)

                Text("开启后，锁定或解锁失败时会清空 Monica 已发布到系统的身份条目；下次解锁并载入条目后会自动补发一次。")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let blockedReason = session.autoFillGuardBlockedReason {
                    AndroidParityDivider()
                    AndroidParityInfoRow(
                        title: appLocalized("最近一次未发布"),
                        value: blockedReason.displayText
                    )
                }
            }

            AndroidParityCard {
                NavigationLink {
                    AndroidParityScreen {
                        AutoFillDomainRulesSettingsView(controller: session.autoFillDomainRules)
                    }
                    .navigationTitle("自动填充域名规则")
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    navigationRow(
                        title: appLocalized("域名规则"),
                        subtitle: appLocalized("指定哪些站点可以或不可以被自动填充")
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 自动填充诊断

    private var diagnosticsSection: some View {
        AndroidParitySection(title: appLocalized("自动填充诊断")) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                ForEach(diagnosticRows) { row in
                    AndroidParityInfoRow(title: row.title, value: row.value)
                }

                Text("以上都是系统公开状态与发布记录，只包含时间、条数、错误原因；不读取、不缓存、不打印任何凭据内容。")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                AndroidParityDivider()

                Button {
                    Task {
                        await session.autoFillDiagnostics.republish {
                            try session.refreshAutoFillEncryptedIndexIfConfigured()
                        }
                    }
                } label: {
                    Label("重新发布身份", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                .disabled(
                    session.vaultState != .unlocked
                        || session.autoFillDiagnostics.republishState.isRunning
                )

                Button {
                    Task {
                        await session.autoFillDiagnostics.refresh()
                    }
                } label: {
                    Label("刷新状态", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                .disabled(session.autoFillDiagnostics.isRefreshing)

                Text(republishStatusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        republishStatusIsError ? Color.red : AndroidParityPalette.textSecondary
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 组件

    private func navigationRow(title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "key.viewfinder")
                .font(.headline.weight(.bold))
                .foregroundStyle(AndroidParityPalette.primary)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
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
    }

    // MARK: - 派生文案

    private var providerStatusText: String {
        guard let status = session.autoFillDiagnostics.snapshot.status else {
            return appLocalized("未知（点击刷新）")
        }
        return status.isEnabled
            ? appLocalized("已在系统设置中启用")
            : appLocalized("系统设置中未启用")
    }

    private var identityCountText: String {
        guard let status = session.autoFillDiagnostics.snapshot.status else {
            return appLocalized("未知（点击刷新）")
        }
        guard let count = status.identityCount else {
            return appLocalized("当前 iOS 版本无法读取")
        }
        return String(count) + " " + appLocalized("条身份")
    }

    private var diagnosticRows: [DiagnosticRow] {
        let snapshot = session.autoFillDiagnostics.snapshot
        var rows: [DiagnosticRow] = [
            DiagnosticRow(
                id: "extension-state",
                title: appLocalized("扩展启用"),
                value: providerStatusText
            ),
            DiagnosticRow(
                id: "extension-version",
                title: appLocalized("扩展版本"),
                value: snapshot.extensionVersion ?? appLocalized("未找到扩展")
            ),
            DiagnosticRow(
                id: "identity-count",
                title: appLocalized("系统侧身份条目"),
                value: identityCountText
            ),
        ]

        if snapshot.statusReadFailed {
            rows.append(
                DiagnosticRow(
                    id: "status-read",
                    title: appLocalized("状态读取"),
                    value: appLocalized("系统未返回状态")
                )
            )
        }

        if let succeededAt = snapshot.log.lastSucceededAt {
            rows.append(
                DiagnosticRow(
                    id: "last-success",
                    title: appLocalized("上次成功发布"),
                    value: joinedLine(
                        succeededAt.formatted(date: .numeric, time: .shortened),
                        String(snapshot.log.lastSucceededCount ?? 0) + " " + appLocalized("条身份")
                    )
                )
            )
        } else {
            rows.append(
                DiagnosticRow(
                    id: "last-success",
                    title: appLocalized("上次成功发布"),
                    value: appLocalized("暂无记录")
                )
            )
        }

        if let failedAt = snapshot.log.lastFailureAt {
            rows.append(
                DiagnosticRow(
                    id: "last-failure",
                    title: appLocalized("上次失败原因"),
                    value: joinedLine(
                        failedAt.formatted(date: .numeric, time: .shortened),
                        snapshot.log.lastFailureMessage ?? appLocalized("未记录原因")
                    )
                )
            )
        } else {
            rows.append(
                DiagnosticRow(
                    id: "last-failure",
                    title: appLocalized("上次失败原因"),
                    value: appLocalized("暂无失败记录")
                )
            )
        }

        if let skippedAt = snapshot.log.lastSkippedAt {
            rows.append(
                DiagnosticRow(
                    id: "last-skip",
                    title: appLocalized("上次跳过发布"),
                    value: joinedLine(
                        skippedAt.formatted(date: .numeric, time: .shortened),
                        snapshot.log.lastSkippedReason ?? appLocalized("未记录原因")
                    )
                )
            )
        }

        if let clearedAt = snapshot.log.lastClearedAt {
            rows.append(
                DiagnosticRow(
                    id: "last-clear",
                    title: appLocalized("上次清空身份"),
                    value: clearedAt.formatted(date: .numeric, time: .shortened)
                )
            )
        }

        return rows
    }

    private func joinedLine(_ parts: String...) -> String {
        parts.joined(separator: " · ")
    }

    private var republishStatusText: String {
        switch session.autoFillDiagnostics.republishState {
        case .idle:
            return appLocalized("尚未手动重新发布。")
        case .running:
            return appLocalized("正在发布身份……")
        case .submitted:
            return appLocalized("已提交发布，系统侧条数以上方诊断为准。")
        case .failed(let message):
            return appLocalized("发布失败：") + message
        case .skipped(let reason):
            return appLocalized("已跳过：") + reason
        }
    }

    private var republishStatusIsError: Bool {
        if case .failed = session.autoFillDiagnostics.republishState {
            return true
        }
        return false
    }
}
