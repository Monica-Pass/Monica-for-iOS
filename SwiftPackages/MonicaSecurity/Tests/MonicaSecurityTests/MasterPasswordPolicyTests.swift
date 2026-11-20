import Testing
import MonicaSecurity

@Test func masterPasswordPolicyRejectsShortPasswords() {
    let empty = MasterPasswordPolicy.strength(of: "")
    #expect(empty.isAcceptable == false)
    #expect(empty.level == .weak)
    #expect(empty.blockingRequirements == [.minimumLength])

    let short = MasterPasswordPolicy.strength(of: "Ab1!")
    #expect(short.isAcceptable == false)
    #expect(short.blockingRequirements == [.minimumLength])
    #expect(MasterPasswordPolicy.isAcceptable("1234567") == false)
}

@Test func masterPasswordPolicyAcceptsLongChinesePassphrase() {
    let strength = MasterPasswordPolicy.strength(of: "明月几时有把酒问青天")
    #expect(strength.isAcceptable)
    #expect(strength.blockingRequirements.isEmpty)
    #expect(MasterPasswordPolicy.isAcceptable("明月几时有把酒问青天"))
}

@Test func masterPasswordPolicyTreatsMixedCharacterClassesAsAdvisoryOnly() {
    let lowercaseOnly = MasterPasswordPolicy.strength(of: "passwordpassword")
    #expect(lowercaseOnly.isAcceptable)
    #expect(lowercaseOnly.unmetRequirements == [.mixedCharacterClasses])
    #expect(lowercaseOnly.hint.contains("混合"))

    let mixed = MasterPasswordPolicy.strength(of: "Password123!")
    #expect(mixed.unmetRequirements.isEmpty)
    #expect(mixed.hint.isEmpty)
}

@Test func masterPasswordPolicyScoresLongerMixedPasswordsHigher() {
    let weak = MasterPasswordPolicy.strength(of: "password")
    let fair = MasterPasswordPolicy.strength(of: "Abcdefgh")
    let good = MasterPasswordPolicy.strength(of: "Password123!")
    let strong = MasterPasswordPolicy.strength(of: "Correct-Horse-Battery-42")

    #expect(weak.level == .weak)
    #expect(fair.level == .fair)
    #expect(good.level == .good)
    #expect(strong.level == .strong)
    #expect(weak.score < fair.score)
    #expect(fair.score < good.score)
    #expect(good.score < strong.score)
    #expect(strong.score <= 5)
}

@Test func masterPasswordPolicyCountsCharacterClasses() {
    #expect(MasterPasswordPolicy.characterClassCount(of: "abcdefgh") == 1)
    #expect(MasterPasswordPolicy.characterClassCount(of: "abcdefg1") == 2)
    #expect(MasterPasswordPolicy.characterClassCount(of: "Abcdefg1") == 3)
    #expect(MasterPasswordPolicy.characterClassCount(of: "Abcdefg1!") == 4)
    #expect(MasterPasswordPolicy.characterClassCount(of: "中文明月") == 0)
    #expect(MasterPasswordPolicy.minimumLength == 8)
}
