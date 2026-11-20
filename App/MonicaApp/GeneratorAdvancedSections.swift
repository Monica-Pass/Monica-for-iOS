import MonicaCore
import SwiftUI

/// 用户名生成选项（#24）。
///
/// 长度控制按「结果上限」理解：词典组合本身决定下限，超过上限时重新抽样，
/// 这样既不会把词截断成半截，也不需要用户理解词表长度分布。
struct GeneratorUsernameOptions: Equatable {
    var includeNumberSuffix = true
    var digitCount = 2
    var separator = "."
    var maximumLength = 24

    static let lengthBounds = 12...32
    static let separatorOptions = UsernameGeneratorPolicy.allowedSeparators
}

/// 用户名选项卡片：数字后缀 / 分隔符 / 长度 / 本地唯一性提示。
struct GeneratorUsernameOptionsCard: View {
    @Binding var options: GeneratorUsernameOptions
    let username: String
    let uniqueness: UsernameUniquenessReport

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("用户名生成器")
                .font(AndroidParityTypography.prominentTitle(weight: .heavy))

            Text("长度上限：\(options.maximumLength)")
                .font(.headline.weight(.heavy))
            Slider(
                value: Binding(
                    get: { Double(options.maximumLength) },
                    set: { options.maximumLength = Int($0.rounded()) }
                ),
                in: lengthLimitRange,
                step: 1
            )
            .tint(AndroidParityPalette.primary)
            .controlSize(.large)
            .accessibilityLabel("长度上限")

            Toggle("包含数字后缀", isOn: $options.includeNumberSuffix)
                .font(.subheadline.weight(.semibold))
                .tint(AndroidParityPalette.primary)

            if options.includeNumberSuffix {
                Picker("数字位数", selection: $options.digitCount) {
                    ForEach(2...4, id: \.self) { count in
                        Text("\(count) 位").tag(count)
                    }
                }
                .pickerStyle(.segmented)
            }

            Picker("分隔符", selection: $options.separator) {
                ForEach(GeneratorUsernameOptions.separatorOptions, id: \.self) { separator in
                    Text(Self.separatorLabel(separator)).tag(separator)
                }
            }
            .pickerStyle(.segmented)

            uniquenessHint
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AndroidParityPalette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.top, 8)
    }

    private var lengthLimitRange: ClosedRange<Double> {
        let bounds = GeneratorUsernameOptions.lengthBounds
        return Double(bounds.lowerBound)...Double(bounds.upperBound)
    }

    private var uniquenessHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: uniqueness.isUnique ? "checkmark.seal" : "exclamationmark.triangle")
                    .font(.subheadline.weight(.heavy))
                Text(uniquenessTitle)
                    .font(.subheadline.weight(.heavy))
            }
            .foregroundStyle(uniqueness.isUnique ? AndroidParityPalette.primary : .orange)

            Text(uniquenessDetail)
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var uniquenessTitle: String {
        if uniqueness.comparedCount == 0 {
            return String(localized: "还没有登录条目可供比对")
        }
        return uniqueness.isUnique
            ? String(localized: "与现有登录用户名不冲突")
            : String(localized: "与现有登录用户名重复")
    }

    private var uniquenessDetail: String {
        guard uniqueness.comparedCount > 0 else {
            return String(localized: "只在本机登录条目中比较，不会联网查询。")
        }
        if uniqueness.isUnique {
            return String(
                localized: "已在本机 \(uniqueness.comparedCount) 个登录用户名中比较「\(username)」，未发现重复。"
            )
        }
        return String(
            localized: "本机 \(uniqueness.comparedCount) 个登录用户名中有 \(uniqueness.caseInsensitiveMatchCount) 个与「\(username)」相同（忽略大小写），建议换一个。"
        )
    }

    private static func separatorLabel(_ separator: String) -> String {
        switch separator {
        case "":
            return String(localized: "无")
        case ".":
            return String(localized: "点")
        case "_":
            return String(localized: "下划线")
        case "-":
            return String(localized: "连字符")
        case "+":
            return String(localized: "加号")
        default:
            return separator
        }
    }
}

/// 生成历史设置与列表（#24）。
///
/// 开关与保留期是普通偏好；历史内容只在内存或加密 Vault 中，锁库后不可读。
struct GeneratorHistorySettingsSection: View {
    let controller: GeneratorHistoryController
    let onCopy: (String) -> Void

    @State private var isConfirmingClear = false

    var body: some View {
        AndroidParitySection(title: String(localized: "生成历史")) {
            AndroidParityCard {
                Toggle(
                    isOn: Binding(
                        get: { controller.isEnabled },
                        set: { enabled in
                            Task { await controller.setEnabled(enabled) }
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("保存生成历史")
                            .font(.subheadline.weight(.semibold))
                        Text(
                            controller.isEnabled
                                ? String(localized: "已开启：历史加密存入当前 Vault，锁库后不可读。")
                                : String(localized: "已关闭：只在本次页面内保留，离开页面即清除。")
                        )
                        .font(.footnote)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(AndroidParityPalette.primary)

                if controller.isEnabled {
                    Picker(
                        "保留时间",
                        selection: Binding(
                            get: { controller.retention },
                            set: { retention in
                                Task { await controller.setRetention(retention) }
                            }
                        )
                    ) {
                        ForEach(GeneratorHistoryRetention.allCases) { retention in
                            Text(Self.retentionLabel(retention)).tag(retention)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(AndroidParityPalette.primary)

                    if !controller.isHistoryAccessible {
                        Text("解锁 Vault 后才能查看已保存的历史。")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                if let errorMessage = controller.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !controller.entries.isEmpty {
                    Button("清空历史", role: .destructive) {
                        isConfirmingClear = true
                    }
                    .font(.subheadline.weight(.semibold))
                    .confirmationDialog("清空全部生成历史？", isPresented: $isConfirmingClear, titleVisibility: .visible) {
                        Button("清空历史", role: .destructive) {
                            Task { await controller.clear() }
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("清空后无法恢复。")
                    }
                }
            }

            if controller.entries.isEmpty {
                Text(emptyHint)
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .padding(.horizontal, 4)
            } else {
                ForEach(controller.entries) { entry in
                    AndroidParityEntryCard(
                        icon: entry.kind.systemImage,
                        title: entry.kind.displayTitle,
                        subtitle: entry.value,
                        detail: Self.retentionDetail(entry),
                        fill: AndroidParityPalette.surfaceVariant.opacity(0.55)
                    ) {
                        Button {
                            onCopy(entry.value)
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

    private var emptyHint: String {
        if controller.isEnabled && !controller.isHistoryAccessible {
            return String(localized: "锁库状态下不显示历史内容。")
        }
        return String(localized: "生成一次后，结果会出现在这里。")
    }

    private static func retentionLabel(_ retention: GeneratorHistoryRetention) -> String {
        switch retention {
        case .oneHour:
            return String(localized: "1 小时")
        case .oneDay:
            return String(localized: "1 天")
        case .sevenDays:
            return String(localized: "7 天")
        case .thirtyDays:
            return String(localized: "30 天")
        case .never:
            return String(localized: "不过期")
        }
    }

    private static func retentionDetail(_ entry: GeneratorHistoryEntry) -> String {
        guard let expiresAt = entry.expiresAt else {
            return String(localized: "不过期")
        }
        return String(localized: "到期：\(expiresAt.formatted(date: .abbreviated, time: .shortened))")
    }
}

/// SSH / GPG 入口的诚实状态（#24）：真实生成能力就绪前不提供生成按钮。
struct GeneratorDependencyStatusSection: View {
    var body: some View {
        AndroidParitySection(title: String(localized: "SSH / GPG 密钥")) {
            AndroidParityCard {
                AndroidParityInfoRow(
                    title: String(localized: "SSH 密钥生成"),
                    value: String(localized: "依赖未就绪")
                )
                Text("SSH 私钥生成尚未实现（跟踪 #20），本版本不会生成伪密钥。")
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                AndroidParityDivider()

                AndroidParityInfoRow(
                    title: String(localized: "GPG / OpenPGP"),
                    value: String(localized: "依赖未就绪")
                )
                Text("OpenPGP 生成依赖 #12；依赖合入前只显示状态，不提供入口。")
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 强度文案与错误文案映射（#24）。
enum GeneratorStrengthCopy {
    static func levelLabel(_ level: PasswordStrengthLevel) -> String {
        switch level {
        case .veryWeak:
            return String(localized: "很弱")
        case .weak:
            return String(localized: "弱")
        case .fair:
            return String(localized: "一般")
        case .strong:
            return String(localized: "强")
        case .veryStrong:
            return String(localized: "很强")
        }
    }

    static func findingLabel(_ finding: PasswordStrengthFinding) -> String {
        switch finding {
        case .tooShort:
            return String(localized: "长度偏短")
        case .allDigits:
            return String(localized: "只有数字")
        case .singleCharacterClass:
            return String(localized: "字符类型单一")
        case .commonPassword:
            return String(localized: "常见弱口令")
        case .repeatedCharacters:
            return String(localized: "存在重复字符")
        case .lowCharacterVariety:
            return String(localized: "字符种类偏少")
        case .sequentialCharacters:
            return String(localized: "存在连续序列")
        case .keyboardSequence:
            return String(localized: "存在键盘序列")
        case .yearSuffix:
            return String(localized: "以年份结尾")
        case .fewPassphraseWords:
            return String(localized: "单词数偏少")
        case .tokenTooShort:
            return String(localized: "令牌字节不足")
        }
    }

    static func message(for error: Error) -> String {
        if let usernameError = error as? UsernameGeneratorError {
            switch usernameError {
            case .unsatisfiableLength:
                return String(localized: "长度上限过小，无法容纳词典组合，请调大上限")
            case .invalidLengthRange:
                return String(localized: "长度范围无效")
            case .unsupportedSeparator:
                return String(localized: "分隔符不受支持")
            case .invalidDigitCount:
                return String(localized: "数字位数需在 2 到 4 之间")
            case .emptyWordList, .invalidWord, .wordTooLong:
                return String(localized: "用户名词典不可用")
            case .randomFailure:
                return String(localized: "安全随机数不可用，请重试")
            }
        }
        if error is GeneratorHistoryError {
            return String(localized: "生成历史暂不可用")
        }
        return error.localizedDescription
    }
}

extension GeneratorSecretKind {
    var displayTitle: String {
        switch self {
        case .password:
            return String(localized: "密码")
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
}
