import Foundation
import Security

/// 用户名生成策略（#24）。
///
/// 词典由两个可注入的词表组成，生成结果形如 `Amber.harbor42`：
/// 形容词 + 分隔符 + 名词 + 可选数字后缀。所有随机取数都经过拒绝采样
/// 直接消费 `SecRandomCopyBytes` 输出的字节，不依赖 `random()` 或时间戳。
public struct UsernameGeneratorPolicy: Sendable, Equatable {
    /// 生成器允许的分隔符；多字符分隔符会显著拉长结果，这里只接受固定集合。
    public static let allowedSeparators = ["", ".", "_", "-", "+"]

    public static let defaultAdjectives = [
        "amber", "brave", "calm", "crimson", "dusty", "eager", "frosty", "gentle",
        "hidden", "ivory", "jolly", "keen", "lunar", "mild", "noble", "olive",
        "pale", "quiet", "rapid", "silver", "tidy", "urban", "vivid", "warm",
    ]

    public static let defaultNouns = [
        "anchor", "badger", "canyon", "cedar", "delta", "ember", "falcon", "garden",
        "harbor", "island", "juniper", "kettle", "lantern", "meadow", "needle",
        "orchard", "pebble", "quill", "river", "saddle", "thunder", "valley",
        "willow", "zephyr",
    ]

    /// 单个词的最大长度；超长词会让「长度控制」几乎不可满足。
    static let maximumWordLength = 24

    public let includeNumberSuffix: Bool
    /// 数字后缀位数；未启用后缀时忽略该值。
    public let digitCount: Int
    public let separator: String
    /// 结果总长度下限与上限（含）。
    public let lengthRange: ClosedRange<Int>
    public let adjectives: [String]
    public let nouns: [String]

    public init(
        includeNumberSuffix: Bool = true,
        digitCount: Int = 2,
        separator: String = ".",
        lengthRange: ClosedRange<Int> = 8...24,
        adjectives: [String] = UsernameGeneratorPolicy.defaultAdjectives,
        nouns: [String] = UsernameGeneratorPolicy.defaultNouns
    ) {
        self.includeNumberSuffix = includeNumberSuffix
        self.digitCount = digitCount
        self.separator = separator
        self.lengthRange = lengthRange
        self.adjectives = adjectives
        self.nouns = nouns
    }
}

public enum UsernameGeneratorError: Error, Sendable, Equatable {
    /// 词典为空，或词条包含不支持生成的字符。
    case emptyWordList
    case invalidWord(characters: String)
    case wordTooLong(maximum: Int)
    case invalidDigitCount
    case unsupportedSeparator
    case invalidLengthRange
    /// 给定词典在允许的尝试次数内拼不出落在长度区间里的结果。
    case unsatisfiableLength
    case randomFailure
}

public enum UsernameGenerator {
    /// 满足长度区间的最大尝试次数；超过后返回 `unsatisfiableLength`，不无限重试。
    static let maximumAttempts = 64

    public static func generate(policy: UsernameGeneratorPolicy = UsernameGeneratorPolicy()) throws -> String {
        try generate(policy: policy, randomBytes: secureRandomBytes)
    }

    /// 可注入确定性随机源，测试用固定字节序列覆盖边界分支。
    public static func generate(
        policy: UsernameGeneratorPolicy,
        randomBytes: (Int) throws -> [UInt8]
    ) throws -> String {
        let words = try validatedWords(policy)

        if policy.includeNumberSuffix, !(2...4).contains(policy.digitCount) {
            throw UsernameGeneratorError.invalidDigitCount
        }
        guard UsernameGeneratorPolicy.allowedSeparators.contains(policy.separator) else {
            throw UsernameGeneratorError.unsupportedSeparator
        }
        let lengthRange = policy.lengthRange
        guard lengthRange.lowerBound >= 4,
              lengthRange.upperBound <= 40,
              lengthRange.lowerBound <= lengthRange.upperBound
        else {
            throw UsernameGeneratorError.invalidLengthRange
        }

        for _ in 0..<maximumAttempts {
            let adjective = capitalized(
                words.adjectives[try randomIndex(upperBound: words.adjectives.count, randomBytes: randomBytes)]
            )
            let noun = capitalized(
                words.nouns[try randomIndex(upperBound: words.nouns.count, randomBytes: randomBytes)]
            )

            var candidate = adjective + policy.separator + noun
            if policy.includeNumberSuffix {
                var digits = ""
                for _ in 0..<policy.digitCount {
                    digits += String(try randomIndex(upperBound: 10, randomBytes: randomBytes))
                }
                candidate += policy.separator + digits
            }

            if lengthRange.contains(candidate.count) {
                return candidate
            }
        }

        throw UsernameGeneratorError.unsatisfiableLength
    }

    private static func validatedWords(
        _ policy: UsernameGeneratorPolicy
    ) throws -> (adjectives: [String], nouns: [String]) {
        let adjectives = try normalizedWords(policy.adjectives)
        let nouns = try normalizedWords(policy.nouns)
        guard !adjectives.isEmpty, !nouns.isEmpty else {
            throw UsernameGeneratorError.emptyWordList
        }
        return (adjectives, nouns)
    }

    private static func normalizedWords(_ words: [String]) throws -> [String] {
        var normalized: [String] = []
        for word in words {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed.isEmpty {
                continue
            }
            // 只接受英文字母，避免生成结果里出现空格、标点或非 ASCII 混排。
            let invalid = trimmed.filter { !($0.isASCII && $0.isLetter) }
            guard invalid.isEmpty else {
                throw UsernameGeneratorError.invalidWord(characters: invalid)
            }
            guard trimmed.count <= UsernameGeneratorPolicy.maximumWordLength else {
                throw UsernameGeneratorError.wordTooLong(
                    maximum: UsernameGeneratorPolicy.maximumWordLength
                )
            }
            normalized.append(trimmed)
        }
        return normalized
    }

    private static func capitalized(_ word: String) -> String {
        guard let first = word.first else {
            return word
        }
        return String(first).uppercased() + word.dropFirst()
    }

    private static func secureRandomBytes(count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw UsernameGeneratorError.randomFailure
        }
        return bytes
    }

    private static func randomIndex(
        upperBound: Int,
        randomBytes: (Int) throws -> [UInt8]
    ) throws -> Int {
        guard upperBound > 0, upperBound <= Int(UInt8.max) else {
            throw UsernameGeneratorError.emptyWordList
        }

        // 拒绝采样：丢弃会引入取模偏差的高位字节，不重新取种子。
        let limit = Int(UInt8.max) - (Int(UInt8.max) % upperBound)
        while true {
            guard let byte = try randomBytes(1).first else {
                throw UsernameGeneratorError.randomFailure
            }
            let value = Int(byte)
            if value < limit {
                return value % upperBound
            }
        }
    }
}

// MARK: - 唯一性提示

/// 本地唯一性比对结果；只在设备上与用户已有的登录条目比较，不联网。
public struct UsernameUniquenessReport: Sendable, Equatable {
    public let candidate: String
    /// 实际参与比较的非空用户名数量。
    public let comparedCount: Int
    /// 大小写完全一致的命中数。
    public let exactMatchCount: Int
    /// 忽略大小写后命中的数量（含 `exactMatchCount`）。
    public let caseInsensitiveMatchCount: Int

    public init(
        candidate: String,
        comparedCount: Int,
        exactMatchCount: Int,
        caseInsensitiveMatchCount: Int
    ) {
        self.candidate = candidate
        self.comparedCount = comparedCount
        self.exactMatchCount = exactMatchCount
        self.caseInsensitiveMatchCount = caseInsensitiveMatchCount
    }

    public var isUnique: Bool {
        caseInsensitiveMatchCount == 0
    }

    public var hasExactMatch: Bool {
        exactMatchCount > 0
    }
}

public enum UsernameUniqueness {
    /// 比较规则：两边都去掉首尾空白后，先按原样比较，再按小写比较。
    public static func compare(
        candidate: String,
        against existingUsernames: [String]
    ) -> UsernameUniquenessReport {
        let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCandidate.isEmpty else {
            return UsernameUniquenessReport(
                candidate: candidate,
                comparedCount: 0,
                exactMatchCount: 0,
                caseInsensitiveMatchCount: 0
            )
        }

        var comparedCount = 0
        var exactMatchCount = 0
        var caseInsensitiveMatchCount = 0
        let loweredCandidate = trimmedCandidate.lowercased()

        for username in existingUsernames {
            let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            comparedCount += 1
            if trimmed == trimmedCandidate {
                exactMatchCount += 1
            }
            if trimmed.lowercased() == loweredCandidate {
                caseInsensitiveMatchCount += 1
            }
        }

        return UsernameUniquenessReport(
            candidate: trimmedCandidate,
            comparedCount: comparedCount,
            exactMatchCount: exactMatchCount,
            caseInsensitiveMatchCount: caseInsensitiveMatchCount
        )
    }
}
