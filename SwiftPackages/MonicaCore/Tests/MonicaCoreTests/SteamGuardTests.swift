import Foundation
import Testing
import MonicaCore

// 期望值由 Python（hmac + hashlib）独立实现算出，未使用被测实现自证。
// 密钥为 base64 文本 "MDEyMzQ1Njc4OWFiY2RlZmdoaWo="（原字节 "0123456789abcdefghij"）。
private let vectorSecret = "MDEyMzQ1Njc4OWFiY2RlZmdoaWo="
private let secondVectorSecret = "AAECAwQFBgcICQoLDA0ODxAREhM="

private func date(_ timestamp: TimeInterval) -> Date {
    Date(timeIntervalSince1970: timestamp)
}

@Test func steamGuardMatchesIndependentImplementationVectors() throws {
    #expect(try SteamGuardGenerator.code(base64Secret: vectorSecret, at: date(0)).code == "CX2MR")
    #expect(try SteamGuardGenerator.code(base64Secret: vectorSecret, at: date(59)).code == "57G3M")
    #expect(try SteamGuardGenerator.code(base64Secret: vectorSecret, at: date(60)).code == "KRPD7")
    #expect(try SteamGuardGenerator.code(base64Secret: vectorSecret, at: date(1_700_000_000)).code == "C96G3")
    #expect(try SteamGuardGenerator.code(base64Secret: vectorSecret, at: date(1_700_000_010)).code == "JGGKH")
    #expect(try SteamGuardGenerator.code(base64Secret: vectorSecret, at: date(1_700_000_030)).code == "JGGKH")
    #expect(try SteamGuardGenerator.code(base64Secret: vectorSecret, at: date(1_700_000_059)).code == "YWBH2")

    #expect(try SteamGuardGenerator.code(base64Secret: secondVectorSecret, at: date(1_700_000_000)).code == "7MQGM")
    #expect(try SteamGuardGenerator.code(base64Secret: secondVectorSecret, at: date(1_700_000_030)).code == "MQV58")
}

@Test func steamGuardUsesSteamAlphabetAndFiveCharacters() throws {
    #expect(SteamGuardGenerator.alphabet == "23456789BCDFGHJKMNPQRTVWXY")
    #expect(SteamGuardGenerator.codeLength == 5)
    #expect(SteamGuardGenerator.period == 30)

    let alphabet = Set(SteamGuardGenerator.alphabet)
    for timestamp in stride(from: 0, through: 600, by: 7) {
        let code = try SteamGuardGenerator.code(base64Secret: vectorSecret, at: date(TimeInterval(timestamp))).code
        #expect(code.count == 5)
        #expect(code.allSatisfy { alphabet.contains($0) })
        #expect(!code.contains("0") && !code.contains("1") && !code.contains("A") && !code.contains("E"))
    }
}

@Test func steamGuardIsStableWithinWindowAndChangesAcrossBoundary() throws {
    let insideFirst = try SteamGuardGenerator.code(base64Secret: vectorSecret, at: date(1_700_000_000)).code
    #expect(try SteamGuardGenerator.code(base64Secret: vectorSecret, at: date(1_700_000_001)).code == insideFirst)
    #expect(try SteamGuardGenerator.code(base64Secret: vectorSecret, at: date(1_700_000_009)).code == insideFirst)

    let nextWindow = try SteamGuardGenerator.code(base64Secret: vectorSecret, at: date(1_700_000_010)).code
    #expect(nextWindow != insideFirst)
    #expect(try SteamGuardGenerator.code(base64Secret: vectorSecret, at: date(1_700_000_029)).code == nextWindow)
}

@Test func steamGuardRemainingSecondsHandlesWindowBoundaries() {
    #expect(SteamGuardGenerator.remainingSeconds(at: 0) == 30)
    #expect(SteamGuardGenerator.remainingSeconds(at: 1) == 29)
    #expect(SteamGuardGenerator.remainingSeconds(at: 29) == 1)
    #expect(SteamGuardGenerator.remainingSeconds(at: 30) == 30)
    #expect(SteamGuardGenerator.remainingSeconds(at: 31) == 29)
    #expect(SteamGuardGenerator.remainingSeconds(at: 59) == 1)
    #expect(SteamGuardGenerator.remainingSeconds(at: 60) == 30)
}

@Test func steamGuardAcceptsWhitespaceAndMissingPadding() throws {
    let spaced = "MDEyMzQ1\nNjc4OWFi\tY2RlZmdo\naWo="
    #expect(SteamGuardSecret.normalizedBase64(spaced) == vectorSecret)
    #expect(try SteamGuardGenerator.code(base64Secret: spaced, at: date(1_700_000_000)).code == "C96G3")

    let unpadded = "MDEyMzQ1Njc4OWFiY2RlZmdoaWo"
    #expect(SteamGuardSecret.normalizedBase64(unpadded) == vectorSecret)
    #expect(try SteamGuardGenerator.code(base64Secret: unpadded, at: date(1_700_000_000)).code == "C96G3")
}

@Test func steamGuardRejectsInvalidBase64Secrets() {
    #expect(throws: SteamGuardError.emptySecret) {
        _ = try SteamGuardSecret(base64: "   \n ")
    }
    #expect(throws: SteamGuardError.invalidBase64Secret) {
        _ = try SteamGuardSecret(base64: "not base64 at all!!")
    }
    #expect(throws: SteamGuardError.invalidBase64Secret) {
        // 1 字节的合法 base64，短于 Steam 密钥下限。
        _ = try SteamGuardSecret(base64: "YQ==")
    }
    #expect(!SteamGuardSecret.isValidBase64Secret("***"))
    #expect(SteamGuardSecret.isValidBase64Secret(vectorSecret))
}

@Test func steamGuardSecretDescriptionDoesNotLeakSecret() throws {
    let secret = try SteamGuardSecret(base64: vectorSecret)
    let text = String(describing: secret)
    #expect(!text.contains(vectorSecret))
    #expect(!text.contains("30313233343536"))
    #expect(text.contains("redacted"))

    let draftSecret = try SteamGuardImportParser.parse(
        text: #"{"shared_secret":"MDEyMzQ1Njc4OWFiY2RlZmdoaWo=","account_name":"alice"}"#
    )
    #expect(!String(describing: draftSecret).contains(vectorSecret))
    #expect(draftSecret.redactedSummary == "alice")
}

@Test func steamGuardImportParsesMaFileAndIgnoresSensitiveFields() throws {
    let json = """
    {
      "shared_secret": "MDEyMzQ1Njc4OWFiY2RlZmdoaWo=",
      "account_name": "alice",
      "steamid": 76561198000000000,
      "identity_secret": "c2VjcmV0",
      "revocation_code": "R12345",
      "token_gid": "abc"
    }
    """
    let draft = try SteamGuardImportParser.parse(Data(json.utf8))
    #expect(draft.accountName == "alice")
    #expect(draft.steamID == "76561198000000000")
    #expect(draft.sharedSecretBase64 == vectorSecret)
    #expect(draft.suggestedTitle == "Steam · alice")
    #expect(draft.redactedSummary == "alice")

    // 仅 shared_secret 也合法。
    let minimal = try SteamGuardImportParser.parse(Data(#"{"shared_secret":"MDEyMzQ1Njc4OWFiY2RlZmdoaWo="}"#.utf8))
    #expect(minimal.accountName.isEmpty)
    #expect(minimal.suggestedTitle == "Steam")
}

@Test func steamGuardImportRejectsMalformedPayloads() {
    #expect(throws: SteamGuardError.invalidImportPayload) {
        _ = try SteamGuardImportParser.parse(Data("not json".utf8))
    }
    #expect(throws: SteamGuardError.missingSharedSecret) {
        _ = try SteamGuardImportParser.parse(Data(#"{"account_name":"alice"}"#.utf8))
    }
    #expect(throws: SteamGuardError.invalidBase64Secret) {
        _ = try SteamGuardImportParser.parse(Data(#"{"shared_secret":"%%%"}"#.utf8))
    }
    #expect(throws: SteamGuardError.invalidSteamGuardURI) {
        _ = try SteamGuardImportParser.parseURI("otpauth://totp/x?secret=AAAA")
    }
}

@Test func steamGuardImportParsesSteamGuardURI() throws {
    let uri = "steamguard://MDEyMzQ1Njc4OWFiY2RlZmdoaWo=?account=alice&steamid=76561198000000000"
    let draft = try SteamGuardImportParser.parseURI(uri)
    #expect(draft.accountName == "alice")
    #expect(draft.steamID == "76561198000000000")
    #expect(draft.sharedSecretBase64 == vectorSecret)

    let bitwardenStyle = try SteamGuardImportParser.parseURI("steam://MDEyMzQ1Njc4OWFiY2RlZmdoaWo=")
    #expect(bitwardenStyle.sharedSecretBase64 == vectorSecret)
    #expect(bitwardenStyle.accountName.isEmpty)
    #expect(bitwardenStyle.issuer == "Steam")
}
