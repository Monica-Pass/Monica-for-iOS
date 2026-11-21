import Foundation

/// 自动填充守护策略：只描述 Monica 自己「要不要把凭据身份发布到系统凭据列表」的本地规则。
///
/// iOS 限制说明：
/// - iOS 不提供无障碍服务，App 无法监听其它 App 的输入框，也无法读取或设置「系统默认密码管理器」是谁。
/// - 因此这里的策略只作用于 Monica 自己的候选与发布行为，不会改变系统或其它 App 的自动填充来源。
public struct AutoFillGuardPolicy: Codable, Equatable, Sendable {
    /// 只在通过设备所有者认证（Face ID / Touch ID / 设备密码）解锁后才发布身份。
    public var publishesOnlyAfterBiometricUnlock: Bool

    /// 保险库锁定后清空已发布到系统的身份条目。
    public var clearsPublishedIdentitiesWhenVaultLocks: Bool

    public init(
        publishesOnlyAfterBiometricUnlock: Bool = false,
        clearsPublishedIdentitiesWhenVaultLocks: Bool = false
    ) {
        self.publishesOnlyAfterBiometricUnlock = publishesOnlyAfterBiometricUnlock
        self.clearsPublishedIdentitiesWhenVaultLocks = clearsPublishedIdentitiesWhenVaultLocks
    }

    /// 保持与引入守护开关之前完全一致的行为：两个开关都关闭。
    public static let `default` = AutoFillGuardPolicy()

    private enum CodingKeys: String, CodingKey {
        case publishesOnlyAfterBiometricUnlock
        case clearsPublishedIdentitiesWhenVaultLocks
    }

    /// 旧版本写入的 payload 可能缺少字段，缺失一律按 `false` 处理，避免升级后行为突变。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        publishesOnlyAfterBiometricUnlock =
            try container.decodeIfPresent(Bool.self, forKey: .publishesOnlyAfterBiometricUnlock) ?? false
        clearsPublishedIdentitiesWhenVaultLocks =
            try container.decodeIfPresent(Bool.self, forKey: .clearsPublishedIdentitiesWhenVaultLocks) ?? false
    }
}

/// 身份发布被守护策略拦下的原因。
public enum AutoFillGuardPublishBlockReason: String, Codable, Equatable, Sendable {
    /// 保险库未解锁。身份条目由解密后的条目构建，锁定时无法发布。
    case vaultLocked

    /// 开启了「仅生物识别解锁后发布」，但当前会话是用主密码解锁的。
    case biometricUnlockRequired
}

/// 守护策略对一次身份发布的裁决。
public enum AutoFillGuardPublishDecision: Equatable, Sendable {
    case allowed
    case blocked(AutoFillGuardPublishBlockReason)

    public var isAllowed: Bool {
        if case .allowed = self {
            return true
        }
        return false
    }

    public var blockReason: AutoFillGuardPublishBlockReason? {
        if case .blocked(let reason) = self {
            return reason
        }
        return nil
    }
}

extension AutoFillGuardPolicy {
    /// 判定当前会话是否允许向系统凭据列表发布身份。
    ///
    /// - Parameters:
    ///   - vaultIsUnlocked: 保险库是否已解锁。
    ///   - unlockedWithBiometrics: 当前解锁会话是否通过了设备所有者认证（生物识别 / 设备密码）。
    public func publishDecision(
        vaultIsUnlocked: Bool,
        unlockedWithBiometrics: Bool
    ) -> AutoFillGuardPublishDecision {
        guard vaultIsUnlocked else {
            return .blocked(.vaultLocked)
        }
        if publishesOnlyAfterBiometricUnlock && !unlockedWithBiometrics {
            return .blocked(.biometricUnlockRequired)
        }
        return .allowed
    }

    /// 锁定保险库时是否需要清空已发布到系统的身份条目。
    public var clearsIdentitiesOnLock: Bool {
        clearsPublishedIdentitiesWhenVaultLocks
    }
}
