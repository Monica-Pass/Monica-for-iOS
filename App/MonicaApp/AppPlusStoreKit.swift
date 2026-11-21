//
//  AppPlusStoreKit.swift
//  Monica
//
//  StoreKit 2 生产实现：非消耗型「支持作者」赞助商品。
//
//  只接受 `VerificationResult.verified` 的事务；unverified 不会产生任何权益。
//  商品 ID 只从 Info.plist 的 `MonicaPlusProductIDs` 读取，价格与名称全部来自
//  StoreKit 的 `displayPrice` / `displayName`，不在代码里猜测或硬编码。
//

import Foundation
import MonicaCore
import StoreKit

struct AppPlusProductInfo: Sendable, Equatable, Identifiable {
    let id: String
    let displayName: String
    let displayPrice: String
    let description: String
}

enum AppPlusPurchaseError: Error, Sendable, Equatable, LocalizedError {
    case notConfigured
    case productUnavailable
    case userCancelled
    case networkUnavailable
    case purchaseFailed

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "Monica Plus 尚未在此版本开放。")
        case .productUnavailable:
            return String(localized: "该商品当前不可用，请稍后重试。")
        case .userCancelled:
            return String(localized: "已取消购买。")
        case .networkUnavailable:
            return String(localized: "网络连接不可用，请稍后重试。")
        case .purchaseFailed:
            return String(localized: "购买失败，请稍后重试。")
        }
    }
}

protocol AppPlusPurchaseService: Sendable {
    /// 返回配置里存在且 App Store 可售的商品，按配置顺序排列；未配置时返回空数组。
    func loadProducts() async throws -> [AppPlusProductInfo]

    func purchase(productID: String) async throws -> PlusPurchaseResult

    /// 触发 App Store 恢复（可能要求登录），返回恢复后的权益；没有可恢复项时返回 inactive。
    func restore() async throws -> PlusEntitlement

    /// 以 `Transaction.currentEntitlements` 为准的当前权益（只统计已验证事务）。
    func currentEntitlement() async -> PlusEntitlement

    /// `Transaction.updates` 的权益流：购买批准（Ask-to-Buy）、退款、撤销等变化。
    var updatesStream: AsyncStream<PlusEntitlement> { get }
}

struct StoreKitAppPlusPurchaseService: AppPlusPurchaseService {
    let productIdentifiers: [String]

    init(productIdentifiers: [String]) {
        self.productIdentifiers = productIdentifiers
    }

    init(infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        self.init(productIdentifiers: PlusProductCatalog.productIdentifiers(in: infoDictionary))
    }

    func loadProducts() async throws -> [AppPlusProductInfo] {
        guard !productIdentifiers.isEmpty else {
            return []
        }
        let products: [Product]
        do {
            products = try await Product.products(for: productIdentifiers)
        } catch {
            throw Self.mapped(error)
        }
        let order = Dictionary(
            uniqueKeysWithValues: productIdentifiers.enumerated().map { ($0.element, $0.offset) }
        )
        return products
            .sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
            .map { product in
                AppPlusProductInfo(
                    id: product.id,
                    displayName: product.displayName,
                    displayPrice: product.displayPrice,
                    description: product.description
                )
            }
    }

    func purchase(productID: String) async throws -> PlusPurchaseResult {
        guard productIdentifiers.contains(productID) else {
            throw AppPlusPurchaseError.notConfigured
        }

        let products: [Product]
        do {
            products = try await Product.products(for: [productID])
        } catch {
            throw Self.mapped(error)
        }
        guard let product = products.first(where: { $0.id == productID }) else {
            throw AppPlusPurchaseError.productUnavailable
        }

        let result: Product.PurchaseResult
        do {
            result = try await product.purchase()
        } catch {
            throw Self.mapped(error)
        }

        switch result {
        case .success(let verification):
            switch verification {
            case .verified(let transaction):
                // 只有 verified 事务才结案；unverified 保持未完成状态，同时不产生权益。
                await transaction.finish()
                return .purchased(productID: transaction.productID)
            case .unverified:
                return .unverified
            }
        case .userCancelled:
            return .userCancelled
        case .pending:
            // Ask-to-Buy 等场景：批准后由 Transaction.updates 推送。
            return .pending
        @unknown default:
            return .pending
        }
    }

    func restore() async throws -> PlusEntitlement {
        do {
            try await AppStore.sync()
        } catch {
            throw Self.mapped(error)
        }
        return await currentEntitlement()
    }

    func currentEntitlement() async -> PlusEntitlement {
        // 未配置商品 ID 时无法区分哪些事务属于 Monica Plus，按无权益处理。
        guard !productIdentifiers.isEmpty else {
            return .inactive(verifiedAt: Date())
        }
        var facts: [PlusTransactionFacts] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else {
                continue
            }
            // 只统计配置里声明的 Monica Plus 商品，避免把其他内购当成支持者权益。
            guard productIdentifiers.contains(transaction.productID) else {
                continue
            }
            facts.append(
                PlusTransactionFacts(
                    id: transaction.id,
                    productID: transaction.productID,
                    purchaseDate: transaction.purchaseDate,
                    expirationDate: transaction.expirationDate,
                    revocationDate: transaction.revocationDate,
                    isUpgraded: transaction.isUpgraded,
                    isVerified: true
                )
            )
        }
        return PlusEntitlementEvaluator.entitlement(from: facts, now: Date())
    }

    var updatesStream: AsyncStream<PlusEntitlement> {
        AsyncStream { continuation in
            let task = Task {
                for await result in Transaction.updates {
                    guard !Task.isCancelled else {
                        return
                    }
                    guard case .verified(let transaction) = result else {
                        continue
                    }
                    await transaction.finish()
                    continuation.yield(await currentEntitlement())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func mapped(_ error: Error) -> AppPlusPurchaseError {
        if let appError = error as? AppPlusPurchaseError {
            return appError
        }
        guard let storeKitError = error as? StoreKitError else {
            return .purchaseFailed
        }
        switch storeKitError {
        case .userCancelled:
            return .userCancelled
        case .networkError:
            return .networkUnavailable
        case .notAvailableInStorefront, .notEntitled, .unsupported, .systemError:
            return .productUnavailable
        default:
            return .purchaseFailed
        }
    }
}
