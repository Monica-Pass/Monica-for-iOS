import Foundation

/// Shared, versioned schema for the App Group JSON snapshots that the main app writes
/// and the widget extension / App Intents read.
///
/// The snapshot is deliberately a *privacy-safe projection* of the vault: it never
/// contains passwords, TOTP secrets, note bodies, or any other secret material. Both the
/// app target and the `MonicaWidgetExtension` target compile this single definition so the
/// on-disk shape cannot drift between writer and reader again.
public enum MonicaWidgetConstants: Sendable {
    /// The App Group container shared by the app and its extensions. Changing this value
    /// would silently hide existing snapshots, so it must stay in sync with the
    /// application-groups entitlements of every target.
    public static let appGroupIdentifier = "group.com.monicapass.monica"
    public static let widgetKind = "MonicaWidget"
    public static let widgetSnapshotFileName = "widget-snapshot-v1.json"
    public static let shortcutsSnapshotFileName = "shortcuts-snapshot-v1.json"
    /// The only schema version ever written. Payloads without a `schemaVersion` key are
    /// treated as v1 (that is how the first app releases wrote them).
    public static let currentSchemaVersion = 1
    public static let legacySchemaVersion = 1
}

public enum MonicaWidgetVaultState: String, Sendable, Equatable, CaseIterable, Codable {
    case locked
    case unlocked

    public var isUnlocked: Bool {
        self == .unlocked
    }

    /// Display text shown by the widget. The literal is the Chinese source string used by
    /// the app's `Localizable.xcstrings`; when a target has no matching entry the literal
    /// itself is rendered, which is the pre-existing behaviour of both targets.
    public var label: String {
        switch self {
        case .locked:
            String(localized: "已锁定")
        case .unlocked:
            String(localized: "已解锁")
        }
    }
}

/// 验证码卡片进度条样式在快照里的投影。
///
/// 之所以在这里重复一份枚举，是因为 Widget Extension 只链接本包、不依赖 MonicaCore；
/// rawValue 必须与 `MonicaCore.TotpProgressStyle` 完全一致（linear / circular）。
public enum MonicaWidgetTotpProgressStyle: String, Sendable, Equatable, CaseIterable, Codable {
    case linear
    case circular

    /// 缺失 / 未知取值一律回落到线性：旧快照与旧版本 App 写出的外观保持一致。
    public init(snapshotValue: String?) {
        self = snapshotValue.flatMap(Self.init(rawValue:)) ?? .linear
    }
}

public struct MonicaWidgetTotpItem: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let title: String
    public let issuer: String
    public let accountName: String
    public let secondsRemaining: Int
    /// 该验证码的刷新周期（秒）。Widget 用它把 `secondsRemaining` 换算成进度比例；
    /// 旧快照没有这个字段，按 TOTP 最常见的 30 秒兜底。
    public let period: Int

    public static let defaultPeriod = 30

    public init(
        id: String,
        title: String,
        issuer: String,
        accountName: String,
        secondsRemaining: Int,
        period: Int = MonicaWidgetTotpItem.defaultPeriod
    ) {
        self.id = id
        self.title = title
        self.issuer = issuer
        self.accountName = accountName
        self.secondsRemaining = max(0, secondsRemaining)
        self.period = max(1, period)
    }

    /// 剩余比例（0…1），钳制在合法区间内，除以 0 也安全。
    public var progressFraction: Double {
        Double(min(max(secondsRemaining, 0), period)) / Double(period)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case issuer
        case accountName
        case secondsRemaining
        case period
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? "",
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
            issuer: try container.decodeIfPresent(String.self, forKey: .issuer) ?? "",
            accountName: try container.decodeIfPresent(String.self, forKey: .accountName) ?? "",
            secondsRemaining: try container.decodeIfPresent(Int.self, forKey: .secondsRemaining) ?? 0,
            period: try container.decodeIfPresent(Int.self, forKey: .period) ?? Self.defaultPeriod
        )
    }
}

public struct MonicaWidgetShortcutItem: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    /// Raw value of `UnifiedVaultItemKind`. Stored as a string so this package stays free
    /// of the storage/security dependency graph and the widget extension stays lightweight.
    public let kind: String
    public let title: String
    public let subtitle: String
    public let searchableText: String

    public init(
        id: String,
        kind: String,
        title: String,
        subtitle: String,
        searchableText: String
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.searchableText = searchableText
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case subtitle
        case searchableText
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? "",
            kind: try container.decodeIfPresent(String.self, forKey: .kind) ?? "",
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
            subtitle: try container.decodeIfPresent(String.self, forKey: .subtitle) ?? "",
            searchableText: try container.decodeIfPresent(String.self, forKey: .searchableText) ?? ""
        )
    }
}

public struct MonicaWidgetSnapshot: Sendable, Equatable, Codable {
    public let schemaVersion: Int
    public let vaultState: MonicaWidgetVaultState
    public let totalEntryCount: Int
    public let totpItems: [MonicaWidgetTotpItem]
    public let shortcutItems: [MonicaWidgetShortcutItem]
    /// 验证码进度条样式，跟随 App 里的「验证码进度条」设置。旧快照缺字段即线性。
    public let totpProgressStyle: MonicaWidgetTotpProgressStyle

    public init(
        schemaVersion: Int = MonicaWidgetConstants.currentSchemaVersion,
        vaultState: MonicaWidgetVaultState,
        totalEntryCount: Int = 0,
        totpItems: [MonicaWidgetTotpItem] = [],
        shortcutItems: [MonicaWidgetShortcutItem] = [],
        totpProgressStyle: MonicaWidgetTotpProgressStyle = .linear
    ) {
        self.schemaVersion = schemaVersion
        self.vaultState = vaultState
        // 进度条样式是纯展示偏好、不含任何项目数据，锁屏状态也保留，
        // 这样解锁瞬间不会因为样式回退而闪一下线性样式。
        self.totpProgressStyle = totpProgressStyle
        // Defence in depth: a locked snapshot must never carry project data, even if a
        // caller (or a hand-edited JSON file) tries to attach some. Sensitive values are
        // dropped here and again when decoding.
        let isLocked = !vaultState.isUnlocked
        self.totalEntryCount = isLocked ? 0 : max(0, totalEntryCount)
        self.totpItems = isLocked ? [] : totpItems
        self.shortcutItems = isLocked ? [] : shortcutItems
    }

    public static let locked = MonicaWidgetSnapshot(vaultState: .locked)

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case vaultState
        case totalEntryCount
        case totpItems
        case shortcutItems
        case totpProgressStyle
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawVaultState = try container.decodeIfPresent(String.self, forKey: .vaultState)
        let rawStyle = try container.decodeIfPresent(String.self, forKey: .totpProgressStyle)
        self.init(
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
                ?? MonicaWidgetConstants.legacySchemaVersion,
            vaultState: rawVaultState.flatMap(MonicaWidgetVaultState.init(rawValue:)) ?? .locked,
            totalEntryCount: try container.decodeIfPresent(Int.self, forKey: .totalEntryCount) ?? 0,
            totpItems: try container.decodeIfPresent([MonicaWidgetTotpItem].self, forKey: .totpItems) ?? [],
            shortcutItems: try container.decodeIfPresent([MonicaWidgetShortcutItem].self, forKey: .shortcutItems) ?? [],
            totpProgressStyle: MonicaWidgetTotpProgressStyle(snapshotValue: rawStyle)
        )
    }
}

public struct MonicaShortcutSnapshotEntry: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let kind: String
    public let title: String
    public let subtitle: String
    public let searchableText: String
    public let openURL: URL

    public init(
        id: String,
        kind: String,
        title: String,
        subtitle: String,
        searchableText: String,
        openURL: URL
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.searchableText = searchableText
        self.openURL = openURL
    }

    private static let fallbackOpenURL = URL(string: "monica://shortcut") ?? URL(fileURLWithPath: "/")

    public static func derivedOpenURL(kind: String, id: String) -> URL {
        URL(string: "monica://shortcut/\(kind)/\(id)") ?? fallbackOpenURL
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case subtitle
        case searchableText
        case openURL
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        let kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
        let title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        let subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        let searchableText = try container.decodeIfPresent(String.self, forKey: .searchableText) ?? ""
        // Older writers always persisted `openURL`; deriving it keeps payloads written by
        // intermediate builds readable instead of invalidating the whole snapshot.
        let openURL = try container.decodeIfPresent(URL.self, forKey: .openURL)
            ?? Self.derivedOpenURL(kind: kind, id: id)
        self.init(
            id: id,
            kind: kind,
            title: title,
            subtitle: subtitle,
            searchableText: searchableText,
            openURL: openURL
        )
    }
}

public struct MonicaShortcutSnapshot: Sendable, Equatable, Codable {
    public let schemaVersion: Int
    public let vaultState: MonicaWidgetVaultState
    public let entries: [MonicaShortcutSnapshotEntry]

    public init(
        schemaVersion: Int = MonicaWidgetConstants.currentSchemaVersion,
        vaultState: MonicaWidgetVaultState,
        entries: [MonicaShortcutSnapshotEntry] = []
    ) {
        self.schemaVersion = schemaVersion
        self.vaultState = vaultState
        self.entries = vaultState.isUnlocked ? entries : []
    }

    public static let locked = MonicaShortcutSnapshot(vaultState: .locked)

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case vaultState
        case entries
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawVaultState = try container.decodeIfPresent(String.self, forKey: .vaultState)
        self.init(
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
                ?? MonicaWidgetConstants.legacySchemaVersion,
            vaultState: rawVaultState.flatMap(MonicaWidgetVaultState.init(rawValue:)) ?? .locked,
            entries: try container.decodeIfPresent([MonicaShortcutSnapshotEntry].self, forKey: .entries) ?? []
        )
    }
}
