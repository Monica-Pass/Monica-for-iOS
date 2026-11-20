//
//  AppSecurityCenterSupport.swift
//  Monica
//
//  安全中心的分组行模型、扩展能力行、重复登录合并预览与撤销记录。
//

import MonicaStorage
import Foundation

struct AppPermissionStatusRow: Sendable, Equatable, Identifiable {
    enum State: String, Sendable, Equatable {
        case granted
        case denied
        case notDetermined
        case unavailable
        case configured
        case notConfigured
        case checkable

        var label: String {
            switch self {
            case .granted:
                String(localized: "已允许")
            case .denied:
                String(localized: "未允许")
            case .notDetermined:
                String(localized: "可检查")
            case .unavailable:
                String(localized: "不可用")
            case .configured:
                String(localized: "已配置")
            case .notConfigured:
                String(localized: "待配置")
            case .checkable:
                String(localized: "可检查")
            }
        }
    }

    let id: String
    let title: String
    let systemImage: String
    let state: State
    let detail: String
    let settingsURL: URL?

    init(
        id: String,
        title: String,
        systemImage: String,
        state: State,
        detail: String,
        settingsURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.state = state
        self.detail = detail
        self.settingsURL = settingsURL
    }

    var value: String {
        state.label
    }
}

struct AppSecurityCenterRow: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let systemImage: String
}

struct AppSecurityCenterRepairSuggestion: Sendable, Equatable, Identifiable {
    let id: String
    let relatedRowID: String
    let title: String
    let detail: String
    let systemImage: String
}

struct AppExtensionCapabilityRow: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let systemImage: String
}

struct AppDuplicateLoginMergePreview: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let username: String
    let url: String
    let entryCountLabel: String
    let primaryEntryID: String
    let duplicateEntryIDs: [String]
    let detail: String
}

struct AppDuplicateLoginMergeUndo: Sendable, Equatable {
    let title: String
    let restoredEntryIDs: [String]
}

struct DuplicateLoginEntryKey: Hashable {
    let title: String
    let username: String
    let url: String

    init?(entry: LocalLoginEntry) {
        title = Self.normalized(entry.title)
        username = Self.normalized(entry.username)
        url = Self.normalized(entry.url)
        guard !title.isEmpty || !username.isEmpty || !url.isEmpty else {
            return nil
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension String {
    var nonBlankValue: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
