import SwiftUI
import UIKit
import MonicaCore

/// 触感播放抽象：App 层统一出口，测试里可换成记录器（#147）。
@MainActor
protocol HapticPlaying: AnyObject {
    func play(_ kind: HapticEventKind)
}

/// 真实触感播放器：把语义类别映射到 `UIFeedbackGenerator`。
@MainActor
final class SystemHapticPlayer: HapticPlaying {
    private let notificationGenerator = UINotificationFeedbackGenerator()
    private let selectionGenerator = UISelectionFeedbackGenerator()
    private let lightImpactGenerator = UIImpactFeedbackGenerator(style: .light)

    func play(_ kind: HapticEventKind) {
        // 低电量模式下不额外唤醒 Taptic Engine；交互类反馈仍然保留。
        let isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        switch kind {
        case .success:
            notificationGenerator.prepare()
            notificationGenerator.notificationOccurred(.success)
        case .error:
            notificationGenerator.prepare()
            notificationGenerator.notificationOccurred(.error)
        case .selection:
            selectionGenerator.prepare()
            selectionGenerator.selectionChanged()
        case .verificationTick:
            guard !isLowPowerMode else { return }
            lightImpactGenerator.prepare()
            lightImpactGenerator.impactOccurred()
        }
    }
}

/// 测试与预览用的记录器：只记录，不触发任何真实反馈。
@MainActor
final class RecordingHapticPlayer: HapticPlaying {
    private(set) var played: [HapticEventKind] = []

    func play(_ kind: HapticEventKind) {
        played.append(kind)
    }

    func reset() {
        played.removeAll()
    }
}

/// 全 App 唯一的触感入口。
///
/// 任何触感都必须经过这里，这样「关闭总开关后零触感」由类型本身保证，
/// 而不是靠每个调用点自己判断（#147）。
@MainActor
final class AppHaptics: ObservableObject {
    @Published private(set) var preferences: HapticsPreferences

    private let store: any HapticsPreferencesStoring
    private let player: any HapticPlaying

    init(
        store: any HapticsPreferencesStoring = UserDefaultsHapticsPreferencesStore(),
        player: any HapticPlaying = SystemHapticPlayer()
    ) {
        self.store = store
        self.player = player
        self.preferences = store.load()
    }

    var policy: HapticsPolicy {
        HapticsPolicy(preferences: preferences)
    }

    var isEnabled: Bool {
        preferences.isEnabled
    }

    var isVerificationEnabled: Bool {
        preferences.isVerificationEnabled
    }

    func setEnabled(_ isEnabled: Bool) {
        guard preferences.isEnabled != isEnabled else { return }
        preferences.isEnabled = isEnabled
        store.save(preferences)
        // 打开总开关时给一次轻量确认，关闭时立即静默。
        if isEnabled {
            player.play(.selection)
        }
    }

    func setVerificationEnabled(_ isEnabled: Bool) {
        guard preferences.isVerificationEnabled != isEnabled else { return }
        preferences.isVerificationEnabled = isEnabled
        store.save(preferences)
        if isEnabled, preferences.isEnabled {
            player.play(.success)
        }
    }

    /// 唯一播放入口；关闭总开关后这里不会有任何副作用。
    func play(_ kind: HapticEventKind) {
        guard policy.shouldPlay(kind) else { return }
        player.play(kind)
    }
}

/// 设置页「触感反馈」区块。
struct AppHapticsSettingsView: View {
    @ObservedObject var haptics: AppHaptics

    var body: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
            Toggle(
                isOn: Binding(
                    get: { haptics.isEnabled },
                    set: { haptics.setEnabled($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("触感反馈")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textPrimary)
                    Text("保存、删除与切换时提供轻量震动")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
            }
            .tint(AndroidParityPalette.primary)
            .accessibilityIdentifier("haptics.master")

            AndroidParityDivider()

            Toggle(
                isOn: Binding(
                    get: { haptics.isVerificationEnabled },
                    set: { haptics.setVerificationEnabled($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("验证器轻震")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textPrimary)
                    Text("验证码刷新时轻震；关闭总开关后此项目不起作用")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
            }
            .tint(AndroidParityPalette.primary)
            .disabled(!haptics.isEnabled)
            .opacity(haptics.isEnabled ? 1 : 0.5)
            .accessibilityIdentifier("haptics.verification")
        }
    }
}
