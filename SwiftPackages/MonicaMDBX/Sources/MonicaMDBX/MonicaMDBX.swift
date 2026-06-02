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
    public static let swiftBinding = "mdbx_ios_ffi"
    public static let binaryModule = "mdbx_ios_ffiFFI"
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
        url: String
    ) throws -> MonicaMDBXLoginEntry {
        let entry = try rawVault.createLoginEntry(
            projectId: projectID,
            title: title,
            username: username,
            password: password,
            url: url
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
        url: String
    ) throws -> MonicaMDBXLoginEntry {
        let entry = try rawVault.updateLoginEntry(
            projectId: projectID,
            entryId: entryID,
            title: title,
            username: username,
            password: password,
            url: url
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

extension MonicaMDBXLoginEntry {
    fileprivate init(raw: LoginEntryRecord) {
        self.init(
            id: raw.entryId,
            projectID: raw.projectId,
            title: raw.title,
            username: raw.username,
            password: raw.password,
            url: raw.url,
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
        url: String
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
        url: String
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
