import MonicaStorage
import SwiftUI

/// 跨类型全局搜索界面。
///
/// 以导航 push 的方式从密码 / 首页入口进入（不新增底部 Tab），结果复用现有的
/// `VaultItemDetailView` 详情页路由。索引只存在于解锁会话内存中，锁库后本界面
/// 会被自动关闭，搜索结果为 0。
struct AppGlobalSearchView: View {
    @Bindable var session: AppSessionModel

    @State private var query = ""
    @State private var selectedKinds: Set<UnifiedVaultItemKind> = []
    @State private var selectedProjectID: String?
    @State private var selectedTags: Set<String> = []
    @State private var favoritesOnly = false
    @State private var includeDeleted = false
    @State private var sort: VaultSearchSort = .relevance
    @State private var results = VaultSearchResults.empty
    @State private var isSearching = false
    @State private var errorMessage: String?
    @FocusState private var isSearchFieldFocused: Bool

    private static let resultLimit = 60
    private static let debounceMilliseconds = 150

    var body: some View {
        AndroidParityScreen {
            searchField
            filterBar
            searchContent
        }
        .navigationTitle("全局搜索")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task {
            session.ensureVaultSearchIndex()
        }
        .task(id: searchSignature) {
            await debouncedSearch()
        }
        .onAppear {
            guard session.vaultState == .unlocked else {
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                isSearchFieldFocused = true
            }
        }
        .onDisappear {
            session.dismissDetail()
        }
        .sheet(isPresented: presentedDetailBinding) {
            if let route = session.presentedDetailRoute {
                VaultItemDetailView(session: session, route: route)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - 搜索框与筛选

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.headline.weight(.heavy))
                .foregroundStyle(AndroidParityPalette.primary)

            TextField("搜索标题、账号、网址、备注", text: $query)
                .focused($isSearchFieldFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .foregroundStyle(AndroidParityPalette.textPrimary)
                .font(.body.weight(.semibold))
                .accessibilityIdentifier("global-search-field")

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            AndroidParityPalette.surfaceVariant.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .disabled(session.vaultState != .unlocked)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                kindFilterMenu
                vaultFilterMenu
                if !availableTags.isEmpty {
                    tagFilterMenu
                }
                Button {
                    favoritesOnly.toggle()
                } label: {
                    filterChip(
                        "仅收藏",
                        systemImage: "star.fill",
                        isActive: favoritesOnly
                    )
                }
                .buttonStyle(.plain)
                Button {
                    includeDeleted.toggle()
                } label: {
                    filterChip(
                        "含已删除",
                        systemImage: "trash",
                        isActive: includeDeleted
                    )
                }
                .buttonStyle(.plain)
                sortFilterMenu
            }
            .padding(.vertical, 2)
        }
        .disabled(session.vaultState != .unlocked)
    }

    private var kindFilterMenu: some View {
        Menu {
            Button {
                selectedKinds.removeAll()
            } label: {
                Label("全部类型", systemImage: selectedKinds.isEmpty ? "checkmark" : "square.grid.2x2")
            }
            Divider()
            ForEach(UnifiedVaultItemKind.fullAndroidParityKinds, id: \.self) { kind in
                Button {
                    if selectedKinds.contains(kind) {
                        selectedKinds.remove(kind)
                    } else {
                        selectedKinds.insert(kind)
                    }
                } label: {
                    Label(kind.localizedDisplayName, systemImage: selectedKinds.contains(kind) ? "checkmark" : "square")
                }
            }
        } label: {
            filterChip(kindFilterTitle, systemImage: "square.grid.2x2", isActive: !selectedKinds.isEmpty)
        }
    }

    private var vaultFilterMenu: some View {
        Menu {
            Button {
                selectedProjectID = nil
            } label: {
                Label("全部保险箱", systemImage: selectedProjectID == nil ? "checkmark" : "tray.full")
            }
            Divider()
            ForEach(session.vaultProjects) { project in
                Button {
                    selectedProjectID = project.id
                } label: {
                    Label(project.title, systemImage: selectedProjectID == project.id ? "checkmark" : "tray")
                }
            }
        } label: {
            filterChip(vaultFilterTitle, systemImage: "tray.full", isActive: selectedProjectID != nil)
        }
    }

    private var tagFilterMenu: some View {
        Menu {
            Button {
                selectedTags.removeAll()
            } label: {
                Label("全部标签", systemImage: selectedTags.isEmpty ? "checkmark" : "tag")
            }
            Divider()
            ForEach(availableTags, id: \.self) { tag in
                Button {
                    if selectedTags.contains(tag) {
                        selectedTags.remove(tag)
                    } else {
                        selectedTags.insert(tag)
                    }
                } label: {
                    Label(tag, systemImage: selectedTags.contains(tag) ? "checkmark" : "tag")
                }
            }
        } label: {
            filterChip(tagFilterTitle, systemImage: "tag", isActive: !selectedTags.isEmpty)
        }
    }

    private var sortFilterMenu: some View {
        Menu {
            ForEach(VaultSearchSort.allCases, id: \.self) { option in
                Button {
                    sort = option
                } label: {
                    Label(
                        option == .relevance ? "按相关度排序" : "按最近使用排序",
                        systemImage: sort == option ? "checkmark" : "arrow.up.arrow.down"
                    )
                }
            }
        } label: {
            filterChip(
                sort == .relevance ? "按相关度排序" : "按最近使用排序",
                systemImage: "arrow.up.arrow.down",
                isActive: sort != .relevance
            )
        }
    }

    private func filterChip(
        _ title: String,
        systemImage: String,
        isActive: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
            Text(title)
                .font(.caption.weight(.heavy))
                .lineLimit(1)
        }
        .foregroundStyle(isActive ? AndroidParityPalette.textPrimary : AndroidParityPalette.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            isActive ? AndroidParityPalette.primaryDeep : AndroidParityPalette.surfaceVariant.opacity(0.56),
            in: Capsule(style: .continuous)
        )
    }

    // MARK: - 结果

    @ViewBuilder
    private var searchContent: some View {
        if session.vaultState != .unlocked {
            notice(String(localized: "保险库已锁定，搜索已清空"))
        } else if normalizedQuery.isEmpty {
            if results.recent.isEmpty && frequentResults.isEmpty {
                notice(String(localized: "输入关键词搜索全部类型条目"))
            } else {
                if !results.recent.isEmpty {
                    resultSection(title: String(localized: "最近访问"), rows: results.recent)
                }
                if !frequentResults.isEmpty {
                    resultSection(title: String(localized: "常用"), rows: frequentResults)
                }
            }
        } else if results.results.isEmpty {
            if isSearching {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("搜索中…")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
                .padding(.vertical, 12)
            } else {
                notice(String(localized: "无匹配结果"))
            }
        } else {
            resultSection(title: String(localized: "搜索结果"), rows: results.results)
            if results.truncated {
                Text("仅显示前 60 条，请补充关键词")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .padding(.horizontal, 4)
            }
        }

        if let errorMessage {
            Text(errorMessage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 4)
        }
    }

    private func resultSection(title: String, rows: [VaultSearchResult]) -> some View {
        AndroidParitySection(title: title) {
            ForEach(rows, id: \.stableIdentifier) { result in
                resultRow(result)
            }
        }
    }

    private func resultRow(_ result: VaultSearchResult) -> some View {
        Button {
            open(result)
        } label: {
            HStack(spacing: 12) {
                AndroidParityIconTile(systemImage: result.kind.searchSystemImage)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(result.title)
                            .font(.subheadline.weight(.heavy))
                            .foregroundStyle(AndroidParityPalette.textPrimary)
                            .lineLimit(1)
                        if result.isFavorite {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(AndroidParityPalette.primary)
                        }
                    }

                    if !result.subtitle.isEmpty {
                        Text(result.subtitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                            .lineLimit(1)
                    }

                    if let match = matchedFieldBadge(for: result) {
                        HStack(spacing: 6) {
                            Text(match.field.localizedTitle)
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(AndroidParityPalette.primary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    AndroidParityPalette.secondaryContainer,
                                    in: Capsule(style: .continuous)
                                )
                            Text(match.snippet)
                                .font(.caption2)
                                .foregroundStyle(AndroidParityPalette.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 8)

                Text(result.kind.localizedDisplayName)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                AndroidParityPalette.surface,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("global-search-result-\(result.kind.rawValue)-\(result.id)")
    }

    private func notice(_ text: String) -> some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.56), cornerRadius: 18) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AndroidParityPalette.primary)
                Text(text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 跳转

    private func open(_ result: VaultSearchResult) {
        do {
            if session.activeVaultProjectID != result.projectID {
                // 详情页读取的是“当前分类”的条目数组；先切到条目所属分类，
                // 再复用现有详情路由，避免跨分类详情为空。
                try session.switchVaultCategory(projectID: result.projectID)
            }
            session.presentDetail(kind: result.kind, entryID: result.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 查询

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentFilters: VaultSearchFilters {
        VaultSearchFilters(
            kinds: selectedKinds,
            projectIDs: selectedProjectID.map { [$0] } ?? [],
            tags: selectedTags,
            favoritesOnly: favoritesOnly,
            includeDeleted: includeDeleted,
            sort: sort
        )
    }

    private var availableTags: [String] {
        session.vaultSearch.availableTags
    }

    private var frequentResults: [VaultSearchResult] {
        let recentKeys = Set(results.recent.map(\.itemKey))
        return results.frequent.filter { !recentKeys.contains($0.itemKey) }
    }

    private var kindFilterTitle: String {
        switch selectedKinds.count {
        case 0:
            return String(localized: "全部类型")
        case 1:
            return selectedKinds.first?.localizedDisplayName ?? String(localized: "全部类型")
        default:
            return "\(String(localized: "类型")) · \(selectedKinds.count)"
        }
    }

    private var vaultFilterTitle: String {
        guard let selectedProjectID,
              let project = session.vaultProjects.first(where: { $0.id == selectedProjectID })
        else {
            return String(localized: "全部保险箱")
        }
        return project.title
    }

    private var tagFilterTitle: String {
        guard !selectedTags.isEmpty else {
            return String(localized: "全部标签")
        }
        if selectedTags.count == 1, let tag = selectedTags.first {
            return tag
        }
        return "\(String(localized: "标签")) · \(selectedTags.count)"
    }

    private func matchedFieldBadge(for result: VaultSearchResult) -> VaultSearchMatch? {
        result.matches.first(where: { $0.field != .title })
    }

    /// `.task(id:)` 的 id：任一输入变化都会取消上一次查询任务。
    private var searchSignature: SearchSignature {
        SearchSignature(
            query: normalizedQuery,
            kinds: selectedKinds,
            projectID: selectedProjectID,
            tags: selectedTags,
            favoritesOnly: favoritesOnly,
            includeDeleted: includeDeleted,
            sort: sort,
            revision: session.vaultSearchRevision
        )
    }

    private func debouncedSearch() async {
        if !normalizedQuery.isEmpty {
            do {
                try await Task.sleep(for: .milliseconds(Self.debounceMilliseconds))
            } catch {
                return
            }
        }
        guard !Task.isCancelled else {
            return
        }
        await performSearch()
    }

    private func performSearch() async {
        let generation = session.vaultSearch.nextSearchGeneration()
        isSearching = true

        do {
            let outcome = try await session.vaultSearch.search(
                normalizedQuery,
                filters: currentFilters,
                limit: Self.resultLimit,
                generation: generation
            )
            guard !Task.isCancelled else {
                return
            }
            results = outcome
            errorMessage = nil
            if generation == session.vaultSearch.currentGeneration {
                isSearching = false
            }
        } catch is CancellationError {
            // 输入变化导致的取消：保留上一次结果，等新查询覆盖。
        } catch VaultSearchError.superseded {
            // 索引已重建或已锁库：旧结果直接丢弃，避免覆盖新结果。
        } catch {
            guard !Task.isCancelled else {
                return
            }
            errorMessage = error.localizedDescription
            if generation == session.vaultSearch.currentGeneration {
                isSearching = false
            }
        }
    }

    private var presentedDetailBinding: Binding<Bool> {
        Binding(
            get: { session.presentedDetailRoute != nil && session.isGlobalSearchPresented },
            set: { isPresented in
                if !isPresented {
                    session.dismissDetail()
                }
            }
        )
    }

    private struct SearchSignature: Hashable {
        let query: String
        let kinds: Set<UnifiedVaultItemKind>
        let projectID: String?
        let tags: Set<String>
        let favoritesOnly: Bool
        let includeDeleted: Bool
        let sort: VaultSearchSort
        let revision: Int
    }
}

private extension UnifiedVaultItemKind {
    var searchSystemImage: String {
        switch self {
        case .login: return "key.fill"
        case .totp: return "clock.badge.checkmark"
        case .note: return "note.text"
        case .card: return "creditcard.fill"
        case .identity: return "person.text.rectangle"
        case .passkey: return "person.badge.key.fill"
        case .sshKey: return "terminal"
        case .apiToken: return "curlybraces"
        case .wifi: return "wifi"
        case .sso: return "person.crop.circle.badge.checkmark"
        case .barcode: return "barcode.viewfinder"
        case .gpgKey: return "key.horizontal.fill"
        case .send: return "paperplane.fill"
        case .steam: return "shield.lefthalf.filled"
        case .attachmentRef: return "paperclip"
        case .billingAddress: return "house.fill"
        case .paymentAccount: return "wallet.pass.fill"
        }
    }
}

private extension VaultSearchMatchField {
    var localizedTitle: String {
        switch self {
        case .title: return String(localized: "标题")
        case .username: return String(localized: "账号")
        case .url: return String(localized: "网址")
        case .tags: return String(localized: "标签")
        case .details: return String(localized: "其他信息")
        case .notes: return String(localized: "备注")
        }
    }
}
