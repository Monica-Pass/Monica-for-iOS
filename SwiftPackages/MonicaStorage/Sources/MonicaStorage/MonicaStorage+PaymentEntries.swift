// MARK: - 支付账户条目：类型、仓库与 MDBX 引擎实现

import Foundation
import MonicaMDBX

public enum LocalPaymentAccountKind: String, Sendable, Equatable, CaseIterable {
    case digitalWallet = "digital-wallet"
    case bankAccount = "bank-account"
    case paymentApp = "payment-app"
    case buyNowPayLater = "buy-now-pay-later"
    case cryptoWallet = "crypto-wallet"
    case other

    /// 兼容 Android 备份中的枚举名（`BANK_ACCOUNT`）与 iOS 私有导出值（`bank-account`）。
    public init(androidName: String) {
        let trimmed = androidName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored = LocalPaymentAccountKind(rawValue: trimmed.lowercased()) {
            self = stored
            return
        }
        switch trimmed.uppercased() {
        case "DIGITAL_WALLET":
            self = .digitalWallet
        case "BANK_ACCOUNT":
            self = .bankAccount
        case "PAYMENT_APP":
            self = .paymentApp
        case "BUY_NOW_PAY_LATER":
            self = .buyNowPayLater
        case "CRYPTO_WALLET":
            self = .cryptoWallet
        default:
            self = .other
        }
    }

    public var androidName: String {
        switch self {
        case .digitalWallet:
            return "DIGITAL_WALLET"
        case .bankAccount:
            return "BANK_ACCOUNT"
        case .paymentApp:
            return "PAYMENT_APP"
        case .buyNowPayLater:
            return "BUY_NOW_PAY_LATER"
        case .cryptoWallet:
            return "CRYPTO_WALLET"
        case .other:
            return "OTHER"
        }
    }

    public var displayName: String {
        switch self {
        case .digitalWallet:
            return "数字钱包"
        case .bankAccount:
            return "银行账户"
        case .paymentApp:
            return "支付应用"
        case .buyNowPayLater:
            return "先买后付"
        case .cryptoWallet:
            return "加密钱包"
        case .other:
            return "其他"
        }
    }
}

public struct LocalPaymentAccountEntryDraft: Sendable, Equatable {
    public let title: String
    public let kind: LocalPaymentAccountKind
    public let provider: String
    public let accountName: String
    public let accountHolderName: String
    public let iban: String
    public let swiftBIC: String
    public let routingNumber: String
    public let accountNumber: String
    public let currency: String
    public let notes: String
    public let metadata: VaultEntryMetadata
    /// 关联的银行卡条目 ID（稳定 ID）。
    public let linkedCardID: String
    /// 关联的账单地址条目 ID（稳定 ID）。
    public let billingAddressID: String

    public init(
        title: String,
        kind: LocalPaymentAccountKind = .other,
        provider: String = "",
        accountName: String = "",
        accountHolderName: String = "",
        iban: String = "",
        swiftBIC: String = "",
        routingNumber: String = "",
        accountNumber: String = "",
        currency: String = "",
        notes: String = "",
        metadata: VaultEntryMetadata = .empty,
        linkedCardID: String = "",
        billingAddressID: String = ""
    ) {
        self.title = title
        self.kind = kind
        self.provider = provider
        self.accountName = accountName
        self.accountHolderName = accountHolderName
        self.iban = iban
        self.swiftBIC = swiftBIC
        self.routingNumber = routingNumber
        self.accountNumber = accountNumber
        self.currency = currency
        self.notes = notes
        self.metadata = metadata
        self.linkedCardID = linkedCardID
        self.billingAddressID = billingAddressID
    }
}

public struct LocalPaymentAccountEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let kind: LocalPaymentAccountKind
    public let provider: String
    public let accountName: String
    public let accountHolderName: String
    public let iban: String
    public let swiftBIC: String
    public let routingNumber: String
    public let accountNumber: String
    public let currency: String
    public let notes: String
    public let linkedCardID: String
    public let billingAddressID: String
    public let favorite: Bool

    public init(
        id: String,
        projectID: String,
        title: String,
        kind: LocalPaymentAccountKind = .other,
        provider: String = "",
        accountName: String = "",
        accountHolderName: String = "",
        iban: String = "",
        swiftBIC: String = "",
        routingNumber: String = "",
        accountNumber: String = "",
        currency: String = "",
        notes: String = "",
        linkedCardID: String = "",
        billingAddressID: String = "",
        favorite: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.kind = kind
        self.provider = provider
        self.accountName = accountName
        self.accountHolderName = accountHolderName
        self.iban = iban
        self.swiftBIC = swiftBIC
        self.routingNumber = routingNumber
        self.accountNumber = accountNumber
        self.currency = currency
        self.notes = notes
        self.linkedCardID = linkedCardID
        self.billingAddressID = billingAddressID
        self.favorite = favorite
    }
}

/// 关联引用的解析状态：未关联 / 已关联 / 目标条目已删除（失效关联）。
public enum VaultEntryReferenceStatus: String, Sendable, Equatable {
    case none
    case linked
    case missing
}

public extension LocalPaymentAccountEntry {
    var searchableText: String {
        [
            title,
            kind.displayName,
            provider,
            accountName,
            accountHolderName,
            iban,
            swiftBIC,
            routingNumber,
            currency,
            notes
        ].joined(separator: " ")
    }

    func billingAddress(in billingAddresses: [LocalBillingAddressEntry]) -> LocalBillingAddressEntry? {
        let reference = billingAddressID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reference.isEmpty == false else {
            return nil
        }
        return billingAddresses.first { $0.id == reference }
    }

    func billingAddressReferenceStatus(in billingAddresses: [LocalBillingAddressEntry]) -> VaultEntryReferenceStatus {
        let reference = billingAddressID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reference.isEmpty == false else {
            return .none
        }
        return billingAddresses.contains { $0.id == reference } ? .linked : .missing
    }

    func linkedCard(in cards: [LocalCardEntry]) -> LocalCardEntry? {
        let reference = linkedCardID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reference.isEmpty == false else {
            return nil
        }
        return cards.first { $0.id == reference }
    }

    func linkedCardReferenceStatus(in cards: [LocalCardEntry]) -> VaultEntryReferenceStatus {
        let reference = linkedCardID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reference.isEmpty == false else {
            return .none
        }
        return cards.contains { $0.id == reference } ? .linked : .missing
    }
}

extension LocalVaultEntryRepository {
    public func createPaymentAccountEntry(projectID: String, draft: LocalPaymentAccountEntryDraft) throws -> LocalPaymentAccountEntry {
        try engine.createPaymentAccountEntry(in: session.handle, projectID: projectID, draft: normalizedPaymentAccountEntryDraft(draft))
    }

    public func listPaymentAccountEntries(projectID: String) throws -> [LocalPaymentAccountEntry] {
        try engine.listPaymentAccountEntries(in: session.handle, projectID: projectID)
    }

    public func updatePaymentAccountEntry(projectID: String, entryID: String, draft: LocalPaymentAccountEntryDraft) throws -> LocalPaymentAccountEntry {
        try engine.updatePaymentAccountEntry(in: session.handle, projectID: projectID, entryID: entryID, draft: normalizedPaymentAccountEntryDraft(draft))
    }

    public func setPaymentAccountEntryFavorite(projectID: String, entryID: String, favorite: Bool) throws -> LocalPaymentAccountEntry {
        try engine.setPaymentAccountEntryFavorite(in: session.handle, projectID: projectID, entryID: entryID, favorite: favorite)
    }

    public func deletePaymentAccountEntry(projectID: String, entryID: String) throws {
        try engine.deletePaymentAccountEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func listDeletedPaymentAccountEntries(projectID: String) throws -> [LocalPaymentAccountEntry] {
        try engine.listDeletedPaymentAccountEntries(in: session.handle, projectID: projectID)
    }

    public func restorePaymentAccountEntry(projectID: String, entryID: String) throws -> LocalPaymentAccountEntry {
        try engine.restorePaymentAccountEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    private func normalizedPaymentAccountEntryDraft(_ draft: LocalPaymentAccountEntryDraft) throws -> LocalPaymentAccountEntryDraft {
        let normalizedTitle = try normalizedEntryTitle(draft.title)
        return LocalPaymentAccountEntryDraft(
            title: normalizedTitle,
            kind: draft.kind,
            provider: draft.provider.trimmingCharacters(in: .whitespacesAndNewlines),
            accountName: draft.accountName.trimmingCharacters(in: .whitespacesAndNewlines),
            accountHolderName: draft.accountHolderName.trimmingCharacters(in: .whitespacesAndNewlines),
            iban: BillingFieldValidator.normalizedIBAN(draft.iban),
            swiftBIC: BillingFieldValidator.normalizedSWIFT(draft.swiftBIC),
            routingNumber: draft.routingNumber.trimmingCharacters(in: .whitespacesAndNewlines),
            accountNumber: draft.accountNumber.trimmingCharacters(in: .whitespacesAndNewlines),
            currency: draft.currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            notes: draft.notes,
            linkedCardID: draft.linkedCardID.trimmingCharacters(in: .whitespacesAndNewlines),
            billingAddressID: draft.billingAddressID.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

extension MDBXLocalVaultEngine {
    public func createPaymentAccountEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalPaymentAccountEntryDraft) throws -> LocalPaymentAccountEntry {
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "document-ref",
            kind: "payment-account",
            title: draft.title,
            payload: paymentAccountPayload(draft)
        )
        return try LocalPaymentAccountEntry(entry)
    }

    public func listPaymentAccountEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalPaymentAccountEntry] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "payment-account").map(LocalPaymentAccountEntry.init)
    }

    public func updatePaymentAccountEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalPaymentAccountEntryDraft) throws -> LocalPaymentAccountEntry {
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: entryID,
            entryType: "document-ref",
            kind: "payment-account",
            title: draft.title,
            payload: paymentAccountPayload(draft)
        )
        return try LocalPaymentAccountEntry(entry)
    }

    public func setPaymentAccountEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalPaymentAccountEntry {
        try LocalPaymentAccountEntry(setParityEntryFavorite(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "payment-account", favorite: favorite))
    }

    public func deletePaymentAccountEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        try deleteParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "payment-account")
    }

    public func listDeletedPaymentAccountEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalPaymentAccountEntry] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "payment-account").map(LocalPaymentAccountEntry.init)
    }

    public func restorePaymentAccountEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalPaymentAccountEntry {
        try LocalPaymentAccountEntry(restoreParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "payment-account"))
    }

    private func paymentAccountPayload(_ draft: LocalPaymentAccountEntryDraft) -> [String: Any] {
        [
            "schemaVersion": 1,
            "paymentType": draft.kind.rawValue,
            "provider": draft.provider,
            "accountName": draft.accountName,
            "accountHolderName": draft.accountHolderName,
            "iban": draft.iban,
            "swiftBic": draft.swiftBIC,
            "routingNumber": draft.routingNumber,
            "accountNumber": draft.accountNumber,
            "currency": draft.currency,
            "notes": draft.notes,
            "linkedCardID": draft.linkedCardID,
            "billingAddressID": draft.billingAddressID
        ]
    }
}

private extension LocalPaymentAccountEntry {
    init(_ entry: MonicaMDBXParityEntry) throws {
        let payload = try entry.payloadDictionary()
        let storedKindValue = payload.string("paymentType")
        let storedKind = storedKindValue.isEmpty ? "OTHER" : storedKindValue
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            kind: LocalPaymentAccountKind(androidName: storedKind),
            provider: payload.string("provider"),
            accountName: payload.string("accountName"),
            accountHolderName: payload.string("accountHolderName"),
            iban: payload.string("iban"),
            swiftBIC: payload.string("swiftBic"),
            routingNumber: payload.string("routingNumber"),
            accountNumber: payload.string("accountNumber"),
            currency: payload.string("currency"),
            notes: payload.string("notes"),
            linkedCardID: payload.string("linkedCardID"),
            billingAddressID: payload.string("billingAddressID"),
            favorite: entry.favorite
        )
    }
}
