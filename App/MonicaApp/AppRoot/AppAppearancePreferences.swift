//
//  AppAppearancePreferences.swift
//  Monica
//
//  外观与显示偏好：卡片密度、布局模块、配色、图标风格及各自的存储后端。
//

import CoreGraphics
import Foundation
import SwiftUI

enum VaultDisplayCardDensity: String, Sendable, Codable, Equatable, CaseIterable, Identifiable {
    case comfortable
    case compact

    var id: String { rawValue }

    var label: String {
        switch self {
        case .comfortable:
            String(localized: "舒适")
        case .compact:
            String(localized: "紧凑")
        }
    }

    var verticalSpacing: CGFloat {
        switch self {
        case .comfortable:
            8
        case .compact:
            4
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .comfortable:
            18
        case .compact:
            14
        }
    }

    /// Dynamic Type-aware font for the card accessory icon (replaces the fixed
    /// `.system(size:)` at the list-card call site). Kept distinct from the
    /// `verticalSpacing` / `iconSize` layout values above.
    var iconFont: Font {
        switch self {
        case .comfortable:
            AndroidParityTypography.smallIcon(weight: .semibold)
        case .compact:
            Font.system(.footnote, design: .default, weight: .semibold)
        }
    }
}

struct VaultDisplayPreferences: Sendable, Codable, Equatable {
    static let `default` = VaultDisplayPreferences(
        cardDensity: .comfortable,
        showsLoginUsername: true,
        showsLoginURL: true,
        showsTabLabels: true
    )

    var cardDensity: VaultDisplayCardDensity
    var showsLoginUsername: Bool
    var showsLoginURL: Bool
    var showsTabLabels: Bool
}

/// 密码页二级模块的稳定标识（#63）。
/// rawValue 是持久化用的稳定 ID；中文标题与数组下标都不参与持久化。
enum PasswordLayoutModule: String, Sendable, Codable, Equatable, CaseIterable, Identifiable {
    case login
    case note
    case passkey
    case generator

    var id: String { rawValue }

    var title: String {
        switch self {
        case .login:
            return String(localized: "登录")
        case .note:
            return String(localized: "笔记")
        case .passkey:
            return String(localized: "通行密钥")
        case .generator:
            return String(localized: "生成器")
        }
    }

    var systemImage: String {
        switch self {
        case .login:
            return "key.fill"
        case .note:
            return "note.text"
        case .passkey:
            return "person.badge.key.fill"
        case .generator:
            return "sparkles"
        }
    }

    /// 对应的密码页列表模块；生成器是工具页，没有列表模块。
    var passwordModule: PasswordModule? {
        switch self {
        case .login:
            return .login
        case .note:
            return .note
        case .passkey:
            return .passkey
        case .generator:
            return nil
        }
    }
}

struct AppVaultDisplayPreferenceRow: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let systemImage: String
}

struct AppAppearancePreferenceRow: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let systemImage: String
}

struct AppLoginStackedGroup: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let preview: String
    let systemImage: String
    let entryIDs: [String]
}

struct AppLoginStackedGroupKey: Hashable {
    let title: String
    let normalized: String
    let isWebsite: Bool
}

protocol VaultDisplayPreferenceStore: Sendable {
    func loadPreferences() -> VaultDisplayPreferences
    func savePreferences(_ preferences: VaultDisplayPreferences)
}

protocol AppAppearancePreferenceStore: Sendable {
    func loadPreferences() -> AppAppearancePreferences
    func savePreferences(_ preferences: AppAppearancePreferences)
}

final class UserDefaultsVaultDisplayPreferenceStore: VaultDisplayPreferenceStore, @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let key = "monica.vaultDisplayPreferences"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func loadPreferences() -> VaultDisplayPreferences {
        guard let data = userDefaults.data(forKey: key),
              let preferences = try? JSONDecoder().decode(VaultDisplayPreferences.self, from: data)
        else {
            return .default
        }
        return preferences
    }

    func savePreferences(_ preferences: VaultDisplayPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else {
            return
        }
        userDefaults.set(data, forKey: key)
    }
}

final class MemoryVaultDisplayPreferenceStore: VaultDisplayPreferenceStore, @unchecked Sendable {
    private(set) var preferences: VaultDisplayPreferences?

    init(preferences: VaultDisplayPreferences? = nil) {
        self.preferences = preferences
    }

    func loadPreferences() -> VaultDisplayPreferences {
        preferences ?? .default
    }

    func savePreferences(_ preferences: VaultDisplayPreferences) {
        self.preferences = preferences
    }
}

final class UserDefaultsAppAppearancePreferenceStore: AppAppearancePreferenceStore, @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let key = "monica.appAppearancePreferences"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func loadPreferences() -> AppAppearancePreferences {
        guard let data = userDefaults.data(forKey: key),
              let preferences = try? JSONDecoder().decode(AppAppearancePreferences.self, from: data)
        else {
            return .default
        }
        return preferences
    }

    func savePreferences(_ preferences: AppAppearancePreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else {
            return
        }
        userDefaults.set(data, forKey: key)
    }
}

final class MemoryAppAppearancePreferenceStore: AppAppearancePreferenceStore, @unchecked Sendable {
    private(set) var preferences: AppAppearancePreferences?

    init(preferences: AppAppearancePreferences? = nil) {
        self.preferences = preferences
    }

    func loadPreferences() -> AppAppearancePreferences {
        preferences ?? .default
    }

    func savePreferences(_ preferences: AppAppearancePreferences) {
        self.preferences = preferences
    }
}
