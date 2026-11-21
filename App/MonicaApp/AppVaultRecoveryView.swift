//
//  AppVaultRecoveryView.swift
//  Monica
//
//  「保险库打开失败」恢复页（issue #144）：失败码、文件与快照证据、重试、脱敏诊断复制、
//  主密码确认后的快照救援。全程锁定态：不渲染任何条目内容。
//

import MonicaStorage
import SwiftUI

struct AppVaultRecoveryView: View {
    var session: AppSessionModel
    let deviceID: String

    @State private var model = AppVaultRecoveryModel()
    @State private var pendingRestore: VaultSnapshotRecord?

    var body: some View {
        NavigationStack {
            AndroidParityScreen {
                headerCard
                failureCard
                evidenceCard
                actionCard
                statusMessage
                snapshotCard
                footerNote
            }
            .navigationTitle("保险库恢复")
            .navigationBarTitleDisplayMode(.inline)
            .task { model.load(session: session) }
            .confirmationDialog(
                "从快照恢复会覆盖当前保险库文件",
                isPresented: restoreConfirmationBinding,
                titleVisibility: .visible
            ) {
                Button("恢复这份快照", role: .destructive) {
                    guard let record = pendingRestore else { return }
                    pendingRestore = nil
                    Task { await model.restore(record, session: session, deviceID: deviceID) }
                }
                Button("取消", role: .cancel) { pendingRestore = nil }
            } message: {
                Text("恢复前会先把当前库复制成回滚点（.preRestoreSafety）；恢复失败不会删除或覆盖原文件。")
            }
        }
    }

    // MARK: 头部

    private var headerCard: some View {
        AndroidParityCard {
            HStack(alignment: .top, spacing: 12) {
                AndroidParityIconTile(
                    systemImage: "exclamationmark.triangle.fill",
                    fill: AndroidParityPalette.danger.opacity(0.16),
                    tint: AndroidParityPalette.danger
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text("保险库打不开")
                        .font(.headline)
                        .foregroundStyle(AndroidParityPalette.textPrimary)
                    Text("当前保持锁定状态：这里只显示文件与快照的元数据，不显示任何条目内容。")
                        .font(.footnote)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: 失败码

    private var failureCard: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
            failureCodeRow
            failureCopy
        }
    }

    private var failureCodeRow: some View {
        HStack(spacing: 8) {
            Text(model.failure.code)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(AndroidParityPalette.onPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(AndroidParityPalette.primaryContainer, in: Capsule())
            Text(model.stage.title)
                .font(.caption)
                .foregroundStyle(AndroidParityPalette.textSecondary)
            Spacer(minLength: 0)
        }
    }

    private var failureCopy: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.failure.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textPrimary)
            Text(model.failure.explanation)
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
            failureNextStep
            failureTechnicalReference
        }
    }

    @ViewBuilder
    private var failureNextStep: some View {
        Label(model.failure.nextStep, systemImage: "arrow.forward.circle")
            .font(.footnote)
            .foregroundStyle(AndroidParityPalette.primary)
    }

    @ViewBuilder
    private var failureTechnicalReference: some View {
        if !model.technicalReference.isEmpty {
            Text(model.technicalReference)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .textSelection(.enabled)
        }
    }

    // MARK: 证据

    private var evidenceCard: some View {
        AndroidParityCard {
            Text("保险库文件")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textPrimary)

            if let file = model.file {
                evidenceRow(label: "路径", value: file.fileURL.path, monospaced: true)
                evidenceRow(label: "大小", value: file.formattedByteCount ?? String(localized: "未知"))
                evidenceRow(label: "文件状态", value: file.exists ? String(localized: "存在") : String(localized: "不存在"))
                if let modificationDate = file.modificationDate {
                    evidenceRow(label: "修改时间", value: modificationDate.formatted(date: .abbreviated, time: .standard))
                }
                if file.isBusy {
                    evidenceRow(label: "未合并的写入日志", value: file.busySidecars.joined(separator: ", "))
                }
            } else {
                Text("没有可用的文件路径。")
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }

            AndroidParityDivider()

            evidenceRow(
                label: "最近一次成功打开",
                value: model.lastOpenedAt?.formatted(date: .abbreviated, time: .standard) ?? String(localized: "无记录")
            )
        }
    }

    private func evidenceRow(label: String, value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(AndroidParityPalette.textSecondary)
            Text(value)
                .font(monospaced ? .system(.footnote, design: .monospaced) : .footnote)
                .foregroundStyle(AndroidParityPalette.textPrimary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 操作

    private var actionCard: some View {
        AndroidParityCard {
            Text("用主密码重试")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textPrimary)

            SecureField("主密码", text: $model.masterPassword)
                .textContentType(.password)
                .textFieldStyle(AndroidParityTextFieldStyle())
                .disabled(model.status.isRunning)

            Button {
                model.retryWithPassword(session: session, deviceID: deviceID)
            } label: {
                Label("重试", systemImage: "arrow.clockwise")
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .filled))
            .disabled(model.status.isRunning || model.masterPassword.isEmpty)

            if model.retryMode == .keychain {
                Button {
                    Task { await model.retryWithKeychain(session: session, deviceID: deviceID) }
                } label: {
                    Label("用设备钥匙串重试", systemImage: "faceid")
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                .disabled(model.status.isRunning)
            }

            Button {
                model.copyDiagnostics(session: session)
            } label: {
                Label("复制诊断", systemImage: "doc.on.doc")
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .outlined))

            Button(role: .destructive) {
                model.dismiss(session: session)
            } label: {
                Label("退出", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .destructiveOutlined))

            Text("复制的内容只包含失败码、文件与快照的元数据，不包含条目内容、标题、主密码或密钥。")
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        if let message = model.status.message {
            Text(message)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(model.status.isFailure ? AndroidParityPalette.danger : AndroidParityPalette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
    }

    // MARK: 快照救援

    private var snapshotCard: some View {
        AndroidParityCard {
            HStack {
                Text("快照救援")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                Spacer(minLength: 0)
                Text("\(model.snapshots.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }

            if let issue = model.snapshotIssue {
                Text(issue.code + " " + issue.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.danger)
                Text(issue.explanation)
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            } else if model.snapshots.isEmpty {
                Text("没有可用快照")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                Text("这个保险库还没有可用的快照，因此无法通过快照救援；可以改用主密码重试。")
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            } else {
                if let newest = model.snapshots.first {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("最近快照：\(newest.manifest.createdAt.formatted(date: .abbreviated, time: .standard))")
                            .font(.footnote)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                        Text("完整性：\(model.newestSnapshotVerification.localizedTitle)")
                            .font(.footnote)
                            .foregroundStyle(
                                model.newestSnapshotVerification == .failed
                                    ? AndroidParityPalette.danger
                                    : AndroidParityPalette.textSecondary
                            )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                ForEach(model.snapshots) { record in
                    AndroidParityDivider()
                    snapshotRow(record)
                }

                Text("恢复前会先创建 .preRestoreSafety 回滚点；恢复失败不会删除或覆盖原文件。")
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }

            if model.subject == nil {
                Text("无法确定这个文件的保险库标识，暂时不能读取快照。")
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }
    }

    private func snapshotRow(_ record: VaultSnapshotRecord) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.manifest.reason.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                Text(record.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                Text("条目 \(record.manifest.index.itemCount) · 项目 \(record.manifest.index.projectCount)")
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
            Spacer(minLength: 0)
            Button {
                pendingRestore = record
            } label: {
                Text("恢复")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
            .disabled(model.status.isRunning || model.masterPassword.isEmpty)
        }
        .padding(.vertical, 2)
    }

    private var footerNote: some View {
        Text("退出只关闭恢复页并回到解锁页，不会删除或重建本地保险库。")
            .font(.footnote)
            .foregroundStyle(AndroidParityPalette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    private var restoreConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingRestore != nil },
            set: { isPresented in
                if !isPresented {
                    pendingRestore = nil
                }
            }
        )
    }
}

#Preview {
    AppVaultRecoveryView(session: AppSessionModel(), deviceID: "preview-device")
}
