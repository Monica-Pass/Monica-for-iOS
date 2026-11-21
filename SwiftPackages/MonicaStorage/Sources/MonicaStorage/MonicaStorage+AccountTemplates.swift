// MARK: - 账号模板侧表：MDBX 引擎实现（模板类型见 AccountTemplates.swift）

import Foundation
import MonicaMDBX

extension MDBXLocalVaultEngine {
    public func listAccountTemplates(
        in handle: LocalVaultHandle,
        anchorProjectID: String
    ) throws -> [AccountTemplate] {
        let entries = try vault(for: handle).listParityEntries(
            projectID: anchorProjectID,
            entryType: AccountTemplate.entryType,
            kind: AccountTemplate.entryKind
        )
        return entries.compactMap { entry in
            AccountTemplate(payloadJSON: entry.payloadJSON, fallbackTemplateID: entry.title)
        }
    }

    public func saveAccountTemplate(
        in handle: LocalVaultHandle,
        anchorProjectID: String,
        template: AccountTemplate
    ) throws {
        guard !template.templateID.isEmpty else {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        let payloadJSON = try template.payloadJSONString()
        let vault = try vault(for: handle)
        let existingEntries = try vault.listParityEntries(
            projectID: anchorProjectID,
            entryType: AccountTemplate.entryType,
            kind: AccountTemplate.entryKind
        )
        if let existing = existingEntries.first(where: { accountTemplateEntry($0, matchesTemplateID: template.templateID) }) {
            _ = try vault.updateParityEntry(
                projectID: anchorProjectID,
                entryID: existing.id,
                entryType: AccountTemplate.entryType,
                kind: AccountTemplate.entryKind,
                title: template.templateID,
                payloadJSON: payloadJSON
            )
            return
        }
        // 同一个 templateID 可能还在回收站（导入覆盖时先删后写），优先恢复旧记录。
        let deletedEntries = try vault.listDeletedParityEntries(
            projectID: anchorProjectID,
            entryType: AccountTemplate.entryType,
            kind: AccountTemplate.entryKind
        )
        if let deletedEntry = deletedEntries.first(where: { accountTemplateEntry($0, matchesTemplateID: template.templateID) }) {
            _ = try vault.restoreParityEntry(
                projectID: anchorProjectID,
                entryID: deletedEntry.id,
                entryType: AccountTemplate.entryType,
                kind: AccountTemplate.entryKind
            )
            _ = try vault.updateParityEntry(
                projectID: anchorProjectID,
                entryID: deletedEntry.id,
                entryType: AccountTemplate.entryType,
                kind: AccountTemplate.entryKind,
                title: template.templateID,
                payloadJSON: payloadJSON
            )
            return
        }
        _ = try vault.createParityEntry(
            projectID: anchorProjectID,
            entryType: AccountTemplate.entryType,
            kind: AccountTemplate.entryKind,
            title: template.templateID,
            payloadJSON: payloadJSON
        )
    }

    public func deleteAccountTemplate(
        in handle: LocalVaultHandle,
        anchorProjectID: String,
        templateID: String
    ) throws {
        let vault = try vault(for: handle)
        let entries = try vault.listParityEntries(
            projectID: anchorProjectID,
            entryType: AccountTemplate.entryType,
            kind: AccountTemplate.entryKind
        )
        guard let entry = entries.first(where: { accountTemplateEntry($0, matchesTemplateID: templateID) }) else {
            return
        }
        _ = try vault.deleteParityEntry(
            projectID: anchorProjectID,
            entryID: entry.id,
            entryType: AccountTemplate.entryType,
            kind: AccountTemplate.entryKind
        )
    }

    private func accountTemplateEntry(_ entry: MonicaMDBXParityEntry, matchesTemplateID templateID: String) -> Bool {
        if let record = AccountTemplate(payloadJSON: entry.payloadJSON, fallbackTemplateID: entry.title) {
            return record.templateID == templateID
        }
        return entry.title == templateID
    }
}
