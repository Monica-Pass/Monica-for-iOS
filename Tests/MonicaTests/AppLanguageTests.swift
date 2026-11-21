@testable import Monica
import Foundation
import XCTest

final class AppLanguageTests: XCTestCase {
    private func makeUserDefaults() throws -> (UserDefaults, String) {
        let suiteName = "AppLanguageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    // MARK: - 持久化往返

    func testStoreDefaultsToSystemAndRoundTripsEveryLanguage() throws {
        let (defaults, suiteName) = try makeUserDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsAppLanguageStore(userDefaults: defaults)

        XCTAssertEqual(store.loadLanguage(), .system)
        XCTAssertEqual(AppLanguage(persistedValue: nil), .system)

        for language in AppLanguage.allCases {
            store.saveLanguage(language)
            XCTAssertEqual(
                defaults.string(forKey: AppLanguage.userDefaultsKey),
                language.rawValue,
                "持久化值应为 rawValue：\(language)"
            )
            XCTAssertEqual(
                UserDefaultsAppLanguageStore(userDefaults: defaults).loadLanguage(),
                language,
                "重新读取应得到同一语言：\(language)"
            )
        }
    }

    func testInvalidPersistedValuesFallBackToSystem() throws {
        let (defaults, suiteName) = try makeUserDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsAppLanguageStore(userDefaults: defaults)

        for invalidValue in ["fr", "", "zh", "en-US", "EN", "english", "zh-Hant", "跟随系统"] {
            defaults.set(invalidValue, forKey: AppLanguage.userDefaultsKey)
            XCTAssertEqual(store.loadLanguage(), .system, "非法值应回退 system：\(invalidValue)")
        }

        defaults.set(42, forKey: AppLanguage.userDefaultsKey)
        XCTAssertEqual(store.loadLanguage(), .system, "非字符串应回退 system")

        defaults.set(["en"], forKey: AppLanguage.userDefaultsKey)
        XCTAssertEqual(store.loadLanguage(), .system, "数组值应回退 system")
    }

    // MARK: - locale / 资源解析

    func testLocaleAndResourceCodeResolution() {
        XCTAssertNil(AppLanguage.system.locale)
        XCTAssertNil(AppLanguage.system.localizationLanguageCode)
        XCTAssertEqual(AppLanguage.simplifiedChinese.locale?.identifier, "zh-Hans")
        XCTAssertEqual(AppLanguage.simplifiedChinese.localizationLanguageCode, "zh-Hans")
        XCTAssertEqual(AppLanguage.english.locale?.identifier, "en")
        XCTAssertEqual(AppLanguage.english.localizationLanguageCode, "en")
        XCTAssertEqual(AppLanguage.allCases.map(\.rawValue), ["system", "zh-Hans", "en"])
    }

    func testSelectedLanguageResolvesStringsFromItsOwnLocalizationBundle() {
        // key 就是简体中文原文：英文 bundle 必须给出英文，中文 bundle 回退原文。
        XCTAssertNotEqual(AppLanguage.english.localized("密码"), "密码")
        XCTAssertEqual(AppLanguage.simplifiedChinese.localized("密码"), "密码")
        XCTAssertEqual(
            AppLanguage.system.localized("密码"),
            Bundle.main.localizedString(forKey: "密码", value: nil, table: nil)
        )
        // 未翻译的 key 原样返回 —— 等价于回退 zh-Hans，不会显示 key 字面量之外的内容。
        XCTAssertEqual(
            AppLanguage.english.localized("AppLanguageTests.未翻译的键"),
            "AppLanguageTests.未翻译的键"
        )
    }

    func testOptionDisplayNamesFollowInterfaceLanguage() {
        XCTAssertEqual(AppLanguage.system.displayName(in: .english), "System")
        XCTAssertEqual(AppLanguage.system.displayName(in: .simplifiedChinese), "跟随系统")
        XCTAssertEqual(AppLanguage.simplifiedChinese.displayName(in: .english), "Simplified Chinese")
        XCTAssertEqual(AppLanguage.simplifiedChinese.displayName(in: .simplifiedChinese), "简体中文")
        XCTAssertEqual(AppLanguage.english.displayName(in: .english), "English")
        XCTAssertEqual(AppLanguage.english.displayName(in: .simplifiedChinese), "英语")
    }

    // MARK: - 运行时状态

    @MainActor
    func testControllerLoadsPersistedSelectionAndPersistsChanges() {
        let store = MemoryAppLanguageStore(persistedValue: "en")
        let controller = AppLanguageController(store: store)

        XCTAssertEqual(controller.language, .english)
        XCTAssertEqual(controller.resolvedLocale.identifier, "en")

        controller.select(.simplifiedChinese)
        XCTAssertEqual(controller.language, .simplifiedChinese)
        XCTAssertEqual(store.persistedValue, "zh-Hans")
        XCTAssertEqual(controller.resolvedLocale.identifier, "zh-Hans")

        controller.select(.system)
        XCTAssertEqual(store.persistedValue, "system")
        XCTAssertEqual(controller.resolvedLocale, Locale.current)

        // 重复选择同一语言不应重复写盘。
        store.saveLanguage(.english)
        controller.select(.system)
        XCTAssertEqual(store.persistedValue, "en")
    }

    @MainActor
    func testControllerFallsBackToSystemForInvalidPersistedValue() {
        let controller = AppLanguageController(store: MemoryAppLanguageStore(persistedValue: "fr"))
        XCTAssertEqual(controller.language, .system)
        XCTAssertEqual(controller.resolvedLocale, Locale.current)
    }
}

// MARK: - #133 进程级本地化入口

extension AppLanguageTests {
    /// `appLocalized` 必须跟随运行时语言，而不是系统语言。
    func testAppLocalizedFollowsRuntimeLanguage() {
        let runtime = AppLocalizationRuntime(language: .simplifiedChinese)
        XCTAssertEqual(
            runtime.current.localized("设置"),
            AppLanguage.simplifiedChinese.localized("设置")
        )

        runtime.set(.english)
        XCTAssertEqual(runtime.current, .english)
        XCTAssertEqual(
            runtime.current.localized("设置"),
            AppLanguage.english.localized("设置"),
            "切换运行时语言后应解析到 en 的 .lproj"
        )
    }

    /// 运行时语言写入后，共享入口同步更新。
    @MainActor
    func testRuntimeSharedInstanceReflectsSelectFromController() throws {
        let (defaults, suiteName) = try makeUserDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let previous = AppLocalizationRuntime.shared.current
        defer { AppLocalizationRuntime.shared.set(previous) }

        let controller = AppLanguageController(store: UserDefaultsAppLanguageStore(userDefaults: defaults))
        controller.select(.english)
        XCTAssertEqual(AppLocalizationRuntime.shared.current, .english)
        XCTAssertEqual(appLocalized("设置"), AppLanguage.english.localized("设置"))
    }

    /// en 缺少翻译时必须回退到 zh-Hans 原文，而不是显示 key 字面量以外的空白。
    func testMissingEnglishTranslationFallsBackToSourceLanguage() {
        let key: String.LocalizationValue = "这条文案在测试里没有 en 译文"
        let resolved = AppLanguage.english.localized(key)
        XCTAssertEqual(resolved, "这条文案在测试里没有 en 译文", "缺译文时应回退 key（即中文原文）")
    }
}
