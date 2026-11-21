// MARK: - WiFi 条目：类型、仓库与 MDBX 引擎实现

import Foundation
import MonicaMDBX

public struct LocalWifiEntryDraft: Sendable, Equatable {
    public let title: String
    public let ssid: String
    public let securityType: String
    public let password: String
    public let hidden: Bool
    public let notes: String

    public let metadata: VaultEntryMetadata

    public init(
        title: String,
        ssid: String,
        securityType: String,
        password: String,
        hidden: Bool,
        notes: String
    ,
        metadata: VaultEntryMetadata = .empty) {
        self.title = title
        self.ssid = ssid
        self.securityType = securityType
        self.password = password
        self.hidden = hidden
        self.notes = notes
        self.metadata = metadata
    }
}

public struct LocalWifiEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let title: String
    public let ssid: String
    public let securityType: String
    public let password: String
    public let hidden: Bool
    public let notes: String
    public let favorite: Bool
    public let metadata: VaultEntryMetadata

    public init(
        id: String,
        projectID: String,
        title: String,
        ssid: String,
        securityType: String,
        password: String,
        hidden: Bool,
        notes: String,
        favorite: Bool = false,
        metadata: VaultEntryMetadata = .empty
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.ssid = ssid
        self.securityType = securityType
        self.password = password
        self.hidden = hidden
        self.notes = notes
        self.favorite = favorite
        self.metadata = metadata
    }
}

public extension LocalWifiEntry {
    var qrCodePayload: String {
        let type = normalizedQRCodeSecurityType
        let passwordSegment = type == "nopass" ? "" : "P:\(Self.qrEscaped(password));"
        return "WIFI:T:\(type);S:\(Self.qrEscaped(ssid));\(passwordSegment)H:\(hidden ? "true" : "false");;"
    }

    private var normalizedQRCodeSecurityType: String {
        let normalized = securityType.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if normalized.isEmpty || normalized == "OPEN" || normalized == "NONE" || normalized == "NOPASS" {
            return "nopass"
        }
        if normalized.contains("WEP") {
            return "WEP"
        }
        return "WPA"
    }

    private static func qrEscaped(_ value: String) -> String {
        value.reduce(into: "") { result, character in
            if "\\;,:\"".contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
    }
}

extension LocalVaultEntryRepository {
    public func createWifiEntry(projectID: String, draft: LocalWifiEntryDraft) throws -> LocalWifiEntry {
        try engine.createWifiEntry(in: session.handle, projectID: projectID, draft: normalizedWifiEntryDraft(draft))
    }

    public func listWifiEntries(projectID: String) throws -> [LocalWifiEntry] {
        try engine.listWifiEntries(in: session.handle, projectID: projectID)
    }

    public func updateWifiEntry(projectID: String, entryID: String, draft: LocalWifiEntryDraft) throws -> LocalWifiEntry {
        try engine.updateWifiEntry(in: session.handle, projectID: projectID, entryID: entryID, draft: normalizedWifiEntryDraft(draft))
    }

    public func setWifiEntryFavorite(projectID: String, entryID: String, favorite: Bool) throws -> LocalWifiEntry {
        try engine.setWifiEntryFavorite(in: session.handle, projectID: projectID, entryID: entryID, favorite: favorite)
    }

    public func deleteWifiEntry(projectID: String, entryID: String) throws {
        try engine.deleteWifiEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    public func listDeletedWifiEntries(projectID: String) throws -> [LocalWifiEntry] {
        try engine.listDeletedWifiEntries(in: session.handle, projectID: projectID)
    }

    public func restoreWifiEntry(projectID: String, entryID: String) throws -> LocalWifiEntry {
        try engine.restoreWifiEntry(in: session.handle, projectID: projectID, entryID: entryID)
    }

    private func normalizedWifiEntryDraft(_ draft: LocalWifiEntryDraft) throws -> LocalWifiEntryDraft {
        let normalizedTitle = try normalizedEntryTitle(draft.title)
        return LocalWifiEntryDraft(
            title: normalizedTitle,
            ssid: draft.ssid,
            securityType: draft.securityType,
            password: draft.password,
            hidden: draft.hidden,
            notes: draft.notes
        )
    }
}

extension MDBXLocalVaultEngine {
    public func createWifiEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalWifiEntryDraft) throws -> LocalWifiEntry {
        let entry = try createParityEntry(
            in: handle,
            projectID: projectID,
            entryType: "document-ref",
            kind: "wifi",
            title: draft.title,
            payload: [
                "ssid": draft.ssid,
                "securityType": draft.securityType,
                "password": draft.password,
                "hidden": draft.hidden,
                "notes": draft.notes
            ]
        )
        return try LocalWifiEntry(entry)
    }

    public func listWifiEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalWifiEntry] {
        try listParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "wifi").map(LocalWifiEntry.init)
    }

    public func updateWifiEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalWifiEntryDraft) throws -> LocalWifiEntry {
        let entry = try updateParityEntry(
            in: handle,
            projectID: projectID,
            entryID: entryID,
            entryType: "document-ref",
            kind: "wifi",
            title: draft.title,
            payload: [
                "ssid": draft.ssid,
                "securityType": draft.securityType,
                "password": draft.password,
                "hidden": draft.hidden,
                "notes": draft.notes
            ]
        )
        return try LocalWifiEntry(entry)
    }

    public func setWifiEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalWifiEntry {
        try LocalWifiEntry(setParityEntryFavorite(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "wifi", favorite: favorite))
    }

    public func deleteWifiEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws {
        try deleteParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "wifi")
    }

    public func listDeletedWifiEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalWifiEntry] {
        try listDeletedParityEntries(in: handle, projectID: projectID, entryType: "document-ref", kind: "wifi").map(LocalWifiEntry.init)
    }

    public func restoreWifiEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalWifiEntry {
        try LocalWifiEntry(restoreParityEntry(in: handle, projectID: projectID, entryID: entryID, entryType: "document-ref", kind: "wifi"))
    }
}

private extension LocalWifiEntry {
    init(_ entry: MonicaMDBXParityEntry) throws {
        let payload = try entry.payloadDictionary()
        self.init(
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            ssid: payload.string("ssid"),
            securityType: payload.string("securityType"),
            password: payload.string("password"),
            hidden: payload.bool("hidden"),
            notes: payload.string("notes"),
            favorite: entry.favorite,
            metadata: VaultEntryMetadata(entry.metadata)
        )
    }
}
