import Foundation

/// 触感反馈的语义类别（#147）。
///
/// 这里只描述「为什么震」，具体用哪种 `UIFeedbackGenerator` 由 App 层映射，
/// 这样策略（开关、降级）可以被单元测试覆盖，而不需要真实设备。
public enum HapticEventKind: String, CaseIterable, Sendable {
    /// 保存、复制等成功动作。
    case success
    /// 删除、失败等否定结果。
    case error
    /// 切换筛选、选择分段等轻量选择。
    case selection
    /// 验证码周期性轻震（可被子开关单独关闭）。
    case verificationTick
}

/// 触感反馈设置。
public struct HapticsPreferences: Equatable, Sendable {
    /// 总开关：关闭后 App 内不应出现任何触感调用。
    public var isEnabled: Bool
    /// 验证码卡片轻震子开关：只在总开关开启时才有意义。
    public var isVerificationEnabled: Bool

    public static let `default` = HapticsPreferences()

    public init(isEnabled: Bool = true, isVerificationEnabled: Bool = true) {
        self.isEnabled = isEnabled
        self.isVerificationEnabled = isVerificationEnabled
    }
}

/// 触感决策策略：集中回答「这个事件现在该不该震」。
public struct HapticsPolicy: Equatable, Sendable {
    public var preferences: HapticsPreferences

    public init(preferences: HapticsPreferences) {
        self.preferences = preferences
    }

    public func shouldPlay(_ kind: HapticEventKind) -> Bool {
        guard preferences.isEnabled else {
            return false
        }
        switch kind {
        case .success, .error, .selection:
            return true
        case .verificationTick:
            return preferences.isVerificationEnabled
        }
    }
}

public enum HapticsPreferenceKeys {
    public static let isEnabled = "monica.haptics.enabled"
    public static let isVerificationEnabled = "monica.haptics.verificationEnabled"
}

public protocol HapticsPreferencesStoring: Sendable {
    func load() -> HapticsPreferences
    func save(_ preferences: HapticsPreferences)
}

/// `UserDefaults` 实现：键不存在时按默认值（开启）处理。
public struct UserDefaultsHapticsPreferencesStore: HapticsPreferencesStoring, @unchecked Sendable {
    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func load() -> HapticsPreferences {
        var preferences = HapticsPreferences.default
        if let stored = userDefaults.object(forKey: HapticsPreferenceKeys.isEnabled) as? Bool {
            preferences.isEnabled = stored
        }
        if let stored = userDefaults.object(forKey: HapticsPreferenceKeys.isVerificationEnabled) as? Bool {
            preferences.isVerificationEnabled = stored
        }
        return preferences
    }

    public func save(_ preferences: HapticsPreferences) {
        userDefaults.set(preferences.isEnabled, forKey: HapticsPreferenceKeys.isEnabled)
        userDefaults.set(preferences.isVerificationEnabled, forKey: HapticsPreferenceKeys.isVerificationEnabled)
    }
}

/// 测试与预览用的内存存储。
public final class MemoryHapticsPreferencesStore: HapticsPreferencesStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var preferences: HapticsPreferences

    public init(preferences: HapticsPreferences = .default) {
        self.preferences = preferences
    }

    public func load() -> HapticsPreferences {
        lock.lock()
        defer { lock.unlock() }
        return preferences
    }

    public func save(_ preferences: HapticsPreferences) {
        lock.lock()
        defer { lock.unlock() }
        self.preferences = preferences
    }
}
