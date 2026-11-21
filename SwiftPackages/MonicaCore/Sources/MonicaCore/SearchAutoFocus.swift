import CoreFoundation
import Foundation

/// 启动时自动聚焦搜索框的决策上下文。
///
/// 这是纯数据模型：不读取全局状态、不依赖 UIKit / SwiftUI，
/// 因此可以在单元测试里直接构造各种组合，验证「什么时候该聚焦」。
public struct SearchAutoFocusContext: Sendable, Equatable {
    /// 设置项是否开启（默认关闭）。
    public var isEnabled: Bool
    /// 保险库是否已经解锁。锁定态绝不聚焦，否则键盘会遮挡锁屏。
    public var isVaultUnlocked: Bool
    /// 当前是否停在密码首页（自动聚焦只针对密码页）。
    public var isPasswordPage: Bool
    /// 是否有待处理的深链 / 控制中心 / 快捷指令目标。被导航覆盖时不抢焦点。
    public var hasPendingNavigationTarget: Bool
    /// 当前尺寸类别是否允许主动弹出键盘（iPad 分屏与大屏不强制）。
    public var allowsForcedKeyboard: Bool
    /// 本次启动是否已经结算过自动聚焦（只聚焦一次，避免反复抢焦点）。
    public var hasAlreadyHandledLaunch: Bool

    public init(
        isEnabled: Bool = false,
        isVaultUnlocked: Bool = false,
        isPasswordPage: Bool = true,
        hasPendingNavigationTarget: Bool = false,
        allowsForcedKeyboard: Bool = true,
        hasAlreadyHandledLaunch: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.isVaultUnlocked = isVaultUnlocked
        self.isPasswordPage = isPasswordPage
        self.hasPendingNavigationTarget = hasPendingNavigationTarget
        self.allowsForcedKeyboard = allowsForcedKeyboard
        self.hasAlreadyHandledLaunch = hasAlreadyHandledLaunch
    }
}

/// 启动自动聚焦的纯决策。
public enum SearchAutoFocusPolicy {
    /// 是否应该在启动进入密码页时自动聚焦搜索框。
    ///
    /// 只有六个条件同时满足才聚焦：设置开启、已解锁、在密码页、
    /// 没有被导航目标覆盖、尺寸类别允许弹出键盘、本次启动尚未结算过。
    public static func shouldFocusOnLaunch(_ context: SearchAutoFocusContext) -> Bool {
        context.isEnabled
            && context.isVaultUnlocked
            && context.isPasswordPage
            && !context.hasPendingNavigationTarget
            && context.allowsForcedKeyboard
            && !context.hasAlreadyHandledLaunch
    }
}

/// 「启动时自动聚焦搜索框」设置项的持久化约定。
public enum SearchAutoFocusPreference {
    /// UserDefaults 键名，与 Android 端的启动自动聚焦设置对应。
    public static let userDefaultsKey = "monica.autofocusSearchOnLaunch"

    /// 只有真正的布尔值才算开启；缺失、字符串、数字等非法值一律回退为关闭。
    public static func isEnabled(persistedValue: Any?) -> Bool {
        guard let number = persistedValue as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return false
        }
        return number.boolValue
    }
}
