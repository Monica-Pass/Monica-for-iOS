import Foundation
import AuthenticationServices
import MonicaCore
import MonicaSecurity
import MonicaStorage
import MonicaSync
import MonicaWidgetShared
import Security
import WidgetKit

struct MonicaAppEnvironment: Sendable {
    let appGroupIdentifier: String
    let minimumIOSVersion: String
    let localDeviceIdentifier: String
    let oneDriveConfiguration: OneDriveCloudFileConfiguration
    let oneDriveAuthenticationService: any AppOneDriveAuthenticationService
    let oneDriveGraphTransport: any OneDriveGraphTransport
    let oneDriveBackupPreferencesStore: any AppOneDriveBackupPreferencesStore
    let plusPurchaseService: (any AppPlusPurchaseService)?
    let googleDriveConfiguration: GoogleDriveConfiguration
    let googleDriveAuthenticationService: any AppGoogleDriveAuthenticationService
    let googleDriveTransport: any GoogleDriveHTTPTransport
    let plusEntitlementStore: any AppPlusEntitlementStore
    let appLanguageStore: any AppLanguageStore

    init(
        appGroupIdentifier: String = "group.com.monicapass.monica",
        minimumIOSVersion: String = "18.0",
        localDeviceIdentifier: String = "ios-local-device",
        oneDriveConfiguration: OneDriveCloudFileConfiguration = .monicaProduction,
        oneDriveAuthenticationService: (any AppOneDriveAuthenticationService)? = nil,
        oneDriveGraphTransport: any OneDriveGraphTransport = URLSessionOneDriveGraphTransport(),
        oneDriveBackupPreferencesStore: (any AppOneDriveBackupPreferencesStore)? = nil,
        googleDriveConfiguration: GoogleDriveConfiguration = .fromBundle(),
        googleDriveAuthenticationService: (any AppGoogleDriveAuthenticationService)? = nil,
        googleDriveTransport: any GoogleDriveHTTPTransport = URLSessionGoogleDriveHTTPTransport(),
        plusPurchaseService: (any AppPlusPurchaseService)? = StoreKitAppPlusPurchaseService(),
        plusEntitlementStore: any AppPlusEntitlementStore = UserDefaultsAppPlusEntitlementStore(),
        appLanguageStore: any AppLanguageStore = UserDefaultsAppLanguageStore()
    ) {
        self.appGroupIdentifier = appGroupIdentifier
        self.minimumIOSVersion = minimumIOSVersion
        self.localDeviceIdentifier = localDeviceIdentifier
        self.oneDriveConfiguration = oneDriveConfiguration
        self.oneDriveAuthenticationService = oneDriveAuthenticationService ?? DefaultAppOneDriveMSALAuthenticationService(
            configuration: oneDriveConfiguration
        )
        self.oneDriveGraphTransport = oneDriveGraphTransport
        self.oneDriveBackupPreferencesStore = oneDriveBackupPreferencesStore ?? UserDefaultsAppOneDriveBackupPreferencesStore()
        self.plusPurchaseService = plusPurchaseService
        self.googleDriveConfiguration = googleDriveConfiguration
        self.googleDriveTransport = googleDriveTransport
        self.googleDriveAuthenticationService = googleDriveAuthenticationService ?? DefaultAppGoogleDriveAuthenticationService(
            configuration: googleDriveConfiguration,
            transport: googleDriveTransport
        )
        self.plusEntitlementStore = plusEntitlementStore
        self.appLanguageStore = appLanguageStore
    }

    var productionCloudFileProviders: [CloudFileProviderKind: any CloudFileProvider] {
        var providers: [CloudFileProviderKind: any CloudFileProvider] = [
            .oneDrive: OneDriveCloudFileProvider(
                configuration: oneDriveConfiguration,
                tokenProvider: oneDriveAuthenticationService,
                graphTransport: oneDriveGraphTransport
            )
        ]
        // 未配置 client ID 时 provider 仍然存在，但 connectionState/list 都会返回「未配置」，
        // 因此 WebDAV 与 OneDrive 的路径不受影响。
        providers[.googleDrive] = GoogleDriveCloudFileProvider(
            configuration: googleDriveConfiguration,
            tokenProvider: googleDriveAuthenticationService,
            transport: googleDriveTransport
        )
        return providers
    }

    var productionCloudFileBrowsers: [CloudFileBrowserKind: any CloudFileBrowser] {
        [
            .oneDrive: OneDriveCloudFileBrowser(
                configuration: oneDriveConfiguration,
                tokenProvider: oneDriveAuthenticationService,
                transport: oneDriveGraphTransport
            ),
            .googleDrive: GoogleDriveCloudFileBrowser(
                configuration: googleDriveConfiguration,
                tokenProvider: googleDriveAuthenticationService,
                transport: googleDriveTransport
            )
        ]
    }
}

protocol AppAutoFillIndexKeyMaterialStore {
    func loadKeyMaterial(vaultID: String) throws -> AutoFillIndexKeyMaterial?
    func saveKeyMaterial(_ keyMaterial: AutoFillIndexKeyMaterial) throws
}

struct AppAutoFillIndexKeyMaterialProvider {
    static let defaultKeyIdentifier = "autofill-index-key-v1"

    private let store: any AppAutoFillIndexKeyMaterialStore
    private let randomBytes: (Int) throws -> Data
    private let now: () -> Date

    init(
        store: any AppAutoFillIndexKeyMaterialStore,
        randomBytes: @escaping (Int) throws -> Data = AppAutoFillIndexKeyMaterialProvider.secureRandomBytes(count:),
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.randomBytes = randomBytes
        self.now = now
    }

    func keyMaterial(for vaultID: String) throws -> AutoFillIndexKeyMaterial {
        let normalizedVaultID = vaultID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedVaultID.isEmpty else {
            throw MonicaSecurityError.emptyVaultID
        }

        if let existing = try store.loadKeyMaterial(vaultID: normalizedVaultID) {
            return existing
        }

        let keyMaterial = AutoFillIndexKeyMaterial(
            vaultID: normalizedVaultID,
            keyIdentifier: Self.defaultKeyIdentifier,
            keyMaterial: try randomBytes(AutoFillIndexKeyMaterial.requiredByteCount),
            createdAt: now()
        )
        try validate(keyMaterial)
        try store.saveKeyMaterial(keyMaterial)
        return keyMaterial
    }

    private func validate(_ keyMaterial: AutoFillIndexKeyMaterial) throws {
        guard !keyMaterial.vaultID.isEmpty else {
            throw MonicaSecurityError.emptyVaultID
        }
        guard !keyMaterial.keyIdentifier.isEmpty else {
            throw MonicaSecurityError.emptyAutoFillIndexKeyIdentifier
        }
        guard keyMaterial.keyMaterial.count == AutoFillIndexKeyMaterial.requiredByteCount else {
            throw MonicaSecurityError.invalidAutoFillIndexKeyLength(
                expected: AutoFillIndexKeyMaterial.requiredByteCount,
                actual: keyMaterial.keyMaterial.count
            )
        }
    }

    static func secureRandomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw MonicaSecurityError.keychainUnexpectedStatus(status)
        }
        return Data(bytes)
    }
}

final class AppKeychainAutoFillIndexKeyMaterialStore: AppAutoFillIndexKeyMaterialStore {
    private let service: String
    private let accessGroup: String?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        service: String = "ru.takagi.monica.autofill-index-key",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.accessGroup = accessGroup
    }

    func loadKeyMaterial(vaultID: String) throws -> AutoFillIndexKeyMaterial? {
        var query = baseQuery(vaultID: vaultID)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw MonicaSecurityError.keychainUnexpectedStatus(status)
        }
        guard let data = item as? Data else {
            throw MonicaSecurityError.autoFillIndexKeyMaterialNotFound
        }
        return try decoder.decode(AutoFillIndexKeyMaterial.self, from: data)
    }

    func saveKeyMaterial(_ keyMaterial: AutoFillIndexKeyMaterial) throws {
        let data = try encoder.encode(keyMaterial)
        var query = baseQuery(vaultID: keyMaterial.vaultID)
        SecItemDelete(query as CFDictionary)

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MonicaSecurityError.keychainUnexpectedStatus(status)
        }
    }

    private func baseQuery(vaultID: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultID.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}

struct AppAutoFillCredentialIdentity: Sendable, Equatable {
    let recordIdentifier: String
    let serviceIdentifier: String
    let username: String

    init(
        recordIdentifier: String,
        serviceIdentifier: String,
        username: String
    ) {
        self.recordIdentifier = recordIdentifier
        self.serviceIdentifier = serviceIdentifier
        self.username = username
    }
}

struct AppAutoFillPasskeyCredentialIdentity: Sendable, Equatable {
    let recordIdentifier: String
    let relyingPartyIdentifier: String
    let username: String
    let credentialID: Data
    let userHandle: Data

    init(
        recordIdentifier: String,
        relyingPartyIdentifier: String,
        username: String,
        credentialID: Data,
        userHandle: Data
    ) {
        self.recordIdentifier = recordIdentifier
        self.relyingPartyIdentifier = relyingPartyIdentifier
        self.username = username
        self.credentialID = credentialID
        self.userHandle = userHandle
    }
}

protocol AppAutoFillCredentialIdentityStore: Sendable {
    func replaceCredentialIdentities(
        _ identities: [AppAutoFillCredentialIdentity],
        passkeyIdentities: [AppAutoFillPasskeyCredentialIdentity]
    )

    /// 读取系统凭据存储的真实状态。无法读取时返回 nil，调用方应展示为「未知」。
    func loadIdentityStoreStatus() async -> AppAutoFillIdentityStoreStatus?

    /// 清空本扩展已经发布到系统凭据列表的身份条目。
    func removeAllPublishedIdentities() async
}

extension AppAutoFillCredentialIdentityStore {
    func loadIdentityStoreStatus() async -> AppAutoFillIdentityStoreStatus? {
        nil
    }

    func removeAllPublishedIdentities() async {}
}

final class SystemAutoFillCredentialIdentityStore: AppAutoFillCredentialIdentityStore, @unchecked Sendable {
    private let store: ASCredentialIdentityStore
    private let publishLog: (any AppAutoFillPublishLogStore)?

    init(
        store: ASCredentialIdentityStore = .shared,
        publishLog: (any AppAutoFillPublishLogStore)? = nil
    ) {
        self.store = store
        self.publishLog = publishLog
    }

    func replaceCredentialIdentities(
        _ identities: [AppAutoFillCredentialIdentity],
        passkeyIdentities: [AppAutoFillPasskeyCredentialIdentity]
    ) {
        let passwordIdentities = identities.map { identity in
            ASPasswordCredentialIdentity(
                serviceIdentifier: ASCredentialServiceIdentifier(
                    identifier: identity.serviceIdentifier,
                    type: serviceIdentifierType(for: identity.serviceIdentifier)
                ),
                user: identity.username,
                recordIdentifier: identity.recordIdentifier
            )
        }
        let systemPasskeyIdentities = passkeyIdentities.map { identity in
            ASPasskeyCredentialIdentity(
                relyingPartyIdentifier: identity.relyingPartyIdentifier,
                userName: identity.username,
                credentialID: identity.credentialID,
                userHandle: identity.userHandle,
                recordIdentifier: identity.recordIdentifier
            )
        }
        let credentialIdentities: [any ASCredentialIdentity] = passwordIdentities + systemPasskeyIdentities
        let publishedIdentityCount = credentialIdentities.count

        // Keep the authoritative full sync, but never write while the provider is disabled:
        // the store rejects writes then and the failure is silent.
        let identityStore = store
        let publishLog = publishLog
        identityStore.getState { state in
            guard state.isEnabled else {
                publishLog?.recordSkip(
                    reason: String(localized: "自动填充扩展未启用，未发布身份。"),
                    at: Date()
                )
                return
            }
            identityStore.replaceCredentialIdentities(credentialIdentities) { success, error in
                // AutoFill identity sync is best-effort; the completion is the only place where the
                // real outcome is observable, so the diagnostics panel reports it from here instead
                // of assuming success.
                let now = Date()
                if success, error == nil {
                    publishLog?.recordSuccess(count: publishedIdentityCount, at: now)
                } else {
                    publishLog?.recordFailure(
                        message: error.map { AppAutoFillPublishErrorMessage.message(for: $0) }
                            ?? String(localized: "系统拒绝了身份发布。"),
                        at: now
                    )
                }
            }
        }
    }

    func loadIdentityStoreStatus() async -> AppAutoFillIdentityStoreStatus? {
        let state = await store.state()
        var identityCount: Int?
        if #available(iOS 17.4, *) {
            // `credentialIdentityTypes: []` 等价于 ASCredentialIdentityTypesAll（raw value 为 0）。
            // 只取数量，返回的身份对象不缓存、不落盘、不打印。
            let identities = await store.credentialIdentities(
                forService: nil,
                credentialIdentityTypes: []
            )
            identityCount = identities.count
        }
        return AppAutoFillIdentityStoreStatus(
            isEnabled: state.isEnabled,
            supportsIncrementalUpdates: state.supportsIncrementalUpdates,
            identityCount: identityCount
        )
    }

    func removeAllPublishedIdentities() async {
        let publishLog = publishLog
        let state = await store.state()
        guard state.isEnabled else {
            publishLog?.recordSkip(
                reason: String(localized: "自动填充扩展未启用，无法清空已发布身份。"),
                at: Date()
            )
            return
        }
        do {
            try await store.removeAllCredentialIdentities()
            publishLog?.recordClear(at: Date())
        } catch {
            publishLog?.recordFailure(
                message: AppAutoFillPublishErrorMessage.message(for: error),
                at: Date()
            )
        }
    }

    private func serviceIdentifierType(
        for serviceIdentifier: String
    ) -> ASCredentialServiceIdentifier.IdentifierType {
        if let url = URL(string: serviceIdentifier),
           url.scheme != nil,
           url.host() != nil {
            return .URL
        }
        return .domain
    }
}

struct KeychainAppVaultKeychainService<Store: WrappedVaultKeyStore, Authenticator: MonicaLocalAuthenticator>: AppVaultKeychainService {
    private let manager: VaultKeychainManager<Store, Authenticator>

    init(store: Store, authenticator: Authenticator) {
        self.manager = VaultKeychainManager(store: store, authenticator: authenticator)
    }

    func saveWrappedKey(_ key: WrappedVaultKey) async throws {
        try await manager.saveWrappedKey(key)
    }

    func loadWrappedKeyAfterAuthentication(
        vaultID: String,
        reason: String
    ) async throws -> WrappedVaultKey {
        try await manager.loadWrappedKeyAfterAuthentication(
            vaultID: vaultID,
            reason: reason
        )
    }
}

struct AppVaultSecurityKeyMaterialProvider {
    static let requiredByteCount = 32

    private let randomBytes: (Int) throws -> Data
    private let now: () -> Date

    init(
        randomBytes: @escaping (Int) throws -> Data = AppAutoFillIndexKeyMaterialProvider.secureRandomBytes(count:),
        now: @escaping () -> Date = Date.init
    ) {
        self.randomBytes = randomBytes
        self.now = now
    }

    func wrappedKey(for session: LocalVaultSession) throws -> WrappedVaultKey {
        guard !session.handle.vaultID.isEmpty else {
            throw MonicaSecurityError.emptyVaultID
        }

        return WrappedVaultKey(
            vaultID: session.handle.vaultID,
            wrappedKeyMaterial: try randomBytes(Self.requiredByteCount),
            keyAlgorithm: .keychainProtectedData,
            createdAt: now()
        )
    }
}

extension AppSessionModel {
    static func production(environment: MonicaAppEnvironment) -> AppSessionModel {
        let appGroupContainerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: environment.appGroupIdentifier
        )
        guard let appGroupContainerURL else {
            return AppSessionModel(
                vaultDisplayPreferenceStore: UserDefaultsVaultDisplayPreferenceStore(),
                appearancePreferenceStore: UserDefaultsAppAppearancePreferenceStore(),
                vaultLayoutPreferenceStore: UserDefaultsVaultLayoutPreferenceStore(),
                searchAutoFocusPreferenceStore: UserDefaultsAppSearchAutoFocusPreferenceStore(),
                totpCardPreferenceStore: UserDefaultsTotpProgressPreferenceStore(),
operationTimelineStore: UserDefaultsAppOperationTimelineStore(),
                itemIconPreferenceStore: UserDefaultsAppItemIconPreferenceStore(),                quickSetupStateStore: UserDefaultsAppQuickSetupStateStore(),
                securityInsightStore: AppSecurityInsightsStoreLocation.productionStore(),
                cloudFileProviders: environment.productionCloudFileProviders,
                oneDriveAuthenticationService: environment.oneDriveAuthenticationService,
                oneDriveBackupPreferencesStore: environment.oneDriveBackupPreferencesStore,
                autoFillPolicyStore: UserDefaultsAppAutoFillPolicyStore(),
                autoFillGuardPolicyStore: UserDefaultsAppAutoFillGuardPolicyStore(),
                autoFillPublishLogStore: UserDefaultsAppAutoFillPublishLogStore(),
                plusPurchaseService: environment.plusPurchaseService,
                plusEntitlementStore: environment.plusEntitlementStore,
                sensitivePasteboard: MonicaSensitivePasteboard(pasteboard: SystemSensitivePasteboard()),
                sensitivePreviewPreferenceStore: UserDefaultsSensitivePreviewPreferenceStore(),
                sensitiveClipboardPreferenceStore: UserDefaultsSensitiveClipboardPreferenceStore()
            )
        }
        let appGroupDefaults = UserDefaults(suiteName: environment.appGroupIdentifier) ?? .standard
        let indexStore = FileAutoFillEncryptedIndexStore(appGroupContainerURL: appGroupContainerURL)
        let secretStore = FileAutoFillCredentialSecretStore(appGroupContainerURL: appGroupContainerURL)
        let widgetSnapshotStore = AppWidgetSnapshotFileStore(containerURL: appGroupContainerURL)
        let shortcutSnapshotStore = AppShortcutSnapshotFileStore(containerURL: appGroupContainerURL)
        // WidgetKit's only public "please refresh" hook. The scheduler coalesces the burst
        // of mutations produced by imports/sync so the widget is not rate limited.
        let widgetReloadScheduler = MonicaWidgetReloadScheduler {
            WidgetCenter.shared.reloadTimelines(ofKind: MonicaWidgetConstants.widgetKind)
        }
        let bitwardenAuthenticationSessionStore = FileAppBitwardenAuthenticationSessionStore(containerURL: appGroupContainerURL)
        let bitwardenVaultKeyStore = FileAppBitwardenVaultKeyStore(containerURL: appGroupContainerURL)
        let bitwardenSendSyncStateStore = FileAppBitwardenSendSyncStateStore(containerURL: appGroupContainerURL)
        let bitwardenFolderSyncStateStore = FileAppBitwardenFolderSyncStateStore(containerURL: appGroupContainerURL)
        let bitwardenItemSyncStateStore = FileAppBitwardenItemSyncStateStore(containerURL: appGroupContainerURL)
        let bitwardenPendingMutationQueueStore = FileAppBitwardenPendingMutationQueueStore(containerURL: appGroupContainerURL)
        let bitwardenSyncCheckpointStore = FileAppBitwardenSyncCheckpointStore(containerURL: appGroupContainerURL)
        let keyMaterialStore = AppKeychainAutoFillIndexKeyMaterialStore()
        let keyMaterialProvider = AppAutoFillIndexKeyMaterialProvider(store: keyMaterialStore)
        let vaultKeychainService = KeychainAppVaultKeychainService(
            store: KeychainWrappedVaultKeyStore(),
            authenticator: DeviceOwnerLocalAuthenticator()
        )
        let vaultSecurityKeyProvider = AppVaultSecurityKeyMaterialProvider()
        // 发布记录由系统凭据存储的回调写入、由会话与诊断面板读取，三处共用同一个实现。
        let autoFillPublishLogStore = UserDefaultsAppAutoFillPublishLogStore()

        let session = AppSessionModel(
            vaultKeychainService: vaultKeychainService,
            vaultWrappedKeyProvider: { session in
                try vaultSecurityKeyProvider.wrappedKey(for: session)
            },
            rememberedVaultStore: UserDefaultsRememberedVaultStore(),
            vaultRegistryStore: UserDefaultsVaultRegistryStore(),
            biometricUnlockPreferenceStore: UserDefaultsBiometricUnlockPreferenceStore(),
            vaultDisplayPreferenceStore: UserDefaultsVaultDisplayPreferenceStore(),
            appearancePreferenceStore: UserDefaultsAppAppearancePreferenceStore(),
            vaultLayoutPreferenceStore: UserDefaultsVaultLayoutPreferenceStore(),
            searchAutoFocusPreferenceStore: UserDefaultsAppSearchAutoFocusPreferenceStore(),
            totpCardPreferenceStore: UserDefaultsTotpProgressPreferenceStore(),
biometricUnlockAuthorizer: DeviceBiometricUnlockAuthorizer(),
            itemIconPreferenceStore: UserDefaultsAppItemIconPreferenceStore(),            biometricCapabilityProvider: deviceBiometricUnlockCapability,
            operationTimelineStore: UserDefaultsAppOperationTimelineStore(defaults: appGroupDefaults),
            quickSetupStateStore: UserDefaultsAppQuickSetupStateStore(defaults: appGroupDefaults),
            securityInsightStore: AppSecurityInsightsStoreLocation.productionStore(),
            cloudFileProviders: environment.productionCloudFileProviders,
            oneDriveAuthenticationService: environment.oneDriveAuthenticationService,
            oneDriveBackupPreferencesStore: environment.oneDriveBackupPreferencesStore,
            bitwardenPasswordAuthenticationService: MonicaSyncBitwardenPasswordAuthenticationService(
                authenticator: BitwardenPasswordAuthenticator(
                    sessionStore: bitwardenAuthenticationSessionStore,
                    vaultKeyStore: bitwardenVaultKeyStore
                )
            ),
            bitwardenSyncProvider: BitwardenVaultSyncProvider(
                sessionStore: bitwardenAuthenticationSessionStore,
                vaultKeyStore: bitwardenVaultKeyStore
            ),
            bitwardenAuthenticationSessionStore: bitwardenAuthenticationSessionStore,
            bitwardenVaultKeyStore: bitwardenVaultKeyStore,
            bitwardenSendSyncStateStore: bitwardenSendSyncStateStore,
            bitwardenFolderSyncStateStore: bitwardenFolderSyncStateStore,
            bitwardenItemSyncStateStore: bitwardenItemSyncStateStore,
            bitwardenPendingMutationQueueStore: bitwardenPendingMutationQueueStore,
            bitwardenSyncCheckpointStore: bitwardenSyncCheckpointStore,
            autoFillIndexStore: indexStore,
            autoFillCredentialSecretStore: secretStore,
            autoFillCredentialIdentityStore: SystemAutoFillCredentialIdentityStore(
                publishLog: autoFillPublishLogStore
            ),
            autoFillPolicyStore: UserDefaultsAppAutoFillPolicyStore(),
            autoFillGuardPolicyStore: UserDefaultsAppAutoFillGuardPolicyStore(),
            autoFillPublishLogStore: autoFillPublishLogStore,
            autoFillIndexKeyMaterialProvider: { vaultID in
                try keyMaterialProvider.keyMaterial(for: vaultID)
            },
            plusPurchaseService: environment.plusPurchaseService,
            plusEntitlementStore: environment.plusEntitlementStore,
            widgetSnapshotStore: widgetSnapshotStore,
            shortcutSnapshotStore: shortcutSnapshotStore,
            widgetReloadScheduler: widgetReloadScheduler,
            sensitivePasteboard: MonicaSensitivePasteboard(pasteboard: SystemSensitivePasteboard()),
            sensitivePreviewPreferenceStore: UserDefaultsSensitivePreviewPreferenceStore(),
            sensitiveClipboardPreferenceStore: UserDefaultsSensitiveClipboardPreferenceStore()
        )
        session.refreshNotificationPermissionStatus()
        return session
    }
}
