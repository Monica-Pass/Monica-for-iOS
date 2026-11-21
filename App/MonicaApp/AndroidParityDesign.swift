import MonicaCore
import MonicaStorage
import SwiftUI

extension KeePassContainerFormat {
    var localizedDisplayName: String {
        switch self {
        case .kdbx:
            return "KDBX"
        case .legacyKdb:
            return "KDB"
        case .unknown:
            return String(localized: "未知格式")
        }
    }
}

extension KeePassCredentialSummary {
    var localizedDisplayName: String {
        switch (hasPassword, hasKeyFile) {
        case (true, true):
            let suffix = keyFileCandidateCount > 0
                ? String(localized: "（\(keyFileCandidateCount) 种 key 解析）")
                : ""
            return String(localized: "密码 + 密钥文件") + suffix
        case (true, false):
            return String(localized: "仅密码")
        case (false, true):
            let suffix = keyFileCandidateCount > 0
                ? String(localized: "（\(keyFileCandidateCount) 种 key 解析）")
                : ""
            return String(localized: "仅密钥文件") + suffix
        case (false, false):
            return String(localized: "未提供凭据")
        }
    }
}

extension KeePassReadOnlyImportSkipReason {
    var localizedDisplayName: String {
        switch self {
        case .deletedEntry:
            return String(localized: "回收站条目")
        }
    }
}

extension UnifiedVaultItemKind {
    /// The package exposes Chinese display names for storage diagnostics; keep
    /// those stable as data while localizing the copy shown in the app.
    var localizedDisplayName: String {
        switch self {
        case .login:
            return String(localized: "密码")
        case .totp:
            return String(localized: "验证器")
        case .note:
            return String(localized: "笔记")
        case .card:
            return String(localized: "银行卡")
        case .identity:
            return String(localized: "证件")
        case .passkey:
            return String(localized: "通行密钥")
        case .sshKey:
            return String(localized: "SSH 密钥")
        case .apiToken:
            return String(localized: "API Token")
        case .wifi:
            return String(localized: "Wi-Fi")
        case .sso:
            return String(localized: "SSO")
        case .barcode:
            return String(localized: "条码")
        case .send:
            return String(localized: "安全发送")
        case .steam:
            return String(localized: "Steam")
        case .attachmentRef:
            return String(localized: "附件")
        }
    }
}

private struct ParitySpacingScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

private struct ParityLineSpacingDeltaKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// Combined Dynamic Type ratio × density spacing multiplier (1 = unchanged).
    var paritySpacingScale: CGFloat {
        get { self[ParitySpacingScaleKey.self] }
        set { self[ParitySpacingScaleKey.self] = newValue }
    }

    /// Extra line spacing from the loose density, scaled by Dynamic Type (0 = unchanged).
    var parityLineSpacingDelta: CGFloat {
        get { self[ParityLineSpacingDeltaKey.self] }
        set { self[ParityLineSpacingDeltaKey.self] = newValue }
    }
}

// MARK: - Android parity palette

enum AndroidParityPalette {
    // 所有颜色都是动态颜色：深浅色、增强对比度来自 UITraitCollection，
    // 主题预设 / 自定义强调色来自 `AppThemeRuntime` 的加锁快照。
    // 这样 400+ 个既有调用点无需改动就能跟随主题。

    static var background: Color { dynamic { $0.background } }
    static var surface: Color { dynamic { $0.surface } }
    static var surfaceVariant: Color { dynamic { $0.surfaceVariant } }
    static var surfaceElevated: Color { dynamic { $0.surfaceElevated } }
    static var primary: Color { dynamic { $0.accent } }
    /// 强调色上可读的前景色（填充按钮、徽章）。
    static var onPrimary: Color { dynamic { $0.onAccent } }
    /// 始终偏暗的强调色底板（信用卡、编辑器头部）。
    static var primaryDeep: Color {
        dynamic { $0.accent.blended(with: .ink, amount: 0.62) }
    }
    /// `primaryDeep` 上的正文颜色。
    static var onPrimaryDeep: Color {
        Color(UIColor { traits in
            let palette = AppThemeRuntime.shared.palette(for: traits)
            let color = traits.userInterfaceStyle == .light ? AppearanceColor.snow : palette.textPrimary
            return color.uiColor
        })
    }
    static var primaryContainer: Color { dynamic { $0.accentContainer } }
    static var secondaryContainer: Color {
        dynamic { $0.surfaceVariant.blended(with: $0.accent, amount: 0.08) }
    }
    static var tertiaryContainer: Color { dynamic { $0.surfaceElevated } }
    static var outline: Color { dynamic { $0.outline } }
    static var textPrimary: Color { dynamic { $0.textPrimary } }
    static var textSecondary: Color { dynamic { $0.textSecondary } }
    static var danger: Color { dynamic { $0.danger } }

    private static func dynamic(_ body: @escaping (ThemePalette) -> AppearanceColor) -> Color {
        Color(UIColor { traits in
            body(AppThemeRuntime.shared.palette(for: traits)).uiColor
        })
    }
}

enum AndroidParityTypography {
    // Baseline point sizes are kept as the single source of truth and are asserted
    // by `VaultSessionModelTests.testAndroidParityTypographyUsesCompactIOSSizing()`.
    static let screenTitleSize: CGFloat = 34
    static let generatorTitleSize: CGFloat = 34
    static let editorTitleSize: CGFloat = 24
    static let prominentValueSize: CGFloat = 26
    static let controlIconSize: CGFloat = 22
    static let tileIconSize: CGFloat = 18

    // Dynamic Type factories: text styles scale automatically with the user's
    // content size, unlike the fixed `.system(size:)` fonts they replace.
    static func displayTitle(weight: Font.Weight = .heavy) -> Font {
        Font.system(.largeTitle, design: .rounded, weight: weight)
    }

    static func prominentTitle(weight: Font.Weight = .heavy) -> Font {
        Font.system(.title2, design: .rounded, weight: weight)
    }

    static func controlIcon(weight: Font.Weight = .heavy) -> Font {
        Font.system(.title2, design: .default, weight: weight)
    }

    static func largeIcon(weight: Font.Weight = .semibold) -> Font {
        Font.system(.largeTitle, design: .default, weight: weight)
    }

    static func smallIcon(weight: Font.Weight = .semibold) -> Font {
        Font.system(.body, design: .default, weight: weight)
    }

    static func roundedBody(weight: Font.Weight = .heavy) -> Font {
        Font.system(.body, design: .rounded, weight: weight)
    }

    static func monospacedValue(weight: Font.Weight = .medium) -> Font {
        Font.system(.body, design: .monospaced, weight: weight)
    }
}

struct AndroidParityScreen<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.paritySpacingScale) private var spacingScale
    @Environment(\.parityLineSpacingDelta) private var lineSpacingDelta

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12 * spacingScale) {
                content
                    .lineSpacing(lineSpacingDelta)
            }
            .padding(.horizontal, 16 * spacingScale)
            .padding(.top, 8 * spacingScale)
            .padding(.bottom, 24 * spacingScale)
        }
        .background(AndroidParityPalette.background.ignoresSafeArea())
        .foregroundStyle(AndroidParityPalette.textPrimary)
    }
}

struct AndroidParitySection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.paritySpacingScale) private var spacingScale

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * spacingScale) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.primary)
                .padding(.horizontal, 4 * spacingScale)
                .padding(.top, 8 * spacingScale)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AndroidParityCard<Content: View>: View {
    var fill = AndroidParityPalette.surface
    var cornerRadius: CGFloat = 12
    @ViewBuilder var content: Content
    @Environment(\.paritySpacingScale) private var spacingScale

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * spacingScale) {
            content
        }
        .padding(16 * spacingScale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(AndroidParityPalette.outline, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
    }
}

struct AndroidParityIconTile: View {
    let systemImage: String
    var fill = AndroidParityPalette.primaryContainer
    var tint = AndroidParityPalette.primary

    var body: some View {
        Image(systemName: systemImage)
            .font(AndroidParityTypography.smallIcon(weight: .semibold))
            .foregroundStyle(tint)
            .frame(minWidth: 40, minHeight: 40)
            .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct AndroidParityTextFieldStyle: TextFieldStyle {
    @Environment(\.paritySpacingScale) private var spacingScale

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, 14 * spacingScale)
            .padding(.vertical, 12 * spacingScale)
            .background(AndroidParityPalette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AndroidParityPalette.outline.opacity(1.8), lineWidth: 1)
            }
    }
}

enum AndroidParityButtonTone {
    case filled
    case outlined
    case destructiveOutlined
}

struct AndroidParityButtonStyle: ButtonStyle {
    let tone: AndroidParityButtonTone
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.paritySpacingScale) private var spacingScale

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 16 * spacingScale)
            // 44pt minimum touch target is intentionally NOT scaled by density.
            .frame(minHeight: AppInterfaceDensity.minimumTouchTarget)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .background(background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(border, lineWidth: tone == .filled ? 0 : 1)
            }
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch tone {
        case .filled:
            return AndroidParityPalette.onPrimary
        case .outlined:
            return AndroidParityPalette.primary
        case .destructiveOutlined:
            return .red
        }
    }

    private var background: Color {
        switch tone {
        case .filled:
            return AndroidParityPalette.primary
        case .outlined:
            return AndroidParityPalette.surface.opacity(0.4)
        case .destructiveOutlined:
            return .red.opacity(0.08)
        }
    }

    private var border: Color {
        switch tone {
        case .filled:
            return .clear
        case .outlined:
            return AndroidParityPalette.primary.opacity(0.48)
        case .destructiveOutlined:
            return .red.opacity(0.52)
        }
    }
}

struct AndroidParityInfoRow: View {
    let title: String
    let value: String
    @Environment(\.paritySpacingScale) private var spacingScale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12 * spacingScale) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(AndroidParityPalette.textPrimary)
            Spacer(minLength: 16 * spacingScale)
            Text(value)
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .multilineTextAlignment(.trailing)
        }
        // 32pt row height is a content floor, not a touch target — scale it.
        .frame(minHeight: 32 * spacingScale)
    }
}

struct AndroidParityDivider: View {
    var body: some View {
        Divider()
            .overlay(AndroidParityPalette.outline)
    }
}

struct AndroidParityEntryCard<Trailing: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    var detail: String?
    var isFavorite = false
    var fill = AndroidParityPalette.surface
    var iconFill = AndroidParityPalette.primaryContainer
    var iconTint = AndroidParityPalette.primary
    @ViewBuilder var trailing: Trailing
    @Environment(\.paritySpacingScale) private var spacingScale

    var body: some View {
        HStack(alignment: .center, spacing: 16 * spacingScale) {
            AndroidParityIconTile(systemImage: icon, fill: iconFill, tint: iconTint)
            VStack(alignment: .leading, spacing: 6 * spacingScale) {
                HStack(spacing: 6 * spacingScale) {
                    Text(title.isEmpty ? String(localized: "未命名") : title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("收藏")
                    }
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8 * spacingScale)
            trailing
        }
        .padding(16 * spacingScale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AndroidParityPalette.outline, lineWidth: 0.5)
        }
    }
}

extension AndroidParityEntryCard where Trailing == Image {
    init(
        icon: String,
        title: String,
        subtitle: String,
        detail: String? = nil,
        isFavorite: Bool = false,
        fill: Color = AndroidParityPalette.surface,
        iconFill: Color = AndroidParityPalette.primaryContainer,
        iconTint: Color = AndroidParityPalette.primary
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.isFavorite = isFavorite
        self.fill = fill
        self.iconFill = iconFill
        self.iconTint = iconTint
        self.trailing = Image(systemName: "chevron.right")
    }
}

struct AndroidParityEmptyCard: View {
    let title: String
    let systemImage: String
    @Environment(\.paritySpacingScale) private var spacingScale

    var body: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
            HStack(spacing: 16 * spacingScale) {
                AndroidParityIconTile(
                    systemImage: systemImage,
                    fill: AndroidParityPalette.surface,
                    tint: .secondary
                )
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
