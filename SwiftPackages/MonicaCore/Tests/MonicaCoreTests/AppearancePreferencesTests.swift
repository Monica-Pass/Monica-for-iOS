import Foundation
import Testing
import MonicaCore

@Suite("外观偏好编码与迁移")
struct AppearancePreferencesTests {
    private func decode(_ json: String) throws -> AppearancePreferences {
        try JSONDecoder().decode(AppearancePreferences.self, from: Data(json.utf8))
    }

    private func encode(_ preferences: AppearancePreferences) throws -> [String: Any] {
        let data = try JSONEncoder().encode(preferences)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// 真实旧版 payload（只有四个字段，没有 schemaVersion / themePreset）。
    @Test func legacyPayloadKeepsEveryValue() throws {
        let legacy = #"{"colorScheme":"dark","accentColor":"blue","passwordListIconStyle":"hidden","interfaceDensity":"compact"}"#
        let decoded = try decode(legacy)

        #expect(decoded.colorScheme == .dark)
        #expect(decoded.accentColor == .blue)
        #expect(decoded.passwordListIconStyle == .hidden)
        #expect(decoded.interfaceDensity == .compact)
        #expect(decoded.customAccentHex == nil)
        #expect(decoded.appIcon == .standard)
        #expect(decoded.decodedSchemaVersion == 1)
        // 旧 accentColor 等义迁移到预设，而不是重置成默认。
        #expect(decoded.themePreset == .ocean)
    }

    /// 最老的一版 payload 连 interfaceDensity 都没有。
    @Test func missingDensityFallsBackToDefault() throws {
        let decoded = try decode(#"{"colorScheme":"light","accentColor":"green","passwordListIconStyle":"monochrome"}"#)
        #expect(decoded.interfaceDensity == .default)
        #expect(decoded.colorScheme == .light)
        #expect(decoded.accentColor == .green)
        #expect(decoded.themePreset == .forest)
    }

    /// 损坏 / 未知字段值逐字段回退，不能整块抛错导致用户主题被清空。
    @Test func corruptValuesFallBackDeterministically() throws {
        let corrupted = #"{"schemaVersion":99,"colorScheme":"neon","accentColor":"chartreuse","passwordListIconStyle":7,"interfaceDensity":"ultra","themePreset":"not-a-preset","customAccentHex":"nope","appIcon":"AppIconNope"}"#
        let decoded = try decode(corrupted)
        #expect(decoded.colorScheme == .system)
        #expect(decoded.accentColor == .monica)
        #expect(decoded.passwordListIconStyle == .color)
        #expect(decoded.interfaceDensity == .default)
        #expect(decoded.themePreset == .monica)
        #expect(decoded.customAccentHex == nil)
        #expect(decoded.appIcon == .standard)
        #expect(decoded.decodedSchemaVersion == 99)
    }

    @Test func roundTripPreservesAllFields() throws {
        var original = AppearancePreferences(colorScheme: .light, accentColor: .green)
        original.selectPreset(.grape)
        original.setCustomAccentHex("#123456")
        original.appIcon = .aurora
        original.interfaceDensity = .loose
        original.passwordListIconStyle = .monochrome

        let decoded = try JSONDecoder().decode(
            AppearancePreferences.self,
            from: JSONEncoder().encode(original)
        )
        #expect(decoded == original)
        #expect(decoded.themePreset == .grape)
        #expect(decoded.customAccentHex == "#123456")
        #expect(decoded.appIcon == .aurora)
    }

    /// 新版本写出的 JSON 仍然带旧字段，降级回去不会被读成默认值。
    @Test func encoderKeepsLegacyFieldsForDowngrade() throws {
        var preferences = AppearancePreferences(colorScheme: .dark)
        preferences.selectPreset(.ocean)
        let object = try encode(preferences)

        #expect(object["schemaVersion"] as? Int == 2)
        #expect(object["colorScheme"] as? String == "dark")
        #expect(object["accentColor"] as? String == "blue")
        #expect(object["passwordListIconStyle"] as? String == "color")
        #expect(object["interfaceDensity"] as? String == "default")
        #expect(object["themePreset"] as? String == "ocean")
        #expect(object["appIcon"] as? String == "AppIcon")
    }

    /// 旧版本 App 用结构体解码新 JSON 时必须还能读懂颜色模式。
    @Test func legacyStructDecodesNewPayload() throws {
        struct LegacyPreferences: Decodable {
            let colorScheme: AppearanceThemeMode
            let accentColor: AppearanceAccentColor
            let passwordListIconStyle: AppearancePasswordIconStyle
        }
        var preferences = AppearancePreferences(colorScheme: .light)
        preferences.selectPreset(.amber)
        let data = try JSONEncoder().encode(preferences)
        let legacy = try JSONDecoder().decode(LegacyPreferences.self, from: data)
        #expect(legacy.colorScheme == .light)
        #expect(legacy.accentColor == .monica)
        #expect(legacy.passwordListIconStyle == .color)
    }

    @Test func presetSelectionClearsCustomAccent() {
        var preferences = AppearancePreferences()
        let didSet = preferences.setCustomAccentHex("#B4005A")
        #expect(didSet)
        #expect(preferences.customAccentHex == "#B4005A")
        preferences.selectPreset(.indigo)
        #expect(preferences.customAccentHex == nil)
        #expect(preferences.effectiveAccentColor(for: .dark) == ThemePreset.indigo.accentDark)
        #expect(preferences.accentColor == .monica)
    }

    @Test func invalidCustomAccentIsRejected() {
        var preferences = AppearancePreferences()
        let rejected = preferences.setCustomAccentHex("not-a-color")
        #expect(rejected == false)
        #expect(preferences.customAccentHex == nil)
        let accepted = preferences.setCustomAccentHex("#0e6f62")
        #expect(accepted)
        #expect(preferences.customAccentHex == "#0E6F62")
        let cleared = preferences.setCustomAccentHex(nil)
        #expect(cleared)
        #expect(preferences.customAccentHex == nil)
    }

    @Test func customAccentDrivesPalette() {
        var preferences = AppearancePreferences(themePreset: .monica)
        preferences.setCustomAccentHex("#B4005A")
        for scheme in AppearanceResolvedColorScheme.allCases {
            let palette = preferences.palette(for: scheme)
            #expect(palette.accent == AppearanceColor(hex: "#B4005A"))
            #expect(preferences.customAccentContrast(for: scheme) != nil)
        }
        #expect(preferences.customAccentContrast(for: .dark) == preferences.palette(for: .dark).accentContrast)
    }

    @Test func defaultPreferencesAreStable() throws {
        let decoded = try decode("{}")
        #expect(decoded.colorScheme == AppearancePreferences.default.colorScheme)
        #expect(decoded.accentColor == AppearancePreferences.default.accentColor)
        #expect(decoded.passwordListIconStyle == AppearancePreferences.default.passwordListIconStyle)
        #expect(decoded.interfaceDensity == AppearancePreferences.default.interfaceDensity)
        #expect(decoded.themePreset == AppearancePreferences.default.themePreset)
        #expect(decoded.colorScheme == .system)
        #expect(decoded.themePreset == .monica)
        #expect(decoded.appIcon == .standard)
        #expect(decoded.decodedSchemaVersion == 1)
        #expect(decoded.palette(for: .dark).accent == ThemePreset.monica.accentDark)
    }

    @Test func legacyAccentMappingCoversEveryCase() {
        for accent in AppearanceAccentColor.allCases {
            let preset = accent.themePreset
            #expect(preset.legacyAccentRawValue == accent.rawValue)
        }
    }
}
