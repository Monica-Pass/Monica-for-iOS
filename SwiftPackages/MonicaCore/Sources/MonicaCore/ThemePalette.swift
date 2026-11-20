import Foundation

/// 解析后的颜色方案。`system` 由 App 层按系统外观落到 light / dark。
public enum AppearanceResolvedColorScheme: String, Sendable, CaseIterable, Hashable, Codable {
    case light
    case dark

    public var isDark: Bool { self == .dark }
}

/// 一套主题在某个颜色方案下解析出的具体颜色。
///
/// 所有值都是不透明 sRGB 颜色：旧界面里的半透明硬编码底色在浅色模式下会糊成一片，
/// 这里统一用实色，透明度只保留给 `outline` 这类装饰。
public struct ThemePalette: Hashable, Sendable {
    public let scheme: AppearanceResolvedColorScheme
    public let background: AppearanceColor
    public let surface: AppearanceColor
    public let surfaceVariant: AppearanceColor
    public let surfaceElevated: AppearanceColor
    public let textPrimary: AppearanceColor
    public let textSecondary: AppearanceColor
    public let textTertiary: AppearanceColor
    public let accent: AppearanceColor
    public let accentContainer: AppearanceColor
    public let onAccent: AppearanceColor
    public let onAccentContainer: AppearanceColor
    public let outline: AppearanceColor
    public let danger: AppearanceColor
    public let isHighContrast: Bool
    public let isReduceTransparency: Bool

    public var isDark: Bool { scheme.isDark }

    /// 该主题下正文与背景的对比度，供测试和设置页展示。
    public var primaryTextContrast: Double {
        textPrimary.contrastRatio(with: background)
    }

    /// 强调色作为文字/图标直接压在背景上的对比度。
    public var accentContrast: Double {
        accent.contrastRatio(with: background)
    }
}

/// 命名主题预设。原始值是不可翻译的稳定标识符，会被写进 `UserDefaults` / 备份，
/// 因此任何重命名都必须保留旧 raw value 的解码路径（见 `AppearancePreferences`）。
public enum ThemePreset: String, Sendable, CaseIterable, Hashable, Identifiable, Codable {
    case monica
    case forest
    case ocean
    case sunset
    case grape
    case amber
    case rose
    case graphite
    case indigo

    public var id: String { rawValue }

    /// 设置页展示名。名称可以随文案调整，raw value 不可以。
    public var displayName: String {
        switch self {
        case .monica: "Monica"
        case .forest: "森林"
        case .ocean: "海洋"
        case .sunset: "落日"
        case .grape: "葡萄"
        case .amber: "琥珀"
        case .rose: "玫瑰"
        case .graphite: "石墨"
        case .indigo: "靛蓝"
        }
    }

    /// 预设说明，用于设置页副标题。
    public var detail: String {
        switch self {
        case .monica: "品牌薄荷绿，默认主题"
        case .forest: "克制的松柏绿"
        case .ocean: "清晰的深海蓝"
        case .sunset: "温暖的落日橙"
        case .grape: "低饱和的葡萄紫"
        case .amber: "琥珀金，适合暖色环境"
        case .rose: "柔和的玫瑰红"
        case .graphite: "中性石墨灰，接近系统外观"
        case .indigo: "沉静的靛蓝"
        }
    }

    /// 预览用强调色（跟随系统外观时由 App 层决定用哪一个）。
    public var accentLight: AppearanceColor {
        switch self {
        case .monica: AppearanceColor(hex: "#0E6F62")!
        case .forest: AppearanceColor(hex: "#2F6B36")!
        case .ocean: AppearanceColor(hex: "#1B5FA8")!
        case .sunset: AppearanceColor(hex: "#A34A18")!
        case .grape: AppearanceColor(hex: "#6A3FA0")!
        case .amber: AppearanceColor(hex: "#7A5200")!
        case .rose: AppearanceColor(hex: "#A22A55")!
        case .graphite: AppearanceColor(hex: "#3E4644")!
        case .indigo: AppearanceColor(hex: "#3A459E")!
        }
    }

    public var accentDark: AppearanceColor {
        switch self {
        case .monica: AppearanceColor(hex: "#86DCCB")!
        case .forest: AppearanceColor(hex: "#A5D6A7")!
        case .ocean: AppearanceColor(hex: "#93C9FF")!
        case .sunset: AppearanceColor(hex: "#FFB68A")!
        case .grape: AppearanceColor(hex: "#C9AEFF")!
        case .amber: AppearanceColor(hex: "#F3C96B")!
        case .rose: AppearanceColor(hex: "#FFADC4")!
        case .graphite: AppearanceColor(hex: "#C9D3CF")!
        case .indigo: AppearanceColor(hex: "#B3BEFF")!
        }
    }

    public func accent(for scheme: AppearanceResolvedColorScheme) -> AppearanceColor {
        scheme.isDark ? accentDark : accentLight
    }

    /// 旧版四种强调色到预设的迁移映射。
    ///
    /// 旧字段 `accentColor` 仍然会被解码并写回，保证降级到旧版本时颜色不变；
    /// 新版本用预设表达同一意图，因此迁移是「等义映射」，不是重置。
    public static func migrated(fromLegacyAccent rawValue: String) -> ThemePreset {
        switch rawValue.lowercased() {
        case "monica": .monica
        case "green": .forest
        case "blue": .ocean
        case "orange": .sunset
        default: .monica
        }
    }

    /// 兼容旧版 `AppAppearanceAccentColor` 的映射，用于把预设写回旧字段。
    public var legacyAccentRawValue: String {
        switch self {
        case .monica: "monica"
        case .forest: "green"
        case .ocean: "blue"
        case .sunset: "orange"
        case .grape, .amber, .rose, .graphite, .indigo: "monica"
        }
    }

    public func palette(
        for scheme: AppearanceResolvedColorScheme,
        highContrast: Bool = false,
        reduceTransparency: Bool = false
    ) -> ThemePalette {
        ThemePalette.make(
            accent: accent(for: scheme),
            scheme: scheme,
            highContrast: highContrast,
            reduceTransparency: reduceTransparency
        )
    }
}

extension ThemePalette {
    /// 用给定强调色构造调色板。自定义强调色和预设共用同一套对比度规则。
    public static func make(
        accent: AppearanceColor,
        scheme: AppearanceResolvedColorScheme,
        highContrast: Bool = false,
        reduceTransparency: Bool = false
    ) -> ThemePalette {
        let baseText = scheme.isDark
            ? (highContrast ? AppearanceColor(hex: "#FFFFFF")! : AppearanceColor(hex: "#F1F5F3")!)
            : (highContrast ? AppearanceColor(hex: "#000000")! : AppearanceColor(hex: "#0F1412")!)
        let secondaryText = scheme.isDark
            ? (highContrast ? AppearanceColor(hex: "#E7EEE9")! : AppearanceColor(hex: "#B6C0BB")!)
            : (highContrast ? AppearanceColor(hex: "#16201B")! : AppearanceColor(hex: "#4B5550")!)
        let tertiaryText = scheme.isDark
            ? (highContrast ? AppearanceColor(hex: "#D6E0DA")! : AppearanceColor(hex: "#8C9791")!)
            : (highContrast ? AppearanceColor(hex: "#243029")! : AppearanceColor(hex: "#6C7671")!)
        let background = scheme.isDark
            ? AppearanceColor(hex: highContrast ? "#000000" : "#0B0D0C")!
            : AppearanceColor(hex: highContrast ? "#FFFFFF" : "#F3F5F4")!
        let surface = scheme.isDark
            ? AppearanceColor(hex: highContrast ? "#0A0C0B" : "#141716")!
            : AppearanceColor(hex: highContrast ? "#FFFFFF" : "#FFFFFF")!
        let surfaceVariant = scheme.isDark
            ? accent.blended(with: AppearanceColor(hex: "#101312")!, amount: 0.84)
            : accent.blended(with: .snow, amount: 0.90)
        let surfaceElevated = scheme.isDark
            ? surface.blended(with: accent, amount: 0.06)
            : surface
        let accentContainer = scheme.isDark
            ? accent.blended(with: AppearanceColor(hex: "#0B0D0C")!, amount: 0.72)
            : accent.blended(with: .snow, amount: 0.86)
        let onAccentContainer = scheme.isDark
            ? (highContrast ? AppearanceColor(hex: "#FFFFFF")! : baseText)
            : (highContrast ? AppearanceColor(hex: "#000000")! : baseText)
        let outline = scheme.isDark
            ? AppearanceColor(hex: "#FFFFFF")!.withAlpha(highContrast ? 0.42 : 0.16)
            : AppearanceColor(hex: "#0F1412")!.withAlpha(highContrast ? 0.46 : 0.16)
        let danger = scheme.isDark
            ? AppearanceColor(hex: "#FFB4AB")!
            : AppearanceColor(hex: "#B3261E")!

        return ThemePalette(
            scheme: scheme,
            background: background,
            surface: surface,
            surfaceVariant: surfaceVariant,
            surfaceElevated: surfaceElevated,
            textPrimary: baseText,
            textSecondary: secondaryText,
            textTertiary: tertiaryText,
            accent: accent,
            accentContainer: accentContainer,
            onAccent: accent.preferredForeground(),
            onAccentContainer: onAccentContainer,
            outline: outline,
            danger: danger,
            isHighContrast: highContrast,
            isReduceTransparency: reduceTransparency
        )
    }
}
