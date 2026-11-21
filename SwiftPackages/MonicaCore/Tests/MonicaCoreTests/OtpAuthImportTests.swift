import Foundation
import Testing
import MonicaCore

private let sampleSecret = "JBSWY3DPEHPK3PXP"

@Test func otpAuthParserParsesStandardTOTPURI() throws {
    let draft = try TotpURIParser.parse(
        "otpauth://totp/GitHub:alice%40example.com?secret=\(sampleSecret)&issuer=GitHub&algorithm=SHA256&digits=8&period=60"
    )

    #expect(draft.title == "GitHub")
    #expect(draft.issuer == "GitHub")
    #expect(draft.accountName == "alice@example.com")
    #expect(draft.secret == sampleSecret)
    #expect(draft.otpType == .totp)
    #expect(draft.algorithm == .sha256)
    #expect(draft.digits == 8)
    #expect(draft.period == 60)
    #expect(draft.counter == 0)
}

@Test func otpAuthParserNormalizesBase32CaseWhitespaceAndPadding() throws {
    let draft = try TotpURIParser.parse(
        "otpauth://totp/GitHub:alice?secret=jbsw%20y3dp%20ehpk%203pxp%3D%3D%3D%3D"
    )

    #expect(draft.secret == sampleSecret)
}

@Test func otpAuthParserRejectsMissingSecretAndBadBase32() {
    #expect(throws: TotpError.invalidSecret) {
        try TotpURIParser.parse("otpauth://totp/GitHub:alice?issuer=GitHub")
    }
    #expect(throws: TotpError.invalidSecret) {
        try TotpURIParser.parse("otpauth://totp/GitHub:alice?secret=ABC*123")
    }
    #expect(throws: TotpError.invalidSecret) {
        try TotpURIParser.parse("otpauth://totp/GitHub:alice?secret=%%%%")
    }
}

@Test func otpAuthParserOnlyAcceptsSixOrEightDigits() throws {
    for digits in [6, 8] {
        let draft = try TotpURIParser.parse(
            "otpauth://totp/GitHub:alice?secret=\(sampleSecret)&digits=\(digits)"
        )
        #expect(draft.digits == digits)
    }
    for digits in [4, 5, 7, 9, 10] {
        #expect(throws: TotpError.invalidDigits) {
            try TotpURIParser.parse(
                "otpauth://totp/GitHub:alice?secret=\(sampleSecret)&digits=\(digits)"
            )
        }
    }
}

@Test func otpAuthParserRequiresCounterForHOTP() throws {
    let draft = try TotpURIParser.parse(
        "otpauth://hotp/GitHub:alice?secret=\(sampleSecret)&counter=42"
    )
    #expect(draft.otpType == .hotp)
    #expect(draft.counter == 42)

    #expect(throws: TotpError.missingCounter) {
        try TotpURIParser.parse("otpauth://hotp/GitHub:alice?secret=\(sampleSecret)")
    }
    #expect(throws: TotpError.invalidCounter) {
        try TotpURIParser.parse("otpauth://hotp/GitHub:alice?secret=\(sampleSecret)&counter=abc")
    }
    #expect(throws: TotpError.invalidCounter) {
        try TotpURIParser.parse("otpauth://hotp/GitHub:alice?secret=\(sampleSecret)&counter=-1")
    }

    let totpIgnoresCounter = try TotpURIParser.parse(
        "otpauth://totp/GitHub:alice?secret=\(sampleSecret)&counter=7"
    )
    #expect(totpIgnoresCounter.counter == 0)
}

@Test func otpAuthParserPrefersIssuerParameterOverLabelPrefix() throws {
    let draft = try TotpURIParser.parse(
        "otpauth://totp/Wrong:alice?secret=\(sampleSecret)&issuer=Right%20Issuer"
    )

    #expect(draft.issuer == "Right Issuer")
    #expect(draft.accountName == "alice")
    #expect(draft.title == "Right Issuer")
}

@Test func otpAuthParserSupportsSHA256AndSHA512() throws {
    let sha256 = try TotpURIParser.parse(
        "otpauth://totp/GitHub:alice?secret=\(sampleSecret)&algorithm=SHA256"
    )
    #expect(sha256.algorithm == .sha256)

    let sha512 = try TotpURIParser.parse(
        "otpauth://totp/GitHub:alice?secret=\(sampleSecret)&algorithm=sha512"
    )
    #expect(sha512.algorithm == .sha512)

    #expect(throws: TotpError.invalidAlgorithm) {
        try TotpURIParser.parse(
            "otpauth://totp/GitHub:alice?secret=\(sampleSecret)&algorithm=MD5"
        )
    }
}

@Test func otpAuthParserRejectsInvalidPeriodAndURI() {
    #expect(throws: TotpError.invalidPeriod) {
        try TotpURIParser.parse("otpauth://totp/GitHub:alice?secret=\(sampleSecret)&period=0")
    }
    #expect(throws: TotpError.invalidPeriod) {
        try TotpURIParser.parse("otpauth://totp/GitHub:alice?secret=\(sampleSecret)&period=abc")
    }
    #expect(throws: TotpError.invalidURI) {
        try TotpURIParser.parse("https://example.com")
    }
    #expect(throws: TotpError.invalidURI) {
        try TotpURIParser.parse("otpauth://steam/GitHub:alice?secret=\(sampleSecret)")
    }
    #expect(throws: TotpError.invalidURI) {
        try TotpURIParser.parse("otpauth://totp/?secret=\(sampleSecret)")
    }
    #expect(throws: TotpError.invalidURI) {
        try TotpURIParser.parse("otpauth://totp/GitHub:?secret=\(sampleSecret)")
    }
}

@Test func otpAuthParserRejectsOverlongURI() {
    let longLabel = String(repeating: "a", count: TotpURIParser.maximumURILength)
    #expect(throws: TotpError.uriTooLong) {
        try TotpURIParser.parse("otpauth://totp/\(longLabel)?secret=\(sampleSecret)")
    }
}

@Test func otpAuthParserHandlesDuplicateQueryParametersWithoutCrashing() throws {
    let draft = try TotpURIParser.parse(
        "otpauth://totp/GitHub:alice?secret=\(sampleSecret)&secret=GEZDGNBVGY3TQOJQ&digits=6&digits=8"
    )
    #expect(draft.secret == sampleSecret)
    #expect(draft.digits == 6)
}

@Test func otpAuthBatchParserReportsBadLinesAndKeepsValidOnes() {
    let text = """
    otpauth://totp/GitHub:alice?secret=\(sampleSecret)&issuer=GitHub

    otpauth://totp/GitLab:bob?secret=GEZDGNBVGY3TQOJQ
    not a valid link
    otpauth://hotp/AWS:carol?secret=GEZDGNBVGY3TQOJQ
    """

    let result = OtpAuthBatchParser.parse(text)

    #expect(result.entries.count == 2)
    #expect(result.entries.map(\.lineNumber) == [1, 3])
    #expect(result.failures.count == 2)
    #expect(result.failures.map(\.lineNumber) == [4, 5])
    #expect(result.failures.first?.error == .invalidURI)
    #expect(result.failures.last?.error == .missingCounter)
}

@Test func otpAuthBatchParserHandlesCRLFAndBlankInput() {
    let text = "otpauth://totp/A:a?secret=\(sampleSecret)\r\n\r\notpauth://totp/B:b?secret=GEZDGNBVGY3TQOJQ\r\n"
    let result = OtpAuthBatchParser.parse(text)

    #expect(result.entries.count == 2)
    #expect(result.entries.map(\.lineNumber) == [1, 3])
    #expect(result.failures.isEmpty)

    let empty = OtpAuthBatchParser.parse("   \n\n  ")
    #expect(empty.entries.isEmpty)
    #expect(empty.failures.isEmpty)
}

@Test func otpAuthDuplicateKeyIgnoresIssuerAccountCaseAndSecretFormatting() {
    let first = try! TotpURIParser.parse(
        "otpauth://totp/GitHub:Alice?secret=jbsw%20y3dp%20ehpk%203pxp&issuer=GitHub"
    )
    let second = try! TotpURIParser.parse(
        "otpauth://totp/github:alice?secret=JBSWY3DPEHPK3PXP&issuer=github"
    )

    #expect(first.duplicateKey == second.duplicateKey)
    #expect(first.duplicateKey != OtpAuthDuplicateKey(issuer: "GitHub", accountName: "bob", secret: sampleSecret))
}

@Test func otpAuthBatchParserComputesLineNumbersForDuplicateDetection() {
    let text = """
    otpauth://totp/GitHub:alice?secret=\(sampleSecret)
    otpauth://totp/GitHub:alice?secret=\(sampleSecret)
    otpauth://totp/GitHub:alice?secret=GEZDGNBVGY3TQOJQ
    """

    let result = OtpAuthBatchParser.parse(text)
    #expect(result.entries.count == 3)
    let keys = result.entries.map(\.draft.duplicateKey)
    #expect(keys[0] == keys[1])
    #expect(keys[0] != keys[2])
}
