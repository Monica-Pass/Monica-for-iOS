import MonicaCore
import SwiftUI

/// 「验证码进度条」设置区块（#155）。
///
/// 三组设置：统一进度条、样式（线性 / 环形）、平滑动画。全部写入
/// `AppSessionModel.totpCardPreferences`；三组都保持默认时，验证器卡片的外观与
/// 引入设置之前完全一致，验证码算法与刷新周期不受影响。
struct AppTotpCardStyleSettingsView: View {
    let session: AppSessionModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var preferences: TotpProgressPreferences {
        session.totpCardPreferences
    }

    var body: some View {
        AndroidParitySection(title: String(localized: "验证码进度条")) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                Toggle("统一进度条", isOn: unifiedProgressBarBinding)
                    .font(.headline.weight(.heavy))
                    .tint(AndroidParityPalette.primary)
                Text(String(localized: "所有 30 秒周期的验证码共用一条进度条，卡片不再重复显示；60 秒与自定义周期仍显示各自的进度。"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                preview
                AndroidParityDivider()
                Picker("进度条样式", selection: styleBinding) {
                    ForEach(TotpProgressStyle.allCases) { style in
                        Text(style.displayLabel).tag(style)
                    }
                }
                Text(String(localized: "线性与之前的胶囊进度条一致；环形沿 12 点方向顺时针收缩。"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                AndroidParityDivider()
                Toggle("平滑动画", isOn: smoothAnimationBinding)
                    .font(.headline.weight(.heavy))
                    .tint(AndroidParityPalette.primary)
                Text(smoothAnimationDetail)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                AndroidParityDivider()
                Button {
                    session.restoreDefaultTotpCardPreferences()
                } label: {
                    Label(String(localized: "恢复默认"), systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
            }
        }
    }

    /// 用真实卡片样式展示当前设置，跟着系统秒走但不读取任何条目。
    private var preview: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            previewCard(at: context.date)
        }
        .accessibilityLabel(String(localized: "样式预览"))
    }

    private func previewCard(at date: Date) -> some View {
        let policy = session.totpCardStylePolicy(reduceMotion: reduceMotion)
        let remaining = policy.unifiedRemaining(at: date)
        let fraction = policy.progress(remaining: remaining, period: TotpCardStylePolicy.unifiedPeriod)
        return AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.78), cornerRadius: 22) {
            HStack(alignment: .center, spacing: 18) {
                AndroidParityIconTile(systemImage: "shield.lefthalf.filled")
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "示例账号"))
                        .font(.subheadline.weight(.semibold))
                    Text(verbatim: "monica@example.com")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                    TotpProgressIndicator(
                        fraction: fraction,
                        style: policy.style,
                        animatesChanges: policy.isSmoothAnimationEnabled,
                        ringDiameter: 26
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(verbatim: "123 456")
                        .font(AndroidParityTypography.prominentTitle(weight: .heavy))
                        .foregroundStyle(AndroidParityPalette.primary)
                    Text(verbatim: "\(remaining)s")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.primary)
                }
            }
        }
    }

    private var smoothAnimationDetail: String {
        if reduceMotion {
            String(localized: "系统「减弱动态效果」已开启，进度条不做平滑动画。")
        } else {
            String(localized: "开启后每秒在新旧进度之间线性过渡；关闭后直接跳到新进度，与旧版本一致。")
        }
    }

    private var unifiedProgressBarBinding: Binding<Bool> {
        Binding {
            preferences.usesUnifiedProgressBar
        } set: { isOn in
            var updated = preferences
            updated.usesUnifiedProgressBar = isOn
            session.updateTotpCardPreferences(updated)
        }
    }

    private var styleBinding: Binding<TotpProgressStyle> {
        Binding {
            preferences.style
        } set: { style in
            var updated = preferences
            updated.style = style
            session.updateTotpCardPreferences(updated)
        }
    }

    private var smoothAnimationBinding: Binding<Bool> {
        Binding {
            preferences.usesSmoothAnimation
        } set: { isOn in
            var updated = preferences
            updated.usesSmoothAnimation = isOn
            session.updateTotpCardPreferences(updated)
        }
    }
}
