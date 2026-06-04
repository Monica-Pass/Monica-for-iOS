import Foundation
import MonicaStorage

struct AppSystemPasskeyRegistrationResult: Sendable, Equatable {
    let relyingPartyID: String
    let username: String
    let userHandle: Data
    let credentialID: Data
    let publicKeyCOSE: Data
    let privateKeyReference: String
    let title: String
    let attestationObject: Data
    let clientDataHash: Data

    var metadataDraft: LocalPasskeyEntryDraft {
        let displayTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let relyingParty = relyingPartyID.trimmingCharacters(in: .whitespacesAndNewlines)
        return LocalPasskeyEntryDraft(
            title: displayTitle.isEmpty ? relyingParty : displayTitle,
            relyingPartyID: relyingParty,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            userHandle: userHandle.base64EncodedString(),
            credentialID: credentialID.base64EncodedString(),
            publicKeyCOSE: publicKeyCOSE.base64EncodedString(),
            privateKeyReference: privateKeyReference,
            notes: "iOS system passkey registration. Transient WebAuthn attestation and client data hash are not stored."
        )
    }
}

struct AppSystemPasskeyRegistrationInboxItem: Sendable, Equatable, Codable {
    let relyingPartyID: String
    let username: String
    let userHandle: Data
    let credentialID: Data
    let publicKeyCOSE: Data
    let privateKeyReference: String
    let title: String

    init(
        relyingPartyID: String,
        username: String,
        userHandle: Data,
        credentialID: Data,
        publicKeyCOSE: Data,
        privateKeyReference: String,
        title: String
    ) {
        self.relyingPartyID = relyingPartyID
        self.username = username
        self.userHandle = userHandle
        self.credentialID = credentialID
        self.publicKeyCOSE = publicKeyCOSE
        self.privateKeyReference = privateKeyReference
        self.title = title
    }

    var registrationResult: AppSystemPasskeyRegistrationResult {
        AppSystemPasskeyRegistrationResult(
            relyingPartyID: relyingPartyID,
            username: username,
            userHandle: userHandle,
            credentialID: credentialID,
            publicKeyCOSE: publicKeyCOSE,
            privateKeyReference: privateKeyReference,
            title: title,
            attestationObject: Data(),
            clientDataHash: Data()
        )
    }
}

struct AppSystemPasskeyRegistrationInboxStore: Sendable {
    private struct Manifest: Codable, Sendable, Equatable {
        let schemaVersion: Int
        let createdAt: TimeInterval
        let items: [Item]
    }

    private struct Item: Codable, Sendable, Equatable {
        let relativeContentPath: String
    }

    static let defaultAppGroupIdentifier = "group.monica-pass.monica"

    let manifestURL: URL

    private let inboxDirectoryURL: URL
    private let contentDirectoryName = "contents"
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(containerURL: URL) {
        inboxDirectoryURL = containerURL.appendingPathComponent("passkey-registration-inbox-v1", isDirectory: true)
        manifestURL = inboxDirectoryURL.appendingPathComponent("manifest.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
    }

    init?(appGroupIdentifier: String = Self.defaultAppGroupIdentifier) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }
        self.init(containerURL: containerURL)
    }

    func saveIncomingRegistration(
        _ registration: AppSystemPasskeyRegistrationInboxItem,
        now: Date = Date()
    ) throws {
        var registrations = try loadPendingRegistrations()
        registrations.removeAll { $0.credentialID == registration.credentialID }
        registrations.append(registration)
        try saveIncomingRegistrations(registrations, now: now)
    }

    func saveIncomingRegistrations(
        _ registrations: [AppSystemPasskeyRegistrationInboxItem],
        now: Date = Date()
    ) throws {
        try FileManager.default.createDirectory(
            at: inboxDirectoryURL,
            withIntermediateDirectories: true
        )
        let contentDirectoryURL = inboxDirectoryURL.appendingPathComponent(contentDirectoryName, isDirectory: true)
        try? FileManager.default.removeItem(at: contentDirectoryURL)
        try FileManager.default.createDirectory(
            at: contentDirectoryURL,
            withIntermediateDirectories: true
        )

        let items = try registrations.enumerated().map { index, registration in
            let fileName = "passkey-\(index).json"
            let contentURL = contentDirectoryURL.appendingPathComponent(fileName)
            try encoder.encode(registration).write(
                to: contentURL,
                options: [.atomic, .completeFileProtection]
            )
            return Item(relativeContentPath: "\(contentDirectoryName)/\(fileName)")
        }
        let manifest = Manifest(
            schemaVersion: 1,
            createdAt: now.timeIntervalSince1970,
            items: items
        )
        try encoder.encode(manifest).write(
            to: manifestURL,
            options: [.atomic, .completeFileProtection]
        )
    }

    func loadPendingRegistrations() throws -> [AppSystemPasskeyRegistrationInboxItem] {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return []
        }
        let manifest = try decoder.decode(
            Manifest.self,
            from: try Data(contentsOf: manifestURL)
        )
        return try manifest.items.map { item in
            let contentURL = inboxDirectoryURL.appendingPathComponent(item.relativeContentPath)
            return try decoder.decode(
                AppSystemPasskeyRegistrationInboxItem.self,
                from: try Data(contentsOf: contentURL)
            )
        }
    }

    func clearPendingRegistrations() throws {
        try? FileManager.default.removeItem(at: inboxDirectoryURL)
    }
}
