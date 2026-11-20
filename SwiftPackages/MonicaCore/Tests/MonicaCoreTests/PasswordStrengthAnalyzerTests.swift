import Foundation
import Testing
import MonicaCore

@Test func strengthLevelsUseFixedEstimatableThresholds() {
    #expect(PasswordStrengthAnalyzer.level(forEstimatedBits: 0) == .veryWeak)
    #expect(PasswordStrengthAnalyzer.level(forEstimatedBits: 27.99) == .veryWeak)
    #expect(PasswordStrengthAnalyzer.level(forEstimatedBits: 28) == .weak)
    #expect(PasswordStrengthAnalyzer.level(forEstimatedBits: 39.99) == .weak)
    #expect(PasswordStrengthAnalyzer.level(forEstimatedBits: 40) == .fair)
    #expect(PasswordStrengthAnalyzer.level(forEstimatedBits: 59.99) == .fair)
    #expect(PasswordStrengthAnalyzer.level(forEstimatedBits: 60) == .strong)
    #expect(PasswordStrengthAnalyzer.level(forEstimatedBits: 79.99) == .strong)
    #expect(PasswordStrengthAnalyzer.level(forEstimatedBits: 80) == .veryStrong)

    #expect(PasswordStrengthAnalyzer.estimatedBits(length: 0, alphabetSize: 94) == 0)
    #expect(PasswordStrengthAnalyzer.estimatedBits(length: 10, alphabetSize: 1) == 0)
    #expect(abs(PasswordStrengthAnalyzer.estimatedBits(length: 10, alphabetSize: 10) - 33.219) < 0.01)
}

@Test func strengthFlagsCommonPasswordsAndTrailingDigitVariants() {
    let plain = PasswordStrengthAnalyzer.assess("password")
    #expect(plain.level == .veryWeak)
    #expect(plain.findings.contains(.commonPassword))
    #expect(plain.findings.contains(.singleCharacterClass))
    #expect(plain.estimatedBits <= 12)

    let variant = PasswordStrengthAnalyzer.assess("password2024")
    #expect(variant.level == .veryWeak)
    #expect(variant.findings.contains(.commonPassword))
    #expect(variant.findings.contains(.yearSuffix))
}

@Test func strengthFlagsRepeatsSequencesAndKeyboardRuns() {
    let repeated = PasswordStrengthAnalyzer.assess("aaaaaaaaaaaa")
    #expect(repeated.findings.contains(.repeatedCharacters))
    #expect(repeated.findings.contains(.lowCharacterVariety))
    #expect(repeated.level == .veryWeak)

    let sequential = PasswordStrengthAnalyzer.assess("abcdefgh")
    #expect(sequential.findings.contains(.sequentialCharacters))
    #expect(sequential.level <= .weak)
    #expect(sequential.estimatedBits < PasswordStrengthAnalyzer.estimatedBits(length: 8, alphabetSize: 26))

    let keyboard = PasswordStrengthAnalyzer.assess("poiuytrewq")
    #expect(keyboard.findings.contains(.keyboardSequence))

    let year = PasswordStrengthAnalyzer.assess("Harbor-Pebble.2024")
    #expect(year.findings.contains(.yearSuffix))
    #expect(year.level == .veryStrong)
}

@Test func strengthTreatsEmptyAndShortSecretsAsVeryWeak() {
    let empty = PasswordStrengthAnalyzer.assess("")
    #expect(empty.level == .veryWeak)
    #expect(empty.findings == [.tooShort])
    #expect(empty.estimatedBits == 0)

    let short = PasswordStrengthAnalyzer.assess("aB3!")
    #expect(short.level == .veryWeak)
    #expect(short.findings.contains(.tooShort))
}

@Test func strengthRewardsLongMixedPasswordWithRealSearchSpace() {
    let strong = PasswordStrengthAnalyzer.assess("Tr0ub4dor&3")
    #expect(strong.level == .strong)
    #expect(strong.characterClassCount == 4)
    #expect(abs(strong.estimatedBits - 72.1) < 0.5)

    let veryStrong = PasswordStrengthAnalyzer.assess("V7!qZ2#mK9$pL4@wR8&xT1")
    #expect(veryStrong.level == .veryStrong)
}

@Test func strengthUsesPinWordAndTokenContexts() {
    let shortPIN = PasswordStrengthAnalyzer.assess("1234", context: .pin)
    #expect(shortPIN.findings.contains(.sequentialCharacters))
    #expect(shortPIN.level == .veryWeak)
    // 4 × log2(10) ≈ 13.29 bit，再叠加“123/234”连续序列的 -10 bit 惩罚。
    #expect(abs(shortPIN.estimatedBits - 3.29) < 0.05)

    let longPIN = PasswordStrengthAnalyzer.assess("4829137053617", context: .pin)
    #expect(longPIN.level == .fair)
    #expect(!longPIN.findings.contains(.allDigits))

    let passphrase = PasswordStrengthAnalyzer.assess(
        "amber-brisk-cedar-delta-signal-tundra",
        context: .passphrase(wordListSize: 7776)
    )
    #expect(passphrase.level == .strong)
    #expect(passphrase.findings.isEmpty)
    #expect(abs(passphrase.estimatedBits - 77.55) < 0.1)

    let shortPassphrase = PasswordStrengthAnalyzer.assess(
        "amber-brisk-cedar",
        context: .passphrase(wordListSize: 7776)
    )
    #expect(shortPassphrase.findings.contains(.fewPassphraseWords))
    #expect(shortPassphrase.level == .weak)

    let duplicateWords = PasswordStrengthAnalyzer.assess(
        "amber-amber-amber-amber",
        context: .passphrase(wordListSize: 7776)
    )
    #expect(duplicateWords.findings.contains(.repeatedCharacters))
    #expect(duplicateWords.level == .veryWeak)

    let token = PasswordStrengthAnalyzer.assess("abc", context: .apiToken(byteCount: 32))
    #expect(token.level == .veryStrong)
    #expect(token.estimatedBits == 256)

    let shortToken = PasswordStrengthAnalyzer.assess("abc", context: .apiToken(byteCount: 8))
    #expect(shortToken.findings.contains(.tokenTooShort))
    #expect(shortToken.level == .weak)
}
