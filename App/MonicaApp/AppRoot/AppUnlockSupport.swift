//
//  AppUnlockSupport.swift
//  Monica
//
//  解锁流程：安全问题、生物识别能力与偏好、记忆库记录、钥匙串状态与自动锁定策略。
//

import MonicaMDBX
import MonicaSecurity
import MonicaStorage
import Foundation
import LocalAuthentication

struct SecurityQuestionOption: Identifiable, Sendable, Equatable {
    let id: Int
    let text: String
}

// 密保记录、答案规范化与 KDF 验证由 MonicaSecurity 提供（#59）。
enum ForgotPasswordRecoveryStep: Sendable, Equatable {
    case none
    case verifySecurityQuestions
    case resetPassword
}

enum FirstTimePasswordSetupStep: Sendable, Equatable {
    case enterPassword
    case confirmPassword
}

enum BiometricUnlockKind: Sendable, Equatable {
    case faceID
    case touchID

    var displayName: String {
        switch self {
        case .faceID:
            return "Face ID"
        case .touchID:
            return "Touch ID"
        }
    }

    var systemImage: String {
        switch self {
        case .faceID:
            return "faceid"
        case .touchID:
            return "touchid"
        }
    }
}

enum BiometricUnlockCapability: Sendable, Equatable {
    case unavailable
    case available(BiometricUnlockKind)

    var kind: BiometricUnlockKind? {
        if case .available(let kind) = self {
            return kind
        }
        return nil
    }
}

struct RememberedVaultRecord: Sendable, Codable, Equatable {
    let fileURL: URL
    let displayName: String
    let vaultID: String
}

protocol RememberedVaultStore: Sendable {
    func load() throws -> RememberedVaultRecord?
    func save(_ record: RememberedVaultRecord) throws
    func delete() throws
}

protocol BiometricUnlockPreferenceStore: Sendable {
    func loadIsEnabled() -> Bool
    func saveIsEnabled(_ isEnabled: Bool)
}

protocol BiometricUnlockAuthorizer: Sendable {
    func authenticate(reason: String) async throws
}

enum FirstTimePasswordSetupError: Error, Sendable, Equatable, LocalizedError {
    case passwordMismatch

    var errorDescription: String? {
        switch self {
        case .passwordMismatch:
            return String(localized: "两次输入的主密码不一致。")
        }
    }
}

enum SecurityQuestionRecoveryError: Error, Sendable, Equatable, LocalizedError {
    case duplicateQuestions
    case missingAnswers
    case missingSecurityQuestions
    case verificationRequired
    case passwordMismatch

    var errorDescription: String? {
        switch self {
        case .duplicateQuestions:
            return String(localized: "请选择两道不同的密保问题。")
        case .missingAnswers:
            return String(localized: "请填写两道密保问题答案。")
        case .missingSecurityQuestions:
            return String(localized: "当前保险库未设置密保问题。")
        case .verificationRequired:
            return String(localized: "请先通过密保问题验证。")
        case .passwordMismatch:
            return String(localized: "两次输入的新密码不一致。")
        }
    }
}

final class UserDefaultsRememberedVaultStore: RememberedVaultStore, @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let key = "monica.rememberedVault"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func load() throws -> RememberedVaultRecord? {
        guard let data = userDefaults.data(forKey: key) else {
            return nil
        }
        return try JSONDecoder().decode(RememberedVaultRecord.self, from: data)
    }

    func save(_ record: RememberedVaultRecord) throws {
        userDefaults.set(try JSONEncoder().encode(record), forKey: key)
    }

    func delete() throws {
        userDefaults.removeObject(forKey: key)
    }
}

final class MemoryRememberedVaultStore: RememberedVaultStore, @unchecked Sendable {
    private(set) var record: RememberedVaultRecord?

    init(record: RememberedVaultRecord? = nil) {
        self.record = record
    }

    var savedDescriptor: LocalVaultDescriptor? {
        record.map {
            LocalVaultDescriptor(fileURL: $0.fileURL, displayName: $0.displayName)
        }
    }

    func load() throws -> RememberedVaultRecord? {
        record
    }

    func save(_ record: RememberedVaultRecord) throws {
        self.record = record
    }

    func delete() throws {
        record = nil
    }
}

final class UserDefaultsBiometricUnlockPreferenceStore: BiometricUnlockPreferenceStore, @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let key = "monica.biometricUnlockEnabled"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func loadIsEnabled() -> Bool {
        userDefaults.bool(forKey: key)
    }

    func saveIsEnabled(_ isEnabled: Bool) {
        userDefaults.set(isEnabled, forKey: key)
    }
}

final class MemoryBiometricUnlockPreferenceStore: BiometricUnlockPreferenceStore, @unchecked Sendable {
    private(set) var isEnabled: Bool

    init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    func loadIsEnabled() -> Bool {
        isEnabled
    }

    func saveIsEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
    }
}

struct DeviceBiometricUnlockAuthorizer: BiometricUnlockAuthorizer {
    func authenticate(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw MonicaSecurityError.localAuthenticationFailed
        }

        do {
            try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
        } catch {
            throw MonicaSecurityError.localAuthenticationFailed
        }
    }
}

func deviceBiometricUnlockCapability() -> BiometricUnlockCapability {
    let context = LAContext()
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
        return .unavailable
    }

    switch context.biometryType {
    case .faceID, .opticID:
        return .available(.faceID)
    case .touchID:
        return .available(.touchID)
    case .none:
        return .unavailable
    @unknown default:
        return .unavailable
    }
}

enum VaultKeychainState: Sendable, Equatable {
    case idle
    case running
    case saved(String)
    case unlocked(String)
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            return String(localized: "就绪")
        case .running:
            return String(localized: "处理中")
        case .saved(let vaultID):
            return String(localized: "已保存 \(vaultID.prefix(8))")
        case .unlocked(let vaultID):
            return String(localized: "已解锁 \(vaultID.prefix(8))")
        case .failed(let message):
            return message
        }
    }

    var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }
}

enum AppVaultKeychainError: Error, Sendable, Equatable, LocalizedError {
    case vaultLocked
    case vaultAlreadyUnlocked
    case keychainUnavailable
    case wrappedKeyProviderUnavailable
    case rememberedVaultUnavailable
    case vaultMismatch

    var errorDescription: String? {
        switch self {
        case .vaultLocked:
            return String(localized: "请先解锁保险库，再启用钥匙串解锁。")
        case .vaultAlreadyUnlocked:
            return String(localized: "保险库已经解锁。")
        case .keychainUnavailable:
            return String(localized: "钥匙串解锁不可用。")
        case .wrappedKeyProviderUnavailable:
            return String(localized: "保险库安全密钥提供器不可用。")
        case .rememberedVaultUnavailable:
            return String(localized: "没有可通过钥匙串解锁的已记住保险库。")
        case .vaultMismatch:
            return String(localized: "已保存的保险库密钥与当前保险库不匹配。")
        }
    }
}

enum MasterPasswordChangeError: Error, Sendable, Equatable, LocalizedError {
    case confirmationMismatch
    case insufficientStrength

    var errorDescription: String? {
        switch self {
        case .confirmationMismatch:
            return "两次输入的新主密码不一致。"
        case .insufficientStrength:
            return "新主密码至少需要 \(MasterPasswordPolicy.minimumLength) 个字符。"
        }
    }
}

protocol AppVaultKeychainService: Sendable {
    func saveWrappedKey(_ key: WrappedVaultKey) async throws

    func loadWrappedKeyAfterAuthentication(
        vaultID: String,
        reason: String
    ) async throws -> WrappedVaultKey
}

enum MDBXVerificationState: Sendable, Equatable {
    case idle
    case running
    case passed(String)
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            return String(localized: "就绪")
        case .running:
            return String(localized: "运行中")
        case .passed(let message):
            return message
        case .failed(let message):
            return message
        }
    }

    var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }
}

struct AppAutoLockPolicy: Sendable, Identifiable, Hashable {
    static let oneMinute = AppAutoLockPolicy(id: "one-minute", idleTimeout: 60)
    static let fiveMinutes = AppAutoLockPolicy(id: "five-minutes", idleTimeout: 300)
    static let fifteenMinutes = AppAutoLockPolicy(id: "fifteen-minutes", idleTimeout: 900)
    static let thirtyMinutes = AppAutoLockPolicy(id: "thirty-minutes", idleTimeout: 1_800)
    static let presets: [AppAutoLockPolicy] = [
        .oneMinute,
        .fiveMinutes,
        .fifteenMinutes,
        .thirtyMinutes
    ]
    static let `default` = AppAutoLockPolicy.fiveMinutes

    let id: String
    let idleTimeout: TimeInterval

    init(id: String, idleTimeout: TimeInterval) {
        self.id = id
        self.idleTimeout = idleTimeout
    }

    init(idleTimeout: TimeInterval) {
        self.init(id: "\(Int(idleTimeout))-seconds", idleTimeout: idleTimeout)
    }

    var label: String {
        let minutes = Int(idleTimeout / 60)
        return String(localized: "\(minutes) 分钟")
    }
}

/// 导出 CXF 通行密钥前复用同一套设备所有者认证（生物识别或设备密码）。
extension DeviceOwnerLocalAuthenticator: BiometricUnlockAuthorizer {}
