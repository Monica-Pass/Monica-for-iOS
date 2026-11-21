import Foundation
import MonicaStorage

// issue #15：自定义字段 / 条目关联只作为“侧表”读写，不塞进各种 typed 条目的 payload，
// 因此不会影响旧保险库、AutoFill 索引与备份格式；这里集中放编辑器/详情用到的读写与解析逻辑。
extension AppSessionModel {
    // MARK: - 条目 ID 集合

    func entryIDs(for kind: UnifiedVaultItemKind) -> [String] {
        switch kind {
        case .login:
            return loginEntries.map(\.id)
        case .note:
            return noteEntries.map(\.id)
        case .totp:
            return totpEntries.map(\.id)
        case .card:
            return cardEntries.map(\.id)
        case .identity:
            return identityEntries.map(\.id)
        case .passkey:
            return passkeyEntries.map(\.id)
        case .sshKey:
            return sshKeyEntries.map(\.id)
        case .apiToken:
            return apiTokenEntries.map(\.id)
        case .wifi:
            return wifiEntries.map(\.id)
        case .sso:
            return ssoEntries.map(\.id)
        case .steam:
            return steamEntries.map(\.id)
        case .barcode:
            return barcodeEntries.map(\.id)
        case .send:
            return sendEntries.map(\.id)
        case .attachmentRef:
            return attachmentEntries.map(\.id)
        case .billingAddress:
            return billingAddressEntries.map(\.id)
        case .paymentAccount:
            return paymentAccountEntries.map(\.id)
        }
    }

    /// 当前分类里所有条目（含回收站）的解析快照。只描述“在不在”，不展开它们自己的关系。
    func vaultItemDescriptors(includeDeleted: Bool = true) -> [VaultItemDescriptor] {
        var descriptors: [VaultItemDescriptor] = []
        descriptors.reserveCapacity(
            loginEntries.count + noteEntries.count + totpEntries.count
                + cardEntries.count + identityEntries.count + passkeyEntries.count
                + sshKeyEntries.count + apiTokenEntries.count + wifiEntries.count
                + sendEntries.count + attachmentEntries.count
        )

        func append(_ id: String, _ kind: UnifiedVaultItemKind, _ title: String, _ isDeleted: Bool) {
            descriptors.append(
                VaultItemDescriptor(itemID: id, kind: kind, title: title, isDeleted: isDeleted)
            )
        }

        for entry in loginEntries {
            append(entry.id, .login, entry.title, false)
        }
        for entry in noteEntries {
            append(entry.id, .note, entry.title, false)
        }
        for entry in totpEntries {
            append(entry.id, .totp, entry.title, false)
        }
        for entry in cardEntries {
            append(entry.id, .card, entry.title, false)
        }
        for entry in identityEntries {
            append(entry.id, .identity, entry.title, false)
        }
        for entry in passkeyEntries {
            append(entry.id, .passkey, entry.title, false)
        }
        for entry in sshKeyEntries {
            append(entry.id, .sshKey, entry.title, false)
        }
        for entry in apiTokenEntries {
            append(entry.id, .apiToken, entry.title, false)
        }
        for entry in wifiEntries {
            append(entry.id, .wifi, entry.title, false)
        }
        for entry in sendEntries {
            append(entry.id, .send, entry.title, false)
        }
        for entry in attachmentEntries {
            append(entry.id, .attachmentRef, entry.fileName, false)
        }

        guard includeDeleted else {
            return descriptors
        }

        for entry in deletedLoginEntries {
            append(entry.id, .login, entry.title, true)
        }
        for entry in deletedNoteEntries {
            append(entry.id, .note, entry.title, true)
        }
        for entry in deletedTotpEntries {
            append(entry.id, .totp, entry.title, true)
        }
        for entry in deletedCardEntries {
            append(entry.id, .card, entry.title, true)
        }
        for entry in deletedIdentityEntries {
            append(entry.id, .identity, entry.title, true)
        }
        for entry in deletedPasskeyEntries {
            append(entry.id, .passkey, entry.title, true)
        }
        for entry in deletedSshKeyEntries {
            append(entry.id, .sshKey, entry.title, true)
        }
        for entry in deletedApiTokenEntries {
            append(entry.id, .apiToken, entry.title, true)
        }
        for entry in deletedWifiEntries {
            append(entry.id, .wifi, entry.title, true)
        }
        for entry in deletedSendEntries {
            append(entry.id, .send, entry.title, true)
        }
        for entry in deletedAttachmentEntries {
            append(entry.id, .attachmentRef, entry.fileName, true)
        }

        return descriptors
    }

    /// 关联选择器候选：只允许关联当前分类里仍然可用的条目，且排除自己。
    func linkableItemDescriptors(excluding itemID: String?) -> [VaultItemDescriptor] {
        var seen = Set<String>()
        return vaultItemDescriptors(includeDeleted: false).filter { descriptor in
            guard !descriptor.isDeleted else {
                return false
            }
            if let itemID, descriptor.itemID == itemID {
                return false
            }
            return seen.insert(descriptor.itemID).inserted
        }
    }

    /// 编辑器展示用：关系的目标标题与可用状态。
    func relationDisplay(for relation: VaultItemRelation) -> (title: String, status: VaultItemRelationStatus) {
        let resolved = VaultItemRelationResolver.resolve(
            [relation],
            descriptors: vaultItemDescriptors(includeDeleted: true)
        )
        guard let first = resolved.first else {
            return (String(localized: "条目不存在"), .missing)
        }
        return (first.targetTitle ?? String(localized: "条目不存在"), first.status)
    }

    // MARK: - 编辑器侧表读写

    func loadPresentedItemExtras() {
        guard let mode = presentedEditorMode else {
            clearPresentedItemExtras()
            return
        }
        guard case .edit(let route) = mode else {
            clearPresentedItemExtras()
            return
        }

        presentedItemExtrasItemID = route.entryID
        guard let repository = activeEntryRepository, let projectID = activeProject?.id else {
            presentedCustomFields = []
            presentedRelations = []
            return
        }

        do {
            let extras = try repository.listItemExtras(projectID: projectID)[route.entryID]
            presentedCustomFields = extras?.customFields ?? []
            presentedRelations = extras?.relations ?? []
        } catch {
            presentedCustomFields = []
            presentedRelations = []
        }
    }

    /// 保存编辑器时把侧表一并写入。字段与关系都为空时直接清空这条隐藏记录。
    func persistPresentedItemExtras(itemID: String, itemKind: UnifiedVaultItemKind) throws {
        guard let repository = activeEntryRepository, let projectID = activeProject?.id else {
            return
        }
        let extras = VaultItemExtras(
            itemID: itemID,
            itemKind: itemKind,
            customFields: presentedCustomFields,
            relations: presentedRelations
        ).normalized()

        if extras.isEmpty {
            try repository.deleteItemExtras(projectID: projectID, itemID: itemID)
            return
        }

        let saved = try repository.saveItemExtras(projectID: projectID, extras: extras)
        presentedCustomFields = saved.customFields
        presentedRelations = saved.relations
    }

    func clearPresentedItemExtras() {
        presentedCustomFields = []
        presentedRelations = []
        presentedItemExtrasItemID = nil
    }

    // MARK: - 详情侧表读取

    func loadPresentedDetailExtras() {
        presentedDetailExtras = nil
        guard let route = presentedDetailRoute,
              let repository = activeEntryRepository,
              let projectID = activeProject?.id
        else {
            return
        }
        presentedDetailExtras = try? repository.listItemExtras(projectID: projectID)[route.entryID]
    }

    func resolvedPresentedDetailRelations() -> [VaultItemResolvedRelation] {
        guard let extras = presentedDetailExtras, !extras.relations.isEmpty else {
            return []
        }
        return VaultItemRelationResolver.resolve(
            extras.relations,
            descriptors: vaultItemDescriptors(includeDeleted: true)
        )
    }
}
