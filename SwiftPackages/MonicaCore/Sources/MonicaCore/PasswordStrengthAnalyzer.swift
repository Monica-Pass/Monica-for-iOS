import Foundation

/// 密码强度等级（#24）。
///
/// 等级只由可解释的规则得出：字符集大小 × 长度得到搜索空间，再按
/// 常见弱口令、重复字符、连续序列、键盘序列、年份后缀等命中扣减。
/// 不提供“精确分数”，`PasswordStrengthAssessment.estimatedBits` 只是估算。
public enum PasswordStrengthLevel: String, Sendable, Equatable, CaseIterable, Comparable {
    case veryWeak
    case weak
    case fair
    case strong
    case veryStrong

    public var rank: Int {
        switch self {
        case .veryWeak: 0
        case .weak: 1
        case .fair: 2
        case .strong: 3
        case .veryStrong: 4
        }
    }

    public static func < (lhs: PasswordStrengthLevel, rhs: PasswordStrengthLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// 影响强度评估的具体命中项，App 侧据此给出可解释的提示文案。
public enum PasswordStrengthFinding: String, Sendable, Equatable, CaseIterable {
    case tooShort
    case allDigits
    case singleCharacterClass
    case commonPassword
    case repeatedCharacters
    case lowCharacterVariety
    case sequentialCharacters
    case keyboardSequence
    case yearSuffix
    case fewPassphraseWords
    case tokenTooShort
}

/// 生成模式对应的评估上下文：PIN 只有数字，短语按词表大小，Token 按字节熵。
public enum PasswordStrengthContext: Sendable, Equatable {
    case password
    case pin
    case passphrase(wordListSize: Int)
    case apiToken(byteCount: Int)
}

public struct PasswordStrengthAssessment: Sendable, Equatable {
    public let level: PasswordStrengthLevel
    /// 估算的搜索空间（bits）；不是精确分数，UI 必须标注“估算”。
    public let estimatedBits: Double
    public let length: Int
    public let characterClassCount: Int
    public let findings: [PasswordStrengthFinding]

    public init(
        level: PasswordStrengthLevel,
        estimatedBits: Double,
        length: Int,
        characterClassCount: Int,
        findings: [PasswordStrengthFinding]
    ) {
        self.level = level
        self.estimatedBits = estimatedBits
        self.length = length
        self.characterClassCount = characterClassCount
        self.findings = findings
    }
}

public enum PasswordStrengthAnalyzer {
    /// 常见弱口令表（小写）。来源是多年公开的弱口令榜单，只用于本地比对。
    public static let commonPasswords: Set<String> = [
        "123456", "password", "12345678", "qwerty", "123456789", "12345", "1234",
        "111111", "1234567", "dragon", "123123", "baseball", "abc123", "football",
        "monkey", "letmein", "shadow", "master", "666666", "qwertyuiop", "123321",
        "mustang", "1234567890", "michael", "654321", "superman", "1qaz2wsx",
        "7777777", "121212", "000000", "qazwsx", "123qwe", "killer", "trustno1",
        "jordan", "jennifer", "zxcvbnm", "asdfgh", "hunter", "buster", "soccer",
        "harley", "batman", "andrew", "tigger", "sunshine", "iloveyou", "charlie",
        "robert", "thomas", "hockey", "ranger", "daniel", "starwars", "klaster",
        "112233", "george", "computer", "michelle", "jessica", "pepper", "1111",
        "zxcvbn", "555555", "11111111", "131313", "freedom", "777777", "maggie",
        "159753", "aaaaaa", "ginger", "princess", "joshua", "cheese", "amanda",
        "summer", "ashley", "6969", "nicole", "chelsea", "biteme", "matthew",
        "access", "yankees", "987654321", "dallas", "austin", "thunder", "taylor",
        "matrix", "william", "corvette", "hello", "martin", "heather", "secret",
        "merlin", "diamond", "1234qwer", "ghfjkm", "hammer", "silver", "222222",
        "88888888", "anthony", "justin", "test", "bailey", "q1w2e3r4t5", "patrick",
        "internet", "scooter", "orange", "11111", "golfer", "cookie", "richard",
        "samantha", "bigdog", "guitar", "jackson", "whatever", "mickey", "chicken",
        "sparky", "snoopy", "maverick", "phoenix", "camaro", "peanut", "morgan",
        "welcome", "falcon", "cowboy", "ferrari", "samsung", "andrea", "smokey",
        "steelers", "joseph", "mercedes", "dakota", "arsenal", "eagles", "melissa",
        "boomer", "booboo", "spider", "nascar", "monster", "tigers", "yellow",
        "xxxxxx", "123123123", "gateway", "marina", "diablo", "bulldog", "qwer1234",
        "compaq", "purple", "hardcore", "banana", "junior", "hannah", "123654",
        "porsche", "lakers", "iceman", "money", "cowboys", "987654", "london",
        "tennis", "020202", "999999", "ncc1701", "coffee", "scooby", "0000",
        "miller", "boston", "q1w2e3r4", "brandon", "yamaha", "chester", "mother",
        "forever", "johnny", "edward", "333333", "oliver", "redsox", "player",
        "nikita", "knight", "fender", "barney", "midnight", "please", "brandy",
        "chicago", "badboy", "iwantu", "slayer", "rangers", "charles", "angel",
        "flower", "bigdaddy", "rabbit", "wizard", "bigdick", "jasper", "enter",
        "rachel", "chris", "steven", "winner", "adidas", "victoria", "natasha",
        "1q2w3e4r", "jasmine", "winter", "prince", "marine", "fishing", "cocacola",
        "casper", "james", "232323", "raiders", "135790", "passw0rd", "password1",
        "password123", "p@ssw0rd", "admin", "administrator", "root", "toor",
        "guest", "changeme", "default", "qwerty123", "1q2w3e", "letmein123",
        "welcome1", "welcome123", "abc123456", "123456a", "a123456", "654321a",
        "qwe123", "zxc123", "asd123", "1qazxsw2", "qazwsx123", "woaini1314",
        "5201314", "1314520", "a123456789", "qq123456", "aa123456", "123456abc",
    ]

    /// 低于该长度的密码直接标为很弱，与 NIST 建议的最短长度一致。
    public static let minimumLength = 8
    static let weakBits = 28.0
    static let fairBits = 40.0
    static let strongBits = 60.0
    static let veryStrongBits = 80.0

    // MARK: - 估算

    /// 由长度与字符集大小估算搜索空间（bits）。
    public static func estimatedBits(length: Int, alphabetSize: Int) -> Double {
        guard length > 0, alphabetSize > 1 else {
            return 0
        }
        return Double(length) * log2(Double(alphabetSize))
    }

    /// bits → 等级。阈值固定且公开，方便 UI 解释，不随结果“猜”分数。
    public static func level(forEstimatedBits bits: Double) -> PasswordStrengthLevel {
        if bits >= veryStrongBits {
            return .veryStrong
        }
        if bits >= strongBits {
            return .strong
        }
        if bits >= fairBits {
            return .fair
        }
        if bits >= weakBits {
            return .weak
        }
        return .veryWeak
    }

    public static func assess(
        _ secret: String,
        context: PasswordStrengthContext = .password
    ) -> PasswordStrengthAssessment {
        switch context {
        case .password:
            return assessPassword(secret)
        case .pin:
            return assessPIN(secret)
        case let .passphrase(wordListSize):
            return assessPassphrase(secret, wordListSize: wordListSize)
        case let .apiToken(byteCount):
            return assessAPIToken(secret, byteCount: byteCount)
        }
    }

    // MARK: - 分模式评估

    private static func assessPassword(_ secret: String) -> PasswordStrengthAssessment {
        let characters = Array(secret)
        let length = characters.count
        let classes = characterClassCount(characters)
        guard length > 0 else {
            return PasswordStrengthAssessment(
                level: .veryWeak,
                estimatedBits: 0,
                length: 0,
                characterClassCount: 0,
                findings: [.tooShort]
            )
        }

        let lowered = secret.lowercased()
        var findings: [PasswordStrengthFinding] = []
        var bits = estimatedBits(length: length, alphabetSize: estimatedAlphabetSize(characters))

        if length < minimumLength {
            findings.append(.tooShort)
            bits = min(bits, weakBits)
        }
        if characters.allSatisfy({ $0.isASCII && $0.isNumber }) {
            findings.append(.allDigits)
        }
        if classes <= 1 {
            findings.append(.singleCharacterClass)
            if length < 12 {
                bits = min(bits, fairBits - 10)
            }
        }
        if isCommonPassword(lowered) {
            findings.append(.commonPassword)
            bits = min(bits, 12)
        }
        if hasRepeatedRun(characters) {
            findings.append(.repeatedCharacters)
            bits *= 0.6
        }
        if hasLowVariety(characters) {
            findings.append(.lowCharacterVariety)
            bits *= 0.7
        }
        if hasSequentialRun(lowered) {
            findings.append(.sequentialCharacters)
            bits = max(0, bits - 10)
        }
        if hasKeyboardRun(lowered) {
            findings.append(.keyboardSequence)
            bits = max(0, bits - 10)
        }
        if hasYearSuffix(lowered) {
            findings.append(.yearSuffix)
            bits = max(0, bits - 4)
        }

        var level = level(forEstimatedBits: bits)
        if findings.contains(.commonPassword) {
            level = .veryWeak
        }
        if findings.contains(.allDigits) {
            level = min(level, .weak)
        }

        return PasswordStrengthAssessment(
            level: level,
            estimatedBits: bits,
            length: length,
            characterClassCount: classes,
            findings: findings
        )
    }

    private static func assessPIN(_ pin: String) -> PasswordStrengthAssessment {
        let characters = Array(pin)
        let length = characters.count
        guard length > 0 else {
            return PasswordStrengthAssessment(
                level: .veryWeak,
                estimatedBits: 0,
                length: 0,
                characterClassCount: 0,
                findings: [.tooShort]
            )
        }

        var findings: [PasswordStrengthFinding] = []
        var bits = estimatedBits(length: length, alphabetSize: 10)
        if length < 6 {
            findings.append(.tooShort)
            bits = min(bits, weakBits)
        }
        if hasRepeatedRun(characters) {
            findings.append(.repeatedCharacters)
            bits *= 0.6
        }
        if hasSequentialRun(pin) {
            findings.append(.sequentialCharacters)
            bits = max(0, bits - 10)
        }

        return PasswordStrengthAssessment(
            level: level(forEstimatedBits: bits),
            estimatedBits: bits,
            length: length,
            characterClassCount: 1,
            findings: findings
        )
    }

    private static func assessPassphrase(
        _ passphrase: String,
        wordListSize: Int
    ) -> PasswordStrengthAssessment {
        let words = passphrase
            .split(whereSeparator: { $0 == "-" || $0 == " " || $0 == "_" || $0 == "." })
            .filter { !$0.isEmpty }
        let wordCount = words.count
        var findings: [PasswordStrengthFinding] = []
        let perWordBits = wordListSize > 1 ? log2(Double(wordListSize)) : 0
        var bits = Double(wordCount) * perWordBits

        if wordCount < 4 {
            findings.append(.fewPassphraseWords)
            bits = min(bits, fairBits - 2)
        }
        if Set(words.map { $0.lowercased() }).count < wordCount {
            // 重复词会显著降低实际熵，按去重后的词数重新估算。
            findings.append(.repeatedCharacters)
            let distinct = Set(words.map { $0.lowercased() }).count
            bits = Double(max(distinct, 1)) * perWordBits
        }

        return PasswordStrengthAssessment(
            level: level(forEstimatedBits: bits),
            estimatedBits: bits,
            length: passphrase.count,
            characterClassCount: 1,
            findings: findings
        )
    }

    private static func assessAPIToken(_ token: String, byteCount: Int) -> PasswordStrengthAssessment {
        var findings: [PasswordStrengthFinding] = []
        var bits = Double(max(byteCount, 0)) * 8
        if byteCount < 16 {
            findings.append(.tokenTooShort)
            bits = min(bits, fairBits - 2)
        }
        return PasswordStrengthAssessment(
            level: level(forEstimatedBits: bits),
            estimatedBits: bits,
            length: token.count,
            characterClassCount: characterClassCount(Array(token)),
            findings: findings
        )
    }

    // MARK: - 规则

    static func characterClassCount(_ characters: [Character]) -> Int {
        var hasLower = false
        var hasUpper = false
        var hasDigit = false
        var hasSymbol = false
        var hasOther = false

        for character in characters {
            if character.isASCII, character.isLowercase {
                hasLower = true
            } else if character.isASCII, character.isUppercase {
                hasUpper = true
            } else if character.isASCII, character.isNumber {
                hasDigit = true
            } else if character.isASCII {
                hasSymbol = true
            } else {
                hasOther = true
            }
        }

        return [hasLower, hasUpper, hasDigit, hasSymbol, hasOther]
            .filter { $0 }
            .count
    }

    /// 与 `PasswordGeneratorPolicy` 使用的字符集保持一致：大小写各 26、数字 10、符号 32。
    /// 每个出现过的字符类只计一次，不按字符数量累加。
    static func estimatedAlphabetSize(_ characters: [Character]) -> Int {
        var hasLower = false
        var hasUpper = false
        var hasDigit = false
        var hasSymbol = false
        var hasOther = false
        for character in characters {
            if character.isASCII, character.isLowercase {
                hasLower = true
            } else if character.isASCII, character.isUppercase {
                hasUpper = true
            } else if character.isASCII, character.isNumber {
                hasDigit = true
            } else if character.isASCII {
                hasSymbol = true
            } else {
                hasOther = true
            }
        }

        var size = 0
        if hasLower { size += 26 }
        if hasUpper { size += 26 }
        if hasDigit { size += 10 }
        if hasSymbol { size += 32 }
        if hasOther { size += 64 }
        return max(size, 2)
    }

    /// 精确命中常见弱口令表；额外把“弱口令 + 纯数字尾巴”视作变体命中。
    static func isCommonPassword(_ lowered: String) -> Bool {
        if commonPasswords.contains(lowered) {
            return true
        }
        let base = String(lowered.reversed().drop { $0.isNumber }.reversed())
        guard base.count >= 4, base != lowered else {
            return false
        }
        return commonPasswords.contains(base)
    }

    static func hasRepeatedRun(_ characters: [Character]) -> Bool {
        guard characters.count >= 3 else {
            return false
        }
        var runLength = 1
        for index in 1..<characters.count {
            if characters[index] == characters[index - 1] {
                runLength += 1
                if runLength >= 3 {
                    return true
                }
            } else {
                runLength = 1
            }
        }
        return false
    }

    static func hasLowVariety(_ characters: [Character]) -> Bool {
        guard characters.count >= 8 else {
            return false
        }
        return Double(Set(characters).count) / Double(characters.count) < 0.4
    }

    /// 3 个及以上连续递增/递减的字母或数字（abc、321、9876）。
    static func hasSequentialRun(_ lowered: String) -> Bool {
        let scalars = Array(lowered.unicodeScalars)
        guard scalars.count >= 3 else {
            return false
        }
        var ascending = 1
        var descending = 1
        for index in 1..<scalars.count {
            let previous = scalars[index - 1]
            let current = scalars[index]
            let bothAlphanumeric = isASCIIAlphanumeric(previous) && isASCIIAlphanumeric(current)
            if bothAlphanumeric, current.value == previous.value + 1 {
                ascending += 1
                descending = 1
            } else if bothAlphanumeric, current.value &+ 1 == previous.value {
                descending += 1
                ascending = 1
            } else {
                ascending = 1
                descending = 1
            }
            if ascending >= 3 || descending >= 3 {
                return true
            }
        }
        return false
    }

    /// 键盘横向序列（含倒序），长度 4 起算。
    static func hasKeyboardRun(_ lowered: String) -> Bool {
        let rows = [
            "qwertyuiop", "asdfghjkl", "zxcvbnm", "1234567890", "1qaz2wsx", "qazwsxedc",
        ]
        guard lowered.count >= 4 else {
            return false
        }
        for row in rows {
            let reversedRow = String(row.reversed())
            for source in [row, reversedRow] {
                var windowStart = source.startIndex
                while let end = source.index(windowStart, offsetBy: 4, limitedBy: source.endIndex) {
                    let window = String(source[windowStart..<end])
                    if lowered.contains(window) {
                        return true
                    }
                    windowStart = source.index(after: windowStart)
                }
            }
        }
        return false
    }

    static func hasYearSuffix(_ lowered: String) -> Bool {
        guard lowered.count >= 4 else {
            return false
        }
        let suffix = String(lowered.suffix(4))
        guard suffix.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return false
        }
        return suffix.hasPrefix("19") || suffix.hasPrefix("20")
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.isASCII else {
            return false
        }
        return (48...57).contains(scalar.value)
            || (65...90).contains(scalar.value)
            || (97...122).contains(scalar.value)
    }
}
