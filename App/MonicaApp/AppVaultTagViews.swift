//
//  AppVaultTagViews.swift
//  Monica
//
//  标签、排序与归档在列表页与详情页的界面。
//

import MonicaStorage
import SwiftUI

// MARK: - 列表工具条：排序 + 标签筛选

struct VaultTagToolsBar: View {
    @Bindable var session: AppSessionModel
    @State private var isManagingTagsPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                sortMenu
                Spacer(minLength: 8)
                Button {
                    isManagingTagsPresented = true
                } label: {
                    Label(String(localized: "管理标签"), systemImage: "tag")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(AndroidParityPalette.surfaceVariant, in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(AndroidParityPalette.textPrimary)
            }

            if !session.vaultTagCatalog.isEmpty || !session.selectedVaultTagIDs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(session.vaultTagCatalog) { tag in
                            tagChip(tag)
                        }
                        if !session.selectedVaultTagIDs.isEmpty {
                            Button {
                                session.clearVaultTagFilters()
                            } label: {
                                Label(String(localized: "清除标签筛选"), systemImage: "xmark.circle")
                                    .font(.caption.weight(.bold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(AndroidParityPalette.surfaceVariant, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $isManagingTagsPresented) {
            VaultTagManagerSheet(session: session)
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(VaultEntrySortField.allCases) { field in
                Button {
                    session.setVaultSortField(field)
                } label: {
                    if session.vaultSortPreference.field == field {
                        Label(field.title, systemImage: "checkmark")
                    } else {
                        Label(field.title, systemImage: field.systemImage)
                    }
                }
            }
            Divider()
            ForEach([VaultEntrySortDirection.ascending, .descending], id: \.rawValue) { direction in
                Button {
                    session.setVaultSortDirection(direction)
                } label: {
                    if session.vaultSortPreference.direction == direction {
                        Label(direction.title, systemImage: "checkmark")
                    } else {
                        Label(direction.title, systemImage: direction.systemImage)
                    }
                }
            }
            Divider()
            Button {
                session.resetVaultSortPreference()
            } label: {
                Label(String(localized: "恢复默认排序"), systemImage: "arrow.counterclockwise")
            }
        } label: {
            Label(
                String(localized: "排序：") + session.vaultSortSummary,
                systemImage: session.vaultSortPreference.field.systemImage
            )
            .font(.caption.weight(.bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(AndroidParityPalette.primaryContainer, in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(AndroidParityPalette.primary)
    }

    private func tagChip(_ tag: VaultTag) -> some View {
        let isSelected = session.selectedVaultTagIDs.contains(tag.id)
        return Button {
            session.toggleVaultTagFilter(tag.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "tag.fill" : "tag")
                Text(tag.name)
                Text("\(tag.entryCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                isSelected ? AndroidParityPalette.primaryContainer : AndroidParityPalette.surfaceVariant,
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? AndroidParityPalette.primary : AndroidParityPalette.textPrimary)
        .accessibilityLabel(Text(String(localized: "筛选标签：") + tag.name))
    }
}

// MARK: - 标签管理（重命名 / 删除）

struct VaultTagManagerSheet: View {
    @Bindable var session: AppSessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var renamingTag: VaultTag?
    @State private var renameDraft = ""
    @State private var deletingTag: VaultTag?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if session.vaultTagCatalog.isEmpty {
                        Text(String(localized: "还没有标签。打开任意条目，在「标签与归档」里添加第一个标签。"))
                            .font(.subheadline)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                            .padding(.vertical, 20)
                    } else {
                        ForEach(session.vaultTagCatalog) { tag in
                            HStack(spacing: 12) {
                                Image(systemName: "tag.fill")
                                    .foregroundStyle(AndroidParityPalette.primary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tag.name)
                                        .font(.subheadline.weight(.semibold))
                                    Text(String(localized: "条目数：") + "\(tag.entryCount)")
                                        .font(.caption2)
                                        .foregroundStyle(AndroidParityPalette.textSecondary)
                                }
                                Spacer()
                                Button(String(localized: "重命名")) {
                                    renamingTag = tag
                                    renameDraft = tag.name
                                }
                                .buttonStyle(.plain)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(AndroidParityPalette.primary)
                                .frame(minWidth: 44, minHeight: 44)
                                Button(String(localized: "删除")) {
                                    deletingTag = tag
                                }
                                .buttonStyle(.plain)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.red)
                                .frame(minWidth: 44, minHeight: 44)
                            }
                            .padding(12)
                            .background(AndroidParityPalette.surfaceVariant, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        Text(String(localized: "重命名会同步更新所有使用该标签的条目；删除只移除标签关联，不会删除条目。"))
                            .font(.caption2)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                            .padding(.top, 6)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(18)
            }
            .background(AndroidParityPalette.background.ignoresSafeArea())
            .navigationTitle(String(localized: "标签"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "完成")) { dismiss() }
                }
            }
            .alert(
                String(localized: "重命名标签"),
                isPresented: Binding(
                    get: { renamingTag != nil },
                    set: { if !$0 { renamingTag = nil } }
                )
            ) {
                TextField(String(localized: "标签名称"), text: $renameDraft)
                Button(String(localized: "取消"), role: .cancel) { renamingTag = nil }
                Button(String(localized: "保存")) {
                    guard let tag = renamingTag else { return }
                    do {
                        try session.renameVaultTag(tagID: tag.id, to: renameDraft)
                        renamingTag = nil
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            .confirmationDialog(
                String(localized: "删除标签？"),
                isPresented: Binding(
                    get: { deletingTag != nil },
                    set: { if !$0 { deletingTag = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(String(localized: "删除标签"), role: .destructive) {
                    guard let tag = deletingTag else { return }
                    do {
                        try session.deleteVaultTag(tagID: tag.id)
                        deletingTag = nil
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                Button(String(localized: "取消"), role: .cancel) { deletingTag = nil }
            } message: {
                Text(String(localized: "只会移除标签关联，不会删除任何条目。"))
            }
        }
    }
}

// MARK: - 详情页：标签与归档

struct VaultEntryTagsSection: View {
    @Bindable var session: AppSessionModel
    let entryID: String
    @State private var isEditorPresented = false

    private var tags: [VaultEntryTag] {
        session.vaultTags(forEntryID: entryID)
    }

    var body: some View {
        AndroidParitySection(title: String(localized: "标签与归档")) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                VStack(alignment: .leading, spacing: 14) {
                    if tags.isEmpty {
                        Text(String(localized: "尚未添加标签"))
                            .font(.subheadline)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    } else {
                        tagChips
                    }

                    Button {
                        isEditorPresented = true
                    } label: {
                        Label(String(localized: "编辑标签"), systemImage: "tag.badge.plus")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AndroidParityPalette.primary)

                    AndroidParityDivider()

                    Toggle(
                        String(localized: "归档"),
                        isOn: Binding(
                            get: { session.isVaultEntryArchived(entryID) },
                            set: { newValue in
                                try? session.setVaultEntryArchived(newValue, entryID: entryID)
                            }
                        )
                    )
                    .font(.subheadline.weight(.semibold))
                    .tint(AndroidParityPalette.primary)
                    Text(String(localized: "归档条目不会出现在默认列表、快捷指令与自动填充候选中，可在「归档」筛选中查看。"))
                        .font(.caption2)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
                .padding(14)
            }
        }
        .sheet(isPresented: $isEditorPresented) {
            VaultEntryTagEditorSheet(session: session, entryID: entryID)
        }
    }

    private var tagChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tags) { tag in
                    HStack(spacing: 6) {
                        Text(tag.name)
                            .font(.caption.weight(.semibold))
                        Button {
                            try? session.removeVaultTag(tagID: tag.id, fromEntryID: entryID)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(String(localized: "移除标签：") + tag.name))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(AndroidParityPalette.primaryContainer, in: Capsule())
                    .foregroundStyle(AndroidParityPalette.primary)
                }
            }
        }
    }
}

// MARK: - 条目标签编辑

struct VaultEntryTagEditorSheet: View {
    @Bindable var session: AppSessionModel
    let entryID: String
    @Environment(\.dismiss) private var dismiss
    @State private var newTagName = ""
    @State private var errorMessage: String?

    private var assignedTags: [VaultEntryTag] {
        session.vaultTags(forEntryID: entryID)
    }

    private var assignedIDs: Set<String> {
        Set(assignedTags.map(\.id))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !assignedTags.isEmpty {
                        sectionTitle(String(localized: "已添加"))
                        chips(assignedTags)
                    }

                    sectionTitle(String(localized: "添加标签"))
                    HStack(spacing: 10) {
                        TextField(String(localized: "输入标签名称"), text: $newTagName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                AndroidParityPalette.surfaceVariant,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                        Button(String(localized: "添加")) {
                            addTag()
                        }
                        .buttonStyle(.plain)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AndroidParityPalette.primary)
                        .frame(minWidth: 44, minHeight: 44)
                    }

                    let suggestions = session.vaultTagCatalog.filter { !assignedIDs.contains($0.id) }
                    if !suggestions.isEmpty {
                        sectionTitle(String(localized: "已有标签"))
                        chips(suggestions.map { VaultEntryTag(id: $0.id, name: $0.name) })
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(18)
            }
            .background(AndroidParityPalette.background.ignoresSafeArea())
            .navigationTitle(String(localized: "编辑标签"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "完成")) { dismiss() }
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.heavy))
            .foregroundStyle(AndroidParityPalette.textSecondary)
    }

    private func chips(_ tags: [VaultEntryTag]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tags) { tag in
                    Button {
                        toggle(tag)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: assignedIDs.contains(tag.id) ? "checkmark.circle.fill" : "plus.circle")
                            Text(tag.name)
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(AndroidParityPalette.surfaceVariant, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                }
            }
        }
    }

    private func toggle(_ tag: VaultEntryTag) {
        do {
            if assignedIDs.contains(tag.id) {
                try session.removeVaultTag(tagID: tag.id, fromEntryID: entryID)
            } else {
                try session.addVaultTag(named: tag.name, toEntryID: entryID)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addTag() {
        let name = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try session.addVaultTag(named: name, toEntryID: entryID)
            newTagName = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
