//
//  AppPlusSupport.swift
//  Monica
//
//  Monica+ 权益行模型、权益快照、解锁服务与权益存储。
//

import Foundation

struct AppPlusEntitlementStatusRow: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let systemImage: String
}

struct AppPlusFeatureRow: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let isUnlocked: Bool

    var value: String {
        isUnlocked ? String(localized: "已解锁") : String(localized: "需要 Plus")
    }
}

enum AppPlusEntitlementSource: Sendable, Equatable {
    case none
    case resourceUnlock
}

struct AppPlusEntitlementSnapshot: Sendable, Equatable {
    var source: AppPlusEntitlementSource = .none
    var expiresAt: Date?

    var isActive: Bool {
        source != .none
    }
}

protocol AppPlusResourceUnlockService: Sendable {
    func unlockPlus() async throws -> Bool
}

struct DefaultAppPlusResourceUnlockService: AppPlusResourceUnlockService {
    func unlockPlus() async throws -> Bool {
        true
    }
}

protocol AppPlusEntitlementStore: Sendable {
    func loadIsResourceUnlocked() -> Bool
    func saveIsResourceUnlocked(_ isUnlocked: Bool)
}

private struct AppPlusPersistedEntitlement: Codable, Equatable {
    let source: String?

    static let inactive = AppPlusPersistedEntitlement(source: nil)
    static let resourceUnlock = AppPlusPersistedEntitlement(source: "resourceUnlock")

    var isResourceUnlocked: Bool {
        source == Self.resourceUnlock.source
    }
}

final class UserDefaultsAppPlusEntitlementStore: AppPlusEntitlementStore, @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let key = "monica.plusEntitlement"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func loadIsResourceUnlocked() -> Bool {
        guard let data = userDefaults.data(forKey: key),
              let entitlement = try? JSONDecoder().decode(AppPlusPersistedEntitlement.self, from: data)
        else {
            return false
        }
        return entitlement.isResourceUnlocked
    }

    func saveIsResourceUnlocked(_ isUnlocked: Bool) {
        let entitlement: AppPlusPersistedEntitlement = isUnlocked ? .resourceUnlock : .inactive
        guard let data = try? JSONEncoder().encode(entitlement) else {
            return
        }
        userDefaults.set(data, forKey: key)
    }
}

final class MemoryAppPlusEntitlementStore: AppPlusEntitlementStore, @unchecked Sendable {
    private var entitlement: AppPlusPersistedEntitlement

    init(isResourceUnlocked: Bool = false) {
        self.entitlement = isResourceUnlocked ? .resourceUnlock : .inactive
    }

    var persistedDebugText: String {
        guard let data = try? JSONEncoder().encode(entitlement) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    func loadIsResourceUnlocked() -> Bool {
        entitlement.isResourceUnlocked
    }

    func saveIsResourceUnlocked(_ isUnlocked: Bool) {
        entitlement = isUnlocked ? .resourceUnlock : .inactive
    }
}

enum PlusActivationState: Sendable, Equatable {
    case idle
    case running
    case activated
    case deactivated
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            return String(localized: "就绪")
        case .running:
            return String(localized: "处理中")
        case .activated:
            return String(localized: "Plus 已激活")
        case .deactivated:
            return String(localized: "Plus 已关闭")
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

enum AppPlusResourceUnlockError: Error, Sendable, Equatable, LocalizedError {
    case serviceUnavailable
    case activationRejected

    var errorDescription: String? {
        switch self {
        case .serviceUnavailable:
            return String(localized: "Plus 解锁服务不可用。")
        case .activationRejected:
            return String(localized: "Plus 解锁未通过。")
        }
    }
}
