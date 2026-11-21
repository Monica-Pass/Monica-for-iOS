//
//  AppKeePassLibraryView.swift
//  Monica
//
//  issue #32：KeePass 原生库浏览器页面。
//  组树（新建/重命名/移动/删除）、条目字段编辑、全库搜索、安全写回。
//  关闭页面即释放明文与解密后的 XML（`AppKeePassLibraryModel.close()`）。
//

import MonicaStorage
import SwiftUI

struct AppKeePassLibraryView: View {
    @State private var model: AppKeePassLibraryModel
    @Environment(\.dismiss) private var dismiss

    @State private var isDatabaseImporterPresented = false
    @State private var isKeyFileImporterPresented = false
    @State private var groupEditorMode: AppKeePassGroupEditorMode?
    @State private var groupNameDraft = ""
    @State private var groupPendingDeletion: KeePassNativeGroup?
    @State private var groupPendingMove: KeePassNativeGroup?
    @State private var presentedEntry: AppKeePassEntryEditorTarget?
    @State private var isCloseConfirmationPresented = false

    init(session: AppSessionModel) {
        _model = State(initialValue: AppKeePassLibraryModel(session: session))
    }

    var body: some View {
        @Bindable var model = model
        return NavigationStack {
            content
                .navigationTitle(appLocalized("KeePass 库"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
        }
        .interactiveDismissDisabled(model.isDirty)
        .onDisappear { model.close() }
        .fileImporter(
            isPresented: $isDatabaseImporterPresented,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    model.importDatabase(from: url)
                }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $isKeyFileImporterPresented,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    model.importKeyFile(from: url)
                }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .alert(
            groupEditorMode?.title ?? appLocalized("分组名称"),
            isPresented: Binding(
                get: { groupEditorMode != nil },
                set: { if !$0 { groupEditorMode = nil } }
            )
        ) {
            TextField("分组名称", text: $groupNameDraft)
            Button("取消", role: .cancel) { groupEditorMode = nil }
            Button("保存") { commitGroupEditor() }
        } message: {
            Text(groupEditorMode?.message ?? "")
        }
        .confirmationDialog(
            appLocalized("删除分组？"),
            isPresented: Binding(
                get: { groupPendingDeletion != nil },
                set: { if !$0 { groupPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: groupPendingDeletion
        ) { group in
            Button("删除", role: .destructive) {
                groupPendingDeletion = nil
                model.deleteGroup(id: group.id)
            }
            Button("取消", role: .cancel) { groupPendingDeletion = nil }
        } message: { group in
            Text(appLocalized("分组及其中的条目会从库中删除；保存写回后才会影响源文件。"))
                .accessibilityLabel(group.title)
        }
        .sheet(item: $groupPendingMove) { group in
            AppKeePassMoveGroupView(model: model, group: group)
        }
        .sheet(item: $presentedEntry) { target in
            AppKeePassEntryEditorView(model: model, target: target)
        }
        .confirmationDialog(
            appLocalized("有未保存的修改"),
            isPresented: $isCloseConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("放弃修改并关闭", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text(appLocalized("关闭页面会丢弃尚未写回的修改，并清理内存中的明文。"))
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .needsDatabase, .needsUnlock:
            unlockContent
        case .unlocked:
            libraryContent
        }
    }

    private var unlockContent: some View {
        AndroidParityScreen {
            statusBanner

            AndroidParitySection(title: appLocalized("数据库")) {
                AndroidParityCard {
                    AndroidParityInfoRow(title: appLocalized("源文件"), value: model.databaseDisplayName)
                    AndroidParityInfoRow(title: appLocalized("KDBX 版本"), value: model.containerSummary)
                    AndroidParityInfoRow(title: appLocalized("加密"), value: model.cryptoSummary)
                    AndroidParityDivider()
                    Button {
                        isDatabaseImporterPresented = true
                    } label: {
                        Label("选择 KDBX 文件", systemImage: "key.radiowaves.forward")
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                    .disabled(model.isBusy)
                }
            }

            AndroidParitySection(title: appLocalized("解锁")) {
                AndroidParityCard {
                    SecureField("数据库密码", text: $model.password)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(AndroidParityTextFieldStyle())
                    HStack(spacing: 12) {
                        Button {
                            isKeyFileImporterPresented = true
                        } label: {
                            Label("选择密钥文件", systemImage: "folder")
                        }
                        .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                        .disabled(model.isBusy)

                        if !model.keyFileName.isEmpty {
                            Button {
                                model.clearKeyFile()
                            } label: {
                                Label("移除密钥", systemImage: "xmark")
                            }
                            .buttonStyle(AndroidParityButtonStyle(tone: .destructiveOutlined))
                            .disabled(model.isBusy)
                        }
                    }
                    if !model.keyFileName.isEmpty {
                        AndroidParityInfoRow(title: appLocalized("密钥文件"), value: model.keyFileName)
                    }
                    Button {
                        model.unlock()
                    } label: {
                        Label(
                            model.isBusy ? appLocalized("正在解锁…") : appLocalized("解锁数据库"),
                            systemImage: "lock.open"
                        )
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                    .disabled(model.isBusy || model.databaseData == nil)
                }
            }

            if model.databaseData == nil {
                AndroidParitySection(title: appLocalized("开始使用")) {
                    AndroidParityCard {
                        Text(appLocalized("先选择 KeePassXC / KeePass 导出的 .kdbx 文件，再输入数据库密码或密钥文件。写回前会重新打开校验，错误口令或未知格式不会覆盖源文件。"))
                            .font(.footnote)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var libraryContent: some View {
        AndroidParityScreen {
            statusBanner

            AndroidParitySection(title: appLocalized("数据库")) {
                AndroidParityCard {
                    AndroidParityInfoRow(
                        title: appLocalized("源文件"),
                        value: model.sourceFileURL?.lastPathComponent ?? model.databaseDisplayName
                    )
                    AndroidParityInfoRow(title: appLocalized("KDBX 版本"), value: model.containerSummary)
                    AndroidParityInfoRow(title: appLocalized("加密"), value: model.cryptoSummary)
                    AndroidParityInfoRow(title: appLocalized("分组"), value: "\(model.groupCount)")
                    AndroidParityInfoRow(title: appLocalized("条目"), value: "\(model.entryCount)")
                    AndroidParityInfoRow(
                        title: appLocalized("写回状态"),
                        value: model.isDirty
                            ? appLocalized("有未保存修改")
                            : appLocalized("与源文件一致")
                    )
                    AndroidParityDivider()
                    HStack(spacing: 12) {
                        Button {
                            presentedEntry = .create(groupID: model.selectedGroupID)
                        } label: {
                            Label("新建条目", systemImage: "plus")
                        }
                        .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                        .disabled(model.isBusy)

                        Button {
                            groupNameDraft = ""
                            groupEditorMode = .create(parentID: model.selectedGroupID)
                        } label: {
                            Label("新建分组", systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                        .disabled(model.isBusy)
                    }
                }
            }

            AndroidParitySection(title: appLocalized("搜索")) {
                AndroidParityCard {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                        TextField("搜索标题、用户名、URL、备注", text: $model.searchText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if model.isSearching {
                            Button {
                                model.searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                        }
                    }
                }
            }

            if model.isSearching {
                AndroidParitySection(title: appLocalized("搜索结果")) {
                    AndroidParityCard {
                        if model.visibleEntries.isEmpty {
                            emptyHint(appLocalized("没有匹配的条目。"))
                        } else {
                            ForEach(model.visibleEntries) { entry in
                                AppKeePassEntryRow(entry: entry, showsGroupPath: true) {
                                    presentedEntry = .edit(entry: entry)
                                }
                                if entry.id != model.visibleEntries.last?.id {
                                    AndroidParityDivider()
                                }
                            }
                        }
                    }
                }
            } else {
                AndroidParitySection(title: appLocalized("分组")) {
                    AndroidParityCard {
                        ForEach(model.visibleGroups) { group in
                            AppKeePassGroupRow(
                                group: group,
                                isSelected: group.id == model.selectedGroupID,
                                isExpanded: model.expandedGroupIDs.contains(group.id),
                                isLoading: model.isBusy,
                                canDelete: model.canDelete(group),
                                onSelect: { model.selectGroup(group) },
                                onToggle: { model.toggleExpansion(group) },
                                onRename: {
                                    groupNameDraft = group.title
                                    groupEditorMode = .rename(id: group.id, currentTitle: group.title)
                                },
                                onMove: { groupPendingMove = group },
                                onDelete: { groupPendingDeletion = group }
                            )
                            if group.id != model.visibleGroups.last?.id {
                                AndroidParityDivider()
                            }
                        }
                    }
                }

                AndroidParitySection(title: selectedGroupSectionTitle) {
                    AndroidParityCard {
                        if model.visibleEntries.isEmpty {
                            emptyHint(appLocalized("这个分组还没有条目。"))
                        } else {
                            ForEach(model.visibleEntries) { entry in
                                AppKeePassEntryRow(entry: entry, showsGroupPath: false) {
                                    presentedEntry = .edit(entry: entry)
                                }
                                if entry.id != model.visibleEntries.last?.id {
                                    AndroidParityDivider()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var selectedGroupSectionTitle: String {
        guard let group = model.selectedGroup else {
            return appLocalized("条目")
        }
        let title = group.title.isEmpty ? appLocalized("未命名分组") : group.title
        return title
    }

    @ViewBuilder
    private var statusBanner: some View {
        if let message = model.errorMessage {
            banner(
                text: message,
                systemImage: "exclamationmark.triangle.fill",
                tint: AndroidParityPalette.danger
            )
        } else if let message = model.statusMessage {
            banner(
                text: message,
                systemImage: "checkmark.circle.fill",
                tint: AndroidParityPalette.primary
            )
        }
    }

    private func banner(text: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(AndroidParityPalette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("关闭") {
                if model.isDirty {
                    isCloseConfirmationPresented = true
                } else {
                    dismiss()
                }
            }
        }
        if model.phaseIsUnlocked {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    model.save()
                } label: {
                    if model.isBusy {
                        ProgressView()
                    } else {
                        Text("保存")
                    }
                }
                .disabled(model.isBusy || !model.isDirty)
            }
        }
    }

    private func commitGroupEditor() {
        guard let mode = groupEditorMode else { return }
        let title = groupNameDraft
        groupEditorMode = nil
        switch mode {
        case .create:
            model.createGroup(title: title)
        case .rename(let id, _):
            model.renameGroup(id: id, title: title)
        }
    }
}

// MARK: - 分组行

private struct AppKeePassGroupRow: View {
    let group: KeePassNativeGroup
    let isSelected: Bool
    let isExpanded: Bool
    let isLoading: Bool
    let canDelete: Bool
    let onSelect: () -> Void
    let onToggle: () -> Void
    let onRename: () -> Void
    let onMove: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if group.childGroupCount > 0 {
                Button(action: onToggle) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 20, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AndroidParityPalette.textSecondary)
            } else {
                Color.clear.frame(width: 20, height: 28)
            }

            Button(action: onSelect) {
                HStack(spacing: 8) {
                    Image(systemName: iconName)
                        .foregroundStyle(isSelected ? AndroidParityPalette.primary : AndroidParityPalette.textSecondary)
                    Text(displayName)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(AndroidParityPalette.textPrimary)
                    Spacer(minLength: 8)
                    Text("\(group.entryCount)")
                        .font(.caption)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
        }
        .padding(.leading, CGFloat(group.depth) * 12)
        .padding(.vertical, 4)
        .background(
            isSelected ? AndroidParityPalette.primary.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contextMenu {
            Button(action: onRename) {
                Label("重命名", systemImage: "pencil")
            }
            Button(action: onMove) {
                Label("移动", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
            }
            if canDelete {
                Button(role: .destructive, action: onDelete) {
                    Label("删除", systemImage: "trash")
                }
            }
        }
    }

    private var displayName: String {
        if group.title.isEmpty {
            return appLocalized("未命名分组")
        }
        return group.title
    }

    private var iconName: String {
        if group.isRecycleBin {
            return "trash"
        }
        if group.isRoot {
            return "externaldrive.fill"
        }
        return isExpanded && group.childGroupCount > 0 ? "folder.fill" : "folder"
    }
}

// MARK: - 条目行

private struct AppKeePassEntryRow: View {
    let entry: KeePassNativeEntry
    let showsGroupPath: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: entry.isInRecycleBin ? "trash" : "key.fill")
                    .foregroundStyle(AndroidParityPalette.primary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textPrimary)
                    if !entry.username.isEmpty {
                        Text(entry.username)
                            .font(.caption)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }
                    if showsGroupPath, !entry.groupPath.isEmpty {
                        Text(entry.groupPath)
                            .font(.caption2)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }
                }
                Spacer(minLength: 8)
                if entry.hasPasswordField {
                    Text(appLocalized("密码"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.primary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }
}

// MARK: - 分组编辑意图

enum AppKeePassGroupEditorMode: Equatable {
    case create(parentID: String?)
    case rename(id: String, currentTitle: String)

    var title: String {
        switch self {
        case .create:
            return appLocalized("新建分组")
        case .rename:
            return appLocalized("重命名分组")
        }
    }

    var message: String {
        switch self {
        case .create:
            return appLocalized("新分组会放在当前选中的分组下。")
        case .rename:
            return appLocalized("只修改分组名称，组内条目与未知字段保持不变。")
        }
    }
}

// MARK: - 条目编辑意图

enum AppKeePassEntryEditorTarget: Identifiable, Equatable {
    case create(groupID: String?)
    case edit(entry: KeePassNativeEntry)

    var id: String {
        switch self {
        case .create(let groupID):
            return "create-\(groupID ?? "root")"
        case .edit(let entry):
            return "edit-\(entry.id)"
        }
    }
}

// MARK: - 移动分组

private struct AppKeePassMoveGroupView: View {
    let model: AppKeePassLibraryModel
    let group: KeePassNativeGroup
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let root = model.groups.first(where: { $0.isRoot }) {
                        destinationRow(root)
                    }
                    ForEach(model.moveCandidates(for: group)) { candidate in
                        destinationRow(candidate)
                    }
                } footer: {
                    Text(appLocalized("不能移动到自身或其子分组。"))
                }
            }
            .navigationTitle(appLocalized("移动分组"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func destinationRow(_ destination: KeePassNativeGroup) -> some View {
        Button {
            if model.moveGroup(id: group.id, to: destination.id) {
                dismiss()
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(destination.title.isEmpty ? appLocalized("未命名分组") : destination.title)
                Text(destination.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 条目编辑器

private struct AppKeePassEntryEditorView: View {
    let model: AppKeePassLibraryModel
    let target: AppKeePassEntryEditorTarget
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var username: String
    @State private var password: String
    @State private var url: String
    @State private var notes: String
    @State private var revealsPassword = false
    @State private var localError: String?

    init(model: AppKeePassLibraryModel, target: AppKeePassEntryEditorTarget) {
        self.model = model
        self.target = target
        switch target {
        case .create:
            _title = State(initialValue: "")
            _username = State(initialValue: "")
            _password = State(initialValue: "")
            _url = State(initialValue: "")
            _notes = State(initialValue: "")
        case .edit(let entry):
            _title = State(initialValue: entry.title)
            _username = State(initialValue: entry.username)
            _password = State(initialValue: entry.password)
            _url = State(initialValue: entry.url)
            _notes = State(initialValue: entry.notes)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let localError {
                    Section {
                        Text(localError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section(appLocalized("基础字段")) {
                    TextField("标题", text: $title)
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("URL", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                Section(appLocalized("密码")) {
                    HStack(spacing: 8) {
                        if revealsPassword {
                            TextField("密码", text: $password)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField("密码", text: $password)
                        }
                        Button {
                            revealsPassword.toggle()
                        } label: {
                            Image(systemName: revealsPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(revealsPassword ? appLocalized("隐藏密码") : appLocalized("显示密码"))
                        Button {
                            model.copySecret(password)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(appLocalized("复制密码"))
                    }
                }

                Section(appLocalized("备注")) {
                    TextField("备注", text: $notes, axis: .vertical)
                        .lineLimit(4...12)
                }

                if case .edit(let entry) = target, !entry.protectedFieldKeys.isEmpty {
                    Section(appLocalized("受保护字段")) {
                        Text(entry.protectedFieldKeys.joined(separator: "、"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
        }
    }

    private var navigationTitle: String {
        switch target {
        case .create:
            return appLocalized("新建条目")
        case .edit:
            return appLocalized("编辑条目")
        }
    }

    private func save() {
        localError = nil
        let succeeded: Bool
        switch target {
        case .create:
            succeeded = model.createEntry(
                title: title,
                username: username,
                password: password,
                url: url,
                notes: notes
            )
        case .edit(let entry):
            succeeded = model.updateEntry(
                id: entry.id,
                title: title,
                username: username,
                password: password,
                url: url,
                notes: notes
            )
        }
        if succeeded {
            dismiss()
        } else {
            localError = model.errorMessage
        }
    }
}
