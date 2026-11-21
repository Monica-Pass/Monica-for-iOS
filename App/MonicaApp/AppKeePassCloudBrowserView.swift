//
//  AppKeePassCloudBrowserView.swift
//  Monica
//
//  设置 → KeePass → 云端 KeePass 文件：选择来源、浏览目录、打开 .kdbx、带冲突检测的保存。
//

import MonicaSync
import SwiftUI

/// sheet 容器：用例模型只在首次出现时构建，避免父视图刷新重置浏览状态。
struct AppKeePassCloudBrowserSheet: View {
    let session: AppSessionModel
    let environment: MonicaAppEnvironment

    @State private var model: AppKeePassCloudBrowserModel?

    var body: some View {
        Group {
            if let model {
                AppKeePassCloudBrowserView(session: session, model: model)
            } else {
                ProgressView()
                    .task {
                        model = .production(environment: environment)
                    }
            }
        }
    }
}

struct AppKeePassCloudBrowserView: View {
    @Bindable var session: AppSessionModel
    @Bindable var model: AppKeePassCloudBrowserModel
    @Environment(\.dismiss) private var dismiss

    @State private var isWorking = false
    @State private var actionError: String?
    @State private var conflictPrompt: ConflictPrompt?
    @State private var didAttemptInitialLoad = false

    private struct ConflictPrompt: Identifiable {
        let id = UUID()
        let fileName: String
    }

    var body: some View {
        NavigationStack {
            List {
                providerSection
                if model.selectedKind == .googleDrive {
                    googleDriveSection
                }
                if let actionError {
                    Section {
                        Text(actionError)
                            .foregroundStyle(.red)
                    }
                }
                if let opened = model.openedFile {
                    openedFileSection(opened)
                }
                if model.canBrowseSelectedProvider {
                    browseSection
                }
            }
            .navigationTitle("云端 KeePass 文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        model.cleanupTemporaryFiles()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(!model.canBrowseSelectedProvider || model.isLoading)
                }
            }
            .task {
                guard !didAttemptInitialLoad else { return }
                didAttemptInitialLoad = true
                if model.selectedKind == .googleDrive {
                    await model.refreshGoogleDriveState()
                }
                if model.canBrowseSelectedProvider {
                    await model.reload()
                }
            }
            .onDisappear {
                model.cleanupTemporaryFiles()
            }
            .alert(
                "云端文件已被修改",
                isPresented: Binding(
                    get: { conflictPrompt != nil },
                    set: { if !$0 { conflictPrompt = nil } }
                ),
                presenting: conflictPrompt
            ) { prompt in
                Button("另存副本") {
                    Task { await saveCopyFromPreview(named: prompt.fileName) }
                }
                Button("取消", role: .cancel) {}
            } message: { prompt in
                Text("\(prompt.fileName) 在云端已更新。为免覆盖其他设备的修改，Monica 不会直接写入；可以另存一份副本。")
            }
        }
    }

    // MARK: - Sections

    private var providerSection: some View {
        Section("来源") {
            if !model.hasAnyProvider {
                Text("没有可用的云端文件来源。")
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
            ForEach(model.availableKinds, id: \.self) { kind in
                Button {
                    Task { await model.select(kind: kind) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.displayName)
                            Text(availabilityLabel(for: kind))
                                .font(.caption)
                                .foregroundStyle(
                                    model.availability(for: kind).isAvailable
                                        ? AndroidParityPalette.textSecondary
                                        : Color.orange
                                )
                        }
                        Spacer()
                        if model.selectedKind == kind {
                            Image(systemName: "checkmark")
                                .foregroundStyle(AndroidParityPalette.primary)
                        }
                    }
                }
                .disabled(!model.availability(for: kind).isAvailable)
            }
            if let statusMessage = model.statusMessage, !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }
    }

    private var googleDriveSection: some View {
        Section("Google Drive") {
            HStack {
                Text(model.googleDriveState.label)
                Spacer()
                if model.googleDriveState.isRunning {
                    ProgressView()
                }
            }
            if model.googleDriveState.isConnected {
                Button("退出 Google Drive") {
                    Task { await model.signOutGoogleDrive() }
                }
            } else {
                Button("登录 Google Drive") {
                    Task { await model.signInGoogleDrive() }
                }
                .disabled(!model.availability(for: .googleDrive).isAvailable)
            }
            if case .notConfigured(let reason) = model.availability(for: .googleDrive) {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }
    }

    private func openedFileSection(_ opened: AppKeePassCloudOpenedFile) -> some View {
        Section("当前打开") {
            Text(opened.redactedSummary)
            if let data = session.keePassPendingDatabaseData {
                Button {
                    Task { await saveBack(data: data) }
                } label: {
                    Label("保存回云端（先比对版本）", systemImage: "icloud.and.arrow.up")
                }
                .disabled(isWorking)

                Button {
                    Task { await saveCopy(data: data, named: opened.entry.name) }
                } label: {
                    Label("另存副本", systemImage: "doc.on.doc")
                }
                .disabled(isWorking)
            }
            if opened.kind == .googleDrive || opened.kind == .oneDrive {
                Text("保存前会先下载云端最新版本比对 ETag/revision；发现他人修改时不会覆盖。")
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
            Text("临时明文已清理，密码库内容只在内存与受保护的预览里。")
                .font(.caption)
                .foregroundStyle(AndroidParityPalette.textSecondary)
        }
    }

    private var browseSection: some View {
        Group {
            Section {
                Picker("显示", selection: filterBinding) {
                    Text("仅 KeePass 数据库").tag(CloudFileBrowserFilter.keePassOnly)
                    Text("全部文件与目录").tag(CloudFileBrowserFilter.all)
                }
                .pickerStyle(.segmented)

                HStack {
                    if model.canGoUp {
                        Button {
                            Task { await model.goUp() }
                        } label: {
                            Label("上一级", systemImage: "chevron.up")
                        }
                    }
                    Text(model.currentDirectoryName)
                        .font(.footnote)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                    Spacer()
                    if model.isLoading {
                        ProgressView()
                    }
                }
            }

            Section("目录") {
                let directories = model.entries.filter(\.isDirectory)
                if directories.isEmpty {
                    Text("没有子目录")
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
                ForEach(directories) { directory in
                    Button {
                        Task { await model.openDirectory(directory) }
                    } label: {
                        HStack {
                            Image(systemName: "folder")
                            Text(CloudFileKeePassFile.sanitizedName(directory.name))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(AndroidParityPalette.textSecondary)
                        }
                    }
                }
            }

            Section("KeePass 数据库") {
                let databases = model.entries.filter { !$0.isDirectory && $0.isKeePassDatabase }
                if databases.isEmpty {
                    Text("此目录没有 .kdbx 文件")
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
                ForEach(databases) { entry in
                    Button {
                        Task { await open(entry) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(CloudFileKeePassFile.sanitizedName(entry.name))
                            Text(entry.redactedSummary)
                                .font(.caption)
                                .foregroundStyle(AndroidParityPalette.textSecondary)
                        }
                    }
                    .disabled(isWorking)
                }
                if model.canLoadNextPage {
                    Button("加载更多") {
                        Task { await model.loadNextPage() }
                    }
                    .disabled(model.isLoading)
                }
            }

            if let errorMessage = model.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var filterBinding: Binding<CloudFileBrowserFilter> {
        Binding(
            get: { model.filter },
            set: { newValue in
                Task { await model.setFilter(newValue) }
            }
        )
    }

    // MARK: - Actions

    private func availabilityLabel(for kind: CloudFileBrowserKind) -> String {
        switch model.availability(for: kind) {
        case .available:
            return String(localized: "可用")
        case .notConfigured(let reason):
            return reason
        }
    }

    private func open(_ entry: CloudFileBrowserEntry) async {
        isWorking = true
        actionError = nil
        defer { isWorking = false }
        do {
            let opened = try await model.openDatabase(entry)
            _ = try session.previewKeePassImport(
                fromCloudFile: opened.download,
                provider: opened.provider
            )
            // 预览已经接管数据，临时明文立刻删除。
            model.completeOpening(opened)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func saveBack(data: Data) async {
        guard let opened = model.openedFile else {
            actionError = AppKeePassCloudBrowserError.missingOpenedFile.localizedDescription
            return
        }
        isWorking = true
        actionError = nil
        defer { isWorking = false }
        do {
            _ = try await model.save(data, to: opened)
        } catch let error as AppKeePassCloudBrowserError {
            if case .conflict(_, let fileName, _) = error {
                conflictPrompt = ConflictPrompt(fileName: fileName)
            } else {
                actionError = error.localizedDescription
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func saveCopyFromPreview(named fileName: String) async {
        guard let data = session.keePassPendingDatabaseData else {
            actionError = AppKeePassCloudBrowserError.missingOpenedFile.localizedDescription
            return
        }
        await saveCopy(data: data, named: fileName)
    }

    private func saveCopy(data: Data, named fileName: String) async {
        guard let opened = model.openedFile else {
            actionError = AppKeePassCloudBrowserError.missingOpenedFile.localizedDescription
            return
        }
        isWorking = true
        actionError = nil
        defer { isWorking = false }
        do {
            _ = try await model.saveCopy(data, of: opened)
            await model.reload()
        } catch {
            actionError = error.localizedDescription
        }
        _ = fileName
    }
}
