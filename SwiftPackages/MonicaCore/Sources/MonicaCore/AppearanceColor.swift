import Foundation

/// 与具体 UI 框架无关的 sRGB 颜色。
///
/// 主题模型必须能在 Swift Package 中做纯计算（对比度、混色、序列化），
/// 因此这里不依赖 SwiftUI / UIKit，App 层再把它桥接成 `Color`。
public struct AppearanceColor: Hashable, Sendable, Codable, CustomStringConvertible {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = Self.clamp(alpha)
    }

    /// 解析 `#RRGGBB` / `#RRGGBBAA` / `RRGGBB` / 三字符缩写；非法输入返回 nil。
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") {
            text.removeFirst()
        }
        text = text.uppercased()
        if text.count == 3 {
            text = text.map { "\($0)\($0)" }.joined()
        }
        guard text.count == 6 || text.count == 8, text.allSatisfy(\.isHexDigit) else {
            return nil
        }
        var value: UInt64 = 0
        guard Scanner(string: text).scanHexInt64(&value) else { return nil }
        if text.count == 6 {
            self.init(
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255
            )
        } else {
            self.init(
                red: Double((value >> 24) & 0xFF) / 255,
                green: Double((value >> 16) & 0xFF) / 255,
                blue: Double((value >> 8) & 0xFF) / 255,
                alpha: Double(value & 0xFF) / 255
            )
        }
    }

    public static let clear = AppearanceColor(red: 0, green: 0, blue: 0, alpha: 0)
    /// 用于浅色背景上的正文色，接近纯黑但避免纯黑带来的 OLED 拖影。
    public static let ink = AppearanceColor(hex: "#0B0F0E")!
    /// 用于深色背景上的正文色。
    public static let snow = AppearanceColor(hex: "#F7FAF8")!

    public var hexString: String {
        let redValue = Int((red * 255).rounded())
        let greenValue = Int((green * 255).rounded())
        let blueValue = Int((blue * 255).rounded())
        let base = String(format: "#%02X%02X%02X", redValue, greenValue, blueValue)
        guard alpha < 0.999 else { return base }
        return base + String(format: "%02X", Int((alpha * 255).rounded()))
    }

    public var description: String { hexString }

    public var isOpaque: Bool { alpha >= 0.999 }

    public func withAlpha(_ value: Double) -> AppearanceColor {
        AppearanceColor(red: red, green: green, blue: blue, alpha: value)
    }

    public func opacity(_ value: Double) -> AppearanceColor {
        withAlpha(alpha * Self.clamp(value))
    }

    /// 线性混合，`amount` 为 0 时返回自身，为 1 时返回 `other`。
    public func blended(with other: AppearanceColor, amount: Double) -> AppearanceColor {
        let ratio = Self.clamp(amount)
        return AppearanceColor(
            red: red + (other.red - red) * ratio,
            green: green + (other.green - green) * ratio,
            blue: blue + (other.blue - blue) * ratio,
            alpha: alpha + (other.alpha - alpha) * ratio
        )
    }

    /// WCAG 2.2 相对亮度。
    public var relativeLuminance: Double {
        0.2126 * Self.linearComponent(red)
            + 0.7152 * Self.linearComponent(green)
            + 0.0722 * Self.linearComponent(blue)
    }

    /// WCAG 对比度，范围 1...21。
    public func contrastRatio(with other: AppearanceColor) -> Double {
        let first = relativeLuminance
        let second = other.relativeLuminance
        let lighter = max(first, second)
        let darker = min(first, second)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// 把半透明颜色合成到不透明背景上，用于对比度检查（透明度会让实际对比度下降）。
    public func composited(over background: AppearanceColor) -> AppearanceColor {
        guard !isOpaque else { return self }
        return blended(with: background, amount: alpha)
    }

    /// 在该颜色上可读性最高的文字色（黑或白），保证对比度不低于 4.5:1。
    public func preferredForeground() -> AppearanceColor {
        let inkRatio = Self.ink.contrastRatio(with: self)
        let snowRatio = Self.snow.contrastRatio(with: self)
        return inkRatio >= snowRatio ? .ink : .snow
    }

    public static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func linearComponent(_ component: Double) -> Double {
        component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }

    // 编码为单个 `#RRGGBB` / `#RRGGBBAA` 字符串，便于写进 JSON 和历史字段共存。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let color = AppearanceColor(hex: text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "无法解析颜色：\(text)"
            )
        }
        self = color
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexString)
    }
}
