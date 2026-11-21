import MonicaStorage
import SwiftUI

// MARK: - #27 保险箱总览

/// 总览页：每类条目数量、收藏、回收站、最近使用与文件夹规模。
///
/// 全部数字来自 `VaultFolderOverview`（由搜索索引的同一批不敏感投影构建），
/// 不额外读库、不新增持久化结构。
struct VaultOverviewPanel: View {
    let overview: VaultFolderOverview
    let tree: VaultFolderTree
    let onOpenFolder: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AndroidParitySection(title: String(localized: "保险箱总览")) {
                AndroidParityCard {
                    HStack(spacing: 12) {
                        summaryTile(
                            title: "条目",
                            value: overview.totalActiveEntries,
                            systemImage: "square.stack.3d.up.fill"
                        )
                        summaryTile(
                            title: "收藏",
                            value: overview.totalFavorites,
                            systemImage: "star.fill"
                        )
                        summaryTile(
                            title: "回收站",
                            value: overview.totalTrashedEntries,
                            systemImage: "trash.fill"
                        )
                    }
                    AndroidParityDivider()
                    AndroidParityInfoRow(title: String(localized: "文件夹总数"), value: "\(overview.totalFolderCount)")
                    AndroidParityInfoRow(title: String(localized: "子文件夹"), value: "\(overview.nestedFolderCount)")
                    AndroidParityInfoRow(title: String(localized: "最深层级"), value: "\(overview.deepestLevel)")
                }
            }

            AndroidParitySection(title: String(localized: "按类型")) {
                AndroidParityCard {
                    ForEach(overview.kindCounts) { count in
                        HStack(spacing: 12) {
                            Text(count.kind.displayName)
                                .font(.subheadline)
                                .foregroundStyle(AndroidParityPalette.textPrimary)
                            Spacer(minLength: 12)
                            Text(countDetail(count))
                                .font(.footnote)
                                .foregroundStyle(AndroidParityPalette.textSecondary)
                        }
                        .frame(minHeight: 32)
                    }
                }
            }

            if !overview.recentDocuments.isEmpty {
                AndroidParitySection(title: String(localized: "最近使用")) {
                    AndroidParityCard {
                        ForEach(overview.recentDocuments) { document in
                            HStack(spacing: 12) {
                                Text(document.title.isEmpty ? document.kind.displayName : document.title)
                                    .font(.subheadline)
                                    .foregroundStyle(AndroidParityPalette.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 12)
                                Text(document.kind.displayName)
                                    .font(.caption)
                                    .foregroundStyle(AndroidParityPalette.textSecondary)
                            }
                            .frame(minHeight: 32)
                        }
                    }
                }
            }

            AndroidParitySection(title: String(localized: "文件夹")) {
                if tree.rootFolders.isEmpty {
                    AndroidParityEmptyCard(title: String(localized: "还没有文件夹"), systemImage: "folder")
                } else {
                    VStack(spacing: 8) {
                        ForEach(tree.rootFolders) { folder in
                            folderRow(folder)
                        }
                    }
                }
            }
        }
    }

    private func folderRow(_ folder: VaultFolderNode) -> some View {
        Button {
            onOpenFolder(folder.id)
        } label: {
            AndroidParityCard {
                HStack(spacing: 12) {
                    AndroidParityIconTile(systemImage: "folder.fill")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AndroidParityPalette.textPrimary)
                            .lineLimit(1)
                        Text("\(tree.children(of: folder.id).count) 个子文件夹")
                            .font(.caption)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }
                    Spacer(minLength: 8)
                    Text("\(overview.entryCount(inFolder: folder.id)) 项")
                        .font(.footnote)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func summaryTile(
        title: LocalizedStringKey,
        value: Int,
        systemImage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
            Text("\(value)")
                .font(.title2.weight(.heavy))
                .foregroundStyle(AndroidParityPalette.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func countDetail(_ count: VaultFolderOverview.KindCount) -> String {
        "\(count.activeCount) · ♥ \(count.favoriteCount) · 🗑 \(count.trashedCount)"
    }
}

// MARK: - 面包屑 + 子文件夹

/// 顶部导航：面包屑、上一级、子文件夹入口以及文件夹管理动作。
struct VaultFolderNavigator: View {
    @Bindable var session: AppSessionModel

    @State private var isCreatePresented = false
    @State private var isRenamePresented = false
    @State private var isDeletePresented = false
    @State private var isDeleteConfirmed = false
    @State private var pendingDeletePlan: VaultFolderDeletionPlan?
    @State private var pendingDeleteStrategy: VaultFolderDeleteStrategy = .reparent
    @State private var pendingTitle = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            breadcrumbBar
            childrenSection
            if session.isVaultOverviewPresented {
                VaultOverviewPanel(
                    overview: session.vaultFolderOverview,
                    tree: session.vaultFolderTree,
                    onOpenFolder: { folderID in
                        do {
                            try session.openVaultFolder(folderID)
                            session.dismissVaultOverview()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                )
            }
        }
        .alert("新建文件夹", isPresented: $isCreatePresented) {
            TextField("文件夹名称", text: $pendingTitle)
            Button("取消", role: .cancel) { pendingTitle = "" }
            Button("确定") { createFolder() }
        }
        .alert("重命名文件夹", isPresented: $isRenamePresented) {
            TextField("文件夹名称", text: $pendingTitle)
            Button("取消", role: .cancel) { pendingTitle = "" }
            Button("确定") { renameFolder() }
        }
        .confirmationDialog(
            "删除文件夹",
            isPresented: $isDeletePresented,
            titleVisibility: .visible
        ) {
            if pendingDeletePlan?.canReparent == true {
                Button("内容上移到上级") {
                    pendingDeleteStrategy = .reparent
                    isDeleteConfirmed = true
                }
            }
            Button("内容移入回收站", role: .destructive) {
                pendingDeleteStrategy = .recursiveTrash
                isDeleteConfirmed = true
            }
            Button("取消", role: .cancel) { pendingDeletePlan = nil }
        } message: {
            Text(deleteDialogMessage)
        }
        .alert("确认删除文件夹", isPresented: $isDeleteConfirmed) {
            Button("取消", role: .cancel) { pendingDeletePlan = nil }
            Button("删除", role: .destructive) { confirmDelete() }
        } message: {
            Text(deleteConfirmMessage)
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("确定", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: 面包屑

    private var breadcrumbBar: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.6), cornerRadius: 22) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    breadcrumbButton(title: "全部条目", isCurrent: session.activeVaultFolder == nil) {
                        navigate(to: nil)
                    }
                    ForEach(session.activeVaultFolderBreadcrumb) { node in
                        Text("/")
                            .font(.caption)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                        breadcrumbButton(
                            title: node.title,
                            isCurrent: node.id == session.activeVaultFolder?.id
                        ) {
                            navigate(to: node.id)
                        }
                    }
                }
                .frame(minHeight: 44)
            }

            HStack(spacing: 8) {
                Button {
                    navigate(to: session.activeVaultFolderBreadcrumb.dropLast().last?.id)
                } label: {
                    Image(systemName: "chevron.up")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AndroidParityPalette.primary)
                .disabled(session.activeVaultFolder == nil)
                .accessibilityLabel("上一级")

                Button {
                    pendingTitle = ""
                    isCreatePresented = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AndroidParityPalette.primary)
                .disabled(!session.canCreateVaultFolder)
                .accessibilityLabel("新建文件夹")

                Button {
                    guard let node = session.activeVaultFolder else { return }
                    pendingTitle = node.title
                    isRenamePresented = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AndroidParityPalette.primary)
                .disabled(session.activeVaultFolder == nil)
                .accessibilityLabel("重命名文件夹")

                moveMenu

                Button {
                    guard let folderID = session.activeVaultFolder?.id else { return }
                    do {
                        pendingDeletePlan = try session.vaultFolderDeletionPlan(folderID: folderID)
                        isDeletePresented = true
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                } label: {
                    Image(systemName: "folder.badge.minus")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .disabled(session.activeVaultFolder == nil)
                .accessibilityLabel("删除文件夹")

                Spacer(minLength: 0)

                Button {
                    if session.isVaultOverviewPresented {
                        session.dismissVaultOverview()
                    } else {
                        session.presentVaultOverview()
                    }
                } label: {
                    let isPresented = session.isVaultOverviewPresented
                    let title: LocalizedStringKey = isPresented ? "收起总览" : "保险箱总览"
                    Label(title, systemImage: "chart.bar.doc.horizontal")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(AndroidParityPalette.primary)
            }
        }
    }

    private var moveMenu: some View {
        Menu {
            Button("根目录") { move(to: nil) }
            ForEach(movableTargets) { folder in
                Button(folder.title) { move(to: folder.id) }
            }
        } label: {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .frame(minWidth: 44, minHeight: 44)
        }
        .disabled(session.activeVaultFolder == nil)
        .accessibilityLabel("移动到…")
    }

    /// 可移动目标：排除自身与整棵子树，避免把文件夹挂到自己的后代下。
    private var movableTargets: [VaultFolderNode] {
        guard let current = session.activeVaultFolder else { return [] }
        let blocked = Set(session.vaultFolderTree.subtree(rootedAt: current.id).map(\.id))
        return session.vaultFolderTree.folders.filter { !blocked.contains($0.id) }
    }

    // MARK: 子文件夹

    @ViewBuilder
    private var childrenSection: some View {
        let children = session.activeVaultChildFolders
        if children.isEmpty {
            if session.activeVaultFolder != nil {
                AndroidParityEmptyCard(title: String(localized: "这里还没有子文件夹"), systemImage: "folder")
            }
        } else {
            AndroidParitySection(title: String(localized: "子文件夹")) {
                VStack(spacing: 8) {
                    ForEach(children) { folder in
                        Button {
                            navigate(to: folder.id)
                        } label: {
                            AndroidParityCard {
                                HStack(spacing: 12) {
                                    AndroidParityIconTile(systemImage: "folder.fill")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(folder.title)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(AndroidParityPalette.textPrimary)
                                            .lineLimit(1)
                                        Text("\(session.vaultFolderTree.children(of: folder.id).count) 个子文件夹")
                                            .font(.caption)
                                            .foregroundStyle(AndroidParityPalette.textSecondary)
                                    }
                                    Spacer(minLength: 8)
                                    Text("\(session.vaultFolderOverview.entryCount(inFolder: folder.id)) 项")
                                        .font(.footnote)
                                        .foregroundStyle(AndroidParityPalette.textSecondary)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(AndroidParityPalette.textSecondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func breadcrumbButton(
        title: String,
        isCurrent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isCurrent ? .heavy : .semibold))
                .foregroundStyle(
                    isCurrent ? AndroidParityPalette.primary : AndroidParityPalette.textSecondary
                )
                .lineLimit(1)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
    }

    // MARK: 动作

    private func navigate(to folderID: String?) {
        do {
            try session.openVaultFolder(folderID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createFolder() {
        let title = pendingTitle
        pendingTitle = ""
        do {
            _ = try session.createVaultFolder(title: title)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func renameFolder() {
        guard let folderID = session.activeVaultFolder?.id else { return }
        let title = pendingTitle
        pendingTitle = ""
        do {
            _ = try session.renameVaultFolder(folderID: folderID, title: title)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func move(to parentID: String?) {
        guard let folderID = session.activeVaultFolder?.id else { return }
        do {
            _ = try session.moveVaultFolder(folderID: folderID, parentID: parentID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func confirmDelete() {
        guard let folderID = session.activeVaultFolder?.id else { return }
        let strategy = pendingDeleteStrategy
        pendingDeletePlan = nil
        do {
            _ = try session.deleteVaultFolder(folderID: folderID, strategy: strategy)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var deleteDialogMessage: String {
        guard let plan = pendingDeletePlan else { return "" }
        return String(
            format: String(localized: "将删除 %lld 个文件夹、%lld 条条目。"),
            plan.descendantFolderCount + 1,
            plan.liveEntryCount
        )
    }

    private var deleteConfirmMessage: String {
        guard let plan = pendingDeletePlan else { return "" }
        switch pendingDeleteStrategy {
        case .reparent:
            return String(
                format: String(localized: "「%@」里的条目会移动到上一级文件夹，不会被删除。"),
                plan.title
            )
        case .recursiveTrash:
            return String(
                format: String(localized: "「%@」里的 %lld 条条目会进入回收站，可以再恢复。"),
                plan.title,
                plan.liveEntryCount
            )
        }
    }
}
