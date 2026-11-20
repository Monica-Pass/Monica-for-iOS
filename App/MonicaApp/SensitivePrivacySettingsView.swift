import MonicaCore
import SwiftUI

/// 设置页的「敏感隐私」区块（#58）。
///
/// 拆成独立文件，避免继续膨胀 `SettingsRootView.swift`；由 `SettingsRootView` 直接嵌入。
struct SensitivePrivacySettingsSection: View {
    @Bindable var session: AppSessionModel
    @State private var manualClearFeedback: String?

    var body: some View {
        AndroidParitySection(title: String(localized: "敏感隐私")) {
            clipboardCard
            maskingCard
        }
    }

    private var clipboardCard: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
            Picker(String(localized: "复制后自动清除剪贴板"), selection: ttlBinding) {
                ForEach(SensitiveClipboardTTL.allCases) { ttl in
                    Text(ttlLabel(ttl)).tag(ttl)
                }
            }
            Text(String(localized: "Monica 只清除自己写入且未被其它 App 替换的内容。iOS 会在 App 进入后台后暂停计时，因此只在 App 内计时，并在回到 App 时补做检查；系统不保证后台精确到秒，也不会读取或覆盖其它 App 的剪贴板。"))
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)

            if session.sensitivePasteboardHasPendingAutoClear {
                AndroidParityDivider()
                Text(String(localized: "有一次复制等待自动清除；回到 App 或到期后会再次核对剪贴板。"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }

            Button {
                manualClearFeedback = manualClearMessage(session.clearSensitivePasteboardManually())
            } label: {
                Label(String(localized: "立即清除剪贴板"), systemImage: "scissors")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
            .disabled(!session.sensitivePasteboardHasPendingAutoClear)

            if let manualClearFeedback {
                Text(manualClearFeedback)
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }
    }

    private var maskingCard: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
            Text(String(localized: "密码、验证码、银行卡号与 CVV 在列表、搜索结果和详情里默认显示为掩码；详情页的「显示敏感字段」只对下面允许的类别生效，并且锁库后立即恢复掩码。"))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)

            Toggle(String(localized: "始终遮蔽敏感预览"), isOn: alwaysMaskBinding)
            Text(String(localized: "开启后连详情页的临时显示也会失效，适合演示或录屏。"))
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)

            AndroidParityDivider()

            ForEach(SensitivePreviewCategory.allCases) { category in
                Toggle(isOn: revealableBinding(category)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.localizedTitle)
                        Text(category.localizedDetail)
                            .font(.footnote)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }
                }
                .disabled(session.sensitivePreviewPreferences.alwaysMask)
                if category != SensitivePreviewCategory.allCases.last {
                    AndroidParityDivider()
                }
            }

            Text(String(localized: "允许显示只影响详情页里手动打开的「显示敏感字段」；列表与搜索结果始终掩码。"))
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
        }
    }

    private var ttlBinding: Binding<SensitiveClipboardTTL> {
        Binding(
            get: { session.sensitiveClipboardTTL },
            set: { session.updateSensitiveClipboardTTL($0) }
        )
    }

    private var alwaysMaskBinding: Binding<Bool> {
        Binding(
            get: { session.sensitivePreviewPreferences.alwaysMask },
            set: { newValue in
                var preferences = session.sensitivePreviewPreferences
                preferences.alwaysMask = newValue
                session.updateSensitivePreviewPreferences(preferences)
            }
        )
    }

    private func revealableBinding(_ category: SensitivePreviewCategory) -> Binding<Bool> {
        Binding(
            get: {
                !session.sensitivePreviewPreferences.masks(category)
            },
            set: { newValue in
                var preferences = session.sensitivePreviewPreferences
                preferences.setRevealable(newValue, for: category)
                session.updateSensitivePreviewPreferences(preferences)
            }
        )
    }

    private func ttlLabel(_ ttl: SensitiveClipboardTTL) -> String {
        switch ttl {
        case .off:
            return String(localized: "关闭")
        case .seconds15:
            return String(localized: "15 秒")
        case .seconds30:
            return String(localized: "30 秒")
        case .seconds60:
            return String(localized: "60 秒")
        }
    }

    private func manualClearMessage(_ outcome: MonicaSensitivePasteboard.ExpiryOutcome) -> String {
        switch outcome {
        case .cleared:
            return String(localized: "已清除 Monica 写入的剪贴板内容。")
        case .skippedBecauseReplacedByAnotherApp:
            return String(localized: "剪贴板已被其它 App 更新，Monica 没有覆盖它。")
        case .notYetDue, .noPendingValue:
            return String(localized: "没有待清除的复制记录。")
        }
    }
}
