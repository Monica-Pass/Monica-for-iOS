import Foundation
import Testing
import MonicaCore

private let rfc4226Secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
private let rfc6238SHA1Secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
private let rfc6238SHA256Secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZA"
private let rfc6238SHA512Secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNA"

@Test func hotpGeneratorMatchesRFC4226AppendixD() throws {
    let vectors: [(UInt64, String)] = [
        (0, "755224"),
        (1, "287082"),
        (2, "359152"),
        (3, "969429"),
        (4, "338314"),
        (5, "254676"),
        (6, "287922"),
        (7, "162583"),
        (8, "399871"),
        (9, "520489"),
    ]

    for (counter, expected) in vectors {
        let code = try HotpGenerator.generate(
            secret: rfc4226Secret,
            algorithm: .sha1,
            digits: 6,
            counter: counter
        )
        #expect(code == expected, "RFC 4226 counter \(counter)")
    }
}

@Test func totpGeneratorMatchesRFC6238VectorsForEveryAlgorithm() throws {
    let vectors: [(TotpAlgorithm, String, [(TimeInterval, String)])] = [
        (
            .sha1,
            rfc6238SHA1Secret,
            [
                (59, "94287082"),
                (1_111_111_109, "07081804"),
                (1_111_111_111, "14050471"),
                (1_234_567_890, "89005924"),
                (2_000_000_000, "69279037"),
                (20_000_000_000, "65353130"),
            ]
        ),
        (
            .sha256,
            rfc6238SHA256Secret,
            [
                (59, "46119246"),
                (1_111_111_109, "68084774"),
                (1_111_111_111, "67062674"),
                (1_234_567_890, "91819424"),
                (2_000_000_000, "90698825"),
                (20_000_000_000, "77737706"),
            ]
        ),
        (
            .sha512,
            rfc6238SHA512Secret,
            [
                (59, "90693936"),
                (1_111_111_109, "25091201"),
                (1_111_111_111, "99943326"),
                (1_234_567_890, "93441116"),
                (2_000_000_000, "38618901"),
                (20_000_000_000, "47863826"),
            ]
        ),
    ]

    for (algorithm, secret, entries) in vectors {
        for (timestamp, expected) in entries {
            let code = try TotpGenerator.generate(
                secret: secret,
                algorithm: algorithm,
                digits: 8,
                period: 30,
                timestamp: timestamp
            )
            #expect(code == expected, "RFC 6238 \(algorithm.rawValue) at \(timestamp)")
        }
    }
}

@Test func hotpGeneratorPreservesLeadingZeros() throws {
    #expect(
        try HotpGenerator.generate(secret: rfc4226Secret, algorithm: .sha1, digits: 6, counter: 30) == "026920"
    )
    #expect(
        try HotpGenerator.generate(secret: rfc4226Secret, algorithm: .sha1, digits: 6, counter: 36) == "003784"
    )
    #expect(
        try HotpGenerator.generate(secret: rfc4226Secret, algorithm: .sha1, digits: 6, counter: 44) == "000152"
    )
    #expect(
        try HotpGenerator.generate(secret: rfc4226Secret, algorithm: .sha1, digits: 8, counter: 21) == "05191635"
    )
}

@Test func hotpGeneratorRejectsInvalidInput() {
    #expect(throws: TotpError.invalidSecret) {
        try HotpGenerator.generate(secret: "not-valid-*", algorithm: .sha1, digits: 6, counter: 0)
    }
    #expect(throws: TotpError.invalidDigits) {
        try HotpGenerator.generate(secret: rfc4226Secret, algorithm: .sha1, digits: 9, counter: 0)
    }
}

@Test func totpURIParserImportsHotpURIWithCounter() throws {
    let draft = try TotpURIParser.parse(
        "otpauth://hotp/GitHub:alice%40example.com?secret=JBSWY3DPEHPK3PXP&issuer=GitHub&period=60&digits=8&algorithm=SHA256&counter=42"
    )

    #expect(draft.otpType == .hotp)
    #expect(draft.counter == 42)
    #expect(draft.title == "GitHub")
    #expect(draft.period == 60)
    #expect(draft.digits == 8)
    #expect(draft.algorithm == .sha256)

    let defaultedCounter = try TotpURIParser.parse(
        "otpauth://hotp/alice?secret=JBSWY3DPEHPK3PXP"
    )
    #expect(defaultedCounter.otpType == .hotp)
    #expect(defaultedCounter.counter == 0)

    let totpIgnoresCounter = try TotpURIParser.parse(
        "otpauth://totp/alice?secret=JBSWY3DPEHPK3PXP&counter=7"
    )
    #expect(totpIgnoresCounter.otpType == .totp)
    #expect(totpIgnoresCounter.counter == 0)

    #expect(throws: TotpError.invalidURI) {
        try TotpURIParser.parse("otpauth://hotp/alice?secret=JBSWY3DPEHPK3PXP&counter=abc")
    }
}

@Test func otpAuthURIExporterRoundTripsTotpURI() throws {
    let uri = try OtpAuthURIExporter.uri(
        secret: "jbsw y3dp ehpk 3pxp",
        issuer: "Git Hub",
        accountName: "alice@example.com",
        period: 60,
        digits: 8,
        algorithm: .sha256
    )

    #expect(uri.hasPrefix("otpauth://totp/"))
    #expect(uri.contains("secret=JBSWY3DPEHPK3PXP"))
    #expect(uri.contains("issuer=Git%20Hub"))
    #expect(uri.contains("period=60"))
    #expect(uri.contains("digits=8"))
    #expect(uri.contains("algorithm=SHA256"))
    #expect(!uri.contains("counter="))

    let draft = try TotpURIParser.parse(uri)
    #expect(draft.otpType == .totp)
    #expect(draft.secret == "JBSWY3DPEHPK3PXP")
    #expect(draft.issuer == "Git Hub")
    #expect(draft.accountName == "alice@example.com")
    #expect(draft.title == "Git Hub")
    #expect(draft.period == 60)
    #expect(draft.digits == 8)
    #expect(draft.algorithm == .sha256)
}

@Test func otpAuthURIExporterRoundTripsHotpURIWithCounter() throws {
    let uri = try OtpAuthURIExporter.uri(
        secret: rfc4226Secret,
        issuer: "示例 服务",
        accountName: "alice:dev",
        period: 30,
        digits: 6,
        algorithm: .sha1,
        otpType: .hotp,
        counter: 42
    )

    #expect(uri.hasPrefix("otpauth://hotp/"))
    #expect(uri.contains("issuer=%E7%A4%BA%E4%BE%8B%20%E6%9C%8D%E5%8A%A1"))
    #expect(uri.contains("counter=42"))

    let draft = try TotpURIParser.parse(uri)
    #expect(draft.otpType == .hotp)
    #expect(draft.counter == 42)
    #expect(draft.issuer == "示例 服务")
    #expect(draft.accountName == "alice:dev")
}

@Test func otpAuthURIExporterRejectsInvalidInput() {
    #expect(throws: TotpError.invalidSecret) {
        try OtpAuthURIExporter.uri(secret: "not-valid-*", issuer: "GitHub", accountName: "alice")
    }
    #expect(throws: TotpError.invalidDigits) {
        try OtpAuthURIExporter.uri(
            secret: rfc4226Secret,
            issuer: "GitHub",
            accountName: "alice",
            digits: 4
        )
    }
    #expect(throws: TotpError.invalidPeriod) {
        try OtpAuthURIExporter.uri(
            secret: rfc4226Secret,
            issuer: "GitHub",
            accountName: "alice",
            period: 0
        )
    }
}

@Test func otpTypeStorageValueFallsBackToTotpForLegacyEntries() {
    #expect(OtpType(storageValue: "HOTP") == .hotp)
    #expect(OtpType(storageValue: " hotp ") == .hotp)
    #expect(OtpType(storageValue: "") == .totp)
    #expect(OtpType(storageValue: "TOTP") == .totp)
    #expect(OtpType(storageValue: "steam") == .totp)
}
