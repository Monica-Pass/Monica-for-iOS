//
//  AppPlusSupport.swift
//  Monica
//
//  Monica Plus 是「支持作者」型非消耗型赞助商品：购买只产生支持者徽章与感谢，
//  不解锁、也不锁定任何既有功能。所有功能永久免费。
//
//  权益判定收敛在 MonicaCore 的 `PlusEntitlementEvaluator`（只接受已验证事务）；
//  这里只负责 App 侧的状态、持久化快照与展示文案。
//

import Foundation
import MonicaCore

struct AppPlusEntitlementStatusRow: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let systemImage: String
}

/// 免费功能行：`value` 恒为「永久免费」，Monica Plus 不会改变任何功能可用性。
struct AppPlusFeatureRow: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String

    var value: String {
        String(localized: "永久免费")
    }
}

/// 权益快照存储。
///
/// 只允许保存 `PlusEntitlement`（productID / expiresAt / verifiedAt）。
/// 不收据原文、不保存「永久解锁」布尔值：真实权益始终以 StoreKit 的已验证事务为准。
protocol AppPlusEntitlementStore: Sendable {
    func loadEntitlement() -> PlusEntitlement?
    func saveEntitlement(_ entitlement: PlusEntitlement)
    func clearEntitlement()
}

/// UserDefaults 里的快照形态：只有三个字段，故意不含任何收据/交易原文。
private struct AppPlusPersistedEntitlement: Codable, Equatable {
    let productID: String?
    let expiresAt: Date?
    let verifiedAt: Date

    init(_ entitlement: PlusEntitlement) {
        self.productID = entitlement.productID
        self.expiresAt = entitlement.expiresAt
        self.verifiedAt = entitlement.verifiedAt
    }

    var entitlement: PlusEntitlement {
        PlusEntitlement(productID: productID, expiresAt: expiresAt, verifiedAt: verifiedAt)
    }
}

final class UserDefaultsAppPlusEntitlementStore: AppPlusEntitlementStore, @unchecked Sendable {
    /// v1：替代旧的 `monica.plusEntitlement` 假解锁布尔值；旧键不再读取。
    static let storageKey = "monica.plus.entitlementSnapshot.v1"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func loadEntitlement() -> PlusEntitlement? {
        guard let data = userDefaults.data(forKey: Self.storageKey),
              let persisted = try? JSONDecoder().decode(AppPlusPersistedEntitlement.self, from: data)
        else {
            return nil
        }
        return persisted.entitlement
    }

    func saveEntitlement(_ entitlement: PlusEntitlement) {
        guard entitlement.isActive else {
            clearEntitlement()
            return
        }
        guard let data = try? JSONEncoder().encode(AppPlusPersistedEntitlement(entitlement)) else {
            return
        }
        userDefaults.set(data, forKey: Self.storageKey)
    }

    func clearEntitlement() {
        userDefaults.removeObject(forKey: Self.storageKey)
    }
}

final class MemoryAppPlusEntitlementStore: AppPlusEntitlementStore, @unchecked Sendable {
    private var entitlement: PlusEntitlement?

    init(entitlement: PlusEntitlement? = nil) {
        self.entitlement = entitlement
    }

    /// 测试与诊断用：只包含快照字段，可直接断言没有收据原文。
    var persistedDebugText: String {
        guard let entitlement,
              let data = try? JSONEncoder().encode(AppPlusPersistedEntitlement(entitlement))
        else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    func loadEntitlement() -> PlusEntitlement? {
        entitlement
    }

    func saveEntitlement(_ entitlement: PlusEntitlement) {
        self.entitlement = entitlement.isActive ? entitlement : nil
    }

    func clearEntitlement() {
        entitlement = nil
    }
}

/// 购买 / 恢复的状态机。失败与取消只影响提示，不影响任何功能可用性。
enum AppPlusPurchaseState: Sendable, Equatable {
    case idle
    case purchasing(productID: String)
    case restoring
    case succeeded
    case userCancelled
    case pending
    case nothingToRestore
    case failed(String)

    var isRunning: Bool {
        switch self {
        case .purchasing, .restoring:
            return true
        case .idle, .succeeded, .userCancelled, .pending, .nothingToRestore, .failed:
            return false
        }
    }

    var label: String {
        switch self {
        case .idle:
            return String(localized: "就绪")
        case .purchasing:
            return String(localized: "正在购买")
        case .restoring:
            return String(localized: "正在恢复购买")
        case .succeeded:
            return String(localized: "感谢支持")
        case .userCancelled:
            return String(localized: "已取消")
        case .pending:
            return String(localized: "等待批准")
        case .nothingToRestore:
            return String(localized: "没有可恢复的购买")
        case .failed(let message):
            return message
        }
    }
}

/// 商品列表状态：未配置（`MonicaPlusProductIDs` 为空）与加载失败都落到「暂不可用」，
/// 但免费功能不受任何影响。
enum AppPlusProductLoadState: Sendable, Equatable {
    case idle
    case loading
    case loaded
    case unavailable(String)

    var isLoading: Bool {
        if case .loading = self {
            return true
        }
        return false
    }

    var unavailableMessage: String? {
        if case .unavailable(let message) = self {
            return message
        }
        return nil
    }
}
