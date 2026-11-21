import CoreGraphics
import Foundation

/// 颜色模式。raw value 与旧版 `AppAppearanceColorScheme` 完全一致。
public enum AppearanceThemeMode: String, Sendable, CaseIterable, Hashable, Identifiable, Codable {
    case system
    case light
    case dark

    public var id: String { rawValue }
}

/// 旧版强调色。保留该字段有两个原因：
/// 1. 老版本 JSON / 备份里只有它，解码时不能丢；
/// 2. 降级回旧版本时仍能从新 JSON 里读回等价颜色，不出现「主题被重置」。
public enum AppearanceAccentColor: String, Sendable, CaseIterable, Hashable, Identifiable, Codable {
    case monica
    case green
    case blue
    case orange

    public var id: String { rawValue }

    public var themePreset: ThemePreset {
        ThemePreset.migrated(fromLegacyAccent: rawValue)
    }
}

/// 密码列表图标样式。raw value 与旧版一致。
public enum AppearancePasswordIconStyle: String, Sendable, CaseIterable, Hashable, Identifiable, Codable {
    case color
    case monochrome
    case hidden

    public var id: String { rawValue }
}

/// 界面密度。raw value 与旧版一致。
public enum AppearanceDensity: String, Sendable, CaseIterable, Hashable, Identifiable, Codable {
    case `default`
    case compact
    case loose

    public var id: String { rawValue }

    public var spacingScale: CGFloat {
        switch self {
        case .default: 1
        case .compact: 0.8
        case .loose: 1.3
        }
    }

    public var lineSpacingDelta: CGFloat {
        switch self {
        case .default: 0
        case .compact: 0
        case .loose: 3
        }
    }

    /// Apple HIG 最小可点击尺寸。
    public static let minimumTouchTarget: CGFloat = 44

    public func touchTarget(_ base: CGFloat) -> CGFloat {
        max(Self.minimumTouchTarget, base)
    }
}

/// 外观 / 主题 / 图标偏好。
///
/// 编码策略：
/// - 始终写入 `schemaVersion`（当前 2）以及**全部旧字段**（colorScheme / accentColor /
///   passwordListIconStyle / interfaceDensity），旧版本 App 解码时会忽略新字段并保持原值；
/// - 解码逐字段容错，缺失 / 类型错误都回落到默认值；
/// - `themePreset` 缺失时按 `accentColor` 等义迁移（monica/green/blue/orange →
///   monica/forest/ocean/sunset），不会把用户已有颜色重置成默认。
public struct AppearancePreferences: Sendable, Equatable, Codable {
    public static let currentSchemaVersion = 2

    public static let `default` = AppearancePreferences()

    public var colorScheme: AppearanceThemeMode
    public var accentColor: AppearanceAccentColor
    public var passwordListIconStyle: AppearancePasswordIconStyle
    public var interfaceDensity: AppearanceDensity
    /// 命名主题预设。稳定 raw value，不随语言变化。
    public var themePreset: ThemePreset
    /// 自定义强调色，`#RRGGBB`；为 nil 时使用 `themePreset` 的强调色。
    public var customAccentHex: String?
    /// 备用 App 图标选择。
    public var appIcon: AlternateAppIcon
    /// 解码时的原始 schema 版本（1 = 旧版 4 字段 JSON，2 = 当前）。
    public var decodedSchemaVersion: Int

    public init(
        colorScheme: AppearanceThemeMode = .system,
        accentColor: AppearanceAccentColor = .monica,
        passwordListIconStyle: AppearancePasswordIconStyle = .color,
        interfaceDensity: AppearanceDensity = .default,
        themePreset: ThemePreset? = nil,
        customAccentHex: String? = nil,
        appIcon: AlternateAppIcon = .standard,
        decodedSchemaVersion: Int = AppearancePreferences.currentSchemaVersion
    ) {
        self.colorScheme = colorScheme
        self.accentColor = accentColor
        self.passwordListIconStyle = passwordListIconStyle
        self.interfaceDensity = interfaceDensity
        self.themePreset = themePreset ?? accentColor.themePreset
        self.customAccentHex = AppearancePreferences.normalizedHex(customAccentHex)
        self.appIcon = appIcon
        self.decodedSchemaVersion = decodedSchemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case colorScheme
        case accentColor
        case passwordListIconStyle
        case interfaceDensity
        case themePreset
        case customAccentHex
        case appIcon
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = (try? container.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? nil
        let colorScheme = (try? container.decodeIfPresent(AppearanceThemeMode.self, forKey: .colorScheme)) ?? nil
        let accentColor = (try? container.decodeIfPresent(AppearanceAccentColor.self, forKey: .accentColor)) ?? nil
        let iconStyle = (try? container.decodeIfPresent(AppearancePasswordIconStyle.self, forKey: .passwordListIconStyle)) ?? nil
        let density = (try? container.decodeIfPresent(AppearanceDensity.self, forKey: .interfaceDensity)) ?? nil
        let storedPreset = (try? container.decodeIfPresent(ThemePreset.self, forKey: .themePreset)) ?? nil
        let storedCustomAccent = (try? container.decodeIfPresent(String.self, forKey: .customAccentHex)) ?? nil
        let storedIcon = (try? container.decodeIfPresent(AlternateAppIcon.self, forKey: .appIcon)) ?? nil

        let resolvedAccent = accentColor ?? Self.default.accentColor
        // v1 数据没有 themePreset：按旧强调色等义迁移，而不是重置。
        let migratedPreset = storedPreset ?? resolvedAccent.themePreset

        self.init(
            colorScheme: colorScheme ?? Self.default.colorScheme,
            accentColor: resolvedAccent,
            passwordListIconStyle: iconStyle ?? Self.default.passwordListIconStyle,
            interfaceDensity: density ?? Self.default.interfaceDensity,
            themePreset: migratedPreset,
            customAccentHex: storedCustomAccent,
            appIcon: storedIcon ?? Self.default.appIcon,
            decodedSchemaVersion: schemaVersion ?? 1
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        // 旧字段保持写入：旧版本 App / 旧备份读取路径不会被破坏。
        try container.encode(colorScheme, forKey: .colorScheme)
        try container.encode(accentColor, forKey: .accentColor)
        try container.encode(passwordListIconStyle, forKey: .passwordListIconStyle)
        try container.encode(interfaceDensity, forKey: .interfaceDensity)
        try container.encode(themePreset, forKey: .themePreset)
        try container.encodeIfPresent(customAccentHex, forKey: .customAccentHex)
        try container.encode(appIcon, forKey: .appIcon)
    }

    // MARK: - 解析

    public var customAccentColor: AppearanceColor? {
        guard let customAccentHex else { return nil }
        return AppearanceColor(hex: customAccentHex)
    }

    /// 实际生效的强调色：自定义色优先，否则用预设。
    public func effectiveAccentColor(for scheme: AppearanceResolvedColorScheme) -> AppearanceColor {
        customAccentColor ?? themePreset.accent(for: scheme)
    }

    public func palette(
        for scheme: AppearanceResolvedColorScheme,
        highContrast: Bool = false,
        reduceTransparency: Bool = false
    ) -> ThemePalette {
        ThemePalette.make(
            accent: effectiveAccentColor(for: scheme),
            scheme: scheme,
            highContrast: highContrast,
            reduceTransparency: reduceTransparency
        )
    }

    /// 自定义强调色与背景的对比度；设置页据此提示「颜色太浅」。
    public func customAccentContrast(for scheme: AppearanceResolvedColorScheme) -> Double? {
        guard let customAccentColor else { return nil }
        let palette = themePreset.palette(for: scheme)
        return customAccentColor.contrastRatio(with: palette.background)
    }

    /// 选择预设时同步旧字段，保证降级兼容。
    public mutating func selectPreset(_ preset: ThemePreset) {
        themePreset = preset
        customAccentHex = nil
        accentColor = AppearanceAccentColor(rawValue: preset.legacyAccentRawValue) ?? .monica
    }

    /// 设置自定义强调色。无效 hex 会被忽略，避免把坏值写进存储。
    @discardableResult
    public mutating func setCustomAccentHex(_ hex: String?) -> Bool {
        guard let hex else {
            customAccentHex = nil
            return true
        }
        guard let normalized = Self.normalizedHex(hex) else { return false }
        customAccentHex = normalized
        return true
    }

    public static func normalizedHex(_ hex: String?) -> String? {
        guard let hex, let color = AppearanceColor(hex: hex) else { return nil }
        return color.hexString
    }
}
