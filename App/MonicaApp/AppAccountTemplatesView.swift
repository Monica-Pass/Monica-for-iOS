//
//  AppAccountTemplatesView.swift
//  Monica
//
//  issue #127：常用账号模板的管理页、编辑页、选择页，以及新建登录条目时
//  顶部的「从模板填充」入口。
//
//  模板只保存网址、账号占位提示、备注和自定义字段骨架，从不包含密码或密钥；
//  写库与读库都走 MonicaStorage 的加密侧表仓储。
//

import MonicaStorage
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 管理页

struct AccountTemplatesView: View {
    @Bindable var session: AppSessionModel

    @State private var isCreatingTemplate = false
    @State private var editingTemplate: AccountTemplate?
    @State private var pendingDeletion: AccountTemplate?
    @State private var isShowingAllIssues = false

    private var builtinTemplates: [AccountTemplate] {
        session.accountTemplates.filter(\.isBuiltin)
    }

    private var customTemplates: [AccountTemplate] {
        session.customAccountTemplates
    }

    var body: some View {
        AndroidParityScreen {
            headerCard
            builtinSection
            customSection
            transferSection
            if let preview = session.accountTemplateImportPreview {
                importPreviewSection(preview)
            }
        }
        .onAppear {
            session.prepareAccountTemplatesForEditor()
        }
        .fileImporter(
            isPresented: $session.isAccountTemplateImportPickerPresented,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    session.beginAccountTemplateImport(from: url)
                }
            case .failure(let error):
                session.entryOperationState = .failed(error.localizedDescription)
            }
        }
        .fileExporter(
            isPresented: $session.isAccountTemplateExportPresented,
            document: session.accountTemplateExportDocument ?? AccountTemplateExportDocument(),
            contentType: .json,
            defaultFilename: AccountTemplateCodec.suggestedFileName()
        ) { result in
            session.finishAccountTemplateExport(result)
        }
        .sheet(isPresented: $isCreatingTemplate) {
            AccountTemplateEditorView(template: AccountTemplate(title: ""), isNew: true, session: session)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $editingTemplate) { template in
            AccountTemplateEditorView(template: template, isNew: false, session: session)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .alert(
            "删除模板？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingDeletion = nil
                    }
                }
            ),
            presenting: pendingDeletion
        ) { template in
            Button("删除「\(template.displayTitle)」", role: .destructive) {
                session.deleteAccountTemplate(template)
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { _ in
            Text("已经用它填过的条目不受影响。")
        }
    }

    // MARK: 顶部

    private var headerCard: some View {
        AndroidParitySection(title: String(localized: "常用账号模板")) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                AndroidParityInfoRow(
                    title: String(localized: "内置模板"),
                    value: String(localized: "\(builtinTemplates.count) 个")
                )
                AndroidParityInfoRow(
                    title: String(localized: "自定义模板"),
                    value: String(localized: "\(customTemplates.count) 个")
                )
                Text("模板只保存网址、账号占位提示、备注和自定义字段，不会保存密码或密钥。新建登录条目时可以选择模板填充，填完还可以继续修改。")
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                if let message = session.accountTemplateStatusMessage {
                    Text(message)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.primary)
                }
                Button {
                    isCreatingTemplate = true
                } label: {
                    Label("新建模板", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .filled))
            }
        }
    }

    // MARK: 内置模板

    private var builtinSection: some View {
        AndroidParitySection(title: String(localized: "内置模板")) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.4)) {
                Text("内置模板只读；需要调整时先复制成自定义模板。")
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                ForEach(builtinTemplates) { template in
                    AccountTemplateRow(
                        template: template,
                        isBuiltin: true,
                        canMoveUp: false,
                        canMoveDown: false,
                        onEdit: nil,
                        onDuplicate: { session.duplicateAccountTemplate(template) },
                        onMoveUp: nil,
                        onMoveDown: nil,
                        onDelete: nil
                    )
                    if template.id != builtinTemplates.last?.id {
                        AndroidParityDivider()
                    }
                }
            }
        }
    }

    // MARK: 自定义模板

    private var customSection: some View {
        AndroidParitySection(title: String(localized: "自定义模板")) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.4)) {
                if customTemplates.isEmpty {
                    Text("还没有自定义模板。可以新建一个，或者导入之前导出的模板文件。")
                        .font(.caption)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                } else {
                    ForEach(Array(customTemplates.enumerated()), id: \.element.id) { index, template in
                        AccountTemplateRow(
                            template: template,
                            isBuiltin: false,
                            canMoveUp: index > 0,
                            canMoveDown: index < customTemplates.count - 1,
                            onEdit: { editingTemplate = template },
                            onDuplicate: { session.duplicateAccountTemplate(template) },
                            onMoveUp: { session.moveAccountTemplate(template, offset: -1) },
                            onMoveDown: { session.moveAccountTemplate(template, offset: 1) },
                            onDelete: { pendingDeletion = template }
                        )
                        if template.id != customTemplates.last?.id {
                            AndroidParityDivider()
                        }
                    }
                }
            }
        }
    }

    // MARK: 导入导出

    private var transferSection: some View {
        AndroidParitySection(title: String(localized: "导入 / 导出")) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.4)) {
                Text("导出文件只包含自定义模板，带格式标识和版本号；导入前会先逐条校验，确认后才写入保险库。")
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                Button {
                    session.presentAccountTemplateImportPicker()
                } label: {
                    Label("导入模板文件", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                Button {
                    session.exportAccountTemplates()
                } label: {
                    Label("导出模板文件", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                Button {
                    session.dismissAccountTemplates()
                } label: {
                    Label("完成", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .filled))
            }
        }
    }

    // MARK: 导入预览

    private func importPreviewSection(_ preview: AccountTemplateImportPreview) -> some View {
        AndroidParitySection(title: String(localized: "导入预览")) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                AndroidParityInfoRow(title: String(localized: "文件"), value: preview.fileName ?? String(localized: "未选择文件"))
                AndroidParityInfoRow(title: String(localized: "格式版本"), value: preview.versionText)
                AndroidParityInfoRow(
                    title: String(localized: "可导入"),
                    value: String(localized: "\(preview.itemCount) / \(preview.sourceItemCount) 条")
                )
                if preview.conflictCount > 0 {
                    AndroidParityInfoRow(
                        title: String(localized: "ID 冲突"),
                        value: String(localized: "\(preview.conflictCount) 条")
                    )
                }
                Toggle(
                    "覆盖同 ID 的自定义模板",
                    isOn: Binding(
                        get: { session.accountTemplateImportOverwrite },
                        set: { session.updateAccountTemplateImportOverwrite($0) }
                    )
                )
                .font(.caption)
                if !preview.issues.isEmpty {
                    issueLines(preview)
                }
                HStack(spacing: 12) {
                    Button {
                        session.cancelAccountTemplateImport()
                    } label: {
                        Label("取消", systemImage: "xmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                    Button {
                        session.confirmAccountTemplateImport()
                    } label: {
                        Label("导入", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                    .disabled(!preview.canImport)
                }
            }
        }
    }

    @ViewBuilder
    private func issueLines(_ preview: AccountTemplateImportPreview) -> some View {
        let visible = isShowingAllIssues ? preview.issues : Array(preview.issues.prefix(5))
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(visible.enumerated()), id: \.offset) { _, issue in
                Text(issueLine(issue))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if preview.issues.count > 5 {
                Button(isShowingAllIssues ? String(localized: "收起问题") : String(localized: "查看全部问题（\(preview.issues.count)）")) {
                    isShowingAllIssues.toggle()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(AndroidParityPalette.primary)
            }
        }
    }

    private func issueLine(_ issue: VaultImportIssue) -> String {
        if let index = issue.sourceIndex {
            return String(localized: "第 \(index + 1) 条：\(issue.message)")
        }
        return issue.message
    }
}

// MARK: - 单行模板

private struct AccountTemplateRow: View {
    let template: AccountTemplate
    let isBuiltin: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onEdit: (() -> Void)?
    let onDuplicate: (() -> Void)?
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?
    let onDelete: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AndroidParityIconTile(systemImage: isBuiltin ? "lock.shield" : "square.stack.3d.up")
            VStack(alignment: .leading, spacing: 4) {
                Text(template.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                Text(template.urlSummary)
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .lineLimit(1)
                badges
            }
            Spacer(minLength: 8)
            if hasActions {
                Menu {
                    if let onEdit {
                        Button("编辑", systemImage: "pencil", action: onEdit)
                    }
                    if let onDuplicate {
                        Button("复制为自定义模板", systemImage: "plus.square.on.square", action: onDuplicate)
                    }
                    if let onMoveUp {
                        Button("上移", systemImage: "arrow.up", action: onMoveUp)
                            .disabled(!canMoveUp)
                    }
                    if let onMoveDown {
                        Button("下移", systemImage: "arrow.down", action: onMoveDown)
                            .disabled(!canMoveDown)
                    }
                    if let onDelete {
                        Button("删除", systemImage: "trash", role: .destructive, action: onDelete)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
            }
        }
    }

    private var badges: some View {
        HStack(spacing: 6) {
            Text(kindLabel)
            if template.requiresTOTP {
                Text("建议开启两步验证")
            }
            if !template.usernamePlaceholder.isEmpty {
                Text(template.usernamePlaceholder)
                    .lineLimit(1)
            }
            if !template.defaultCustomFields.isEmpty {
                Text("\(template.defaultCustomFields.count) 个字段")
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(AndroidParityPalette.primary)
    }

    private var kindLabel: String {
        template.itemKind == .login ? String(localized: "登录") : template.itemKind.localizedDisplayName
    }

    private var hasActions: Bool {
        onEdit != nil || onDuplicate != nil || onMoveUp != nil || onMoveDown != nil || onDelete != nil
    }
}

// MARK: - 新建 / 编辑模板

struct AccountTemplateEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: AppSessionModel

    @State private var draft: AccountTemplate
    @State private var urlsText: String
    @State private var errorMessage: String?

    private let isNew: Bool

    /// 模板里不允许出现受保护字段（隐藏文本），编辑时也只能选这几类。
    private let selectableKinds = VaultCustomFieldKind.allCases.filter { !$0.isProtected }

    init(template: AccountTemplate, isNew: Bool, session: AppSessionModel) {
        _draft = State(initialValue: template)
        _urlsText = State(initialValue: template.defaultURLs.joined(separator: "\n"))
        self.isNew = isNew
        self.session = session
    }

    var body: some View {
        AndroidParityScreen {
            AndroidParitySection(title: isNew ? String(localized: "新建模板") : String(localized: "编辑模板")) {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                    AndroidParityInfoRow(title: String(localized: "适用条目"), value: String(localized: "登录"))
                    AccountTemplateLabeledField(
                        title: String(localized: "模板标题"),
                        placeholder: String(localized: "例如「公司邮箱」"),
                        text: $draft.title
                    )
                    AccountTemplateLabeledField(
                        title: String(localized: "账号占位提示"),
                        placeholder: String(localized: "例如「GitHub 用户名或邮箱」"),
                        text: $draft.usernamePlaceholder
                    )
                    urlEditor
                    notesEditor
                    Toggle("提示该账号建议开启两步验证", isOn: $draft.requiresTOTP)
                        .font(.subheadline.weight(.semibold))
                    customFieldsEditor
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    HStack(spacing: 12) {
                        Button {
                            dismiss()
                        } label: {
                            Label("取消", systemImage: "xmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                        Button {
                            save()
                        } label: {
                            Label("保存", systemImage: "checkmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                    }
                }
            }
        }
    }

    private var urlEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("默认网址（每行一个）")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
            TextEditor(text: $urlsText)
                .frame(minHeight: 88)
                .padding(12)
                .scrollContentBackground(.hidden)
                .background(AndroidParityPalette.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 16).stroke(AndroidParityPalette.outline, lineWidth: 1) }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
        }
    }

    private var notesEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("默认备注")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
            TextEditor(text: $draft.defaultNotes)
                .frame(minHeight: 88)
                .padding(12)
                .scrollContentBackground(.hidden)
                .background(AndroidParityPalette.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 16).stroke(AndroidParityPalette.outline, lineWidth: 1) }
        }
    }

    private var customFieldsEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("默认自定义字段")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
            ForEach(draft.defaultCustomFields.indices, id: \.self) { index in
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        TextField("字段名", text: $draft.defaultCustomFields[index].label)
                            .textFieldStyle(AndroidParityTextFieldStyle())
                        Button {
                            draft.defaultCustomFields.remove(at: index)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    HStack(spacing: 10) {
                        Picker("类型", selection: $draft.defaultCustomFields[index].kind) {
                            ForEach(selectableKinds, id: \.self) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        TextField("默认值（可留空）", text: $draft.defaultCustomFields[index].defaultValue)
                            .textFieldStyle(AndroidParityTextFieldStyle())
                    }
                }
            }
            if draft.defaultCustomFields.count < AccountTemplateRules.maxCustomFieldCount {
                Button {
                    draft.defaultCustomFields.append(
                        AccountTemplateCustomField(label: "", kind: .text, defaultValue: "")
                    )
                } label: {
                    Label("添加字段", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
            }
        }
    }

    private func save() {
        errorMessage = nil
        var template = draft
        template.itemKind = .login
        template.isBuiltin = false
        template.defaultURLs = urlsText
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        if isNew {
            template.createdAt = Date()
        }
        template.updatedAt = Date()
        do {
            _ = try session.saveAccountTemplate(template)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct AccountTemplateLabeledField: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(AndroidParityTextFieldStyle())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}

// MARK: - 选择模板

struct AccountTemplatePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: AppSessionModel

    private var templates: [AccountTemplate] {
        session.accountTemplates(for: .login)
    }

    var body: some View {
        AndroidParityScreen {
            if templates.isEmpty {
                AndroidParitySection(title: String(localized: "从模板填充")) {
                    AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                        Text("还没有可用的模板。可以先在「设置 → 常用账号模板」里新建一个。")
                            .font(.caption)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }
                }
            } else {
                AndroidParitySection(title: String(localized: "从模板填充")) {
                    AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                        Text("选一个模板填入空字段，已经填好的内容不会被覆盖。")
                            .font(.caption)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                        ForEach(templates) { template in
                            Button {
                                session.applyAccountTemplate(template)
                                dismiss()
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    AndroidParityIconTile(systemImage: template.isBuiltin ? "lock.shield" : "square.stack.3d.up")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(template.displayTitle)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(AndroidParityPalette.textPrimary)
                                        Text(template.urlSummary)
                                            .font(.caption)
                                            .foregroundStyle(AndroidParityPalette.textSecondary)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(AndroidParityPalette.textSecondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if template.id != templates.last?.id {
                                AndroidParityDivider()
                            }
                        }
                    }
                }
            }
            Button {
                dismiss()
            } label: {
                Label("取消", systemImage: "xmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
        }
    }
}

// MARK: - 新建登录条目时的模板入口

struct AccountTemplatePrefillSection: View {
    @Bindable var session: AppSessionModel
    @State private var isPickerPresented = false

    var body: some View {
        VStack(spacing: 8) {
            Button {
                session.prepareAccountTemplatesForEditor()
                isPickerPresented = true
            } label: {
                Label("从模板填充", systemImage: "square.stack.3d.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .outlined))

            if let message = session.accountTemplatePrefillMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !session.accountTemplateUsernamePrompt.isEmpty {
                Text("账号占位提示：\(session.accountTemplateUsernamePrompt)")
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(isPresented: $isPickerPresented) {
            AccountTemplatePickerSheet(session: session)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}
