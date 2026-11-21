import Foundation
import MonicaCore

/// 自动填充守护策略的本地存储。
///
/// 纯本地策略：只决定 Monica 自己要不要把凭据身份发布到系统凭据列表，
/// 不涉及、也无法影响系统或其它 App 的自动填充来源。
protocol AppAutoFillGuardPolicyStore: Sendable {
    func loadPolicy() -> AutoFillGuardPolicy
    func savePolicy(_ policy: AutoFillGuardPolicy)
}

/// 测试与预览使用的内存实现。
final class MemoryAppAutoFillGuardPolicyStore: AppAutoFillGuardPolicyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var policy: AutoFillGuardPolicy

    init(policy: AutoFillGuardPolicy = .default) {
        self.policy = policy
    }

    func loadPolicy() -> AutoFillGuardPolicy {
        lock.lock()
        defer { lock.unlock() }
        return policy
    }

    func savePolicy(_ policy: AutoFillGuardPolicy) {
        lock.lock()
        defer { lock.unlock() }
        self.policy = policy
    }
}

/// 生产环境使用的 UserDefaults 实现。
final class UserDefaultsAppAutoFillGuardPolicyStore: AppAutoFillGuardPolicyStore, @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let key: String

    init(userDefaults: UserDefaults = .standard, key: String = "app.autofill.guard.v1") {
        self.userDefaults = userDefaults
        self.key = key
    }

    func loadPolicy() -> AutoFillGuardPolicy {
        guard
            let data = userDefaults.data(forKey: key),
            let policy = try? JSONDecoder().decode(AutoFillGuardPolicy.self, from: data)
        else {
            return .default
        }
        return policy
    }

    func savePolicy(_ policy: AutoFillGuardPolicy) {
        guard let data = try? JSONEncoder().encode(policy) else { return }
        userDefaults.set(data, forKey: key)
    }
}

/// 身份发布记录：只保留时间点、条数与失败原因，不保存任何凭据内容。
struct AppAutoFillPublishLog: Codable, Equatable, Sendable {
    var lastSucceededAt: Date?
    var lastSucceededCount: Int?
    var lastFailureAt: Date?
    var lastFailureMessage: String?
    var lastSkippedAt: Date?
    var lastSkippedReason: String?
    var lastClearedAt: Date?
}

/// 记录身份发布结果，供诊断面板展示真实状态（不伪造成功）。
protocol AppAutoFillPublishLogStore: Sendable {
    func loadLog() -> AppAutoFillPublishLog
    func recordSuccess(count: Int, at date: Date)
    func recordFailure(message: String, at date: Date)
    func recordSkip(reason: String, at date: Date)
    func recordClear(at date: Date)
}

extension AppAutoFillPublishLogStore {
    /// 只在存在失败记录时返回最近一次失败原因。
    var latestFailureMessage: String? {
        let log = loadLog()
        guard log.lastFailureAt != nil else { return nil }
        return log.lastFailureMessage
    }
}

final class MemoryAppAutoFillPublishLogStore: AppAutoFillPublishLogStore, @unchecked Sendable {
    private let lock = NSLock()
    private var log: AppAutoFillPublishLog

    init(log: AppAutoFillPublishLog = AppAutoFillPublishLog()) {
        self.log = log
    }

    func loadLog() -> AppAutoFillPublishLog {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    func recordSuccess(count: Int, at date: Date) {
        mutate { log in
            log.lastSucceededAt = date
            log.lastSucceededCount = count
        }
    }

    func recordFailure(message: String, at date: Date) {
        mutate { log in
            log.lastFailureAt = date
            log.lastFailureMessage = message
        }
    }

    func recordSkip(reason: String, at date: Date) {
        mutate { log in
            log.lastSkippedAt = date
            log.lastSkippedReason = reason
        }
    }

    func recordClear(at date: Date) {
        mutate { log in
            log.lastClearedAt = date
        }
    }

    private func mutate(_ body: (inout AppAutoFillPublishLog) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&log)
    }
}

/// 生产环境使用的 UserDefaults 实现；写入可能来自系统回调的后台队列，读写都要加锁。
final class UserDefaultsAppAutoFillPublishLogStore: AppAutoFillPublishLogStore, @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    init(userDefaults: UserDefaults = .standard, key: String = "app.autofill.publish-log.v1") {
        self.userDefaults = userDefaults
        self.key = key
    }

    func loadLog() -> AppAutoFillPublishLog {
        lock.lock()
        defer { lock.unlock() }
        return readLogLocked()
    }

    func recordSuccess(count: Int, at date: Date) {
        mutate { log in
            log.lastSucceededAt = date
            log.lastSucceededCount = count
        }
    }

    func recordFailure(message: String, at date: Date) {
        mutate { log in
            log.lastFailureAt = date
            log.lastFailureMessage = message
        }
    }

    func recordSkip(reason: String, at date: Date) {
        mutate { log in
            log.lastSkippedAt = date
            log.lastSkippedReason = reason
        }
    }

    func recordClear(at date: Date) {
        mutate { log in
            log.lastClearedAt = date
        }
    }

    private func readLogLocked() -> AppAutoFillPublishLog {
        guard
            let data = userDefaults.data(forKey: key),
            let log = try? JSONDecoder().decode(AppAutoFillPublishLog.self, from: data)
        else {
            return AppAutoFillPublishLog()
        }
        return log
    }

    private func mutate(_ body: (inout AppAutoFillPublishLog) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var log = readLogLocked()
        body(&log)
        guard let data = try? JSONEncoder().encode(log) else { return }
        userDefaults.set(data, forKey: key)
    }
}

enum AppAutoFillPublishErrorMessage {
    /// 只保留系统给出的错误描述，并截断长度，避免把任何上下文写入记录。
    static func message(for error: any Error) -> String {
        let description: String
        if
            let localizedError = error as? any LocalizedError,
            let errorDescription = localizedError.errorDescription,
            !errorDescription.isEmpty
        {
            description = errorDescription
        } else {
            description = error.localizedDescription
        }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return String(localized: "系统未返回错误原因。") }
        return String(trimmed.prefix(160))
    }
}

extension AutoFillGuardPublishBlockReason {
    /// 诊断面板展示用的简短说明。
    var displayText: String {
        switch self {
        case .vaultLocked:
            return String(localized: "保险库未解锁")
        case .biometricUnlockRequired:
            return String(localized: "等待生物识别解锁")
        }
    }

    /// 写入发布记录时的原因文案。
    var skipReasonText: String {
        switch self {
        case .vaultLocked:
            return String(localized: "保险库未解锁，未发布身份。")
        case .biometricUnlockRequired:
            return String(localized: "尚未通过生物识别解锁，未发布身份。")
        }
    }
}
