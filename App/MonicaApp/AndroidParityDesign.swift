import SwiftUI

struct AndroidParityBottomNavigation: View {
    let tabs: [MonicaAppTab]
    @Binding var selectedTab: MonicaAppTab

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            ForEach(tabs, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    AndroidParityBottomNavigationItem(
                        tab: tab,
                        isSelected: selectedTab == tab
                    )
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(AndroidParityPalette.background.opacity(0.96))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AndroidParityPalette.outline)
                .frame(height: 0.5)
        }
    }
}

private struct AndroidParityBottomNavigationItem: View {
    let tab: MonicaAppTab
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 18, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? AndroidParityPalette.primary : .secondary)
                .frame(width: 44, height: 28)
                .background {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(AndroidParityPalette.primaryContainer)
                    }
                }
            Text(tab.title)
                .font(.caption2.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? AndroidParityPalette.primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(minWidth: 48, minHeight: 48)
        .contentShape(Rectangle())
    }
}

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
    static let screenTitleSize: CGFloat = 34
    static let generatorTitleSize: CGFloat = 34
    static let editorTitleSize: CGFloat = 24
    static let prominentValueSize: CGFloat = 26
    static let controlIconSize: CGFloat = 22
    static let tileIconSize: CGFloat = 18
}

struct AndroidParityScreen<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(AndroidParityPalette.background.ignoresSafeArea())
        .foregroundStyle(AndroidParityPalette.textPrimary)
    }
}

struct AndroidParitySection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.primary)
                .padding(.horizontal, 4)
                .padding(.top, 8)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AndroidParityCard<Content: View>: View {
    var fill = AndroidParityPalette.surface
    var cornerRadius: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(16)
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
            .font(.system(size: AndroidParityTypography.tileIconSize, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 40, height: 40)
            .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct AndroidParityTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
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

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(AndroidParityPalette.textPrimary)
            Spacer(minLength: 16)
            Text(value)
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 32)
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

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            AndroidParityIconTile(systemImage: icon, fill: iconFill, tint: iconTint)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(title.isEmpty ? "未命名" : title)
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
            Spacer(minLength: 8)
            trailing
        }
        .padding(16)
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

    var body: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
            HStack(spacing: 16) {
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
