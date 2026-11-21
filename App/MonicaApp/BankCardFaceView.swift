import SwiftUI

/// 卡面样式。空字符串保留为「跟随卡组织」，保证旧条目不写新键时也有合理外观。
enum BankCardArtworkStyle: String, CaseIterable, Identifiable, Sendable {
    case followNetwork = ""
    case midnight
    case ocean
    case forest
    case sunset
    case violet

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .followNetwork: return String(localized: "跟随卡组织")
        case .midnight: return String(localized: "午夜黑")
        case .ocean: return String(localized: "深海蓝")
        case .forest: return String(localized: "森林绿")
        case .sunset: return String(localized: "日落橙")
        case .violet: return String(localized: "紫罗兰")
        }
    }
}

/// 纯 SwiftUI 绘制的银行卡卡面：渐变、芯片与文字网络标志，不使用第三方资源或真实卡组织图片。
struct BankCardFaceView: View {
    let title: String
    let cardholderName: String
    let number: String
    let expiryMonth: String
    let expiryYear: String
    let issuer: String
    let network: String
    let artwork: String
    let masksNumber: Bool

    private var style: BankCardArtworkStyle {
        BankCardArtworkStyle(rawValue: artwork) ?? .followNetwork
    }

    private var gradientColors: [Color] {
        switch style {
        case .midnight:
            return [Color(red: 0.07, green: 0.08, blue: 0.11), Color(red: 0.18, green: 0.20, blue: 0.26)]
        case .ocean:
            return [Color(red: 0.03, green: 0.16, blue: 0.29), Color(red: 0.11, green: 0.43, blue: 0.55)]
        case .forest:
            return [Color(red: 0.05, green: 0.23, blue: 0.16), Color(red: 0.18, green: 0.42, blue: 0.31)]
        case .sunset:
            return [Color(red: 0.43, green: 0.16, blue: 0.16), Color(red: 0.85, green: 0.48, blue: 0.23)]
        case .violet:
            return [Color(red: 0.19, green: 0.12, blue: 0.36), Color(red: 0.42, green: 0.29, blue: 0.72)]
        case .followNetwork:
            return networkColors
        }
    }

    private var networkColors: [Color] {
        let key = network.lowercased()
        if key.contains("visa") {
            return [Color(red: 0.10, green: 0.12, blue: 0.44), Color(red: 0.19, green: 0.32, blue: 0.72)]
        }
        if key.contains("master") {
            return [Color(red: 0.16, green: 0.10, blue: 0.08), Color(red: 0.48, green: 0.24, blue: 0.12)]
        }
        if key.contains("union") || key.contains("银联") {
            return [Color(red: 0.47, green: 0.10, blue: 0.15), Color(red: 0.74, green: 0.20, blue: 0.25)]
        }
        if key.contains("amex") || key.contains("american") {
            return [Color(red: 0.05, green: 0.33, blue: 0.38), Color(red: 0.07, green: 0.23, blue: 0.36)]
        }
        if key.contains("jcb") {
            return [Color(red: 0.22, green: 0.11, blue: 0.35), Color(red: 0.46, green: 0.17, blue: 0.37)]
        }
        if key.contains("discover") {
            return [Color(red: 0.29, green: 0.18, blue: 0.10), Color(red: 0.62, green: 0.40, blue: 0.18)]
        }
        return [Color(red: 0.16, green: 0.14, blue: 0.24), Color(red: 0.34, green: 0.29, blue: 0.50)]
    }

    private var displayNetworkName: String {
        let trimmed = network.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "CARD" }
        return trimmed.uppercased()
    }

    private var displayIssuer: String {
        let trimmed = issuer.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? title : trimmed
    }

    private var displayCardholder: String {
        let trimmed = cardholderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "未填写持卡人") : trimmed
    }

    private var displayExpiry: String {
        let month = expiryMonth.trimmingCharacters(in: .whitespacesAndNewlines)
        let year = expiryYear.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !month.isEmpty || !year.isEmpty else { return "--/--" }
        let normalizedYear = year.count > 2 ? String(year.suffix(2)) : year
        return "\(month.isEmpty ? "--" : month)/\(normalizedYear.isEmpty ? "--" : normalizedYear)"
    }

    private var displayNumber: String {
        if masksNumber {
            return "•••• •••• •••• ••••"
        }
        let formatted = Self.groupedNumber(number)
        return formatted.isEmpty ? "•••• •••• •••• ••••" : formatted
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: gradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 230, height: 230)
                .offset(x: 150, y: -90)
            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: 26)
                .frame(width: 190, height: 190)
                .offset(x: 170, y: 90)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayIssuer.isEmpty ? String(localized: "银行卡") : displayIssuer)
                            .font(.subheadline.weight(.heavy))
                            .lineLimit(1)
                        Text(String(localized: "银行卡卡面"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.62))
                    }
                    Spacer(minLength: 12)
                    networkBadge
                }

                HStack(spacing: 10) {
                    chip
                    Image(systemName: "wave.3.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.72))
                        .accessibilityHidden(true)
                    Spacer()
                }
                .padding(.top, 18)

                Spacer(minLength: 12)

                Text(displayNumber)
                    .font(.system(size: 19, weight: .semibold, design: .monospaced))
                    .tracking(1.4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityLabel(masksNumber ? String(localized: "卡号已隐藏") : String(localized: "卡号"))

                Spacer(minLength: 10)

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "持卡人"))
                            .font(.system(size: 8, weight: .bold))
                            .tracking(1.1)
                            .foregroundStyle(.white.opacity(0.55))
                        Text(displayCardholder)
                            .font(.caption.weight(.bold))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 16)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(localized: "有效期"))
                            .font(.system(size: 8, weight: .bold))
                            .tracking(1.1)
                            .foregroundStyle(.white.opacity(0.55))
                        Text(displayExpiry)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(20)
        }
        .frame(height: 196)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.22), radius: 18, y: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(String(localized: "银行卡卡面")))
    }

    private var chip: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.93, green: 0.82, blue: 0.58),
                        Color(red: 0.72, green: 0.57, blue: 0.31)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 40, height: 29)
            .overlay {
                VStack(spacing: 4) {
                    Rectangle().fill(Color.black.opacity(0.18)).frame(height: 1)
                    Rectangle().fill(Color.black.opacity(0.18)).frame(height: 1)
                }
                .padding(.horizontal, 8)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.white.opacity(0.28), lineWidth: 0.8)
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var networkBadge: some View {
        if displayNetworkName.contains("MASTER") {
            HStack(spacing: -7) {
                Circle().fill(Color(red: 0.91, green: 0.27, blue: 0.22)).frame(width: 19, height: 19)
                Circle().fill(Color(red: 0.96, green: 0.64, blue: 0.16)).frame(width: 19, height: 19)
            }
            .accessibilityHidden(true)
        } else {
            Text(displayNetworkName)
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .italic()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityHidden(true)
        }
    }

    /// 每四位分组；非纯数字内容原样返回，避免把已格式化的旧数据二次拆散。
    static func groupedNumber(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.filter(\.isNumber)
        guard digits.count >= 4, digits.count == trimmed.filter({ !$0.isWhitespace && $0 != "-" }).count else {
            return trimmed
        }
        var groups: [String] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let end = digits.index(index, offsetBy: 4, limitedBy: digits.endIndex) ?? digits.endIndex
            groups.append(String(digits[index..<end]))
            index = end
        }
        return groups.joined(separator: " ")
    }
}
