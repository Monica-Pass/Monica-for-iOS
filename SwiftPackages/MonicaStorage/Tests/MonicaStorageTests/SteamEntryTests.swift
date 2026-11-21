import Foundation
import Testing
@testable import MonicaStorage

private let vectorSecret = "MDEyMzQ1Njc4OWFiY2RlZmdoaWo="

@Test func steamSharedSecretValidationNormalizesAndRejectsBadInput() {
    #expect(SteamSharedSecretValidator.isValid(vectorSecret))
    #expect(SteamSharedSecretValidator.isValid("MDEyMzQ1\nNjc4OWFiY2RlZmdoaWo"))
    #expect(SteamSharedSecretValidator.normalizedBase64("MDEyMzQ1 Njc4OWFiY2RlZmdoaWo") == vectorSecret)
    #expect(!SteamSharedSecretValidator.isValid(""))
    #expect(!SteamSharedSecretValidator.isValid("***"))
    #expect(!SteamSharedSecretValidator.isValid("YQ=="))
}

@Test func steamEntryPayloadCodecRoundTripsWithoutLosingFields() {
    let draft = LocalSteamEntryDraft(
        title: "Steam · alice",
        accountName: "alice",
        steamID: "76561198000000000",
        sharedSecret: vectorSecret,
        issuer: "Steam",
        notes: "backup code in 1password"
    )
    let payload = SteamEntryPayloadCodec.encoded(draft)
    #expect(payload[SteamEntryPayloadCodec.Key.schemaVersion] as? Int == 1)

    let decoded = SteamEntryPayloadCodec.decoded(
        payload,
        entryID: "entry-1",
        projectID: "project-1",
        title: "Steam · alice",
        favorite: true
    )
    #expect(decoded.id == "entry-1")
    #expect(decoded.projectID == "project-1")
    #expect(decoded.accountName == "alice")
    #expect(decoded.steamID == "76561198000000000")
    #expect(decoded.sharedSecret == vectorSecret)
    #expect(decoded.notes == "backup code in 1password")
    #expect(decoded.favorite)
}

@Test func steamEntryPayloadCodecDropsCorruptSecretInsteadOfCrashing() {
    let decoded = SteamEntryPayloadCodec.decoded(
        ["sharedSecret": "not-a-secret"],
        entryID: "entry-1",
        projectID: "project-1",
        title: "Steam",
        favorite: false
    )
    #expect(decoded.sharedSecret.isEmpty)
    #expect(decoded.issuer == "Steam")
}

@Test func steamEntryDescriptionsNeverContainSharedSecret() {
    let draft = LocalSteamEntryDraft(title: "Steam · alice", accountName: "alice", sharedSecret: vectorSecret)
    let entry = LocalSteamEntry(
        id: "entry-1",
        projectID: "project-1",
        title: draft.title,
        accountName: draft.accountName,
        sharedSecret: draft.sharedSecret
    )
    #expect(!String(describing: draft).contains(vectorSecret))
    #expect(!String(describing: entry).contains(vectorSecret))
    #expect(String(describing: entry).contains("redacted"))
}

@Test func steamEntriesRoundTripThroughMDBXEngine() throws {
    let engine = MDBXLocalVaultEngine()
    let vaultRepository = LocalVaultRepository(engine: engine)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("monica-steam-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let session = try vaultRepository.createVault(
        named: "Personal",
        in: directory,
        password: "中文 password 12345!",
        deviceID: "ios-storage-test"
    )
    let entryRepository = LocalVaultEntryRepository(session: session, engine: engine)
    let project = try entryRepository.createProject(title: "Gaming")

    let created = try entryRepository.createSteamEntry(
        projectID: project.id,
        draft: LocalSteamEntryDraft(
            title: "  Steam · alice  ",
            accountName: " alice ",
            steamID: "76561198000000000",
            sharedSecret: vectorSecret,
            notes: "main account"
        )
    )
    #expect(created.title == "Steam · alice")
    #expect(created.accountName == "alice")
    #expect(created.sharedSecret == vectorSecret)

    let listed = try entryRepository.listSteamEntries(projectID: project.id)
    #expect(listed == [created])

    let favorite = try entryRepository.setSteamEntryFavorite(projectID: project.id, entryID: created.id, favorite: true)
    #expect(favorite.favorite)

    let updated = try entryRepository.updateSteamEntry(
        projectID: project.id,
        entryID: created.id,
        draft: LocalSteamEntryDraft(
            title: "Steam · alt",
            accountName: "alice",
            sharedSecret: vectorSecret,
            notes: "alt"
        )
    )
    #expect(updated.title == "Steam · alt")
    #expect(updated.favorite)

    try entryRepository.deleteSteamEntry(projectID: project.id, entryID: created.id)
    #expect(try entryRepository.listSteamEntries(projectID: project.id).isEmpty)
    let deleted = try entryRepository.listDeletedSteamEntries(projectID: project.id)
    #expect(deleted.map(\.id) == [created.id])

    let restored = try entryRepository.restoreSteamEntry(projectID: project.id, entryID: created.id)
    #expect(restored.id == created.id)
    #expect(try entryRepository.listSteamEntries(projectID: project.id).count == 1)
}

@Test func steamEntryRejectsEmptyTitleAndInvalidSecret() throws {
    let engine = MDBXLocalVaultEngine()
    let vaultRepository = LocalVaultRepository(engine: engine)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("monica-steam-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = try vaultRepository.createVault(
        named: "Personal",
        in: directory,
        password: "中文 password 12345!",
        deviceID: "ios-storage-test"
    )
    let entryRepository = LocalVaultEntryRepository(session: session, engine: engine)
    let project = try entryRepository.createProject(title: "Gaming")

    #expect(throws: LocalVaultRepositoryError.emptyEntryTitle) {
        _ = try entryRepository.createSteamEntry(
            projectID: project.id,
            draft: LocalSteamEntryDraft(title: "   ", sharedSecret: vectorSecret)
        )
    }
    #expect(throws: LocalVaultRepositoryError.invalidEntryPayload) {
        _ = try entryRepository.createSteamEntry(
            projectID: project.id,
            draft: LocalSteamEntryDraft(title: "Steam", sharedSecret: "not base64")
        )
    }
    #expect(try entryRepository.listSteamEntries(projectID: project.id).isEmpty)
}

@Test func steamEntrySurvivesCSVAndAndroidBackupRoundTrip() throws {
    let draft = LocalSteamEntryDraft(
        title: "Steam · alice",
        accountName: "alice",
        steamID: "76561198000000000",
        sharedSecret: vectorSecret,
        notes: "main"
    )

    let csv = VaultCSVCodec.exportItems([.steam(draft)])
    let imported = VaultCSVCodec.importItems(from: csv)
    #expect(imported.issues.isEmpty)
    #expect(imported.items.count == 1)
    guard case .steam(let decoded) = imported.items.first else {
        Issue.record("CSV 导入未还原 Steam 条目")
        return
    }
    #expect(decoded.accountName == "alice")
    #expect(decoded.sharedSecret == vectorSecret)
    #expect(decoded.notes == "main")

    // Android 备份把 Steam 写成 STEAM 型 TOTP，导回时必须还原成 Steam 条目。
    let backupItemData = LocalSteamEntryDraft.backupItemData(from: draft)
    #expect(backupItemData["otpType"] as? String == "STEAM")
    #expect(backupItemData["digits"] as? Int == 5)
    let roundTripped = LocalSteamEntryDraft.steamDraft(
        title: draft.title,
        issuer: draft.issuer,
        accountName: draft.accountName,
        itemData: backupItemData
    )
    #expect(roundTripped?.sharedSecret == vectorSecret)
    #expect(roundTripped?.accountName == "alice")
}
