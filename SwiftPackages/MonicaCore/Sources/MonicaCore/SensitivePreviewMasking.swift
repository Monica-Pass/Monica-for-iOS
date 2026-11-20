import Foundation

/// 需要掩码的敏感预览类别（#58）。
///
/// rawValue 是持久化用的稳定标识；中文标题、排序都不参与持久化。
public enum SensitivePreviewCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    /// 登录密码、Wi-Fi 密码。
    case password
    /// 验证码（TOTP 动态码）与 TOTP 密钥。
    case totp
    /// 银行卡号。
    case cardNumber
    /// 银行卡 CVV。
    case cvv
    /// 笔记正文、Send 内容。
    case noteBody
    /// 其它敏感字段：证件号、API Token、私钥引用、通行密钥标识等。
    case otherSecret

    public var id: String { rawValue }
}

/// 敏感预览的持久化偏好。
///
/// 默认（`.default`）是“全部掩码”：`revealableCategories` 为空，列表、搜索与详情里的
/// 敏感值都显示掩码；用户需要在设置里逐项允许显示。
public struct SensitivePreviewPreferences: Codable, Equatable, Sendable {
    /// 始终遮蔽：任何界面都不显示明文，详情里的“显示敏感字段”开关也失效。
    public var alwaysMask: Bool
    /// 允许临时显示明文的类别。
    public var revealableCategories: Set<SensitivePreviewCategory>

    public static let `default` = SensitivePreviewPreferences(alwaysMask: false, revealableCategories: [])

    public init(alwaysMask: Bool = false, revealableCategories: Set<SensitivePreviewCategory> = []) {
        self.alwaysMask = alwaysMask
        self.revealableCategories = revealableCategories
    }

    /// 是否必须掩码：列表/搜索预览、详情都以此为准。
    public func masks(_ category: SensitivePreviewCategory) -> Bool {
        alwaysMask || !revealableCategories.contains(category)
    }

    /// 详情里的“显示敏感字段”开关能否揭开这一类别。
    public func allowsTemporaryReveal(_ category: SensitivePreviewCategory) -> Bool {
        !masks(category)
    }

    public var hasRevealableCategories: Bool {
        !revealableCategories.isEmpty
    }

    public mutating func setRevealable(_ revealable: Bool, for category: SensitivePreviewCategory) {
        if revealable {
            revealableCategories.insert(category)
        } else {
            revealableCategories.remove(category)
        }
    }

    /// 按偏好生成预览值：需要掩码时返回占位符，否则返回原文。
    public func previewValue(
        _ value: String,
        category: SensitivePreviewCategory,
        temporarilyRevealed: Bool,
        placeholder: String = "••••••"
    ) -> String {
        if !masks(category), temporarilyRevealed {
            return value
        }
        return value.isEmpty ? value : placeholder
    }
}

/// 单次解锁会话内的“临时显示”状态。
///
/// 只放在 `AppSessionModel` 的内存里：锁库立即调用 `reset()`，App 重启后自然为空，
/// 不会写进任何持久化存储。
public struct SensitivePreviewSession: Equatable, Sendable {
    public private(set) var revealedEntryIDs: Set<String>

    public init() {
        revealedEntryIDs = []
    }

    public func isRevealed(entryID: String) -> Bool {
        revealedEntryIDs.contains(entryID)
    }

    public mutating func setRevealed(_ revealed: Bool, forEntryID entryID: String) {
        if revealed {
            revealedEntryIDs.insert(entryID)
        } else {
            revealedEntryIDs.remove(entryID)
        }
    }

    public mutating func reset() {
        revealedEntryIDs.removeAll(keepingCapacity: false)
    }

    public var isEmpty: Bool {
        revealedEntryIDs.isEmpty
    }
}

/// 敏感预览偏好的持久化存储。只保存开关，不保存任何条目内容。
public protocol SensitivePreviewPreferenceStore: Sendable {
    func loadPreferences() -> SensitivePreviewPreferences
    func savePreferences(_ preferences: SensitivePreviewPreferences)
}

public final class MemorySensitivePreviewPreferenceStore: SensitivePreviewPreferenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var preferences: SensitivePreviewPreferences

    public init(preferences: SensitivePreviewPreferences = .default) {
        self.preferences = preferences
    }

    public func loadPreferences() -> SensitivePreviewPreferences {
        lock.lock()
        defer { lock.unlock() }
        return preferences
    }

    public func savePreferences(_ preferences: SensitivePreviewPreferences) {
        lock.lock()
        defer { lock.unlock() }
        self.preferences = preferences
    }
}

public final class UserDefaultsSensitivePreviewPreferenceStore: SensitivePreviewPreferenceStore, @unchecked Sendable {
    public static let userDefaultsKey = "monica.sensitivePreviewPreferences"

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func loadPreferences() -> SensitivePreviewPreferences {
        guard let data = userDefaults.data(forKey: Self.userDefaultsKey),
              let preferences = try? JSONDecoder().decode(SensitivePreviewPreferences.self, from: data)
        else {
            return .default
        }
        return preferences
    }

    public func savePreferences(_ preferences: SensitivePreviewPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else {
            return
        }
        userDefaults.set(data, forKey: Self.userDefaultsKey)
    }
}
