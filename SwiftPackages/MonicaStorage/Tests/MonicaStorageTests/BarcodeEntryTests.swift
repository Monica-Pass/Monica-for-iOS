import Foundation
import Testing
@testable import MonicaStorage

private let barcodeFixtures: [LocalBarcodeEntryDraft] = [
    LocalBarcodeEntryDraft(
        title: "登机牌",
        symbology: .pdf417,
        payload: "M1DOE/JOHN  EABC123 SFOJFK 0123 100Y012A0001 100",
        label: "登机牌"
    ),
    LocalBarcodeEntryDraft(
        title: "入场二维码",
        symbology: .qr,
        payload: "https://example.com/ticket/42?seat=12A",
        label: "电子票"
    ),
    LocalBarcodeEntryDraft(
        title: "会员卡条码",
        symbology: .code128,
        payload: "MONICA-2026-0001",
        label: "会员编号",
        notes: "收银台出示"
    ),
    LocalBarcodeEntryDraft(
        title: "商品条码",
        symbology: .ean13,
        payload: "590123412345",
        label: ""
    ),
    LocalBarcodeEntryDraft(
        title: "Aztec 车票",
        symbology: .aztec,
        payload: "TICKET:2026-11-21:SEAT-12A",
        label: "车票"
    )
]

@Test func barcodePayloadValidationRejectsUnrenderableContent() {
    #expect(throws: BarcodePayloadValidationError.emptyPayload) {
        try BarcodePayloadValidator.validate("   ", symbology: .qr)
    }
    #expect(throws: BarcodePayloadValidationError.unsupportedCharacters(symbology: .code128)) {
        try BarcodePayloadValidator.validate("订单-42", symbology: .code128)
    }
    #expect(throws: BarcodePayloadValidationError.payloadTooLong(symbology: .code128, maximumBytes: 80)) {
        try BarcodePayloadValidator.validate(String(repeating: "A", count: 81), symbology: .code128)
    }
    #expect(throws: BarcodePayloadValidationError.payloadTooLong(symbology: .qr, maximumBytes: 2000)) {
        try BarcodePayloadValidator.validate(String(repeating: "A", count: 2001), symbology: .qr)
    }
    #expect(throws: BarcodePayloadValidationError.eanDigitsRequired) {
        try BarcodePayloadValidator.validate("59012341234A", symbology: .ean13)
    }
    #expect(throws: BarcodePayloadValidationError.eanCheckDigitMismatch) {
        try BarcodePayloadValidator.validate("5901234123458", symbology: .ean13)
    }
}

@Test func ean13NormalizationComputesCheckDigitAndModules() throws {
    #expect(try EAN13Code.normalizedDigits("590123412345") == "5901234123457")
    #expect(try EAN13Code.normalizedDigits("5901234123457") == "5901234123457")
    #expect(try BarcodePayloadValidator.normalizedPayload("590123412345", symbology: .ean13) == "5901234123457")

    let modules = try EAN13Code.modules(for: "5901234123457")
    #expect(modules.count == 95)
    #expect(Array(modules.prefix(3)) == [true, false, true])
    #expect(Array(modules.dropFirst(45).prefix(5)) == [false, true, false, true, false])
    #expect(Array(modules.suffix(3)) == [true, false, true])
}

@Test func barcodeEntryPayloadCodecRoundTripsAllSymbologies() throws {
    for draft in barcodeFixtures {
        let payload = BarcodeEntryPayloadCodec.encoded(draft)
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let decodedPayload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let entry = BarcodeEntryPayloadCodec.decoded(
            decodedPayload,
            entryID: "entry-1",
            projectID: "project-1",
            title: draft.title,
            favorite: true
        )
        #expect(entry.id == "entry-1")
        #expect(entry.projectID == "project-1")
        #expect(entry.title == draft.title)
        #expect(entry.symbology == draft.symbology)
        #expect(entry.payload == draft.payload)
        #expect(entry.label == draft.label)
        #expect(entry.notes == draft.notes)
        #expect(entry.favorite)
        #expect(entry.draft == draft)
    }

    // 迁移兼容：缺失 schemaVersion 的旧/外部 payload 仍可读，缺省按 QR 处理。
    let legacy = BarcodeEntryPayloadCodec.decoded(
        ["payload": "legacy-content"],
        entryID: "legacy",
        projectID: "project-1",
        title: "Legacy",
        favorite: false
    )
    #expect(legacy.symbology == .qr)
    #expect(legacy.payload == "legacy-content")
    #expect(legacy.label == "")
}

@Test func barcodeEntriesRoundTripThroughEncryptedVault() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("monica-barcode-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let engine = MDBXLocalVaultEngine()
    let vaultRepository = LocalVaultRepository(engine: engine)
    let session = try vaultRepository.createVault(
        named: "Barcode",
        in: directory,
        password: "中文 password 12345!",
        deviceID: "ios-barcode-test"
    )
    let entries = vaultRepository.entryRepository(for: session)
    let project = try entries.createProject(title: "Boarding")

    var created: [LocalBarcodeEntry] = []
    for draft in barcodeFixtures {
        created.append(try entries.createBarcodeEntry(projectID: project.id, draft: draft))
    }
    #expect(created.count == barcodeFixtures.count)
    for (entry, draft) in zip(created, barcodeFixtures) {
        #expect(entry.title == draft.title)
        #expect(entry.symbology == draft.symbology)
        #expect(entry.payload == (try BarcodePayloadValidator.normalizedPayload(draft.payload, symbology: draft.symbology)))
    }

    _ = try entries.setBarcodeEntryFavorite(projectID: project.id, entryID: created[2].id, favorite: true)
    try entries.deleteBarcodeEntry(projectID: project.id, entryID: created[3].id)
    #expect(try entries.listBarcodeEntries(projectID: project.id).count == barcodeFixtures.count - 1)
    #expect(try entries.listDeletedBarcodeEntries(projectID: project.id).count == 1)
    _ = try entries.restoreBarcodeEntry(projectID: project.id, entryID: created[3].id)

    let updatedDraft = LocalBarcodeEntryDraft(
        title: "登机牌（改签）",
        symbology: .qr,
        payload: "BP:ABC123:2026-11-22:14C",
        label: "登机牌"
    )
    let updated = try entries.updateBarcodeEntry(projectID: project.id, entryID: created[0].id, draft: updatedDraft)
    #expect(updated.title == updatedDraft.title)
    #expect(updated.symbology == .qr)

    vaultRepository.closeVault(for: session)

    // 重新打开保险库（全新 engine 实例），确认条码内容走加密存储且可完整回读。
    let reopenedEngine = MDBXLocalVaultEngine()
    let reopenedRepository = LocalVaultRepository(engine: reopenedEngine)
    let reopened = try reopenedRepository.openVault(
        at: session.descriptor.fileURL,
        password: "中文 password 12345!",
        deviceID: "ios-barcode-test"
    )
    let reopenedEntries = reopenedRepository.entryRepository(for: reopened)
    // MDBX 引擎的项目列表是内存态；重开后用关闭前捕获的 projectID 直接读条目，验证加密内容持久化。
    let listed = try reopenedEntries.listBarcodeEntries(projectID: project.id)
    #expect(listed.count == barcodeFixtures.count)

    let reopenedBoardingPass = try #require(listed.first(where: { $0.id == updated.id }))
    #expect(reopenedBoardingPass.title == "登机牌（改签）")
    #expect(reopenedBoardingPass.symbology == .qr)
    #expect(reopenedBoardingPass.payload == "BP:ABC123:2026-11-22:14C")
    #expect(reopenedBoardingPass.label == "登机牌")

    let reopenedMemberCard = try #require(listed.first(where: { $0.id == created[2].id }))
    #expect(reopenedMemberCard.favorite)
    #expect(reopenedMemberCard.payload == "MONICA-2026-0001")

    let reopenedEAN = try #require(listed.first(where: { $0.id == created[3].id }))
    #expect(reopenedEAN.symbology == .ean13)
    #expect(reopenedEAN.payload == "5901234123457")

    reopenedRepository.closeVault(for: reopened)
    try? FileManager.default.removeItem(at: directory)
}

@Test func barcodeEntriesRoundTripThroughCSVCodec() {
    let csv = VaultCSVCodec.exportItems(barcodeFixtures.map(VaultCSVItemDraft.barcode))
    let report = VaultCSVCodec.importItems(from: csv)

    #expect(report.issues.isEmpty)
    #expect(report.items.count == barcodeFixtures.count)
    #expect(csv.hasPrefix(VaultCSVCodec.headerLine))
    #expect(csv.contains("payload") && csv.contains("symbology"))

    for (imported, expected) in zip(report.items, barcodeFixtures) {
        guard case .barcode(let draft) = imported else {
            Issue.record("Expected barcode draft")
            return
        }
        #expect(draft.title == expected.title)
        #expect(draft.symbology == expected.symbology)
        #expect(draft.payload == expected.payload)
        #expect(draft.label == expected.label)
        #expect(draft.notes == expected.notes)
    }
}

@Test func barcodeEntriesRoundTripThroughAndroidBackup() throws {
    let archive = try AndroidBackupCodec.exportItems(barcodeFixtures.map(VaultCSVItemDraft.barcode))
    let report = try AndroidBackupCodec.importItems(from: archive)

    #expect(report.issues.isEmpty)
    let barcodeDrafts = report.items.compactMap { item -> LocalBarcodeEntryDraft? in
        guard case .barcode(let draft) = item else { return nil }
        return draft
    }
    #expect(barcodeDrafts.count == barcodeFixtures.count)
    for (imported, expected) in zip(barcodeDrafts, barcodeFixtures) {
        #expect(imported.title == expected.title)
        #expect(imported.symbology == expected.symbology)
        #expect(imported.payload == expected.payload)
        #expect(imported.label == expected.label)
        #expect(imported.notes == expected.notes)
    }
}

@Test func androidBackupWithoutBarcodeMetadataDefaultsToQR() throws {
    // Android 端的条码只是 loginType == "BARCODE" 的密码条目，没有制式字段。
    let object: [String: Any] = [
        "id": 42,
        "title": "安卓条码",
        "username": "",
        "password": "ANDROID-PAYLOAD-42",
        "website": "",
        "notes": "from android",
        "loginType": "BARCODE",
        "isFavorite": false
    ]
    let jsonData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let json = try #require(String(data: jsonData, encoding: .utf8))
    let archive = try AndroidBackupCodec.exportZip(entries: [
        "folders/Boarding/passwords/password_42_1797000000042.json": json
    ])

    let report = try AndroidBackupCodec.importItems(from: archive)
    #expect(report.issues.isEmpty)
    let imported = try #require(report.items.first)
    guard case .barcode(let draft) = imported else {
        Issue.record("Expected barcode draft")
        return
    }
    #expect(draft.title == "安卓条码")
    #expect(draft.symbology == .qr)
    #expect(draft.payload == "ANDROID-PAYLOAD-42")
    #expect(draft.notes == "from android")
}
