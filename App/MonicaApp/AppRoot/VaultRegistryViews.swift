import SwiftUI
import MonicaStorage

/// 设置页里的「本地保险库」卡片：列表 + 当前默认库 + 新建入口。
struct VaultRegistrySettingsCard: View {
    @Bindable var session: AppSessionModel
    let deviceID: String

    var body: some View {
        VaultRegistryListView(
            session: session,
            deviceID: deviceID,
            showsCreateButton: true
        )
    }
}

/// 锁屏与设置共用的多库选择面板。
struct VaultRegistrySheet: View {
    @Bindable var session: AppSessionModel
    let deviceID: String
    var onVaultSelected: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AndroidParityScreen {
                VaultRegistryListView(
                    session: session,
                    deviceID: deviceID,
                    showsCreateButton: true,
                    onVaultSelected: {
                        onVaultSelected?()
                        dismiss()
                    }
                )
            }
            .navigationTitle("保险库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct VaultRegistryListView: View {
    @Bindable var session: AppSessionModel
    let deviceID: String
    var showsCreateButton: Bool = true
    var onVaultSelected: (() -> Void)?

    @State private var renameTarget: VaultRegistryEntry?
    @State private var renameDraft = ""
    @State private var isCreatingVault = false
    @State private var newVaultName = ""
    @State private var deleteTarget: VaultRegistryEntry?
    @State private var errorMessage: String?

    var body: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
            if session.registeredVaultEntries.isEmpty {
                Text("还没有保存在这里的保险库，先新建一个。")
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            } else {
                ForEach(Array(session.registeredVaultEntries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        AndroidParityDivider()
                    }
                    vaultRow(entry)
                }
            }

            AndroidParityDivider()

            Text("默认库只在启动时预选，仍然需要输入主密码解锁。切换保险库会先锁定当前库。")
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)

            if showsCreateButton {
                Button {
                    newVaultName = ""
                    isCreatingVault = true
                } label: {
                    Label("新建保险库", systemImage: "plus.circle")
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
            }

            if case let .failed(message) = session.vaultRegistryOperationState {
                Text(message)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
            }
            if case let .succeeded(message) = session.vaultRegistryOperationState {
                Text(message)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }
        .alert("新建保险库", isPresented: $isCreatingVault) {
            TextField("保险库名称", text: $newVaultName)
            Button("取消", role: .cancel) {}
            Button("创建") {
                if session.beginVaultCreation(named: newVaultName) {
                    onVaultSelected?()
                } else if case let .failed(message) = session.vaultRegistryOperationState {
                    errorMessage = message
                }
            }
        } message: {
            Text("新库会和现有保险库一起出现在列表里，创建后需要设置主密码。")
        }
        .alert("重命名保险库", isPresented: renameAlertBinding) {
            TextField("保险库名称", text: $renameDraft)
            Button("取消", role: .cancel) {
                renameTarget = nil
            }
            Button("保存") {
                guard let target = renameTarget else { return }
                renameTarget = nil
                do {
                    try session.renameRegisteredVault(id: target.id, to: renameDraft)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } message: {
            Text("只修改列表里的名称，磁盘上的文件不会改名。")
        }
        .sheet(item: $deleteTarget) { entry in
            VaultRegistryDeleteSheet(session: session, entry: entry)
        }
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { isPresented in
                if !isPresented {
                    renameTarget = nil
                }
            }
        )
    }

    @ViewBuilder
    private func vaultRow(_ entry: VaultRegistryEntry) -> some View {
        let isActive = session.isRegisteredVaultActive(entry)
        let fileExists = session.registeredVaultFileExists(entry)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(entry.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                if entry.isDefault {
                    badge("默认", color: AndroidParityPalette.primary)
                }
                if isActive {
                    badge("当前", color: .green)
                }
                Spacer(minLength: 0)
                Menu {
                    if !isActive {
                        Button {
                            switchToVault(entry)
                        } label: {
                            Label("切换到此库", systemImage: "arrow.left.arrow.right")
                        }
                    }
                    if !entry.isDefault {
                        Button {
                            do {
                                try session.setDefaultRegisteredVault(id: entry.id)
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        } label: {
                            Label("设为默认库", systemImage: "star")
                        }
                    }
                    Button {
                        renameDraft = entry.displayName
                        renameTarget = entry
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    Divider()
                    Button(role: .destructive) {
                        deleteTarget = entry
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: AppVaultDirectories.isExternal(session.resolvedFileURL(for: entry)) ? "externaldrive" : "internaldrive")
                Text(session.pathHint(for: entry))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption)
            .foregroundStyle(AndroidParityPalette.textSecondary)

            HStack(spacing: 6) {
                Image(systemName: "clock")
                if let lastOpenedAt = entry.lastOpenedAt {
                    Text(relativeText(for: lastOpenedAt))
                } else {
                    Text("从未打开")
                }
            }
            .font(.caption)
            .foregroundStyle(AndroidParityPalette.textSecondary)

            if !fileExists {
                Label("文件不在原位置", systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isActive else { return }
            switchToVault(entry)
        }
    }

    private func badge(_ title: LocalizedStringKey, color: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule(style: .continuous))
    }

    private func switchToVault(_ entry: VaultRegistryEntry) {
        errorMessage = nil
        do {
            try session.switchToRegisteredVault(id: entry.id)
            onVaultSelected?()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func relativeText(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// 删除保险库：先说明备份，再要求输入库名；删除磁盘文件还要二次确认。
struct VaultRegistryDeleteSheet: View {
    @Bindable var session: AppSessionModel
    let entry: VaultRegistryEntry

    @Environment(\.dismiss) private var dismiss
    @State private var typedName = ""
    @State private var removeFile = false
    @State private var isConfirmingFileDeletion = false
    @State private var errorMessage: String?

    private var isNameConfirmed: Bool {
        typedName.trimmingCharacters(in: .whitespacesAndNewlines) == entry.displayName
    }

    var body: some View {
        NavigationStack {
            AndroidParityScreen {
                AndroidParitySection(title: String(localized: "删除保险库")) {
                    AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                        Text("删除前请确认已经有一份可用的备份。这个操作不可撤销。")
                            .font(.footnote)
                            .foregroundStyle(AndroidParityPalette.textSecondary)

                        AndroidParityInfoRow(title: String(localized: "保险库"), value: entry.displayName)
                        AndroidParityInfoRow(
                            title: String(localized: "文件位置"),
                            value: session.pathHint(for: entry)
                        )

                        Text("请输入库名以确认删除")
                            .font(.subheadline.weight(.semibold))
                        TextField(entry.displayName, text: $typedName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(AndroidParityTextFieldStyle())

                        Toggle("同时删除磁盘上的 .mdbx 文件", isOn: $removeFile)
                            .tint(.red)

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.red)
                        }

                        Button(role: .destructive) {
                            if removeFile {
                                isConfirmingFileDeletion = true
                            } else {
                                performDeletion()
                            }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        .buttonStyle(AndroidParityButtonStyle(tone: .destructiveOutlined))
                        .disabled(!isNameConfirmed)
                    }
                }
            }
            .navigationTitle(entry.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
            .alert("确认删除磁盘文件？", isPresented: $isConfirmingFileDeletion) {
                Button("取消", role: .cancel) {}
                Button("永久删除", role: .destructive) {
                    performDeletion()
                }
            } message: {
                Text("磁盘上的 .mdbx 文件会被永久删除，无法恢复。")
            }
        }
    }

    private func performDeletion() {
        do {
            try session.deleteRegisteredVault(id: entry.id, removeFile: removeFile)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
