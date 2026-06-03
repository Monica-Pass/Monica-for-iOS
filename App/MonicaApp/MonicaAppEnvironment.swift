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

    init(
        appGroupIdentifier: String = "group.monica-pass.monica",
        minimumIOSVersion: String = "17.0",
        firstBackupProvider: String = "WebDAV",
        localDeviceIdentifier: String = "ios-local-device",
        oneDriveConfiguration: OneDriveCloudFileConfiguration = .monicaProduction
    ) {
        self.appGroupIdentifier = appGroupIdentifier
        self.minimumIOSVersion = minimumIOSVersion
        self.firstBackupProvider = firstBackupProvider
        self.localDeviceIdentifier = localDeviceIdentifier
        self.oneDriveConfiguration = oneDriveConfiguration
    }

    var productionCloudFileProviders: [CloudFileProviderKind: any CloudFileProvider] {
        [
            .oneDrive: OneDriveCloudFileProvider(configuration: oneDriveConfiguration)
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

protocol AppAutoFillCredentialIdentityStore: Sendable {
    func replaceCredentialIdentities(_ identities: [AppAutoFillCredentialIdentity])
}

final class SystemAutoFillCredentialIdentityStore: AppAutoFillCredentialIdentityStore, @unchecked Sendable {
    private let store: ASCredentialIdentityStore

    init(store: ASCredentialIdentityStore = .shared) {
        self.store = store
    }

    func replaceCredentialIdentities(_ identities: [AppAutoFillCredentialIdentity]) {
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

        store.replaceCredentialIdentities(passwordIdentities) { _, _ in
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
                plusResourceUnlockService: DefaultAppPlusResourceUnlockService()
            )
        }
        let indexStore = FileAutoFillEncryptedIndexStore(appGroupContainerURL: appGroupContainerURL)
        let secretStore = FileAutoFillCredentialSecretStore(appGroupContainerURL: appGroupContainerURL)
        let widgetSnapshotStore = AppWidgetSnapshotFileStore(containerURL: appGroupContainerURL)
        let shortcutSnapshotStore = AppShortcutSnapshotFileStore(containerURL: appGroupContainerURL)
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
            autoFillIndexStore: indexStore,
            autoFillCredentialSecretStore: secretStore,
            autoFillCredentialIdentityStore: SystemAutoFillCredentialIdentityStore(),
            autoFillIndexKeyMaterialProvider: { vaultID in
                try keyMaterialProvider.keyMaterial(for: vaultID)
            },
            plusResourceUnlockService: DefaultAppPlusResourceUnlockService(),
            widgetSnapshotStore: widgetSnapshotStore,
            shortcutSnapshotStore: shortcutSnapshotStore
        )
        session.refreshNotificationPermissionStatus()
        return session
    }
}
