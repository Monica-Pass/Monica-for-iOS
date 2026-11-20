import MonicaCore
import SwiftUI

/// 外观设置：主题预设、自定义强调色、条目图标样式与备用 App 图标。
///
/// 颜色全部通过 `AndroidParityPalette` / `ThemePalette` 动态解析：
/// 深浅色与增强对比度由系统 `UITraitCollection` 决定，本页只负责写入偏好。
struct AppThemeSettingsView: View {
    let session: AppSessionModel

    @Environment(\.colorScheme) private var colorScheme
    @State private var iconError: AlternateAppIconError?
    @State private var isApplyingIcon = false

    private var preferences: AppAppearancePreferences {
        session.appearancePreferences
    }

    private var resolvedScheme: AppearanceResolvedColorScheme {
        colorScheme == .light ? .light : .dark
    }

    private var iconController: AppAlternateIconController {
        AppAlternateIconController.shared
    }

    var body: some View {
        AndroidParitySection(title: String(localized: "主题与图标")) {
            AndroidParityCard {
                colorSchemePicker
                AndroidParityDivider()
                presetGrid
                AndroidParityDivider()
                customAccentPicker
                AndroidParityDivider()
                passwordIconPicker
                AndroidParityDivider()
                appIconSection
            }
        }
        .task {
            reconcileAppIcon()
        }
        .alert(
            String(localized: "无法切换 App 图标"),
            isPresented: Binding(
                get: { iconError != nil },
                set: { presented in if !presented { iconError = nil } }
            )
        ) {
            Button(String(localized: "好"), role: .cancel) {}
        } message: {
            Text(iconError?.errorDescription ?? String(localized: "请稍后再试。"))
        }
    }

    // MARK: - 颜色模式

    private var colorSchemePicker: some View {
        Picker("颜色模式", selection: colorSchemeSelection) {
            ForEach(AppAppearanceColorScheme.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .font(.headline.weight(.heavy))
    }

    private var colorSchemeSelection: Binding<AppAppearanceColorScheme> {
        Binding {
            preferences.colorScheme
        } set: { mode in
            var updated = preferences
            updated.colorScheme = mode
            session.updateAppearancePreferences(updated)
        }
    }

    // MARK: - 主题预设

    private var presetGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("主题预设")
                .font(.headline.weight(.heavy))
            Text("预设提供深浅两套配色；对比度在增强对比度开启时会自动提高。")
                .font(.subheadline)
                .foregroundStyle(AndroidParityPalette.textSecondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                ForEach(ThemePreset.allCases) { preset in
                    presetButton(preset)
                }
            }
        }
    }

    private func presetButton(_ preset: ThemePreset) -> some View {
        let isSelected = preferences.customAccentColor == nil && preferences.themePreset == preset
        let lightPalette = preset.palette(for: .light)
        let darkPalette = preset.palette(for: .dark)
        return Button {
            var updated = preferences
            updated.selectPreset(preset)
            session.updateAppearancePreferences(updated)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(lightPalette.accent.swiftUIColor)
                        .frame(width: 18, height: 18)
                    Circle()
                        .fill(darkPalette.accent.swiftUIColor)
                        .frame(width: 18, height: 18)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(AndroidParityPalette.primary)
                    }
                }
                Text(preset.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textPrimary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                AndroidParityPalette.surfaceVariant.opacity(isSelected ? 0.9 : 0.5),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? AndroidParityPalette.primary : AndroidParityPalette.outline,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(preset.displayName))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - 自定义强调色

    private var customAccentPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            ColorPicker("自定义强调色", selection: customAccentBinding, supportsOpacity: false)
                .font(.headline.weight(.heavy))
            if let customAccent = preferences.customAccentColor,
               let ratio = preferences.customAccentContrast(for: resolvedScheme) {
                Label {
                    Text(contrastHint(for: ratio, accent: customAccent))
                        .font(.subheadline)
                } icon: {
                    Image(systemName: ratio < 4.5 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                }
                .foregroundStyle(ratio < 4.5 ? AndroidParityPalette.danger : AndroidParityPalette.textSecondary)
            }
            if preferences.customAccentColor != nil {
                Button(String(localized: "恢复预设强调色")) {
                    var updated = preferences
                    _ = updated.setCustomAccentHex(nil)
                    session.updateAppearancePreferences(updated)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
            }
        }
    }

    private func contrastHint(for ratio: Double, accent: AppearanceColor) -> String {
        let formatted = String(format: "%.1f", ratio)
        if ratio < 4.5 {
            return String(localized: "当前强调色与背景的对比度为 \(formatted):1，低于 4.5:1，正文可能不易阅读。建议选择更深的颜色。")
        }
        return String(localized: "当前强调色与背景的对比度为 \(formatted):1，符合 4.5:1 的正文可读性要求。")
    }

    private var customAccentBinding: Binding<Color> {
        Binding {
            preferences.customAccentColor?.swiftUIColor ?? preferences.effectiveAccentColor(for: resolvedScheme).swiftUIColor
        } set: { color in
            guard let hex = color.appearanceHexString else { return }
            var updated = preferences
            guard updated.setCustomAccentHex(hex) else { return }
            session.updateAppearancePreferences(updated)
        }
    }

    // MARK: - 密码列表图标

    private var passwordIconPicker: some View {
        Picker("密码列表图标", selection: passwordIconStyleSelection) {
            ForEach(AppPasswordListIconStyle.allCases) { style in
                Text(style.label).tag(style)
            }
        }
        .font(.headline.weight(.heavy))
    }

    private var passwordIconStyleSelection: Binding<AppPasswordListIconStyle> {
        Binding {
            preferences.passwordListIconStyle
        } set: { style in
            var updated = preferences
            updated.passwordListIconStyle = style
            session.updateAppearancePreferences(updated)
        }
    }

    // MARK: - 备用 App 图标

    private var appIconSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("App 图标")
                .font(.headline.weight(.heavy))
            Text("备用图标通过系统 API 立即切换，恢复默认同样即时生效。")
                .font(.subheadline)
                .foregroundStyle(AndroidParityPalette.textSecondary)
            ForEach(AlternateAppIcon.allCases) { icon in
                appIconRow(icon)
            }
            if !iconController.isSupported {
                Label {
                    Text("当前设备或模拟器不支持备用 App 图标，真机安装后可在本页切换。")
                        .font(.subheadline)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .foregroundStyle(AndroidParityPalette.textSecondary)
            }
            Text("iOS 不允许 App 在运行时修改显示名称；备用图标只通过系统的 App 图标 API 切换，名称与默认图标仍由 Xcode 工程配置决定。")
                .font(.caption)
                .foregroundStyle(AndroidParityPalette.textSecondary)
            Button(String(localized: "恢复默认图标")) {
                applyAppIcon(.standard)
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
            .disabled(!iconController.isSupported || isApplyingIcon || preferences.appIcon == .standard)
        }
    }

    private func appIconRow(_ icon: AlternateAppIcon) -> some View {
        let isSelected = preferences.appIcon == icon
        return Button {
            applyAppIcon(icon)
        } label: {
            HStack(spacing: 14) {
                appIconThumbnail(icon)
                VStack(alignment: .leading, spacing: 4) {
                    Text(icon.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textPrimary)
                    Text(icon.detail)
                        .font(.caption)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
                Spacer(minLength: 0)
                if isApplyingIcon && isSelected {
                    ProgressView()
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AndroidParityPalette.primary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                AndroidParityPalette.surfaceVariant.opacity(isSelected ? 0.9 : 0.5),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? AndroidParityPalette.primary : AndroidParityPalette.outline,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(!iconController.isSupported || isApplyingIcon)
        .accessibilityLabel(Text(icon.displayName))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func appIconThumbnail(_ icon: AlternateAppIcon) -> some View {
        let background: Color
        let glyph: Color
        switch icon {
        case .standard:
            background = AndroidParityPalette.primaryContainer
            glyph = AndroidParityPalette.primary
        case .midnight:
            background = Color(.sRGB, red: 0.08, green: 0.12, blue: 0.24, opacity: 1)
            glyph = Color(.sRGB, red: 0.96, green: 0.77, blue: 0.36, opacity: 1)
        case .aurora:
            background = Color(.sRGB, red: 0.04, green: 0.17, blue: 0.15, opacity: 1)
            glyph = Color(.sRGB, red: 0.72, green: 0.98, blue: 0.92, opacity: 1)
        }
        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(background)
            .frame(width: 44, height: 44)
            .overlay {
                Image(systemName: "key.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(glyph)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AndroidParityPalette.outline, lineWidth: 1)
            }
    }

    private func applyAppIcon(_ icon: AlternateAppIcon) {
        guard !isApplyingIcon else { return }
        isApplyingIcon = true
        Task { @MainActor in
            defer { isApplyingIcon = false }
            do {
                try await iconController.apply(icon)
                var updated = session.appearancePreferences
                updated.appIcon = icon
                session.updateAppearancePreferences(updated)
            } catch let error as AlternateAppIconError {
                iconError = error
                reconcileAppIcon()
            } catch {
                iconError = .notAvailable(icon.rawValue)
                reconcileAppIcon()
            }
        }
    }

    /// 图标状态以系统为准：上次从备份恢复的偏好可能在当前设备上并未生效。
    private func reconcileAppIcon() {
        // 以系统实际值为准：模拟器/不支持备用图标的设备上 `current` 会是默认图标，
        // 这样界面不会把「偏好里记录过、但本机并未生效」的图标显示成已应用。
        let actual = iconController.current
        guard session.appearancePreferences.appIcon != actual else { return }
        var updated = session.appearancePreferences
        updated.appIcon = actual
        session.updateAppearancePreferences(updated)
    }
}

private extension Color {
    /// `Color` → `#RRGGBB`。系统转换失败（例如使用非 sRGB 色彩空间）时返回 nil，
    /// 调用方忽略这次选择而不是写入一个猜测值。
    var appearanceHexString: String? {
        let uiColor = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            guard let converted = uiColor.cgColor.converted(
                to: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                intent: .defaultIntent,
                options: nil
            ), let components = converted.components, components.count >= 3 else {
                return nil
            }
            return Self.hexString(red: components[0], green: components[1], blue: components[2])
        }
        return Self.hexString(red: red, green: green, blue: blue)
    }

    static func hexString(red: CGFloat, green: CGFloat, blue: CGFloat) -> String {
        func clamp(_ value: CGFloat) -> Int {
            Int((max(0, min(1, value)) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X", clamp(red), clamp(green), clamp(blue))
    }
}
