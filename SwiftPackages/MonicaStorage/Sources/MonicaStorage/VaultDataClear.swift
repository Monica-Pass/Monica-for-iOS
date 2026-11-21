//
//  VaultDataClear.swift
//  MonicaStorage
//
//  按数据类型清空（issue #145）。Android 支持「按类型选择性清空」，iOS 目前只能整库删除；
//  这里提供与 UI 解耦的存储层能力：统计每类条目数量、校验主密码后按类型调用真实删除 API。
//
//  设计约束：
//  - 只走 `LocalVaultEntryRepository` 的既有删除 API，绝不直接改 `.mdbx` 文件；
//  - 条目删除是软删除（进入回收站，可在回收站恢复），标签删除是永久删除；
//  - 先校验主密码，校验失败时不删除任何数据；
//  - 清理条目时顺带移除指向这些条目的附件引用，避免留下悬空引用；
//  - 不删除分类、文件夹或项目，库结构保持不变。
//

import Foundation

/// 按数据类型清空的结果。
public struct VaultDataClearReport: Equatable, Sendable {
    /// 每个类型实际删除（软删除进回收站）的条目数量。
    public var deletedCounts: [UnifiedVaultItemKind: Int]
    /// 删除的标签数量。
    public var removedTagCount: Int
    /// 因标签被删除而受影响的条目数量。
    public var affectedEntryCount: Int

    public var totalDeletedCount: Int {
        deletedCounts.values.reduce(0, +)
    }

    public init(
        deletedCounts: [UnifiedVaultItemKind: Int] = [:],
        removedTagCount: Int = 0,
        affectedEntryCount: Int = 0
    ) {
        self.deletedCounts = deletedCounts
        self.removedTagCount = removedTagCount
        self.affectedEntryCount = affectedEntryCount
    }
}

/// 按数据类型清空真实保险库数据。
public struct VaultDataClearService {
    private let repository: LocalVaultRepository
    private let session: LocalVaultSession
    private let entryRepository: LocalVaultEntryRepository

    public init(repository: LocalVaultRepository, session: LocalVaultSession) {
        self.repository = repository
        self.session = session
        self.entryRepository = repository.entryRepository(for: session)
    }

    public func liveProjectIDs() throws -> [String] {
        try entryRepository.listProjects().map(\.id)
    }

    /// 统计每个类型的现存条目数量；无法枚举的类型按 0 计，避免一个坏类型拖垮整个设置页。
    public func counts(projectIDs: [String]? = nil) throws -> [UnifiedVaultItemKind: Int] {
        let targets = try projectIDs ?? liveProjectIDs()
        var counts: [UnifiedVaultItemKind: Int] = [:]
        for kind in UnifiedVaultItemKind.allCases {
            var total = 0
            for projectID in targets {
                total += (try? entryIDs(kind: kind, projectID: projectID).count) ?? 0
            }
            counts[kind] = total
        }
        return counts
    }

    /// 校验主密码后按类型清空。
    ///
    /// - Parameters:
    ///   - kinds: 勾选的条目类型；`.attachmentRef` 表示删除全部附件引用。
    ///   - clearsTags: 是否删除全部标签。
    ///   - projectIDs: 限定项目；为 nil 时覆盖库内全部项目。
    ///   - masterPassword: 主密码，校验失败抛 `LocalVaultRepositoryError.currentPasswordMismatch`。
    @discardableResult
    public func clear(
        kinds: Set<UnifiedVaultItemKind>,
        clearsTags: Bool = false,
        projectIDs: [String]? = nil,
        masterPassword: String
    ) throws -> VaultDataClearReport {
        try repository.verifyMasterPassword(for: session, password: masterPassword)

        let targets = try projectIDs ?? liveProjectIDs()

        // 先枚举所有待删条目：任何类型枚举失败都在动手之前抛出，避免只删了一半。
        var plan: [(kind: UnifiedVaultItemKind, projectID: String, ids: [String])] = []
        for projectID in targets {
            for kind in UnifiedVaultItemKind.allCases
            where kinds.contains(kind) && kind != .attachmentRef {
                plan.append(
                    (
                        kind: kind,
                        projectID: projectID,
                        ids: try entryIDs(kind: kind, projectID: projectID)
                    )
                )
            }
        }

        var report = VaultDataClearReport()
        var removedEntryIDs: Set<String> = []
        for item in plan {
            for id in item.ids {
                try deleteEntry(kind: item.kind, projectID: item.projectID, id: id)
                removedEntryIDs.insert(id)
            }
            report.deletedCounts[item.kind, default: 0] += item.ids.count
        }

        let removesAllAttachments = kinds.contains(.attachmentRef)
        if removesAllAttachments || !removedEntryIDs.isEmpty {
            for projectID in targets {
                let attachments = (try? entryRepository.listAttachmentMetadata(projectID: projectID)) ?? []
                for attachment in attachments {
                    let isOrphaned = attachment.entryID.map { removedEntryIDs.contains($0) } ?? false
                    guard removesAllAttachments || isOrphaned else {
                        continue
                    }
                    try entryRepository.deleteAttachmentMetadata(
                        projectID: projectID,
                        attachmentID: attachment.id
                    )
                    report.deletedCounts[.attachmentRef, default: 0] += 1
                }
            }
        }

        if clearsTags {
            for tag in (try? entryRepository.listVaultTags()) ?? [] {
                let affected = try entryRepository.deleteVaultTag(tagID: tag.id)
                report.removedTagCount += 1
                report.affectedEntryCount += affected
            }
        }

        return report
    }

    private func entryIDs(
        kind: UnifiedVaultItemKind,
        projectID: String
    ) throws -> [String] {
        switch kind {
        case .login:
            return try entryRepository.listLoginEntries(projectID: projectID).map(\.id)
        case .totp:
            return try entryRepository.listTotpEntries(projectID: projectID).map(\.id)
        case .note:
            return try entryRepository.listNoteEntries(projectID: projectID).map(\.id)
        case .card:
            return try entryRepository.listCardEntries(projectID: projectID).map(\.id)
        case .identity:
            return try entryRepository.listIdentityEntries(projectID: projectID).map(\.id)
        case .passkey:
            return try entryRepository.listPasskeyEntries(projectID: projectID).map(\.id)
        case .sshKey:
            return try entryRepository.listSshKeyEntries(projectID: projectID).map(\.id)
        case .gpgKey:
            return try entryRepository.listGPGKeyEntries(projectID: projectID).map(\.id)
        case .apiToken:
            return try entryRepository.listApiTokenEntries(projectID: projectID).map(\.id)
        case .wifi:
            return try entryRepository.listWifiEntries(projectID: projectID).map(\.id)
        case .sso:
            return try entryRepository.listSSOEntries(projectID: projectID).map(\.id)
        case .send:
            return try entryRepository.listSendEntries(projectID: projectID).map(\.id)
        case .attachmentRef:
            return try entryRepository.listAttachmentMetadata(projectID: projectID).map(\.id)
        case .steam:
            return try entryRepository.listSteamEntries(projectID: projectID).map(\.id)
        case .barcode:
            return try entryRepository.listBarcodeEntries(projectID: projectID).map(\.id)
        case .billingAddress:
            return try entryRepository.listBillingAddressEntries(projectID: projectID).map(\.id)
        case .paymentAccount:
            return try entryRepository.listPaymentAccountEntries(projectID: projectID).map(\.id)
        }
    }

    private func deleteEntry(
        kind: UnifiedVaultItemKind,
        projectID: String,
        id: String
    ) throws {
        switch kind {
        case .login:
            try entryRepository.deleteLoginEntry(projectID: projectID, entryID: id)
        case .totp:
            try entryRepository.deleteTotpEntry(projectID: projectID, entryID: id)
        case .note:
            try entryRepository.deleteNoteEntry(projectID: projectID, entryID: id)
        case .card:
            try entryRepository.deleteCardEntry(projectID: projectID, entryID: id)
        case .identity:
            try entryRepository.deleteIdentityEntry(projectID: projectID, entryID: id)
        case .passkey:
            try entryRepository.deletePasskeyEntry(projectID: projectID, entryID: id)
        case .sshKey:
            try entryRepository.deleteSshKeyEntry(projectID: projectID, entryID: id)
        case .gpgKey:
            try entryRepository.deleteGPGKeyEntry(projectID: projectID, entryID: id)
        case .apiToken:
            try entryRepository.deleteApiTokenEntry(projectID: projectID, entryID: id)
        case .wifi:
            try entryRepository.deleteWifiEntry(projectID: projectID, entryID: id)
        case .sso:
            try entryRepository.deleteSSOEntry(projectID: projectID, entryID: id)
        case .send:
            try entryRepository.deleteSendEntry(projectID: projectID, entryID: id)
        case .attachmentRef:
            try entryRepository.deleteAttachmentMetadata(projectID: projectID, attachmentID: id)
        case .steam:
            try entryRepository.deleteSteamEntry(projectID: projectID, entryID: id)
        case .barcode:
            try entryRepository.deleteBarcodeEntry(projectID: projectID, entryID: id)
        case .billingAddress:
            try entryRepository.deleteBillingAddressEntry(projectID: projectID, entryID: id)
        case .paymentAccount:
            try entryRepository.deletePaymentAccountEntry(projectID: projectID, entryID: id)
        }
    }
}
