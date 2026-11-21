import Observation
import SwiftUI

/// 应用内语言的运行时状态（#128）。
///
/// 唯一写入方是设置页的「语言」选择器：先写内存（界面立即刷新），再落 `UserDefaults`。
/// 启动层用 `\.locale` + `\.lproj` bundle 把当前语言注入整棵视图树。
@MainActor
@Observable
final class AppLanguageController {
    private(set) var language: AppLanguage

    private let store: any AppLanguageStore

    init(store: any AppLanguageStore = UserDefaultsAppLanguageStore()) {
        self.store = store
        self.language = store.loadLanguage()
    }

    /// 注入 `\.locale` 的值；`.system` 沿用系统当前 locale。
    var resolvedLocale: Locale {
        language.locale ?? Locale.current
    }

    /// 当前语言下的文案。
    func localized(_ key: String.LocalizationValue) -> String {
        language.localized(key)
    }

    func select(_ language: AppLanguage) {
        guard language != self.language else {
            return
        }
        self.language = language
        store.saveLanguage(language)
    }
}
