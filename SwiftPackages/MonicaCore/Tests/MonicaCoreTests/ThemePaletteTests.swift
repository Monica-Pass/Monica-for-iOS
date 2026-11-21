import Foundation
import Testing
import MonicaCore

@Suite("主题预设与对比度")
struct ThemePaletteTests {
    /// 正文文字在背景 / 卡片 / 变色卡片上都必须达到 WCAG AA（4.5:1）。
    @Test func textMeetsAAOnEveryPreset() {
        for preset in ThemePreset.allCases {
            for scheme in AppearanceResolvedColorScheme.allCases {
                let palette = preset.palette(for: scheme)
                let surfaces: [(String, AppearanceColor)] = [
                    ("background", palette.background),
                    ("surface", palette.surface),
                    ("surfaceVariant", palette.surfaceVariant),
                    ("surfaceElevated", palette.surfaceElevated),
                    ("accentContainer", palette.accentContainer)
                ]
                for (name, background) in surfaces {
                    let primary = palette.textPrimary.contrastRatio(with: background)
                    let secondary = palette.textSecondary.contrastRatio(with: background)
                    #expect(
                        primary >= 4.5,
                        "\(preset.rawValue)/\(scheme.rawValue) 正文在 \(name) 上对比度 \(primary) < 4.5"
                    )
                    #expect(
                        secondary >= 4.5,
                        "\(preset.rawValue)/\(scheme.rawValue) 次要文字在 \(name) 上对比度 \(secondary) < 4.5"
                    )
                }
            }
        }
    }

    /// 强调色会被直接当作文字 / 图标压在背景上，同样要求 AA。
    @Test func accentMeetsAAOnBackground() {
        for preset in ThemePreset.allCases {
            for scheme in AppearanceResolvedColorScheme.allCases {
                let palette = preset.palette(for: scheme)
                let ratio = palette.accentContrast
                #expect(
                    ratio >= 4.5,
                    "\(preset.rawValue)/\(scheme.rawValue) 强调色对比度 \(ratio) < 4.5"
                )
            }
        }
    }

    /// 强调色上的文字必须是黑/白中更可读的那个，且 >= 4.5。
    @Test func onAccentIsReadableForEveryPreset() {
        for preset in ThemePreset.allCases {
            for scheme in AppearanceResolvedColorScheme.allCases {
                let palette = preset.palette(for: scheme)
                let ratio = palette.onAccent.contrastRatio(with: palette.accent)
                #expect(ratio >= 4.5, "\(preset.rawValue)/\(scheme.rawValue) onAccent 对比度 \(ratio)")
                #expect(palette.onAccent == .ink || palette.onAccent == .snow)
            }
        }
    }

    /// 增强对比度模式必须在普通模式之上继续提高正文对比度。
    @Test func highContrastImprovesTextContrast() {
        for preset in ThemePreset.allCases {
            for scheme in AppearanceResolvedColorScheme.allCases {
                let normal = preset.palette(for: scheme)
                let high = preset.palette(for: scheme, highContrast: true)
                #expect(high.textPrimary.contrastRatio(with: high.background) >= 7)
                #expect(high.textSecondary.contrastRatio(with: high.background) >= 7)
                #expect(high.textPrimary.contrastRatio(with: high.background) >= normal.textPrimary.contrastRatio(with: normal.background))
                #expect(high.outline.alpha >= normal.outline.alpha)
            }
        }
    }

    /// 减少透明度模式：调色板本身保持不透明，避免叠加材质后文字发灰。
    @Test func reduceTransparencyKeepsOpaqueSurfaces() {
        for preset in ThemePreset.allCases {
            for scheme in AppearanceResolvedColorScheme.allCases {
                let palette = preset.palette(for: scheme, reduceTransparency: true)
                #expect(palette.surface.isOpaque)
                #expect(palette.background.isOpaque)
                #expect(palette.accentContainer.isOpaque)
                #expect(palette.isReduceTransparency)
            }
        }
    }

    /// 自定义强调色使用同一套对比度规则。
    @Test func customAccentUsesSameContrastRules() {
        let custom = AppearanceColor(hex: "#B4005A")!
        for scheme in AppearanceResolvedColorScheme.allCases {
            for highContrast in [false, true] {
                let palette = ThemePalette.make(
                    accent: custom,
                    scheme: scheme,
                    highContrast: highContrast
                )
                #expect(palette.accent == custom)
                #expect(palette.onAccent.contrastRatio(with: custom) >= 4.5)
            }
        }
        // 太浅的强调色在浅色背景上必然不达标 —— 这是设置页需要提示的场景。
        let pale = AppearanceColor(hex: "#F7E36B")!
        let lightPalette = ThemePalette.make(accent: pale, scheme: .light)
        #expect(lightPalette.accentContrast < 4.5)
    }

    /// 每个预设都必须有稳定、唯一的 raw value；展示名不得参与存储。
    @Test func presetsHaveStableUniqueIdentifiers() {
        let rawValues = ThemePreset.allCases.map(\.rawValue)
        #expect(Set(rawValues).count == rawValues.count)
        #expect(rawValues == rawValues.map { $0.lowercased() })
        #expect(ThemePreset.allCases.count >= 8)
        // 历史 raw value 不可变：这些字符串可能已经写进用户设备。
        #expect(ThemePreset.monica.rawValue == "monica")
        #expect(ThemePreset.forest.rawValue == "forest")
        #expect(ThemePreset.ocean.rawValue == "ocean")
        #expect(ThemePreset.sunset.rawValue == "sunset")
    }

    @Test func legacyAccentMigratesToEquivalentPreset() {
        #expect(ThemePreset.migrated(fromLegacyAccent: "monica") == .monica)
        #expect(ThemePreset.migrated(fromLegacyAccent: "green") == .forest)
        #expect(ThemePreset.migrated(fromLegacyAccent: "blue") == .ocean)
        #expect(ThemePreset.migrated(fromLegacyAccent: "orange") == .sunset)
        #expect(ThemePreset.migrated(fromLegacyAccent: "unknown") == .monica)
        // 反向映射保证降级兼容。
        #expect(ThemePreset.forest.legacyAccentRawValue == "green")
        #expect(ThemePreset.ocean.legacyAccentRawValue == "blue")
        #expect(ThemePreset.sunset.legacyAccentRawValue == "orange")
    }
}

@Suite("颜色与对比度计算")
struct AppearanceColorTests {
    @Test func hexParsingRoundTrips() {
        #expect(AppearanceColor(hex: "#0E6F62")!.hexString == "#0E6F62")
        #expect(AppearanceColor(hex: "0e6f62")!.hexString == "#0E6F62")
        #expect(AppearanceColor(hex: "#FFF")!.hexString == "#FFFFFF")
        #expect(AppearanceColor(hex: "#10203040")!.hexString == "#10203040")
        #expect(AppearanceColor(hex: "#10203040")!.alpha == 64.0 / 255.0)
        #expect(AppearanceColor(hex: "") == nil)
        #expect(AppearanceColor(hex: "#12345") == nil)
        #expect(AppearanceColor(hex: "#GGGGGG") == nil)
        #expect(AppearanceColor(hex: "not-a-color") == nil)
    }

    @Test func wcagVectorsMatchKnownValues() {
        // WCAG 公开示例：纯黑/纯白 = 21:1，同色 = 1:1，#777 对白 ≈ 4.48:1。
        let black = AppearanceColor(hex: "#000000")!
        let white = AppearanceColor(hex: "#FFFFFF")!
        #expect(abs(black.contrastRatio(with: white) - 21) < 0.01)
        #expect(abs(AppearanceColor(hex: "#777777")!.contrastRatio(with: white) - 4.48) < 0.02)
        #expect(AppearanceColor(hex: "#0E6F62")!.contrastRatio(with: AppearanceColor(hex: "#0E6F62")!) == 1)
        // 品牌 ink/snow 接近但不等于纯黑白，同样应是高对比。
        #expect(AppearanceColor.ink.contrastRatio(with: .snow) > 15)
    }

    @Test func preferredForegroundPicksHigherContrast() {
        #expect(AppearanceColor(hex: "#0E6F62")!.preferredForeground() == .snow)
        #expect(AppearanceColor(hex: "#F3F5F4")!.preferredForeground() == .ink)
    }

    @Test func blendingEndpointBehaviour() {
        let red = AppearanceColor(hex: "#FF0000")!
        let blue = AppearanceColor(hex: "#0000FF")!
        #expect(red.blended(with: blue, amount: 0) == red)
        #expect(red.blended(with: blue, amount: 1) == blue)
        #expect(red.blended(with: blue, amount: 0.5).hexString == "#800080")
    }
}
