import AppIntents
import Foundation
import MonicaWidgetShared

private struct MonicaShortcutSnapshotReader: Sendable {
    func loadEntries() -> [MonicaShortcutSnapshotEntry] {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: MonicaWidgetConstants.appGroupIdentifier
        ) else {
            return []
        }
        // A missing, corrupt, locked, or newer-version snapshot yields no App Intent
        // entities; the shared store guarantees the `.locked` fallback.
        let snapshot = MonicaShortcutSnapshotFileStore(containerURL: containerURL).loadSnapshotOrFallback()
        guard snapshot.vaultState == .unlocked else {
            return []
        }
        return snapshot.entries.filter { entry in
            entry.openURL.scheme == "monica"
                && entry.openURL.host() == "shortcut"
        }
    }
}

struct MonicaShortcutEntryEntity: AppEntity, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Monica Entry")
    static let defaultQuery = MonicaShortcutEntryQuery()

    let id: String
    let title: String
    let subtitle: String
    let searchableText: String
    let openURL: URL

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: title),
            subtitle: LocalizedStringResource(stringLiteral: subtitle)
        )
    }
}

struct MonicaShortcutEntryQuery: EntityQuery, Sendable {
    init() {}

    func entities(for identifiers: [String]) async throws -> [MonicaShortcutEntryEntity] {
        let identifierSet = Set(identifiers)
        return Self.allEntities().filter { identifierSet.contains($0.id) }
    }

    func suggestedEntities() async throws -> [MonicaShortcutEntryEntity] {
        Self.allEntities()
    }

    private static func allEntities() -> [MonicaShortcutEntryEntity] {
        MonicaShortcutSnapshotReader().loadEntries().map { entry in
            MonicaShortcutEntryEntity(
                id: "\(entry.kind):\(entry.id)",
                title: entry.title,
                subtitle: entry.subtitle,
                searchableText: entry.searchableText,
                openURL: entry.openURL
            )
        }
    }
}

struct OpenMonicaShortcutEntryIntent: AppIntent, Sendable {
    static let title: LocalizedStringResource = "Open Monica Entry"
    static let description = IntentDescription("Open a redacted Monica entry shortcut.")
    static let openAppWhenRun = true

    @Parameter(title: "Entry")
    var entry: MonicaShortcutEntryEntity

    init() {}

    init(entry: MonicaShortcutEntryEntity) {
        self.entry = entry
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(entry.openURL))
    }
}

struct MonicaShortcutsProvider: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenMonicaShortcutEntryIntent(),
            phrases: [
                "Open \(\.$entry) in \(.applicationName)",
                "Show \(\.$entry) in \(.applicationName)"
            ],
            shortTitle: "Open Entry",
            systemImageName: "key.viewfinder"
        )
    }
}
