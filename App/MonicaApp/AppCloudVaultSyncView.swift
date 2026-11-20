import SwiftUI
import MonicaSync

/// Settings screen for issue #31: manual, encrypted cloud vault sync over the
/// already configured WebDAV / OneDrive providers.
///
/// The screen is intentionally explicit about what is uploaded (the complete
/// encrypted vault file, never entries in clear text), that syncing is manual,
/// and that destructive conflict resolutions always keep a conflict copy first.
struct AppCloudVaultSyncSettingsView: View {
    let session: AppSessionModel

    @Environment(\.dismiss) private var dismiss
    @State private var coordinator: AppCloudVaultSyncCoordinator?
    @State private var setupError: String?
    @State private var vaultPassword = ""
    @State private var showResetConfirmation = false

    var body: some View {
        AndroidParityScreen {
            if let setupError {
                AndroidParitySection(title: "无法使用云端保险库") {
                    AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.6)) {
                        Text(setupError)
                            .font(.subheadline)
                            .foregroundStyle(AndroidParityPalette.textPrimary)
                        Text("请先解锁保险库，并在「云端备份」中完成云服务配置后重试。")
                            .font(.footnote)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }
                }
            } else if let coordinator {
                content(for: coordinator)
            } else {
                AndroidParitySection(title: "准备中") {
                    AndroidParityCard {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .navigationTitle("云端保险库")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard coordinator == nil, setupError == nil else { return }
            do {
                let built = try session.makeCloudVaultSyncBridge()
                let value = AppCloudVaultSyncCoordinator(bridge: built)
                value.prepare()
                coordinator = value
            } catch {
                setupError = error.localizedDescription
            }
        }
        .onChange(of: session.vaultState) { _, newValue in
            if newValue != .unlocked {
                coordinator = nil
            }
        }
        .confirmationDialog("清除本机的云端同步记录？", isPresented: $showResetConfirmation, titleVisibility: .visible) {
            Button("清除同步记录", role: .destructive) {
                coordinator?.resetState()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只清除本机保存的版本基线与失败记录，不会删除云端文件，也不会修改保险库内容。")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func content(for coordinator: AppCloudVaultSyncCoordinator) -> some View {
        providerSection(coordinator)
        vaultSection(coordinator)
        statusSection(coordinator)
        actionsSection(coordinator)
        if coordinator.awaitingPasswordOutcome != nil || coordinator.stage == .needsVaultPassword {
            passwordSection(coordinator)
        }
        if coordinator.conflict != nil || isConflictFailure(coordinator) {
            conflictSection(coordinator)
        }
        if case .failed(let message) = coordinator.stage,
           coordinator.awaitingPasswordOutcome == nil,
           coordinator.conflict == nil {
            failureSection(coordinator, message: message)
        }
        if case .finished(let message) = coordinator.stage, coordinator.awaitingPasswordOutcome == nil {
            AndroidParitySection(title: "结果") {
                AndroidParityCard(fill: AndroidParityPalette.secondaryContainer.opacity(0.45)) {
                    Text(message)
                        .font(.subheadline.weight(.semibold))
                    if let extra = coordinator.statusMessage, extra != message {
                        Text(extra)
                            .font(.footnote)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }
                }
            }
        }
        notesSection(coordinator)
    }

    @ViewBuilder
    private func providerSection(_ coordinator: AppCloudVaultSyncCoordinator) -> some View {
        AndroidParitySection(title: "云端位置") {
            AndroidParityCard {
                if coordinator.bridge.availableProviders.count > 1 {
                    Picker("服务", selection: Binding(
                        get: { coordinator.selectedProvider },
                        set: { coordinator.selectProvider($0) }
                    )) {
                        ForEach(coordinator.bridge.availableProviders, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                } else {
                    AndroidParityInfoRow(
                        title: "服务",
                        value: coordinator.selectedProvider.displayName
                    )
                }
                Text(coordinator.providerDescription)
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                if coordinator.bridge.availableProviders.isEmpty {
                    Label("还没有可用的云服务：请先在「云端备份」中配置 WebDAV，或登录 OneDrive。", systemImage: "exclamationmark.triangle")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.primary)
                }
            }
        }
    }

    @ViewBuilder
    private func vaultSection(_ coordinator: AppCloudVaultSyncCoordinator) -> some View {
        AndroidParitySection(title: "当前保险库") {
            AndroidParityCard {
                AndroidParityInfoRow(title: "名称", value: coordinator.bridge.vaultName)
                AndroidParityInfoRow(title: "标识", value: String(coordinator.bridge.vaultID.prefix(12)))
                AndroidParityInfoRow(title: "上传文件", value: coordinator.bridge.vaultFileName)
                AndroidParityInfoRow(title: "本机设备", value: coordinator.bridge.deviceName)
            }
        }
    }

    @ViewBuilder
    private func statusSection(_ coordinator: AppCloudVaultSyncCoordinator) -> some View {
        AndroidParitySection(title: "同步状态") {
            AndroidParityCard {
                AndroidParityInfoRow(
                    title: "最近同步",
                    value: AppCloudVaultSyncCoordinator.formattedDate(coordinator.lastSyncedAt)
                )
                if let revision = coordinator.remoteManifestRevision {
                    AndroidParityInfoRow(title: "上次云端版本", value: "第 \(revision) 版")
                }
                if let remoteSummary = coordinator.remoteSummary {
                    AndroidParityInfoRow(title: "云端", value: remoteSummary)
                }
                if coordinator.pendingUpload {
                    Label("上次上传未完成，重新检查后可继续上传", systemImage: "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.primary)
                }
                Text(coordinator.decisionDescription)
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                if coordinator.isBusy {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func actionsSection(_ coordinator: AppCloudVaultSyncCoordinator) -> some View {
        AndroidParitySection(title: "手动同步") {
            AndroidParityCard {
                Button {
                    Task { await coordinator.check() }
                } label: {
                    Label("检查云端版本", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                .disabled(coordinator.isBusy || coordinator.awaitingPasswordOutcome != nil)

                Button {
                    Task { await coordinator.push() }
                } label: {
                    Label("上传本机保险库到云端", systemImage: "icloud.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                .disabled(coordinator.isBusy || coordinator.awaitingPasswordOutcome != nil)

                Button {
                    Task { await coordinator.pull() }
                } label: {
                    Label("从云端更新本机", systemImage: "icloud.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                .disabled(coordinator.isBusy || coordinator.awaitingPasswordOutcome != nil)

                AndroidParityDivider()

                Button {
                    showResetConfirmation = true
                } label: {
                    Label("重置同步记录", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .destructiveOutlined))
                .disabled(coordinator.isBusy)
            }
        }
    }

    @ViewBuilder
    private func passwordSection(_ coordinator: AppCloudVaultSyncCoordinator) -> some View {
        AndroidParitySection(title: "需要该保险库的密码") {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.6)) {
                Text(coordinator.guidance ?? "云端文件属于另一个保险库，需要输入它的密码来验证并保存到本机。")
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                SecureField("云端保险库密码", text: $vaultPassword)
                    .textFieldStyle(AndroidParityTextFieldStyle())
                    .textContentType(.password)
                    .submitLabel(.continue)
                    .onSubmit { submitPassword(coordinator) }
                Button {
                    submitPassword(coordinator)
                } label: {
                    Label("验证并保存到本机", systemImage: "checkmark.shield")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                .disabled(vaultPassword.isEmpty || coordinator.isBusy)
                Button {
                    vaultPassword = ""
                    coordinator.cancelPasswordPrompt()
                } label: {
                    Label("取消", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                Text("不会覆盖本机现有保险库；验证通过后会保存为新文件，可在锁屏「打开已有保险库」中打开。")
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func conflictSection(_ coordinator: AppCloudVaultSyncCoordinator) -> some View {
        AndroidParitySection(title: "同步冲突") {
            AndroidParityCard(fill: AndroidParityPalette.tertiaryContainer.opacity(0.4)) {
                if let conflict = coordinator.conflict {
                    Text(conflict.reason.localizedSummary)
                        .font(.subheadline.weight(.semibold))
                    AndroidParityInfoRow(
                        title: "本机已修改",
                        value: conflict.localChanged ? "是" : "否"
                    )
                    AndroidParityInfoRow(
                        title: "云端已修改",
                        value: conflict.remoteChanged ? "是" : "否"
                    )
                    AndroidParityInfoRow(
                        title: "云端版本",
                        value: "第 \(conflict.remoteManifestRevision) 版"
                    )
                } else {
                    Text("本机与云端都发生了变化，请选择保留方式。")
                        .font(.subheadline.weight(.semibold))
                }
                Text("无论选择哪种方式，都不会在未校验完整性时覆盖任何一侧数据。")
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                ForEach(CloudVaultConflictResolution.allCases, id: \.self) { resolution in
                    Button {
                        Task { await coordinator.resolveConflict(resolution) }
                    } label: {
                        Label(resolution.localizedTitle, systemImage: icon(for: resolution))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(
                        tone: resolution == .keepLocal ? .filled : (resolution == .keepRemote ? .outlined : .destructiveOutlined)
                    ))
                    .disabled(coordinator.isBusy)
                }
            }
        }
    }

    @ViewBuilder
    private func failureSection(_ coordinator: AppCloudVaultSyncCoordinator, message: String) -> some View {
        AndroidParitySection(title: "同步失败") {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.6)) {
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                if let guidance = coordinator.guidance {
                    Text(guidance)
                        .font(.footnote)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
                Button {
                    Task { await coordinator.check() }
                } label: {
                    Label("重新检查云端版本", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                .disabled(coordinator.isBusy)
                Button {
                    coordinator.clearFailure()
                } label: {
                    Label("关闭提示", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
            }
        }
    }

    @ViewBuilder
    private func notesSection(_ coordinator: AppCloudVaultSyncCoordinator) -> some View {
        AndroidParitySection(title: "说明") {
            AndroidParityCard {
                bullet("上传的是完整加密的保险库文件（.mdbx）与清单，云端不会出现明文条目。")
                bullet("清单记录保险库标识与版本号；清单与文件不一致时停止同步，不会信任任意一侧。")
                bullet("只在主动点击时联网，后台不会自动上传或轮询。")
                bullet("两机同时修改时会暂停并让你选择：保留本机、保留云端，或先上传冲突副本。")
                bullet("同一保险库的云端更新会替换本机文件并要求重新解锁；其他保险库的文件会保存为新文件，避免覆盖本机库。")
                bullet("如需自动后台同步，请参考 issue #54/#76 的规划。")
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .padding(.top, 6)
                .foregroundStyle(AndroidParityPalette.primary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
        }
    }

    private func icon(for resolution: CloudVaultConflictResolution) -> String {
        switch resolution {
        case .keepLocal: return "iphone.and.arrow.forward"
        case .keepRemote: return "icloud.and.arrow.down"
        case .createConflictCopy: return "doc.on.doc"
        }
    }

    private func isConflictFailure(_ coordinator: AppCloudVaultSyncCoordinator) -> Bool {
        if case .failed = coordinator.stage, coordinator.conflict != nil {
            return true
        }
        return false
    }

    private func submitPassword(_ coordinator: AppCloudVaultSyncCoordinator) {
        let password = vaultPassword
        vaultPassword = ""
        Task { await coordinator.submitVaultPassword(password) }
    }
}
