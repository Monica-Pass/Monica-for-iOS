import Observation
import SwiftUI
import UniformTypeIdentifiers

struct PrivacyShieldView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Monica 已锁定")
                    .font(.headline)
            }
        }
        .transition(.opacity)
    }
}

struct MonicaLockScreen: View {
    @Bindable var session: AppSessionModel
    let submitPassword: () -> Void
    let unlockWithKeychain: () -> Void
    let createVault: () -> Void
    let openVault: (URL) -> Void
    let forgotPassword: () -> Void
    @State private var isVaultImporterPresented = false
    @State private var isPasswordVisible = false

    private let vaultFileType = UTType(filenameExtension: "mdbx") ?? .data

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 180)
            VStack(spacing: 42) {
                lockScreenHeader
                lockScreenControls
            }
            .padding(.horizontal, 38)
            Spacer(minLength: 52)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AndroidParityPalette.background.ignoresSafeArea())
        .fileImporter(
            isPresented: $isVaultImporterPresented,
            allowedContentTypes: [vaultFileType],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let fileURL = urls.first else {
                return
            }
            openVault(fileURL)
        }
    }

    private var lockScreenHeader: some View {
        VStack(spacing: 18) {
            Text("Monica")
                .font(.system(size: 36, weight: .heavy, design: .rounded))
                .foregroundStyle(AndroidParityPalette.primary)
            Text(lockScreenPrompt)
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundStyle(AndroidParityPalette.textPrimary)
        }
        .multilineTextAlignment(.center)
    }

    private var lockScreenControls: some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                Group {
                    if isPasswordVisible {
                        TextField("主密码", text: $session.vaultPassword)
                    } else {
                        SecureField("主密码", text: $session.vaultPassword)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.textPrimary)
                .submitLabel(.go)
                .onSubmit {
                    guard !session.vaultPassword.isEmpty,
                          !session.vaultOperationState.isRunning
                    else {
                        return
                    }
                    submitPassword()
                }

                Button {
                    isPasswordVisible.toggle()
                } label: {
                    Image(systemName: isPasswordVisible ? "eye" : "eye.slash")
                        .font(.system(size: AndroidParityTypography.controlIconSize, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AndroidParityPalette.textSecondary)
            }
            .padding(.horizontal, 26)
            .frame(minHeight: 68)
            .background(AndroidParityPalette.background)
            .clipShape(Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(AndroidParityPalette.textSecondary.opacity(0.78), lineWidth: 1.6)
            }

            Button(action: submitPassword) {
                Text(primaryButtonTitle)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .filled))
            .disabled(session.vaultPassword.isEmpty || session.vaultOperationState.isRunning)

            if session.shouldShowBiometricUnlockOnLockScreen {
                Button(action: unlockWithKeychain) {
                    Label(session.biometricUnlockButtonTitle, systemImage: session.biometricUnlockSystemImage)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                .disabled(!session.canUnlockRememberedVaultWithKeychain)
            }

            if !session.isFirstTimeVaultSetup {
                Button(action: forgotPassword) {
                    Text("忘记密码？")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(AndroidParityPalette.primary)
                .padding(.top, 8)
            }

            if shouldShowOperationState {
                Text(session.vaultOperationState.label)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(operationStateColor)
                    .multilineTextAlignment(.center)
                    .padding(.top, -4)
            }

            if session.firstTimePasswordSetupStep != .confirmPassword {
                Button {
                    isVaultImporterPresented = true
                } label: {
                    Label("打开已有保险库", systemImage: "folder")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(AndroidParityPalette.textSecondary.opacity(0.82))
                .padding(.top, shouldShowOperationState ? 0 : 4)
            }
        }
    }

    private var lockScreenPrompt: String {
        if session.isFirstTimeVaultSetup {
            switch session.firstTimePasswordSetupStep {
            case .enterPassword:
                return "设置您的主密码"
            case .confirmPassword:
                return "确认主密码"
            }
        }
        return "输入您的主密码"
    }

    private var primaryButtonTitle: String {
        if session.isFirstTimeVaultSetup {
            switch session.firstTimePasswordSetupStep {
            case .enterPassword:
                return "设置密码"
            case .confirmPassword:
                return "确认"
            }
        }
        return "解锁"
    }

    private var shouldShowOperationState: Bool {
        switch session.vaultOperationState {
        case .idle:
            return false
        case .running, .succeeded, .failed:
            return true
        }
    }

    private var operationStateColor: Color {
        switch session.vaultOperationState {
        case .failed:
            return .red
        case .idle, .running, .succeeded:
            return AndroidParityPalette.textSecondary
        }
    }
}

private struct AndroidLockTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, 22)
            .frame(minHeight: 64)
            .foregroundStyle(AndroidParityPalette.textPrimary)
            .background(AndroidParityPalette.background)
            .clipShape(Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(AndroidParityPalette.textSecondary.opacity(0.76), lineWidth: 1.4)
            }
    }
}

struct ForgotPasswordRecoverySheet: View {
    @Bindable var session: AppSessionModel
    let deviceID: String

    var body: some View {
        NavigationStack {
            AndroidParityScreen {
                switch session.forgotPasswordRecoveryStep {
                case .verifySecurityQuestions:
                    securityQuestionContent
                case .resetPassword:
                    resetPasswordContent
                case .none:
                    EmptyView()
                }
            }
            .navigationTitle("忘记密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        session.dismissForgotPasswordRecovery()
                    }
                }
            }
        }
    }

    private var securityQuestionContent: some View {
        AndroidParitySection(title: "验证身份") {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                Text(session.forgotPasswordQuestion1Text)
                    .font(.subheadline.weight(.semibold))
                TextField("答案 1", text: $session.forgotPasswordAnswer1)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(AndroidParityTextFieldStyle())
                Text(session.forgotPasswordQuestion2Text)
                    .font(.subheadline.weight(.semibold))
                TextField("答案 2", text: $session.forgotPasswordAnswer2)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(AndroidParityTextFieldStyle())
                if shouldShowOperationState {
                    Text(session.vaultOperationState.label)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.red)
                }
                Button {
                    _ = session.verifyForgotPasswordSecurityAnswers(
                        answer1: session.forgotPasswordAnswer1,
                        answer2: session.forgotPasswordAnswer2
                    )
                } label: {
                    Label("验证答案", systemImage: "checkmark.shield")
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                .disabled(
                    session.forgotPasswordAnswer1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || session.forgotPasswordAnswer2.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || session.forgotPasswordAttemptCount >= 3
                )
            }
        }
    }

    private var resetPasswordContent: some View {
        AndroidParitySection(title: "重设主密码") {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                Text("身份已通过验证。请输入新的主密码，重设后请使用新密码解锁。")
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                SecureField("新主密码", text: $session.forgotPasswordNewPassword)
                    .textFieldStyle(AndroidParityTextFieldStyle())
                SecureField("确认新主密码", text: $session.forgotPasswordConfirmPassword)
                    .textFieldStyle(AndroidParityTextFieldStyle())
                if shouldShowOperationState {
                    Text(session.vaultOperationState.label)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(operationStateColor)
                }
                Button {
                    Task {
                        try? await session.resetForgottenPasswordWithVerifiedSecurityAnswers(
                            deviceID: deviceID
                        )
                    }
                } label: {
                    Label("重设密码", systemImage: "key")
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                .disabled(
                    session.forgotPasswordNewPassword.isEmpty
                        || session.forgotPasswordConfirmPassword.isEmpty
                        || session.vaultOperationState.isRunning
                )
            }
        }
    }

    private var shouldShowOperationState: Bool {
        switch session.vaultOperationState {
        case .idle:
            return false
        case .running, .succeeded, .failed:
            return true
        }
    }

    private var operationStateColor: Color {
        switch session.vaultOperationState {
        case .failed:
            return .red
        case .idle, .running, .succeeded:
            return AndroidParityPalette.textSecondary
        }
    }
}
