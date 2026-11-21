//
//  AppAutoFillSupport.swift
//  Monica
//
//  自动填充策略、策略存储与自动填充索引 / 策略错误。
//

import Foundation

struct AppAutoFillPolicy: Sendable, Equatable, Codable {
    var blockedFields: [String]
    var blockedSaveTargets: [String]

    init(blockedFields: [String] = [], blockedSaveTargets: [String] = []) {
        self.blockedFields = Self.normalizedUnique(blockedFields)
        self.blockedSaveTargets = Self.normalizedUnique(blockedSaveTargets)
    }

    func blocksSaveTarget(_ value: String) -> Bool {
        let identifiers = AppAutoFillPolicy.serviceIdentifiers(for: value).map(Self.normalizedMatchValue)
        let blockedIdentifiers = blockedSaveTargets
            .flatMap(Self.serviceIdentifiers(for:))
            .map(Self.normalizedMatchValue)
        return blockedIdentifiers.contains { blocked in
            identifiers.contains(blocked)
        }
    }

    static func normalizedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return nil }
            let key = normalizedMatchValue(normalized)
            guard seen.insert(key).inserted else { return nil }
            return normalized
        }
    }

    private static func serviceIdentifiers(for value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var identifiers: [String] = []
        if let url = URL(string: trimmed),
           let host = url.host(),
           !host.isEmpty {
            identifiers.append(host)
        }
        identifiers.append(trimmed)
        return identifiers
    }

    private static func normalizedMatchValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

protocol AppAutoFillPolicyStore: Sendable {
    func loadPolicy() -> AppAutoFillPolicy
    func savePolicy(_ policy: AppAutoFillPolicy)
}

final class MemoryAppAutoFillPolicyStore: AppAutoFillPolicyStore, @unchecked Sendable {
    private var policy: AppAutoFillPolicy

    init(policy: AppAutoFillPolicy = AppAutoFillPolicy()) {
        self.policy = policy
    }

    func loadPolicy() -> AppAutoFillPolicy {
        policy
    }

    func savePolicy(_ policy: AppAutoFillPolicy) {
        self.policy = policy
    }
}

final class UserDefaultsAppAutoFillPolicyStore: AppAutoFillPolicyStore, @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(userDefaults: UserDefaults = .standard, key: String = "app.autofill.policy.v1") {
        self.userDefaults = userDefaults
        self.key = key
    }

    func loadPolicy() -> AppAutoFillPolicy {
        guard let data = userDefaults.data(forKey: key),
              let policy = try? decoder.decode(AppAutoFillPolicy.self, from: data)
        else {
            return AppAutoFillPolicy()
        }
        return policy
    }

    func savePolicy(_ policy: AppAutoFillPolicy) {
        let normalized = AppAutoFillPolicy(
            blockedFields: policy.blockedFields,
            blockedSaveTargets: policy.blockedSaveTargets
        )
        if let data = try? encoder.encode(normalized) {
            userDefaults.set(data, forKey: key)
        }
    }
}

enum AutoFillIndexState: Sendable, Equatable {
    case idle
    case running
    case succeeded(Int)
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            return String(localized: "就绪")
        case .running:
            return String(localized: "处理中")
        case .succeeded(let count):
            return String(localized: "已索引 \(count)")
        case .failed(let message):
            return message
        }
    }

    var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }
}

enum AppAutoFillPolicyError: Error, LocalizedError, Sendable, Equatable {
    case saveTargetBlocked

    var errorDescription: String? {
        switch self {
        case .saveTargetBlocked:
            return String(localized: "自动填充保存目标已被忽略。")
        }
    }
}

enum AppAutoFillIndexError: Error, Sendable, Equatable, LocalizedError {
    case vaultLocked
    case indexStoreUnavailable
    case indexKeyVaultMismatch

    var errorDescription: String? {
        switch self {
        case .vaultLocked:
            return String(localized: "更新自动填充前必须先解锁保险库。")
        case .indexStoreUnavailable:
            return String(localized: "自动填充索引存储不可用。")
        case .indexKeyVaultMismatch:
            return String(localized: "自动填充索引密钥与当前保险库不匹配。")
        }
    }
}
