import Foundation

/// 主密码强度评估结果。
///
/// Monica 的主密码只作为 KEK 使用：Argon2id 从口令派生 unlock key，再用 AEAD 解包随机的
/// vault key。因此这里评估的是「人选择的口令」本身，而不是保险库密钥材料。
public struct MasterPasswordStrength: Sendable, Equatable {
    public enum Level: Int, Sendable, Equatable, CaseIterable {
        case weak
        case fair
        case good
        case strong

        public var label: String {
            switch self {
            case .weak:
                return "弱"
            case .fair:
                return "一般"
            case .good:
                return "较强"
            case .strong:
                return "强"
            }
        }
    }

    /// 不满足的要求。`minimumLength` 是硬性要求，会阻止提交；其余只作为提示。
    public enum Requirement: String, Sendable, Equatable, CaseIterable {
        case minimumLength
        case mixedCharacterClasses

        public var isBlocking: Bool {
            switch self {
            case .minimumLength:
                return true
            case .mixedCharacterClasses:
                return false
            }
        }

        public var hint: String {
            switch self {
            case .minimumLength:
                return "至少 \(MasterPasswordPolicy.minimumLength) 个字符"
            case .mixedCharacterClasses:
                return "混合大小写、数字或符号可以更强"
            }
        }
    }

    /// 0...5 的启发式评分，只用于展示，不参与解锁逻辑。
    public let score: Int
    public let level: Level
    public let unmetRequirements: [Requirement]

    public init(score: Int, level: Level, unmetRequirements: [Requirement]) {
        self.score = score
        self.level = level
        self.unmetRequirements = unmetRequirements
    }

    public var blockingRequirements: [Requirement] {
        unmetRequirements.filter(\.isBlocking)
    }

    /// 是否可以提交为新主密码。
    public var isAcceptable: Bool {
        blockingRequirements.isEmpty
    }

    /// 面向用户的提示文案，例如「至少 8 个字符；混合大小写、数字或符号可以更强」。
    public var hint: String {
        unmetRequirements.map(\.hint).joined(separator: "；")
    }
}

/// 主密码校验策略。
///
/// 注意：这里只约束「新主密码」。旧主密码仍然只由 MDBX 引擎判定，避免历史保险库因为
/// 策略升级而无法验证或无法修改。
public enum MasterPasswordPolicy {
    /// 硬性下限，按 `Character` 计数（中文等宽字符也算 1 个）。
    public static let minimumLength = 8
    /// 推荐长度，仅用于强度评分。
    public static let recommendedLength = 16

    public static func strength(of password: String) -> MasterPasswordStrength {
        let length = password.count
        let classCount = characterClassCount(of: password)

        var score = 0
        if length >= minimumLength {
            score += 1
        }
        if length >= 12 {
            score += 1
        }
        if length >= recommendedLength {
            score += 1
        }
        if classCount >= 2 {
            score += 1
        }
        if classCount >= 3 {
            score += 1
        }

        var unmet: [MasterPasswordStrength.Requirement] = []
        if length < minimumLength {
            unmet.append(.minimumLength)
        }
        if classCount < 2 {
            unmet.append(.mixedCharacterClasses)
        }

        let level: MasterPasswordStrength.Level
        switch score {
        case 0...1:
            level = .weak
        case 2:
            level = .fair
        case 3, 4:
            level = .good
        default:
            level = .strong
        }

        return MasterPasswordStrength(score: score, level: level, unmetRequirements: unmet)
    }

    public static func isAcceptable(_ password: String) -> Bool {
        strength(of: password).isAcceptable
    }

    /// 小写、大写、数字、符号四类字符中出现了几类。
    public static func characterClassCount(of password: String) -> Int {
        var classes = 0
        if password.contains(where: \.isLowercase) {
            classes += 1
        }
        if password.contains(where: \.isUppercase) {
            classes += 1
        }
        if password.contains(where: \.isNumber) {
            classes += 1
        }
        if password.contains(where: { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }) {
            classes += 1
        }
        return classes
    }
}
