import MonicaStorage
import SwiftUI

// issue #15：自定义字段与条目关联的 UI。
// 编辑器里只展示摘要，真正的增删改与排序都在两个 sheet 里完成；
// 详情页按字段类型渲染，隐藏文本默认掩码，必须由用户点“显示”才露出明文。

// MARK: - 编辑器区块

struct VaultItemExtrasEditorSection: View {
    @Bindable var session: AppSessionModel
    let itemKind: UnifiedVaultItemKind

    @State private var isFieldManagerPresented = false
    @State private var isRelationPickerPresented = false

    private var fields: [VaultCustomField] { session.presentedCustomFields }
    private var relations: [VaultItemRelation] { session.presentedRelations }

    private var currentItemID: String? {
        if case .edit(let route) = session.presentedEditorMode {
            return route.entryID
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AndroidParityDivider()

            HStack(spacing: 10) {
                Label {
                    Text("自定义字段")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.primary)
                } icon: {
                    Image(systemName: "text.badge.plus")
                        .foregroundStyle(AndroidParityPalette.primary)
                }
                Spacer(minLength: 8)
                Button(fields.isEmpty ? String(localized: "添加") : String(localized: "管理")) {
                    isFieldManagerPresented = true
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.primary)
                .buttonStyle(.plain)
                .frame(minHeight: AppInterfaceDensity.minimumTouchTarget)
            }

            if fields.isEmpty {
                Text("为这个条目补充恢复码、到期日等自定义字段。")
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            } else {
                ForEach(fields) { field in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(field.trimmedLabel.isEmpty ? String(localized: "未命名字段") : field.label)
                                .font(.subheadline)
                                .foregroundStyle(AndroidParityPalette.textPrimary)
                            Text(field.kind.displayName)
                                .font(.caption2)
                                .foregroundStyle(AndroidParityPalette.textSecondary)
                        }
                        Spacer(minLength: 12)
                        Text(summary(for: field))
                            .font(.footnote)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }

            AndroidParityDivider()

            HStack(spacing: 10) {
                Label {
                    Text("关联条目")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.primary)
                } icon: {
                    Image(systemName: "link")
                        .foregroundStyle(AndroidParityPalette.primary)
                }
                Spacer(minLength: 8)
                Button(relations.isEmpty ? String(localized: "选择") : String(localized: "编辑")) {
                    isRelationPickerPresented = true
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.primary)
                .buttonStyle(.plain)
                .frame(minHeight: AppInterfaceDensity.minimumTouchTarget)
            }

            if relations.isEmpty {
                Text("把这条记录和分类里的其他条目关联起来，例如登录条目关联恢复码笔记。")
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            } else {
                ForEach(relations) { relation in
                    relationChip(relation)
                }
            }
        }
        .sheet(isPresented: $isFieldManagerPresented) {
            VaultCustomFieldManagerSheet(fields: $session.presentedCustomFields)
        }
        .sheet(isPresented: $isRelationPickerPresented) {
            VaultItemRelationPickerSheet(
                relations: $session.presentedRelations,
                candidates: session.linkableItemDescriptors(excluding: currentItemID)
            )
        }
    }

    private func summary(for field: VaultCustomField) -> String {
        if field.isProtected {
            return field.maskedValue.isEmpty ? String(localized: "空") : field.maskedValue
        }
        if field.kind == .url, !field.hasValidURLValue {
            return String(localized: "链接格式待修正")
        }
        return field.value.isEmpty ? String(localized: "空") : field.value
    }

    @ViewBuilder
    private func relationChip(_ relation: VaultItemRelation) -> some View {
        let display = session.relationDisplay(for: relation)
        HStack(spacing: 8) {
            Image(systemName: display.status.isBroken ? "exclamationmark.triangle" : "arrow.turn.down.right")
                .font(.caption)
                .foregroundStyle(display.status.isBroken ? .orange : AndroidParityPalette.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(display.title)
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                    .lineLimit(1)
                Text("\(relation.targetKind.displayName) · \(statusText(for: display.status))")
                    .font(.caption2)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }
}

private func statusText(for status: VaultItemRelationStatus) -> String {
    switch status {
    case .available:
        return String(localized: "可用")
    case .deleted:
        return String(localized: "已删除")
    case .kindMismatch:
        return String(localized: "类型不匹配")
    case .missing:
        return String(localized: "不存在")
    }
}

// MARK: - 自定义字段管理

struct VaultCustomFieldManagerSheet: View {
    @Binding var fields: [VaultCustomField]
    @Environment(\.dismiss) private var dismiss
    @State private var revealedFieldIDs: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($fields) { $field in
                        VaultCustomFieldEditorRow(
                            field: $field,
                            isRevealed: revealedBinding(for: field.fieldID)
                        )
                    }
                    .onDelete(perform: deleteFields)
                    .onMove(perform: moveFields)

                    Button {
                        fields.append(VaultCustomField(label: String(localized: "新字段"), order: fields.count))
                    } label: {
                        Label("添加字段", systemImage: "plus.circle.fill")
                    }
                    .frame(minHeight: AppInterfaceDensity.minimumTouchTarget)
                } footer: {
                    Text("隐藏文本默认只显示掩码；点右侧的显示按钮才会出现明文，遮挡和明文都不会写入搜索索引或日志。")
                }
            }
            .navigationTitle("自定义字段")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    EditButton()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        normalizeOrder()
                        dismiss()
                    }
                }
            }
        }
        .onDisappear {
            revealedFieldIDs.removeAll()
            normalizeOrder()
        }
    }

    private func revealedBinding(for fieldID: String) -> Binding<Bool> {
        Binding(
            get: { revealedFieldIDs.contains(fieldID) },
            set: { isRevealed in
                if isRevealed {
                    revealedFieldIDs.insert(fieldID)
                } else {
                    revealedFieldIDs.remove(fieldID)
                }
            }
        )
    }

    private func deleteFields(at offsets: IndexSet) {
        fields.remove(atOffsets: offsets)
        normalizeOrder()
    }

    private func moveFields(from source: IndexSet, to destination: Int) {
        fields.move(fromOffsets: source, toOffset: destination)
        normalizeOrder()
    }

    private func normalizeOrder() {
        for index in fields.indices {
            fields[index].order = index
        }
    }
}

private struct VaultCustomFieldEditorRow: View {
    @Binding var field: VaultCustomField
    @Binding var isRevealed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("字段名称", text: $field.label)
                    .textInputAutocapitalization(.never)
                    .font(.subheadline.weight(.medium))

                Picker("字段类型", selection: $field.kind) {
                    ForEach(VaultCustomFieldKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(AndroidParityPalette.primary)
            }

            valueEditor
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var valueEditor: some View {
        switch field.kind {
        case .hiddenText:
            HStack(spacing: 8) {
                Group {
                    if isRevealed {
                        TextField("隐藏值", text: $field.value)
                    } else {
                        SecureField("隐藏值", text: $field.value)
                    }
                }
                .textInputAutocapitalization(.never)

                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .foregroundStyle(AndroidParityPalette.primary)
                        .frame(minWidth: AppInterfaceDensity.minimumTouchTarget, minHeight: AppInterfaceDensity.minimumTouchTarget)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isRevealed ? Text("隐藏") : Text("显示"))
            }
        case .url:
            VStack(alignment: .leading, spacing: 4) {
                TextField("https://example.com", text: $field.value)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !field.hasValidURLValue {
                    Text("链接需要以 https:// 这类协议开头")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        case .date:
            DatePicker(
                "日期",
                selection: dateBinding,
                displayedComponents: .date
            )
        case .text:
            TextField("值", text: $field.value, axis: .vertical)
                .textInputAutocapitalization(.never)
                .lineLimit(1...4)
        }
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: { VaultCustomFieldDateCoding.date(from: field.value) ?? Date() },
            set: { field.value = VaultCustomFieldDateCoding.string(from: $0) }
        )
    }
}

// MARK: - 关联选择

struct RelationCandidateGroup: Identifiable {
    let kind: UnifiedVaultItemKind
    let items: [VaultItemDescriptor]

    var id: UnifiedVaultItemKind { kind }
}

struct VaultItemRelationPickerSheet: View {
    @Binding var relations: [VaultItemRelation]
    let candidates: [VaultItemDescriptor]

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredCandidates: [VaultItemDescriptor] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return candidates
        }
        return candidates.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var groupedCandidates: [RelationCandidateGroup] {
        var order: [UnifiedVaultItemKind] = []
        var grouped: [UnifiedVaultItemKind: [VaultItemDescriptor]] = [:]
        for candidate in filteredCandidates {
            if grouped[candidate.kind] == nil {
                order.append(candidate.kind)
            }
            grouped[candidate.kind, default: []].append(candidate)
        }
        return order.map { RelationCandidateGroup(kind: $0, items: grouped[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                if candidates.isEmpty {
                    Section {
                        Text("当前分类里还没有可关联的条目。")
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(groupedCandidates) { group in
                    Section {
                        ForEach(group.items, id: \.itemID) { candidate in
                            relationCandidateRow(candidate)
                        }
                    } header: {
                        Text(group.kind.displayName)
                    }
                }
            }
            .navigationTitle("关联条目")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: Text("搜索条目"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func relationCandidateRow(_ candidate: VaultItemDescriptor) -> some View {
        Button {
            toggle(candidate)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.title.isEmpty ? String(localized: "未命名条目") : candidate.title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if isSelected(candidate) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AndroidParityPalette.primary)
                }
            }
            .frame(minHeight: AppInterfaceDensity.minimumTouchTarget)
        }
        .buttonStyle(.plain)
    }

    private func isSelected(_ candidate: VaultItemDescriptor) -> Bool {
        relations.contains { $0.targetItemID == candidate.itemID && $0.targetKind == candidate.kind }
    }

    private func toggle(_ candidate: VaultItemDescriptor) {
        if let index = relations.firstIndex(where: {
            $0.targetItemID == candidate.itemID && $0.targetKind == candidate.kind
        }) {
            relations.remove(at: index)
        } else {
            guard relations.count < VaultItemExtras.maxRelations else {
                return
            }
            relations.append(VaultItemRelation(targetItemID: candidate.itemID, targetKind: candidate.kind))
        }
    }
}

// MARK: - 详情展示

struct VaultItemExtrasDetailSection: View {
    let customFields: [VaultCustomField]
    let relations: [VaultItemResolvedRelation]

    @State private var revealedFieldIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 18) {
            if !customFields.isEmpty {
                AndroidParitySection(title: String(localized: "自定义字段")) {
                    AndroidParityCard {
                        ForEach(customFields.indices, id: \.self) { index in
                            if index > 0 {
                                AndroidParityDivider()
                            }
                            fieldRow(customFields[index])
                        }
                    }
                }
            }

            if !relations.isEmpty {
                AndroidParitySection(title: String(localized: "关联条目")) {
                    AndroidParityCard {
                        ForEach(relations.indices, id: \.self) { index in
                            if index > 0 {
                                AndroidParityDivider()
                            }
                            relationRow(relations[index])
                        }
                    }
                }
            }
        }
        .onDisappear {
            revealedFieldIDs.removeAll()
        }
    }

    private func fieldRow(_ field: VaultCustomField) -> some View {
        let revealed = revealedFieldIDs.contains(field.fieldID)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(field.trimmedLabel.isEmpty ? String(localized: "未命名字段") : field.label)
                    .font(.subheadline)
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                Text(field.kind.displayName)
                    .font(.caption2)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
            Spacer(minLength: 16)
            fieldValueView(field, revealed: revealed)

            if field.isProtected {
                Button {
                    if revealed {
                        revealedFieldIDs.remove(field.fieldID)
                    } else {
                        revealedFieldIDs.insert(field.fieldID)
                    }
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                        .foregroundStyle(AndroidParityPalette.primary)
                        .frame(minWidth: AppInterfaceDensity.minimumTouchTarget, minHeight: AppInterfaceDensity.minimumTouchTarget)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(revealed ? Text("隐藏") : Text("显示"))
            }
        }
        .frame(minHeight: 32)
    }

    private func relationRow(_ resolved: VaultItemResolvedRelation) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName(for: resolved.status))
                .font(.footnote)
                .foregroundStyle(resolved.status.isBroken ? Color.orange : AndroidParityPalette.primary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(resolved.targetTitle ?? String(localized: "条目不存在"))
                    .font(.subheadline)
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                    .lineLimit(2)
                Text(relationSubtitle(resolved))
                    .font(.caption2)
                    .foregroundStyle(resolved.status.isBroken ? Color.orange : AndroidParityPalette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 32)
    }

    @ViewBuilder
    private func fieldValueView(_ field: VaultCustomField, revealed: Bool) -> some View {
        if field.isProtected && !revealed {
            Text(field.maskedValue)
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .accessibilityLabel(Text("已隐藏"))
        } else if field.kind == .url,
                  field.hasValidURLValue,
                  let url = URL(string: field.value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            Link(field.value, destination: url)
                .font(.footnote)
                .lineLimit(1)
        } else if field.kind == .date, let date = VaultCustomFieldDateCoding.date(from: field.value) {
            Text(date.formatted(date: .abbreviated, time: .omitted))
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
        } else {
            Text(field.value.isEmpty ? String(localized: "空") : field.value)
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func relationSubtitle(_ resolved: VaultItemResolvedRelation) -> String {
        switch resolved.status {
        case .available:
            return resolved.targetKind.displayName
        case .deleted:
            return String(localized: "目标条目已在回收站，链接暂时不可用")
        case .kindMismatch:
            return String(localized: "目标条目类型已变化，链接不可用")
        case .missing:
            return String(localized: "目标条目已不存在")
        }
    }

    private func iconName(for status: VaultItemRelationStatus) -> String {
        switch status {
        case .available:
            return "link"
        case .deleted:
            return "exclamationmark.triangle"
        case .kindMismatch:
            return "questionmark.circle"
        case .missing:
            return "xmark.circle"
        }
    }
}
