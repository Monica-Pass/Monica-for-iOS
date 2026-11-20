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
        case .send:
            return String(localized: "安全发送")
        case .attachmentRef:
            return String(localized: "附件")
        }
    }
}

// MARK: - Interface density (issue #61)

/// Global, user-selectable interface density. Adjusts spacing / line height only —
/// never font sizes, icon sizes, corner radii, or the 44pt minimum touch target.
/// Fonts scale through system text styles; this enum only tunes the whitespace
/// between them, so it is safe to combine with the largest accessibility sizes.
enum AppInterfaceDensity: String, Sendable, Codable, Equatable, CaseIterable, Identifiable {
    case `default`
    case compact
    case loose

    var id: String { rawValue }

    var label: String {
        switch self {
        case .default: String(localized: "默认")
        case .compact: String(localized: "紧凑")
        case .loose: String(localized: "宽松")
        }
    }

    var detail: String {
        switch self {
        case .default: String(localized: "标准间距与行高。")
        case .compact: String(localized: "收紧间距与行高，一屏显示更多内容。")
        case .loose: String(localized: "放宽间距与行高，内容更疏朗易读。")
        }
    }

    /// Multiplies every shared-component spacing/padding value.
    var spacingScale: CGFloat {
        switch self {
        case .default: 1.0
        case .compact: 0.8
        case .loose: 1.3
        }
    }

    /// Extra points of line spacing applied to screen content.
    var lineSpacingDelta: CGFloat {
        switch self {
        case .default, .compact: 0
        case .loose: 3
        }
    }

    static let minimumTouchTarget: CGFloat = 44

    /// Touch targets never shrink below the accessibility minimum, regardless of density.
    func touchTarget(_ base: CGFloat) -> CGFloat {
        max(Self.minimumTouchTarget, base)
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
    static let background = Color(red: 0.06, green: 0.06, blue: 0.06)
    static let surface = Color(red: 0.15, green: 0.15, blue: 0.15)
    static let surfaceVariant = Color(red: 0.20, green: 0.21, blue: 0.20)
    static let primary = Color(red: 0.53, green: 0.86, blue: 0.80)
    static let primaryDeep = Color(red: 0.00, green: 0.38, blue: 0.33)
    static let primaryContainer = Color(red: 0.00, green: 0.38, blue: 0.33)
    static let secondaryContainer = Color(red: 0.12, green: 0.24, blue: 0.22)
    static let tertiaryContainer = Color(red: 0.27, green: 0.27, blue: 0.26)
    static let outline = Color.white.opacity(0.14)
    static let textPrimary = Color(red: 0.92, green: 0.92, blue: 0.92)
    static let textSecondary = Color(red: 0.76, green: 0.76, blue: 0.76)
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
            return AndroidParityPalette.textPrimary
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
