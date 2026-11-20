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

public struct MonicaWidgetTotpItem: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let title: String
    public let issuer: String
    public let accountName: String
    public let secondsRemaining: Int

    public init(
        id: String,
        title: String,
        issuer: String,
        accountName: String,
        secondsRemaining: Int
    ) {
        self.id = id
        self.title = title
        self.issuer = issuer
        self.accountName = accountName
        self.secondsRemaining = max(0, secondsRemaining)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case issuer
        case accountName
        case secondsRemaining
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? "",
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
            issuer: try container.decodeIfPresent(String.self, forKey: .issuer) ?? "",
            accountName: try container.decodeIfPresent(String.self, forKey: .accountName) ?? "",
            secondsRemaining: try container.decodeIfPresent(Int.self, forKey: .secondsRemaining) ?? 0
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

    public init(
        schemaVersion: Int = MonicaWidgetConstants.currentSchemaVersion,
        vaultState: MonicaWidgetVaultState,
        totalEntryCount: Int = 0,
        totpItems: [MonicaWidgetTotpItem] = [],
        shortcutItems: [MonicaWidgetShortcutItem] = []
    ) {
        self.schemaVersion = schemaVersion
        self.vaultState = vaultState
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
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawVaultState = try container.decodeIfPresent(String.self, forKey: .vaultState)
        self.init(
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
                ?? MonicaWidgetConstants.legacySchemaVersion,
            vaultState: rawVaultState.flatMap(MonicaWidgetVaultState.init(rawValue:)) ?? .locked,
            totalEntryCount: try container.decodeIfPresent(Int.self, forKey: .totalEntryCount) ?? 0,
            totpItems: try container.decodeIfPresent([MonicaWidgetTotpItem].self, forKey: .totpItems) ?? [],
            shortcutItems: try container.decodeIfPresent([MonicaWidgetShortcutItem].self, forKey: .shortcutItems) ?? []
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
