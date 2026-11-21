import Foundation

/// 场景（scene）的可见阶段。
///
/// App 层把 SwiftUI `ScenePhase` 映射到这里，让「是否遮罩 / 是否锁定会话」的
/// 决策可以脱离 UI 框架单独测试。
public enum ScreenPrivacyPhase: Sendable, Hashable, CaseIterable {
    case active
    case inactive
    case background
}

/// 一次场景切换后需要执行的隐私动作。
public struct ScreenPrivacyDecision: Sendable, Hashable {
    /// 是否立即用不含任何 Vault 数据的中性遮罩覆盖界面。
    public let showsShield: Bool
    /// 是否关闭当前 Vault 会话（仅后台阶段）。
    public let locksVault: Bool

    public init(showsShield: Bool, locksVault: Bool) {
        self.showsShield = showsShield
        self.locksVault = locksVault
    }
}

public enum ScreenPrivacyPolicy {
    /// 非 active 阶段一律立即遮罩：
    /// - `.inactive` 是 App Switcher 手势、来电、控制中心的第一步，系统快照可能
    ///   在进入 `.background` 之前就已经生成，所以不能等到后台才遮；
    /// - `.background` 时即使 Vault 已经锁定也要遮罩，因为锁屏上仍可能保留主密码
    ///   输入框等用户可见内容。
    ///
    /// 真正的会话锁定只发生在 `.background`，避免 `.inactive`（例如系统弹窗、
    /// 来电）把正在使用的会话丢掉。
    public static func decision(
        for phase: ScreenPrivacyPhase,
        isVaultUnlocked: Bool
    ) -> ScreenPrivacyDecision {
        switch phase {
        case .active:
            return ScreenPrivacyDecision(showsShield: false, locksVault: false)
        case .inactive:
            return ScreenPrivacyDecision(showsShield: true, locksVault: false)
        case .background:
            return ScreenPrivacyDecision(showsShield: true, locksVault: isVaultUnlocked)
        }
    }
}

/// 录屏 / 屏幕共享期间对高敏字段的强制掩码规则。
///
/// 「正在被录制或共享」优先于用户手动打开的「显示敏感字段」；录制结束后结果
/// 自动回落到用户自己的开关，因此不需要改写用户的设置就能恢复原状。
public enum SensitiveFieldMaskingPolicy {
    public static func isMasked(
        isSceneCaptured: Bool,
        userRequestedReveal: Bool
    ) -> Bool {
        isSceneCaptured || !userRequestedReveal
    }
}
