import Foundation

/// 条目图标。存储的是「稳定资源标识符」，而不是本地化名称、也不是 图片文件路径：
///
/// - `sf:key.fill`                 → SF Symbols（白名单内才认为有效）
/// - `catalog:bank`                → 内置图标目录里的稳定 id
///
/// 渲染时才把标识符解析成具体图标；未知 / 损坏的值一律落到确定性回退，
/// 绝不按界面语言反查图标，避免切换语言后图标丢失。
public enum ItemIcon: Hashable, Sendable, Codable, CustomStringConvertible {
    case symbol(String)
    case catalog(String)

    public static let symbolPrefix = "sf:"
    public static let catalogPrefix = "catalog:"

    /// 条目没有自定义图标时，渲染层使用的确定性回退。
    public static let fallbackSymbol = "key.fill"

    public var storageValue: String {
        switch self {
        case .symbol(let name): Self.symbolPrefix + name
        case .catalog(let id): Self.catalogPrefix + id
        }
    }

    public var description: String { storageValue }

    /// 严格解析：只接受带命名空间的标识符。返回值保留未知 id，
    /// 由 `resolvedSystemName` 在渲染时回退（这样未来版本新增图标不会被旧客户端丢弃）。
    public init?(storageValue: String) {
        let text = storageValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let name = text.dropPrefixIfPresent(Self.symbolPrefix) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            self = .symbol(trimmed)
        } else if let id = text.dropPrefixIfPresent(Self.catalogPrefix) {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else { return nil }
            self = .catalog(trimmed)
        } else {
            return nil
        }
    }

    /// 宽松解析：兼容历史数据。Android 迁移过来的值可能是
    /// `SIMple_ICON` 的 slug（`bank`）、旧中文标签（`钥匙`）、或裸 SF 符号名（`key.fill`）。
    /// 无法识别的值返回 nil，由调用方回退到条目类型默认图标。
    public static func migrated(fromLegacy rawValue: String?) -> ItemIcon? {
        guard let rawValue else { return nil }
        let text = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let parsed = ItemIcon(storageValue: text) {
            return parsed
        }

        let lowered = text.lowercased()
        switch lowered {
        case "none", "simple_icon", "uploaded", "null":
            // Android 的枚举值本身不是图标；UPLOADED 是本地文件名，iOS 端无法解析。
            return nil
        default:
            break
        }

        if let catalogID = ItemIconCatalog.legacyCatalogAliases[lowered] {
            return .catalog(catalogID)
        }
        if let catalogID = ItemIconCatalog.legacyChineseLabels[text] {
            return .catalog(catalogID)
        }
        if ItemIconCatalog.contains(id: lowered) {
            return .catalog(lowered)
        }
        // 裸 SF 符号名（历史数据里偶尔直接存了 systemImage）。
        if lowered.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "." || $0 == "-" }),
           lowered.contains(".") {
            return .symbol(lowered)
        }
        return nil
    }

    /// 解析成可渲染的 SF 符号名。未知 id 回退到 `fallbackSymbol`，结果确定。
    public var resolvedSystemName: String {
        switch self {
        case .symbol(let name):
            let lowered = name.lowercased()
            return ItemIconCatalog.isKnownSymbol(lowered) ? lowered : Self.fallbackSymbol
        case .catalog(let id):
            return ItemIconCatalog.entry(id: id)?.symbolName ?? Self.fallbackSymbol
        }
    }

    /// 是否能在当前版本里真正渲染（用于设置页提示）。
    public var isResolved: Bool {
        switch self {
        case .symbol(let name): ItemIconCatalog.isKnownSymbol(name.lowercased())
        case .catalog(let id): ItemIconCatalog.entry(id: id) != nil
        }
    }

    /// 条目类型默认图标。仅在用户没有选择自定义图标时使用。
    public static func defaultSymbol(forKind kindID: String) -> String {
        switch kindID.lowercased() {
        case "login", "password": "key.fill"
        case "totp", "totpentry": "text.badge.key"
        case "note": "note.text"
        case "card": "creditcard"
        case "identity": "person.text.rectangle"
        case "passkey": "key.horizontal.fill"
        case "sshkey": "key.fill"
        case "apitoken": "text.badge.key"
        case "wifi": "wifi"
        case "send": "paperplane.fill"
        case "attachmentref", "attachment": "paperclip"
        default: fallbackSymbol
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let icon = ItemIcon(storageValue: text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "无法解析条目图标：\(text)"
            )
        }
        self = icon
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageValue)
    }
}

/// 内置图标目录。id 稳定、可翻译名称只是展示层数据。
public struct ItemIconCatalogEntry: Hashable, Sendable, Identifiable {
    public let id: String
    public let symbolName: String
    public let displayName: String

    public init(id: String, symbolName: String, displayName: String) {
        self.id = id
        self.symbolName = symbolName
        self.displayName = displayName
    }
}

public enum ItemIconCatalog {
    public static let entries: [ItemIconCatalogEntry] = [
        ItemIconCatalogEntry(id: "bank", symbolName: "building.columns.fill", displayName: "银行"),
        ItemIconCatalogEntry(id: "card", symbolName: "creditcard.fill", displayName: "卡片"),
        ItemIconCatalogEntry(id: "mail", symbolName: "envelope.fill", displayName: "邮箱"),
        ItemIconCatalogEntry(id: "cloud", symbolName: "cloud.fill", displayName: "云服务"),
        ItemIconCatalogEntry(id: "dev", symbolName: "chevron.left.forwardslash.chevron.right", displayName: "开发"),
        ItemIconCatalogEntry(id: "social", symbolName: "person.2.fill", displayName: "社交"),
        ItemIconCatalogEntry(id: "shop", symbolName: "bag.fill", displayName: "购物"),
        ItemIconCatalogEntry(id: "work", symbolName: "briefcase.fill", displayName: "工作"),
        ItemIconCatalogEntry(id: "home", symbolName: "house.fill", displayName: "家庭"),
        ItemIconCatalogEntry(id: "key", symbolName: "key.fill", displayName: "钥匙"),
        ItemIconCatalogEntry(id: "wifi", symbolName: "wifi", displayName: "无线网络"),
        ItemIconCatalogEntry(id: "server", symbolName: "server.rack", displayName: "服务器"),
        ItemIconCatalogEntry(id: "media", symbolName: "play.rectangle.fill", displayName: "媒体"),
        ItemIconCatalogEntry(id: "wallet", symbolName: "wallet.pass.fill", displayName: "钱包"),
        ItemIconCatalogEntry(id: "travel", symbolName: "airplane", displayName: "旅行"),
        ItemIconCatalogEntry(id: "health", symbolName: "heart.fill", displayName: "健康"),
        ItemIconCatalogEntry(id: "education", symbolName: "graduationcap.fill", displayName: "教育"),
        ItemIconCatalogEntry(id: "generic", symbolName: "square.grid.2x2.fill", displayName: "通用")
    ]

    /// 允许直接以 `sf:` 形式存储的符号白名单。白名单外的一律回退，
    /// 避免把随系统版本消失的符号名写进用户数据。
    public static let extraSymbols: [String] = [
        "key.fill",
        "key.horizontal.fill",
        "lock.fill",
        "lock.shield.fill",
        "globe",
        "person.fill",
        "person.text.rectangle",
        "text.badge.key",
        "shield.lefthalf.filled",
        "note.text",
        "paperplane.fill",
        "paperclip",
        "creditcard",
        "building.2.fill",
        "terminal.fill",
        "gamecontroller.fill",
        "film.fill",
        "music.note",
        "cart.fill",
        "fork.knife",
        "pawprint.fill",
        "car.fill",
        "ticket.fill",
        "banknote.fill",
        "doc.text.fill",
        "bookmark.fill",
        "star.fill",
        "flag.fill",
        "bolt.fill",
        "cpu.fill",
        "externaldrive.fill",
        "envelope.open.fill",
        "phone.fill",
        "message.fill",
        "camera.fill",
        "photo.fill",
        "printer.fill",
        "headphones",
        "wifi.router.fill",
        "questionmark.circle.fill"
    ]

    public static var allSymbols: [String] {
        var symbols = entries.map(\.symbolName)
        for symbol in extraSymbols where !symbols.contains(symbol) {
            symbols.append(symbol)
        }
        return symbols
    }

    public static func entry(id: String) -> ItemIconCatalogEntry? {
        entries.first { $0.id == id.lowercased() }
    }

    public static func contains(id: String) -> Bool {
        entry(id: id) != nil
    }

    public static func isKnownSymbol(_ name: String) -> Bool {
        allSymbols.contains(name.lowercased())
    }

    static let legacyCatalogAliases: [String: String] = [
        "bank": "bank",
        "banking": "bank",
        "creditcard": "card",
        "credit-card": "card",
        "visa": "card",
        "mastercard": "card",
        "mail": "mail",
        "gmail": "mail",
        "outlook": "mail",
        "icloud": "cloud",
        "dropbox": "cloud",
        "onedrive": "cloud",
        "googledrive": "cloud",
        "github": "dev",
        "gitlab": "dev",
        "git": "dev",
        "docker": "dev",
        "steam": "social",
        "steamcommunity": "social",
        "twitter": "social",
        "x": "social",
        "facebook": "social",
        "instagram": "social",
        "discord": "social",
        "telegram": "social",
        "wechat": "social",
        "weibo": "social",
        "amazon": "shop",
        "ebay": "shop",
        "taobao": "shop",
        "jd": "shop",
        "office365": "work",
        "microsoft": "work",
        "office": "work",
        "slack": "work",
        "notion": "work",
        "home": "home",
        "key": "key",
        "wifi": "wifi",
        "router": "wifi",
        "server": "server",
        "vps": "server",
        "netflix": "media",
        "youtube": "media",
        "spotify": "media",
        "bilibili": "media",
        "paypal": "wallet",
        "alipay": "wallet",
        "wechatpay": "wallet",
        "airbnb": "travel",
        "booking": "travel",
        "uber": "travel",
        "health": "health",
        "education": "education",
        "generic": "generic"
    ]

    static let legacyChineseLabels: [String: String] = [
        "银行": "bank",
        "金融": "bank",
        "卡片": "card",
        "银行卡": "card",
        "邮箱": "mail",
        "邮件": "mail",
        "云服务": "cloud",
        "开发": "dev",
        "社交": "social",
        "购物": "shop",
        "工作": "work",
        "家庭": "home",
        "钥匙": "key",
        "密码": "key",
        "无线网络": "wifi",
        "无线": "wifi",
        "服务器": "server",
        "媒体": "media",
        "钱包": "wallet",
        "旅行": "travel",
        "健康": "health",
        "教育": "education",
        "通用": "generic"
    ]
}

private extension String {
    func dropPrefixIfPresent(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
