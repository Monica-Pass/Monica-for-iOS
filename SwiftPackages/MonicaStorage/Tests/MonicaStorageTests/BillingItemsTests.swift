import Testing
import Foundation
import ZIPFoundation
import MonicaStorage

// MARK: - 类型与稳定值

@Test func billingItemKindsExposeStableRawValuesAndDisplayNames() {
    #expect(UnifiedVaultItemKind.billingAddress.rawValue == "billingAddress")
    #expect(UnifiedVaultItemKind.paymentAccount.rawValue == "paymentAccount")
    #expect(UnifiedVaultItemKind.billingAddress.displayName == "账单地址")
    #expect(UnifiedVaultItemKind.paymentAccount.displayName == "支付账户")
    #expect(UnifiedVaultItemKind.fullAndroidParityKinds.contains(.billingAddress))
    #expect(UnifiedVaultItemKind.fullAndroidParityKinds.contains(.paymentAccount))
    #expect(UnifiedVaultItemKind.phaseOneKinds.contains(.billingAddress) == false)
    #expect(UnifiedVaultItemKind.phaseOneKinds.contains(.paymentAccount) == false)
    #expect(UnifiedVaultItemKind(rawValue: "billingAddress") == .billingAddress)
    #expect(UnifiedVaultItemKind(rawValue: "paymentAccount") == .paymentAccount)
}

@Test func billingAddressFormatsAddressLinesForInternationalLayouts() {
    let japanese = LocalBillingAddressEntry(
        id: "addr-1",
        projectID: "project-1",
        title: "自宅",
        streetAddress: "1-2-3 Shibuya",
        apartment: "Room 401",
        city: "Shibuya-ku",
        stateProvince: "Tokyo",
        postalCode: "150-0002",
        country: "Japan"
    )
    #expect(japanese.addressLines == ["1-2-3 Shibuya", "Room 401", "Shibuya-ku, Tokyo 150-0002 Japan"])
    #expect(japanese.formattedAddress.contains("\n"))

    let american = LocalBillingAddressEntry(
        id: "addr-2",
        projectID: "project-1",
        title: "Home",
        streetAddress: "500 Congress Ave",
        city: "Austin",
        stateProvince: "TX",
        postalCode: "78701",
        country: "United States"
    )
    #expect(american.addressLines == ["500 Congress Ave", "Austin, TX 78701 United States"])

    let minimal = LocalBillingAddressEntry(id: "addr-3", projectID: "project-1", title: "空", country: "Germany")
    #expect(minimal.addressLines == ["Germany"])
}

// MARK: - 温和格式校验

@Test func billingFieldValidatorAcceptsInternationalFormats() {
    #expect(BillingFieldValidator.ibanIssue("GB82 WEST 1234 5698 7654 32") == nil)
    #expect(BillingFieldValidator.ibanIssue("de89370400440532013000") == nil)
    #expect(BillingFieldValidator.ibanIssue("") == nil)
    #expect(BillingFieldValidator.swiftBICIssue("DEUTDEFF") == nil)
    #expect(BillingFieldValidator.swiftBICIssue("deutdeff500") == nil)
    #expect(BillingFieldValidator.swiftBICIssue("") == nil)
    #expect(BillingFieldValidator.routingNumberIssue("021000021") == nil)
    #expect(BillingFieldValidator.routingNumberIssue("12-34 56") == nil)
    #expect(BillingFieldValidator.routingNumberIssue("ABC123") == nil)
    #expect(BillingFieldValidator.postalCodeIssue("SW1A 1AA") == nil)
    #expect(BillingFieldValidator.postalCodeIssue("150-0002") == nil)
    #expect(BillingFieldValidator.postalCodeIssue("") == nil)
    #expect(BillingFieldValidator.currencyIssue("USD") == nil)
    #expect(BillingFieldValidator.currencyIssue("jpy") == nil)
}

@Test func billingFieldValidatorOnlyHintsObviousFormatProblems() {
    #expect(BillingFieldValidator.ibanIssue("GB82WEST12345698765433") == .ibanChecksum)
    #expect(BillingFieldValidator.ibanIssue("GB82WEST1234$$") == .ibanCharacters)
    #expect(BillingFieldValidator.ibanIssue("GB82") == .ibanLength)
    #expect(BillingFieldValidator.swiftBICIssue("DEUTDEF") == .swiftLength)
    #expect(BillingFieldValidator.swiftBICIssue("DEUTDEFF50") == .swiftLength)
    #expect(BillingFieldValidator.swiftBICIssue("DEUTDE F") == .swiftCharacters)
    #expect(BillingFieldValidator.routingNumberIssue("12#34") == .routingNumberFormat)
    #expect(BillingFieldValidator.routingNumberIssue(String(repeating: "9", count: 40)) == .routingNumberFormat)
    #expect(BillingFieldValidator.postalCodeIssue("!!!") == .postalCodeFormat)
    #expect(BillingFieldValidator.postalCodeIssue(String(repeating: "1", count: 20)) == .postalCodeFormat)
    #expect(BillingFieldValidator.currencyIssue("US") == .currencyFormat)
    #expect(BillingFieldValidator.currencyIssue("US1") == .currencyFormat)
}

@Test func billingFieldValidatorMasksAccountNumbersKeepingLastFourDigits() {
    #expect(BillingFieldValidator.maskedAccountNumber("1234567890") == "••••••7890")
    #expect(BillingFieldValidator.maskedAccountNumber("1234") == "••••")
    #expect(BillingFieldValidator.maskedAccountNumber("   ") == "")
}

// MARK: - 稳定 ID 关联

@Test func billingReferencesDistinguishLinkedAndMissingTargets() {
    let card = LocalCardEntry(
        id: "card-1",
        projectID: "project-1",
        title: "Visa",
        cardholderName: "Alice",
        number: "4111111111111111",
        expiryMonth: "12",
        expiryYear: "2030",
        cvv: "123",
        issuer: "Bank",
        network: "Visa",
        notes: ""
    )
    let address = LocalBillingAddressEntry(
        id: "addr-1",
        projectID: "project-1",
        title: "Home",
        linkedCardIDs: ["card-1", "card-deleted"]
    )
    #expect(address.linkedCards(in: [card]).map(\.id) == ["card-1"])
    #expect(address.missingLinkedCardIDs(in: [card]) == ["card-deleted"])

    let linked = LocalPaymentAccountEntry(
        id: "acct-1",
        projectID: "project-1",
        title: "Checking",
        linkedCardID: "card-1",
        billingAddressID: "addr-1"
    )
    #expect(linked.linkedCard(in: [card])?.id == "card-1")
    #expect(linked.billingAddress(in: [address])?.id == "addr-1")
    #expect(linked.linkedCardReferenceStatus(in: [card]) == .linked)
    #expect(linked.billingAddressReferenceStatus(in: [address]) == .linked)

    let stale = LocalPaymentAccountEntry(
        id: "acct-2",
        projectID: "project-1",
        title: "Old",
        linkedCardID: "card-missing",
        billingAddressID: "addr-missing"
    )
    #expect(stale.billingAddressReferenceStatus(in: [address]) == .missing)
    #expect(stale.linkedCardReferenceStatus(in: [card]) == .missing)

    let unlinked = LocalPaymentAccountEntry(id: "acct-3", projectID: "project-1", title: "Cash")
    #expect(unlinked.billingAddressReferenceStatus(in: [address]) == .none)
    #expect(unlinked.linkedCardReferenceStatus(in: [card]) == .none)
}

// MARK: - CSV

@Test func billingAddressCSVRoundTripPreservesFields() {
    let draft = LocalBillingAddressEntryDraft(
        title: "Home",
        fullName: "Alice Zhang",
        streetAddress: "500 Congress Ave",
        apartment: "Apt 12",
        city: "Austin",
        stateProvince: "TX",
        postalCode: "78701",
        country: "United States",
        phone: "+1 512 555 0100",
        notes: "门禁 1234",
        linkedCardIDs: ["card-1", "card-2"]
    )

    let csv = VaultCSVCodec.exportItems([.billingAddress(draft)])
    let report = VaultCSVCodec.importItems(from: csv)

    #expect(report.issues.isEmpty)
    #expect(report.items == [.billingAddress(draft)])
    #expect(csv.contains("streetAddress"))
    #expect(csv.contains("linkedCardIDs"))
}

@Test func paymentAccountCSVRoundTripPreservesFieldsAndLinks() {
    let draft = LocalPaymentAccountEntryDraft(
        title: "工资账户",
        kind: .bankAccount,
        provider: "招商银行",
        accountName: "alice@example.com",
        accountHolderName: "Alice Zhang",
        iban: "GB82WEST12345698765432",
        swiftBIC: "DEUTDEFF500",
        routingNumber: "021000021",
        accountNumber: "1234567890",
        currency: "USD",
        notes: "备用账户",
        linkedCardID: "card-1",
        billingAddressID: "addr-1"
    )

    let csv = VaultCSVCodec.exportItems([.paymentAccount(draft)])
    let report = VaultCSVCodec.importItems(from: csv)

    #expect(report.issues.isEmpty)
    #expect(report.items == [.paymentAccount(draft)])
    #expect(csv.contains("paymentType"))
    #expect(csv.contains("BANK_ACCOUNT"))
}

@Test func csvImportHintsSuspiciousPaymentFormatsWithoutDroppingRow() {
    let draft = LocalPaymentAccountEntryDraft(
        title: "可疑账户",
        kind: .other,
        iban: "GB82WEST12345698765433",
        swiftBIC: "TOOLONGSWIFT",
        currency: "US"
    )
    let csv = VaultCSVCodec.exportItems([.paymentAccount(draft)])
    let report = VaultCSVCodec.importItems(from: csv)

    #expect(report.items.count == 1)
    #expect(report.issues.contains { $0.code == .invalidFieldFormat && $0.field == "iban" })
}

// MARK: - Android 备份

@Test func androidBackupExportsBillingItemsIntoCardWalletPaths() throws {
    let address = LocalBillingAddressEntryDraft(title: "Home", streetAddress: "500 Congress Ave", city: "Austin", country: "United States")
    let account = LocalPaymentAccountEntryDraft(
        title: "Checking",
        kind: .bankAccount,
        iban: "GB82WEST12345698765432",
        currency: "USD",
        billingAddressID: "addr-1"
    )

    let data = try AndroidBackupCodec.exportItems([.billingAddress(address), .paymentAccount(account)])
    let archive = try ArchiveReader(paths: data)

    #expect(archive.paths.contains { $0.contains("/billing_addresses/billing_address_1_") })
    #expect(archive.paths.contains { $0.contains("/payment_accounts/payment_account_2_") })
    let paylod = try archive.json(at: #require(archive.paths.first { $0.contains("/payment_accounts/") }))
    #expect(paylod["itemType"] as? String == "PAYMENT_ACCOUNT")
    let itemData = try #require(paylod["itemData"] as? String)
    #expect(itemData.contains("\"billingAddressID\":\"addr-1\""))
    #expect(itemData.contains("\"paymentType\":\"BANK_ACCOUNT\""))
}

@Test func androidBackupRoundTripsBillingItems() throws {
    let address = LocalBillingAddressEntryDraft(
        title: "Home",
        fullName: "Alice Zhang",
        streetAddress: "500 Congress Ave",
        apartment: "Apt 12",
        city: "Austin",
        stateProvince: "TX",
        postalCode: "78701",
        country: "United States",
        phone: "+1 512 555 0100",
        notes: "门禁 1234",
        linkedCardIDs: ["card-1"]
    )
    let account = LocalPaymentAccountEntryDraft(
        title: "工资账户",
        kind: .digitalWallet,
        provider: "PayPal",
        accountName: "alice@example.com",
        accountHolderName: "Alice Zhang",
        iban: "GB82WEST12345698765432",
        swiftBIC: "DEUTDEFF500",
        routingNumber: "021000021",
        accountNumber: "1234567890",
        currency: "USD",
        notes: "备用账户",
        linkedCardID: "card-1",
        billingAddressID: "addr-1"
    )

    let data = try AndroidBackupCodec.exportItems([.billingAddress(address), .paymentAccount(account)])
    let report = try AndroidBackupCodec.importItems(from: data)

    #expect(report.issues.isEmpty)
    #expect(report.items.count == 2)
    #expect(report.items.contains(.billingAddress(address)))
    #expect(report.items.contains(.paymentAccount(account)))
}

@Test func androidBackupKeepsEmbeddedAndroidAddressInNotesWhenNoLinkExists() throws {
    let itemData = try jsonString([
        "accountName": "alice",
        "billingAddress": try jsonString([
            "fullName": "Alice Zhang",
            "streetAddress": "500 Congress Ave",
            "city": "Austin",
            "stateProvince": "TX",
            "postalCode": "78701",
            "country": "United States"
        ])
    ])
    let payload = try jsonString([
        "id": 1,
        "itemType": "PAYMENT_ACCOUNT",
        "title": "Chase",
        "itemData": itemData,
        "notes": "旧备注"
    ])
    let data = try AndroidBackupCodec.exportZip(entries: [
        "folders/Personal/payment_accounts/payment_account_1_1797000000000.json": payload
    ])
    let report = try AndroidBackupCodec.importItems(from: data)

    guard case .paymentAccount(let draft)? = report.items.first else {
        Issue.record("应导入支付账户条目")
        return
    }
    #expect(draft.notes.contains("旧备注"))
    #expect(draft.notes.contains("500 Congress Ave"))
    #expect(draft.billingAddressID.isEmpty)
}

@Test func androidBackupKeepsLinkAndSkipsEmbeddedAddressWhenReferenceExists() throws {
    let itemData = try jsonString([
        "accountName": "alice",
        "billingAddressID": "addr-9",
        "billingAddress": try jsonString(["streetAddress": "1 Main St", "country": "US"])
    ])
    let payload = try jsonString([
        "id": 1,
        "itemType": "PAYMENT_ACCOUNT",
        "title": "Chase",
        "itemData": itemData,
        "notes": "旧备注"
    ])
    let data = try AndroidBackupCodec.exportZip(entries: [
        "folders/Personal/payment_accounts/payment_account_1_1797000000000.json": payload
    ])
    let report = try AndroidBackupCodec.importItems(from: data)

    guard case .paymentAccount(let draft)? = report.items.first else {
        Issue.record("应导入支付账户条目")
        return
    }
    #expect(draft.billingAddressID == "addr-9")
    #expect(draft.notes == "旧备注")
}

@Test func androidBackupRestoresDeletedBillingItemsFromTrash() throws {
    let entry = try jsonString([
        "id": 7,
        "itemType": "BILLING_ADDRESS",
        "title": "Home",
        "itemData": try jsonString(["streetAddress": "500 Congress Ave", "country": "United States"]),
        "notes": "",
        "deletedAt": 1_797_000_000_000
    ])
    let data = try AndroidBackupCodec.exportZip(entries: [
        "trash/trash_secure_items.json": "[" + entry + "]"
    ])
    let report = try AndroidBackupCodec.importItems(from: data)

    #expect(report.deletedItems.count == 1)
    guard case .billingAddress(let draft)? = report.deletedItems.first?.draft else {
        Issue.record("应导入回收站账单地址条目")
        return
    }
    #expect(draft.title == "Home")
    #expect(draft.streetAddress == "500 Congress Ave")
}

// MARK: - 仓库归一化与真实引擎往返

private func makeBillingSession() throws -> (LocalVaultEntryRepository, LocalVaultProject, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("monica-billing-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let engine = MDBXLocalVaultEngine()
    let repository = LocalVaultRepository(engine: engine)
    let session = try repository.createVault(
        named: "Personal",
        in: directory,
        password: "password 12345!",
        deviceID: "ios-billing-test"
    )
    let entryRepository = LocalVaultEntryRepository(session: session, engine: engine)
    let project = try entryRepository.createProject(title: "Personal")
    return (entryRepository, project, directory)
}

@Test func billingAddressRepositoryNormalizesTitleAndReferenceIdentifiers() throws {
    let (entryRepository, project, directory) = try makeBillingSession()
    defer { try? FileManager.default.removeItem(at: directory) }

    let entry = try entryRepository.createBillingAddressEntry(
        projectID: project.id,
        draft: LocalBillingAddressEntryDraft(
            title: "  家  ",
            fullName: "  Alice Zhang  ",
            streetAddress: " 500 Congress Ave ",
            linkedCardIDs: [" card-1 ", "card-1", "", "card-2"]
        )
    )

    #expect(entry.title == "家")
    #expect(entry.fullName == "Alice Zhang")
    #expect(entry.streetAddress == "500 Congress Ave")
    #expect(entry.linkedCardIDs == ["card-1", "card-2"])
    #expect(try entryRepository.listBillingAddressEntries(projectID: project.id) == [entry])
}

@Test func paymentAccountRepositoryNormalizesIBANSWIFTAndCurrency() throws {
    let (entryRepository, project, directory) = try makeBillingSession()
    defer { try? FileManager.default.removeItem(at: directory) }

    let entry = try entryRepository.createPaymentAccountEntry(
        projectID: project.id,
        draft: LocalPaymentAccountEntryDraft(
            title: " 工资账户 ",
            kind: .bankAccount,
            iban: "gb82 west 1234 5698 7654 32",
            swiftBIC: " deutdeff ",
            currency: " usd ",
            linkedCardID: " card-1 ",
            billingAddressID: " addr-1 "
        )
    )

    #expect(entry.title == "工资账户")
    #expect(entry.iban == "GB82WEST12345698765432")
    #expect(entry.swiftBIC == "DEUTDEFF")
    #expect(entry.currency == "USD")
    #expect(entry.linkedCardID == "card-1")
    #expect(entry.billingAddressID == "addr-1")
    #expect(entry.kind == .bankAccount)
}

@Test func billingRepositoryRejectsBlankTitles() throws {
    let (entryRepository, project, directory) = try makeBillingSession()
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(throws: LocalVaultRepositoryError.self) {
        _ = try entryRepository.createBillingAddressEntry(
            projectID: project.id,
            draft: LocalBillingAddressEntryDraft(title: "   ")
        )
    }
    #expect(throws: LocalVaultRepositoryError.self) {
        _ = try entryRepository.createPaymentAccountEntry(
            projectID: project.id,
            draft: LocalPaymentAccountEntryDraft(title: "")
        )
    }
}

@Test func billingEntriesSurviveEngineRoundTripWithFavoriteDeleteRestore() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("monica-billing-roundtrip-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let engine = MDBXLocalVaultEngine()
    let repository = LocalVaultRepository(engine: engine)
    let session = try repository.createVault(
        named: "Personal",
        in: directory,
        password: "password 12345!",
        deviceID: "ios-billing-test"
    )
    let entryRepository = LocalVaultEntryRepository(session: session, engine: engine)
    let project = try entryRepository.createProject(title: "Personal")

    let address = try entryRepository.createBillingAddressEntry(
        projectID: project.id,
        draft: LocalBillingAddressEntryDraft(
            title: "Home",
            fullName: "Alice Zhang",
            streetAddress: "500 Congress Ave",
            apartment: "Apt 12",
            city: "Austin",
            stateProvince: "TX",
            postalCode: "78701",
            country: "United States",
            phone: "+1 512 555 0100",
            notes: "门禁 1234",
            linkedCardIDs: ["card-1", "card-2"]
        )
    )
    let account = try entryRepository.createPaymentAccountEntry(
        projectID: project.id,
        draft: LocalPaymentAccountEntryDraft(
            title: "工资账户",
            kind: .bankAccount,
            provider: "招商银行",
            accountName: "alice@example.com",
            accountHolderName: "Alice Zhang",
            iban: "GB82WEST12345698765432",
            swiftBIC: "DEUTDEFF500",
            routingNumber: "021000021",
            accountNumber: "1234567890",
            currency: "USD",
            notes: "备用账户",
            linkedCardID: "card-1",
            billingAddressID: address.id
        )
    )

    #expect(try entryRepository.listBillingAddressEntries(projectID: project.id) == [address])
    #expect(try entryRepository.listPaymentAccountEntries(projectID: project.id) == [account])
    #expect(account.billingAddress(in: [address])?.id == address.id)

    let favorite = try entryRepository.setPaymentAccountEntryFavorite(
        projectID: project.id,
        entryID: account.id,
        favorite: true
    )
    #expect(favorite.favorite)

    try entryRepository.deleteBillingAddressEntry(projectID: project.id, entryID: address.id)
    #expect(try entryRepository.listBillingAddressEntries(projectID: project.id).isEmpty)
    let deletedIDs = try entryRepository.listDeletedBillingAddressEntries(projectID: project.id).map(\.id)
    #expect(deletedIDs == [address.id])

    let restored = try entryRepository.restoreBillingAddressEntry(projectID: project.id, entryID: address.id)
    #expect(restored.id == address.id)
    #expect(restored.linkedCardIDs == ["card-1", "card-2"])

    let secondProject = try entryRepository.createProject(title: "Work")
    let moved = try entryRepository.moveEntry(
        kind: .paymentAccount,
        entryID: account.id,
        fromProjectID: project.id,
        toProjectID: secondProject.id
    )
    #expect(moved.id == account.id)
    let movedIDs = try entryRepository.listPaymentAccountEntries(projectID: secondProject.id).map(\.id)
    #expect(movedIDs == [account.id])
}

private struct ArchiveReader {
    let paths: [String]
    private let data: Data

    init(paths data: Data) throws {
        self.data = data
        let archive = try Archive(data: data, accessMode: .read)
        self.paths = archive.map(\.path)
    }

    func json(at path: String) throws -> [String: Any] {
        let archive = try Archive(data: data, accessMode: .read)
        for entry in archive where entry.path == path {
            var payload = Data()
            _ = try archive.extract(entry) { payload.append($0) }
            return try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        }
        Issue.record("压缩包内找不到路径：\(path)")
        return [:]
    }
}

private func jsonString(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

// MARK: - 搜索索引投影

struct BillingSearchIndexTests {
    private func makeSnapshot() -> VaultSearchEntrySnapshot {
        var snapshot = VaultSearchEntrySnapshot()
        snapshot.billingAddressEntries = [
            LocalBillingAddressEntry(
                id: "address-1",
                projectID: "project-1",
                title: "家庭地址",
                fullName: "ZHANG SAN",
                streetAddress: "1 Heping Road",
                city: "Shanghai",
                postalCode: "200000",
                country: "China",
                phone: "+86 21 1234 5678",
                notes: "周末收件"
            )
        ]
        snapshot.paymentAccountEntries = [
            LocalPaymentAccountEntry(
                id: "account-1",
                projectID: "project-1",
                title: "工资卡账户",
                kind: .bankAccount,
                provider: "Monica Bank",
                accountName: "Monica Studio",
                accountHolderName: "ZHANG SAN",
                iban: "DE89370400440532013000",
                swiftBIC: "DEUTDEFF",
                routingNumber: "021000021",
                accountNumber: "1234567890",
                currency: "EUR",
                billingAddressID: "address-1"
            )
        ]
        snapshot.deletedPaymentAccountEntries = [
            LocalPaymentAccountEntry(
                id: "account-deleted",
                projectID: "project-1",
                title: "旧账户",
                kind: .digitalWallet,
                provider: "Old Wallet",
                accountName: "legacy",
                iban: "GB82WEST12345698765432",
                accountNumber: "9876543210",
                currency: "GBP"
            )
        ]
        return snapshot
    }

    @Test func searchIndexProjectsBillingEntriesWithoutSecrets() {
        let snapshot = makeSnapshot()
        let documents = VaultSearchDocumentBuilder.documents(from: snapshot)

        #expect(documents.count == 3)
        #expect(documents.contains { $0.kind == .billingAddress && $0.id == "address-1" })
        #expect(documents.contains { $0.kind == .paymentAccount && $0.id == "account-1" })
        #expect(documents.contains { $0.kind == .paymentAccount && $0.id == "account-deleted" && $0.isDeleted })

        let secrets = [
            "DE89370400440532013000",
            "GB82WEST12345698765432",
            "1234567890",
            "9876543210",
            "DEUTDEFF",
            "021000021",
            "+86 21 1234 5678"
        ]
        for document in documents {
            let searchable = ([document.title, document.username, document.url, document.details, document.notes]
                + document.tags).joined(separator: "\u{1F}")
            for secret in secrets {
                #expect(!searchable.contains(secret), "索引中不允许出现敏感值 \(secret)")
            }
        }
    }

    @Test func searchIndexFindsBillingEntriesByNonSecretFields() {
        let index = VaultSearchIndex(
            documents: VaultSearchDocumentBuilder.documents(from: makeSnapshot())
        )

        let addressHit = index.search("家庭地址")
        #expect(addressHit.results.contains { $0.kind == .billingAddress })

        let cityHit = index.search("Shanghai")
        #expect(cityHit.results.contains { $0.id == "address-1" })

        let providerHit = index.search("Monica Bank")
        #expect(providerHit.results.contains { $0.kind == .paymentAccount })

        #expect(index.search("DE89370400440532013000").results.isEmpty)
        #expect(index.search("1234567890").results.isEmpty)
        #expect(index.search("021000021").results.isEmpty)
    }
}
