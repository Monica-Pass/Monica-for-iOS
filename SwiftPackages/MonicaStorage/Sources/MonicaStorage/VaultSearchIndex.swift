import Foundation

// MARK: - 搜索密钥与使用记录

/// 跨类型搜索的稳定标识：`kind + id`。
///
/// 同一条目在索引、结果和最近访问之间始终使用该键，避免仅用 `id` 时
/// 不同类型之间的潜在碰撞。
public struct VaultSearchItemKey: Hashable, Sendable {
    public let kind: UnifiedVaultItemKind
    public let id: String

    public init(kind: UnifiedVaultItemKind, id: String) {
        self.kind = kind
        self.id = id
    }

    public var stableIdentifier: String {
        "\(kind.rawValue):\(id)"
    }
}

/// 最近查看时间与查看次数。
///
/// 这两个值来自解锁会话内已有的操作时间线（`operationTimelineEvents` 的
/// `.viewed` 事件），不新增持久化结构；锁库后随索引一起丢弃。
public struct VaultSearchUsage: Sendable, Equatable {
    public let viewCount: Int
    public let lastViewedAt: Date?

    public init(viewCount: Int = 0, lastViewedAt: Date? = nil) {
        self.viewCount = max(0, viewCount)
        self.lastViewedAt = lastViewedAt
    }
}

// MARK: - 匹配字段

/// 可参与匹配的非敏感元数据字段。
///
/// 密码、TOTP 密钥、私钥、卡号、CVV、证件号、API Token 明文等 secret
/// 字段永远不进入索引，因此也不会出现在匹配字段中。
public enum VaultSearchMatchField: String, Sendable, Hashable, CaseIterable {
    case title
    case username
    case url
    case tags
    case details
    case notes

    /// UI 展示顺序：越靠前越能说明“为什么命中”。
    public static let displayOrder: [VaultSearchMatchField] = [
        .title,
        .username,
        .url,
        .tags,
        .details,
        .notes
    ]

    public var displayName: String {
        switch self {
        case .title:
            return "标题"
        case .username:
            return "账号"
        case .url:
            return "网址"
        case .tags:
            return "标签"
        case .details:
            return "其他信息"
        case .notes:
            return "备注"
        }
    }
}

public struct VaultSearchMatch: Sendable, Equatable, Hashable {
    public let field: VaultSearchMatchField
    public let snippet: String

    public init(field: VaultSearchMatchField, snippet: String) {
        self.field = field
        self.snippet = snippet
    }
}

// MARK: - 文档与结果

/// 索引中的一条非敏感投影。
///
/// 注意：本结构`没有`密码 / TOTP secret / 私钥 / 卡号 / CVV / 证件号 /
/// API Token / Wi-Fi 密码 / Send 正文等字段，构造时源数据里这些值直接丢弃。
public struct VaultSearchDocument: Sendable, Equatable, Identifiable {
    public let kind: UnifiedVaultItemKind
    public let id: String
    public let projectID: String
    public let title: String
    public let username: String
    public let url: String
    public let details: String
    public let notes: String
    public let tags: [String]
    public let isFavorite: Bool
    public let isDeleted: Bool
    public let isArchived: Bool
    public var lastViewedAt: Date?
    public var viewCount: Int

    public init(
        kind: UnifiedVaultItemKind,
        id: String,
        projectID: String,
        title: String,
        username: String = "",
        url: String = "",
        details: String = "",
        notes: String = "",
        tags: [String] = [],
        isFavorite: Bool = false,
        isDeleted: Bool = false,
        isArchived: Bool = false,
        lastViewedAt: Date? = nil,
        viewCount: Int = 0
    ) {
        self.kind = kind
        self.id = id
        self.projectID = projectID
        self.title = title
        self.username = username
        self.url = url
        self.details = details
        self.notes = notes
        self.tags = tags
        self.isFavorite = isFavorite
        self.isDeleted = isDeleted
        self.isArchived = isArchived
        self.lastViewedAt = lastViewedAt
        self.viewCount = max(0, viewCount)
    }

    /// `Identifiable` 只要求 id；跨类型唯一定位请使用 `itemKey`。
    public var itemKey: VaultSearchItemKey {
        VaultSearchItemKey(kind: kind, id: id)
    }

    public var stableIdentifier: String {
        itemKey.stableIdentifier
    }
}

public struct VaultSearchResult: Sendable, Equatable, Identifiable {
    public let kind: UnifiedVaultItemKind
    public let id: String
    public let projectID: String
    public let title: String
    public let subtitle: String
    public let isFavorite: Bool
    public let isDeleted: Bool
    public let isArchived: Bool
    public let matches: [VaultSearchMatch]
    public let lastViewedAt: Date?
    public let viewCount: Int
    /// 相关度分数；按最近使用排序时仅用于稳定 tie-break。
    public let score: Double

    public init(
        kind: UnifiedVaultItemKind,
        id: String,
        projectID: String,
        title: String,
        subtitle: String,
        isFavorite: Bool,
        isDeleted: Bool,
        isArchived: Bool,
        matches: [VaultSearchMatch],
        lastViewedAt: Date?,
        viewCount: Int,
        score: Double
    ) {
        self.kind = kind
        self.id = id
        self.projectID = projectID
        self.title = title
        self.subtitle = subtitle
        self.isFavorite = isFavorite
        self.isDeleted = isDeleted
        self.isArchived = isArchived
        self.matches = matches
        self.lastViewedAt = lastViewedAt
        self.viewCount = viewCount
        self.score = score
    }

    public var itemKey: VaultSearchItemKey {
        VaultSearchItemKey(kind: kind, id: id)
    }

    public var stableIdentifier: String {
        itemKey.stableIdentifier
    }

    public var primaryMatchField: VaultSearchMatchField? {
        matches.first?.field
    }
}

/// 一次搜索的完整返回。
///
/// - `results`：非空查询的命中列表；空查询时为“最近 + 常用”的合并列表。
/// - `recent` / `frequent`：空查询时的最近访问与常用列表（两者不重叠）。
public struct VaultSearchResults: Sendable, Equatable {
    public let query: String
    public let results: [VaultSearchResult]
    public let recent: [VaultSearchResult]
    public let frequent: [VaultSearchResult]
    public let totalMatchCount: Int

    public init(
        query: String,
        results: [VaultSearchResult],
        recent: [VaultSearchResult] = [],
        frequent: [VaultSearchResult] = [],
        totalMatchCount: Int? = nil
    ) {
        self.query = query
        self.results = results
        self.recent = recent
        self.frequent = frequent
        self.totalMatchCount = totalMatchCount ?? results.count
    }

    public static let empty = VaultSearchResults(query: "", results: [])

    public var isEmpty: Bool {
        results.isEmpty && recent.isEmpty && frequent.isEmpty
    }

    public var truncated: Bool {
        totalMatchCount > results.count
    }
}

// MARK: - 过滤与排序

public enum VaultSearchSort: String, Sendable, Equatable, CaseIterable {
    case relevance
    case recentlyUsed

    public var displayName: String {
        switch self {
        case .relevance:
            return "相关度"
        case .recentlyUsed:
            return "最近使用"
        }
    }
}

public struct VaultSearchFilters: Sendable, Equatable {
    /// 空集合表示全部类型。
    public var kinds: Set<UnifiedVaultItemKind>
    /// 空集合表示全部保险箱 / 分类。
    public var projectIDs: Set<String>
    /// 空集合表示不按标签过滤。
    public var tags: Set<String>
    public var favoritesOnly: Bool
    public var includeDeleted: Bool
    public var includeArchived: Bool
    public var sort: VaultSearchSort

    public init(
        kinds: Set<UnifiedVaultItemKind> = [],
        projectIDs: Set<String> = [],
        tags: Set<String> = [],
        favoritesOnly: Bool = false,
        includeDeleted: Bool = false,
        includeArchived: Bool = false,
        sort: VaultSearchSort = .relevance
    ) {
        self.kinds = kinds
        self.projectIDs = projectIDs
        self.tags = tags
        self.favoritesOnly = favoritesOnly
        self.includeDeleted = includeDeleted
        self.includeArchived = includeArchived
        self.sort = sort
    }
}

public enum VaultSearchDefaults {
    public static let resultLimit = 50
    public static let usageListLimit = 10
    /// 单次查询的最大字符数，防止异常输入拖垮匹配。
    public static let maximumQueryLength = 200
}

// MARK: - 索引

/// 解锁会话内存中的跨类型搜索索引。
///
/// 该类型是纯值类型、无任何持久化入口；调用方负责在锁库时丢弃实例
/// （`VaultSearchSession.lock()`），因此明文元数据不会落盘。
public struct VaultSearchIndex: Sendable, Equatable {
    public let documents: [VaultSearchDocument]

    public init(documents: [VaultSearchDocument] = []) {
        var seen = Set<VaultSearchItemKey>()
        self.documents = documents.filter { document in
            seen.insert(document.itemKey).inserted
        }
    }

    public func search(
        _ rawQuery: String,
        filters: VaultSearchFilters = VaultSearchFilters(),
        limit: Int = VaultSearchDefaults.resultLimit
    ) -> VaultSearchResults {
        search(rawQuery, filters: filters, limit: limit, cancellationCheck: {})
    }

    /// 同步搜索。`cancellationCheck` 会定期调用（含进入时一次），
    /// 用于把任务取消 / 索引代次失效传播到调用方。
    public func search(
        _ rawQuery: String,
        filters: VaultSearchFilters,
        limit: Int,
        cancellationCheck: () throws -> Void
    ) rethrows -> VaultSearchResults {
        try cancellationCheck()
        let query = Self.sanitized(rawQuery)
        let candidates = documents.filter { filters.matches($0) }
        let cappedLimit = max(0, limit)

        guard !query.tokens.isEmpty else {
            return Self.usageResults(
                query: query.display,
                documents: candidates,
                limit: cappedLimit
            )
        }

        var scored: [(document: VaultSearchDocument, score: Double, matches: [VaultSearchMatch])] = []
        for (index, document) in candidates.enumerated() {
            if index.isMultiple(of: 32) {
                try cancellationCheck()
            }
            guard let evaluation = Self.evaluate(document, tokens: query.tokens) else {
                continue
            }
            scored.append((document, evaluation.score, evaluation.matches))
        }
        try cancellationCheck()

        switch filters.sort {
        case .relevance:
            scored.sort { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return Self.isOrderedBefore(lhs.document, rhs.document)
            }
        case .recentlyUsed:
            scored.sort { lhs, rhs in
                let lhsDate = lhs.document.lastViewedAt ?? .distantPast
                let rhsDate = rhs.document.lastViewedAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                if lhs.document.viewCount != rhs.document.viewCount {
                    return lhs.document.viewCount > rhs.document.viewCount
                }
                return Self.isOrderedBefore(lhs.document, rhs.document)
            }
        }

        let results = scored.prefix(cappedLimit).map { entry in
            Self.makeResult(document: entry.document, matches: entry.matches, score: entry.score)
        }
        return VaultSearchResults(
            query: query.display,
            results: Array(results),
            totalMatchCount: scored.count
        )
    }

    // MARK: 空查询

    private static func usageResults(
        query: String,
        documents: [VaultSearchDocument],
        limit: Int
    ) -> VaultSearchResults {
        let usageLimit = max(1, min(limit, VaultSearchDefaults.usageListLimit))
        let viewed = documents
            .filter { $0.lastViewedAt != nil }
            .sorted { lhs, rhs in
                let lhsDate = lhs.lastViewedAt ?? .distantPast
                let rhsDate = rhs.lastViewedAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return isOrderedBefore(lhs, rhs)
            }
        let recentDocuments = Array(viewed.prefix(usageLimit))

        // “常用”按查看次数排序，允许与“最近”重叠；合并列表里再去重，
        // 这样最常用的条目不会因为刚看过而消失。
        let frequentDocuments = documents
            .filter { $0.viewCount > 0 }
            .sorted { lhs, rhs in
                if lhs.viewCount != rhs.viewCount { return lhs.viewCount > rhs.viewCount }
                let lhsDate = lhs.lastViewedAt ?? .distantPast
                let rhsDate = rhs.lastViewedAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return isOrderedBefore(lhs, rhs)
            }
            .prefix(usageLimit)

        let recent = recentDocuments.map { makeResult(document: $0, matches: [], score: 0) }
        let frequent = frequentDocuments.map { makeResult(document: $0, matches: [], score: 0) }
        var seen = Set<VaultSearchItemKey>()
        let merged = (recent + frequent)
            .filter { seen.insert($0.itemKey).inserted }
            .prefix(limit)
        return VaultSearchResults(
            query: query,
            results: Array(merged),
            recent: recent,
            frequent: frequent,
            totalMatchCount: merged.count
        )
    }

    // MARK: 匹配

    private struct Evaluation {
        let score: Double
        let matches: [VaultSearchMatch]
    }

    private static func evaluate(
        _ document: VaultSearchDocument,
        tokens: [String]
    ) -> Evaluation? {
        var totalScore = 0.0
        var matchedFields = Set<VaultSearchMatchField>()

        for token in tokens {
            var tokenBest = 0.0
            var tokenMatched = false

            if let score = fieldScore(document.title, token: token, exact: 120, prefix: 95, contains: 70) {
                tokenBest = max(tokenBest, score)
                matchedFields.insert(.title)
                tokenMatched = true
            }
            if let score = fieldScore(document.username, token: token, exact: 85, prefix: 68, contains: 48) {
                tokenBest = max(tokenBest, score)
                matchedFields.insert(.username)
                tokenMatched = true
            }
            if let score = urlScore(document.url, token: token) {
                tokenBest = max(tokenBest, score)
                matchedFields.insert(.url)
                tokenMatched = true
            }
            if document.tags.contains(where: { normalize($0) == token }) {
                tokenBest = max(tokenBest, 65)
                matchedFields.insert(.tags)
                tokenMatched = true
            } else if document.tags.contains(where: { normalize($0).contains(token) }) {
                tokenBest = max(tokenBest, 45)
                matchedFields.insert(.tags)
                tokenMatched = true
            }
            if let score = fieldScore(document.details, token: token, exact: 55, prefix: 40, contains: 28) {
                tokenBest = max(tokenBest, score)
                matchedFields.insert(.details)
                tokenMatched = true
            }
            if let score = fieldScore(document.notes, token: token, exact: 40, prefix: 30, contains: 18) {
                tokenBest = max(tokenBest, score)
                matchedFields.insert(.notes)
                tokenMatched = true
            }

            guard tokenMatched else { return nil }
            totalScore += tokenBest
        }

        var matches = matchedFields
            .sorted { lhs, rhs in
                let lhsIndex = VaultSearchMatchField.displayOrder.firstIndex(of: lhs) ?? 0
                let rhsIndex = VaultSearchMatchField.displayOrder.firstIndex(of: rhs) ?? 0
                return lhsIndex < rhsIndex
            }
            .map { field in
                VaultSearchMatch(
                    field: field,
                    snippet: snippet(for: field, document: document, tokens: tokens)
                )
            }
        if matches.isEmpty {
            matches = [VaultSearchMatch(field: .title, snippet: document.title)]
        }

        if document.isFavorite {
            totalScore += 5
        }
        return Evaluation(score: totalScore, matches: matches)
    }

    private static func fieldScore(
        _ value: String,
        token: String,
        exact: Double,
        prefix: Double,
        contains: Double
    ) -> Double? {
        guard !value.isEmpty else { return nil }
        let normalized = normalize(value)
        guard !normalized.isEmpty else { return nil }
        if normalized == token { return exact }
        if normalized.hasPrefix(token) { return prefix }
        if normalized.contains(token) { return contains }
        return nil
    }

    private static func urlScore(_ rawURL: String, token: String) -> Double? {
        guard !rawURL.isEmpty else { return nil }
        var best = fieldScore(rawURL, token: token, exact: 55, prefix: 45, contains: 32)
        let host = normalizedHost(rawURL)
        if !host.isEmpty {
            if host == token {
                best = max(best ?? 0, 90)
            } else if host.hasPrefix(token) {
                best = max(best ?? 0, 72)
            } else if host.contains(token) {
                best = max(best ?? 0, 52)
            }
        }
        return best
    }

    private static func normalizedHost(_ rawURL: String) -> String {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var host = trimmed
        if let schemeRange = host.range(of: "://") {
            host = String(host[schemeRange.upperBound...])
        }
        if let slash = host.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            host = String(host[..<slash])
        }
        if let at = host.lastIndex(of: "@") {
            host = String(host[host.index(after: at)...])
        }
        if let colon = host.firstIndex(of: ":") {
            host = String(host[..<colon])
        }
        host = normalize(host)
        if host.hasPrefix("www.") {
            host = String(host.dropFirst(4))
        }
        return host
    }

    private static func snippet(
        for field: VaultSearchMatchField,
        document: VaultSearchDocument,
        tokens: [String]
    ) -> String {
        let value: String
        switch field {
        case .title:
            value = document.title
        case .username:
            value = document.username
        case .url:
            value = document.url
        case .tags:
            value = document.tags.joined(separator: "、")
        case .details:
            value = document.details
        case .notes:
            value = document.notes
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return document.title }
        guard let token = tokens.first(where: { !$0.isEmpty }) else {
            return String(trimmed.prefix(80))
        }
        if let range = trimmed.range(
            of: token,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) {
            let start = trimmed.index(range.lowerBound, offsetBy: -24, limitedBy: trimmed.startIndex)
                ?? trimmed.startIndex
            let end = trimmed.index(range.upperBound, offsetBy: 56, limitedBy: trimmed.endIndex)
                ?? trimmed.endIndex
            var excerpt = String(trimmed[start..<end])
            if start != trimmed.startIndex { excerpt = "…" + excerpt }
            if end != trimmed.endIndex { excerpt += "…" }
            return excerpt
        }
        return String(trimmed.prefix(80))
    }

    private static func makeResult(
        document: VaultSearchDocument,
        matches: [VaultSearchMatch],
        score: Double
    ) -> VaultSearchResult {
        VaultSearchResult(
            kind: document.kind,
            id: document.id,
            projectID: document.projectID,
            title: document.title.isEmpty ? document.kind.displayName : document.title,
            subtitle: subtitle(for: document),
            isFavorite: document.isFavorite,
            isDeleted: document.isDeleted,
            isArchived: document.isArchived,
            matches: matches,
            lastViewedAt: document.lastViewedAt,
            viewCount: document.viewCount,
            score: score
        )
    }

    private static func subtitle(for document: VaultSearchDocument) -> String {
        if !document.username.isEmpty {
            return document.username
        }
        if !document.url.isEmpty {
            let host = normalizedHost(document.url)
            return host.isEmpty ? document.url : host
        }
        if !document.tags.isEmpty {
            return document.tags.joined(separator: "、")
        }
        return document.details
    }

    /// 稳定 tie-break：标题 → 类型 → id，保证相同分数下顺序可复现。
    private static func isOrderedBefore(
        _ lhs: VaultSearchDocument,
        _ rhs: VaultSearchDocument
    ) -> Bool {
        let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        return lhs.id < rhs.id
    }

    // MARK: 规范化

    struct SanitizedQuery {
        let display: String
        let tokens: [String]
    }

    static func sanitized(_ rawQuery: String) -> SanitizedQuery {
        let collapsed = rawQuery
            .unicodeScalars
            .prefix(VaultSearchDefaults.maximumQueryLength)
            .map { scalar -> Character in
                if CharacterSet.controlCharacters.contains(scalar) {
                    return " "
                }
                return Character(scalar)
            }
        let display = String(collapsed)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = display
            .split(whereSeparator: { $0.isWhitespace })
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }
        return SanitizedQuery(display: display, tokens: tokens)
    }

    static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension VaultSearchFilters {
    func matches(_ document: VaultSearchDocument) -> Bool {
        if !kinds.isEmpty && !kinds.contains(document.kind) { return false }
        if !projectIDs.isEmpty && !projectIDs.contains(document.projectID) { return false }
        if !tags.isEmpty {
            let normalizedTags = Set(document.tags.map(VaultSearchIndex.normalize))
            let normalizedFilter = Set(tags.map(VaultSearchIndex.normalize))
            if normalizedTags.isDisjoint(with: normalizedFilter) { return false }
        }
        if favoritesOnly && !document.isFavorite { return false }
        if !includeDeleted && document.isDeleted { return false }
        if !includeArchived && document.isArchived { return false }
        return true
    }
}

// MARK: - 索引快照与构造

/// 从现有条目模型构造索引的输入快照。
///
/// 只保存非敏感元数据；调用方把会话里已有的本地条目数组填进来即可，
/// 不需要新增持久化结构。
public struct VaultSearchEntrySnapshot: Sendable, Equatable {
    public var loginEntries: [LocalLoginEntry] = []
    public var deletedLoginEntries: [LocalLoginEntry] = []
    public var noteEntries: [LocalNoteEntry] = []
    public var deletedNoteEntries: [LocalNoteEntry] = []
    public var totpEntries: [LocalTotpEntry] = []
    public var deletedTotpEntries: [LocalTotpEntry] = []
    public var cardEntries: [LocalCardEntry] = []
    public var deletedCardEntries: [LocalCardEntry] = []
    public var identityEntries: [LocalIdentityEntry] = []
    public var deletedIdentityEntries: [LocalIdentityEntry] = []
    public var passkeyEntries: [LocalPasskeyEntry] = []
    public var deletedPasskeyEntries: [LocalPasskeyEntry] = []
    public var sshKeyEntries: [LocalSshKeyEntry] = []
    public var deletedSshKeyEntries: [LocalSshKeyEntry] = []
    public var apiTokenEntries: [LocalApiTokenEntry] = []
    public var deletedApiTokenEntries: [LocalApiTokenEntry] = []
    public var wifiEntries: [LocalWifiEntry] = []
    public var deletedWifiEntries: [LocalWifiEntry] = []
    public var sendEntries: [LocalSendEntry] = []
    public var deletedSendEntries: [LocalSendEntry] = []
    public var attachmentEntries: [LocalAttachmentMetadata] = []
    public var deletedAttachmentEntries: [LocalAttachmentMetadata] = []

    public init() {}
}

public enum VaultSearchDocumentBuilder {
    /// 把条目快照投影为索引文档。
    ///
    /// - Parameter usage: 可选的最近查看 / 查看次数，通常来自操作时间线。
    public static func documents(
        from snapshot: VaultSearchEntrySnapshot,
        usage: [VaultSearchItemKey: VaultSearchUsage] = [:]
    ) -> [VaultSearchDocument] {
        var documents: [VaultSearchDocument] = []
        documents.reserveCapacity(
            snapshot.loginEntries.count + snapshot.noteEntries.count
                + snapshot.totpEntries.count + snapshot.cardEntries.count
                + snapshot.passkeyEntries.count + snapshot.identityEntries.count
        )

        append(
            documents: &documents,
            entries: snapshot.loginEntries,
            deleted: snapshot.deletedLoginEntries,
            usage: usage,
            make: loginDocument
        )
        append(
            documents: &documents,
            entries: snapshot.noteEntries,
            deleted: snapshot.deletedNoteEntries,
            usage: usage,
            make: noteDocument
        )
        append(
            documents: &documents,
            entries: snapshot.totpEntries,
            deleted: snapshot.deletedTotpEntries,
            usage: usage,
            make: totpDocument
        )
        append(
            documents: &documents,
            entries: snapshot.cardEntries,
            deleted: snapshot.deletedCardEntries,
            usage: usage,
            make: cardDocument
        )
        append(
            documents: &documents,
            entries: snapshot.identityEntries,
            deleted: snapshot.deletedIdentityEntries,
            usage: usage,
            make: identityDocument
        )
        append(
            documents: &documents,
            entries: snapshot.passkeyEntries,
            deleted: snapshot.deletedPasskeyEntries,
            usage: usage,
            make: passkeyDocument
        )
        append(
            documents: &documents,
            entries: snapshot.sshKeyEntries,
            deleted: snapshot.deletedSshKeyEntries,
            usage: usage,
            make: sshKeyDocument
        )
        append(
            documents: &documents,
            entries: snapshot.apiTokenEntries,
            deleted: snapshot.deletedApiTokenEntries,
            usage: usage,
            make: apiTokenDocument
        )
        append(
            documents: &documents,
            entries: snapshot.wifiEntries,
            deleted: snapshot.deletedWifiEntries,
            usage: usage,
            make: wifiDocument
        )
        append(
            documents: &documents,
            entries: snapshot.sendEntries,
            deleted: snapshot.deletedSendEntries,
            usage: usage,
            make: sendDocument
        )
        append(
            documents: &documents,
            entries: snapshot.attachmentEntries,
            deleted: snapshot.deletedAttachmentEntries,
            usage: usage,
            make: attachmentDocument
        )
        return documents
    }

    private static func append<Entry>(
        documents: inout [VaultSearchDocument],
        entries: [Entry],
        deleted: [Entry],
        usage: [VaultSearchItemKey: VaultSearchUsage],
        make: (Entry, Bool) -> VaultSearchDocument
    ) {
        for entry in entries {
            append(documents: &documents, document: make(entry, false), usage: usage)
        }
        for entry in deleted {
            append(documents: &documents, document: make(entry, true), usage: usage)
        }
    }

    private static func append(
        documents: inout [VaultSearchDocument],
        document: VaultSearchDocument,
        usage: [VaultSearchItemKey: VaultSearchUsage]
    ) {
        var document = document
        if let record = usage[document.itemKey] {
            document.lastViewedAt = record.lastViewedAt
            document.viewCount = max(document.viewCount, record.viewCount)
        }
        documents.append(document)
    }

    private static func loginDocument(_ entry: LocalLoginEntry, deleted: Bool) -> VaultSearchDocument {
        VaultSearchDocument(
            kind: .login,
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            username: entry.username,
            url: entry.url,
            notes: entry.notes,
            isFavorite: entry.favorite,
            isDeleted: deleted
        )
    }

    private static func noteDocument(_ entry: LocalNoteEntry, deleted: Bool) -> VaultSearchDocument {
        VaultSearchDocument(
            kind: .note,
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            notes: entry.body,
            isFavorite: entry.favorite,
            isDeleted: deleted
        )
    }

    private static func totpDocument(_ entry: LocalTotpEntry, deleted: Bool) -> VaultSearchDocument {
        VaultSearchDocument(
            kind: .totp,
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            username: entry.accountName,
            details: entry.issuer,
            isFavorite: entry.favorite,
            isDeleted: deleted
        )
    }

    private static func cardDocument(_ entry: LocalCardEntry, deleted: Bool) -> VaultSearchDocument {
        VaultSearchDocument(
            kind: .card,
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            username: entry.cardholderName,
            details: joined(entry.issuer, entry.network),
            notes: entry.notes,
            isFavorite: entry.favorite,
            isDeleted: deleted
        )
    }

    private static func identityDocument(_ entry: LocalIdentityEntry, deleted: Bool) -> VaultSearchDocument {
        VaultSearchDocument(
            kind: .identity,
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            username: entry.fullName,
            details: joined(entry.documentType, entry.issuer, entry.country),
            notes: entry.notes,
            isFavorite: entry.favorite,
            isDeleted: deleted
        )
    }

    private static func passkeyDocument(_ entry: LocalPasskeyEntry, deleted: Bool) -> VaultSearchDocument {
        VaultSearchDocument(
            kind: .passkey,
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            username: entry.username,
            url: entry.relyingPartyID,
            notes: entry.notes,
            isFavorite: entry.favorite,
            isDeleted: deleted
        )
    }

    private static func sshKeyDocument(_ entry: LocalSshKeyEntry, deleted: Bool) -> VaultSearchDocument {
        VaultSearchDocument(
            kind: .sshKey,
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            username: entry.username,
            url: entry.host,
            notes: entry.notes,
            isFavorite: entry.favorite,
            isDeleted: deleted
        )
    }

    private static func apiTokenDocument(_ entry: LocalApiTokenEntry, deleted: Bool) -> VaultSearchDocument {
        VaultSearchDocument(
            kind: .apiToken,
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            username: entry.accountName,
            details: joined(entry.issuer, entry.scopes),
            notes: entry.notes,
            isFavorite: entry.favorite,
            isDeleted: deleted
        )
    }

    private static func wifiDocument(_ entry: LocalWifiEntry, deleted: Bool) -> VaultSearchDocument {
        VaultSearchDocument(
            kind: .wifi,
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            username: entry.ssid,
            details: entry.securityType,
            notes: entry.notes,
            isFavorite: entry.favorite,
            isDeleted: deleted
        )
    }

    private static func sendDocument(_ entry: LocalSendEntry, deleted: Bool) -> VaultSearchDocument {
        VaultSearchDocument(
            kind: .send,
            id: entry.id,
            projectID: entry.projectID,
            title: entry.title,
            notes: entry.notes,
            isFavorite: entry.favorite,
            isDeleted: deleted
        )
    }

    private static func attachmentDocument(
        _ entry: LocalAttachmentMetadata,
        deleted: Bool
    ) -> VaultSearchDocument {
        VaultSearchDocument(
            kind: .attachmentRef,
            id: entry.id,
            projectID: entry.projectID,
            title: entry.fileName,
            details: joined(entry.mediaType, entry.storageMode, entry.downloadState),
            isDeleted: deleted || entry.deleted
        )
    }

    private static func joined(_ values: String...) -> String {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

// MARK: - 会话级搜索（取消 + 锁库清除）

public enum VaultSearchError: Error, Equatable, Sendable {
    /// 搜索发起后索引已更新或已锁库，旧结果被拒绝，避免覆盖新结果。
    case superseded
}

/// 解锁会话内的搜索持有者，负责：
/// - 内存索引（锁库即清空，不落盘）；
/// - 代次（generation）取消语义：新查询会让旧查询在下一个检查点失败；
/// - 最近查看 / 查看次数记录的即时更新。
public final class VaultSearchSession: Sendable {
    private struct State: Sendable {
        var documents: [VaultSearchDocument] = []
        var generation: Int = 0
        var isLocked: Bool = false
    }

    private let box: LockedBox<State>

    public init(
        documents: [VaultSearchDocument] = [],
        isLocked: Bool = false
    ) {
        var state = State()
        state.documents = documents
        state.isLocked = isLocked
        box = LockedBox(state)
    }

    public var isLocked: Bool {
        box.withLock { $0.isLocked }
    }

    public var documentCount: Int {
        box.withLock { $0.documents.count }
    }

    public var currentGeneration: Int {
        box.withLock { $0.generation }
    }

    /// 当前索引中出现的标签（去重、排序）；无标签功能时为空。
    public var availableTags: [String] {
        box.withLock { state in
            var tags = Set<String>()
            for document in state.documents {
                tags.formUnion(document.tags)
            }
            return tags.sorted { lhs, rhs in
                lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
        }
    }

    /// 用最新快照替换索引；同时让进行中的旧搜索失效。
    public func replaceDocuments(_ documents: [VaultSearchDocument]) {
        box.withLock { state in
            state.documents = Self.deduplicated(documents)
            state.isLocked = false
            state.generation += 1
        }
    }

    /// 锁库：清空全部内存元数据并让进行中的搜索失效。
    public func lock() {
        box.withLock { state in
            state.documents = []
            state.isLocked = true
            state.generation += 1
        }
    }

    /// 申请一个新搜索代次；UI 每次输入变化调用一次。
    @discardableResult
    public func nextSearchGeneration() -> Int {
        box.withLock { state in
            state.generation += 1
            return state.generation
        }
    }

    /// 记录一次查看，立即反映到“最近访问 / 常用”。
    public func recordView(_ key: VaultSearchItemKey, at date: Date = Date()) {
        box.withLock { state in
            guard !state.isLocked,
                  let index = state.documents.firstIndex(where: { $0.itemKey == key })
            else {
                return
            }
            var document = state.documents[index]
            if let existing = document.lastViewedAt {
                document.lastViewedAt = max(existing, date)
            } else {
                document.lastViewedAt = date
            }
            document.viewCount += 1
            state.documents[index] = document
        }
    }

    /// 执行一次可取消的搜索。
    ///
    /// - Parameter generation: `nil` 时以进入搜索时的代次为准；旧代次的搜索会在
    ///   检查点抛出 `VaultSearchError.superseded`，调用方应忽略该结果。
    public func search(
        _ rawQuery: String,
        filters: VaultSearchFilters = VaultSearchFilters(),
        limit: Int = VaultSearchDefaults.resultLimit,
        generation: Int? = nil
    ) async throws -> VaultSearchResults {
        try Task.checkCancellation()

        let snapshot = box.withLock { state -> (documents: [VaultSearchDocument], isLocked: Bool, generation: Int) in
            (state.documents, state.isLocked, state.generation)
        }
        let expectedGeneration = generation ?? snapshot.generation

        guard !snapshot.isLocked else {
            return VaultSearchResults(query: VaultSearchIndex.sanitized(rawQuery).display, results: [])
        }
        guard snapshot.generation == expectedGeneration else {
            throw VaultSearchError.superseded
        }

        let index = VaultSearchIndex(documents: snapshot.documents)
        return try index.search(rawQuery, filters: filters, limit: limit) {
            try Task.checkCancellation()
            let current = box.withLock { $0.generation }
            if current != expectedGeneration {
                throw VaultSearchError.superseded
            }
        }
    }

    private static func deduplicated(_ documents: [VaultSearchDocument]) -> [VaultSearchDocument] {
        var seen = Set<VaultSearchItemKey>()
        return documents.filter { seen.insert($0.itemKey).inserted }
    }
}

/// `NSLock` 保护的状态盒；用于 Swift 6 严格并发下的会话级索引。
private final class LockedBox<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    init(_ state: State) {
        self.state = state
    }

    func withLock<Result>(_ body: (inout State) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}
