import SwiftUI

/// 设置页「语言」分组（#128）。
///
/// 与 `AppThemeSettingsView` 同页、独立 section：只在其后追加，不重排已有分组。
/// 文案统一走 `AppLanguageController.localized(_:)`（`\.lproj` bundle 解析），
/// 因此选中项变化后本分组立即刷新，不依赖杀 App。
struct AppLanguageSettingsView: View {
    @Environment(AppLanguageController.self) private var appLanguage

    var body: some View {
        AndroidParitySection(title: appLanguage.localized("语言")) {
            AndroidParityCard {
                Picker(appLanguage.localized("应用语言"), selection: selection) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.displayName(in: appLanguage.language))
                            .tag(option)
                    }
                }
                AndroidParityDivider()
                Text(
                    appLanguage.localized(
                        "部分由系统缓存的文案（权限弹窗、App 名称、桌面小组件）需重启 App 或更改系统语言后才会更新。"
                    )
                )
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var selection: Binding<AppLanguage> {
        Binding {
            appLanguage.language
        } set: { option in
            appLanguage.select(option)
        }
    }
}
