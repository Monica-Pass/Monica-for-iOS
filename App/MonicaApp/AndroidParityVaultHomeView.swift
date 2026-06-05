import MonicaStorage
import Observation
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AndroidParityVaultHomeView: View {
    @Bindable var session: AppSessionModel
    let tab: MonicaAppTab
    let moduleTitle: String
    let itemKind: UnifiedVaultItemKind
    let storageStrategy: String
    let mdbxBridge: String
    let createVault: () -> Void
    let openVault: (URL) -> Void
    let lockVault: () -> Void
    let createLoginEntry: () -> Void
    let generateLoginPassword: () -> Void
    let updateLoginEntry: () -> Void
    let generateSelectedLoginPassword: () -> Void
    let setSelectedLoginFavorite: (Bool) -> Void
    let deleteLoginEntry: () -> Void
    let restoreLoginEntry: (LocalLoginEntry) -> Void
    let createNoteEntry: () -> Void
    let updateNoteEntry: () -> Void
    let setSelectedNoteFavorite: (Bool) -> Void
    let deleteNoteEntry: () -> Void
    let restoreNoteEntry: (LocalNoteEntry) -> Void
    let createTotpEntry: () -> Void
    let importTotpURI: () -> Void
    let scanTotpQRCode: (String) -> Bool
    let updateTotpEntry: () -> Void
    let setSelectedTotpFavorite: (Bool) -> Void
    let deleteTotpEntry: () -> Void
    let restoreTotpEntry: (LocalTotpEntry) -> Void
    let createCardEntry: () -> Void
    let updateCardEntry: () -> Void
    let setSelectedCardFavorite: (Bool) -> Void
    let deleteCardEntry: () -> Void
    let restoreCardEntry: (LocalCardEntry) -> Void
    let createIdentityEntry: () -> Void
    let updateIdentityEntry: () -> Void
    let setSelectedIdentityFavorite: (Bool) -> Void
    let deleteIdentityEntry: () -> Void
    let restoreIdentityEntry: (LocalIdentityEntry) -> Void
    let createPasskeyEntry: () -> Void
    let updatePasskeyEntry: () -> Void
    let setSelectedPasskeyFavorite: (Bool) -> Void
    let deletePasskeyEntry: () -> Void
    let restorePasskeyEntry: (LocalPasskeyEntry) -> Void
    let setSelectedSshKeyFavorite: (Bool) -> Void
    let deleteSshKeyEntry: () -> Void
    let restoreSshKeyEntry: (LocalSshKeyEntry) -> Void
    let setSelectedApiTokenFavorite: (Bool) -> Void
    let deleteApiTokenEntry: () -> Void
    let restoreApiTokenEntry: (LocalApiTokenEntry) -> Void
    let setSelectedWifiFavorite: (Bool) -> Void
    let deleteWifiEntry: () -> Void
    let restoreWifiEntry: (LocalWifiEntry) -> Void
    let setSelectedSendFavorite: (Bool) -> Void
    let deleteSendEntry: () -> Void
    let restoreSendEntry: (LocalSendEntry) -> Void
    let deleteAttachmentEntry: (LocalAttachmentMetadata) -> Void
    let restoreAttachmentEntry: (LocalAttachmentMetadata) -> Void
    let refreshExtendedParityEntries: () -> Void

    @State private var isVaultImporterPresented = false
    @State private var isTotpScannerPresented = false
    @State private var isCreateCategoryAlertPresented = false
    @State private var isRenameCategoryAlertPresented = false
    @State private var pendingCategoryTitle = ""
    @State private var now = Date()

    private let vaultFileType = UTType(filenameExtension: "mdbx") ?? .data
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        AndroidParityModuleChrome(
            title: largeTitle,
            tab: tab,
            selectedAction: $session.expandedToolbarAction,
            searchText: searchBinding,
            favoritesOnly: favoritesBinding,
            stackedGroupMode: $session.isLoginStackedGroupModeEnabled,
            showsStackedGroupModeToggle: itemKind == .login,
            quickFilterRows: session.vaultQuickFilterRows,
            categoryBar: { categoryBar },
            onQuickFilter: session.applyVaultQuickFilter,
            onOpenVault: { isVaultImporterPresented = true },
            onAdd: { session.presentAddEditor(for: tab) },
            batchBar: { batchActionBar }
        ) {
            if session.vaultState == .unlocked {
                unlockedContent
            } else {
                lockedSummary
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .fileImporter(
            isPresented: $isVaultImporterPresented,
            allowedContentTypes: [vaultFileType],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let fileURL = urls.first else {
                return
            }
            openVault(fileURL)
        }
        .sheet(isPresented: presentedEditorBinding) {
            if let mode = session.presentedEditorMode {
                AddEditVaultItemView(
                    session: session,
                    mode: mode,
                    activeVaultName: session.activeVaultName ?? "Monica",
                    generateLoginPassword: generateLoginPassword,
                    generateSelectedLoginPassword: generateSelectedLoginPassword,
                    importTotpURI: importTotpURI,
                    scanTotpQRCode: scanTotpQRCode,
                    setFavorite: setFavorite,
                    deleteEntry: deletePresentedEntry,
                    save: savePresentedEditor,
                    dismiss: session.dismissPresentedEditor
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $isTotpScannerPresented) {
            TotpQRCodeScannerSheet(
                session: session,
                onCode: { payload in
                    if scanTotpQRCode(payload) {
                        isTotpScannerPresented = false
                        return true
                    }
                    return false
                },
                onCancel: { isTotpScannerPresented = false }
            )
        }
        .quickLookPreview(attachmentQuickLookPreviewBinding)
        .onReceive(timer) { value in
            now = value
        }
        .alert("新建分类", isPresented: $isCreateCategoryAlertPresented) {
            TextField("分类名称", text: $pendingCategoryTitle)
            Button("取消", role: .cancel) { pendingCategoryTitle = "" }
            Button("创建") {
                do { try session.createVaultCategory(title: pendingCategoryTitle) } catch {}
                pendingCategoryTitle = ""
            }
        }
        .alert("重命名分类", isPresented: $isRenameCategoryAlertPresented) {
            TextField("分类名称", text: $pendingCategoryTitle)
            Button("取消", role: .cancel) { pendingCategoryTitle = "" }
            Button("保存") {
                if let projectID = session.activeVaultProjectID {
                    do { try session.renameVaultCategory(projectID: projectID, title: pendingCategoryTitle) } catch {}
                }
                pendingCategoryTitle = ""
            }
        }
    }

    @ViewBuilder
    private var unlockedContent: some View {
        switch itemKind {
        case .login:
            passwordList
        case .totp:
            totpList
        case .note:
            noteList
        case .card:
            walletList
        case .passkey:
            passkeyList
        case .identity:
            identityList
        case .sshKey:
            sshKeyList
        case .apiToken:
            apiTokenList
        case .wifi:
            wifiList
        case .send:
            sendList
        case .attachmentRef:
            attachmentList
        }
    }

    private var lockedSummary: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.7), cornerRadius: 24) {
            HStack(spacing: 16) {
                AndroidParityIconTile(systemImage: "lock.shield.fill", fill: AndroidParityPalette.primaryContainer)
                VStack(alignment: .leading, spacing: 4) {
                    Text("保险库已锁定")
                        .font(.subheadline.weight(.semibold))
                    Text("返回锁屏输入主密码，或使用生物识别认证。")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
            }
        }
    }

    private var passwordList: some View {
        VStack(spacing: 14) {
            if session.isLoginStackedGroupModeEnabled {
                ForEach(session.loginStackedGroups) { group in
                    Button { session.loginSearchQuery = group.title } label: {
                        AndroidPasswordStackedGroupCard(
                            group: group,
                            appearancePreferences: session.appearancePreferences
                        )
                    }
                    .buttonStyle(.plain)
                }
                if session.loginStackedGroups.isEmpty {
                    emptyList("没有匹配的分组", icon: "square.stack.3d.up.fill")
                }
            } else {
                ForEach(session.filteredLoginEntries) { entry in
                    batchAwareButton(id: entry.id, kind: .login, edit: { session.presentEditEditor(for: entry) }) {
                        batchSelectableCard(id: entry.id) {
                            AndroidPasswordListCard(
                                entry: entry,
                                displayPreferences: session.vaultDisplayPreferences,
                                appearancePreferences: session.appearancePreferences
                            )
                        }
                    }
                }
                if session.filteredLoginEntries.isEmpty {
                    emptyList("没有匹配的密码", icon: "lock.fill")
                }
            }
            deletedLoginRows
        }
    }

    private var totpList: some View {
        VStack(spacing: 14) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.52), cornerRadius: 22) {
                HStack(spacing: 12) {
                    SecureField("粘贴 otpauth:// URI", text: $session.totpImportURI)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(AndroidParityTextFieldStyle())
                    Button { isTotpScannerPresented = true } label: {
                        Image(systemName: "camera.viewfinder")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 46, height: 46)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AndroidParityPalette.primary)
                }
                Button(action: importTotpURI) {
                    Label("导入验证器", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
            }
            ForEach(session.filteredTotpEntries) { entry in
                batchAwareButton(id: entry.id, kind: .totp, edit: { session.presentEditEditor(for: entry) }) {
                    batchSelectableCard(id: entry.id) {
                        AndroidTotpListCard(entry: entry, code: totpCode(for: entry), remaining: session.totpTimeRemaining(for: entry, at: now))
                    }
                }
            }
            if session.filteredTotpEntries.isEmpty {
                emptyList("没有匹配的验证码", icon: "shield.lefthalf.filled")
            }
            deletedTotpRows
        }
    }

    private var walletList: some View {
        VStack(spacing: 16) {
            ForEach(session.filteredCardEntries) { entry in
                batchAwareButton(id: entry.id, kind: .card, edit: { session.presentEditEditor(for: entry) }) {
                    batchSelectableCard(id: entry.id) {
                        AndroidBankCardListCard(entry: entry)
                    }
                }
            }
            ForEach(session.filteredIdentityEntries) { entry in
                batchAwareButton(id: entry.id, kind: .identity, edit: { session.presentEditEditor(for: entry) }) {
                    batchSelectableCard(id: entry.id) {
                        AndroidIdentityListCard(entry: entry)
                    }
                }
            }
            if session.filteredCardEntries.isEmpty && session.filteredIdentityEntries.isEmpty {
                emptyList("没有匹配的卡片或证件", icon: "creditcard")
            }
            deletedCardRows
            deletedIdentityRows
        }
    }

    private var noteList: some View {
        VStack(spacing: 14) {
            ForEach(session.filteredNoteEntries) { entry in
                batchAwareButton(id: entry.id, kind: .note, edit: { session.presentEditEditor(for: entry) }) {
                    batchSelectableCard(id: entry.id) {
                        AndroidNoteListCard(entry: entry)
                    }
                }
            }
            if session.filteredNoteEntries.isEmpty {
                emptyList("没有匹配的笔记", icon: "note.text")
            }
            deletedNoteRows
        }
    }

    private var passkeyList: some View {
        VStack(spacing: 14) {
            ForEach(session.filteredPasskeyEntries) { entry in
                batchAwareButton(id: entry.id, kind: .passkey, edit: { session.presentEditEditor(for: entry) }) {
                    batchSelectableCard(id: entry.id) {
                        AndroidPasskeyListCard(entry: entry)
                    }
                }
            }
            if session.filteredPasskeyEntries.isEmpty {
                emptyList("没有匹配的通行密钥", icon: "key.horizontal.fill")
            }
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.52), cornerRadius: 22) {
                AndroidParityInfoRow(title: "SSH 密钥", value: "\(session.sshKeyEntries.count) 条")
                AndroidParityInfoRow(title: "API Token", value: "\(session.apiTokenEntries.count) 条")
                AndroidParityInfoRow(title: "Wi-Fi", value: "\(session.wifiEntries.count) 条")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], spacing: 10) {
                    extendedAddButton(.sshKey)
                    extendedAddButton(.apiToken)
                    extendedAddButton(.wifi)
                    extendedAddButton(.send)
                }
                Button(action: refreshExtendedParityEntries) {
                    Label("刷新扩展条目", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
            }
            extendedPasskeySections
            deletedPasskeyRows
        }
    }

    private var sshKeyList: some View {
        VStack(spacing: 14) {
            ForEach(session.filteredSshKeyEntries) { entry in
                batchAwareButton(id: entry.id, kind: .sshKey, edit: { session.presentEditEditor(for: entry) }) {
                    batchSelectableCard(id: entry.id) {
                        AndroidSshKeyListCard(entry: entry)
                    }
                }
            }
            if session.filteredSshKeyEntries.isEmpty {
                emptyList("没有匹配的 SSH 密钥", icon: "key.fill")
            }
            deletedSshKeyRows
        }
    }

    private var apiTokenList: some View {
        VStack(spacing: 14) {
            ForEach(session.filteredApiTokenEntries) { entry in
                batchAwareButton(id: entry.id, kind: .apiToken, edit: { session.presentEditEditor(for: entry) }) {
                    batchSelectableCard(id: entry.id) {
                        AndroidApiTokenListCard(entry: entry)
                    }
                }
            }
            if session.filteredApiTokenEntries.isEmpty {
                emptyList("没有匹配的 API Token", icon: "text.badge.key")
            }
            deletedApiTokenRows
        }
    }

    private var wifiList: some View {
        VStack(spacing: 14) {
            ForEach(session.filteredWifiEntries) { entry in
                batchAwareButton(id: entry.id, kind: .wifi, edit: { session.presentEditEditor(for: entry) }) {
                    batchSelectableCard(id: entry.id) {
                        AndroidWifiListCard(entry: entry)
                    }
                }
            }
            if session.filteredWifiEntries.isEmpty {
                emptyList("没有匹配的 Wi-Fi", icon: "wifi")
            }
            deletedWifiRows
        }
    }

    private var sendList: some View {
        VStack(spacing: 14) {
            ForEach(session.filteredSendEntries) { entry in
                batchAwareButton(id: entry.id, kind: .send, edit: { session.presentEditEditor(for: entry) }) {
                    batchSelectableCard(id: entry.id) {
                        AndroidSendListCard(entry: entry)
                    }
                }
            }
            if session.filteredSendEntries.isEmpty {
                emptyList("没有匹配的 Send", icon: "paperplane.fill")
            }
            deletedSendRows
        }
    }

    private var attachmentList: some View {
        VStack(spacing: 14) {
            ForEach(session.filteredAttachmentEntries) { entry in
                if session.isVaultBatchSelectionActive {
                    Button { session.toggleVaultBatchItemSelection(entry.id, for: .attachmentRef) } label: {
                        batchSelectableCard(id: entry.id) {
                            AndroidAttachmentListCard(entry: entry, showsActions: false, download: nil, preview: {}) {}
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    AndroidAttachmentListCard(entry: entry, download: {
                        Task {
                            do {
                                _ = try await session.downloadBitwardenAttachmentContent(entry)
                            } catch {
                                // AppSessionModel owns user-visible failure state.
                            }
                        }
                    }, preview: {
                        do {
                            try session.presentAttachmentQuickLookPreview(entry)
                        } catch {
                            // AppSessionModel owns user-visible failure state.
                        }
                    }, delete: {
                        deleteAttachmentEntry(entry)
                    })
                }
            }
            if session.filteredAttachmentEntries.isEmpty {
                emptyList("没有匹配的附件引用", icon: "paperclip")
            }
            deletedAttachmentRows
        }
    }

    private var extendedPasskeySections: some View {
        VStack(spacing: 14) {
            ForEach(session.filteredSshKeyEntries) { entry in
                batchAwareButton(id: entry.id, kind: .sshKey, edit: { session.presentEditEditor(for: entry) }) {
                    batchSelectableCard(id: entry.id) { AndroidSshKeyListCard(entry: entry) }
                }
            }
            ForEach(session.filteredApiTokenEntries) { entry in
                batchAwareButton(id: entry.id, kind: .apiToken, edit: { session.presentEditEditor(for: entry) }) {
                    batchSelectableCard(id: entry.id) { AndroidApiTokenListCard(entry: entry) }
                }
            }
            ForEach(session.filteredWifiEntries) { entry in
                batchAwareButton(id: entry.id, kind: .wifi, edit: { session.presentEditEditor(for: entry) }) {
                    batchSelectableCard(id: entry.id) { AndroidWifiListCard(entry: entry) }
                }
            }
            ForEach(session.filteredSendEntries) { entry in
                batchAwareButton(id: entry.id, kind: .send, edit: { session.presentEditEditor(for: entry) }) {
                    batchSelectableCard(id: entry.id) { AndroidSendListCard(entry: entry) }
                }
            }
            deletedSshKeyRows
            deletedApiTokenRows
            deletedWifiRows
            deletedSendRows
        }
    }

    private var identityList: some View {
        VStack(spacing: 14) {
            ForEach(session.filteredIdentityEntries) { entry in
                batchAwareButton(id: entry.id, kind: .identity, edit: { session.presentEditEditor(for: entry) }) {
                    batchSelectableCard(id: entry.id) {
                        AndroidIdentityListCard(entry: entry)
                    }
                }
            }
            if session.filteredIdentityEntries.isEmpty {
                emptyList("没有匹配的证件", icon: "person.text.rectangle")
            }
            deletedIdentityRows
        }
    }

    @ViewBuilder private var deletedLoginRows: some View {
        if !session.deletedLoginEntries.isEmpty {
            restoreSection("最近删除") {
                ForEach(session.deletedLoginEntries) { entry in
                    restoreButton(id: entry.id, kind: .login, title: entry.title, subtitle: entry.username) {
                        restoreLoginEntry(entry)
                    }
                }
            }
        }
    }

    @ViewBuilder private var deletedNoteRows: some View {
        if !session.deletedNoteEntries.isEmpty {
            restoreSection("已删除笔记") {
                ForEach(session.deletedNoteEntries) { entry in
                    restoreButton(id: entry.id, kind: .note, title: entry.title, subtitle: entry.body) {
                        restoreNoteEntry(entry)
                    }
                }
            }
        }
    }

    @ViewBuilder private var deletedTotpRows: some View {
        if !session.deletedTotpEntries.isEmpty {
            restoreSection("已删除验证器") {
                ForEach(session.deletedTotpEntries) { entry in
                    restoreButton(id: entry.id, kind: .totp, title: entry.title, subtitle: entry.issuer) {
                        restoreTotpEntry(entry)
                    }
                }
            }
        }
    }

    @ViewBuilder private var deletedCardRows: some View {
        if !session.deletedCardEntries.isEmpty {
            restoreSection("已删除银行卡") {
                ForEach(session.deletedCardEntries) { entry in
                    restoreButton(id: entry.id, kind: .card, title: entry.title, subtitle: cardSummary(for: entry)) {
                        restoreCardEntry(entry)
                    }
                }
            }
        }
    }

    @ViewBuilder private var deletedIdentityRows: some View {
        if !session.deletedIdentityEntries.isEmpty {
            restoreSection("已删除证件") {
                ForEach(session.deletedIdentityEntries) { entry in
                    restoreButton(id: entry.id, kind: .identity, title: entry.title, subtitle: identitySummary(for: entry)) {
                        restoreIdentityEntry(entry)
                    }
                }
            }
        }
    }

    @ViewBuilder private var deletedPasskeyRows: some View {
        if !session.deletedPasskeyEntries.isEmpty {
            restoreSection("已删除通行密钥") {
                ForEach(session.deletedPasskeyEntries) { entry in
                    restoreButton(id: entry.id, kind: .passkey, title: entry.title, subtitle: entry.relyingPartyID) {
                        restorePasskeyEntry(entry)
                    }
                }
            }
        }
    }

    @ViewBuilder private var deletedSshKeyRows: some View {
        if !session.deletedSshKeyEntries.isEmpty {
            restoreSection("已删除 SSH 密钥") {
                ForEach(session.deletedSshKeyEntries) { entry in
                    restoreButton(id: entry.id, kind: .sshKey, title: entry.title, subtitle: entry.host) {
                        restoreSshKeyEntry(entry)
                    }
                }
            }
        }
    }

    @ViewBuilder private var deletedApiTokenRows: some View {
        if !session.deletedApiTokenEntries.isEmpty {
            restoreSection("已删除 API Token") {
                ForEach(session.deletedApiTokenEntries) { entry in
                    restoreButton(id: entry.id, kind: .apiToken, title: entry.title, subtitle: entry.issuer) {
                        restoreApiTokenEntry(entry)
                    }
                }
            }
        }
    }

    @ViewBuilder private var deletedWifiRows: some View {
        if !session.deletedWifiEntries.isEmpty {
            restoreSection("已删除 Wi-Fi") {
                ForEach(session.deletedWifiEntries) { entry in
                    restoreButton(id: entry.id, kind: .wifi, title: entry.title, subtitle: entry.ssid) {
                        restoreWifiEntry(entry)
                    }
                }
            }
        }
    }

    @ViewBuilder private var deletedSendRows: some View {
        if !session.deletedSendEntries.isEmpty {
            restoreSection("已删除 Send") {
                ForEach(session.deletedSendEntries) { entry in
                    restoreButton(id: entry.id, kind: .send, title: entry.title, subtitle: entry.expiresAt) {
                        restoreSendEntry(entry)
                    }
                }
            }
        }
    }

    @ViewBuilder private var deletedAttachmentRows: some View {
        if !session.deletedAttachmentEntries.isEmpty {
            restoreSection("已删除附件引用") {
                ForEach(session.deletedAttachmentEntries) { entry in
                    restoreButton(id: entry.id, kind: .attachmentRef, title: entry.fileName, subtitle: attachmentSubtitle(for: entry)) {
                        restoreAttachmentEntry(entry)
                    }
                }
            }
        }
    }

    private var largeTitle: String {
        itemKind == .passkey ? "通行密钥" : (session.activeVaultName ?? "Monica")
    }

    private var presentedEditorBinding: Binding<Bool> {
        Binding(
            get: { session.presentedEditorMode != nil },
            set: { isPresented in
                if !isPresented { session.dismissPresentedEditor() }
            }
        )
    }

    private var attachmentQuickLookPreviewBinding: Binding<URL?> {
        Binding(
            get: { session.attachmentQuickLookPreviewURL },
            set: { newValue in
                if newValue == nil {
                    session.dismissAttachmentQuickLookPreview()
                } else {
                    session.attachmentQuickLookPreviewURL = newValue
                }
            }
        )
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: {
                switch itemKind {
                case .login: return session.loginSearchQuery
                case .note: return session.noteSearchQuery
                case .totp: return session.totpSearchQuery
                case .card: return session.cardSearchQuery
                case .identity: return session.identitySearchQuery
                case .passkey: return session.passkeySearchQuery
                case .sshKey: return session.sshKeySearchQuery
                case .apiToken: return session.apiTokenSearchQuery
                case .wifi: return session.wifiSearchQuery
                case .send: return session.sendSearchQuery
                case .attachmentRef: return session.attachmentSearchQuery
                }
            },
            set: { value in
                switch itemKind {
                case .login: session.loginSearchQuery = value
                case .note: session.noteSearchQuery = value
                case .totp: session.totpSearchQuery = value
                case .card:
                    session.cardSearchQuery = value
                    session.identitySearchQuery = value
                case .identity: session.identitySearchQuery = value
                case .passkey: session.passkeySearchQuery = value
                case .sshKey: session.sshKeySearchQuery = value
                case .apiToken: session.apiTokenSearchQuery = value
                case .wifi: session.wifiSearchQuery = value
                case .send: session.sendSearchQuery = value
                case .attachmentRef: session.attachmentSearchQuery = value
                }
            }
        )
    }

    private var favoritesBinding: Binding<Bool> {
        Binding(
            get: {
                switch itemKind {
                case .login: return session.showFavoriteLoginEntriesOnly
                case .note: return session.showFavoriteNoteEntriesOnly
                case .totp: return session.showFavoriteTotpEntriesOnly
                case .card: return session.showFavoriteCardEntriesOnly || session.showFavoriteIdentityEntriesOnly
                case .identity: return session.showFavoriteIdentityEntriesOnly
                case .passkey: return session.showFavoritePasskeyEntriesOnly
                case .sshKey: return session.showFavoriteSshKeyEntriesOnly
                case .apiToken: return session.showFavoriteApiTokenEntriesOnly
                case .wifi: return session.showFavoriteWifiEntriesOnly
                case .send: return session.showFavoriteSendEntriesOnly
                case .attachmentRef: return false
                }
            },
            set: { value in
                switch itemKind {
                case .login: session.showFavoriteLoginEntriesOnly = value
                case .note: session.showFavoriteNoteEntriesOnly = value
                case .totp: session.showFavoriteTotpEntriesOnly = value
                case .card:
                    session.showFavoriteCardEntriesOnly = value
                    session.showFavoriteIdentityEntriesOnly = value
                case .identity: session.showFavoriteIdentityEntriesOnly = value
                case .passkey: session.showFavoritePasskeyEntriesOnly = value
                case .sshKey: session.showFavoriteSshKeyEntriesOnly = value
                case .apiToken: session.showFavoriteApiTokenEntriesOnly = value
                case .wifi: session.showFavoriteWifiEntriesOnly = value
                case .send: session.showFavoriteSendEntriesOnly = value
                case .attachmentRef: break
                }
            }
        )
    }

    private var batchActionKind: UnifiedVaultItemKind {
        session.activeVaultBatchSelectionKind ?? itemKind
    }

    private var categoryBar: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.6), cornerRadius: 22) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(session.vaultProjects) { project in
                        Button {
                            do { try session.switchVaultCategory(projectID: project.id) } catch {}
                        } label: {
                            Label(project.title, systemImage: project.id == session.activeVaultProjectID ? "checkmark.circle.fill" : "folder")
                        }
                    }
                } label: {
                    Label(session.activeVaultCategoryTitle, systemImage: "folder.fill")
                        .font(.subheadline.weight(.heavy))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(session.vaultProjects.isEmpty)
                .foregroundStyle(AndroidParityPalette.textPrimary)

                Button {
                    pendingCategoryTitle = ""
                    isCreateCategoryAlertPresented = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AndroidParityPalette.primary)

                Button {
                    pendingCategoryTitle = session.activeVaultCategoryTitle
                    isRenameCategoryAlertPresented = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AndroidParityPalette.primary)
                .disabled(session.activeVaultProjectID == nil)

                Button {
                    if let projectID = session.activeVaultProjectID {
                        do { try session.deleteVaultCategory(projectID: projectID) } catch {}
                    }
                } label: {
                    Image(systemName: "folder.badge.minus")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .disabled(session.activeVaultProjectID == nil)
            }
        }
    }

    private var batchActionBar: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.6), cornerRadius: 22) {
            HStack(spacing: 10) {
                Text(session.vaultBatchSelectionTitle)
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                if session.isVaultBatchSelectionActive {
                    Button {
                        session.selectAllVisibleVaultBatchItems(for: batchActionKind)
                    } label: {
                        Image(systemName: "checklist.checked")
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AndroidParityPalette.primary)
                    Menu {
                        ForEach(session.availableVaultBatchMoveTargets) { project in
                            Button {
                                do {
                                    try session.moveSelectedVaultBatchItems(toProjectID: project.id)
                                } catch {
                                    // AppSessionModel owns user-visible failure state.
                                }
                            } label: {
                                Label(project.title, systemImage: "folder")
                            }
                        }
                    } label: {
                        Image(systemName: "folder.badge.gearshape")
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AndroidParityPalette.primary)
                    .disabled(!session.canMoveSelectedVaultBatchItems)
                    Button {
                        do {
                            if session.isTrashQuickFilterSelected {
                                try session.restoreSelectedVaultBatchItems()
                            } else {
                                try session.deleteSelectedVaultBatchItems()
                            }
                        } catch {
                            // AppSessionModel owns user-visible failure state.
                        }
                    } label: {
                        Image(systemName: session.isTrashQuickFilterSelected ? "arrow.uturn.backward.circle.fill" : "trash.circle.fill")
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(session.isTrashQuickFilterSelected ? AndroidParityPalette.primary : .red)
                    .disabled(session.isTrashQuickFilterSelected ? !session.canRestoreSelectedVaultBatchItems : !session.canDeleteSelectedVaultBatchItems)
                    Button {
                        session.clearVaultBatchSelection()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                } else {
                    Button {
                        session.enterVaultBatchSelection(for: itemKind)
                    } label: {
                        Image(systemName: "checkmark.circle")
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AndroidParityPalette.primary)
                }
            }
        }
    }

    private func batchAwareButton<Content: View>(
        id: String,
        kind: UnifiedVaultItemKind,
        edit: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        Button {
            if session.isVaultBatchSelectionActive {
                session.toggleVaultBatchItemSelection(id, for: kind)
            } else {
                edit()
            }
        } label: {
            content()
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func batchSelectableCard<Content: View>(
        id: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if session.isVaultBatchSelectionActive {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: session.selectedVaultBatchItemIDs.contains(id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: AndroidParityTypography.controlIconSize, weight: .heavy))
                    .foregroundStyle(session.selectedVaultBatchItemIDs.contains(id) ? AndroidParityPalette.primary : AndroidParityPalette.textSecondary)
                    .frame(width: 30, height: 30)
                content()
            }
        } else {
            content()
        }
    }

    private func savePresentedEditor() {
        Task {
            do {
                try await session.savePresentedEditorWithBitwardenFileSend(projectTitle: session.activeVaultName ?? "个人")
            } catch {}
        }
    }

    private func setFavorite(_ favorite: Bool) {
        guard let mode = session.presentedEditorMode else { return }
        switch mode.kind {
        case .login: setSelectedLoginFavorite(favorite)
        case .note: setSelectedNoteFavorite(favorite)
        case .totp: setSelectedTotpFavorite(favorite)
        case .card: setSelectedCardFavorite(favorite)
        case .identity: setSelectedIdentityFavorite(favorite)
        case .passkey: setSelectedPasskeyFavorite(favorite)
        case .sshKey: setSelectedSshKeyFavorite(favorite)
        case .apiToken: setSelectedApiTokenFavorite(favorite)
        case .wifi: setSelectedWifiFavorite(favorite)
        case .send: setSelectedSendFavorite(favorite)
        case .attachmentRef: break
        }
    }

    private func deletePresentedEntry() {
        guard let mode = session.presentedEditorMode, !mode.isAdding else { return }
        switch mode.kind {
        case .login: deleteLoginEntry()
        case .note: deleteNoteEntry()
        case .totp: deleteTotpEntry()
        case .card: deleteCardEntry()
        case .identity: deleteIdentityEntry()
        case .passkey: deletePasskeyEntry()
        case .sshKey: deleteSshKeyEntry()
        case .apiToken: deleteApiTokenEntry()
        case .wifi: deleteWifiEntry()
        case .send: deleteSendEntry()
        case .attachmentRef: break
        }
        session.dismissPresentedEditor()
    }

    private func totpCode(for entry: LocalTotpEntry) -> String {
        (try? session.totpCode(for: entry, at: now)) ?? "------"
    }

    private func cardSummary(for entry: LocalCardEntry) -> String {
        let lastFour = String(entry.number.suffix(4))
        return [entry.issuer, entry.network, lastFour.isEmpty ? "" : "**** \(lastFour)"].filter { !$0.isEmpty }.joined(separator: " / ")
    }

    private func identitySummary(for entry: LocalIdentityEntry) -> String {
        [entry.documentType, entry.fullName, entry.country].filter { !$0.isEmpty }.joined(separator: " / ")
    }

    private func attachmentSubtitle(for entry: LocalAttachmentMetadata) -> String {
        let sizeText = "\(entry.storedSize)/\(entry.originalSize) 字节"
        return [
            entry.downloadState.isEmpty ? "未知状态" : entry.downloadState,
            entry.storageMode,
            sizeText
        ]
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
    }

    private func emptyList(_ title: String, icon: String) -> some View {
        AndroidParityEmptyCard(title: title, systemImage: icon)
    }

    private func restoreSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.primary)
            content()
        }
    }

    @ViewBuilder
    private func restoreButton(
        id: String,
        kind: UnifiedVaultItemKind,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        if session.isVaultBatchSelectionActive {
            Button {
                session.toggleVaultBatchItemSelection(id, for: kind)
            } label: {
                batchSelectableCard(id: id) {
                    AndroidParityEntryCard(icon: "arrow.uturn.backward", title: title, subtitle: subtitle) {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .font(.system(size: AndroidParityTypography.controlIconSize, weight: .bold))
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }
                }
            }
            .buttonStyle(.plain)
        } else {
            AndroidParityEntryCard(icon: "arrow.uturn.backward", title: title, subtitle: subtitle) {
                Button(action: action) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.system(size: AndroidParityTypography.controlIconSize, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(AndroidParityPalette.primary)
            }
        }
    }

    private func extendedAddButton(_ kind: UnifiedVaultItemKind) -> some View {
        Button { session.presentAddEditor(forItemKind: kind) } label: {
            Label(kind.displayName, systemImage: kind.systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
    }
}

struct AndroidParityModuleChrome<CategoryBar: View, BatchBar: View, Content: View>: View {
    let title: String
    let tab: MonicaAppTab
    @Binding var selectedAction: AndroidParityToolbarAction?
    @Binding var searchText: String
    @Binding var favoritesOnly: Bool
    @Binding var stackedGroupMode: Bool
    let showsStackedGroupModeToggle: Bool
    let quickFilterRows: [AppVaultQuickFilterRow]
    @ViewBuilder var categoryBar: CategoryBar
    let onQuickFilter: (String) -> Void
    let onOpenVault: () -> Void
    let onAdd: () -> Void
    @ViewBuilder var batchBar: BatchBar
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    header
                    categoryBar
                    quickFilterStrip
                    batchBar
                    if selectedAction == .search { searchPanel }
                    content
                }
                .padding(.horizontal, 18)
                .padding(.top, 44)
                .padding(.bottom, 132)
            }
            .background(AndroidParityPalette.background.ignoresSafeArea())
            .foregroundStyle(AndroidParityPalette.textPrimary)

            Button(action: onAdd) {
                Image(systemName: tab == .generator ? "arrow.clockwise" : "plus")
                    .font(.system(size: AndroidParityTypography.controlIconSize, weight: .medium))
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                    .frame(width: 54, height: 54)
                    .background(AndroidParityPalette.primaryContainer, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 18)
            .padding(.bottom, 26)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title)
                .font(.system(size: AndroidParityTypography.screenTitleSize, weight: .heavy, design: .rounded))
                .foregroundStyle(AndroidParityPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.64)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 22) {
                toolbarButton(.folder, icon: "folder.fill", action: onOpenVault)
                toolbarButton(.search, icon: "magnifyingglass")
                toolbarButton(.more, icon: "ellipsis")
            }
            .padding(.horizontal, 24)
            .frame(height: 64)
            .background(AndroidParityPalette.surfaceVariant, in: Capsule(style: .continuous))
        }
    }

    private var searchPanel: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.56), cornerRadius: 22) {
            TextField("搜索", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(AndroidParityTextFieldStyle())
            Toggle("仅显示收藏", isOn: $favoritesOnly)
                .font(.headline.weight(.heavy))
                .tint(AndroidParityPalette.primary)
            if showsStackedGroupModeToggle {
                Toggle("堆叠分组", isOn: $stackedGroupMode)
                    .font(.headline.weight(.heavy))
                    .tint(AndroidParityPalette.primary)
            }
        }
    }

    private var quickFilterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(quickFilterRows) { row in
                    Button {
                        onQuickFilter(row.id)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: row.systemImage)
                                .font(.subheadline.weight(.heavy))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title)
                                    .font(.subheadline.weight(.heavy))
                                    .lineLimit(1)
                                Text(row.value)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(row.isSelected ? AndroidParityPalette.textPrimary.opacity(0.72) : AndroidParityPalette.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 52)
                        .background(
                            row.isSelected ? AndroidParityPalette.primaryContainer : AndroidParityPalette.surfaceVariant,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                        .foregroundStyle(row.isSelected ? AndroidParityPalette.textPrimary : AndroidParityPalette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(row.title)，\(row.value)")
                    .accessibilityHint(row.detail)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func toolbarButton(_ action: AndroidParityToolbarAction, icon: String, action directAction: (() -> Void)? = nil) -> some View {
        Button {
            if let directAction { directAction() } else { selectedAction = selectedAction == action ? nil : action }
        } label: {
            Image(systemName: icon)
                .font(.system(size: AndroidParityTypography.controlIconSize, weight: .heavy))
                .foregroundStyle(AndroidParityPalette.textPrimary.opacity(selectedAction == action ? 1 : 0.82))
                .frame(width: 34, height: 50)
        }
        .buttonStyle(.plain)
    }
}

private struct AndroidPasswordListCard: View {
    let entry: LocalLoginEntry
    let displayPreferences: VaultDisplayPreferences
    let appearancePreferences: AppAppearancePreferences

    var body: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.78), cornerRadius: 22) {
            HStack(alignment: .top, spacing: displayPreferences.cardDensity == .compact ? 12 : 18) {
                if appearancePreferences.showsPasswordListIcon {
                    AndroidParityIconTile(
                        systemImage: "lock.fill",
                        fill: appearancePreferences.passwordListIconFill,
                        tint: appearancePreferences.passwordListIconTint
                    )
                }
                VStack(alignment: .leading, spacing: displayPreferences.cardDensity.verticalSpacing) {
                    Text(entry.title.isEmpty ? "未命名" : entry.title)
                        .font(.subheadline.weight(.semibold))
                    if displayPreferences.showsLoginUsername, !entry.username.isEmpty {
                        Text(entry.username)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }
                    if displayPreferences.showsLoginURL, !entry.url.isEmpty {
                        Text(entry.url)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AndroidParityPalette.textSecondary.opacity(0.78))
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "ellipsis")
                    .font(.system(size: displayPreferences.cardDensity.iconSize, weight: .semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }
    }
}

private struct AndroidPasswordStackedGroupCard: View {
    let group: AppLoginStackedGroup
    let appearancePreferences: AppAppearancePreferences

    var body: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.78), cornerRadius: 22) {
            HStack(alignment: .top, spacing: 18) {
                if appearancePreferences.showsPasswordListIcon {
                    AndroidParityIconTile(
                        systemImage: group.systemImage,
                        fill: appearancePreferences.passwordListIconFill,
                        tint: appearancePreferences.passwordListIconTint
                    )
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(group.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(group.value)
                            .font(.caption.weight(.heavy))
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(AndroidParityPalette.primaryContainer, in: Capsule(style: .continuous))
                    }
                    Text(group.preview.isEmpty ? "未命名条目" : group.preview)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                        .lineLimit(2)
                    if !group.detail.isEmpty {
                        Text(group.detail)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AndroidParityPalette.textSecondary.opacity(0.78))
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }
        .accessibilityLabel("\(group.title)，\(group.value)")
        .accessibilityHint("打开该分组的密码条目")
    }
}

private struct AndroidTotpListCard: View {
    let entry: LocalTotpEntry
    let code: String
    let remaining: Int

    var body: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.78), cornerRadius: 22) {
            HStack(alignment: .center, spacing: 18) {
                AndroidParityIconTile(systemImage: "shield.lefthalf.filled", fill: AndroidParityPalette.primaryContainer)
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.title.isEmpty ? entry.issuer : entry.title)
                        .font(.subheadline.weight(.semibold))
                    Text([entry.issuer, entry.accountName].filter { !$0.isEmpty }.joined(separator: " / "))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                    GeometryReader { proxy in
                        Capsule()
                            .fill(AndroidParityPalette.outline)
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(AndroidParityPalette.primary)
                                    .frame(width: max(0, proxy.size.width * CGFloat(remaining) / CGFloat(max(Int(entry.period), 1))))
                            }
                    }
                    .frame(height: 10)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text(code)
                        .font(.system(size: AndroidParityTypography.prominentValueSize, weight: .heavy, design: .rounded))
                        .foregroundStyle(AndroidParityPalette.primary)
                    Text("\(remaining)s")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.primary)
                }
            }
        }
    }
}

private struct AndroidBankCardListCard: View {
    let entry: LocalCardEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.title.isEmpty ? entry.issuer : entry.title)
                        .font(.subheadline.weight(.semibold))
                    Text(entry.issuer)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.primary.opacity(0.88))
                }
                Spacer()
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
            }
            Text(maskedCardNumber(entry.number))
                .font(.system(size: AndroidParityTypography.prominentValueSize, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.62)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("持卡人")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.primary.opacity(0.8))
                    Text(entry.cardholderName.isEmpty ? "-" : entry.cardholderName)
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text("有效期")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.primary.opacity(0.8))
                    Text("\(entry.expiryMonth)/\(entry.expiryYear)")
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AndroidParityPalette.primaryDeep, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .foregroundStyle(AndroidParityPalette.primary)
    }

    private func maskedCardNumber(_ value: String) -> String {
        let suffix = value.suffix(4)
        return suffix.isEmpty ? "**** **** ****" : "****  ****  ****  \(suffix)"
    }
}

private struct AndroidIdentityListCard: View {
    let entry: LocalIdentityEntry

    var body: some View {
        AndroidParityCard(fill: AndroidParityPalette.tertiaryContainer.opacity(0.95), cornerRadius: 22) {
            HStack(alignment: .top, spacing: 18) {
                AndroidParityIconTile(systemImage: "person.text.rectangle.fill", fill: AndroidParityPalette.surfaceVariant, tint: AndroidParityPalette.primary)
                VStack(alignment: .leading, spacing: 10) {
                    Text(entry.title.isEmpty ? entry.documentType : entry.title)
                        .font(.subheadline.weight(.semibold))
                    Text(entry.fullName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                    Text("证件号码\n****\(entry.documentNumber.suffix(4))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary.opacity(0.86))
                }
                Spacer()
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
            }
        }
    }
}

private struct AndroidNoteListCard: View {
    let entry: LocalNoteEntry

    var body: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.78), cornerRadius: 22) {
            HStack(alignment: .top, spacing: 18) {
                AndroidParityIconTile(systemImage: "doc.text.fill", fill: AndroidParityPalette.primaryContainer)
                VStack(alignment: .leading, spacing: 12) {
                    Text(entry.title.isEmpty ? "未命名" : entry.title)
                        .font(.subheadline.weight(.semibold))
                    Text(entry.body)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                        .lineLimit(3)
                    HStack(spacing: 12) {
                        Text("#123")
                        Text("#joccc")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary.opacity(0.5))
                    Text("2026-03-11")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
                Spacer()
            }
        }
    }
}

private struct AndroidPasskeyListCard: View {
    let entry: LocalPasskeyEntry

    var body: some View {
        AndroidParityCard(fill: AndroidParityPalette.surface.opacity(0.92), cornerRadius: 22) {
            HStack(spacing: 20) {
                AndroidParityIconTile(systemImage: providerIcon, fill: providerFill, tint: providerTint)
                    .frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.title.isEmpty ? entry.username : entry.title)
                        .font(.subheadline.weight(.semibold))
                    Text(providerName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                    if entry.notes.localizedCaseInsensitiveContains("keepass") {
                        Text("KeePass format")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color.purple.opacity(0.72), in: Capsule())
                    }
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }
    }

    private var providerName: String {
        if entry.relyingPartyID.localizedCaseInsensitiveContains("github") { return "GitHub" }
        if entry.relyingPartyID.localizedCaseInsensitiveContains("google") { return "Google" }
        if entry.relyingPartyID.localizedCaseInsensitiveContains("openai") { return "OpenAI" }
        return entry.relyingPartyID
    }

    private var providerIcon: String {
        if entry.relyingPartyID.localizedCaseInsensitiveContains("github") { return "chevron.left.forwardslash.chevron.right" }
        if entry.relyingPartyID.localizedCaseInsensitiveContains("google") { return "g.circle.fill" }
        return "key.horizontal.fill"
    }

    private var providerFill: Color { providerName == "GitHub" ? .white : AndroidParityPalette.primaryContainer }
    private var providerTint: Color { providerName == "GitHub" ? .black : AndroidParityPalette.primary }
}

private struct AndroidSshKeyListCard: View {
    let entry: LocalSshKeyEntry

    var body: some View {
        AndroidExtendedSecretListCard(
            icon: "key.fill",
            title: entry.title,
            primary: [entry.username, entry.host].filter { !$0.isEmpty }.joined(separator: "@"),
            secondary: entry.publicKey,
            favorite: entry.favorite
        )
    }
}

private struct AndroidApiTokenListCard: View {
    let entry: LocalApiTokenEntry

    var body: some View {
        AndroidExtendedSecretListCard(
            icon: "text.badge.key",
            title: entry.title,
            primary: [entry.issuer, entry.accountName].filter { !$0.isEmpty }.joined(separator: " / "),
            secondary: entry.scopes,
            favorite: entry.favorite
        )
    }
}

private struct AndroidWifiListCard: View {
    let entry: LocalWifiEntry

    var body: some View {
        AndroidExtendedSecretListCard(
            icon: "wifi",
            title: entry.title,
            primary: entry.ssid,
            secondary: entry.hidden ? "\(entry.securityType) / 隐藏网络" : entry.securityType,
            favorite: entry.favorite
        )
    }
}

private struct AndroidSendListCard: View {
    let entry: LocalSendEntry

    var body: some View {
        AndroidExtendedSecretListCard(
            icon: "paperplane.fill",
            title: entry.title,
            primary: entry.expiresAt.isEmpty ? "不过期" : entry.expiresAt,
            secondary: "最多查看 \(entry.maxViews) 次",
            favorite: entry.favorite
        )
    }
}

private struct AndroidAttachmentListCard: View {
    let entry: LocalAttachmentMetadata
    var showsActions = true
    let download: (() -> Void)?
    let preview: () -> Void
    let delete: () -> Void

    var body: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.78), cornerRadius: 22) {
            HStack(alignment: .top, spacing: 18) {
                AndroidParityIconTile(systemImage: "paperclip", fill: AndroidParityPalette.primaryContainer)
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.fileName.isEmpty ? "未命名附件" : entry.fileName)
                        .font(.subheadline.weight(.semibold))
                    Text(primaryText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                    Text(secondaryText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary.opacity(0.78))
                        .lineLimit(1)
                }
                Spacer()
                if showsActions {
                    HStack(spacing: 12) {
                        if canDownloadBitwardenAttachment, let download {
                            Button(action: download) {
                                Image(systemName: "arrow.down.circle")
                                    .font(.system(size: AndroidParityTypography.controlIconSize, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AndroidParityPalette.primary)
                        }

                        Button(action: preview) {
                            Image(systemName: "eye")
                                .font(.system(size: AndroidParityTypography.controlIconSize, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AndroidParityPalette.primary)

                        Button(role: .destructive, action: delete) {
                            Image(systemName: "trash")
                                .font(.system(size: AndroidParityTypography.controlIconSize, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private var canDownloadBitwardenAttachment: Bool {
        entry.source == "bitwarden" && entry.downloadState == "pending-bitwarden-download"
    }

    private var primaryText: String {
        [
            entry.mediaType.isEmpty ? "未知类型" : entry.mediaType,
            entry.downloadState.isEmpty ? "未知状态" : entry.downloadState
        ]
            .joined(separator: " / ")
    }

    private var secondaryText: String {
        let sizeText = "\(entry.storedSize)/\(entry.originalSize) 字节"
        return [
            entry.storageMode,
            sizeText
        ]
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
    }
}

private struct AndroidExtendedSecretListCard: View {
    let icon: String
    let title: String
    let primary: String
    let secondary: String
    let favorite: Bool

    var body: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.78), cornerRadius: 22) {
            HStack(alignment: .top, spacing: 18) {
                AndroidParityIconTile(systemImage: icon, fill: AndroidParityPalette.primaryContainer)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title.isEmpty ? "未命名" : title)
                        .font(.subheadline.weight(.semibold))
                    Text(primary.isEmpty ? "未填写" : primary)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                    Text(secondary.isEmpty ? "无备注" : secondary)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary.opacity(0.78))
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: favorite ? "heart.fill" : "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(favorite ? AndroidParityPalette.primary : AndroidParityPalette.textSecondary)
            }
        }
    }
}

struct AddEditVaultItemView: View {
    @Bindable var session: AppSessionModel
    let mode: VaultItemEditorMode
    let activeVaultName: String
    let generateLoginPassword: () -> Void
    let generateSelectedLoginPassword: () -> Void
    let importTotpURI: () -> Void
    let scanTotpQRCode: (String) -> Bool
    let setFavorite: (Bool) -> Void
    let deleteEntry: () -> Void
    let save: () -> Void
    let dismiss: () -> Void

    @State private var isTotpScannerPresented = false
    @State private var isSendFileImporterPresented = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    storageBanner
                    formCard
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 120)
            }
            .background(AndroidParityPalette.background.ignoresSafeArea())
            Button(action: save) {
                Image(systemName: "checkmark")
                    .font(.system(size: AndroidParityTypography.controlIconSize, weight: .heavy))
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                    .frame(width: 54, height: 54)
                    .background(AndroidParityPalette.tertiaryContainer, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(18)
        }
        .sheet(isPresented: $isTotpScannerPresented) {
            TotpQRCodeScannerSheet(
                session: session,
                onCode: { payload in
                    if scanTotpQRCode(payload) {
                        isTotpScannerPresented = false
                        return true
                    }
                    return false
                },
                onCancel: { isTotpScannerPresented = false }
            )
        }
        .fileImporter(
            isPresented: $isSendFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard case .success(let urls) = result, let url = urls.first else {
                    return
                }
                try session.selectBitwardenSendFile(url: url)
            } catch {
                session.entryOperationState = .failed(error.localizedDescription)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 18) {
            Button(action: dismiss) {
                Image(systemName: "chevron.left")
                    .font(.system(size: AndroidParityTypography.controlIconSize, weight: .heavy))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AndroidParityPalette.textPrimary)
            Text(mode.isAdding ? "添加\(mode.kind.displayName)" : "编辑\(mode.kind.displayName)")
                .font(.system(size: AndroidParityTypography.editorTitleSize, weight: .heavy, design: .rounded))
                .foregroundStyle(AndroidParityPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer()
            typeChip
            favoriteButton
        }
    }

    private var typeChip: some View {
        HStack(spacing: 8) {
            Text(typeChipTitle)
                .font(.subheadline.weight(.semibold))
            Image(systemName: "chevron.down")
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(AndroidParityPalette.textPrimary)
        .padding(.horizontal, 18)
        .frame(height: 56)
        .background(AndroidParityPalette.primaryContainer, in: Capsule(style: .continuous))
    }

    @ViewBuilder
    private var favoriteButton: some View {
        Button { setFavorite(!currentFavorite) } label: {
            Image(systemName: currentFavorite ? "heart.fill" : "heart")
                .font(.system(size: AndroidParityTypography.controlIconSize, weight: .heavy))
                .frame(width: 50, height: 50)
        }
        .buttonStyle(.plain)
        .foregroundStyle(currentFavorite ? AndroidParityPalette.primary : AndroidParityPalette.textPrimary)
        .disabled(mode.isAdding)
    }

    private var storageBanner: some View {
        HStack(spacing: 18) {
            AndroidParityIconTile(systemImage: mode.kind.systemImage, fill: AndroidParityPalette.primary, tint: AndroidParityPalette.background)
            VStack(alignment: .leading, spacing: 4) {
                Text("多数据库存储")
                    .font(.subheadline.weight(.semibold))
                Text("\(activeVaultName) · 未分类")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.primary.opacity(0.86))
            }
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.subheadline.weight(.semibold))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(AndroidParityPalette.primary)
        .background(AndroidParityPalette.primaryDeep, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var formCard: some View {
        AndroidParityCard(fill: AndroidParityPalette.surface.opacity(0.92), cornerRadius: 22) {
            Text(formTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.primary)
            switch mode.kind {
            case .login: loginFields
            case .note: noteFields
            case .totp: totpFields
            case .card: cardFields
            case .identity: identityFields
            case .passkey: passkeyFields
            case .sshKey: sshKeyFields
            case .apiToken: apiTokenFields
            case .wifi: wifiFields
            case .send: sendFields
            case .attachmentRef:
                Text("该类型当前只支持列表展示。")
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
            AndroidParityInfoRow(title: "状态", value: session.entryOperationState.label)
            if !mode.isAdding {
                Button(role: .destructive, action: deleteEntry) {
                    Label("删除", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .destructiveOutlined))
            }
        }
    }

    private var loginFields: some View {
        VStack(spacing: 18) {
            field(icon: "folder.fill", title: "标题 *", text: mode.isAdding ? $session.loginTitle : $session.editingLoginTitle)
            field(icon: "globe", title: "网站/网址", text: mode.isAdding ? $session.loginURL : $session.editingLoginURL)
            HStack(spacing: 14) {
                Button("+ 添加 URL") {}
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                Button("绑定应用") {}
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
            }
            field(icon: "person.fill", title: "账号", text: mode.isAdding ? $session.loginUsername : $session.editingLoginUsername)
            Picker("登录方式", selection: .constant(0)) {
                Text("密码登录").tag(0)
                Text("第三方登录").tag(1)
            }
            .pickerStyle(.segmented)
            secureField(icon: "lock.fill", title: "密码", text: mode.isAdding ? $session.loginPassword : $session.editingLoginPassword)
            Button(action: mode.isAdding ? generateLoginPassword : generateSelectedLoginPassword) {
                Label("添加密码", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
        }
    }

    private var noteFields: some View {
        VStack(spacing: 18) {
            field(icon: "folder.fill", title: "标题 *", text: mode.isAdding ? $session.noteTitle : $session.editingNoteTitle)
            TextEditor(text: mode.isAdding ? $session.noteBody : $session.editingNoteBody)
                .frame(minHeight: 190)
                .padding(12)
                .scrollContentBackground(.hidden)
                .background(AndroidParityPalette.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 16).stroke(AndroidParityPalette.outline, lineWidth: 1) }
        }
    }

    private var totpFields: some View {
        VStack(spacing: 18) {
            field(icon: "folder.fill", title: "标题 *", text: mode.isAdding ? $session.totpTitle : $session.editingTotpTitle)
            secureField(icon: "key.fill", title: "密钥", text: mode.isAdding ? $session.totpSecret : $session.editingTotpSecret)
            field(icon: "building.2.fill", title: "签发方", text: mode.isAdding ? $session.totpIssuer : $session.editingTotpIssuer)
            field(icon: "person.fill", title: "账号", text: mode.isAdding ? $session.totpAccountName : $session.editingTotpAccountName)
            Button { isTotpScannerPresented = true } label: {
                Label("扫描二维码", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
        }
    }

    private var cardFields: some View {
        VStack(spacing: 18) {
            field(icon: "folder.fill", title: "标题 *", text: mode.isAdding ? $session.cardTitle : $session.editingCardTitle)
            field(icon: "person.fill", title: "持卡人", text: mode.isAdding ? $session.cardholderName : $session.editingCardholderName)
            secureField(icon: "creditcard.fill", title: "卡号", text: mode.isAdding ? $session.cardNumber : $session.editingCardNumber)
            HStack(spacing: 14) {
                field(icon: "calendar", title: "月", text: mode.isAdding ? $session.cardExpiryMonth : $session.editingCardExpiryMonth)
                field(icon: "calendar", title: "年", text: mode.isAdding ? $session.cardExpiryYear : $session.editingCardExpiryYear)
            }
            secureField(icon: "lock.fill", title: "CVV", text: mode.isAdding ? $session.cardCVV : $session.editingCardCVV)
            field(icon: "building.columns.fill", title: "银行", text: mode.isAdding ? $session.cardIssuer : $session.editingCardIssuer)
            field(icon: "network", title: "卡组织", text: mode.isAdding ? $session.cardNetwork : $session.editingCardNetwork)
        }
    }

    private var identityFields: some View {
        VStack(spacing: 18) {
            field(icon: "folder.fill", title: "标题 *", text: mode.isAdding ? $session.identityTitle : $session.editingIdentityTitle)
            field(icon: "doc.text.fill", title: "类型", text: mode.isAdding ? $session.identityDocumentType : $session.editingIdentityDocumentType)
            field(icon: "person.fill", title: "姓名", text: mode.isAdding ? $session.identityFullName : $session.editingIdentityFullName)
            secureField(icon: "number", title: "证件号", text: mode.isAdding ? $session.identityDocumentNumber : $session.editingIdentityDocumentNumber)
            field(icon: "building.2.fill", title: "签发方", text: mode.isAdding ? $session.identityIssuer : $session.editingIdentityIssuer)
            field(icon: "globe", title: "国家/地区", text: mode.isAdding ? $session.identityCountry : $session.editingIdentityCountry)
        }
    }

    private var passkeyFields: some View {
        VStack(spacing: 18) {
            field(icon: "folder.fill", title: "标题 *", text: mode.isAdding ? $session.passkeyTitle : $session.editingPasskeyTitle)
            field(icon: "globe", title: "RP ID", text: mode.isAdding ? $session.passkeyRelyingPartyID : $session.editingPasskeyRelyingPartyID)
            field(icon: "person.fill", title: "账号", text: mode.isAdding ? $session.passkeyUsername : $session.editingPasskeyUsername)
            field(icon: "key.horizontal.fill", title: "Credential ID", text: mode.isAdding ? $session.passkeyCredentialID : $session.editingPasskeyCredentialID)
            field(icon: "curlybraces", title: "Public Key COSE", text: mode.isAdding ? $session.passkeyPublicKeyCOSE : $session.editingPasskeyPublicKeyCOSE)
            secureField(icon: "lock.shield.fill", title: "Keychain 引用", text: mode.isAdding ? $session.passkeyPrivateKeyReference : $session.editingPasskeyPrivateKeyReference)
        }
    }

    private var sshKeyFields: some View {
        VStack(spacing: 18) {
            field(icon: "folder.fill", title: "标题 *", text: mode.isAdding ? $session.sshKeyTitle : $session.editingSshKeyTitle)
            field(icon: "person.fill", title: "用户名", text: mode.isAdding ? $session.sshKeyUsername : $session.editingSshKeyUsername)
            field(icon: "network", title: "主机", text: mode.isAdding ? $session.sshKeyHost : $session.editingSshKeyHost)
            field(icon: "key.fill", title: "公钥", text: mode.isAdding ? $session.sshKeyPublicKey : $session.editingSshKeyPublicKey)
            secureField(icon: "lock.shield.fill", title: "私钥引用", text: mode.isAdding ? $session.sshKeyPrivateKeyReference : $session.editingSshKeyPrivateKeyReference)
            field(icon: "text.bubble.fill", title: "口令提示", text: mode.isAdding ? $session.sshKeyPassphraseHint : $session.editingSshKeyPassphraseHint)
            field(icon: "note.text", title: "备注", text: mode.isAdding ? $session.sshKeyNotes : $session.editingSshKeyNotes)
        }
    }

    private var apiTokenFields: some View {
        VStack(spacing: 18) {
            field(icon: "folder.fill", title: "标题 *", text: mode.isAdding ? $session.apiTokenTitle : $session.editingApiTokenTitle)
            field(icon: "building.2.fill", title: "签发方", text: mode.isAdding ? $session.apiTokenIssuer : $session.editingApiTokenIssuer)
            field(icon: "person.fill", title: "账号", text: mode.isAdding ? $session.apiTokenAccountName : $session.editingApiTokenAccountName)
            secureField(icon: "text.badge.key", title: "Token", text: mode.isAdding ? $session.apiTokenToken : $session.editingApiTokenToken)
            field(icon: "scope", title: "权限范围", text: mode.isAdding ? $session.apiTokenScopes : $session.editingApiTokenScopes)
            field(icon: "calendar", title: "过期时间", text: mode.isAdding ? $session.apiTokenExpiresAt : $session.editingApiTokenExpiresAt)
            field(icon: "note.text", title: "备注", text: mode.isAdding ? $session.apiTokenNotes : $session.editingApiTokenNotes)
        }
    }

    private var wifiFields: some View {
        VStack(spacing: 18) {
            field(icon: "folder.fill", title: "标题 *", text: mode.isAdding ? $session.wifiTitle : $session.editingWifiTitle)
            field(icon: "wifi", title: "SSID", text: mode.isAdding ? $session.wifiSSID : $session.editingWifiSSID)
            field(icon: "lock.shield.fill", title: "安全类型", text: mode.isAdding ? $session.wifiSecurityType : $session.editingWifiSecurityType)
            secureField(icon: "lock.fill", title: "密码", text: mode.isAdding ? $session.wifiPassword : $session.editingWifiPassword)
            Toggle("隐藏网络", isOn: mode.isAdding ? $session.wifiHidden : $session.editingWifiHidden)
                .font(.subheadline.weight(.semibold))
                .tint(AndroidParityPalette.primary)
            field(icon: "note.text", title: "备注", text: mode.isAdding ? $session.wifiNotes : $session.editingWifiNotes)
            if !mode.isAdding, !session.editingWifiQRCodePayload.isEmpty {
                if let image = WifiQRCodeRenderer.image(for: session.editingWifiQRCodePayload, size: 192) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 192, height: 192)
                        .padding(16)
                        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .frame(maxWidth: .infinity)
                }
                AndroidParityInfoRow(title: "二维码内容", value: session.editingWifiQRCodePayload)
                ShareLink(item: session.editingWifiQRCodePayload) {
                    Label("分享 Wi-Fi", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
            }
        }
    }

    private var sendFields: some View {
        VStack(spacing: 18) {
            field(icon: "folder.fill", title: "标题 *", text: mode.isAdding ? $session.sendTitle : $session.editingSendTitle)
            if mode.isAdding {
                Picker("Send 类型", selection: $session.sendCreateType) {
                    ForEach(SendCreateType.allCases) { type in
                        Text(type.title).tag(type)
                    }
                }
                .pickerStyle(.segmented)
            }
            if mode.isAdding, session.sendCreateType == .file {
                Button {
                    isSendFileImporterPresented = true
                } label: {
                    Label(session.sendFileName.isEmpty ? "选择文件" : session.sendFileName, systemImage: "paperclip")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                secureField(icon: "key.fill", title: "访问密码", text: $session.sendPassword)
                Toggle("隐藏邮箱", isOn: $session.sendHideEmail)
                    .font(.subheadline.weight(.semibold))
                    .tint(AndroidParityPalette.primary)
            } else {
                secureField(icon: "text.alignleft", title: "内容", text: mode.isAdding ? $session.sendBody : $session.editingSendBody)
            }
            field(icon: "calendar", title: "过期时间", text: mode.isAdding ? $session.sendExpiresAt : $session.editingSendExpiresAt)
            Stepper(value: mode.isAdding ? $session.sendMaxViews : $session.editingSendMaxViews, in: 1...999) {
                Text("最多查看 \(mode.isAdding ? session.sendMaxViews : session.editingSendMaxViews) 次")
                    .font(.subheadline.weight(.semibold))
            }
            .tint(AndroidParityPalette.primary)
            field(icon: "note.text", title: "备注", text: mode.isAdding ? $session.sendNotes : $session.editingSendNotes)
        }
    }

    private func field(icon: String, title: String, text: Binding<String>) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .frame(width: 34)
            TextField(title, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 58)
        .background(AndroidParityPalette.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(AndroidParityPalette.outline, lineWidth: 1.2) }
    }

    private func secureField(icon: String, title: String, text: Binding<String>) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .frame(width: 34)
            SecureField(title, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 58)
        .background(AndroidParityPalette.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(AndroidParityPalette.outline, lineWidth: 1.2) }
    }

    private var typeChipTitle: String {
        mode.kind == .login ? "*** 密码" : mode.kind.displayName
    }

    private var formTitle: String {
        switch mode.kind {
        case .login: return "凭据"
        case .note: return "笔记"
        case .totp: return "验证器"
        case .card: return "银行卡"
        case .identity: return "证件"
        case .passkey: return "通行密钥"
        case .sshKey, .apiToken, .wifi, .send, .attachmentRef: return mode.kind.displayName
        }
    }

    private var currentFavorite: Bool {
        switch mode.kind {
        case .login: return session.editingLoginFavorite
        case .note: return session.editingNoteFavorite
        case .totp: return session.editingTotpFavorite
        case .card: return session.editingCardFavorite
        case .identity: return session.editingIdentityFavorite
        case .passkey: return session.editingPasskeyFavorite
        case .sshKey: return session.editingSshKeyFavorite
        case .apiToken: return session.editingApiTokenFavorite
        case .wifi: return session.editingWifiFavorite
        case .send: return session.editingSendFavorite
        case .attachmentRef: return false
        }
    }
}

private extension UnifiedVaultItemKind {
    var systemImage: String {
        switch self {
        case .login: return "lock.fill"
        case .note: return "doc.text.fill"
        case .totp: return "shield.fill"
        case .card: return "creditcard.fill"
        case .identity: return "person.text.rectangle.fill"
        case .passkey: return "key.horizontal.fill"
        case .sshKey: return "key.fill"
        case .apiToken: return "text.badge.key"
        case .wifi: return "wifi"
        case .send: return "paperplane.fill"
        case .attachmentRef: return "paperclip"
        }
    }
}
