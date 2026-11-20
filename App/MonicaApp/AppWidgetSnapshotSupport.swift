import Foundation
import MonicaStorage
import MonicaWidgetShared

// The App Group snapshot schema lives in `MonicaWidgetShared` so the app and the widget
// extension compile one definition. These aliases keep the existing app-facing names and
// the App Group file/container behaviour unchanged.

typealias AppWidgetVaultState = MonicaWidgetVaultState
typealias AppWidgetTotpItem = MonicaWidgetTotpItem
typealias AppWidgetSnapshot = MonicaWidgetSnapshot
typealias AppWidgetSnapshotFileStore = MonicaWidgetSnapshotFileStore
typealias AppShortcutSnapshot = MonicaShortcutSnapshot
typealias AppShortcutSnapshotEntry = MonicaShortcutSnapshotEntry
typealias AppShortcutSnapshotFileStore = MonicaShortcutSnapshotFileStore

extension MonicaWidgetTotpItem {
    var timeRemainingLabel: String {
        String(localized: "\(secondsRemaining) 秒")
    }
}

extension MonicaWidgetSnapshot {
    var totalEntryLabel: String {
        String(localized: "\(totalEntryCount) 项")
    }

    /// Redacted, log-safe rendering of the snapshot. It intentionally contains only the
    /// same non-secret projection the widget itself displays.
    var redactedDebugSummary: String {
        let totpText = totpItems
            .map { "\($0.title) \($0.issuer) \($0.accountName) \($0.timeRemainingLabel)" }
            .joined(separator: " ")
        let shortcutText = shortcutItems
            .map { summary in
                let kindLabel = UnifiedVaultItemKind(rawValue: summary.kind)?.localizedDisplayName
                    ?? summary.kind
                return "\(kindLabel) \(summary.title) \(summary.subtitle) \(summary.searchableText)"
            }
            .joined(separator: " ")
        return [
            vaultState.label,
            totalEntryLabel,
            totpText,
            shortcutText
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }
}

extension MonicaWidgetShortcutItem {
    init(summary: AppShortcutEntrySummary) {
        self.init(
            id: summary.id,
            kind: summary.kind.rawValue,
            title: summary.title,
            subtitle: summary.subtitle,
            searchableText: summary.searchableText
        )
    }
}

extension MonicaShortcutSnapshotEntry {
    init(summary: AppShortcutEntrySummary) {
        self.init(
            id: summary.id,
            kind: summary.kind.rawValue,
            title: summary.title,
            subtitle: summary.subtitle,
            searchableText: summary.searchableText,
            openURL: URL(string: "monica://shortcut/\(summary.kind.rawValue)/\(summary.id)")
                ?? MonicaShortcutSnapshotEntry.derivedOpenURL(kind: summary.kind.rawValue, id: summary.id)
        )
    }
}
