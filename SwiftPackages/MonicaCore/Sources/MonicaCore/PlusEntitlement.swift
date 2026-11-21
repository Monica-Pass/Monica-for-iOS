//
//  PlusEntitlement.swift
//  MonicaCore
//
//  Monica Plus 的权益判定：把 StoreKit 事务事实收敛成一份可测试的权益快照。
//  这里刻意不依赖 StoreKit —— 判定逻辑必须在没有 StoreKit 的环境（包测试、CI）里可验证。
//

import Foundation

/// 从 StoreKit 事务里抽取出来的“事实”，只保留判定所需字段。
///
/// `isVerified` 来自 `VerificationResult`：未通过签名校验的事务不得产生任何权益。
public struct PlusTransactionFacts: Sendable, Equatable {
    public var id: UInt64
    public var productID: String
    public var purchaseDate: Date
    public var expirationDate: Date?
    public var revocationDate: Date?
    public var isUpgraded: Bool
    public var isVerified: Bool

    public init(
        id: UInt64,
        productID: String,
        purchaseDate: Date,
        expirationDate: Date? = nil,
        revocationDate: Date? = nil,
        isUpgraded: Bool = false,
        isVerified: Bool = true
    ) {
        self.id = id
        self.productID = productID
        self.purchaseDate = purchaseDate
        self.expirationDate = expirationDate
        self.revocationDate = revocationDate
        self.isUpgraded = isUpgraded
        self.isVerified = isVerified
    }
}

/// 一份已验证的权益快照。`productID == nil` 表示当前没有任何有效权益。
public struct PlusEntitlement: Sendable, Equatable {
    public var productID: String?
    public var expiresAt: Date?
    public var verifiedAt: Date

    public init(productID: String? = nil, expiresAt: Date? = nil, verifiedAt: Date) {
        self.productID = productID
        self.expiresAt = expiresAt
        self.verifiedAt = verifiedAt
    }

    /// 无有效权益。`verifiedAt` 用调用方时间，便于诊断“最后一次校验发生在什么时候”。
    public static func inactive(verifiedAt: Date) -> PlusEntitlement {
        PlusEntitlement(productID: nil, expiresAt: nil, verifiedAt: verifiedAt)
    }

    public var isActive: Bool {
        productID != nil
    }

    /// 是否是一次性买断（没有到期时间）。
    public var isPermanent: Bool {
        isActive && expiresAt == nil
    }

    /// 展示用判定：订阅到期后即使快照里仍保留 productID，也不再视为支持者。
    ///
    /// 快照只负责离线展示，真正续期必须以 StoreKit 的 `Transaction.currentEntitlements`
    /// 为准；这里不会凭空延长权益。
    public func isActive(at date: Date) -> Bool {
        guard productID != nil else { return false }
        guard let expiresAt else { return true }
        return expiresAt > date
    }
}

public enum PlusEntitlementEvaluator {
    /// 把事务事实收敛成权益快照。
    ///
    /// 规则（顺序即优先级）：
    /// 1. 未验证的事务直接丢弃 —— 不接受任何未验证结果；
    /// 2. 已退款/撤销（`revocationDate != nil`）丢弃；
    /// 3. 已被升级替换（`isUpgraded`）丢弃；
    /// 4. 已过期的订阅丢弃；
    /// 5. 剩余事务里取到期时间最晚的一条；买断（无到期时间）优先级最高。
    public static func entitlement(from facts: [PlusTransactionFacts], now: Date) -> PlusEntitlement {
        let usable = facts.filter { fact in
            guard fact.isVerified else { return false }
            guard fact.revocationDate == nil else { return false }
            guard !fact.isUpgraded else { return false }
            if let expirationDate = fact.expirationDate, expirationDate <= now {
                return false
            }
            return !fact.productID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        guard let winner = usable.max(by: { lhs, rhs in
            isOrderedBefore(lhs, rhs)
        }) else {
            return .inactive(verifiedAt: now)
        }

        return PlusEntitlement(productID: winner.productID, expiresAt: winner.expirationDate, verifiedAt: now)
    }

    /// 谁更“弱”谁在前。买断视为无限期，排最后（即最强）。
    private static func isOrderedBefore(_ lhs: PlusTransactionFacts, _ rhs: PlusTransactionFacts) -> Bool {
        switch (lhs.expirationDate, rhs.expirationDate) {
        case (nil, nil):
            return lhs.purchaseDate < rhs.purchaseDate
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        case let (.some(left), .some(right)):
            if left == right {
                return lhs.purchaseDate < rhs.purchaseDate
            }
            return left < right
        }
    }
}

public enum PlusProductCatalog {
    /// `Info.plist` 里声明产品 ID 的键。产品 ID 必须来自 App Store Connect，禁止在代码里猜。
    public static let infoPlistKey = "MonicaPlusProductIDs"

    /// 解析配置里的产品 ID：支持字符串数组或逗号分隔字符串，去空白、去空项、保序去重。
    public static func productIdentifiers(in infoDictionary: [String: Any]) -> [String] {
        let rawValues: [String]
        switch infoDictionary[infoPlistKey] {
        case let array as [String]:
            rawValues = array
        case let array as [Any]:
            rawValues = array.compactMap { $0 as? String }
        case let string as String:
            rawValues = string.split(separator: ",").map(String.init)
        default:
            rawValues = []
        }

        var seen = Set<String>()
        var identifiers: [String] = []
        for rawValue in rawValues {
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            identifiers.append(trimmed)
        }
        return identifiers
    }
}

/// 购买/恢复的收敛结果。UI 只允许对 `.purchased` 展示成功。
public enum PlusPurchaseResult: Sendable, Equatable {
    case purchased(productID: String)
    case userCancelled
    case pending
    case unverified
    case nothingToRestore

    public var isSuccess: Bool {
        if case .purchased = self { return true }
        return false
    }
}
