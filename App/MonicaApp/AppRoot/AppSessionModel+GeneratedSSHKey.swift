import Foundation
import MonicaCore
import MonicaStorage

/// 生成器保存 SSH 密钥时的参数校验错误。
enum AppGeneratedSSHSaveError: LocalizedError, Equatable {
    case missingTitle
    case missingPrivateKey
    case vaultLocked
    case storeWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingTitle:
            return String(localized: "请填写 SSH 密钥标题。")
        case .missingPrivateKey:
            return String(localized: "私钥为空，无法保存。")
        case .vaultLocked:
            return String(localized: "请先解锁保险库再保存 SSH 密钥。")
        case .storeWriteFailed(let message):
            return message
        }
    }
}

extension AppSessionModel {
    /// 把生成器里的 SSH 密钥保存为 SSH 条目（#154）。
    ///
    /// 私钥只写入钥匙串（`KeychainSSHPrivateKeyStore`，WhenUnlockedThisDeviceOnly），
    /// 条目本身只保存公钥、指纹、钥匙串引用和位数。写入顺序是「私钥 → 条目」：
    /// 条目创建失败时回滚刚写入的私钥，避免留下指向空引用的半成品条目。
    @discardableResult
    func saveGeneratedSSHKey(
        title: String,
        keyPair: SSHKeyPair,
        username: String = "",
        host: String = "",
        passphraseHint: String = "",
        notes: String = "",
        projectTitle: String? = nil
    ) throws -> LocalSshKeyEntry {
        recordUserActivity()
        entryOperationState = .running

        var storedReference: String?
        var createdEntry = false

        do {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else {
                throw AppGeneratedSSHSaveError.missingTitle
            }
            guard !keyPair.privateKeyOpenSSH.isEmpty else {
                throw AppGeneratedSSHSaveError.missingPrivateKey
            }
            guard vaultState == .unlocked, let entryRepository = activeEntryRepository else {
                throw AppGeneratedSSHSaveError.vaultLocked
            }

            let identifier = UUID().uuidString
            let reference: String
            do {
                reference = try sshPrivateKeyStore.savePrivateKey(
                    keyPair.privateKeyOpenSSH,
                    identifier: identifier
                )
            } catch {
                throw AppGeneratedSSHSaveError.storeWriteFailed(error.localizedDescription)
            }
            storedReference = reference

            let resolvedProjectTitle = projectTitle ?? activeVaultName ?? String(localized: "个人")
            let project = try ensureActiveProject(
                projectTitle: resolvedProjectTitle,
                entryRepository: entryRepository
            )

            let entry = try entryRepository.createSshKeyEntry(
                projectID: project.id,
                draft: LocalSshKeyEntryDraft(
                    title: trimmedTitle,
                    username: username,
                    host: host,
                    publicKey: keyPair.publicKeyOpenSSH,
                    privateKeyReference: reference,
                    passphraseHint: passphraseHint,
                    notes: notes,
                    algorithm: keyPair.algorithm.rawValue,
                    keySize: keyPair.keySize,
                    fingerprint: keyPair.fingerprintSHA256
                )
            )
            createdEntry = true

            sshKeyEntries = try entryRepository.listSshKeyEntries(projectID: project.id)
            deletedSshKeyEntries = try entryRepository.listDeletedSshKeyEntries(projectID: project.id)
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .sshKey,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
            return entry
        } catch {
            if let storedReference, !createdEntry {
                try? sshPrivateKeyStore.deletePrivateKey(reference: storedReference)
            }
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }
}
