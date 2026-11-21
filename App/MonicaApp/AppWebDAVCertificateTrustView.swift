import MonicaSync
import SwiftUI

/// WebDAV 证书信任（Trust On First Use）。
///
/// 安全模型：
/// - 系统信任链直接放行，只有系统不信任的自签名 / 私有 CA 证书才落到 TOFU；
/// - 首次连接只展示指纹，必须由用户确认后才保存 `host:port + 用户名 → SHA-256`；
/// - 已保存的指纹发生变化时连接被硬失败阻断，必须由用户确认后才会更新；
/// - 撤销只写墓碑（保留指纹），下次连接重新进入「待确认」，不会静默放行。
@MainActor
extension AppSessionModel {
    /// 重新读取 Keychain 中的指纹记录，供设置页展示。
    func refreshWebDAVCertificateTrustRecords() {
        do {
            webDAVCertificateTrustRecords = try webDAVCertificateTrustStore
                .allRecords()
                .sorted { $0.identity.storageKey < $1.identity.storageKey }
        } catch {
            webDAVCertificateTrustRecords = []
        }
    }

    /// 用户核对指纹后确认信任。仅由设置页的确认按钮调用。
    @discardableResult
    func trustWebDAVCertificate(_ challenge: WebDAVCertificateChallenge, at date: Date = Date()) -> Bool {
        do {
            try webDAVCertificateTrustStore.save(
                WebDAVTrustedCertificateRecord(
                    identity: challenge.info.identity,
                    fingerprint: challenge.info.fingerprint,
                    subjectSummary: challenge.info.subjectSummary,
                    issuerSummary: challenge.info.issuerSummary,
                    firstTrustedAt: date,
                    trustedAt: date
                )
            )
            webDAVPendingCertificateChallenge = nil
            refreshWebDAVCertificateTrustRecords()
            if case .failed = webDAVBackupState {
                webDAVBackupState = .idle
            }
            return true
        } catch {
            webDAVBackupState = .failed(String(localized: "无法保存 WebDAV 证书指纹，请稍后重试。"))
            return false
        }
    }

    /// 撤销某个服务器的证书信任；下一次连接会重新询问。
    @discardableResult
    func revokeWebDAVCertificateTrust(for identity: WebDAVTrustIdentity, at date: Date = Date()) -> Bool {
        do {
            try webDAVCertificateTrustStore.revoke(identity: identity, at: date)
            if webDAVPendingCertificateChallenge?.info.identity == identity {
                webDAVPendingCertificateChallenge = nil
            }
            refreshWebDAVCertificateTrustRecords()
            return true
        } catch {
            webDAVBackupState = .failed(String(localized: "无法撤销 WebDAV 证书信任，请稍后重试。"))
            return false
        }
    }

    /// 用户放弃本次信任：只清掉待确认状态，不写入任何记录。
    func dismissWebDAVCertificateChallenge() {
        webDAVPendingCertificateChallenge = nil
        if case .failed = webDAVBackupState {
            webDAVBackupState = .idle
        }
    }

    func webDAVCertificateTrustRecord(for identity: WebDAVTrustIdentity) -> WebDAVTrustedCertificateRecord? {
        webDAVCertificateTrustRecords.first { $0.identity == identity }
    }
}

/// 设置 → WebDAV 卡片底部的证书信任区块。
struct AppWebDAVCertificateTrustSection: View {
    let session: AppSessionModel

    @Environment(\.paritySpacingScale) private var spacingScale
    @State private var revokingRecord: WebDAVTrustedCertificateRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * spacingScale) {
            AndroidParityDivider()

            HStack(alignment: .firstTextBaseline, spacing: 8 * spacingScale) {
                Label("证书信任", systemImage: "checkmark.shield")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                Spacer(minLength: 8 * spacingScale)
                Text(String(localized: "自签名证书信任（TOFU）"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }

            Text("首次连接自签名或私有 CA 的 WebDAV 服务器时，请核对下方 SHA-256 指纹后再信任。系统信任的证书无需确认；指纹一旦变化，连接会被阻止。")
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let challenge = session.webDAVPendingCertificateChallenge {
                pendingCertificateView(challenge)
            }

            AndroidParityDivider()

            Text("已信任的服务器")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textPrimary)

            if session.webDAVCertificateTrustRecords.isEmpty {
                Text("尚未信任任何服务器证书。")
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: 12 * spacingScale) {
                    ForEach(session.webDAVCertificateTrustRecords) { record in
                        trustedRecordView(record)
                        if record.id != session.webDAVCertificateTrustRecords.last?.id {
                            AndroidParityDivider()
                        }
                    }
                }
            }

            Button {
                session.refreshWebDAVCertificateTrustRecords()
            } label: {
                Label("刷新信任列表", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
        }
        .task {
            session.refreshWebDAVCertificateTrustRecords()
        }
        .confirmationDialog(
            String(localized: "撤销后，下次连接需要重新确认指纹。"),
            isPresented: Binding(
                get: { revokingRecord != nil },
                set: { isPresented in
                    if !isPresented {
                        revokingRecord = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: revokingRecord
        ) { record in
            Button(String(localized: "撤销信任"), role: .destructive) {
                session.revokeWebDAVCertificateTrust(for: record.identity)
                revokingRecord = nil
            }
            Button(String(localized: "取消"), role: .cancel) {
                revokingRecord = nil
            }
        } message: { record in
            Text(record.identity.displayAddress)
        }
    }

    // MARK: - Pending challenge

    @ViewBuilder
    private func pendingCertificateView(_ challenge: WebDAVCertificateChallenge) -> some View {
        let isChange = challenge.isFingerprintChange
        VStack(alignment: .leading, spacing: 8 * spacingScale) {
            HStack(alignment: .firstTextBaseline, spacing: 8 * spacingScale) {
                Text(isChange ? String(localized: "指纹已变更") : String(localized: "待确认"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isChange ? Color.red : AndroidParityPalette.primary)
                Spacer(minLength: 8 * spacingScale)
                Text(String(localized: "自签名或私有 CA 证书"))
                    .font(.caption2)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }

            certificateDetailRow(title: String(localized: "服务器"), value: challenge.info.identity.displayAddress)
            certificateDetailRow(title: String(localized: "用户名"), value: challenge.info.identity.username)
            certificateDetailRow(title: String(localized: "证书主体"), value: challenge.info.subjectSummary)
            if let issuer = challenge.info.issuerSummary {
                certificateDetailRow(title: String(localized: "颁发者"), value: issuer)
            }
            if let notBefore = challenge.info.notBefore, let notAfter = challenge.info.notAfter {
                certificateDetailRow(
                    title: String(localized: "有效期"),
                    value: "\(notBefore.formatted(date: .numeric, time: .omitted)) – \(notAfter.formatted(date: .numeric, time: .omitted))"
                )
            }
            fingerprintRow(title: String(localized: "SHA-256 指纹"), fingerprint: challenge.info.displayFingerprint)
            if isChange, let pinned = challenge.pinnedFingerprint {
                fingerprintRow(title: String(localized: "原指纹"), fingerprint: pinned)
            }

            if isChange {
                Text("服务器证书与已确认的指纹不一致。请确认服务器确实更换过证书后再更新；更新前不会发送任何数据。")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8 * spacingScale) {
                Button {
                    session.trustWebDAVCertificate(challenge)
                } label: {
                    Label(
                        isChange ? String(localized: "更新指纹并信任") : String(localized: "信任并继续"),
                        systemImage: isChange ? "exclamationmark.shield" : "checkmark.shield"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: isChange ? .destructiveOutlined : .filled))

                Button {
                    session.dismissWebDAVCertificateChallenge()
                } label: {
                    Label("取消", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
            }
        }
        .padding(12 * spacingScale)
        .background(AndroidParityPalette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isChange ? Color.red.opacity(0.45) : AndroidParityPalette.outline, lineWidth: 1)
        }
    }

    // MARK: - Trusted records

    @ViewBuilder
    private func trustedRecordView(_ record: WebDAVTrustedCertificateRecord) -> some View {
        VStack(alignment: .leading, spacing: 6 * spacingScale) {
            HStack(alignment: .firstTextBaseline, spacing: 8 * spacingScale) {
                Text(record.identity.displayAddress)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                Spacer(minLength: 8 * spacingScale)
                Text(record.isTrusted ? String(localized: "已信任") : String(localized: "已撤销"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(record.isTrusted ? AndroidParityPalette.primary : Color.secondary)
            }

            certificateDetailRow(title: String(localized: "用户名"), value: record.identity.username)
            if !record.subjectSummary.isEmpty {
                certificateDetailRow(title: String(localized: "证书主体"), value: record.subjectSummary)
            }
            certificateDetailRow(
                title: String(localized: "首次信任"),
                value: record.firstTrustedAt.formatted(date: .abbreviated, time: .shortened)
            )
            fingerprintRow(title: String(localized: "SHA-256 指纹"), fingerprint: WebDAVCertificateFingerprint.grouped(record.fingerprint))

            if record.isTrusted {
                Button(role: .destructive) {
                    revokingRecord = record
                } label: {
                    Label("撤销信任", systemImage: "shield.slash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .destructiveOutlined))
            }
        }
    }

    // MARK: - Rows

    private func certificateDetailRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12 * spacingScale) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .frame(width: 76 * spacingScale, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(AndroidParityPalette.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fingerprintRow(title: String, fingerprint: String) -> some View {
        VStack(alignment: .leading, spacing: 2 * spacingScale) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AndroidParityPalette.textSecondary)
            Text(fingerprint)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(AndroidParityPalette.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
