import MonicaSecurity
import MonicaStorage
import MonicaSync
import Observation
import SwiftUI

struct SettingsRootView: View {
    let environment: MonicaAppEnvironment
    @Bindable var session: AppSessionModel
    let storageStrategy: String
    let mdbxBridge: String
    let refreshAutoFillIndex: () -> Void
    let runVerification: () -> Void

    private var autoLockSelection: Binding<AppAutoLockPolicy> {
        Binding {
            session.autoLockPolicy
        } set: { policy in
            session.updateAutoLockPolicy(policy)
        }
    }

    var body: some View {
        AndroidParityScreen {
            AndroidParitySection(title: "应用") {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                    AndroidParityInfoRow(title: "最低 iOS", value: environment.minimumIOSVersion)
                    AndroidParityDivider()
                    AndroidParityInfoRow(title: "备份", value: MonicaSyncBaseline.firstBackupProvider)
                    AndroidParityInfoRow(title: "密钥策略", value: MonicaSecurityBaseline.biometricPolicy)
                    AndroidParityInfoRow(title: "保险库 Keychain", value: session.vaultKeychainState.label)
                    AndroidParityInfoRow(
                        title: session.biometricUnlockSettingsTitle,
                        value: session.isBiometricUnlockEnabled ? "已启用" : biometricStatusText
                    )
                    Picker("自动锁定", selection: autoLockSelection) {
                        ForEach(AppAutoLockPolicy.presets) { policy in
                            Text(policy.label).tag(policy)
                        }
                    }
                    Button {
                        if session.isBiometricUnlockEnabled {
                            session.setBiometricUnlockEnabled(false)
                        } else {
                            Task {
                                try? await session.prepareVaultKeychainUnlock()
                            }
                        }
                    } label: {
                        Label(
                            session.isBiometricUnlockEnabled
                                ? "关闭 \(session.biometricUnlockDisplayName) 解锁"
                                : "启用 \(session.biometricUnlockDisplayName) 解锁",
                            systemImage: session.biometricUnlockSystemImage
                        )
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                    .disabled(
                        !session.isBiometricUnlockEnabled
                            && (!session.canPrepareVaultKeychainUnlock
                                || !session.canUseBiometricUnlockHardware
                                || session.vaultKeychainState.isRunning)
                    )
                    Button {
                        Task {
                            try? await session.unlockRememberedVaultWithKeychain(
                                deviceID: environment.localDeviceIdentifier
                            )
                        }
                    } label: {
                        Label("使用 Keychain 解锁", systemImage: "lock.open")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                    .disabled(!session.canUnlockRememberedVaultWithKeychain || session.vaultKeychainState.isRunning)
                }
            }

            AndroidParitySection(title: "密保问题") {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                    AndroidParityInfoRow(
                        title: "状态",
                        value: session.areSecurityQuestionsSetForActiveVault ? "已设置" : "未设置"
                    )
                    Picker("问题 1", selection: $session.securityQuestion1ID) {
                        ForEach(AppSessionModel.securityQuestionOptions) { option in
                            Text(option.text).tag(option.id)
                        }
                    }
                    Picker("问题 2", selection: $session.securityQuestion2ID) {
                        ForEach(AppSessionModel.securityQuestionOptions) { option in
                            Text(option.text).tag(option.id)
                        }
                    }
                    TextField("答案 1", text: $session.securityAnswer1)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(AndroidParityTextFieldStyle())
                    TextField("答案 2", text: $session.securityAnswer2)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(AndroidParityTextFieldStyle())
                    if shouldShowSecurityQuestionState {
                        Text(session.securityQuestionState.label)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(securityQuestionStateColor)
                    }
                    Button {
                        do {
                            try session.saveSecurityQuestions()
                        } catch {
                            // AppSessionModel owns user-visible failure state.
                        }
                    } label: {
                        Label("保存密保问题", systemImage: "questionmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                    .disabled(
                        session.vaultState != .unlocked
                            || session.securityAnswer1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || session.securityAnswer2.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }

            AndroidParitySection(title: "自动填充") {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                    AndroidParityInfoRow(
                        title: "阶段",
                        value: ParityFeatureFlag.autofill.isEnabledInPhaseTwo ? "P2 已启用" : "未启用"
                    )
                    AndroidParityInfoRow(title: "索引", value: session.autoFillIndexState.label)
                    AndroidParityInfoRow(title: "App Group", value: environment.appGroupIdentifier)
                    Button(action: refreshAutoFillIndex) {
                        Label("更新自动填充索引", systemImage: "key.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                    .disabled(session.vaultState != .unlocked || session.autoFillIndexState.isRunning)
                }
            }

            AndroidParitySection(title: "技术检查") {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                    AndroidParityInfoRow(title: "主存储", value: storageStrategy)
                    AndroidParityInfoRow(title: "桥接", value: mdbxBridge)
                    AndroidParityInfoRow(title: "检查", value: session.mdbxVerificationState.label)
                    Button(action: runVerification) {
                        Label("运行 MDBX 检查", systemImage: "play.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                    .disabled(session.mdbxVerificationState.isRunning)
                }
            }

            AndroidParitySection(title: "WebDAV") {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                    TextField("服务器 URL", text: $session.webDAVBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textFieldStyle(AndroidParityTextFieldStyle())
                    TextField("用户名", text: $session.webDAVUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(AndroidParityTextFieldStyle())
                    SecureField("密码", text: $session.webDAVPassword)
                        .textFieldStyle(AndroidParityTextFieldStyle())
                    TextField("远端文件", text: $session.webDAVRemoteFileName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(AndroidParityTextFieldStyle())
                    AndroidParityInfoRow(title: "状态", value: session.webDAVBackupState.label)
                    Button {
                        Task {
                            try? await session.uploadActiveVaultBackup()
                        }
                    } label: {
                        Label("备份保险库", systemImage: "arrow.up.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                    .disabled(session.vaultState != .unlocked || session.webDAVBackupState.isRunning)
                    Button {
                        Task {
                            try? await session.downloadWebDAVRestorePreview()
                        }
                    } label: {
                        Label("预览恢复", systemImage: "arrow.down.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                    .disabled(session.vaultState != .unlocked || session.webDAVBackupState.isRunning)
                    if let preview = session.webDAVRestorePreview {
                        AndroidParityDivider()
                        AndroidParityInfoRow(title: "恢复文件", value: preview.fileName)
                        AndroidParityInfoRow(title: "字节", value: "\(preview.byteCount)")
                        AndroidParityInfoRow(title: "SHA-256", value: preview.sha256)
                        SecureField("保险库密码", text: $session.webDAVRestoreVaultPassword)
                            .textFieldStyle(AndroidParityTextFieldStyle())
                        Button(role: .destructive) {
                            do {
                                try session.confirmWebDAVRestore()
                            } catch {
                                // AppSessionModel owns user-visible failure state.
                            }
                        } label: {
                            Label("恢复备份", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AndroidParityButtonStyle(tone: .destructiveOutlined))
                        .disabled(session.webDAVBackupState.isRunning || session.webDAVRestoreVaultPassword.isEmpty)
                    }
                }
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var shouldShowSecurityQuestionState: Bool {
        switch session.securityQuestionState {
        case .idle:
            return false
        case .running, .succeeded, .failed:
            return true
        }
    }

    private var biometricStatusText: String {
        session.canUseBiometricUnlockHardware ? "未启用" : "不可用"
    }

    private var securityQuestionStateColor: Color {
        switch session.securityQuestionState {
        case .failed:
            return .red
        case .idle, .running, .succeeded:
            return AndroidParityPalette.textSecondary
        }
    }
}
