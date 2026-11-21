import MonicaCore
import MonicaMDBX
import MonicaStorage
import Foundation
import Observation
import SwiftUI

// 旧 UserDefaults 密保记录由 MonicaSecurity 的 UserDefaultsLegacySecurityQuestionRecoveryStore
// 读取，并在首次验证成功后迁移进钥匙串（#59）。

struct AppRootView: View {
    let environment: MonicaAppEnvironment
    private let coreInfo = MonicaCoreInfo()
    private let mdbxInfo = MonicaMDBXBridgeInfo()
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: AppSessionModel

    /// A body-relative metric turns the user's Dynamic Type size into a spacing
    /// ratio (16pt at the default size). Combined with the chosen density it is
    /// injected into the shared `AndroidParity*` components so the whole layout —
    /// not just the text — responds to accessibility text sizes. No `scaleEffect`
    /// is applied to the root view: SwiftUI layout sizes stay truthful, so tap
    /// targets never drift away from their visual positions.
    @ScaledMetric(relativeTo: .body) private var paritySpacingBase: CGFloat = 16

    private var paritySpacingScale: CGFloat {
        let dynamicTypeRatio = paritySpacingBase / 16
        return dynamicTypeRatio * session.appearancePreferences.interfaceDensity.spacingScale
    }

    private var parityLineSpacingDelta: CGFloat {
        let dynamicTypeRatio = paritySpacingBase / 16
        return session.appearancePreferences.interfaceDensity.lineSpacingDelta * dynamicTypeRatio
    }

    init(environment: MonicaAppEnvironment) {
        self.environment = environment
        _session = State(initialValue: AppSessionModel.production(environment: environment))
    }

    var body: some View {
        ZStack {
            if session.vaultState == .locked {
                MonicaLockScreen(
                    session: session,
                    submitPassword: submitLockScreenPassword,
                    unlockWithKeychain: {
                        Task {
                            try? await session.unlockRememberedVaultWithKeychain(
                                deviceID: environment.localDeviceIdentifier,
                                fallbackDirectory: vaultDirectory
                            )
                            importPendingExtensionInboxItems()
                            session.maybePresentQuickSetupAfterUnlock()
                        }
                    },
                    createVault: createLocalVault,
                    openVault: openLocalVault,
                    forgotPassword: session.showForgotPasswordGuidance
                )
            } else {
                TabView(selection: $session.selectedTab) {
                    ForEach(MonicaAppTab.rootTabs, id: \.self) { tab in
                        tabContent(for: tab)
                            .tabItem {
                                if session.vaultDisplayPreferences.showsTabLabels {
                                    Label(tab.title, systemImage: tab.systemImage)
                                } else {
                                    Image(systemName: tab.systemImage)
                                }
                            }
                            .tag(tab)
                    }
                }
                .background(AndroidParityPalette.background.ignoresSafeArea())
            }

            if session.isPrivacyShieldVisible {
                PrivacyShieldView()
            }
        }
        .tint(session.appearancePreferences.swiftUIAccentColor)
        .preferredColorScheme(session.appearancePreferences.swiftUIColorScheme)
        .environment(\.paritySpacingScale, paritySpacingScale)
        .environment(\.parityLineSpacingDelta, parityLineSpacingDelta)
        .simultaneousGesture(
            TapGesture().onEnded {
                session.recordUserActivity()
            }
        )
        .onChange(of: scenePhase) { _, phase in
            session.handleScenePhaseChange(phase)
            if phase == .active {
                restoreOneDriveAuthenticationSessionIfAvailable()
                restoreBitwardenAuthenticationSessionIfAvailable()
                importPendingExtensionInboxItems()
                session.consumePendingControlNavigationIfAvailable()
            }
        }
        .onChange(of: session.vaultState) { _, state in
            if state == .unlocked {
                session.consumePendingControlNavigationIfAvailable()
                session.consumePendingControlPageIfUnlocked()
            }
        }
        .onChange(of: session.vaultState) { _, state in
            if state == .unlocked {
                session.continuePendingCredentialExchangeImportIfAvailable()
            }
        }
        .onOpenURL { url in
            if !session.handleOneDriveRedirectURL(url) {
                _ = session.openDeepLinkURL(url)
            }
        }
        .handlesCredentialExchangeActivity { activity in
            session.handleCredentialExchangeActivity(activity)
        }
        .onReceive(NotificationCenter.default.publisher(for: MonicaControlNavigationStore.didUpdateNotification)) { _ in
            session.consumePendingControlNavigationIfAvailable()
        }
        .task {
            restoreOneDriveAuthenticationSessionIfAvailable()
            restoreBitwardenAuthenticationSessionIfAvailable()
            importPendingExtensionInboxItems()
            session.consumePendingControlNavigationIfAvailable()
        }
        .sheet(isPresented: forgotPasswordSheetBinding) {
            ForgotPasswordRecoverySheet(
                session: session,
                deviceID: environment.localDeviceIdentifier
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $session.isQuickSetupPresented) {
            AppQuickSetupView(session: session)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $session.isExtensionsPresented) {
            AppExtensionsView(session: session)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: credentialExchangeImportSheetBinding) {
            CredentialExchangeImportSheet(session: session)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: credentialExchangeExportSheetBinding) {
            CredentialExchangeExportSheet(session: session)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert("无法导入凭据", isPresented: credentialExchangeImportAlertBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(session.credentialExchange.importError ?? "")
        }
    }

    private var credentialExchangeImportSheetBinding: Binding<Bool> {
        Binding {
            session.credentialExchange.importPreview != nil
        } set: { isPresented in
            if !isPresented {
                session.cancelCredentialExchangeImport()
            }
        }
    }

    private var credentialExchangeExportSheetBinding: Binding<Bool> {
        Binding {
            session.credentialExchange.exportPlan != nil
        } set: { isPresented in
            if !isPresented {
                session.cancelCredentialExchangeExport()
            }
        }
    }

    private var credentialExchangeImportAlertBinding: Binding<Bool> {
        Binding {
            session.credentialExchange.importError != nil
                && session.credentialExchange.importPreview == nil
                && !session.credentialExchange.isFetchingImport
        } set: { isPresented in
            if !isPresented {
                session.credentialExchange.importError = nil
            }
        }
    }

    private var forgotPasswordSheetBinding: Binding<Bool> {
        Binding {
            session.forgotPasswordRecoveryStep != .none
        } set: { isPresented in
            if !isPresented {
                session.dismissForgotPasswordRecovery()
            }
        }
    }

    private func restoreOneDriveAuthenticationSessionIfAvailable() {
        guard !session.oneDriveAuthenticationState.isRunning else {
            return
        }
        Task {
            try? await session.restoreOneDriveAuthenticationSession()
        }
    }

    private func restoreBitwardenAuthenticationSessionIfAvailable() {
        _ = try? session.restoreBitwardenAuthenticationSession()
    }

    private func importPendingAutoFillSaveRequests() {
        guard session.vaultState == .unlocked,
              let inboxStore = AppAutoFillCredentialSaveInboxStore()
        else {
            return
        }
        do {
            try session.importPendingAutoFillSaveRequests(
                inboxStore: inboxStore,
                projectTitle: session.activeVaultName ?? String(localized: "个人")
            )
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func importPendingShareExtensionItems() {
        guard session.vaultState == .unlocked,
              let inboxStore = AppShareExtensionInboxStore()
        else {
            return
        }
        do {
            try session.importPendingShareExtensionItems(
                inboxStore: inboxStore,
                projectTitle: session.activeVaultName ?? String(localized: "个人")
            )
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    /// 统一排空所有 App Group 收件箱（AutoFill 保存 / 分享扩展 / 系统通行密钥注册）。
    /// 所有解锁与前台激活路径都应调用本方法，避免新增收件箱时漏接。
    private func importPendingExtensionInboxItems() {
        importPendingAutoFillSaveRequests()
        importPendingShareExtensionItems()
        importPendingSystemPasskeyRegistrations()
    }

    private func importPendingSystemPasskeyRegistrations() {
        guard session.vaultState == .unlocked,
              let inboxStore = AppSystemPasskeyRegistrationInboxStore()
        else {
            return
        }
        _ = try? session.importPendingSystemPasskeyRegistrations(
            inboxStore: inboxStore,
            projectTitle: "Personal"
        )
    }

    @ViewBuilder
    private func tabContent(for tab: MonicaAppTab) -> some View {
        Group {
            switch tab {
            case .passwords:
                NavigationStack {
                    vaultHomeView(isPasswordRoot: true, baseItemKind: nil)
                }
            case .totp:
                NavigationStack {
                    vaultHomeView(isPasswordRoot: false, baseItemKind: .totp)
                }
            case .wallet:
                NavigationStack {
                    vaultHomeView(isPasswordRoot: false, baseItemKind: .card)
                }
            case .settings:
                NavigationStack {
                    SettingsRootView(
                        environment: environment,
                        session: session,
                        refreshAutoFillIndex: refreshAutoFillIndex
                    )
                }
            }
        }
        .toolbarBackground(AndroidParityPalette.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private func vaultHomeView(isPasswordRoot: Bool, baseItemKind: UnifiedVaultItemKind?) -> some View {
        AndroidParityVaultHomeView(
            session: session,
            isPasswordRoot: isPasswordRoot,
            baseItemKind: baseItemKind,
            storageStrategy: coreInfo.storageStrategy,
            mdbxBridge: mdbxInfo.bridge,
            createVault: createLocalVault,
            openVault: openLocalVault,
            lockVault: session.lockLocalVault,
            createLoginEntry: createLoginEntry,
            generateLoginPassword: generateLoginPassword,
            updateLoginEntry: updateLoginEntry,
            generateSelectedLoginPassword: generateSelectedLoginPassword,
            setSelectedLoginFavorite: setSelectedLoginFavorite,
            deleteLoginEntry: deleteLoginEntry,
            restoreLoginEntry: restoreLoginEntry,
            createNoteEntry: createNoteEntry,
            updateNoteEntry: updateNoteEntry,
            setSelectedNoteFavorite: setSelectedNoteFavorite,
            deleteNoteEntry: deleteNoteEntry,
            restoreNoteEntry: restoreNoteEntry,
            createTotpEntry: createTotpEntry,
            importTotpURI: importTotpURI,
            scanTotpQRCode: scanTotpQRCode,
            updateTotpEntry: updateTotpEntry,
            setSelectedTotpFavorite: setSelectedTotpFavorite,
            deleteTotpEntry: deleteTotpEntry,
            restoreTotpEntry: restoreTotpEntry,
            createCardEntry: createCardEntry,
            updateCardEntry: updateCardEntry,
            setSelectedCardFavorite: setSelectedCardFavorite,
            deleteCardEntry: deleteCardEntry,
            restoreCardEntry: restoreCardEntry,
            createIdentityEntry: createIdentityEntry,
            updateIdentityEntry: updateIdentityEntry,
            setSelectedIdentityFavorite: setSelectedIdentityFavorite,
            deleteIdentityEntry: deleteIdentityEntry,
            restoreIdentityEntry: restoreIdentityEntry,
            createPasskeyEntry: createPasskeyEntry,
            updatePasskeyEntry: updatePasskeyEntry,
            setSelectedPasskeyFavorite: setSelectedPasskeyFavorite,
            deletePasskeyEntry: deletePasskeyEntry,
            restorePasskeyEntry: restorePasskeyEntry,
            setSelectedSshKeyFavorite: setSelectedSshKeyFavorite,
            deleteSshKeyEntry: deleteSshKeyEntry,
            restoreSshKeyEntry: restoreSshKeyEntry,
            setSelectedApiTokenFavorite: setSelectedApiTokenFavorite,
            deleteApiTokenEntry: deleteApiTokenEntry,
            restoreApiTokenEntry: restoreApiTokenEntry,
            setSelectedWifiFavorite: setSelectedWifiFavorite,
            deleteWifiEntry: deleteWifiEntry,
            restoreWifiEntry: restoreWifiEntry,
            setSelectedSendFavorite: setSelectedSendFavorite,
            deleteSendEntry: deleteSendEntry,
            restoreSendEntry: restoreSendEntry,
            deleteAttachmentEntry: deleteAttachmentEntry,
            restoreAttachmentEntry: restoreAttachmentEntry,
            refreshExtendedParityEntries: refreshExtendedParityEntries
        )
    }

    private func createLocalVault() {
        do {
            try session.createLocalVault(
                in: vaultDirectory,
                deviceID: environment.localDeviceIdentifier
            )
            importPendingExtensionInboxItems()
            session.maybePresentQuickSetupAfterUnlock()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func submitLockScreenPassword() {
        do {
            if session.isFirstTimeVaultSetup {
                switch session.firstTimePasswordSetupStep {
                case .enterPassword:
                    session.beginFirstTimePasswordConfirmation()
                case .confirmPassword:
                    try session.confirmFirstTimePasswordAndCreateVault(
                        in: vaultDirectory,
                        deviceID: environment.localDeviceIdentifier
                    )
                    importPendingExtensionInboxItems()
                    session.maybePresentQuickSetupAfterUnlock()
                }
            } else {
                try session.unlockRememberedVaultWithPassword(
                    deviceID: environment.localDeviceIdentifier,
                    fallbackDirectory: vaultDirectory
                )
                importPendingExtensionInboxItems()
                session.maybePresentQuickSetupAfterUnlock()
            }
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func openLocalVault(at fileURL: URL) {
        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try session.openLocalVault(
                at: fileURL,
                deviceID: environment.localDeviceIdentifier
            )
            importPendingExtensionInboxItems()
            session.maybePresentQuickSetupAfterUnlock()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func createLoginEntry() {
        do {
            try session.createLoginEntry(
                projectTitle: session.activeVaultName ?? String(localized: "个人")
            )
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func generateLoginPassword() {
        do {
            try session.generateLoginPassword()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func updateLoginEntry() {
        do {
            try session.updateSelectedLoginEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func generateSelectedLoginPassword() {
        do {
            try session.generateSelectedLoginPassword()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func setSelectedLoginFavorite(_ favorite: Bool) {
        do {
            try session.setSelectedLoginFavorite(favorite)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func refreshAutoFillIndex() {
        do {
            try session.refreshAutoFillEncryptedIndex()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func deleteLoginEntry() {
        do {
            try session.deleteSelectedLoginEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func restoreLoginEntry(_ entry: LocalLoginEntry) {
        do {
            try session.restoreLoginEntry(entry)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func createNoteEntry() {
        do {
            try session.createNoteEntry(
                projectTitle: session.activeVaultName ?? String(localized: "个人")
            )
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func updateNoteEntry() {
        do {
            try session.updateSelectedNoteEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func setSelectedNoteFavorite(_ favorite: Bool) {
        do {
            try session.setSelectedNoteFavorite(favorite)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func deleteNoteEntry() {
        do {
            try session.deleteSelectedNoteEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func restoreNoteEntry(_ entry: LocalNoteEntry) {
        do {
            try session.restoreNoteEntry(entry)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func createTotpEntry() {
        do {
            try session.createTotpEntry(
                projectTitle: session.activeVaultName ?? String(localized: "个人")
            )
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func importTotpURI() {
        do {
            try session.importTotpURI(session.totpImportURI)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func scanTotpQRCode(_ payload: String) -> Bool {
        do {
            try session.importScannedTotpQRCode(payload)
            return true
        } catch {
            // AppSessionModel owns user-visible failure state.
            return false
        }
    }

    private func updateTotpEntry() {
        do {
            try session.updateSelectedTotpEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func setSelectedTotpFavorite(_ favorite: Bool) {
        do {
            try session.setSelectedTotpFavorite(favorite)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func deleteTotpEntry() {
        do {
            try session.deleteSelectedTotpEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func restoreTotpEntry(_ entry: LocalTotpEntry) {
        do {
            try session.restoreTotpEntry(entry)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func createCardEntry() {
        do {
            try session.createCardEntry(
                projectTitle: session.activeVaultName ?? String(localized: "个人")
            )
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func updateCardEntry() {
        do {
            try session.updateSelectedCardEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func setSelectedCardFavorite(_ favorite: Bool) {
        do {
            try session.setSelectedCardFavorite(favorite)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func deleteCardEntry() {
        do {
            try session.deleteSelectedCardEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func restoreCardEntry(_ entry: LocalCardEntry) {
        do {
            try session.restoreCardEntry(entry)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func createIdentityEntry() {
        do {
            try session.createIdentityEntry(
                projectTitle: session.activeVaultName ?? String(localized: "个人")
            )
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func updateIdentityEntry() {
        do {
            try session.updateSelectedIdentityEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func setSelectedIdentityFavorite(_ favorite: Bool) {
        do {
            try session.setSelectedIdentityFavorite(favorite)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func deleteIdentityEntry() {
        do {
            try session.deleteSelectedIdentityEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func restoreIdentityEntry(_ entry: LocalIdentityEntry) {
        do {
            try session.restoreIdentityEntry(entry)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func createPasskeyEntry() {
        do {
            try session.createPasskeyEntry(
                projectTitle: session.activeVaultName ?? String(localized: "个人")
            )
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func updatePasskeyEntry() {
        do {
            try session.updateSelectedPasskeyEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func setSelectedPasskeyFavorite(_ favorite: Bool) {
        do {
            try session.setSelectedPasskeyFavorite(favorite)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func deletePasskeyEntry() {
        do {
            try session.deleteSelectedPasskeyEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func restorePasskeyEntry(_ entry: LocalPasskeyEntry) {
        do {
            try session.restorePasskeyEntry(entry)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func setSelectedSshKeyFavorite(_ favorite: Bool) {
        do {
            try session.setSelectedSshKeyFavorite(favorite)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func deleteSshKeyEntry() {
        do {
            try session.deleteSelectedSshKeyEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func restoreSshKeyEntry(_ entry: LocalSshKeyEntry) {
        do {
            try session.restoreSshKeyEntry(entry)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func setSelectedApiTokenFavorite(_ favorite: Bool) {
        do {
            try session.setSelectedApiTokenFavorite(favorite)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func deleteApiTokenEntry() {
        do {
            try session.deleteSelectedApiTokenEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func restoreApiTokenEntry(_ entry: LocalApiTokenEntry) {
        do {
            try session.restoreApiTokenEntry(entry)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func setSelectedWifiFavorite(_ favorite: Bool) {
        do {
            try session.setSelectedWifiFavorite(favorite)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func deleteWifiEntry() {
        do {
            try session.deleteSelectedWifiEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func restoreWifiEntry(_ entry: LocalWifiEntry) {
        do {
            try session.restoreWifiEntry(entry)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func setSelectedSendFavorite(_ favorite: Bool) {
        do {
            try session.setSelectedSendFavorite(favorite)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func deleteSendEntry() {
        do {
            try session.deleteSelectedSendEntry()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func restoreSendEntry(_ entry: LocalSendEntry) {
        do {
            try session.restoreSendEntry(entry)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func deleteAttachmentEntry(_ entry: LocalAttachmentMetadata) {
        do {
            try session.deleteAttachmentEntry(entry)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func restoreAttachmentEntry(_ entry: LocalAttachmentMetadata) {
        do {
            try session.restoreAttachmentEntry(entry)
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private func refreshExtendedParityEntries() {
        do {
            try session.refreshExtendedParityEntries()
        } catch {
            // AppSessionModel owns user-visible failure state.
        }
    }

    private var vaultDirectory: URL {
        FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
    }
}

#Preview {
    AppRootView(environment: MonicaAppEnvironment())
}
