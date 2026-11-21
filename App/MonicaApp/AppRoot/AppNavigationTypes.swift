//
//  AppNavigationTypes.swift
//  Monica
//
//  页面标签、路由与保险库状态枚举等导航层类型。
//

import MonicaStorage
import Foundation

struct AppVaultQuickFilterRow: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let isSelected: Bool
}

enum MonicaAppTab: Hashable {
    case passwords
    case totp
    case wallet
    case settings

    /// 顶层 Tab 的唯一顺序来源：密码 → 验证 → 卡包 → 设置。
    static let rootTabs: [MonicaAppTab] = [
        .passwords,
        .totp,
        .wallet,
        .settings
    ]

    var title: String {
        switch self {
        case .passwords:
            return String(localized: "密码")
        case .totp:
            return String(localized: "验证")
        case .wallet:
            return String(localized: "卡包")
        case .settings:
            return String(localized: "设置")
        }
    }

    var systemImage: String {
        switch self {
        case .passwords:
            return "key.fill"
        case .totp:
            return "timer"
        case .wallet:
            return "creditcard"
        case .settings:
            return "gearshape"
        }
    }
}

extension MonicaControlPage {
    /// 控制中心页面与固定四 Tab 共用同一套标题和图标。
    var appTab: MonicaAppTab {
        switch self {
        case .passwords:
            return .passwords
        case .totp:
            return .totp
        case .wallet:
            return .wallet
        case .settings:
            return .settings
        }
    }
}

/// 密码页的二级模块。
///
/// `rawValue` 是 #63 布局自定义使用的稳定 ID：不能用中文标题或数组下标表达含义。
enum PasswordModule: String, CaseIterable, Hashable, Identifiable, Sendable {
    case login
    case passkey
    case note
    case other

    var id: String { rawValue }

    /// 三个主模块，#63 只排序这三项。
    static let primaryModules: [PasswordModule] = [.login, .passkey, .note]

    /// 加上「其他」后的完整顺序；「其他」固定置后，不参与 #63 排序。
    static let allModules: [PasswordModule] = [.login, .passkey, .note, .other]

    /// 「其他」页的二级类型，固定顺序。
    static let otherKinds: [UnifiedVaultItemKind] = [
        .sshKey,
        .apiToken,
        .wifi,
        .sso,
        .send,
        .attachmentRef
    ]

    var title: String {
        switch self {
        case .login:
            return String(localized: "登录")
        case .passkey:
            return String(localized: "通行密钥")
        case .note:
            return String(localized: "笔记")
        case .other:
            return String(localized: "其他")
        }
    }

    var itemKind: UnifiedVaultItemKind? {
        switch self {
        case .login:
            return .login
        case .passkey:
            return .passkey
        case .note:
            return .note
        case .other:
            return nil
        }
    }
}

extension UnifiedVaultItemKind {
    /// 该条目类型在密码页归入哪个二级模块；TOTP/卡包不是密码页模块。
    var passwordModule: PasswordModule? {
        switch self {
        case .login:
            return .login
        case .passkey:
            return .passkey
        case .note:
            return .note
        case .sshKey, .apiToken, .wifi, .sso, .send, .attachmentRef:
            return .other
        case .totp, .card, .identity, .steam:
            return nil
        }
    }
}

/// 验证 Tab 下的二级模块：验证码与 Steam Guard。
enum TotpModule: String, CaseIterable, Hashable, Identifiable, Sendable {
    case totp
    case steam

    var id: String { rawValue }

    var title: String {
        switch self {
        case .totp:
            return String(localized: "验证码")
        case .steam:
            return String(localized: "Steam")
        }
    }

    var systemImage: String {
        switch self {
        case .totp:
            return "timer"
        case .steam:
            return "shield.lefthalf.filled"
        }
    }
}

/// 快捷指令 / 深链打开条目时的完整落点。
struct VaultShortcutDestination: Equatable, Sendable {
    let tab: MonicaAppTab
    let passwordModule: PasswordModule?
    let otherKind: UnifiedVaultItemKind?
}

enum AndroidParityToolbarAction: Hashable, Sendable {
    case folder
    case search
}

struct VaultItemRoute: Hashable, Sendable {
    let kind: UnifiedVaultItemKind
    let entryID: String
}

enum VaultItemEditorMode: Hashable, Sendable {
    case add(UnifiedVaultItemKind)
    case edit(VaultItemRoute)

    var kind: UnifiedVaultItemKind {
        switch self {
        case .add(let kind):
            return kind
        case .edit(let route):
            return route.kind
        }
    }

    var isAdding: Bool {
        if case .add = self {
            return true
        }
        return false
    }
}

enum SendCreateType: String, CaseIterable, Identifiable, Sendable {
    case text
    case file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: return String(localized: "文本")
        case .file: return String(localized: "文件")
        }
    }
}

struct VaultItemDisplayModel: Identifiable, Hashable, Sendable {
    let id: String
    let kind: UnifiedVaultItemKind
    let title: String
    let subtitle: String
    let detail: String
    let favorite: Bool
    let accent: String
}

enum VaultState: String, Sendable {
    case locked = "已锁定"
    case unlocked = "已解锁"
    case needsSetup = "需要设置"
}

enum VaultOperationState: Sendable, Equatable {
    case idle
    case running
    case succeeded(String)
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            return String(localized: "就绪")
        case .running:
            return String(localized: "处理中")
        case .succeeded(let name):
            return String(localized: "已创建 \(name)")
        case .failed(let message):
            return message
        }
    }

    var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }
}

enum EntryOperationState: Sendable, Equatable {
    case idle
    case running
    case succeeded(String)
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            return String(localized: "就绪")
        case .running:
            return String(localized: "处理中")
        case .succeeded(let title):
            return String(localized: "已保存 \(title)")
        case .failed(let message):
            return message
        }
    }

    var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }
}
