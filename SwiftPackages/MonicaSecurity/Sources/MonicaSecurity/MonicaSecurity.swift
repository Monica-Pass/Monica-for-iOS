import Foundation
import LocalAuthentication
import Security

public enum MonicaSecurityBaseline {
    public static let biometricPolicy = "LocalAuthentication 只包裹密钥材料，生物识别不是保险库秘密本身"
}

public enum MonicaSecurityError: Error, Sendable, Equatable, LocalizedError {
    case emptyVaultID
    case emptyWrappedKeyMaterial
    case wrappedKeyNotFound
    case emptyAutoFillIndexKeyIdentifier
    case autoFillIndexKeyMaterialNotFound
    case invalidAutoFillIndexKeyLength(expected: Int, actual: Int)
    case localAuthenticationFailed
    case keychainUnexpectedStatus(Int32)

    public var errorDescription: String? {
        switch self {
        case .emptyVaultID:
            return "保险库 ID 不能为空。"
        case .emptyWrappedKeyMaterial:
            return "包装后的密钥材料不能为空。"
        case .wrappedKeyNotFound:
            return "未找到包装后的密钥材料。"
        case .emptyAutoFillIndexKeyIdentifier:
            return "自动填充索引密钥标识不能为空。"
        case .autoFillIndexKeyMaterialNotFound:
            return "未找到自动填充索引密钥材料。"
        case .invalidAutoFillIndexKeyLength(let expected, let actual):
            return "自动填充索引密钥材料必须是 \(expected) 字节，当前为 \(actual) 字节。"
        case .localAuthenticationFailed:
            return "本地认证失败。"
        case .keychainUnexpectedStatus(let status):
            return "Keychain 返回了异常状态 \(status)。"
        }
    }
}

public enum WrappedVaultKeyAlgorithm: String, Sendable, Codable, Equatable {
    case keychainProtectedData
    case secureEnclaveP256KeyAgreement
}

public struct WrappedVaultKey: Sendable, Codable, Equatable {
    public let vaultID: String
    public let wrappedKeyMaterial: Data
    public let keyAlgorithm: WrappedVaultKeyAlgorithm
    public let createdAt: Date

    public init(
        vaultID: String,
        wrappedKeyMaterial: Data,
        keyAlgorithm: WrappedVaultKeyAlgorithm,
        createdAt: Date
    ) {
        self.vaultID = vaultID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.wrappedKeyMaterial = wrappedKeyMaterial
        self.keyAlgorithm = keyAlgorithm
        self.createdAt = createdAt
    }
}

public protocol WrappedVaultKeyStore: Sendable {
    func saveWrappedKey(_ key: WrappedVaultKey) async throws
    func loadWrappedKey(vaultID: String) async throws -> WrappedVaultKey?
    func deleteWrappedKey(vaultID: String) async throws
}

public protocol MonicaLocalAuthenticator: Sendable {
    func authenticate(reason: String) async throws
}

public struct AutoFillIndexKeyMaterial: Sendable, Codable, Equatable {
    public static let requiredByteCount = 32

    public let vaultID: String
    public let keyIdentifier: String
    public let keyMaterial: Data
    public let createdAt: Date

    public init(
        vaultID: String,
        keyIdentifier: String,
        keyMaterial: Data,
        createdAt: Date
    ) {
        self.vaultID = vaultID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.keyIdentifier = keyIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        self.keyMaterial = keyMaterial
        self.createdAt = createdAt
    }
}

public protocol AutoFillIndexKeyStore: Sendable {
    func saveKeyMaterial(_ keyMaterial: AutoFillIndexKeyMaterial) async throws
    func loadKeyMaterial(vaultID: String) async throws -> AutoFillIndexKeyMaterial?
    func deleteKeyMaterial(vaultID: String) async throws
}

public struct VaultKeychainManager<Store: WrappedVaultKeyStore, Authenticator: MonicaLocalAuthenticator>: Sendable {
    private let store: Store
    private let authenticator: Authenticator

    public init(store: Store, authenticator: Authenticator) {
        self.store = store
        self.authenticator = authenticator
    }

    public func saveWrappedKey(_ key: WrappedVaultKey) async throws {
        try validateWrappedKey(key)
        try await store.saveWrappedKey(key)
    }

    public func loadWrappedKeyAfterAuthentication(
        vaultID: String,
        reason: String
    ) async throws -> WrappedVaultKey {
        try await authenticator.authenticate(reason: reason)
        guard let key = try await store.loadWrappedKey(vaultID: vaultID) else {
            throw MonicaSecurityError.wrappedKeyNotFound
        }
        return key
    }

    public func deleteWrappedKey(vaultID: String) async throws {
        try await store.deleteWrappedKey(vaultID: vaultID)
    }

    private func validateWrappedKey(_ key: WrappedVaultKey) throws {
        guard !key.vaultID.isEmpty else {
            throw MonicaSecurityError.emptyVaultID
        }
        guard !key.wrappedKeyMaterial.isEmpty else {
            throw MonicaSecurityError.emptyWrappedKeyMaterial
        }
    }
}

public struct AutoFillIndexKeychainManager<Store: AutoFillIndexKeyStore, Authenticator: MonicaLocalAuthenticator>: Sendable {
    private let store: Store
    private let authenticator: Authenticator

    public init(store: Store, authenticator: Authenticator) {
        self.store = store
        self.authenticator = authenticator
    }

    public func saveKeyMaterial(_ keyMaterial: AutoFillIndexKeyMaterial) async throws {
        try validateKeyMaterial(keyMaterial)
        try await store.saveKeyMaterial(keyMaterial)
    }

    public func loadKeyMaterialAfterAuthentication(
        vaultID: String,
        reason: String
    ) async throws -> AutoFillIndexKeyMaterial {
        try await authenticator.authenticate(reason: reason)
        guard let keyMaterial = try await store.loadKeyMaterial(vaultID: vaultID) else {
            throw MonicaSecurityError.autoFillIndexKeyMaterialNotFound
        }
        return keyMaterial
    }

    public func deleteKeyMaterial(vaultID: String) async throws {
        try await store.deleteKeyMaterial(vaultID: vaultID)
    }

    private func validateKeyMaterial(_ keyMaterial: AutoFillIndexKeyMaterial) throws {
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
}

public actor MemoryWrappedKeyStore: WrappedVaultKeyStore {
    private var keys: [String: WrappedVaultKey] = [:]

    public init() {}

    public func saveWrappedKey(_ key: WrappedVaultKey) async throws {
        keys[key.vaultID] = key
    }

    public func loadWrappedKey(vaultID: String) async throws -> WrappedVaultKey? {
        keys[vaultID.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    public func deleteWrappedKey(vaultID: String) async throws {
        keys.removeValue(forKey: vaultID.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public actor MemoryAutoFillIndexKeyStore: AutoFillIndexKeyStore {
    private var keys: [String: AutoFillIndexKeyMaterial] = [:]

    public init() {}

    public func saveKeyMaterial(_ keyMaterial: AutoFillIndexKeyMaterial) async throws {
        keys[keyMaterial.vaultID] = keyMaterial
    }

    public func loadKeyMaterial(vaultID: String) async throws -> AutoFillIndexKeyMaterial? {
        keys[vaultID.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    public func deleteKeyMaterial(vaultID: String) async throws {
        keys.removeValue(forKey: vaultID.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public final class RecordingLocalAuthenticator: MonicaLocalAuthenticator, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedReasons: [String] = []
    private let result: Bool
    public var reasons: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedReasons
    }

    public init(result: Bool) {
        self.result = result
    }

    public func authenticate(reason: String) throws {
        lock.lock()
        recordedReasons.append(reason)
        lock.unlock()
        guard result else {
            throw MonicaSecurityError.localAuthenticationFailed
        }
    }
}

public final class KeychainWrappedVaultKeyStore: WrappedVaultKeyStore, @unchecked Sendable {
    private let service: String
    private let accessGroup: String?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        service: String = "ru.takagi.monica.vault-unlock",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func saveWrappedKey(_ key: WrappedVaultKey) async throws {
        let data = try encoder.encode(key)
        var query = baseQuery(vaultID: key.vaultID)
        SecItemDelete(query as CFDictionary)

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MonicaSecurityError.keychainUnexpectedStatus(status)
        }
    }

    public func loadWrappedKey(vaultID: String) async throws -> WrappedVaultKey? {
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
            throw MonicaSecurityError.wrappedKeyNotFound
        }
        return try decoder.decode(WrappedVaultKey.self, from: data)
    }

    public func deleteWrappedKey(vaultID: String) async throws {
        let status = SecItemDelete(baseQuery(vaultID: vaultID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
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

public final class KeychainAutoFillIndexKeyStore: AutoFillIndexKeyStore, @unchecked Sendable {
    private let service: String
    private let accessGroup: String?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        service: String = "ru.takagi.monica.autofill-index-key",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func saveKeyMaterial(_ keyMaterial: AutoFillIndexKeyMaterial) async throws {
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

    public func loadKeyMaterial(vaultID: String) async throws -> AutoFillIndexKeyMaterial? {
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

    public func deleteKeyMaterial(vaultID: String) async throws {
        let status = SecItemDelete(baseQuery(vaultID: vaultID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
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

public final class DeviceOwnerLocalAuthenticator: MonicaLocalAuthenticator, @unchecked Sendable {
    private let policy: LAPolicy

    public init(policy: LAPolicy = .deviceOwnerAuthentication) {
        self.policy = policy
    }

    public func authenticate(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(policy, error: &error) else {
            throw MonicaSecurityError.localAuthenticationFailed
        }

        do {
            try await context.evaluatePolicy(policy, localizedReason: reason)
        } catch {
            throw MonicaSecurityError.localAuthenticationFailed
        }
    }
}
