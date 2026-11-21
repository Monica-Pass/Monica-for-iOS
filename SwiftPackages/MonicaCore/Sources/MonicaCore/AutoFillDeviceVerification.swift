import Foundation

/// 一次设备所有者验证的结果（#146）。
///
/// 扩展把 `LAContext.evaluatePolicy(.deviceOwnerAuthentication)` 的结果收敛成这四种，
/// 好让「是否放行本次填充」的判决能在包级测试里用注入的结果覆盖，而不必真的弹 Face ID。
public enum AutoFillDeviceVerificationOutcome: String, Codable, Equatable, Sendable {
    /// 设备所有者验证通过（Face ID / Touch ID / 设备口令任一）。
    case verified

    /// 用户主动取消。
    case cancelled

    /// 验证执行了但没通过（例如连续匹配失败、系统取消）。
    case failed

    /// 设备没有可用的验证方式（未设密码、无生物识别、策略不可用）。
    case unavailable
}

/// 设备验证没通过时，Monica 拒绝返回密码的原因。
///
/// 这些原因不带任何凭据内容：扩展只拿它拼用户可见的说明，不把密码、用户名写进文案或日志。
public enum AutoFillDeviceVerificationFailure: String, Codable, Equatable, Sendable {
    /// 用户在系统验证面板上点了取消。
    case userCancelled

    /// 验证执行了但没有通过。
    case verificationFailed

    /// 这台设备当前没有可用的设备口令或生物识别。
    case verificationUnavailable

    /// 给用户看的说明：明确「没有返回密码」，不假装验证成功，也不引导用户去关系统验证。
    public var message: String {
        switch self {
        case .userCancelled:
            return "已取消设备验证，Monica 没有返回密码。"
        case .verificationFailed:
            return "设备验证未通过，Monica 没有返回密码。"
        case .verificationUnavailable:
            return "这台设备没有可用的 Face ID、Touch ID 或设备口令，Monica 不会返回密码。请先给设备设置密码，或在 Monica 设置 → 自动填充中关闭「自动填充前要求设备验证」。"
        }
    }
}

/// 一次填充请求的放行结果。
public enum AutoFillFillAuthorization: Equatable, Sendable {
    /// 允许把密码交给系统；`grant` 只能兑换一次。
    case authorized(AutoFillDeviceVerificationGrant)

    /// 静默路径没有交互机会，必须交回系统 UI 让用户走需要验证的流程。
    case interactionRequired

    /// 明确拒绝：调用方绝不能返回密码。
    case refused(AutoFillDeviceVerificationFailure)

    /// 是否允许返回密码。
    public var isAuthorized: Bool {
        if case .authorized = self {
            return true
        }
        return false
    }

    /// 一次性放行凭证；未通过验证时为空。
    public var grant: AutoFillDeviceVerificationGrant? {
        if case .authorized(let grant) = self {
            return grant
        }
        return nil
    }

    /// 拒绝原因；放行或需要交互时为空。
    public var failure: AutoFillDeviceVerificationFailure? {
        if case .refused(let failure) = self {
            return failure
        }
        return nil
    }
}

/// 验证通过后发出的一次性放行凭证。
///
/// 每次填充都要重新验证：结果既不缓存，也不允许同一份验证放行第二次填充。
public struct AutoFillDeviceVerificationGrant: Equatable, Sendable {
    private var isConsumed: Bool

    public init() {
        isConsumed = false
    }

    /// 还没被兑换过。
    public var isAvailable: Bool {
        !isConsumed
    }

    /// 兑换本次填充的放行；重复兑换返回 false。
    public mutating func consume() -> Bool {
        guard !isConsumed else {
            return false
        }
        isConsumed = true
        return true
    }
}

/// 自动填充前设备验证策略（#146）。
///
/// 只描述本地规则：开关打开时，返回密码前必须做一次设备所有者验证；
/// 只影响「返回密码」这一步，不影响保存、通行密钥，也不影响 Monica 内查看/复制密码。
public struct AutoFillDeviceVerificationPolicy: Codable, Equatable, Sendable {
    /// 返回密码前是否要求设备所有者验证（Face ID / Touch ID / 设备口令）。
    public var requiresVerificationBeforeFilling: Bool

    public init(requiresVerificationBeforeFilling: Bool = false) {
        self.requiresVerificationBeforeFilling = requiresVerificationBeforeFilling
    }

    /// 与引入开关之前完全一致的行为：不额外验证。
    public static let `default` = AutoFillDeviceVerificationPolicy()

    /// 静默填充（没有 UI、没有交互机会）的判决。
    ///
    /// 开关打开时永远不直接给密码：交回系统 UI，由用户点选后再走一次验证。
    public func authorizeSilentFill() -> AutoFillFillAuthorization {
        guard requiresVerificationBeforeFilling else {
            return .authorized(AutoFillDeviceVerificationGrant())
        }
        return .interactionRequired
    }

    /// 交互填充（扩展界面已经出现）的判决。
    ///
    /// 开关关闭时直接放行，行为与历史版本一致；开关打开时只有 `.verified` 才放行。
    public func authorizeInteractiveFill(
        after outcome: AutoFillDeviceVerificationOutcome
    ) -> AutoFillFillAuthorization {
        guard requiresVerificationBeforeFilling else {
            return .authorized(AutoFillDeviceVerificationGrant())
        }
        switch outcome {
        case .verified:
            return .authorized(AutoFillDeviceVerificationGrant())
        case .cancelled:
            return .refused(.userCancelled)
        case .failed:
            return .refused(.verificationFailed)
        case .unavailable:
            return .refused(.verificationUnavailable)
        }
    }
}

/// 「自动填充前要求设备验证」开关的持久化。
///
/// 开关必须让 AutoFill 扩展（另一个进程）读到，所以放在 App Group UserDefaults；
/// 这只是一个布尔偏好，不是密钥，不需要 Keychain。扩展每次请求都重新读一次，
/// 不做进程内缓存——用户在 Monica 里刚改的开关应当立刻生效。
public struct AutoFillDeviceVerificationPreferenceStore {
    /// AutoFill 扩展与主 App 共用的 App Group。
    public static let appGroupIdentifier = "group.com.monicapass.monica"

    /// UserDefaults key。
    public static let storageKey = "autoFillRequiresDeviceVerificationBeforeFilling"

    private let defaults: UserDefaults?

    /// 生产路径：直接读写 App Group 共享偏好。
    public init(
        defaults: UserDefaults? = UserDefaults(
            suiteName: AutoFillDeviceVerificationPreferenceStore.appGroupIdentifier
        )
    ) {
        self.defaults = defaults
    }

    /// 测试与诊断路径：指定一份偏好域。
    public init(suiteName: String) {
        defaults = UserDefaults(suiteName: suiteName)
    }

    /// 共享偏好是否可用（App Group 未配置时为 false）。
    public var isAvailable: Bool {
        defaults != nil
    }

    /// 是否要求填充前验证设备所有者。默认关闭；共享偏好不可用时按开启处理（fail-closed），
    /// 宁可多要一次验证，也不在用户以为已开启时把密码直接交出去。
    public var requiresVerificationBeforeFilling: Bool {
        guard let defaults else {
            return true
        }
        return defaults.bool(forKey: Self.storageKey)
    }

    /// 写入开关，并立刻推给共享偏好，避免扩展进程读到旧值。
    public func saveRequiresVerificationBeforeFilling(_ enabled: Bool) {
        guard let defaults else {
            return
        }
        defaults.set(enabled, forKey: Self.storageKey)
        _ = defaults.synchronize()
    }
}
