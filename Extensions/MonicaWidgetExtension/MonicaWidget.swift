import Foundation
import MonicaWidgetShared
import SwiftUI
import WidgetKit

private struct MonicaWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: MonicaWidgetSnapshot
}

private struct MonicaWidgetSnapshotReader {
    func loadSnapshot() -> MonicaWidgetSnapshot {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: MonicaWidgetConstants.appGroupIdentifier
        ) else {
            return .locked
        }
        // Corrupt, missing, and newer-than-supported payloads all degrade to `.locked`, so
        // the widget never renders stale project data.
        return MonicaWidgetSnapshotFileStore(containerURL: containerURL).loadSnapshotOrFallback()
    }
}

private struct MonicaWidgetProvider: TimelineProvider {
    private let reader = MonicaWidgetSnapshotReader()

    func placeholder(in context: Context) -> MonicaWidgetEntry {
        MonicaWidgetEntry(date: Date(), snapshot: .locked)
    }

    func getSnapshot(in context: Context, completion: @escaping (MonicaWidgetEntry) -> Void) {
        completion(MonicaWidgetEntry(date: Date(), snapshot: reader.loadSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MonicaWidgetEntry>) -> Void) {
        let now = Date()
        let snapshot = reader.loadSnapshot()
        let nextRefresh = nextRefreshDate(now: now, snapshot: snapshot)
        completion(
            Timeline(
                entries: [MonicaWidgetEntry(date: now, snapshot: snapshot)],
                policy: .after(nextRefresh)
            )
        )
    }

    /// The app pushes a reload after every vault mutation, so the timeline only needs a
    /// cheap fallback poll: as soon as the widget can show a TOTP countdown it refreshes
    /// when that countdown changes, otherwise at most every five minutes.
    private func nextRefreshDate(now: Date, snapshot: MonicaWidgetSnapshot) -> Date {
        let nextTotpRefresh = snapshot.totpItems
            .map(\.secondsRemaining)
            .filter { $0 > 0 }
            .min() ?? 300
        let interval = max(30, min(nextTotpRefresh, 300))
        return now.addingTimeInterval(TimeInterval(interval))
    }
}

private struct MonicaWidgetEntryView: View {
    let entry: MonicaWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: entry.snapshot.vaultState == .unlocked ? "lock.open.fill" : "lock.fill")
                    .foregroundStyle(entry.snapshot.vaultState == .unlocked ? .green : .secondary)
                Text("Monica")
                    .font(.headline)
                Spacer()
                Text(entry.snapshot.vaultState.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if entry.snapshot.vaultState == .locked {
                Text("保险库已锁定")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                Text("\(entry.snapshot.totalEntryCount) 项")
                    .font(.title2.weight(.semibold))
                if let item = entry.snapshot.totpItems.first {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title.isEmpty ? String(localized: "验证码") : item.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text([item.issuer, item.accountName].filter { !$0.isEmpty }.joined(separator: " / "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text("\(max(0, item.secondsRemaining)) 秒")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } else if let shortcut = entry.snapshot.shortcutItems.first {
                    Text(shortcut.title.isEmpty ? String(localized: "快捷入口") : shortcut.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(shortcut.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("暂无可显示项目")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .containerBackground(.background, for: .widget)
    }
}

struct MonicaWidget: Widget {
    let kind = MonicaWidgetConstants.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MonicaWidgetProvider()) { entry in
            MonicaWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Monica")
        .description(String(localized: "显示安全的保险库状态和快捷摘要。"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
