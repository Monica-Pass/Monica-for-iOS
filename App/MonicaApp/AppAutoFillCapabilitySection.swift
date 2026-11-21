import MonicaCore
import SwiftUI

/// 自动填充能力矩阵的界面文案。
///
/// 文案与 `AutoFillCapability` 的事实分离：Core 只声明事实，App 负责中英文展示。
/// `GeneratorSaveLoginTests` 会扫描这里的全部文案，确保没有承诺系统一定会在所有输入框展示建议的表述。
enum AppAutoFillCapabilityCopy {
    static func title(for capability: AutoFillCapability) -> String {
        switch capability.id {
        case AutoFillCapability.credentialProvider.id:
            return String(localized: "系统自动填充扩展")
        case AutoFillCapability.systemQuickType.id:
            return String(localized: "系统 QuickType 建议")
        case AutoFillCapability.arbitraryFieldScan.id:
            return String(localized: "监听任意输入框")
        case AutoFillCapability.inlineSuggestionPanel.id:
            return String(localized: "内联建议面板")
        case AutoFillCapability.strongPasswordSuggestion.id:
            return String(localized: "系统强密码建议")
        case AutoFillCapability.readDefaultManager.id:
            return String(localized: "读取系统默认密码管理器")
        case AutoFillCapability.defaultManagerSelection.id:
            return String(localized: "选择系统默认密码管理器")
        case AutoFillCapability.openAppSettings.id:
            return String(localized: "打开 Monica 系统设置")
        case AutoFillCapability.openPasswordSettings.id:
            return String(localized: "直达系统密码选项")
        case AutoFillCapability.inAppGenerator.id:
            return String(localized: "App 内生成密码")
        case AutoFillCapability.saveGeneratedLogin.id:
            return String(localized: "保存生成结果为登录项")
        default:
            return capability.id
        }
    }

    static func detail(for capability: AutoFillCapability) -> String {
        switch capability.id {
        case AutoFillCapability.credentialProvider.id:
            return String(localized: "Monica 通过系统「密码自动填充」扩展提供候选；只有系统识别出的用户名 / 密码输入框会调用它。")
        case AutoFillCapability.systemQuickType.id:
            return String(localized: "键盘上方的建议是否出现、显示哪一条由 iOS 决定；Monica 无法强制它在所有输入框出现。")
        case AutoFillCapability.arbitraryFieldScan.id:
            return String(localized: "iOS 不允许第三方自动填充扩展监听其它 App 或网页里的输入框，Monica 不能扫描任意字段。")
        case AutoFillCapability.inlineSuggestionPanel.id:
            return String(localized: "Monica 不能在其它 App 的输入框旁注入内联建议面板，也不能替换系统键盘。")
        case AutoFillCapability.strongPasswordSuggestion.id:
            return String(localized: "系统键盘的强密码建议是 iOS 的界面，第三方扩展不能把自己的建议注入其中；可以在 Monica 内生成后复制或保存。")
        case AutoFillCapability.readDefaultManager.id:
            return String(localized: "iOS 不提供读取「系统默认密码管理器是谁」的公开接口。")
        case AutoFillCapability.defaultManagerSelection.id:
            return String(localized: "默认来源只能由你在系统设置里选择，Monica 不能替你切换。")
        case AutoFillCapability.openAppSettings.id:
            return String(localized: "Monica 可以用系统公开的 openSettingsURLString 打开本 App 的设置页。")
        case AutoFillCapability.openPasswordSettings.id:
            return String(localized: "iOS 没有公开的「密码选项」深链，Monica 只能打开本 App 设置页，剩余路径需要手动进入。")
        case AutoFillCapability.inAppGenerator.id:
            return String(localized: "Monica 可以在 App 内生成密码、短语、PIN 与 API Token，并一键复制。")
        case AutoFillCapability.saveGeneratedLogin.id:
            return String(localized: "生成结果可以编辑并保存进保险库，之后从登录项复制或交给系统自动填充。")
        default:
            return ""
        }
    }

    static func availabilityLabel(for availability: AutoFillCapability.Availability) -> String {
        switch availability {
        case .supported:
            return String(localized: "公开 API 支持")
        case .systemDecided:
            return String(localized: "由 iOS 决定")
        case .unsupported:
            return String(localized: "公开 API 不支持")
        }
    }

    static func systemImage(for capability: AutoFillCapability) -> String {
        switch capability.id {
        case AutoFillCapability.credentialProvider.id:
            return "puzzlepiece.extension"
        case AutoFillCapability.systemQuickType.id:
            return "keyboard"
        case AutoFillCapability.arbitraryFieldScan.id:
            return "eye.slash"
        case AutoFillCapability.inlineSuggestionPanel.id:
            return "rectangle.slash"
        case AutoFillCapability.strongPasswordSuggestion.id:
            return "lock.slash"
        case AutoFillCapability.readDefaultManager.id:
            return "lock.doc"
        case AutoFillCapability.defaultManagerSelection.id:
            return "switch.2"
        case AutoFillCapability.openAppSettings.id:
            return "gearshape"
        case AutoFillCapability.openPasswordSettings.id:
            return "link.badge.plus"
        case AutoFillCapability.inAppGenerator.id:
            return "wand.and.stars"
        case AutoFillCapability.saveGeneratedLogin.id:
            return "tray.and.arrow.down"
        default:
            return "questionmark.circle"
        }
    }

    static var allVisibleCopy: [String] {
        AutoFillCapability.matrix.flatMap { capability in
            [title(for: capability), detail(for: capability)]
        } + AutoFillCapability.Availability.allCases.map(availabilityLabel(for:))
    }
}

/// 能力矩阵卡片：引导页与设置页共用的诚实边界说明。
struct AppAutoFillCapabilityMatrixSection: View {
    var body: some View {
        AndroidParitySection(title: String(localized: "能力矩阵")) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                Text("下表说明 Monica 在 iOS 公开 API 边界内能做什么。系统 QuickType 结果由 iOS 决定，无法强制出现在所有输入框。")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(AutoFillCapability.highlighted) { capability in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: AppAutoFillCapabilityCopy.systemImage(for: capability))
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(AndroidParityPalette.primary)
                                .frame(width: 24, height: 24)
                            Text(AppAutoFillCapabilityCopy.title(for: capability))
                                .font(.subheadline.weight(.heavy))
                                .foregroundStyle(AndroidParityPalette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Text(AppAutoFillCapabilityCopy.availabilityLabel(for: capability.availability))
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(availabilityColor(capability.availability))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(availabilityColor(capability.availability).opacity(0.14), in: Capsule())
                        }
                        Text(AppAutoFillCapabilityCopy.detail(for: capability))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if capability.id != AutoFillCapability.highlighted.last?.id {
                        AndroidParityDivider()
                    }
                }
            }
        }
    }

    private func availabilityColor(_ availability: AutoFillCapability.Availability) -> Color {
        switch availability {
        case .supported:
            return AndroidParityPalette.primary
        case .systemDecided:
            return .orange
        case .unsupported:
            return AndroidParityPalette.textSecondary
        }
    }
}
