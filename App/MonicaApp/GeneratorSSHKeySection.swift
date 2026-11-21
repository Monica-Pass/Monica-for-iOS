import MonicaCore
import MonicaStorage
import SwiftUI
import UIKit

/// #154：生成器里的 SSH 密钥区块（Ed25519 / RSA 2048-4096）。
///
/// 生成结果只展示公钥与 SHA-256 指纹；私钥在「保存为 SSH 条目」时才写入
/// 本机钥匙串（WhenUnlockedThisDeviceOnly），条目里只保留引用，绝不进入
/// 明文存储、日志或 UserDefaults。RSA 生成在后台任务执行，4096 位可能耗时十几秒。
struct GeneratorSSHKeySection: View {
    @Bindable var session: AppSessionModel

    @State private var algorithm: SSHKeyAlgorithm = .ed25519
    @State private var rsaKeySize = SSHKeyPairGenerator.defaultRSAKeySize
    @State private var state: GenerationState = .idle
    @State private var generationTask: Task<Void, Never>?
    @State private var copyMessage: String?
    @State private var isSavePresented = false
    @State private var savedEntryTitle: String?

    private enum GenerationState: Equatable {
        case idle
        case running
        case ready(SSHKeyPair)
        case failed(String)
    }

    private var isGenerating: Bool {
        if case .running = state {
            return true
        }
        return false
    }

    private var generatedKeyPair: SSHKeyPair? {
        if case .ready(let keyPair) = state {
            return keyPair
        }
        return nil
    }

    var body: some View {
        AndroidParitySection(title: String(localized: "SSH 密钥")) {
            AndroidParityCard {
                Text("生成 Ed25519 或 RSA 密钥对。公钥与 SHA-256 指纹可以直接复制；私钥只在保存时写入本机钥匙串，不会出现在条目详情、日志或备份明文里。")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("算法")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                    Picker("算法", selection: $algorithm) {
                        ForEach(SSHKeyAlgorithm.allCases, id: \.self) { algorithm in
                            Text(algorithm.displayName).tag(algorithm)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: algorithm) { _, _ in
                        resetResult()
                    }
                }

                if algorithm == .rsa {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("RSA 位数")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                        Picker("RSA 位数", selection: $rsaKeySize) {
                            ForEach(SSHKeyPairGenerator.rsaKeySizeOptions, id: \.self) { bits in
                                Text("\(bits) 位").tag(bits)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: rsaKeySize) { _, _ in
                            resetResult()
                        }
                    }
                    Text("RSA 4096 生成较慢（约十几秒），请保持应用在前台。")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    generate()
                } label: {
                    Label(
                        isGenerating ? String(localized: "正在生成…") : String(localized: "生成密钥对"),
                        systemImage: "key.horizontal"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                .disabled(isGenerating)

                if isGenerating {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在生成密钥对…")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }
                    .accessibilityLabel("正在生成密钥对")
                }

                if case .failed(let message) = state {
                    Text(message)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let keyPair = generatedKeyPair {
                    resultView(keyPair)
                }
            }
        }
        .sheet(isPresented: $isSavePresented) {
            if let keyPair = generatedKeyPair {
                GeneratorSSHSaveSheet(session: session, keyPair: keyPair) { entry in
                    savedEntryTitle = entry.title
                    copyMessage = nil
                }
            }
        }
        .onDisappear {
            generationTask?.cancel()
        }
    }

    @ViewBuilder
    private func resultView(_ keyPair: SSHKeyPair) -> some View {
        AndroidParityDivider()

        HStack(spacing: 8) {
            Label("生成结果", systemImage: "checkmark.seal")
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(AndroidParityPalette.primary)
            Spacer()
            Text("\(keyPair.algorithm.displayName) · \(keyPair.keySize) 位")
                .font(.caption.weight(.heavy))
                .foregroundStyle(AndroidParityPalette.textSecondary)
        }

        secretBlock(
            title: String(localized: "公钥"),
            value: keyPair.publicKeyOpenSSH
        ) {
            copy(keyPair.publicKeyOpenSSH)
        }

        secretBlock(
            title: String(localized: "SHA-256 指纹"),
            value: keyPair.fingerprintSHA256
        ) {
            copy(keyPair.fingerprintSHA256)
        }

        Text("私钥只保存在本机钥匙串（解锁后可读、不随备份同步），条目里仅保存公钥、指纹与引用。")
            .font(.caption.weight(.semibold))
            .foregroundStyle(AndroidParityPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

        Button {
            isSavePresented = true
        } label: {
            Label("保存为 SSH 条目", systemImage: "tray.and.arrow.down")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(AndroidParityButtonStyle(tone: .filled))
        .disabled(session.vaultState != .unlocked)

        if session.vaultState != .unlocked {
            Text("保险库已锁定，请先解锁再保存。")
                .font(.caption.weight(.heavy))
                .foregroundStyle(.orange)
        }

        if let savedEntryTitle {
            Text("已保存到保险库：\(savedEntryTitle)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.primary)
        }

        if let copyMessage {
            Text(copyMessage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textSecondary)
        }
    }

    @ViewBuilder
    private func secretBlock(title: String, value: String, copy action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                Spacer()
                Button(action: action) {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.caption.weight(.heavy))
                }
                .buttonStyle(.plain)
                .foregroundStyle(AndroidParityPalette.primary)
            }
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(AndroidParityPalette.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    AndroidParityPalette.surfaceVariant.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
    }

    private func resetResult() {
        generationTask?.cancel()
        generationTask = nil
        state = .idle
        savedEntryTitle = nil
        copyMessage = nil
    }

    private func generate() {
        guard !isGenerating else {
            return
        }
        let algorithm = algorithm
        let rsaKeySize = rsaKeySize
        state = .running
        savedEntryTitle = nil
        copyMessage = nil
        generationTask?.cancel()
        generationTask = Task { @MainActor in
            do {
                let keyPair = try await Task.detached(priority: .userInitiated) {
                    try SSHKeyPairGenerator.generate(
                        algorithm: algorithm,
                        rsaKeySize: algorithm == .rsa ? rsaKeySize : 0
                    )
                }.value
                guard !Task.isCancelled else {
                    return
                }
                state = .ready(keyPair)
                session.haptics.play(.success)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                state = .failed(error.localizedDescription)
                session.haptics.play(.error)
            }
        }
    }

    private func copy(_ value: String) {
        guard !value.isEmpty else {
            return
        }
        copyMessage = session.copySensitiveValueToPasteboard(value).message
    }
}

/// 把生成的 SSH 密钥保存为 SSH 条目（#154）。
///
/// 保存走 `AppSessionModel.saveGeneratedSSHKey`：先把私钥写入钥匙串，再创建条目；
/// 任一步失败都不会留下半成品条目，钥匙串里的残留也会回滚。
struct GeneratorSSHSaveSheet: View {
    @Bindable var session: AppSessionModel
    @Environment(\.dismiss) private var dismiss
    let keyPair: SSHKeyPair
    let onSaved: (LocalSshKeyEntry) -> Void

    @State private var title = ""
    @State private var username = ""
    @State private var host = ""
    @State private var passphraseHint = ""
    @State private var notes = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        session.vaultState == .unlocked
            && !trimmedTitle.isEmpty
            && !isSaving
    }

    var body: some View {
        NavigationStack {
            AndroidParityScreen {
                AndroidParitySection(title: String(localized: "SSH 密钥信息")) {
                    AndroidParityCard {
                        AndroidParityInfoRow(
                            title: String(localized: "算法"),
                            value: "\(keyPair.algorithm.displayName) · \(keyPair.keySize) 位"
                        )
                        AndroidParityInfoRow(
                            title: String(localized: "SHA-256 指纹"),
                            value: keyPair.fingerprintSHA256
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text("公钥")
                                .font(.caption.weight(.heavy))
                                .foregroundStyle(AndroidParityPalette.textSecondary)
                            Text(keyPair.publicKeyOpenSSH)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                AndroidParitySection(title: String(localized: "条目信息")) {
                    AndroidParityCard {
                        field(
                            title: String(localized: "标题"),
                            prompt: String(localized: "例如：GitHub 部署密钥"),
                            text: $title
                        )
                        field(
                            title: String(localized: "用户名"),
                            prompt: String(localized: "可选"),
                            text: $username
                        )
                        field(
                            title: String(localized: "主机"),
                            prompt: String(localized: "可选，例如：github.com"),
                            text: $host,
                            keyboardType: .URL
                        )
                        field(
                            title: String(localized: "口令提示"),
                            prompt: String(localized: "可选"),
                            text: $passphraseHint
                        )
                        VStack(alignment: .leading, spacing: 6) {
                            Text("备注")
                                .font(.caption.weight(.heavy))
                                .foregroundStyle(AndroidParityPalette.textSecondary)
                            TextField("备注", text: $notes, axis: .vertical)
                                .lineLimit(2...4)
                                .textFieldStyle(AndroidParityTextFieldStyle())
                        }
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
                        Text("私钥只会写入本机钥匙串，不随条目导出，也不会同步到其它设备；条目里保存公钥、指纹、引用与位数。")
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
            .navigationTitle("保存 SSH 密钥")
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
            let entry = try session.saveGeneratedSSHKey(
                title: trimmedTitle,
                keyPair: keyPair,
                username: username,
                host: host,
                passphraseHint: passphraseHint,
                notes: notes
            )
            onSaved(entry)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}
