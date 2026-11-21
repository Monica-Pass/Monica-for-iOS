//
//  ItemIconPreferences.swift
//  MonicaCore
//
//  Issue #149：条目图标全局体系。
//  - 全局「显示条目图标」开关 + 分页面开关（密码 / 验证码 / 通行密钥）。
//  - 未匹配策略：默认图标 / 首字母 / 隐藏。
//  - 来源优先级：内置目录 > SF Symbol > 首字母，可上下调整。
//
//  这里只放纯模型与解析器：不依赖 SwiftUI、不读写 UserDefaults，
//  也**不发起任何网络请求**（不做 favicon 抓取，全部本地匹配）。
//  既有 `ItemIcon` 的 `sf:` / `catalog:` 编解码保持不变，本文件只读取它。
//

import CoreGraphics
import Foundation

// MARK: - 页面

/// 条目图标作用的列表页面。rawValue 是稳定持久化 ID，不含展示文案。
public enum ItemIconPage: String, CaseIterable, Sendable, Codable, Hashable, Identifiable {
    case password
    case totp
    case passkey

    public var id: String { rawValue }
}

// MARK: - 未匹配策略

/// 所有来源都没命中时如何渲染。
///
/// 取值对应 Android `UnmatchedIconHandlingStrategy`，但 iOS 默认是「首字母」。
public enum ItemIconUnmatchedPolicy: String, CaseIterable, Sendable, Codable, Hashable, Identifiable {
    case defaultIcon = "default_icon"
    case firstLetter = "first_letter"
    case hidden

    public var id: String { rawValue }
}

// MARK: - 来源

/// 图标来源。rawValue 是稳定持久化 ID，数组顺序就是优先级。
public enum ItemIconSource: String, CaseIterable, Sendable, Codable, Hashable, Identifiable {
    /// 内置目录：域名 / 标题命中内置目录（github、银行、邮箱……）。
    case catalog
    /// SF Symbol：条目显式选择的符号，或页面级的自动符号（如通行密钥的服务商图标）。
    case symbol
    /// 首字母：兜底槽位，按未匹配策略渲染（首字母 / 默认图标 / 隐藏占位）。
    case firstLetter = "first_letter"

    public var id: String { rawValue }

    /// 默认优先级：内置目录 > SF Symbol > 首字母。
    public static let defaultPriority: [ItemIconSource] = [.catalog, .symbol, .firstLetter]
}

// MARK: - 偏好

/// 版本化的条目图标偏好（#149）。
///
/// 与 `VaultLayoutPreferences` 一样是独立 schema：只存稳定 ID，
/// 与保险库数据完全分离（UserDefaults），不随备份 / 恢复 / 同步迁移。
public struct ItemIconPreferences: Sendable, Codable, Equatable {
    public static let currentVersion = 1

    public static let `default` = ItemIconPreferences()

    /// schema 版本；未知版本整份回退默认值，不猜测新格式。
    public var version: Int
    /// 全局「显示条目图标」总开关，默认开启。
    public var isEnabled: Bool
    /// 密码页开关，默认开启。
    public var showsPasswordPageIcons: Bool
    /// 验证码页开关，默认开启。
    public var showsTotpPageIcons: Bool
    /// 通行密钥页开关，默认开启。
    public var showsPasskeyPageIcons: Bool
    /// 未匹配策略，默认首字母。
    public var unmatchedPolicy: ItemIconUnmatchedPolicy
    /// 来源优先级，默认 `ItemIconSource.defaultPriority`。
    public var sourcePriority: [ItemIconSource]

    public init(
        version: Int = Self.currentVersion,
        isEnabled: Bool = true,
        showsPasswordPageIcons: Bool = true,
        showsTotpPageIcons: Bool = true,
        showsPasskeyPageIcons: Bool = true,
        unmatchedPolicy: ItemIconUnmatchedPolicy = .firstLetter,
        sourcePriority: [ItemIconSource] = ItemIconSource.defaultPriority
    ) {
        self.version = version
        self.isEnabled = isEnabled
        self.showsPasswordPageIcons = showsPasswordPageIcons
        self.showsTotpPageIcons = showsTotpPageIcons
        self.showsPasskeyPageIcons = showsPasskeyPageIcons
        self.unmatchedPolicy = unmatchedPolicy
        self.sourcePriority = sourcePriority
        normalize()
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case version
        case isEnabled
        case showsPasswordPageIcons
        case showsTotpPageIcons
        case showsPasskeyPageIcons
        case unmatchedPolicy
        case sourcePriority
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 老配置缺字段或类型不符时逐项回退默认值，不让整份配置解码失败。
        let version = (try? container.decode(Int.self, forKey: .version)) ?? Self.currentVersion
        let isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? true
        let passwordIcons = (try? container.decode(Bool.self, forKey: .showsPasswordPageIcons)) ?? true
        let totpIcons = (try? container.decode(Bool.self, forKey: .showsTotpPageIcons)) ?? true
        let passkeyIcons = (try? container.decode(Bool.self, forKey: .showsPasskeyPageIcons)) ?? true
        let policyRawValue = try? container.decode(String.self, forKey: .unmatchedPolicy)
        let policy = policyRawValue.flatMap(ItemIconUnmatchedPolicy.init(rawValue:)) ?? .firstLetter
        // 逐项把 rawValue 还原成枚举：未知 ID 丢弃，缺失的来源按默认顺序补齐。
        let priorityRawValues = (try? container.decode([String].self, forKey: .sourcePriority)) ?? []
        let priority = priorityRawValues.compactMap(ItemIconSource.init(rawValue:))
        self.init(
            version: version,
            isEnabled: isEnabled,
            showsPasswordPageIcons: passwordIcons,
            showsTotpPageIcons: totpIcons,
            showsPasskeyPageIcons: passkeyIcons,
            unmatchedPolicy: policy,
            sourcePriority: priority.isEmpty ? ItemIconSource.defaultPriority : priority
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(showsPasswordPageIcons, forKey: .showsPasswordPageIcons)
        try container.encode(showsTotpPageIcons, forKey: .showsTotpPageIcons)
        try container.encode(showsPasskeyPageIcons, forKey: .showsPasskeyPageIcons)
        try container.encode(unmatchedPolicy, forKey: .unmatchedPolicy)
        try container.encode(sourcePriority, forKey: .sourcePriority)
    }

    // MARK: 归一化

    /// 把任意来源的配置收敛成一份完整、可安全使用的偏好。
    public mutating func normalize() {
        guard version == Self.currentVersion else {
            self = Self.default
            return
        }
        sourcePriority = Self.normalizedPriority(sourcePriority)
    }

    public func normalized() -> Self {
        var copy = self
        copy.normalize()
        return copy
    }

    static func normalizedPriority(_ priority: [ItemIconSource]) -> [ItemIconSource] {
        var seen = Set<ItemIconSource>()
        var result: [ItemIconSource] = []
        for source in priority where seen.insert(source).inserted {
            result.append(source)
        }
        for source in ItemIconSource.defaultPriority where !seen.contains(source) {
            result.append(source)
        }
        return result
    }

    // MARK: 查询

    /// 页面级最终是否显示图标：总开关与分页面开关同时开启才显示。
    public func isEnabled(for page: ItemIconPage) -> Bool {
        guard isEnabled else { return false }
        switch page {
        case .password: return showsPasswordPageIcons
        case .totp: return showsTotpPageIcons
        case .passkey: return showsPasskeyPageIcons
        }
    }

    public mutating func setEnabled(_ enabled: Bool, for page: ItemIconPage) {
        switch page {
        case .password: showsPasswordPageIcons = enabled
        case .totp: showsTotpPageIcons = enabled
        case .passkey: showsPasskeyPageIcons = enabled
        }
    }

    /// 归一化后的来源优先级（永远是三个来源的完整排列）。
    public var orderedSources: [ItemIconSource] {
        Self.normalizedPriority(sourcePriority)
    }

    /// 上下调整来源优先级：`offset` 为 -1 上移、+1 下移。
    public mutating func moveSource(_ source: ItemIconSource, by offset: Int) {
        var sources = orderedSources
        guard let index = sources.firstIndex(of: source) else { return }
        let destination = index + offset
        guard sources.indices.contains(destination), destination != index else { return }
        sources.swapAt(index, destination)
        sourcePriority = sources
    }

    public func isFirstSource(_ source: ItemIconSource) -> Bool {
        orderedSources.first == source
    }

    public func isLastSource(_ source: ItemIconSource) -> Bool {
        orderedSources.last == source
    }
}

// MARK: - 头像

/// 列表里渲染一个条目图标槽位所需的最小信息。
///
/// 刻意做成值类型而不是图片：列表每行不做解码 / 不建视图模型，
/// 首字母用 `Text`、符号用 `Image(systemName:)` 直接渲染。
public enum ItemIconAvatar: Hashable, Sendable {
    /// SF Symbol 名称（白名单内的符号，或内置目录的符号）。
    case symbol(String)
    /// 首字母（单个字符，中文保留原字）。
    case initial(String)
    /// 透明占位：与图标同尺寸，关闭或隐藏图标时行高与留白不跳动。
    case placeholder

    public var systemName: String? {
        if case let .symbol(systemName) = self { return systemName }
        return nil
    }

    public var initialText: String? {
        if case let .initial(text) = self { return text }
        return nil
    }

    public var isPlaceholder: Bool {
        if case .placeholder = self { return true }
        return false
    }

    /// 三种头像都占用图标槽位；占位也占位，因此关闭图标不会改变列表布局。
    public var reservesIconSlot: Bool { true }
}

// MARK: - 槽位度量

/// 图标槽位的固定度量（pt）。关闭图标时使用同尺寸透明占位，行高与留白不跳动。
public enum ItemIconSlotMetrics {
    /// 密码 / 验证码列表的图标槽位边长。
    public static let size: CGFloat = 40
    /// 通行密钥列表在 40pt 图标外再包一层 54pt 槽位（与既有 UI 一致）。
    public static let passkeySize: CGFloat = 54
    public static let cornerRadius: CGFloat = 10

    /// 无论是否显示图标，槽位宽度恒定。
    public static func slotWidth(isIconVisible: Bool) -> CGFloat { size }
    public static func slotHeight(isIconVisible: Bool) -> CGFloat { size }
}

// MARK: - 解析请求

/// 解析一个条目图标所需的输入。全部来自本地数据，不含网络字段。
public struct ItemIconRequest: Sendable, Equatable {
    public var page: ItemIconPage
    /// 条目类型 ID，用于「默认图标」策略（`ItemIcon.defaultSymbol(forKind:)`）。
    public var kindID: String
    /// 已持久化的图标值（`sf:` / `catalog:`，可能是旧格式）。
    public var storedValue: String?
    /// 页面独有、存在其他列的显式图标（目前用于验证码的 `iconName`）。
    public var explicitSymbol: String?
    public var title: String
    public var secondaryText: String
    /// 参与内置目录匹配的域名（登录 URL、通行密钥 relyingPartyID 等）。
    public var domains: [String]
    /// 页面级的自动符号，只在「SF Symbol」来源参与优先级比较（如通行密钥服务商图标）。
    public var symbolOverride: String?

    public init(
        page: ItemIconPage,
        kindID: String,
        storedValue: String? = nil,
        explicitSymbol: String? = nil,
        title: String = "",
        secondaryText: String = "",
        domains: [String] = [],
        symbolOverride: String? = nil
    ) {
        self.page = page
        self.kindID = kindID
        self.storedValue = storedValue
        self.explicitSymbol = explicitSymbol
        self.title = title
        self.secondaryText = secondaryText
        self.domains = domains
        self.symbolOverride = symbolOverride
    }
}

// MARK: - 解析器

/// 把「偏好 + 条目信息」解析成一行要渲染的头像。
///
/// 优先级顺序：
/// 1. 全局 / 分页面开关关闭 → `.placeholder`（同尺寸占位，布局不跳动）。
/// 2. 条目显式选择的图标（`storedValue` 或 `explicitSymbol`）→ 直接渲染，
///    显式选择永远优先于自动匹配，避免用户手选的图标被优先级「吃掉」。
/// 3. 按用户调整的来源优先级逐个尝试自动来源：内置目录 → SF Symbol → 首字母槽位。
/// 4. 全部落空 → 未匹配策略（默认图标 / 首字母 / 隐藏）。
public enum ItemIconAvatarResolver {
    public static func avatar(
        for request: ItemIconRequest,
        preferences: ItemIconPreferences
    ) -> ItemIconAvatar {
        guard preferences.isEnabled(for: request.page) else {
            return .placeholder
        }

        if let symbol = explicitSystemName(for: request) {
            return .symbol(symbol)
        }

        let normalized = preferences.normalized()
        for source in normalized.orderedSources {
            switch source {
            case .catalog:
                if let entry = catalogEntry(for: request) {
                    return .symbol(entry.symbolName)
                }
            case .symbol:
                if let override = request.symbolOverride,
                   ItemIconCatalog.isKnownSymbol(override) {
                    return .symbol(override)
                }
            case .firstLetter:
                return policyAvatar(for: request, policy: normalized.unmatchedPolicy)
            }
        }
        return policyAvatar(for: request, policy: normalized.unmatchedPolicy)
    }

    // MARK: 显式图标

    /// 条目自己选定的图标：先按 `ItemIcon` 编解码解析，再退回页面独有列。
    /// 未知 / 损坏的 `catalog:` / `sf:` 值视为未选择，交给策略兜底。
    public static func explicitSystemName(for request: ItemIconRequest) -> String? {
        if let storedValue = request.storedValue,
           let icon = ItemIcon(storageValue: storedValue) ?? ItemIcon.migrated(fromLegacy: storedValue),
           icon.isResolved {
            return icon.resolvedSystemName
        }
        if let explicitSymbol = request.explicitSymbol?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitSymbol.isEmpty {
            return explicitSymbol
        }
        return nil
    }

    // MARK: 未匹配策略

    static func policyAvatar(for request: ItemIconRequest, policy: ItemIconUnmatchedPolicy) -> ItemIconAvatar {
        switch policy {
        case .defaultIcon:
            let symbol = ItemIcon.defaultSymbol(forKind: request.kindID)
            return .symbol(ItemIconCatalog.isKnownSymbol(symbol) ? symbol : ItemIcon.fallbackSymbol)
        case .firstLetter:
            return .initial(initial(for: request))
        case .hidden:
            return .placeholder
        }
    }

    // MARK: 首字母

    /// 首字母：优先标题，其次副标题，最后域名的主机标签；取第一个非空白字符并大写。
    /// 全部为空时用 `#`，保证槽位永远有稳定内容。
    public static func initial(for request: ItemIconRequest) -> String {
        for text in [request.title, request.secondaryText] {
            guard let character = text.first(where: { !$0.isWhitespace }) else { continue }
            return String(character).uppercased()
        }
        for domain in request.domains {
            guard let label = domainLabels(domain).first,
                  let character = label.first(where: { !$0.isWhitespace })
            else { continue }
            return String(character).uppercased()
        }
        return "#"
    }

    // MARK: 内置目录匹配

    /// 本地匹配内置目录：先看域名，再看标题 / 副标题。
    /// 只做字符串比较，不请求 favicon、不发起网络请求。
    public static func catalogEntry(for request: ItemIconRequest) -> ItemIconCatalogEntry? {
        for domain in request.domains {
            if let entry = catalogEntry(matchingDomain: domain) {
                return entry
            }
        }
        for text in [request.title, request.secondaryText] where !text.isEmpty {
            if let entry = catalogEntry(matchingText: text) {
                return entry
            }
        }
        return nil
    }

    static func catalogEntry(matchingDomain domain: String) -> ItemIconCatalogEntry? {
        let labels = domainLabels(domain)
        guard !labels.isEmpty else { return nil }
        // 单段主机（例如通行密钥里只写了 "github"）直接参与匹配。
        let candidates = labels.count > 1 ? Array(labels.dropLast()) : labels
        for (alias, catalogID) in sortedAliases where candidates.contains(alias) {
            return ItemIconCatalog.entry(id: catalogID)
        }
        return nil
    }

    static func catalogEntry(matchingText text: String) -> ItemIconCatalogEntry? {
        // 关键词命中取「最长」的那一个，跨中文标签与拉丁别名统一比较：
        // 「GitHub工作账号」里 github（6）比「工作」（2）更具体，命中开发而不是工作。
        let lowercased = text.lowercased()
        var best: (length: Int, catalogID: String)?
        func consider(_ keyword: String, _ catalogID: String) {
            guard best == nil || keyword.count > best!.length else { return }
            best = (keyword.count, catalogID)
        }
        // 中文标签用包含匹配（「招商银行」包含「银行」）。
        for (label, catalogID) in sortedChineseLabels where text.contains(label) {
            consider(label, catalogID)
        }
        for (alias, catalogID) in sortedAliases where containsLatinWord(alias, in: lowercased) {
            consider(alias, catalogID)
        }
        guard let best else { return nil }
        return ItemIconCatalog.entry(id: best.catalogID)
    }

    /// 域名 → 小写标签数组：去掉协议、端口、路径、查询串与 `www.` 前缀。
    static func domainLabels(_ rawDomain: String) -> [String] {
        var host = rawDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty else { return [] }
        if let schemeRange = host.range(of: "://") {
            host = String(host[schemeRange.upperBound...])
        }
        if let separator = host.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            host = String(host[..<separator])
        }
        if let at = host.lastIndex(of: "@") {
            host = String(host[host.index(after: at)...])
        }
        if let colon = host.firstIndex(of: ":") {
            host = String(host[..<colon])
        }
        while host.hasPrefix("www.") {
            host.removeFirst("www.".count)
        }
        return host
            .split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "_" })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// 整词匹配：前后不能紧邻拉丁字母 / 数字，避免 "network" 命中 "work"。
    /// 中文紧邻拉丁词时仍然命中（「GitHub工作账号」）。
    static func containsLatinWord(_ word: String, in lowercasedText: String) -> Bool {
        guard !word.isEmpty, !lowercasedText.isEmpty else { return false }
        var searchRange = lowercasedText.startIndex..<lowercasedText.endIndex
        while let range = lowercasedText.range(of: word, range: searchRange) {
            let beforeIsWordCharacter = range.lowerBound > lowercasedText.startIndex
                ? isLatinWordCharacter(lowercasedText[lowercasedText.index(before: range.lowerBound)])
                : false
            let afterIsWordCharacter = range.upperBound < lowercasedText.endIndex
                ? isLatinWordCharacter(lowercasedText[range.upperBound])
                : false
            if !beforeIsWordCharacter && !afterIsWordCharacter {
                return true
            }
            searchRange = range.upperBound..<lowercasedText.endIndex
        }
        return false
    }

    static func isLatinWordCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }

    /// 别名按长度倒序（同长度按字面序），保证最长、最具体的别名先命中。
    static let sortedAliases: [(String, String)] = ItemIconCatalog.legacyCatalogAliases
        .map { ($0.key.lowercased(), $0.value) }
        .sorted { lhs, rhs in
            lhs.0.count == rhs.0.count ? lhs.0 < rhs.0 : lhs.0.count > rhs.0.count
        }

    static let sortedChineseLabels: [(String, String)] = ItemIconCatalog.legacyChineseLabels
        .map { ($0.key, $0.value) }
        .sorted { lhs, rhs in
            lhs.0.count == rhs.0.count ? lhs.0 < rhs.0 : lhs.0.count > rhs.0.count
        }
}
