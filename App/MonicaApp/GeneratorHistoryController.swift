import Foundation
import MonicaCore
import Observation
import Security

/// 生成历史的 App 侧状态（#24）。
///
/// 隐私边界：
/// - 开关与保留期属于普通偏好，可以进 `UserDefaults`；
/// - 历史**内容**绝不写明文：关闭时只在内存里，开启时用 AES-GCM 加密后
///   按 Vault 隔离存盘，密钥保存在钥匙串（`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`）；
/// - 锁库后不再持有密钥，读取直接失败，界面不显示旧内容。
@MainActor
@Observable
final class GeneratorHistoryController {
    static let enabledDefaultsKey = "monica.generatorHistory.enabled"
    static let retentionDefaultsKey = "monica.generatorHistory.retention"
    /// 设置里的「按数据类型清空」删掉密文后广播，让本进程内其它界面丢弃旧缓存。
    static let didClearNotification = Notification.Name("monica.generatorHistory.didClear")

    private(set) var entries: [GeneratorHistoryEntry] = []
    private(set) var isEnabled: Bool
    private(set) var retention: GeneratorHistoryRetention
    /// 当前 Vault 是否已解锁（未解锁时开启的历史不可读）。
    private(set) var isVaultUnlocked = false
    private(set) var errorMessage: String?

    private let defaults: UserDefaults
    private let keychain: GeneratorHistoryKeychain
    private let store: FileGeneratorHistoryStore
    private let coordinator: GeneratorHistoryCoordinator
    private var activeVaultID: String?

    init(
        defaults: UserDefaults = .standard,
        directoryURL: URL? = nil,
        keychain: GeneratorHistoryKeychain = GeneratorHistoryKeychain()
    ) {
        self.defaults = defaults
        self.keychain = keychain

        let resolvedDirectory = directoryURL ?? Self.defaultDirectoryURL()
        let store = FileGeneratorHistoryStore(directoryURL: resolvedDirectory)
        self.store = store

        let retention = GeneratorHistoryRetention(
            rawValue: defaults.string(forKey: Self.retentionDefaultsKey) ?? ""
        ) ?? .oneDay
        let isEnabled = defaults.bool(forKey: Self.enabledDefaultsKey)
        self.retention = retention
        self.isEnabled = isEnabled
        self.coordinator = GeneratorHistoryCoordinator(
            vault: GeneratorHistoryVault(store: store),
            policy: GeneratorHistoryPolicy(isEnabled: isEnabled, retention: retention)
        )
    }

    /// 开启历史后，只有 Vault 解锁且拿到作用域标识时才可读。
    var isHistoryAccessible: Bool {
        !isEnabled || (isVaultUnlocked && activeVaultID != nil)
    }

    /// 与 Vault 生命周期同步：解锁时准备密钥，锁库或关闭 Vault 时清空内存与密钥。
    func sync(vaultID: String?, isVaultUnlocked unlocked: Bool) async {
        guard unlocked, let vaultID, !vaultID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            activeVaultID = nil
            isVaultUnlocked = false
            entries = []
            await coordinator.lock()
            return
        }

        if activeVaultID != vaultID {
            await coordinator.lock()
            entries = []
            activeVaultID = vaultID
        }
        isVaultUnlocked = true

        guard isEnabled else {
            await refreshEntries()
            return
        }
        await unlockEncryptedHistory(vaultID: vaultID)
    }

    /// 锁库：立即释放密钥与内存历史，之后的读取会抛 `vaultLocked`。
    func lock() async {
        isVaultUnlocked = false
        entries = []
        await coordinator.lock()
    }

    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)

        do {
            try await coordinator.updatePolicy(
                GeneratorHistoryPolicy(isEnabled: enabled, retention: retention)
            )
        } catch {
            errorMessage = Self.message(for: error)
        }

        guard enabled else {
            // 关闭历史属于破坏性操作：连密文与钥匙串密钥一起删除，避免留下旧内容。
            await discardPersistedHistory()
            return
        }

        guard isVaultUnlocked, let vaultID = activeVaultID else {
            return
        }
        await unlockEncryptedHistory(vaultID: vaultID)
    }

    func setRetention(_ retention: GeneratorHistoryRetention) async {
        guard retention != self.retention else { return }
        self.retention = retention
        defaults.set(retention.rawValue, forKey: Self.retentionDefaultsKey)

        // 关闭历史时保留期只影响后续记录，不能借此清空当前内存历史。
        guard isEnabled else { return }
        do {
            try await coordinator.updatePolicy(
                GeneratorHistoryPolicy(isEnabled: true, retention: retention)
            )
            await refreshEntries()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func record(kind: GeneratorSecretKind, value: String) async {
        guard !value.isEmpty else { return }
        do {
            entries = try await coordinator.record(kind: kind, value: value)
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func clear() async {
        do {
            try await coordinator.clear()
            entries = []
            errorMessage = nil
        } catch {
            entries = []
            errorMessage = Self.message(for: error)
        }
    }

    func refreshEntries() async {
        do {
            entries = try await coordinator.entries()
            errorMessage = nil
        } catch {
            entries = []
            errorMessage = Self.message(for: error)
        }
    }

    /// 设置里的「按数据类型清空」删除了该 Vault 的加密生成历史后调用。
    ///
    /// 只删除密文，不删除钥匙串密钥（历史可能继续记录）；同时让本实例丢弃内存缓存，
    /// 并广播通知，让生成器页面的控制器重新同步。
    func clearPersistedHistory(forVaultID vaultID: String) async {
        let trimmed = vaultID.trimmingCharacters(in: .whitespacesAndNewlines)
        entries = []
        errorMessage = nil
        guard !trimmed.isEmpty else { return }

        try? await store.remove(vaultID: trimmed)
        if activeVaultID == trimmed {
            await coordinator.lock()
            isVaultUnlocked = false
        }
        NotificationCenter.default.post(name: Self.didClearNotification, object: nil)
    }

    private func unlockEncryptedHistory(vaultID: String) async {
        do {
            let material = try keychain.keyMaterial(for: vaultID)
            try await coordinator.unlock(vaultID: vaultID, keyMaterial: material)
            await refreshEntries()
        } catch {
            entries = []
            errorMessage = Self.message(for: error)
        }
    }

    private func discardPersistedHistory() async {
        entries = []
        guard let vaultID = activeVaultID else { return }
        try? await store.remove(vaultID: vaultID)
        do {
            try keychain.removeKeyMaterial(for: vaultID)
        } catch {
            // 删不掉钥匙串条目只影响之后的读取，不记录任何历史内容。
        }
    }

    private static func defaultDirectoryURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("GeneratorHistory", isDirectory: true)
    }

    private static func message(for error: Error) -> String {
        if let historyError = error as? GeneratorHistoryError {
            switch historyError {
            case .vaultLocked:
                return String(localized: "锁库后无法访问生成历史")
            case .invalidVaultIdentifier:
                return String(localized: "尚未打开 Vault，生成历史不可用")
            case .invalidKeyMaterial, .corruptedPayload:
                return String(localized: "生成历史密钥或密文损坏，已停止读取")
            case .randomFailure:
                return String(localized: "安全随机数不可用，请重试")
            }
        }
        return String(localized: "生成历史暂不可用")
    }
}

/// 生成历史密钥的钥匙串读写。
///
/// 每个 Vault 一把 32 字节密钥，`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`：
/// 设备锁定时读不到，也不会随备份迁移到其他设备。
struct GeneratorHistoryKeychain: Sendable {
    static let defaultService = "com.monicapass.monica.generator-history"

    let service: String

    init(service: String = defaultService) {
        self.service = service
    }

    func keyMaterial(for vaultID: String) throws -> Data {
        if let existing = try load(vaultID: vaultID) {
            return existing
        }
        let material = try GeneratorHistoryKeyMaterial.random()
        try save(material, vaultID: vaultID)
        return material
    }

    func removeKeyMaterial(for vaultID: String) throws {
        let status = SecItemDelete(baseQuery(vaultID: vaultID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GeneratorHistoryError.invalidKeyMaterial
        }
    }

    private func load(vaultID: String) throws -> Data? {
        var query = baseQuery(vaultID: vaultID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  data.count == GeneratorHistoryKeyMaterial.requiredByteCount else {
                throw GeneratorHistoryError.invalidKeyMaterial
            }
            return data
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed, errSecNotAvailable:
            throw GeneratorHistoryError.vaultLocked
        default:
            throw GeneratorHistoryError.invalidKeyMaterial
        }
    }

    private func save(_ material: Data, vaultID: String) throws {
        SecItemDelete(baseQuery(vaultID: vaultID) as CFDictionary)

        var query = baseQuery(vaultID: vaultID)
        query[kSecValueData as String] = material
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw status == errSecInteractionNotAllowed
                ? GeneratorHistoryError.vaultLocked
                : GeneratorHistoryError.invalidKeyMaterial
        }
    }

    private func baseQuery(vaultID: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultID,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }
}
