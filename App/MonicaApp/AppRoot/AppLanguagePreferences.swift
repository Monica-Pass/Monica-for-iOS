import Foundation

/// 应用内语言（#128）。
///
/// `rawValue` 既是设置页的选项标识，也是 `UserDefaults` 里的持久化值；
/// 读取时 `nil`、空串与任何非法值都回退 `.system`，升级/降级不会让界面语言失效。
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    /// 跟随系统语言。
    case system
    /// 简体中文。
    case simplifiedChinese = "zh-Hans"
    /// English。
    case english = "en"

    /// `UserDefaults` 中的持久化键。
    static let userDefaultsKey = "monica.appLanguage"

    var id: String { rawValue }

    /// 用持久化值构造；非法值回退 `.system`。
    init(persistedValue: String?) {
        guard let persistedValue,
              let language = AppLanguage(rawValue: persistedValue)
        else {
            self = .system
            return
        }
        self = language
    }

    /// 注入 SwiftUI `\.locale` 的值；`.system` 返回 `nil`，由系统 locale 决定。
    var locale: Locale? {
        switch self {
        case .system:
            nil
        case .simplifiedChinese:
            Locale(identifier: "zh-Hans")
        case .english:
            Locale(identifier: "en")
        }
    }

    /// `.lproj` 资源目录名；`.system` 交给 `Bundle.main` 自己解析。
    var localizationLanguageCode: String? {
        switch self {
        case .system:
            nil
        case .simplifiedChinese:
            "zh-Hans"
        case .english:
            "en"
        }
    }

    /// 该语言对应的 `.lproj` bundle；资源缺失时回退 `Bundle.main`。
    var localizationBundle: Bundle {
        guard let languageCode = localizationLanguageCode,
              let bundle = Self.localizationBundles[languageCode]
        else {
            return .main
        }
        return bundle
    }

    /// 按该语言解析文案。
    ///
    /// `String(localized:)` 的 `locale:` 参数不参与 `.lproj` 选择（只影响格式化），
    /// 所以运行时切换语言必须显式指定 `bundle:`。未翻译的 key 会原样返回 ——
    /// 本工程的 key 就是简体中文原文，因此天然回退到 zh-Hans。
    func localized(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: localizationBundle)
    }

    /// `interfaceLanguage` 界面语言下的选项名称。
    ///
    /// 例：English 界面里「简体中文」显示为 `Simplified Chinese`；
    /// 简体中文界面里「英语」显示为 `英语`。
    func displayName(in interfaceLanguage: AppLanguage) -> String {
        let key: String.LocalizationValue
        switch self {
        case .system:
            key = "跟随系统"
        case .simplifiedChinese:
            key = "简体中文"
        case .english:
            key = "英语"
        }
        return interfaceLanguage.localized(key)
    }

    /// 惰性构建并复用 `.lproj` bundle，避免每次取文案都查一次路径。
    private static let localizationBundles: [String: Bundle] = {
        var bundles: [String: Bundle] = [:]
        for language in AppLanguage.allCases {
            guard let languageCode = language.localizationLanguageCode,
                  let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
                  let bundle = Bundle(path: path)
            else {
                continue
            }
            bundles[languageCode] = bundle
        }
        return bundles
    }()
}

/// 应用内语言的持久化。
protocol AppLanguageStore: Sendable {
    func loadLanguage() -> AppLanguage
    func saveLanguage(_ language: AppLanguage)
}

final class UserDefaultsAppLanguageStore: AppLanguageStore, @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let key: String

    init(userDefaults: UserDefaults = .standard, key: String = AppLanguage.userDefaultsKey) {
        self.userDefaults = userDefaults
        self.key = key
    }

    func loadLanguage() -> AppLanguage {
        AppLanguage(persistedValue: userDefaults.string(forKey: key))
    }

    func saveLanguage(_ language: AppLanguage) {
        userDefaults.set(language.rawValue, forKey: key)
    }
}

final class MemoryAppLanguageStore: AppLanguageStore, @unchecked Sendable {
    private(set) var persistedValue: String?

    init(persistedValue: String? = nil) {
        self.persistedValue = persistedValue
    }

    func loadLanguage() -> AppLanguage {
        AppLanguage(persistedValue: persistedValue)
    }

    func saveLanguage(_ language: AppLanguage) {
        persistedValue = language.rawValue
    }
}
