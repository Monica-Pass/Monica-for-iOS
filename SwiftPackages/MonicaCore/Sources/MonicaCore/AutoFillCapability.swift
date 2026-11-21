import Foundation

/// iOS 自动填充能力矩阵（#39）。
///
/// 这份矩阵只描述 Apple 公开 API 的边界，不描述 Android 侧的无障碍注入能力：
/// - 第三方 Credential Provider 只能实现 `ASCredentialProviderViewController`，
///   由系统在它识别的用户名 / 密码输入框里调用；
/// - 扩展没有无障碍服务，不能读取其它 App 的界面，不能监听任意输入框，
///   也不能注入内联建议面板或键盘；
/// - 系统键盘上的 QuickType / 强密码建议由 iOS 决定，第三方无法强制它出现，
///   也无法保证某一条建议一定来自 Monica。
///
/// 对应文档：`docs/AUTOFILL_CAPABILITY_MATRIX.md`。新增能力时先改这里，
/// 再同步文档与 `AppAutoFillCapabilityCopy` 的界面文案，测试会校验两边覆盖一致。
public struct AutoFillCapability: Identifiable, Equatable, Sendable {
    /// 能力在 iOS 公开 API 边界内的可用性。
    public enum Availability: String, CaseIterable, Sendable {
        /// Monica 可以通过公开 API 做到。
        case supported
        /// 结果由 iOS 决定，Monica 只能提供数据，不能控制时机或位置。
        case systemDecided
        /// 公开 API 不支持，Monica 不会实现。
        case unsupported
    }

    public let id: String
    public let availability: Availability
    /// 是否进入 App 内能力矩阵的高亮列表（完整矩阵仍保留在本类型里）。
    public let isHighlighted: Bool

    public init(id: String, availability: Availability, isHighlighted: Bool = false) {
        self.id = id
        self.availability = availability
        self.isHighlighted = isHighlighted
    }
}

extension AutoFillCapability {
    public static let credentialProvider = AutoFillCapability(
        id: "credential-provider",
        availability: .supported
    )
    public static let systemQuickType = AutoFillCapability(
        id: "system-quicktype",
        availability: .systemDecided,
        isHighlighted: true
    )
    public static let arbitraryFieldScan = AutoFillCapability(
        id: "arbitrary-field-scan",
        availability: .unsupported,
        isHighlighted: true
    )
    public static let inlineSuggestionPanel = AutoFillCapability(
        id: "inline-suggestion-panel",
        availability: .unsupported,
        isHighlighted: true
    )
    public static let strongPasswordSuggestion = AutoFillCapability(
        id: "strong-password-suggestion",
        availability: .unsupported,
        isHighlighted: true
    )
    public static let readDefaultManager = AutoFillCapability(
        id: "read-default-manager",
        availability: .unsupported
    )
    public static let defaultManagerSelection = AutoFillCapability(
        id: "default-manager-selection",
        availability: .systemDecided
    )
    public static let openAppSettings = AutoFillCapability(
        id: "open-app-settings",
        availability: .supported
    )
    public static let openPasswordSettings = AutoFillCapability(
        id: "open-password-settings",
        availability: .unsupported
    )
    public static let inAppGenerator = AutoFillCapability(
        id: "in-app-generator",
        availability: .supported,
        isHighlighted: true
    )
    public static let saveGeneratedLogin = AutoFillCapability(
        id: "save-generated-login",
        availability: .supported
    )

    /// 完整矩阵。顺序稳定，便于文档与测试逐项核对。
    public static let matrix: [AutoFillCapability] = [
        .credentialProvider,
        .systemQuickType,
        .arbitraryFieldScan,
        .inlineSuggestionPanel,
        .strongPasswordSuggestion,
        .readDefaultManager,
        .defaultManagerSelection,
        .openAppSettings,
        .openPasswordSettings,
        .inAppGenerator,
        .saveGeneratedLogin
    ]

    /// App 内引导页展示的高亮能力，避免把完整矩阵堆进一屏。
    public static var highlighted: [AutoFillCapability] {
        matrix.filter(\.isHighlighted)
    }
}

/// 自动填充引导文案的护栏。
///
/// 产品红线：不能承诺「系统一定会在所有输入框里显示 Monica 的建议」。
/// 这个护栏只做关键词判断，用于测试和 review，不替代人工判断。
public enum AutoFillCapabilityCopyGuard {
    /// 已知的过度承诺表达。匹配时统一转小写，英文也覆盖。
    public static let overpromisingPhrases: [String] = [
        "保证可填充",
        "保证填充",
        "保证能填",
        "保证可以填充",
        "确保可填充",
        "确保能填充",
        "一定可以填充",
        "一定能填充",
        "所有输入框都能",
        "所有输入框都可以",
        "任意输入框都能",
        "任意输入框都可以",
        "任意字段都能",
        "任意字段都可以",
        "自动填充任意",
        "guaranteed to fill",
        "guarantee fill",
        "fill any field",
        "fill any input",
        "every input field",
        "all input fields"
    ]

    /// 文本是否包含过度承诺表达。
    public static func isOverpromising(_ text: String) -> Bool {
        firstOverpromisingPhrase(in: [text]) != nil
    }

    /// 返回第一处命中的过度承诺表达；没有命中返回 `nil`。
    public static func firstOverpromisingPhrase(in texts: [String]) -> String? {
        let lowered = texts.map { $0.lowercased() }
        for phrase in overpromisingPhrases where lowered.contains(where: { $0.contains(phrase.lowercased()) }) {
            return phrase
        }
        return nil
    }
}
