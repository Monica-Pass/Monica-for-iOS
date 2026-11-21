import MonicaCore
import SwiftUI

struct GeneratorRootView: View {
    @Bindable var session: AppSessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var length = 128.0
    @State private var includeUppercase = true
    @State private var includeLowercase = true
    @State private var includeDigits = true
    @State private var includeSymbols = true
    @State private var generatedPassword = ""
    @State private var generatorState = String(localized: "就绪")
    @State private var generatorMode: GeneratorMode = .password
    @State private var usernameOptions = GeneratorUsernameOptions()
    @State private var historyController: GeneratorHistoryController?
    @State private var isSaveLoginPresented = false

    var body: some View {
        AndroidParityScreen {
            generatorHeader
            generatorModeControl
            generatedPasswordCard
            generatorControlsCard
            if generatorMode == .username {
                GeneratorUsernameOptionsCard(
                    options: $usernameOptions,
                    username: generatedPassword,
                    uniqueness: usernameUniqueness
                )
            }
            if let historyController {
                GeneratorHistorySettingsSection(controller: historyController) { value in
                    copy(value)
                }
            }
            autoFillGuidanceSection
            GeneratorDependencyStatusSection()
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            ensureHistoryController()
            Task {
                await historyController?.sync(
                    vaultID: session.activeVaultHistoryScope,
                    isVaultUnlocked: session.vaultState == .unlocked
                )
                if generatedPassword.isEmpty {
                    generate()
                }
            }
        }
        .onChange(of: generatorMode) { _, _ in
            normalizeLengthForMode()
            generate()
        }
        .onChange(of: usernameOptions) { _, _ in
            guard generatorMode == .username else {
                return
            }
            generate()
        }
        .onChange(of: session.vaultState) { _, _ in
            Task {
                if session.vaultState == .unlocked {
                    await historyController?.sync(
                        vaultID: session.activeVaultHistoryScope,
                        isVaultUnlocked: true
                    )
                } else {
                    // 锁库：历史内容与密钥立刻从内存消失，界面不再展示旧值。
                    await historyController?.lock()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: GeneratorHistoryController.didClearNotification
        )) { _ in
            Task {
                // 设置页从另一个入口删除了加密历史：先丢弃旧缓存，再按当前 Vault 重新同步。
                await historyController?.lock()
                await historyController?.sync(
                    vaultID: session.activeVaultHistoryScope,
                    isVaultUnlocked: session.vaultState == .unlocked
                )
            }
        }
        .sheet(isPresented: $isSaveLoginPresented) {
            GeneratorSaveLoginSheet(session: session, password: generatedPassword) { entry in
                generatorState = String(localized: "已保存到登录项：\(entry.title)")
            }
        }
    }

    private var generatorHeader: some View {
        HStack(alignment: .center) {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(AndroidParityTypography.controlIcon(weight: .heavy))
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                    .frame(minWidth: AppInterfaceDensity.minimumTouchTarget, minHeight: 56)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回")
            Text("生成器")
                .font(AndroidParityTypography.displayTitle(weight: .heavy))
                .foregroundStyle(AndroidParityPalette.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: generate) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(AndroidParityTypography.controlIcon(weight: .heavy))
                    .foregroundStyle(AndroidParityPalette.primary)
                    .frame(minWidth: 56, minHeight: 56)
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
                    .frame(minWidth: 64, minHeight: 56)
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
                    generatorState = session.copySensitiveValueToPasteboard(generatedPassword).message
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.headline.weight(.heavy))
                }
                .buttonStyle(.plain)
                .disabled(generatedPassword.isEmpty)
            }
            .foregroundStyle(AndroidParityPalette.primary)

            // 生成结果可直接编辑：改完仍按当前内容评分、复制或保存为登录项（#39）。
            TextField(
                String(localized: "点击刷新生成密码"),
                text: $generatedPassword,
                axis: .vertical
            )
            .font(AndroidParityTypography.monospacedValue(weight: .medium))
            .foregroundStyle(AndroidParityPalette.textPrimary)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .lineLimit(2...5)
            .textFieldStyle(.plain)
            .accessibilityLabel("生成的\(generatorMode.resultTitle)")

            if generatorMode != .username {
                Button {
                    isSaveLoginPresented = true
                } label: {
                    Label("保存为登录项", systemImage: "tray.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                .disabled(generatedPassword.isEmpty || session.vaultState != .unlocked)
                Text("可先直接修改上方结果，再保存到保险库。")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("用户名结果不需要保存为登录项；可复制后用于注册或登录。")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("安全程度")
                        .font(.headline.weight(.heavy))
                    if let assessment = strengthAssessment {
                        Text("约 \(Int(assessment.estimatedBits.rounded())) bit（估算）· \(assessment.characterClassCount) 类字符")
                            .font(.subheadline.weight(.heavy))
                        if !findingSummary.isEmpty {
                            Text(findingSummary)
                                .font(.footnote)
                                .foregroundStyle(AndroidParityPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("用户名不做密码强度评分")
                            .font(.subheadline.weight(.heavy))
                    }
                    Label(lengthDetailLabel, systemImage: "info.circle.fill")
                        .font(.subheadline.weight(.heavy))
                }
                Spacer()
                Text(strengthBadgeLabel)
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
                    .font(AndroidParityTypography.prominentTitle(weight: .heavy))
                if generatorMode != .username {
                    Text("\(generatorMode.lengthLabel)：\(Int(length))")
                        .font(.headline.weight(.heavy))
                    Slider(value: $length, in: generatorMode.lengthRange, step: 1)
                        .tint(AndroidParityPalette.primary)
                        .controlSize(.large)
                        .onChange(of: length) { _, _ in generate() }
                }
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
                AndroidParityInfoRow(title: String(localized: "状态"), value: generatorState)
            }
            .padding(28)
            .padding(.trailing, 72)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AndroidParityPalette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            Button(action: generate) {
                Image(systemName: "arrow.clockwise")
                    .font(AndroidParityTypography.controlIcon(weight: .heavy))
                    .foregroundStyle(AndroidParityPalette.primary)
                    .frame(minWidth: 74, minHeight: 74)
                    .background(AndroidParityPalette.primaryContainer, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 2)
        }
        .padding(.top, 8)
    }

    private var autoFillGuidanceSection: some View {
        AndroidParitySection(title: String(localized: "自动填充")) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                Text("保存到保险库后，iOS 会在它识别的用户名 / 密码输入框里提供 Monica 建议。系统未识别的输入框不会显示建议，QuickType 何时出现也由 iOS 决定。")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                NavigationLink {
                    AppAutoFillDefaultManagerGuideView(title: String(localized: "系统自动填充说明"))
                } label: {
                    HStack(spacing: 12) {
                        Label("系统自动填充说明", systemImage: "questionmark.circle")
                            .font(.subheadline.weight(.heavy))
                            .foregroundStyle(AndroidParityPalette.primary)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var usernameUniqueness: UsernameUniquenessReport {
        UsernameUniqueness.compare(
            candidate: generatedPassword,
            against: session.loginEntries.map(\.username)
        )
    }

    private var strengthAssessment: PasswordStrengthAssessment? {
        guard generatorMode != .username, !generatedPassword.isEmpty else {
            return nil
        }
        return PasswordStrengthAnalyzer.assess(generatedPassword, context: strengthContext)
    }

    private var strengthContext: PasswordStrengthContext {
        switch generatorMode {
        case .pin:
            return .pin
        case .passphrase:
            return .passphrase(wordListSize: SecretGenerator.defaultPassphraseWords.count)
        case .apiToken:
            return .apiToken(byteCount: Int(length))
        case .password, .username:
            return .password
        }
    }

    private var strengthBadgeLabel: String {
        if generatorMode == .username {
            return String(localized: "不评分")
        }
        guard let assessment = strengthAssessment else {
            return String(localized: "待生成")
        }
        return GeneratorStrengthCopy.levelLabel(assessment.level)
    }

    private var findingSummary: String {
        guard let assessment = strengthAssessment, !assessment.findings.isEmpty else {
            return ""
        }
        return assessment.findings.prefix(3)
            .map(GeneratorStrengthCopy.findingLabel)
            .joined(separator: " · ")
    }

    private var lengthDetailLabel: String {
        if generatorMode == .username {
            return String(localized: "长度上限：\(usernameOptions.maximumLength)")
        }
        return "\(generatorMode.lengthLabel)：\(Int(length))"
    }

    private func ensureHistoryController() {
        if historyController == nil {
            historyController = GeneratorHistoryController()
        }
    }

    private func copy(_ value: String) {
        guard !value.isEmpty else {
            return
        }
        generatorState = session.copySensitiveValueToPasteboard(value).message
    }

    private func generate() {
        do {
            generatedPassword = try generateValue()
            generatorState = String(localized: "已生成")
            recordGeneratedValue()
        } catch {
            generatorState = GeneratorStrengthCopy.message(for: error)
        }
    }

    private func generateValue() throws -> String {
        switch generatorMode {
        case .username:
            return try UsernameGenerator.generate(policy: usernamePolicy)
        case .password, .pin, .passphrase, .apiToken:
            return try SecretGenerator.generate(policy: generatorPolicy)
        }
    }

    private var usernamePolicy: UsernameGeneratorPolicy {
        let upperBound = usernameOptions.maximumLength
        let lowerBound = min(GeneratorUsernameOptions.lengthBounds.lowerBound, upperBound)
        return UsernameGeneratorPolicy(
            includeNumberSuffix: usernameOptions.includeNumberSuffix,
            digitCount: usernameOptions.digitCount,
            separator: usernameOptions.separator,
            lengthRange: lowerBound...upperBound
        )
    }

    private var generatorPolicy: SecretGeneratorPolicy {
        switch generatorMode {
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
        case .password, .username:
            // 用户名走 `UsernameGenerator`，这个分支不会被使用。
            return .password(
                PasswordGeneratorPolicy(
                    length: Int(length),
                    includeUppercase: includeUppercase,
                    includeLowercase: includeLowercase,
                    includeDigits: includeDigits,
                    includeSymbols: includeSymbols
                )
            )
        }
    }

    private func normalizeLengthForMode() {
        guard generatorMode != .username else {
            return
        }
        let range = generatorMode.lengthRange
        length = min(max(length, range.lowerBound), range.upperBound)
    }

    private func recordGeneratedValue() {
        guard !generatedPassword.isEmpty, let historyController else {
            return
        }
        let kind = generatorMode.secretKind
        let value = generatedPassword
        Task {
            await historyController.record(kind: kind, value: value)
        }
    }
}

private enum GeneratorMode: String, CaseIterable, Identifiable {
    case password
    case pin
    case passphrase
    case apiToken
    case username

    var id: String { rawValue }

    var title: String {
        switch self {
        case .password:
            return String(localized: "符号")
        case .pin:
            return "PIN"
        case .passphrase:
            return String(localized: "短语")
        case .apiToken:
            return "API Token"
        case .username:
            return String(localized: "用户名")
        }
    }

    var resultTitle: String {
        switch self {
        case .password:
            return String(localized: "密码")
        case .pin:
            return "PIN"
        case .passphrase:
            return String(localized: "短语")
        case .apiToken:
            return "Token"
        case .username:
            return String(localized: "用户名")
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
        case .username:
            return "person.crop.circle"
        }
    }

    var lengthLabel: String {
        switch self {
        case .passphrase:
            return String(localized: "词数")
        case .apiToken:
            return String(localized: "字节")
        default:
            return String(localized: "长度")
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
        case .username:
            return 12...32
        }
    }

    var secretKind: GeneratorSecretKind {
        switch self {
        case .password:
            return .password
        case .pin:
            return .pin
        case .passphrase:
            return .passphrase
        case .apiToken:
            return .apiToken
        case .username:
            return .username
        }
    }
}
