import Foundation

/// 自动填充域名规则的类型（#40）。
///
/// - `block`：命中后 Monica 不再为该域名提供自动填充候选。
/// - `allow`：例外规则；即使命中了 `block`，只要同时命中 `allow` 就仍然允许。
///
/// 只约束 Monica 自己返回的候选与发布的凭据标识；系统设置里的其它密码管理器、
/// 以及用户在系统键盘/自动填充面板里手动选择的其它来源都不受这里影响。
public enum AutoFillDomainRuleKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case block
    case allow

    public var id: String { rawValue }
}

/// 一条域名规则。
///
/// `pattern` 始终是规范化之后的 host（小写、去端口/路径/协议、IDN 统一为 Unicode），
/// 这样保存下来的规则可以跨进程、跨语言版本稳定比较。
public struct AutoFillDomainRule: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    /// 规范化后的 host，例如 `example.com`、`192.168.1.1`、`例子.测试`。
    public var pattern: String
    public var kind: AutoFillDomainRuleKind
    /// 是否同时匹配子域名。IP 地址与单标签 host 永远只做精确匹配。
    public var includesSubdomains: Bool
    /// 用户备注，只用于展示，不参与匹配。
    public var note: String
    public var createdAt: Date

    public init?(
        rawPattern: String,
        kind: AutoFillDomainRuleKind,
        includesSubdomains: Bool = true,
        note: String = "",
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) {
        guard let parsed = AutoFillDomainNormalizer.parseRulePattern(rawPattern) else {
            return nil
        }
        self.id = id
        self.pattern = parsed.pattern
        self.kind = kind
        self.includesSubdomains = parsed.isIPAddress ? false : (includesSubdomains && parsed.isSubdomainCapable)
        self.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        // 规则要跨进程持久化，时间截断到整秒，避免 ISO8601 编码丢掉亚秒后比较不相等。
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
    }

    /// 是否命中给定的（已规范化的）host。
    public func matches(normalizedHost host: String) -> Bool {
        if host == pattern {
            return true
        }
        guard includesSubdomains else {
            return false
        }
        // 必须按标签边界比较：`notexample.com` 不能命中 `example.com`。
        return host.hasSuffix("." + pattern)
    }
}

/// 一条规则命中后的判定结果。
public enum AutoFillDomainDecision: Equatable, Sendable {
    case allowed
    case blocked(ruleID: UUID, pattern: String)

    public var isBlocked: Bool {
        if case .blocked = self {
            return true
        }
        return false
    }
}

/// 用户维护的域名规则集合。
///
/// 规则按「先例外、后屏蔽」判定：任意 `allow` 规则命中即放行；否则任意 `block` 规则命中即拦截。
public struct AutoFillDomainRuleSet: Codable, Equatable, Sendable {
    /// 结构版本，便于以后迁移；当前只有 1。
    public var version: Int
    public var rules: [AutoFillDomainRule]

    public static let empty = AutoFillDomainRuleSet(rules: [])
    public static let currentVersion = 1

    public init(rules: [AutoFillDomainRule] = []) {
        self.version = Self.currentVersion
        self.rules = rules
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        self.rules = try container.decodeIfPresent([AutoFillDomainRule].self, forKey: .rules) ?? []
    }

    public var isEmpty: Bool { rules.isEmpty }

    public var blockedRules: [AutoFillDomainRule] { rules.filter { $0.kind == .block } }
    public var allowedRules: [AutoFillDomainRule] { rules.filter { $0.kind == .allow } }

    /// 判定一个 host（可以是 URL、带端口/路径的串或裸域名）。
    public func decision(for rawHost: String) -> AutoFillDomainDecision {
        guard let host = AutoFillDomainNormalizer.normalizeHost(rawHost) else {
            return .allowed
        }
        return decision(forNormalizedHost: host)
    }

    public func decision(forNormalizedHost host: String) -> AutoFillDomainDecision {
        if let allowRule = rules.first(where: { $0.kind == .allow && $0.matches(normalizedHost: host) }) {
            _ = allowRule
            return .allowed
        }
        if let blockRule = rules.first(where: { $0.kind == .block && $0.matches(normalizedHost: host) }) {
            return .blocked(ruleID: blockRule.id, pattern: blockRule.pattern)
        }
        return .allowed
    }

    /// 判断一条凭据的 service identifier（URL 或域名）是否应被隐藏。
    public func hidesServiceIdentifier(_ identifier: String) -> Bool {
        decision(for: identifier).isBlocked
    }

    /// 追加一条规则；同 kind + 同 pattern 的重复规则会被忽略（返回 false）。
    @discardableResult
    public mutating func add(_ rule: AutoFillDomainRule) -> Bool {
        if rules.contains(where: { $0.pattern == rule.pattern && $0.kind == rule.kind }) {
            return false
        }
        rules.append(rule)
        return true
    }

    @discardableResult
    public mutating func remove(id: UUID) -> Bool {
        let before = rules.count
        rules.removeAll { $0.id == id }
        return rules.count != before
    }

    public func replacingRule(id: UUID, with rule: AutoFillDomainRule) -> AutoFillDomainRuleSet {
        var copy = self
        if let index = copy.rules.firstIndex(where: { $0.id == id }) {
            copy.rules[index] = rule
        }
        return copy
    }
}

/// host 规范化与校验。
///
/// 设计原则：规则与候选必须走同一套规范化，否则「用户输入的域名」与「系统给的
/// service identifier」永远对不上。规范化只做无损变换（大小写、IDN、去端口/路径/协议、
/// 去尾点），不做任何猜测性改写。
public enum AutoFillDomainNormalizer {
    public struct ParsedRulePattern: Equatable, Sendable {
        public var pattern: String
        public var isIPAddress: Bool
        /// 单标签 host 不能匹配子域名（它没有标签边界可依赖）。
        public var isSubdomainCapable: Bool
    }

    /// 把任意用户输入（URL、带端口、带通配前缀、带尾点）规范化为可比较的 host。
    ///
    /// 无法解析时返回 nil（调用方应当给用户一个内联错误，而不是静默接受）。
    public static func normalizeHost(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }

        if text.hasPrefix("*.") {
            text.removeFirst(2)
        }

        let candidate: String
        if text.contains("://") {
            guard let host = URLComponents(string: text)?.host else {
                return nil
            }
            candidate = host
        } else if text.contains("/") || text.contains("?") || text.contains("#") {
            guard let host = URLComponents(string: "https://" + text)?.host else {
                return nil
            }
            candidate = host
        } else {
            // 裸 host（可能带端口或 userinfo）。
            guard let host = URLComponents(string: "https://" + text)?.host else {
                return nil
            }
            candidate = host
        }

        return canonicalize(host: candidate)
    }

    /// 解析一条规则输入，同时给出「是否 IP」「能否匹配子域名」。
    public static func parseRulePattern(_ raw: String) -> ParsedRulePattern? {
        guard let host = normalizeHost(raw) else {
            return nil
        }
        let isIP = isIPv4Literal(host)
        let labelCount = host.split(separator: ".", omittingEmptySubsequences: false).count
        // 单标签（如 `com`、`localhost`）允许保存，但只能精确匹配；
        // 屏蔽整个 TLD 的风险由界面文案提示，而不是静默拒绝用户的合法输入。
        return ParsedRulePattern(pattern: host, isIPAddress: isIP, isSubdomainCapable: !isIP && labelCount >= 2)
    }

    /// 校验并规范化；拒绝空标签、非法字符、超长标签等明显错误。
    public static func canonicalize(host rawHost: String) -> String? {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasSuffix(".") {
            host.removeLast()
        }
        guard !host.isEmpty, host.count <= 253 else {
            return nil
        }

        // 统一 Unicode 组合形式，避免同一个域名有两种字节表示。
        host = host.precomposedStringWithCanonicalMapping

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else {
            return nil
        }
        for label in labels {
            guard !label.isEmpty, label.count <= 63 else {
                return nil
            }
            guard label.first != "-", label.last != "-" else {
                return nil
            }
            for scalar in label.unicodeScalars {
                if scalar.isASCII {
                    let isAllowed = CharacterSet.alphanumerics
                        .union(CharacterSet(charactersIn: "-"))
                        .contains(scalar)
                    guard isAllowed else {
                        return nil
                    }
                } else {
                    // 非 ASCII 交给系统 IDN 规则；这里只排除标点/空白/控制字符。
                    let disallowed = CharacterSet.punctuationCharacters
                        .union(.whitespacesAndNewlines)
                        .union(.controlCharacters)
                        .union(.symbols)
                    guard !disallowed.contains(scalar) else {
                        return nil
                    }
                }
            }
        }
        return host
    }

    /// 是否是点分十进制 IPv4 字面量。
    public static func isIPv4Literal(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            return false
        }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber), let value = Int(part) else {
                return false
            }
            return value >= 0 && value <= 255
        }
    }
}
