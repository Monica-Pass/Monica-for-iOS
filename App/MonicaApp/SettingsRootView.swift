import MonicaSecurity
import MonicaStorage
import MonicaSync
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct SettingsRootView: View {
    let environment: MonicaAppEnvironment
    @Bindable var session: AppSessionModel
    let storageStrategy: String
    let mdbxBridge: String
    let refreshAutoFillIndex: () -> Void
    let runVerification: () -> Void

    @State private var isCSVImporterPresented = false
    @State private var isCSVExporterPresented = false
    @State private var csvExportDocument = CSVExportDocument()
    @State private var isAndroidBackupImporterPresented = false
    @State private var isAndroidBackupExporterPresented = false
    @State private var isAndroidBackupPasswordPromptPresented = false
    @State private var androidBackupExportDocument = AndroidBackupExportDocument()

    private var autoLockSelection: Binding<AppAutoLockPolicy> {
        Binding {
            session.autoLockPolicy
        } set: { policy in
            session.updateAutoLockPolicy(policy)
        }
    }

    private var cardDensitySelection: Binding<VaultDisplayCardDensity> {
        Binding {
            session.vaultDisplayPreferences.cardDensity
        } set: { density in
            var preferences = session.vaultDisplayPreferences
            preferences.cardDensity = density
            session.updateVaultDisplayPreferences(preferences)
        }
    }

    private var showsLoginUsernameBinding: Binding<Bool> {
        Binding {
            session.vaultDisplayPreferences.showsLoginUsername
        } set: { isVisible in
            var preferences = session.vaultDisplayPreferences
            preferences.showsLoginUsername = isVisible
            session.updateVaultDisplayPreferences(preferences)
        }
    }

    private var showsLoginURLBinding: Binding<Bool> {
        Binding {
            session.vaultDisplayPreferences.showsLoginURL
        } set: { isVisible in
            var preferences = session.vaultDisplayPreferences
            preferences.showsLoginURL = isVisible
            session.updateVaultDisplayPreferences(preferences)
        }
    }

    private var showsTabLabelsBinding: Binding<Bool> {
        Binding {
            session.vaultDisplayPreferences.showsTabLabels
        } set: { isVisible in
            var preferences = session.vaultDisplayPreferences
            preferences.showsTabLabels = isVisible
            session.updateVaultDisplayPreferences(preferences)
        }
    }

    private var colorSchemeSelection: Binding<AppAppearanceColorScheme> {
        Binding {
            session.appearancePreferences.colorScheme
        } set: { colorScheme in
            var preferences = session.appearancePreferences
            preferences.colorScheme = colorScheme
            session.updateAppearancePreferences(preferences)
        }
    }

    private var accentColorSelection: Binding<AppAppearanceAccentColor> {
        Binding {
            session.appearancePreferences.accentColor
        } set: { accentColor in
            var preferences = session.appearancePreferences
            preferences.accentColor = accentColor
            session.updateAppearancePreferences(preferences)
        }
    }

    private var passwordListIconStyleSelection: Binding<AppPasswordListIconStyle> {
        Binding {
            session.appearancePreferences.passwordListIconStyle
        } set: { iconStyle in
            var preferences = session.appearancePreferences
            preferences.passwordListIconStyle = iconStyle
            session.updateAppearancePreferences(preferences)
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
                    Picker("颜色模式", selection: colorSchemeSelection) {
                        ForEach(AppAppearanceColorScheme.allCases) { colorScheme in
                            Text(colorScheme.label).tag(colorScheme)
                        }
                    }
                    Picker("强调色", selection: accentColorSelection) {
                        ForEach(AppAppearanceAccentColor.allCases) { accentColor in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(accentColor.swiftUIColor)
                                    .frame(width: 12, height: 12)
                                Text(accentColor.label)
                            }
                            .tag(accentColor)
                        }
                    }
                    Picker("密码列表图标", selection: passwordListIconStyleSelection) {
                        ForEach(AppPasswordListIconStyle.allCases) { iconStyle in
                            Text(iconStyle.label).tag(iconStyle)
                        }
                    }
                    AndroidParityDivider()
                    Picker("卡片密度", selection: cardDensitySelection) {
                        ForEach(VaultDisplayCardDensity.allCases) { density in
                            Text(density.label).tag(density)
                        }
                    }
                    Toggle("账号字段", isOn: showsLoginUsernameBinding)
                        .font(.headline.weight(.heavy))
                        .tint(AndroidParityPalette.primary)
                    Toggle("网址字段", isOn: showsLoginURLBinding)
                        .font(.headline.weight(.heavy))
                        .tint(AndroidParityPalette.primary)
                    Toggle("底部导航文字", isOn: showsTabLabelsBinding)
                        .font(.headline.weight(.heavy))
                        .tint(AndroidParityPalette.primary)
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

            AndroidParitySection(title: "安全中心") {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                    ForEach(session.securityCenterRows) { row in
                        AndroidParitySecurityCenterRow(row: row)
                        if row.id != session.securityCenterRows.last?.id {
                            AndroidParityDivider()
                        }
                    }
                }
                if !session.securityCenterRepairSuggestions.isEmpty {
                    AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                        ForEach(session.securityCenterRepairSuggestions) { suggestion in
                            AndroidParitySecurityRepairSuggestionRow(suggestion: suggestion)
                            if suggestion.id != session.securityCenterRepairSuggestions.last?.id {
                                AndroidParityDivider()
                            }
                        }
                    }
                }
                if !recentOperationTimelineEvents.isEmpty {
                    AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                        ForEach(recentOperationTimelineEvents) { event in
                            AndroidParityOperationTimelineRow(event: event)
                            if event.id != recentOperationTimelineEvents.last?.id {
                                AndroidParityDivider()
                            }
                        }
                    }
                }
                if !session.duplicateLoginMergePreviews.isEmpty {
                    AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                        ForEach(session.duplicateLoginMergePreviews) { preview in
                            AndroidParityDuplicateLoginPreviewRow(
                                preview: preview,
                                mergePreview: {
                                    try? session.mergeDuplicateLoginPreview(preview)
                                },
                                ignorePreview: {
                                    session.ignoreDuplicateLoginPreview(preview)
                                }
                            )
                            if preview.id != session.duplicateLoginMergePreviews.last?.id {
                                AndroidParityDivider()
                            }
                        }
                    }
                }
                if session.ignoredDuplicateLoginGroupCount > 0 {
                    Button {
                        session.clearIgnoredDuplicateLoginPreviews()
                    } label: {
                        Label("恢复已忽略重复项", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                }
                if session.canUndoLastDuplicateLoginMerge {
                    Button {
                        try? session.undoLastDuplicateLoginMerge()
                    } label: {
                        Label("撤销上次合并", systemImage: "arrow.uturn.backward.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                }
            }

            AndroidParitySection(title: "权限管理") {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                    ForEach(session.permissionStatusRows) { row in
                        AndroidParityPermissionRow(row: row)
                        if row.id != session.permissionStatusRows.last?.id {
                            AndroidParityDivider()
                        }
                    }
                }
            }

            AndroidParitySection(title: "迁移") {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                    AndroidParityInfoRow(title: "CSV", value: session.entryOperationState.label)
                    HStack(spacing: 12) {
                        Button {
                            isCSVImporterPresented = true
                        } label: {
                            Label("导入 CSV", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                        .disabled(session.vaultState != .unlocked)

                        Button {
                            do {
                                csvExportDocument = try session.csvExportDocument()
                                isCSVExporterPresented = true
                            } catch {
                                session.entryOperationState = .failed(error.localizedDescription)
                            }
                        } label: {
                            Label("导出 CSV", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                        .disabled(session.vaultState != .unlocked)
                    }

                    if let preview = session.csvImportPreview {
                        AndroidParityDivider()
                        AndroidParityInfoRow(title: "可导入", value: "\(preview.items.count)")
                        AndroidParityInfoRow(title: "问题", value: "\(preview.issues.count)")
                        Button {
                            do {
                                try session.confirmCSVImport(projectTitle: "CSV 导入")
                            } catch {
                                // AppSessionModel owns user-visible failure state.
                            }
                        } label: {
                            Label("确认导入", systemImage: "checkmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                        .disabled(preview.items.isEmpty)
                    }

                    AndroidParityDivider()
                    AndroidParityInfoRow(title: "Android 备份", value: session.entryOperationState.label)
                    if let encryptedFileName = session.pendingAndroidEncryptedBackupFileName {
                        AndroidParityInfoRow(title: "加密备份", value: encryptedFileName)
                    }
                    HStack(spacing: 12) {
                        Button {
                            isAndroidBackupImporterPresented = true
                        } label: {
                            Label("导入备份", systemImage: "archivebox")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                        .disabled(session.vaultState != .unlocked)

                        Button {
                            do {
                                androidBackupExportDocument = try session.androidBackupExportDocument()
                                isAndroidBackupExporterPresented = true
                            } catch {
                                session.entryOperationState = .failed(error.localizedDescription)
                            }
                        } label: {
                            Label("导出备份", systemImage: "archivebox.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                        .disabled(session.vaultState != .unlocked)
                    }

                    if let preview = session.androidBackupImportPreview {
                        AndroidParityDivider()
                        AndroidParityInfoRow(title: "备份可导入", value: "\(preview.items.count)")
                        AndroidParityInfoRow(title: "备份问题", value: "\(preview.issues.count)")
                        Button {
                            do {
                                try session.confirmAndroidBackupImport(projectTitle: "Android 备份")
                            } catch {
                                // AppSessionModel owns user-visible failure state.
                            }
                        } label: {
                            Label("确认导入备份", systemImage: "checkmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                        .disabled(preview.items.isEmpty)
                    }
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

            AndroidParitySection(title: "开发者设置") {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                    let rows = AppDeveloperDiagnostics.rows(
                        environment: environment,
                        session: session,
                        storageStrategy: storageStrategy,
                        mdbxBridge: mdbxBridge
                    )
                    ForEach(rows) { row in
                        AndroidParityDeveloperDiagnosticRow(row: row)
                        if row.id != rows.last?.id {
                            AndroidParityDivider()
                        }
                    }
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
        .fileImporter(
            isPresented: $isCSVImporterPresented,
            allowedContentTypes: [.commaSeparatedText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let fileURL = urls.first else {
                    return
                }
                do {
                    _ = try session.previewCSVImport(from: fileURL)
                } catch {
                    session.entryOperationState = .failed(error.localizedDescription)
                }
            case .failure(let error):
                session.entryOperationState = .failed(error.localizedDescription)
            }
        }
        .fileExporter(
            isPresented: $isCSVExporterPresented,
            document: csvExportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: "monica-vault.csv"
        ) { result in
            if case .failure(let error) = result {
                session.entryOperationState = .failed(error.localizedDescription)
            }
        }
        .fileImporter(
            isPresented: $isAndroidBackupImporterPresented,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let fileURL = urls.first else {
                    return
                }
                do {
                    _ = try session.prepareAndroidBackupImport(from: fileURL)
                    isAndroidBackupPasswordPromptPresented = session.pendingAndroidEncryptedBackupFileName != nil
                } catch {
                    session.entryOperationState = .failed(error.localizedDescription)
                }
            case .failure(let error):
                session.entryOperationState = .failed(error.localizedDescription)
            }
        }
        .fileExporter(
            isPresented: $isAndroidBackupExporterPresented,
            document: androidBackupExportDocument,
            contentType: .zip,
            defaultFilename: "monica-android-backup.zip"
        ) { result in
            if case .failure(let error) = result {
                session.entryOperationState = .failed(error.localizedDescription)
            }
        }
        .alert("Android 加密备份", isPresented: $isAndroidBackupPasswordPromptPresented) {
            SecureField("备份密码", text: $session.androidBackupDecryptPassword)
            Button("取消", role: .cancel) {
                session.cancelPendingAndroidEncryptedBackupImport()
            }
            Button("解密预览") {
                do {
                    _ = try session.previewPendingAndroidEncryptedBackupImport()
                } catch {
                    session.entryOperationState = .failed(error.localizedDescription)
                    isAndroidBackupPasswordPromptPresented = session.pendingAndroidEncryptedBackupFileName != nil
                }
            }
            .disabled(session.androidBackupDecryptPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("请输入从 Android 导出该备份时设置的密码。密码只在本次解密中使用。")
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

    private var recentOperationTimelineEvents: [AppOperationTimelineEvent] {
        Array(session.operationTimelineEvents.prefix(6))
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

private struct AndroidParityOperationTimelineRow: View {
    let event: AppOperationTimelineEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AndroidParityPalette.primary)
                .frame(width: 28, height: 28)
                .background(AndroidParityPalette.primary.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(event.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textPrimary)
                    Spacer(minLength: 8)
                    Text(event.occurredAt, style: .time)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
                Text(event.detail)
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AndroidParitySecurityCenterRow: View {
    let row: AppSecurityCenterRow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AndroidParityPalette.primary)
                .frame(width: 28, height: 28)
                .background(AndroidParityPalette.primary.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(row.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textPrimary)
                    Spacer(minLength: 8)
                    Text(row.value)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AndroidParitySecurityRepairSuggestionRow: View {
    let suggestion: AppSecurityCenterRepairSuggestion

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: suggestion.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AndroidParityPalette.primary)
                .frame(width: 28, height: 28)
                .background(AndroidParityPalette.primary.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(suggestion.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                Text(suggestion.detail)
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AndroidParityDuplicateLoginPreviewRow: View {
    let preview: AppDuplicateLoginMergePreview
    let mergePreview: () -> Void
    let ignorePreview: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AndroidParityPalette.primary)
                .frame(width: 28, height: 28)
                .background(AndroidParityPalette.primary.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(preview.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textPrimary)
                    Spacer(minLength: 8)
                    Text(preview.entryCountLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
                Text(preview.detail)
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(preview.username) · \(preview.url)")
                    .font(.caption2)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Button(action: mergePreview) {
                        Label("合并重复项", systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))

                    Button(action: ignorePreview) {
                        Label("忽略", systemImage: "eye.slash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AndroidParityPermissionRow: View {
    let row: AppPermissionStatusRow
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 28, height: 28)
                .background(statusColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(row.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textPrimary)
                    Spacer(minLength: 8)
                    Text(row.value)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                }
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let settingsURL = row.settingsURL {
                    Button {
                        openURL(settingsURL)
                    } label: {
                        Label("打开设置", systemImage: "gearshape")
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusColor: Color {
        switch row.state {
        case .granted, .configured:
            AndroidParityPalette.primary
        case .denied, .unavailable:
            .red
        case .notDetermined, .notConfigured, .checkable:
            AndroidParityPalette.textSecondary
        }
    }
}

private struct AndroidParityDeveloperDiagnosticRow: View {
    let row: AppDeveloperDiagnosticRow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AndroidParityPalette.primary)
                .frame(width: 28, height: 28)
                .background(AndroidParityPalette.primary.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(row.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textPrimary)
                    Spacer(minLength: 8)
                    Text(row.value)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
