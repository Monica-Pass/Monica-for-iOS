import MonicaCore
import SwiftUI

/// 设置页的「验证器」区块（#148）：到期自动复制下一个验证码。
///
/// 与 #58 的「敏感隐私」相邻：自动续写同样写入敏感剪贴板，并遵循那里的自动清除时长。
/// 拆成独立文件，避免继续膨胀 `SettingsRootView.swift`。
struct TotpAutoCopySettingsSection: View {
    @Bindable var session: AppSessionModel

    var body: some View {
        AndroidParitySection(title: String(localized: "验证器")) {
            autoCopyCard
        }
    }

    private var autoCopyCard: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
            Toggle(String(localized: "到期自动复制下一个验证码"), isOn: enabledBinding)
            Text(String(localized: "复制过一次验证码后，当前验证码剩余 3 秒以内时，会把下一个验证码写入剪贴板。只在验证页处于前台、且密码库已解锁时生效；锁屏或切到后台不会写入。"))
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
            Text(String(localized: "只支持基于时间的验证码（TOTP）；计数器验证码（HOTP）不会自动复制。写入同样遵循「敏感隐私」里的自动清除时长。"))
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)

            if session.totpAutoCopyEnabled && !session.hasArmedTotpAutoCopyEntry {
                AndroidParityDivider()
                Text(String(localized: "还没有可续写的条目：先手动复制一次验证码。"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { session.totpAutoCopyEnabled },
            set: { session.updateTotpAutoCopyEnabled($0) }
        )
    }
}
