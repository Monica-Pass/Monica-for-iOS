//
//  PlusEntitlementTests.swift
//  MonicaCoreTests
//

import Foundation
import Testing
@testable import MonicaCore

@Suite("Monica Plus 权益判定")
struct PlusEntitlementTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fact(
        id: UInt64 = 1,
        product: String = "app.monica.plus.lifetime",
        purchaseOffset: TimeInterval = -86_400,
        expiresOffset: TimeInterval? = nil,
        revokedOffset: TimeInterval? = nil,
        isUpgraded: Bool = false,
        isVerified: Bool = true
    ) -> PlusTransactionFacts {
        PlusTransactionFacts(
            id: id,
            productID: product,
            purchaseDate: now.addingTimeInterval(purchaseOffset),
            expirationDate: expiresOffset.map { now.addingTimeInterval($0) },
            revocationDate: revokedOffset.map { now.addingTimeInterval($0) },
            isUpgraded: isUpgraded,
            isVerified: isVerified
        )
    }

    @Test("空事务没有权益")
    func emptyTransactions() {
        let entitlement = PlusEntitlementEvaluator.entitlement(from: [], now: now)
        #expect(!entitlement.isActive)
        #expect(entitlement.verifiedAt == now)
    }

    @Test("买断事务产生永久权益")
    func lifetimePurchase() {
        let entitlement = PlusEntitlementEvaluator.entitlement(from: [fact()], now: now)
        #expect(entitlement.isActive)
        #expect(entitlement.isPermanent)
        #expect(entitlement.productID == "app.monica.plus.lifetime")
    }

    @Test("未验证事务不产生权益")
    func unverifiedIgnored() {
        let entitlement = PlusEntitlementEvaluator.entitlement(from: [fact(isVerified: false)], now: now)
        #expect(!entitlement.isActive)
    }

    @Test("已退款事务不产生权益")
    func revokedIgnored() {
        let entitlement = PlusEntitlementEvaluator.entitlement(
            from: [fact(revokedOffset: -3_600)],
            now: now
        )
        #expect(!entitlement.isActive)
    }

    @Test("已升级替换的旧事务不产生权益")
    func upgradedIgnored() {
        let entitlement = PlusEntitlementEvaluator.entitlement(from: [fact(isUpgraded: true)], now: now)
        #expect(!entitlement.isActive)
    }

    @Test("过期订阅不产生权益")
    func expiredSubscriptionIgnored() {
        let entitlement = PlusEntitlementEvaluator.entitlement(
            from: [fact(product: "app.monica.plus.yearly", expiresOffset: -60)],
            now: now
        )
        #expect(!entitlement.isActive)
    }

    @Test("有效订阅保留到期时间")
    func activeSubscription() {
        let entitlement = PlusEntitlementEvaluator.entitlement(
            from: [fact(product: "app.monica.plus.yearly", expiresOffset: 86_400 * 30)],
            now: now
        )
        #expect(entitlement.isActive)
        #expect(!entitlement.isPermanent)
        #expect(entitlement.expiresAt == now.addingTimeInterval(86_400 * 30))
    }

    @Test("买断优先于订阅")
    func lifetimeBeatsSubscription() {
        let facts = [
            fact(id: 2, product: "app.monica.plus.yearly", expiresOffset: 86_400 * 30),
            fact(id: 3, product: "app.monica.plus.lifetime", purchaseOffset: -10)
        ]
        let entitlement = PlusEntitlementEvaluator.entitlement(from: facts, now: now)
        #expect(entitlement.productID == "app.monica.plus.lifetime")
        #expect(entitlement.isPermanent)
    }

    @Test("多条订阅取到期最晚的一条")
    func latestSubscriptionWins() {
        let facts = [
            fact(id: 4, product: "app.monica.plus.yearly", purchaseOffset: -200_000, expiresOffset: 86_400),
            fact(id: 5, product: "app.monica.plus.yearly", purchaseOffset: -100_000, expiresOffset: 86_400 * 90)
        ]
        let entitlement = PlusEntitlementEvaluator.entitlement(from: facts, now: now)
        #expect(entitlement.productID == "app.monica.plus.yearly")
        #expect(entitlement.expiresAt == now.addingTimeInterval(86_400 * 90))
    }

    @Test("空白产品 ID 视为无效")
    func blankProductIgnored() {
        let entitlement = PlusEntitlementEvaluator.entitlement(from: [fact(product: "   ")], now: now)
        #expect(!entitlement.isActive)
    }

    @Test("快照到期后不再视为支持者")
    func snapshotExpiryIsTimeAware() {
        let snapshot = PlusEntitlement(
            productID: "app.monica.plus.yearly",
            expiresAt: now.addingTimeInterval(86_400),
            verifiedAt: now
        )
        #expect(snapshot.isActive)
        #expect(snapshot.isActive(at: now))
        #expect(snapshot.isActive(at: now.addingTimeInterval(86_399)))
        #expect(!snapshot.isActive(at: now.addingTimeInterval(86_401)))
    }

    @Test("买断快照在任何时间都有效")
    func permanentSnapshotNeverExpires() {
        let snapshot = PlusEntitlement(productID: "app.monica.plus.lifetime", verifiedAt: now)
        #expect(snapshot.isActive(at: now.addingTimeInterval(86_400 * 365 * 50)))
        #expect(!PlusEntitlement.inactive(verifiedAt: now).isActive(at: now))
    }

    @Test("退款事务即使还有到期时间也不产生权益")
    func revokedWithFutureExpiryIgnored() {
        let entitlement = PlusEntitlementEvaluator.entitlement(
            from: [fact(product: "app.monica.plus.yearly", expiresOffset: 86_400, revokedOffset: -60)],
            now: now
        )
        #expect(!entitlement.isActive)
    }

    // MARK: - 产品目录

    @Test("数组形式的产品 ID 被保留顺序并去重")
    func catalogArray() {
        let identifiers = PlusProductCatalog.productIdentifiers(in: [
            PlusProductCatalog.infoPlistKey: ["app.monica.plus.lifetime", " app.monica.plus.yearly ", "app.monica.plus.lifetime", ""]
        ])
        #expect(identifiers == ["app.monica.plus.lifetime", "app.monica.plus.yearly"])
    }

    @Test("逗号分隔字符串形式的产品 ID 被拆分")
    func catalogString() {
        let identifiers = PlusProductCatalog.productIdentifiers(in: [
            PlusProductCatalog.infoPlistKey: "app.monica.plus.lifetime, app.monica.plus.yearly"
        ])
        #expect(identifiers == ["app.monica.plus.lifetime", "app.monica.plus.yearly"])
    }

    @Test("未配置产品 ID 时返回空数组")
    func catalogMissingKey() {
        #expect(PlusProductCatalog.productIdentifiers(in: [:]).isEmpty)
        #expect(PlusProductCatalog.productIdentifiers(in: [PlusProductCatalog.infoPlistKey: [Any]()]).isEmpty)
        #expect(PlusProductCatalog.productIdentifiers(in: [PlusProductCatalog.infoPlistKey: 42]).isEmpty)
    }

    @Test("购买结果只有成功才算成功")
    func purchaseResultSuccess() {
        #expect(PlusPurchaseResult.purchased(productID: "x").isSuccess)
        #expect(!PlusPurchaseResult.userCancelled.isSuccess)
        #expect(!PlusPurchaseResult.pending.isSuccess)
        #expect(!PlusPurchaseResult.unverified.isSuccess)
        #expect(!PlusPurchaseResult.nothingToRestore.isSuccess)
    }
}
