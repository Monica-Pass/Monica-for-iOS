//
//  AppDataClearView.swift
//  Monica
//
//  设置 →「按数据类型清空」（issue #145）。
//
//  交互流程：多选类型（显示每类条目数量）→ 二次确认（明确回收站 / 不可撤销）
//  → 输入主密码 → 校验通过后调用真实删除 API；密码错误则中止并提示，零删除。
//

import MonicaStorage
import SwiftUI

struct AppDataClearView: View {
    let session: AppSessionModel
    var refreshAutoFillIndex: () -> Void = {}

    @State private var snapshot: AppDataClearSnapshot?
    @State private var selected: Set<AppDataClearCategory> = []
    @State private var isLoading = false
    @State private var loadErrorMessage: String?
    @State private var isConfirmationPresented = false
    @State private var outcome: AppDataClearOutcome?
    @State private var clearErrorMessage: String?

    private var isUnlocked: Bool {
        session.vaultState == .unlocked
    }

    private var selectableCategories: [AppDataClearCategory] {
        AppDataClearCategory.allCases.filter { category in
            (snapshot?.count(for: category) ?? 0) > 0
        }
    }

    var body: some View {
        AndroidParityScreen {
            if isUnlocked {
                introSection
                categorySection
                actionSection
                if let outcome {
                    outcomeSection(outcome)
                }
                if let clearErrorMessage {
                    failureSection(clearErrorMessage)
                }
            } else {
                lockedSection
            }
        }
        .navigationTitle(String(localized: "按数据类型清空"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadSnapshot()
        }
        .sheet(isPresented: $isConfirmationPresented) {
            AppDataClearConfirmationSheet(
                categories: AppDataClearCategory.allCases.filter { selected.contains($0) },
                snapshot: snapshot,
                session: session
            ) { result in
                outcome = result
                clearErrorMessage = nil
                selected.removeAll()
                refreshAutoFillIndex()
                Task { await loadSnapshot() }
            }
        }
    }

    // MARK: - 说明

    private var introSection: some View {
        AndroidParitySection(title: String(localized: "按数据类型清空")) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                Text("勾选要清空的数据类型，确认主密码后执行。条目会进入回收站，可在回收站恢复；标签与生成历史会被立即删除，不可撤销。只影响当前保险库，不会删除主密码、设置或其他保险库。")
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                AndroidParityDivider()
                AndroidParityInfoRow(
                    title: String(localized: "可清空条目"),
                    value: snapshot.map { String($0.totalItemCount) } ?? "—"
                )
            }
        }
    }

    private var lockedSection: some View {
        AndroidParitySection(title: String(localized: "按数据类型清空")) {
            AndroidParityCard {
                Text("解锁保险库后即可按数据类型清空。")
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }
    }

    // MARK: - 类型列表

    private var categorySection: some View {
        AndroidParitySection(title: String(localized: "数据类型")) {
            AndroidParityCard {
                if isLoading && snapshot == nil {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 12)
                } else if let snapshot, snapshot.isEmpty {
                    Text("没有可清空的数据。")
                        .font(.footnote)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                } else {
                    ForEach(AppDataClearCategory.allCases) { category in
                        categoryRow(category, count: snapshot?.count(for: category) ?? 0)
                        if category != AppDataClearCategory.allCases.last {
                            AndroidParityDivider()
                        }
                    }
                }

                if let loadErrorMessage {
                    AndroidParityDivider()
                    Text(verbatim: loadErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func categoryRow(_ category: AppDataClearCategory, count: Int) -> some View {
        let isSelected = selected.contains(category)
        let isEnabled = count > 0
        return Button {
            guard isEnabled else { return }
            if isSelected {
                selected.remove(category)
            } else {
                selected.insert(category)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: category.systemImage)
                    .font(AndroidParityTypography.controlIcon())
                    .foregroundStyle(
                        isSelected
                            ? AndroidParityPalette.primary
                            : AndroidParityPalette.textSecondary
                    )
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title)
                        .font(.body)
                        .foregroundStyle(AndroidParityPalette.textPrimary)
                    if let detail = category.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }
                }

                Spacer(minLength: 8)

                Text(verbatim: String(count))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(AndroidParityTypography.controlIcon())
                    .foregroundStyle(
                        isSelected
                            ? AndroidParityPalette.primary
                            : AndroidParityPalette.outline
                    )
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }

    // MARK: - 执行

    private var actionSection: some View {
        AndroidParitySection(title: String(localized: "执行")) {
            AndroidParityCard {
                Text("已选择 \(selected.count) 类")
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)

                HStack(spacing: 12) {
                    Button {
                        selected = Set(selectableCategories)
                    } label: {
                        Text("全选")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                    .disabled(isLoading || selectableCategories.isEmpty)

                    Button {
                        selected.removeAll()
                    } label: {
                        Text("取消全选")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                    .disabled(selected.isEmpty || isLoading)
                }

                Button {
                    clearErrorMessage = nil
                    isConfirmationPresented = true
                } label: {
                    Text("清空所选类型")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .destructiveOutlined))
                .disabled(selected.isEmpty || isLoading || !isUnlocked)
            }
        }
    }

    // MARK: - 结果 / 失败

    private func outcomeSection(_ outcome: AppDataClearOutcome) -> some View {
        AndroidParitySection(title: String(localized: "上次结果")) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                Text("已清空所选数据")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                AndroidParityInfoRow(
                    title: String(localized: "条目"),
                    value: String(outcome.totalEntryCount)
                )
                if outcome.removedTagCount > 0 {
                    AndroidParityInfoRow(
                        title: String(localized: "标签"),
                        value: String(outcome.removedTagCount)
                    )
                }
                if outcome.generatorHistoryCleared {
                    AndroidParityInfoRow(
                        title: String(localized: "生成历史"),
                        value: String(localized: "已删除")
                    )
                }
                AndroidParityDivider()
                Text("条目已进入回收站，可在回收站恢复；标签与生成历史已永久删除。")
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func failureSection(_ message: String) -> some View {
        AndroidParitySection(title: String(localized: "清空失败")) {
            AndroidParityCard {
                Text(verbatim: message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 数据

    private func loadSnapshot() async {
        guard isUnlocked else {
            snapshot = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            snapshot = try await session.dataClearSnapshot()
            loadErrorMessage = nil
            selected = selected.filter { category in
                (snapshot?.count(for: category) ?? 0) > 0
            }
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }
}

/// 二次确认 + 主密码校验。密码错误时只提示，不触发任何删除。
private struct AppDataClearConfirmationSheet: View {
    let categories: [AppDataClearCategory]
    let snapshot: AppDataClearSnapshot?
    let session: AppSessionModel
    let onCompleted: (AppDataClearOutcome) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var masterPassword = ""
    @State private var isClearing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    warningCard
                    summaryCard
                    passwordCard
                    if let errorMessage {
                        errorCard(errorMessage)
                    }
                }
                .padding(16)
            }
            .background(AndroidParityPalette.background.ignoresSafeArea())
            .navigationTitle(String(localized: "确认清空所选类型？"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                    .disabled(isClearing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await performClear() }
                    } label: {
                        if isClearing {
                            ProgressView()
                        } else {
                            Text("确认清空")
                        }
                    }
                    .disabled(masterPassword.isEmpty || isClearing)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var warningCard: some View {
        AndroidParityCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("此操作会把所选类型的全部条目移入回收站，可在回收站恢复；标签与生成历史会被立即删除，不可撤销。")
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var summaryCard: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
            ForEach(categories) { category in
                AndroidParityInfoRow(
                    title: category.title,
                    value: String(snapshot?.count(for: category) ?? 0)
                )
            }
        }
    }

    private var passwordCard: some View {
        AndroidParityCard {
            Text("主密码")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
            SecureField("请输入主密码", text: $masterPassword)
                .textContentType(.password)
                .textFieldStyle(AndroidParityTextFieldStyle())
                .disabled(isClearing)
            Text("仅影响当前保险库，不会删除主密码、设置或其他保险库。")
                .font(.caption)
                .foregroundStyle(AndroidParityPalette.textSecondary)
        }
    }

    private func errorCard(_ message: String) -> some View {
        AndroidParityCard {
            Text(verbatim: message)
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func performClear() async {
        guard !masterPassword.isEmpty, !isClearing else { return }
        isClearing = true
        errorMessage = nil
        defer { isClearing = false }

        do {
            let result = try await session.performDataClear(
                categories: Set(categories),
                masterPassword: masterPassword
            )
            masterPassword = ""
            onCompleted(result)
            dismiss()
        } catch {
            errorMessage = message(for: error)
        }
    }

    private func message(for error: Error) -> String {
        guard let repositoryError = error as? LocalVaultRepositoryError else {
            return error.localizedDescription
        }
        switch repositoryError {
        case .currentPasswordMismatch:
            return String(localized: "主密码错误，未清空任何数据。")
        case .vaultUnavailable:
            return String(localized: "保险库未解锁，未清空任何数据。")
        default:
            return String(localized: "清空失败，请稍后重试。")
        }
    }
}
