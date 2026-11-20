//
//  AppOperationTimeline.swift
//  Monica
//
//  操作时间线的事件模型、动作枚举与存储后端。
//

import MonicaStorage
import Foundation

enum AppOperationTimelineAction: String, Sendable, Equatable, Codable {
    case created
    case updated
    case deleted
    case restored
    case moved
    case viewed
    case backedUp
    case restoredBackup
    case cleanedUp
    case synced
    case blocked

    var title: String {
        switch self {
        case .created:
            String(localized: "已创建")
        case .updated:
            String(localized: "已更新")
        case .deleted:
            String(localized: "已删除")
        case .restored:
            String(localized: "已恢复")
        case .moved:
            String(localized: "已移动")
        case .viewed:
            String(localized: "已查看")
        case .backedUp:
            String(localized: "已备份")
        case .restoredBackup:
            String(localized: "已恢复备份")
        case .cleanedUp:
            String(localized: "已清理")
        case .synced:
            String(localized: "已同步")
        case .blocked:
            String(localized: "已阻止")
        }
    }

    var systemImage: String {
        switch self {
        case .created:
            "plus.circle"
        case .updated:
            "pencil.circle"
        case .deleted:
            "trash.circle"
        case .restored:
            "arrow.uturn.backward.circle"
        case .moved:
            "arrow.right.circle"
        case .viewed:
            "eye.circle"
        case .backedUp:
            "arrow.up.doc"
        case .restoredBackup:
            "arrow.down.doc"
        case .cleanedUp:
            "sparkles"
        case .synced:
            "arrow.triangle.2.circlepath.circle"
        case .blocked:
            "hand.raised.circle"
        }
    }
}

struct AppOperationTimelineEvent: Sendable, Equatable, Identifiable, Codable {
    let id: String
    let action: AppOperationTimelineAction
    let itemKind: UnifiedVaultItemKind
    let itemID: String
    let itemTitle: String
    let occurredAt: Date
    let result: String
    let errorCategory: String?

    init(
        id: String,
        action: AppOperationTimelineAction,
        itemKind: UnifiedVaultItemKind,
        itemID: String,
        itemTitle: String,
        occurredAt: Date,
        result: String = "success",
        errorCategory: String? = nil
    ) {
        self.id = id
        self.action = action
        self.itemKind = itemKind
        self.itemID = itemID
        self.itemTitle = itemTitle
        self.occurredAt = occurredAt
        self.result = result
        self.errorCategory = errorCategory
    }

    enum CodingKeys: String, CodingKey {
        case id
        case action
        case itemKind
        case itemID
        case itemTitle
        case occurredAt
        case result
        case errorCategory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        action = try container.decode(AppOperationTimelineAction.self, forKey: .action)
        let rawKind = try container.decode(String.self, forKey: .itemKind)
        itemKind = UnifiedVaultItemKind(rawValue: rawKind) ?? .login
        itemID = try container.decode(String.self, forKey: .itemID)
        itemTitle = try container.decode(String.self, forKey: .itemTitle)
        occurredAt = try container.decode(Date.self, forKey: .occurredAt)
        result = try container.decodeIfPresent(String.self, forKey: .result) ?? "success"
        errorCategory = try container.decodeIfPresent(String.self, forKey: .errorCategory)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(action, forKey: .action)
        try container.encode(itemKind.rawValue, forKey: .itemKind)
        try container.encode(itemID, forKey: .itemID)
        try container.encode(itemTitle, forKey: .itemTitle)
        try container.encode(occurredAt, forKey: .occurredAt)
        try container.encode(result, forKey: .result)
        try container.encodeIfPresent(errorCategory, forKey: .errorCategory)
    }

    var title: String {
        "\(action.title) \(itemKind.localizedDisplayName)"
    }

    var detail: String {
        let displayTitle = itemTitle.isEmpty ? String(localized: "未命名条目") : itemTitle
        guard let errorCategory, !errorCategory.isEmpty else {
            return displayTitle
        }
        return "\(displayTitle) · \(errorCategory)"
    }

    var systemImage: String {
        action.systemImage
    }
}

protocol AppOperationTimelineStore: Sendable {
    func loadEvents() -> [AppOperationTimelineEvent]
    func saveEvents(_ events: [AppOperationTimelineEvent])
}

final class MemoryAppOperationTimelineStore: AppOperationTimelineStore, @unchecked Sendable {
    private var events: [AppOperationTimelineEvent]

    init(events: [AppOperationTimelineEvent] = []) {
        self.events = events
    }

    func loadEvents() -> [AppOperationTimelineEvent] {
        events
    }

    func saveEvents(_ events: [AppOperationTimelineEvent]) {
        self.events = events
    }
}

final class UserDefaultsAppOperationTimelineStore: AppOperationTimelineStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard, key: String = "app-operation-timeline-v1") {
        self.defaults = defaults
        self.key = key
    }

    func loadEvents() -> [AppOperationTimelineEvent] {
        guard let data = defaults.data(forKey: key),
              let events = try? decoder.decode([AppOperationTimelineEvent].self, from: data)
        else {
            return []
        }
        return events
    }

    func saveEvents(_ events: [AppOperationTimelineEvent]) {
        guard let data = try? encoder.encode(Array(events.prefix(500))) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}
