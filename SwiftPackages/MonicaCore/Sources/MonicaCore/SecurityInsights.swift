import CryptoKit
import Foundation

// MARK: - 问题分类

/// 安全分析能给出的本地问题分类（#56）。
///
/// 全部由本机数据推导，不发起任何网络请求：
/// - `weakPassword`：长度 / 字符类别不足，或命中本地常见弱口令表。
/// - `reusedPassword`：多个登录条目使用同一个密码（本次审计内用一次性 HMAC 分组，明文不落盘）。
/// - `missingTwoFactor`：本机没有找到与该登录匹配的验证器条目（本地启发式，不代表服务端是否开启 2FA）。
/// - `duplicateEntry`：标题、账号与站点归一化后完全相同的多条记录（同一站点的不同账号不算）。
/// - `stalePassword`：当前密码的设置时间超过阈值（依据密码历史推导，未知年龄不计入）。
/// - `flaggedBreach`：用户手动标记为“疑似已泄露”，仅本地保存，不做任何在线查询。
public enum SecurityInsightIssue: String, Sendable, Equatable, Hashable, CaseIterable, Codable, Identifiable {
    case flaggedBreach
    case weakPassword
    case reusedPassword
    case missingTwoFactor
    case duplicateEntry
    case stalePassword

    public var id: String { rawValue }

    /// 严重度排序：数字越小越优先处理，也决定仪表盘里的展示顺序。
    public var severityRank: Int {
        switch self {
        case .flaggedBreach: 0
        case .weakPassword: 1
        case .reusedPassword: 2
        case .missingTwoFactor: 3
        case .duplicateEntry: 4
        case .stalePassword: 5
        }
    }
}

// MARK: - 评分

/// 0–100 评分的可审计定义（#56）。
///
/// `score = max(0, 100 - Σ min(count(issue) × weight(issue), cap(issue)))`。
/// 每个分类都有独立的权重与封顶，任何一项都不会把其他项挤成“看不见”，
/// 因此界面可以把每一次扣分原样展示给用户审计。
public enum SecurityInsightScoring {
    public static let maximumScore = 100

    public static func weight(for issue: SecurityInsightIssue) -> Int {
        switch issue {
        case .flaggedBreach: 12
        case .weakPassword: 10
        case .reusedPassword: 8
        case .missingTwoFactor: 5
        case .duplicateEntry: 6
        case .stalePassword: 4
        }
    }

    public static func cap(for issue: SecurityInsightIssue) -> Int {
        switch issue {
        case .flaggedBreach: 48
        case .weakPassword: 40
        case .reusedPassword: 32
        case .missingTwoFactor: 20
        case .duplicateEntry: 18
        case .stalePassword: 16
        }
    }

    /// 单项扣分：`min(count × weight, cap)`。
    public static func points(count: Int, for issue: SecurityInsightIssue) -> Int {
        guard count > 0 else {
            return 0
        }
        let raw = count * weight(for: issue)
        return min(raw, cap(for: issue))
    }

    /// 由各分类命中数量算出最终分数。
    public static func score(counts: [SecurityInsightIssue: Int]) -> Int {
        let total = SecurityInsightIssue.allCases.reduce(0) { partial, issue in
            partial + points(count: counts[issue] ?? 0, for: issue)
        }
        return max(0, maximumScore - total)
    }
}

/// 把 0–100 总分换算成分档：界面据此决定文案与配色，也让“为什么是 64 分”可被外部复核。
public enum SecurityInsightScoreBand: String, Sendable, Equatable, CaseIterable {
    /// 90–100：几乎没有可立即处理的问题。
    case excellent
    /// 75–89：存在少量问题。
    case good
    /// 55–74：需要集中处理。
    case fair
    /// 0–54：风险较高。
    case atRisk

    /// 分档下界（含）。
    public var minimumScore: Int {
        switch self {
        case .excellent: 90
        case .good: 75
        case .fair: 55
        case .atRisk: 0
        }
    }

    /// 分档上界（含）。
    public var maximumScore: Int {
        switch self {
        case .excellent: SecurityInsightScoring.maximumScore
        case .good: 89
        case .fair: 74
        case .atRisk: 54
        }
    }

    /// 分值 → 分档；越界分数按最近一档处理。
    public static func band(for score: Int) -> SecurityInsightScoreBand {
        switch score {
        case 90...: .excellent
        case 75..<90: .good
        case 55..<75: .fair
        default: .atRisk
        }
    }
}

/// 单项扣分的完整依据，供界面逐条展示（“为什么扣了 X 分”）。
public struct SecurityInsightPenalty: Sendable, Equatable, Identifiable {
    public let issue: SecurityInsightIssue
    public let count: Int
    public let weight: Int
    public let cap: Int
    public let points: Int

    public var id: String { issue.rawValue }

    public init(issue: SecurityInsightIssue, count: Int) {
        self.issue = issue
        self.count = max(0, count)
        self.weight = SecurityInsightScoring.weight(for: issue)
        self.cap = SecurityInsightScoring.cap(for: issue)
        self.points = SecurityInsightScoring.points(count: self.count, for: issue)
    }
}

// MARK: - 年龄分布

/// 当前密码年龄分布（#56）。
///
/// 年龄来自密码历史里最近一次改密时间；从未改过密码的条目没有可靠时间，
/// 归入 `unknown`，既不猜也不计入“长期未改”。
public enum SecurityPasswordAgeBucket: String, Sendable, Equatable, CaseIterable, Codable, Identifiable {
    case unknown
    case under90Days
    case days90To179
    case days180To364
    case atLeast365Days

    public var id: String { rawValue }

    /// 桶的上界（天，不含），`nil` 表示无上界或未知。
    public var upperBoundDays: Int? {
        switch self {
        case .unknown: nil
        case .under90Days: 90
        case .days90To179: 180
        case .days180To364: 365
        case .atLeast365Days: nil
        }
    }

    public static func bucket(forAgeDays ageDays: Int?) -> SecurityPasswordAgeBucket {
        guard let ageDays, ageDays >= 0 else {
            return .unknown
        }
        switch ageDays {
        case ..<90: return .under90Days
        case 90..<180: return .days90To179
        case 180..<365: return .days180To364
        default: return .atLeast365Days
        }
    }
}

// MARK: - 输入

/// 一次审计的单个登录条目快照。
///
/// `password` 只在内存里参与计算：审计结束后不会出现在报告、趋势或持久化文件里。
/// 不包含 `createdAt` / `updatedAt`，因为存储层没有这两个字段——年龄只来自密码历史。
public struct SecurityInsightSubject: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let username: String
    public let url: String
    public let password: String
    /// 当前密码的设置时间；`nil` 表示本机没有可靠记录。
    public let passwordChangedAt: Date?
    /// 本机是否找到与该登录匹配的验证器条目。
    public let hasLinkedAuthenticator: Bool
    /// 用户是否手动标记为“疑似已泄露”。
    public let isMarkedBreached: Bool
    /// 是否已被用户忽略合并：这些条目不再计入“重复项”，与安全中心既有的忽略机制保持同一口径。
    public let isIgnoredForDuplicateGrouping: Bool

    public init(
        id: String,
        title: String,
        username: String,
        url: String,
        password: String,
        passwordChangedAt: Date?,
        hasLinkedAuthenticator: Bool,
        isMarkedBreached: Bool,
        isIgnoredForDuplicateGrouping: Bool = false
    ) {
        self.id = id
        self.title = title
        self.username = username
        self.url = url
        self.password = password
        self.passwordChangedAt = passwordChangedAt
        self.hasLinkedAuthenticator = hasLinkedAuthenticator
        self.isMarkedBreached = isMarkedBreached
        self.isIgnoredForDuplicateGrouping = isIgnoredForDuplicateGrouping
    }
}

// MARK: - 结果

/// 单条命中，供界面逐项展示与跳转到条目。
///
/// 只保留标题 / 账号 / 站点等已有可见信息，**不含密码**。
public struct SecurityInsightFinding: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let username: String
    public let host: String?
    public let issues: [SecurityInsightIssue]
    /// 当前密码已使用天数；`nil` 表示未知。
    public let ageDays: Int?

    public init(
        id: String,
        title: String,
        username: String,
        host: String?,
        issues: [SecurityInsightIssue],
        ageDays: Int?
    ) {
        self.id = id
        self.title = title
        self.username = username
        self.host = host
        self.issues = issues
        self.ageDays = ageDays
    }

    public var severityRank: Int {
        issues.map(\.severityRank).min() ?? SecurityInsightIssue.allCases.count
    }
}

/// 一次安全审计的完整结果。
public struct SecurityInsightReport: Sendable, Equatable {
    /// 0–100，见 `SecurityInsightScoring`。
    public let score: Int
    public let totalItemCount: Int
    /// 每个分类的命中条目数；五个分类全部存在，缺失按 0 处理。
    public let counts: [SecurityInsightIssue: Int]
    /// 只包含命中数大于 0 的扣分项，按严重度排序。
    public let penalties: [SecurityInsightPenalty]
    public let ageDistribution: [SecurityPasswordAgeBucket: Int]
    /// 只包含至少命中一个问题分类的条目，按严重度 + 标题排序。
    public let findings: [SecurityInsightFinding]
    public let auditedAt: Date

    public init(
        score: Int,
        totalItemCount: Int,
        counts: [SecurityInsightIssue: Int],
        penalties: [SecurityInsightPenalty],
        ageDistribution: [SecurityPasswordAgeBucket: Int],
        findings: [SecurityInsightFinding],
        auditedAt: Date
    ) {
        self.score = score
        self.totalItemCount = totalItemCount
        self.counts = counts
        self.penalties = penalties
        self.ageDistribution = ageDistribution
        self.findings = findings
        self.auditedAt = auditedAt
    }

    public var isEmpty: Bool {
        totalItemCount == 0
    }

    public var findingItemCount: Int {
        findings.count
    }

    public func count(for issue: SecurityInsightIssue) -> Int {
        counts[issue] ?? 0
    }

    public func penalty(for issue: SecurityInsightIssue) -> Int {
        penalties.first { $0.issue == issue }?.points ?? 0
    }

    /// 一键筛选：`nil` 返回全部命中条目。
    public func findings(matching issue: SecurityInsightIssue?) -> [SecurityInsightFinding] {
        guard let issue else {
            return findings
        }
        return findings.filter { $0.issues.contains(issue) }
    }

    public func ageCount(for bucket: SecurityPasswordAgeBucket) -> Int {
        ageDistribution[bucket] ?? 0
    }
}

// MARK: - 锁定态快照

/// 仪表盘可用的安全状态。
///
/// 锁库时构造出的快照**不携带任何条目元信息**（无分数、无计数、无命中项），
/// 界面因此无法误把条目信息画到锁屏预览上。
public struct SecurityInsightDashboardSnapshot: Sendable, Equatable {
    public let isLocked: Bool
    public let report: SecurityInsightReport?

    public init(isLocked: Bool, report: SecurityInsightReport?) {
        self.isLocked = isLocked
        // 锁定态一律丢弃报告，即使调用方传进来也不保留。
        self.report = isLocked ? nil : report
    }

    public static let locked = SecurityInsightDashboardSnapshot(isLocked: true, report: nil)

    public static func unlocked(_ report: SecurityInsightReport) -> SecurityInsightDashboardSnapshot {
        SecurityInsightDashboardSnapshot(isLocked: false, report: report)
    }

    public var score: Int? { report?.score }
    public var totalItemCount: Int? { report?.totalItemCount }
    public var counts: [SecurityInsightIssue: Int] { report?.counts ?? [:] }
    public var penalties: [SecurityInsightPenalty] { report?.penalties ?? [] }
    public var findings: [SecurityInsightFinding] { report?.findings ?? [] }
    public var ageDistribution: [SecurityPasswordAgeBucket: Int] { report?.ageDistribution ?? [:] }

    public func count(for issue: SecurityInsightIssue) -> Int {
        report?.count(for: issue) ?? 0
    }

    public func findings(matching issue: SecurityInsightIssue?) -> [SecurityInsightFinding] {
        report?.findings(matching: issue) ?? []
    }
}

// MARK: - 站点 / 账号归一化

/// 站点与账号的归一化规则，供重复检测和验证器匹配共用。
public enum SecurityInsightURL {
    /// 从任意写法的 URL / 域名里取小写主机名，去掉 `www.` 与端口。
    public static func normalizedHost(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            return nil
        }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var host = URL(string: candidate)?.host?.lowercased() else {
            return nil
        }
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        return host.isEmpty ? nil : host
    }

    /// 只保留字母数字，用于比较 issuer / 标题等人类可读名称。
    public static func normalizedName(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let scalars = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }
}

// MARK: - 2FA 关联

/// 本地 2FA 关联启发式（#56）。
///
/// 验证器条目里没有“属于哪个登录”的外键，只能用账号名 / 站点主机 / 标题做匹配。
/// 匹配不上只会让界面提示“本机未找到匹配验证器条目”，**不会**断言该账号没有开启 2FA。
public enum SecurityInsightTwoFactorMatcher {
    public struct AuthenticatorIdentity: Sendable, Equatable {
        public let accountName: String
        public let issuer: String
        public let title: String

        public init(accountName: String, issuer: String, title: String) {
            self.accountName = accountName
            self.issuer = issuer
            self.title = title
        }
    }

    /// 验证器条目与登录条目是否视为已关联。
    public static func isLinked(
        username: String,
        urls: [String],
        title: String,
        authenticators: [AuthenticatorIdentity]
    ) -> Bool {
        let hosts = Set(urls.compactMap { SecurityInsightURL.normalizedHost($0) })
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedTitle = SecurityInsightURL.normalizedName(title)

        for authenticator in authenticators {
            let accountName = authenticator.accountName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            // 1) 账号名直接相等（最常见：验证器账号名就是登录账号）。
            if !normalizedUsername.isEmpty, accountName == normalizedUsername {
                return true
            }
            // 2) 账号名形如 "站点:账号"，尾段与登录账号相等。
            if !normalizedUsername.isEmpty,
               let suffix = accountName.split(separator: ":").last.map(String.init),
               suffix.trimmingCharacters(in: .whitespaces) == normalizedUsername {
                return true
            }
            // 3) 账号名是邮箱，且邮箱域名与登录站点相同（或站点是其子域）。
            if let atIndex = accountName.lastIndex(of: "@") {
                let domain = String(accountName[accountName.index(after: atIndex)...])
                if !domain.isEmpty {
                    for host in hosts where host == domain || host.hasSuffix(".\(domain)") {
                        return true
                    }
                }
            }
            // 4) issuer 与登录站点按域名标签相等（"github" 对 "github.com"）。
            let issuerName = SecurityInsightURL.normalizedName(authenticator.issuer)
            if issuerName.count >= 3 {
                for host in hosts where hostMatches(host: host, name: issuerName) {
                    return true
                }
                // 5) issuer 与条目标题完全同名（"GitHub" 对 "GitHub"），标题匹配较弱，要求全等。
                if !normalizedTitle.isEmpty, normalizedTitle == issuerName {
                    return true
                }
            }
        }
        return false
    }

    private static func hostMatches(host: String, name: String) -> Bool {
        guard !host.isEmpty, !name.isEmpty else {
            return false
        }
        let labels = host.split(separator: ".").map(String.init)
        return labels.contains(name) || host == name
    }
}

// MARK: - 分析

public enum SecurityInsightAnalyzer {
    /// “长期未改”的默认阈值（天）。
    public static let defaultStalePasswordDays = 365
    /// 弱密码的最短长度，与 #55 起使用的本地规则保持一致。
    public static let minimumPasswordLength = 12

    /// 本地分析入口：纯函数，无网络、无落盘。
    public static func analyze(
        subjects: [SecurityInsightSubject],
        now: Date,
        stalePasswordDays: Int = defaultStalePasswordDays
    ) -> SecurityInsightReport {
        let thresholdDays = max(1, stalePasswordDays)
        let reuse = reuseFingerprints(in: subjects)
        let reusedFingerprints = Set(reuse.counts.filter { $0.value >= 2 }.keys)
        let duplicateEntryIDs = duplicateEntryIDs(in: subjects)

        var counts: [SecurityInsightIssue: Int] = [:]
        for issue in SecurityInsightIssue.allCases {
            counts[issue] = 0
        }
        var ageDistribution: [SecurityPasswordAgeBucket: Int] = [:]
        for bucket in SecurityPasswordAgeBucket.allCases {
            ageDistribution[bucket] = 0
        }
        var findings: [SecurityInsightFinding] = []

        for subject in subjects {
            let ageDays = passwordAgeDays(
                changedAt: subject.passwordChangedAt,
                now: now
            )
            ageDistribution[SecurityPasswordAgeBucket.bucket(forAgeDays: ageDays), default: 0] += 1

            var issues: [SecurityInsightIssue] = []
            if subject.isMarkedBreached {
                issues.append(.flaggedBreach)
            }
            if isWeakPassword(subject.password) {
                issues.append(.weakPassword)
            }
            if let fingerprint = reuse.bySubjectID[subject.id],
               reusedFingerprints.contains(fingerprint) {
                issues.append(.reusedPassword)
            }
            if !subject.hasLinkedAuthenticator {
                issues.append(.missingTwoFactor)
            }
            if duplicateEntryIDs.contains(subject.id) {
                issues.append(.duplicateEntry)
            }
            if let ageDays, ageDays >= thresholdDays {
                issues.append(.stalePassword)
            }

            guard !issues.isEmpty else {
                continue
            }
            issues.sort { $0.severityRank < $1.severityRank }
            for issue in issues {
                counts[issue, default: 0] += 1
            }
            findings.append(
                SecurityInsightFinding(
                    id: subject.id,
                    title: subject.title,
                    username: subject.username,
                    host: SecurityInsightURL.normalizedHost(subject.url),
                    issues: issues,
                    ageDays: ageDays
                )
            )
        }

        findings.sort { lhs, rhs in
            if lhs.severityRank != rhs.severityRank {
                return lhs.severityRank < rhs.severityRank
            }
            if lhs.issues.count != rhs.issues.count {
                return lhs.issues.count > rhs.issues.count
            }
            if lhs.title != rhs.title {
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            return lhs.id < rhs.id
        }

        let penalties = SecurityInsightIssue.allCases
            .filter { (counts[$0] ?? 0) > 0 }
            .sorted { $0.severityRank < $1.severityRank }
            .map { SecurityInsightPenalty(issue: $0, count: counts[$0] ?? 0) }

        return SecurityInsightReport(
            score: SecurityInsightScoring.score(counts: counts),
            totalItemCount: subjects.count,
            counts: counts,
            penalties: penalties,
            ageDistribution: ageDistribution,
            findings: findings,
            auditedAt: now
        )
    }

    /// 弱密码判定（可解释、可测试）：
    /// 去空白后为空 → 不判定（没有密码可评估）；否则长度 < 12、缺任一字符类别、
    /// 或命中本地常见弱口令表都算弱。
    public static func isWeakPassword(_ password: String) -> Bool {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        if PasswordStrengthAnalyzer.commonPasswords.contains(trimmed.lowercased()) {
            return true
        }
        if trimmed.count < minimumPasswordLength {
            return true
        }
        let classes = characterClassCount(trimmed)
        return classes < 4
    }

    static func characterClassCount(_ password: String) -> Int {
        var count = 0
        if password.contains(where: { $0.isLowercase }) { count += 1 }
        if password.contains(where: { $0.isUppercase }) { count += 1 }
        if password.contains(where: { $0.isNumber }) { count += 1 }
        if password.contains(where: { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }) {
            count += 1
        }
        return count
    }

    /// 当前密码已使用天数；未知或未来时间返回 `nil` / 0。
    public static func passwordAgeDays(changedAt: Date?, now: Date) -> Int? {
        guard let changedAt else {
            return nil
        }
        let interval = now.timeIntervalSince(changedAt)
        guard interval > 0 else {
            return 0
        }
        return Int(interval / 86_400)
    }

    /// 本次审计内的一次性 HMAC 分组：同一个密码得到同一个指纹，
    /// 但指纹无法跨进程复用，也不会落盘，避免留下可离线爆破的密码校验值。
    private struct ReuseFingerprints {
        /// 指纹 → 出现次数。
        var counts: [String: Int] = [:]
        /// 条目 ID → 指纹。
        var bySubjectID: [String: String] = [:]
    }

    private static func reuseFingerprints(in subjects: [SecurityInsightSubject]) -> ReuseFingerprints {
        let key = oneTimeKey()
        var result = ReuseFingerprints()
        for subject in subjects {
            guard let fingerprint = fingerprint(subject.password, key: key) else {
                continue
            }
            result.bySubjectID[subject.id] = fingerprint
            result.counts[fingerprint, default: 0] += 1
        }
        return result
    }

    private struct DuplicateEntryKey: Hashable {
        let title: String
        let username: String
        let url: String
    }

    /// 重复条目：标题 / 账号 / 站点归一化后完全相同才计入。
    /// 同一站点、不同账号是正常的多账号场景，不判为重复。
    private static func duplicateEntryIDs(in subjects: [SecurityInsightSubject]) -> Set<String> {
        var groups: [DuplicateEntryKey: [String]] = [:]
        for subject in subjects where !subject.isIgnoredForDuplicateGrouping {
            let title = normalizedIdentifier(subject.title)
            let username = normalizedIdentifier(subject.username)
            let url = normalizedIdentifier(subject.url)
            guard !title.isEmpty || !username.isEmpty || !url.isEmpty else {
                continue
            }
            groups[DuplicateEntryKey(title: title, username: username, url: url), default: []]
                .append(subject.id)
        }
        var ids: Set<String> = []
        for members in groups.values where members.count >= 2 {
            ids.formUnion(members)
        }
        return ids
    }

    static func normalizedIdentifier(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func oneTimeKey() -> SymmetricKey {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255, using: &generator)
        }
        return SymmetricKey(data: Data(bytes))
    }

    private static func fingerprint(_ password: String, key: SymmetricKey) -> String? {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let mac = HMAC<SHA256>.authenticationCode(for: Data(trimmed.utf8), using: key)
        return Data(mac).base64EncodedString()
    }
}

// MARK: - 趋势

/// 一次审计的按天快照。只保存聚合计数，不保存任何条目信息。
public struct SecurityAuditTrendPoint: Codable, Sendable, Equatable, Identifiable {
    /// `yyyy-MM-dd`（UTC）。
    public let dayKey: String
    public let recordedAt: Date
    public let score: Int
    public let totalItemCount: Int
    /// 分类 rawValue → 命中条目数。
    public let issueCounts: [String: Int]

    public var id: String { dayKey }

    public init(
        dayKey: String,
        recordedAt: Date,
        score: Int,
        totalItemCount: Int,
        issueCounts: [String: Int]
    ) {
        self.dayKey = dayKey
        self.recordedAt = recordedAt
        self.score = score
        self.totalItemCount = totalItemCount
        self.issueCounts = issueCounts
    }

    public init(report: SecurityInsightReport, now: Date, calendar: Calendar = SecurityAuditTrend.utcCalendar) {
        var rawCounts: [String: Int] = [:]
        for issue in SecurityInsightIssue.allCases {
            rawCounts[issue.rawValue] = report.count(for: issue)
        }
        self.init(
            dayKey: SecurityAuditTrend.dayKey(for: now, calendar: calendar),
            recordedAt: now,
            score: report.score,
            totalItemCount: report.totalItemCount,
            issueCounts: rawCounts
        )
    }

    public func count(for issue: SecurityInsightIssue) -> Int {
        issueCounts[issue.rawValue] ?? 0
    }
}

/// 总量趋势：每天最多一个点，保留最近 `maximumPointCount` 天。
public struct SecurityAuditTrend: Codable, Sendable, Equatable {
    public static let maximumPointCount = 30

    /// UTC 日历，保证同一天在不同时区的设备上仍然聚合到同一个点。
    public static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    /// 按天升序排列，最后一个是最新的。
    public private(set) var points: [SecurityAuditTrendPoint]

    public init(points: [SecurityAuditTrendPoint] = []) {
        var byDay: [String: SecurityAuditTrendPoint] = [:]
        for point in points {
            byDay[point.dayKey] = point
        }
        let sorted = byDay.values.sorted { $0.dayKey < $1.dayKey }
        self.points = Array(sorted.suffix(Self.maximumPointCount))
    }

    private enum CodingKeys: String, CodingKey {
        case points
    }

    /// 解码同样走归一化：脏数据里重复的日期或超长历史不会绕过上限。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? container.decode([SecurityAuditTrendPoint].self, forKey: .points)) ?? []
        self.init(points: raw)
    }

    public var isEmpty: Bool { points.isEmpty }
    public var latest: SecurityAuditTrendPoint? { points.last }
    public var earliest: SecurityAuditTrendPoint? { points.first }

    /// 最新分数相对上一个点的变化；不足两个点时为 `nil`。
    public var scoreDelta: Int? {
        guard points.count >= 2 else {
            return nil
        }
        return points[points.count - 1].score - points[points.count - 2].score
    }

    /// 最新条目总量相对上一个点的变化；不足两个点时为 `nil`。
    public var totalItemDelta: Int? {
        guard points.count >= 2 else {
            return nil
        }
        return points[points.count - 1].totalItemCount - points[points.count - 2].totalItemCount
    }

    /// 最新分数相对最早一个点的变化（即整段趋势的变化量）；不足两个点时为 `nil`。
    public var scoreDeltaFromEarliest: Int? {
        guard points.count >= 2 else {
            return nil
        }
        return points[points.count - 1].score - points[0].score
    }

    /// 最新条目总量相对最早一个点的变化；不足两个点时为 `nil`。
    public var totalItemDeltaFromEarliest: Int? {
        guard points.count >= 2 else {
            return nil
        }
        return points[points.count - 1].totalItemCount - points[0].totalItemCount
    }

    /// 记录一个点：同一天覆盖旧值，超过上限丢弃最旧的。
    public mutating func record(_ point: SecurityAuditTrendPoint) {
        self = SecurityAuditTrend(points: points + [point])
    }

    public mutating func removeAll() {
        points = []
    }

    public static func dayKey(for date: Date, calendar: Calendar = SecurityAuditTrend.utcCalendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

// MARK: - 手动泄露标记

/// 手动标记的修订标识（#56）。
///
/// 标记只和“密码是否变过”绑定：用密码历史条数与最近一次改密时间派生标识，
/// 不含任何密码材料。密码一变标识就变，旧标记自动失效，不会继续提示已处理过的问题。
public enum SecurityInsightRevision {
    public static func token(historyCount: Int, latestChangeAt: Date?) -> String {
        let stamp = latestChangeAt.map { Int($0.timeIntervalSince1970) } ?? 0
        return "\(max(0, historyCount)):\(stamp)"
    }

    public static func token(historyCount: Int, latestChangeAt: Date?, extra: String) -> String {
        "\(token(historyCount: historyCount, latestChangeAt: latestChangeAt)):\(extra)"
    }
}

/// 安全分析的本地状态：手动泄露标记 + 趋势。
///
/// 只保存条目 ID、修订标识与聚合计数，不保存密码、密码指纹或条目内容。
public struct SecurityInsightState: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let empty = SecurityInsightState(version: currentVersion, breachMarks: [:], trend: SecurityAuditTrend())

    public var version: Int
    /// 条目 ID → 修订标识。修订不匹配说明密码已变，标记自动失效。
    public var breachMarks: [String: String]
    public var trend: SecurityAuditTrend

    public init(
        version: Int = SecurityInsightState.currentVersion,
        breachMarks: [String: String] = [:],
        trend: SecurityAuditTrend = SecurityAuditTrend()
    ) {
        self.version = version
        self.breachMarks = breachMarks.filter { !$0.key.isEmpty && !$0.value.isEmpty }
        self.trend = trend
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case breachMarks
        case trend
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = (try? container.decode(Int.self, forKey: .version)) ?? Self.currentVersion
        // 未知版本整份回退：宁可丢掉标记与趋势，也不要按猜出来的格式解释用户数据。
        guard version == Self.currentVersion else {
            self = .empty
            return
        }
        let marks = (try? container.decode([String: String].self, forKey: .breachMarks)) ?? [:]
        let trend = (try? container.decode(SecurityAuditTrend.self, forKey: .trend)) ?? SecurityAuditTrend()
        self.init(version: version, breachMarks: marks, trend: trend)
    }

    public func isMarkedBreached(entryID: String, revision: String) -> Bool {
        breachMarks[entryID] == revision
    }

    public mutating func setBreachMark(_ marked: Bool, entryID: String, revision: String) {
        guard !entryID.isEmpty, !revision.isEmpty else {
            return
        }
        if marked {
            breachMarks[entryID] = revision
        } else {
            breachMarks.removeValue(forKey: entryID)
        }
    }

    /// 用当前密码修订清理失效标记（密码已改、条目已删）。
    public mutating func pruneBreachMarks(keeping revisions: [String: String]) {
        breachMarks = breachMarks.filter { entryID, token in
            revisions[entryID] == token
        }
    }

    /// 记录当天审计点（每天最多一个）。
    public mutating func recordAudit(
        _ report: SecurityInsightReport,
        now: Date,
        calendar: Calendar = SecurityAuditTrend.utcCalendar
    ) {
        trend.record(SecurityAuditTrendPoint(report: report, now: now, calendar: calendar))
    }
}

// MARK: - 持久化

public enum SecurityInsightStoreError: Error, Equatable {
    case invalidVaultIdentifier
}

public protocol SecurityInsightPersisting: Sendable {
    func load(vaultID: String) async throws -> SecurityInsightState
    func save(_ state: SecurityInsightState, vaultID: String) async throws
    func remove(vaultID: String) async throws
}

/// 未注入依赖时使用的内存实现：只在当前进程内有效，不落盘。
public final class MemorySecurityInsightStore: SecurityInsightPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String: SecurityInsightState] = [:]

    public init() {}

    public func load(vaultID: String) async throws -> SecurityInsightState {
        synchronized { $0[vaultID] ?? .empty }
    }

    public func save(_ state: SecurityInsightState, vaultID: String) async throws {
        let trimmed = vaultID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SecurityInsightStoreError.invalidVaultIdentifier
        }
        synchronized { $0[trimmed] = state }
    }

    public func remove(vaultID: String) async throws {
        synchronized { $0[vaultID] = nil }
    }

    private func synchronized<T>(_ body: (inout [String: SecurityInsightState]) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&states)
    }
}

/// 把状态写到指定目录的 JSON 文件。
///
/// - 文件名是 `vaultID` 的 SHA-256 前缀，路径里不出现 Vault 标识。
/// - 写入使用原子写 + 完整文件保护（iOS），与生成历史一致。
/// - 内容损坏或版本未知时回退到空状态，不让仪表盘因为脏数据崩溃。
public struct FileSecurityInsightStore: SecurityInsightPersisting {
    public let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public func fileURL(for vaultID: String) throws -> URL {
        let trimmed = vaultID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SecurityInsightStoreError.invalidVaultIdentifier
        }
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directoryURL.appendingPathComponent(
            "insights-\(name.prefix(32)).json",
            isDirectory: false
        )
    }

    public func load(vaultID: String) async throws -> SecurityInsightState {
        let url = try fileURL(for: vaultID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .empty
        }
        guard let data = try? Data(contentsOf: url) else {
            return .empty
        }
        return (try? JSONDecoder().decode(SecurityInsightState.self, from: data)) ?? .empty
    }

    public func save(_ state: SecurityInsightState, vaultID: String) async throws {
        let url = try fileURL(for: vaultID)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        guard state.version == SecurityInsightState.currentVersion else {
            throw SecurityInsightStoreError.invalidVaultIdentifier
        }
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: writingOptions)
    }

    public func remove(vaultID: String) async throws {
        let url = try fileURL(for: vaultID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }

    private var writingOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtection]
        #else
        [.atomic]
        #endif
    }
}
