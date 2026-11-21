// MARK: - 账单地址条目：类型、字段校验、仓库与 MDBX 引擎实现

import Foundation
import MonicaMDBX

/// 账单地址的展示行拼装规则（国家/地区差异只影响排版，不做任何有效性判断）。
public enum BillingAddressLines {
    public static func lines(
        streetAddress: String,
        apartment: String,
        city: String,
        stateProvince: String,
        postalCode: String,
        country: String
    ) -> [String] {
        var lines: [String] = []
        let street = streetAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = apartment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !street.isEmpty {
            lines.append(street)
        }
        if !unit.isEmpty {
            lines.append(unit)
        }
        let region = [city, stateProvince]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let zone = [postalCode, country]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let locality = [region, zone].filter { !$0.isEmpty }.joined(separator: " ")
        if !locality.isEmpty {
            lines.append(locality)
        }
        return lines
    }

    public static func singleLine(
        streetAddress: String,
        apartment: String,
        city: String,
        stateProvince: String,
        postalCode: String,
        country: String
    ) -> String {
        lines(
            streetAddress: streetAddress,
            apartment: apartment,
            city: city,
            stateProvince: stateProvince,
            postalCode: postalCode,
            country: country
        ).joined(separator: ", ")
    }
}

public struct LocalBillingAddressEntryDraft: Sendable, Equatable {
    public let title: String
    public let fullName: String
    public let streetAddress: String
    public let apartment: String
    public let city: String
    public let stateProvince: String
    public let postalCode: String
    public let country: String
    public let phone: String
    public let notes: String
    public let metadata: VaultEntryMetadata
    /// 引用该地址的银行卡条目 ID（稳定 ID，不使用卡片展示名）。
    public let linkedCardIDs: [String]

    public init(
        title: String,
        fullName: String = "",
        streetAddress: String = "",
        apartment: String = "",
        city: String = "",
        stateProvince: String = "",
        postalCode: String = "",
        country: String = "",
        phone: String = "",
        notes: String = "",
        metadata: VaultEntryMetadata = .empty,
        linkedCardIDs: [String] = []
    ) {
        self.title = title
        self.fullName = fullName
        self.streetAddress = streetAddress
        self.apartment = apartment
        self.city = city
        self.stateProvince = stateProvince
        self.postalCode = postalCode
        self.country = country
        self.phone = phone
        self.notes = notes
        self.metadata = metadata
        self.linkedCardIDs = linkedCardIDs
    }
}

public struct LocalBillingAddressEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let fullName: String
    public let streetAddress: String
    public let apartment: String
    public let city: String
    public let stateProvince: String
    public let postalCode: String
    public let country: String
    public let phone: String
    public let notes: String
    public let linkedCardIDs: [String]
    public let favorite: Bool

    public init(
        id: String,
        projectID: String,
        title: String,
        fullName: String = "",
        streetAddress: String = "",
        apartment: String = "",
        city: String = "",
        stateProvince: String = "",
        postalCode: String = "",
        country: String = "",
        phone: String = "",
        notes: String = "",
        linkedCardIDs: [String] = [],
        favorite: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.fullName = fullName
        self.streetAddress = streetAddress
        self.apartment = apartment
        self.city = city
        self.stateProvince = stateProvince
        self.postalCode = postalCode
        self.country = country
        self.phone = phone
        self.notes = notes
        self.linkedCardIDs = linkedCardIDs
        self.favorite = favorite
    }
}

public extension LocalBillingAddressEntry {
    var addressLines: [String] {
        BillingAddressLines.lines(
            streetAddress: streetAddress,
            apartment: apartment,
            city: city,
            stateProvince: stateProvince,
            postalCode: postalCode,
            country: country
        )
    }

    var formattedAddress: String {
        addressLines.joined(separator: "\n")
    }

    var addressSummary: String {
        BillingAddressLines.singleLine(
            streetAddress: streetAddress,
            apartment: apartment,
            city: city,
            stateProvince: stateProvince,
            postalCode: postalCode,
            country: country
        )
    }

    var searchableText: String {
        [
            title,
            fullName,
            streetAddress,
            apartment,
            city,
            stateProvince,
            postalCode,
            country,
            phone,
            notes
        ].joined(separator: " ")
    }

    /// 解析引用的银行卡条目；已被删除的引用会被忽略，由 UI 通过 `missingLinkedCardIDs(in:)` 提示。
    func linkedCards(in cards: [LocalCardEntry]) -> [LocalCardEntry] {
        linkedCardIDs.compactMap { id in cards.first { $0.id == id } }
    }

    func missingLinkedCardIDs(in cards: [LocalCardEntry]) -> [String] {
        linkedCardIDs.filter { id in cards.contains { $0.id == id } == false }
    }
}

public enum BillingFieldValidationIssue: Sendable, Equatable {
    case ibanCharacters
    case ibanLength
    case ibanChecksum
    case swiftCharacters
    case swiftLength
    case routingNumberFormat
    case postalCodeFormat
    case currencyFormat
}

/// 温和格式校验：只提示格式/长度层面的可疑输入，不判断账户或地址在现实中是否有效，
/// 也不做 US-only 的 IBAN/routing number 强制约束。
public enum BillingFieldValidator {
    public static let minimumIBANLength = 15
    public static let maximumIBANLength = 34
    public static let minimumSWIFTLIength = 8
    public static let maximumSWIFTLength = 11
    public static let maximumReferenceLength = 34
    public static let maximumPostalCodeLength = 16

    public static func normalizedIBAN(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .uppercased()
    }

    public static func normalizedSWIFT(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    public static func ibanIssue(_ value: String) -> BillingFieldValidationIssue? {
        let normalized = normalizedIBAN(value)
        guard normalized.isEmpty == false else {
            return nil
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        guard normalized.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return .ibanCharacters
        }
        guard (minimumIBANLength...maximumIBANLength).contains(normalized.count) else {
            return .ibanLength
        }
        guard isValidIBANChecksum(normalized) else {
            return .ibanChecksum
        }
        return nil
    }

    public static func swiftBICIssue(_ value: String) -> BillingFieldValidationIssue? {
        let normalized = normalizedSWIFT(value)
        guard normalized.isEmpty == false else {
            return nil
        }
        guard normalized.count == minimumSWIFTLIength || normalized.count == maximumSWIFTLength else {
            return .swiftLength
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        guard normalized.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return .swiftCharacters
        }
        return nil
    }

    /// 路由号/清算号：只要求是字母、数字、空格或连字符，长度合理，不套用任何国家的固定长度。
    public static func routingNumberIssue(_ value: String) -> BillingFieldValidationIssue? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 -")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return .routingNumberFormat
        }
        guard trimmed.count <= maximumReferenceLength else {
            return .routingNumberFormat
        }
        return nil
    }

    public static func postalCodeIssue(_ value: String) -> BillingFieldValidationIssue? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 -")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return .postalCodeFormat
        }
        guard trimmed.count <= maximumPostalCodeLength else {
            return .postalCodeFormat
        }
        return nil
    }

    public static func currencyIssue(_ value: String) -> BillingFieldValidationIssue? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }
        guard trimmed.count == 3 else {
            return .currencyFormat
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return .currencyFormat
        }
        return nil
    }

    /// 账号/IBAN 的掩码展示：保留末 4 位，其余用圆点占位。
    public static func maskedAccountNumber(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return ""
        }
        guard trimmed.count > 4 else {
            return String(repeating: "•", count: trimmed.count)
        }
        return String(repeating: "•", count: trimmed.count - 4) + trimmed.suffix(4)
    }

    private static func isValidIBANChecksum(_ iban: String) -> Bool {
        let rearranged = String(iban.dropFirst(4)) + String(iban.prefix(4))
        var remainder = 0
        for scalar in rearranged.unicodeScalars {
            let value: Int
            if scalar.value >= 48, scalar.value <= 57 {
                value = Int(scalar.value - 48)
            } else if scalar.value >= 65, scalar.value <= 90 {
                value = Int(scalar.value - 65) + 10
            } else {
                return false
            }
            remainder = value >= 10 ? (remainder * 100 + value) % 97 : (remainder * 10 + value) % 97
        }
        return remainder == 1
    }
}

extension LocalVaultEntryRepository {
    public func createBillingAddressEntry(projectID: String, draft: LocalBillingAddressEntryDraft) throws -> LocalBillingAddressEntry {
        try engine.createBillingAddressEntry(in: session.handle, projectID: projectID, draft: normalizedBillingAddressEntryDraft(draft))
    }

    public func listBillingAddressEntries(projectID: String) throws -> [LocalBillingAddressEntry] {
        try engine.listBillingAddressEntries(in: session.handle, projectID: projectID)
    }

    public func updateBillingAddressEntry(projectID: String, entryID: String, draft: LocalBillingAddressEntryDraft) throws -> LocalBillingAddressEntry {
        try engine.updateBillingAddressEntry(in: session.handle, projectID: projectID, entryID: entryID, draft: normalizedBillingAddressEntryDraft(draft))
    }

    public func setBillingAddressEntryFavorite(projectID: String, entryID: String, favorite: Bool) throws -> LocalBillingAddressEntry {
        try engine.setBillingAddressEntryFavorite(in: session.handle, projectID: projectID, entryID: entryID, favorite: favorite)
    }

    public func deleteBillingAddressEntry(projectID: String, entryID: String) throws {
        try engine.deleteBillingAddressEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func listDeletedBillingAddressEntries(projectID: String) throws -> [LocalBillingAddressEntry] {
        try engine.listDeletedBillingAddressEntries(in: session.handle, projectID: projectID)
    }

    public func restoreBillingAddressEntry(projectID: String, entryID: String) throws -> LocalBillingAddressEntry {
        try engine.restoreBillingAddressEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    private func normalizedBillingAddressEntryDraft(_ draft: LocalBillingAddressEntryDraft) throws -> LocalBillingAddressEntryDraft {
        let normalizedTitle = try normalizedEntryTitle(draft.title)
        return LocalBillingAddressEntryDraft(
            title: normalizedTitle,
            fullName: draft.fullName.trimmingCharacters(in: .whitespacesAndNewlines),
            streetAddress: draft.streetAddress.trimmingCharacters(in: .whitespacesAndNewlines),
            apartment: draft.apartment.trimmingCharacters(in: .whitespacesAndNewlines),
            city: draft.city.trimmingCharacters(in: .whitespacesAndNewlines),
            stateProvince: draft.stateProvince.trimmingCharacters(in: .whitespacesAndNewlines),
            postalCode: draft.postalCode.trimmingCharacters(in: .whitespacesAndNewlines),
            country: draft.country.trimmingCharacters(in: .whitespacesAndNewlines),
            phone: draft.phone.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: draft.notes,
            linkedCardIDs: normalizedReferenceIdentifiers(draft.linkedCardIDs)
        )
    }

    private func normalizedReferenceIdentifiers(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for identifier in identifiers {
            let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false, seen.insert(trimmed).inserted else {
                continue
            }
            result.append(trimmed)
        }
        return result
    }
}

extension MDBXLocalVaultEngine {
    public func createBillingAddressEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalBillingAddressEntryDraft) throws -> LocalBillingAddressEntry {
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "document-ref",
            kind: "billing-address",
            title: draft.title,
            payload: billingAddressPayload(draft)
        )
        return try LocalBillingAddressEntry(entry)
    }

    public func listBillingAddressEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalBillingAddressEntry] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "billing-address").map(LocalBillingAddressEntry.init)
    }

    public func updateBillingAddressEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalBillingAddressEntryDraft) throws -> LocalBillingAddressEntry {
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: entryID,
            entryType: "document-ref",
            kind: "billing-address",
            title: draft.title,
            payload: billingAddressPayload(draft)
        )
        return try LocalBillingAddressEntry(entry)
    }

    public func setBillingAddressEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalBillingAddressEntry {
        try LocalBillingAddressEntry(setParityEntryFavorite(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "billing-address", favorite: favorite))
    }

    public func deleteBillingAddressEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        try deleteParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "billing-address")
    }

    public func listDeletedBillingAddressEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalBillingAddressEntry] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "billing-address").map(LocalBillingAddressEntry.init)
    }

    public func restoreBillingAddressEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalBillingAddressEntry {
        try LocalBillingAddressEntry(restoreParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "billing-address"))
    }

    private func billingAddressPayload(_ draft: LocalBillingAddressEntryDraft) -> [String: Any] {
        [
            "schemaVersion": 1,
            "fullName": draft.fullName,
            "streetAddress": draft.streetAddress,
            "apartment": draft.apartment,
            "city": draft.city,
            "stateProvince": draft.stateProvince,
            "postalCode": draft.postalCode,
            "country": draft.country,
            "phone": draft.phone,
            "notes": draft.notes,
            "linkedCardIDs": draft.linkedCardIDs
        ]
    }
}

private extension LocalBillingAddressEntry {
    init(_ entry: MonicaMDBXParityEntry) throws {
        let payload = try entry.payloadDictionary()
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            fullName: payload.string("fullName"),
            streetAddress: payload.string("streetAddress"),
            apartment: payload.string("apartment"),
            city: payload.string("city"),
            stateProvince: payload.string("stateProvince"),
            postalCode: payload.string("postalCode"),
            country: payload.string("country"),
            phone: payload.string("phone"),
            notes: payload.string("notes"),
            linkedCardIDs: payload.stringArray("linkedCardIDs"),
            favorite: entry.favorite
        )
    }
}
