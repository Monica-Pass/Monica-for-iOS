import MonicaStorage
import UIKit
import SwiftUI

/// 把生成器结果保存成登录项（#39）。
///
/// 生成结果先进入可编辑字段，再由用户确认标题、用户名与网址；
/// 保存走 `AppSessionModel.saveGeneratedLogin`，与普通新建登录共用仓储与自动填充索引刷新。
struct GeneratorSaveLoginSheet: View {
    @Bindable var session: AppSessionModel
    @Environment(\.dismiss) private var dismiss
    let onSaved: (LocalLoginEntry) -> Void

    @State private var title = ""
    @State private var username = ""
    @State private var url = ""
    @State private var password: String
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(
        session: AppSessionModel,
        password: String,
        onSaved: @escaping (LocalLoginEntry) -> Void
    ) {
        self.session = session
        self.onSaved = onSaved
        _password = State(initialValue: password)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        session.vaultState == .unlocked
            && !trimmedTitle.isEmpty
            && !password.isEmpty
            && !isSaving
    }

    var body: some View {
        NavigationStack {
            AndroidParityScreen {
                AndroidParitySection(title: String(localized: "登录项信息")) {
                    AndroidParityCard {
                        field(
                            title: String(localized: "标题"),
                            prompt: String(localized: "例如：GitHub"),
                            text: $title
                        )
                        field(
                            title: String(localized: "用户名"),
                            prompt: String(localized: "可选"),
                            text: $username,
                            keyboardType: .emailAddress
                        )
                        field(
                            title: String(localized: "网址"),
                            prompt: String(localized: "可选，例如：https://github.com"),
                            text: $url,
                            keyboardType: .URL
                        )
                        VStack(alignment: .leading, spacing: 6) {
                            Text("密码")
                                .font(.caption.weight(.heavy))
                                .foregroundStyle(AndroidParityPalette.textSecondary)
                            TextField("密码", text: $password, axis: .vertical)
                                .font(.system(.body, design: .monospaced))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .lineLimit(2...5)
                                .textFieldStyle(AndroidParityTextFieldStyle())
                        }
                        Text("保存后可在保险库的登录项里复制密码，或由系统自动填充在它识别的登录框里使用。")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                AndroidParitySection(title: String(localized: "保存位置")) {
                    AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                        AndroidParityInfoRow(
                            title: String(localized: "保险库"),
                            value: session.activeVaultName ?? String(localized: "未打开")
                        )
                        AndroidParityInfoRow(
                            title: String(localized: "项目"),
                            value: session.activeProject?.title ?? session.activeVaultName ?? String(localized: "个人")
                        )
                        Text("密码只会写入本机加密保险库，不经过网络；自动填充扩展是否可用仍由系统设置决定。")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if session.vaultState != .unlocked {
                    Text("保险库已锁定，请先返回解锁后再保存。")
                        .font(.footnote.weight(.heavy))
                        .foregroundStyle(.orange)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .navigationTitle("保存为登录项")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    @ViewBuilder
    private func field(
        title: String,
        prompt: String,
        text: Binding<String>,
        keyboardType: UIKeyboardType = .default
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.heavy))
                .foregroundStyle(AndroidParityPalette.textSecondary)
            TextField(prompt, text: text)
                .keyboardType(keyboardType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(AndroidParityTextFieldStyle())
        }
    }

    private func save() {
        guard canSave else {
            return
        }
        isSaving = true
        errorMessage = nil
        do {
            let entry = try session.saveGeneratedLogin(
                title: trimmedTitle,
                username: username,
                password: password,
                url: url.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            onSaved(entry)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}
