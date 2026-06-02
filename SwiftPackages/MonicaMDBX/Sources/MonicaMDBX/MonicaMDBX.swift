import Foundation

public enum MonicaMDBXBridgeState: Sendable, Equatable {
    case generatedBindingsRequired
    case ready
}

public struct MonicaMDBXBridgeInfo: Sendable, Equatable {
    public let state: MonicaMDBXBridgeState
    public let bridge: String

    public init(
        state: MonicaMDBXBridgeState = .ready,
        bridge: String = "UniFFI"
    ) {
        self.state = state
        self.bridge = bridge
    }
}

public enum MonicaMDBXBindingAvailability {
    public static let swiftBinding = "mdbx_ffi"
    public static let binaryModule = "mdbx_ffiFFI"
}

public enum MonicaMDBXError: Error, Sendable, Equatable, LocalizedError {
    case unavailableOnCurrentPlatform
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailableOnCurrentPlatform:
            return "MDBX UniFFI 桥接只在 iOS 构建中可用。"
        case .verificationFailed(let message):
            return message
        }
    }
}

public struct MonicaMDBXVaultInfo: Sendable, Equatable {
    public let vaultID: String
    public let deviceID: String
}

public struct MonicaMDBXProject: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
}

public struct MonicaMDBXLoginEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let username: String
    public let password: String
    public let url: String
    public let notes: String
    public let favorite: Bool
}

public struct MonicaMDBXNoteEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let body: String
    public let favorite: Bool
}

public struct MonicaMDBXTotpEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let secret: String
    public let issuer: String
    public let accountName: String
    public let period: UInt32
    public let digits: UInt32
    public let algorithm: String
    public let otpType: String
    public let counter: UInt64
    public let favorite: Bool
}

public struct MonicaMDBXCardEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let cardholderName: String
    public let number: String
    public let expiryMonth: String
    public let expiryYear: String
    public let cvv: String
    public let issuer: String
    public let network: String
    public let notes: String
    public let favorite: Bool
}

public struct MonicaMDBXIdentityEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let documentType: String
    public let fullName: String
    public let documentNumber: String
    public let issuer: String
    public let country: String
    public let issueDate: String
    public let expiryDate: String
    public let notes: String
    public let favorite: Bool
}

public struct MonicaMDBXParityEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let entryType: String
    public let kind: String
    public let payloadJSON: String
    public let favorite: Bool
}

public struct MonicaMDBXSmokeTestResult: Sendable, Equatable {
    public let vaultID: String
    public let deviceID: String
    public let projectTitle: String
    public let entryTitle: String
}

#if os(iOS)
public final class MonicaMDBXVault: @unchecked Sendable {
    private let rawVault: MdbxVault

    fileprivate init(rawVault: MdbxVault) {
        self.rawVault = rawVault
    }

    public func info() -> MonicaMDBXVaultInfo {
        let rawInfo = rawVault.info()
        return MonicaMDBXVaultInfo(
            vaultID: rawInfo.vaultId,
            deviceID: rawInfo.deviceId
        )
    }

    public func createProject(title: String) throws -> MonicaMDBXProject {
        let project = try rawVault.createProject(title: title)
        return MonicaMDBXProject(id: project.projectId, title: project.title)
    }

    public func createLoginEntry(
        projectID: String,
        title: String,
        username: String,
        password: String,
        url: String,
        notes: String = ""
    ) throws -> MonicaMDBXLoginEntry {
        let entry = try rawVault.createLoginEntry(
            projectId: projectID,
            title: title,
            username: username,
            password: password,
            url: url,
            notes: notes
        )
        return MonicaMDBXLoginEntry(raw: entry)
    }

    public func listLoginEntries(projectID: String) throws -> [MonicaMDBXLoginEntry] {
        try rawVault.listEntries(projectId: projectID).map(MonicaMDBXLoginEntry.init(raw:))
    }

    public func listDeletedLoginEntries(projectID: String) throws -> [MonicaMDBXLoginEntry] {
        try rawVault.listDeletedEntries(projectId: projectID).map(MonicaMDBXLoginEntry.init(raw:))
    }

    public func updateLoginEntry(
        projectID: String,
        entryID: String,
        title: String,
        username: String,
        password: String,
        url: String,
        notes: String = ""
    ) throws -> MonicaMDBXLoginEntry {
        let entry = try rawVault.updateLoginEntry(
            projectId: projectID,
            entryId: entryID,
            title: title,
            username: username,
            password: password,
            url: url,
            notes: notes
        )
        return MonicaMDBXLoginEntry(raw: entry)
    }

    public func setLoginEntryFavorite(
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> MonicaMDBXLoginEntry {
        let entry = try rawVault.setLoginFavorite(
            projectId: projectID,
            entryId: entryID,
            favorite: favorite
        )
        return MonicaMDBXLoginEntry(raw: entry)
    }

    public func deleteLoginEntry(projectID: String, entryID: String) throws {
        try rawVault.deleteLoginEntry(projectId: projectID, entryId: entryID)
    }

    public func restoreLoginEntry(
        projectID: String,
        entryID: String
    ) throws -> MonicaMDBXLoginEntry {
        let entry = try rawVault.restoreLoginEntry(projectId: projectID, entryId: entryID)
        return MonicaMDBXLoginEntry(raw: entry)
    }

    public func moveLoginEntry(
        projectID: String,
        entryID: String,
        targetProjectID: String
    ) throws -> MonicaMDBXLoginEntry {
        let entry = try rawVault.moveLoginEntry(
            projectId: projectID,
            entryId: entryID,
            targetProjectId: targetProjectID
        )
        return MonicaMDBXLoginEntry(raw: entry)
    }

    public func createNoteEntry(
        projectID: String,
        title: String,
        body: String
    ) throws -> MonicaMDBXNoteEntry {
        let entry = try rawVault.createNoteEntry(
            projectId: projectID,
            title: title,
            body: body
        )
        return MonicaMDBXNoteEntry(raw: entry)
    }

    public func listNoteEntries(projectID: String) throws -> [MonicaMDBXNoteEntry] {
        try rawVault.listNoteEntries(projectId: projectID).map(MonicaMDBXNoteEntry.init(raw:))
    }

    public func listDeletedNoteEntries(projectID: String) throws -> [MonicaMDBXNoteEntry] {
        try rawVault.listDeletedNoteEntries(projectId: projectID).map(MonicaMDBXNoteEntry.init(raw:))
    }

    public func updateNoteEntry(
        projectID: String,
        entryID: String,
        title: String,
        body: String
    ) throws -> MonicaMDBXNoteEntry {
        let entry = try rawVault.updateNoteEntry(
            projectId: projectID,
            entryId: entryID,
            title: title,
            body: body
        )
        return MonicaMDBXNoteEntry(raw: entry)
    }

    public func setNoteEntryFavorite(
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> MonicaMDBXNoteEntry {
        let entry = try rawVault.setNoteFavorite(
            projectId: projectID,
            entryId: entryID,
            favorite: favorite
        )
        return MonicaMDBXNoteEntry(raw: entry)
    }

    public func deleteNoteEntry(projectID: String, entryID: String) throws {
        try rawVault.deleteNoteEntry(projectId: projectID, entryId: entryID)
    }

    public func restoreNoteEntry(
        projectID: String,
        entryID: String
    ) throws -> MonicaMDBXNoteEntry {
        let entry = try rawVault.restoreNoteEntry(projectId: projectID, entryId: entryID)
        return MonicaMDBXNoteEntry(raw: entry)
    }

    public func moveNoteEntry(
        projectID: String,
        entryID: String,
        targetProjectID: String
    ) throws -> MonicaMDBXNoteEntry {
        let entry = try rawVault.moveNoteEntry(
            projectId: projectID,
            entryId: entryID,
            targetProjectId: targetProjectID
        )
        return MonicaMDBXNoteEntry(raw: entry)
    }

    public func createTotpEntry(
        projectID: String,
        title: String,
        secret: String,
        issuer: String,
        accountName: String,
        period: UInt32,
        digits: UInt32,
        algorithm: String,
        otpType: String,
        counter: UInt64
    ) throws -> MonicaMDBXTotpEntry {
        let entry = try rawVault.createTotpEntry(
            projectId: projectID,
            title: title,
            secret: secret,
            issuer: issuer,
            accountName: accountName,
            period: period,
            digits: digits,
            algorithm: algorithm,
            otpType: otpType,
            counter: counter
        )
        return MonicaMDBXTotpEntry(raw: entry)
    }

    public func listTotpEntries(projectID: String) throws -> [MonicaMDBXTotpEntry] {
        try rawVault.listTotpEntries(projectId: projectID).map(MonicaMDBXTotpEntry.init(raw:))
    }

    public func listDeletedTotpEntries(projectID: String) throws -> [MonicaMDBXTotpEntry] {
        try rawVault.listDeletedTotpEntries(projectId: projectID).map(MonicaMDBXTotpEntry.init(raw:))
    }

    public func updateTotpEntry(
        projectID: String,
        entryID: String,
        title: String,
        secret: String,
        issuer: String,
        accountName: String,
        period: UInt32,
        digits: UInt32,
        algorithm: String,
        otpType: String,
        counter: UInt64
    ) throws -> MonicaMDBXTotpEntry {
        let entry = try rawVault.updateTotpEntry(
            projectId: projectID,
            entryId: entryID,
            title: title,
            secret: secret,
            issuer: issuer,
            accountName: accountName,
            period: period,
            digits: digits,
            algorithm: algorithm,
            otpType: otpType,
            counter: counter
        )
        return MonicaMDBXTotpEntry(raw: entry)
    }

    public func setTotpEntryFavorite(
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> MonicaMDBXTotpEntry {
        let entry = try rawVault.setTotpFavorite(
            projectId: projectID,
            entryId: entryID,
            favorite: favorite
        )
        return MonicaMDBXTotpEntry(raw: entry)
    }

    public func deleteTotpEntry(projectID: String, entryID: String) throws {
        try rawVault.deleteTotpEntry(projectId: projectID, entryId: entryID)
    }

    public func restoreTotpEntry(
        projectID: String,
        entryID: String
    ) throws -> MonicaMDBXTotpEntry {
        let entry = try rawVault.restoreTotpEntry(projectId: projectID, entryId: entryID)
        return MonicaMDBXTotpEntry(raw: entry)
    }

    public func moveTotpEntry(
        projectID: String,
        entryID: String,
        targetProjectID: String
    ) throws -> MonicaMDBXTotpEntry {
        let entry = try rawVault.moveTotpEntry(
            projectId: projectID,
            entryId: entryID,
            targetProjectId: targetProjectID
        )
        return MonicaMDBXTotpEntry(raw: entry)
    }

    public func createCardEntry(
        projectID: String,
        title: String,
        cardholderName: String,
        number: String,
        expiryMonth: String,
        expiryYear: String,
        cvv: String,
        issuer: String,
        network: String,
        notes: String
    ) throws -> MonicaMDBXCardEntry {
        let entry = try rawVault.createCardEntry(
            projectId: projectID,
            title: title,
            cardholderName: cardholderName,
            number: number,
            expiryMonth: expiryMonth,
            expiryYear: expiryYear,
            cvv: cvv,
            issuer: issuer,
            network: network,
            notes: notes
        )
        return MonicaMDBXCardEntry(raw: entry)
    }

    public func listCardEntries(projectID: String) throws -> [MonicaMDBXCardEntry] {
        try rawVault.listCardEntries(projectId: projectID).map(MonicaMDBXCardEntry.init(raw:))
    }

    public func listDeletedCardEntries(projectID: String) throws -> [MonicaMDBXCardEntry] {
        try rawVault.listDeletedCardEntries(projectId: projectID).map(MonicaMDBXCardEntry.init(raw:))
    }

    public func updateCardEntry(
        projectID: String,
        entryID: String,
        title: String,
        cardholderName: String,
        number: String,
        expiryMonth: String,
        expiryYear: String,
        cvv: String,
        issuer: String,
        network: String,
        notes: String
    ) throws -> MonicaMDBXCardEntry {
        let entry = try rawVault.updateCardEntry(
            projectId: projectID,
            entryId: entryID,
            title: title,
            cardholderName: cardholderName,
            number: number,
            expiryMonth: expiryMonth,
            expiryYear: expiryYear,
            cvv: cvv,
            issuer: issuer,
            network: network,
            notes: notes
        )
        return MonicaMDBXCardEntry(raw: entry)
    }

    public func setCardEntryFavorite(
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> MonicaMDBXCardEntry {
        let entry = try rawVault.setCardFavorite(
            projectId: projectID,
            entryId: entryID,
            favorite: favorite
        )
        return MonicaMDBXCardEntry(raw: entry)
    }

    public func deleteCardEntry(projectID: String, entryID: String) throws {
        try rawVault.deleteCardEntry(projectId: projectID, entryId: entryID)
    }

    public func restoreCardEntry(
        projectID: String,
        entryID: String
    ) throws -> MonicaMDBXCardEntry {
        let entry = try rawVault.restoreCardEntry(projectId: projectID, entryId: entryID)
        return MonicaMDBXCardEntry(raw: entry)
    }

    public func moveCardEntry(
        projectID: String,
        entryID: String,
        targetProjectID: String
    ) throws -> MonicaMDBXCardEntry {
        let entry = try rawVault.moveCardEntry(
            projectId: projectID,
            entryId: entryID,
            targetProjectId: targetProjectID
        )
        return MonicaMDBXCardEntry(raw: entry)
    }

    public func createIdentityEntry(
        projectID: String,
        title: String,
        documentType: String,
        fullName: String,
        documentNumber: String,
        issuer: String,
        country: String,
        issueDate: String,
        expiryDate: String,
        notes: String
    ) throws -> MonicaMDBXIdentityEntry {
        let entry = try rawVault.createIdentityEntry(
            projectId: projectID,
            title: title,
            documentType: documentType,
            fullName: fullName,
            documentNumber: documentNumber,
            issuer: issuer,
            country: country,
            issueDate: issueDate,
            expiryDate: expiryDate,
            notes: notes
        )
        return MonicaMDBXIdentityEntry(raw: entry)
    }

    public func listIdentityEntries(projectID: String) throws -> [MonicaMDBXIdentityEntry] {
        try rawVault.listIdentityEntries(projectId: projectID).map(MonicaMDBXIdentityEntry.init(raw:))
    }

    public func listDeletedIdentityEntries(projectID: String) throws -> [MonicaMDBXIdentityEntry] {
        try rawVault.listDeletedIdentityEntries(projectId: projectID).map(MonicaMDBXIdentityEntry.init(raw:))
    }

    public func updateIdentityEntry(
        projectID: String,
        entryID: String,
        title: String,
        documentType: String,
        fullName: String,
        documentNumber: String,
        issuer: String,
        country: String,
        issueDate: String,
        expiryDate: String,
        notes: String
    ) throws -> MonicaMDBXIdentityEntry {
        let entry = try rawVault.updateIdentityEntry(
            projectId: projectID,
            entryId: entryID,
            title: title,
            documentType: documentType,
            fullName: fullName,
            documentNumber: documentNumber,
            issuer: issuer,
            country: country,
            issueDate: issueDate,
            expiryDate: expiryDate,
            notes: notes
        )
        return MonicaMDBXIdentityEntry(raw: entry)
    }

    public func setIdentityEntryFavorite(
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> MonicaMDBXIdentityEntry {
        let entry = try rawVault.setIdentityFavorite(
            projectId: projectID,
            entryId: entryID,
            favorite: favorite
        )
        return MonicaMDBXIdentityEntry(raw: entry)
    }

    public func deleteIdentityEntry(projectID: String, entryID: String) throws {
        try rawVault.deleteIdentityEntry(projectId: projectID, entryId: entryID)
    }

    public func restoreIdentityEntry(
        projectID: String,
        entryID: String
    ) throws -> MonicaMDBXIdentityEntry {
        let entry = try rawVault.restoreIdentityEntry(projectId: projectID, entryId: entryID)
        return MonicaMDBXIdentityEntry(raw: entry)
    }

    public func moveIdentityEntry(
        projectID: String,
        entryID: String,
        targetProjectID: String
    ) throws -> MonicaMDBXIdentityEntry {
        let entry = try rawVault.moveIdentityEntry(
            projectId: projectID,
            entryId: entryID,
            targetProjectId: targetProjectID
        )
        return MonicaMDBXIdentityEntry(raw: entry)
    }

    public func createParityEntry(
        projectID: String,
        entryType: String,
        kind: String,
        title: String,
        payloadJSON: String
    ) throws -> MonicaMDBXParityEntry {
        let entry = try rawVault.createParityEntry(
            projectId: projectID,
            entryType: entryType,
            kind: kind,
            title: title,
            payloadJson: payloadJSON
        )
        return MonicaMDBXParityEntry(raw: entry, entryType: entryType)
    }

    public func listParityEntries(
        projectID: String,
        entryType: String,
        kind: String
    ) throws -> [MonicaMDBXParityEntry] {
        try rawVault
            .listParityEntries(projectId: projectID, entryType: entryType, kind: kind)
            .map { MonicaMDBXParityEntry(raw: $0, entryType: entryType) }
    }

    public func listDeletedParityEntries(
        projectID: String,
        entryType: String,
        kind: String
    ) throws -> [MonicaMDBXParityEntry] {
        try rawVault
            .listDeletedParityEntries(projectId: projectID, entryType: entryType, kind: kind)
            .map { MonicaMDBXParityEntry(raw: $0, entryType: entryType) }
    }

    public func updateParityEntry(
        projectID: String,
        entryID: String,
        entryType: String,
        kind: String,
        title: String,
        payloadJSON: String
    ) throws -> MonicaMDBXParityEntry {
        let entry = try rawVault.updateParityEntry(
            projectId: projectID,
            entryId: entryID,
            entryType: entryType,
            kind: kind,
            title: title,
            payloadJson: payloadJSON
        )
        return MonicaMDBXParityEntry(raw: entry, entryType: entryType)
    }

    public func setParityEntryFavorite(
        projectID: String,
        entryID: String,
        entryType: String,
        kind: String,
        favorite: Bool
    ) throws -> MonicaMDBXParityEntry {
        let entry = try rawVault.setParityEntryFavorite(
            projectId: projectID,
            entryId: entryID,
            entryType: entryType,
            kind: kind,
            favorite: favorite
        )
        return MonicaMDBXParityEntry(raw: entry, entryType: entryType)
    }

    public func deleteParityEntry(
        projectID: String,
        entryID: String,
        entryType: String,
        kind: String
    ) throws {
        try rawVault.deleteParityEntry(
            projectId: projectID,
            entryId: entryID,
            entryType: entryType,
            kind: kind
        )
    }

    public func restoreParityEntry(
        projectID: String,
        entryID: String,
        entryType: String,
        kind: String
    ) throws -> MonicaMDBXParityEntry {
        let entry = try rawVault.restoreParityEntry(
            projectId: projectID,
            entryId: entryID,
            entryType: entryType,
            kind: kind
        )
        return MonicaMDBXParityEntry(raw: entry, entryType: entryType)
    }

    public func moveParityEntry(
        projectID: String,
        entryID: String,
        entryType: String,
        kind: String,
        targetProjectID: String
    ) throws -> MonicaMDBXParityEntry {
        let entry = try rawVault.moveParityEntry(
            projectId: projectID,
            entryId: entryID,
            entryType: entryType,
            kind: kind,
            targetProjectId: targetProjectID
        )
        return MonicaMDBXParityEntry(raw: entry, entryType: entryType)
    }

    public func setupLocalSecurityKeyUnlock(_ keyMaterial: Data) throws {
        try rawVault.setupLocalSecurityKeyUnlock(keyMaterial: keyMaterial)
    }

    public func resetMasterPassword(_ newPassword: String) throws {
        try rawVault.resetMasterPassword(newPassword: newPassword)
    }
}

fileprivate struct LoginEntryRecord {
    let entryId: String
    let projectId: String
    let title: String
    let username: String
    let password: String
    let url: String
    let notes: String
    let favorite: Bool
}

fileprivate struct NoteEntryRecord {
    let entryId: String
    let projectId: String
    let title: String
    let body: String
    let favorite: Bool
}

fileprivate struct TotpEntryRecord {
    let entryId: String
    let projectId: String
    let title: String
    let secret: String
    let issuer: String
    let accountName: String
    let period: UInt32
    let digits: UInt32
    let algorithm: String
    let otpType: String
    let counter: UInt64
    let favorite: Bool
}

fileprivate struct CardEntryRecord {
    let entryId: String
    let projectId: String
    let title: String
    let cardholderName: String
    let number: String
    let expiryMonth: String
    let expiryYear: String
    let cvv: String
    let issuer: String
    let network: String
    let notes: String
    let favorite: Bool
}

fileprivate struct IdentityEntryRecord {
    let entryId: String
    let projectId: String
    let title: String
    let documentType: String
    let fullName: String
    let documentNumber: String
    let issuer: String
    let country: String
    let issueDate: String
    let expiryDate: String
    let notes: String
    let favorite: Bool
}

fileprivate struct ParityEntryRecord {
    let entryId: String
    let projectId: String
    let title: String
    let kind: String
    let payloadJson: String
    let favorite: Bool
}

fileprivate enum MDBXBusinessPayload {
    static func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else {
            throw MonicaMDBXError.verificationFailed("无法序列化 MDBX payload。")
        }
        return string
    }

    static func object(from json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MonicaMDBXError.verificationFailed("MDBX payload 必须是 JSON object。")
        }
        return object
    }

    static func string(_ object: [String: Any], _ key: String) -> String {
        object[key] as? String ?? ""
    }

    static func bool(_ object: [String: Any], _ key: String) -> Bool {
        object[key] as? Bool ?? false
    }

    static func uint32(_ object: [String: Any], _ key: String, default defaultValue: UInt32) -> UInt32 {
        if let number = object[key] as? NSNumber {
            return number.uint32Value
        }
        return defaultValue
    }

    static func uint64(_ object: [String: Any], _ key: String) -> UInt64 {
        if let number = object[key] as? NSNumber {
            return number.uint64Value
        }
        return 0
    }

    static func withFavorite(_ payloadJSON: String, favorite: Bool) throws -> String {
        var object = try object(from: payloadJSON)
        object["favorite"] = favorite
        return try jsonString(object)
    }

    static func favorite(from payloadJSON: String) throws -> Bool {
        try bool(object(from: payloadJSON), "favorite")
    }

    static func kind(from payloadJSON: String) throws -> String {
        try string(object(from: payloadJSON), "kind")
    }
}

fileprivate extension EntryRecord {
    var payloadObject: [String: Any] {
        get throws { try MDBXBusinessPayload.object(from: payloadJson) }
    }
}

fileprivate extension LoginEntryRecord {
    init(raw: EntryRecord) throws {
        let payload = try raw.payloadObject
        self.init(
            entryId: raw.entryId,
            projectId: raw.projectId,
            title: raw.title,
            username: MDBXBusinessPayload.string(payload, "username"),
            password: MDBXBusinessPayload.string(payload, "password"),
            url: MDBXBusinessPayload.string(payload, "website"),
            notes: MDBXBusinessPayload.string(payload, "notes"),
            favorite: MDBXBusinessPayload.bool(payload, "favorite")
        )
    }
}

fileprivate extension NoteEntryRecord {
    init(raw: EntryRecord) throws {
        let payload = try raw.payloadObject
        self.init(
            entryId: raw.entryId,
            projectId: raw.projectId,
            title: raw.title,
            body: MDBXBusinessPayload.string(payload, "body"),
            favorite: MDBXBusinessPayload.bool(payload, "favorite")
        )
    }
}

fileprivate extension TotpEntryRecord {
    init(raw: EntryRecord) throws {
        let payload = try raw.payloadObject
        self.init(
            entryId: raw.entryId,
            projectId: raw.projectId,
            title: raw.title,
            secret: MDBXBusinessPayload.string(payload, "secret"),
            issuer: MDBXBusinessPayload.string(payload, "issuer"),
            accountName: MDBXBusinessPayload.string(payload, "accountName"),
            period: MDBXBusinessPayload.uint32(payload, "period", default: 30),
            digits: MDBXBusinessPayload.uint32(payload, "digits", default: 6),
            algorithm: MDBXBusinessPayload.string(payload, "algorithm").isEmpty ? "SHA1" : MDBXBusinessPayload.string(payload, "algorithm"),
            otpType: MDBXBusinessPayload.string(payload, "otpType").isEmpty ? "TOTP" : MDBXBusinessPayload.string(payload, "otpType"),
            counter: MDBXBusinessPayload.uint64(payload, "counter"),
            favorite: MDBXBusinessPayload.bool(payload, "favorite")
        )
    }
}

fileprivate extension CardEntryRecord {
    init(raw: EntryRecord) throws {
        let payload = try raw.payloadObject
        self.init(
            entryId: raw.entryId,
            projectId: raw.projectId,
            title: raw.title,
            cardholderName: MDBXBusinessPayload.string(payload, "cardholderName"),
            number: MDBXBusinessPayload.string(payload, "number"),
            expiryMonth: MDBXBusinessPayload.string(payload, "expiryMonth"),
            expiryYear: MDBXBusinessPayload.string(payload, "expiryYear"),
            cvv: MDBXBusinessPayload.string(payload, "cvv"),
            issuer: MDBXBusinessPayload.string(payload, "issuer"),
            network: MDBXBusinessPayload.string(payload, "network"),
            notes: MDBXBusinessPayload.string(payload, "notes"),
            favorite: MDBXBusinessPayload.bool(payload, "favorite")
        )
    }
}

fileprivate extension IdentityEntryRecord {
    init(raw: EntryRecord) throws {
        let payload = try raw.payloadObject
        self.init(
            entryId: raw.entryId,
            projectId: raw.projectId,
            title: raw.title,
            documentType: MDBXBusinessPayload.string(payload, "documentType"),
            fullName: MDBXBusinessPayload.string(payload, "fullName"),
            documentNumber: MDBXBusinessPayload.string(payload, "documentNumber"),
            issuer: MDBXBusinessPayload.string(payload, "issuer"),
            country: MDBXBusinessPayload.string(payload, "country"),
            issueDate: MDBXBusinessPayload.string(payload, "issueDate"),
            expiryDate: MDBXBusinessPayload.string(payload, "expiryDate"),
            notes: MDBXBusinessPayload.string(payload, "notes"),
            favorite: MDBXBusinessPayload.bool(payload, "favorite")
        )
    }
}

fileprivate extension ParityEntryRecord {
    init(raw: EntryRecord) throws {
        let payload = try raw.payloadObject
        self.init(
            entryId: raw.entryId,
            projectId: raw.projectId,
            title: raw.title,
            kind: MDBXBusinessPayload.string(payload, "kind"),
            payloadJson: raw.payloadJson,
            favorite: MDBXBusinessPayload.bool(payload, "favorite")
        )
    }
}

fileprivate extension MdbxVault {
    func createLoginEntry(
        projectId: String,
        title: String,
        username: String,
        password: String,
        url: String,
        notes: String
    ) throws -> LoginEntryRecord {
        let payload = try MDBXBusinessPayload.jsonString([
            "kind": "password",
            "username": username,
            "password": password,
            "website": url,
            "notes": notes,
            "favorite": false
        ])
        return try LoginEntryRecord(raw: createEntry(
            projectId: projectId,
            entryType: "login",
            title: title,
            payloadJson: payload
        ))
    }

    func listEntries(projectId: String) throws -> [LoginEntryRecord] {
        try listEntries(projectId: projectId, entryType: "login").map(LoginEntryRecord.init(raw:))
    }

    func listDeletedEntries(projectId: String) throws -> [LoginEntryRecord] {
        try listDeletedEntries(projectId: projectId, entryType: "login").map(LoginEntryRecord.init(raw:))
    }

    func updateLoginEntry(
        projectId: String,
        entryId: String,
        title: String,
        username: String,
        password: String,
        url: String,
        notes: String
    ) throws -> LoginEntryRecord {
        let favorite = try currentPayloadFavorite(projectId: projectId, entryId: entryId, entryType: "login")
        let payload = try MDBXBusinessPayload.jsonString([
            "kind": "password",
            "username": username,
            "password": password,
            "website": url,
            "notes": notes,
            "favorite": favorite
        ])
        return try LoginEntryRecord(raw: updateEntry(
            projectId: projectId,
            entryId: entryId,
            entryType: "login",
            title: title,
            payloadJson: payload
        ))
    }

    func setLoginFavorite(projectId: String, entryId: String, favorite: Bool) throws -> LoginEntryRecord {
        try LoginEntryRecord(raw: setFavorite(projectId: projectId, entryId: entryId, entryType: "login", favorite: favorite))
    }

    func deleteLoginEntry(projectId: String, entryId: String) throws {
        _ = try activeEntry(projectId: projectId, entryId: entryId, entryType: "login")
        try deleteEntry(projectId: projectId, entryId: entryId)
    }

    func restoreLoginEntry(projectId: String, entryId: String) throws -> LoginEntryRecord {
        try LoginEntryRecord(raw: restoreEntry(projectId: projectId, entryId: entryId))
    }

    func moveLoginEntry(projectId: String, entryId: String, targetProjectId: String) throws -> LoginEntryRecord {
        _ = try activeEntry(projectId: projectId, entryId: entryId, entryType: "login")
        return try LoginEntryRecord(raw: moveEntry(projectId: projectId, entryId: entryId, targetProjectId: targetProjectId))
    }

    func createNoteEntry(projectId: String, title: String, body: String) throws -> NoteEntryRecord {
        let payload = try MDBXBusinessPayload.jsonString(["kind": "note", "body": body, "favorite": false])
        return try NoteEntryRecord(raw: createEntry(projectId: projectId, entryType: "note", title: title, payloadJson: payload))
    }

    func listNoteEntries(projectId: String) throws -> [NoteEntryRecord] {
        try listEntries(projectId: projectId, entryType: "note").map(NoteEntryRecord.init(raw:))
    }

    func listDeletedNoteEntries(projectId: String) throws -> [NoteEntryRecord] {
        try listDeletedEntries(projectId: projectId, entryType: "note").map(NoteEntryRecord.init(raw:))
    }

    func updateNoteEntry(projectId: String, entryId: String, title: String, body: String) throws -> NoteEntryRecord {
        let favorite = try currentPayloadFavorite(projectId: projectId, entryId: entryId, entryType: "note")
        let payload = try MDBXBusinessPayload.jsonString(["kind": "note", "body": body, "favorite": favorite])
        return try NoteEntryRecord(raw: updateEntry(projectId: projectId, entryId: entryId, entryType: "note", title: title, payloadJson: payload))
    }

    func setNoteFavorite(projectId: String, entryId: String, favorite: Bool) throws -> NoteEntryRecord {
        try NoteEntryRecord(raw: setFavorite(projectId: projectId, entryId: entryId, entryType: "note", favorite: favorite))
    }

    func deleteNoteEntry(projectId: String, entryId: String) throws {
        _ = try activeEntry(projectId: projectId, entryId: entryId, entryType: "note")
        try deleteEntry(projectId: projectId, entryId: entryId)
    }

    func restoreNoteEntry(projectId: String, entryId: String) throws -> NoteEntryRecord {
        try NoteEntryRecord(raw: restoreEntry(projectId: projectId, entryId: entryId))
    }

    func moveNoteEntry(projectId: String, entryId: String, targetProjectId: String) throws -> NoteEntryRecord {
        _ = try activeEntry(projectId: projectId, entryId: entryId, entryType: "note")
        return try NoteEntryRecord(raw: moveEntry(projectId: projectId, entryId: entryId, targetProjectId: targetProjectId))
    }

    func createTotpEntry(projectId: String, title: String, secret: String, issuer: String, accountName: String, period: UInt32, digits: UInt32, algorithm: String, otpType: String, counter: UInt64) throws -> TotpEntryRecord {
        let payload = try totpPayload(secret: secret, issuer: issuer, accountName: accountName, period: period, digits: digits, algorithm: algorithm, otpType: otpType, counter: counter, favorite: false)
        return try TotpEntryRecord(raw: createEntry(projectId: projectId, entryType: "totp", title: title, payloadJson: payload))
    }

    func listTotpEntries(projectId: String) throws -> [TotpEntryRecord] {
        try listEntries(projectId: projectId, entryType: "totp").map(TotpEntryRecord.init(raw:))
    }

    func listDeletedTotpEntries(projectId: String) throws -> [TotpEntryRecord] {
        try listDeletedEntries(projectId: projectId, entryType: "totp").map(TotpEntryRecord.init(raw:))
    }

    func updateTotpEntry(projectId: String, entryId: String, title: String, secret: String, issuer: String, accountName: String, period: UInt32, digits: UInt32, algorithm: String, otpType: String, counter: UInt64) throws -> TotpEntryRecord {
        let favorite = try currentPayloadFavorite(projectId: projectId, entryId: entryId, entryType: "totp")
        let payload = try totpPayload(secret: secret, issuer: issuer, accountName: accountName, period: period, digits: digits, algorithm: algorithm, otpType: otpType, counter: counter, favorite: favorite)
        return try TotpEntryRecord(raw: updateEntry(projectId: projectId, entryId: entryId, entryType: "totp", title: title, payloadJson: payload))
    }

    func setTotpFavorite(projectId: String, entryId: String, favorite: Bool) throws -> TotpEntryRecord {
        try TotpEntryRecord(raw: setFavorite(projectId: projectId, entryId: entryId, entryType: "totp", favorite: favorite))
    }

    func deleteTotpEntry(projectId: String, entryId: String) throws {
        _ = try activeEntry(projectId: projectId, entryId: entryId, entryType: "totp")
        try deleteEntry(projectId: projectId, entryId: entryId)
    }

    func restoreTotpEntry(projectId: String, entryId: String) throws -> TotpEntryRecord {
        try TotpEntryRecord(raw: restoreEntry(projectId: projectId, entryId: entryId))
    }

    func moveTotpEntry(projectId: String, entryId: String, targetProjectId: String) throws -> TotpEntryRecord {
        _ = try activeEntry(projectId: projectId, entryId: entryId, entryType: "totp")
        return try TotpEntryRecord(raw: moveEntry(projectId: projectId, entryId: entryId, targetProjectId: targetProjectId))
    }

    func createCardEntry(projectId: String, title: String, cardholderName: String, number: String, expiryMonth: String, expiryYear: String, cvv: String, issuer: String, network: String, notes: String) throws -> CardEntryRecord {
        let payload = try cardPayload(cardholderName: cardholderName, number: number, expiryMonth: expiryMonth, expiryYear: expiryYear, cvv: cvv, issuer: issuer, network: network, notes: notes, favorite: false)
        return try CardEntryRecord(raw: createEntry(projectId: projectId, entryType: "card", title: title, payloadJson: payload))
    }

    func listCardEntries(projectId: String) throws -> [CardEntryRecord] {
        try listEntries(projectId: projectId, entryType: "card").map(CardEntryRecord.init(raw:))
    }

    func listDeletedCardEntries(projectId: String) throws -> [CardEntryRecord] {
        try listDeletedEntries(projectId: projectId, entryType: "card").map(CardEntryRecord.init(raw:))
    }

    func updateCardEntry(projectId: String, entryId: String, title: String, cardholderName: String, number: String, expiryMonth: String, expiryYear: String, cvv: String, issuer: String, network: String, notes: String) throws -> CardEntryRecord {
        let favorite = try currentPayloadFavorite(projectId: projectId, entryId: entryId, entryType: "card")
        let payload = try cardPayload(cardholderName: cardholderName, number: number, expiryMonth: expiryMonth, expiryYear: expiryYear, cvv: cvv, issuer: issuer, network: network, notes: notes, favorite: favorite)
        return try CardEntryRecord(raw: updateEntry(projectId: projectId, entryId: entryId, entryType: "card", title: title, payloadJson: payload))
    }

    func setCardFavorite(projectId: String, entryId: String, favorite: Bool) throws -> CardEntryRecord {
        try CardEntryRecord(raw: setFavorite(projectId: projectId, entryId: entryId, entryType: "card", favorite: favorite))
    }

    func deleteCardEntry(projectId: String, entryId: String) throws {
        _ = try activeEntry(projectId: projectId, entryId: entryId, entryType: "card")
        try deleteEntry(projectId: projectId, entryId: entryId)
    }

    func restoreCardEntry(projectId: String, entryId: String) throws -> CardEntryRecord {
        try CardEntryRecord(raw: restoreEntry(projectId: projectId, entryId: entryId))
    }

    func moveCardEntry(projectId: String, entryId: String, targetProjectId: String) throws -> CardEntryRecord {
        _ = try activeEntry(projectId: projectId, entryId: entryId, entryType: "card")
        return try CardEntryRecord(raw: moveEntry(projectId: projectId, entryId: entryId, targetProjectId: targetProjectId))
    }

    func createIdentityEntry(projectId: String, title: String, documentType: String, fullName: String, documentNumber: String, issuer: String, country: String, issueDate: String, expiryDate: String, notes: String) throws -> IdentityEntryRecord {
        let payload = try identityPayload(documentType: documentType, fullName: fullName, documentNumber: documentNumber, issuer: issuer, country: country, issueDate: issueDate, expiryDate: expiryDate, notes: notes, favorite: false)
        return try IdentityEntryRecord(raw: createEntry(projectId: projectId, entryType: "identity", title: title, payloadJson: payload))
    }

    func listIdentityEntries(projectId: String) throws -> [IdentityEntryRecord] {
        try listEntries(projectId: projectId, entryType: "identity").map(IdentityEntryRecord.init(raw:))
    }

    func listDeletedIdentityEntries(projectId: String) throws -> [IdentityEntryRecord] {
        try listDeletedEntries(projectId: projectId, entryType: "identity").map(IdentityEntryRecord.init(raw:))
    }

    func updateIdentityEntry(projectId: String, entryId: String, title: String, documentType: String, fullName: String, documentNumber: String, issuer: String, country: String, issueDate: String, expiryDate: String, notes: String) throws -> IdentityEntryRecord {
        let favorite = try currentPayloadFavorite(projectId: projectId, entryId: entryId, entryType: "identity")
        let payload = try identityPayload(documentType: documentType, fullName: fullName, documentNumber: documentNumber, issuer: issuer, country: country, issueDate: issueDate, expiryDate: expiryDate, notes: notes, favorite: favorite)
        return try IdentityEntryRecord(raw: updateEntry(projectId: projectId, entryId: entryId, entryType: "identity", title: title, payloadJson: payload))
    }

    func setIdentityFavorite(projectId: String, entryId: String, favorite: Bool) throws -> IdentityEntryRecord {
        try IdentityEntryRecord(raw: setFavorite(projectId: projectId, entryId: entryId, entryType: "identity", favorite: favorite))
    }

    func deleteIdentityEntry(projectId: String, entryId: String) throws {
        _ = try activeEntry(projectId: projectId, entryId: entryId, entryType: "identity")
        try deleteEntry(projectId: projectId, entryId: entryId)
    }

    func restoreIdentityEntry(projectId: String, entryId: String) throws -> IdentityEntryRecord {
        try IdentityEntryRecord(raw: restoreEntry(projectId: projectId, entryId: entryId))
    }

    func moveIdentityEntry(projectId: String, entryId: String, targetProjectId: String) throws -> IdentityEntryRecord {
        _ = try activeEntry(projectId: projectId, entryId: entryId, entryType: "identity")
        return try IdentityEntryRecord(raw: moveEntry(projectId: projectId, entryId: entryId, targetProjectId: targetProjectId))
    }

    func createParityEntry(projectId: String, entryType: String, kind: String, title: String, payloadJson: String) throws -> ParityEntryRecord {
        let payload = try parityPayload(kind: kind, payloadJSON: payloadJson, favorite: false)
        return try ParityEntryRecord(raw: createEntry(projectId: projectId, entryType: entryType, title: title, payloadJson: payload))
    }

    func listParityEntries(projectId: String, entryType: String, kind: String) throws -> [ParityEntryRecord] {
        try listEntries(projectId: projectId, entryType: entryType)
            .filter { try MDBXBusinessPayload.kind(from: $0.payloadJson) == kind }
            .map(ParityEntryRecord.init(raw:))
    }

    func listDeletedParityEntries(projectId: String, entryType: String, kind: String) throws -> [ParityEntryRecord] {
        try listDeletedEntries(projectId: projectId, entryType: entryType)
            .filter { try MDBXBusinessPayload.kind(from: $0.payloadJson) == kind }
            .map(ParityEntryRecord.init(raw:))
    }

    func updateParityEntry(projectId: String, entryId: String, entryType: String, kind: String, title: String, payloadJson: String) throws -> ParityEntryRecord {
        let current = try activeParityEntry(projectId: projectId, entryId: entryId, entryType: entryType, kind: kind)
        let favorite = try MDBXBusinessPayload.favorite(from: current.payloadJson)
        let payload = try parityPayload(kind: kind, payloadJSON: payloadJson, favorite: favorite)
        return try ParityEntryRecord(raw: updateEntry(projectId: projectId, entryId: entryId, entryType: entryType, title: title, payloadJson: payload))
    }

    func setParityEntryFavorite(projectId: String, entryId: String, entryType: String, kind: String, favorite: Bool) throws -> ParityEntryRecord {
        let current = try activeParityEntry(projectId: projectId, entryId: entryId, entryType: entryType, kind: kind)
        let payload = try MDBXBusinessPayload.withFavorite(current.payloadJson, favorite: favorite)
        return try ParityEntryRecord(raw: updateEntry(projectId: projectId, entryId: entryId, entryType: entryType, title: current.title, payloadJson: payload))
    }

    func deleteParityEntry(projectId: String, entryId: String, entryType: String, kind: String) throws {
        _ = try activeParityEntry(projectId: projectId, entryId: entryId, entryType: entryType, kind: kind)
        try deleteEntry(projectId: projectId, entryId: entryId)
    }

    func restoreParityEntry(projectId: String, entryId: String, entryType: String, kind: String) throws -> ParityEntryRecord {
        let restored = try restoreEntry(projectId: projectId, entryId: entryId)
        guard restored.entryType == entryType, try MDBXBusinessPayload.kind(from: restored.payloadJson) == kind else {
            throw MonicaMDBXError.verificationFailed("恢复的 MDBX 条目类型不匹配。")
        }
        return try ParityEntryRecord(raw: restored)
    }

    func moveParityEntry(projectId: String, entryId: String, entryType: String, kind: String, targetProjectId: String) throws -> ParityEntryRecord {
        _ = try activeParityEntry(projectId: projectId, entryId: entryId, entryType: entryType, kind: kind)
        return try ParityEntryRecord(raw: moveEntry(projectId: projectId, entryId: entryId, targetProjectId: targetProjectId))
    }

    private func activeEntry(projectId: String, entryId: String, entryType: String) throws -> EntryRecord {
        guard let entry = try listEntries(projectId: projectId, entryType: entryType).first(where: { $0.entryId == entryId }) else {
            throw MonicaMDBXError.verificationFailed("找不到 MDBX 条目。")
        }
        return entry
    }

    private func activeParityEntry(projectId: String, entryId: String, entryType: String, kind: String) throws -> EntryRecord {
        let entry = try activeEntry(projectId: projectId, entryId: entryId, entryType: entryType)
        guard try MDBXBusinessPayload.kind(from: entry.payloadJson) == kind else {
            throw MonicaMDBXError.verificationFailed("MDBX parity 条目 kind 不匹配。")
        }
        return entry
    }

    private func currentPayloadFavorite(projectId: String, entryId: String, entryType: String) throws -> Bool {
        try MDBXBusinessPayload.favorite(from: activeEntry(projectId: projectId, entryId: entryId, entryType: entryType).payloadJson)
    }

    private func setFavorite(projectId: String, entryId: String, entryType: String, favorite: Bool) throws -> EntryRecord {
        let current = try activeEntry(projectId: projectId, entryId: entryId, entryType: entryType)
        let payload = try MDBXBusinessPayload.withFavorite(current.payloadJson, favorite: favorite)
        return try updateEntry(projectId: projectId, entryId: entryId, entryType: entryType, title: current.title, payloadJson: payload)
    }

    private func totpPayload(secret: String, issuer: String, accountName: String, period: UInt32, digits: UInt32, algorithm: String, otpType: String, counter: UInt64, favorite: Bool) throws -> String {
        try MDBXBusinessPayload.jsonString([
            "kind": "totp",
            "secret": secret,
            "issuer": issuer,
            "accountName": accountName,
            "period": period,
            "digits": digits,
            "algorithm": algorithm,
            "otpType": otpType,
            "counter": counter,
            "favorite": favorite,
            "steamFingerprint": "",
            "steamDeviceId": "",
            "steamSerialNumber": "",
            "steamSharedSecretBase64": "",
            "steamRevocationCode": "",
            "steamIdentitySecret": "",
            "steamTokenGid": "",
            "steamRawJson": ""
        ])
    }

    private func cardPayload(cardholderName: String, number: String, expiryMonth: String, expiryYear: String, cvv: String, issuer: String, network: String, notes: String, favorite: Bool) throws -> String {
        try MDBXBusinessPayload.jsonString([
            "kind": "card",
            "cardholderName": cardholderName,
            "number": number,
            "expiryMonth": expiryMonth,
            "expiryYear": expiryYear,
            "cvv": cvv,
            "issuer": issuer,
            "network": network,
            "notes": notes,
            "favorite": favorite
        ])
    }

    private func identityPayload(documentType: String, fullName: String, documentNumber: String, issuer: String, country: String, issueDate: String, expiryDate: String, notes: String, favorite: Bool) throws -> String {
        try MDBXBusinessPayload.jsonString([
            "kind": "identity",
            "documentType": documentType,
            "fullName": fullName,
            "documentNumber": documentNumber,
            "issuer": issuer,
            "country": country,
            "issueDate": issueDate,
            "expiryDate": expiryDate,
            "notes": notes,
            "favorite": favorite
        ])
    }

    private func parityPayload(kind: String, payloadJSON: String, favorite: Bool) throws -> String {
        var object = try MDBXBusinessPayload.object(from: payloadJSON)
        object["kind"] = kind
        object["favorite"] = favorite
        return try MDBXBusinessPayload.jsonString(object)
    }
}

extension MonicaMDBXLoginEntry {
    fileprivate init(raw: LoginEntryRecord) {
        self.init(
            id: raw.entryId,
            projectID: raw.projectId,
            title: raw.title,
            username: raw.username,
            password: raw.password,
            url: raw.url,
            notes: raw.notes,
            favorite: raw.favorite
        )
    }
}

extension MonicaMDBXNoteEntry {
    fileprivate init(raw: NoteEntryRecord) {
        self.init(
            id: raw.entryId,
            projectID: raw.projectId,
            title: raw.title,
            body: raw.body,
            favorite: raw.favorite
        )
    }
}

extension MonicaMDBXTotpEntry {
    fileprivate init(raw: TotpEntryRecord) {
        self.init(
            id: raw.entryId,
            projectID: raw.projectId,
            title: raw.title,
            secret: raw.secret,
            issuer: raw.issuer,
            accountName: raw.accountName,
            period: raw.period,
            digits: raw.digits,
            algorithm: raw.algorithm,
            otpType: raw.otpType,
            counter: raw.counter,
            favorite: raw.favorite
        )
    }
}

extension MonicaMDBXCardEntry {
    fileprivate init(raw: CardEntryRecord) {
        self.init(
            id: raw.entryId,
            projectID: raw.projectId,
            title: raw.title,
            cardholderName: raw.cardholderName,
            number: raw.number,
            expiryMonth: raw.expiryMonth,
            expiryYear: raw.expiryYear,
            cvv: raw.cvv,
            issuer: raw.issuer,
            network: raw.network,
            notes: raw.notes,
            favorite: raw.favorite
        )
    }
}

extension MonicaMDBXIdentityEntry {
    fileprivate init(raw: IdentityEntryRecord) {
        self.init(
            id: raw.entryId,
            projectID: raw.projectId,
            title: raw.title,
            documentType: raw.documentType,
            fullName: raw.fullName,
            documentNumber: raw.documentNumber,
            issuer: raw.issuer,
            country: raw.country,
            issueDate: raw.issueDate,
            expiryDate: raw.expiryDate,
            notes: raw.notes,
            favorite: raw.favorite
        )
    }
}

extension MonicaMDBXParityEntry {
    fileprivate init(raw: ParityEntryRecord, entryType: String) {
        self.init(
            id: raw.entryId,
            projectID: raw.projectId,
            title: raw.title,
            entryType: entryType,
            kind: raw.kind,
            payloadJSON: raw.payloadJson,
            favorite: raw.favorite
        )
    }
}
#else
public final class MonicaMDBXVault: @unchecked Sendable {
    fileprivate init() {}

    public func info() -> MonicaMDBXVaultInfo {
        MonicaMDBXVaultInfo(vaultID: "", deviceID: "")
    }

    public func createProject(title: String) throws -> MonicaMDBXProject {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func createLoginEntry(
        projectID: String,
        title: String,
        username: String,
        password: String,
        url: String,
        notes: String = ""
    ) throws -> MonicaMDBXLoginEntry {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func listLoginEntries(projectID: String) throws -> [MonicaMDBXLoginEntry] {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func listDeletedLoginEntries(projectID: String) throws -> [MonicaMDBXLoginEntry] {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func updateLoginEntry(
        projectID: String,
        entryID: String,
        title: String,
        username: String,
        password: String,
        url: String,
        notes: String = ""
    ) throws -> MonicaMDBXLoginEntry {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func setLoginEntryFavorite(
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> MonicaMDBXLoginEntry {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func deleteLoginEntry(projectID: String, entryID: String) throws {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func restoreLoginEntry(
        projectID: String,
        entryID: String
    ) throws -> MonicaMDBXLoginEntry {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func moveLoginEntry(
        projectID: String,
        entryID: String,
        targetProjectID: String
    ) throws -> MonicaMDBXLoginEntry {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func createNoteEntry(
        projectID: String,
        title: String,
        body: String
    ) throws -> MonicaMDBXNoteEntry {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func listNoteEntries(projectID: String) throws -> [MonicaMDBXNoteEntry] {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func listDeletedNoteEntries(projectID: String) throws -> [MonicaMDBXNoteEntry] {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func updateNoteEntry(
        projectID: String,
        entryID: String,
        title: String,
        body: String
    ) throws -> MonicaMDBXNoteEntry {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func setNoteEntryFavorite(
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> MonicaMDBXNoteEntry {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func deleteNoteEntry(projectID: String, entryID: String) throws {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func restoreNoteEntry(
        projectID: String,
        entryID: String
    ) throws -> MonicaMDBXNoteEntry {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func moveNoteEntry(
        projectID: String,
        entryID: String,
        targetProjectID: String
    ) throws -> MonicaMDBXNoteEntry {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func createTotpEntry(
        projectID: String,
        title: String,
        secret: String,
        issuer: String,
        accountName: String,
        period: UInt32,
        digits: UInt32,
        algorithm: String,
        otpType: String,
        counter: UInt64
    ) throws -> MonicaMDBXTotpEntry {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func listTotpEntries(projectID: String) throws -> [MonicaMDBXTotpEntry] {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func listDeletedTotpEntries(projectID: String) throws -> [MonicaMDBXTotpEntry] {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func updateTotpEntry(
        projectID: String,
        entryID: String,
        title: String,
        secret: String,
        issuer: String,
        accountName: String,
        period: UInt32,
        digits: UInt32,
        algorithm: String,
        otpType: String,
        counter: UInt64
    ) throws -> MonicaMDBXTotpEntry {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func setTotpEntryFavorite(
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> MonicaMDBXTotpEntry {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func deleteTotpEntry(projectID: String, entryID: String) throws {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func restoreTotpEntry(
        projectID: String,
        entryID: String
    ) throws -> MonicaMDBXTotpEntry {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func moveTotpEntry(
        projectID: String,
        entryID: String,
        targetProjectID: String
    ) throws -> MonicaMDBXTotpEntry {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func createCardEntry(
        projectID: String,
        title: String,
        cardholderName: String,
        number: String,
        expiryMonth: String,
        expiryYear: String,
        cvv: String,
        issuer: String,
        network: String,
        notes: String
    ) throws -> MonicaMDBXCardEntry {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func listCardEntries(projectID: String) throws -> [MonicaMDBXCardEntry] {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func listDeletedCardEntries(projectID: String) throws -> [MonicaMDBXCardEntry] {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func updateCardEntry(
        projectID: String,
        entryID: String,
        title: String,
        cardholderName: String,
        number: String,
        expiryMonth: String,
        expiryYear: String,
        cvv: String,
        issuer: String,
        network: String,
        notes: String
    ) throws -> MonicaMDBXCardEntry {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func setCardEntryFavorite(
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> MonicaMDBXCardEntry {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func deleteCardEntry(projectID: String, entryID: String) throws {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func restoreCardEntry(
        projectID: String,
        entryID: String
    ) throws -> MonicaMDBXCardEntry {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func moveCardEntry(
        projectID: String,
        entryID: String,
        targetProjectID: String
    ) throws -> MonicaMDBXCardEntry {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func createIdentityEntry(
        projectID: String,
        title: String,
        documentType: String,
        fullName: String,
        documentNumber: String,
        issuer: String,
        country: String,
        issueDate: String,
        expiryDate: String,
        notes: String
    ) throws -> MonicaMDBXIdentityEntry {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func listIdentityEntries(projectID: String) throws -> [MonicaMDBXIdentityEntry] {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func listDeletedIdentityEntries(projectID: String) throws -> [MonicaMDBXIdentityEntry] {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func updateIdentityEntry(
        projectID: String,
        entryID: String,
        title: String,
        documentType: String,
        fullName: String,
        documentNumber: String,
        issuer: String,
        country: String,
        issueDate: String,
        expiryDate: String,
        notes: String
    ) throws -> MonicaMDBXIdentityEntry {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func setIdentityEntryFavorite(
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> MonicaMDBXIdentityEntry {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func deleteIdentityEntry(projectID: String, entryID: String) throws {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func restoreIdentityEntry(
        projectID: String,
        entryID: String
    ) throws -> MonicaMDBXIdentityEntry {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func moveIdentityEntry(
        projectID: String,
        entryID: String,
        targetProjectID: String
    ) throws -> MonicaMDBXIdentityEntry {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func createParityEntry(
        projectID: String,
        entryType: String,
        kind: String,
        title: String,
        payloadJSON: String
    ) throws -> MonicaMDBXParityEntry {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func listParityEntries(
        projectID: String,
        entryType: String,
        kind: String
    ) throws -> [MonicaMDBXParityEntry] {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func listDeletedParityEntries(
        projectID: String,
        entryType: String,
        kind: String
    ) throws -> [MonicaMDBXParityEntry] {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func updateParityEntry(
        projectID: String,
        entryID: String,
        entryType: String,
        kind: String,
        title: String,
        payloadJSON: String
    ) throws -> MonicaMDBXParityEntry {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func setParityEntryFavorite(
        projectID: String,
        entryID: String,
        entryType: String,
        kind: String,
        favorite: Bool
    ) throws -> MonicaMDBXParityEntry {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func deleteParityEntry(
        projectID: String,
        entryID: String,
        entryType: String,
        kind: String
    ) throws {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func restoreParityEntry(
        projectID: String,
        entryID: String,
        entryType: String,
        kind: String
    ) throws -> MonicaMDBXParityEntry {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func moveParityEntry(
        projectID: String,
        entryID: String,
        entryType: String,
        kind: String,
        targetProjectID: String
    ) throws -> MonicaMDBXParityEntry {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func setupLocalSecurityKeyUnlock(_ keyMaterial: Data) throws {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func resetMasterPassword(_ newPassword: String) throws {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }
}
#endif

public enum MonicaMDBXRuntime {
    public static func createVault(
        at fileURL: URL,
        password: String,
        deviceID: String
    ) throws -> MonicaMDBXVault {
        #if os(iOS)
        try MonicaMDBXVault(
            rawVault: MonicaMDBX.createVault(
                path: fileURL.path,
                password: password,
                deviceId: deviceID
            )
        )
        #else
        throw MonicaMDBXError.unavailableOnCurrentPlatform
        #endif
    }

    public static func openVault(
        at fileURL: URL,
        password: String,
        deviceID: String
    ) throws -> MonicaMDBXVault {
        #if os(iOS)
        try MonicaMDBXVault(
            rawVault: MonicaMDBX.openVault(
                path: fileURL.path,
                password: password,
                deviceId: deviceID
            )
        )
        #else
        throw MonicaMDBXError.unavailableOnCurrentPlatform
        #endif
    }

    public static func openVaultWithSecurityKey(
        at fileURL: URL,
        securityKeyMaterial: Data,
        deviceID: String
    ) throws -> MonicaMDBXVault {
        #if os(iOS)
        try MonicaMDBXVault(
            rawVault: MonicaMDBX.openVaultWithSecurityKey(
                path: fileURL.path,
                keyMaterial: securityKeyMaterial,
                deviceId: deviceID
            )
        )
        #else
        throw MonicaMDBXError.unavailableOnCurrentPlatform
        #endif
    }
}

public enum MonicaMDBXTechnicalVerifier {
    public static func runProjectScopedLoginRoundTrip(
        in directoryURL: URL,
        password: String = "中文 password 12345!",
        deviceID: String = "ios-technical-verifier"
    ) throws -> MonicaMDBXSmokeTestResult {
        #if os(iOS)
        let vaultURL = directoryURL.appendingPathComponent(
            "monica-ios-\(UUID().uuidString).mdbx",
            isDirectory: false
        )
        defer {
            try? FileManager.default.removeItem(at: vaultURL)
        }

        let projectID: String
        let createdEntryID: String

        do {
            let vault = try MonicaMDBXRuntime.createVault(
                at: vaultURL,
                password: password,
                deviceID: deviceID
            )
            let project = try vault.createProject(title: "GitHub")
            let entry = try vault.createLoginEntry(
                projectID: project.id,
                title: "GitHub main login",
                username: "alice",
                password: "correct horse battery staple",
                url: "https://github.com"
            )
            projectID = project.id
            createdEntryID = entry.id
        }

        let reopened = try MonicaMDBXRuntime.openVault(
            at: vaultURL,
            password: password,
            deviceID: deviceID
        )
        let info = reopened.info()
        let entries = try reopened.listLoginEntries(projectID: projectID)

        guard entries.count == 1 else {
            throw MonicaMDBXError.verificationFailed("预期 1 个登录条目，实际 \(entries.count) 个。")
        }
        guard let entry = entries.first, entry.id == createdEntryID else {
            throw MonicaMDBXError.verificationFailed("重新打开保险库后返回了不同条目。")
        }
        guard entry.title == "GitHub main login",
              entry.username == "alice",
              entry.password == "correct horse battery staple",
              entry.url == "https://github.com"
        else {
            throw MonicaMDBXError.verificationFailed("重新打开后的登录条目内容不匹配。")
        }

        return MonicaMDBXSmokeTestResult(
            vaultID: info.vaultID,
            deviceID: info.deviceID,
            projectTitle: "GitHub",
            entryTitle: entry.title
        )
        #else
        throw MonicaMDBXError.unavailableOnCurrentPlatform
        #endif
    }
}
