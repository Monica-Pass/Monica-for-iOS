//
//  AppKeyboardInputSupport.swift
//  Monica
//
//  Issue #41：iOS 不允许第三方输入法读取或填充安全文本输入框，这里提供
//  「系统自动填充 + 用户主动复制 + 快捷指令」三条公开 API 可达的替代路径，
//  并把系统限制写清楚，避免出现「任意输入框都能填」的误导文案。
//

import SwiftUI
import UIKit

struct AppKeyboardInputLimitationsView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
            AndroidParityInfoRow(
                title: String(localized: "系统限制"),
                value: String(localized: "安全文本输入强制使用系统键盘")
            )
            Text("iOS 在密码框等安全文本输入区域会强制使用系统键盘，第三方键盘（包括自定义输入法）无法读取或填入内容。Monica 不提供、也无法提供绕过该系统限制的输入法。")
                .font(.caption)
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            AndroidParityDivider()

            AndroidParityInfoRow(
                title: String(localized: "推荐方式"),
                value: String(localized: "系统密码自动填充")
            )
            Text("设置 → 通用 → 自动填充与密码 → 选择 Monica，然后在 App 或 Safari 的用户名/密码输入框上方使用系统 QuickType 建议。")
                .font(.caption)
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            AndroidParityDivider()

            AndroidParityInfoRow(
                title: String(localized: "手动复制"),
                value: String(localized: "用户主动触发")
            )
            Text("在条目列表长按登录条目，或在条目详情点击复制按钮，可复制用户名、密码或验证码；复制内容会按「敏感剪贴板」设置自动清除。锁库状态下不会展示任何秘密。")
                .font(.caption)
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            AndroidParityDivider()

            AndroidParityInfoRow(
                title: String(localized: "快捷指令"),
                value: String(localized: "Open Monica Entry")
            )
            Text("在「快捷指令」App 中添加 Monica 的「Open Entry」动作，可从桌面或自动化直接打开指定条目；打开后仍需解锁保险库。")
                .font(.caption)
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            } label: {
                Label("打开系统设置", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .outlined))

            Button {
                if let url = URL(string: "shortcuts://") {
                    openURL(url)
                }
            } label: {
                Label("打开快捷指令", systemImage: "square.stack.3d.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .filled))
        }
    }
}
