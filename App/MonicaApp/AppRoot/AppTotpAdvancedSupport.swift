import Foundation
import SwiftUI
import MonicaCore
import MonicaStorage

// MARK: - 错误

enum TotpAdvancedError: LocalizedError {
    case notHotpEntry
    case counterOverflow
    case invalidIconName

    var errorDescription: String? {
        switch self {
        case .notHotpEntry:
            return String(localized: "只有计数器验证码（HOTP）需要手动生成下一个。")
        case .counterOverflow:
            return String(localized: "计数器已达到上限，无法继续生成新的验证码。")
        case .invalidIconName:
            return String(localized: "请选择有效的验证码图标。")
        }
    }
}

// MARK: - 图标目录

struct TotpIconOption: Identifiable, Hashable, Sendable {
    let id: String
    let systemName: String
    let title: String
}

enum TotpIconCatalog {
    /// 空字符串代表「跟随默认外观」，用于兼容旧条目缺失的 iconName。
    static let defaultIconName = ""
    static let fallbackSystemName = "shield.lefthalf.filled"

    static let options: [TotpIconOption] = [
        TotpIconOption(id: defaultIconName, systemName: fallbackSystemName, title: String(localized: "默认")),
        TotpIconOption(id: "key.fill", systemName: "key.fill", title: String(localized: "钥匙")),
        TotpIconOption(id: "lock.fill", systemName: "lock.fill", title: String(localized: "锁")),
        TotpIconOption(id: "envelope.fill", systemName: "envelope.fill", title: String(localized: "邮件")),
        TotpIconOption(id: "building.2.fill", systemName: "building.2.fill", title: String(localized: "公司")),
        TotpIconOption(id: "person.fill", systemName: "person.fill", title: String(localized: "人物")),
        TotpIconOption(id: "globe", systemName: "globe", title: String(localized: "网站")),
        TotpIconOption(id: "gamecontroller.fill", systemName: "gamecontroller.fill", title: String(localized: "游戏")),
        TotpIconOption(id: "cloud.fill", systemName: "cloud.fill", title: String(localized: "云端")),
        TotpIconOption(id: "creditcard.fill", systemName: "creditcard.fill", title: String(localized: "银行卡"))
    ]

    static func resolved(_ iconName: String) -> TotpIconOption {
        options.first(where: { $0.id == iconName }) ?? options[0]
    }

    static func systemName(for iconName: String) -> String {
        resolved(iconName).systemName
    }
}

// MARK: - 数据流

extension AppSessionModel {
    func otpType(for entry: LocalTotpEntry) -> OtpType {
        OtpType(storageValue: entry.otpType)
    }

    func totpAdvancedSummary(for entry: LocalTotpEntry) -> String {
        let type = otpType(for: entry)
        let algorithm = totpAlgorithm(from: entry.algorithm).rawValue
        switch type {
        case .totp:
            return "\(type.rawValue) · \(algorithm) · \(entry.digits) 位 · \(entry.period)s"
        case .hotp:
            return "\(type.rawValue) · \(algorithm) · \(entry.digits) 位 · #\(entry.counter)"
        }
    }

    /// 统一校验并归一化落库草稿：算法收敛到受支持的取值，TOTP 强制清零计数器，
    /// 并在写库前验证密钥/位数/周期可用，避免存入无法生成验证码的条目。
    func advancedTotpDraft(
        title: String,
        secret: String,
        issuer: String,
        accountName: String,
        period: UInt32,
        digits: UInt32,
        algorithm: String,
        otpType: OtpType,
        counter: UInt64,
        iconName: String
    ) throws -> LocalTotpEntryDraft {
        let resolvedAlgorithm = totpAlgorithm(from: algorithm)
        let resolvedDigits = Int(digits)
        guard (6...8).contains(resolvedDigits) else {
            throw TotpError.invalidDigits
        }
        guard period > 0 else {
            throw TotpError.invalidPeriod
        }

        switch otpType {
        case .totp:
            _ = try TotpGenerator.generate(
                secret: secret,
                algorithm: resolvedAlgorithm,
                digits: resolvedDigits,
                period: Int(period),
                timestamp: 0
            )
        case .hotp:
            _ = try HotpGenerator.generate(
                secret: secret,
                algorithm: resolvedAlgorithm,
                digits: resolvedDigits,
                counter: counter
            )
        }

        return LocalTotpEntryDraft(
            title: title,
            secret: secret,
            issuer: issuer,
            accountName: accountName,
            period: period,
            digits: digits,
            algorithm: resolvedAlgorithm.rawValue,
            otpType: otpType.rawValue,
            counter: otpType == .hotp ? counter : 0,
            iconName: TotpIconCatalog.resolved(iconName).id
        )
    }

    /// 导出标准 otpauth URI；调用方负责把结果交给分享面板，避免二次持久化。
    func otpAuthURI(for entry: LocalTotpEntry) throws -> String {
        try OtpAuthURIExporter.uri(
            secret: entry.secret,
            issuer: entry.issuer,
            accountName: entry.accountName,
            period: Int(entry.period),
            digits: Int(entry.digits),
            algorithm: totpAlgorithm(from: entry.algorithm),
            otpType: otpType(for: entry),
            counter: entry.counter
        )
    }

    /// 复制「当前验证码」：锁库状态直接拒绝，屏幕掩码不影响复制内容。
    ///
    /// 复制成功后同时记住这个条目（#148）：打开「到期自动复制下一个」时，
    /// 只会为最近一次手动复制的条目续写，不会替用户决定复制哪一个。
    @discardableResult
    func copyOtpCode(for entry: LocalTotpEntry, at date: Date = Date()) -> SensitivePasteboardCopyFeedback {
        guard vaultState == .unlocked else {
            return .nothingToCopy
        }
        guard let code = try? totpCode(for: entry, at: date), !code.isEmpty else {
            return .nothingToCopy
        }
        recordUserActivity(at: date)
        let feedback = copySensitiveValueToPasteboard(code)
        if feedback != .nothingToCopy {
            totpAutoCopyController.arm(entryID: entry.id)
        }
        return feedback
    }

    /// HOTP 按用户确认消费：先持久化 counter + 1 并等待写入成功，之后才用新计数器返回验证码。
    /// 写入失败时计数器保持不变，也不向调用方返回任何新验证码。
    @discardableResult
    func consumeHotpCode(for entry: LocalTotpEntry) throws -> String {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            guard otpType(for: entry) == .hotp else {
                throw TotpAdvancedError.notHotpEntry
            }
            guard entry.counter < UInt64.max else {
                throw TotpAdvancedError.counterOverflow
            }

            let draft = try advancedTotpDraft(
                title: entry.title,
                secret: entry.secret,
                issuer: entry.issuer,
                accountName: entry.accountName,
                period: entry.period,
                digits: entry.digits,
                algorithm: entry.algorithm,
                otpType: .hotp,
                counter: entry.counter + 1,
                iconName: entry.iconName
            )
            let updated = try entryRepository.updateTotpEntry(
                projectID: entry.projectID,
                entryID: entry.id,
                draft: draft
            )
            totpEntries = try entryRepository.listTotpEntries(projectID: entry.projectID)
            deletedTotpEntries = try entryRepository.listDeletedTotpEntries(projectID: entry.projectID)
            if editingTotpEntryID == entry.id {
                selectTotpEntryForEditing(updated)
            }

            let code = try totpCode(for: updated)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .totp,
                itemID: updated.id,
                itemTitle: updated.title
            )
            entryOperationState = .succeeded(updated.title)
            return code
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }
}

// MARK: - 编辑器字段

struct TotpAdvancedFieldsView: View {
    @Binding var otpType: String
    @Binding var algorithm: String
    @Binding var digits: UInt32
    @Binding var period: UInt32
    @Binding var counter: UInt64
    @Binding var iconName: String

    private var selectedType: OtpType {
        OtpType(storageValue: otpType)
    }

    private var periodOptions: [UInt32] {
        var options: [UInt32] = [15, 30, 60]
        if !options.contains(period) {
            options.append(period)
        }
        return options.sorted()
    }

    var body: some View {
        VStack(spacing: 18) {
            menuRow(icon: "shield.lefthalf.filled", title: String(localized: "类型")) {
                Picker(String(localized: "类型"), selection: $otpType) {
                    ForEach(OtpType.allCases, id: \.rawValue) { type in
                        Text(type == .totp ? String(localized: "定时验证码（TOTP）") : String(localized: "计数器验证码（HOTP）"))
                            .tag(type.rawValue)
                    }
                }
            }

            menuRow(icon: "number", title: String(localized: "算法")) {
                Picker(String(localized: "算法"), selection: $algorithm) {
                    ForEach(TotpAlgorithm.allCases, id: \.rawValue) { algorithm in
                        Text(algorithm.rawValue).tag(algorithm.rawValue)
                    }
                }
            }

            menuRow(icon: "textformat.123", title: String(localized: "位数")) {
                Picker(String(localized: "位数"), selection: $digits) {
                    ForEach([UInt32(6), 7, 8], id: \.self) { value in
                        Text(String(value)).tag(value)
                    }
                }
            }

            if selectedType == .totp {
                menuRow(icon: "timer", title: String(localized: "周期")) {
                    Picker(String(localized: "周期"), selection: $period) {
                        ForEach(periodOptions, id: \.self) { value in
                            Text(String(localized: "\(Int(value)) 秒")).tag(value)
                        }
                    }
                }
            } else {
                counterRow
            }

            iconSelector
        }
    }

    private var counterRow: some View {
        HStack(spacing: 16) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .frame(minWidth: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "计数器"))
                    .font(.subheadline.weight(.semibold))
                Text("\(counter)")
                    .font(AndroidParityTypography.monospacedValue())
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
            Spacer(minLength: 8)
            Stepper(
                String(localized: "计数器"),
                value: $counter,
                in: UInt64(0)...UInt64(9_999_999)
            )
            .labelsHidden()
            .tint(AndroidParityPalette.primary)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 58)
        .background(AndroidParityPalette.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(AndroidParityPalette.outline, lineWidth: 1.2) }
    }

    private var iconSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .frame(minWidth: 34)
                Text(String(localized: "图标"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(TotpIconCatalog.resolved(iconName).title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(TotpIconCatalog.options) { option in
                        Button {
                            iconName = option.id
                        } label: {
                            Image(systemName: option.systemName)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(
                                    iconName == option.id
                                        ? AndroidParityPalette.primary
                                        : AndroidParityPalette.textSecondary
                                )
                                .frame(width: 46, height: 46)
                                .background(
                                    iconName == option.id
                                        ? AndroidParityPalette.primaryContainer
                                        : AndroidParityPalette.background,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(
                                            iconName == option.id
                                                ? AndroidParityPalette.primary
                                                : AndroidParityPalette.outline,
                                            lineWidth: iconName == option.id ? 1.6 : 1
                                        )
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(option.title))
                        .accessibilityValue(Text(iconName == option.id ? String(localized: "已选择") : ""))
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(18)
        .background(AndroidParityPalette.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(AndroidParityPalette.outline, lineWidth: 1.2) }
    }

    private func menuRow<Content: View>(
        icon: String,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .frame(minWidth: 34)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            content()
                .labelsHidden()
                .tint(AndroidParityPalette.primary)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 58)
        .background(AndroidParityPalette.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(AndroidParityPalette.outline, lineWidth: 1.2) }
    }
}

// MARK: - 详情页验证码操作

struct TotpDetailActionsView: View {
    @Bindable var session: AppSessionModel
    let entryID: String
    let onFeedback: (String) -> Void

    private var entry: LocalTotpEntry? {
        session.totpEntries.first(where: { $0.id == entryID })
    }

    var body: some View {
        if let entry {
            AndroidParitySection(title: String(localized: "验证码")) {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                    TimelineView(.periodic(from: Date(), by: 1)) { context in
                        codeRow(entry: entry, at: context.date)
                    }
                    HStack(spacing: 12) {
                        Button {
                            onFeedback(session.copyOtpCode(for: entry).message)
                        } label: {
                            Label("复制验证码", systemImage: "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AndroidParityButtonStyle(tone: .outlined))

                        if let uri = try? session.otpAuthURI(for: entry) {
                            ShareLink(item: uri) {
                                Label("导出 otpauth URI", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                        }
                    }
                    if session.otpType(for: entry) == .hotp {
                        Button {
                            do {
                                _ = try session.consumeHotpCode(for: entry)
                                onFeedback(String(localized: "已使用当前验证码，并生成下一个"))
                            } catch {
                                onFeedback(error.localizedDescription)
                            }
                        } label: {
                            Label("已使用，生成下一个", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                        Text("计数器验证码只在确认使用后前进一位，不会被每秒刷新自动消耗。")
                            .font(.caption2)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }
                }
            }
        }
    }

    private func codeRow(entry: LocalTotpEntry, at date: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(displayedCode(entry: entry, at: date))
                .font(AndroidParityTypography.prominentTitle(weight: .heavy))
                .foregroundStyle(AndroidParityPalette.textPrimary)
                .textSelection(.enabled)
            Spacer()
            Text(session.totpAdvancedSummary(for: entry))
                .font(.caption2)
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func displayedCode(entry: LocalTotpEntry, at date: Date) -> String {
        guard let code = try? session.totpCode(for: entry, at: date), !code.isEmpty else {
            return "------"
        }
        return session.sensitivePreviewValue(code, category: .totp, entryID: entry.id)
    }
}
