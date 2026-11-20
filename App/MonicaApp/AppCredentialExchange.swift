import AuthenticationServices
import MonicaStorage
import SwiftUI
import UIKit

/// 凭据交换的 App 会话状态。密码/TOTP 预览只保存在内存里，落库发生在用户确认之后。
struct AppCredentialExchangeState {
    var pendingImportToken: UUID?
    var isFetchingImport = false
    var importPreview: AppCredentialExchangeImportPreview?
    var importError: String?
    var isImporting = false
    var exportPlan: CredentialExchangeExportPlan?
    var exportError: String?
    var isExporting = false
    var exportMessage: String?

    var hasPendingImport: Bool {
        pendingImportToken != nil
    }
}

struct AppCredentialExchangeImportPreview {
    let plan: CredentialExchangeImportPlan
    let exporterDisplayName: String
    let formatVersion: String
}

/// 系统 `ASImportedCredentialData` 与本仓库平台无关模型之间的桥接。
@available(iOS 26.0, *)
enum AppCredentialExchangeBridge {
    static func accounts(from data: ASExportedCredentialData) -> [CredentialExchangeAccount] {
        data.accounts.map { account in
            CredentialExchangeAccount(
                userName: account.userName,
                email: account.email,
                fullName: account.fullName,
                items: account.items.map { item in
                    CredentialExchangeItem(
                        title: item.title,
                        urls: item.scope?.urls.map(\.absoluteString) ?? [],
                        favorite: item.favorite,
                        credentials: item.credentials.map(neutralCredential)
                    )
                }
            )
        }
    }

    static func exportedData(from plan: CredentialExchangeExportPlan) -> ASExportedCredentialData {
        let accounts = [plan.account].map { account in
            ASImportableAccount(
                id: Data("cxf-account-\(account.userName)".utf8),
                userName: account.userName,
                email: account.email,
                fullName: account.fullName,
                collections: [],
                items: account.items.enumerated().map { index, item in
                    ASImportableItem(
                        id: Data("cxf-item-\(index)".utf8),
                        created: Date(),
                        lastModified: Date(),
                        title: item.title,
                        subtitle: nil,
                        favorite: item.favorite,
                        scope: scope(for: item.urls),
                        credentials: item.credentials.compactMap(appleCredential),
                        tags: []
                    )
                }
            )
        }
        return ASExportedCredentialData(
            accounts: accounts,
            formatVersion: .v1,
            exporterRelyingPartyIdentifier: "com.monicapass.monica",
            exporterDisplayName: "Monica",
            timestamp: Date()
        )
    }

    private static func neutralCredential(_ credential: ASImportableCredential) -> CredentialExchangeCredential {
        switch credential {
        case .basicAuthentication(let authentication):
            return .password(CredentialExchangePassword(
                userName: authentication.userName?.value ?? "",
                password: authentication.password?.value ?? ""
            ))
        case .totp(let totp):
            return .totp(CredentialExchangeTOTP(
                secret: String(decoding: totp.secret, as: UTF8.self),
                period: UInt32(totp.period),
                digits: UInt32(totp.digits),
                accountName: totp.userName ?? "",
                issuer: totp.issuer ?? "",
                algorithm: algorithmName(totp.algorithm)
            ))
        case .passkey:
            return .unsupported(label: "通行密钥")
        default:
            return .unsupported(label: "不支持的凭据")
        }
    }

    private static func appleCredential(_ credential: CredentialExchangeCredential) -> ASImportableCredential? {
        switch credential {
        case .password(let password):
            return .basicAuthentication(ASImportableCredential.BasicAuthentication(
                userName: ASImportableEditableField(
                    id: nil,
                    fieldType: .string,
                    value: password.userName,
                    label: nil
                ),
                password: ASImportableEditableField(
                    id: nil,
                    fieldType: .concealedString,
                    value: password.password,
                    label: nil
                )
            ))
        case .totp(let totp):
            return .totp(ASImportableCredential.TOTP(
                secret: Data(totp.secret.utf8),
                period: UInt16(clamping: totp.period),
                digits: UInt16(clamping: totp.digits),
                userName: totp.accountName.isEmpty ? nil : totp.accountName,
                algorithm: appleAlgorithm(totp.algorithm),
                issuer: totp.issuer.isEmpty ? nil : totp.issuer
            ))
        case .unsupported:
            return nil
        }
    }

    private static func scope(for urls: [String]) -> ASImportableCredentialScope? {
        let parsed = urls.compactMap { URL(string: $0) }
        guard !parsed.isEmpty else { return nil }
        return ASImportableCredentialScope(urls: parsed, androidApps: [])
    }

    private static func algorithmName(_ algorithm: ASImportableCredential.TOTP.Algorithm) -> String {
        switch algorithm {
        case .sha1:
            return "SHA1"
        case .sha256:
            return "SHA256"
        case .sha512:
            return "SHA512"
        @unknown default:
            return "SHA1"
        }
    }

    private static func appleAlgorithm(_ algorithm: String) -> ASImportableCredential.TOTP.Algorithm {
        switch algorithm.uppercased() {
        case "SHA256":
            return .sha256
        case "SHA512":
            return .sha512
        default:
            return .sha1
        }
    }
}

@available(iOS 26.0, *)
@MainActor
enum AppCredentialExchangePresenter {
    static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
}

/// 声明接收 CXF 导入 activity；低版本系统不注册任何相关类型。
struct CredentialExchangeActivityModifier: ViewModifier {
    let perform: (NSUserActivity) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.onContinueUserActivity(ASCredentialExchangeActivity, perform: perform)
        } else {
            content
        }
    }
}

extension View {
    func handlesCredentialExchangeActivity(perform: @escaping (NSUserActivity) -> Void) -> some View {
        modifier(CredentialExchangeActivityModifier(perform: perform))
    }
}

struct CredentialExchangeImportSheet: View {
    @Bindable var session: AppSessionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let preview = session.credentialExchange.importPreview {
                        previewContent(preview)
                    } else if session.credentialExchange.isFetchingImport {
                        fetchingContent
                    } else {
                        unavailableContent
                    }
                }
                .padding(20)
            }
            .background(AndroidParityPalette.background.ignoresSafeArea())
            .navigationTitle("系统导入凭据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        session.cancelCredentialExchangeImport()
                        dismiss()
                    }
                }
            }
        }
    }

    private var fetchingContent: some View {
        AndroidParityCard {
            HStack(spacing: 12) {
                ProgressView()
                Text("正在从系统读取凭据…")
                    .font(.subheadline)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }
    }

    private var unavailableContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("没有可导入的凭据")
                .font(.headline)
            if let error = session.credentialExchange.importError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("本地保险库没有发生任何改动。")
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AndroidParityPalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func previewContent(_ preview: AppCredentialExchangeImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            AndroidParityCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("来自 \(preview.exporterDisplayName.isEmpty ? "其他密码管理器" : preview.exporterDisplayName)")
                        .font(.headline)
                    Text("格式版本 \(preview.formatVersion)")
                        .font(.caption)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
            }

            AndroidParityCard {
                VStack(alignment: .leading, spacing: 4) {
                    AndroidParityInfoRow(title: "密码", value: "\(preview.plan.passwordCount)")
                    AndroidParityInfoRow(title: "TOTP", value: "\(preview.plan.totpCount)")
                    if preview.plan.skippedDuplicateCount > 0 {
                        AndroidParityInfoRow(title: "重复跳过", value: "\(preview.plan.skippedDuplicateCount)")
                    }
                    if preview.plan.unsupportedCredentialCount > 0 {
                        AndroidParityInfoRow(title: "暂不支持", value: "\(preview.plan.unsupportedCredentialCount)")
                    }
                    if preview.plan.invalidCredentialCount > 0 {
                        AndroidParityInfoRow(title: "无效数据", value: "\(preview.plan.invalidCredentialCount)")
                    }
                }
            }

            Text("Passkey 私钥不会通过 CXF 迁移。导入会在当前保险库中新建「凭据交换」项目，且重复条目会自动跳过。")
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = session.credentialExchange.importError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                do {
                    try session.confirmCredentialExchangeImport()
                    dismiss()
                } catch {
                    // 失败原因由 session 写入 importError，并保留预览供重试或取消。
                }
            } label: {
                HStack {
                    if session.credentialExchange.isImporting {
                        ProgressView()
                            .tint(.white)
                    }
                    Text("导入 \(preview.plan.importableCount) 项")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AndroidParityPalette.primary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(session.credentialExchange.isImporting || preview.plan.isEmpty)

            Text("取消后不会写入任何数据。")
                .font(.caption)
                .foregroundStyle(AndroidParityPalette.textSecondary)
        }
    }
}

struct CredentialExchangeExportSheet: View {
    @Bindable var session: AppSessionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let plan = session.credentialExchange.exportPlan {
                        planContent(plan)
                    } else {
                        Text("没有待导出的条目。")
                            .font(.subheadline)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }
                }
                .padding(20)
            }
            .background(AndroidParityPalette.background.ignoresSafeArea())
            .navigationTitle("导出到其他密码管理器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        session.cancelCredentialExchangeExport()
                        dismiss()
                    }
                }
            }
        }
    }

    private func planContent(_ plan: CredentialExchangeExportPlan) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            AndroidParityCard {
                VStack(alignment: .leading, spacing: 4) {
                    AndroidParityInfoRow(title: "密码", value: "\(plan.passwordCount)")
                    AndroidParityInfoRow(title: "TOTP", value: "\(plan.totpCount)")
                    if plan.skippedCount > 0 {
                        AndroidParityInfoRow(title: "无法导出", value: "\(plan.skippedCount)")
                    }
                }
            }

            if plan.skippedCount > 0 {
                Text("有 \(plan.skippedCount) 条 TOTP 密钥不是有效的 Base32，已跳过，不会写入导出数据。")
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("下一步会由系统选择接收方 App。Passkey、备注、卡片、身份等类型不会导出。")
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = session.credentialExchange.exportError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task {
                    if await session.performCredentialExchangeExport() {
                        dismiss()
                    }
                }
            } label: {
                HStack {
                    if session.credentialExchange.isExporting {
                        ProgressView()
                            .tint(.white)
                    }
                    Text("开始导出")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AndroidParityPalette.primary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(session.credentialExchange.isExporting)
        }
    }
}
