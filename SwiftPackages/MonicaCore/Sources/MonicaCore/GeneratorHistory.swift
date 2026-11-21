import CryptoKit
import Foundation
import Security

/// 生成结果的类别；历史条目按类别展示图标与标题。
public enum GeneratorSecretKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case password
    case pin
    case passphrase
    case apiToken
    case username

    public var id: String { rawValue }
}

public struct GeneratorHistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: GeneratorSecretKind
    public let value: String
    public let createdAt: Date
    public let expiresAt: Date?

    public init(
        id: UUID = UUID(),
        kind: GeneratorSecretKind,
        value: String,
        createdAt: Date,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.value = value
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    public func isExpired(at date: Date) -> Bool {
        guard let expiresAt else {
            return false
        }
        return expiresAt <= date
    }
}

/// 历史保留期。过期条目不参与展示，读取与写入时都会清理。
public enum GeneratorHistoryRetention: String, Codable, Sendable, CaseIterable, Identifiable {
    case oneHour
    case oneDay
    case sevenDays
    case thirtyDays
    case never

    public var id: String { rawValue }

    public var expiryInterval: TimeInterval? {
        switch self {
        case .oneHour: 60 * 60
        case .oneDay: 24 * 60 * 60
        case .sevenDays: 7 * 24 * 60 * 60
        case .thirtyDays: 30 * 24 * 60 * 60
        case .never: nil
        }
    }

    /// 每种保留期允许保存的条目上限，避免无限增长。
    public var maximumEntryCount: Int {
        switch self {
        case .oneHour: 20
        case .oneDay: 30
        case .sevenDays: 50
        case .thirtyDays: 100
        case .never: 100
        }
    }
}

public enum GeneratorHistoryError: Error, Sendable, Equatable {
    case vaultLocked
    case invalidVaultIdentifier
    case invalidKeyMaterial
    case corruptedPayload
    case randomFailure
}

public enum GeneratorHistoryKeyMaterial {
    /// AES-256 密钥长度。
    public static let requiredByteCount = 32

    /// 密钥来自 `SecRandomCopyBytes`，不使用时间戳或伪随机数。
    public static func random() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: requiredByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw GeneratorHistoryError.randomFailure
        }
        return Data(bytes)
    }
}

public struct GeneratorHistorySnapshot: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public let version: Int
    public var entries: [GeneratorHistoryEntry]
    public var savedAt: Date

    public init(
        version: Int = GeneratorHistorySnapshot.currentVersion,
        entries: [GeneratorHistoryEntry],
        savedAt: Date
    ) {
        self.version = version
        self.entries = entries
        self.savedAt = savedAt
    }
}

/// 只做加解密的纯结构，便于用固定密钥做确定性测试。
public struct GeneratorHistoryCipher: Sendable {
    public init() {}

    public func seal(
        entries: [GeneratorHistoryEntry],
        keyMaterial: Data,
        context: Data,
        savedAt: Date
    ) throws -> Data {
        guard keyMaterial.count == GeneratorHistoryKeyMaterial.requiredByteCount else {
            throw GeneratorHistoryError.invalidKeyMaterial
        }

        let snapshot = GeneratorHistorySnapshot(entries: entries, savedAt: savedAt)
        let plaintext = try JSONEncoder().encode(snapshot)
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: keyMaterial),
            authenticating: context
        )
        guard let combined = sealed.combined else {
            throw GeneratorHistoryError.corruptedPayload
        }
        return combined
    }

    public func open(
        _ payload: Data,
        keyMaterial: Data,
        context: Data
    ) throws -> GeneratorHistorySnapshot {
        guard keyMaterial.count == GeneratorHistoryKeyMaterial.requiredByteCount else {
            throw GeneratorHistoryError.invalidKeyMaterial
        }

        do {
            let box = try AES.GCM.SealedBox(combined: payload)
            let plaintext = try AES.GCM.open(
                box,
                using: SymmetricKey(data: keyMaterial),
                authenticating: context
            )
            let snapshot = try JSONDecoder().decode(GeneratorHistorySnapshot.self, from: plaintext)
            guard snapshot.version == GeneratorHistorySnapshot.currentVersion else {
                throw GeneratorHistoryError.corruptedPayload
            }
            return snapshot
        } catch let error as GeneratorHistoryError {
            throw error
        } catch {
            throw GeneratorHistoryError.corruptedPayload
        }
    }
}

public protocol GeneratorHistoryPersisting: Sendable {
    func load(vaultID: String) async throws -> Data?
    func save(_ payload: Data, vaultID: String) async throws
    func remove(vaultID: String) async throws
}

/// 把密文写到指定目录。文件名是 vaultID 的 SHA-256 前缀，
/// 避免把 Vault 标识或任何明文写进路径与日志。
public struct FileGeneratorHistoryStore: GeneratorHistoryPersisting {
    public let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public func fileURL(for vaultID: String) throws -> URL {
        let trimmed = vaultID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GeneratorHistoryError.invalidVaultIdentifier
        }
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directoryURL.appendingPathComponent(
            "history-\(name.prefix(32)).bin",
            isDirectory: false
        )
    }

    public func load(vaultID: String) async throws -> Data? {
        let url = try fileURL(for: vaultID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try Data(contentsOf: url)
    }

    public func save(_ payload: Data, vaultID: String) async throws {
        let url = try fileURL(for: vaultID)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try payload.write(to: url, options: writingOptions)
    }

    public func remove(vaultID: String) async throws {
        let url = try fileURL(for: vaultID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }

    private var writingOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtection]
        #else
        [.atomic]
        #endif
    }
}

/// 历史关闭时使用的内存记录：不落盘、不写日志，离开页面即随视图销毁。
public struct GeneratorHistoryLog: Sendable, Equatable {
    public static let defaultMaximumEntryCount = 6

    public let maximumEntryCount: Int
    public private(set) var entries: [GeneratorHistoryEntry]

    public init(maximumEntryCount: Int = GeneratorHistoryLog.defaultMaximumEntryCount) {
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.entries = []
    }

    public mutating func record(
        kind: GeneratorSecretKind,
        value: String,
        createdAt: Date,
        expiresAt: Date?
    ) {
        guard !value.isEmpty else {
            return
        }
        entries.removeAll { $0.kind == kind && $0.value == value }
        entries.insert(
            GeneratorHistoryEntry(kind: kind, value: value, createdAt: createdAt, expiresAt: expiresAt),
            at: 0
        )
        if entries.count > maximumEntryCount {
            entries.removeLast(entries.count - maximumEntryCount)
        }
    }

    public mutating func removeExpired(at date: Date) {
        entries.removeAll { $0.isExpired(at: date) }
    }

    public mutating func removeAll() {
        entries = []
    }
}

/// 历史开关与保留期；只有这两项允许进入 UserDefaults，历史内容永远不进。
public struct GeneratorHistoryPolicy: Sendable, Equatable {
    public var isEnabled: Bool
    public var retention: GeneratorHistoryRetention

    public init(isEnabled: Bool = false, retention: GeneratorHistoryRetention = .oneDay) {
        self.isEnabled = isEnabled
        self.retention = retention
    }

    public var maximumEntryCount: Int {
        retention.maximumEntryCount
    }
}

/// 加密历史的唯一入口。未 `unlock` 时任何读写都抛 `vaultLocked`，
/// 锁库（`lock()`）会立刻丢弃内存中的密钥与标识。
public actor GeneratorHistoryVault {
    private let store: any GeneratorHistoryPersisting
    private let cipher: GeneratorHistoryCipher
    private var unlockedVaultID: String?
    private var keyMaterial: Data?

    public init(
        store: any GeneratorHistoryPersisting,
        cipher: GeneratorHistoryCipher = GeneratorHistoryCipher()
    ) {
        self.store = store
        self.cipher = cipher
    }

    public var isUnlocked: Bool {
        unlockedVaultID != nil && keyMaterial != nil
    }

    public var unlockedVaultIdentifier: String? {
        unlockedVaultID
    }

    public func unlock(vaultID: String, keyMaterial: Data) throws {
        let trimmed = vaultID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GeneratorHistoryError.invalidVaultIdentifier
        }
        guard keyMaterial.count == GeneratorHistoryKeyMaterial.requiredByteCount else {
            throw GeneratorHistoryError.invalidKeyMaterial
        }
        self.unlockedVaultID = trimmed
        self.keyMaterial = keyMaterial
    }

    public func lock() {
        unlockedVaultID = nil
        keyMaterial = nil
    }

    public func entries(
        at date: Date = Date(),
        retention: GeneratorHistoryRetention = .oneDay
    ) async throws -> [GeneratorHistoryEntry] {
        let (vaultID, key) = try unlockedContext()
        guard let payload = try await store.load(vaultID: vaultID) else {
            return []
        }

        let snapshot = try cipher.open(
            payload,
            keyMaterial: key,
            context: contextData(for: vaultID)
        )
        let pruned = prunedEntries(snapshot.entries, at: date, retention: retention)
        if pruned != snapshot.entries {
            try await persist(pruned, vaultID: vaultID, keyMaterial: key, at: date)
        }
        return pruned
    }

    public func record(
        kind: GeneratorSecretKind,
        value: String,
        at date: Date = Date(),
        retention: GeneratorHistoryRetention = .oneDay
    ) async throws -> [GeneratorHistoryEntry] {
        guard !value.isEmpty else {
            return try await entries(at: date, retention: retention)
        }

        var current = try await entries(at: date, retention: retention)
        current.removeAll { $0.kind == kind && $0.value == value }
        current.insert(
            GeneratorHistoryEntry(
                kind: kind,
                value: value,
                createdAt: date,
                expiresAt: retention.expiryInterval.map { date.addingTimeInterval($0) }
            ),
            at: 0
        )
        if current.count > retention.maximumEntryCount {
            current.removeLast(current.count - retention.maximumEntryCount)
        }

        let (vaultID, key) = try unlockedContext()
        try await persist(current, vaultID: vaultID, keyMaterial: key, at: date)
        return current
    }

    public func clear() async throws {
        let (vaultID, _) = try unlockedContext()
        try await store.remove(vaultID: vaultID)
    }

    /// 删除指定 Vault 的密文。销毁数据不需要密钥，因此允许在未解锁时调用，
    /// 用于「关闭历史」时立即清除已落盘内容。
    public func removeStoredData(vaultID: String) async throws {
        try await store.remove(vaultID: vaultID)
    }

    private func unlockedContext() throws -> (vaultID: String, keyMaterial: Data) {
        guard let unlockedVaultID, let keyMaterial else {
            throw GeneratorHistoryError.vaultLocked
        }
        return (unlockedVaultID, keyMaterial)
    }

    private func contextData(for vaultID: String) -> Data {
        Data("monica.generator-history.v1.\(vaultID)".utf8)
    }

    private func persist(
        _ entries: [GeneratorHistoryEntry],
        vaultID: String,
        keyMaterial: Data,
        at date: Date
    ) async throws {
        let payload = try cipher.seal(
            entries: entries,
            keyMaterial: keyMaterial,
            context: contextData(for: vaultID),
            savedAt: date
        )
        try await store.save(payload, vaultID: vaultID)
    }

    private func prunedEntries(
        _ entries: [GeneratorHistoryEntry],
        at date: Date,
        retention: GeneratorHistoryRetention
    ) -> [GeneratorHistoryEntry] {
        var result = entries.filter { !$0.isExpired(at: date) }
        if result.count > retention.maximumEntryCount {
            result = Array(result.prefix(retention.maximumEntryCount))
        }
        return result
    }
}

/// 按开关把记录分发到「加密 Vault」或「仅内存」。关闭时不会向 store 写入任何内容。
public actor GeneratorHistoryCoordinator {
    private let vault: GeneratorHistoryVault
    private var policy: GeneratorHistoryPolicy
    private var log: GeneratorHistoryLog

    public init(
        vault: GeneratorHistoryVault,
        policy: GeneratorHistoryPolicy = GeneratorHistoryPolicy(),
        memoryLimit: Int = GeneratorHistoryLog.defaultMaximumEntryCount
    ) {
        self.vault = vault
        self.policy = policy
        self.log = GeneratorHistoryLog(maximumEntryCount: memoryLimit)
    }

    public var currentPolicy: GeneratorHistoryPolicy {
        policy
    }

    public var isHistoryEnabled: Bool {
        policy.isEnabled
    }

    /// 关闭历史时立即删除已落盘的密文，并把内存记录一起清空。
    public func updatePolicy(_ policy: GeneratorHistoryPolicy) async throws {
        self.policy = policy
        guard !policy.isEnabled else {
            return
        }
        log.removeAll()
        if let vaultID = await vault.unlockedVaultIdentifier {
            try await vault.removeStoredData(vaultID: vaultID)
        }
    }

    public func unlock(vaultID: String, keyMaterial: Data) async throws {
        try await vault.unlock(vaultID: vaultID, keyMaterial: keyMaterial)
    }

    public func lock() async {
        await vault.lock()
        log.removeAll()
    }

    public func record(
        kind: GeneratorSecretKind,
        value: String,
        at date: Date = Date()
    ) async throws -> [GeneratorHistoryEntry] {
        if policy.isEnabled {
            return try await vault.record(
                kind: kind,
                value: value,
                at: date,
                retention: policy.retention
            )
        }

        log.record(
            kind: kind,
            value: value,
            createdAt: date,
            expiresAt: policy.retention.expiryInterval.map { date.addingTimeInterval($0) }
        )
        return log.entries
    }

    public func entries(at date: Date = Date()) async throws -> [GeneratorHistoryEntry] {
        if policy.isEnabled {
            return try await vault.entries(at: date, retention: policy.retention)
        }
        log.removeExpired(at: date)
        return log.entries
    }

    public func clear() async throws {
        log.removeAll()
        if policy.isEnabled {
            try await vault.clear()
        }
    }
}
