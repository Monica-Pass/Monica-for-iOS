import MonicaCore
import SwiftUI
import UIKit

struct GeneratorRootView: View {
    @State private var length = 128.0
    @State private var includeUppercase = true
    @State private var includeLowercase = true
    @State private var includeDigits = true
    @State private var includeSymbols = true
    @State private var generatedPassword = ""
    @State private var generatorState = "就绪"
    @State private var generatorMode: GeneratorMode = .password
    @State private var history: [GeneratedSecretHistoryItem] = []

    var body: some View {
        AndroidParityScreen {
            generatorHeader
            generatorModeControl
            generatedPasswordCard
            generatorControlsCard
            generatorHistorySection
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if generatedPassword.isEmpty {
                generate()
            }
        }
        .onChange(of: generatorMode) { _, _ in
            normalizeLengthForMode()
            generate()
        }
    }

    private var generatorHeader: some View {
        HStack(alignment: .center) {
            Text("生成器")
                .font(.system(size: AndroidParityTypography.generatorTitleSize, weight: .heavy, design: .rounded))
                .foregroundStyle(AndroidParityPalette.textPrimary)
                .minimumScaleFactor(0.8)
            Spacer()
            Button(action: generate) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: AndroidParityTypography.controlIconSize, weight: .heavy))
                    .foregroundStyle(AndroidParityPalette.primary)
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("重新生成")
        }
        .padding(.horizontal, 4)
        .padding(.top, 18)
    }

    private var generatorModeControl: some View {
        HStack(spacing: 2) {
            Button {
                generate()
            } label: {
                Label(generatorMode.title, systemImage: generatorMode.systemImage)
                    .font(.headline.weight(.semibold))
                    .frame(minWidth: 128, minHeight: 56)
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                    .background(AndroidParityPalette.primaryContainer, in: UnevenRoundedRectangle(topLeadingRadius: 28, bottomLeadingRadius: 28))
            }
            Menu {
                ForEach(GeneratorMode.allCases) { mode in
                    Button {
                        generatorMode = mode
                    } label: {
                        Label(mode.title, systemImage: mode.systemImage)
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.headline.weight(.semibold))
                    .frame(width: 64, height: 56)
                    .foregroundStyle(AndroidParityPalette.primary)
                    .background(AndroidParityPalette.primaryContainer, in: UnevenRoundedRectangle(bottomTrailingRadius: 28, topTrailingRadius: 28))
            }
        }
        .padding(.top, 20)
    }

    private var generatedPasswordCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: generatorMode.systemImage)
                    .font(.headline.weight(.heavy))
                Text("生成的\(generatorMode.resultTitle)")
                    .font(.headline.weight(.heavy))
                Spacer()
                Button {
                    UIPasteboard.general.string = generatedPassword
                    generatorState = "已复制"
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.headline.weight(.heavy))
                }
                .buttonStyle(.plain)
                .disabled(generatedPassword.isEmpty)
            }
            .foregroundStyle(AndroidParityPalette.primary)

            Text(generatedPassword.isEmpty ? "点击刷新生成密码" : generatedPassword)
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .foregroundStyle(AndroidParityPalette.textPrimary)
                .textSelection(.enabled)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("安全程度")
                        .font(.headline.weight(.heavy))
                    Label("\(generatorMode.lengthLabel)：\(Int(length))", systemImage: "info.circle.fill")
                        .font(.subheadline.weight(.heavy))
                }
                Spacer()
                Text(passwordStrengthLabel)
                    .font(.headline.weight(.heavy))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(AndroidParityPalette.primary.opacity(0.16), in: Capsule())
            }
            .foregroundStyle(AndroidParityPalette.primary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AndroidParityPalette.primaryContainer, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.top, 18)
    }

    private var generatorControlsCard: some View {
        ZStack(alignment: .trailing) {
            VStack(alignment: .leading, spacing: 26) {
                Text("\(generatorMode.title)生成器")
                    .font(.system(size: AndroidParityTypography.editorTitleSize, weight: .heavy, design: .rounded))
                Text("\(generatorMode.lengthLabel)：\(Int(length))")
                    .font(.headline.weight(.heavy))
                Slider(value: $length, in: generatorMode.lengthRange, step: 1)
                    .tint(AndroidParityPalette.primary)
                    .controlSize(.large)
                    .onChange(of: length) { _, _ in generate() }
                if generatorMode == .password {
                    Text("字符类型")
                        .font(.headline.weight(.heavy))
                    Toggle("包含大写字母 (A-Z)", isOn: $includeUppercase)
                        .font(.subheadline.weight(.semibold))
                        .tint(AndroidParityPalette.primary)
                        .onChange(of: includeUppercase) { _, _ in generate() }
                    Toggle("包含小写字母 (a-z)", isOn: $includeLowercase)
                        .font(.subheadline.weight(.semibold))
                        .tint(AndroidParityPalette.primary)
                        .onChange(of: includeLowercase) { _, _ in generate() }
                    Toggle("包含数字 (0-9)", isOn: $includeDigits)
                        .font(.subheadline.weight(.semibold))
                        .tint(AndroidParityPalette.primary)
                        .onChange(of: includeDigits) { _, _ in generate() }
                    Toggle("包含符号 (!@#)", isOn: $includeSymbols)
                        .font(.subheadline.weight(.semibold))
                        .tint(AndroidParityPalette.primary)
                        .onChange(of: includeSymbols) { _, _ in generate() }
                }
                AndroidParityInfoRow(title: "状态", value: generatorState)
            }
            .padding(28)
            .padding(.trailing, 72)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AndroidParityPalette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            Button(action: generate) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: AndroidParityTypography.controlIconSize, weight: .heavy))
                    .foregroundStyle(AndroidParityPalette.primary)
                    .frame(width: 74, height: 74)
                    .background(AndroidParityPalette.primaryContainer, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 2)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var generatorHistorySection: some View {
        if !history.isEmpty {
            AndroidParitySection(title: "历史") {
                ForEach(history) { item in
                    AndroidParityEntryCard(
                        icon: item.mode.systemImage,
                        title: item.mode.title,
                        subtitle: item.value,
                        fill: AndroidParityPalette.surfaceVariant.opacity(0.55)
                    ) {
                        Button {
                            UIPasteboard.general.string = item.value
                            generatorState = "已复制"
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.headline)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("复制")
                    }
                }
            }
        }
    }

    private var passwordStrengthLabel: String {
        switch generatorMode {
        case .pin:
            return "数字"
        case .passphrase:
            return "可读"
        case .apiToken:
            return "令牌"
        case .password:
            break
        }
        if length >= 64 && includeSymbols && includeDigits {
            return "非常强"
        }
        if length >= 24 {
            return "强"
        }
        return "普通"
    }

    private func generate() {
        do {
            generatedPassword = try SecretGenerator.generate(policy: generatorPolicy)
            rememberGeneratedValue()
            generatorState = "已生成"
        } catch {
            generatorState = error.localizedDescription
        }
    }

    private var generatorPolicy: SecretGeneratorPolicy {
        switch generatorMode {
        case .password:
            return .password(
                PasswordGeneratorPolicy(
                    length: Int(length),
                    includeUppercase: includeUppercase,
                    includeLowercase: includeLowercase,
                    includeDigits: includeDigits,
                    includeSymbols: includeSymbols
                )
            )
        case .pin:
            return .pin(length: Int(length))
        case .passphrase:
            return .passphrase(
                wordCount: Int(length),
                separator: "-",
                wordList: SecretGenerator.defaultPassphraseWords
            )
        case .apiToken:
            return .apiToken(prefix: "monica", byteCount: Int(length))
        }
    }

    private func normalizeLengthForMode() {
        let range = generatorMode.lengthRange
        length = min(max(length, range.lowerBound), range.upperBound)
    }

    private func rememberGeneratedValue() {
        guard !generatedPassword.isEmpty else {
            return
        }
        history.removeAll { $0.value == generatedPassword }
        history.insert(
            GeneratedSecretHistoryItem(mode: generatorMode, value: generatedPassword),
            at: 0
        )
        if history.count > 6 {
            history.removeLast(history.count - 6)
        }
    }
}

private enum GeneratorMode: String, CaseIterable, Identifiable {
    case password
    case pin
    case passphrase
    case apiToken

    var id: String { rawValue }

    var title: String {
        switch self {
        case .password:
            return "符号"
        case .pin:
            return "PIN"
        case .passphrase:
            return "短语"
        case .apiToken:
            return "API Token"
        }
    }

    var resultTitle: String {
        switch self {
        case .password:
            return "密码"
        case .pin:
            return "PIN"
        case .passphrase:
            return "短语"
        case .apiToken:
            return "Token"
        }
    }

    var systemImage: String {
        switch self {
        case .password:
            return "key.fill"
        case .pin:
            return "number"
        case .passphrase:
            return "text.quote"
        case .apiToken:
            return "curlybraces"
        }
    }

    var lengthLabel: String {
        switch self {
        case .passphrase:
            return "词数"
        case .apiToken:
            return "字节"
        default:
            return "长度"
        }
    }

    var lengthRange: ClosedRange<Double> {
        switch self {
        case .password:
            return 8...128
        case .pin:
            return 4...32
        case .passphrase:
            return 3...8
        case .apiToken:
            return 16...64
        }
    }
}

private struct GeneratedSecretHistoryItem: Identifiable, Equatable {
    let id = UUID()
    let mode: GeneratorMode
    let value: String
}
