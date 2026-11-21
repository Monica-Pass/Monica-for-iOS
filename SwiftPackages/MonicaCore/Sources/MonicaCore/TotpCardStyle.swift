import Foundation

/// 验证码卡片进度条样式。
///
/// raw value 同时是写入 Widget 快照的稳定字符串（`MonicaWidgetTotpProgressStyle`
/// 的 rawValue 与之逐一对应），不要修改已有取值。
public enum TotpProgressStyle: String, Sendable, CaseIterable, Hashable, Identifiable, Codable {
    /// 线性进度条（旧版本唯一形态，也是默认值）。
    case linear
    /// 环形进度条。
    case circular

    public var id: String { rawValue }
}

/// 验证码卡片进度条偏好。
///
/// 编码策略与 `AppearancePreferences` 一致：逐字段容错解码，缺失、类型错误或未知
/// 枚举值都回落到默认值，不会因为旧版本 / 新版本多出一个字段就把用户设置重置。
public struct TotpProgressPreferences: Sendable, Equatable, Codable {
    /// 默认值：统一进度条关闭、线性样式、平滑动画开启。
    ///
    /// 关闭统一进度条是刻意的：这样升级上来的用户外观与旧版本完全一致。
    public static let `default` = TotpProgressPreferences()

    /// 统一进度条：所有标准周期（30 秒）卡片共用同一周期。默认关闭。
    public var usesUnifiedProgressBar: Bool
    /// 进度条样式。默认线性。
    public var style: TotpProgressStyle
    /// 平滑动画：每秒在旧值与新值之间线性插值。默认开启；
    /// 系统「减弱动态效果」开启时由 `TotpCardStylePolicy` 强制关闭。
    public var usesSmoothAnimation: Bool

    public init(
        usesUnifiedProgressBar: Bool = false,
        style: TotpProgressStyle = .linear,
        usesSmoothAnimation: Bool = true
    ) {
        self.usesUnifiedProgressBar = usesUnifiedProgressBar
        self.style = style
        self.usesSmoothAnimation = usesSmoothAnimation
    }

    private enum CodingKeys: String, CodingKey {
        case usesUnifiedProgressBar
        case style
        case usesSmoothAnimation
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = TotpProgressPreferences.default
        usesUnifiedProgressBar = (try? container.decodeIfPresent(Bool.self, forKey: .usesUnifiedProgressBar))
            .flatMap { $0 } ?? fallback.usesUnifiedProgressBar
        usesSmoothAnimation = (try? container.decodeIfPresent(Bool.self, forKey: .usesSmoothAnimation))
            .flatMap { $0 } ?? fallback.usesSmoothAnimation
        if let raw = try? container.decodeIfPresent(String.self, forKey: .style),
           let decoded = TotpProgressStyle(rawValue: raw) {
            style = decoded
        } else {
            style = fallback.style
        }
    }
}

/// UserDefaults 键。
///
/// 三个设置分键存储而不是写一个 JSON blob：某个键损坏时只回落一项，不会整组重置。
public enum TotpProgressPreferenceKey {
    public static let style = "monica.totpProgress.style"
    public static let unifiedProgressBar = "monica.totpProgress.unified"
    public static let smoothAnimation = "monica.totpProgress.smoothAnimation"
}

/// 进度条偏好的持久化抽象。测试用内存实现，生产环境用 UserDefaults。
public protocol TotpProgressPreferenceStore: Sendable {
    func loadPreferences() -> TotpProgressPreferences
    func savePreferences(_ preferences: TotpProgressPreferences)
}

/// UserDefaults 实现。
///
/// `UserDefaults` 本身没有标注 `Sendable`（Foundation 未采纳并发标注），这里只在初始化
/// 时捕获实例，每次读写都走 `UserDefaults` 自身的线程安全 API，并且不缓存任何可变状态，
/// 因此用 `@unchecked Sendable` 声明——和仓库里其它偏好存储一致。
public final class UserDefaultsTotpProgressPreferenceStore: TotpProgressPreferenceStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadPreferences() -> TotpProgressPreferences {
        var preferences = TotpProgressPreferences.default
        if let raw = defaults.string(forKey: TotpProgressPreferenceKey.style),
           let style = TotpProgressStyle(rawValue: raw) {
            preferences.style = style
        }
        if let unified = defaults.object(forKey: TotpProgressPreferenceKey.unifiedProgressBar) as? NSNumber {
            preferences.usesUnifiedProgressBar = unified.boolValue
        }
        if let smooth = defaults.object(forKey: TotpProgressPreferenceKey.smoothAnimation) as? NSNumber {
            preferences.usesSmoothAnimation = smooth.boolValue
        }
        return preferences
    }

    public func savePreferences(_ preferences: TotpProgressPreferences) {
        defaults.set(preferences.style.rawValue, forKey: TotpProgressPreferenceKey.style)
        defaults.set(preferences.usesUnifiedProgressBar, forKey: TotpProgressPreferenceKey.unifiedProgressBar)
        defaults.set(preferences.usesSmoothAnimation, forKey: TotpProgressPreferenceKey.smoothAnimation)
    }
}

/// 内存实现：预览、测试与未接入持久化的 `AppSessionModel` 默认值使用。
public final class MemoryTotpProgressPreferenceStore: TotpProgressPreferenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var preferences: TotpProgressPreferences

    public init(preferences: TotpProgressPreferences = .default) {
        self.preferences = preferences
    }

    public func loadPreferences() -> TotpProgressPreferences {
        lock.withLock { preferences }
    }

    public func savePreferences(_ preferences: TotpProgressPreferences) {
        lock.withLock { self.preferences = preferences }
    }
}

/// 把「用户偏好 + 系统减弱动态效果」解析成卡片实际渲染用的规则。
///
/// 视图层只依赖这个类型，不直接读 UserDefaults / 环境值，方便单元测试。
public struct TotpCardStylePolicy: Sendable, Equatable {
    /// 统一进度条接管的标准周期（秒）。
    public static let unifiedPeriod: Int = 30

    public let preferences: TotpProgressPreferences
    /// 系统「减弱动态效果」是否开启。
    public let reduceMotion: Bool

    public init(preferences: TotpProgressPreferences, reduceMotion: Bool) {
        self.preferences = preferences
        self.reduceMotion = reduceMotion
    }

    public var style: TotpProgressStyle { preferences.style }

    public var usesUnifiedProgressBar: Bool { preferences.usesUnifiedProgressBar }

    /// 「减弱动态效果」开启时强制关闭平滑动画：系统级无障碍约定优先于用户偏好。
    public var isSmoothAnimationEnabled: Bool {
        preferences.usesSmoothAnimation && !reduceMotion
    }

    /// 单张卡片实际使用的周期。
    ///
    /// 统一进度条只接管标准 30 秒周期；60 秒与自定义周期保持自身周期，否则进度条会在
    /// 验证码还没刷新时归零。HOTP（计数器）卡片没有周期概念，由调用方自行跳过。
    public func period(forEntryPeriod entryPeriod: Int) -> Int {
        let resolved = max(entryPeriod, 1)
        guard preferences.usesUnifiedProgressBar, resolved == Self.unifiedPeriod else { return resolved }
        return Self.unifiedPeriod
    }

    /// 单张卡片是否还显示自己的进度条。
    ///
    /// - 计数器（HOTP）没有周期，始终不显示；
    /// - 统一进度条开启时，标准 30 秒周期由列表顶部那条统一进度条接管，卡片不再重复画；
    /// - 其余情况保持旧行为（60 秒与自定义周期继续显示各自的进度条）。
    public func showsCardProgress(isCounterBased: Bool, entryPeriod: Int) -> Bool {
        guard !isCounterBased else { return false }
        guard preferences.usesUnifiedProgressBar else { return true }
        return max(entryPeriod, 1) != Self.unifiedPeriod
    }

    /// 统一进度条的剩余秒数。
    ///
    /// 与 `AppSessionModel.totpTimeRemaining` 同一公式（整秒取模，整除时返回整周期），
    /// 只是周期固定为 30 秒，这样统一进度条和卡片上的秒数不会错位。
    public func unifiedRemaining(at date: Date = Date()) -> Int {
        let total = max(Self.unifiedPeriod, 1)
        let elapsed = Int(date.timeIntervalSince1970) % total
        return elapsed == 0 ? total : total - elapsed
    }

    /// 剩余比例（0…1），线性与环形共用。
    public func progress(remaining: Int, period: Int) -> Double {
        let total = max(period, 1)
        let clamped = min(max(remaining, 0), total)
        return Double(clamped) / Double(total)
    }

    /// 是否正处在周期起点（验证码刚刷新）。
    ///
    /// 这一帧不能做平滑动画：`totpTimeRemaining` 在刷新瞬间返回整周期，若从 0 动画到满
    /// 会看到进度条突然回绕；直接跳到起点才和旧版本一致。
    public func isCycleStart(remaining: Int, period: Int) -> Bool {
        remaining >= max(period, 1)
    }
}

public extension TotpProgressStyle {
    /// 写入 Widget 快照的稳定字符串，与 `MonicaWidgetTotpProgressStyle` 的 rawValue 一致。
    var snapshotValue: String { rawValue }

    /// 从 Widget 快照读回；缺失、未知或旧快照一律回落到线性，保持旧外观。
    init(snapshotValue: String?) {
        self = snapshotValue.flatMap(Self.init(rawValue:)) ?? .linear
    }
}
