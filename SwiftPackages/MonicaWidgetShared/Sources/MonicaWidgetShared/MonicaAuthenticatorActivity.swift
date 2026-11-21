//
//  MonicaAuthenticatorActivity.swift
//  MonicaWidgetShared
//
//  「验证器锁屏倒计时」Live Activity 试点里所有**不依赖 ActivityKit** 的纯逻辑。
//
//  为什么单独放在共享包里：
//  - App 与 widget extension 需要同一份窗口/别名/周期推导，避免两边各写一套算法后漂移；
//  - 这些类型在 macOS 上也能编译，因此可以用 `swift test` 覆盖倒计时边界、
//    别名清洗和 feature-gate 回退，不需要真机或模拟器。
//
//  安全边界（与 Android 常驻通知不等价）：
//  - 这里的 `MonicaAuthenticatorActivityEntry` 只保留条目 id、别名和周期，
//    不包含 OTP 密钥，也不包含任何一次性的验证码正文；
//  - 真正下发给 ActivityKit 的载荷见同目录 `MonicaAuthenticatorActivityAttributes.swift`。
//

import Foundation

/// Live Activity 载荷允许出现的最小信息集：条目 id、别名、周期。
///
/// 刻意不携带 `LocalTotpEntry.secret`，也不快照当前验证码：锁屏/灵动岛需要的是
/// 「还有多少秒」而不是「验证码是多少」。少一份密钥副本，就少一条泄露路径。
public struct MonicaAuthenticatorActivityEntry: Sendable, Equatable, Hashable, Codable {
    /// `LocalTotpEntry.id` 的字符串形式，用于把 Live Activity 对回具体条目。
    public let id: String
    /// 清洗后的展示别名（标题/签发方/账号名之一），长度与空白都已归一。
    public let alias: String
    /// 归一后的周期（秒）。
    public let period: Int

    public init(id: String, alias: String, period: Int) {
        self.id = id
        self.alias = MonicaAuthenticatorActivityLimits.sanitizedAlias(alias)
        self.period = MonicaAuthenticatorActivityLimits.normalizedPeriod(period)
    }

    /// 从 App 的本地条目构造载荷；只在 App target 里调用。
    ///
    /// 别名优先取用户自己起的标题，其次签发方，最后账号名，全部为空时回退到通用文案。
    public init(id: String, title: String, issuer: String, accountName: String, period: Int) {
        let candidate = [title, issuer, accountName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        self.init(id: id, alias: candidate ?? "", period: period)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case alias
        case period
    }

    /// 解码时重新走一遍归一化：Live Activity 的载荷会写进系统存储，
    /// 反序列化路径同样不应该信任其中的字符串长度或周期取值。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            alias: try container.decode(String.self, forKey: .alias),
            period: try container.decode(Int.self, forKey: .period)
        )
    }
}

/// 试点用到的所有数值边界，集中在一处，App、widget 与测试共用。
public enum MonicaAuthenticatorActivityLimits {
    /// TOTP 默认周期（秒）。
    public static let defaultPeriod = 30
    /// 允许的最小周期（秒）。
    public static let minimumPeriod = 1
    /// 允许的最大周期（秒）；超出范围一律夹紧，避免非法周期把倒计时算成负数或毛刺。
    public static let maximumPeriod = 600
    /// 别名上限（字符数），超出直接截断。
    public static let maximumAliasLength = 64
    /// 单次试点的时长：30 分钟。到点后倒计时归零，App 内也会提示重新开始。
    public static let pilotSessionDuration: TimeInterval = 30 * 60
    /// 单次 Live Activity 的最短时长，避免 `end` 之前就被系统视为已过期。
    public static let minimumSessionDuration: TimeInterval = 60
    /// 单个 Live Activity 的生命周期上限：约 8 小时。这只用作夹紧输入，
    /// 真正的结束时机由 ActivityKit 决定（系统可以提前回收）。
    public static let systemMaximumDuration: TimeInterval = 8 * 60 * 60

    /// 没有任何可用别名时的兜底文案；调用方需要本地化时请自行替换。
    public static var fallbackAlias: String {
        String(localized: "验证码")
    }

    /// 把任意周期夹到 `minimumPeriod...maximumPeriod`，非正数回退到默认值。
    public static func normalizedPeriod(_ raw: Int) -> Int {
        guard raw > 0 else { return defaultPeriod }
        return min(max(raw, minimumPeriod), maximumPeriod)
    }

    /// 把任意时长夹到 `minimumSessionDuration...systemMaximumDuration`。
    public static func normalizedDuration(_ raw: TimeInterval) -> TimeInterval {
        guard !raw.isNaN else { return pilotSessionDuration }
        return min(max(raw, minimumSessionDuration), systemMaximumDuration)
    }

    /// 合并空白、去掉首尾空白、截断超长别名，空串回退到本地化的「验证码」。
    public static func sanitizedAlias(_ raw: String) -> String {
        let collapsed = raw
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallbackAlias }
        return String(trimmed.prefix(maximumAliasLength))
    }
}

/// 一次 Live Activity 的展示计划：哪一个倒计时窗口、什么时候结束。
///
/// `windowStart`/`windowEnd` 直接喂给 `Text(timerInterval:)` 与
/// `ProgressView(timerInterval:)`，由系统负责逐秒渲染——App 里没有任何定时器。
public struct MonicaAuthenticatorActivityPlan: Sendable, Equatable, Hashable, Codable {
    public let entry: MonicaAuthenticatorActivityEntry
    /// 当前验证码窗口的起点（整周期的整数倍）。
    public let windowStart: Date
    /// 当前验证码窗口的终点，倒计时到这里归零。
    public let windowEnd: Date
    /// 本次试点结束的时间；之后系统不再保证展示。
    public let sessionEndsAt: Date
    /// 传给 ActivityKit 的 `staleDate`，与 `sessionEndsAt` 一致。
    public let staleDate: Date

    /// 以 `now` 所在周期的窗口创建计划。
    public init(
        entry: MonicaAuthenticatorActivityEntry,
        now: Date = Date(),
        duration: TimeInterval = MonicaAuthenticatorActivityLimits.pilotSessionDuration
    ) {
        let period = TimeInterval(entry.period)
        let timestamp = now.timeIntervalSince1970
        let windowIndex = (timestamp / period).rounded(.down)
        let start = windowIndex * period
        let sessionEnd = now.addingTimeInterval(MonicaAuthenticatorActivityLimits.normalizedDuration(duration))
        self.init(
            entry: entry,
            windowStart: Date(timeIntervalSince1970: start),
            windowEnd: Date(timeIntervalSince1970: start + period),
            sessionEndsAt: sessionEnd,
            staleDate: sessionEnd
        )
    }

    /// 从 ActivityKit 中恢复已有活动时使用；不做任何时间夹紧，原样还原。
    public init(
        entry: MonicaAuthenticatorActivityEntry,
        windowStart: Date,
        windowEnd: Date,
        sessionEndsAt: Date,
        staleDate: Date
    ) {
        self.entry = entry
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.sessionEndsAt = sessionEndsAt
        self.staleDate = staleDate
    }

    public var alias: String { entry.alias }
    public var period: Int { entry.period }

    /// 距离窗口结束还剩几秒；已过期返回 0。
    ///
    /// 取整方式与 App 现有的 `AppSessionModel.totpTimeRemaining(for:at:)` 一致
    /// （向上取整），保证锁屏和列表不会出现「差一秒」的错位。
    public func remainingSeconds(at date: Date) -> Int {
        let remaining = windowEnd.timeIntervalSince(date)
        guard remaining > 0 else { return 0 }
        return Int(remaining.rounded(.up))
    }

    /// 当前窗口是否已经走完（需要推进到下一个窗口）。
    public func isWindowExpired(at date: Date) -> Bool {
        date >= windowEnd
    }

    /// 整次试点是否已经结束。
    public func isExpired(at date: Date) -> Bool {
        date >= sessionEndsAt
    }

    /// 推进到 `date` 所在的窗口，`sessionEndsAt`/`staleDate` 保持不变。
    ///
    /// 只在试点尚未结束时推进；倒着开会退回到旧窗口。
    public func advanced(to date: Date) -> MonicaAuthenticatorActivityPlan {
        guard !isExpired(at: date) else { return self }
        let period = TimeInterval(entry.period)
        let index = (date.timeIntervalSince1970 / period).rounded(.down)
        let start = index * period
        guard start >= windowStart.timeIntervalSince1970 else { return self }
        return MonicaAuthenticatorActivityPlan(
            entry: entry,
            windowStart: Date(timeIntervalSince1970: start),
            windowEnd: Date(timeIntervalSince1970: start + period),
            sessionEndsAt: sessionEndsAt,
            staleDate: staleDate
        )
    }
}

/// 能否开始 Live Activity：设备/系统是否支持，以及用户是否允许。
public enum MonicaAuthenticatorActivityAvailability: String, Sendable, Equatable, Codable {
    /// 可以开始。
    case available
    /// 设备或系统版本不支持 Live Activity。
    case unsupportedDevice
    /// 支持，但用户在系统设置里关闭了实时活动（`areActivitiesEnabled == false`）。
    case disabled

    /// 由 `ActivityAuthorizationInfo` 的两个输入推导；纯函数，便于测试覆盖。
    public static func evaluate(isDeviceSupported: Bool, areActivitiesEnabled: Bool) -> MonicaAuthenticatorActivityAvailability {
        guard isDeviceSupported else { return .unsupportedDevice }
        return areActivitiesEnabled ? .available : .disabled
    }

    public var canStart: Bool {
        self == .available
    }

    /// 不可用时对应的失败原因，用于在界面上给出本地化提示。
    public var failure: MonicaAuthenticatorActivityFailure? {
        switch self {
        case .available: return nil
        case .unsupportedDevice: return .unsupportedDevice
        case .disabled: return .disabled
        }
    }
}

/// 试点失败/结束的原因。所有分支都必须回退到普通界面，不允许抛到调用方。
public enum MonicaAuthenticatorActivityFailure: String, Error, Sendable, Equatable, Codable, CaseIterable {
    /// 设备或系统不支持 Live Activity。
    case unsupportedDevice
    /// 用户或系统关闭了实时活动。
    case disabled
    /// `Activity.request` 抛错（系统拒绝、配额已满等）。
    case requestFailed
    /// 试点时长已到，倒计时结束。
    case expired

    /// 失败后一律显示普通验证码界面，不做任何自动重试。
    public var fallsBackToInlineUI: Bool { true }
}

/// App 侧发起 Live Activity 的状态机，刻意做成不依赖 ActivityKit 的值类型，
/// 这样「开始 → 失败回退 → 结束」的分支可以在 macOS 上用 `swift test` 直接验证。
public enum MonicaAuthenticatorActivityState: Sendable, Equatable {
    /// 没有活动，界面显示开始按钮。
    case idle
    /// 已经通过 feature-gate，正在调用 `Activity.request`。
    case starting
    /// 已在锁屏展示。
    case running(MonicaAuthenticatorActivityPlan)
    /// 失败：界面回到普通列表并展示本地化提示。
    case failed(MonicaAuthenticatorActivityFailure)
}

/// 状态机的所有合法迁移都在这里，视图只负责展示。
public struct MonicaAuthenticatorActivitySession: Sendable, Equatable {
    public private(set) var state: MonicaAuthenticatorActivityState

    public init(state: MonicaAuthenticatorActivityState = .idle) {
        self.state = state
    }

    public var plan: MonicaAuthenticatorActivityPlan? {
        guard case .running(let plan) = state else { return nil }
        return plan
    }

    public var failure: MonicaAuthenticatorActivityFailure? {
        guard case .failed(let failure) = state else { return nil }
        return failure
    }

    public var isRunning: Bool { plan != nil }

    public var isStarting: Bool {
        if case .starting = state { return true }
        return false
    }

    /// 失败后是否应该退回普通界面（按要求恒为 true，保留成属性方便阅读调用点）。
    public var shouldPresentInlineFallback: Bool {
        failure?.fallsBackToInlineUI ?? false
    }

    /// 尝试开始：可用则进入 `.starting`，不可用则直接标记失败并返回 false。
    ///
    /// 已经在跑或正在启动时不会重复发起，也不会覆盖现有状态。
    @discardableResult
    public mutating func beginStart(availability: MonicaAuthenticatorActivityAvailability) -> Bool {
        guard !isRunning, !isStarting else { return false }
        guard availability.canStart else {
            state = .failed(availability.failure ?? .disabled)
            return false
        }
        state = .starting
        return true
    }

    /// `Activity.request` 成功。
    public mutating func markStarted(_ plan: MonicaAuthenticatorActivityPlan) {
        state = .running(plan)
    }

    /// 任意一步失败，回到可重试的失败态。
    public mutating func markFailed(_ failure: MonicaAuthenticatorActivityFailure) {
        state = .failed(failure)
    }

    /// 用户结束、系统回收、或异常清理后回到空闲。
    public mutating func markEnded() {
        state = .idle
    }

    /// App 回到前台时对齐当前窗口。
    ///
    /// - 试点已到期：标记 `.expired`，调用方应立即 `end(dismissalPolicy: .immediate)`；
    /// - 窗口已跨过：推进到新窗口，调用方需要 `activity.update(...)` 同步起点；
    /// - 其余情况返回 nil，不需要任何操作。
    @discardableResult
    public mutating func refresh(at date: Date) -> MonicaAuthenticatorActivityPlan? {
        guard let plan else { return nil }
        if plan.isExpired(at: date) {
            state = .failed(.expired)
            return nil
        }
        guard plan.isWindowExpired(at: date) else { return nil }
        let advanced = plan.advanced(to: date)
        state = .running(advanced)
        return advanced
    }
}
