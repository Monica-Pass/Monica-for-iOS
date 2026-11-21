import Foundation
import Testing
import MonicaCore

private func zeroBytes(_ count: Int) -> [UInt8] {
    [UInt8](repeating: 0, count: count)
}

@Test func usernameGeneratorProducesDictionarySeparatorAndDigits() throws {
    let policy = UsernameGeneratorPolicy(
        includeNumberSuffix: true,
        digitCount: 3,
        separator: "_",
        lengthRange: 4...40,
        adjectives: ["amber"],
        nouns: ["anchor"]
    )

    // 固定字节向量：索引恒为 0 → “Amber”、数字恒为 0 → “000”。
    let username = try UsernameGenerator.generate(policy: policy, randomBytes: zeroBytes)
    #expect(username == "Amber_Anchor_000")
    #expect(username.count == 16)
}

@Test func usernameGeneratorHonorsConfiguredLengthRange() throws {
    let policy = UsernameGeneratorPolicy(
        includeNumberSuffix: false,
        separator: ".",
        lengthRange: 5...5,
        adjectives: ["ab"],
        nouns: ["cd"]
    )

    let username = try UsernameGenerator.generate(policy: policy, randomBytes: zeroBytes)
    #expect(username == "Ab.Cd")
    #expect(policy.lengthRange.contains(username.count))
}

@Test func usernameGeneratorFailsWhenDictionaryCannotSatisfyLength() throws {
    let policy = UsernameGeneratorPolicy(
        includeNumberSuffix: true,
        digitCount: 2,
        separator: ".",
        lengthRange: 5...6,
        adjectives: ["amber"],
        nouns: ["harbor"]
    )

    #expect(throws: UsernameGeneratorError.unsatisfiableLength) {
        try UsernameGenerator.generate(policy: policy, randomBytes: zeroBytes)
    }
}

@Test func usernameGeneratorRejectsInvalidPolicies() throws {
    #expect(throws: UsernameGeneratorError.emptyWordList) {
        try UsernameGenerator.generate(
            policy: UsernameGeneratorPolicy(adjectives: [], nouns: ["harbor"]),
            randomBytes: zeroBytes
        )
    }

    #expect(throws: UsernameGeneratorError.invalidWord(characters: " ")) {
        try UsernameGenerator.generate(
            policy: UsernameGeneratorPolicy(adjectives: ["am ber"], nouns: ["harbor"]),
            randomBytes: zeroBytes
        )
    }

    #expect(throws: UsernameGeneratorError.wordTooLong(maximum: 24)) {
        try UsernameGenerator.generate(
            policy: UsernameGeneratorPolicy(
                adjectives: [String(repeating: "a", count: 25)],
                nouns: ["harbor"]
            ),
            randomBytes: zeroBytes
        )
    }

    #expect(throws: UsernameGeneratorError.invalidDigitCount) {
        try UsernameGenerator.generate(
            policy: UsernameGeneratorPolicy(includeNumberSuffix: true, digitCount: 1),
            randomBytes: zeroBytes
        )
    }

    #expect(throws: UsernameGeneratorError.unsupportedSeparator) {
        try UsernameGenerator.generate(
            policy: UsernameGeneratorPolicy(separator: "@"),
            randomBytes: zeroBytes
        )
    }

    #expect(throws: UsernameGeneratorError.invalidLengthRange) {
        try UsernameGenerator.generate(
            policy: UsernameGeneratorPolicy(lengthRange: 2...6),
            randomBytes: zeroBytes
        )
    }

    #expect(throws: UsernameGeneratorError.randomFailure) {
        try UsernameGenerator.generate(
            policy: UsernameGeneratorPolicy(),
            randomBytes: { _ in [] }
        )
    }
}

@Test func usernameGeneratorSampleStaysInsideCharsetAndLength() throws {
    // 用 2,000 次抽样代替 10,000 次：既能覆盖拒绝采样与长度区间，
    // 又把本用例控制在秒级。种子完全来自 SecRandomCopyBytes。
    let policy = UsernameGeneratorPolicy()
    let sampleCount = 2_000
    var generated: Set<String> = []
    var sawDigitSuffix = false

    for _ in 0..<sampleCount {
        let username = try UsernameGenerator.generate(policy: policy)
        generated.insert(username)

        #expect(policy.lengthRange.contains(username.count))
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: UsernameGeneratorPolicy.allowedSeparators.joined()))
        let insideCharset = username.unicodeScalars.allSatisfy { allowed.contains($0) }
        #expect(insideCharset)
        let asciiOnly = username.unicodeScalars.allSatisfy(\.isASCII)
        #expect(asciiOnly)

        let suffix = username.suffix(2)
        if suffix.allSatisfy({ $0.isASCII && $0.isNumber }) {
            sawDigitSuffix = true
        }
    }

    #expect(sawDigitSuffix)
    // 词典 24 × 24 × 100 种组合，2,000 次抽样应基本不重复。
    #expect(generated.count >= sampleCount * 9 / 10)
}

@Test func usernameUniquenessComparesExistingLoginsLocally() {
    let existing = ["alice", "Alice.01", " bob ", "", "   "]
    let report = UsernameUniqueness.compare(candidate: " Alice.01 ", against: existing)

    #expect(report.candidate == "Alice.01")
    #expect(report.comparedCount == 3)
    #expect(report.exactMatchCount == 1)
    // 大小写不敏感计数包含精确匹配，这里只有 "Alice.01" 命中。
    #expect(report.caseInsensitiveMatchCount == 1)
    #expect(report.hasExactMatch)
    #expect(!report.isUnique)

    let unique = UsernameUniqueness.compare(candidate: "carol", against: existing)
    #expect(unique.isUnique)
    #expect(unique.comparedCount == 3)

    let empty = UsernameUniqueness.compare(candidate: "   ", against: existing)
    #expect(empty.comparedCount == 0)
    #expect(empty.isUnique)
}
