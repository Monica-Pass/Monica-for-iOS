import Foundation
import Testing
import MonicaCore

@Test func monicaCoreInfoDocumentsMdbxFirstIOS17Baseline() {
    let info = MonicaCoreInfo()

    #expect(info.minimumIOSVersion == "17.0")
    #expect(info.storageStrategy == "MDBX 优先")
}

@Test func totpGeneratorMatchesRFC6238Vectors() throws {
    let sha1Secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    let sha256Secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZA===="
    let sha512Secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNA="

    #expect(
        try TotpGenerator.generate(
            secret: sha1Secret,
            algorithm: .sha1,
            digits: 8,
            period: 30,
            timestamp: 59
        ) == "94287082"
    )
    #expect(
        try TotpGenerator.generate(
            secret: sha256Secret,
            algorithm: .sha256,
            digits: 8,
            period: 30,
            timestamp: 59
        ) == "46119246"
    )
    #expect(
        try TotpGenerator.generate(
            secret: sha512Secret,
            algorithm: .sha512,
            digits: 8,
            period: 30,
            timestamp: 59
        ) == "90693936"
    )
    #expect(
        try TotpGenerator.generate(
            secret: sha1Secret,
            algorithm: .sha1,
            digits: 8,
            period: 30,
            timestamp: 1_111_111_109
        ) == "07081804"
    )
}

@Test func totpGeneratorNormalizesBase32SecretsAndRejectsInvalidInput() throws {
    #expect(
        try TotpGenerator.generate(
            secret: "jbsw y3dp ehpk 3pxp",
            algorithm: .sha1,
            digits: 6,
            period: 30,
            timestamp: 0
        ) == "282760"
    )
    #expect(throws: TotpError.invalidSecret) {
        try TotpGenerator.generate(
            secret: "not-valid-*",
            algorithm: .sha1,
            digits: 6,
            period: 30,
            timestamp: 0
        )
    }
    #expect(throws: TotpError.invalidDigits) {
        try TotpGenerator.generate(
            secret: "JBSWY3DPEHPK3PXP",
            algorithm: .sha1,
            digits: 4,
            period: 30,
            timestamp: 0
        )
    }
    #expect(throws: TotpError.invalidPeriod) {
        try TotpGenerator.generate(
            secret: "JBSWY3DPEHPK3PXP",
            algorithm: .sha1,
            digits: 6,
            period: 0,
            timestamp: 0
        )
    }
}

@Test func passkeyRegistrationBuildsCredentialMetadataAndStoresPrivateKey() throws {
    let store = MemoryPasskeyPrivateKeyStore()
    let manager = MonicaPasskeyCredentialManager(
        privateKeyStore: store,
        randomBytes: { count in Array(UInt8(1)...UInt8(count)) }
    )

    let registration = try manager.createRegistration(
        relyingPartyID: "github.com",
        username: "joyin@example.com",
        userHandle: Data("github-user-handle".utf8),
        clientDataHash: Data(repeating: 0xCA, count: 32)
    )

    #expect(registration.credentialID.count == 32)
    #expect(registration.publicKeyCOSE.count > 70)
    #expect(registration.attestationObject.count > 120)
    #expect(registration.privateKeyReference.hasPrefix("monica-passkey://"))
    #expect(try store.loadPrivateKey(credentialID: registration.credentialID) != nil)
    #expect(registration.vaultMetadataDraft(title: "GitHub").credentialID == registration.credentialID.base64EncodedString())
    #expect(registration.vaultMetadataDraft(title: "GitHub").publicKeyCOSE == registration.publicKeyCOSE.base64EncodedString())
    #expect(!String(decoding: registration.attestationObject, as: UTF8.self).contains("github-user-handle"))
}

@Test func passkeyRelyingPartyIDsAreNormalizedBeforeUse() throws {
    let store = MemoryPasskeyPrivateKeyStore()
    let manager = MonicaPasskeyCredentialManager(
        privateKeyStore: store,
        randomBytes: { count in Array(repeating: 0x3C, count: count) }
    )

    let registration = try manager.createRegistration(
        relyingPartyID: "  Bücher.Example.  ",
        username: "joyin@example.com",
        userHandle: Data("unicode-user-handle".utf8),
        clientDataHash: Data(repeating: 0xCA, count: 32)
    )

    #expect(registration.relyingPartyID == "xn--bcher-kva.example")

    let assertion = try manager.createAssertion(
        relyingPartyID: "BÜCHER.EXAMPLE.",
        credentialID: registration.credentialID,
        userHandle: Data("unicode-user-handle".utf8),
        clientDataHash: Data(repeating: 0xCB, count: 32)
    )

    #expect(assertion.relyingPartyID == "xn--bcher-kva.example")
    #expect(
        try manager.verifyAssertion(
            assertion,
            publicKeyCOSE: registration.publicKeyCOSE
        )
    )
}

@Test func passkeyRelyingPartyIDsRejectNonHostInput() throws {
    let manager = MonicaPasskeyCredentialManager(
        privateKeyStore: MemoryPasskeyPrivateKeyStore(),
        randomBytes: { count in Array(repeating: 0x4D, count: count) }
    )
    let userHandle = Data("github-user-handle".utf8)
    let clientDataHash = Data(repeating: 0xCA, count: 32)

    for invalidRelyingPartyID in [
        "",
        "https://example.com",
        "bad_host.example",
        "-example.com",
        "example..com",
        "example.com/path"
    ] {
        #expect(throws: PasskeyCredentialError.invalidRelyingPartyID) {
            try manager.createRegistration(
                relyingPartyID: invalidRelyingPartyID,
                username: "joyin@example.com",
                userHandle: userHandle,
                clientDataHash: clientDataHash
            )
        }
    }
}

@Test func passkeyAssertionSignsAuthenticatorDataAndClientDataHash() throws {
    let store = MemoryPasskeyPrivateKeyStore()
    let manager = MonicaPasskeyCredentialManager(
        privateKeyStore: store,
        randomBytes: { count in Array(repeating: 0x2A, count: count) }
    )
    let registration = try manager.createRegistration(
        relyingPartyID: "github.com",
        username: "joyin@example.com",
        userHandle: Data("github-user-handle".utf8),
        clientDataHash: Data(repeating: 0xCA, count: 32)
    )

    let assertion = try manager.createAssertion(
        relyingPartyID: "github.com",
        credentialID: registration.credentialID,
        userHandle: Data("github-user-handle".utf8),
        clientDataHash: Data(repeating: 0xCB, count: 32)
    )

    #expect(assertion.credentialID == registration.credentialID)
    #expect(assertion.userHandle == Data("github-user-handle".utf8))
    #expect(assertion.authenticatorData.count == 37)
    #expect(assertion.signature.count > 60)
    #expect(
        try manager.verifyAssertion(
            assertion,
            publicKeyCOSE: registration.publicKeyCOSE
        )
    )
}

@Test func totpURIParserImportsStandardOtpauthTotpURI() throws {
    let draft = try TotpURIParser.parse(
        "otpauth://totp/GitHub:alice%40example.com?secret=JBSWY3DPEHPK3PXP&issuer=GitHub&period=60&digits=8&algorithm=SHA256"
    )

    #expect(draft.title == "GitHub")
    #expect(draft.secret == "JBSWY3DPEHPK3PXP")
    #expect(draft.issuer == "GitHub")
    #expect(draft.accountName == "alice@example.com")
    #expect(draft.period == 60)
    #expect(draft.digits == 8)
    #expect(draft.algorithm == .sha256)
}

@Test func totpURIParserUsesLabelFallbacksAndRejectsInvalidURIs() throws {
    let draft = try TotpURIParser.parse(
        "otpauth://totp/alice@example.com?secret=jbsw%20y3dp%20ehpk%203pxp"
    )

    #expect(draft.title == "alice@example.com")
    #expect(draft.secret == "JBSW Y3DP EHPK 3PXP")
    #expect(draft.issuer == "")
    #expect(draft.accountName == "alice@example.com")
    #expect(draft.period == 30)
    #expect(draft.digits == 6)
    #expect(draft.algorithm == .sha1)

    #expect(throws: TotpError.invalidURI) {
        try TotpURIParser.parse("https://example.com")
    }
    #expect(throws: TotpError.invalidSecret) {
        try TotpURIParser.parse("otpauth://totp/GitHub:alice?issuer=GitHub")
    }
    #expect(throws: TotpError.invalidDigits) {
        try TotpURIParser.parse(
            "otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP&digits=4"
        )
    }
    #expect(throws: TotpError.invalidAlgorithm) {
        try TotpURIParser.parse(
            "otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP&algorithm=MD5"
        )
    }
}

@Test func passwordGeneratorCreatesPolicyCompliantPassword() throws {
    var byteCursor = 0
    let password = try PasswordGenerator.generate(
        policy: PasswordGeneratorPolicy(length: 20),
        randomBytes: { count in
            let bytes = (0..<count).map { offset in
                UInt8((byteCursor + offset) % 251)
            }
            byteCursor += count
            return bytes
        }
    )

    #expect(password.count == 20)
    #expect(password.rangeOfCharacter(from: .uppercaseLetters) != nil)
    #expect(password.rangeOfCharacter(from: .lowercaseLetters) != nil)
    #expect(password.rangeOfCharacter(from: .decimalDigits) != nil)
    #expect(password.rangeOfCharacter(from: PasswordGeneratorPolicy.defaultSymbolCharacterSet) != nil)
    #expect(password.rangeOfCharacter(from: .whitespacesAndNewlines) == nil)
}

@Test func passwordGeneratorRejectsInvalidPolicies() throws {
    #expect(throws: PasswordGeneratorError.invalidLength) {
        try PasswordGenerator.generate(
            policy: PasswordGeneratorPolicy(length: 3),
            randomBytes: { count in Array(repeating: 0, count: count) }
        )
    }

    #expect(throws: PasswordGeneratorError.emptyCharacterSet) {
        try PasswordGenerator.generate(
            policy: PasswordGeneratorPolicy(
                length: 20,
                includeUppercase: false,
                includeLowercase: false,
                includeDigits: false,
                includeSymbols: false
            ),
            randomBytes: { count in Array(repeating: 0, count: count) }
        )
    }
}

@Test func secretGeneratorCreatesPinPassphraseAndApiTokenModes() throws {
    var byteCursor = 0
    let deterministicBytes: (Int) throws -> [UInt8] = { count in
        let bytes = (0..<count).map { offset in
            UInt8((byteCursor + offset) % 251)
        }
        byteCursor += count
        return bytes
    }

    let pin = try SecretGenerator.generate(
        policy: .pin(length: 6),
        randomBytes: deterministicBytes
    )
    #expect(pin.count == 6)
    #expect(pin.rangeOfCharacter(from: CharacterSet.decimalDigits.inverted) == nil)

    let passphrase = try SecretGenerator.generate(
        policy: .passphrase(
            wordCount: 4,
            separator: "-",
            wordList: ["amber", "brisk", "cedar", "delta"]
        ),
        randomBytes: deterministicBytes
    )
    #expect(passphrase.split(separator: "-").count == 4)
    #expect(passphrase.allSatisfy { $0.isLowercase || $0 == "-" })

    let apiToken = try SecretGenerator.generate(
        policy: .apiToken(prefix: "monica", byteCount: 24),
        randomBytes: deterministicBytes
    )
    #expect(apiToken.hasPrefix("monica_"))
    #expect(!apiToken.contains("+"))
    #expect(!apiToken.contains("/"))
    #expect(!apiToken.contains("="))
}

@Test func secretGeneratorRejectsInvalidModePolicies() throws {
    #expect(throws: PasswordGeneratorError.invalidLength) {
        try SecretGenerator.generate(
            policy: .pin(length: 3),
            randomBytes: { count in Array(repeating: 0, count: count) }
        )
    }

    #expect(throws: PasswordGeneratorError.invalidLength) {
        try SecretGenerator.generate(
            policy: .passphrase(wordCount: 2, separator: "-", wordList: ["amber", "brisk"]),
            randomBytes: { count in Array(repeating: 0, count: count) }
        )
    }

    #expect(throws: PasswordGeneratorError.emptyCharacterSet) {
        try SecretGenerator.generate(
            policy: .passphrase(wordCount: 4, separator: "-", wordList: []),
            randomBytes: { count in Array(repeating: 0, count: count) }
        )
    }

    #expect(throws: PasswordGeneratorError.invalidLength) {
        try SecretGenerator.generate(
            policy: .apiToken(prefix: "monica", byteCount: 7),
            randomBytes: { count in Array(repeating: 0, count: count) }
        )
    }
}
