import Foundation
import AuthenticationServices
import MonicaSecurity
import MonicaStorage
import MonicaSync
import Security

struct MonicaAppEnvironment: Sendable {
    let appGroupIdentifier: String
    let minimumIOSVersion: String
    let firstBackupProvider: String
    let localDeviceIdentifier: String
    let oneDriveConfiguration: OneDriveCloudFileConfiguration
    let oneDriveAuthenticationService: any AppOneDriveAuthenticationService
    let oneDriveGraphTransport: any OneDriveGraphTransport
    let plusEntitlementStore: any AppPlusEntitlementStore

    init(
        appGroupIdentifier: String = "group.monica-pass.monica",
        minimumIOSVersion: String = "17.0",
        firstBackupProvider: String = "WebDAV",
        localDeviceIdentifier: String = "ios-local-device",
        oneDriveConfiguration: OneDriveCloudFileConfiguration = .monicaProduction,
        oneDriveAuthenticationService: (any AppOneDriveAuthenticationService)? = nil,
        oneDriveGraphTransport: any OneDriveGraphTransport = URLSessionOneDriveGraphTransport(),
        plusEntitlementStore: any AppPlusEntitlementStore = UserDefaultsAppPlusEntitlementStore()
    ) {
        self.appGroupIdentifier = appGroupIdentifier
        self.minimumIOSVersion = minimumIOSVersion
        self.firstBackupProvider = firstBackupProvider
        self.localDeviceIdentifier = localDeviceIdentifier
        self.oneDriveConfiguration = oneDriveConfiguration
        self.oneDriveAuthenticationService = oneDriveAuthenticationService ?? DefaultAppOneDriveMSALAuthenticationService(
            configuration: oneDriveConfiguration
        )
        self.oneDriveGraphTransport = oneDriveGraphTransport
        self.plusEntitlementStore = plusEntitlementStore
    }

    var productionCloudFileProviders: [CloudFileProviderKind: any CloudFileProvider] {
        [
            .oneDrive: OneDriveCloudFileProvider(
                configuration: oneDriveConfiguration,
                tokenProvider: oneDriveAuthenticationService,
                graphTransport: oneDriveGraphTransport
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
}

final class SystemAutoFillCredentialIdentityStore: AppAutoFillCredentialIdentityStore, @unchecked Sendable {
    private let store: ASCredentialIdentityStore

    init(store: ASCredentialIdentityStore = .shared) {
        self.store = store
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

        store.replaceCredentialIdentities(credentialIdentities) { _, _ in
            // AutoFill identity sync is best-effort; signed-device validation covers entitlement errors.
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
                cloudFileProviders: environment.productionCloudFileProviders,
                oneDriveAuthenticationService: environment.oneDriveAuthenticationService,
                plusResourceUnlockService: DefaultAppPlusResourceUnlockService(),
                plusEntitlementStore: environment.plusEntitlementStore
            )
        }
        let indexStore = FileAutoFillEncryptedIndexStore(appGroupContainerURL: appGroupContainerURL)
        let secretStore = FileAutoFillCredentialSecretStore(appGroupContainerURL: appGroupContainerURL)
        let widgetSnapshotStore = AppWidgetSnapshotFileStore(containerURL: appGroupContainerURL)
        let shortcutSnapshotStore = AppShortcutSnapshotFileStore(containerURL: appGroupContainerURL)
        let bitwardenAuthenticationSessionStore = FileAppBitwardenAuthenticationSessionStore(containerURL: appGroupContainerURL)
        let bitwardenVaultKeyStore = FileAppBitwardenVaultKeyStore(containerURL: appGroupContainerURL)
        let bitwardenSendSyncStateStore = FileAppBitwardenSendSyncStateStore(containerURL: appGroupContainerURL)
        let bitwardenFolderSyncStateStore = FileAppBitwardenFolderSyncStateStore(containerURL: appGroupContainerURL)
        let bitwardenItemSyncStateStore = FileAppBitwardenItemSyncStateStore(containerURL: appGroupContainerURL)
        let bitwardenPendingMutationQueueStore = FileAppBitwardenPendingMutationQueueStore(containerURL: appGroupContainerURL)
        let keyMaterialStore = AppKeychainAutoFillIndexKeyMaterialStore()
        let keyMaterialProvider = AppAutoFillIndexKeyMaterialProvider(store: keyMaterialStore)
        let vaultKeychainService = KeychainAppVaultKeychainService(
            store: KeychainWrappedVaultKeyStore(),
            authenticator: DeviceOwnerLocalAuthenticator()
        )
        let vaultSecurityKeyProvider = AppVaultSecurityKeyMaterialProvider()

        let session = AppSessionModel(
            vaultKeychainService: vaultKeychainService,
            vaultWrappedKeyProvider: { session in
                try vaultSecurityKeyProvider.wrappedKey(for: session)
            },
            rememberedVaultStore: UserDefaultsRememberedVaultStore(),
            biometricUnlockPreferenceStore: UserDefaultsBiometricUnlockPreferenceStore(),
            vaultDisplayPreferenceStore: UserDefaultsVaultDisplayPreferenceStore(),
            appearancePreferenceStore: UserDefaultsAppAppearancePreferenceStore(),
            biometricUnlockAuthorizer: DeviceBiometricUnlockAuthorizer(),
            biometricCapabilityProvider: deviceBiometricUnlockCapability,
            cloudFileProviders: environment.productionCloudFileProviders,
            oneDriveAuthenticationService: environment.oneDriveAuthenticationService,
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
            autoFillIndexStore: indexStore,
            autoFillCredentialSecretStore: secretStore,
            autoFillCredentialIdentityStore: SystemAutoFillCredentialIdentityStore(),
            autoFillIndexKeyMaterialProvider: { vaultID in
                try keyMaterialProvider.keyMaterial(for: vaultID)
            },
            plusResourceUnlockService: DefaultAppPlusResourceUnlockService(),
            plusEntitlementStore: environment.plusEntitlementStore,
            widgetSnapshotStore: widgetSnapshotStore,
            shortcutSnapshotStore: shortcutSnapshotStore
        )
        session.refreshNotificationPermissionStatus()
        return session
    }
}
