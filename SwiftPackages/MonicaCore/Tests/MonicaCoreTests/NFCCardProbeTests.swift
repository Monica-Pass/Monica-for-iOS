import Foundation
import Testing
import MonicaCore

@Suite("NFC 银行卡诊断策略")
struct NFCCardProbeTests {
    @Test func featureFlagDefaultsToDisabled() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        #expect(NFCCardProbeFeatureFlag.isEnabled(in: defaults) == false)

        NFCCardProbeFeatureFlag.setEnabled(true, in: defaults)
        #expect(NFCCardProbeFeatureFlag.isEnabled(in: defaults))

        NFCCardProbeFeatureFlag.setEnabled(false, in: defaults)
        #expect(NFCCardProbeFeatureFlag.isEnabled(in: defaults) == false)
    }

    @Test func onlyNdefApplicationAIDsAreSelectable() {
        #expect(
            NFCCardProbeAIDPolicy.decision(forSelectIdentifier: "D2760000850100")
                == .ndefApplication
        )
        #expect(
            NFCCardProbeAIDPolicy.decision(forSelectIdentifier: "d2760000850101")
                == .ndefApplication
        )
        #expect(
            NFCCardProbeAIDPolicy.decision(forSelectIdentifier: "0xD2760000850100")
                == .ndefApplication
        )
        #expect(
            NFCCardProbeAIDPolicy.decision(forSelectIdentifier: "D276 0000 8501 00")
                == .ndefApplication
        )
        #expect(NFCCardProbeAIDPolicy.allowedSelectIdentifiers.allSatisfy {
            NFCCardProbeAIDPolicy.decision(forSelectIdentifier: $0).isSelectable
        })
    }

    @Test func paymentApplicationIdentifiersAreRejected() {
        let cases: [(String, String?)] = [
            ("325041592E5359532E4444463031", "EMV PPSE/PSE"),
            ("315041592E5359532E4444463031", "EMV PPSE/PSE"),
            ("A0000000031010", "Visa"),
            ("A0000000041010", "Mastercard"),
            ("A0000000250107", "American Express"),
            ("A0000000651010", "JCB"),
            ("A0000001523010", "Discover"),
            ("A0000002771010", "Interac"),
            ("A0000003330101", "UnionPay"),
            ("A0000009991010", nil)
        ]
        for (identifier, provider) in cases {
            let decision = NFCCardProbeAIDPolicy.decision(forSelectIdentifier: identifier)
            #expect(decision == .paymentRelated(provider: provider), "\(identifier)")
            #expect(decision.isPaymentRelated)
            #expect(decision.isSelectable == false)
        }
    }

    @Test func conservativelyTreatsUnknownIndustryRIDsAsPaymentRelated() {
        // eMRTD 的 AID 也落在 A000000 RID 段；诊断宁可误报也不展示未知 RID。
        #expect(
            NFCCardProbeAIDPolicy.decision(forSelectIdentifier: "A0000002471001")
                == .paymentRelated(provider: nil)
        )
        #expect(
            NFCCardProbeAIDPolicy.decision(forSelectIdentifier: "F0010203040506")
                == .notAllowlisted
        )
    }

    @Test func malformedSelectIdentifiersAreRejected() {
        for value in ["", "D276", "D2760000", "ZZ760000850100", "D27600008501000"] {
            #expect(
                NFCCardProbeAIDPolicy.decision(forSelectIdentifier: value) == .malformed,
                "\(value)"
            )
        }
    }

    @Test func unsafeSelectIdentifiersReportsPaymentOnly() {
        let identifiers = [
            "D2760000850100",
            "A0000000031010",
            "325041592E5359532E4444463031",
            "A0000002471001"
        ]
        #expect(
            NFCCardProbeAIDPolicy.unsafeSelectIdentifiers(in: identifiers)
                == [
                    "A0000000031010",
                    "325041592E5359532E4444463031",
                    "A0000002471001"
                ]
        )
    }

    @Test func iso7816FactsKeepNonPaymentAIDAndHidePaymentAID() {
        let ndefFacts = NFCCardProbeTagFacts.iso7816(
            isAvailable: true,
            initialSelectedAID: "d2760000850100"
        )
        #expect(ndefFacts.family == .iso7816)
        #expect(ndefFacts.iso7816SelectedAID == "D2760000850100")
        #expect(ndefFacts.withheldPaymentAID == false)

        let paymentFacts = NFCCardProbeTagFacts.iso7816(
            isAvailable: true,
            initialSelectedAID: "A0000000031010"
        )
        #expect(paymentFacts.iso7816SelectedAID == nil)
        #expect(paymentFacts.withheldPaymentAID)
        #expect(paymentFacts.summaryLines.contains { $0.contains("A0000000031010") } == false)
        #expect(paymentFacts.summaryLines.contains { $0.contains("支付类 AID") })
    }

    @Test func tagSummaryNeverContainsRawTagIdentifiersOrCardData() {
        let facts = NFCCardProbeTagFacts(
            family: .ndef,
            ndefRecordCount: 1,
            ndefRecordTypeNames: ["URI"]
        )
        let summary = facts.summaryLines.joined(separator: "\n")
        #expect(summary.contains("NDEF"))
        #expect(summary.contains("URI"))
        for forbidden in ["PAN", "CVV", "UID", "APDU"] {
            #expect(summary.contains(forbidden) == false, "\(forbidden)")
        }
    }

    @Test func rawErrorCodesMapToUserFacingFailures() {
        #expect(NFCCardProbeFailure.from(rawErrorCode: 1) == .unsupportedFeature)
        #expect(NFCCardProbeFailure.from(rawErrorCode: 2) == .missingEntitlement)
        #expect(NFCCardProbeFailure.from(rawErrorCode: 6) == .radioDisabled)
        #expect(NFCCardProbeFailure.from(rawErrorCode: 200) == .userCanceled)
        #expect(NFCCardProbeFailure.from(rawErrorCode: 201) == .noTagDetected)
        #expect(NFCCardProbeFailure.from(rawErrorCode: 202) == .sessionTerminatedUnexpectedly)
        #expect(NFCCardProbeFailure.from(rawErrorCode: 203) == .systemBusy)
        #expect(NFCCardProbeFailure.from(rawErrorCode: 204) == .firstNDEFTagRead)
        #expect(NFCCardProbeFailure.from(rawErrorCode: 100) == .tagCommunicationFailure(rawCode: 100))
        #expect(NFCCardProbeFailure.from(rawErrorCode: 403) == .zeroLengthNDEFMessage)
        #expect(NFCCardProbeFailure.from(rawErrorCode: 999) == .unknown(rawCode: 999))
    }

    @Test func failuresExposeStableDiagnosticCodesWithoutRawPayloads() {
        #expect(NFCCardProbeFailure.missingEntitlement.diagnosticCode == "NFC-2")
        #expect(NFCCardProbeFailure.noTagDetected.diagnosticCode == "NFC-201")
        #expect(NFCCardProbeFailure.unknown(rawCode: 999).diagnosticCode == "NFC-999")
        #expect(NFCCardProbeFailure.firstNDEFTagRead.isInformationalCompletion)
        #expect(NFCCardProbeFailure.userCanceled.isUserCancellation)
        #expect(NFCCardProbeFailure.missingEntitlement.title.isEmpty == false)
        #expect(NFCCardProbeFailure.missingEntitlement.message.contains("NFC Tag Reading"))
        #expect(NFCCardProbeFailure.noTagDetected.message.contains("银行卡"))
    }

    @Test func policyStatesThatNoPaymentCardFieldsAreReadable() {
        #expect(NFCCardProbePolicy.readablePaymentCardFields.isEmpty)
        #expect(NFCCardProbePolicy.disclaimer.contains("不读取"))
        #expect(NFCCardProbePolicy.disclaimer.contains("APDU"))
        #expect(NFCCardProbeMode.iso7816NonPayment.requiresTagReaderEntitlement)
        #expect(NFCCardProbeMode.ndef.requiresTagReaderEntitlement == false)
    }

    private let defaultsSuiteName = "MonicaCore.NFCCardProbeTests"

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: defaultsSuiteName) ?? .standard
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }
}
