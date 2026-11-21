import Foundation

// MARK: - 为什么没有写

/// 自动续写下一码没有发生的原因（#148）。
///
/// 只描述“为什么没写”，不携带验证码内容；文案由 App 层决定。
public enum TotpAutoCopySkipReason: Equatable, Sendable {
    /// 开关关闭。
    case disabled
    /// 密码库未解锁。
    case vaultLocked
    /// 应用不在前台（inactive/background）。
    case sceneNotActive
    /// 验证器页当前不可见。
    case authenticatorPageNotVisible
    /// 计数器验证码（HOTP）不适用。
    case hotpEntry
    /// 还没有手动复制过验证码，不知道该续写哪一个条目。
    case notArmed
    /// 上次手动复制的条目已经不在当前列表中。
    case armedEntryUnavailable
    /// 剪贴板在这之后被其它来源替换，不覆盖。
    case clipboardReplacedByAnotherApp
    /// 条目周期无效。
    case invalidPeriod
    /// 预取窗口不小于周期，永远不会触发（防御性判断）。
    case prefetchWindowNotShorterThanPeriod
    /// 距离下一个周期还早。
    case notYetDue(remainingSeconds: Int)
    /// 这个周期已经写过一次。
    case alreadyCopiedThisPeriod(periodIndex: UInt64)
    /// 生成下一码失败（配置损坏等）。
    case codeUnavailable
}

// MARK: - 下一码

/// 预取到的“下一个验证码”所属的周期。
///
/// 只有周期编号与生效时刻，不含验证码本身。
public struct TotpAutoCopyNextCode: Equatable, Sendable {
    /// 下一码所属的周期编号（即 RFC 6238 的 `TOTP counter`）。
    public let periodIndex: UInt64
    /// 下一码生效的时刻，正好是周期起点。
    public let validFrom: Date

    public init(periodIndex: UInt64, validFrom: Date) {
        self.periodIndex = periodIndex
        self.validFrom = validFrom
    }
}

// MARK: - 门控

/// 自动续写的写入门控。
///
/// 全部条件都满足才会写剪贴板；任何一个不满足都只返回跳过原因。
public struct TotpAutoCopyGates: Equatable, Sendable {
    public var isEnabled: Bool
    public var isVaultUnlocked: Bool
    public var isSceneActive: Bool
    public var isAuthenticatorPageVisible: Bool
    public var isHOTP: Bool
    public var isArmed: Bool
    /// 剪贴板仍是本 App 上一次写入的值（`changeCount` 未变）。
    public var isClipboardOwned: Bool

    public init(
        isEnabled: Bool = false,
        isVaultUnlocked: Bool = false,
        isSceneActive: Bool = false,
        isAuthenticatorPageVisible: Bool = false,
        isHOTP: Bool = false,
        isArmed: Bool = false,
        isClipboardOwned: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.isVaultUnlocked = isVaultUnlocked
        self.isSceneActive = isSceneActive
        self.isAuthenticatorPageVisible = isAuthenticatorPageVisible
        self.isHOTP = isHOTP
        self.isArmed = isArmed
        self.isClipboardOwned = isClipboardOwned
    }
}

// MARK: - 决策

/// 某一秒的决策结果。
public enum TotpAutoCopyDecision: Equatable, Sendable {
    case copy(TotpAutoCopyNextCode)
    case skip(TotpAutoCopySkipReason)
}

// MARK: - 纯策略

/// #148「验证码到期自动复制下一个码」的纯逻辑。
///
/// 只做判断：读取注入的时钟、门控与“这个周期是否已写过”，不读取剪贴板、
/// 不生成验证码、不访问 `UserDefaults`，因此可以用固定时钟覆盖跨周期行为。
public struct TotpAutoCopyPolicy: Equatable, Sendable {
    /// 默认在当前码剩余 3 秒时预取下一码。
    public static let defaultPrefetchWindowSeconds = 3

    /// 预取窗口（秒），必须小于条目周期才有意义。
    public let prefetchWindowSeconds: Int

    public init(prefetchWindowSeconds: Int = TotpAutoCopyPolicy.defaultPrefetchWindowSeconds) {
        self.prefetchWindowSeconds = max(prefetchWindowSeconds, 1)
    }

    /// 当前码的剩余秒数。
    ///
    /// 与 `AppSessionModel.totpTimeRemaining` 语义一致：周期起点返回整个周期，
    /// 而不是 0；这样倒计时不会闪一下 0。
    public func remainingSeconds(now: Date, period: Int) -> Int? {
        guard period > 0 else {
            return nil
        }
        let timestamp = Int(now.timeIntervalSince1970.rounded(.down))
        let elapsed = timestamp % period
        let normalizedElapsed = elapsed >= 0 ? elapsed : elapsed + period
        return normalizedElapsed == 0 ? period : period - normalizedElapsed
    }

    /// 下一码是否已进入预取窗口（纯时钟判断，不含任何门控）。
    public func nextCodeDue(now: Date, period: Int, remainingSeconds remaining: Int) -> TotpAutoCopyNextCode? {
        guard prefetchWindowSeconds < period,
              remaining > 0,
              remaining <= prefetchWindowSeconds,
              let nextCode = nextCode(now: now, period: period)
        else {
            return nil
        }
        return nextCode
    }

    /// 下一码所属的周期编号与生效时刻。
    public func nextCode(now: Date, period: Int) -> TotpAutoCopyNextCode? {
        guard period > 0 else {
            return nil
        }
        let timestamp = now.timeIntervalSince1970
        guard timestamp >= 0 else {
            return nil
        }
        let nextPeriodIndex = UInt64(timestamp / Double(period)) + 1
        return TotpAutoCopyNextCode(
            periodIndex: nextPeriodIndex,
            validFrom: Date(timeIntervalSince1970: TimeInterval(nextPeriodIndex) * Double(period))
        )
    }

    /// 综合门控、时钟与去重记录，判断这一秒要不要写下一码。
    ///
    /// 门控顺序即优先级：关闭 → 锁库 → 后台 → 页面不可见 → HOTP → 未武装 →
    /// 剪贴板被替换 → 周期/窗口无效 → 未到期 → 本周期已写过。
    public func decision(
        gates: TotpAutoCopyGates,
        now: Date,
        period: Int,
        remainingSeconds remaining: Int,
        lastWrittenPeriod: UInt64?
    ) -> TotpAutoCopyDecision {
        guard gates.isEnabled else {
            return .skip(.disabled)
        }
        guard gates.isVaultUnlocked else {
            return .skip(.vaultLocked)
        }
        guard gates.isSceneActive else {
            return .skip(.sceneNotActive)
        }
        guard gates.isAuthenticatorPageVisible else {
            return .skip(.authenticatorPageNotVisible)
        }
        guard !gates.isHOTP else {
            return .skip(.hotpEntry)
        }
        guard gates.isArmed else {
            return .skip(.notArmed)
        }
        guard gates.isClipboardOwned else {
            return .skip(.clipboardReplacedByAnotherApp)
        }
        guard period > 0 else {
            return .skip(.invalidPeriod)
        }
        guard prefetchWindowSeconds < period else {
            return .skip(.prefetchWindowNotShorterThanPeriod)
        }
        guard remaining > 0, remaining <= prefetchWindowSeconds else {
            return .skip(.notYetDue(remainingSeconds: remaining))
        }
        guard let nextCode = nextCode(now: now, period: period) else {
            return .skip(.invalidPeriod)
        }
        if lastWrittenPeriod == nextCode.periodIndex {
            return .skip(.alreadyCopiedThisPeriod(periodIndex: nextCode.periodIndex))
        }
        return .copy(nextCode)
    }
}

// MARK: - 去重记录

/// 每个条目最近一次自动写入的“下一码周期编号”，用来保证同一周期只写一次。
///
/// 只保存周期编号，不含验证码、也不写磁盘。
public struct TotpAutoCopyLedger: Equatable, Sendable {
    private var writtenPeriodsByEntryID: [String: UInt64] = [:]

    public init() {}

    /// 已记录的条目数量（测试与调试用）。
    public var trackedEntryCount: Int {
        writtenPeriodsByEntryID.count
    }

    public func lastWrittenPeriod(for entryID: String) -> UInt64? {
        writtenPeriodsByEntryID[entryID]
    }

    public mutating func markWritten(periodIndex: UInt64, for entryID: String) {
        writtenPeriodsByEntryID[entryID] = periodIndex
    }

    public mutating func forget(entryID: String) {
        writtenPeriodsByEntryID[entryID] = nil
    }

    public mutating func reset() {
        writtenPeriodsByEntryID.removeAll()
    }
}

// MARK: - 持久化

/// 自动续写开关的持久化。
///
/// 只持久化一个布尔值，不涉及任何被复制的值。
public protocol TotpAutoCopyPreferenceStore: Sendable {
    func loadIsEnabled() -> Bool
    func saveIsEnabled(_ isEnabled: Bool)
}

/// 测试与预览用的内存实现。
public final class MemoryTotpAutoCopyPreferenceStore: TotpAutoCopyPreferenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var isEnabled: Bool

    public init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    public func loadIsEnabled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isEnabled
    }

    public func saveIsEnabled(_ isEnabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.isEnabled = isEnabled
    }
}

/// `UserDefaults` 实现；键不存在时视为关闭（默认关闭）。
public final class UserDefaultsTotpAutoCopyPreferenceStore: TotpAutoCopyPreferenceStore, @unchecked Sendable {
    public static let userDefaultsKey = "monica.totp.autoCopyNextCode"

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func loadIsEnabled() -> Bool {
        guard userDefaults.object(forKey: Self.userDefaultsKey) != nil else {
            return false
        }
        return userDefaults.bool(forKey: Self.userDefaultsKey)
    }

    public func saveIsEnabled(_ isEnabled: Bool) {
        userDefaults.set(isEnabled, forKey: Self.userDefaultsKey)
    }
}

// MARK: - 结果

/// 一次 tick 的结果。
///
/// `.copied` 里只有条目、周期与到期时间，不含验证码本身。
public enum TotpAutoCopyOutcome: Equatable, Sendable {
    case copied(entryID: String, periodIndex: UInt64, expiresAt: Date?)
    case skipped(TotpAutoCopySkipReason)
}

// MARK: - 控制器

/// 把纯策略、敏感剪贴板与去重记录串起来的（主线程）控制器。
///
/// 写入只经过 `MonicaSensitivePasteboard`（#58 的敏感通道）：自动复制同样受
/// “复制后自动清除”的 TTL 约束，并且从不把验证码明文存进任何属性或日志。
@MainActor
public final class TotpAutoCopyController {
    /// 验证器列表里一个条目的最小信息，避免核心层依赖 App 的存储模型。
    public struct Entry: Equatable, Sendable {
        public let entryID: String
        public let period: Int
        public let isHOTP: Bool

        public init(entryID: String, period: Int, isHOTP: Bool) {
            self.entryID = entryID
            self.period = period
            self.isHOTP = isHOTP
        }
    }

    /// 一次 tick 的输入。`now` 由调用方注入，便于测试跨周期行为。
    public struct Request: Equatable, Sendable {
        public var isEnabled: Bool
        public var isVaultUnlocked: Bool
        public var isSceneActive: Bool
        public var isAuthenticatorPageVisible: Bool
        public var ttl: SensitiveClipboardTTL
        public var now: Date

        public init(
            isEnabled: Bool,
            isVaultUnlocked: Bool,
            isSceneActive: Bool,
            isAuthenticatorPageVisible: Bool,
            ttl: SensitiveClipboardTTL,
            now: Date
        ) {
            self.isEnabled = isEnabled
            self.isVaultUnlocked = isVaultUnlocked
            self.isSceneActive = isSceneActive
            self.isAuthenticatorPageVisible = isAuthenticatorPageVisible
            self.ttl = ttl
            self.now = now
        }
    }

    public let policy: TotpAutoCopyPolicy

    private let pasteboard: MonicaSensitivePasteboard
    private var ledger = TotpAutoCopyLedger()
    private var armedEntryID: String?
    private var armedChangeCount: Int?

    public init(
        pasteboard: MonicaSensitivePasteboard,
        policy: TotpAutoCopyPolicy = TotpAutoCopyPolicy()
    ) {
        self.pasteboard = pasteboard
        self.policy = policy
    }

    /// 手动复制后记住条目，之后的 tick 只会为它续写。
    public var isArmed: Bool {
        armedEntryID != nil
    }

    /// 当前记住续写的条目 id。
    public var armedEntryIdentifier: String? {
        armedEntryID
    }

    /// 手动复制成功后调用；`changeCount` 在写入之后记录，作为剪贴板归属凭据。
    public func arm(entryID: String) {
        armedEntryID = entryID
        armedChangeCount = pasteboard.changeCount
    }

    /// 取消续写（关闭开关时不调用，避免“复制后再打开开关”失效）。
    public func disarm() {
        armedEntryID = nil
        armedChangeCount = nil
    }

    /// 每秒调用一次；只有所有门控都满足且本周期未写过时才会真正写剪贴板。
    ///
    /// - Parameter code: 用 `nextCode.validFrom` 生成验证码。只有在确实要写时才调用，
    ///   因此正常倒计时不会每秒生成一次验证码。
    @discardableResult
    public func tick(
        _ request: Request,
        entry: Entry?,
        code: (TotpAutoCopyNextCode) throws -> String
    ) -> TotpAutoCopyOutcome {
        if let armedEntryID {
            guard let entry, entry.entryID == armedEntryID else {
                disarm()
                return .skipped(.armedEntryUnavailable)
            }
        }

        let isArmed = armedEntryID != nil
        let gates = TotpAutoCopyGates(
            isEnabled: request.isEnabled,
            isVaultUnlocked: request.isVaultUnlocked,
            isSceneActive: request.isSceneActive,
            isAuthenticatorPageVisible: request.isAuthenticatorPageVisible,
            isHOTP: entry?.isHOTP ?? false,
            isArmed: isArmed,
            isClipboardOwned: isArmed && armedChangeCount == pasteboard.changeCount
        )
        let period = entry?.period ?? 0
        let remaining = policy.remainingSeconds(now: request.now, period: period) ?? 0
        let decision = policy.decision(
            gates: gates,
            now: request.now,
            period: period,
            remainingSeconds: remaining,
            lastWrittenPeriod: entry.flatMap { ledger.lastWrittenPeriod(for: $0.entryID) }
        )

        switch decision {
        case let .skip(reason):
            if reason == .clipboardReplacedByAnotherApp {
                disarm()
            }
            return .skipped(reason)

        case let .copy(nextCode):
            guard let entry else {
                return .skipped(.armedEntryUnavailable)
            }
            let secret: String
            do {
                secret = try code(nextCode)
            } catch {
                return .skipped(.codeUnavailable)
            }
            guard !secret.isEmpty else {
                return .skipped(.codeUnavailable)
            }

            switch pasteboard.copy(secret: secret, ttl: request.ttl) {
            case .nothingToCopy:
                return .skipped(.codeUnavailable)

            case let .copiedWithAutoClear(expiresAt):
                ledger.markWritten(periodIndex: nextCode.periodIndex, for: entry.entryID)
                armedChangeCount = pasteboard.changeCount
                return .copied(entryID: entry.entryID, periodIndex: nextCode.periodIndex, expiresAt: expiresAt)

            case .copiedWithoutAutoClear:
                ledger.markWritten(periodIndex: nextCode.periodIndex, for: entry.entryID)
                armedChangeCount = pasteboard.changeCount
                return .copied(entryID: entry.entryID, periodIndex: nextCode.periodIndex, expiresAt: nil)
            }
        }
    }
}
