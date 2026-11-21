import MonicaCore
import SwiftUI
import UIKit

// 主题 / 配色 / 图标模型已经下沉到 MonicaCore（可被 swift test 覆盖）。
// 这里用 typealias + SwiftUI 扩展保留 App 侧原有名字与语义，避免大范围改动
// AppRootView / SettingsRootView 的调用点。

typealias AppAppearanceColorScheme = AppearanceThemeMode
typealias AppAppearanceAccentColor = AppearanceAccentColor
typealias AppPasswordListIconStyle = AppearancePasswordIconStyle
typealias AppInterfaceDensity = AppearanceDensity
typealias AppAppearancePreferences = AppearancePreferences

extension AppearanceThemeMode {
    var label: String {
        switch self {
        case .system: String(localized: "跟随系统")
        case .light: String(localized: "浅色")
        case .dark: String(localized: "深色")
        }
    }

    var swiftUIColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension AppearanceAccentColor {
    var label: String {
        switch self {
        case .monica: "Monica"
        case .green: String(localized: "绿色")
        case .blue: String(localized: "蓝色")
        case .orange: String(localized: "橙色")
        }
    }

    /// 旧字段的颜色。保留旧语义（含测试里 `swiftUIAccentColor == .blue` 的断言），
    /// 新 UI 请使用 `AppearancePreferences.themeAccentColor`。
    var swiftUIColor: Color {
        switch self {
        case .monica: AndroidParityPalette.primary
        case .green: .green
        case .blue: .blue
        case .orange: .orange
        }
    }
}

extension AppearancePasswordIconStyle {
    var label: String {
        switch self {
        case .color: String(localized: "彩色")
        case .monochrome: String(localized: "单色")
        case .hidden: String(localized: "隐藏")
        }
    }
}

extension AppearanceDensity {
    var label: String {
        switch self {
        case .default: String(localized: "默认")
        case .compact: String(localized: "紧凑")
        case .loose: String(localized: "宽松")
        }
    }

    var detail: String {
        switch self {
        case .default: String(localized: "标准间距与行高。")
        case .compact: String(localized: "收紧间距与行高，一屏显示更多内容。")
        case .loose: String(localized: "放宽间距与行高，内容更疏朗易读。")
        }
    }
}

extension AppearanceColor {
    var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

extension AppearancePreferences {
    var swiftUIColorScheme: ColorScheme? {
        colorScheme.swiftUIColorScheme
    }

    /// 旧「强调色」字段对应的颜色。仅用于兼容旧存储与旧测试。
    var swiftUIAccentColor: Color {
        accentColor.swiftUIColor
    }

    /// 当前主题实际使用的强调色（自定义色优先，其次预设），随深浅色切换。
    var themeAccentColor: Color {
        Color(UIColor { traits in
            AppThemeRuntime.shared.palette(for: traits).accent.uiColor
        })
    }

    var showsPasswordListIcon: Bool {
        passwordListIconStyle != .hidden
    }

    var passwordListIconFill: Color {
        switch passwordListIconStyle {
        case .color: AndroidParityPalette.primaryContainer
        case .monochrome: AndroidParityPalette.surface
        case .hidden: .clear
        }
    }

    var passwordListIconTint: Color {
        switch passwordListIconStyle {
        case .color: AndroidParityPalette.primary
        case .monochrome: AndroidParityPalette.textSecondary
        case .hidden: .clear
        }
    }
}

/// 条目图标的读取规则：先按稳定资源 ID 解析，旧版/外部导入的值再做一次迁移，
/// 仍然无法识别时回退到条目类型的默认符号。渲染层只依赖这个入口。
enum AppItemIconResolver {
    static func icon(storedValue: String?, defaultKind: String = "login") -> ItemIcon? {
        guard let storedValue, !storedValue.isEmpty else { return nil }
        if let icon = ItemIcon(storageValue: storedValue) {
            return icon
        }
        return ItemIcon.migrated(fromLegacy: storedValue)
    }

    static func symbol(storedValue: String?, defaultKind: String = "login") -> String {
        icon(storedValue: storedValue, defaultKind: defaultKind)?.resolvedSystemName
            ?? ItemIcon.defaultSymbol(forKind: defaultKind)
    }
}

/// 主题运行时快照。
///
/// `AndroidParityPalette` 的 400+ 个调用点用的是静态属性，无法逐个注入环境值，
/// 因此这里保存一份加锁的偏好快照，供 `Color(UIColor { traits in … })` 动态解析：
/// 深浅色、增强对比度来自 `UITraitCollection`，主题预设 / 自定义强调色来自快照。
/// 颜色在渲染时解析，所以切换主题后已创建的 `Color` 也会立即更新。
final class AppThemeRuntime: @unchecked Sendable {
    static let shared = AppThemeRuntime()

    private let lock = NSLock()
    private var preferences = AppearancePreferences.default
    private var reduceTransparency = false

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAccessibilitySettings()
        }
        refreshAccessibilitySettings()
    }

    func update(_ preferences: AppearancePreferences) {
        lock.lock()
        self.preferences = preferences
        lock.unlock()
    }

    func refreshAccessibilitySettings() {
        // `UIAccessibility` 是 MainActor 隔离的；观察者与 App 启动都在主线程，
        // 但仍显式断言，避免在其他线程误读造成崩溃。
        guard Thread.isMainThread else { return }
        let value = MainActor.assumeIsolated { UIAccessibility.isReduceTransparencyEnabled }
        lock.lock()
        reduceTransparency = value
        lock.unlock()
    }

    func currentPreferences() -> AppearancePreferences {
        lock.lock()
        defer { lock.unlock() }
        return preferences
    }

    func palette(for traits: UITraitCollection) -> ThemePalette {
        let resolved: AppearanceResolvedColorScheme = traits.userInterfaceStyle == .light ? .light : .dark
        lock.lock()
        let preferences = preferences
        let reduceTransparency = reduceTransparency
        lock.unlock()
        return preferences.palette(
            for: resolved,
            highContrast: traits.accessibilityContrast == .high,
            reduceTransparency: reduceTransparency
        )
    }
}
