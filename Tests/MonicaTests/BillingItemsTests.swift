@testable import Monica
import MonicaCore
import MonicaStorage
import UIKit
import XCTest

@MainActor
final class BillingItemsTests: XCTestCase {
    private func repositoryFileURL(_ relativePath: String) throws -> URL {
        #if os(iOS) && !targetEnvironment(simulator)
        throw XCTSkip("Repository files are not available inside the real-device test sandbox.")
        #else
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Repository file is not available in this test environment: \(relativePath)")
        }
        return url
        #endif
    }

    private func makeSession() -> AppSessionModel {
        AppSessionModel(
            sensitivePasteboard: MonicaSensitivePasteboard(pasteboard: MemoryBillingPasteboard()),
            sensitivePreviewPreferenceStore: MemorySensitivePreviewPreferenceStore(),
            sensitiveClipboardPreferenceStore: MemorySensitiveClipboardPreferenceStore()
        )
    }

    private func makeCard(id: String, title: String) -> LocalCardEntry {
        LocalCardEntry(
            id: id,
            projectID: "project-1",
            title: title,
            cardholderName: "ZHANG SAN",
            number: "4111111111111111",
            expiryMonth: "08",
            expiryYear: "2030",
            cvv: "123",
            issuer: "Monica Bank",
            network: "Visa",
            notes: ""
        )
    }

    private func makeAddress(id: String, title: String, linkedCardIDs: [String] = []) -> LocalBillingAddressEntry {
        LocalBillingAddressEntry(
            id: id,
            projectID: "project-1",
            title: title,
            fullName: "ZHANG SAN",
            streetAddress: "1 Heping Road",
            apartment: "12-3",
            city: "Shanghai",
            stateProvince: "Shanghai",
            postalCode: "200000",
            country: "China",
            phone: "+86 21 1234 5678",
            linkedCardIDs: linkedCardIDs
        )
    }

    private func makeAccount(
        id: String,
        title: String,
        linkedCardID: String = "",
        billingAddressID: String = ""
    ) -> LocalPaymentAccountEntry {
        LocalPaymentAccountEntry(
            id: id,
            projectID: "project-1",
            title: title,
            kind: .bankAccount,
            provider: "Monica Bank",
            accountName: "Monica Studio",
            accountHolderName: "ZHANG SAN",
            iban: "DE89370400440532013000",
            swiftBIC: "DEUTDEFF",
            routingNumber: "021000021",
            accountNumber: "1234567890",
            currency: "EUR",
            notes: "",
            linkedCardID: linkedCardID,
            billingAddressID: billingAddressID
        )
    }

    // MARK: - 表单状态

    func testBillingAddressFormStateRoundTripsEveryField() {
        let entry = makeAddress(id: "address-1", title: "家庭地址", linkedCardIDs: ["card-1", "card-2"])
        let form = BillingAddressFormState(entry: entry)

        XCTAssertEqual(form.title, "家庭地址")
        XCTAssertEqual(form.fullName, "ZHANG SAN")
        XCTAssertEqual(form.streetAddress, "1 Heping Road")
        XCTAssertEqual(form.city, "Shanghai")
        XCTAssertEqual(form.postalCode, "200000")
        XCTAssertEqual(form.country, "China")
        XCTAssertEqual(form.linkedCardIDs, ["card-1", "card-2"])
        XCTAssertEqual(form.draft.linkedCardIDs, ["card-1", "card-2"])
        XCTAssertEqual(form.previewAddress, entry.formattedAddress)
    }

    func testPaymentAccountFormStateDropsEmptyReferenceIdentifiers() {
        let form = PaymentAccountFormState()
        XCTAssertEqual(form.draft.linkedCardID, "")
        XCTAssertEqual(form.draft.billingAddressID, "")

        var filled = PaymentAccountFormState()
        filled.linkedCardID = " card-1 "
        filled.billingAddressID = " address-1 "
        XCTAssertEqual(filled.draft.linkedCardID, "card-1")
        XCTAssertEqual(filled.draft.billingAddressID, "address-1")
    }

    func testPaymentAccountFormStateKeepsMaskedAccountNumberOutOfDraftFormat() {
        var form = PaymentAccountFormState()
        form.accountNumber = "1234567890"
        XCTAssertEqual(form.maskedAccountNumber, "••••••7890")
        XCTAssertEqual(form.draft.accountNumber, "1234567890")
    }

    // MARK: - 温和校验只提示不拒绝

    func testBillingAddressWarningsAcceptInternationalPostalFormats() {
        let session = makeSession()
        var form = BillingAddressFormState()
        form.postalCode = "SW1A 1AA"
        XCTAssertTrue(session.billingAddressWarnings(for: form).isEmpty)

        form.postalCode = "K1A-0B1"
        XCTAssertTrue(session.billingAddressWarnings(for: form).isEmpty)

        form.postalCode = "200000"
        XCTAssertTrue(session.billingAddressWarnings(for: form).isEmpty)
    }

    func testBillingAddressWarningsHintOnlyObviousFormatProblems() {
        let session = makeSession()
        var form = BillingAddressFormState()
        form.postalCode = "200000!"
        let warnings = session.billingAddressWarnings(for: form)

        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("邮编"), warnings[0])
    }

    func testPaymentAccountWarningsAcceptAnySingleCountryAccountFormat() {
        let session = makeSession()
        var form = PaymentAccountFormState()
        form.iban = "gb82 west 1234 5698 7654 32"
        form.swiftBIC = "DEUTDEFF500"
        form.routingNumber = "021000021"
        form.currency = "usd"
        XCTAssertTrue(session.paymentAccountWarnings(for: form).isEmpty)
    }

    func testPaymentAccountWarningsNameTheFieldInsteadOfBlockingSaving() {
        let session = makeSession()
        var form = PaymentAccountFormState()
        form.iban = "DE89370400440532013001"
        form.currency = "EURO"
        let warnings = session.paymentAccountWarnings(for: form)

        XCTAssertEqual(warnings.count, 2)
        XCTAssertTrue(warnings.contains { $0.contains("IBAN") }, warnings.joined(separator: " | "))
        XCTAssertTrue(warnings.contains { $0.contains("币种") }, warnings.joined(separator: " | "))
    }

    // MARK: - 引用降级

    func testBillingAddressWithoutLinkedCardsReportsNotLinked() {
        let session = makeSession()
        session.cardEntries = [makeCard(id: "card-1", title: "Visa 尾号 1111")]
        let address = makeAddress(id: "address-1", title: "家庭地址")

        XCTAssertEqual(session.billingLinkedCardsDescription(for: address), "未关联")
    }

    func testBillingAddressReportsDeletedCardsWithoutCrashing() {
        let session = makeSession()
        session.cardEntries = [makeCard(id: "card-1", title: "Visa 尾号 1111")]
        let address = makeAddress(id: "address-1", title: "家庭地址", linkedCardIDs: ["card-1", "card-missing"])

        let description = session.billingLinkedCardsDescription(for: address)
        XCTAssertTrue(description.contains("Visa 尾号 1111"), description)
        XCTAssertTrue(description.contains("1 张银行卡已删除"), description)
    }

    func testPaymentAccountReportsDeletedBillingAddressAndCard() {
        let session = makeSession()
        session.billingAddressEntries = []
        session.cardEntries = []
        let account = makeAccount(
            id: "account-1",
            title: "工资卡",
            linkedCardID: "card-missing",
            billingAddressID: "address-missing"
        )

        XCTAssertEqual(session.paymentBillingAddressDescription(for: account), "关联的账单地址已删除")
        XCTAssertEqual(session.paymentLinkedCardDescription(for: account), "关联的银行卡已删除")
    }

    func testPaymentAccountShowsLinkedTitlesWhenReferencesResolve() {
        let session = makeSession()
        session.cardEntries = [makeCard(id: "card-1", title: "Visa 尾号 1111")]
        session.billingAddressEntries = [makeAddress(id: "address-1", title: "收货地址")]
        let account = makeAccount(
            id: "account-1",
            title: "工资卡",
            linkedCardID: "card-1",
            billingAddressID: "address-1"
        )

        XCTAssertEqual(session.paymentLinkedCardDescription(for: account), "Visa 尾号 1111")
        XCTAssertEqual(session.paymentBillingAddressDescription(for: account), "收货地址")
    }

    func testBillingAddressesCanBeQueriedByCard() {
        let session = makeSession()
        let card = makeCard(id: "card-1", title: "Visa 尾号 1111")
        session.cardEntries = [card]
        session.billingAddressEntries = [
            makeAddress(id: "address-1", title: "家庭地址", linkedCardIDs: ["card-1"]),
            makeAddress(id: "address-2", title: "公司地址", linkedCardIDs: ["card-2"])
        ]

        XCTAssertEqual(session.billingAddresses(linkedTo: card).map(\.id), ["address-1"])
    }

    // MARK: - 详情行

    func testPaymentAccountDetailRowsMaskSensitiveValuesUntilRevealed() {
        let session = makeSession()
        let account = makeAccount(id: "account-1", title: "工资卡")

        let maskedRows = session.paymentAccountDetailRows(for: account)
        let ibanRow = maskedRows.first { $0.id == "iban" }
        XCTAssertNotNil(ibanRow)
        XCTAssertNotEqual(ibanRow?.value, account.iban)

        session.updateSensitivePreviewPreferences(
            SensitivePreviewPreferences(alwaysMask: false, revealableCategories: [.otherSecret])
        )
        session.setSensitivePreviewRevealed(true, entryID: account.id)
        let revealedRows = session.paymentAccountDetailRows(for: account)
        XCTAssertEqual(revealedRows.first { $0.id == "iban" }?.value, account.iban)
    }

    func testBillingAddressDetailSecretsCoverSensitiveContactFields() {
        let session = makeSession()
        let address = makeAddress(id: "address-1", title: "家庭地址")
        let secrets = session.billingAddressDetailSecrets(for: address)

        XCTAssertEqual(Set(secrets.keys), ["fullName", "phone"])
        XCTAssertEqual(secrets["phone"], address.phone)
        let maskedRows = session.billingAddressDetailRows(for: address)
        XCTAssertNotEqual(maskedRows.first { $0.id == "phone" }?.value, address.phone)
    }

    // MARK: - 接线与本地化

    func testWalletRootExposesBillingEntryCreation() throws {
        let homeView = try String(contentsOf: try repositoryFileURL("App/MonicaApp/AndroidParityVaultHomeView.swift"), encoding: .utf8)

        XCTAssertTrue(homeView.contains("return [.card, .identity, .billingAddress, .paymentAccount]"))
        XCTAssertTrue(homeView.contains("AndroidBillingAddressListCard(entry: entry)"))
        XCTAssertTrue(homeView.contains("AndroidPaymentAccountListCard(entry: entry)"))
        XCTAssertTrue(homeView.contains("BillingAddressEditorFields(session: session, isAdding: mode.isAdding)"))
        XCTAssertTrue(homeView.contains("session.billingAddressDetailRows(for: entry)"))
        XCTAssertTrue(homeView.contains("session.paymentAccountDetailSecrets(for: entry)"))
    }

    func testSessionModelWiresBillingEntryLifecycle() throws {
        // slice B 起 AppSessionModel 按域拆成 AppSessionModel+<Domain>.swift 多个 extension 文件，
        // 账单接线的一部分（批量删除/恢复分支）随之搬进了扩展文件。这里只把读取范围扩大到
        // 类文件 + 全部扩展文件，断言本身保持原样，不放宽。
        let appRootURL = try repositoryFileURL("App/MonicaApp/AppRoot")
        let sessionModelFiles = try FileManager.default
            .contentsOfDirectory(at: appRootURL, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("AppSessionModel") && $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(sessionModelFiles.isEmpty)
        let sessionModel = try sessionModelFiles
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        XCTAssertTrue(sessionModel.contains("try createBillingAddressEntry(projectTitle: projectTitle)"))
        XCTAssertTrue(sessionModel.contains("try updateSelectedPaymentAccountEntry()"))
        XCTAssertTrue(sessionModel.contains("entryRepository.deleteBillingAddressEntry(projectID: projectID, entryID: id)"))
        XCTAssertTrue(sessionModel.contains("entryRepository.restorePaymentAccountEntry(projectID: projectID, entryID: id)"))
        XCTAssertTrue(sessionModel.contains("billingAddressEntries = try entryRepository.listBillingAddressEntries(projectID: projectID)"))
        XCTAssertTrue(sessionModel.contains(".billingAddress(LocalBillingAddressEntryDraft("))
        XCTAssertFalse(sessionModel.contains("UserDefaults.standard.set(account.iban"))
    }

    func testBillingStringsAreLocalizedForSimplifiedChineseAndEnglish() throws {
        let data = try Data(contentsOf: try repositoryFileURL("App/MonicaApp/Localizable.xcstrings"))
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])

        for key in ["账单地址", "支付账户", "未关联", "关联的银行卡已删除", "以上只是格式提示，不影响保存。"] {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "缺少本地化 key：\(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            for language in ["en", "zh-Hans"] {
                let unit = try XCTUnwrap(localizations[language] as? [String: Any], "\(key) 缺少 \(language)")
                let stringUnit = try XCTUnwrap(unit["stringUnit"] as? [String: Any])
                XCTAssertEqual(stringUnit["state"] as? String, "translated")
                XCTAssertFalse((stringUnit["value"] as? String ?? "").isEmpty)
            }
        }
    }

    func testAppRootSourcesNeverLogSecretFields() throws {
        let appRootURL = try repositoryFileURL("App/MonicaApp/AppRoot")
        let files = try FileManager.default.contentsOfDirectory(at: appRootURL, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(source.contains("NSLog("), "\(file.lastPathComponent) 不应用 NSLog 输出")
        }
    }
}

@MainActor
private final class MemoryBillingPasteboard: SensitivePasteboardWriting {
    private var content: String?
    private(set) var changeCount = 0

    var string: String? {
        content
    }

    func setString(_ value: String) {
        content = value
        changeCount += 1
    }

    func clear() {
        content = nil
        changeCount += 1
    }
}
