import MonicaCore
import MonicaStorage
import SwiftUI

/// CXF 通行密钥在导入/导出过程中逐条降级出来的可读问题。
///
/// 单条数据损坏、缺少私钥、钥匙串拒绝访问或与现有条目重复时，只把这一条记成问题，
/// 其余条目继续处理，绝不整批失败。
struct AppCredentialExchangeIssue: Identifiable, Equatable {
    enum Reason: String, Equatable {
        case invalidData
        case missingPrivateKey
        case accessDenied
        case storageFailure
        case duplicate
    }

    let title: String
    let relyingPartyIdentifier: String
    let reason: Reason

    var id: String {
        "\(reason.rawValue)|\(relyingPartyIdentifier)|\(title)"
    }

    var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { return trimmedTitle }
        let trimmedRelyingParty = relyingPartyIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRelyingParty.isEmpty { return trimmedRelyingParty }
        return String(localized: "未命名条目")
    }

    var message: String {
        switch reason {
        case .invalidData:
            return String(localized: "条目数据不完整或格式无效，已跳过。")
        case .missingPrivateKey:
            return String(localized: "找不到对应的私钥，已跳过。")
        case .accessDenied:
            return String(localized: "系统拒绝了安全存储访问，已跳过。")
        case .storageFailure:
            return String(localized: "安全存储操作失败，已跳过。")
        case .duplicate:
            return String(localized: "与保险库中已有条目重复，已跳过。")
        }
    }
}

extension AppCredentialExchangeIssue {
    /// 平台无关层已经判定为坏数据/重复的条目。
    init(storageIssue issue: CredentialExchangePasskeyIssue) {
        let reason: Reason
        switch issue.reason {
        case .duplicate:
            reason = .duplicate
        case .missingCredentialID, .missingRelyingPartyIdentifier, .missingUserHandle, .missingPrivateKey:
            reason = .invalidData
        }
        self.init(
            title: issue.title,
            relyingPartyIdentifier: issue.relyingPartyIdentifier,
            reason: reason
        )
    }

    /// 加密层抛出的错误：缺私钥、钥匙串拒绝、数据无效或存储失败。
    init(error: Error, title: String, relyingPartyIdentifier: String = "") {
        let reason: Reason
        if let exchangeError = error as? PasskeyExchangeError {
            switch exchangeError {
            case .privateKeyNotFound:
                reason = .missingPrivateKey
            case .privateKeyAccessDenied:
                reason = .accessDenied
            case .invalidCredentialID,
                 .invalidRelyingPartyID,
                 .invalidUsername,
                 .invalidUserHandle,
                 .invalidPrivateKey:
                reason = .invalidData
            case .privateKeyReferenceMismatch,
                 .privateKeyStoreFailure,
                 .keychainUnexpectedStatus:
                reason = .storageFailure
            }
        } else {
            reason = .storageFailure
        }
        self.init(
            title: title,
            relyingPartyIdentifier: relyingPartyIdentifier,
            reason: reason
        )
    }
}

/// 逐条问题列表：每个问题都能看到条目标题与降级原因。
struct AppCredentialExchangeIssueList: View {
    let title: String
    let issues: [AppCredentialExchangeIssue]

    var body: some View {
        if !issues.isEmpty {
            AndroidParityCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.displayTitle)
                                .font(.footnote)
                            Text(issue.message)
                                .font(.caption)
                                .foregroundStyle(AndroidParityPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// 导出前只做元数据检查（不读私钥），把明显无效的条目提前列成问题。
enum AppCredentialExchangePasskeys {
    struct ExportCandidates {
        let entries: [LocalPasskeyEntry]
        let issues: [AppCredentialExchangeIssue]
    }

    static func exportCandidates(from entries: [LocalPasskeyEntry]) -> ExportCandidates {
        var usable: [LocalPasskeyEntry] = []
        var issues: [AppCredentialExchangeIssue] = []
        for entry in entries {
            let hasCredentialID = !entry.credentialID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasUserHandle = !entry.userHandle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard hasCredentialID,
                  hasUserHandle,
                  Data(base64Encoded: entry.credentialID) != nil,
                  let userHandle = Data(base64Encoded: entry.userHandle),
                  !userHandle.isEmpty,
                  PasskeyRelyingPartyIDNormalizer.normalize(entry.relyingPartyID) != nil
            else {
                issues.append(AppCredentialExchangeIssue(
                    title: entry.title,
                    relyingPartyIdentifier: entry.relyingPartyID,
                    reason: .invalidData
                ))
                continue
            }
            usable.append(entry)
        }
        return ExportCandidates(entries: usable, issues: issues)
    }
}

extension PasskeyExchangeCredential {
    /// 平台无关 CXF 通行密钥 → 加密层可接受的输入（私钥仍是 CXF 的 PKCS#8 DER）。
    init(_ passkey: CredentialExchangePasskey) {
        self.init(
            credentialID: passkey.credentialID,
            relyingPartyID: passkey.relyingPartyIdentifier,
            userName: passkey.userName,
            userDisplayName: passkey.userDisplayName,
            userHandle: passkey.userHandle,
            privateKey: passkey.privateKey
        )
    }
}

extension CredentialExchangePasskey {
    /// 加密层读出的通行密钥 → 平台无关 CXF 模型，交给系统导出面板。
    init(_ credential: PasskeyExchangeCredential) {
        self.init(
            credentialID: credential.credentialID,
            relyingPartyIdentifier: credential.relyingPartyID,
            userName: credential.userName,
            userDisplayName: credential.userDisplayName,
            userHandle: credential.userHandle,
            privateKey: credential.privateKey
        )
    }
}
