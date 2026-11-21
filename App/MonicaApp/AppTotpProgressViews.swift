import MonicaCore
import SwiftUI

/// 验证码卡片进度指示器（#155）。
///
/// 线性外观与引入设置之前逐像素一致（`Capsule` 轨道 + 前景胶囊），环形用 `Circle().trim`。
/// 两种样式共用同一份 0…1 比例：父视图每秒刷新一次数值，`Shape` 层级保持不变，
/// 既不每帧新建 Shape，也不额外起 Timer。
struct TotpProgressIndicator: View {
    /// 剩余比例（0…1）。
    let fraction: Double
    let style: TotpProgressStyle
    /// 是否允许在两次数值之间做平滑插值。
    ///
    /// 偏好关闭、或系统开启「减弱动态效果」时传 `false`，进度条直接跳到新数值。
    let animatesChanges: Bool
    /// 环形直径；线性样式忽略该值。
    var ringDiameter: CGFloat = 40

    private var clampedFraction: Double {
        min(max(fraction, 0), 1)
    }

    var body: some View {
        track
            .animation(animatesChanges ? Animation.linear(duration: 1) : nil, value: clampedFraction)
            // 剩余秒数已经在卡片上以文字呈现，进度条对旁白只是重复信息。
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var track: some View {
        switch style {
        case .linear:
            TotpLinearProgressTrack(fraction: clampedFraction)
        case .circular:
            TotpCircularProgressTrack(fraction: clampedFraction, diameter: ringDiameter)
        }
    }
}

///「统一进度条」：所有 30 秒周期卡片共用的那一条进度（#155）。
///
/// 开启后卡片自己的 30 秒进度条会被隐藏，避免同一周期画出两条一模一样的进度；
/// 已验证码算法与刷新周期完全不变，只是不再重复绘制。
struct TotpUnifiedProgressBar: View {
    /// 剩余比例（0…1）。
    let fraction: Double
    let style: TotpProgressStyle
    let animatesChanges: Bool

    var body: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.52), cornerRadius: 22) {
            switch style {
            case .linear:
                label
                TotpProgressIndicator(fraction: fraction, style: .linear, animatesChanges: animatesChanges)
            case .circular:
                HStack(spacing: 12) {
                    label
                    Spacer(minLength: 0)
                    TotpProgressIndicator(
                        fraction: fraction,
                        style: .circular,
                        animatesChanges: animatesChanges,
                        ringDiameter: 26
                    )
                }
            }
        }
    }

    private var label: some View {
        Text("统一进度条")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(AndroidParityPalette.textSecondary)
    }
}

/// 线性进度条：外观保持 #155 之前的实现。
private struct TotpLinearProgressTrack: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(AndroidParityPalette.outline)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(AndroidParityPalette.primary)
                        .frame(width: max(0, proxy.size.width * fraction))
                }
        }
        .frame(height: 10)
    }
}

/// 环形进度条：灰色底环 + 自 12 点方向顺时针收缩的彩色弧。
private struct TotpCircularProgressTrack: View {
    let fraction: Double
    let diameter: CGFloat

    private let lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle()
                .stroke(AndroidParityPalette.outline, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    AndroidParityPalette.primary,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
    }
}

extension TotpProgressStyle {
    /// 设置页展示名。
    ///
    /// 放在 App 侧：`MonicaCore` 不携带本地化资源，颜色与文案都由 App 决定。
    var displayLabel: String {
        switch self {
        case .linear:
            String(localized: "线性")
        case .circular:
            String(localized: "环形")
        }
    }
}
