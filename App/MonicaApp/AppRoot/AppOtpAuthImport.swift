import Foundation
import MonicaCore
import MonicaStorage
import SwiftUI
import UIKit

// MARK: - 导入数据

enum AppOtpAuthImportSource: Sendable, Equatable {
    case deepLink
    case paste
    case clipboard
}

enum AppOtpAuthDuplicateResolution: String, CaseIterable, Identifiable, Sendable {
    case skip
    case overwrite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .skip:
            return String(localized: "跳过")
        case .overwrite:
            return String(localized: "覆盖")
        }
    }
}

/// 预览面板中的一条待导入验证器。`duplicateEntry` 表示库里已有同 issuer+account+secret 的条目；
/// `repeatedBatchLineNumber` 表示这一行与本次粘贴的某一行完全重复。
struct AppOtpAuthImportLine: Identifiable, Equatable {
    let id: UUID
    let lineNumber: Int
    let draft: TotpImportDraft
    let duplicateEntry: LocalTotpEntry?
    let repeatedBatchLineNumber: Int?

    var isDuplicate: Bool {
        duplicateEntry != nil || repeatedBatchLineNumber != nil
    }
}

struct AppOtpAuthImportFailure: Identifiable, Equatable {
    let lineNumber: Int
    let message: String

    var id: Int { lineNumber }
}

struct AppOtpAuthImportReview: Identifiable, Equatable {
    let id: UUID
    let source: AppOtpAuthImportSource
    let lines: [AppOtpAuthImportLine]
    let failures: [AppOtpAuthImportFailure]

    var importableCount: Int { lines.count }
    var duplicateCount: Int { lines.filter(\.isDuplicate).count }
}

enum AppOtpAuthImportError: LocalizedError, Equatable {
    case vaultLocked
    case partialImport(String)

    var errorDescription: String? {
        switch self {
        case .vaultLocked:
            return String(localized: "保险库已锁定，请先解锁后再导入验证器。")
        case .partialImport(let detail):
            return String(localized: "部分验证器导入失败：") + " " + detail
        }
    }
}

extension TotpError {
    var otpAuthImportMessage: String {
        switch self {
        case .invalidSecret:
            return String(localized: "密钥不是合法的 Base32。")
        case .invalidDigits:
            return String(localized: "仅支持 6 位或 8 位验证码。")
        case .invalidPeriod:
            return String(localized: "周期必须是大于 0 的整数。")
        case .invalidAlgorithm:
            return String(localized: "仅支持 SHA1、SHA256、SHA512。")
        case .invalidCounter:
            return String(localized: "HOTP 计数器必须是有效的非负整数。")
        case .missingCounter:
            return String(localized: "HOTP 链接必须包含 counter 参数。")
        case .uriTooLong:
            return String(localized: "链接超过 4 KB 上限。")
        case .invalidURI:
            return String(localized: "不是有效的 otpauth:// 链接。")
        }
    }
}

// MARK: - 会话操作

extension AppSessionModel {
    /// 外部 `otpauth://` deep link 的统一入口。锁定时只暂存原文，解锁后再解析并确认。
    func handleOtpAuthDeepLink(_ url: URL) {
        let rawURI = url.absoluteString
        guard vaultState == .unlocked else {
            pendingOtpAuthURIAfterUnlock = rawURI
            // 解锁后先落到「验证」页，再弹出预览面板。
            pendingControlPage = .totp
            return
        }
        otpAuthImportInput = ""
        prepareOtpAuthImport(text: rawURI, source: .deepLink)
        isOtpAuthImportSheetPresented = true
    }

    /// 由视图在 `vaultState` 变为解锁时调用，随后清空暂存的 URI。
    func consumePendingOtpAuthImportIfUnlocked() {
        guard vaultState == .unlocked,
              let rawURI = pendingOtpAuthURIAfterUnlock else {
            return
        }
        pendingOtpAuthURIAfterUnlock = nil
        otpAuthImportInput = ""
        prepareOtpAuthImport(text: rawURI, source: .deepLink)
        isOtpAuthImportSheetPresented = true
    }

    /// 打开「粘贴导入」面板。只清空界面状态，不读取剪贴板。
    func beginOtpAuthPasteImport() {
        guard vaultState == .unlocked else { return }
        otpAuthImportReview = nil
        otpAuthImportInput = ""
        otpAuthImportFeedback = nil
        isOtpAuthImportSheetPresented = true
    }

    /// 从剪贴板一次读取并立即解析。读取失败时给出可读提示，绝不覆盖剪贴板内容。
    func importOtpAuthFromClipboard() {
        guard vaultState == .unlocked else { return }
        recordUserActivity()
        otpAuthImportReview = nil
        otpAuthImportFeedback = nil
        let text = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            otpAuthImportInput = ""
            otpAuthImportFeedback = String(localized: "剪贴板中没有可导入的 otpauth:// 链接。")
            isOtpAuthImportSheetPresented = true
            return
        }
        otpAuthImportInput = text
        prepareOtpAuthImport(text: text, source: .clipboard)
        isOtpAuthImportSheetPresented = true
    }

    /// 用户主动点击「读取剪贴板」时再读一次，用于先打开面板再复制的场景。
    func readOtpAuthClipboardIntoInput() {
        guard vaultState == .unlocked else { return }
        let text = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            otpAuthImportFeedback = String(localized: "剪贴板中没有可导入的 otpauth:// 链接。")
            return
        }
        otpAuthImportInput = text
        otpAuthImportFeedback = String(localized: "已读取剪贴板内容，点击「解析并预览」继续。")
    }

    /// 仅在用户明确点击时清空剪贴板。
    func clearOtpAuthClipboard() {
        UIPasteboard.general.string = ""
        otpAuthImportFeedback = String(localized: "已清空剪贴板。")
    }

    /// 解析文本框中的单条或多条链接并生成预览，不写库。
    func prepareOtpAuthImportFromInput() {
        prepareOtpAuthImport(text: otpAuthImportInput, source: .paste)
    }

    func dismissOtpAuthImportSheet() {
        otpAuthImportReview = nil
        otpAuthImportInput = ""
        otpAuthImportFeedback = nil
        isOtpAuthImportSheetPresented = false
    }

    /// 预览界面点击「返回修改」：保留粘贴文本，只丢弃预览。
    func editOtpAuthImportAgain() {
        otpAuthImportReview = nil
        otpAuthImportFeedback = nil
    }

    /// 确认导入。按行独立写入，单行失败不会中断其余行；全部成功后刷新列表、时间线和自动填充索引。
    func confirmOtpAuthImport(resolutions: [UUID: AppOtpAuthDuplicateResolution]) throws {
        guard vaultState == .unlocked else {
            throw AppOtpAuthImportError.vaultLocked
        }
        guard let review = otpAuthImportReview, !review.lines.isEmpty else {
            return
        }
        guard let entryRepository = activeEntryRepository else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }

        recordUserActivity()
        entryOperationState = .running

        do {
            let project: LocalVaultProject
            if let activeProject {
                project = activeProject
            } else {
                project = try createOrReuseVaultProject(
                    title: activeVaultName ?? String(localized: "个人"),
                    entryRepository: entryRepository
                )
                activeProject = project
            }

            var createdCount = 0
            var overwrittenCount = 0
            var skippedCount = 0
            var failureDetails: [String] = []

            for line in review.lines {
                if line.repeatedBatchLineNumber != nil {
                    skippedCount += 1
                    continue
                }
                do {
                    if let existing = line.duplicateEntry {
                        guard resolutions[line.id] == .overwrite else {
                            skippedCount += 1
                            continue
                        }
                        let updated = try entryRepository.updateTotpEntry(
                            projectID: project.id,
                            entryID: existing.id,
                            draft: try localOtpAuthDraft(for: line.draft, existing: existing)
                        )
                        appendOperationTimelineEvent(
                            action: .updated,
                            itemKind: .totp,
                            itemID: updated.id,
                            itemTitle: updated.title
                        )
                        overwrittenCount += 1
                    } else {
                        let created = try entryRepository.createTotpEntry(
                            projectID: project.id,
                            draft: try localOtpAuthDraft(for: line.draft, existing: nil)
                        )
                        appendOperationTimelineEvent(
                            action: .created,
                            itemKind: .totp,
                            itemID: created.id,
                            itemTitle: created.title
                        )
                        createdCount += 1
                    }
                } catch {
                    failureDetails.append("#\(line.lineNumber) " + error.localizedDescription)
                }
            }

            // 无论部分失败与否，都把已写入的结果同步到列表。
            totpEntries = try entryRepository.listTotpEntries(projectID: project.id)
            deletedTotpEntries = try entryRepository.listDeletedTotpEntries(projectID: project.id)
            try? refreshAutoFillEncryptedIndexIfConfigured()

            let summary = Self.otpAuthImportSummary(
                created: createdCount,
                overwritten: overwrittenCount,
                skipped: skippedCount
            )

            guard failureDetails.isEmpty else {
                entryOperationState = .failed(summary)
                throw AppOtpAuthImportError.partialImport(failureDetails.joined(separator: "；"))
            }

            entryOperationState = .succeeded(summary)
            dismissOtpAuthImportSheet()
        } catch {
            if entryOperationState.isRunning {
                entryOperationState = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    // MARK: Private

    private func prepareOtpAuthImport(text: String, source: AppOtpAuthImportSource) {
        otpAuthImportReview = nil
        otpAuthImportFeedback = nil

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            otpAuthImportFeedback = String(localized: "请粘贴至少一条 otpauth:// 链接。")
            return
        }
        // 上限保护：单条链接 4 KB，批量文本额外限制 256 KB，避免超大剪贴板卡住主线程。
        guard text.utf8.count <= 256 * 1024 else {
            otpAuthImportFeedback = String(localized: "批量导入内容过长，请分批粘贴。")
            return
        }

        let result = OtpAuthBatchParser.parse(text)
        guard !result.entries.isEmpty || !result.failures.isEmpty else {
            otpAuthImportFeedback = String(localized: "没有找到可导入的 otpauth:// 链接。")
            return
        }

        var firstLineByKey: [OtpAuthDuplicateKey: Int] = [:]
        let lines: [AppOtpAuthImportLine] = result.entries.map { entry in
            let key = entry.draft.duplicateKey
            let repeatedLine = firstLineByKey[key]
            if repeatedLine == nil {
                firstLineByKey[key] = entry.lineNumber
            }
            let existing = repeatedLine == nil
                ? totpEntries.first(where: { $0.otpAuthDuplicateKey == key })
                : nil
            return AppOtpAuthImportLine(
                id: UUID(),
                lineNumber: entry.lineNumber,
                draft: entry.draft,
                duplicateEntry: existing,
                repeatedBatchLineNumber: repeatedLine
            )
        }
        let failures = result.failures.map {
            AppOtpAuthImportFailure(lineNumber: $0.lineNumber, message: $0.error.otpAuthImportMessage)
        }
        otpAuthImportReview = AppOtpAuthImportReview(
            id: UUID(),
            source: source,
            lines: lines,
            failures: failures
        )
    }

    private func localOtpAuthDraft(
        for draft: TotpImportDraft,
        existing: LocalTotpEntry?
    ) throws -> LocalTotpEntryDraft {
        guard let period = UInt32(exactly: draft.period) else {
            throw TotpError.invalidPeriod
        }
        guard let digits = UInt32(exactly: draft.digits) else {
            throw TotpError.invalidDigits
        }
        return try advancedTotpDraft(
            title: existing?.title ?? draft.title,
            secret: draft.secret,
            issuer: draft.issuer,
            accountName: draft.accountName,
            period: period,
            digits: digits,
            algorithm: draft.algorithm.rawValue,
            otpType: draft.otpType,
            counter: draft.counter,
            iconName: existing?.iconName ?? ""
        )
    }

    private static func otpAuthImportSummary(created: Int, overwritten: Int, skipped: Int) -> String {
        var parts: [String] = []
        if created > 0 {
            parts.append(String(localized: "新增") + " \(created)")
        }
        if overwritten > 0 {
            parts.append(String(localized: "覆盖") + " \(overwritten)")
        }
        if skipped > 0 {
            parts.append(String(localized: "跳过") + " \(skipped)")
        }
        if parts.isEmpty {
            return String(localized: "没有导入任何验证器")
        }
        return parts.joined(separator: "，")
    }
}

extension LocalTotpEntry {
    var otpAuthDuplicateKey: OtpAuthDuplicateKey {
        OtpAuthDuplicateKey(issuer: issuer, accountName: accountName, secret: secret)
    }
}

// MARK: - 预览与粘贴面板

struct AppOtpAuthImportSheet: View {
    @Bindable var session: AppSessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var resolutions: [UUID: AppOtpAuthDuplicateResolution] = [:]
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let review = session.otpAuthImportReview {
                    reviewView(review)
                } else {
                    pasteView
                }
            }
            .background(AndroidParityPalette.background.ignoresSafeArea())
            .navigationTitle(String(localized: "导入验证器"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) {
                        session.dismissOtpAuthImportSheet()
                        dismiss()
                    }
                }
            }
        }
        .onAppear(perform: syncResolutions)
        .onChange(of: session.otpAuthImportReview?.id) { _, _ in
            syncResolutions()
        }
        .alert(
            String(localized: "导入失败"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(String(localized: "好"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: 粘贴

    private var pasteView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(String(localized: "粘贴 otpauth:// 链接，每行一条。导入前会先预览，确认后才会写入验证器列表。"))
                    .font(.subheadline)
                    .foregroundStyle(AndroidParityPalette.textSecondary)

                TextEditor(text: $session.otpAuthImportInput)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 220)
                    .padding(10)
                    .background(
                        AndroidParityPalette.surfaceVariant,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .overlay(alignment: .topLeading) {
                        if session.otpAuthImportInput.isEmpty {
                            Text(String(localized: "otpauth://totp/示例:alice?secret=..."))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(AndroidParityPalette.textSecondary.opacity(0.7))
                                .padding(.horizontal, 15)
                                .padding(.vertical, 18)
                                .allowsHitTesting(false)
                        }
                    }

                HStack(spacing: 10) {
                    Button(String(localized: "读取剪贴板")) {
                        session.readOtpAuthClipboardIntoInput()
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))

                    Button(String(localized: "清空剪贴板")) {
                        session.clearOtpAuthClipboard()
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                }

                if let feedback = session.otpAuthImportFeedback {
                    Text(feedback)
                        .font(.footnote)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }

                Button(String(localized: "解析并预览")) {
                    session.prepareOtpAuthImportFromInput()
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                .disabled(
                    session.otpAuthImportInput
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                )
            }
            .padding(20)
        }
    }

    // MARK: 预览

    private func reviewView(_ review: AppOtpAuthImportReview) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                summaryCard(review)

                if !review.lines.isEmpty {
                    AndroidParityCard(
                        fill: AndroidParityPalette.surfaceVariant.opacity(0.52),
                        cornerRadius: 20
                    ) {
                        Text(String(localized: "待导入"))
                            .font(.headline)
                        ForEach(review.lines) { line in
                            lineRow(line)
                            if line.id != review.lines.last?.id {
                                Divider()
                            }
                        }
                    }
                }

                if !review.failures.isEmpty {
                    failureCard(review.failures)
                }

                Text(String(localized: "导入的密钥只保存在本机加密保险库中，不会上传或写入日志。"))
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)

                Button(String(localized: "返回修改")) {
                    session.editOtpAuthImportAgain()
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))

                if !review.lines.isEmpty {
                    Button(String(localized: "确认导入")) {
                        do {
                            try session.confirmOtpAuthImport(resolutions: resolutions)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                    .disabled(session.entryOperationState.isRunning)
                }
            }
            .padding(20)
        }
    }

    private func summaryCard(_ review: AppOtpAuthImportReview) -> some View {
        AndroidParityCard(fill: AndroidParityPalette.primaryContainer, cornerRadius: 20) {
            HStack(spacing: 12) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.primary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "可导入链接：") + " \(review.importableCount)")
                        .font(.headline)
                    if review.duplicateCount > 0 {
                        Text(String(localized: "其中重复：") + " \(review.duplicateCount)")
                            .font(.footnote)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }
                    if !review.failures.isEmpty {
                        Text(String(localized: "无法导入：") + " \(review.failures.count)")
                            .font(.footnote)
                            .foregroundStyle(AndroidParityPalette.danger)
                    }
                }
            }
        }
    }

    private func lineRow(_ line: AppOtpAuthImportLine) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AndroidParityIconTile(
                systemImage: line.draft.otpType == .hotp ? "number.circle" : "timer"
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(line.draft.title.isEmpty ? line.draft.accountName : line.draft.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if !line.draft.accountName.isEmpty, line.draft.accountName != line.draft.title {
                    Text(line.draft.accountName)
                        .font(.caption)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                        .lineLimit(1)
                }
                Text(technicalDetail(line.draft))
                    .font(.caption2.monospaced())
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                if let reason = duplicateReason(line) {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(AndroidParityPalette.danger)
                }
            }
            Spacer(minLength: 4)
            if line.duplicateEntry != nil {
                Picker(
                    String(localized: "重复处理"),
                    selection: resolutionBinding(for: line.id)
                ) {
                    ForEach(AppOtpAuthDuplicateResolution.allCases) { resolution in
                        Text(resolution.title).tag(resolution)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            } else if line.repeatedBatchLineNumber != nil {
                Text(String(localized: "跳过"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func failureCard(_ failures: [AppOtpAuthImportFailure]) -> some View {
        AndroidParityCard(fill: AndroidParityPalette.surface, cornerRadius: 20) {
            Text(String(localized: "无法导入的链接"))
                .font(.headline)
            ForEach(failures) { failure in
                HStack(alignment: .top, spacing: 8) {
                    Text(verbatim: "#\(failure.lineNumber)")
                        .font(.caption.monospaced())
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                    Text(failure.message)
                        .font(.caption)
                        .foregroundStyle(AndroidParityPalette.danger)
                }
            }
        }
    }

    private func technicalDetail(_ draft: TotpImportDraft) -> String {
        var parts = [
            draft.otpType.rawValue,
            draft.algorithm.rawValue,
            String(format: String(localized: "%d 位"), draft.digits)
        ]
        if draft.otpType == .hotp {
            parts.append("#\(draft.counter)")
        } else {
            parts.append(String(format: String(localized: "%d 秒"), draft.period))
        }
        return parts.joined(separator: " · ")
    }

    private func duplicateReason(_ line: AppOtpAuthImportLine) -> String? {
        if let existing = line.duplicateEntry {
            return String(localized: "已存在相同验证器：") + " " + existing.title
        }
        if let repeated = line.repeatedBatchLineNumber {
            return String(localized: "与本批第") + " \(repeated) " + String(localized: "行重复，将跳过")
        }
        return nil
    }

    private func resolutionBinding(for id: UUID) -> Binding<AppOtpAuthDuplicateResolution> {
        Binding(
            get: { resolutions[id] ?? .skip },
            set: { resolutions[id] = $0 }
        )
    }

    private func syncResolutions() {
        guard let review = session.otpAuthImportReview else { return }
        var next: [UUID: AppOtpAuthDuplicateResolution] = [:]
        for line in review.lines where line.duplicateEntry != nil {
            next[line.id] = resolutions[line.id] ?? .skip
        }
        resolutions = next
    }
}
