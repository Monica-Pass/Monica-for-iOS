import Testing
import Foundation
import MonicaSecurity

@Test func securityBaselineDocumentsBiometricBoundary() {
    #expect(MonicaSecurityBaseline.biometricPolicy.contains("LocalAuthentication"))
    #expect(MonicaSecurityBaseline.biometricPolicy.contains("不是保险库秘密本身"))
}

@Test func vaultKeychainSavesWrappedKeyMaterialWithoutRawVaultSecret() async throws {
    let store = MemoryWrappedKeyStore()
    let authenticator = RecordingLocalAuthenticator(result: true)
    let vaultID = "vault-1"
    let rawVaultKey = Data("raw vault key material".utf8)
    let wrappedKey = Data("wrapped key material".utf8)
    let manager = VaultKeychainManager(
        store: store,
        authenticator: authenticator
    )

    try await manager.saveWrappedKey(
        WrappedVaultKey(
            vaultID: vaultID,
            wrappedKeyMaterial: wrappedKey,
            keyAlgorithm: .secureEnclaveP256KeyAgreement,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    )

    let stored = try await store.loadWrappedKey(vaultID: vaultID)

    #expect(stored?.wrappedKeyMaterial == wrappedKey)
    #expect(stored?.wrappedKeyMaterial != rawVaultKey)
    #expect(stored?.keyAlgorithm == .secureEnclaveP256KeyAgreement)
}

@Test func vaultKeychainRequiresLocalAuthenticationBeforeReturningWrappedKey() async throws {
    let store = MemoryWrappedKeyStore()
    let authenticator = RecordingLocalAuthenticator(result: true)
    let vaultID = "vault-1"
    let wrappedKey = WrappedVaultKey(
        vaultID: vaultID,
        wrappedKeyMaterial: Data("wrapped key material".utf8),
        keyAlgorithm: .keychainProtectedData,
        createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let manager = VaultKeychainManager(store: store, authenticator: authenticator)

    try await manager.saveWrappedKey(wrappedKey)
    let unlocked = try await manager.loadWrappedKeyAfterAuthentication(
        vaultID: vaultID,
        reason: "解锁 Monica 保险库"
    )

    #expect(unlocked == wrappedKey)
    #expect(authenticator.reasons == ["解锁 Monica 保险库"])
}

@Test func vaultKeychainDoesNotReturnWrappedKeyWhenAuthenticationFails() async throws {
    let store = MemoryWrappedKeyStore()
    let authenticator = RecordingLocalAuthenticator(result: false)
    let vaultID = "vault-1"
    let wrappedKey = WrappedVaultKey(
        vaultID: vaultID,
        wrappedKeyMaterial: Data("wrapped key material".utf8),
        keyAlgorithm: .keychainProtectedData,
        createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let manager = VaultKeychainManager(store: store, authenticator: authenticator)

    try await manager.saveWrappedKey(wrappedKey)

    await #expect(throws: MonicaSecurityError.localAuthenticationFailed) {
        _ = try await manager.loadWrappedKeyAfterAuthentication(
            vaultID: vaultID,
            reason: "解锁 Monica 保险库"
        )
    }
}

@Test func autoFillIndexKeychainRequiresLocalAuthenticationBeforeReturningKeyMaterial() async throws {
    let store = MemoryAutoFillIndexKeyStore()
    let authenticator = RecordingLocalAuthenticator(result: true)
    let key = AutoFillIndexKeyMaterial(
        vaultID: "vault-1",
        keyIdentifier: "autofill-key-1",
        keyMaterial: Data(repeating: 4, count: 32),
        createdAt: Date(timeIntervalSince1970: 1_800_200_000)
    )
    let manager = AutoFillIndexKeychainManager(store: store, authenticator: authenticator)

    try await manager.saveKeyMaterial(key)
    let unlocked = try await manager.loadKeyMaterialAfterAuthentication(
        vaultID: "vault-1",
        reason: "解锁 Monica 自动填充"
    )

    #expect(unlocked == key)
    #expect(authenticator.reasons == ["解锁 Monica 自动填充"])
}

@Test func autoFillIndexKeychainRejectsInvalidKeyLength() async {
    let store = MemoryAutoFillIndexKeyStore()
    let authenticator = RecordingLocalAuthenticator(result: true)
    let manager = AutoFillIndexKeychainManager(store: store, authenticator: authenticator)

    await #expect(throws: MonicaSecurityError.invalidAutoFillIndexKeyLength(expected: 32, actual: 31)) {
        try await manager.saveKeyMaterial(
            AutoFillIndexKeyMaterial(
                vaultID: "vault-1",
                keyIdentifier: "autofill-key-1",
                keyMaterial: Data(repeating: 4, count: 31),
                createdAt: Date(timeIntervalSince1970: 1_800_200_000)
            )
        )
    }
}

@Test func autoFillIndexKeychainDoesNotReturnKeyMaterialWhenAuthenticationFails() async throws {
    let store = MemoryAutoFillIndexKeyStore()
    let authenticator = RecordingLocalAuthenticator(result: false)
    let manager = AutoFillIndexKeychainManager(store: store, authenticator: authenticator)
    try await manager.saveKeyMaterial(
        AutoFillIndexKeyMaterial(
            vaultID: "vault-1",
            keyIdentifier: "autofill-key-1",
            keyMaterial: Data(repeating: 4, count: 32),
            createdAt: Date(timeIntervalSince1970: 1_800_200_000)
        )
    )

    await #expect(throws: MonicaSecurityError.localAuthenticationFailed) {
        _ = try await manager.loadKeyMaterialAfterAuthentication(
            vaultID: "vault-1",
            reason: "解锁 Monica 自动填充"
        )
    }
}
