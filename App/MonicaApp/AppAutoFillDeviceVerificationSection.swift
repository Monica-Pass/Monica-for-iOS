import LocalAuthentication
import MonicaCore
import SwiftUI

/// 设置页「自动填充」区的设备验证开关（#146）。
///
/// 开关值写入 App Group：自动填充扩展在每次返回密码前重新读取，主 App 不持有
/// 扩展侧的缓存。开关默认关闭，关闭时扩展行为与加入该项之前完全一致。
struct AppAutoFillDeviceVerificationSection: View {
    @State private var requiresVerification: Bool
    @State private var availability: DeviceOwnerAuthenticationAvailability
    private let store: AutoFillDeviceVerificationPreferenceStore

    init(store: AutoFillDeviceVerificationPreferenceStore = AutoFillDeviceVerificationPreferenceStore()) {
        self.store = store
        _requiresVerification = State(initialValue: store.requiresVerificationBeforeFilling)
        _availability = State(initialValue: DeviceOwnerAuthenticationAvailability.current)
    }

    var body: some View {
        AndroidParitySection(title: String(localized: "自动填充前要求设备验证")) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                Toggle(isOn: requiresVerificationBinding) {
                    Text("自动填充前要求设备验证")
                        .font(.subheadline.weight(.semibold))
                }
                .tint(AndroidParityPalette.primary)

                Text("打开后，每次用 Monica 自动填充密码前都要先用 Face ID、Touch ID 或设备口令确认。取消、验证失败或无法验证时，扩展不会返回密码。")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                AndroidParityDivider()

                Text(availabilityText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(availability == .unavailable ? Color.red : AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !store.isAvailable {
                    Text("共享配置不可用：扩展读不到这个开关，会按「开启」处理，静默填充会被拒绝。")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Monica 只使用验证是否通过这一结果；生物识别数据始终由系统处理，不会被保存或写进日志。")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var requiresVerificationBinding: Binding<Bool> {
        Binding(
            get: { requiresVerification },
            set: { newValue in
                requiresVerification = newValue
                store.saveRequiresVerificationBeforeFilling(newValue)
            }
        )
    }

    private var availabilityText: String {
        switch availability {
        case .deviceOwner:
            String(localized: "填充前会要求 Face ID 或 Touch ID，必要时回落到设备口令。")
        case .passcodeOnly:
            String(localized: "这台设备没有可用的 Face ID 或 Touch ID，填充前会要求输入设备口令。")
        case .unavailable:
            String(localized: "这台设备还没有设置设备口令，系统无法验证设备所有者；打开这个开关后，Monica 自动填充会拒绝返回密码。请先在系统设置里给设备设置密码。")
        }
    }
}

/// 当前设备能提供的设备所有者验证方式。
private enum DeviceOwnerAuthenticationAvailability: Equatable {
    /// Face ID / Touch ID 可用，失败后可回落到设备口令。
    case deviceOwner
    /// 没有可用生物识别，但设备口令可用。
    case passcodeOnly
    /// 连设备口令都没有：系统无法验证设备所有者。
    case unavailable

    static var current: Self {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            return .unavailable
        }
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
            ? .deviceOwner
            : .passcodeOnly
    }
}
