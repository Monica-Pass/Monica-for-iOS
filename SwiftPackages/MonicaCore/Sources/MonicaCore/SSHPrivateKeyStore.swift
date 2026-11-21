import Foundation
import Security

// MARK: - 引用格式

/// SSH 私钥在条目里的引用格式（#154）。
///
/// 条目只保存 `monica-ssh://<uuid>`，具体私钥文本放在 Keychain 里，
/// 与 Passkey 的 `monica-passkey://<credentialID>` 思路一致。
public enum SSHPrivateKeyReference {
    public static let scheme = "monica-ssh"

    public static func reference(for identifier: String) -> String {
        "\(scheme)://\(identifier)"
    }

    /// 从引用里取回 Keychain account；格式不对时返回 nil。
    public static func identifier(from reference: String) -> String? {
        let prefix = "\(scheme)://"
        guard reference.hasPrefix(prefix) else { return nil }
        let identifier = String(reference.dropFirst(prefix.count))
        guard !identifier.isEmpty,
              identifier.count <= 128,
              identifier.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else {
            return nil
        }
        return identifier
    }

    public static func isReference(_ value: String) -> Bool {
        identifier(from: value) != nil
    }

    /// Keychain account 的基本约束：非空、无空白字符、长度不超过 128。
    public static func isValidIdentifier(_ identifier: String) -> Bool {
        !identifier.isEmpty
            && identifier.count <= 128
            && identifier.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }
}

// MARK: - 存储抽象

/// SSH 私钥文本的持久化抽象（#154）。
///
/// 实现必须把私钥放到 Keychain（或等价的系统加密容器）里，
/// 不允许写 `UserDefaults`、明文文件、日志或缓存。
public protocol SSHPrivateKeyStore: Sendable {
    /// 保存并返回写进条目的引用。
    @discardableResult
    func savePrivateKey(_ privateKey: String, identifier: String) throws -> String
    func loadPrivateKey(reference: String) throws -> String?
    /// 删除不存在的私钥不算错误：回滚必须幂等。
    func deletePrivateKey(reference: String) throws
}

public enum SSHPrivateKeyStoreError: Error, Sendable, Equatable {
    case invalidReference
    case privateKeyNotFound
    case keychainUnexpectedStatus(OSStatus)
}

/// 测试、预览与「尚未保存」场景使用的内存实现。
public final class MemorySSHPrivateKeyStore: SSHPrivateKeyStore, @unchecked Sendable {
    private var privateKeys: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    @discardableResult
    public func savePrivateKey(_ privateKey: String, identifier: String) throws -> String {
        guard SSHPrivateKeyReference.isValidIdentifier(identifier) else {
            throw SSHPrivateKeyStoreError.invalidReference
        }
        lock.lock()
        defer { lock.unlock() }
        privateKeys[identifier] = privateKey
        return SSHPrivateKeyReference.reference(for: identifier)
    }

    public func loadPrivateKey(reference: String) throws -> String? {
        guard let identifier = SSHPrivateKeyReference.identifier(from: reference) else {
            throw SSHPrivateKeyStoreError.invalidReference
        }
        lock.lock()
        defer { lock.unlock() }
        return privateKeys[identifier]
    }

    public func deletePrivateKey(reference: String) throws {
        guard let identifier = SSHPrivateKeyReference.identifier(from: reference) else {
            throw SSHPrivateKeyStoreError.invalidReference
        }
        lock.lock()
        defer { lock.unlock() }
        privateKeys[identifier] = nil
    }

    /// 测试辅助：内存里是否还留着某把私钥。
    public func contains(reference: String) -> Bool {
        guard let identifier = SSHPrivateKeyReference.identifier(from: reference) else {
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        return privateKeys[identifier] != nil
    }
}

/// Keychain 实现（#154）。
///
/// - 专用 service：与 Passkey、自动填充索引等既有条目隔离，便于单独清理。
/// - `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`：锁屏后不可读，且不随 iCloud Keychain
///   同步到其他设备——私钥不离开本机。
/// - 不做 `SecItemUpdate`：每次生成都是新的引用 id，覆盖语义只会掩盖 id 复用错误。
public final class KeychainSSHPrivateKeyStore: SSHPrivateKeyStore, @unchecked Sendable {
    public static let defaultService = "com.monicapass.monica.ssh-private-keys"

    private let service: String
    private let accessGroup: String?

    public init(
        service: String = KeychainSSHPrivateKeyStore.defaultService,
        accessGroup: String? = nil
    ) {
        self.service = service
        self.accessGroup = accessGroup
    }

    @discardableResult
    public func savePrivateKey(_ privateKey: String, identifier: String) throws -> String {
        guard SSHPrivateKeyReference.isValidIdentifier(identifier) else {
            throw SSHPrivateKeyStoreError.invalidReference
        }
        let reference = SSHPrivateKeyReference.reference(for: identifier)
        SecItemDelete(baseQuery(identifier: identifier) as CFDictionary)

        var query = baseQuery(identifier: identifier)
        query[kSecValueData as String] = Data(privateKey.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SSHPrivateKeyStoreError.keychainUnexpectedStatus(status)
        }
        return reference
    }

    public func loadPrivateKey(reference: String) throws -> String? {
        guard let identifier = SSHPrivateKeyReference.identifier(from: reference) else {
            throw SSHPrivateKeyStoreError.invalidReference
        }
        var query = baseQuery(identifier: identifier)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw SSHPrivateKeyStoreError.keychainUnexpectedStatus(status)
        }
        guard let data = item as? Data,
              let text = String(data: data, encoding: .utf8)
        else {
            throw SSHPrivateKeyStoreError.privateKeyNotFound
        }
        return text
    }

    public func deletePrivateKey(reference: String) throws {
        guard let identifier = SSHPrivateKeyReference.identifier(from: reference) else {
            throw SSHPrivateKeyStoreError.invalidReference
        }
        let status = SecItemDelete(baseQuery(identifier: identifier) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SSHPrivateKeyStoreError.keychainUnexpectedStatus(status)
        }
    }

    private func baseQuery(identifier: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identifier,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
