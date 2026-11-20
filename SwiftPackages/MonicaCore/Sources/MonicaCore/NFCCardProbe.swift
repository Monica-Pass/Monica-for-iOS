import Foundation

/// issue #44 的 Core NFC 银行卡贴卡诊断的纯逻辑层。
///
/// 这里只放可以在 macOS 上编译、测试的模型与策略；真正的 Core NFC 会话在
/// 主 App 的 `NFCBankCardProbe.swift`。该设计让 AID 白名单、错误映射和脱敏
/// 规则不依赖真机即可被单元测试覆盖。
///
/// 约束（来自 Apple Core NFC 文档）：
/// - `NFCTagReaderSession` 不支持选择支付类 application ID（EMV/PAN 读取）；
/// - iOS 26 起 EU 的 `NFCPaymentTagReaderSession` 需要单独申请，且不向本 App 开放；
/// - 因此诊断只能声明 NDEF application AID，并且不得发送任何 APDU。
public enum NFCCardProbePolicy {
    /// 诊断默认关闭，必须由用户在设置中显式开启。
    public static let enabledByDefault = false

    /// 面向用户的合规说明，UI 与文档共用，避免各处措辞漂移。
    public static let disclaimer = """
    本诊断只读取标签类型、NDEF 状态和非支付类 ISO7816 应用标识，不读取、不保存、不上传银行卡号、有效期、CVV 或 APDU 原文。\
    iOS 的 Core NFC 不向普通 App 开放支付类 application ID，因此无法通过贴卡自动建档。
    """

    /// 支付卡相关的可读字段：普通 Core NFC 会话拿不到任何一项。
    public static let readablePaymentCardFields: [String] = []
}

/// 诊断入口的 feature flag。默认关闭；关闭时设置页只显示开关，不显示诊断入口。
public enum NFCCardProbeFeatureFlag {
    public static let userDefaultsKey = "monica.nfc.card-probe.enabled"

    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: userDefaultsKey) != nil else {
            return NFCCardProbePolicy.enabledByDefault
        }
        return defaults.bool(forKey: userDefaultsKey)
    }

    public static func setEnabled(_ isEnabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: userDefaultsKey)
    }
}

/// 诊断会话类型。`.iso7816NonPayment` 需要额外的 NFC Tag Reader entitlement，
/// 且 Info.plist 必须声明 NDEF application AID，否则系统会以 securityViolation 拒绝。
public enum NFCCardProbeMode: String, CaseIterable, Identifiable, Sendable {
    case ndef = "ndef"
    case iso7816NonPayment = "iso7816-non-payment"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ndef:
            return "NDEF 标签会话"
        case .iso7816NonPayment:
            return "ISO7816 非支付标签"
        }
    }

    public var subtitle: String {
        switch self {
        case .ndef:
            return "无需 NFC Tag entitlement，只读取 NDEF 消息。"
        case .iso7816NonPayment:
            return "需要付费开发者账号的 NFC Tag entitlement；只声明 NDEF application AID。"
        }
    }

    public var requiresTagReaderEntitlement: Bool {
        self == .iso7816NonPayment
    }
}

/// 单个 application identifier 的判定结果。
public enum NFCCardProbeAIDDecision: Equatable, Sendable {
    case ndefApplication
    case paymentRelated(provider: String?)
    case notAllowlisted
    case malformed

    public var isSelectable: Bool {
        self == .ndefApplication
    }

    public var isPaymentRelated: Bool {
        if case .paymentRelated = self {
            return true
        }
        return false
    }
}

/// AID 白名单与支付类 AID 识别。
///
/// 只有 NFC Forum 的 NDEF application AID 会被声明给系统；任何看起来像
/// EMV 注册应用提供商（RID 以 `A000000` 开头）或 PPSE/PSE 的 AID 都会被拒绝。
/// 这样即使后续有人误改 Info.plist，单元测试也会拦住支付类 AID。
public enum NFCCardProbeAIDPolicy {
    /// NDEF Tag Application v2.0（NFC Forum）。
    public static let ndefApplicationV2 = "D2760000850100"
    /// NDEF Tag Application v1.0（NFC Forum）。
    public static let ndefApplicationV1 = "D2760000850101"

    public static let allowedSelectIdentifiers: [String] = [
        ndefApplicationV2,
        ndefApplicationV1
    ]

    /// EMV 支付应用的 RID 前缀。EMV 注册 RID 均以 `A000000` 开头，这里只列常见卡组织用于提示文案。
    public static let paymentRIDProviders: [(prefix: String, provider: String)] = [
        ("A000000003", "Visa"),
        ("A000000004", "Mastercard"),
        ("A000000025", "American Express"),
        ("A000000065", "JCB"),
        ("A000000152", "Discover"),
        ("A000000277", "Interac"),
        ("A000000333", "UnionPay")
    ]

    /// `2PAY.SYS.DDF01`（PPSE）与 `1PAY.SYS.DDF01`（PSE）。
    public static let paymentEnvironmentIdentifiers: Set<String> = [
        "325041592E5359532E4444463031",
        "315041592E5359532E4444463031"
    ]

    public static func normalizedSelectIdentifier(_ rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.hasPrefix("0X") {
            value.removeFirst(2)
        }
        value.removeAll { character in
            character == " " || character == ":" || character == "-"
        }
        guard !value.isEmpty,
              value.count.isMultiple(of: 2),
              (10...32).contains(value.count),
              value.allSatisfy(\.isHexDigit)
        else {
            return nil
        }
        return value
    }

    public static func decision(forSelectIdentifier rawValue: String) -> NFCCardProbeAIDDecision {
        guard let identifier = normalizedSelectIdentifier(rawValue) else {
            return .malformed
        }
        if allowedSelectIdentifiers.contains(identifier) {
            return .ndefApplication
        }
        if paymentEnvironmentIdentifiers.contains(identifier) {
            return .paymentRelated(provider: "EMV PPSE/PSE")
        }
        if let match = paymentRIDProviders.first(where: { identifier.hasPrefix($0.prefix) }) {
            return .paymentRelated(provider: match.provider)
        }
        // EMV 注册应用提供商 RID 统一以 A000000 开头；未知 RID 也按支付类处理，避免误放行。
        if identifier.hasPrefix("A000000") {
            return .paymentRelated(provider: nil)
        }
        return .notAllowlisted
    }

    /// Info.plist 中不允许出现的 AID；供配置检查和测试使用。
    public static func unsafeSelectIdentifiers(in identifiers: [String]) -> [String] {
        identifiers.filter { decision(forSelectIdentifier: $0).isPaymentRelated }
    }

    /// 生成 Info.plist 片段说明时使用的真实白名单。
    public static var declaredSelectIdentifiers: [String] {
        allowedSelectIdentifiers
    }
}

/// 标签家族。只使用公开的 `NFCTagType`/协议族名称，不包含 UID。
public enum NFCCardProbeTagFamily: String, Sendable {
    case ndef
    case iso7816
    case miFare
    case feliCa
    case iso15693
    case unknown

    public var displayName: String {
        switch self {
        case .ndef:
            return "NDEF"
        case .iso7816:
            return "ISO7816"
        case .miFare:
            return "MIFARE"
        case .feliCa:
            return "FeliCa"
        case .iso15693:
            return "ISO15693"
        case .unknown:
            return "未知"
        }
    }
}

/// 一次诊断读取到的、已脱敏的标签事实。这里刻意不包含 UID、PAN、APDU 等原始数据。
public struct NFCCardProbeTagFacts: Equatable, Sendable {
    public var family: NFCCardProbeTagFamily
    public var isAvailable: Bool
    public var ndefRecordCount: Int
    public var ndefRecordTypeNames: [String]
    public var iso7816SelectedAID: String?
    public var withheldPaymentAID: Bool
    public var notes: [String]

    public init(
        family: NFCCardProbeTagFamily,
        isAvailable: Bool = true,
        ndefRecordCount: Int = 0,
        ndefRecordTypeNames: [String] = [],
        iso7816SelectedAID: String? = nil,
        withheldPaymentAID: Bool = false,
        notes: [String] = []
    ) {
        self.family = family
        self.isAvailable = isAvailable
        self.ndefRecordCount = ndefRecordCount
        self.ndefRecordTypeNames = ndefRecordTypeNames
        self.iso7816SelectedAID = iso7816SelectedAID
        self.withheldPaymentAID = withheldPaymentAID
        self.notes = notes
    }

    /// 依据 AID 策略构造脱敏后的 ISO7816 事实；支付类 AID 只记录“已隐藏”，不留下原文。
    public static func iso7816(
        isAvailable: Bool,
        initialSelectedAID: String?,
        notes: [String] = []
    ) -> NFCCardProbeTagFacts {
        var facts = NFCCardProbeTagFacts(
            family: .iso7816,
            isAvailable: isAvailable,
            notes: notes
        )
        if let initialSelectedAID {
            switch NFCCardProbeAIDPolicy.decision(forSelectIdentifier: initialSelectedAID) {
            case .ndefApplication, .notAllowlisted:
                facts.iso7816SelectedAID = initialSelectedAID.uppercased()
            case .paymentRelated:
                facts.withheldPaymentAID = true
            case .malformed:
                break
            }
        }
        return facts
    }

    /// UI 展示行；所有内容均来自白名单字段。
    public var summaryLines: [String] {
        var lines = ["标签类型：\(family.displayName)"]
        if family == .ndef || ndefRecordCount > 0 {
            let typeSuffix = ndefRecordTypeNames.isEmpty ? "" : "（\(ndefRecordTypeNames.joined(separator: "、"))）"
            lines.append("NDEF 记录：\(ndefRecordCount) 条\(typeSuffix)")
        }
        if let iso7816SelectedAID {
            lines.append("ISO7816 应用标识：\(iso7816SelectedAID)（非支付）")
        }
        if withheldPaymentAID {
            lines.append("ISO7816 应用标识：系统选中了支付类 AID，已按合规策略隐藏")
        }
        if !isAvailable {
            lines.append("标签状态：已离开读取范围")
        }
        lines.append(contentsOf: notes)
        return lines
    }
}

/// Core NFC 错误（`NFCReaderError` 的 raw code）到用户可读反馈的映射。
///
/// 只保留错误类别与建议，不保留底层 error description / APDU / 标签数据。
public enum NFCCardProbeFailure: Error, Equatable, Sendable {
    case unsupportedFeature
    case missingEntitlement
    case invalidSessionParameter
    case radioDisabled
    case ineligible
    case accessNotAccepted
    case tagCommunicationFailure(rawCode: Int)
    case userCanceled
    case noTagDetected
    case sessionTerminatedUnexpectedly
    case systemBusy
    case firstNDEFTagRead
    case tagCommandConfigurationInvalid
    case ndefTagNotWritable
    case ndefTagUpdateFailure
    case ndefTagSizeTooSmall
    case zeroLengthNDEFMessage
    case paymentSessionLocationUnavailable
    case unknown(rawCode: Int)

    public static func from(rawErrorCode: Int) -> NFCCardProbeFailure {
        switch rawErrorCode {
        case 1:
            return .unsupportedFeature
        case 2:
            return .missingEntitlement
        case 3, 4, 5:
            return .invalidSessionParameter
        case 6:
            return .radioDisabled
        case 7:
            return .ineligible
        case 8:
            return .accessNotAccepted
        case 100...199:
            return .tagCommunicationFailure(rawCode: rawErrorCode)
        case 200:
            return .userCanceled
        case 201:
            return .noTagDetected
        case 202:
            return .sessionTerminatedUnexpectedly
        case 203:
            return .systemBusy
        case 204:
            return .firstNDEFTagRead
        case 300:
            return .tagCommandConfigurationInvalid
        case 400:
            return .ndefTagNotWritable
        case 401:
            return .ndefTagUpdateFailure
        case 402:
            return .ndefTagSizeTooSmall
        case 403:
            return .zeroLengthNDEFMessage
        case 500...502:
            return .paymentSessionLocationUnavailable
        default:
            return .unknown(rawCode: rawErrorCode)
        }
    }

    /// 系统自动结束会话（首条 NDEF 已读完）不算失败。
    public var isInformationalCompletion: Bool {
        self == .firstNDEFTagRead
    }

    public var isUserCancellation: Bool {
        self == .userCanceled
    }

    public var diagnosticCode: String {
        "NFC-\(rawRepresentativeCode)"
    }

    private var rawRepresentativeCode: Int {
        switch self {
        case .unsupportedFeature:
            return 1
        case .missingEntitlement:
            return 2
        case .invalidSessionParameter:
            return 3
        case .radioDisabled:
            return 6
        case .ineligible:
            return 7
        case .accessNotAccepted:
            return 8
        case .tagCommunicationFailure(let rawCode), .unknown(let rawCode):
            return rawCode
        case .userCanceled:
            return 200
        case .noTagDetected:
            return 201
        case .sessionTerminatedUnexpectedly:
            return 202
        case .systemBusy:
            return 203
        case .firstNDEFTagRead:
            return 204
        case .tagCommandConfigurationInvalid:
            return 300
        case .ndefTagNotWritable:
            return 400
        case .ndefTagUpdateFailure:
            return 401
        case .ndefTagSizeTooSmall:
            return 402
        case .zeroLengthNDEFMessage:
            return 403
        case .paymentSessionLocationUnavailable:
            return 500
        }
    }

    public var title: String {
        switch self {
        case .unsupportedFeature:
            return "设备或系统不支持 NFC"
        case .missingEntitlement:
            return "缺少 NFC 标签读取授权"
        case .invalidSessionParameter:
            return "会话参数无效"
        case .radioDisabled:
            return "NFC 已关闭"
        case .ineligible:
            return "当前系统条件不允许 NFC"
        case .accessNotAccepted:
            return "用户尚未允许 NFC"
        case .tagCommunicationFailure:
            return "标签通信中断"
        case .userCanceled:
            return "已取消扫描"
        case .noTagDetected:
            return "没有检测到标签"
        case .sessionTerminatedUnexpectedly:
            return "NFC 会话被系统终止"
        case .systemBusy:
            return "NFC 暂时不可用"
        case .firstNDEFTagRead:
            return "NDEF 读取完成"
        case .tagCommandConfigurationInvalid:
            return "标签命令配置无效"
        case .ndefTagNotWritable:
            return "标签不可写入"
        case .ndefTagUpdateFailure:
            return "标签写入失败"
        case .ndefTagSizeTooSmall:
            return "标签容量不足"
        case .zeroLengthNDEFMessage:
            return "标签不含 NDEF 内容"
        case .paymentSessionLocationUnavailable:
            return "支付标签会话的位置服务不可用"
        case .unknown:
            return "未识别的 NFC 错误"
        }
    }

    public var message: String {
        switch self {
        case .unsupportedFeature:
            return "模拟器、iPad 或没有 NFC 硬件的设备无法启动 Core NFC 会话。"
        case .missingEntitlement:
            return "当前签名缺少 com.apple.developer.nfc.readersession.formats（NFC Tag Reading），或 Info.plist 没有声明可选的 ISO7816 AID。"
        case .invalidSessionParameter:
            return "Core NFC 拒绝了会话参数；请检查 AID 列表和轮询配置。"
        case .radioDisabled:
            return "请在系统设置中打开 NFC，然后再试。"
        case .ineligible:
            return "当前设备状态（如地区、系统策略）不满足该会话的启用条件。"
        case .accessNotAccepted:
            return "NFC 使用许可尚未被接受，请重试并在系统弹窗中允许。"
        case .tagCommunicationFailure:
            return "与标签的连接或响应中断；这不代表读到了银行卡数据。"
        case .userCanceled:
            return "扫描被用户取消，没有读取任何数据。"
        case .noTagDetected:
            return "在超时前没有检测到可读标签。银行卡属于支付类卡片，系统不会把它作为普通标签返回。"
        case .sessionTerminatedUnexpectedly:
            return "系统提前结束了会话，请重新开始诊断。"
        case .systemBusy:
            return "系统资源暂时不可用，请关闭其他 NFC 任务后重试。"
        case .firstNDEFTagRead:
            return "系统在读完第一条 NDEF 消息后自动结束了会话。"
        case .tagCommandConfigurationInvalid:
            return "标签命令配置无效；本诊断不会发送任何 APDU。"
        case .ndefTagNotWritable:
            return "标签为只读状态；本诊断只读取，不写入。"
        case .ndefTagUpdateFailure:
            return "标签更新失败；本诊断只读取，不写入。"
        case .ndefTagSizeTooSmall:
            return "标签容量不足；本诊断只读取，不写入。"
        case .zeroLengthNDEFMessage:
            return "标签存在，但没有 NDEF 消息；银行卡通常就属于这种非 NDEF 支付标签。"
        case .paymentSessionLocationUnavailable:
            return "这是 iOS 26 支付标签会话（仅 EU）的位置服务错误；本 App 的诊断不会使用该会话。"
        case .unknown:
            return "Core NFC 返回了未映射的错误码，可把诊断编号反馈给开发者。"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .unsupportedFeature:
            return "改用带 NFC 的 iPhone 真机进行验证；模拟器结果不能代表真机。"
        case .missingEntitlement:
            return "使用付费 Apple Developer Program 账号，在 Xcode 的 Signing & Capabilities 添加 NFC Tag Reading，并在开发者后台为 App ID 启用该 capability。"
        case .radioDisabled:
            return "打开 设置 → 控制中心 或系统 NFC 开关后重试。"
        case .noTagDetected, .zeroLengthNDEFMessage:
            return "把 iPhone 顶部靠近一张 NDEF 标签验证会话可用；银行卡无法通过 Core NFC 读取，请继续手动录入。"
        case .systemBusy, .sessionTerminatedUnexpectedly:
            return "等待几秒后重新开始诊断。"
        default:
            return nil
        }
    }
}
