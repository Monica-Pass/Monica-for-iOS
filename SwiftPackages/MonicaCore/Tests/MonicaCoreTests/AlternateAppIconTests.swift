import Foundation
import Testing
import MonicaCore

@Suite("备用 App 图标")
struct AlternateAppIconTests {
    @Test func rawValuesMatchAssetCatalogNames() {
        // 这些字符串同时是 asset catalog 的 appiconset 名称，改名会让
        // setAlternateIconName 静默失败。
        #expect(AlternateAppIcon.standard.rawValue == "AppIcon")
        #expect(AlternateAppIcon.midnight.rawValue == "AppIconMidnight")
        #expect(AlternateAppIcon.aurora.rawValue == "AppIconAurora")
        #expect(AlternateAppIcon.allCases.count >= 3)
    }

    @Test func alternateNamesFollowAppleRules() {
        // 默认图标不是 alternate：必须传 nil。
        #expect(AlternateAppIcon.standard.alternateIconName == nil)
        #expect(AlternateAppIcon.midnight.alternateIconName == "AppIconMidnight")
        #expect(AlternateAppIcon.aurora.alternateIconName == "AppIconAurora")
        #expect(AlternateAppIcon.standard.isAlternate == false)
        #expect(AlternateAppIcon.midnight.isAlternate)
    }

    @Test func currentIconResolvesUnknownToStandard() {
        #expect(AlternateAppIcon.current(alternateIconName: nil) == .standard)
        #expect(AlternateAppIcon.current(alternateIconName: "AppIconMidnight") == .midnight)
        #expect(AlternateAppIcon.current(alternateIconName: "SomeOtherAppIconPack") == .standard)
        // 有人可能把主图标名当 alternate 名返回，也不能展示成「已切换」。
        #expect(AlternateAppIcon.current(alternateIconName: "AppIcon") == .standard)
    }

    @Test func roundTripThroughPreferences() throws {
        var preferences = AppearancePreferences()
        #expect(preferences.appIcon == .standard)
        preferences.selectPreset(.rose)
        preferences.appIcon = .midnight

        let decoded = try JSONDecoder().decode(
            AppearancePreferences.self,
            from: JSONEncoder().encode(preferences)
        )
        #expect(decoded.appIcon == .midnight)
        #expect(decoded.themePreset == .rose)
    }

    @Test func everyIconHasUserFacingCopy() {
        for icon in AlternateAppIcon.allCases {
            #expect(icon.displayName.isEmpty == false)
            #expect(icon.detail.isEmpty == false)
        }
        #expect(Set(AlternateAppIcon.allCases.map(\.displayName)).count == AlternateAppIcon.allCases.count)
    }
}
