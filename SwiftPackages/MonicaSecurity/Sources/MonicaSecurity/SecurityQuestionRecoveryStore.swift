import Foundation
import Security

public struct SecurityQuestionRecoverySetup: Sendable, Codable, Equatable {
    public let vaultID: String
    public let question1ID: Int
    public let question1Text: String
    public let answer1: SecurityQuestionAnswerCredential
    public let question2ID: Int
    public let question2Text: String
    public let answer2: SecurityQuestionAnswerCredential

    public init(
        vaultID: String,
        question1ID: Int,
        question1Text: String,
        answer1: SecurityQuestionAnswerCredential,
        question2ID: Int,
        question2Text: String,
        answer2: SecurityQuestionAnswerCredential
    ) {
        self.vaultID = vaultID
        self.question1ID = question1ID
        self.question1Text = question1Text
        self.answer1 = answer1
        self.question2ID = question2ID
        self.question2Text = question2Text
        self.answer2 = answer2
    }

    public func replacingAnswers(
        answer1: SecurityQuestionAnswerCredential,
        answer2: SecurityQuestionAnswerCredential
    ) -> SecurityQuestionRecoverySetup {
        SecurityQuestionRecoverySetup(
            vaultID: vaultID,
            question1ID: question1ID,
            question1Text: question1Text,
            answer1: answer1,
            question2ID: question2ID,
            question2Text: question2Text,
            answer2: answer2
        )
    }

    /// 记录中是否仍有旧版无盐 SHA-256 答案，需要用户下次答对后迁移。
    public var containsLegacyAnswers: Bool {
        answer1.isLegacy || answer2.isLegacy
    }
}

public protocol SecurityQuestionRecoveryStore: Sendable {
    func save(_ setup: SecurityQuestionRecoverySetup) throws
    func load(vaultID: String) throws -> SecurityQuestionRecoverySetup?
    func delete(vaultID: String) throws
    func loadThrottleState(vaultID: String) -> SecurityQuestionVerificationThrottle.State
    func saveThrottleState(
        _ state: SecurityQuestionVerificationThrottle.State,
        vaultID: String
    ) throws
}

public extension SecurityQuestionRecoveryStore {
    func loadThrottleState(vaultID: String) -> SecurityQuestionVerificationThrottle.State {
        .clear
    }

    func saveThrottleState(
        _ state: SecurityQuestionVerificationThrottle.State,
        vaultID: String
    ) throws {
        // 存储实现可以选择不持久化节流状态。
    }
}

/// 将密保记录保存在钥匙串中的生产实现（`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`，锁定后不可读）。
public final class KeychainSecurityQuestionRecoveryStore: SecurityQuestionRecoveryStore, @unchecked Sendable {
    public static let defaultService = "com.monicapass.monica.security-question-recovery"

    private let service: String
    private let accessGroup: String?

    public init(
        service: String = KeychainSecurityQuestionRecoveryStore.defaultService,
        accessGroup: String? = nil
    ) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func save(_ setup: SecurityQuestionRecoverySetup) throws {
        let data = try JSONEncoder().encode(setup)
        try upsert(data: data, account: credentialAccount(for: setup.vaultID))
    }

    public func load(vaultID: String) throws -> SecurityQuestionRecoverySetup? {
        guard let data = try readItem(account: credentialAccount(for: vaultID)) else {
            return nil
        }
        return try Self.decodeStoredSetup(data)
    }

    public func delete(vaultID: String) throws {
        try deleteItem(account: credentialAccount(for: vaultID))
        try deleteItem(account: throttleAccount(for: vaultID))
    }

    public func loadThrottleState(vaultID: String) -> SecurityQuestionVerificationThrottle.State {
        guard let data = try? readItem(account: throttleAccount(for: vaultID)),
              let state = try? JSONDecoder().decode(
                  SecurityQuestionVerificationThrottle.State.self,
                  from: data
              )
        else {
            return .clear
        }
        return state
    }

    public func saveThrottleState(
        _ state: SecurityQuestionVerificationThrottle.State,
        vaultID: String
    ) throws {
        if state == .clear {
            try deleteItem(account: throttleAccount(for: vaultID))
            return
        }
        let data = try JSONEncoder().encode(state)
        try upsert(data: data, account: throttleAccount(for: vaultID))
    }

    static func decodeStoredSetup(_ data: Data) throws -> SecurityQuestionRecoverySetup {
        do {
            return try JSONDecoder().decode(SecurityQuestionRecoverySetup.self, from: data)
        } catch {
            throw SecurityQuestionCredentialError.corruptedStoredRecord
        }
    }

    private func credentialAccount(for vaultID: String) -> String {
        "credential." + vaultID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func throttleAccount(for vaultID: String) -> String {
        "throttle." + vaultID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func readItem(account: String) throws -> Data? {
        var query = baseQuery(account: account)
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
            throw SecurityQuestionCredentialError.corruptedStoredRecord
        }
        return data
    }

    private func upsert(data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw MonicaSecurityError.keychainUnexpectedStatus(addStatus)
            }
        default:
            throw MonicaSecurityError.keychainUnexpectedStatus(updateStatus)
        }
    }

    private func deleteItem(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MonicaSecurityError.keychainUnexpectedStatus(status)
        }
    }
}

/// 旧版 UserDefaults 明文记录（`monica.securityQuestions.<vaultID>`）的只读适配器，仅用于一次性迁移。
public final class UserDefaultsLegacySecurityQuestionRecoveryStore: SecurityQuestionRecoveryStore, @unchecked Sendable {
    public static let keyPrefix = "monica.securityQuestions."

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func save(_ setup: SecurityQuestionRecoverySetup) throws {
        throw SecurityQuestionCredentialError.legacyStoreReadOnly
    }

    public func load(vaultID: String) throws -> SecurityQuestionRecoverySetup? {
        guard let data = userDefaults.data(forKey: key(for: vaultID)) else {
            return nil
        }
        let record: LegacyRecord
        do {
            record = try JSONDecoder().decode(LegacyRecord.self, from: data)
        } catch {
            throw SecurityQuestionCredentialError.corruptedStoredRecord
        }
        return SecurityQuestionRecoverySetup(
            vaultID: record.vaultID,
            question1ID: record.question1ID,
            question1Text: record.question1Text,
            answer1: .legacyUnsaltedSHA256(hexDigest: record.answer1Hash.lowercased()),
            question2ID: record.question2ID,
            question2Text: record.question2Text,
            answer2: .legacyUnsaltedSHA256(hexDigest: record.answer2Hash.lowercased())
        )
    }

    public func delete(vaultID: String) throws {
        userDefaults.removeObject(forKey: key(for: vaultID))
    }

    private func key(for vaultID: String) -> String {
        Self.keyPrefix + vaultID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct LegacyRecord: Decodable {
        let vaultID: String
        let question1ID: Int
        let question1Text: String
        let answer1Hash: String
        let question2ID: Int
        let question2Text: String
        let answer2Hash: String
    }
}

/// 读取时优先钥匙串、其次旧 UserDefaults；写入先落钥匙串再删除旧记录，避免迁移过程中丢失密保答案。
public struct MigratingSecurityQuestionRecoveryStore: SecurityQuestionRecoveryStore, Sendable {
    public let primary: any SecurityQuestionRecoveryStore
    public let legacy: any SecurityQuestionRecoveryStore

    public init(
        primary: any SecurityQuestionRecoveryStore = KeychainSecurityQuestionRecoveryStore(),
        legacy: any SecurityQuestionRecoveryStore = UserDefaultsLegacySecurityQuestionRecoveryStore()
    ) {
        self.primary = primary
        self.legacy = legacy
    }

    public func save(_ setup: SecurityQuestionRecoverySetup) throws {
        try primary.save(setup)
        try? legacy.delete(vaultID: setup.vaultID)
    }

    public func load(vaultID: String) throws -> SecurityQuestionRecoverySetup? {
        if let setup = try primary.load(vaultID: vaultID) {
            return setup
        }
        return try legacy.load(vaultID: vaultID)
    }

    public func delete(vaultID: String) throws {
        try primary.delete(vaultID: vaultID)
        try? legacy.delete(vaultID: vaultID)
    }

    public func loadThrottleState(vaultID: String) -> SecurityQuestionVerificationThrottle.State {
        primary.loadThrottleState(vaultID: vaultID)
    }

    public func saveThrottleState(
        _ state: SecurityQuestionVerificationThrottle.State,
        vaultID: String
    ) throws {
        try primary.saveThrottleState(state, vaultID: vaultID)
    }
}

public final class MemorySecurityQuestionRecoveryStore: SecurityQuestionRecoveryStore, @unchecked Sendable {
    private let lock = NSLock()
    private var setups: [String: SecurityQuestionRecoverySetup] = [:]
    private var throttleStates: [String: SecurityQuestionVerificationThrottle.State] = [:]

    public init() {}

    public func save(_ setup: SecurityQuestionRecoverySetup) throws {
        lock.lock()
        setups[setup.vaultID] = setup
        lock.unlock()
    }

    public func load(vaultID: String) throws -> SecurityQuestionRecoverySetup? {
        lock.lock()
        defer { lock.unlock() }
        return setups[vaultID.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    public func delete(vaultID: String) throws {
        lock.lock()
        setups.removeValue(forKey: vaultID.trimmingCharacters(in: .whitespacesAndNewlines))
        throttleStates.removeValue(forKey: vaultID.trimmingCharacters(in: .whitespacesAndNewlines))
        lock.unlock()
    }

    public func loadThrottleState(vaultID: String) -> SecurityQuestionVerificationThrottle.State {
        lock.lock()
        defer { lock.unlock() }
        return throttleStates[vaultID.trimmingCharacters(in: .whitespacesAndNewlines)] ?? .clear
    }

    public func saveThrottleState(
        _ state: SecurityQuestionVerificationThrottle.State,
        vaultID: String
    ) throws {
        lock.lock()
        throttleStates[vaultID.trimmingCharacters(in: .whitespacesAndNewlines)] = state
        lock.unlock()
    }
}
