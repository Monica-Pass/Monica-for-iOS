//
//  AppShortcutEntrySummary.swift
//  Monica
//
//  快捷指令条目摘要（快照编解码见 AppWidgetSnapshotSupport）。
//

import MonicaStorage

struct AppShortcutEntrySummary: Sendable, Equatable, Identifiable {
    let id: String
    let kind: UnifiedVaultItemKind
    let title: String
    let subtitle: String
    let searchableText: String

    init(
        id: String,
        kind: UnifiedVaultItemKind,
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
}
