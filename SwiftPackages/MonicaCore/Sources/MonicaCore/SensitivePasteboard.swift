import CryptoKit
import Foundation

/// 复制敏感值后自动清除剪贴板的时长选项（#58）。
///
/// `rawValue` 是持久化用的秒数；`.off`（0）表示用户关闭了自动清除。
public enum SensitiveClipboardTTL: Int, CaseIterable, Codable, Sendable, Identifiable {
    case off = 0
    case seconds15 = 15
    case seconds30 = 30
    case seconds60 = 60

    public static let `default`: SensitiveClipboardTTL = .seconds30

    public var id: Int { rawValue }

    /// 自动清除的秒数；关闭时为 `nil`。
    public var seconds: TimeInterval? {
        self == .off ? nil : TimeInterval(rawValue)
    }

    public var isEnabled: Bool {
        seconds != nil
    }
}

/// 对系统剪贴板的最小抽象，便于在 macOS 上用假实现测试策略。
///
/// - Important: 读取 `string` 会触发 iOS 的“粘贴”隐私提示，并暴露其它 App 写入的内容。
///   `MonicaSensitivePasteboard` 只在写入时记录 `changeCount`；清理判断只比较 `changeCount`，
///   从不读取 `string`。
@MainActor
public protocol SensitivePasteboardWriting: AnyObject {
    /// 系统剪贴板的变化计数。读取该属性不会触发粘贴提示。
    var changeCount: Int { get }
    var string: String? { get }
    func setString(_ value: String)
    /// 清空剪贴板。调用方必须先确认剪贴板里仍是本 App 写入的值。
    func clear()
}

/// 一个不写入任何内容的占位剪贴板。
///
/// 只用于没有注入真实剪贴板的测试/预览环境；生产环境必须注入
/// `SystemSensitivePasteboard`（见 `MonicaAppEnvironment.swift`）。
@MainActor
public final class UnavailableSensitivePasteboard: SensitivePasteboardWriting {
    public private(set) var changeCount = 0
    public var string: String? { nil }

    public init() {}

    public func setString(_ value: String) {
        // 刻意不保存明文：没有真实剪贴板时连内存副本也不保留。
    }

    public func clear() {}
}

/// 集中管理敏感值复制与“尽力而为”的剪贴板清理（#58）。
///
/// 设计约束（iOS 平台事实）：
/// - App 进入后台后会被挂起，`Timer`/`Task` 不会按秒运行；后台无法保证精确的清理时间。
///   因此只能在前台运行清理检查，并在回到前台时补做一次到期检查。
/// - 系统剪贴板是 App 共享的。为了不覆盖用户在其它 App 新复制的内容，清理前只比较
///   `changeCount` 是否仍是本 App 写入后的值；比较不需要、也绝不读取剪贴板内容。
/// - 记录的 `changeCount`、到期时间与加盐散列只保存在内存里：进程被系统终止后，
///   本 App 无法在不读取剪贴板的前提下证明剪贴板仍是自己的值，因此冷启动不做清理。
///
/// 记录里不含明文，也不写入 `UserDefaults`/文件；散列只用于测试与调试时的身份核对。
@MainActor
public final class MonicaSensitivePasteboard {
    /// 一次写入的内存记录。刻意不保存明文。
    public struct Record: Equatable, Sendable {
        /// 本 App 写入完成后的 `changeCount`。
        public let changeCount: Int
        public let expiresAt: Date
        /// 写入值的 HMAC-SHA256（密钥随机、仅内存）。不是明文，也不能还原明文。
        public let valueDigest: String

        public func isExpired(at date: Date) -> Bool {
            date >= expiresAt
        }
    }

    public enum CopyOutcome: Equatable, Sendable {
        case copiedWithAutoClear(expiresAt: Date)
        case copiedWithoutAutoClear
        case nothingToCopy
    }

    public enum ExpiryOutcome: Equatable, Sendable {
        case noPendingValue
        case notYetDue(expiresAt: Date)
        case cleared
        /// 剪贴板已被其它 App 替换：保持原样，也不读取它的内容。
        case skippedBecauseReplacedByAnotherApp
    }

    private let pasteboard: any SensitivePasteboardWriting
    private let now: @MainActor () -> Date
    private let digestKey: SymmetricKey

    /// 当前待清理记录；没有任何待清理值时是 `nil`。仅内存。
    public private(set) var activeRecord: Record?

    public init(
        pasteboard: any SensitivePasteboardWriting,
        now: @escaping @MainActor () -> Date = { Date() },
        digestKeyBytes: [UInt8]? = nil
    ) {
        self.pasteboard = pasteboard
        self.now = now
        self.digestKey = Self.makeDigestKey(bytes: digestKeyBytes)
    }

    public var hasPendingAutoClear: Bool {
        activeRecord != nil
    }

    /// 系统剪贴板当前的变化计数。
    ///
    /// 读取它不需要、也不会读取剪贴板内容，因此不会触发系统粘贴提示；
    /// #148 的自动续写用它判断“剪贴板里还是我上次写入的值”。
    public var changeCount: Int {
        pasteboard.changeCount
    }

    /// 把敏感值写入剪贴板，并在开启自动清除时记录身份与到期时间。
    ///
    /// `changeCount` 在写入之后读取，避免把写入之前的旧计数当作自己的身份。
    @discardableResult
    public func copy(secret: String, ttl: SensitiveClipboardTTL) -> CopyOutcome {
        guard !secret.isEmpty else {
            return .nothingToCopy
        }

        pasteboard.setString(secret)
        let writtenChangeCount = pasteboard.changeCount

        guard let seconds = ttl.seconds else {
            activeRecord = nil
            return .copiedWithoutAutoClear
        }

        let expiresAt = now().addingTimeInterval(seconds)
        activeRecord = Record(
            changeCount: writtenChangeCount,
            expiresAt: expiresAt,
            valueDigest: Self.digest(secret, key: digestKey)
        )
        return .copiedWithAutoClear(expiresAt: expiresAt)
    }

    /// 到期时清理；未到期返回 `.notYetDue`，调用方继续前台轮询即可。
    @discardableResult
    public func clearIfExpired(at date: Date? = nil) -> ExpiryOutcome {
        guard let record = activeRecord else {
            return .noPendingValue
        }
        guard record.isExpired(at: date ?? now()) else {
            return .notYetDue(expiresAt: record.expiresAt)
        }
        return clearIfStillOwned(record)
    }

    /// 用户手动“立即清除”。同样只在剪贴板仍是本 App 写入的值时才清空。
    @discardableResult
    public func clearImmediatelyIfOwned() -> ExpiryOutcome {
        guard let record = activeRecord else {
            return .noPendingValue
        }
        return clearIfStillOwned(record)
    }

    /// 丢失待清理记录但不碰剪贴板：用户在倒计时中途关闭自动清除时使用。
    ///
    /// 之后 `clearIfExpired` 不会再清理这次复制；剪贴板内容原样保留。
    public func discardPendingRecord() {
        activeRecord = nil
    }

    /// 还剩多少秒自动清除；没有待清理值时是 `nil`。
    public func remainingSeconds(at date: Date? = nil) -> Int? {
        guard let record = activeRecord else {
            return nil
        }
        let reference = date ?? now()
        return max(0, Int(record.expiresAt.timeIntervalSince(reference).rounded(.up)))
    }

    /// 只比较 `changeCount`：一旦其它 App 复制了新内容，就不再碰剪贴板。
    /// 这里刻意不读 `pasteboard.string`，否则会触发系统粘贴提示并看到别人的数据。
    private func clearIfStillOwned(_ record: Record) -> ExpiryOutcome {
        guard pasteboard.changeCount == record.changeCount else {
            activeRecord = nil
            return .skippedBecauseReplacedByAnotherApp
        }
        pasteboard.clear()
        activeRecord = nil
        return .cleared
    }

    private static func makeDigestKey(bytes: [UInt8]?) -> SymmetricKey {
        if let bytes, !bytes.isEmpty {
            return SymmetricKey(data: Data(bytes))
        }
        return SymmetricKey(size: .bits256)
    }

    static func digest(_ value: String, key: SymmetricKey) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: key)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// 剪贴板自动清除时长的持久化偏好。
///
/// 只持久化一个秒数，不涉及任何被复制的值。
public protocol SensitiveClipboardPreferenceStore: Sendable {
    func loadTTL() -> SensitiveClipboardTTL
    func saveTTL(_ ttl: SensitiveClipboardTTL)
}

public final class MemorySensitiveClipboardPreferenceStore: SensitiveClipboardPreferenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var ttl: SensitiveClipboardTTL

    public init(ttl: SensitiveClipboardTTL = .default) {
        self.ttl = ttl
    }

    public func loadTTL() -> SensitiveClipboardTTL {
        lock.lock()
        defer { lock.unlock() }
        return ttl
    }

    public func saveTTL(_ ttl: SensitiveClipboardTTL) {
        lock.lock()
        defer { lock.unlock() }
        self.ttl = ttl
    }
}

public final class UserDefaultsSensitiveClipboardPreferenceStore: SensitiveClipboardPreferenceStore, @unchecked Sendable {
    public static let userDefaultsKey = "monica.sensitiveClipboard.ttlSeconds"

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func loadTTL() -> SensitiveClipboardTTL {
        guard userDefaults.object(forKey: Self.userDefaultsKey) != nil else {
            return .default
        }
        return SensitiveClipboardTTL(rawValue: userDefaults.integer(forKey: Self.userDefaultsKey)) ?? .default
    }

    public func saveTTL(_ ttl: SensitiveClipboardTTL) {
        userDefaults.set(ttl.rawValue, forKey: Self.userDefaultsKey)
    }
}
