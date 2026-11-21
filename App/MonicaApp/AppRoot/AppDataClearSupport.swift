//
//  AppDataClearSupport.swift
//  Monica
//
//  设置里「按数据类型清空」的分类模型与会话动作（issue #145）。
//
//  设计约束：
//  - 删除只走 `VaultDataClearService` → `LocalVaultEntryRepository` 的删除 API，
//    不直接改 `.mdbx`，也不删除分类/文件夹；
//  - 条目是软删除（进入回收站），标签与生成历史是永久删除，文案必须区分；
//  - 主密码校验在存储层完成，失败时零删除；
//  - 成功后刷新条目列表、搜索索引、自动填充索引、Widget 快照，并写脱敏的 Timeline 事件。
//

import Foundation
import MonicaStorage

/// 「按数据类型清空」里可选的数据类别。
///
/// 刻意不复用 `UnifiedVaultItemKind`：这里要合并「卡包」（银行卡 + 证件），还要覆盖
/// 标签与生成历史这两个不属于条目类型的对象。
enum AppDataClearCategory: String, CaseIterable, Identifiable, Sendable {
    case login
    case note
    case totp
    case cardPack
    case sshKey
    case apiToken
    case wifi
    case passkey
    case send
    case attachmentRef
    case sso
    case steam
    case gpgKey
    case barcode
    case billingAddress
    case paymentAccount
    case tags
    case generatorHistory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .login:
            return String(localized: "登录")
        case .note:
            return String(localized: "笔记")
        case .totp:
            return String(localized: "验证码")
        case .cardPack:
            return String(localized: "卡包")
        case .sshKey:
            return String(localized: "SSH 密钥")
        case .apiToken:
            return String(localized: "API Token")
        case .wifi:
            return String(localized: "WiFi")
        case .passkey:
            return String(localized: "Passkey")
        case .send:
            return String(localized: "Send")
        case .attachmentRef:
            return String(localized: "附件引用")
        case .sso:
            return String(localized: "SSO")
        case .steam:
            return String(localized: "Steam")
        case .gpgKey:
            return String(localized: "GPG 密钥")
        case .barcode:
            return String(localized: "条码")
        case .billingAddress:
            return String(localized: "账单地址")
        case .paymentAccount:
            return String(localized: "支付账户")
        case .tags:
            return String(localized: "标签")
        case .generatorHistory:
            return String(localized: "生成历史")
        }
    }

    /// 次要说明；只给容易误解的类别加，避免列表噪音。
    var detail: String? {
        switch self {
        case .cardPack:
            return String(localized: "银行卡与证件")
        case .attachmentRef:
            return String(localized: "被清空条目的附件会一并移除")
        case .tags:
            return String(localized: "永久删除，不进回收站")
        case .generatorHistory:
            return String(localized: "永久删除，不进回收站")
        default:
            return nil
        }
    }

    var systemImage: String {
        switch self {
        case .login:
            return "key.fill"
        case .note:
            return "note.text"
        case .totp:
            return "clock.badge.checkmark"
        case .cardPack:
            return "creditcard.fill"
        case .sshKey:
            return "terminal.fill"
        case .apiToken:
            return "curlybraces"
        case .wifi:
            return "wifi"
        case .passkey:
            return "person.badge.key.fill"
        case .send:
            return "paperplane.fill"
        case .attachmentRef:
            return "paperclip"
        case .sso:
            return "person.2.badge.key.fill"
        case .steam:
            return "gamecontroller.fill"
        case .gpgKey:
            return "lock.shield.fill"
        case .barcode:
            return "barcode"
        case .billingAddress:
            return "doc.text.fill"
        case .paymentAccount:
            return "banknote.fill"
        case .tags:
            return "tag.fill"
        case .generatorHistory:
            return "clock.arrow.circlepath"
        }
    }

    /// 该类别覆盖的条目类型；标签与生成历史不属于条目类型，返回空数组。
    var kinds: [UnifiedVaultItemKind] {
        switch self {
        case .login:
            return [.login]
        case .note:
            return [.note]
        case .totp:
            return [.totp]
        case .cardPack:
            return [.card, .identity]
        case .sshKey:
            return [.sshKey]
        case .apiToken:
            return [.apiToken]
        case .wifi:
            return [.wifi]
        case .passkey:
            return [.passkey]
        case .send:
            return [.send]
        case .attachmentRef:
            return [.attachmentRef]
        case .sso:
            return [.sso]
        case .steam:
            return [.steam]
        case .gpgKey:
            return [.gpgKey]
        case .barcode:
            return [.barcode]
        case .billingAddress:
            return [.billingAddress]
        case .paymentAccount:
            return [.paymentAccount]
        case .tags, .generatorHistory:
            return []
        }
    }

    var clearsTags: Bool { self == .tags }

    var clearsGeneratorHistory: Bool { self == .generatorHistory }

    /// 条目类删除都进回收站；标签与生成历史是永久删除。
    var movesEntriesToTrash: Bool { !kinds.isEmpty }
}

/// 页面加载时的分类计数快照。
struct AppDataClearSnapshot: Equatable, Sendable {
    var counts: [AppDataClearCategory: Int] = [:]
    var projectCount: Int = 0

    var totalItemCount: Int {
        counts.values.reduce(0, +)
    }

    var isEmpty: Bool {
        totalItemCount == 0
    }

    func count(for category: AppDataClearCategory) -> Int {
        counts[category] ?? 0
    }
}

/// 一次清空的结果，用于页面回显。
struct AppDataClearOutcome: Equatable, Sendable {
    var deletedCounts: [AppDataClearCategory: Int] = [:]
    var removedTagCount: Int = 0
    var affectedEntryCount: Int = 0
    var generatorHistoryCleared: Bool = false

    var totalEntryCount: Int {
        deletedCounts.values.reduce(0, +)
    }
}

@MainActor
extension AppSessionModel {
    /// 统计每个类别在当前保险库里的条目数量（跨全部项目）。
    func dataClearSnapshot() async throws -> AppDataClearSnapshot {
        guard vaultState == .unlocked, let vaultSession = activeVaultSession else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }

        let entryRepository = vaultRepository.entryRepository(for: vaultSession)
        let service = VaultDataClearService(repository: vaultRepository, session: vaultSession)
        let kindCounts = try service.counts()
        let tagCount = (try? entryRepository.listVaultTags().count) ?? 0

        var counts: [AppDataClearCategory: Int] = [:]
        for category in AppDataClearCategory.allCases {
            if category.clearsTags {
                counts[category] = tagCount
            } else if category.clearsGeneratorHistory {
                counts[category] = await generatorHistoryEntryCount(vaultID: vaultSession.handle.vaultID)
            } else {
                counts[category] = category.kinds.reduce(0) { partial, kind in
                    partial + (kindCounts[kind] ?? 0)
                }
            }
        }

        return AppDataClearSnapshot(
            counts: counts,
            projectCount: (try? service.liveProjectIDs().count) ?? 0
        )
    }

    /// 校验主密码后按类别清空，并刷新所有派生数据。
    func performDataClear(
        categories: Set<AppDataClearCategory>,
        masterPassword: String
    ) async throws -> AppDataClearOutcome {
        guard vaultState == .unlocked, let vaultSession = activeVaultSession else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        guard !categories.isEmpty else {
            return AppDataClearOutcome()
        }

        let entryRepository = vaultRepository.entryRepository(for: vaultSession)
        let service = VaultDataClearService(repository: vaultRepository, session: vaultSession)
        let kinds = categories.reduce(into: Set<UnifiedVaultItemKind>()) { result, category in
            result.formUnion(category.kinds)
        }
        let clearsGeneratorHistory = categories.contains(.generatorHistory)

        // 校验失败会在这里抛出，此时不会删除任何数据。
        let report = try service.clear(
            kinds: kinds,
            clearsTags: categories.contains(.tags),
            masterPassword: masterPassword
        )

        if clearsGeneratorHistory {
            let historyController = GeneratorHistoryController()
            await historyController.clearPersistedHistory(forVaultID: vaultSession.handle.vaultID)
        }

        refreshAfterDataClear(entryRepository: entryRepository)
        appendDataClearTimeline(
            report: report,
            categories: categories,
            generatorHistoryCleared: clearsGeneratorHistory
        )
        recordUserActivity()

        var deletedCounts: [AppDataClearCategory: Int] = [:]
        for category in AppDataClearCategory.allCases where categories.contains(category) {
            let count = category.kinds.reduce(0) { partial, kind in
                partial + (report.deletedCounts[kind] ?? 0)
            }
            if count > 0 {
                deletedCounts[category] = count
            }
        }

        return AppDataClearOutcome(
            deletedCounts: deletedCounts,
            removedTagCount: report.removedTagCount,
            affectedEntryCount: report.affectedEntryCount,
            generatorHistoryCleared: clearsGeneratorHistory
        )
    }

    /// 条目列表、标签、搜索索引、Widget 快照都从真实存储重新拉取，避免残留已删条目。
    private func refreshAfterDataClear(entryRepository: LocalVaultEntryRepository) {
        let projectID = activeProject?.id
            ?? ((try? entryRepository.listProjects())?.first?.id)
        if let projectID {
            try? refreshAllEntryLists(projectID: projectID, entryRepository: entryRepository)
        } else {
            refreshVaultTags()
            _ = publishWidgetSnapshots()
        }
        // refreshAllEntryLists 只在身份类条目变化时刷新自动填充索引，这里显式刷新一次。
        try? refreshAutoFillEncryptedIndexIfConfigured()
    }

    private func appendDataClearTimeline(
        report: VaultDataClearReport,
        categories: Set<AppDataClearCategory>,
        generatorHistoryCleared: Bool
    ) {
        for category in AppDataClearCategory.allCases where categories.contains(category) {
            let deletedCount = category.kinds.reduce(0) { partial, kind in
                partial + (report.deletedCounts[kind] ?? 0)
            }
            let didChangeSomething = deletedCount > 0
                || (category.clearsTags && report.removedTagCount > 0)
                || (category.clearsGeneratorHistory && generatorHistoryCleared)
            guard didChangeSomething else {
                continue
            }

            // 只写类别名与数量级，绝不写条目名称；itemKind 用类别代表类型，方便 Timeline 过滤。
            appendOperationTimelineEvent(
                action: .cleanedUp,
                itemKind: category.kinds.first ?? .login,
                itemID: "data-clear-\(category.rawValue)-\(UUID().uuidString)",
                itemTitle: category.title
            )
        }
    }

    private func generatorHistoryEntryCount(vaultID: String) async -> Int {
        let controller = GeneratorHistoryController()
        await controller.sync(vaultID: vaultID, isVaultUnlocked: true)
        let count = controller.isEnabled && controller.isVaultUnlocked
            ? controller.entries.count
            : 0
        await controller.lock()
        return count
    }
}
