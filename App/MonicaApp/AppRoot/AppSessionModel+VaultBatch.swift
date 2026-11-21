import Foundation
import MonicaStorage

// slice B: VaultBatch 域，从 AppSessionModel.swift 逐字搬移。
extension AppSessionModel {
    func applyVaultQuickFilter(_ filterID: String) {
        guard vaultQuickFilterRows.contains(where: { $0.id == filterID }) else {
            return
        }
        clearVaultBatchSelection()
        clearVaultSearchQueries()
        setAllFavoriteFilters(filterID == "favorites")
        selectedVaultQuickFilterID = filterID
    }

    var isVaultBatchSelectionActive: Bool {
        vaultBatchSelectionKind != nil
    }

    var activeVaultBatchSelectionKind: UnifiedVaultItemKind? {
        vaultBatchSelectionKind
    }

    var vaultBatchSelectionTitle: String {
        if !isVaultBatchSelectionActive {
            return String(localized: "未选择")
        }
        return selectedVaultBatchItemIDs.isEmpty
            ? String(localized: "选择条目")
            : String(localized: "已选择 \(selectedVaultBatchItemIDs.count) 项")
    }

    var canDeleteSelectedVaultBatchItems: Bool {
        isVaultBatchSelectionActive && !isTrashQuickFilterSelected && !selectedVaultBatchItemIDs.isEmpty
    }

    var canRestoreSelectedVaultBatchItems: Bool {
        isVaultBatchSelectionActive && isTrashQuickFilterSelected && !selectedVaultBatchItemIDs.isEmpty
    }

    var canMoveSelectedVaultBatchItems: Bool {
        isVaultBatchSelectionActive
            && !isTrashQuickFilterSelected
            && !selectedVaultBatchItemIDs.isEmpty
            && !availableVaultBatchMoveTargets.isEmpty
    }

    var availableVaultBatchMoveTargets: [LocalVaultProject] {
        guard let activeProject else {
            return []
        }
        return vaultProjects.filter { $0.id != activeProject.id }
    }

    func enterVaultBatchSelection(for kind: UnifiedVaultItemKind) {
        vaultBatchSelectionKind = kind
        selectedVaultBatchItemIDs = selectedVaultBatchItemIDs.intersection(visibleVaultBatchItemIDs(for: kind))
        recordUserActivity()
    }

    func clearVaultBatchSelection() {
        vaultBatchSelectionKind = nil
        selectedVaultBatchItemIDs = []
    }

    func toggleVaultBatchItemSelection(_ itemID: String, for kind: UnifiedVaultItemKind) {
        if vaultBatchSelectionKind != kind {
            selectedVaultBatchItemIDs = []
            vaultBatchSelectionKind = kind
        }
        if selectedVaultBatchItemIDs.contains(itemID) {
            selectedVaultBatchItemIDs.remove(itemID)
        } else if visibleVaultBatchItemIDs(for: kind).contains(itemID) {
            selectedVaultBatchItemIDs.insert(itemID)
        }
        recordUserActivity()
    }

    func toggleVaultBatchItemSelection(id itemID: String) {
        guard let kind = vaultBatchSelectionKind else {
            return
        }
        toggleVaultBatchItemSelection(itemID, for: kind)
    }

    func selectAllVisibleVaultBatchItems(for kind: UnifiedVaultItemKind) {
        vaultBatchSelectionKind = kind
        selectedVaultBatchItemIDs = visibleVaultBatchItemIDs(for: kind)
        recordUserActivity()
    }

    func deleteSelectedVaultBatchItems() throws {
        guard let kind = vaultBatchSelectionKind, canDeleteSelectedVaultBatchItems else {
            return
        }
        try mutateSelectedVaultBatchItems(kind: kind, action: .deleted)
    }

    func restoreSelectedVaultBatchItems() throws {
        guard let kind = vaultBatchSelectionKind, canRestoreSelectedVaultBatchItems else {
            return
        }
        try mutateSelectedVaultBatchItems(kind: kind, action: .restored)
    }

    func moveSelectedVaultBatchItems(toProjectID targetProjectID: String) throws {
        guard let kind = vaultBatchSelectionKind, canMoveSelectedVaultBatchItems else {
            return
        }
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let sourceProjectID = activeProject?.id,
                  vaultProjects.contains(where: { $0.id == targetProjectID })
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let orderedIDs = visibleVaultBatchItemOrder(for: kind)
                .filter { selectedVaultBatchItemIDs.contains($0) }
            guard !orderedIDs.isEmpty else {
                clearVaultBatchSelection()
                entryOperationState = .idle
                return
            }

            let events = try moveVaultBatchItems(
                kind: kind,
                ids: orderedIDs,
                fromProjectID: sourceProjectID,
                toProjectID: targetProjectID,
                entryRepository: entryRepository
            )

            try refreshAllEntryLists(projectID: sourceProjectID, entryRepository: entryRepository)
            clearVaultSearchQueries()
            if kind == .login {
                try refreshAutoFillEncryptedIndexIfConfigured()
            }
            for event in events {
                appendOperationTimelineEvent(
                    action: .moved,
                    itemKind: kind,
                    itemID: event.id,
                    itemTitle: event.title
                )
            }
            clearVaultBatchSelection()
            entryOperationState = .succeeded(String(localized: "已移动 \(events.count) 项"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func visibleVaultBatchItemIDs(for kind: UnifiedVaultItemKind) -> Set<String> {
        Set(visibleVaultBatchItemOrder(for: kind))
    }

    func visibleVaultBatchItemOrder(for kind: UnifiedVaultItemKind) -> [String] {
        if isTrashQuickFilterSelected {
            switch kind {
            case .login:
                return deletedLoginEntries.map(\.id)
            case .totp:
                return deletedTotpEntries.map(\.id)
            case .note:
                return deletedNoteEntries.map(\.id)
            case .card:
                return deletedCardEntries.map(\.id)
            case .identity:
                return deletedIdentityEntries.map(\.id)
            case .passkey:
                return deletedPasskeyEntries.map(\.id)
            case .sshKey:
                return deletedSshKeyEntries.map(\.id)
            case .gpgKey:
                return deletedGPGKeyEntries.map(\.id)
            case .apiToken:
                return deletedApiTokenEntries.map(\.id)
            case .wifi:
                return deletedWifiEntries.map(\.id)
            case .sso:
                return deletedSSOEntries.map(\.id)
            case .barcode:
                return deletedBarcodeEntries.map(\.id)
            case .send:
                return deletedSendEntries.map(\.id)
            case .steam:
                return deletedSteamEntries.map(\.id)
            case .billingAddress:
                return deletedBillingAddressEntries.map(\.id)
            case .paymentAccount:
                return deletedPaymentAccountEntries.map(\.id)
            case .attachmentRef:
                return deletedAttachmentEntries.map(\.id)
            }
        }

        switch kind {
        case .login:
            return filteredLoginEntries.map(\.id)
        case .totp:
            return filteredTotpEntries.map(\.id)
        case .note:
            return filteredNoteEntries.map(\.id)
        case .card:
            return filteredCardEntries.map(\.id)
        case .identity:
            return filteredIdentityEntries.map(\.id)
        case .passkey:
            return filteredPasskeyEntries.map(\.id)
        case .sshKey:
            return filteredSshKeyEntries.map(\.id)
        case .gpgKey:
            return filteredGPGKeyEntries.map(\.id)
        case .apiToken:
            return filteredApiTokenEntries.map(\.id)
        case .wifi:
            return filteredWifiEntries.map(\.id)
        case .sso:
            return filteredSSOEntries.map(\.id)
        case .barcode:
            return filteredBarcodeEntries.map(\.id)
        case .send:
            return filteredSendEntries.map(\.id)
        case .steam:
            return filteredSteamEntries.map(\.id)
        case .billingAddress:
            return filteredBillingAddressEntries.map(\.id)
        case .paymentAccount:
            return filteredPaymentAccountEntries.map(\.id)
        case .attachmentRef:
            return filteredAttachmentEntries.map(\.id)
        }
    }

    func mutateSelectedVaultBatchItems(
        kind: UnifiedVaultItemKind,
        action: AppOperationTimelineAction
    ) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let orderedIDs = visibleVaultBatchItemOrder(for: kind)
                .filter { selectedVaultBatchItemIDs.contains($0) }
            guard !orderedIDs.isEmpty else {
                clearVaultBatchSelection()
                entryOperationState = .idle
                return
            }

            let events: [(id: String, title: String)]
            switch action {
            case .deleted:
                events = try deleteVaultBatchItems(
                    kind: kind,
                    ids: orderedIDs,
                    projectID: projectID,
                    entryRepository: entryRepository
                )
            case .restored:
                events = try restoreVaultBatchItems(
                    kind: kind,
                    ids: orderedIDs,
                    projectID: projectID,
                    entryRepository: entryRepository
                )
            case .created, .updated, .moved, .viewed, .backedUp, .restoredBackup, .cleanedUp, .synced, .blocked:
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            try refreshAllEntryLists(projectID: projectID, entryRepository: entryRepository)
            if kind == .login {
                try refreshAutoFillEncryptedIndexIfConfigured()
            }
            for event in events {
                appendOperationTimelineEvent(
                    action: action,
                    itemKind: kind,
                    itemID: event.id,
                    itemTitle: event.title
                )
            }
            clearVaultBatchSelection()
            let verb = action == .deleted ? String(localized: "删除") : String(localized: "恢复")
            entryOperationState = .succeeded(String(localized: "已\(verb) \(events.count) 项"))
            haptics.play(action == .deleted ? .error : .success)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            haptics.play(.error)
            throw error
        }
    }

    func deleteVaultBatchItems(
        kind: UnifiedVaultItemKind,
        ids: [String],
        projectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> [(id: String, title: String)] {
        var events: [(id: String, title: String)] = []
        for id in ids {
            switch kind {
            case .login:
                guard let entry = loginEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteLoginEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .totp:
                guard let entry = totpEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteTotpEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .note:
                guard let entry = noteEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteNoteEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .card:
                guard let entry = cardEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteCardEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .identity:
                guard let entry = identityEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteIdentityEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .passkey:
                guard let entry = passkeyEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deletePasskeyEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .sshKey:
                guard let entry = sshKeyEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteSshKeyEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .gpgKey:
                guard let entry = gpgKeyEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteGPGKeyEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .apiToken:
                guard let entry = apiTokenEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteApiTokenEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .wifi:
                guard let entry = wifiEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteWifiEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .sso:
                guard let entry = ssoEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteSSOEntry(projectID: projectID, entryID: id)
            case .barcode:
                guard let entry = barcodeEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteBarcodeEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .send:
                guard let entry = sendEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteSendEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .steam:
                guard let entry = steamEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteSteamEntry(projectID: projectID, entryID: id)
            case .billingAddress:
                guard let entry = billingAddressEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteBillingAddressEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .paymentAccount:
                guard let entry = paymentAccountEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deletePaymentAccountEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .attachmentRef:
                guard let entry = attachmentEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteAttachmentMetadata(projectID: projectID, attachmentID: id)
                events.append((id, entry.fileName))
            }
        }
        return events
    }

    func restoreVaultBatchItems(
        kind: UnifiedVaultItemKind,
        ids: [String],
        projectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> [(id: String, title: String)] {
        var events: [(id: String, title: String)] = []
        for id in ids {
            switch kind {
            case .login:
                let entry = try entryRepository.restoreLoginEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .totp:
                let entry = try entryRepository.restoreTotpEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .note:
                let entry = try entryRepository.restoreNoteEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .card:
                let entry = try entryRepository.restoreCardEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .identity:
                let entry = try entryRepository.restoreIdentityEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .passkey:
                let entry = try entryRepository.restorePasskeyEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .sshKey:
                let entry = try entryRepository.restoreSshKeyEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .gpgKey:
                let entry = try entryRepository.restoreGPGKeyEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .apiToken:
                let entry = try entryRepository.restoreApiTokenEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .wifi:
                let entry = try entryRepository.restoreWifiEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .sso:
                let entry = try entryRepository.restoreSSOEntry(projectID: projectID, entryID: id)
            case .barcode:
                let entry = try entryRepository.restoreBarcodeEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .send:
                let entry = try entryRepository.restoreSendEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .steam:
                let entry = try entryRepository.restoreSteamEntry(projectID: projectID, entryID: id)
            case .billingAddress:
                let entry = try entryRepository.restoreBillingAddressEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .paymentAccount:
                let entry = try entryRepository.restorePaymentAccountEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .attachmentRef:
                let entry = try entryRepository.restoreAttachmentMetadata(projectID: projectID, attachmentID: id)
                events.append((id, entry.fileName))
            }
        }
        return events
    }

    func moveVaultBatchItems(
        kind: UnifiedVaultItemKind,
        ids: [String],
        fromProjectID: String,
        toProjectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> [(id: String, title: String)] {
        // issue #28：批量迁移复用 moveEntries——先预检、逐条迁移后校验侧表与附件引用，
        // 任何一条失败都会按逆序回滚，源分类不会丢数据。
        let items = ids.map { id in
            VaultBatchMigrationItem(
                id: id,
                kind: kind,
                title: vaultBatchItemTitle(kind: kind, id: id)
            )
        }
        let outcome = try entryRepository.moveEntries(
            items,
            fromProjectID: fromProjectID,
            toProjectID: toProjectID
        )
        return outcome.movedEntries.map { (id: $0.id, title: $0.title) }
    }

    /// 批量迁移失败时用可读标题提示，取不到时退回条目 id。
    func vaultBatchItemTitle(kind: UnifiedVaultItemKind, id: String) -> String {
        switch kind {
        case .login:
            return loginEntries.first { $0.id == id }?.title ?? id
        case .note:
            return noteEntries.first { $0.id == id }?.title ?? id
        case .totp:
            return totpEntries.first { $0.id == id }?.title ?? id
        case .card:
            return cardEntries.first { $0.id == id }?.title ?? id
        case .identity:
            return identityEntries.first { $0.id == id }?.title ?? id
        case .passkey:
            return passkeyEntries.first { $0.id == id }?.title ?? id
        case .sshKey:
            return sshKeyEntries.first { $0.id == id }?.title ?? id
        case .apiToken:
            return apiTokenEntries.first { $0.id == id }?.title ?? id
        case .wifi:
            return wifiEntries.first { $0.id == id }?.title ?? id
        case .sso:
            return ssoEntries.first { $0.id == id }?.title ?? id
        case .send:
            return sendEntries.first { $0.id == id }?.title ?? id
        case .steam:
            return steamEntries.first { $0.id == id }?.title ?? id
        case .barcode:
            return barcodeEntries.first { $0.id == id }?.title ?? id
        case .billingAddress:
            return billingAddressEntries.first { $0.id == id }?.title ?? id
        case .paymentAccount:
            return paymentAccountEntries.first { $0.id == id }?.title ?? id
        case .gpgKey:
            return gpgKeyEntries.first { $0.id == id }?.title ?? id
        case .attachmentRef:
            return attachmentEntries.first { $0.id == id }?.fileName ?? id
        }
    }
}
