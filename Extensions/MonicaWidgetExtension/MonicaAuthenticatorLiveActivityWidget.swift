//
//  MonicaAuthenticatorLiveActivityWidget.swift
//  MonicaWidgetExtension
//
//  Issue #47：验证器 Live Activity 的锁屏 / 灵动岛界面。
//
//  展示规则（安全边界）：
//  - 只有「条目别名 + 倒计时 + 进度条」，从不渲染验证码正文，也不读取 OTP 密钥；
//  - 倒计时完全交给系统的 `Text(timerInterval:)` / `ProgressView(timerInterval:)`，
//    widget extension 里没有任何刷新循环；
//  - 活动被系统标记为 stale（试点 30 分钟到期）后，显示「已结束」而不是卡住的 0:00。
//
//  本地化：本扩展目前没有字符串目录（现有控件文案同样是硬编码中文），
//  这里保持一致的最小方案，见 PR 说明。
//

import ActivityKit
import MonicaWidgetShared
import SwiftUI
import WidgetKit

/// 验证器锁屏倒计时。
struct MonicaAuthenticatorLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MonicaAuthenticatorActivityAttributes.self) { context in
            MonicaAuthenticatorLockScreenView(
                alias: context.attributes.alias,
                state: context.state,
                isStale: context.isStale
            )
            .activityBackgroundTint(Color.black.opacity(0.6))
            .activitySystemActionForegroundColor(.white)
            .widgetURL(URL(string: "monica://open/totp"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.display")
                            .font(.caption)
                        Text(context.attributes.alias)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.isStale {
                        Text("已结束")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(timerInterval: context.state.windowStart...context.state.windowEnd, countsDown: true)
                            .font(.system(.title3, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color.authenticatorLiveActivityAccent)
                            .frame(maxWidth: 92, alignment: .trailing)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        if !context.isStale {
                            ProgressView(
                                timerInterval: context.state.windowStart...context.state.windowEnd,
                                countsDown: true
                            ) {
                                EmptyView()
                            } currentValueLabel: {
                                EmptyView()
                            }
                            .progressViewStyle(.linear)
                            .tint(Color.authenticatorLiveActivityAccent)
                        }
                        Text("只显示倒计时，不显示验证码正文")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "lock.display")
                    .foregroundStyle(Color.authenticatorLiveActivityAccent)
            } compactTrailing: {
                if context.isStale {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                } else {
                    Text(timerInterval: context.state.windowStart...context.state.windowEnd, countsDown: true)
                        .monospacedDigit()
                        .foregroundStyle(Color.authenticatorLiveActivityAccent)
                        .frame(maxWidth: 48)
                }
            } minimal: {
                Image(systemName: "lock.display")
                    .foregroundStyle(Color.authenticatorLiveActivityAccent)
            }
            .widgetURL(URL(string: "monica://open/totp"))
        }
    }
}

private struct MonicaAuthenticatorLockScreenView: View {
    let alias: String
    let state: MonicaAuthenticatorActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(alias)
                        .font(.headline)
                        .lineLimit(1)
                    Text(isStale ? "倒计时已结束，打开 Monica 重新开始" : "验证码倒计时（不显示验证码）")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if isStale {
                    Text("已结束")
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text(timerInterval: state.windowStart...state.windowEnd, countsDown: true)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.authenticatorLiveActivityAccent)
                        .frame(maxWidth: 104, alignment: .trailing)
                }
            }
            if !isStale {
                ProgressView(
                    timerInterval: state.windowStart...state.windowEnd,
                    countsDown: true
                ) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .progressViewStyle(.linear)
                .tint(Color.authenticatorLiveActivityAccent)
            }
            // 明确告诉用户：刷新由系统调度，试点会自己结束，不承诺后台常驻。
            Text("由系统调度刷新，试点开始约 \(Int(MonicaAuthenticatorActivityLimits.pilotSessionDuration / 60)) 分钟后自动结束")
                .font(.caption2)
                .foregroundStyle(.secondary.opacity(0.85))
        }
        .padding(16)
    }
}

private extension Color {
    /// 与 App 内验证器高亮色一致的青绿色。
    static let authenticatorLiveActivityAccent = Color(red: 0.53, green: 0.86, blue: 0.80)
}
