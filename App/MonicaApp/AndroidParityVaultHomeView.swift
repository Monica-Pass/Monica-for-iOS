import MonicaCore
import MonicaStorage
import Observation
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AndroidParityVaultHomeView: View {
    @Bindable var session: AppSessionModel
    @Environment(\.screenPrivacyMonitor) private var screenPrivacyMonitor
    /// 是否为密码 Tab 根页：为 true 时显示二级模块 Picker，列表随 `session.passwordModule` 切换。
    let isPasswordRoot: Bool
    /// 非密码根页时固定的条目类型（验证器 / 银行卡）。
    let baseItemKind: UnifiedVaultItemKind?
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
    let createBillingAddressEntry: () -> Void
    let updateBillingAddressEntry: () -> Void
    let setSelectedBillingAddressFavorite: (Bool) -> Void
    let deleteBillingAddressEntry: () -> Void
    let restoreBillingAddressEntry: (LocalBillingAddressEntry) -> Void
    let createPaymentAccountEntry: () -> Void
    let updatePaymentAccountEntry: () -> Void
    let setSelectedPaymentAccountFavorite: (Bool) -> Void
    let deletePaymentAccountEntry: () -> Void
    let restorePaymentAccountEntry: (LocalPaymentAccountEntry) -> Void
    let createPasskeyEntry: () -> Void
    let updatePasskeyEntry: () -> Void
    let setSelectedPasskeyFavorite: (Bool) -> Void
    let deletePasskeyEntry: () -> Void
    let restorePasskeyEntry: (LocalPasskeyEntry) -> Void
    let setSelectedSshKeyFavorite: (Bool) -> Void
    let deleteSshKeyEntry: () -> Void
    let restoreSshKeyEntry: (LocalSshKeyEntry) -> Void
    let setSelectedGPGKeyFavorite: (Bool) -> Void
    let deleteGPGKeyEntry: () -> Void
    let restoreGPGKeyEntry: (LocalGPGKeyEntry) -> Void
    let setSelectedApiTokenFavorite: (Bool) -> Void
    let deleteApiTokenEntry: () -> Void
    let restoreApiTokenEntry: (LocalApiTokenEntry) -> Void
    let setSelectedWifiFavorite: (Bool) -> Void
    let deleteWifiEntry: () -> Void
    let restoreWifiEntry: (LocalWifiEntry) -> Void
    let setSelectedBarcodeFavorite: (Bool) -> Void
    let deleteBarcodeEntry: () -> Void
    let restoreBarcodeEntry: (LocalBarcodeEntry) -> Void
    let setSelectedSendFavorite: (Bool) -> Void
    let deleteSendEntry: () -> Void
    let restoreSendEntry: (LocalSendEntry) -> Void
    let deleteAttachmentEntry: (LocalAttachmentMetadata) -> Void
    let restoreAttachmentEntry: (LocalAttachmentMetadata) -> Void
    let refreshExtendedParityEntries: () -> Void

    @State private var isVaultImporterPresented = false
    @State private var isTotpScannerPresented = false
    @State private var now = Date()
    @State private var isGeneratorPresented = false
    @State private var isAutoFillGuidePresented = false
    @State private var totpActionFeedback: String?
    @State private var isTrashPurgeConfirmationPresented = false
    @State private var isEmptyTrashConfirmationPresented = false
    @State private var loginActionFeedback: String?

    private let vaultFileType = UTType(filenameExtension: "mdbx") ?? .data
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var itemKind: UnifiedVaultItemKind {
        guard isPasswordRoot else {
            if baseItemKind == .totp, session.totpModule == .steam {
                return .steam
            }
            return baseItemKind ?? .login
        }
        switch session.passwordModule {
        case .login:
            return .login
        case .passkey:
            return .passkey
        case .note:
            return .note
        case .other:
            return session.passwordOtherKind
        }
    }

    private var addMenuKinds: [UnifiedVaultItemKind] {
        if !isPasswordRoot {
            return [.card, .identity, .billingAddress, .paymentAccount]
        }
        return session.passwordModule == .other ? PasswordModule.otherKinds : []
    }

    var body: some View {
        AndroidParityModuleChrome(
            title: largeTitle,
            selectedAction: $session.expandedToolbarAction,
            searchText: searchBinding,
            favoritesOnly: favoritesBinding,
            stackedGroupMode: $session.isLoginStackedGroupModeEnabled,
            showsStackedGroupModeToggle: itemKind == .login,
            quickFilterRows: session.vaultQuickFilterRows,
            sectionBar: { sectionBarContent },
            categoryBar: { categoryBar },
            tagBar: { VaultTagToolsBar(session: session) },
            onQuickFilter: { filter in
                session.haptics.play(.selection)
                session.applyVaultQuickFilter(filter)
            },
            onOpenVault: { isVaultImporterPresented = true },
            onAdd: { session.presentAddEditor(forItemKind: itemKind) },
            onAddKind: { kind in session.presentAddEditor(forItemKind: kind) },
            addMenuKinds: addMenuKinds,
            showsMoreMenu: isPasswordRoot,
            moreMenuModules: session.moreMenuLayoutModules,
            onSelectMoreModule: { module in
                switch module {
                case .generator:
                    isGeneratorPresented = true
                case .keePass:
                    session.isKeePassLibraryPresented = true
                default:
                    if let listModule = module.passwordModule {
                        session.passwordModule = listModule
                    }
                }
            },
            onOpenGlobalSearch: session.vaultState == .unlocked
                ? { session.isGlobalSearchPresented = true }
                : nil,
            batchBar: { batchActionBar }
        ) {
            if session.vaultState == .unlocked {
                VStack(spacing: 14) {
                    if session.isTrashQuickFilterSelected {
                        trashMaintenanceCard
                    }
                    unlockedContent
                }
            } else {
                lockedSummary
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $isGeneratorPresented) {
            GeneratorRootView(session: session)
        }
        .navigationDestination(isPresented: $isAutoFillGuidePresented) {
            AppAutoFillDefaultManagerGuideView(title: String(localized: "系统自动填充说明"))
        }
        .navigationDestination(isPresented: $session.isGlobalSearchPresented) {
            AppGlobalSearchView(session: session)
        }
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
                    dismiss: session.dismissPresentedEditorSavingNoteDraft
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: presentedDetailBinding) {
            if let route = session.presentedDetailRoute {
                VaultItemDetailView(session: session, route: route)
                    .presentationDetents([.medium, .large])
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
    }

    @ViewBuilder
    private var unlockedContent: some View {
        switch itemKind {
        case .login:
            passwordList
        case .totp:
            totpList
        case .steam:
            steamList
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
        case .gpgKey:
            gpgKeyList
        case .apiToken:
            apiTokenList
        case .wifi:
            wifiList
        case .sso:
            ssoList
        case .barcode:
            barcodeList
        case .send:
            sendList
        case .billingAddress:
            billingAddressList
        case .paymentAccount:
            paymentAccountList
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
                    emptyList(String(localized: "没有匹配的分组"), icon: "square.stack.3d.up.fill")
                }
            } else {
                ForEach(session.filteredLoginEntries) { entry in
                    batchAwareButton(id: entry.id, kind: .login) {
                        batchSelectableCard(id: entry.id) {
                            AndroidPasswordListCard(
                                entry: entry,
                                displayPreferences: session.vaultDisplayPreferences,
                                appearancePreferences: session.appearancePreferences
                            )
                        }
                    }
                    .contextMenu {
                        Button {
                            copyLoginValue(entry.username)
                        } label: {
                            Label("复制用户名", systemImage: "person.text.rectangle")
                        }
                        Button {
                            copyLoginValue(entry.password)
                        } label: {
                            Label("复制密码", systemImage: "key")
                        }
                    }
                }
                if let loginActionFeedback {
                    Text(loginActionFeedback)
                        .font(.caption2)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                if session.filteredLoginEntries.isEmpty {
                    emptyList(String(localized: "没有匹配的密码"), icon: "lock.fill")
                }
            }
            deletedLoginRows
        }
    }

    private func copyLoginValue(_ value: String) {
        guard session.vaultState == .unlocked else {
            loginActionFeedback = String(localized: "请先解锁保险库。")
            return
        }
        loginActionFeedback = session.copySensitiveValueToPasteboard(value).message
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
            // Issue #47：手动开始/结束的锁屏倒计时试点，只显示别名 + 倒计时。
            AuthenticatorLiveActivityCard(entries: session.filteredTotpEntries, now: now)
            ForEach(session.filteredTotpEntries) { entry in
                batchAwareButton(id: entry.id, kind: .totp) {
                    batchSelectableCard(id: entry.id) {
                        AndroidTotpListCard(
                            entry: entry,
                            code: session.maskedSensitivePreview(totpCode(for: entry)),
                            remaining: session.totpTimeRemaining(for: entry, at: now),
                            iconSystemName: session.totpIconSystemName(for: entry),
                            haptics: session.haptics
                        )
                    }
                }
                .contextMenu {
                    Button {
                        totpActionFeedback = session.copyOtpCode(for: entry).message
                    } label: {
                        Label("复制验证码", systemImage: "doc.on.doc")
                    }
                    if session.otpType(for: entry) == .hotp {
                        Button {
                            do {
                                _ = try session.consumeHotpCode(for: entry)
                                totpActionFeedback = String(localized: "已使用当前验证码，并生成下一个")
                            } catch {
                                totpActionFeedback = error.localizedDescription
                            }
                        } label: {
                            Label("已使用，生成下一个", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
            if let totpActionFeedback {
                Text(totpActionFeedback)
                    .font(.caption2)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            if session.filteredTotpEntries.isEmpty {
                emptyList(String(localized: "没有匹配的验证码"), icon: "shield.lefthalf.filled")
            }
            deletedTotpRows
        }
    }

    private var steamList: some View {
        VStack(spacing: 14) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.52), cornerRadius: 22) {
                HStack(spacing: 12) {
                    SecureField("粘贴 maFile / steamguard 链接", text: $session.steamImportInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(AndroidParityTextFieldStyle())
                    Button {
                        do {
                            try session.importSteamGuard(text: session.steamImportInput)
                        } catch {
                            session.entryOperationState = .failed(error.localizedDescription)
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 46, height: 46)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AndroidParityPalette.primary)
                    .accessibilityLabel(String(localized: "导入 Steam 数据"))
                }
                Button {
                    session.presentAddEditor(forItemKind: .steam)
                } label: {
                    Label("添加 Steam 账号", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
            }
            ForEach(session.filteredSteamEntries) { entry in
                batchAwareButton(id: entry.id, kind: .steam) {
                    batchSelectableCard(id: entry.id) {
                        AndroidSteamListCard(
                            entry: entry,
                            code: session.steamGuardCode(for: entry, at: now),
                            remaining: session.steamGuardRemainingSeconds(for: entry, at: now)
                        )
                    }
                }
            }
            if session.filteredSteamEntries.isEmpty {
                emptyList(String(localized: "还没有 Steam Guard 条目"), icon: "shield.lefthalf.filled")
            }
            deletedSteamRows
        }
    }

    @ViewBuilder private var deletedSteamRows: some View {
        if !session.deletedSteamEntries.isEmpty {
            restoreSection("已删除 Steam") {
                ForEach(session.deletedSteamEntries) { entry in
                    restoreButton(id: entry.id, kind: .steam, title: entry.title, subtitle: entry.accountName) {
                        do {
                            try session.restoreSteamEntry(entry)
                        } catch {}
                    }
                }
            }
        }
    }

    private var walletList: some View {
        VStack(spacing: 16) {
            ForEach(session.filteredCardEntries) { entry in
                batchAwareButton(id: entry.id, kind: .card) {
                    batchSelectableCard(id: entry.id) {
                        AndroidBankCardListCard(entry: entry)
                    }
                }
            }
            ForEach(session.filteredIdentityEntries) { entry in
                batchAwareButton(id: entry.id, kind: .identity) {
                    batchSelectableCard(id: entry.id) {
                        AndroidIdentityListCard(entry: entry)
                    }
                }
            }
            ForEach(session.filteredBillingAddressEntries) { entry in
                batchAwareButton(id: entry.id, kind: .billingAddress) {
                    batchSelectableCard(id: entry.id) {
                        AndroidBillingAddressListCard(entry: entry)
                    }
                }
            }
            ForEach(session.filteredPaymentAccountEntries) { entry in
                batchAwareButton(id: entry.id, kind: .paymentAccount) {
                    batchSelectableCard(id: entry.id) {
                        AndroidPaymentAccountListCard(entry: entry)
                    }
                }
            }
            if session.filteredCardEntries.isEmpty
                && session.filteredIdentityEntries.isEmpty
                && session.filteredBillingAddressEntries.isEmpty
                && session.filteredPaymentAccountEntries.isEmpty {
                emptyList(String(localized: "没有匹配的卡片、证件或账单信息"), icon: "creditcard")
            }
            deletedCardRows
            deletedIdentityRows
            deletedBillingAddressRows
            deletedPaymentAccountRows
        }
    }

    private var billingAddressList: some View {
        VStack(spacing: 14) {
            ForEach(session.filteredBillingAddressEntries) { entry in
                batchAwareButton(id: entry.id, kind: .billingAddress) {
                    batchSelectableCard(id: entry.id) {
                        AndroidBillingAddressListCard(entry: entry)
                    }
                }
            }
            if session.filteredBillingAddressEntries.isEmpty {
                emptyList(String(localized: "没有匹配的账单地址"), icon: "house.fill")
            }
            deletedBillingAddressRows
        }
    }

    private var paymentAccountList: some View {
        VStack(spacing: 14) {
            ForEach(session.filteredPaymentAccountEntries) { entry in
                batchAwareButton(id: entry.id, kind: .paymentAccount) {
                    batchSelectableCard(id: entry.id) {
                        AndroidPaymentAccountListCard(entry: entry)
                    }
                }
            }
            if session.filteredPaymentAccountEntries.isEmpty {
                emptyList(String(localized: "没有匹配的支付账户"), icon: "wallet.pass.fill")
            }
            deletedPaymentAccountRows
        }
    }

    private var noteList: some View {
        VStack(spacing: 14) {
            ForEach(session.filteredNoteEntries) { entry in
                batchAwareButton(id: entry.id, kind: .note) {
                    batchSelectableCard(id: entry.id) {
                        AndroidNoteListCard(entry: entry, previewBody: session.maskedSensitivePreview(entry.body))
                    }
                }
            }
            if session.filteredNoteEntries.isEmpty {
                emptyList(String(localized: "没有匹配的笔记"), icon: "note.text")
            }
            deletedNoteRows
        }
    }

    private var passkeyList: some View {
        VStack(spacing: 14) {
            ForEach(session.filteredPasskeyEntries) { entry in
                batchAwareButton(id: entry.id, kind: .passkey) {
                    batchSelectableCard(id: entry.id) {
                        AndroidPasskeyListCard(entry: entry)
                    }
                }
            }
            if session.filteredPasskeyEntries.isEmpty {
                emptyList(String(localized: "没有匹配的通行密钥"), icon: "key.horizontal.fill")
            }
            deletedPasskeyRows
        }
    }

    private var sshKeyList: some View {
        VStack(spacing: 14) {
            ForEach(session.filteredSshKeyEntries) { entry in
                batchAwareButton(id: entry.id, kind: .sshKey) {
                    batchSelectableCard(id: entry.id) {
                        AndroidSshKeyListCard(entry: entry)
                    }
                }
            }
            if session.filteredSshKeyEntries.isEmpty {
                emptyList(String(localized: "没有匹配的 SSH 密钥"), icon: "key.fill")
            }
            deletedSshKeyRows
        }
    }

    private var gpgKeyList: some View {
        VStack(spacing: 14) {
            ForEach(session.filteredGPGKeyEntries) { entry in
                batchAwareButton(id: entry.id, kind: .gpgKey) {
                    batchSelectableCard(id: entry.id) {
                        AndroidGPGKeyListCard(entry: entry)
                    }
                }
            }
            if session.filteredGPGKeyEntries.isEmpty {
                emptyList(String(localized: "没有匹配的 GPG 密钥"), icon: "key.horizontal.fill")
            }
            deletedGPGKeyRows
        }
    }

    private var apiTokenList: some View {
        VStack(spacing: 14) {
            ForEach(session.filteredApiTokenEntries) { entry in
                batchAwareButton(id: entry.id, kind: .apiToken) {
                    batchSelectableCard(id: entry.id) {
                        AndroidApiTokenListCard(entry: entry)
                    }
                }
            }
            if session.filteredApiTokenEntries.isEmpty {
                emptyList(String(localized: "没有匹配的 API Token"), icon: "text.badge.key")
            }
            deletedApiTokenRows
        }
    }

    private var wifiList: some View {
        VStack(spacing: 14) {
            ForEach(session.filteredWifiEntries) { entry in
                batchAwareButton(id: entry.id, kind: .wifi) {
                    batchSelectableCard(id: entry.id) {
                        AndroidWifiListCard(entry: entry)
                    }
                }
            }
            if session.filteredWifiEntries.isEmpty {
                emptyList(String(localized: "没有匹配的 Wi-Fi"), icon: "wifi")
            }
            deletedWifiRows
        }
    }

    private var ssoList: some View {
        VStack(spacing: 14) {
            ForEach(session.filteredSSOEntries) { entry in
                batchAwareButton(id: entry.id, kind: .sso) {
                    batchSelectableCard(id: entry.id) {
                        AndroidSSOListCard(entry: entry)
                    }
                }
            }
            if session.filteredSSOEntries.isEmpty {
                emptyList(String(localized: "没有匹配的 SSO 条目"), icon: "person.badge.key.fill")
            }
            deletedSSORows
        }
    }

    private var barcodeList: some View {
        VStack(spacing: 14) {
            ForEach(session.filteredBarcodeEntries) { entry in
                batchAwareButton(id: entry.id, kind: .barcode) {
                    batchSelectableCard(id: entry.id) {
                        AndroidBarcodeListCard(entry: entry)
                    }
                }
            }
            if session.filteredBarcodeEntries.isEmpty {
                emptyList(String(localized: "没有匹配的条码"), icon: "barcode.viewfinder")
            }
            deletedBarcodeRows
        }
    }

    private var sendList: some View {
        VStack(spacing: 14) {
            ForEach(session.filteredSendEntries) { entry in
                batchAwareButton(id: entry.id, kind: .send) {
                    batchSelectableCard(id: entry.id) {
                        AndroidSendListCard(entry: entry)
                    }
                }
            }
            if session.filteredSendEntries.isEmpty {
                emptyList(String(localized: "没有匹配的 Send"), icon: "paperplane.fill")
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
                emptyList(String(localized: "没有匹配的附件引用"), icon: "paperclip")
            }
            deletedAttachmentRows
        }
    }

    private var identityList: some View {
        VStack(spacing: 14) {
            ForEach(session.filteredIdentityEntries) { entry in
                batchAwareButton(id: entry.id, kind: .identity) {
                    batchSelectableCard(id: entry.id) {
                        AndroidIdentityListCard(entry: entry)
                    }
                }
            }
            if session.filteredIdentityEntries.isEmpty {
                emptyList(String(localized: "没有匹配的证件"), icon: "person.text.rectangle")
            }
            deletedIdentityRows
        }
    }


    /// issue #28：回收站保留策略、到期预览与永久清理入口。
    private var trashMaintenanceCard: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.7), cornerRadius: 20) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    AndroidParityIconTile(systemImage: "trash.slash.fill", fill: AndroidParityPalette.primaryContainer)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("回收站自动清理")
                            .font(.subheadline.weight(.semibold))
                        Text(trashMaintenanceSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Menu {
                        ForEach(TrashRetentionPolicy.allCases) { policy in
                            Button {
                                session.setTrashRetentionPolicy(policy)
                            } label: {
                                if policy == session.trashRetentionPolicy {
                                    Label(policy.displayName, systemImage: "checkmark")
                                } else {
                                    Text(policy.displayName)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(session.trashRetentionPolicy.displayName)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                        }
                        .font(.footnote.weight(.semibold))
                    }
                }

                if !session.trashRetentionPolicy.isAutomaticPurgeEnabled {
                    Text("自动清理未开启；选择保留天数后，到期条目才会被自动清理。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("删除后无法恢复；清理只影响已标记删除的条目，不会动正常条目。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let message = session.trashMaintenanceMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button(
                        String(
                            format: String(localized: "立即清理已到期（%d）"),
                            session.trashPreviewExpiredCount
                        )
                    ) {
                        isTrashPurgeConfirmationPresented = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(session.trashPreviewExpiredCount == 0)

                    Button("清空回收站", role: .destructive) {
                        isEmptyTrashConfirmationPresented = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(session.trashPreviewTotalCount == 0)
                }
            }
        }
        .confirmationDialog(
            String(
                format: String(localized: "确定永久清理 %d 项已到期条目吗？此操作无法撤销。"),
                session.trashPreviewExpiredCount
            ),
            isPresented: $isTrashPurgeConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("永久清理", role: .destructive) {
                do {
                    _ = try session.purgeExpiredTrashItems()
                } catch {
                    session.entryOperationState = .failed(error.localizedDescription)
                }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            String(
                format: String(localized: "确定要清空回收站吗？%d 项将被永久删除，无法撤销。"),
                session.trashPreviewTotalCount
            ),
            isPresented: $isEmptyTrashConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("清空回收站", role: .destructive) {
                do {
                    _ = try session.emptyTrashNow()
                } catch {
                    session.entryOperationState = .failed(error.localizedDescription)
                }
            }
            Button("取消", role: .cancel) {}
        }
        .onAppear {
            session.refreshTrashMaintenancePreview()
        }
    }

    private var trashMaintenanceSubtitle: String {
        if session.trashRetentionPolicy.isAutomaticPurgeEnabled {
            return String(
                format: String(localized: "共 %d 项，按当前策略 %d 项已到期"),
                session.trashPreviewTotalCount,
                session.trashPreviewExpiredCount
            )
        }
        return String(
            format: String(localized: "自动清理未开启，共 %d 项"),
            session.trashPreviewTotalCount
        )
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

    @ViewBuilder private var deletedBillingAddressRows: some View {
        if !session.deletedBillingAddressEntries.isEmpty {
            restoreSection("已删除账单地址") {
                ForEach(session.deletedBillingAddressEntries) { entry in
                    restoreButton(id: entry.id, kind: .billingAddress, title: entry.title, subtitle: entry.addressSummary) {
                        restoreBillingAddressEntry(entry)
                    }
                }
            }
        }
    }

    @ViewBuilder private var deletedPaymentAccountRows: some View {
        if !session.deletedPaymentAccountEntries.isEmpty {
            restoreSection("已删除支付账户") {
                ForEach(session.deletedPaymentAccountEntries) { entry in
                    restoreButton(id: entry.id, kind: .paymentAccount, title: entry.title, subtitle: entry.kind.displayName) {
                        restorePaymentAccountEntry(entry)
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

    @ViewBuilder private var deletedGPGKeyRows: some View {
        if !session.deletedGPGKeyEntries.isEmpty {
            restoreSection(String(localized: "已删除 GPG 密钥")) {
                ForEach(session.deletedGPGKeyEntries) { entry in
                    restoreButton(
                        id: entry.id,
                        kind: .gpgKey,
                        title: entry.title,
                        subtitle: entry.keyID
                    ) {
                        restoreGPGKeyEntry(entry)
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

    @ViewBuilder private var deletedSSORows: some View {
        if !session.deletedSSOEntries.isEmpty {
            restoreSection("已删除 SSO") {
                ForEach(session.deletedSSOEntries) { entry in
                    restoreButton(id: entry.id, kind: .sso, title: entry.title, subtitle: entry.displayProviderName) {
                        try? session.restoreSSOEntry(entry)
                    }
                }
            }
        }
    }

    @ViewBuilder private var deletedBarcodeRows: some View {
        if !session.deletedBarcodeEntries.isEmpty {
            restoreSection("已删除条码") {
                ForEach(session.deletedBarcodeEntries) { entry in
                    restoreButton(id: entry.id, kind: .barcode, title: entry.title, subtitle: entry.displaySubtitle) {
                        restoreBarcodeEntry(entry)
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

    @ViewBuilder
    private var sectionBarContent: some View {
        if isPasswordRoot {
            passwordSectionBar
        } else if baseItemKind == .totp {
            totpSectionBar
        }
    }

    /// 验证 Tab 的二级模块入口：验证码与 Steam Guard。
    @ViewBuilder
    private var totpSectionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("验证模块", selection: $session.totpModule) {
                ForEach(TotpModule.allCases) { module in
                    Text(module.title).tag(module)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("验证模块")

            Button(action: refreshExtendedParityEntries) {
                Label("刷新", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.heavy))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 40)
                    .background(AndroidParityPalette.primaryContainer, in: Capsule(style: .continuous))
                    .foregroundStyle(AndroidParityPalette.textPrimary)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var passwordSectionBar: some View {
        if isPasswordRoot {
            VStack(alignment: .leading, spacing: 10) {
                Picker("密码模块", selection: $session.passwordModule) {
                    ForEach(session.passwordModuleBarModules) { module in
                        Text(module.title).tag(module)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("密码模块")

                // 生成器作为可见的二级模块时，以胶囊入口出现在模块栏（#63）；
                // 默认隐藏，此时 UI 与 #77 的分段控件完全一致。
                // 「自动填充说明」是密码页固定可见的入口（#39），解释 iOS 的公开 API 边界。
                HStack(spacing: 10) {
                    if !session.vaultLayoutPreferences.isHidden(.generator) {
                        Button {
                            isGeneratorPresented = true
                        } label: {
                            Label(
                                PasswordLayoutModule.generator.title,
                                systemImage: PasswordLayoutModule.generator.systemImage
                            )
                            .font(.subheadline.weight(.heavy))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(
                                AndroidParityPalette.primaryContainer,
                                in: Capsule(style: .continuous)
                            )
                            .foregroundStyle(AndroidParityPalette.textPrimary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(PasswordLayoutModule.generator.title)
                    }

                    Button {
                        isAutoFillGuidePresented = true
                    } label: {
                        Label("自动填充说明", systemImage: "questionmark.circle")
                            .font(.subheadline.weight(.heavy))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(
                                AndroidParityPalette.surfaceVariant,
                                in: Capsule(style: .continuous)
                            )
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("系统自动填充说明")
                }

                if session.passwordModule == .other {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(PasswordModule.otherKinds, id: \.self) { kind in
                                Button {
                                    session.passwordOtherKind = kind
                                } label: {
                                    Text(kind.localizedDisplayName)
                                        .font(.subheadline.weight(.heavy))
                                        .padding(.horizontal, 14)
                                        .frame(minHeight: 44)
                                        .background(
                                            session.passwordOtherKind == kind
                                                ? AndroidParityPalette.primaryContainer
                                                : AndroidParityPalette.surfaceVariant,
                                            in: Capsule(style: .continuous)
                                        )
                                        .foregroundStyle(
                                            session.passwordOtherKind == kind
                                                ? AndroidParityPalette.textPrimary
                                                : AndroidParityPalette.textSecondary
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                            Button(action: refreshExtendedParityEntries) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.subheadline.weight(.heavy))
                                    .frame(minWidth: 44, minHeight: 44)
                                    .background(AndroidParityPalette.surfaceVariant, in: Circle())
                                    .foregroundStyle(AndroidParityPalette.textSecondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("刷新扩展条目")
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private var largeTitle: String {
        itemKind == .passkey ? String(localized: "通行密钥") : (session.activeVaultName ?? "Monica")
    }

    private var presentedEditorBinding: Binding<Bool> {
        Binding(
            get: { session.presentedEditorMode != nil },
            set: { isPresented in
                if !isPresented { session.dismissPresentedEditorSavingNoteDraft() }
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

    private var presentedDetailBinding: Binding<Bool> {
        Binding(
            get: { session.presentedDetailRoute != nil && !session.isGlobalSearchPresented },
            set: { isPresented in
                if !isPresented {
                    session.dismissDetail()
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
                case .gpgKey: return session.gpgKeySearchQuery
                case .apiToken: return session.apiTokenSearchQuery
                case .wifi: return session.wifiSearchQuery
                case .sso: return session.ssoSearchQuery
                case .barcode: return session.barcodeSearchQuery
                case .send: return session.sendSearchQuery
                case .steam: return session.steamSearchQuery
                case .billingAddress: return session.billingAddressSearchQuery
                case .paymentAccount: return session.paymentAccountSearchQuery
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
                case .gpgKey: session.gpgKeySearchQuery = value
                case .apiToken: session.apiTokenSearchQuery = value
                case .wifi: session.wifiSearchQuery = value
                case .sso: session.ssoSearchQuery = value
                case .barcode: session.barcodeSearchQuery = value
                case .send: session.sendSearchQuery = value
                case .steam: session.steamSearchQuery = value
                case .billingAddress: session.billingAddressSearchQuery = value
                case .paymentAccount: session.paymentAccountSearchQuery = value
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
                case .gpgKey: return session.showFavoriteGPGKeyEntriesOnly
                case .apiToken: return session.showFavoriteApiTokenEntriesOnly
                case .wifi: return session.showFavoriteWifiEntriesOnly
                case .sso: return session.showFavoriteSSOEntriesOnly
                case .barcode: return session.showFavoriteBarcodeEntriesOnly
                case .send: return session.showFavoriteSendEntriesOnly
                case .steam: return session.showFavoriteSteamEntriesOnly
                case .billingAddress: return session.showFavoriteBillingAddressEntriesOnly
                case .paymentAccount: return session.showFavoritePaymentAccountEntriesOnly
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
                case .gpgKey: session.showFavoriteGPGKeyEntriesOnly = value
                case .apiToken: session.showFavoriteApiTokenEntriesOnly = value
                case .wifi: session.showFavoriteWifiEntriesOnly = value
                case .sso: session.showFavoriteSSOEntriesOnly = value
                case .barcode: session.showFavoriteBarcodeEntriesOnly = value
                case .send: session.showFavoriteSendEntriesOnly = value
                case .steam: session.showFavoriteSteamEntriesOnly = value
                case .billingAddress: session.showFavoriteBillingAddressEntriesOnly = value
                case .paymentAccount: session.showFavoritePaymentAccountEntriesOnly = value
                case .attachmentRef: break
                }
            }
        )
    }

    private var batchActionKind: UnifiedVaultItemKind {
        session.activeVaultBatchSelectionKind ?? itemKind
    }

    private var categoryBar: some View {
        VaultFolderNavigator(session: session)
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
                            .frame(minWidth: 44, minHeight: 44)
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
                            .frame(minWidth: 44, minHeight: 44)
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
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(session.isTrashQuickFilterSelected ? AndroidParityPalette.primary : .red)
                    .disabled(session.isTrashQuickFilterSelected ? !session.canRestoreSelectedVaultBatchItems : !session.canDeleteSelectedVaultBatchItems)
                    Button {
                        session.clearVaultBatchSelection()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                } else {
                    Button {
                        session.enterVaultBatchSelection(for: itemKind)
                    } label: {
                        Image(systemName: "checkmark.circle")
                            .frame(minWidth: 44, minHeight: 44)
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
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        Button {
            if session.isVaultBatchSelectionActive {
                session.toggleVaultBatchItemSelection(id, for: kind)
            } else {
                session.presentDetail(kind: kind, entryID: id)
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
                    .font(AndroidParityTypography.controlIcon(weight: .heavy))
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
                try await session.savePresentedEditorWithBitwardenFileSend(projectTitle: session.activeVaultName ?? String(localized: "个人"))
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
        case .gpgKey: setSelectedGPGKeyFavorite(favorite)
        case .apiToken: setSelectedApiTokenFavorite(favorite)
        case .wifi: setSelectedWifiFavorite(favorite)
        case .sso: try? session.setSelectedSSOFavorite(favorite)
        case .barcode: setSelectedBarcodeFavorite(favorite)
        case .send: setSelectedSendFavorite(favorite)
        case .steam: try? session.setSelectedSteamFavorite(favorite)
        case .billingAddress: setSelectedBillingAddressFavorite(favorite)
        case .paymentAccount: setSelectedPaymentAccountFavorite(favorite)
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
        case .gpgKey: deleteGPGKeyEntry()
        case .apiToken: deleteApiTokenEntry()
        case .wifi: deleteWifiEntry()
        case .sso: try? session.deleteSelectedSSOEntry()
        case .barcode: deleteBarcodeEntry()
        case .send: deleteSendEntry()
        case .steam: try? session.deleteSelectedSteamEntry()
        case .billingAddress: deleteBillingAddressEntry()
        case .paymentAccount: deletePaymentAccountEntry()
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
        let sizeText = String(localized: "\(entry.storedSize)/\(entry.originalSize) 字节")
        return [
            entry.downloadState.isEmpty ? String(localized: "未知状态") : entry.downloadState,
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
                            .font(AndroidParityTypography.controlIcon(weight: .bold))
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }
                }
            }
            .buttonStyle(.plain)
        } else {
            AndroidParityEntryCard(icon: "arrow.uturn.backward", title: title, subtitle: subtitle) {
                Button(action: action) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(AndroidParityTypography.controlIcon(weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(AndroidParityPalette.primary)
            }
        }
    }

}

struct AndroidParityModuleChrome<SectionBar: View, CategoryBar: View, TagBar: View, BatchBar: View, Content: View>: View {
    let title: String
    @Binding var selectedAction: AndroidParityToolbarAction?
    @Binding var searchText: String
    @Binding var favoritesOnly: Bool
    @Binding var stackedGroupMode: Bool
    let showsStackedGroupModeToggle: Bool
    let quickFilterRows: [AppVaultQuickFilterRow]
    @ViewBuilder var sectionBar: SectionBar
    @ViewBuilder var categoryBar: CategoryBar
    @ViewBuilder var tagBar: TagBar
    let onQuickFilter: (String) -> Void
    let onOpenVault: () -> Void
    let onAdd: () -> Void
    let onAddKind: (UnifiedVaultItemKind) -> Void
    let addMenuKinds: [UnifiedVaultItemKind]
    let showsMoreMenu: Bool
    let moreMenuModules: [PasswordLayoutModule]
    let onSelectMoreModule: (PasswordLayoutModule) -> Void
    /// 为 nil 时（例如锁库状态）不展示全局搜索入口。
    var onOpenGlobalSearch: (() -> Void)? = nil
    @ViewBuilder var batchBar: BatchBar
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    header
                    globalSearchEntry
                    sectionBar
                    categoryBar
                    quickFilterStrip
                    tagBar
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
            .appScrollEdgeEffectBottom()

            if addMenuKinds.isEmpty {
                Button(action: onAdd) {
                    fabLabel
                }
                .buttonStyle(.plain)
                .accessibilityLabel("添加")
                .padding(.trailing, 18)
                .padding(.bottom, 26)
            } else {
                Menu {
                    ForEach(addMenuKinds, id: \.self) { kind in
                        Button(kind.localizedDisplayName) {
                            onAddKind(kind)
                        }
                    }
                } label: {
                    fabLabel
                }
                .buttonStyle(.plain)
                .accessibilityLabel("添加")
                .padding(.trailing, 18)
                .padding(.bottom, 26)
            }
        }
    }

    private var fabLabel: some View {
        Image(systemName: "plus")
            .font(AndroidParityTypography.controlIcon(weight: .medium))
            .foregroundStyle(AndroidParityPalette.textPrimary)
            .frame(minWidth: 54, minHeight: 54)
            .appFloatingControlSurface(
                fill: AndroidParityPalette.primaryContainer,
                outline: AndroidParityPalette.outline,
                shape: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title)
                .font(AndroidParityTypography.displayTitle(weight: .heavy))
                .foregroundStyle(AndroidParityPalette.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 22) {
                toolbarButton(.folder, icon: "folder.fill", action: onOpenVault)
                    .accessibilityLabel("打开保险库")
                toolbarButton(.search, icon: "magnifyingglass")
                    .accessibilityLabel("搜索")
                if showsMoreMenu, !moreMenuModules.isEmpty {
                    Menu {
                        ForEach(moreMenuModules) { module in
                            Button {
                                onSelectMoreModule(module)
                            } label: {
                                Label(module.title, systemImage: module.systemImage)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(AndroidParityTypography.controlIcon(weight: .heavy))
                            .foregroundStyle(AndroidParityPalette.textPrimary.opacity(0.82))
                            .frame(minWidth: AppInterfaceDensity.minimumTouchTarget, minHeight: 50)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("更多")
                }
            }
            .padding(.horizontal, 24)
            .frame(minHeight: 64)
            .appFloatingControlSurface(
                fill: AndroidParityPalette.surfaceVariant,
                outline: AndroidParityPalette.outline,
                shape: Capsule(style: .continuous)
            )
        }
    }

    @ViewBuilder
    private var globalSearchEntry: some View {
        if let onOpenGlobalSearch {
            Button(action: onOpenGlobalSearch) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(AndroidParityPalette.primary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("全局搜索")
                            .font(.subheadline.weight(.heavy))
                            .foregroundStyle(AndroidParityPalette.textPrimary)
                        Text("密码、笔记、卡片、验证码")
                            .font(.caption)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    AndroidParityPalette.surfaceVariant.opacity(0.56),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("global-search-entry")
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
                        .frame(minHeight: 52)
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
                .font(AndroidParityTypography.controlIcon(weight: .heavy))
                .foregroundStyle(AndroidParityPalette.textPrimary.opacity(selectedAction == action ? 1 : 0.82))
                .frame(minWidth: AppInterfaceDensity.minimumTouchTarget, minHeight: 50)
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
                        systemImage: loginIconSymbol(for: entry),
                        fill: appearancePreferences.passwordListIconFill,
                        tint: appearancePreferences.passwordListIconTint
                    )
                }
                VStack(alignment: .leading, spacing: displayPreferences.cardDensity.verticalSpacing) {
                    Text(entry.title.isEmpty ? String(localized: "未命名") : entry.title)
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
                    .font(displayPreferences.cardDensity.iconFont)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }
    }

    /// 存储的是稳定资源 ID；解析失败（未知 / 损坏）时回退到登录条目的默认符号。
    private func loginIconSymbol(for entry: LocalLoginEntry) -> String {
        AppItemIconResolver.symbol(storedValue: entry.icon)
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
                            .frame(minHeight: 24)
                            .background(AndroidParityPalette.primaryContainer, in: Capsule(style: .continuous))
                    }
                    Text(group.preview.isEmpty ? String(localized: "未命名条目") : group.preview)
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
    let iconSystemName: String
    let haptics: AppHaptics

    private var isCounterBased: Bool {
        OtpType(storageValue: entry.otpType) == .hotp
    }

    var body: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.78), cornerRadius: 22) {
            HStack(alignment: .center, spacing: 18) {
                AndroidParityIconTile(systemImage: iconSystemName, fill: AndroidParityPalette.primaryContainer)
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.title.isEmpty ? entry.issuer : entry.title)
                        .font(.subheadline.weight(.semibold))
                    Text([entry.issuer, entry.accountName].filter { !$0.isEmpty }.joined(separator: " / "))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                    if isCounterBased {
                        Text(String(localized: "计数器 #\(entry.counter) · 确认使用后前进"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    } else {
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
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text(code)
                        .font(AndroidParityTypography.prominentTitle(weight: .heavy))
                        .foregroundStyle(AndroidParityPalette.primary)
                    Text(isCounterBased ? String(localized: "按需生成") : "\(remaining)s")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.primary)
                }
            }
        }
        // 每个新周期轻震一次；关闭总开关或子开关后由 AppHaptics 统一拦截。
        .onChange(of: code) { _, _ in
            guard !isCounterBased else { return }
            haptics.play(.verificationTick)
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
                .font(AndroidParityTypography.prominentTitle(weight: .heavy))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("持卡人")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.onPrimaryDeep.opacity(0.8))
                    Text(entry.cardholderName.isEmpty ? "-" : entry.cardholderName)
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text("有效期")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.onPrimaryDeep.opacity(0.8))
                    Text("\(entry.expiryMonth)/\(entry.expiryYear)")
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AndroidParityPalette.primaryDeep, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .foregroundStyle(AndroidParityPalette.onPrimaryDeep)
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
    let previewBody: String

    var body: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.78), cornerRadius: 22) {
            HStack(alignment: .top, spacing: 18) {
                AndroidParityIconTile(systemImage: "doc.text.fill", fill: AndroidParityPalette.primaryContainer)
                VStack(alignment: .leading, spacing: 12) {
                    Text(entry.title.isEmpty ? String(localized: "未命名") : entry.title)
                        .font(.subheadline.weight(.semibold))
                    Text(previewBody)
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
            secondary: entry.hidden ? String(localized: "\(entry.securityType) / 隐藏网络") : entry.securityType,
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
            primary: entry.expiresAt.isEmpty ? String(localized: "不过期") : entry.expiresAt,
            secondary: String(localized: "最多查看 \(entry.maxViews) 次"),
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
                    Text(entry.fileName.isEmpty ? String(localized: "未命名附件") : entry.fileName)
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
                                    .font(AndroidParityTypography.controlIcon(weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AndroidParityPalette.primary)
                        }

                        Button(action: preview) {
                            Image(systemName: "eye")
                                .font(AndroidParityTypography.controlIcon(weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AndroidParityPalette.primary)

                        Button(role: .destructive, action: delete) {
                            Image(systemName: "trash")
                                .font(AndroidParityTypography.controlIcon(weight: .bold))
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
            entry.mediaType.isEmpty ? String(localized: "未知类型") : entry.mediaType,
            entry.downloadState.isEmpty ? String(localized: "未知状态") : entry.downloadState
        ]
            .joined(separator: " / ")
    }

    private var secondaryText: String {
        let sizeText = String(localized: "\(entry.storedSize)/\(entry.originalSize) 字节")
        return [
            entry.storageMode,
            sizeText
        ]
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
    }
}

struct AndroidExtendedSecretListCard: View {
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
                    Text(title.isEmpty ? String(localized: "未命名") : title)
                        .font(.subheadline.weight(.semibold))
                    Text(primary.isEmpty ? String(localized: "未填写") : primary)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                    Text(secondary.isEmpty ? String(localized: "无备注") : secondary)
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
    @State private var isBarcodeScannerPresented = false
    @State private var isSendFileImporterPresented = false
    @State private var isAttachmentImporterPresented = false
    @State private var sendLinkCopyFeedback: String?
    @State private var isIconPickerPresented = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    storageBanner
                    formCard
                    if mode.kind == .identity, !mode.isAdding, let entryID = currentEntryID {
                        IdentityDocumentPhotoSection(
                            session: session,
                            entryID: entryID,
                            allowsEditing: true,
                            masksPhotos: false
                        )
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 120)
            }
            .background(AndroidParityPalette.background.ignoresSafeArea())
            Button(action: save) {
                Image(systemName: "checkmark")
                    .font(AndroidParityTypography.controlIcon(weight: .heavy))
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
        .sheet(isPresented: $isBarcodeScannerPresented) {
            BarcodeScannerSheet(
                onCode: { value, symbology in
                    applyScannedBarcode(value, symbology: symbology)
                },
                onCancel: { isBarcodeScannerPresented = false }
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
        .fileImporter(
            isPresented: $isAttachmentImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard case .success(let urls) = result, let url = urls.first else {
                    return
                }
                _ = try session.addLocalAttachmentContent(entryID: currentEntryID, fileURL: url)
            } catch {
                session.entryOperationState = .failed(error.localizedDescription)
            }
        }
        .task {
            session.loadPresentedItemExtras()
        }
    }

    private var header: some View {
        HStack(spacing: 18) {
            Button(action: dismiss) {
                Image(systemName: "chevron.left")
                    .font(AndroidParityTypography.controlIcon(weight: .heavy))
                    .frame(minWidth: AppInterfaceDensity.minimumTouchTarget, minHeight: AppInterfaceDensity.minimumTouchTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AndroidParityPalette.textPrimary)
            Text(mode.isAdding ? String(localized: "添加\(mode.kind.localizedDisplayName)") : String(localized: "编辑\(mode.kind.localizedDisplayName)"))
                .font(AndroidParityTypography.prominentTitle(weight: .heavy))
                .foregroundStyle(AndroidParityPalette.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
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
        .frame(minHeight: 56)
        .background(AndroidParityPalette.primaryContainer, in: Capsule(style: .continuous))
    }

    @ViewBuilder
    private var favoriteButton: some View {
        Button { setFavorite(!currentFavorite) } label: {
            Image(systemName: currentFavorite ? "heart.fill" : "heart")
                .font(AndroidParityTypography.controlIcon(weight: .heavy))
                .frame(minWidth: 50, minHeight: 50)
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
                    .foregroundStyle(AndroidParityPalette.onPrimaryDeep.opacity(0.86))
            }
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.subheadline.weight(.semibold))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(AndroidParityPalette.onPrimaryDeep)
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
            case .gpgKey: GPGKeyEntryEditorFields(session: session, isAdding: mode.isAdding)
            case .apiToken: apiTokenFields
            case .wifi: wifiFields
            case .sso: SSOEntryEditorFields(session: session, isAdding: mode.isAdding)
            case .barcode: barcodeFields
            case .send: sendFields
            case .steam: SteamEntryEditorFields(session: session, isAdding: mode.isAdding)
            case .billingAddress:
                BillingAddressEditorFields(session: session, isAdding: mode.isAdding)
            case .paymentAccount:
                PaymentAccountEditorFields(session: session, isAdding: mode.isAdding)
            case .attachmentRef:
                Text("该类型当前只支持列表展示。")
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
            attachmentEditSection
            if mode.kind != .attachmentRef {
                VaultItemExtrasEditorSection(session: session, itemKind: mode.kind)
            }
            AndroidParityInfoRow(title: String(localized: "状态"), value: session.entryOperationState.label)
            if !mode.isAdding {
                Button(role: .destructive, action: deleteEntry) {
                    Label("删除", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .destructiveOutlined))
            }
        }
    }

    @ViewBuilder
    private var attachmentEditSection: some View {
        if !mode.isAdding && mode.kind != .attachmentRef {
            AndroidParityDivider()
            Text("附件")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.primary)
            // 附件编辑永久免费；Monica Plus 不再参与这里的可用性判断。
            Button {
                isAttachmentImporterPresented = true
            } label: {
                Label("添加附件", systemImage: "paperclip.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
            ForEach(session.attachmentEntries(for: currentEntryID)) { attachment in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "paperclip")
                        .foregroundStyle(AndroidParityPalette.primary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(attachment.fileName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text("\(attachment.downloadState) · \(attachment.storedSize) 字节")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }
                    Spacer()
                    Button {
                        try? session.presentAttachmentQuickLookPreview(attachment)
                    } label: {
                        Image(systemName: "eye")
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    Button(role: .destructive) {
                        try? session.deleteAttachmentEntry(attachment)
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                }
            }
            if nonIdentityPhotoAttachments.isEmpty {
                Text("暂无附件")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }
    }

    private var currentEntryID: String? {
        guard case .edit(let route) = mode else {
            return nil
        }
        return route.entryID
    }

    /// 证件正反面照片由专用区块管理，避免在通用附件列表里重复出现。
    private var nonIdentityPhotoAttachments: [LocalAttachmentMetadata] {
        session.attachmentEntries(for: currentEntryID).filter { attachment in
            !IdentityDocumentPhotoSide.allCases.contains { attachment.fileName.hasPrefix($0.fileNamePrefix) }
        }
    }

    private var loginIconBinding: Binding<String?> {
        mode.isAdding ? $session.loginIcon : $session.editingLoginIcon
    }

    private var loginIconSymbol: String {
        AppItemIconResolver.symbol(storedValue: loginIconBinding.wrappedValue)
    }

    private var loginIconLabel: String {
        guard let stored = loginIconBinding.wrappedValue,
              let icon = ItemIcon(storageValue: stored) else {
            return String(localized: "默认图标")
        }
        switch icon {
        case .catalog(let id):
            return ItemIconCatalog.entry(id: id)?.displayName ?? id
        case .symbol(let name):
            return name
        }
    }

    private var iconRow: some View {
        Button {
            isIconPickerPresented = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: loginIconSymbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.primary)
                    .frame(minWidth: 34)
                Text("条目图标")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                Spacer()
                Text(loginIconLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 58)
            .background(AndroidParityPalette.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(AndroidParityPalette.outline, lineWidth: 1.2) }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isIconPickerPresented) {
            AppItemIconPickerView(icon: loginIconBinding)
                .presentationDetents([.large])
        }
    }

    private var loginFields: some View {
        VStack(spacing: 18) {
            if mode.isAdding {
                // issue #127：新建登录条目时可以从常用账号模板填入空字段。
                AccountTemplatePrefillSection(session: session)
            }
            field(icon: "folder.fill", title: String(localized: "标题 *"), text: mode.isAdding ? $session.loginTitle : $session.editingLoginTitle)
            iconRow
            field(icon: "globe", title: String(localized: "网站/网址"), text: mode.isAdding ? $session.loginURL : $session.editingLoginURL)
            LoginAdditionalURLEditor(urls: mode.isAdding ? $session.loginAdditionalURLs : $session.editingLoginAdditionalURLs)
            LoginAppBindingEditor(
                appName: mode.isAdding ? $session.loginAppName : $session.editingLoginAppName,
                bundleID: mode.isAdding ? $session.loginAppBundleID : $session.editingLoginAppBundleID
            )
            field(
                icon: "person.fill",
                title: String(localized: "账号"),
                placeholder: mode.isAdding && !session.accountTemplateUsernamePrompt.isEmpty
                    ? session.accountTemplateUsernamePrompt
                    : nil,
                text: mode.isAdding ? $session.loginUsername : $session.editingLoginUsername
            )
            secureField(icon: "lock.fill", title: String(localized: "密码"), text: mode.isAdding ? $session.loginPassword : $session.editingLoginPassword)
            Button(action: mode.isAdding ? generateLoginPassword : generateSelectedLoginPassword) {
                Label("添加密码", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
            VStack(alignment: .leading, spacing: 6) {
                Text("备注")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                TextEditor(text: mode.isAdding ? $session.loginNotes : $session.editingLoginNotes)
                    .frame(minHeight: 120)
                    .padding(12)
                    .scrollContentBackground(.hidden)
                    .background(AndroidParityPalette.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 16).stroke(AndroidParityPalette.outline, lineWidth: 1) }
            }
        }
    }

    private var noteFields: some View {
        VStack(spacing: 18) {
            field(icon: "folder.fill", title: String(localized: "标题 *"), text: mode.isAdding ? $session.noteTitle : $session.editingNoteTitle)
            AppNoteMarkdownComposer(
                session: session,
                title: mode.isAdding ? $session.noteTitle : $session.editingNoteTitle,
                markdownBody: mode.isAdding ? $session.noteBody : $session.editingNoteBody,
                noteID: currentEntryID
            )
        }
    }

    private var totpFields: some View {
        VStack(spacing: 18) {
            field(icon: "folder.fill", title: String(localized: "标题 *"), text: mode.isAdding ? $session.totpTitle : $session.editingTotpTitle)
            secureField(icon: "key.fill", title: String(localized: "密钥"), text: mode.isAdding ? $session.totpSecret : $session.editingTotpSecret)
            field(icon: "building.2.fill", title: String(localized: "签发方"), text: mode.isAdding ? $session.totpIssuer : $session.editingTotpIssuer)
            field(icon: "person.fill", title: String(localized: "账号"), text: mode.isAdding ? $session.totpAccountName : $session.editingTotpAccountName)
            TotpAdvancedFieldsView(
                otpType: mode.isAdding ? $session.totpOtpType : $session.editingTotpOtpType,
                algorithm: mode.isAdding ? $session.totpAlgorithm : $session.editingTotpAlgorithm,
                digits: mode.isAdding ? $session.totpDigits : $session.editingTotpDigits,
                period: mode.isAdding ? $session.totpPeriod : $session.editingTotpPeriod,
                counter: mode.isAdding ? $session.totpCounter : $session.editingTotpCounter,
                iconName: mode.isAdding ? $session.totpIconName : $session.editingTotpIconName
            )
            Button { isTotpScannerPresented = true } label: {
                Label("扫描二维码", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
        }
    }

    private var cardFields: some View {
        VStack(spacing: 18) {
            field(icon: "folder.fill", title: String(localized: "标题 *"), text: mode.isAdding ? $session.cardTitle : $session.editingCardTitle)
            field(icon: "person.fill", title: String(localized: "持卡人"), text: mode.isAdding ? $session.cardholderName : $session.editingCardholderName)
            secureField(icon: "creditcard.fill", title: String(localized: "卡号"), text: mode.isAdding ? $session.cardNumber : $session.editingCardNumber)
            HStack(spacing: 14) {
                field(icon: "calendar", title: String(localized: "月"), text: mode.isAdding ? $session.cardExpiryMonth : $session.editingCardExpiryMonth)
                field(icon: "calendar", title: String(localized: "年"), text: mode.isAdding ? $session.cardExpiryYear : $session.editingCardExpiryYear)
            }
            secureField(icon: "lock.fill", title: "CVV", text: mode.isAdding ? $session.cardCVV : $session.editingCardCVV)
            field(icon: "building.columns.fill", title: String(localized: "银行"), text: mode.isAdding ? $session.cardIssuer : $session.editingCardIssuer)
            field(icon: "network", title: String(localized: "卡组织"), text: mode.isAdding ? $session.cardNetwork : $session.editingCardNetwork)
            BankCardFaceView(
                title: mode.isAdding ? session.cardTitle : session.editingCardTitle,
                cardholderName: mode.isAdding ? session.cardholderName : session.editingCardholderName,
                number: mode.isAdding ? session.cardNumber : session.editingCardNumber,
                expiryMonth: mode.isAdding ? session.cardExpiryMonth : session.editingCardExpiryMonth,
                expiryYear: mode.isAdding ? session.cardExpiryYear : session.editingCardExpiryYear,
                issuer: mode.isAdding ? session.cardIssuer : session.editingCardIssuer,
                network: mode.isAdding ? session.cardNetwork : session.editingCardNetwork,
                artwork: cardArtworkBinding.wrappedValue,
                masksNumber: true
            )
            .padding(.top, 2)
            field(icon: "number", title: "IBAN", text: mode.isAdding ? $session.cardIBAN : $session.editingCardIBAN)
            field(icon: "arrow.left.arrow.right", title: String(localized: "SWIFT 代码"), text: mode.isAdding ? $session.cardSwiftCode : $session.editingCardSwiftCode)
            field(icon: "mappin.and.ellipse", title: String(localized: "账单地址"), text: mode.isAdding ? $session.cardBillingAddress : $session.editingCardBillingAddress)
            HStack(spacing: 16) {
                Image(systemName: "paintpalette.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .frame(minWidth: 34)
                Text("卡面样式")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Picker("卡面样式", selection: cardArtworkBinding) {
                    ForEach(BankCardArtworkStyle.allCases) { style in
                        Text(style.localizedName).tag(style.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(AndroidParityPalette.primary)
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 58)
            .background(AndroidParityPalette.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(AndroidParityPalette.outline, lineWidth: 1.2) }
        }
    }

    private var cardArtworkBinding: Binding<String> {
        mode.isAdding ? $session.cardArtwork : $session.editingCardArtwork
    }

    private var identityFields: some View {
        VStack(spacing: 18) {
            field(icon: "folder.fill", title: String(localized: "标题 *"), text: mode.isAdding ? $session.identityTitle : $session.editingIdentityTitle)
            field(icon: "doc.text.fill", title: String(localized: "类型"), text: mode.isAdding ? $session.identityDocumentType : $session.editingIdentityDocumentType)
            field(icon: "person.fill", title: String(localized: "姓名"), text: mode.isAdding ? $session.identityFullName : $session.editingIdentityFullName)
            secureField(icon: "number", title: String(localized: "证件号"), text: mode.isAdding ? $session.identityDocumentNumber : $session.editingIdentityDocumentNumber)
            field(icon: "building.2.fill", title: String(localized: "签发方"), text: mode.isAdding ? $session.identityIssuer : $session.editingIdentityIssuer)
            field(icon: "globe", title: String(localized: "国家/地区"), text: mode.isAdding ? $session.identityCountry : $session.editingIdentityCountry)
            field(icon: "calendar", title: String(localized: "签发日期"), text: mode.isAdding ? $session.identityIssueDate : $session.editingIdentityIssueDate)
            field(icon: "calendar.badge.clock", title: String(localized: "有效期至"), text: mode.isAdding ? $session.identityExpiryDate : $session.editingIdentityExpiryDate)
            Text("日期格式 YYYY-MM-DD，可留空。")
                .font(.caption2)
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .padding(.horizontal, 4)
        }
    }

    private var passkeyFields: some View {
        VStack(spacing: 18) {
            field(icon: "folder.fill", title: String(localized: "标题 *"), text: mode.isAdding ? $session.passkeyTitle : $session.editingPasskeyTitle)
            field(icon: "globe", title: String(localized: "网站标识"), text: mode.isAdding ? $session.passkeyRelyingPartyID : $session.editingPasskeyRelyingPartyID)
            field(icon: "person.fill", title: String(localized: "账号"), text: mode.isAdding ? $session.passkeyUsername : $session.editingPasskeyUsername)
            field(icon: "key.horizontal.fill", title: String(localized: "通行密钥标识"), text: mode.isAdding ? $session.passkeyCredentialID : $session.editingPasskeyCredentialID)
            field(icon: "curlybraces", title: String(localized: "公钥数据"), text: mode.isAdding ? $session.passkeyPublicKeyCOSE : $session.editingPasskeyPublicKeyCOSE)
            secureField(icon: "lock.shield.fill", title: String(localized: "钥匙串引用"), text: mode.isAdding ? $session.passkeyPrivateKeyReference : $session.editingPasskeyPrivateKeyReference)
        }
    }

    private var sshKeyFields: some View {
        VStack(spacing: 18) {
            field(icon: "folder.fill", title: String(localized: "标题 *"), text: mode.isAdding ? $session.sshKeyTitle : $session.editingSshKeyTitle)
            field(icon: "person.fill", title: String(localized: "用户名"), text: mode.isAdding ? $session.sshKeyUsername : $session.editingSshKeyUsername)
            field(icon: "network", title: String(localized: "主机"), text: mode.isAdding ? $session.sshKeyHost : $session.editingSshKeyHost)
            field(icon: "key.fill", title: String(localized: "公钥"), text: mode.isAdding ? $session.sshKeyPublicKey : $session.editingSshKeyPublicKey)
            secureField(icon: "lock.shield.fill", title: String(localized: "私钥引用"), text: mode.isAdding ? $session.sshKeyPrivateKeyReference : $session.editingSshKeyPrivateKeyReference)
            field(icon: "text.bubble.fill", title: String(localized: "口令提示"), text: mode.isAdding ? $session.sshKeyPassphraseHint : $session.editingSshKeyPassphraseHint)
            field(icon: "note.text", title: String(localized: "备注"), text: mode.isAdding ? $session.sshKeyNotes : $session.editingSshKeyNotes)
        }
    }

    private var apiTokenFields: some View {
        VStack(spacing: 18) {
            field(icon: "folder.fill", title: String(localized: "标题 *"), text: mode.isAdding ? $session.apiTokenTitle : $session.editingApiTokenTitle)
            field(icon: "building.2.fill", title: String(localized: "签发方"), text: mode.isAdding ? $session.apiTokenIssuer : $session.editingApiTokenIssuer)
            field(icon: "person.fill", title: String(localized: "账号"), text: mode.isAdding ? $session.apiTokenAccountName : $session.editingApiTokenAccountName)
            secureField(icon: "text.badge.key", title: "Token", text: mode.isAdding ? $session.apiTokenToken : $session.editingApiTokenToken)
            field(icon: "scope", title: String(localized: "权限范围"), text: mode.isAdding ? $session.apiTokenScopes : $session.editingApiTokenScopes)
            field(icon: "calendar", title: String(localized: "过期时间"), text: mode.isAdding ? $session.apiTokenExpiresAt : $session.editingApiTokenExpiresAt)
            field(icon: "note.text", title: String(localized: "备注"), text: mode.isAdding ? $session.apiTokenNotes : $session.editingApiTokenNotes)
        }
    }

    private var wifiFields: some View {
        VStack(spacing: 18) {
            field(icon: "folder.fill", title: String(localized: "标题 *"), text: mode.isAdding ? $session.wifiTitle : $session.editingWifiTitle)
            field(icon: "wifi", title: "SSID", text: mode.isAdding ? $session.wifiSSID : $session.editingWifiSSID)
            field(icon: "lock.shield.fill", title: String(localized: "安全类型"), text: mode.isAdding ? $session.wifiSecurityType : $session.editingWifiSecurityType)
            secureField(icon: "lock.fill", title: String(localized: "密码"), text: mode.isAdding ? $session.wifiPassword : $session.editingWifiPassword)
            Toggle("隐藏网络", isOn: mode.isAdding ? $session.wifiHidden : $session.editingWifiHidden)
                .font(.subheadline.weight(.semibold))
                .tint(AndroidParityPalette.primary)
            field(icon: "note.text", title: String(localized: "备注"), text: mode.isAdding ? $session.wifiNotes : $session.editingWifiNotes)
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
                AndroidParityInfoRow(title: String(localized: "二维码内容"), value: session.editingWifiQRCodePayload)
                ShareLink(item: session.editingWifiQRCodePayload) {
                    Label("分享 Wi-Fi", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
            }
        }
    }

    private var barcodeFields: some View {
        BarcodeEditorFields(
            title: mode.isAdding ? $session.barcodeTitle : $session.editingBarcodeTitle,
            symbology: mode.isAdding ? $session.barcodeSymbology : $session.editingBarcodeSymbology,
            payload: mode.isAdding ? $session.barcodePayload : $session.editingBarcodePayload,
            label: mode.isAdding ? $session.barcodeLabel : $session.editingBarcodeLabel,
            notes: mode.isAdding ? $session.barcodeNotes : $session.editingBarcodeNotes,
            onScan: { isBarcodeScannerPresented = true }
        )
    }

    private func applyScannedBarcode(_ value: String, symbology: BarcodeSymbology) {
        if mode.isAdding {
            session.barcodeSymbology = symbology
            session.barcodePayload = value
        } else {
            session.editingBarcodeSymbology = symbology
            session.editingBarcodePayload = value
        }
        isBarcodeScannerPresented = false
    }

    private var sendFields: some View {
        VStack(spacing: 18) {
            field(icon: "folder.fill", title: String(localized: "标题 *"), text: mode.isAdding ? $session.sendTitle : $session.editingSendTitle)
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
                    Label(session.sendFileName.isEmpty ? String(localized: "选择文件") : session.sendFileName, systemImage: "paperclip")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                secureField(icon: "key.fill", title: String(localized: "访问密码"), text: $session.sendPassword)
                Toggle("隐藏邮箱", isOn: $session.sendHideEmail)
                    .font(.subheadline.weight(.semibold))
                    .tint(AndroidParityPalette.primary)
            } else {
                secureField(icon: "text.alignleft", title: String(localized: "内容"), text: mode.isAdding ? $session.sendBody : $session.editingSendBody)
            }
            field(icon: "calendar", title: String(localized: "过期时间"), text: mode.isAdding ? $session.sendExpiresAt : $session.editingSendExpiresAt)
            Stepper(value: mode.isAdding ? $session.sendMaxViews : $session.editingSendMaxViews, in: 1...999) {
                Text("最多查看 \(mode.isAdding ? session.sendMaxViews : session.editingSendMaxViews) 次")
                    .font(.subheadline.weight(.semibold))
            }
            .tint(AndroidParityPalette.primary)
            field(icon: "note.text", title: String(localized: "备注"), text: mode.isAdding ? $session.sendNotes : $session.editingSendNotes)
            if mode.isAdding, session.bitwardenAuthenticationState.isConnected {
                Text("将推送到 Bitwarden 并在创建后给出可分享链接")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
            if let shareLink = session.bitwardenSendShareLink, !shareLink.isEmpty {
                AndroidParityDivider()
                Text("分享链接")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.primary)
                Text(shareLink)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                Button {
                    sendLinkCopyFeedback = session.copySensitiveValueToPasteboard(shareLink).message
                } label: {
                    Label("复制链接", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                if let sendLinkCopyFeedback {
                    Text(sendLinkCopyFeedback)
                        .font(.caption2)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
                Text("链接包含解密密钥，只能通过安全渠道发送，且只显示这一次。")
                    .font(.caption2)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }
    }

    private func field(
        icon: String,
        title: String,
        placeholder: String? = nil,
        text: Binding<String>
    ) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .frame(minWidth: 34)
            TextField(placeholder ?? title, text: text)
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
                .frame(minWidth: 34)
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
        mode.kind == .login ? String(localized: "*** 密码") : mode.kind.localizedDisplayName
    }

    private var formTitle: String {
        switch mode.kind {
        case .login: return String(localized: "凭据")
        case .note: return String(localized: "笔记")
        case .totp: return String(localized: "验证器")
        case .card: return String(localized: "银行卡")
        case .identity: return String(localized: "证件")
        case .passkey: return String(localized: "通行密钥")
        case .billingAddress: return String(localized: "账单地址")
        case .paymentAccount: return String(localized: "支付账户")
        case .sshKey, .apiToken, .wifi, .gpgKey, .sso, .barcode, .send, .steam, .attachmentRef: return mode.kind.localizedDisplayName
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
        case .gpgKey: return session.editingGPGKeyFavorite
        case .apiToken: return session.editingApiTokenFavorite
        case .wifi: return session.editingWifiFavorite
        case .sso: return session.editingSSOFavorite
        case .barcode: return session.editingBarcodeFavorite
        case .send: return session.editingSendFavorite
        case .steam: return session.editingSteamFavorite
        case .billingAddress: return session.editingBillingAddressFavorite
        case .paymentAccount: return session.editingPaymentAccountFavorite
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
        case .gpgKey: return "key.horizontal.fill"
        case .apiToken: return "text.badge.key"
        case .wifi: return "wifi"
        case .sso: return "person.badge.key.fill"
        case .barcode: return "barcode.viewfinder"
        case .send: return "paperplane.fill"
        case .steam: return "shield.lefthalf.filled"
        case .billingAddress: return "house.fill"
        case .paymentAccount: return "wallet.pass.fill"
        case .attachmentRef: return "paperclip"
        }
    }
}

struct VaultItemDetailView: View {
    private struct CopyFeedback: Equatable {
        let rowID: String
        let message: String
    }

    @Bindable var session: AppSessionModel
    let route: VaultItemRoute
    @Environment(\.screenPrivacyMonitor) private var screenPrivacyMonitor
    @State private var copyFeedback: CopyFeedback?
    @State private var copyFeedbackDismissTask: Task<Void, Never>?
    @State private var historyOperationMessage: String?

    var body: some View {
        AndroidParityScreen {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.6), cornerRadius: 22) {
                HStack(spacing: 14) {
                    AndroidParityIconTile(systemImage: route.kind.systemImage, fill: AndroidParityPalette.primaryContainer)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(route.kind.localizedDisplayName)
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(AndroidParityPalette.primary)
                        Text(title)
                            .font(.title3.weight(.heavy))
                            .foregroundStyle(AndroidParityPalette.textPrimary)
                    }
                    Spacer()
                    Button {
                        session.editPresentedDetail()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.headline.weight(.bold))
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AndroidParityPalette.primary)
                    .disabled(route.kind == .attachmentRef)
                }
                Toggle("显示敏感字段", isOn: revealBinding)
                    .font(.subheadline.weight(.semibold))
                    .tint(AndroidParityPalette.primary)
                    .disabled(!session.canTemporarilyRevealSensitiveFieldsInDetail)
                    // 录制/共享期间强制掩码，用户无法临时打开；停止后开关回到用户原设置。
                    .disabled(isSceneCaptured)
                if !session.canTemporarilyRevealSensitiveFieldsInDetail {
                    Text("在「设置 › 敏感隐私」中允许显示后可用")
                        .font(.caption2)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
                if isSceneCaptured {
                    Label("录制或共享期间无法显示敏感字段", systemImage: "eye.slash")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
            }

            if route.kind == .steam,
               let steamEntry = session.steamEntries.first(where: { $0.id == route.entryID }) {
                SteamGuardCodePanel(session: session, entry: steamEntry)
            }

            if route.kind == .card,
               let entry = session.cardEntries.first(where: { $0.id == route.entryID }) {
                BankCardFaceView(
                    title: entry.title,
                    cardholderName: entry.cardholderName,
                    number: entry.number,
                    expiryMonth: entry.expiryMonth,
                    expiryYear: entry.expiryYear,
                    issuer: entry.issuer,
                    network: entry.network,
                    artwork: entry.cardArtwork,
                    masksNumber: masksSensitiveFields
                )
            }
            if route.kind == .barcode,
               let entry = session.barcodeEntries.first(where: { $0.id == route.entryID }) {
                AndroidParitySection(title: String(localized: "条码")) {
                    BarcodeDetailCodeCard(
                        payload: entry.payload,
                        symbology: entry.symbology,
                        isRevealed: session.isSensitivePreviewRevealed(entryID: route.entryID)
                    )
                }
            }

            AndroidParitySection(title: String(localized: "详情")) {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 12) {
                                AndroidParityInfoRow(title: row.title, value: row.value)
                                if let secret = copyableSecrets[row.id], !secret.isEmpty {
                                    let isCopied = copyFeedback?.rowID == row.id
                                    Button {
                                        copy(secret, rowID: row.id)
                                    } label: {
                                        Image(systemName: isCopied ? "checkmark.circle.fill" : "doc.on.doc")
                                            .font(.caption.weight(.bold))
                                            .frame(minWidth: 44, minHeight: 44)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(AndroidParityPalette.primary)
                                    .accessibilityLabel(Text("复制 \(row.title)"))
                                }
                            }
                            if let copyFeedback, copyFeedback.rowID == row.id {
                                Text(copyFeedback.message)
                                    .font(.caption2)
                                    .foregroundStyle(AndroidParityPalette.primary)
                                    .padding(.horizontal, 4)
                                    .transition(.opacity)
                                    .accessibilityLabel(Text(copyFeedback.message))
                            }
                        }
                        if row.id != rows.last?.id {
                            AndroidParityDivider()
                        }
                    }
                }
            }

            if route.kind == .identity {
                IdentityDocumentPhotoSection(
                    session: session,
                    entryID: route.entryID,
                    allowsEditing: false,
                    masksPhotos: masksSensitiveFields
                )
            }

            if let entry = loginEntry, !entry.passwordHistory.isEmpty {
                LoginPasswordHistorySection(
                    history: entry.passwordHistory,
                    canReveal: session.canTemporarilyRevealSensitiveFieldsInDetail,
                    onDelete: { historyEntryID in
                        Task { @MainActor in
                            do {
                                try session.deleteLoginPasswordHistoryEntry(
                                    entryID: route.entryID,
                                    historyEntryID: historyEntryID
                                )
                                historyOperationMessage = nil
                            } catch {
                                historyOperationMessage = error.localizedDescription
                            }
                        }
                    },
                    onClear: {
                        Task { @MainActor in
                            do {
                                try session.clearLoginPasswordHistory(entryID: route.entryID)
                                historyOperationMessage = nil
                            } catch {
                                historyOperationMessage = error.localizedDescription
                            }
                        }
                    }
                )
                if let historyOperationMessage {
                    Text(historyOperationMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 4)
                }
            }

            VaultItemExtrasDetailSection(
                customFields: session.presentedDetailExtras?.customFields ?? [],
                relations: session.resolvedPresentedDetailRelations()
            )
            if route.kind == .send,
               let entry = session.sendEntries.first(where: { $0.id == route.entryID }) {
                MonicaSendShareSection(session: session, entry: entry)
            }
            if route.kind == .sso,
               let entry = session.ssoEntries.first(where: { $0.id == route.entryID }) {
                SSOLoginLinkSection(session: session, entry: entry)
            }
            if route.kind == .totp {
                TotpDetailActionsView(
                    session: session,
                    entryID: route.entryID,
                    onFeedback: { message in
                        showCopyFeedback(rowID: route.entryID, message: message)
                    }
                )
            }
            if route.kind == .note,
               session.isSensitivePreviewRevealed(entryID: route.entryID),
               let note = session.noteEntries.first(where: { $0.id == route.entryID }) {
                AndroidParitySection(title: String(localized: "Markdown 预览")) {
                    AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                        AppNoteMarkdownPreview(
                            document: NoteMarkdownDocument.parse(note.body),
                            session: session
                        )
                    }
                }
            }

            VaultEntryTagsSection(session: session, entryID: route.entryID)
        }
        .onDisappear {
            copyFeedbackDismissTask?.cancel()
            copyFeedback = nil
            session.setSensitivePreviewRevealed(false, entryID: route.entryID)
        }
    }

    private var loginEntry: LocalLoginEntry? {
        guard route.kind == .login else { return nil }
        return session.loginEntries.first(where: { $0.id == route.entryID })
    }

    private func copy(_ secret: String, rowID: String) {
        let feedback = session.copySensitiveValueToPasteboard(secret)
        copyFeedbackDismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) {
            copyFeedback = CopyFeedback(rowID: rowID, message: feedback.message)
        }
        copyFeedbackDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                copyFeedback = nil
            }
        }
    }

    private func showCopyFeedback(rowID: String, message: String) {
        copyFeedbackDismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) {
            copyFeedback = CopyFeedback(rowID: rowID, message: message)
        }
        copyFeedbackDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                copyFeedback = nil
            }
        }
    }

    private var title: String {
        rows.first(where: { $0.id == "title" })?.value ?? route.kind.localizedDisplayName
    }

    private var rows: [AppExtensionCapabilityRow] {
        switch route.kind {
        case .login:
            guard let entry = session.loginEntries.first(where: { $0.id == route.entryID }) else { return missingRows }
            let urls = entry.effectiveURLs
            var items = [
                row("title", String(localized: "标题"), entry.title),
                row("username", String(localized: "账号"), entry.username)
            ]
            if urls.isEmpty {
                items.append(row("url", String(localized: "网址"), ""))
            } else {
                for (index, url) in urls.enumerated() {
                    items.append(
                        row(
                            index == 0 ? "url" : "url-\(index + 1)",
                            index == 0 ? String(localized: "网址") : String(localized: "网址") + " \(index + 2)",
                            redactedURL(url)
                        )
                    )
                }
            }
            items.append(row("password", String(localized: "密码"), sensitive(entry.password, .password)))
            items.append(row("appBinding", String(localized: "应用绑定"), appBinding(entry)))
            items.append(row("notes", String(localized: "备注"), sensitive(entry.notes, .noteBody)))
            items.append(row("favorite", String(localized: "收藏"), entry.favorite ? String(localized: "是") : String(localized: "否")))
            return items
        case .note:
            guard let entry = session.noteEntries.first(where: { $0.id == route.entryID }) else { return missingRows }
            return [row("title", String(localized: "标题"), entry.title), row("body", String(localized: "正文"), sensitive(entry.body, .noteBody)), row("favorite", String(localized: "收藏"), entry.favorite ? String(localized: "是") : String(localized: "否"))]
        case .totp:
            guard let entry = session.totpEntries.first(where: { $0.id == route.entryID }) else { return missingRows }
            var totpRows = [
                row("title", String(localized: "标题"), entry.title),
                row("issuer", String(localized: "签发方"), entry.issuer),
                row("account", String(localized: "账号"), entry.accountName),
                row("secret", String(localized: "密钥"), sensitive(entry.secret, .totp)),
                row("type", String(localized: "类型"), session.otpType(for: entry) == .hotp ? String(localized: "计数器验证码（HOTP）") : String(localized: "定时验证码（TOTP）")),
                row("algorithm", String(localized: "算法"), session.totpAlgorithm(from: entry.algorithm).rawValue),
                row("digits", String(localized: "位数"), String(entry.digits))
            ]
            if session.otpType(for: entry) == .hotp {
                totpRows.append(row("counter", String(localized: "计数器"), String(entry.counter)))
            } else {
                totpRows.append(row("period", String(localized: "周期"), "\(entry.period)s"))
            }
            return totpRows
        case .card:
            guard let entry = session.cardEntries.first(where: { $0.id == route.entryID }) else { return missingRows }
            return [
                row("title", String(localized: "标题"), entry.title),
                row("holder", String(localized: "持卡人"), entry.cardholderName),
                row("number", String(localized: "卡号"), sensitive(entry.number, .cardNumber)),
                row("expiry", String(localized: "有效期"), "\(entry.expiryMonth)/\(entry.expiryYear)"),
                row("cvv", "CVV", sensitive(entry.cvv, .cvv)),
                row("issuer", String(localized: "银行"), entry.issuer),
                row("network", String(localized: "卡组织"), entry.network),
                row("iban", "IBAN", sensitive(entry.iban, .otherSecret)),
                row("swift", String(localized: "SWIFT 代码"), entry.swiftCode),
                row("billing", String(localized: "账单地址"), sensitive(entry.billingAddress, .otherSecret))
            ]
        case .identity:
            guard let entry = session.identityEntries.first(where: { $0.id == route.entryID }) else { return missingRows }
            return [row("title", String(localized: "标题"), entry.title), row("type", String(localized: "类型"), entry.documentType), row("name", String(localized: "姓名"), entry.fullName), row("number", String(localized: "证件号"), sensitive(entry.documentNumber, .otherSecret)), row("issuer", String(localized: "签发方"), entry.issuer), row("country", String(localized: "国家/地区"), entry.country), row("issue", String(localized: "签发日期"), entry.issueDate), row("expiry", String(localized: "有效期至"), entry.expiryDate)]
        case .passkey:
            guard let entry = session.passkeyEntries.first(where: { $0.id == route.entryID }) else { return missingRows }
            return [row("title", String(localized: "标题"), entry.title), row("rp", String(localized: "网站标识"), entry.relyingPartyID), row("username", String(localized: "账号"), entry.username), row("credential", String(localized: "通行密钥标识"), sensitive(entry.credentialID, .otherSecret)), row("private", String(localized: "私钥引用"), sensitive(entry.privateKeyReference, .otherSecret))]
        case .sshKey:
            guard let entry = session.sshKeyEntries.first(where: { $0.id == route.entryID }) else { return missingRows }
            return [row("title", String(localized: "标题"), entry.title), row("user", String(localized: "用户名"), entry.username), row("host", String(localized: "主机"), entry.host), row("public", String(localized: "公钥"), sensitive(entry.publicKey, .otherSecret)), row("private", String(localized: "私钥引用"), sensitive(entry.privateKeyReference, .otherSecret)), row("hint", String(localized: "口令提示"), entry.passphraseHint)]
        case .gpgKey:
            return session.gpgKeyDetailRows(for: route.entryID)
        case .apiToken:
            guard let entry = session.apiTokenEntries.first(where: { $0.id == route.entryID }) else { return missingRows }
            return [row("title", String(localized: "标题"), entry.title), row("issuer", String(localized: "签发方"), entry.issuer), row("account", String(localized: "账号"), entry.accountName), row("token", "Token", sensitive(entry.token, .otherSecret)), row("scopes", String(localized: "范围"), entry.scopes), row("expires", String(localized: "过期"), entry.expiresAt)]
        case .sso:
            guard let entry = session.ssoEntries.first(where: { $0.id == route.entryID }) else { return missingRows }
            return session.ssoDetailRows(for: entry)
        case .wifi:
            guard let entry = session.wifiEntries.first(where: { $0.id == route.entryID }) else { return missingRows }
            return [row("title", String(localized: "标题"), entry.title), row("ssid", "SSID", entry.ssid), row("security", String(localized: "安全类型"), entry.securityType), row("password", String(localized: "密码"), sensitive(entry.password, .password)), row("hidden", String(localized: "隐藏网络"), entry.hidden ? String(localized: "是") : String(localized: "否"))]
        case .barcode:
            guard let entry = session.barcodeEntries.first(where: { $0.id == route.entryID }) else { return missingRows }
            return [
                row("title", String(localized: "标题"), entry.title),
                row("symbology", String(localized: "制式"), entry.symbology.displayName),
                row("payload", String(localized: "原始内容"), sensitive(entry.payload, .otherSecret)),
                row("label", String(localized: "显示标签"), entry.label),
                row("notes", String(localized: "备注"), entry.notes),
                row("favorite", String(localized: "收藏"), entry.favorite ? String(localized: "是") : String(localized: "否"))
            ]
        case .send:
            guard let entry = session.sendEntries.first(where: { $0.id == route.entryID }) else { return missingRows }
            return [row("title", String(localized: "标题"), entry.title), row("body", String(localized: "内容"), sensitive(entry.body, .noteBody)), row("expires", String(localized: "过期"), entry.expiresAt.isEmpty ? String(localized: "不过期") : entry.expiresAt), row("views", String(localized: "最多查看"), "\(entry.maxViews)")]
        case .steam:
            guard let entry = session.steamEntries.first(where: { $0.id == route.entryID }) else { return missingRows }
            return session.steamDetailRows(for: entry)
        case .billingAddress:
            guard let entry = session.billingAddressEntries.first(where: { $0.id == route.entryID }) else { return missingRows }
            return session.billingAddressDetailRows(for: entry)
        case .paymentAccount:
            guard let entry = session.paymentAccountEntries.first(where: { $0.id == route.entryID }) else { return missingRows }
            return session.paymentAccountDetailRows(for: entry)
        case .attachmentRef:
            guard let entry = session.attachmentEntries.first(where: { $0.id == route.entryID }) else { return missingRows }
            return [row("title", String(localized: "文件名"), entry.fileName), row("state", String(localized: "状态"), entry.downloadState), row("mode", String(localized: "存储"), entry.storageMode), row("size", String(localized: "大小"), String(localized: "\(entry.storedSize)/\(entry.originalSize) 字节"))]
        }
    }

    private var missingRows: [AppExtensionCapabilityRow] {
        [row("missing", String(localized: "状态"), String(localized: "条目不可用"))]
    }

    private var isSceneCaptured: Bool {
        screenPrivacyMonitor?.isSceneCaptured == true
    }

    /// 录制/共享期间一律掩码，压过用户在详情里的临时显示；停止后回落到 #58 的类别偏好。
    private var masksSensitiveFields: Bool {
        SensitiveFieldMaskingPolicy.isMasked(
            isSceneCaptured: isSceneCaptured,
            userRequestedReveal: session.isSensitivePreviewRevealed(entryID: route.entryID)
        )
    }

    private var revealBinding: Binding<Bool> {
        Binding(
            // 录制/共享期间开关显示为关闭且不可用；停止后回到用户原本的临时显示状态。
            get: { !isSceneCaptured && session.isSensitivePreviewRevealed(entryID: route.entryID) },
            set: { revealed in
                guard !isSceneCaptured else { return }
                session.setSensitivePreviewRevealed(revealed, entryID: route.entryID)
            }
        )
    }

    /// 只有被掩码的敏感行才给复制入口，复制内容仍走统一的剪贴板治理。
    private var copyableSecrets: [String: String] {
        switch route.kind {
        case .login:
            guard let entry = session.loginEntries.first(where: { $0.id == route.entryID }) else { return [:] }
            // 用户名、密码、备注都给复制入口；密码与备注在展示层仍是掩码，复制值来自 Vault 解锁后的内存数据。
            return ["username": entry.username, "password": entry.password, "notes": entry.notes]
        case .note:
            guard let entry = session.noteEntries.first(where: { $0.id == route.entryID }) else { return [:] }
            return ["body": entry.body]
        case .totp:
            guard let entry = session.totpEntries.first(where: { $0.id == route.entryID }) else { return [:] }
            return ["secret": entry.secret]
        case .card:
            guard let entry = session.cardEntries.first(where: { $0.id == route.entryID }) else { return [:] }
            return ["number": entry.number, "cvv": entry.cvv, "iban": entry.iban]
        case .identity:
            guard let entry = session.identityEntries.first(where: { $0.id == route.entryID }) else { return [:] }
            return ["number": entry.documentNumber]
        case .passkey:
            guard let entry = session.passkeyEntries.first(where: { $0.id == route.entryID }) else { return [:] }
            return ["credential": entry.credentialID, "private": entry.privateKeyReference]
        case .sshKey:
            guard let entry = session.sshKeyEntries.first(where: { $0.id == route.entryID }) else { return [:] }
            return ["public": entry.publicKey, "private": entry.privateKeyReference]
        case .gpgKey:
            return session.gpgKeyDetailSecrets(for: route.entryID)
        case .apiToken:
            guard let entry = session.apiTokenEntries.first(where: { $0.id == route.entryID }) else { return [:] }
            return ["token": entry.token]
        case .wifi:
            guard let entry = session.wifiEntries.first(where: { $0.id == route.entryID }) else { return [:] }
            return ["password": entry.password]
        case .sso:
            guard let entry = session.ssoEntries.first(where: { $0.id == route.entryID }) else { return [:] }
            return session.ssoDetailSecrets(for: entry)
        case .barcode:
            guard let entry = session.barcodeEntries.first(where: { $0.id == route.entryID }) else { return [:] }
            return ["payload": entry.payload]
        case .send:
            guard let entry = session.sendEntries.first(where: { $0.id == route.entryID }) else { return [:] }
            return ["body": entry.body]
        case .steam:
            guard let entry = session.steamEntries.first(where: { $0.id == route.entryID }) else { return [:] }
            return session.steamDetailSecrets(for: entry)
        case .billingAddress:
            guard let entry = session.billingAddressEntries.first(where: { $0.id == route.entryID }) else { return [:] }
            return session.billingAddressDetailSecrets(for: entry)
        case .paymentAccount:
            guard let entry = session.paymentAccountEntries.first(where: { $0.id == route.entryID }) else { return [:] }
            return session.paymentAccountDetailSecrets(for: entry)
        case .attachmentRef:
            return [:]
        }
    }

    private func sensitive(_ value: String, _ category: SensitivePreviewCategory) -> String {
        guard !value.isEmpty else { return String(localized: "空") }
        if masksSensitiveFields { return AppSessionModel.sensitivePreviewMaskPlaceholder }
        return session.sensitivePreviewValue(value, category: category, entryID: route.entryID)
    }

    private func appBinding(_ entry: LocalLoginEntry) -> String {
        let name = entry.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundle = entry.appBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (name.isEmpty, bundle.isEmpty) {
        case (true, true):
            return ""
        case (false, true):
            return name
        case (true, false):
            return bundle
        case (false, false):
            return "\(name)（\(bundle)）"
        }
    }

    private func redactedURL(_ value: String) -> String {
        guard !value.isEmpty else { return String(localized: "空") }
        guard let host = URL(string: value)?.host() else { return value }
        return host
    }

    private func row(_ id: String, _ title: String, _ value: String) -> AppExtensionCapabilityRow {
        AppExtensionCapabilityRow(
            id: id,
            title: title,
            value: value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "空") : value,
            detail: "",
            systemImage: ""
        )
    }
}
