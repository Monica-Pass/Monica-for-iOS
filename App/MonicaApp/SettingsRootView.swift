import MonicaSecurity
import MonicaStorage
import MonicaSync
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct SettingsRootView: View {
    let environment: MonicaAppEnvironment
    @Bindable var session: AppSessionModel
    let refreshAutoFillIndex: () -> Void

    @State private var isCSVImporterPresented = false
    @State private var isCSVExporterPresented = false
    @State private var csvExportDocument = CSVExportDocument()
    @State private var isKeePassImporterPresented = false
    @State private var isKeePassKeyFileImporterPresented = false
    @State private var isKeePassAttachmentReplacementImporterPresented = false
    @State private var isKeePassAttachmentAdditionImporterPresented = false
    @State private var pendingKeePassAttachmentReplacementEntryID: String?
    @State private var pendingKeePassAttachmentReplacementAttachmentID: String?
    @State private var pendingKeePassAttachmentAdditionEntryID: String?
    @State private var keePassAttachmentSearchText = ""
    @State private var isAndroidBackupImporterPresented = false
    @State private var isAndroidBackupExporterPresented = false
    @State private var isAndroidBackupPasswordPromptPresented = false
    @State private var androidBackupExportDocument = AndroidBackupExportDocument()
    @State private var isSteamAuthenticatorImporterPresented = false
    @State private var autoFillBlockedFieldInput = ""
    @State private var autoFillBlockedSaveTargetInput = ""

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

    private var interfaceDensitySelection: Binding<AppInterfaceDensity> {
        Binding {
            session.appearancePreferences.interfaceDensity
        } set: { density in
            var preferences = session.appearancePreferences
            preferences.interfaceDensity = density
            session.updateAppearancePreferences(preferences)
        }
    }

    private func moveLayoutModule(_ module: PasswordLayoutModule, offset: Int) {
        var preferences = session.vaultLayoutPreferences
        var modules = preferences.orderedModules
        guard let index = modules.firstIndex(of: module) else { return }
        let destination = index + offset
        guard modules.indices.contains(destination) else { return }
        modules.swapAt(index, destination)
        preferences.orderedModules = modules
        session.updateVaultLayoutPreferences(preferences)
    }

    private func toggleLayoutModuleVisibility(_ module: PasswordLayoutModule) {
        var preferences = session.vaultLayoutPreferences
        preferences.setHidden(!preferences.isHidden(module), for: module)
        session.updateVaultLayoutPreferences(preferences)
    }

    private func isFirstLayoutModule(_ module: PasswordLayoutModule) -> Bool {
        session.vaultLayoutPreferences.orderedModules.first == module
    }

    private func isLastLayoutModule(_ module: PasswordLayoutModule) -> Bool {
        session.vaultLayoutPreferences.orderedModules.last == module
    }

    var body: some View {
        AndroidParityScreen {
            AndroidParitySection(title: String(localized: "应用")) {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                    AndroidParityInfoRow(title: String(localized: "系统要求"), value: environment.minimumIOSVersion)
                    AndroidParityDivider()
                    AndroidParityInfoRow(title: String(localized: "备份"), value: MonicaSyncBaseline.firstBackupProvider)
                    AndroidParityInfoRow(title: String(localized: "密钥策略"), value: MonicaSecurityBaseline.biometricPolicy)
                    AndroidParityInfoRow(title: String(localized: "保险库钥匙串"), value: session.vaultKeychainState.label)
                    AndroidParityInfoRow(
                        title: session.biometricUnlockSettingsTitle,
                        value: session.isBiometricUnlockEnabled ? String(localized: "已启用") : biometricStatusText
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
                                ? String(localized: "关闭 \(session.biometricUnlockDisplayName) 解锁")
                                : String(localized: "启用 \(session.biometricUnlockDisplayName) 解锁"),
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
                        Label("使用钥匙串解锁", systemImage: "lock.open")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                    .disabled(!session.canUnlockRememberedVaultWithKeychain || session.vaultKeychainState.isRunning)
                    AndroidParityDivider()
                    Button {
                        session.presentQuickSetup()
                    } label: {
                        Label("快速设置", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                    Button {
                        session.presentExtensions()
                    } label: {
                        Label("扩展功能", systemImage: "square.grid.2x2")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                }
            }

            AndroidParitySection(title: String(localized: "界面密度")) {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                    Text(String(localized: "字号始终跟随系统动态字体与辅助功能设置；三档密度只调整间距与行高，不改变字号、图标或可触控区域（不小于 44pt）。"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                    Picker("界面密度", selection: interfaceDensitySelection) {
                        ForEach(AppInterfaceDensity.allCases) { density in
                            Text(density.label).tag(density)
                        }
                    }
                    Text(session.appearancePreferences.interfaceDensity.detail)
                        .font(.footnote)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                    Button {
                        session.restoreDefaultInterfaceDensity()
                    } label: {
                        Label(String(localized: "恢复默认界面密度"), systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                    .disabled(session.appearancePreferences.interfaceDensity == .default)
                }
            }

            AndroidParitySection(title: String(localized: "布局")) {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                    Text(String(localized: "密码页模块"))
                        .font(.headline.weight(.heavy))
                    Text(String(localized: "调整二级模块的顺序与显隐；隐藏的模块仍可从「更多」进入。卡片密度与字段显隐在「应用」中设置。"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                    AndroidParityDivider()
                    ForEach(session.vaultLayoutPreferences.orderedModules) { module in
                        HStack(spacing: 12) {
                            Image(systemName: module.systemImage)
                                .frame(width: 22)
                                .foregroundStyle(AndroidParityPalette.primary)
                            Text(module.title)
                                .font(.subheadline.weight(.heavy))
                            Spacer()
                            Button {
                                moveLayoutModule(module, offset: -1)
                            } label: {
                                Image(systemName: "chevron.up")
                            }
                            .buttonStyle(.plain)
                            .disabled(isFirstLayoutModule(module))
                            .accessibilityLabel(String(localized: "上移"))
                            Button {
                                moveLayoutModule(module, offset: 1)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.plain)
                            .disabled(isLastLayoutModule(module))
                            .accessibilityLabel(String(localized: "下移"))
                            Button {
                                toggleLayoutModuleVisibility(module)
                            } label: {
                                Image(
                                    systemName: session.vaultLayoutPreferences.isHidden(module)
                                        ? "eye.slash"
                                        : "eye"
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                session.vaultLayoutPreferences.isHidden(module)
                                    ? String(localized: "显示")
                                    : String(localized: "隐藏")
                            )
                        }
                        .padding(.vertical, 4)
                    }
                    AndroidParityDivider()
                    Button {
                        session.restoreDefaultVaultLayoutPreferences()
                    } label: {
                        Label(String(localized: "恢复默认布局"), systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                }
            }

            AndroidParitySection(title: "Monica Plus") {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                    AndroidParityInfoRow(
                        title: session.plusEntitlementStatusRow.title,
                        value: session.plusEntitlementStatusRow.value
                    )
                    Text(session.plusEntitlementStatusRow.detail)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                    AndroidParityInfoRow(title: String(localized: "激活"), value: session.plusActivationState.label)
                    if session.isPlusActive {
                        Button(role: .destructive) {
                            session.deactivatePlus()
                        } label: {
                            Label("关闭 Plus", systemImage: "seal")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AndroidParityButtonStyle(tone: .destructiveOutlined))
                        .disabled(session.plusActivationState.isRunning)
                    } else {
                        Button {
                            Task {
                                try? await session.activatePlusFromResource()
                            }
                        } label: {
                            Label("激活 Plus", systemImage: "checkmark.seal")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                        .disabled(!session.canActivatePlusFromResource || session.plusActivationState.isRunning)
                    }
                    AndroidParityDivider()
                    ForEach(session.plusFeatureRows) { row in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: row.systemImage)
                                .font(.headline.weight(.bold))
                                .foregroundStyle(row.isUnlocked ? AndroidParityPalette.primary : AndroidParityPalette.textSecondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(row.title)
                                        .font(.subheadline.weight(.heavy))
                                    Spacer(minLength: 8)
                                    Text(row.value)
                                        .font(.caption.weight(.heavy))
                                        .foregroundStyle(row.isUnlocked ? AndroidParityPalette.primary : AndroidParityPalette.textSecondary)
                                }
                                Text(row.detail)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AndroidParityPalette.textSecondary)
                            }
                        }
                        if row.id != session.plusFeatureRows.last?.id {
                            AndroidParityDivider()
                        }
                    }
                }
            }

            AndroidParitySection(title: String(localized: "密保问题")) {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                    AndroidParityInfoRow(
                        title: String(localized: "状态"),
                        value: session.areSecurityQuestionsSetForActiveVault ? String(localized: "已设置") : String(localized: "未设置")
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
                        Task {
                            try? await session.saveSecurityQuestions()
                        }
                    } label: {
                        Label("保存密保问题", systemImage: "questionmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                    .disabled(
                        session.vaultState != .unlocked
                            || session.securityQuestionState.isRunning
                            || session.securityAnswer1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || session.securityAnswer2.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }

            AndroidParitySection(title: String(localized: "自动填充")) {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                    AndroidParityInfoRow(title: String(localized: "索引"), value: session.autoFillIndexState.label)
                    AndroidParityInfoRow(title: String(localized: "共享数据"), value: environment.appGroupIdentifier.isEmpty ? String(localized: "待配置") : String(localized: "已配置"))
                    ForEach(session.autoFillPolicyRows, id: \.title) { row in
                        AndroidParityInfoRow(title: row.title, value: row.value)
                    }
                    ForEach(session.autoFillSystemStatusRows) { row in
                        AndroidParityInfoRow(title: row.title, value: row.value)
                        Text(row.detail)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }
                    TextField("忽略字段", text: $autoFillBlockedFieldInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(AndroidParityTextFieldStyle())
                    Button {
                        addAutoFillBlockedField()
                    } label: {
                        Label("添加阻止字段", systemImage: "text.badge.xmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                    .disabled(autoFillBlockedFieldInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    TextField("忽略保存目标", text: $autoFillBlockedSaveTargetInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(AndroidParityTextFieldStyle())
                    Button {
                        addAutoFillBlockedSaveTarget()
                    } label: {
                        Label("添加忽略目标", systemImage: "link.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                    .disabled(autoFillBlockedSaveTargetInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button {
                        clearAutoFillPolicy()
                    } label: {
                        Label("清空忽略规则", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                    .disabled(
                        session.autoFillPolicy.blockedFields.isEmpty
                            && session.autoFillPolicy.blockedSaveTargets.isEmpty
                    )
                    Button(action: refreshAutoFillIndex) {
                        Label("更新自动填充索引", systemImage: "key.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                    .disabled(session.vaultState != .unlocked || session.autoFillIndexState.isRunning)
                }
            }

            AndroidParitySection(title: String(localized: "Steam 导入")) {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                    AndroidParityInfoRow(title: String(localized: "格式"), value: "Steam maFile / JSON")
                    Button {
                        isSteamAuthenticatorImporterPresented = true
                    } label: {
                        Label("导入 Steam maFile", systemImage: "gamecontroller")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                    .disabled(session.vaultState != .unlocked)
                }
            }

            AndroidParitySection(title: String(localized: "安全中心")) {
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

            AndroidParitySection(title: "Timeline") {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                    Picker("类型", selection: Binding(
                        get: { session.operationTimelineFilterKind?.rawValue ?? "all" },
                        set: { value in
                            session.operationTimelineFilterKind = value == "all" ? nil : UnifiedVaultItemKind(rawValue: value)
                        }
                    )) {
                        Text("全部").tag("all")
                        ForEach(UnifiedVaultItemKind.allCases, id: \.rawValue) { kind in
                            Text(kind.localizedDisplayName).tag(kind.rawValue)
                        }
                    }
                    Picker("动作", selection: Binding(
                        get: { session.operationTimelineFilterAction?.rawValue ?? "all" },
                        set: { value in
                            session.operationTimelineFilterAction = value == "all" ? nil : AppOperationTimelineAction(rawValue: value)
                        }
                    )) {
                        Text("全部").tag("all")
                        ForEach(AppOperationTimelineAction.allCasesForSettings, id: \.rawValue) { action in
                            Text(action.title).tag(action.rawValue)
                        }
                    }
                    ForEach(session.filteredOperationTimelineEvents.prefix(20)) { event in
                        AndroidParityOperationTimelineRow(event: event)
                        if event.id != session.filteredOperationTimelineEvents.prefix(20).last?.id {
                            AndroidParityDivider()
                        }
                    }
                    if session.filteredOperationTimelineEvents.isEmpty {
                        AndroidParityInfoRow(title: String(localized: "记录"), value: String(localized: "暂无"))
                    }
                }
            }

            AndroidParitySection(title: String(localized: "权限管理")) {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                    ForEach(session.permissionStatusRows) { row in
                        AndroidParityPermissionRow(row: row)
                        if row.id != session.permissionStatusRows.last?.id {
                            AndroidParityDivider()
                        }
                    }
                }
            }

            AndroidParitySection(title: String(localized: "迁移")) {
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
                        AndroidParityInfoRow(title: String(localized: "可导入"), value: "\(preview.items.count)")
                        AndroidParityInfoRow(title: String(localized: "问题"), value: "\(preview.issues.count)")
                        Button {
                            do {
                                try session.confirmCSVImport(projectTitle: String(localized: "CSV 导入"))
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
                    AndroidParityInfoRow(title: "KeePass / KDBX", value: session.entryOperationState.label)
                    Button {
                        isKeePassImporterPresented = true
                    } label: {
                        Label("选择 KDBX", systemImage: "key.radiowaves.forward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                    .disabled(session.vaultState != .unlocked)

                    if let preview = session.keePassImportPreview {
                        AndroidParityDivider()
                        AndroidParityInfoRow(title: String(localized: "KeePass 格式"), value: preview.format.localizedDisplayName)
                        AndroidParityInfoRow(title: String(localized: "状态"), value: keePassPreviewStatusText(preview.status))
                        if let headerSummary = preview.headerSummary {
                            AndroidParityInfoRow(title: String(localized: "KDBX 版本"), value: headerSummary.displayName)
                            if let cryptoSummary = headerSummary.cryptoSummary {
                                AndroidParityInfoRow(title: String(localized: "KDBX 加密"), value: cryptoSummary.displaySummary)
                            }
                        }
                        SecureField("数据库密码", text: $session.keePassUnlockPassword)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.vertical, 6)
                        HStack(spacing: 12) {
                            Button {
                                isKeePassKeyFileImporterPresented = true
                            } label: {
                                Label("选择密钥文件", systemImage: "folder")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(AndroidParityButtonStyle(tone: .outlined))

                            Button {
                                do {
                                    _ = try session.prepareKeePassUnlockPreflight()
                                } catch {
                                    // AppSessionModel owns user-visible failure state.
                                }
                            } label: {
                                Label("准备解锁", systemImage: "lock.open")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                        }
                        AndroidParityInfoRow(
                            title: String(localized: "密钥文件"),
                            value: session.keePassKeyFileName.isEmpty ? String(localized: "未选择") : session.keePassKeyFileName
                        )
                        if let preflight = preview.unlockPreflight {
                            AndroidParityInfoRow(title: String(localized: "凭据"), value: preflight.credentials.localizedDisplayName)
                        }
                        Button {
                            do {
                                _ = try session.previewKeePassReadOnlyTree()
                            } catch {
                                // AppSessionModel owns user-visible failure state.
                            }
                        } label: {
                            Label("预览结构", systemImage: "list.bullet.rectangle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AndroidParityButtonStyle(tone: .outlined))

                        if let snapshot = session.keePassReadOnlySnapshot {
                            AndroidParityInfoRow(title: String(localized: "只读预览"), value: snapshot.displaySummary)
                            AndroidParityInfoRow(title: String(localized: "分组"), value: "\(snapshot.groupCount)")
                            AndroidParityInfoRow(title: String(localized: "条目"), value: "\(snapshot.entryCount)")
                            ForEach(snapshot.groups.prefix(3)) { group in
                                AndroidParityInfoRow(
                                    title: group.title.isEmpty ? String(localized: "未命名分组") : group.title,
                                    value: group.path
                                )
                            }
                            ForEach(snapshot.entries) { entry in
                                AndroidParityInfoRow(
                                    title: entry.title.isEmpty ? String(localized: "未命名条目") : entry.title,
                                    value: entry.username.isEmpty ? entry.groupPath : entry.username
                                )
                                HStack(spacing: 12) {
                                    if entry.isDeleted {
                                        Button {
                                            do {
                                                _ = try session.restoreKeePassReadOnlyRecycleBinEntryAndWriteBack(
                                                    entryID: entry.id
                                                )
                                            } catch {
                                                session.entryOperationState = .failed(error.localizedDescription)
                                            }
                                        } label: {
                                            Label("恢复并写回", systemImage: "arrow.uturn.backward.circle")
                                                .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                                        .disabled(session.keePassSourceFileURL == nil)
                                    }

                                    Button {
                                        pendingKeePassAttachmentAdditionEntryID = entry.id
                                        isKeePassAttachmentAdditionImporterPresented = true
                                    } label: {
                                        Label("添加附件并写回", systemImage: "paperclip.badge.plus")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                                    .disabled(session.keePassSourceFileURL == nil)
                                }
                            }
                            AndroidParityDivider()
                            TextField("搜索 KeePass 附件", text: $keePassAttachmentSearchText)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(.vertical, 6)
                            let candidates = (try? session.keePassAttachmentEditCandidates(
                                matching: keePassAttachmentSearchText
                            )) ?? []
                            AndroidParityInfoRow(title: String(localized: "可编辑附件"), value: "\(candidates.count)")
                            ForEach(candidates) { candidate in
                                VStack(alignment: .leading, spacing: 8) {
                                    AndroidParityInfoRow(
                                        title: candidate.fileName,
                                        value: String(localized: "\(candidate.originalSize) 字节")
                                    )
                                    AndroidParityInfoRow(
                                        title: candidate.entryTitle.isEmpty ? String(localized: "未命名条目") : candidate.entryTitle,
                                        value: candidate.entryUsername.isEmpty ? candidate.groupPath : candidate.entryUsername
                                    )
                                    HStack(spacing: 12) {
                                        Button {
                                            pendingKeePassAttachmentReplacementEntryID = candidate.entryID
                                            pendingKeePassAttachmentReplacementAttachmentID = candidate.attachmentID
                                            isKeePassAttachmentReplacementImporterPresented = true
                                        } label: {
                                            Label("替换并写回", systemImage: "arrow.triangle.2.circlepath")
                                                .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                                        .disabled(session.keePassSourceFileURL == nil)

                                        Button(role: .destructive) {
                                            do {
                                                _ = try session.deleteKeePassReadOnlyAttachmentAndWriteBack(
                                                    entryID: candidate.entryID,
                                                    attachmentID: candidate.attachmentID
                                                )
                                            } catch {
                                                session.entryOperationState = .failed(error.localizedDescription)
                                            }
                                        } label: {
                                            Label("删除并写回", systemImage: "trash")
                                                .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(AndroidParityButtonStyle(tone: .destructiveOutlined))
                                        .disabled(session.keePassSourceFileURL == nil)
                                    }
                                }
                            }
                        }
                        Button {
                            do {
                                _ = try session.previewKeePassReadOnlyImportPlan()
                            } catch {
                                // AppSessionModel owns user-visible failure state.
                            }
                        } label: {
                            Label("预览导入项", systemImage: "tray.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AndroidParityButtonStyle(tone: .outlined))

                        if let plan = session.keePassReadOnlyImportPlan {
                            AndroidParityInfoRow(title: String(localized: "导入计划"), value: plan.displaySummary)
                            AndroidParityInfoRow(title: String(localized: "可预览"), value: "\(plan.candidateCount)")
                            AndroidParityInfoRow(title: String(localized: "跳过"), value: "\(plan.skippedCount)")
                            if !plan.pendingCapabilitySummary.isEmpty {
                                AndroidParityInfoRow(title: String(localized: "待解码"), value: plan.pendingCapabilitySummary)
                            }
                            ForEach(plan.candidates.prefix(3)) { candidate in
                                AndroidParityInfoRow(
                                    title: candidate.title.isEmpty ? String(localized: "未命名条目") : candidate.title,
                                    value: candidate.username.isEmpty ? candidate.groupPath : candidate.username
                                )
                            }
                            ForEach(plan.skipped.prefix(3)) { skipped in
                                AndroidParityInfoRow(
                                    title: skipped.title.isEmpty ? String(localized: "跳过条目") : skipped.title,
                                    value: skipped.reason.localizedDisplayName
                                )
                            }
                            Button {
                                do {
                                    try session.confirmKeePassReadOnlyImport(projectTitle: "KeePass")
                                } catch {
                                    // AppSessionModel owns user-visible failure state.
                                }
                            } label: {
                                Label("确认导入元数据", systemImage: "checkmark.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                            .disabled(plan.candidateCount == 0)
                        }
                    }

                    AndroidParityDivider()
                    AndroidParityInfoRow(title: String(localized: "移动端备份"), value: session.entryOperationState.label)
                    if let encryptedFileName = session.pendingAndroidEncryptedBackupFileName {
                        AndroidParityInfoRow(title: String(localized: "加密备份"), value: encryptedFileName)
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
                        AndroidParityInfoRow(title: String(localized: "备份可导入"), value: "\(preview.items.count)")
                        AndroidParityInfoRow(title: String(localized: "备份问题"), value: "\(preview.issues.count)")
                        Button {
                            do {
                                try session.confirmAndroidBackupImport(projectTitle: String(localized: "移动端备份"))
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

            AndroidParitySection(title: "OneDrive") {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                    AndroidParityInfoRow(title: String(localized: "账号"), value: session.oneDriveAuthenticationState.label)
                    AndroidParityInfoRow(title: String(localized: "文件"), value: session.cloudFileState.label)
                    if session.oneDriveAuthenticationState.isConnected {
                        Button(role: .destructive) {
                            Task {
                                try? await session.signOutFromOneDrive()
                            }
                        } label: {
                            Label("退出 OneDrive", systemImage: "rectangle.portrait.and.arrow.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AndroidParityButtonStyle(tone: .destructiveOutlined))
                        .disabled(session.oneDriveAuthenticationState.isRunning || session.cloudFileState.isRunning)
                    } else {
                        Button {
                            Task {
                                try? await session.signInToOneDrive()
                            }
                        } label: {
                            Label("登录 OneDrive", systemImage: "person.crop.circle.badge.checkmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                        .disabled(session.oneDriveAuthenticationState.isRunning)
                    }
                    Button {
                        Task {
                            try? await session.refreshCloudFileItems(provider: .oneDrive)
                        }
                    } label: {
                        Label("刷新文件", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                    .disabled(!session.oneDriveAuthenticationState.isConnected || session.cloudFileState.isRunning)
                    Button {
                        Task {
                            try? await session.uploadActiveVaultToCloud(provider: .oneDrive)
                        }
                    } label: {
                        Label("备份保险库", systemImage: "arrow.up.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                    .disabled(
                        !session.oneDriveAuthenticationState.isConnected
                            || session.vaultState != .unlocked
                            || session.cloudFileState.isRunning
                    )
                    if let items = session.cloudFileItemsByProvider[.oneDrive], !items.isEmpty {
                        AndroidParityDivider()
                        ForEach(items.prefix(3)) { item in
                            AndroidParityInfoRow(title: item.name, value: item.redactedSummary)
                            HStack(spacing: 10) {
                                Button {
                                    Task {
                                        try? await session.downloadCloudFileRestorePreview(
                                            itemID: item.id,
                                            provider: .oneDrive
                                        )
                                    }
                                } label: {
                                    Label("预览", systemImage: "arrow.down.doc")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                                Button {
                                    Task {
                                        try? await session.setCloudFileBackupItemPermanent(
                                            provider: .oneDrive,
                                            item: item,
                                            isPermanent: !item.name.contains("_permanent")
                                        )
                                    }
                                } label: {
                                    Label(item.name.contains("_permanent") ? String(localized: "取消永久") : String(localized: "永久"), systemImage: "pin")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                                Button(role: .destructive) {
                                    Task {
                                        try? await session.deleteCloudFileBackupItem(provider: .oneDrive, item: item)
                                    }
                                } label: {
                                    Image(systemName: "trash")
                                        .frame(width: 42, height: 42)
                                }
                                .buttonStyle(.plain)
                            }
                            .disabled(session.vaultState != .unlocked || session.cloudFileState.isRunning)
                        }
                    }
                }
            }

            AndroidParitySection(title: "Bitwarden") {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                    AndroidParityInfoRow(title: String(localized: "账号"), value: session.bitwardenAuthenticationState.label)
                    AndroidParityInfoRow(title: String(localized: "同步"), value: session.bitwardenSyncState.label)
                    if let preview = session.bitwardenSyncPreview {
                        AndroidParityInfoRow(title: String(localized: "远端"), value: String(localized: "\(preview.remoteItemCount) 个条目，\(preview.remoteSendCount) 个 Send"))
                        AndroidParityInfoRow(title: String(localized: "文件夹"), value: String(localized: "\(preview.remoteFolderCount) 个"))
                        AndroidParityInfoRow(title: "Premium", value: preview.premiumSummary)
                        AndroidParityInfoRow(title: String(localized: "类型"), value: preview.kindSummary)
                        AndroidParityInfoRow(title: String(localized: "附件"), value: preview.attachmentSummary)
                    }
                    if !session.bitwardenPendingMutationBatches.isEmpty {
                        AndroidParityDivider()
                        ForEach(Array(session.bitwardenPendingMutationBatches.prefix(3))) { batch in
                            AndroidParityInfoRow(title: String(localized: "待重试"), value: batch.redactedSummary)
                            AndroidParityInfoRow(title: String(localized: "最近错误"), value: batch.lastErrorSummary)
                            ForEach(Array(batch.redactedSummaries.prefix(3)).indices, id: \.self) { index in
                                AndroidParityInfoRow(
                                    title: String(localized: "变更 \(index + 1)"),
                                    value: batch.redactedSummaries[index]
                                )
                            }
                        }
                        Button {
                            Task {
                                try? await session.retryBitwardenPendingMutationQueue()
                            }
                        } label: {
                            Label("重试队列", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                        .disabled(
                            !session.bitwardenAuthenticationState.isConnected
                                || session.vaultState != .unlocked
                                || session.bitwardenSyncState.isRunning
                        )
                        Button(role: .destructive) {
                            try? session.clearBitwardenPendingMutationQueue()
                        } label: {
                            Label("清空队列", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AndroidParityButtonStyle(tone: .destructiveOutlined))
                        .disabled(session.vaultState != .unlocked || session.bitwardenSyncState.isRunning)
                    }
                    if session.bitwardenAuthenticationState.isConnected {
                        Button(role: .destructive) {
                            try? session.signOutFromBitwarden()
                        } label: {
                            Label("退出 Bitwarden", systemImage: "rectangle.portrait.and.arrow.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AndroidParityButtonStyle(tone: .destructiveOutlined))
                        .disabled(session.bitwardenSyncState.isRunning)
                    } else if session.bitwardenAuthenticationState.isTwoFactorRequired {
                        if !session.bitwardenTwoFactorProviders.isEmpty {
                            Picker("验证方式", selection: $session.bitwardenTwoFactorProviderID) {
                                ForEach(session.bitwardenTwoFactorProviders) { provider in
                                    Text(provider.displayName).tag(provider.providerID)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                        TextField("验证码", text: $session.bitwardenTwoFactorCode)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numberPad)
                            .textFieldStyle(AndroidParityTextFieldStyle())
                        Toggle("记住此设备", isOn: $session.bitwardenRememberTwoFactorDevice)
                            .tint(AndroidParityPalette.primary)
                        if session.canRequestBitwardenEmailTwoFactorCode {
                            Button {
                                Task {
                                    try? await session.requestBitwardenEmailTwoFactorCode()
                                }
                            } label: {
                                Label("发送邮件验证码", systemImage: "envelope.badge")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                            .disabled(session.bitwardenSyncState.isRunning)
                        }
                        Button {
                            Task {
                                try? await session.completeBitwardenTwoFactorSignIn()
                            }
                        } label: {
                            Label("验证并登录", systemImage: "checkmark.shield")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                        .disabled(
                            session.bitwardenSyncState.isRunning
                                || session.bitwardenTwoFactorCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                    } else {
                        TextField("服务器 URL", text: $session.bitwardenServerURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textFieldStyle(AndroidParityTextFieldStyle())
                        TextField("邮箱", text: $session.bitwardenEmail)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                            .textFieldStyle(AndroidParityTextFieldStyle())
                        SecureField("主密码", text: $session.bitwardenMasterPassword)
                            .textFieldStyle(AndroidParityTextFieldStyle())
                        Button {
                            Task {
                                try? await session.signInToBitwarden()
                            }
                        } label: {
                            Label("登录 Bitwarden", systemImage: "key")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                        .disabled(
                            session.bitwardenSyncState.isRunning
                                || session.bitwardenEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || session.bitwardenMasterPassword.isEmpty
                        )
                        Button {
                            _ = try? session.restoreBitwardenAuthenticationSession()
                        } label: {
                            Label("恢复 Bitwarden 登录", systemImage: "person.crop.circle.badge.checkmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                    }
                    Button {
                        Task {
                            try? await session.previewBitwardenSync()
                        }
                    } label: {
                        Label("预览同步", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                    .disabled(
                        !session.bitwardenAuthenticationState.isConnected
                            || session.vaultState != .unlocked
                            || session.bitwardenSyncState.isRunning
                    )
                    Button {
                        Task {
                            try? await session.syncBitwardenVaultData(projectTitle: "Bitwarden")
                        }
                    } label: {
                        Label("同步到本地", systemImage: "arrow.down.to.line.compact")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                    .disabled(
                        !session.bitwardenAuthenticationState.isConnected
                            || session.vaultState != .unlocked
                            || session.bitwardenSyncState.isRunning
                    )
                    Button {
                        Task {
                            try? await session.pushLocalBitwardenChanges()
                        }
                    } label: {
                        Label("推送本地变更", systemImage: "arrow.up.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                    .disabled(
                        !session.bitwardenAuthenticationState.isConnected
                            || session.vaultState != .unlocked
                            || session.bitwardenSyncState.isRunning
                    )
                }
            }

            AndroidParitySection(title: String(localized: "接收 Bitwarden Send")) {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                    Text("粘贴别人发来的 Send 链接即可查看内容，无需登录。")
                        .font(.footnote)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                    TextField("Send 链接", text: $session.bitwardenReceiveLinkInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textFieldStyle(AndroidParityTextFieldStyle())
                    SecureField("访问密码（如无则留空）", text: $session.bitwardenReceivePassword)
                        .textFieldStyle(AndroidParityTextFieldStyle())
                    AndroidParityInfoRow(title: String(localized: "状态"), value: session.bitwardenReceiveState.label)
                    Button {
                        Task {
                            try? await session.receiveBitwardenSend(
                                linkInput: session.bitwardenReceiveLinkInput,
                                password: session.bitwardenReceivePassword
                            )
                        }
                    } label: {
                        Label("获取内容", systemImage: "tray.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                    .disabled(
                        session.bitwardenReceiveState.isRunning
                            || session.bitwardenReceiveLinkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    if let received = session.bitwardenReceivedSend {
                        AndroidParityDivider()
                        AndroidParityInfoRow(title: String(localized: "标题"), value: received.title.isEmpty ? String(localized: "（无标题）") : received.title)
                        if !received.expiresAt.isEmpty {
                            AndroidParityInfoRow(title: String(localized: "过期时间"), value: received.expiresAt)
                        }
                        AndroidParityInfoRow(title: String(localized: "最大查看"), value: String(localized: "\(received.maxViews) 次"))
                        if let remaining = received.remainingViews {
                            AndroidParityInfoRow(title: String(localized: "剩余查看"), value: String(localized: "\(remaining) 次"))
                        }
                        Text(received.text)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(AndroidParityPalette.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        if let notes = received.notes, !notes.isEmpty {
                            Text(notes)
                                .font(.caption)
                                .foregroundStyle(AndroidParityPalette.textSecondary)
                        }
                        Button {
                            session.clearBitwardenReceiveResult()
                        } label: {
                            Label("清除", systemImage: "xmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
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
                    AndroidParityInfoRow(title: String(localized: "状态"), value: session.webDAVBackupState.label)
                    AndroidParityInfoRow(title: String(localized: "后台备份"), value: session.webDAVBackgroundBackupSchedulerState.label)
                    Toggle("后台自动备份", isOn: Binding(
                        get: { session.webDAVBackgroundBackupEnabled },
                        set: { enabled in
                            if enabled {
                                Task { await session.scheduleBackgroundWebDAVBackup() }
                            } else {
                                session.disableBackgroundWebDAVBackup()
                            }
                        }
                    ))
                    .font(.headline.weight(.heavy))
                    .tint(AndroidParityPalette.primary)
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
                    Button {
                        Task {
                            try? await session.refreshWebDAVBackupItems()
                        }
                    } label: {
                        Label("刷新备份列表", systemImage: "list.bullet.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                    .disabled(session.vaultState != .unlocked || session.webDAVBackupState.isRunning)
                    Stepper(value: $session.webDAVBackupRetentionDays, in: 1...365) {
                        Text("保留 \(session.webDAVBackupRetentionDays) 天")
                            .font(.subheadline.weight(.semibold))
                    }
                    Button(role: .destructive) {
                        Task {
                            try? await session.cleanupExpiredWebDAVBackups()
                        }
                    } label: {
                        Label("清理过期备份", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .destructiveOutlined))
                    .disabled(session.webDAVBackupItems.isEmpty || session.webDAVBackupState.isRunning)
                    if !session.webDAVBackupItems.isEmpty {
                        AndroidParityDivider()
                        ForEach(session.webDAVBackupItems.prefix(8)) { item in
                            AndroidParityInfoRow(
                                title: item.fileName,
                                value: item.isPermanent ? String(localized: "永久 · \(item.byteCount) 字节") : String(localized: "\(item.byteCount) 字节")
                            )
                            HStack(spacing: 10) {
                                Button {
                                    session.webDAVRemoteFileName = item.fileName
                                    Task { try? await session.downloadWebDAVRestorePreview() }
                                } label: {
                                    Label("预览", systemImage: "arrow.down.doc")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                                Button {
                                    Task {
                                        try? await session.setWebDAVBackupItemPermanent(item, isPermanent: !item.isPermanent)
                                    }
                                } label: {
                                    Label(item.isPermanent ? String(localized: "取消永久") : String(localized: "永久"), systemImage: "pin")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                                Button(role: .destructive) {
                                    Task { try? await session.deleteWebDAVBackupItem(item) }
                                } label: {
                                    Image(systemName: "trash")
                                        .frame(width: 42, height: 42)
                                }
                                .buttonStyle(.plain)
                            }
                            .disabled(session.webDAVBackupState.isRunning)
                        }
                    }
                    if let preview = session.webDAVRestorePreview {
                        AndroidParityDivider()
                        AndroidParityInfoRow(title: String(localized: "恢复文件"), value: preview.fileName)
                        AndroidParityInfoRow(title: String(localized: "字节"), value: "\(preview.byteCount)")
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

            AndroidParitySection(title: "NFC 银行卡诊断") {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.6)) {
                    NavigationLink {
                        NFCBankCardProbeView()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "wave.3.right")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(AndroidParityPalette.primary)
                                .frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("贴卡读取诊断")
                                    .font(.subheadline.weight(.heavy))
                                    .foregroundStyle(AndroidParityPalette.textPrimary)
                                Text("技术验证 · 默认关闭 · 不读取银行卡敏感数据")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AndroidParityPalette.textSecondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(AndroidParityPalette.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
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
            defaultFilename: "monica-mobile-backup.zip"
        ) { result in
            if case .failure(let error) = result {
                session.entryOperationState = .failed(error.localizedDescription)
            }
        }
        .fileImporter(
            isPresented: $isKeePassImporterPresented,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let fileURL = urls.first else {
                    return
                }
                do {
                    _ = try session.previewKeePassImport(from: fileURL)
                } catch {
                    session.entryOperationState = .failed(error.localizedDescription)
                }
            case .failure(let error):
                session.entryOperationState = .failed(error.localizedDescription)
            }
        }
        .fileImporter(
            isPresented: $isKeePassKeyFileImporterPresented,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let fileURL = urls.first else {
                    return
                }
                do {
                    try session.importKeePassKeyFile(from: fileURL)
                } catch {
                    session.entryOperationState = .failed(error.localizedDescription)
                }
            case .failure(let error):
                session.entryOperationState = .failed(error.localizedDescription)
            }
        }
        .fileImporter(
            isPresented: $isKeePassAttachmentReplacementImporterPresented,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            defer {
                pendingKeePassAttachmentReplacementEntryID = nil
                pendingKeePassAttachmentReplacementAttachmentID = nil
            }
            switch result {
            case .success(let urls):
                guard let fileURL = urls.first else {
                    return
                }
                replacePendingKeePassAttachment(with: fileURL)
            case .failure(let error):
                session.entryOperationState = .failed(error.localizedDescription)
            }
        }
        .fileImporter(
            isPresented: $isKeePassAttachmentAdditionImporterPresented,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            defer {
                pendingKeePassAttachmentAdditionEntryID = nil
            }
            switch result {
            case .success(let urls):
                guard let fileURL = urls.first else {
                    return
                }
                addPendingKeePassAttachment(from: fileURL)
            case .failure(let error):
                session.entryOperationState = .failed(error.localizedDescription)
            }
        }
        .fileImporter(
            isPresented: $isSteamAuthenticatorImporterPresented,
            allowedContentTypes: [.json, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let fileURL = urls.first else {
                    return
                }
                importSteamAuthenticator(from: fileURL)
            case .failure(let error):
                session.entryOperationState = .failed(error.localizedDescription)
            }
        }
        .alert("移动端加密备份", isPresented: $isAndroidBackupPasswordPromptPresented) {
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
            Text("请输入导出该移动端备份时设置的密码。密码只在本次解密中使用。")
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func replacePendingKeePassAttachment(with fileURL: URL) {
        guard let entryID = pendingKeePassAttachmentReplacementEntryID,
              let attachmentID = pendingKeePassAttachmentReplacementAttachmentID else {
            session.entryOperationState = .failed(String(localized: "请先选择要替换的 KeePass 附件。"))
            return
        }
        do {
            _ = try session.replaceKeePassReadOnlyAttachmentContentFromFileAndWriteBack(
                entryID: entryID,
                attachmentID: attachmentID,
                fileURL: fileURL
            )
        } catch {
            session.entryOperationState = .failed(error.localizedDescription)
        }
    }

    private func addPendingKeePassAttachment(from fileURL: URL) {
        guard let entryID = pendingKeePassAttachmentAdditionEntryID else {
            session.entryOperationState = .failed(String(localized: "请先选择要添加附件的 KeePass 条目。"))
            return
        }
        do {
            _ = try session.addKeePassReadOnlyAttachmentContentFromFileAndWriteBack(
                entryID: entryID,
                fileURL: fileURL
            )
        } catch {
            session.entryOperationState = .failed(error.localizedDescription)
        }
    }

    private func importSteamAuthenticator(from fileURL: URL) {
        let didAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try session.importSteamAuthenticator(Data(contentsOf: fileURL))
        } catch {
            // AppSessionModel owns the redacted user-visible failure state.
        }
    }

    private func addAutoFillBlockedField() {
        var fields = session.autoFillPolicy.blockedFields
        fields.append(autoFillBlockedFieldInput)
        session.updateAutoFillPolicy(
            blockedFields: fields,
            blockedSaveTargets: session.autoFillPolicy.blockedSaveTargets
        )
        autoFillBlockedFieldInput = ""
    }

    private func addAutoFillBlockedSaveTarget() {
        var targets = session.autoFillPolicy.blockedSaveTargets
        targets.append(autoFillBlockedSaveTargetInput)
        session.updateAutoFillPolicy(
            blockedFields: session.autoFillPolicy.blockedFields,
            blockedSaveTargets: targets
        )
        autoFillBlockedSaveTargetInput = ""
    }

    private func clearAutoFillPolicy() {
        session.updateAutoFillPolicy(blockedFields: [], blockedSaveTargets: [])
        autoFillBlockedFieldInput = ""
        autoFillBlockedSaveTargetInput = ""
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
        session.canUseBiometricUnlockHardware ? String(localized: "未启用") : String(localized: "不可用")
    }

    private func keePassPreviewStatusText(_ status: KeePassImportStatus) -> String {
        switch status {
        case .requiresCredentials:
            return String(localized: "等待密码或密钥文件")
        case .readyToUnlock:
            return String(localized: "等待解锁")
        case .unsupported:
            return String(localized: "无法导入")
        case .unknown:
            return String(localized: "无法识别")
        }
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
                .font(AndroidParityTypography.smallIcon(weight: .semibold))
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

private extension AppOperationTimelineAction {
    static let allCasesForSettings: [AppOperationTimelineAction] = [
        .created,
        .updated,
        .deleted,
        .restored,
        .moved,
        .viewed,
        .backedUp,
        .restoredBackup,
        .cleanedUp,
        .synced,
        .blocked
    ]
}

struct AppQuickSetupView: View {
    @Bindable var session: AppSessionModel

    var body: some View {
        AndroidParityScreen {
            AndroidParitySection(title: String(localized: "快速设置")) {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.6)) {
                    ForEach(session.quickSetupRows) { row in
                        AppCapabilityRowView(row: row)
                        if row.id != session.quickSetupRows.last?.id {
                            AndroidParityDivider()
                        }
                    }
                    Button {
                        session.completeQuickSetup()
                    } label: {
                        Label("完成快速设置", systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                }
            }
        }
    }
}

struct AppExtensionsView: View {
    @Bindable var session: AppSessionModel

    var body: some View {
        AndroidParityScreen {
            AndroidParitySection(title: String(localized: "扩展功能")) {
                AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.6)) {
                    ForEach(session.extensionCapabilityRows) { row in
                        AppCapabilityRowView(row: row)
                        if row.id != session.extensionCapabilityRows.last?.id {
                            AndroidParityDivider()
                        }
                    }
                }
            }
        }
    }
}

private struct AppCapabilityRowView: View {
    let row: AppExtensionCapabilityRow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.systemImage)
                .font(.headline.weight(.bold))
                .foregroundStyle(AndroidParityPalette.primary)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(row.title)
                        .font(.subheadline.weight(.heavy))
                    Spacer(minLength: 8)
                    Text(row.value)
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(AndroidParityPalette.primary)
                }
                Text(row.detail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }
    }
}

private struct AndroidParitySecurityCenterRow: View {
    let row: AppSecurityCenterRow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.systemImage)
                .font(AndroidParityTypography.smallIcon(weight: .semibold))
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
                .font(AndroidParityTypography.smallIcon(weight: .semibold))
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
                .font(AndroidParityTypography.smallIcon(weight: .semibold))
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
                .font(AndroidParityTypography.smallIcon(weight: .semibold))
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
