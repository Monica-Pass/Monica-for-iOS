import MonicaCore
import MonicaStorage
import SwiftUI
import UIKit

/// issue #16：登录条目的多 URL、应用绑定与密码历史在编辑器/详情页共用的展示与编辑组件。
///
/// 这里只做 UI 状态与展示，所有持久化规则（去重、历史追加、加密落盘）在 `MonicaStorage` 里，
/// 敏感值的显示仍受 `AppSessionModel` 的敏感预览开关约束。

extension LoginEntryURLRules.Issue {
    /// 编辑器里的内联提示。空行不算错误，由调用方决定是否展示。
    var localizedMessage: String {
        switch self {
        case .empty:
            return String(localized: "网址不能为空")
        case .unsupportedScheme:
            return String(localized: "暂不支持该链接协议，请使用 http 或 https")
        case .missingHost:
            return String(localized: "网址缺少域名")
        case .malformed:
            return String(localized: "网址格式看起来不正确，仍会按原样保存")
        }
    }
}

/// 有序、去重的附加网址编辑器：主网址单独编辑，这里维护其余条目。
struct LoginAdditionalURLEditor: View {
    @Binding var urls: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(urls.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "link")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AndroidParityPalette.primary)
                        TextField(
                            String(localized: "附加网址"),
                            text: binding(for: index)
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.subheadline)
                        Button {
                            move(index, by: -1)
                        } label: {
                            Image(systemName: "chevron.up")
                                .frame(minWidth: 32, minHeight: 32)
                        }
                        .buttonStyle(.plain)
                        .disabled(index == urls.startIndex)
                        .accessibilityLabel(Text("上移网址"))
                        Button {
                            move(index, by: 1)
                        } label: {
                            Image(systemName: "chevron.down")
                                .frame(minWidth: 32, minHeight: 32)
                        }
                        .buttonStyle(.plain)
                        .disabled(index == urls.count - 1)
                        .accessibilityLabel(Text("下移网址"))
                        Button(role: .destructive) {
                            remove(at: index)
                        } label: {
                            Image(systemName: "trash")
                                .frame(minWidth: 32, minHeight: 32)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("删除网址"))
                    }
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        AndroidParityPalette.background,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(AndroidParityPalette.outline, lineWidth: 1)
                    }

                    if let issue = LoginEntryURLRules.issue(for: urls[index]), issue != .empty {
                        Label(issue.localizedMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 4)
                    }
                }
            }

            Button {
                guard urls.count + 1 < LoginEntryURLRules.maximumURLCount else { return }
                urls.append("")
            } label: {
                Label("添加网址", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
            .disabled(urls.count + 1 >= LoginEntryURLRules.maximumURLCount)

            if urls.count + 1 >= LoginEntryURLRules.maximumURLCount {
                Text("已达到网址数量上限")
                    .font(.caption2)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }
    }

    private func binding(for index: Int) -> Binding<String> {
        Binding(
            get: {
                guard urls.indices.contains(index) else { return "" }
                return urls[index]
            },
            set: { newValue in
                guard urls.indices.contains(index) else { return }
                urls[index] = newValue
            }
        )
    }

    private func move(_ index: Int, by offset: Int) {
        guard urls.indices.contains(index),
              urls.indices.contains(index + offset)
        else { return }
        urls.swapAt(index, index + offset)
    }

    private func remove(at index: Int) {
        guard urls.indices.contains(index) else { return }
        urls.remove(at: index)
    }
}

/// 应用绑定：可编辑的应用名与 bundle id，只用于展示和筛选。
struct LoginAppBindingEditor: View {
    @Binding var appName: String
    @Binding var bundleID: String
    @State private var isExpanded = false

    init(appName: Binding<String>, bundleID: Binding<String>) {
        _appName = appName
        _bundleID = bundleID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "app.badge")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AndroidParityPalette.primary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("绑定应用")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AndroidParityPalette.textPrimary)
                        Text(summary)
                            .font(.caption2)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(isExpanded ? "收起应用绑定" : "展开应用绑定"))

            if isExpanded {
                field(String(localized: "应用名称"), text: $appName, keyboard: .default)
                    .textInputAutocapitalization(.words)
                field(String(localized: "Bundle ID"), text: $bundleID, keyboard: .URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("仅用于详情展示与筛选，不会改变系统自动填充的域名限制。")
                    .font(.caption2)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }
    }

    private var summary: String {
        let name = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (name.isEmpty, bundle.isEmpty) {
        case (true, true):
            return String(localized: "未绑定应用")
        case (false, true):
            return name
        case (true, false):
            return bundle
        case (false, false):
            return "\(name) · \(bundle)"
        }
    }

    private func field(_ title: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        TextField(title, text: text)
            .keyboardType(keyboard)
            .font(.subheadline)
            .foregroundStyle(AndroidParityPalette.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                AndroidParityPalette.background,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AndroidParityPalette.outline, lineWidth: 1)
            }
    }
}

/// 详情页的密码历史：默认全部掩码，逐条「显示」后才展开；可删除单条或清空。
struct LoginPasswordHistorySection: View {
    let history: [LocalLoginPasswordHistoryEntry]
    let canReveal: Bool
    let onDelete: (String) -> Void
    let onClear: () -> Void

    @State private var revealedIDs: Set<String> = []
    @State private var isClearConfirmationPresented = false

    init(
        history: [LocalLoginPasswordHistoryEntry],
        canReveal: Bool,
        onDelete: @escaping (String) -> Void,
        onClear: @escaping () -> Void
    ) {
        self.history = history
        self.canReveal = canReveal
        self.onDelete = onDelete
        self.onClear = onClear
    }

    var body: some View {
        AndroidParitySection(title: String(localized: "密码历史")) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                ForEach(history) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(AndroidParityPalette.primary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.changedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AndroidParityPalette.textSecondary)
                                Text(value(for: entry))
                                    .font(.subheadline.monospaced())
                                    .foregroundStyle(AndroidParityPalette.textPrimary)
                                    .textSelection(.disabled)
                            }
                            Spacer()
                            Button {
                                toggle(entry)
                            } label: {
                                Text(isRevealed(entry) ? String(localized: "隐藏") : String(localized: "显示"))
                                    .font(.caption.weight(.bold))
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AndroidParityPalette.primary)
                            .disabled(!canReveal)
                            .accessibilityLabel(
                                Text(isRevealed(entry) ? "隐藏这条旧密码" : "显示这条旧密码")
                            )
                            Button(role: .destructive) {
                                revealedIDs.remove(entry.id)
                                onDelete(entry.id)
                            } label: {
                                Image(systemName: "trash")
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                            .accessibilityLabel(Text("删除这条密码历史"))
                        }
                        if !canReveal {
                            Text("在「设置 › 敏感隐私」中允许显示后可用")
                                .font(.caption2)
                                .foregroundStyle(AndroidParityPalette.textSecondary)
                        }
                    }
                    .padding(.vertical, 2)
                    if entry.id != history.last?.id {
                        AndroidParityDivider()
                    }
                }
            }
            Text("修改密码时才会自动记录旧密码；历史保存在加密 Vault 内，不会写入日志或明文缓存。")
                .font(.caption2)
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .padding(.horizontal, 4)
            Button(role: .destructive) {
                isClearConfirmationPresented = true
            } label: {
                Label("清空密码历史", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .destructiveOutlined))
            .confirmationDialog(
                "清空全部密码历史？",
                isPresented: $isClearConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("清空历史", role: .destructive) {
                    revealedIDs.removeAll()
                    onClear()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("清空后无法恢复，当前密码不受影响。")
            }
        }
        .onChange(of: history.map(\.id)) { _, ids in
            revealedIDs.formIntersection(Set(ids))
        }
    }

    private func isRevealed(_ entry: LocalLoginPasswordHistoryEntry) -> Bool {
        canReveal && revealedIDs.contains(entry.id)
    }

    private func value(for entry: LocalLoginPasswordHistoryEntry) -> String {
        isRevealed(entry) ? entry.password : String(repeating: "•", count: 8)
    }

    private func toggle(_ entry: LocalLoginPasswordHistoryEntry) {
        guard canReveal else { return }
        if revealedIDs.contains(entry.id) {
            revealedIDs.remove(entry.id)
        } else {
            revealedIDs.insert(entry.id)
        }
    }
}
