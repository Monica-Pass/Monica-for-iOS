import Foundation
import SwiftUI
import WidgetKit

private let monicaWidgetAppGroupIdentifier = "group.takagi.ru.monica"
private let monicaWidgetSnapshotFileName = "widget-snapshot-v1.json"

private enum MonicaWidgetVaultState: String, Codable {
    case locked
    case unlocked

    var label: String {
        switch self {
        case .locked:
            return "已锁定"
        case .unlocked:
            return "已解锁"
        }
    }
}

private struct MonicaWidgetTotpItem: Codable, Identifiable {
    let id: String
    let title: String
    let issuer: String
    let accountName: String
    let secondsRemaining: Int
}

private struct MonicaWidgetShortcutItem: Codable, Identifiable {
    let id: String
    let kind: String
    let title: String
    let subtitle: String
    let searchableText: String
}

private struct MonicaWidgetSnapshot: Codable {
    let vaultState: MonicaWidgetVaultState
    let totalEntryCount: Int
    let totpItems: [MonicaWidgetTotpItem]
    let shortcutItems: [MonicaWidgetShortcutItem]

    static let locked = MonicaWidgetSnapshot(
        vaultState: .locked,
        totalEntryCount: 0,
        totpItems: [],
        shortcutItems: []
    )
}

private struct MonicaWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: MonicaWidgetSnapshot
}

private struct MonicaWidgetSnapshotReader {
    func loadSnapshot() -> MonicaWidgetSnapshot {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: monicaWidgetAppGroupIdentifier
        ) else {
            return .locked
        }
        let url = containerURL.appendingPathComponent(monicaWidgetSnapshotFileName)
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(MonicaWidgetSnapshot.self, from: data)
        else {
            return .locked
        }
        return snapshot
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
                        Text(item.title.isEmpty ? "验证码" : item.title)
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
                    Text(shortcut.title.isEmpty ? "快捷入口" : shortcut.title)
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

@main
struct MonicaWidget: Widget {
    let kind = "MonicaWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MonicaWidgetProvider()) { entry in
            MonicaWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Monica")
        .description("显示安全的保险库状态和快捷摘要。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
