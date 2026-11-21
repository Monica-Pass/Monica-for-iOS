import Foundation

/// 应用内语言的进程级入口（#133）。
///
/// `String(localized:)` 固定从 `Bundle.main` 按**系统**语言解析，无法跟随设置页里的
/// 应用内语言；SwiftUI 的 `Text(LocalizedStringKey)` 才吃 `\.locale`。因此凡是要拿到
/// `String` 的地方（行标题、错误文案、分享文本、导出文件名）统一改用 `appLocalized(_:)`。
///
/// 语言值由 `AppLanguageController` 写入；读取端可能来自后台任务，故用锁保护，
/// 只在启动与手动切换时写入一次，读取开销可忽略。
final class AppLocalizationRuntime: @unchecked Sendable {
    static let shared = AppLocalizationRuntime()

    private let lock = NSLock()
    private var language: AppLanguage

    init(language: AppLanguage = UserDefaultsAppLanguageStore().loadLanguage()) {
        self.language = language
    }

    var current: AppLanguage {
        lock.lock()
        defer { lock.unlock() }
        return language
    }

    /// 更新运行时语言；与当前值相同时不做任何事。
    func set(_ language: AppLanguage) {
        lock.lock()
        defer { lock.unlock() }
        self.language = language
    }
}

/// 跟随应用内语言解析文案。
///
/// key 就是简体中文原文，`en` 缺少翻译时 `Bundle` 会回退到开发语言（zh-Hans），
/// 因此不会把 key 字面量漏到界面上。
func appLocalized(_ key: String.LocalizationValue) -> String {
    AppLocalizationRuntime.shared.current.localized(key)
}
