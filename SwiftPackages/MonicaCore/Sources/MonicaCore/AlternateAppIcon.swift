import Foundation

/// 备用 App 图标。
///
/// 采用 Apple 文档推荐的 asset catalog 路线：图标是 `Assets.xcassets` 里的
/// `AppIcon*.appiconset`，工程需要打开 `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS`，
/// 运行时用 `UIApplication.setAlternateIconName(_:)` 切换；`nil` 表示恢复默认图标。
///
/// 原始值就是图标集名称，必须和 asset catalog 保持一致（`standard` 是主图标，
/// 不可作为 alternate 名称传入）。
public enum AlternateAppIcon: String, Sendable, CaseIterable, Hashable, Identifiable, Codable {
    case standard = "AppIcon"
    case midnight = "AppIconMidnight"
    case aurora = "AppIconAurora"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .standard: "默认"
        case .midnight: "午夜"
        case .aurora: "极光"
        }
    }

    public var detail: String {
        switch self {
        case .standard: "薄荷绿钥匙孔"
        case .midnight: "深蓝夜色与金色钥匙孔"
        case .aurora: "墨绿极光与青绿钥匙孔"
        }
    }

    /// 传给 `UIApplication.setAlternateIconName(_:)` 的值；`nil` = 主图标。
    public var alternateIconName: String? {
        self == .standard ? nil : rawValue
    }

    /// 是否是备用图标（设置页用来决定是否显示「恢复默认」）。
    public var isAlternate: Bool { self != .standard }

    /// 系统返回的当前图标名（`nil` = 主图标）转成模型；未知名称按默认处理。
    public static func current(alternateIconName: String?) -> AlternateAppIcon {
        guard let alternateIconName,
              let icon = AlternateAppIcon(rawValue: alternateIconName),
              icon.isAlternate else {
            return .standard
        }
        return icon
    }

    /// asset catalog 里必须存在的图标集名称（单元测试用来防止重命名漏改）。
    public static var assetCatalogNames: [String] {
        allCases.map(\.rawValue)
    }
}
