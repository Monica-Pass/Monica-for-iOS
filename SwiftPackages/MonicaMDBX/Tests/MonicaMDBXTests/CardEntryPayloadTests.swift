import Foundation
import Testing
@testable import MonicaMDBX

/// issue #17：银行卡扩展字段（IBAN/SWIFT/账单地址/卡面样式）必须向后兼容——
/// 旧 payload 缺少这些键时按空串解码，新 payload 穿过真实 MDBX 后保持完整。
@Suite(.serialized)
struct CardEntryPayloadTests {
    @Test func legacyCardPayloadWithoutExtendedFieldsDecodesEmptyValues() throws {
        let payload = """
        {"kind":"card","cardholderName":"Alice Example","number":"4111111111111111","expiryMonth":"12","expiryYear":"2030","cvv":"123","issuer":"Monica Bank","network":"Visa","notes":"legacy card","favorite":false}
        """

        let entry = try MonicaMDBXCardEntry.decodePayloadForTesting(payload)

        #expect(entry.cardholderName == "Alice Example")
        #expect(entry.number == "4111111111111111")
        #expect(entry.issuer == "Monica Bank")
        #expect(entry.network == "Visa")
        #expect(entry.iban.isEmpty)
        #expect(entry.swiftCode.isEmpty)
        #expect(entry.billingAddress.isEmpty)
        #expect(entry.cardArtwork.isEmpty)
        #expect(entry.notes == "legacy card")
        #expect(entry.favorite == false)
    }

    @Test func extendedCardFieldsRoundTripThroughRealVault() throws {
        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-mdbx-card-extended-\(UUID().uuidString).mdbx", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let vault = try MonicaMDBXRuntime.createVault(
            at: vaultURL,
            password: "card extended password 12345!",
            deviceID: "swiftpm-card-extended"
        )
        let project = try vault.createProject(title: "Cards")

        let created = try vault.createCardEntry(
            projectID: project.id,
            title: "Travel Card",
            cardholderName: "Alice Example",
            number: "4111111111111111",
            expiryMonth: "12",
            expiryYear: "2030",
            cvv: "123",
            issuer: "Monica Bank",
            network: "Visa",
            iban: "DE89370400440532013000",
            swiftCode: "COBADEFFXXX",
            billingAddress: "Friedrichstraße 1, Berlin",
            cardArtwork: "midnight",
            notes: "travel"
        )
        #expect(created.iban == "DE89370400440532013000")
        #expect(created.swiftCode == "COBADEFFXXX")
        #expect(created.billingAddress == "Friedrichstraße 1, Berlin")
        #expect(created.cardArtwork == "midnight")

        let reopened = try MonicaMDBXRuntime.openVault(
            at: vaultURL,
            password: "card extended password 12345!",
            deviceID: "swiftpm-card-extended"
        )
        let persisted = try reopened.listCardEntries(projectID: project.id)
        guard let entry = persisted.first(where: { $0.id == created.id }) else {
            Issue.record("Expected persisted card entry")
            return
        }
        #expect(entry.iban == "DE89370400440532013000")
        #expect(entry.swiftCode == "COBADEFFXXX")
        #expect(entry.billingAddress == "Friedrichstraße 1, Berlin")
        #expect(entry.cardArtwork == "midnight")
        #expect(entry.number == "4111111111111111")
    }
}
