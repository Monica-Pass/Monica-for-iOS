//
//  VaultSnapshotViews.swift
//  Monica
//
//  「保险库快照」界面（issue #30）：列表、创建、恢复预览与清理。
//

import MonicaStorage
import SwiftUI

// MARK: - 入口

/// 设置页「本地保险库」卡片里的快照入口。
struct VaultSnapshotCenterView: View {
    @Bindable var session: AppSessionModel

    @State private var model = VaultSnapshotCenterModel()
    @State private var isConfirmingCreate = false
    @State private var isConfirmingDeleteAll = false
    @State private var deleteTarget: VaultSnapshotRecord?
    @State private var previewTarget: VaultSnapshotRecord?

    var body: some View {
        AndroidParityScreen {
            overviewCard
            actionCard
            statusMessage
            recordsCard
            policyCard
        }
        .navigationTitle("保险库快照")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.reload(session: session) }
        .onChange(of: session.vaultState) { _, _ in
            model.reload(session: session)
        }
        .confirmationDialog(
            "创建快照需要先锁定保险库，之后 MDBX 检查点才一致。",
            isPresented: $isConfirmingCreate,
            titleVisibility: .visible
        ) {
            Button("继续") {
                Task { await model.createSnapshot(session: session) }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            "清理全部快照会删除这个保险库的所有快照，无法撤销。",
            isPresented: $isConfirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("清理全部快照", role: .destructive) {
                model.deleteAllSnapshots()
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            "删除这一份快照？",
            isPresented: deleteConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let deleteTarget {
                    model.deleteSnapshot(deleteTarget)
                }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        }
        .sheet(item: $previewTarget) { record in
            VaultSnapshotPreviewSheet(session: session, model: model, record: record)
        }
        .onChange(of: previewTarget?.id) { _, _ in
            if previewTarget == nil {
                model.cancelRestoreConfirmation()
            }
        }
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { isPresented in
                if !isPresented {
                    deleteTarget = nil
                }
            }
        )
    }

    // MARK: 概览

    private var overviewCard: some View {
        AndroidParityCard {
            HStack(spacing: 12) {
                AndroidParityIconTile(systemImage: "clock.arrow.circlepath")
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.subject?.displayName ?? String(localized: "没有可用的保险库。"))
                        .font(.headline)
                        .foregroundStyle(AndroidParityPalette.textPrimary)
                    if model.isVaultUnlocked {
                        Text("当前库已解锁")
                            .font(.caption)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    } else {
                        Text("当前库已锁定")
                            .font(.caption)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            Text("快照使用 AES-GCM 加密，密钥保存在钥匙串。")
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
        }
    }

    private var actionCard: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
            Button {
                model.reload(session: session)
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .outlined))

            Button {
                isConfirmingCreate = true
            } label: {
                Label("创建快照", systemImage: "camera.aperture")
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .filled))
            .disabled(!model.isVaultUnlocked || model.status.isRunning || model.subject == nil)

            Text("创建快照需要先锁定保险库，之后 MDBX 检查点才一致。")
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

    // MARK: 列表

    private var recordsCard: some View {
        AndroidParityCard {
            HStack {
                Text("快照列表")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                Spacer(minLength: 0)
                Text("\(model.records.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }

            if model.records.isEmpty {
                Text("还没有快照")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                Text("创建第一份快照，之后可在这里对比与恢复。")
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            } else {
                ForEach(Array(model.records.enumerated()), id: \.element.id) { index, record in
                    if index > 0 {
                        AndroidParityDivider()
                    }
                    recordRow(record)
                }
                AndroidParityDivider()
                Button(role: .destructive) {
                    isConfirmingDeleteAll = true
                } label: {
                    Label("清理全部快照", systemImage: "trash")
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .destructiveOutlined))
                .disabled(model.status.isRunning)
            }
        }
    }

    @ViewBuilder
    private func recordRow(_ record: VaultSnapshotRecord) -> some View {
        Button {
            model.prepareRestorePreview(record: record, session: session)
            model.confirmRestore(record: record)
            previewTarget = record
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: iconName(for: record.manifest.reason))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.primary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.manifest.reason.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textPrimary)
                    Text(record.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                    HStack(spacing: 10) {
                        Text(byteCountText(record.envelopeByteCount))
                        Text("条目")
                        Text("\(record.manifest.itemCount)")
                        Text("项目")
                        Text("\(record.manifest.projectCount)")
                    }
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                }
                Spacer(minLength: 0)
                Menu {
                    Button(role: .destructive) {
                        deleteTarget = record
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func iconName(for reason: VaultSnapshotReason) -> String {
        switch reason {
        case .manual:
            return "camera.aperture"
        case .automaticLock:
            return "lock"
        case .preRestoreSafety:
            return "arrow.uturn.backward.circle"
        }
    }

    private func byteCountText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: 策略

    private var policyCard: some View {
        AndroidParityCard {
            Text("保留策略")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textPrimary)
            Text("默认保留最近 10 份快照，超出后自动删除最旧的。")
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
            Text("恢复前会自动创建一份回滚点。")
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
            Text("快照位置")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textPrimary)
            Text("Application Support/MonicaVaultSnapshots")
                .font(.caption.monospaced())
                .foregroundStyle(AndroidParityPalette.textSecondary)
        }
    }
}

// MARK: - 恢复预览

struct VaultSnapshotPreviewSheet: View {
    @Bindable var session: AppSessionModel
    var model: VaultSnapshotCenterModel
    let record: VaultSnapshotRecord

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingRestore = false

    var body: some View {
        NavigationStack {
            AndroidParityScreen {
                manifestCard
                if let diff = model.previewDiff {
                    diffCard(diff)
                } else {
                    unavailableDiffCard
                }
                if let message = model.status.message {
                    Text(message)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(model.status.isFailure ? AndroidParityPalette.danger : AndroidParityPalette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                restoreCard
            }
            .navigationTitle("恢复预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .confirmationDialog(
                "恢复此快照？",
                isPresented: $isConfirmingRestore,
                titleVisibility: .visible
            ) {
                Button("恢复", role: .destructive) {
                    Task {
                        await model.restoreSnapshot(session: session)
                        if case .succeeded = model.status {
                            dismiss()
                        }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("会先创建回滚点，再原子替换当前库文件。恢复后保险库保持锁定。")
            }
        }
    }

    private var manifestCard: some View {
        AndroidParityCard {
            HStack(spacing: 12) {
                AndroidParityIconTile(systemImage: "clock.arrow.circlepath")
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.manifest.reason.displayName)
                        .font(.headline)
                        .foregroundStyle(AndroidParityPalette.textPrimary)
                    Text(record.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
                Spacer(minLength: 0)
            }
            infoRow("保险库", record.manifest.vaultDisplayName)
            infoRow("条目", "\(record.manifest.itemCount)")
            infoRow("项目", "\(record.manifest.projectCount)")
            infoRow("大小", ByteCountFormatter.string(fromByteCount: Int64(record.envelopeByteCount), countStyle: .file))
        }
    }

    private func infoRow(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
            Spacer(minLength: 0)
            Text(value)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textPrimary)
        }
    }

    private func diffCard(_ diff: VaultSnapshotDiff) -> some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
            Text("恢复后变化")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textPrimary)
            countRow("恢复后新增", diff.addedCount, color: AndroidParityPalette.textPrimary)
            countRow("恢复后删除", diff.removedCount, color: AndroidParityPalette.danger)
            countRow("恢复后变更", diff.modifiedCount, color: AndroidParityPalette.textPrimary)
            countRow("未变化条目", diff.unchangedItemCount, color: AndroidParityPalette.textSecondary)

            if diff.isDestructive {
                Label("恢复会删除当前库中的条目，请确认。", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.danger)
            }

            changeSection("恢复后删除", diff.items(.removed))
            changeSection("恢复后变更", diff.items(.modified))
            changeSection("恢复后新增", diff.items(.added))
        }
    }

    private func countRow(_ title: LocalizedStringKey, _ count: Int, color: Color) -> some View {
        HStack {
            Text(title)
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
            Spacer(minLength: 0)
            Text("\(count)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(color)
        }
    }

    @ViewBuilder
    private func changeSection(_ title: LocalizedStringKey, _ items: [VaultSnapshotDifference]) -> some View {
        if !items.isEmpty {
            AndroidParityDivider()
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
            ForEach(items.prefix(20)) { item in
                HStack(spacing: 8) {
                    Text(item.kind.displayName)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AndroidParityPalette.surface, in: Capsule())
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                    Text(item.displayTitle)
                        .font(.caption)
                        .foregroundStyle(AndroidParityPalette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            if items.count > 20 {
                HStack(spacing: 4) {
                    Text("其余已省略")
                    Text("\(items.count - 20)")
                }
                .font(.caption2)
                .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }
    }

    private var unavailableDiffCard: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
            Label("解锁保险库后可对比当前条目。", systemImage: "lock")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
        }
    }

    private var restoreCard: some View {
        AndroidParityCard {
            Button {
                isConfirmingRestore = true
            } label: {
                Label("恢复此快照", systemImage: "arrow.uturn.backward.circle")
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .destructiveOutlined))
            .disabled(model.previewDiff == nil || model.status.isRunning)

            if model.previewDiff == nil {
                Text("没有可对比的当前状态，请先解锁并预览。")
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }
    }
}
