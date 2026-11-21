//
//  AppSessionModel.swift
//  Monica
//
//  应用会话模型：会话状态、依赖注入与各领域操作（按领域拆分见后续 PR）。
//

import MonicaCore
import MonicaMDBX
import MonicaSecurity
import MonicaStorage
import MonicaSync
import MonicaWidgetShared
import AVFoundation
import AuthenticationServices
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import Foundation
import LocalAuthentication
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications
import BackgroundTasks

@MainActor
@Observable
final class AppSessionModel {
    static let securityQuestionOptions: [SecurityQuestionOption] = [
        .init(id: 42, text: String(localized: "你喜欢什么奥特曼？")),
        .init(id: 1, text: String(localized: "您第一只宠物的名字是什么？")),
        .init(id: 2, text: String(localized: "您母亲的娘家姓是什么？")),
        .init(id: 3, text: String(localized: "您出生在哪个城市？")),
        .init(id: 4, text: String(localized: "您的小学校名是什么？")),
        .init(id: 5, text: String(localized: "您最喜欢的电影是什么？")),
        .init(id: 6, text: String(localized: "您的第一辆汽车是什么型号？")),
        .init(id: 7, text: String(localized: "您童年最好朋友的名字是什么？")),
        .init(id: 8, text: String(localized: "您小时候最喜欢的食物是什么？")),
        .init(id: 9, text: String(localized: "您成长的街道名称是什么？")),
        .init(id: 10, text: String(localized: "您高中的吉祥物是什么？"))
    ]

    var selectedTab: MonicaAppTab = .passwords
    /// 控制中心在锁定态点击后暂存的目标页面，解锁并进入主界面后再消费。
    var pendingControlPage: MonicaControlPage?
    var passwordModule: PasswordModule = .login
    var passwordOtherKind: UnifiedVaultItemKind = .sshKey
    var vaultState: VaultState = .locked

    /// 生成历史的 Vault 作用域（#24）：只有解锁后才暴露 vaultID。
    ///
    /// 生成历史按 Vault 隔离加密存放，锁库或未打开 Vault 时为 nil，
    /// 调用方不应再尝试读取历史。
    var activeVaultHistoryScope: String? {
        guard vaultState == .unlocked else {
            return nil
        }
        return activeVaultSession?.handle.vaultID
    }
    var vaultOperationState: VaultOperationState = .idle
    var vaultName = ""
    var vaultPassword = ""
    var firstTimePasswordSetupStep: FirstTimePasswordSetupStep = .enterPassword
    var activeVaultName: String?
    var entryOperationState: EntryOperationState = .idle
    var loginTitle = ""
    var loginUsername = ""
    var loginPassword = ""
    var loginURL = ""
    /// 新建登录条目的图标（`sf:…` / `catalog:…` 稳定 id），`nil` 表示使用默认图标。
    var loginIcon: String?
    // issue #16：多 URL、应用绑定与备注（历史只从「修改密码」开始记录）。
    var loginAdditionalURLs: [String] = []
    var loginAppBundleID = ""
    var loginAppName = ""
    var loginNotes = ""
    var loginSearchQuery = ""
    var showFavoriteLoginEntriesOnly = false
    var isLoginStackedGroupModeEnabled = false
    var loginEntries: [LocalLoginEntry] = []
    var deletedLoginEntries: [LocalLoginEntry] = []
    var breachedPasswordSHA256Fingerprints: Set<String> = []
    var operationTimelineEvents: [AppOperationTimelineEvent] = []
    var operationTimelineFilterKind: UnifiedVaultItemKind?
    var operationTimelineFilterAction: AppOperationTimelineAction?
    private var ignoredDuplicateLoginKeys: Set<DuplicateLoginEntryKey> = []
    private var lastDuplicateLoginMergeUndo: AppDuplicateLoginMergeUndo?
    private var nextOperationTimelineEventSequence = 0
    var editingLoginEntryID: String?
    var editingLoginTitle = ""
    var editingLoginUsername = ""
    var editingLoginPassword = ""
    var editingLoginURL = ""
    var editingLoginFavorite = false
    /// 编辑中の登录条目图标稳定 id。
    var editingLoginIcon: String?
    var editingLoginAdditionalURLs: [String] = []
    var editingLoginAppBundleID = ""
    var editingLoginAppName = ""
    var editingLoginNotes = ""
    var editingLoginPasswordHistory: [LocalLoginPasswordHistoryEntry] = []
    var noteTitle = ""
    var noteBody = ""
    var noteSearchQuery = ""
    var showFavoriteNoteEntriesOnly = false
    var noteEntries: [LocalNoteEntry] = []
    var deletedNoteEntries: [LocalNoteEntry] = []
    var editingNoteEntryID: String?
    var editingNoteTitle = ""
    var editingNoteBody = ""
    var editingNoteFavorite = false
    var totpTitle = ""
    var totpSecret = ""
    var totpIssuer = ""
    var totpAccountName = ""
    var totpPeriod: UInt32 = 30
    var totpDigits: UInt32 = 6
    var totpAlgorithm = "SHA1"
    var totpOtpType = OtpType.totp.rawValue
    var totpCounter: UInt64 = 0
    var totpIconName = ""
    var totpImportURI = ""
    var totpSearchQuery = ""
    var showFavoriteTotpEntriesOnly = false
    var totpEntries: [LocalTotpEntry] = []
    var deletedTotpEntries: [LocalTotpEntry] = []
    var editingTotpEntryID: String?
    var editingTotpTitle = ""
    var editingTotpSecret = ""
    var editingTotpIssuer = ""
    var editingTotpAccountName = ""
    var editingTotpPeriod: UInt32 = 30
    var editingTotpDigits: UInt32 = 6
    var editingTotpAlgorithm = "SHA1"
    var editingTotpOtpType = OtpType.totp.rawValue
    var editingTotpCounter: UInt64 = 0
    var editingTotpIconName = ""
    var editingTotpFavorite = false
    var cardTitle = ""
    var cardholderName = ""
    var cardNumber = ""
    var cardExpiryMonth = ""
    var cardExpiryYear = ""
    var cardCVV = ""
    var cardIssuer = ""
    var cardNetwork = ""
    var cardNotes = ""
    var cardSearchQuery = ""
    var showFavoriteCardEntriesOnly = false
    var cardEntries: [LocalCardEntry] = []
    var deletedCardEntries: [LocalCardEntry] = []
    var editingCardEntryID: String?
    var editingCardTitle = ""
    var editingCardholderName = ""
    var editingCardNumber = ""
    var editingCardExpiryMonth = ""
    var editingCardExpiryYear = ""
    var editingCardCVV = ""
    var editingCardIssuer = ""
    var editingCardNetwork = ""
    var editingCardNotes = ""
    var editingCardFavorite = false
    var identityTitle = ""
    var identityDocumentType = ""
    var identityFullName = ""
    var identityDocumentNumber = ""
    var identityIssuer = ""
    var identityCountry = ""
    var identityIssueDate = ""
    var identityExpiryDate = ""
    var identityNotes = ""
    var identitySearchQuery = ""
    var showFavoriteIdentityEntriesOnly = false
    var identityEntries: [LocalIdentityEntry] = []
    var deletedIdentityEntries: [LocalIdentityEntry] = []
    var editingIdentityEntryID: String?
    var editingIdentityTitle = ""
    var editingIdentityDocumentType = ""
    var editingIdentityFullName = ""
    var editingIdentityDocumentNumber = ""
    var editingIdentityIssuer = ""
    var editingIdentityCountry = ""
    var editingIdentityIssueDate = ""
    var editingIdentityExpiryDate = ""
    var editingIdentityNotes = ""
    var editingIdentityFavorite = false
    var passkeyTitle = ""
    var passkeyRelyingPartyID = ""
    var passkeyUsername = ""
    var passkeyUserHandle = ""
    var passkeyCredentialID = ""
    var passkeyPublicKeyCOSE = ""
    var passkeyPrivateKeyReference = ""
    var passkeyNotes = ""
    var passkeySearchQuery = ""
    var showFavoritePasskeyEntriesOnly = false
    var passkeyEntries: [LocalPasskeyEntry] = []
    var deletedPasskeyEntries: [LocalPasskeyEntry] = []
    var editingPasskeyEntryID: String?
    var editingPasskeyTitle = ""
    var editingPasskeyRelyingPartyID = ""
    var editingPasskeyUsername = ""
    var editingPasskeyUserHandle = ""
    var editingPasskeyCredentialID = ""
    var editingPasskeyPublicKeyCOSE = ""
    var editingPasskeyPrivateKeyReference = ""
    var editingPasskeyNotes = ""
    var editingPasskeyFavorite = false
    var sshKeyEntries: [LocalSshKeyEntry] = []
    var deletedSshKeyEntries: [LocalSshKeyEntry] = []
    var sshKeyTitle = ""
    var sshKeyUsername = ""
    var sshKeyHost = ""
    var sshKeyPublicKey = ""
    var sshKeyPrivateKeyReference = ""
    var sshKeyPassphraseHint = ""
    var sshKeyNotes = ""
    var sshKeySearchQuery = ""
    var showFavoriteSshKeyEntriesOnly = false
    var editingSshKeyEntryID: String?
    var editingSshKeyTitle = ""
    var editingSshKeyUsername = ""
    var editingSshKeyHost = ""
    var editingSshKeyPublicKey = ""
    var editingSshKeyPrivateKeyReference = ""
    var editingSshKeyPassphraseHint = ""
    var editingSshKeyNotes = ""
    var editingSshKeyFavorite = false
    var apiTokenEntries: [LocalApiTokenEntry] = []
    var deletedApiTokenEntries: [LocalApiTokenEntry] = []
    var apiTokenTitle = ""
    var apiTokenIssuer = ""
    var apiTokenAccountName = ""
    var apiTokenToken = ""
    var apiTokenScopes = ""
    var apiTokenExpiresAt = ""
    var apiTokenNotes = ""
    var apiTokenSearchQuery = ""
    var showFavoriteApiTokenEntriesOnly = false
    var editingApiTokenEntryID: String?
    var editingApiTokenTitle = ""
    var editingApiTokenIssuer = ""
    var editingApiTokenAccountName = ""
    var editingApiTokenToken = ""
    var editingApiTokenScopes = ""
    var editingApiTokenExpiresAt = ""
    var editingApiTokenNotes = ""
    var editingApiTokenFavorite = false
    var wifiEntries: [LocalWifiEntry] = []
    var deletedWifiEntries: [LocalWifiEntry] = []
    var wifiTitle = ""
    var wifiSSID = ""
    var wifiSecurityType = "WPA2"
    var wifiPassword = ""
    var wifiHidden = false
    var wifiNotes = ""
    var wifiSearchQuery = ""
    var showFavoriteWifiEntriesOnly = false
    var editingWifiEntryID: String?
    var editingWifiTitle = ""
    var editingWifiSSID = ""
    var editingWifiSecurityType = "WPA2"
    var editingWifiPassword = ""
    var editingWifiHidden = false
    var editingWifiNotes = ""
    var editingWifiFavorite = false
    var ssoEntries: [LocalSSOEntry] = []
    var deletedSSOEntries: [LocalSSOEntry] = []
    var ssoTitle = ""
    var ssoProvider: SSOProvider = .custom
    var ssoProviderName = ""
    var ssoIssuer = ""
    var ssoAccountName = ""
    var ssoLoginURL = ""
    var ssoLinkedLoginEntryID = ""
    var ssoNotes = ""
    var ssoSecret = ""
    var ssoSearchQuery = ""
    var showFavoriteSSOEntriesOnly = false
    var editingSSOEntryID: String?
    var editingSSOTitle = ""
    var editingSSOProvider: SSOProvider = .custom
    var editingSSOProviderName = ""
    var editingSSOIssuer = ""
    var editingSSOAccountName = ""
    var editingSSOLoginURL = ""
    var editingSSOLinkedLoginEntryID = ""
    var editingSSONotes = ""
    var editingSSOSecret = ""
    var editingSSOFavorite = false
    var sendEntries: [LocalSendEntry] = []
    var deletedSendEntries: [LocalSendEntry] = []
    var sendCreateType: SendCreateType = .text
    var sendTitle = ""
    var sendBody = ""
    var sendFileName = ""
    var sendFileContent: Data?
    var sendFileMediaType = "application/octet-stream"
    var sendExpiresAt = ""
    var sendMaxViews = 1
    var sendNotes = ""
    var sendPassword = ""
    var sendHideEmail = false
    var sendSearchQuery = ""
    var showFavoriteSendEntriesOnly = false
    /// 刚创建的 Bitwarden 文本 Send 链接（只在创建成功后短暂保留，供复制）。
    var bitwardenSendShareLink: String?
    /// 接收端：用户粘贴的 Send 链接与访问密码。
    var bitwardenReceiveLinkInput = ""
    var bitwardenReceivePassword = ""
    var bitwardenReceiveState: AppBitwardenReceiveState = .idle
    /// 接收成功后解密出的内容。
    var bitwardenReceivedSend: BitwardenReceivedSend?
    var editingSendEntryID: String?
    var editingSendTitle = ""
    var editingSendBody = ""
    var editingSendExpiresAt = ""
    var editingSendMaxViews = 1
    var editingSendNotes = ""
    var editingSendFavorite = false
    var attachmentEntries: [LocalAttachmentMetadata] = []
    var deletedAttachmentEntries: [LocalAttachmentMetadata] = []
    var attachmentSearchQuery = ""
    var attachmentQuickLookPreviewURL: URL?
    var vaultProjects: [LocalVaultProject] = []
    var selectedVaultQuickFilterID = "all"
    var selectedVaultBatchItemIDs: Set<String> = []
    private var vaultBatchSelectionKind: UnifiedVaultItemKind?
    var vaultDisplayPreferences: VaultDisplayPreferences
    var appearancePreferences: AppAppearancePreferences
    var vaultLayoutPreferences: VaultLayoutPreferences
    /// #58：剪贴板自动清除时长与敏感预览掩码偏好。
    var sensitiveClipboardTTL: SensitiveClipboardTTL
    var sensitivePreviewPreferences: SensitivePreviewPreferences
    /// 本次解锁会话内的「显示敏感字段」状态；锁库立即清空，不持久化。
    var sensitivePreviewSession = SensitivePreviewSession()
    var sensitivePasteboardHasPendingAutoClear = false
    var mdbxVerificationState: MDBXVerificationState = .idle
    var isPrivacyShieldVisible = false
    var autoLockPolicy: AppAutoLockPolicy
    var autoFillIndexState: AutoFillIndexState = .idle
    let autoFillDomainRules = AutoFillDomainRuleController()
    var notificationPermissionState: AppPermissionStatusRow.State = .checkable
    var systemAutoFillProviderState: AppPermissionStatusRow.State = .checkable
    var autoFillPolicy: AppAutoFillPolicy
    var vaultKeychainState: VaultKeychainState = .idle
    private var plusEntitlementSnapshot = AppPlusEntitlementSnapshot()
    var plusActivationState: PlusActivationState = .idle
    var webDAVBaseURL = ""
    var webDAVUsername = ""
    var webDAVPassword = ""
    var webDAVRemoteFileName = ""
    var webDAVRestoreVaultPassword = ""
    var webDAVBackupState: WebDAVBackupState = .idle
    var webDAVRestorePreview: WebDAVRestorePreview?
    var webDAVBackupItems: [WebDAVBackupItem] = []
    var webDAVBackupRetentionDays = 30
    var webDAVBackgroundBackupEnabled = false
    var webDAVBackgroundBackupSchedulerState: AppBackgroundBackupSchedulerState = .idle
    var cloudFileState: CloudFileState = .idle
    var cloudFileItemsByProvider: [CloudFileProviderKind: [CloudFileItem]] = [:]
    var cloudFileRestorePreview: AppCloudFileRestorePreview?
    var cloudFileSelectedBackupItemByProvider: [CloudFileProviderKind: CloudFileItem] = [:]
    var oneDriveAuthenticationState: OneDriveAuthenticationState = .disconnected
    var oneDriveAccounts: [AppOneDriveAuthenticationSession] = []
    var currentOneDriveAccountIdentifier = ""
    var oneDriveBackupPreferences = CloudFileBackupPreferences()
    var oneDriveBackupDirectoryState: AppOneDriveBackupDirectoryState = .unknown
    var oneDriveDefaultLocationFiles: [CloudFileItem] = []
    var oneDriveBackupNotice: String?
    var bitwardenServerURL = "https://vault.bitwarden.com"
    var bitwardenEmail = ""
    var bitwardenMasterPassword = ""
    var bitwardenTwoFactorCode = ""
    var bitwardenTwoFactorProviderID = 0
    var bitwardenRememberTwoFactorDevice = false
    var bitwardenAuthenticationState: BitwardenAuthenticationState = .disconnected
    var bitwardenSyncState: BitwardenSyncState = .idle
    var bitwardenSyncPreview: AppBitwardenSyncPreview?
    var bitwardenPendingMutationBatches: [AppBitwardenPendingMutationBatch] = []
    var csvImportPreview: CSVImportPreview?
    var credentialExchange = AppCredentialExchangeState()
    var androidBackupImportPreview: AndroidBackupImportPreview?
    var keePassImportPreview: KeePassImportPreview?
    var keePassReadOnlySnapshot: KeePassReadOnlySnapshot?
    var keePassReadOnlyImportPlan: KeePassReadOnlyImportPlan?
    var keePassPendingDatabaseData: Data?
    var keePassPendingDatabaseName: String?
    var keePassSourceFileURL: URL?
    var keePassCloudFileSource: AppKeePassCloudFileSource?
    var keePassUnlockPassword = ""
    var keePassKeyFileData: Data?
    var keePassKeyFileName = ""
    var keePassLastMetadataImportReferences: [AppKeePassImportedEntryReference] = []
    var androidBackupDecryptPassword = ""
    var pendingAndroidEncryptedBackupFileName: String?
    var presentedEditorMode: VaultItemEditorMode?
    var presentedDetailRoute: VaultItemRoute?
    /// 全局搜索索引：只存在于解锁会话内存，锁库即清空（不落盘）。
    let vaultSearch = VaultSearchSession()
    /// 索引代次：索引重建或查看记录变化时自增，驱动搜索界面重新查询。
    var vaultSearchRevision = 0
    /// 全局搜索界面是否以导航 push 的方式展示（不新增底部 Tab）。
    var isGlobalSearchPresented = false
    // issue #15：自定义字段 / 条目关联的侧表状态（编辑器与详情各自一份，互不共享）。
    var presentedItemExtrasItemID: String?
    var presentedCustomFields: [VaultCustomField] = []
    var presentedRelations: [VaultItemRelation] = []
    var presentedDetailExtras: VaultItemExtras?
    var isQuickSetupPresented = false
    var isExtensionsPresented = false
    var expandedToolbarAction: AndroidParityToolbarAction?
    var securityQuestion1ID = AppSessionModel.securityQuestionOptions[0].id
    var securityQuestion2ID = AppSessionModel.securityQuestionOptions[1].id
    var securityAnswer1 = ""
    var securityAnswer2 = ""
    var securityQuestionState: VaultOperationState = .idle
    var currentMasterPassword = ""
    var newMasterPassword = ""
    var confirmNewMasterPassword = ""
    var masterPasswordChangeState: VaultOperationState = .idle
    private var isChangingMasterPassword = false
    var forgotPasswordRecoveryStep: ForgotPasswordRecoveryStep = .none
    var forgotPasswordQuestion1Text = ""
    var forgotPasswordQuestion2Text = ""
    var forgotPasswordAnswer1 = ""
    var forgotPasswordAnswer2 = ""
    var forgotPasswordAttemptCount = 0
    var forgotPasswordLockoutRemaining: TimeInterval = 0
    var isVerifyingForgotPasswordAnswers = false
    var forgotPasswordNewPassword = ""
    var forgotPasswordConfirmPassword = ""
    var isBiometricUnlockEnabled: Bool {
        didSet {
            biometricUnlockPreferenceStore.saveIsEnabled(isBiometricUnlockEnabled)
        }
    }
    private var downloadedWebDAVRestoreBackup: WebDAVDownloadedBackup?
    private var downloadedCloudFileRestore: CloudFileDownload?
    private let oneDriveBackupPreferencesStore: any AppOneDriveBackupPreferencesStore
    private let oneDriveNow: () -> Date

    private let vaultRepository: LocalVaultRepository
    private let vaultKeychainService: (any AppVaultKeychainService)?
    private let vaultWrappedKeyProvider: ((LocalVaultSession) throws -> WrappedVaultKey)?
    private let rememberedVaultStore: any RememberedVaultStore
    private let biometricUnlockPreferenceStore: any BiometricUnlockPreferenceStore
    private let vaultDisplayPreferenceStore: any VaultDisplayPreferenceStore
    private let appearancePreferenceStore: any AppAppearancePreferenceStore
    private let vaultLayoutPreferenceStore: any VaultLayoutPreferenceStore
    private let sensitivePreviewPreferenceStore: any SensitivePreviewPreferenceStore
    private let sensitiveClipboardPreferenceStore: any SensitiveClipboardPreferenceStore
    private let sensitivePasteboard: MonicaSensitivePasteboard
    @ObservationIgnored private var sensitivePasteboardExpiryTask: Task<Void, Never>?
    private let biometricUnlockAuthorizer: any BiometricUnlockAuthorizer
    private let biometricCapabilityProvider: () -> BiometricUnlockCapability
    private let securityQuestionStore: any SecurityQuestionRecoveryStore
    private let securityQuestionVerifier: SecurityQuestionAnswerVerifier
    private let securityQuestionThrottle: SecurityQuestionVerificationThrottle
    private let securityQuestionClock: () -> Date
    private let webDAVBackupService: any AppWebDAVBackupService
    private let operationTimelineStore: any AppOperationTimelineStore
    private let quickSetupStateStore: any AppQuickSetupStateStore
    private let backgroundBackupScheduler: any AppBackgroundBackupScheduler
    private let cloudFileProviders: [CloudFileProviderKind: any CloudFileProvider]
    private let oneDriveAuthenticationService: (any AppOneDriveAuthenticationService)?
    private let bitwardenPasswordAuthenticationService: (any AppBitwardenPasswordAuthenticationService)?
    private let bitwardenSyncProvider: (any BitwardenSyncProvider)?
    private let bitwardenAuthenticationSessionStore: any BitwardenAuthenticationSessionStore
    private let bitwardenVaultKeyStore: (any BitwardenVaultKeyStore)?
    private let bitwardenSendSyncStateStore: any AppBitwardenSendSyncStateStore
    private let bitwardenFolderSyncStateStore: any AppBitwardenFolderSyncStateStore
    private let bitwardenItemSyncStateStore: any AppBitwardenItemSyncStateStore
    private let bitwardenPendingMutationQueueStore: any AppBitwardenPendingMutationQueueStore
    private let autoFillIndexStore: (any AutoFillEncryptedIndexStore)?
    private let autoFillCredentialSecretStore: (any AutoFillCredentialSecretStore)?
    private let autoFillCredentialIdentityStore: (any AppAutoFillCredentialIdentityStore)?
    private let autoFillPolicyStore: any AppAutoFillPolicyStore
    private let autoFillIndexKeyMaterialProvider: ((String) throws -> AutoFillIndexKeyMaterial)?
    private let autoFillIndexCodec: AutoFillEncryptedIndexCodec
    private let autoFillCredentialSecretCodec: AutoFillCredentialSecretCodec
    private let plusResourceUnlockService: (any AppPlusResourceUnlockService)?
    private let plusEntitlementStore: any AppPlusEntitlementStore
    private let androidBackupAttachmentBlobStore: any AndroidBackupAttachmentBlobStore
    private let keePassDatabaseReader: any KeePassDatabaseReader
    private let keePassKdbxFileWritebackService: any AppKeePassKdbxFileWritebackService
    private let keePassKdbx3WritebackCoordinator: any KeePassKdbx3WritebackCoordinator
    private let keePassKdbx4WritebackCoordinator: any KeePassKdbx4WritebackCoordinator
    private let widgetSnapshotStore: AppWidgetSnapshotFileStore?
    private let shortcutSnapshotStore: AppShortcutSnapshotFileStore?
    private let widgetReloadScheduler: (any MonicaWidgetReloadScheduling)?
    private(set) var widgetSnapshotSyncError: String?
    private let controlNavigationDefaults: UserDefaults?
    private let attachmentContentEncryptionKeyProvider: ((LocalAttachmentMetadata) throws -> Data)?
    private let androidAttachmentWrappingKeyProvider: ((LocalAttachmentMetadata) throws -> AndroidAttachmentContentWrappingKey)?
    private let passwordGenerator: () throws -> String
    private let bitwardenFileSendLocalIDProvider: () -> String
    private let bitwardenTextSendLocalIDProvider: () -> String
    var activeVaultSession: LocalVaultSession?
    var activeEntryRepository: LocalVaultEntryRepository?
    var activeProject: LocalVaultProject?
    private var rememberedVaultDescriptor: LocalVaultDescriptor?
    private var rememberedVaultID: String?
    private var lastUserActivityAt: Date?
    private var pendingAndroidEncryptedBackupData: Data?
    private var keePassLastSuccessfulUnlockCredentials: KeePassUnlockCredentials?
    private var pendingBitwardenTwoFactorChallenge: BitwardenTwoFactorLoginChallenge?
    private var quickSetupState: AppQuickSetupState

    var bitwardenTwoFactorProviders: [BitwardenTwoFactorProvider] {
        pendingBitwardenTwoFactorChallenge?.providers ?? []
    }

    var canRequestBitwardenEmailTwoFactorCode: Bool {
        pendingBitwardenTwoFactorChallenge?.supportsEmailCodeRequest ?? false
    }

    init(
        vaultRepository: LocalVaultRepository = LocalVaultRepository(),
        vaultKeychainService: (any AppVaultKeychainService)? = nil,
        vaultWrappedKeyProvider: ((LocalVaultSession) throws -> WrappedVaultKey)? = nil,
        rememberedVaultStore: any RememberedVaultStore = MemoryRememberedVaultStore(),
        biometricUnlockPreferenceStore: any BiometricUnlockPreferenceStore = MemoryBiometricUnlockPreferenceStore(),
        vaultDisplayPreferenceStore: any VaultDisplayPreferenceStore = MemoryVaultDisplayPreferenceStore(),
        appearancePreferenceStore: any AppAppearancePreferenceStore = MemoryAppAppearancePreferenceStore(),
        vaultLayoutPreferenceStore: any VaultLayoutPreferenceStore = MemoryVaultLayoutPreferenceStore(),
        biometricUnlockAuthorizer: any BiometricUnlockAuthorizer = DeviceBiometricUnlockAuthorizer(),
        biometricCapabilityProvider: @escaping () -> BiometricUnlockCapability = { .unavailable },
        securityQuestionStore: any SecurityQuestionRecoveryStore = MigratingSecurityQuestionRecoveryStore(),
        securityQuestionVerifier: SecurityQuestionAnswerVerifier = SecurityQuestionAnswerVerifier(),
        securityQuestionThrottle: SecurityQuestionVerificationThrottle = .default,
        securityQuestionClock: @escaping () -> Date = { Date() },
        webDAVBackupService: any AppWebDAVBackupService = URLSessionAppWebDAVBackupService(),
        operationTimelineStore: any AppOperationTimelineStore = MemoryAppOperationTimelineStore(),
        quickSetupStateStore: any AppQuickSetupStateStore = MemoryAppQuickSetupStateStore(),
        backgroundBackupScheduler: any AppBackgroundBackupScheduler = SystemAppBackgroundBackupScheduler(),
        cloudFileProviders: [CloudFileProviderKind: any CloudFileProvider] = [:],
        oneDriveAuthenticationService: (any AppOneDriveAuthenticationService)? = nil,
        oneDriveBackupPreferencesStore: (any AppOneDriveBackupPreferencesStore)? = nil,
        oneDriveNow: @escaping () -> Date = Date.init,
        bitwardenPasswordAuthenticationService: (any AppBitwardenPasswordAuthenticationService)? = nil,
        bitwardenSyncProvider: (any BitwardenSyncProvider)? = nil,
        bitwardenAuthenticationSessionStore: any BitwardenAuthenticationSessionStore = MemoryBitwardenAuthenticationSessionStore(),
        bitwardenVaultKeyStore: (any BitwardenVaultKeyStore)? = nil,
        bitwardenSendSyncStateStore: any AppBitwardenSendSyncStateStore = MemoryAppBitwardenSendSyncStateStore(),
        bitwardenFolderSyncStateStore: any AppBitwardenFolderSyncStateStore = MemoryAppBitwardenFolderSyncStateStore(),
        bitwardenItemSyncStateStore: any AppBitwardenItemSyncStateStore = MemoryAppBitwardenItemSyncStateStore(),
        bitwardenPendingMutationQueueStore: any AppBitwardenPendingMutationQueueStore = MemoryAppBitwardenPendingMutationQueueStore(),
        autoFillIndexStore: (any AutoFillEncryptedIndexStore)? = nil,
        autoFillCredentialSecretStore: (any AutoFillCredentialSecretStore)? = nil,
        autoFillCredentialIdentityStore: (any AppAutoFillCredentialIdentityStore)? = nil,
        autoFillPolicyStore: any AppAutoFillPolicyStore = MemoryAppAutoFillPolicyStore(),
        autoFillIndexKeyMaterialProvider: ((String) throws -> AutoFillIndexKeyMaterial)? = nil,
        autoFillIndexCodec: AutoFillEncryptedIndexCodec = AutoFillEncryptedIndexCodec(),
        autoFillCredentialSecretCodec: AutoFillCredentialSecretCodec = AutoFillCredentialSecretCodec(),
        plusResourceUnlockService: (any AppPlusResourceUnlockService)? = nil,
        plusEntitlementStore: any AppPlusEntitlementStore = MemoryAppPlusEntitlementStore(),
        androidBackupAttachmentBlobStore: any AndroidBackupAttachmentBlobStore = FileAndroidBackupAttachmentBlobStore(),
        keePassDatabaseReader: any KeePassDatabaseReader = DefaultKeePassDatabaseReader(),
        keePassKdbxFileWritebackService: any AppKeePassKdbxFileWritebackService = FileSystemAppKeePassKdbxFileWritebackService(),
        keePassKdbx3WritebackCoordinator: any KeePassKdbx3WritebackCoordinator = DefaultKeePassKdbx3WritebackCoordinator(),
        keePassKdbx4WritebackCoordinator: any KeePassKdbx4WritebackCoordinator = DefaultKeePassKdbx4WritebackCoordinator(),
        widgetSnapshotStore: AppWidgetSnapshotFileStore? = nil,
        shortcutSnapshotStore: AppShortcutSnapshotFileStore? = nil,
        widgetReloadScheduler: (any MonicaWidgetReloadScheduling)? = nil,
        controlNavigationDefaults: UserDefaults? = UserDefaults(suiteName: MonicaControlNavigationStore.appGroupIdentifier),
        attachmentContentEncryptionKeyProvider: ((LocalAttachmentMetadata) throws -> Data)? = nil,
        androidAttachmentWrappingKeyProvider: ((LocalAttachmentMetadata) throws -> AndroidAttachmentContentWrappingKey)? = nil,
        notificationPermissionStatusProvider: @escaping () -> AppPermissionStatusRow.State = { .checkable },
        passwordGenerator: @escaping () throws -> String = {
            try PasswordGenerator.generate()
        },
        bitwardenFileSendLocalIDProvider: @escaping () -> String = {
            "bitwarden-file-send-\(UUID().uuidString)"
        },
        bitwardenTextSendLocalIDProvider: @escaping () -> String = {
            "bitwarden-text-send-\(UUID().uuidString)"
        },
        autoLockPolicy: AppAutoLockPolicy = .default,
        sensitivePasteboard: MonicaSensitivePasteboard? = nil,
        sensitivePreviewPreferenceStore: any SensitivePreviewPreferenceStore = MemorySensitivePreviewPreferenceStore(),
        sensitiveClipboardPreferenceStore: any SensitiveClipboardPreferenceStore = MemorySensitiveClipboardPreferenceStore()
    ) {
        self.vaultRepository = vaultRepository
        self.vaultKeychainService = vaultKeychainService
        self.vaultWrappedKeyProvider = vaultWrappedKeyProvider
        self.rememberedVaultStore = rememberedVaultStore
        self.biometricUnlockPreferenceStore = biometricUnlockPreferenceStore
        self.vaultDisplayPreferenceStore = vaultDisplayPreferenceStore
        self.appearancePreferenceStore = appearancePreferenceStore
        self.vaultLayoutPreferenceStore = vaultLayoutPreferenceStore
        self.biometricUnlockAuthorizer = biometricUnlockAuthorizer
        self.biometricCapabilityProvider = biometricCapabilityProvider
        self.securityQuestionStore = securityQuestionStore
        self.securityQuestionVerifier = securityQuestionVerifier
        self.securityQuestionThrottle = securityQuestionThrottle
        self.securityQuestionClock = securityQuestionClock
        self.webDAVBackupService = webDAVBackupService
        self.operationTimelineStore = operationTimelineStore
        self.quickSetupStateStore = quickSetupStateStore
        self.backgroundBackupScheduler = backgroundBackupScheduler
        self.cloudFileProviders = cloudFileProviders
        self.oneDriveAuthenticationService = oneDriveAuthenticationService
        self.oneDriveBackupPreferencesStore = oneDriveBackupPreferencesStore ?? MemoryAppOneDriveBackupPreferencesStore()
        self.oneDriveNow = oneDriveNow
        self.bitwardenPasswordAuthenticationService = bitwardenPasswordAuthenticationService
        self.bitwardenSyncProvider = bitwardenSyncProvider
        self.bitwardenAuthenticationSessionStore = bitwardenAuthenticationSessionStore
        self.bitwardenVaultKeyStore = bitwardenVaultKeyStore
        self.bitwardenSendSyncStateStore = bitwardenSendSyncStateStore
        self.bitwardenFolderSyncStateStore = bitwardenFolderSyncStateStore
        self.bitwardenItemSyncStateStore = bitwardenItemSyncStateStore
        self.bitwardenPendingMutationQueueStore = bitwardenPendingMutationQueueStore
        self.autoFillIndexStore = autoFillIndexStore
        self.autoFillCredentialSecretStore = autoFillCredentialSecretStore
        self.autoFillCredentialIdentityStore = autoFillCredentialIdentityStore
        self.autoFillPolicyStore = autoFillPolicyStore
        self.autoFillIndexKeyMaterialProvider = autoFillIndexKeyMaterialProvider
        self.autoFillIndexCodec = autoFillIndexCodec
        self.autoFillCredentialSecretCodec = autoFillCredentialSecretCodec
        self.plusResourceUnlockService = plusResourceUnlockService
        self.plusEntitlementStore = plusEntitlementStore
        self.androidBackupAttachmentBlobStore = androidBackupAttachmentBlobStore
        self.keePassDatabaseReader = keePassDatabaseReader
        self.keePassKdbxFileWritebackService = keePassKdbxFileWritebackService
        self.keePassKdbx3WritebackCoordinator = keePassKdbx3WritebackCoordinator
        self.keePassKdbx4WritebackCoordinator = keePassKdbx4WritebackCoordinator
        self.widgetSnapshotStore = widgetSnapshotStore
        self.shortcutSnapshotStore = shortcutSnapshotStore
        self.widgetReloadScheduler = widgetReloadScheduler
        self.controlNavigationDefaults = controlNavigationDefaults
        self.attachmentContentEncryptionKeyProvider = attachmentContentEncryptionKeyProvider
        self.androidAttachmentWrappingKeyProvider = androidAttachmentWrappingKeyProvider
        self.passwordGenerator = passwordGenerator
        self.bitwardenFileSendLocalIDProvider = bitwardenFileSendLocalIDProvider
        self.bitwardenTextSendLocalIDProvider = bitwardenTextSendLocalIDProvider
        self.autoLockPolicy = autoLockPolicy
        self.quickSetupState = quickSetupStateStore.loadState()
        let loadedTimelineEvents = operationTimelineStore.loadEvents()
        self.operationTimelineEvents = loadedTimelineEvents
        self.nextOperationTimelineEventSequence = loadedTimelineEvents.count
        self.notificationPermissionState = notificationPermissionStatusProvider()
        self.isBiometricUnlockEnabled = biometricUnlockPreferenceStore.loadIsEnabled()
        self.vaultDisplayPreferences = vaultDisplayPreferenceStore.loadPreferences()
        self.appearancePreferences = appearancePreferenceStore.loadPreferences()
        self.vaultLayoutPreferences = vaultLayoutPreferenceStore.loadPreferences()
        self.sensitivePreviewPreferenceStore = sensitivePreviewPreferenceStore
        self.sensitivePreviewPreferences = sensitivePreviewPreferenceStore.loadPreferences()
        self.sensitiveClipboardPreferenceStore = sensitiveClipboardPreferenceStore
        self.sensitiveClipboardTTL = sensitiveClipboardPreferenceStore.loadTTL()
        self.sensitivePasteboard = sensitivePasteboard
            ?? MonicaSensitivePasteboard(pasteboard: UnavailableSensitivePasteboard())
        self.autoFillPolicy = autoFillPolicyStore.loadPolicy()
        if plusEntitlementStore.loadIsResourceUnlocked() {
            self.plusEntitlementSnapshot = AppPlusEntitlementSnapshot(source: .resourceUnlock, expiresAt: nil)
        }
        if let remembered = try? rememberedVaultStore.load() {
            self.rememberedVaultDescriptor = LocalVaultDescriptor(
                fileURL: remembered.fileURL,
                displayName: remembered.displayName
            )
            self.rememberedVaultID = remembered.vaultID
        }
    }

    var filteredLoginEntries: [LocalLoginEntry] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = loginSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return filteredFavoriteEntries(
            loginEntries,
            query: query,
            favoritesOnly: showFavoriteLoginEntriesOnly,
            isFavorite: { $0.favorite }
        ) { entry, query in
            entry.title.localizedCaseInsensitiveContains(query)
                || entry.username.localizedCaseInsensitiveContains(query)
                || entry.url.localizedCaseInsensitiveContains(query)
        }
    }

    var loginStackedGroups: [AppLoginStackedGroup] {
        let grouped = Dictionary(grouping: filteredLoginEntries) { entry in
            loginStackedGroupKey(for: entry)
        }
        return grouped.map { key, entries in
            let titles = entries
                .map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let usernames = entries
                .map { $0.username.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return AppLoginStackedGroup(
                id: "login-stack-\(key.normalized)",
                title: key.title,
                value: itemCountLabel(entries.count),
                detail: usernames.prefix(3).joined(separator: " / "),
                preview: titles.prefix(3).joined(separator: " / "),
                systemImage: key.isWebsite ? "globe" : "textformat",
                entryIDs: entries.map(\.id)
            )
        }
        .sorted { lhs, rhs in
            if lhs.entryIDs.count != rhs.entryIDs.count {
                return lhs.entryIDs.count > rhs.entryIDs.count
            }
            if lhs.systemImage != rhs.systemImage {
                return lhs.systemImage == "globe"
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    var filteredNoteEntries: [LocalNoteEntry] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = noteSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return filteredFavoriteEntries(
            noteEntries,
            query: query,
            favoritesOnly: showFavoriteNoteEntriesOnly,
            isFavorite: { $0.favorite }
        ) { entry, query in
            entry.title.localizedCaseInsensitiveContains(query)
                || entry.body.localizedCaseInsensitiveContains(query)
        }
    }

    var filteredTotpEntries: [LocalTotpEntry] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = totpSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return filteredFavoriteEntries(
            totpEntries,
            query: query,
            favoritesOnly: showFavoriteTotpEntriesOnly,
            isFavorite: { $0.favorite }
        ) { entry, query in
            entry.title.localizedCaseInsensitiveContains(query)
                || entry.issuer.localizedCaseInsensitiveContains(query)
                || entry.accountName.localizedCaseInsensitiveContains(query)
        }
    }

    var filteredCardEntries: [LocalCardEntry] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = cardSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return filteredFavoriteEntries(
            cardEntries,
            query: query,
            favoritesOnly: showFavoriteCardEntriesOnly,
            isFavorite: { $0.favorite }
        ) { entry, query in
            entry.title.localizedCaseInsensitiveContains(query)
                || entry.cardholderName.localizedCaseInsensitiveContains(query)
                || entry.issuer.localizedCaseInsensitiveContains(query)
                || entry.network.localizedCaseInsensitiveContains(query)
                || entry.notes.localizedCaseInsensitiveContains(query)
        }
    }

    var filteredIdentityEntries: [LocalIdentityEntry] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = identitySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return filteredFavoriteEntries(
            identityEntries,
            query: query,
            favoritesOnly: showFavoriteIdentityEntriesOnly,
            isFavorite: { $0.favorite }
        ) { entry, query in
            entry.title.localizedCaseInsensitiveContains(query)
                || entry.documentType.localizedCaseInsensitiveContains(query)
                || entry.fullName.localizedCaseInsensitiveContains(query)
                || entry.documentNumber.localizedCaseInsensitiveContains(query)
                || entry.issuer.localizedCaseInsensitiveContains(query)
                || entry.country.localizedCaseInsensitiveContains(query)
                || entry.notes.localizedCaseInsensitiveContains(query)
        }
    }

    var filteredPasskeyEntries: [LocalPasskeyEntry] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = passkeySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return filteredFavoriteEntries(
            passkeyEntries,
            query: query,
            favoritesOnly: showFavoritePasskeyEntriesOnly,
            isFavorite: { $0.favorite }
        ) { entry, query in
            entry.title.localizedCaseInsensitiveContains(query)
                || entry.relyingPartyID.localizedCaseInsensitiveContains(query)
                || entry.username.localizedCaseInsensitiveContains(query)
                || entry.notes.localizedCaseInsensitiveContains(query)
            }
    }

    var filteredSshKeyEntries: [LocalSshKeyEntry] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = sshKeySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return filteredFavoriteEntries(
            sshKeyEntries,
            query: query,
            favoritesOnly: showFavoriteSshKeyEntriesOnly,
            isFavorite: { $0.favorite }
        ) { entry, query in
            entry.title.localizedCaseInsensitiveContains(query)
                || entry.username.localizedCaseInsensitiveContains(query)
                || entry.host.localizedCaseInsensitiveContains(query)
                || entry.publicKey.localizedCaseInsensitiveContains(query)
                || entry.notes.localizedCaseInsensitiveContains(query)
        }
    }

    var filteredApiTokenEntries: [LocalApiTokenEntry] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = apiTokenSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return filteredFavoriteEntries(
            apiTokenEntries,
            query: query,
            favoritesOnly: showFavoriteApiTokenEntriesOnly,
            isFavorite: { $0.favorite }
        ) { entry, query in
            entry.title.localizedCaseInsensitiveContains(query)
                || entry.issuer.localizedCaseInsensitiveContains(query)
                || entry.accountName.localizedCaseInsensitiveContains(query)
                || entry.scopes.localizedCaseInsensitiveContains(query)
                || entry.notes.localizedCaseInsensitiveContains(query)
        }
    }

    var filteredWifiEntries: [LocalWifiEntry] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = wifiSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return filteredFavoriteEntries(
            wifiEntries,
            query: query,
            favoritesOnly: showFavoriteWifiEntriesOnly,
            isFavorite: { $0.favorite }
        ) { entry, query in
            entry.title.localizedCaseInsensitiveContains(query)
                || entry.ssid.localizedCaseInsensitiveContains(query)
                || entry.securityType.localizedCaseInsensitiveContains(query)
                || entry.notes.localizedCaseInsensitiveContains(query)
        }
    }

    var editingWifiQRCodePayload: String {
        guard let entryID = editingWifiEntryID else {
            return ""
        }
        return LocalWifiEntry(
            id: entryID,
            projectID: activeProject?.id ?? "",
            title: editingWifiTitle,
            ssid: editingWifiSSID,
            securityType: editingWifiSecurityType,
            password: editingWifiPassword,
            hidden: editingWifiHidden,
            notes: editingWifiNotes,
            favorite: editingWifiFavorite
        ).qrCodePayload
    }

    var filteredSendEntries: [LocalSendEntry] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = sendSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return filteredFavoriteEntries(
            sendEntries,
            query: query,
            favoritesOnly: showFavoriteSendEntriesOnly,
            isFavorite: { $0.favorite }
        ) { entry, query in
            entry.title.localizedCaseInsensitiveContains(query)
                || entry.body.localizedCaseInsensitiveContains(query)
                || entry.expiresAt.localizedCaseInsensitiveContains(query)
                || entry.notes.localizedCaseInsensitiveContains(query)
        }
    }

    var filteredAttachmentEntries: [LocalAttachmentMetadata] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = attachmentSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return attachmentEntries
        }
        return attachmentEntries.filter { entry in
            entry.fileName.localizedCaseInsensitiveContains(query)
                || entry.mediaType.localizedCaseInsensitiveContains(query)
                || entry.storageMode.localizedCaseInsensitiveContains(query)
                || entry.downloadState.localizedCaseInsensitiveContains(query)
                || entry.source.localizedCaseInsensitiveContains(query)
                || entry.contentHash.localizedCaseInsensitiveContains(query)
                || (entry.entryID?.localizedCaseInsensitiveContains(query) ?? false)
                || (entry.localPath?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    func shortcutEntrySummaries(matching query: String) -> [AppShortcutEntrySummary] {
        guard vaultState == .unlocked else {
            return []
        }

        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return allShortcutEntrySummaries().filter { summary in
            guard !normalizedQuery.isEmpty else {
                return true
            }
            return summary.title.localizedCaseInsensitiveContains(normalizedQuery)
                || summary.subtitle.localizedCaseInsensitiveContains(normalizedQuery)
                || summary.searchableText.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    func shortcutSnapshot() -> AppShortcutSnapshot {
        guard vaultState == .unlocked else {
            return .locked
        }
        return AppShortcutSnapshot(
            vaultState: .unlocked,
            entries: allShortcutEntrySummaries().map(AppShortcutSnapshotEntry.init(summary:))
        )
    }

    func refreshShortcutSnapshotIfConfigured() throws {
        guard let shortcutSnapshotStore else {
            return
        }
        try shortcutSnapshotStore.saveSnapshot(shortcutSnapshot())
    }

    func widgetSnapshot(now: Date = Date()) -> AppWidgetSnapshot {
        guard vaultState == .unlocked else {
            return AppWidgetSnapshot(
                vaultState: .locked,
                totalEntryCount: 0,
                totpItems: [],
                shortcutItems: []
            )
        }

        let totpItems = totpEntries.prefix(3).map { entry in
            AppWidgetTotpItem(
                id: entry.id,
                title: shortcutTitle(entry.title),
                issuer: entry.issuer,
                accountName: entry.accountName,
                secondsRemaining: totpTimeRemaining(for: entry, at: now)
            )
        }
        return AppWidgetSnapshot(
            vaultState: .unlocked,
            totalEntryCount: activeVaultEntryCount,
            totpItems: Array(totpItems),
            shortcutItems: allShortcutEntrySummaries().prefix(4).map(MonicaWidgetShortcutItem.init(summary:))
        )
    }

    func refreshWidgetSnapshotIfConfigured(now: Date = Date()) throws {
        guard let widgetSnapshotStore else {
            return
        }
        try widgetSnapshotStore.saveSnapshot(widgetSnapshot(now: now))
    }

    /// Rewrites both App Group snapshots (a privacy-safe projection of the vault) and,
    /// only when at least one write succeeded, asks WidgetKit to reload.
    ///
    /// The reload is requested through `MonicaWidgetReloadScheduling`, which coalesces
    /// bursts: creating/importing many entries produces one timeline reload instead of one
    /// per entry. `reloadImmediately` is reserved for lock and vault switches, where the
    /// widget must observe the now-empty projection without waiting for the coalescing
    /// window. A failure never changes the vault operation result; the (secret-free) error
    /// description is kept in `widgetSnapshotSyncError` for diagnostics.
    @discardableResult
    func publishWidgetSnapshots(now: Date = Date(), reloadImmediately: Bool = false) -> Bool {
        var didWriteSnapshot = false
        if let widgetSnapshotStore {
            do {
                try widgetSnapshotStore.saveSnapshot(widgetSnapshot(now: now))
                didWriteSnapshot = true
            } catch {
                widgetSnapshotSyncError = error.localizedDescription
            }
        }
        if let shortcutSnapshotStore {
            do {
                try shortcutSnapshotStore.saveSnapshot(shortcutSnapshot())
                didWriteSnapshot = true
            } catch {
                widgetSnapshotSyncError = error.localizedDescription
            }
        }
        guard didWriteSnapshot else {
            return false
        }
        widgetSnapshotSyncError = nil
        guard let widgetReloadScheduler else {
            return true
        }
        if reloadImmediately {
            widgetReloadScheduler.requestImmediateReload()
        } else {
            widgetReloadScheduler.requestReload()
        }
        return true
    }

    func openShortcutEntry(_ summary: AppShortcutEntrySummary) throws {
        recordUserActivity()
        guard shortcutEntryExists(summary) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }

        let destination = destination(forShortcutEntryKind: summary.kind)
        selectedTab = destination.tab
        if let passwordModule = destination.passwordModule {
            self.passwordModule = passwordModule
        }
        if let otherKind = destination.otherKind {
            passwordOtherKind = otherKind
        }
        presentedDetailRoute = VaultItemRoute(kind: summary.kind, entryID: summary.id)
    }

    private func shortcutEntryExists(_ summary: AppShortcutEntrySummary) -> Bool {
        switch summary.kind {
        case .login:
            return loginEntries.contains { $0.id == summary.id }
        case .note:
            return noteEntries.contains { $0.id == summary.id }
        case .totp:
            return totpEntries.contains { $0.id == summary.id }
        case .card:
            return cardEntries.contains { $0.id == summary.id }
        case .identity:
            return identityEntries.contains { $0.id == summary.id }
        case .passkey:
            return passkeyEntries.contains { $0.id == summary.id }
        case .sshKey:
            return sshKeyEntries.contains { $0.id == summary.id }
        case .apiToken:
            return apiTokenEntries.contains { $0.id == summary.id }
        case .wifi:
            return wifiEntries.contains { $0.id == summary.id }
        case .sso:
            return ssoEntries.contains { $0.id == summary.id }
        case .send:
            return sendEntries.contains { $0.id == summary.id }
        case .attachmentRef:
            return false
        }
    }

    @discardableResult
    func openShortcutURL(_ url: URL) -> Bool {
        guard url.scheme == "monica",
              url.host() == "shortcut" else {
            return false
        }
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard pathComponents.count == 2,
              let kind = UnifiedVaultItemKind(rawValue: pathComponents[0]) else {
            return false
        }
        let entryID = pathComponents[1]
        do {
            try openShortcutEntry(
                AppShortcutEntrySummary(
                    id: entryID,
                    kind: kind,
                    title: "",
                    subtitle: "",
                    searchableText: ""
                )
            )
            return true
        } catch {
            vaultOperationState = .failed(String(localized: "快捷入口已失效，请重新选择条目。"))
            return false
        }
    }

    /// 统一处理 `monica://` 深链：旧的条目快捷入口与控制中心页面入口共用同一条导航路径。
    @discardableResult
    func openDeepLinkURL(_ url: URL) -> Bool {
        if openShortcutURL(url) {
            return true
        }
        guard url.scheme == "monica",
              url.host() == "open" else {
            return false
        }
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard pathComponents.count == 1,
              let page = MonicaControlPage(rawValue: pathComponents[0]) else {
            vaultOperationState = .failed("快捷入口无效，请重新选择页面。")
            return false
        }
        handleControlPage(page)
        return true
    }

    /// 控制按钮与深链都会走这里；锁定态只记录页面，绝不提前读取或展示条目。
    func handleControlPage(_ page: MonicaControlPage) {
        pendingControlPage = page
        consumePendingControlPageIfUnlocked()
    }

    /// 由视图在 vaultState 变为解锁时调用，覆盖首次创建、打开和生物识别解锁等所有路径。
    func consumePendingControlPageIfUnlocked() {
        guard vaultState == .unlocked,
              let page = pendingControlPage else {
            return
        }
        pendingControlPage = nil
        applyControlPage(page)
    }

    /// 从 App Group 取走控制中心留下的页面；启动、回到前台或收到通知时调用。
    func consumePendingControlNavigationIfAvailable() {
        guard let url = MonicaControlNavigationStore.consume(from: controlNavigationDefaults) else {
            return
        }
        _ = openDeepLinkURL(url)
    }

    private func applyControlPage(_ page: MonicaControlPage) {
        recordUserActivity()
        selectedTab = page.appTab
        if page == .passwords {
            passwordModule = .login
        }
        presentedDetailRoute = nil
    }

    private func allShortcutEntrySummaries() -> [AppShortcutEntrySummary] {
        var summaries: [AppShortcutEntrySummary] = []
        summaries += loginEntries.map(shortcutSummary(for:))
        summaries += noteEntries.map(shortcutSummary(for:))
        summaries += totpEntries.map(shortcutSummary(for:))
        summaries += cardEntries.map(shortcutSummary(for:))
        summaries += identityEntries.map(shortcutSummary(for:))
        summaries += passkeyEntries.map(shortcutSummary(for:))
        summaries += sshKeyEntries.map(shortcutSummary(for:))
        summaries += apiTokenEntries.map(shortcutSummary(for:))
        summaries += wifiEntries.map(shortcutSummary(for:))
        summaries += ssoEntries.map(shortcutSummary(for:))
        summaries += sendEntries.map(shortcutSummary(for:))
        return summaries
    }

    private func shortcutSummary(for entry: LocalLoginEntry) -> AppShortcutEntrySummary {
        let host = normalizedLoginHost(from: entry.url)
        let subtitle = shortcutSubtitle([entry.username, host])
        return AppShortcutEntrySummary(
            id: entry.id,
            kind: .login,
            title: shortcutTitle(entry.title),
            subtitle: subtitle,
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.login.localizedDisplayName, entry.title, entry.username, host])
        )
    }

    private func shortcutSummary(for entry: LocalNoteEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .note,
            title: shortcutTitle(entry.title),
            subtitle: UnifiedVaultItemKind.note.localizedDisplayName,
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.note.localizedDisplayName, entry.title])
        )
    }

    private func shortcutSummary(for entry: LocalTotpEntry) -> AppShortcutEntrySummary {
        let subtitle = shortcutSubtitle([entry.accountName, entry.issuer])
        return AppShortcutEntrySummary(
            id: entry.id,
            kind: .totp,
            title: shortcutTitle(entry.title),
            subtitle: subtitle,
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.totp.localizedDisplayName, entry.title, entry.issuer, entry.accountName])
        )
    }

    private func shortcutSummary(for entry: LocalCardEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .card,
            title: shortcutTitle(entry.title),
            subtitle: shortcutSubtitle([entry.cardholderName, entry.issuer, entry.network]),
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.card.localizedDisplayName, entry.title, entry.cardholderName, entry.issuer, entry.network])
        )
    }

    private func shortcutSummary(for entry: LocalIdentityEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .identity,
            title: shortcutTitle(entry.title),
            subtitle: shortcutSubtitle([entry.fullName, entry.documentType, entry.issuer, entry.country]),
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.identity.localizedDisplayName, entry.title, entry.fullName, entry.documentType, entry.issuer, entry.country])
        )
    }

    private func shortcutSummary(for entry: LocalPasskeyEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .passkey,
            title: shortcutTitle(entry.title),
            subtitle: shortcutSubtitle([entry.username, entry.relyingPartyID]),
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.passkey.localizedDisplayName, entry.title, entry.username, entry.relyingPartyID])
        )
    }

    private func shortcutSummary(for entry: LocalSshKeyEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .sshKey,
            title: shortcutTitle(entry.title),
            subtitle: shortcutSubtitle([entry.username, entry.host]),
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.sshKey.localizedDisplayName, entry.title, entry.username, entry.host])
        )
    }

    private func shortcutSummary(for entry: LocalApiTokenEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .apiToken,
            title: shortcutTitle(entry.title),
            subtitle: shortcutSubtitle([entry.accountName, entry.issuer, entry.expiresAt]),
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.apiToken.localizedDisplayName, entry.title, entry.accountName, entry.issuer, entry.expiresAt])
        )
    }

    private func shortcutSummary(for entry: LocalWifiEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .wifi,
            title: shortcutTitle(entry.title),
            subtitle: shortcutSubtitle([entry.ssid, entry.securityType]),
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.wifi.localizedDisplayName, entry.title, entry.ssid, entry.securityType])
        )
    }

    private func shortcutSummary(for entry: LocalSSOEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .sso,
            title: shortcutTitle(entry.title),
            subtitle: shortcutSubtitle([entry.displayProviderName, entry.accountName]),
            searchableText: shortcutSearchableText([
                UnifiedVaultItemKind.sso.localizedDisplayName,
                entry.title,
                entry.displayProviderName,
                entry.accountName,
                entry.issuer
            ])
        )
    }

    private func shortcutSummary(for entry: LocalSendEntry) -> AppShortcutEntrySummary {
        AppShortcutEntrySummary(
            id: entry.id,
            kind: .send,
            title: shortcutTitle(entry.title),
            subtitle: shortcutSubtitle([entry.expiresAt, String(localized: "最多查看 \(entry.maxViews) 次")]),
            searchableText: shortcutSearchableText([UnifiedVaultItemKind.send.localizedDisplayName, entry.title, entry.expiresAt])
        )
    }

    private func shortcutTitle(_ value: String) -> String {
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? String(localized: "未命名") : title
    }

    private func shortcutSubtitle(_ values: [String?]) -> String {
        let parts = values.compactMap { value -> String? in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        return parts.isEmpty ? String(localized: "可打开") : parts.joined(separator: " / ")
    }

    private func shortcutSearchableText(_ values: [String?]) -> String {
        values.compactMap { value -> String? in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        .joined(separator: " ")
    }

    private func destination(forShortcutEntryKind kind: UnifiedVaultItemKind) -> VaultShortcutDestination {
        switch kind {
        case .login:
            return VaultShortcutDestination(tab: .passwords, passwordModule: .login, otherKind: nil)
        case .note:
            return VaultShortcutDestination(tab: .passwords, passwordModule: .note, otherKind: nil)
        case .passkey:
            return VaultShortcutDestination(tab: .passwords, passwordModule: .passkey, otherKind: nil)
        case .sshKey, .apiToken, .wifi, .sso, .send, .attachmentRef:
            return VaultShortcutDestination(tab: .passwords, passwordModule: .other, otherKind: kind)
        case .totp:
            return VaultShortcutDestination(tab: .totp, passwordModule: nil, otherKind: nil)
        case .card, .identity:
            return VaultShortcutDestination(tab: .wallet, passwordModule: nil, otherKind: nil)
        }
    }

    func attachmentContentStatus(for entry: LocalAttachmentMetadata) -> AppAttachmentContentStatus {
        guard let vaultID = activeVaultSession?.handle.vaultID else {
            return AppAttachmentContentStatus(
                state: .unavailable,
                value: String(localized: "未解锁"),
                detail: String(localized: "请先解锁保险库，再检查附件内容。")
            )
        }
        guard entry.downloadState == "downloaded",
              let localPath = entry.localPath,
              !localPath.isEmpty else {
            return AppAttachmentContentStatus(
                state: .missing,
                value: String(localized: "待恢复"),
                detail: String(localized: "附件密文尚未保存在本机。")
            )
        }
        guard androidBackupAttachmentBlobStore.encryptedBlobExists(vaultID: vaultID, localPath: localPath) else {
            return AppAttachmentContentStatus(
                state: .missing,
                value: String(localized: "待恢复"),
                detail: String(localized: "附件密文尚未保存在本机。")
            )
        }
        return AppAttachmentContentStatus(
            state: .available,
            value: String(localized: "\(entry.storedSize) 字节"),
            detail: storedAttachmentContentCanPreviewDirectly(entry)
                ? String(localized: "附件内容已保存在本机，可预览。")
                : String(localized: "附件密文已保存在本机，可进入预览恢复流程。")
        )
    }

    func loadAttachmentEncryptedBlob(_ entry: LocalAttachmentMetadata) throws -> Data {
        recordUserActivity()
        do {
            let vaultSession = try requireActiveVaultSession()
            guard let localPath = entry.localPath, !localPath.isEmpty else {
                throw LocalAttachmentContentStoreError.missingLocalPath
            }
            let blob = try androidBackupAttachmentBlobStore.encryptedBlobData(
                vaultID: vaultSession.handle.vaultID,
                localPath: localPath
            )
            entryOperationState = .succeeded(String(localized: "附件密文已读取：\(entry.fileName) \(blob.count) 字节"))
            return blob
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    private func resolveAttachmentContentEncryptionKey(_ entry: LocalAttachmentMetadata) throws -> Data {
        if let attachmentContentEncryptionKeyProvider {
            return try attachmentContentEncryptionKeyProvider(entry)
        }
        if let wrappedContentEncryptionKey = entry.wrappedContentEncryptionKey,
           wrappedContentEncryptionKey.hasPrefix("IOS-RAWCEK:") {
            let encoded = String(wrappedContentEncryptionKey.dropFirst("IOS-RAWCEK:".count))
            guard let data = Data(base64Encoded: encoded),
                  data.count == LocalAttachmentContentDecryptor.androidContentEncryptionKeyByteCount
            else {
                throw AppAttachmentPreviewError.contentEncryptionKeyUnavailable
            }
            return data
        }
        guard let wrappedContentEncryptionKey = entry.wrappedContentEncryptionKey,
              !wrappedContentEncryptionKey.isEmpty,
              let androidAttachmentWrappingKeyProvider
        else {
            throw AppAttachmentPreviewError.contentEncryptionKeyUnavailable
        }
        return try AndroidWrappedAttachmentContentKeyUnwrapper.unwrap(
            wrappedContentEncryptionKey,
            using: try androidAttachmentWrappingKeyProvider(entry)
        )
    }

    func replaceAttachmentContent(
        _ entry: LocalAttachmentMetadata,
        plaintext: Data,
        mediaType: String? = nil
    ) throws -> LocalAttachmentMetadata {
        recordUserActivity()
        entryOperationState = .running

        do {
            let vaultSession = try requireActiveVaultSession()
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let contentEncryptionKey = try resolveAttachmentContentEncryptionKey(entry)
            guard contentEncryptionKey.count == LocalAttachmentContentDecryptor.androidContentEncryptionKeyByteCount else {
                throw LocalAttachmentContentCryptoError.invalidContentEncryptionKeyLength
            }

            let sealedBox = try AES.GCM.seal(
                plaintext,
                using: SymmetricKey(data: contentEncryptionKey)
            )
            guard let encryptedBlob = sealedBox.combined else {
                throw AppAttachmentPreviewError.contentWriteFailed
            }
            let requestedLocalPath = entry.localPath?.isEmpty == false ? entry.localPath! : "\(entry.id).enc"
            let localPath = try androidBackupAttachmentBlobStore.saveEncryptedBlob(
                encryptedBlob,
                vaultID: vaultSession.handle.vaultID,
                localPath: requestedLocalPath
            )
            let contentHash = Data(SHA256.hash(data: plaintext))
                .map { String(format: "%02x", $0) }
                .joined()
            let updated = try entryRepository.updateAttachmentMetadata(
                projectID: projectID,
                attachmentID: entry.id,
                entryID: entry.entryID,
                fileName: entry.fileName,
                mediaType: mediaType ?? entry.mediaType,
                originalSize: Int64(plaintext.count),
                storedSize: Int64(encryptedBlob.count),
                contentHash: "sha256:\(contentHash)",
                storageMode: "ios-edited-encrypted-blob",
                source: entry.source.isEmpty ? "ios-local-edit" : entry.source,
                downloadState: "downloaded",
                wrappedContentEncryptionKey: entry.wrappedContentEncryptionKey,
                localPath: localPath
            )
            attachmentEntries = try entryRepository.listAttachmentMetadata(projectID: projectID)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .attachmentRef,
                itemID: updated.id,
                itemTitle: sanitizedAttachmentPreviewFileName(updated.fileName)
            )
            entryOperationState = .succeeded(String(localized: "附件内容已替换：\(sanitizedAttachmentPreviewFileName(updated.fileName)) \(plaintext.count) 字节"))
            return updated
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func addLocalAttachmentContent(
        entryID: String?,
        fileURL: URL
    ) throws -> LocalAttachmentMetadata {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard isPlusActive else {
                throw AppPlusResourceUnlockError.serviceUnavailable
            }
            let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }
            let plaintext = try Data(contentsOf: fileURL)
            let mediaType = fileURL.pathExtension.isEmpty
                ? "application/octet-stream"
                : "application/\(fileURL.pathExtension.lowercased())"
            return try addLocalAttachmentContent(
                entryID: entryID,
                fileName: sanitizedAttachmentPreviewFileName(fileURL.lastPathComponent),
                mediaType: mediaType,
                plaintext: plaintext,
                source: "ios-file-importer"
            )
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    /// 直接以内存数据写入加密附件存储；笔记 Markdown 图片与文件导入共用这条路径。
    func addLocalAttachmentContent(
        entryID: String?,
        fileName: String,
        mediaType: String,
        plaintext: Data,
        source: String
    ) throws -> LocalAttachmentMetadata {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard isPlusActive else {
                throw AppPlusResourceUnlockError.serviceUnavailable
            }
            let vaultSession = try requireActiveVaultSession()
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let contentEncryptionKey = Data((0..<LocalAttachmentContentDecryptor.androidContentEncryptionKeyByteCount).map { _ in UInt8.random(in: 0...255) })
            let sealedBox = try AES.GCM.seal(
                plaintext,
                using: SymmetricKey(data: contentEncryptionKey)
            )
            guard let encryptedBlob = sealedBox.combined else {
                throw AppAttachmentPreviewError.contentWriteFailed
            }
            let sanitizedFileName = sanitizedAttachmentPreviewFileName(fileName)
            let localPath = try androidBackupAttachmentBlobStore.saveEncryptedBlob(
                encryptedBlob,
                vaultID: vaultSession.handle.vaultID,
                localPath: "ios-local-\(UUID().uuidString)-\(sanitizedFileName).enc"
            )
            let contentHash = Data(SHA256.hash(data: plaintext)).map { String(format: "%02x", $0) }.joined()
            let attachment = try entryRepository.createAttachmentMetadata(
                projectID: projectID,
                entryID: entryID,
                fileName: sanitizedFileName,
                mediaType: mediaType,
                originalSize: Int64(plaintext.count),
                storedSize: Int64(encryptedBlob.count),
                contentHash: "sha256:\(contentHash)",
                storageMode: "ios-local-encrypted-blob",
                source: source,
                downloadState: "downloaded",
                wrappedContentEncryptionKey: "IOS-RAWCEK:\(contentEncryptionKey.base64EncodedString())",
                localPath: localPath
            )
            attachmentEntries = try entryRepository.listAttachmentMetadata(projectID: projectID)
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .attachmentRef,
                itemID: attachment.id,
                itemTitle: attachment.fileName
            )
            entryOperationState = .succeeded(String(localized: "附件已添加：\(attachment.fileName)"))
            return attachment
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    /// 静默解密附件内容：供图片渲染使用，不写操作状态、不记录日志。
    func attachmentPlaintext(_ entry: LocalAttachmentMetadata) throws -> Data {
        let vaultSession = try requireActiveVaultSession()
        guard let localPath = entry.localPath, !localPath.isEmpty else {
            throw LocalAttachmentContentStoreError.missingLocalPath
        }
        let blob = try androidBackupAttachmentBlobStore.encryptedBlobData(
            vaultID: vaultSession.handle.vaultID,
            localPath: localPath
        )
        let contentEncryptionKey = try resolveAttachmentContentEncryptionKey(entry)
        return try LocalAttachmentContentDecryptor.decryptAndroidLocalBlob(
            blob,
            contentEncryptionKey: contentEncryptionKey
        )
    }

    func attachmentEntries(for entryID: String?) -> [LocalAttachmentMetadata] {
        guard let entryID, !entryID.isEmpty else {
            return []
        }
        return attachmentEntries.filter { $0.entryID == entryID }
    }

    func materializeAttachmentPreview(
        _ entry: LocalAttachmentMetadata,
        contentEncryptionKey: Data
    ) throws -> AppAttachmentPreviewFile {
        recordUserActivity()
        do {
            let encryptedBlob = try loadAttachmentEncryptedBlob(entry)
            let plaintext = try LocalAttachmentContentDecryptor.decryptAndroidLocalBlob(
                encryptedBlob,
                contentEncryptionKey: contentEncryptionKey
            )
            let displayFileName = sanitizedAttachmentPreviewFileName(entry.fileName)
            let directoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MonicaAttachmentPreviews", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let fileURL = directoryURL.appendingPathComponent(displayFileName, isDirectory: false)
            try plaintext.write(to: fileURL, options: [.atomic])
            let preview = AppAttachmentPreviewFile(
                fileURL: fileURL,
                displayFileName: displayFileName,
                byteCount: plaintext.count
            )
            entryOperationState = .succeeded(String(localized: "附件预览已准备：\(displayFileName) \(plaintext.count) 字节"))
            return preview
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func materializeStoredAttachmentContentPreview(
        _ entry: LocalAttachmentMetadata
    ) throws -> AppAttachmentPreviewFile {
        recordUserActivity()
        do {
            let content = try loadAttachmentEncryptedBlob(entry)
            let displayFileName = sanitizedAttachmentPreviewFileName(entry.fileName)
            let directoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MonicaAttachmentPreviews", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let fileURL = directoryURL.appendingPathComponent(displayFileName, isDirectory: false)
            try content.write(to: fileURL, options: [.atomic])
            let preview = AppAttachmentPreviewFile(
                fileURL: fileURL,
                displayFileName: displayFileName,
                byteCount: content.count
            )
            entryOperationState = .succeeded(String(localized: "附件预览已准备：\(displayFileName) \(content.count) 字节"))
            return preview
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func presentAttachmentQuickLookPreview(_ entry: LocalAttachmentMetadata) throws {
        recordUserActivity()
        dismissAttachmentQuickLookPreview()

        if storedAttachmentContentCanPreviewDirectly(entry) {
            do {
                let preview = try materializeStoredAttachmentContentPreview(entry)
                attachmentQuickLookPreviewURL = preview.fileURL
                appendOperationTimelineEvent(
                    action: .viewed,
                    itemKind: .attachmentRef,
                    itemID: entry.id,
                    itemTitle: preview.displayFileName
                )
                entryOperationState = .succeeded(String(localized: "附件预览已准备：\(preview.displayFileName) \(preview.byteCount) 字节"))
                return
            } catch let error as LocalAttachmentContentStoreError {
                entryOperationState = .failed(error.localizedDescription)
                throw error
            } catch {
                let previewError = AppAttachmentPreviewError.previewFailed
                entryOperationState = .failed(previewError.localizedDescription)
                throw previewError
            }
        }

        let contentEncryptionKey: Data
        do {
            contentEncryptionKey = try resolveAttachmentContentEncryptionKey(entry)
        } catch {
            let previewError = AppAttachmentPreviewError.contentEncryptionKeyUnavailable
            entryOperationState = .failed(previewError.localizedDescription)
            throw previewError
        }

        do {
            let preview = try materializeAttachmentPreview(
                entry,
                contentEncryptionKey: contentEncryptionKey
            )
            attachmentQuickLookPreviewURL = preview.fileURL
            appendOperationTimelineEvent(
                action: .viewed,
                itemKind: .attachmentRef,
                itemID: entry.id,
                itemTitle: preview.displayFileName
            )
            entryOperationState = .succeeded(String(localized: "附件预览已准备：\(preview.displayFileName) \(preview.byteCount) 字节"))
        } catch let error as LocalAttachmentContentStoreError {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        } catch let error as LocalAttachmentContentCryptoError {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        } catch let error as AppWebDAVBackupError {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        } catch {
            let previewError = AppAttachmentPreviewError.previewFailed
            entryOperationState = .failed(previewError.localizedDescription)
            throw previewError
        }
    }

    func dismissAttachmentQuickLookPreview() {
        guard let previewURL = attachmentQuickLookPreviewURL else {
            return
        }
        attachmentQuickLookPreviewURL = nil
        try? FileManager.default.removeItem(at: previewURL.deletingLastPathComponent())
    }

    var vaultQuickFilterRows: [AppVaultQuickFilterRow] {
        let category = activeProject
        let activeCount = activeVaultEntryCount
        let deletedCount = deletedVaultEntryCount
        var rows = [
            AppVaultQuickFilterRow(
                id: "all",
                title: String(localized: "全部"),
                value: itemCountLabel(activeCount),
                detail: String(localized: "显示当前分类里的全部活动条目。"),
                systemImage: "tray.full",
                isSelected: selectedVaultQuickFilterID == "all"
            )
        ]
        if let category {
            rows.append(
                AppVaultQuickFilterRow(
                    id: "category-\(category.id)",
                    title: category.title,
                    value: itemCountLabel(activeCount),
                    detail: String(localized: "当前分类。"),
                    systemImage: "folder",
                    isSelected: selectedVaultQuickFilterID == "category-\(category.id)"
                )
            )
        }
        rows.append(
            AppVaultQuickFilterRow(
                id: "favorites",
                title: String(localized: "收藏"),
                value: itemCountLabel(favoriteVaultEntryCount),
                detail: String(localized: "只显示已收藏条目。"),
                systemImage: "star",
                isSelected: selectedVaultQuickFilterID == "favorites"
            )
        )
        rows.append(
            AppVaultQuickFilterRow(
                id: "trash",
                title: String(localized: "回收站"),
                value: itemCountLabel(deletedCount),
                detail: String(localized: "显示当前分类的已删除条目。"),
                systemImage: "trash",
                isSelected: selectedVaultQuickFilterID == "trash"
            )
        )
        return rows
    }

    var activeVaultCategoryTitle: String {
        activeProject?.title ?? String(localized: "未选择分类")
    }

    var activeVaultProjectID: String? {
        activeProject?.id
    }

    var isTrashQuickFilterSelected: Bool {
        selectedVaultQuickFilterID == "trash"
    }

    func applyVaultQuickFilter(_ filterID: String) {
        guard vaultQuickFilterRows.contains(where: { $0.id == filterID }) else {
            return
        }
        clearVaultBatchSelection()
        clearVaultSearchQueries()
        setAllFavoriteFilters(filterID == "favorites")
        selectedVaultQuickFilterID = filterID
    }

    var isVaultBatchSelectionActive: Bool {
        vaultBatchSelectionKind != nil
    }

    var activeVaultBatchSelectionKind: UnifiedVaultItemKind? {
        vaultBatchSelectionKind
    }

    var vaultBatchSelectionTitle: String {
        if !isVaultBatchSelectionActive {
            return String(localized: "未选择")
        }
        return selectedVaultBatchItemIDs.isEmpty
            ? String(localized: "选择条目")
            : String(localized: "已选择 \(selectedVaultBatchItemIDs.count) 项")
    }

    var canDeleteSelectedVaultBatchItems: Bool {
        isVaultBatchSelectionActive && !isTrashQuickFilterSelected && !selectedVaultBatchItemIDs.isEmpty
    }

    var canRestoreSelectedVaultBatchItems: Bool {
        isVaultBatchSelectionActive && isTrashQuickFilterSelected && !selectedVaultBatchItemIDs.isEmpty
    }

    var canMoveSelectedVaultBatchItems: Bool {
        isVaultBatchSelectionActive
            && !isTrashQuickFilterSelected
            && !selectedVaultBatchItemIDs.isEmpty
            && !availableVaultBatchMoveTargets.isEmpty
    }

    var availableVaultBatchMoveTargets: [LocalVaultProject] {
        guard let activeProject else {
            return []
        }
        return vaultProjects.filter { $0.id != activeProject.id }
    }

    func enterVaultBatchSelection(for kind: UnifiedVaultItemKind) {
        vaultBatchSelectionKind = kind
        selectedVaultBatchItemIDs = selectedVaultBatchItemIDs.intersection(visibleVaultBatchItemIDs(for: kind))
        recordUserActivity()
    }

    @discardableResult
    func createVaultCategory(title: String) throws -> LocalVaultProject {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project = try entryRepository.createProject(title: title)
            vaultProjects.append(project)
            try activateVaultCategory(project, entryRepository: entryRepository)
            entryOperationState = .succeeded(project.title)
            return project
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func switchVaultCategory(projectID: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let project = vaultProjects.first(where: { $0.id == projectID })
            else {
                throw LocalVaultRepositoryError.projectNotFound
            }
            try activateVaultCategory(project, entryRepository: entryRepository)
            entryOperationState = .succeeded(project.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    @discardableResult
    func renameVaultCategory(projectID: String, title: String) throws -> LocalVaultProject {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let renamed = try entryRepository.renameProject(projectID: projectID, title: title)
            vaultProjects = vaultProjects.map { $0.id == projectID ? renamed : $0 }
            if activeProject?.id == projectID {
                activeProject = renamed
                selectedVaultQuickFilterID = "category-\(renamed.id)"
            }
            entryOperationState = .succeeded(renamed.title)
            return renamed
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteVaultCategory(projectID: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            try entryRepository.deleteProject(projectID: projectID)
            vaultProjects.removeAll { $0.id == projectID }
            if activeProject?.id == projectID {
                if let next = vaultProjects.first {
                    try activateVaultCategory(next, entryRepository: entryRepository)
                } else {
                    activeProject = nil
                    clearAllEntryLists()
                    resetVaultQuickFilters()
                }
            }
            publishWidgetSnapshots()
            refreshVaultSearchIndex(entryRepository: entryRepository)
            entryOperationState = .succeeded(String(localized: "已删除分类"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func clearVaultBatchSelection() {
        vaultBatchSelectionKind = nil
        selectedVaultBatchItemIDs = []
    }

    func toggleVaultBatchItemSelection(_ itemID: String, for kind: UnifiedVaultItemKind) {
        if vaultBatchSelectionKind != kind {
            selectedVaultBatchItemIDs = []
            vaultBatchSelectionKind = kind
        }
        if selectedVaultBatchItemIDs.contains(itemID) {
            selectedVaultBatchItemIDs.remove(itemID)
        } else if visibleVaultBatchItemIDs(for: kind).contains(itemID) {
            selectedVaultBatchItemIDs.insert(itemID)
        }
        recordUserActivity()
    }

    func toggleVaultBatchItemSelection(id itemID: String) {
        guard let kind = vaultBatchSelectionKind else {
            return
        }
        toggleVaultBatchItemSelection(itemID, for: kind)
    }

    func selectAllVisibleVaultBatchItems(for kind: UnifiedVaultItemKind) {
        vaultBatchSelectionKind = kind
        selectedVaultBatchItemIDs = visibleVaultBatchItemIDs(for: kind)
        recordUserActivity()
    }

    func deleteSelectedVaultBatchItems() throws {
        guard let kind = vaultBatchSelectionKind, canDeleteSelectedVaultBatchItems else {
            return
        }
        try mutateSelectedVaultBatchItems(kind: kind, action: .deleted)
    }

    func restoreSelectedVaultBatchItems() throws {
        guard let kind = vaultBatchSelectionKind, canRestoreSelectedVaultBatchItems else {
            return
        }
        try mutateSelectedVaultBatchItems(kind: kind, action: .restored)
    }

    func moveSelectedVaultBatchItems(toProjectID targetProjectID: String) throws {
        guard let kind = vaultBatchSelectionKind, canMoveSelectedVaultBatchItems else {
            return
        }
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let sourceProjectID = activeProject?.id,
                  vaultProjects.contains(where: { $0.id == targetProjectID })
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let orderedIDs = visibleVaultBatchItemOrder(for: kind)
                .filter { selectedVaultBatchItemIDs.contains($0) }
            guard !orderedIDs.isEmpty else {
                clearVaultBatchSelection()
                entryOperationState = .idle
                return
            }

            let events = try moveVaultBatchItems(
                kind: kind,
                ids: orderedIDs,
                fromProjectID: sourceProjectID,
                toProjectID: targetProjectID,
                entryRepository: entryRepository
            )

            try refreshAllEntryLists(projectID: sourceProjectID, entryRepository: entryRepository)
            clearVaultSearchQueries()
            if kind == .login {
                try refreshAutoFillEncryptedIndexIfConfigured()
            }
            for event in events {
                appendOperationTimelineEvent(
                    action: .moved,
                    itemKind: kind,
                    itemID: event.id,
                    itemTitle: event.title
                )
            }
            clearVaultBatchSelection()
            entryOperationState = .succeeded(String(localized: "已移动 \(events.count) 项"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    var vaultDisplayPreferenceRows: [AppVaultDisplayPreferenceRow] {
        [
            AppVaultDisplayPreferenceRow(
                id: "card-density",
                title: String(localized: "卡片密度"),
                value: vaultDisplayPreferences.cardDensity.label,
                detail: String(localized: "调整密码列表卡片的间距和扫描密度。"),
                systemImage: "rectangle.compress.vertical"
            ),
            AppVaultDisplayPreferenceRow(
                id: "login-username",
                title: String(localized: "账号字段"),
                value: vaultDisplayPreferences.showsLoginUsername ? String(localized: "显示") : String(localized: "隐藏"),
                detail: String(localized: "控制密码列表是否展示账号摘要。"),
                systemImage: "person.text.rectangle"
            ),
            AppVaultDisplayPreferenceRow(
                id: "login-url",
                title: String(localized: "网址字段"),
                value: vaultDisplayPreferences.showsLoginURL ? String(localized: "显示") : String(localized: "隐藏"),
                detail: String(localized: "控制密码列表是否展示网站或 URL 摘要。"),
                systemImage: "globe"
            ),
            AppVaultDisplayPreferenceRow(
                id: "tab-labels",
                title: String(localized: "底部导航文字"),
                value: vaultDisplayPreferences.showsTabLabels ? String(localized: "显示") : String(localized: "隐藏"),
                detail: String(localized: "控制底部导航是否显示文字标签。"),
                systemImage: "menubar.rectangle"
            )
        ]
    }

    func updateVaultDisplayPreferences(_ preferences: VaultDisplayPreferences) {
        vaultDisplayPreferences = preferences
        vaultDisplayPreferenceStore.savePreferences(preferences)
        recordUserActivity()
    }

    // MARK: - 敏感值复制与预览掩码（#58）

    static let sensitivePreviewMaskPlaceholder = "••••••"

    /// 列表、搜索结果与卡包摘要一律掩码，不依赖临时显示状态。
    func maskedSensitivePreview(_ value: String) -> String {
        value.isEmpty ? String(localized: "空") : Self.sensitivePreviewMaskPlaceholder
    }

    /// 详情页按「类别偏好 + 本次解锁会话的临时显示状态」决定显示掩码还是明文。
    func sensitivePreviewValue(_ value: String, category: SensitivePreviewCategory, entryID: String) -> String {
        guard !value.isEmpty else {
            return String(localized: "空")
        }
        let revealed = sensitivePreviewPreferences.allowsTemporaryReveal(category)
            && sensitivePreviewSession.isRevealed(entryID: entryID)
        return revealed ? value : Self.sensitivePreviewMaskPlaceholder
    }

    /// 详情页「显示敏感字段」开关能否使用：全部类别都被禁止时不给误触机会。
    var canTemporarilyRevealSensitiveFieldsInDetail: Bool {
        !sensitivePreviewPreferences.alwaysMask && sensitivePreviewPreferences.hasRevealableCategories
    }

    func isSensitivePreviewRevealed(entryID: String) -> Bool {
        sensitivePreviewSession.isRevealed(entryID: entryID)
    }

    func setSensitivePreviewRevealed(_ revealed: Bool, entryID: String) {
        sensitivePreviewSession.setRevealed(revealed, forEntryID: entryID)
    }

    /// 锁库时清空临时显示状态；不写入任何持久化存储。
    func resetSensitivePreviewReveal() {
        sensitivePreviewSession.reset()
    }

    func updateSensitivePreviewPreferences(_ preferences: SensitivePreviewPreferences) {
        sensitivePreviewPreferences = preferences
        sensitivePreviewPreferenceStore.savePreferences(preferences)
        if preferences.alwaysMask {
            sensitivePreviewSession.reset()
        }
        recordUserActivity()
    }

    func updateSensitiveClipboardTTL(_ ttl: SensitiveClipboardTTL) {
        sensitiveClipboardTTL = ttl
        sensitiveClipboardPreferenceStore.saveTTL(ttl)
        if ttl == .off {
            // 关闭自动清除后丢弃待清理记录，避免下一次回到前台时把仅剩的记录清掉。
            sensitivePasteboard.discardPendingRecord()
            sensitivePasteboardHasPendingAutoClear = false
            sensitivePasteboardExpiryTask?.cancel()
            sensitivePasteboardExpiryTask = nil
        }
        recordUserActivity()
    }

    @discardableResult
    func copySensitiveValueToPasteboard(_ secret: String) -> SensitivePasteboardCopyFeedback {
        switch sensitivePasteboard.copy(secret: secret, ttl: sensitiveClipboardTTL) {
        case .nothingToCopy:
            return .nothingToCopy
        case .copiedWithoutAutoClear:
            sensitivePasteboardHasPendingAutoClear = false
            sensitivePasteboardExpiryTask?.cancel()
            sensitivePasteboardExpiryTask = nil
            return .copiedWithoutAutoClear
        case .copiedWithAutoClear:
            sensitivePasteboardHasPendingAutoClear = true
            startSensitivePasteboardExpiryMonitor()
            return .copiedWithAutoClear(seconds: sensitiveClipboardTTL.rawValue)
        }
    }

    @discardableResult
    func checkSensitivePasteboardExpiry(at date: Date = Date()) -> MonicaSensitivePasteboard.ExpiryOutcome {
        let outcome = sensitivePasteboard.clearIfExpired(at: date)
        switch outcome {
        case .noPendingValue, .cleared, .skippedBecauseReplacedByAnotherApp:
            sensitivePasteboardHasPendingAutoClear = false
            sensitivePasteboardExpiryTask?.cancel()
            sensitivePasteboardExpiryTask = nil
        case .notYetDue:
            sensitivePasteboardHasPendingAutoClear = true
        }
        return outcome
    }

    @discardableResult
    func clearSensitivePasteboardManually() -> MonicaSensitivePasteboard.ExpiryOutcome {
        let outcome = sensitivePasteboard.clearImmediatelyIfOwned()
        sensitivePasteboardHasPendingAutoClear = sensitivePasteboard.hasPendingAutoClear
        if !sensitivePasteboard.hasPendingAutoClear {
            sensitivePasteboardExpiryTask?.cancel()
            sensitivePasteboardExpiryTask = nil
        }
        return outcome
    }

    /// 回到前台时补做到期检查：App 被挂起期间 Timer 不会运行，系统也不允许可靠的秒级后台清理。
    func resumeSensitivePasteboardExpiryMonitoringIfNeeded() {
        guard sensitivePasteboard.hasPendingAutoClear else {
            sensitivePasteboardHasPendingAutoClear = false
            sensitivePasteboardExpiryTask?.cancel()
            sensitivePasteboardExpiryTask = nil
            return
        }
        _ = checkSensitivePasteboardExpiry()
        if sensitivePasteboard.hasPendingAutoClear {
            startSensitivePasteboardExpiryMonitor()
        }
    }

    private func startSensitivePasteboardExpiryMonitor() {
        sensitivePasteboardExpiryTask?.cancel()
        guard sensitivePasteboard.hasPendingAutoClear else {
            sensitivePasteboardHasPendingAutoClear = false
            return
        }
        sensitivePasteboardExpiryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else {
                    return
                }
                self.checkSensitivePasteboardExpiry()
                if !self.sensitivePasteboard.hasPendingAutoClear {
                    return
                }
            }
        }
    }

    /// 密码页模块栏里实际展示的 `PasswordModule`（#63）。
    /// 按布局顺序取可见的列表模块；「其他」固定置后，不参与排序。
    /// 当前选中的模块即使被隐藏也暂时保留，避免分段控件丢失选中项。
    var passwordModuleBarModules: [PasswordModule] {
        let layout = vaultLayoutPreferences
        let selected = passwordModule
        var modules: [PasswordModule] = layout.orderedModules.compactMap { module in
            guard let listModule = module.passwordModule else { return nil }
            if layout.isHidden(module), listModule != selected { return nil }
            return listModule
        }
        modules.append(.other)
        return modules
    }

    /// 「更多」菜单里的模块入口（#63）：被隐藏的模块按布局顺序出现；
    /// 生成器作为工具页始终保留在此，保证任何布局下都能从「更多」找到它。
    var moreMenuLayoutModules: [PasswordLayoutModule] {
        var modules = vaultLayoutPreferences.hiddenModules
        if !modules.contains(.generator) {
            modules.append(.generator)
        }
        return modules
    }

    func updateVaultLayoutPreferences(_ preferences: VaultLayoutPreferences) {
        let normalized = preferences.normalized()
        vaultLayoutPreferences = normalized
        vaultLayoutPreferenceStore.savePreferences(normalized)
        // 当前选中的模块若被隐藏，回退到第一个可见列表模块，保持页面有内容。
        if let selectedLayoutModule = PasswordLayoutModule.allCases.first(where: { $0.passwordModule == passwordModule }),
           normalized.isHidden(selectedLayoutModule),
           let firstVisible = normalized.visibleModules.compactMap({ $0.passwordModule }).first {
            passwordModule = firstVisible
        }
        recordUserActivity()
    }

    func restoreDefaultVaultLayoutPreferences() {
        updateVaultLayoutPreferences(.default)
    }

    var appearancePreferenceRows: [AppAppearancePreferenceRow] {
        [
            AppAppearancePreferenceRow(
                id: "color-scheme",
                title: String(localized: "颜色模式"),
                value: appearancePreferences.colorScheme.label,
                detail: String(localized: "使用系统外观，或固定为浅色/深色。"),
                systemImage: "circle.lefthalf.filled"
            ),
            AppAppearancePreferenceRow(
                id: "accent-color",
                title: String(localized: "强调色"),
                value: appearancePreferences.accentColor.label,
                detail: String(localized: "控制按钮、选择态和系统 tint 色。"),
                systemImage: "paintpalette"
            ),
            AppAppearancePreferenceRow(
                id: "password-list-icon",
                title: String(localized: "密码列表图标"),
                value: appearancePreferences.passwordListIconStyle.label,
                detail: String(localized: "控制密码列表图标的显示方式。"),
                systemImage: "app.badge"
            ),
            AppAppearancePreferenceRow(
                id: "interface-density",
                title: String(localized: "界面密度"),
                value: appearancePreferences.interfaceDensity.label,
                detail: String(localized: "调整间距与行高；字号始终跟随系统动态字体，触控区域不小于 44pt。"),
                systemImage: "square.resize"
            )
        ]
    }

    func updateAppearancePreferences(_ preferences: AppAppearancePreferences) {
        appearancePreferences = preferences
        appearancePreferenceStore.savePreferences(preferences)
        recordUserActivity()
    }

    func restoreDefaultInterfaceDensity() {
        var preferences = appearancePreferences
        preferences.interfaceDensity = .default
        updateAppearancePreferences(preferences)
    }

    var plusEntitlementStatusRow: AppPlusEntitlementStatusRow {
        return AppPlusEntitlementStatusRow(
            id: "plus-entitlement",
            title: "Monica Plus",
            value: isPlusActive ? String(localized: "已激活") : String(localized: "未激活"),
            detail: plusEntitlementDetail(for: plusEntitlementSnapshot),
            systemImage: isPlusActive ? "checkmark.seal.fill" : "seal"
        )
    }

    var isPlusActive: Bool {
        plusEntitlementSnapshot.isActive
    }

    var plusFeatureRows: [AppPlusFeatureRow] {
        return [
            AppPlusFeatureRow(
                id: "premium_themes",
                title: String(localized: "会员专属主题"),
                detail: String(localized: "解锁 Monica Plus 专属主题配色。"),
                systemImage: "paintpalette",
                isUnlocked: isPlusActive
            ),
            AppPlusFeatureRow(
                id: "validator_vibration",
                title: String(localized: "验证器震动提醒"),
                detail: String(localized: "验证码即将刷新时的本机提醒能力。"),
                systemImage: "waveform",
                isUnlocked: isPlusActive
            ),
            AppPlusFeatureRow(
                id: "copy_next_code",
                title: String(localized: "智能复制下一个验证码"),
                detail: String(localized: "倒计时过短时可切换到下一枚 TOTP。"),
                systemImage: "arrow.triangle.2.circlepath",
                isUnlocked: isPlusActive
            ),
            AppPlusFeatureRow(
                id: "bitwarden_sync",
                title: String(localized: "Bitwarden 同步"),
                detail: String(localized: "解锁 Bitwarden 同步能力。"),
                systemImage: "cloud",
                isUnlocked: isPlusActive
            )
        ]
    }

    var canActivatePlusFromResource: Bool {
        plusResourceUnlockService != nil
    }

    func activatePlusFromResource(now: Date = Date()) async throws {
        recordUserActivity()
        plusActivationState = .running
        do {
            guard let plusResourceUnlockService else {
                throw AppPlusResourceUnlockError.serviceUnavailable
            }
            guard try await plusResourceUnlockService.unlockPlus() else {
                throw AppPlusResourceUnlockError.activationRejected
            }
            plusEntitlementSnapshot = AppPlusEntitlementSnapshot(source: .resourceUnlock, expiresAt: nil)
            plusEntitlementStore.saveIsResourceUnlocked(true)
            plusActivationState = .activated
            recordUserActivity(at: now)
        } catch {
            plusActivationState = .failed(readablePlusResourceUnlockErrorMessage(for: error))
            throw error
        }
    }

    func deactivatePlus(now: Date = Date()) {
        recordUserActivity()
        plusEntitlementSnapshot = AppPlusEntitlementSnapshot()
        plusEntitlementStore.saveIsResourceUnlocked(false)
        plusActivationState = .deactivated
        recordUserActivity(at: now)
    }

    private func readablePlusResourceUnlockErrorMessage(for error: Error) -> String {
        if let appError = error as? AppPlusResourceUnlockError {
            return appError.localizedDescription
        }
        return String(localized: "Plus 解锁失败，请稍后重试。")
    }

    var permissionStatusRows: [AppPermissionStatusRow] {
        [
            AppPermissionStatusRow(
                id: "camera",
                title: String(localized: "相机"),
                systemImage: "camera",
                state: cameraPermissionState,
                detail: String(localized: "用于扫描 TOTP 设置二维码。"),
                settingsURL: URL(string: UIApplication.openSettingsURLString)
            ),
            AppPermissionStatusRow(
                id: "autofill",
                title: String(localized: "自动填充"),
                systemImage: "key.viewfinder",
                state: autoFillIndexStore == nil || autoFillCredentialIdentityStore == nil ? .notConfigured : .configured,
                detail: String(localized: "系统自动填充、建议列表和加密索引。")
            ),
            AppPermissionStatusRow(
                id: "notifications",
                title: String(localized: "通知"),
                systemImage: "bell",
                state: notificationPermissionState,
                detail: String(localized: "TOTP 快捷查看会使用系统安全通知。"),
                settingsURL: URL(string: UIApplication.openSettingsURLString)
            ),
            AppPermissionStatusRow(
                id: "app-group",
                title: String(localized: "共享数据"),
                systemImage: "rectangle.connected.to.line.below",
                state: autoFillIndexStore == nil || autoFillCredentialSecretStore == nil ? .notConfigured : .configured,
                detail: String(localized: "主 App 与扩展共享加密后的自动填充数据。")
            ),
            AppPermissionStatusRow(
                id: "keychain",
                title: String(localized: "钥匙串"),
                systemImage: "lock.shield",
                state: vaultKeychainService == nil ? .notConfigured : .configured,
                detail: String(localized: "保存受系统保护的本地解锁材料，不保存主密码。")
            ),
            AppPermissionStatusRow(
                id: "autofill-provider",
                title: String(localized: "系统自动填充扩展"),
                systemImage: "key.viewfinder",
                state: systemAutoFillProviderState,
                detail: String(localized: "在“设置 › 通用 › 自动填充与密码”中启用 Monica 后，系统才能提供填充和通行密钥。")
            )
        ]
    }

    var filteredOperationTimelineEvents: [AppOperationTimelineEvent] {
        operationTimelineEvents.filter { event in
            if let operationTimelineFilterKind, event.itemKind != operationTimelineFilterKind {
                return false
            }
            if let operationTimelineFilterAction, event.action != operationTimelineFilterAction {
                return false
            }
            return true
        }
    }

    var quickSetupRows: [AppExtensionCapabilityRow] {
        [
            AppExtensionCapabilityRow(
                id: "security",
                title: String(localized: "安全"),
                value: areSecurityQuestionsSetForActiveVault ? String(localized: "已配置") : String(localized: "待配置"),
                detail: String(localized: "主密码、密保问题、钥匙串与生物识别解锁。"),
                systemImage: "lock.shield"
            ),
            AppExtensionCapabilityRow(
                id: "autofill",
                title: String(localized: "自动填充"),
                value: autoFillIndexStore == nil ? String(localized: "待配置") : autoFillIndexState.label,
                detail: String(localized: "使用系统凭据提供器、加密索引和安全策略完成填充。"),
                systemImage: "key.viewfinder"
            ),
            AppExtensionCapabilityRow(
                id: "appearance",
                title: String(localized: "外观"),
                value: appearancePreferences.accentColor.label,
                detail: String(localized: "颜色、图标、卡片密度、列表字段和底栏文字。"),
                systemImage: "paintpalette"
            ),
            AppExtensionCapabilityRow(
                id: "backup",
                title: String(localized: "备份"),
                value: "WebDAV / OneDrive",
                detail: String(localized: "手动备份、恢复、远端管理和自动备份状态。"),
                systemImage: "externaldrive.badge.icloud"
            ),
            AppExtensionCapabilityRow(
                id: "plus",
                title: "Monica Plus",
                value: isPlusActive ? String(localized: "已解锁") : String(localized: "可一键解锁"),
                detail: String(localized: "使用本地授权资源解锁可用能力。"),
                systemImage: "checkmark.seal"
            )
        ]
    }

    var extensionCapabilityRows: [AppExtensionCapabilityRow] {
        [
            AppExtensionCapabilityRow(
                id: "credential-provider",
                title: String(localized: "系统自动填充"),
                value: autoFillIndexStore == nil ? String(localized: "待配置") : String(localized: "已接入"),
                detail: String(localized: "按网站和通行密钥服务匹配，并使用加密索引保护数据。"),
                systemImage: "key.viewfinder"
            ),
            AppExtensionCapabilityRow(
                id: "shortcuts",
                title: String(localized: "快捷指令"),
                value: shortcutSnapshotStore == nil ? String(localized: "待配置") : String(localized: "已接入"),
                detail: String(localized: "搜索条目、打开 URL、复制安全摘要；锁定态不泄密。"),
                systemImage: "sparkles.rectangle.stack"
            ),
            AppExtensionCapabilityRow(
                id: "widget",
                title: String(localized: "小组件"),
                value: widgetSnapshotStore == nil ? String(localized: "待配置") : String(localized: "已接入"),
                detail: String(localized: "只读取脱敏快照，锁定态不展示敏感内容。"),
                systemImage: "rectangle.inset.filled"
            ),
            AppExtensionCapabilityRow(
                id: "share",
                title: String(localized: "分享导入"),
                value: String(localized: "已接入"),
                detail: String(localized: "从系统分享入口导入内容，锁定态只进入安全收件箱。"),
                systemImage: "square.and.arrow.down"
            )
        ]
    }

    var autoFillSystemStatusRows: [AppExtensionCapabilityRow] {
        [
            AppExtensionCapabilityRow(
                id: "match",
                title: String(localized: "匹配规则"),
                value: String(localized: "网站与通行密钥"),
                detail: String(localized: "按网站域名和通行密钥服务标识匹配。"),
                systemImage: "link"
            ),
            AppExtensionCapabilityRow(
                id: "blocked-fields",
                title: String(localized: "忽略字段"),
                value: "\(autoFillPolicy.blockedFields.count)",
                detail: String(localized: "这些输入字段不会触发自动填充建议。"),
                systemImage: "text.badge.xmark"
            ),
            AppExtensionCapabilityRow(
                id: "blocked-save",
                title: String(localized: "忽略保存目标"),
                value: "\(autoFillPolicy.blockedSaveTargets.count)",
                detail: String(localized: "这些网站或应用不会自动创建保存草稿。"),
                systemImage: "link.badge.plus"
            ),
            AppExtensionCapabilityRow(
                id: "identity-sync",
                title: String(localized: "系统凭据"),
                value: autoFillCredentialIdentityStore == nil ? String(localized: "待配置") : String(localized: "已配置"),
                detail: String(localized: "自动填充建议会与系统凭据列表保持同步。"),
                systemImage: "person.text.rectangle"
            )
        ]
    }

    func presentQuickSetup(force: Bool = true) {
        guard force || quickSetupState.shouldPresent(for: activeVaultSession?.handle.vaultID) else {
            return
        }
        isQuickSetupPresented = true
    }

    func completeQuickSetup() {
        if let vaultID = activeVaultSession?.handle.vaultID, !vaultID.isEmpty {
            quickSetupState.completedVaultIDs.insert(vaultID)
        }
        quickSetupState.lastCompletedAt = Date()
        quickSetupStateStore.saveState(quickSetupState)
        isQuickSetupPresented = false
        appendOperationTimelineEvent(
            action: .updated,
            itemKind: .login,
            itemID: "quick-setup",
            itemTitle: String(localized: "快速设置")
        )
    }

    func maybePresentQuickSetupAfterUnlock() {
        presentQuickSetup(force: false)
    }

    func presentExtensions() {
        isExtensionsPresented = true
    }

    var autoFillPolicyRows: [(title: String, value: String)] {
        [
            (title: String(localized: "忽略字段"), value: "\(autoFillPolicy.blockedFields.count)"),
            (title: String(localized: "忽略保存目标"), value: "\(autoFillPolicy.blockedSaveTargets.count)")
        ]
    }

    func updateAutoFillPolicy(blockedFields: [String], blockedSaveTargets: [String]) {
        let policy = AppAutoFillPolicy(
            blockedFields: blockedFields,
            blockedSaveTargets: blockedSaveTargets
        )
        autoFillPolicy = policy
        autoFillPolicyStore.savePolicy(policy)
        entryOperationState = .succeeded(String(localized: "自动填充规则已更新"))
    }

    var securityCenterRows: [AppSecurityCenterRow] {
        let weakPasswordCount = loginEntries.filter { Self.isWeakPassword($0.password) }.count
        let reusedPasswordCount = reusedPasswordEntryCount(in: loginEntries)
        let breachedPasswordCount = breachedPasswordEntryCount(in: loginEntries)
        let duplicateLoginCount = duplicateLoginEntryCount(in: loginEntries)
        return [
            AppSecurityCenterRow(
                id: "weak-passwords",
                title: String(localized: "弱密码"),
                value: itemCountLabel(weakPasswordCount),
                detail: weakPasswordCount == 0
                    ? String(localized: "当前登录条目未发现明显弱密码。")
                    : String(localized: "建议优先为这些登录条目生成更长且包含多类字符的密码。"),
                systemImage: "exclamationmark.shield"
            ),
            AppSecurityCenterRow(
                id: "reused-passwords",
                title: String(localized: "复用密码"),
                value: itemCountLabel(reusedPasswordCount),
                detail: reusedPasswordCount == 0
                    ? String(localized: "当前登录条目未发现密码复用。")
                    : String(localized: "建议为复用密码的登录条目分别设置唯一密码。"),
                systemImage: "rectangle.2.swap"
            ),
            AppSecurityCenterRow(
                id: "breached-passwords",
                title: String(localized: "泄露风险"),
                value: itemCountLabel(breachedPasswordCount),
                detail: breachedPasswordCount == 0
                    ? String(localized: "当前登录条目未命中本地泄露指纹库。")
                    : String(localized: "建议立即为命中泄露指纹的登录条目更换唯一密码。"),
                systemImage: "bolt.shield"
            ),
            AppSecurityCenterRow(
                id: "duplicate-logins",
                title: String(localized: "重复项"),
                value: itemCountLabel(duplicateLoginCount),
                detail: duplicateLoginCount == 0
                    ? String(localized: "当前登录条目未发现明显重复项。")
                    : String(localized: "建议检查这些登录条目，确认是否需要合并或保留。"),
                systemImage: "doc.on.doc"
            )
        ]
    }

    var securityCenterRepairSuggestions: [AppSecurityCenterRepairSuggestion] {
        let weakPasswordCount = loginEntries.filter { Self.isWeakPassword($0.password) }.count
        let reusedPasswordCount = reusedPasswordEntryCount(in: loginEntries)
        let breachedPasswordCount = breachedPasswordEntryCount(in: loginEntries)
        let duplicateLoginCount = duplicateLoginEntryCount(in: loginEntries)
        var suggestions: [AppSecurityCenterRepairSuggestion] = []

        if weakPasswordCount > 0 {
            suggestions.append(
                AppSecurityCenterRepairSuggestion(
                    id: "repair-weak-passwords",
                    relatedRowID: "weak-passwords",
                    title: String(localized: "生成强密码"),
                    detail: String(localized: "为弱密码条目生成更长且包含多类字符的唯一密码。"),
                    systemImage: "wand.and.stars"
                )
            )
        }
        if reusedPasswordCount > 0 {
            suggestions.append(
                AppSecurityCenterRepairSuggestion(
                    id: "repair-reused-passwords",
                    relatedRowID: "reused-passwords",
                    title: String(localized: "拆分复用密码"),
                    detail: String(localized: "逐个为复用密码条目设置不同密码，降低单点泄露影响。"),
                    systemImage: "rectangle.2.swap"
                )
            )
        }
        if breachedPasswordCount > 0 {
            suggestions.append(
                AppSecurityCenterRepairSuggestion(
                    id: "repair-breached-passwords",
                    relatedRowID: "breached-passwords",
                    title: String(localized: "更换泄露密码"),
                    detail: String(localized: "优先处理命中泄露指纹的登录条目，并同步更新对应服务。"),
                    systemImage: "bolt.shield"
                )
            )
        }
        if duplicateLoginCount > 0 {
            suggestions.append(
                AppSecurityCenterRepairSuggestion(
                    id: "repair-duplicate-logins",
                    relatedRowID: "duplicate-logins",
                    title: String(localized: "合并重复项"),
                    detail: String(localized: "检查重复登录预览，确认后保留主条目并清理重复记录。"),
                    systemImage: "arrow.triangle.merge"
                )
            )
        }

        return suggestions
    }

    var duplicateLoginMergePreviews: [AppDuplicateLoginMergePreview] {
        let grouped = duplicateLoginGroups(in: loginEntries)
        return grouped.map { key, entries in
            let primary = entries[0]
            let duplicateIDs = entries.dropFirst().map(\.id)
            let title = primary.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = title.isEmpty ? key.title : title
            return AppDuplicateLoginMergePreview(
                id: "duplicate-login-\(primary.id)",
                title: displayTitle,
                username: key.username,
                url: key.url,
                entryCountLabel: itemCountLabel(entries.count),
                primaryEntryID: primary.id,
                duplicateEntryIDs: duplicateIDs,
                detail: String(localized: "保留 \(displayTitle)，预览合并 \(duplicateIDs.count) 个重复条目。")
            )
        }
    }

    var ignoredDuplicateLoginGroupCount: Int {
        ignoredDuplicateLoginKeys.count
    }

    var canUndoLastDuplicateLoginMerge: Bool {
        lastDuplicateLoginMergeUndo != nil
    }

    var lastDuplicateLoginMergeUndoTitle: String? {
        lastDuplicateLoginMergeUndo?.title
    }

    private static func isWeakPassword(_ password: String) -> Bool {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12 else {
            return true
        }
        let scalars = trimmed.unicodeScalars
        let hasLowercase = scalars.contains { CharacterSet.lowercaseLetters.contains($0) }
        let hasUppercase = scalars.contains { CharacterSet.uppercaseLetters.contains($0) }
        let hasDigit = scalars.contains { CharacterSet.decimalDigits.contains($0) }
        let hasSymbol = scalars.contains {
            !CharacterSet.alphanumerics.contains($0)
                && !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return !(hasLowercase && hasUppercase && hasDigit && hasSymbol)
    }

    private func reusedPasswordEntryCount(in entries: [LocalLoginEntry]) -> Int {
        let grouped = Dictionary(grouping: entries) { entry in
            entry.password.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return grouped
            .filter { password, entries in
                !password.isEmpty && entries.count > 1
            }
            .reduce(0) { count, group in count + group.value.count }
    }

    private func breachedPasswordEntryCount(in entries: [LocalLoginEntry]) -> Int {
        let fingerprints = Set(breachedPasswordSHA256Fingerprints.map { $0.lowercased() })
        guard !fingerprints.isEmpty else {
            return 0
        }
        return entries.filter { entry in
            let password = entry.password.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !password.isEmpty else {
                return false
            }
            return fingerprints.contains(Self.sha256Fingerprint(for: password))
        }.count
    }

    private static func sha256Fingerprint(for value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }

    private func duplicateLoginEntryCount(in entries: [LocalLoginEntry]) -> Int {
        duplicateLoginGroups(in: entries)
            .reduce(0) { count, group in count + group.entries.count }
    }

    private func duplicateLoginGroups(
        in entries: [LocalLoginEntry],
        excludingIgnored: Bool = true
    ) -> [(key: DuplicateLoginEntryKey, entries: [LocalLoginEntry])] {
        var grouped: [DuplicateLoginEntryKey: [LocalLoginEntry]] = [:]
        for entry in entries {
            guard let key = DuplicateLoginEntryKey(entry: entry) else {
                continue
            }
            grouped[key, default: []].append(entry)
        }
        return grouped
            .filter { _, entries in entries.count > 1 }
            .filter { key, _ in
                !excludingIgnored || !ignoredDuplicateLoginKeys.contains(key)
            }
            .map { key, entries in (key: key, entries: entries) }
            .sorted { lhs, rhs in
                lhs.entries[0].id.localizedStandardCompare(rhs.entries[0].id) == .orderedAscending
            }
    }

    private var activeVaultEntryCount: Int {
        loginEntries.count
            + noteEntries.count
            + totpEntries.count
            + cardEntries.count
            + identityEntries.count
            + passkeyEntries.count
            + sshKeyEntries.count
            + apiTokenEntries.count
            + wifiEntries.count
            + sendEntries.count
            + attachmentEntries.count
    }

    private var favoriteVaultEntryCount: Int {
        loginEntries.filter(\.favorite).count
            + noteEntries.filter(\.favorite).count
            + totpEntries.filter(\.favorite).count
            + cardEntries.filter(\.favorite).count
            + identityEntries.filter(\.favorite).count
            + passkeyEntries.filter(\.favorite).count
            + sshKeyEntries.filter(\.favorite).count
            + apiTokenEntries.filter(\.favorite).count
            + wifiEntries.filter(\.favorite).count
            + sendEntries.filter(\.favorite).count
    }

    private var deletedVaultEntryCount: Int {
        deletedLoginEntries.count
            + deletedNoteEntries.count
            + deletedTotpEntries.count
            + deletedCardEntries.count
            + deletedIdentityEntries.count
            + deletedPasskeyEntries.count
            + deletedSshKeyEntries.count
            + deletedApiTokenEntries.count
            + deletedWifiEntries.count
            + deletedSendEntries.count
            + deletedAttachmentEntries.count
    }

    private func itemCountLabel(_ count: Int) -> String {
        String(localized: "\(count) 项")
    }

    private func plusEntitlementDetail(for snapshot: AppPlusEntitlementSnapshot) -> String {
        switch snapshot.source {
        case .none:
            return String(localized: "点击资源激活按钮即可解锁 Monica Plus。")
        case .resourceUnlock:
            return String(localized: "已通过本地授权资源解锁 Monica Plus。")
        }
    }

    private func loginStackedGroupKey(for entry: LocalLoginEntry) -> AppLoginStackedGroupKey {
        if let host = normalizedLoginHost(from: entry.url) {
            return AppLoginStackedGroupKey(
                title: host,
                normalized: host,
                isWebsite: true
            )
        }
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = title.isEmpty ? String(localized: "未命名") : title
        return AppLoginStackedGroupKey(
            title: fallbackTitle,
            normalized: fallbackTitle.lowercased(),
            isWebsite: false
        )
    }

    private func normalizedLoginHost(from url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let host = URLComponents(string: candidate)?.host?.lowercased() else {
            return nil
        }
        let normalizedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return normalizedHost.isEmpty ? nil : normalizedHost
    }

    private func sharedLoginTitle(from url: URL) -> String {
        let host = url.host()?.lowercased() ?? normalizedLoginHost(from: url.absoluteString)
        let normalizedHost = host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        return normalizedHost?.nonBlankValue ?? "Shared Link"
    }

    private func sharedAttachmentMediaType(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).nonBlankValue ?? "application/octet-stream"
    }

    private func sharedAttachmentLocalPath(fileName: String) -> String {
        sanitizedAttachmentPreviewFileName("share-extension-\(UUID().uuidString)-\(fileName)")
    }

    private func storedAttachmentContentCanPreviewDirectly(_ entry: LocalAttachmentMetadata) -> Bool {
        switch entry.storageMode {
        case "keepass-kdbx-decoded-content",
            "bitwarden-downloaded-content",
            "share-extension-imported-blob":
            return true
        default:
            return false
        }
    }

    private func sharedContentHash(_ data: Data) -> String {
        let digest = Data(SHA256.hash(data: data))
            .map { String(format: "%02x", $0) }
            .joined()
        return "sha256:\(digest)"
    }

    var isFirstTimeVaultSetup: Bool {
        rememberedVaultDescriptor == nil
    }

    var isFirstVaultSetupRequired: Bool {
        isFirstTimeVaultSetup
    }

    var hasRememberedVault: Bool {
        rememberedVaultDescriptor != nil && rememberedVaultID != nil
    }

    var biometricUnlockCapability: BiometricUnlockCapability {
        biometricCapabilityProvider()
    }

    var biometricUnlockKind: BiometricUnlockKind? {
        biometricUnlockCapability.kind
    }

    var biometricUnlockDisplayName: String {
        biometricUnlockKind?.displayName ?? String(localized: "生物识别")
    }

    var biometricUnlockTitle: String {
        String(localized: "使用 \(biometricUnlockDisplayName) 解锁")
    }

    var biometricUnlockButtonTitle: String {
        String(localized: "使用 \(biometricUnlockDisplayName)")
    }

    var biometricUnlockSettingsTitle: String {
        String(localized: "\(biometricUnlockDisplayName) 解锁")
    }

    var biometricUnlockSystemImage: String {
        biometricUnlockKind?.systemImage ?? "person.badge.key"
    }

    private var cameraPermissionState: AppPermissionStatusRow.State {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            .granted
        case .denied, .restricted:
            .denied
        case .notDetermined:
            .notDetermined
        @unknown default:
            .checkable
        }
    }

    func refreshNotificationPermissionStatus() {
        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationPermissionState = Self.notificationPermissionState(
                for: settings.authorizationStatus
            )
        }
    }

    /// Reflects whether iOS has registered and enabled the AutoFill credential provider
    /// extension, so the vault can explain why AutoFill/passkey items never appear.
    func refreshSystemAutoFillProviderStatus() {
        ASCredentialIdentityStore.shared.getState { [weak self] state in
            let isEnabled = state.isEnabled
            #if DEBUG
            print("[Monica] autofill-provider enabled=\(isEnabled) incremental=\(state.supportsIncrementalUpdates)")
            #endif
            Task { @MainActor in
                self?.systemAutoFillProviderState = isEnabled ? .granted : .denied
            }
        }
    }

    nonisolated private static func notificationPermissionState(
        for authorizationStatus: UNAuthorizationStatus
    ) -> AppPermissionStatusRow.State {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            .granted
        case .denied:
            .denied
        case .notDetermined:
            .notDetermined
        @unknown default:
            .checkable
        }
    }

    var canUseBiometricUnlockHardware: Bool {
        biometricUnlockKind != nil
    }

    var shouldShowBiometricUnlockOnLockScreen: Bool {
        vaultState == .locked
            && isBiometricUnlockEnabled
            && canUseBiometricUnlockHardware
            && canUnlockRememberedVaultWithKeychain
    }

    private func filteredFavoriteEntries<Entry>(
        _ entries: [Entry],
        query: String,
        favoritesOnly: Bool,
        isFavorite: (Entry) -> Bool,
        matches: (Entry, String) -> Bool
    ) -> [Entry] {
        entries.enumerated()
            .filter { _, entry in
                (!favoritesOnly || isFavorite(entry))
                    && (query.isEmpty || matches(entry, query))
            }
            .sorted { lhs, rhs in
                let lhsFavorite = isFavorite(lhs.element)
                let rhsFavorite = isFavorite(rhs.element)
                if lhsFavorite != rhsFavorite {
                    return lhsFavorite
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func visibleVaultBatchItemIDs(for kind: UnifiedVaultItemKind) -> Set<String> {
        Set(visibleVaultBatchItemOrder(for: kind))
    }

    private func visibleVaultBatchItemOrder(for kind: UnifiedVaultItemKind) -> [String] {
        if isTrashQuickFilterSelected {
            switch kind {
            case .login:
                return deletedLoginEntries.map(\.id)
            case .totp:
                return deletedTotpEntries.map(\.id)
            case .note:
                return deletedNoteEntries.map(\.id)
            case .card:
                return deletedCardEntries.map(\.id)
            case .identity:
                return deletedIdentityEntries.map(\.id)
            case .passkey:
                return deletedPasskeyEntries.map(\.id)
            case .sshKey:
                return deletedSshKeyEntries.map(\.id)
            case .apiToken:
                return deletedApiTokenEntries.map(\.id)
            case .wifi:
                return deletedWifiEntries.map(\.id)
            case .sso:
                return deletedSSOEntries.map(\.id)
            case .send:
                return deletedSendEntries.map(\.id)
            case .attachmentRef:
                return deletedAttachmentEntries.map(\.id)
            }
        }

        switch kind {
        case .login:
            return filteredLoginEntries.map(\.id)
        case .totp:
            return filteredTotpEntries.map(\.id)
        case .note:
            return filteredNoteEntries.map(\.id)
        case .card:
            return filteredCardEntries.map(\.id)
        case .identity:
            return filteredIdentityEntries.map(\.id)
        case .passkey:
            return filteredPasskeyEntries.map(\.id)
        case .sshKey:
            return filteredSshKeyEntries.map(\.id)
        case .apiToken:
            return filteredApiTokenEntries.map(\.id)
        case .wifi:
            return filteredWifiEntries.map(\.id)
        case .sso:
            return filteredSSOEntries.map(\.id)
        case .send:
            return filteredSendEntries.map(\.id)
        case .attachmentRef:
            return filteredAttachmentEntries.map(\.id)
        }
    }

    private func mutateSelectedVaultBatchItems(
        kind: UnifiedVaultItemKind,
        action: AppOperationTimelineAction
    ) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let orderedIDs = visibleVaultBatchItemOrder(for: kind)
                .filter { selectedVaultBatchItemIDs.contains($0) }
            guard !orderedIDs.isEmpty else {
                clearVaultBatchSelection()
                entryOperationState = .idle
                return
            }

            let events: [(id: String, title: String)]
            switch action {
            case .deleted:
                events = try deleteVaultBatchItems(
                    kind: kind,
                    ids: orderedIDs,
                    projectID: projectID,
                    entryRepository: entryRepository
                )
            case .restored:
                events = try restoreVaultBatchItems(
                    kind: kind,
                    ids: orderedIDs,
                    projectID: projectID,
                    entryRepository: entryRepository
                )
            case .created, .updated, .moved, .viewed, .backedUp, .restoredBackup, .cleanedUp, .synced, .blocked:
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            try refreshAllEntryLists(projectID: projectID, entryRepository: entryRepository)
            if kind == .login {
                try refreshAutoFillEncryptedIndexIfConfigured()
            }
            for event in events {
                appendOperationTimelineEvent(
                    action: action,
                    itemKind: kind,
                    itemID: event.id,
                    itemTitle: event.title
                )
            }
            clearVaultBatchSelection()
            let verb = action == .deleted ? String(localized: "删除") : String(localized: "恢复")
            entryOperationState = .succeeded(String(localized: "已\(verb) \(events.count) 项"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    private func deleteVaultBatchItems(
        kind: UnifiedVaultItemKind,
        ids: [String],
        projectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> [(id: String, title: String)] {
        var events: [(id: String, title: String)] = []
        for id in ids {
            switch kind {
            case .login:
                guard let entry = loginEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteLoginEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .totp:
                guard let entry = totpEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteTotpEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .note:
                guard let entry = noteEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteNoteEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .card:
                guard let entry = cardEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteCardEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .identity:
                guard let entry = identityEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteIdentityEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .passkey:
                guard let entry = passkeyEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deletePasskeyEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .sshKey:
                guard let entry = sshKeyEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteSshKeyEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .apiToken:
                guard let entry = apiTokenEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteApiTokenEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .wifi:
                guard let entry = wifiEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteWifiEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .sso:
                guard let entry = ssoEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteSSOEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .send:
                guard let entry = sendEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteSendEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .attachmentRef:
                guard let entry = attachmentEntries.first(where: { $0.id == id }) else { continue }
                try entryRepository.deleteAttachmentMetadata(projectID: projectID, attachmentID: id)
                events.append((id, entry.fileName))
            }
        }
        return events
    }

    private func restoreVaultBatchItems(
        kind: UnifiedVaultItemKind,
        ids: [String],
        projectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> [(id: String, title: String)] {
        var events: [(id: String, title: String)] = []
        for id in ids {
            switch kind {
            case .login:
                let entry = try entryRepository.restoreLoginEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .totp:
                let entry = try entryRepository.restoreTotpEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .note:
                let entry = try entryRepository.restoreNoteEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .card:
                let entry = try entryRepository.restoreCardEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .identity:
                let entry = try entryRepository.restoreIdentityEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .passkey:
                let entry = try entryRepository.restorePasskeyEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .sshKey:
                let entry = try entryRepository.restoreSshKeyEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .apiToken:
                let entry = try entryRepository.restoreApiTokenEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .wifi:
                let entry = try entryRepository.restoreWifiEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .sso:
                let entry = try entryRepository.restoreSSOEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .send:
                let entry = try entryRepository.restoreSendEntry(projectID: projectID, entryID: id)
                events.append((id, entry.title))
            case .attachmentRef:
                let entry = try entryRepository.restoreAttachmentMetadata(projectID: projectID, attachmentID: id)
                events.append((id, entry.fileName))
            }
        }
        return events
    }

    private func moveVaultBatchItems(
        kind: UnifiedVaultItemKind,
        ids: [String],
        fromProjectID: String,
        toProjectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> [(id: String, title: String)] {
        var events: [(id: String, title: String)] = []
        for id in ids {
            let moved = try entryRepository.moveEntry(
                kind: kind,
                entryID: id,
                fromProjectID: fromProjectID,
                toProjectID: toProjectID
            )
            events.append((moved.id, moved.title))
        }
        return events
    }

    private func clearVaultSearchQueries() {
        loginSearchQuery = ""
        noteSearchQuery = ""
        totpSearchQuery = ""
        cardSearchQuery = ""
        identitySearchQuery = ""
        passkeySearchQuery = ""
        sshKeySearchQuery = ""
        apiTokenSearchQuery = ""
        wifiSearchQuery = ""
        ssoSearchQuery = ""
        sendSearchQuery = ""
        attachmentSearchQuery = ""
    }

    private func setAllFavoriteFilters(_ favoritesOnly: Bool) {
        showFavoriteLoginEntriesOnly = favoritesOnly
        showFavoriteNoteEntriesOnly = favoritesOnly
        showFavoriteTotpEntriesOnly = favoritesOnly
        showFavoriteCardEntriesOnly = favoritesOnly
        showFavoriteIdentityEntriesOnly = favoritesOnly
        showFavoritePasskeyEntriesOnly = favoritesOnly
        showFavoriteSshKeyEntriesOnly = favoritesOnly
        showFavoriteApiTokenEntriesOnly = favoritesOnly
        showFavoriteWifiEntriesOnly = favoritesOnly
        showFavoriteSSOEntriesOnly = favoritesOnly
        showFavoriteSendEntriesOnly = favoritesOnly
    }

    private func resetVaultQuickFilters() {
        selectedVaultQuickFilterID = "all"
        isLoginStackedGroupModeEnabled = false
        clearVaultBatchSelection()
        clearVaultSearchQueries()
        setAllFavoriteFilters(false)
    }

    private var pendingFirstTimePassword = ""

    func beginFirstTimePasswordConfirmation() {
        pendingFirstTimePassword = vaultPassword
        vaultPassword = ""
        firstTimePasswordSetupStep = .confirmPassword
        vaultOperationState = .idle
    }

    func confirmFirstTimePasswordAndCreateVault(
        in directoryURL: URL,
        deviceID: String,
        now: Date = Date()
    ) throws {
        guard pendingFirstTimePassword == vaultPassword else {
            pendingFirstTimePassword = ""
            vaultPassword = ""
            firstTimePasswordSetupStep = .enterPassword
            vaultOperationState = .failed(FirstTimePasswordSetupError.passwordMismatch.localizedDescription)
            throw FirstTimePasswordSetupError.passwordMismatch
        }

        vaultPassword = pendingFirstTimePassword
        pendingFirstTimePassword = ""
        try createLocalVault(in: directoryURL, deviceID: deviceID, now: now)
        firstTimePasswordSetupStep = .enterPassword
    }

    func createLocalVault(
        in directoryURL: URL,
        deviceID: String,
        now: Date = Date()
    ) throws {
        vaultOperationState = .running

        do {
            let displayName = vaultName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Monica"
                : vaultName
            let session = try vaultRepository.createVault(
                named: displayName,
                in: directoryURL,
                password: vaultPassword,
                deviceID: deviceID
            )
            vaultPassword = ""
            isPrivacyShieldVisible = false
            vaultState = .unlocked
            activeVaultName = session.descriptor.displayName
            activeVaultSession = session
            let entryRepository = vaultRepository.entryRepository(for: session)
            activeEntryRepository = entryRepository
            activeProject = nil
            vaultProjects = try entryRepository.listProjects()
            rememberVault(session)
            bitwardenPendingMutationBatches = (try? bitwardenPendingMutationQueueStore.loadBatches(
                vaultID: session.handle.vaultID
            )) ?? []
            loginEntries = []
            deletedLoginEntries = []
            noteEntries = []
            deletedNoteEntries = []
            totpEntries = []
            deletedTotpEntries = []
            totpImportURI = ""
            cardEntries = []
            deletedCardEntries = []
            identityEntries = []
            deletedIdentityEntries = []
            passkeyEntries = []
            deletedPasskeyEntries = []
            clearExtendedParityEntries()
            clearOperationTimelineEvents()
            recordUserActivity(at: now)
            publishWidgetSnapshots(now: now, reloadImmediately: true)
            vaultOperationState = .succeeded(session.descriptor.displayName)
        } catch {
            AppDiagnosticEmission.vaultFailure(error, stage: .create)
            clearVaultAccessAfterFailure()
            vaultOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func openLocalVault(
        at fileURL: URL,
        deviceID: String,
        now: Date = Date()
    ) throws {
        vaultOperationState = .running

        do {
            let session = try vaultRepository.openVault(
                at: fileURL,
                password: vaultPassword,
                deviceID: deviceID
            )
            vaultPassword = ""
            isPrivacyShieldVisible = false
            vaultState = .unlocked
            activeVaultName = session.descriptor.displayName
            activeVaultSession = session
            let entryRepository = vaultRepository.entryRepository(for: session)
            activeEntryRepository = entryRepository
            activeProject = nil
            vaultProjects = try entryRepository.listProjects()
            rememberVault(session)
            bitwardenPendingMutationBatches = (try? bitwardenPendingMutationQueueStore.loadBatches(
                vaultID: session.handle.vaultID
            )) ?? []
            loginEntries = []
            deletedLoginEntries = []
            noteEntries = []
            deletedNoteEntries = []
            totpEntries = []
            deletedTotpEntries = []
            totpImportURI = ""
            cardEntries = []
            deletedCardEntries = []
            identityEntries = []
            deletedIdentityEntries = []
            passkeyEntries = []
            deletedPasskeyEntries = []
            clearExtendedParityEntries()
            clearOperationTimelineEvents()
            recordUserActivity(at: now)
            publishWidgetSnapshots(now: now, reloadImmediately: true)
            vaultOperationState = .succeeded(session.descriptor.displayName)
        } catch {
            AppDiagnosticEmission.vaultFailure(error, stage: .open)
            clearVaultAccessAfterFailure()
            vaultOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func unlockRememberedVaultWithPassword(
        deviceID: String,
        now: Date = Date(),
        fallbackDirectory: URL? = nil
    ) throws {
        guard let rememberedVaultDescriptor else {
            vaultOperationState = .failed(AppVaultKeychainError.rememberedVaultUnavailable.localizedDescription)
            throw AppVaultKeychainError.rememberedVaultUnavailable
        }

        let descriptor = resolvedRememberedVaultDescriptor(
            rememberedVaultDescriptor,
            fallbackDirectory: fallbackDirectory
        )
        try openLocalVault(
            at: descriptor.fileURL,
            deviceID: deviceID,
            now: now
        )
    }

    func openRememberedLocalVaultWithPassword(
        deviceID: String,
        now: Date = Date()
    ) throws {
        try unlockRememberedVaultWithPassword(deviceID: deviceID, now: now)
    }

    func showForgotPasswordGuidance() {
        recordUserActivity()
        resetForgotPasswordInputs()
        do {
            guard let rememberedVaultID,
                  let setup = try securityQuestionStore.load(vaultID: rememberedVaultID) else {
                vaultOperationState = .failed(
                    String(localized: "主密码无法找回。可尝试钥匙串生物识别解锁、打开可记得密码的备份，或新建保险库。")
                )
                return
            }
            forgotPasswordQuestion1Text = setup.question1Text
            forgotPasswordQuestion2Text = setup.question2Text
            forgotPasswordLockoutRemaining = securityQuestionThrottle.remainingLockout(
                state: securityQuestionStore.loadThrottleState(vaultID: rememberedVaultID),
                now: securityQuestionClock()
            )
            forgotPasswordRecoveryStep = .verifySecurityQuestions
            vaultOperationState = .idle
        } catch {
            vaultOperationState = .failed(error.localizedDescription)
        }
    }

    var areSecurityQuestionsSetForActiveVault: Bool {
        guard let activeVaultSession else {
            return false
        }
        return (try? securityQuestionStore.load(vaultID: activeVaultSession.handle.vaultID)) != nil
    }

    func saveSecurityQuestions() async throws {
        recordUserActivity()
        do {
            guard let activeVaultSession else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            guard securityQuestion1ID != securityQuestion2ID else {
                throw SecurityQuestionRecoveryError.duplicateQuestions
            }
            let answer1 = securityAnswer1.trimmingCharacters(in: .whitespacesAndNewlines)
            let answer2 = securityAnswer2.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer1.isEmpty, !answer2.isEmpty else {
                throw SecurityQuestionRecoveryError.missingAnswers
            }

            securityQuestionState = .running
            let verifier = securityQuestionVerifier
            let credentials = try await Task.detached(priority: .userInitiated) {
                (
                    try verifier.makeCredential(for: answer1),
                    try verifier.makeCredential(for: answer2)
                )
            }.value

            let setup = SecurityQuestionRecoverySetup(
                vaultID: activeVaultSession.handle.vaultID,
                question1ID: securityQuestion1ID,
                question1Text: securityQuestionText(for: securityQuestion1ID),
                answer1: credentials.0,
                question2ID: securityQuestion2ID,
                question2Text: securityQuestionText(for: securityQuestion2ID),
                answer2: credentials.1
            )
            try securityQuestionStore.save(setup)
            try? securityQuestionStore.saveThrottleState(.clear, vaultID: setup.vaultID)
            securityAnswer1 = ""
            securityAnswer2 = ""
            forgotPasswordLockoutRemaining = 0
            securityQuestionState = .succeeded(String(localized: "密保问题已保存。"))
        } catch {
            securityQuestionState = .failed(error.localizedDescription)
            throw error
        }
    }

    var masterPasswordStrength: MasterPasswordStrength {
        MasterPasswordPolicy.strength(of: newMasterPassword)
    }

    var canSubmitMasterPasswordChange: Bool {
        vaultState == .unlocked
            && activeVaultSession != nil
            && !isChangingMasterPassword
            && !currentMasterPassword.isEmpty
            && !newMasterPassword.isEmpty
            && newMasterPassword == confirmNewMasterPassword
            && MasterPasswordPolicy.isAcceptable(newMasterPassword)
    }

    /// 修改主密码。
    ///
    /// 流程：本地校验 → `LocalVaultRepository.changeMasterPassword`（旧口令在独立临时连接上
    /// 验证，再由引擎在单个事务里重新包裹 vault key）→ 成功后清空输入并同步钥匙串解锁状态。
    /// 任何一步失败都保留原会话和旧口令，用户仍然可以用旧主密码解锁。
    func changeMasterPassword() async throws {
        recordUserActivity()

        guard !isChangingMasterPassword else {
            return
        }
        guard let activeVaultSession, vaultState == .unlocked else {
            let error = LocalVaultRepositoryError.vaultUnavailable
            masterPasswordChangeState = .failed(error.localizedDescription)
            throw error
        }
        guard newMasterPassword == confirmNewMasterPassword else {
            let error = MasterPasswordChangeError.confirmationMismatch
            masterPasswordChangeState = .failed(error.localizedDescription)
            throw error
        }
        guard MasterPasswordPolicy.isAcceptable(newMasterPassword) else {
            let error = MasterPasswordChangeError.insufficientStrength
            masterPasswordChangeState = .failed(error.localizedDescription)
            throw error
        }

        let currentPassword = currentMasterPassword
        let replacementPassword = newMasterPassword
        isChangingMasterPassword = true
        masterPasswordChangeState = .running
        defer { isChangingMasterPassword = false }

        do {
            try vaultRepository.changeMasterPassword(
                for: activeVaultSession,
                currentPassword: currentPassword,
                newPassword: replacementPassword
            )
        } catch {
            masterPasswordChangeState = .failed(readableMasterPasswordChangeError(error))
            throw error
        }

        currentMasterPassword = ""
        newMasterPassword = ""
        confirmNewMasterPassword = ""
        if vaultState == .unlocked, case .running = masterPasswordChangeState {
            confirmKeychainUnlockAfterMasterPasswordChange(session: activeVaultSession)
            masterPasswordChangeState = .succeeded(String(localized: "主密码已更新，请使用新主密码解锁。"))
        }
    }

    private func clearMasterPasswordChangeInput() {
        currentMasterPassword = ""
        newMasterPassword = ""
        confirmNewMasterPassword = ""
        masterPasswordChangeState = .idle
        isChangingMasterPassword = false
    }

    private func readableMasterPasswordChangeError(_ error: Error) -> String {
        if let repositoryError = error as? LocalVaultRepositoryError {
            return repositoryError.localizedDescription
        }
        return error.localizedDescription
    }

    /// 主密码只改变 `unlock_key`，`vault_key` 与钥匙串里的安全密钥材料都不变，
    /// 所以钥匙串解锁条目**不需要**重写：重写会写入一份未在保险库注册的新材料，
    /// 反而让下一次钥匙串解锁失败。这里只同步展示状态。
    private func confirmKeychainUnlockAfterMasterPasswordChange(session: LocalVaultSession) {
        guard isBiometricUnlockEnabled, vaultKeychainService != nil else {
            return
        }
        vaultKeychainState = .saved(session.handle.vaultID)
    }

    func verifyForgotPasswordSecurityAnswers(answer1: String, answer2: String) async -> Bool {
        guard let rememberedVaultID else {
            vaultOperationState = .failed(SecurityQuestionRecoveryError.missingSecurityQuestions.localizedDescription)
            return false
        }
        let setup: SecurityQuestionRecoverySetup
        do {
            guard let storedSetup = try securityQuestionStore.load(vaultID: rememberedVaultID) else {
                vaultOperationState = .failed(
                    SecurityQuestionRecoveryError.missingSecurityQuestions.localizedDescription
                )
                return false
            }
            setup = storedSetup
        } catch {
            vaultOperationState = .failed(error.localizedDescription)
            return false
        }

        let now = securityQuestionClock()
        let storedThrottleState = securityQuestionStore.loadThrottleState(vaultID: rememberedVaultID)
        let remainingLockout = securityQuestionThrottle.remainingLockout(
            state: storedThrottleState,
            now: now
        )
        guard remainingLockout <= 0 else {
            forgotPasswordLockoutRemaining = remainingLockout
            vaultOperationState = .failed(forgotPasswordLockoutMessage(remaining: remainingLockout))
            return false
        }

        isVerifyingForgotPasswordAnswers = true
        let verifier = securityQuestionVerifier
        let verdicts = await Task.detached(priority: .userInitiated) {
            (
                verifier.verify(answer1, against: setup.answer1),
                verifier.verify(answer2, against: setup.answer2)
            )
        }.value
        isVerifyingForgotPasswordAnswers = false

        if let invalidReason = verdicts.0.invalidRecordReason ?? verdicts.1.invalidRecordReason {
            vaultOperationState = .failed(forgotPasswordInvalidRecordMessage(invalidReason))
            return false
        }
        guard verdicts.0.isMatch, verdicts.1.isMatch else {
            let failedState = securityQuestionThrottle.stateAfterFailure(
                state: storedThrottleState,
                now: now
            )
            try? securityQuestionStore.saveThrottleState(failedState, vaultID: rememberedVaultID)
            forgotPasswordAttemptCount = failedState.failureCount
            let lockout = securityQuestionThrottle.remainingLockout(state: failedState, now: now)
            forgotPasswordLockoutRemaining = lockout
            vaultOperationState = .failed(
                lockout > 0
                    ? forgotPasswordLockoutMessage(remaining: lockout)
                    : String(localized: "密保答案不正确。")
            )
            return false
        }

        // 验证通过后才透明迁移旧记录或升级弱参数；迁移失败不影响本次找回，下次验证会重试。
        if verdicts.0.requiresRehash || verdicts.1.requiresRehash {
            let upgraded = try? await Task.detached(priority: .userInitiated) {
                try verifier.upgradedSetup(
                    for: setup,
                    answer1: answer1,
                    answer2: answer2,
                    verdict1: verdicts.0,
                    verdict2: verdicts.1
                )
            }.value
            if let upgraded {
                try? securityQuestionStore.save(upgraded)
            }
        }

        try? securityQuestionStore.saveThrottleState(.clear, vaultID: rememberedVaultID)
        forgotPasswordAttemptCount = 0
        forgotPasswordLockoutRemaining = 0
        forgotPasswordRecoveryStep = .resetPassword
        vaultOperationState = .idle
        return true
    }

    func resetForgottenPasswordWithVerifiedSecurityAnswers(deviceID: String) async throws {
        recordUserActivity()
        do {
            guard forgotPasswordRecoveryStep == .resetPassword else {
                throw SecurityQuestionRecoveryError.verificationRequired
            }
            guard forgotPasswordNewPassword == forgotPasswordConfirmPassword else {
                throw SecurityQuestionRecoveryError.passwordMismatch
            }
            guard let rememberedVaultDescriptor,
                  let rememberedVaultID else {
                throw AppVaultKeychainError.rememberedVaultUnavailable
            }
            guard let vaultKeychainService else {
                throw AppVaultKeychainError.keychainUnavailable
            }

            vaultOperationState = .running
            let wrappedKey = try await vaultKeychainService.loadWrappedKeyAfterAuthentication(
                vaultID: rememberedVaultID,
                reason: String(localized: "重设 Monica 主密码")
            )
            guard wrappedKey.vaultID == rememberedVaultID else {
                throw AppVaultKeychainError.vaultMismatch
            }
            let session = try vaultRepository.openVaultWithSecurityKey(
                at: rememberedVaultDescriptor.fileURL,
                securityKeyMaterial: wrappedKey.wrappedKeyMaterial,
                deviceID: deviceID
            )
            guard session.handle.vaultID == rememberedVaultID else {
                vaultRepository.closeVault(for: session)
                throw AppVaultKeychainError.vaultMismatch
            }

            try vaultRepository.resetMasterPassword(
                for: session,
                newPassword: forgotPasswordNewPassword
            )
            vaultRepository.closeVault(for: session)
            resetForgotPasswordInputs()
            vaultState = .locked
            vaultPassword = ""
            vaultOperationState = .succeeded(String(localized: "主密码已重设，请使用新密码解锁。"))
        } catch {
            vaultOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func dismissForgotPasswordRecovery() {
        resetForgotPasswordInputs()
    }

    private func resetForgotPasswordInputs() {
        forgotPasswordRecoveryStep = .none
        forgotPasswordQuestion1Text = ""
        forgotPasswordQuestion2Text = ""
        forgotPasswordAnswer1 = ""
        forgotPasswordAnswer2 = ""
        forgotPasswordAttemptCount = 0
        forgotPasswordLockoutRemaining = 0
        isVerifyingForgotPasswordAnswers = false
        forgotPasswordNewPassword = ""
        forgotPasswordConfirmPassword = ""
    }

    private func securityQuestionText(for id: Int) -> String {
        Self.securityQuestionOptions.first { $0.id == id }?.text ?? String(localized: "密保问题")
    }

    private func forgotPasswordLockoutMessage(remaining: TimeInterval) -> String {
        let seconds = max(1, Int(remaining.rounded(.up)))
        return String(localized: "密保答案错误次数过多，请在 \(seconds) 秒后重试。")
    }

    private func forgotPasswordInvalidRecordMessage(_ reason: String) -> String {
        "\(SecurityQuestionCredentialError.corruptedStoredRecord.localizedDescription)（\(reason)）"
    }

    func presentAddEditor(forItemKind itemKind: UnifiedVaultItemKind) {
        // 图标属于「上一次选择」的残留状态，新建不同条目时必须清掉。
        if itemKind == .login {
            loginIcon = nil
        }
        presentedEditorMode = .add(itemKind)
    }

    func presentEditEditor(for entry: LocalLoginEntry) {
        selectLoginEntryForEditing(entry)
        presentedEditorMode = .edit(VaultItemRoute(kind: .login, entryID: entry.id))
    }

    func presentEditEditor(for entry: LocalNoteEntry) {
        selectNoteEntryForEditing(entry)
        presentedEditorMode = .edit(VaultItemRoute(kind: .note, entryID: entry.id))
    }

    func presentEditEditor(for entry: LocalTotpEntry) {
        selectTotpEntryForEditing(entry)
        presentedEditorMode = .edit(VaultItemRoute(kind: .totp, entryID: entry.id))
    }

    func presentEditEditor(for entry: LocalCardEntry) {
        selectCardEntryForEditing(entry)
        presentedEditorMode = .edit(VaultItemRoute(kind: .card, entryID: entry.id))
    }

    func presentEditEditor(for entry: LocalIdentityEntry) {
        selectIdentityEntryForEditing(entry)
        presentedEditorMode = .edit(VaultItemRoute(kind: .identity, entryID: entry.id))
    }

    func presentEditEditor(for entry: LocalPasskeyEntry) {
        selectPasskeyEntryForEditing(entry)
        presentedEditorMode = .edit(VaultItemRoute(kind: .passkey, entryID: entry.id))
    }

    func presentEditEditor(for entry: LocalSshKeyEntry) {
        selectSshKeyEntryForEditing(entry)
        presentedEditorMode = .edit(VaultItemRoute(kind: .sshKey, entryID: entry.id))
    }

    func presentEditEditor(for entry: LocalApiTokenEntry) {
        selectApiTokenEntryForEditing(entry)
        presentedEditorMode = .edit(VaultItemRoute(kind: .apiToken, entryID: entry.id))
    }

    func presentEditEditor(for entry: LocalWifiEntry) {
        selectWifiEntryForEditing(entry)
        presentedEditorMode = .edit(VaultItemRoute(kind: .wifi, entryID: entry.id))
    }

    func presentEditEditor(for entry: LocalSendEntry) {
        selectSendEntryForEditing(entry)
        presentedEditorMode = .edit(VaultItemRoute(kind: .send, entryID: entry.id))
    }

    func presentDetail(kind: UnifiedVaultItemKind, entryID: String) {
        presentedDetailRoute = VaultItemRoute(kind: kind, entryID: entryID)
        appendOperationTimelineEvent(
            action: .viewed,
            itemKind: kind,
            itemID: entryID,
            itemTitle: detailTitle(kind: kind, entryID: entryID)
        )
        recordVaultSearchView(kind: kind, entryID: entryID)
    }

    func dismissDetail() {
        presentedDetailRoute = nil
        presentedDetailExtras = nil
    }

    func editPresentedDetail() {
        guard let route = presentedDetailRoute else {
            return
        }
        switch route.kind {
        case .login:
            if let entry = loginEntries.first(where: { $0.id == route.entryID }) { presentEditEditor(for: entry) }
        case .note:
            if let entry = noteEntries.first(where: { $0.id == route.entryID }) { presentEditEditor(for: entry) }
        case .totp:
            if let entry = totpEntries.first(where: { $0.id == route.entryID }) { presentEditEditor(for: entry) }
        case .card:
            if let entry = cardEntries.first(where: { $0.id == route.entryID }) { presentEditEditor(for: entry) }
        case .identity:
            if let entry = identityEntries.first(where: { $0.id == route.entryID }) { presentEditEditor(for: entry) }
        case .passkey:
            if let entry = passkeyEntries.first(where: { $0.id == route.entryID }) { presentEditEditor(for: entry) }
        case .sshKey:
            if let entry = sshKeyEntries.first(where: { $0.id == route.entryID }) { presentEditEditor(for: entry) }
        case .apiToken:
            if let entry = apiTokenEntries.first(where: { $0.id == route.entryID }) { presentEditEditor(for: entry) }
        case .wifi:
            if let entry = wifiEntries.first(where: { $0.id == route.entryID }) { presentEditEditor(for: entry) }
        case .sso:
            if let entry = ssoEntries.first(where: { $0.id == route.entryID }) { presentEditEditor(for: entry) }
        case .send:
            if let entry = sendEntries.first(where: { $0.id == route.entryID }) { presentEditEditor(for: entry) }
        case .attachmentRef:
            break
        }
        presentedDetailRoute = nil
    }

    private func detailTitle(kind: UnifiedVaultItemKind, entryID: String) -> String {
        switch kind {
        case .login:
            return loginEntries.first { $0.id == entryID }?.title ?? String(localized: "密码")
        case .note:
            return noteEntries.first { $0.id == entryID }?.title ?? String(localized: "笔记")
        case .totp:
            return totpEntries.first { $0.id == entryID }?.title ?? String(localized: "验证器")
        case .card:
            return cardEntries.first { $0.id == entryID }?.title ?? String(localized: "银行卡")
        case .identity:
            return identityEntries.first { $0.id == entryID }?.title ?? String(localized: "证件")
        case .passkey:
            return passkeyEntries.first { $0.id == entryID }?.title ?? String(localized: "通行密钥")
        case .sshKey:
            return sshKeyEntries.first { $0.id == entryID }?.title ?? String(localized: "SSH 密钥")
        case .apiToken:
            return apiTokenEntries.first { $0.id == entryID }?.title ?? "API Token"
        case .wifi:
            return wifiEntries.first { $0.id == entryID }?.title ?? "Wi-Fi"
        case .sso:
            return ssoEntries.first { $0.id == entryID }?.title ?? "SSO"
        case .send:
            return sendEntries.first { $0.id == entryID }?.title ?? "Send"
        case .attachmentRef:
            return attachmentEntries.first { $0.id == entryID }?.fileName ?? String(localized: "附件")
        }
    }

    func dismissPresentedEditor() {
        presentedEditorMode = nil
        clearPresentedItemExtras()
    }

    func savePresentedEditor(projectTitle: String) throws {
        guard let presentedEditorMode else {
            return
        }

        switch presentedEditorMode {
        case .add(let kind):
            // 新增条目没有 ID 之前无法挂侧表：保存前记录现有 ID，保存后取差集定位新条目。
            let existingIDs = Set(entryIDs(for: kind))
            try saveNewEntry(kind: kind, projectTitle: projectTitle)
            if let createdID = entryIDs(for: kind).first(where: { !existingIDs.contains($0) }) {
                try persistPresentedItemExtras(itemID: createdID, itemKind: kind)
            }
        case .edit(let route):
            try saveEditedEntry(kind: route.kind)
            try persistPresentedItemExtras(itemID: route.entryID, itemKind: route.kind)
        }
        self.presentedEditorMode = nil
    }

    /// Send 编辑器的统一保存入口：按类型分流到 Bitwarden 文件型 / 文本型，其余走本地。
    func savePresentedEditorWithBitwardenFileSend(projectTitle: String) async throws {
        guard let presentedEditorMode else {
            return
        }
        if case .add(.send) = presentedEditorMode {
            switch sendCreateType {
            case .file:
                try await createSelectedBitwardenFileSend()
                self.presentedEditorMode = nil
                return
            case .text:
                // 文本型同样推到 Bitwarden，这样才拿得到可分享链接。
                try await createBitwardenTextSend(
                    title: sendTitle,
                    text: sendBody,
                    notes: sendNotes,
                    expiresAt: sendExpiresAt,
                    maxViews: sendMaxViews,
                    password: sendPassword,
                    hideEmail: sendHideEmail
                )
                self.presentedEditorMode = nil
                return
            }
        }
        try savePresentedEditor(projectTitle: projectTitle)
    }

    private func saveNewEntry(kind: UnifiedVaultItemKind, projectTitle: String) throws {
        switch kind {
        case .login:
            try createLoginEntry(projectTitle: projectTitle)
        case .note:
            try createNoteEntry(projectTitle: projectTitle)
        case .totp:
            try createTotpEntry(projectTitle: projectTitle)
        case .card:
            try createCardEntry(projectTitle: projectTitle)
        case .identity:
            try createIdentityEntry(projectTitle: projectTitle)
        case .passkey:
            try createPasskeyEntry(projectTitle: projectTitle)
        case .sshKey:
            try createSshKeyEntry(projectTitle: projectTitle)
        case .apiToken:
            try createApiTokenEntry(projectTitle: projectTitle)
        case .wifi:
            try createWifiEntry(projectTitle: projectTitle)
        case .sso:
            try createSSOEntry(projectTitle: projectTitle)
        case .send:
            try createSendEntry(projectTitle: projectTitle)
        case .attachmentRef:
            throw LocalVaultRepositoryError.unsupportedEntryType(kind)
        }
    }

    private func saveEditedEntry(kind: UnifiedVaultItemKind) throws {
        switch kind {
        case .login:
            try updateSelectedLoginEntry()
        case .note:
            try updateSelectedNoteEntry()
        case .totp:
            try updateSelectedTotpEntry()
        case .card:
            try updateSelectedCardEntry()
        case .identity:
            try updateSelectedIdentityEntry()
        case .passkey:
            try updateSelectedPasskeyEntry()
        case .sshKey:
            try updateSelectedSshKeyEntry()
        case .apiToken:
            try updateSelectedApiTokenEntry()
        case .wifi:
            try updateSelectedWifiEntry()
        case .sso:
            try updateSelectedSSOEntry()
        case .send:
            try updateSelectedSendEntry()
        case .attachmentRef:
            throw LocalVaultRepositoryError.unsupportedEntryType(kind)
        }
    }

    func createLoginEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project: LocalVaultProject
            if let activeProject {
                project = activeProject
            } else {
                project = try entryRepository.createProject(title: projectTitle)
                activeProject = project
            }
            var entry = try entryRepository.createLoginEntry(
                projectID: project.id,
                draft: LocalLoginEntryDraft(
                    title: loginTitle,
                    username: loginUsername,
                    password: loginPassword,
                    url: loginURL,
                    notes: loginNotes,
                    urls: [loginURL] + loginAdditionalURLs,
                    appBundleID: loginAppBundleID,
                    appName: loginAppName
                )
            )
            if let loginIcon {
                entry = try entryRepository.setLoginEntryIcon(
                    projectID: project.id,
                    entryID: entry.id,
                    icon: loginIcon
                )
            }
            loginPassword = ""
            loginAdditionalURLs = []
            loginAppBundleID = ""
            loginAppName = ""
            loginNotes = ""
            loginEntries = try entryRepository.listLoginEntries(projectID: project.id)
            deletedLoginEntries = try entryRepository.listDeletedLoginEntries(projectID: project.id)
            try refreshAutoFillEncryptedIndexIfConfigured()
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .login,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            AppDiagnosticEmission.passkeyFailure(error, stage: .create)
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func generateLoginPassword() throws {
        recordUserActivity()
        do {
            loginPassword = try passwordGenerator()
            entryOperationState = .succeeded(String(localized: "已生成密码"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func selectLoginEntryForEditing(_ entry: LocalLoginEntry) {
        recordUserActivity()
        editingLoginEntryID = entry.id
        editingLoginTitle = entry.title
        editingLoginUsername = entry.username
        editingLoginPassword = entry.password
        editingLoginURL = entry.url
        editingLoginFavorite = entry.favorite
        editingLoginIcon = entry.icon
        let urls = entry.effectiveURLs
        editingLoginAdditionalURLs = urls.count > 1 ? Array(urls.dropFirst()) : []
        editingLoginAppBundleID = entry.appBundleID
        editingLoginAppName = entry.appName
        editingLoginNotes = entry.notes
        editingLoginPasswordHistory = entry.passwordHistory
    }

    func updateSelectedLoginEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingLoginEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            var entry = try entryRepository.updateLoginEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalLoginEntryDraft(
                    title: editingLoginTitle,
                    username: editingLoginUsername,
                    password: editingLoginPassword,
                    url: editingLoginURL,
                    notes: editingLoginNotes,
                    urls: [editingLoginURL] + editingLoginAdditionalURLs,
                    appBundleID: editingLoginAppBundleID,
                    appName: editingLoginAppName,
                    passwordHistory: editingLoginPasswordHistory
                )
            )
            // 图标不属于编辑表单字段：只有用户显式改过才回写，避免把旧值当成变更。
            if entry.icon != editingLoginIcon {
                entry = try entryRepository.setLoginEntryIcon(
                    projectID: projectID,
                    entryID: entryID,
                    icon: editingLoginIcon
                )
            }
            loginEntries = try entryRepository.listLoginEntries(projectID: projectID)
            deletedLoginEntries = try entryRepository.listDeletedLoginEntries(projectID: projectID)
            selectLoginEntryForEditing(entry)
            try refreshAutoFillEncryptedIndexIfConfigured()
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .login,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    /// 删除详情页里的一条旧密码；密码本身不变，因此不会再被自动补回。
    func deleteLoginPasswordHistoryEntry(entryID: String, historyEntryID: String) throws {
        try mutateLoginPasswordHistory(entryID: entryID) { history in
            LoginPasswordHistoryPolicy.removing(id: historyEntryID, from: history)
        }
    }

    /// 清空详情页里展示的密码历史。
    func clearLoginPasswordHistory(entryID: String) throws {
        try mutateLoginPasswordHistory(entryID: entryID) { _ in [] }
    }

    private func mutateLoginPasswordHistory(
        entryID: String,
        transform: ([LocalLoginPasswordHistoryEntry]) -> [LocalLoginPasswordHistoryEntry]
    ) throws {
        recordUserActivity()
        guard let entryRepository = activeEntryRepository,
              let projectID = activeProject?.id,
              let entry = loginEntries.first(where: { $0.id == entryID })
        else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }

        do {
            let updated = try entryRepository.updateLoginEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalLoginEntryDraft(
                    title: entry.title,
                    username: entry.username,
                    password: entry.password,
                    url: entry.url,
                    notes: entry.notes,
                    urls: entry.effectiveURLs,
                    appBundleID: entry.appBundleID,
                    appName: entry.appName,
                    passwordHistory: transform(entry.passwordHistory)
                )
            )
            loginEntries = try entryRepository.listLoginEntries(projectID: projectID)
            if editingLoginEntryID == entryID {
                selectLoginEntryForEditing(updated)
            }
            entryOperationState = .succeeded(updated.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    @discardableResult
    func importPendingShareExtensionItems(
        inboxStore: AppShareExtensionInboxStore,
        projectTitle: String
    ) throws -> AppShareImportResult {
        let requests = try inboxStore.loadPendingImportRequests()
        guard !requests.isEmpty else {
            return AppShareImportResult(importedCounts: [:], importedTitles: [])
        }
        let result = try importSharedItems(requests, projectTitle: projectTitle)
        try inboxStore.clearPendingImportRequests()
        return result
    }

    @discardableResult
    func importSharedItems(
        _ requests: [AppShareImportRequest],
        projectTitle: String
    ) throws -> AppShareImportResult {
        recordUserActivity()
        entryOperationState = .running

        do {
            let vaultSession = try requireActiveVaultSession()
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project = try ensureActiveProject(projectTitle: projectTitle, entryRepository: entryRepository)
            var importedCounts: [UnifiedVaultItemKind: Int] = [:]
            var importedTitles: [String] = []

            for request in requests {
                switch request {
                case .url(let url):
                    let title = sharedLoginTitle(from: url)
                    let entry = try entryRepository.createLoginEntry(
                        projectID: project.id,
                        draft: LocalLoginEntryDraft(
                            title: title,
                            username: "",
                            password: "",
                            url: url.absoluteString
                        )
                    )
                    importedCounts[.login, default: 0] += 1
                    importedTitles.append(entry.title)
                    appendOperationTimelineEvent(
                        action: .created,
                        itemKind: .login,
                        itemID: entry.id,
                        itemTitle: entry.title
                    )
                case .text(let text):
                    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !body.isEmpty else {
                        continue
                    }
                    let entry = try entryRepository.createNoteEntry(
                        projectID: project.id,
                        draft: LocalNoteEntryDraft(
                            title: String(localized: "来自分享的文本"),
                            body: body
                        )
                    )
                    importedCounts[.note, default: 0] += 1
                    importedTitles.append(entry.title)
                    appendOperationTimelineEvent(
                        action: .created,
                        itemKind: .note,
                        itemID: entry.id,
                        itemTitle: entry.title
                    )
                case .file(let url, let mediaType):
                    let data = try Data(contentsOf: url)
                    let fileName = sanitizedAttachmentPreviewFileName(url.lastPathComponent)
                    let localPath = sharedAttachmentLocalPath(fileName: fileName)
                    let storedPath = try androidBackupAttachmentBlobStore.saveEncryptedBlob(
                        data,
                        vaultID: vaultSession.handle.vaultID,
                        localPath: localPath
                    )
                    let attachment = try entryRepository.createAttachmentMetadata(
                        projectID: project.id,
                        entryID: nil,
                        fileName: fileName,
                        mediaType: sharedAttachmentMediaType(mediaType),
                        originalSize: Int64(data.count),
                        storedSize: Int64(data.count),
                        contentHash: sharedContentHash(data),
                        storageMode: "share-extension-imported-blob",
                        source: "ios-share-extension",
                        downloadState: "downloaded",
                        wrappedContentEncryptionKey: nil,
                        localPath: storedPath
                    )
                    importedCounts[.attachmentRef, default: 0] += 1
                    importedTitles.append(attachment.fileName)
                    appendOperationTimelineEvent(
                        action: .created,
                        itemKind: .attachmentRef,
                        itemID: attachment.id,
                        itemTitle: attachment.fileName
                    )
                }
            }

            try refreshAllEntryLists(projectID: project.id, entryRepository: entryRepository)
            try refreshAutoFillEncryptedIndexIfConfigured()
            let result = AppShareImportResult(
                importedCounts: importedCounts,
                importedTitles: importedTitles
            )
            entryOperationState = .succeeded(String(localized: "分享导入已导入 \(result.totalCount) 项"))
            return result
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func saveAutoFillCredential(
        _ request: AppAutoFillCredentialSaveRequest,
        projectTitle: String
    ) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let normalizedRequest = try normalizedAutoFillSaveRequest(request)
            guard !autoFillPolicy.blocksSaveTarget(normalizedRequest.serviceIdentifier) else {
                throw AppAutoFillPolicyError.saveTargetBlocked
            }
            let project: LocalVaultProject
            if let activeProject {
                project = activeProject
            } else {
                project = try entryRepository.createProject(title: projectTitle)
                activeProject = project
            }

            if let existing = matchingLoginEntry(for: normalizedRequest, in: loginEntries) {
                let updated = try entryRepository.updateLoginEntry(
                    projectID: project.id,
                    entryID: existing.id,
                    draft: LocalLoginEntryDraft(
                        title: existing.title,
                        username: normalizedRequest.username,
                        password: normalizedRequest.password,
                        url: existing.url,
                        notes: existing.notes
                    )
                )
                loginEntries = try entryRepository.listLoginEntries(projectID: project.id)
                deletedLoginEntries = try entryRepository.listDeletedLoginEntries(projectID: project.id)
                try refreshAutoFillEncryptedIndexIfConfigured()
                appendOperationTimelineEvent(
                    action: .updated,
                    itemKind: .login,
                    itemID: updated.id,
                    itemTitle: updated.title
                )
                entryOperationState = .succeeded(String(localized: "自动填充已更新 \(updated.title)"))
            } else {
                let title = autoFillSaveTitle(for: normalizedRequest)
                let entry = try entryRepository.createLoginEntry(
                    projectID: project.id,
                    draft: LocalLoginEntryDraft(
                        title: title,
                        username: normalizedRequest.username,
                        password: normalizedRequest.password,
                        url: normalizedRequest.serviceIdentifier
                    )
                )
                loginEntries = try entryRepository.listLoginEntries(projectID: project.id)
                deletedLoginEntries = try entryRepository.listDeletedLoginEntries(projectID: project.id)
                try refreshAutoFillEncryptedIndexIfConfigured()
                appendOperationTimelineEvent(
                    action: .created,
                    itemKind: .login,
                    itemID: entry.id,
                    itemTitle: entry.title
                )
                entryOperationState = .succeeded(String(localized: "自动填充已保存 \(entry.title)"))
            }
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    @discardableResult
    func importPendingAutoFillSaveRequests(
        inboxStore: AppAutoFillCredentialSaveInboxStore,
        projectTitle: String
    ) throws -> Int {
        let requests = try inboxStore.loadPendingSaveRequests()
        guard !requests.isEmpty else {
            return 0
        }

        for request in requests {
            try saveAutoFillCredential(request, projectTitle: projectTitle)
        }
        try inboxStore.clearPendingSaveRequests()
        entryOperationState = .succeeded(String(localized: "自动填充已导入 \(requests.count) 个保存请求"))
        return requests.count
    }

    func generateSelectedLoginPassword() throws {
        recordUserActivity()
        do {
            editingLoginPassword = try passwordGenerator()
            entryOperationState = .succeeded(String(localized: "已生成密码"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedLoginFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingLoginEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setLoginEntryFavorite(
                projectID: projectID,
                entryID: entryID,
                favorite: favorite
            )
            loginEntries = try entryRepository.listLoginEntries(projectID: projectID)
            selectLoginEntryForEditing(updated)
            entryOperationState = .succeeded(favorite ? String(localized: "已收藏 \(updated.title)") : String(localized: "已取消收藏 \(updated.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedLoginEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingLoginEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingLoginTitle
            try entryRepository.deleteLoginEntry(projectID: projectID, entryID: entryID)
            loginEntries = try entryRepository.listLoginEntries(projectID: projectID)
            deletedLoginEntries = try entryRepository.listDeletedLoginEntries(projectID: projectID)
            clearEditingLoginEntry()
            try refreshAutoFillEncryptedIndexIfConfigured()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .login,
                itemID: entryID,
                itemTitle: deletedTitle
            )
            entryOperationState = .succeeded(String(localized: "已删除 \(deletedTitle)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func mergeDuplicateLoginPreview(_ preview: AppDuplicateLoginMergePreview) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            guard let currentPreview = duplicateLoginMergePreviews.first(where: { $0.id == preview.id }) else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            for entryID in currentPreview.duplicateEntryIDs {
                try entryRepository.deleteLoginEntry(projectID: projectID, entryID: entryID)
            }
            lastDuplicateLoginMergeUndo = AppDuplicateLoginMergeUndo(
                title: currentPreview.title,
                restoredEntryIDs: currentPreview.duplicateEntryIDs
            )
            loginEntries = try entryRepository.listLoginEntries(projectID: projectID)
            deletedLoginEntries = try entryRepository.listDeletedLoginEntries(projectID: projectID)
            try refreshAutoFillEncryptedIndexIfConfigured()
            entryOperationState = .succeeded(String(localized: "已合并 \(currentPreview.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func undoLastDuplicateLoginMerge() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let undo = lastDuplicateLoginMergeUndo,
                  let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            for entryID in undo.restoredEntryIDs {
                _ = try entryRepository.restoreLoginEntry(projectID: projectID, entryID: entryID)
            }
            loginEntries = try entryRepository.listLoginEntries(projectID: projectID)
            deletedLoginEntries = try entryRepository.listDeletedLoginEntries(projectID: projectID)
            try refreshAutoFillEncryptedIndexIfConfigured()
            lastDuplicateLoginMergeUndo = nil
            entryOperationState = .succeeded(String(localized: "已撤销合并 \(undo.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func ignoreDuplicateLoginPreview(_ preview: AppDuplicateLoginMergePreview) {
        recordUserActivity()

        guard let group = duplicateLoginGroups(in: loginEntries, excludingIgnored: false)
            .first(where: { group in
                "duplicate-login-\(group.entries[0].id)" == preview.id
            })
        else {
            return
        }

        ignoredDuplicateLoginKeys.insert(group.key)
        entryOperationState = .succeeded(String(localized: "已忽略 \(preview.title)"))
    }

    func clearIgnoredDuplicateLoginPreviews() {
        recordUserActivity()
        ignoredDuplicateLoginKeys.removeAll()
        entryOperationState = .succeeded(String(localized: "已恢复重复项提示"))
    }

    func restoreLoginEntry(_ entry: LocalLoginEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreLoginEntry(
                projectID: projectID,
                entryID: entry.id
            )
            loginEntries = try entryRepository.listLoginEntries(projectID: projectID)
            deletedLoginEntries = try entryRepository.listDeletedLoginEntries(projectID: projectID)
            try refreshAutoFillEncryptedIndexIfConfigured()
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .login,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded(String(localized: "已恢复 \(restored.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func createNoteEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project: LocalVaultProject
            if let activeProject {
                project = activeProject
            } else {
                project = try entryRepository.createProject(title: projectTitle)
                activeProject = project
            }
            let entry = try entryRepository.createNoteEntry(
                projectID: project.id,
                draft: LocalNoteEntryDraft(title: noteTitle, body: noteBody)
            )
            noteEntries = try entryRepository.listNoteEntries(projectID: project.id)
            deletedNoteEntries = try entryRepository.listDeletedNoteEntries(projectID: project.id)
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .note,
                itemID: entry.id,
                itemTitle: entry.title
            )
            completeNoteDraftCommit(noteID: entry.id, body: entry.body)
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func selectNoteEntryForEditing(_ entry: LocalNoteEntry) {
        recordUserActivity()
        editingNoteEntryID = entry.id
        editingNoteTitle = entry.title
        editingNoteBody = entry.body
        editingNoteFavorite = entry.favorite
    }

    func updateSelectedNoteEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingNoteEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let entry = try entryRepository.updateNoteEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalNoteEntryDraft(title: editingNoteTitle, body: editingNoteBody)
            )
            noteEntries = try entryRepository.listNoteEntries(projectID: projectID)
            deletedNoteEntries = try entryRepository.listDeletedNoteEntries(projectID: projectID)
            selectNoteEntryForEditing(entry)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .note,
                itemID: entry.id,
                itemTitle: entry.title
            )
            completeNoteDraftCommit(noteID: entry.id, body: entry.body)
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedNoteFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingNoteEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setNoteEntryFavorite(
                projectID: projectID,
                entryID: entryID,
                favorite: favorite
            )
            noteEntries = try entryRepository.listNoteEntries(projectID: projectID)
            selectNoteEntryForEditing(updated)
            entryOperationState = .succeeded(favorite ? String(localized: "已收藏 \(updated.title)") : String(localized: "已取消收藏 \(updated.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedNoteEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingNoteEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingNoteTitle
            try entryRepository.deleteNoteEntry(projectID: projectID, entryID: entryID)
            noteEntries = try entryRepository.listNoteEntries(projectID: projectID)
            deletedNoteEntries = try entryRepository.listDeletedNoteEntries(projectID: projectID)
            clearEditingNoteEntry()
            if let store = noteDraftStore {
                try? store.deleteDraft(draftID: AppNoteDraftPolicy.draftID(noteID: entryID))
            }
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .note,
                itemID: entryID,
                itemTitle: deletedTitle
            )
            entryOperationState = .succeeded(String(localized: "已删除 \(deletedTitle)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func restoreNoteEntry(_ entry: LocalNoteEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreNoteEntry(
                projectID: projectID,
                entryID: entry.id
            )
            noteEntries = try entryRepository.listNoteEntries(projectID: projectID)
            deletedNoteEntries = try entryRepository.listDeletedNoteEntries(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .note,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded(String(localized: "已恢复 \(restored.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func createTotpEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project: LocalVaultProject
            if let activeProject {
                project = activeProject
            } else {
                project = try entryRepository.createProject(title: projectTitle)
                activeProject = project
            }
            let entry = try entryRepository.createTotpEntry(
                projectID: project.id,
                draft: try advancedTotpDraft(
                    title: totpTitle,
                    secret: totpSecret,
                    issuer: totpIssuer,
                    accountName: totpAccountName,
                    period: totpPeriod,
                    digits: totpDigits,
                    algorithm: totpAlgorithm,
                    otpType: OtpType(storageValue: totpOtpType),
                    counter: totpCounter,
                    iconName: totpIconName
                )
            )
            totpSecret = ""
            totpCounter = 0
            totpEntries = try entryRepository.listTotpEntries(projectID: project.id)
            deletedTotpEntries = try entryRepository.listDeletedTotpEntries(projectID: project.id)
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .totp,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func importTotpURI(_ value: String) throws {
        try importTotpURI(value, source: .manualURI)
    }

    func importScannedTotpQRCode(_ value: String) throws {
        try importTotpURI(value, source: .scannedQRCode)
    }

    func importSteamAuthenticator(_ data: Data) throws {
        recordUserActivity()

        do {
            let draft = try SteamAuthenticatorImportParser.parse(data)
            guard let period = UInt32(exactly: draft.period) else {
                throw TotpError.invalidPeriod
            }
            guard let digits = UInt32(exactly: draft.digits) else {
                throw TotpError.invalidDigits
            }

            totpTitle = draft.title
            totpSecret = draft.secret
            totpIssuer = draft.issuer
            totpAccountName = draft.accountName
            totpPeriod = period
            totpDigits = digits
            totpAlgorithm = draft.algorithm.rawValue
            totpOtpType = draft.otpType.rawValue
            totpCounter = draft.counter
            totpIconName = ""
            totpImportURI = ""
            entryOperationState = .succeeded(String(localized: "已导入 \(draft.redactedSummary)"))
        } catch {
            entryOperationState = .failed(readableSteamImportErrorMessage(for: error))
            throw error
        }
    }

    private func importTotpURI(_ value: String, source: TotpImportSource) throws {
        recordUserActivity()

        do {
            let draft = try TotpURIParser.parse(value)
            guard let period = UInt32(exactly: draft.period) else {
                throw TotpError.invalidPeriod
            }
            guard let digits = UInt32(exactly: draft.digits) else {
                throw TotpError.invalidDigits
            }

            totpTitle = draft.title
            totpSecret = draft.secret
            totpIssuer = draft.issuer
            totpAccountName = draft.accountName
            totpPeriod = period
            totpDigits = digits
            totpAlgorithm = draft.algorithm.rawValue
            totpOtpType = draft.otpType.rawValue
            totpCounter = draft.counter
            totpIconName = ""
            totpImportURI = ""
            entryOperationState = .succeeded(String(localized: "已导入 \(draft.title)"))
        } catch {
            entryOperationState = .failed(readableTotpImportErrorMessage(for: error, source: source))
            throw error
        }
    }

    private func readableTotpImportErrorMessage(for error: Error, source: TotpImportSource) -> String {
        guard let totpError = error as? TotpError else {
            return error.localizedDescription
        }

        switch (source, totpError) {
        case (.scannedQRCode, .invalidURI):
            return String(localized: "扫描到的二维码不是 TOTP 设置码。")
        case (.manualURI, .invalidURI):
            return String(localized: "请输入有效的 otpauth:// TOTP 设置 URI。")
        case (.scannedQRCode, .invalidSecret):
            return String(localized: "扫描到的二维码包含无效的 TOTP 密钥。")
        case (.manualURI, .invalidSecret):
            return String(localized: "TOTP 设置 URI 包含无效密钥。")
        case (.scannedQRCode, .invalidDigits):
            return String(localized: "扫描到的二维码使用了不支持的 TOTP 位数。")
        case (.manualURI, .invalidDigits):
            return String(localized: "TOTP 设置 URI 使用了不支持的位数。")
        case (.scannedQRCode, .invalidPeriod):
            return String(localized: "扫描到的二维码使用了不支持的 TOTP 周期。")
        case (.manualURI, .invalidPeriod):
            return String(localized: "TOTP 设置 URI 使用了不支持的周期。")
        case (.scannedQRCode, .invalidAlgorithm):
            return String(localized: "扫描到的二维码使用了不支持的 TOTP 算法。")
        case (.manualURI, .invalidAlgorithm):
            return String(localized: "TOTP 设置 URI 使用了不支持的算法。")
        }
    }

    private func readableSteamImportErrorMessage(for error: Error) -> String {
        guard let totpError = error as? TotpError else {
            return error.localizedDescription
        }

        switch totpError {
        case .invalidSecret:
            return String(localized: "Steam 验证器文件缺少有效密钥。")
        case .invalidURI:
            return String(localized: "请输入有效的 Steam maFile/JSON 验证器文件。")
        case .invalidDigits, .invalidPeriod, .invalidAlgorithm:
            return String(localized: "无法导入该 Steam 验证器文件。")
        }
    }

    func selectTotpEntryForEditing(_ entry: LocalTotpEntry) {
        recordUserActivity()
        editingTotpEntryID = entry.id
        editingTotpTitle = entry.title
        editingTotpSecret = entry.secret
        editingTotpIssuer = entry.issuer
        editingTotpAccountName = entry.accountName
        editingTotpPeriod = entry.period
        editingTotpDigits = entry.digits
        editingTotpAlgorithm = entry.algorithm
        editingTotpOtpType = OtpType(storageValue: entry.otpType).rawValue
        editingTotpCounter = entry.counter
        editingTotpIconName = entry.iconName
        editingTotpFavorite = entry.favorite
    }

    func updateSelectedTotpEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingTotpEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let entry = try entryRepository.updateTotpEntry(
                projectID: projectID,
                entryID: entryID,
                draft: try advancedTotpDraft(
                    title: editingTotpTitle,
                    secret: editingTotpSecret,
                    issuer: editingTotpIssuer,
                    accountName: editingTotpAccountName,
                    period: editingTotpPeriod,
                    digits: editingTotpDigits,
                    algorithm: editingTotpAlgorithm,
                    otpType: OtpType(storageValue: editingTotpOtpType),
                    counter: editingTotpCounter,
                    iconName: editingTotpIconName
                )
            )
            totpEntries = try entryRepository.listTotpEntries(projectID: projectID)
            deletedTotpEntries = try entryRepository.listDeletedTotpEntries(projectID: projectID)
            selectTotpEntryForEditing(entry)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .totp,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedTotpFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingTotpEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setTotpEntryFavorite(
                projectID: projectID,
                entryID: entryID,
                favorite: favorite
            )
            totpEntries = try entryRepository.listTotpEntries(projectID: projectID)
            selectTotpEntryForEditing(updated)
            entryOperationState = .succeeded(favorite ? String(localized: "已收藏 \(updated.title)") : String(localized: "已取消收藏 \(updated.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedTotpEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingTotpEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingTotpTitle
            try entryRepository.deleteTotpEntry(projectID: projectID, entryID: entryID)
            totpEntries = try entryRepository.listTotpEntries(projectID: projectID)
            deletedTotpEntries = try entryRepository.listDeletedTotpEntries(projectID: projectID)
            clearEditingTotpEntry()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .totp,
                itemID: entryID,
                itemTitle: deletedTitle
            )
            entryOperationState = .succeeded(String(localized: "已删除 \(deletedTitle)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func restoreTotpEntry(_ entry: LocalTotpEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreTotpEntry(
                projectID: projectID,
                entryID: entry.id
            )
            totpEntries = try entryRepository.listTotpEntries(projectID: projectID)
            deletedTotpEntries = try entryRepository.listDeletedTotpEntries(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .totp,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded(String(localized: "已恢复 \(restored.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func createCardEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project: LocalVaultProject
            if let activeProject {
                project = activeProject
            } else {
                project = try entryRepository.createProject(title: projectTitle)
                activeProject = project
            }
            let entry = try entryRepository.createCardEntry(
                projectID: project.id,
                draft: LocalCardEntryDraft(
                    title: cardTitle,
                    cardholderName: cardholderName,
                    number: cardNumber,
                    expiryMonth: cardExpiryMonth,
                    expiryYear: cardExpiryYear,
                    cvv: cardCVV,
                    issuer: cardIssuer,
                    network: cardNetwork,
                    notes: cardNotes
                )
            )
            cardNumber = ""
            cardCVV = ""
            cardEntries = try entryRepository.listCardEntries(projectID: project.id)
            deletedCardEntries = try entryRepository.listDeletedCardEntries(projectID: project.id)
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .card,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            cardNumber = ""
            cardCVV = ""
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func selectCardEntryForEditing(_ entry: LocalCardEntry) {
        recordUserActivity()
        editingCardEntryID = entry.id
        editingCardTitle = entry.title
        editingCardholderName = entry.cardholderName
        editingCardNumber = entry.number
        editingCardExpiryMonth = entry.expiryMonth
        editingCardExpiryYear = entry.expiryYear
        editingCardCVV = entry.cvv
        editingCardIssuer = entry.issuer
        editingCardNetwork = entry.network
        editingCardNotes = entry.notes
        editingCardFavorite = entry.favorite
    }

    func updateSelectedCardEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingCardEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let entry = try entryRepository.updateCardEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalCardEntryDraft(
                    title: editingCardTitle,
                    cardholderName: editingCardholderName,
                    number: editingCardNumber,
                    expiryMonth: editingCardExpiryMonth,
                    expiryYear: editingCardExpiryYear,
                    cvv: editingCardCVV,
                    issuer: editingCardIssuer,
                    network: editingCardNetwork,
                    notes: editingCardNotes
                )
            )
            cardEntries = try entryRepository.listCardEntries(projectID: projectID)
            deletedCardEntries = try entryRepository.listDeletedCardEntries(projectID: projectID)
            selectCardEntryForEditing(entry)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .card,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedCardFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingCardEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setCardEntryFavorite(
                projectID: projectID,
                entryID: entryID,
                favorite: favorite
            )
            cardEntries = try entryRepository.listCardEntries(projectID: projectID)
            selectCardEntryForEditing(updated)
            entryOperationState = .succeeded(favorite ? String(localized: "已收藏 \(updated.title)") : String(localized: "已取消收藏 \(updated.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedCardEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingCardEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingCardTitle
            try entryRepository.deleteCardEntry(projectID: projectID, entryID: entryID)
            cardEntries = try entryRepository.listCardEntries(projectID: projectID)
            deletedCardEntries = try entryRepository.listDeletedCardEntries(projectID: projectID)
            clearEditingCardEntry()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .card,
                itemID: entryID,
                itemTitle: deletedTitle
            )
            entryOperationState = .succeeded(String(localized: "已删除 \(deletedTitle)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func restoreCardEntry(_ entry: LocalCardEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreCardEntry(
                projectID: projectID,
                entryID: entry.id
            )
            cardEntries = try entryRepository.listCardEntries(projectID: projectID)
            deletedCardEntries = try entryRepository.listDeletedCardEntries(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .card,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded(String(localized: "已恢复 \(restored.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func createIdentityEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project: LocalVaultProject
            if let activeProject {
                project = activeProject
            } else {
                project = try entryRepository.createProject(title: projectTitle)
                activeProject = project
            }
            let entry = try entryRepository.createIdentityEntry(
                projectID: project.id,
                draft: LocalIdentityEntryDraft(
                    title: identityTitle,
                    documentType: identityDocumentType,
                    fullName: identityFullName,
                    documentNumber: identityDocumentNumber,
                    issuer: identityIssuer,
                    country: identityCountry,
                    issueDate: identityIssueDate,
                    expiryDate: identityExpiryDate,
                    notes: identityNotes
                )
            )
            identityEntries = try entryRepository.listIdentityEntries(projectID: project.id)
            deletedIdentityEntries = try entryRepository.listDeletedIdentityEntries(projectID: project.id)
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .identity,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func selectIdentityEntryForEditing(_ entry: LocalIdentityEntry) {
        recordUserActivity()
        editingIdentityEntryID = entry.id
        editingIdentityTitle = entry.title
        editingIdentityDocumentType = entry.documentType
        editingIdentityFullName = entry.fullName
        editingIdentityDocumentNumber = entry.documentNumber
        editingIdentityIssuer = entry.issuer
        editingIdentityCountry = entry.country
        editingIdentityIssueDate = entry.issueDate
        editingIdentityExpiryDate = entry.expiryDate
        editingIdentityNotes = entry.notes
        editingIdentityFavorite = entry.favorite
    }

    func updateSelectedIdentityEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingIdentityEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let entry = try entryRepository.updateIdentityEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalIdentityEntryDraft(
                    title: editingIdentityTitle,
                    documentType: editingIdentityDocumentType,
                    fullName: editingIdentityFullName,
                    documentNumber: editingIdentityDocumentNumber,
                    issuer: editingIdentityIssuer,
                    country: editingIdentityCountry,
                    issueDate: editingIdentityIssueDate,
                    expiryDate: editingIdentityExpiryDate,
                    notes: editingIdentityNotes
                )
            )
            identityEntries = try entryRepository.listIdentityEntries(projectID: projectID)
            deletedIdentityEntries = try entryRepository.listDeletedIdentityEntries(projectID: projectID)
            selectIdentityEntryForEditing(entry)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .identity,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedIdentityFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingIdentityEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setIdentityEntryFavorite(
                projectID: projectID,
                entryID: entryID,
                favorite: favorite
            )
            identityEntries = try entryRepository.listIdentityEntries(projectID: projectID)
            selectIdentityEntryForEditing(updated)
            entryOperationState = .succeeded(favorite ? String(localized: "已收藏 \(updated.title)") : String(localized: "已取消收藏 \(updated.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedIdentityEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingIdentityEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingIdentityTitle
            try entryRepository.deleteIdentityEntry(projectID: projectID, entryID: entryID)
            identityEntries = try entryRepository.listIdentityEntries(projectID: projectID)
            deletedIdentityEntries = try entryRepository.listDeletedIdentityEntries(projectID: projectID)
            clearEditingIdentityEntry()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .identity,
                itemID: entryID,
                itemTitle: deletedTitle
            )
            entryOperationState = .succeeded(String(localized: "已删除 \(deletedTitle)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func restoreIdentityEntry(_ entry: LocalIdentityEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreIdentityEntry(
                projectID: projectID,
                entryID: entry.id
            )
            identityEntries = try entryRepository.listIdentityEntries(projectID: projectID)
            deletedIdentityEntries = try entryRepository.listDeletedIdentityEntries(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .identity,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded(String(localized: "已恢复 \(restored.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func createPasskeyEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project: LocalVaultProject
            if let activeProject {
                project = activeProject
            } else {
                project = try entryRepository.createProject(title: projectTitle)
                activeProject = project
            }
            let entry = try entryRepository.createPasskeyEntry(
                projectID: project.id,
                draft: LocalPasskeyEntryDraft(
                    title: passkeyTitle,
                    relyingPartyID: try normalizedPasskeyRelyingPartyID(passkeyRelyingPartyID),
                    username: passkeyUsername,
                    userHandle: passkeyUserHandle,
                    credentialID: passkeyCredentialID,
                    publicKeyCOSE: passkeyPublicKeyCOSE,
                    privateKeyReference: passkeyPrivateKeyReference,
                    notes: passkeyNotes
                )
            )
            passkeyPrivateKeyReference = ""
            passkeyEntries = try entryRepository.listPasskeyEntries(projectID: project.id)
            deletedPasskeyEntries = try entryRepository.listDeletedPasskeyEntries(projectID: project.id)
            try refreshAutoFillEncryptedIndexIfConfigured()
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .passkey,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func recordSystemPasskeyRegistration(
        _ result: AppSystemPasskeyRegistrationResult,
        projectTitle: String
    ) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project: LocalVaultProject
            if let activeProject {
                project = activeProject
            } else {
                project = try entryRepository.createProject(title: projectTitle)
                activeProject = project
            }

            let entry = try entryRepository.createPasskeyEntry(
                projectID: project.id,
                draft: try normalizedPasskeyDraft(result.metadataDraft)
            )
            passkeyCredentialID = ""
            passkeyPublicKeyCOSE = ""
            passkeyPrivateKeyReference = ""
            passkeyEntries = try entryRepository.listPasskeyEntries(projectID: project.id)
            deletedPasskeyEntries = try entryRepository.listDeletedPasskeyEntries(projectID: project.id)
            try refreshAutoFillEncryptedIndexIfConfigured()
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .passkey,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(String(localized: "Passkey 已保存：\(entry.title)"))
        } catch {
            AppDiagnosticEmission.passkeyFailure(error, stage: .register)
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func importPendingSystemPasskeyRegistrations(
        inboxStore: AppSystemPasskeyRegistrationInboxStore,
        projectTitle: String
    ) throws -> Int {
        guard vaultState == .unlocked else {
            throw AppAutoFillIndexError.vaultLocked
        }
        do {
            let registrations = try inboxStore.loadPendingRegistrations()
            guard !registrations.isEmpty else {
                return 0
            }

            for registration in registrations {
                try recordSystemPasskeyRegistration(
                    registration.registrationResult,
                    projectTitle: projectTitle
                )
            }
            try inboxStore.clearPendingRegistrations()
            return registrations.count
        } catch {
            AppDiagnosticEmission.passkeyFailure(error, stage: .importInbox)
            throw error
        }
    }

    func selectPasskeyEntryForEditing(_ entry: LocalPasskeyEntry) {
        recordUserActivity()
        editingPasskeyEntryID = entry.id
        editingPasskeyTitle = entry.title
        editingPasskeyRelyingPartyID = entry.relyingPartyID
        editingPasskeyUsername = entry.username
        editingPasskeyUserHandle = entry.userHandle
        editingPasskeyCredentialID = entry.credentialID
        editingPasskeyPublicKeyCOSE = entry.publicKeyCOSE
        editingPasskeyPrivateKeyReference = entry.privateKeyReference
        editingPasskeyNotes = entry.notes
        editingPasskeyFavorite = entry.favorite
    }

    func updateSelectedPasskeyEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingPasskeyEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let entry = try entryRepository.updatePasskeyEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalPasskeyEntryDraft(
                    title: editingPasskeyTitle,
                    relyingPartyID: try normalizedPasskeyRelyingPartyID(editingPasskeyRelyingPartyID),
                    username: editingPasskeyUsername,
                    userHandle: editingPasskeyUserHandle,
                    credentialID: editingPasskeyCredentialID,
                    publicKeyCOSE: editingPasskeyPublicKeyCOSE,
                    privateKeyReference: editingPasskeyPrivateKeyReference,
                    notes: editingPasskeyNotes
                )
            )
            passkeyEntries = try entryRepository.listPasskeyEntries(projectID: projectID)
            deletedPasskeyEntries = try entryRepository.listDeletedPasskeyEntries(projectID: projectID)
            selectPasskeyEntryForEditing(entry)
            try refreshAutoFillEncryptedIndexIfConfigured()
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .passkey,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedPasskeyFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingPasskeyEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setPasskeyEntryFavorite(
                projectID: projectID,
                entryID: entryID,
                favorite: favorite
            )
            passkeyEntries = try entryRepository.listPasskeyEntries(projectID: projectID)
            selectPasskeyEntryForEditing(updated)
            try refreshAutoFillEncryptedIndexIfConfigured()
            entryOperationState = .succeeded(favorite ? String(localized: "已收藏 \(updated.title)") : String(localized: "已取消收藏 \(updated.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedPasskeyEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingPasskeyEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingPasskeyTitle
            try entryRepository.deletePasskeyEntry(projectID: projectID, entryID: entryID)
            passkeyEntries = try entryRepository.listPasskeyEntries(projectID: projectID)
            deletedPasskeyEntries = try entryRepository.listDeletedPasskeyEntries(projectID: projectID)
            clearEditingPasskeyEntry()
            try refreshAutoFillEncryptedIndexIfConfigured()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .passkey,
                itemID: entryID,
                itemTitle: deletedTitle
            )
            entryOperationState = .succeeded(String(localized: "已删除 \(deletedTitle)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func restorePasskeyEntry(_ entry: LocalPasskeyEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restorePasskeyEntry(
                projectID: projectID,
                entryID: entry.id
            )
            passkeyEntries = try entryRepository.listPasskeyEntries(projectID: projectID)
            deletedPasskeyEntries = try entryRepository.listDeletedPasskeyEntries(projectID: projectID)
            try refreshAutoFillEncryptedIndexIfConfigured()
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .passkey,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded(String(localized: "已恢复 \(restored.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func createSshKeyEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project = try ensureActiveProject(projectTitle: projectTitle, entryRepository: entryRepository)
            let entry = try entryRepository.createSshKeyEntry(
                projectID: project.id,
                draft: LocalSshKeyEntryDraft(
                    title: sshKeyTitle,
                    username: sshKeyUsername,
                    host: sshKeyHost,
                    publicKey: sshKeyPublicKey,
                    privateKeyReference: sshKeyPrivateKeyReference,
                    passphraseHint: sshKeyPassphraseHint,
                    notes: sshKeyNotes
                )
            )
            sshKeyPrivateKeyReference = ""
            sshKeyEntries = try entryRepository.listSshKeyEntries(projectID: project.id)
            deletedSshKeyEntries = try entryRepository.listDeletedSshKeyEntries(projectID: project.id)
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .sshKey,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func selectSshKeyEntryForEditing(_ entry: LocalSshKeyEntry) {
        recordUserActivity()
        editingSshKeyEntryID = entry.id
        editingSshKeyTitle = entry.title
        editingSshKeyUsername = entry.username
        editingSshKeyHost = entry.host
        editingSshKeyPublicKey = entry.publicKey
        editingSshKeyPrivateKeyReference = entry.privateKeyReference
        editingSshKeyPassphraseHint = entry.passphraseHint
        editingSshKeyNotes = entry.notes
        editingSshKeyFavorite = entry.favorite
    }

    func updateSelectedSshKeyEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingSshKeyEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let entry = try entryRepository.updateSshKeyEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalSshKeyEntryDraft(
                    title: editingSshKeyTitle,
                    username: editingSshKeyUsername,
                    host: editingSshKeyHost,
                    publicKey: editingSshKeyPublicKey,
                    privateKeyReference: editingSshKeyPrivateKeyReference,
                    passphraseHint: editingSshKeyPassphraseHint,
                    notes: editingSshKeyNotes
                )
            )
            sshKeyEntries = try entryRepository.listSshKeyEntries(projectID: projectID)
            deletedSshKeyEntries = try entryRepository.listDeletedSshKeyEntries(projectID: projectID)
            selectSshKeyEntryForEditing(entry)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .sshKey,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedSshKeyFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingSshKeyEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setSshKeyEntryFavorite(projectID: projectID, entryID: entryID, favorite: favorite)
            sshKeyEntries = try entryRepository.listSshKeyEntries(projectID: projectID)
            selectSshKeyEntryForEditing(updated)
            entryOperationState = .succeeded(favorite ? String(localized: "已收藏 \(updated.title)") : String(localized: "已取消收藏 \(updated.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedSshKeyEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingSshKeyEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingSshKeyTitle
            try entryRepository.deleteSshKeyEntry(projectID: projectID, entryID: entryID)
            sshKeyEntries = try entryRepository.listSshKeyEntries(projectID: projectID)
            deletedSshKeyEntries = try entryRepository.listDeletedSshKeyEntries(projectID: projectID)
            clearEditingSshKeyEntry()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .sshKey,
                itemID: entryID,
                itemTitle: deletedTitle
            )
            entryOperationState = .succeeded(String(localized: "已删除 \(deletedTitle)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func restoreSshKeyEntry(_ entry: LocalSshKeyEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreSshKeyEntry(projectID: projectID, entryID: entry.id)
            sshKeyEntries = try entryRepository.listSshKeyEntries(projectID: projectID)
            deletedSshKeyEntries = try entryRepository.listDeletedSshKeyEntries(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .sshKey,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded(String(localized: "已恢复 \(restored.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func createApiTokenEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project = try ensureActiveProject(projectTitle: projectTitle, entryRepository: entryRepository)
            let entry = try entryRepository.createApiTokenEntry(
                projectID: project.id,
                draft: LocalApiTokenEntryDraft(
                    title: apiTokenTitle,
                    issuer: apiTokenIssuer,
                    accountName: apiTokenAccountName,
                    token: apiTokenToken,
                    scopes: apiTokenScopes,
                    expiresAt: apiTokenExpiresAt,
                    notes: apiTokenNotes
                )
            )
            apiTokenToken = ""
            apiTokenEntries = try entryRepository.listApiTokenEntries(projectID: project.id)
            deletedApiTokenEntries = try entryRepository.listDeletedApiTokenEntries(projectID: project.id)
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .apiToken,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func selectApiTokenEntryForEditing(_ entry: LocalApiTokenEntry) {
        recordUserActivity()
        editingApiTokenEntryID = entry.id
        editingApiTokenTitle = entry.title
        editingApiTokenIssuer = entry.issuer
        editingApiTokenAccountName = entry.accountName
        editingApiTokenToken = entry.token
        editingApiTokenScopes = entry.scopes
        editingApiTokenExpiresAt = entry.expiresAt
        editingApiTokenNotes = entry.notes
        editingApiTokenFavorite = entry.favorite
    }

    func updateSelectedApiTokenEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingApiTokenEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let entry = try entryRepository.updateApiTokenEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalApiTokenEntryDraft(
                    title: editingApiTokenTitle,
                    issuer: editingApiTokenIssuer,
                    accountName: editingApiTokenAccountName,
                    token: editingApiTokenToken,
                    scopes: editingApiTokenScopes,
                    expiresAt: editingApiTokenExpiresAt,
                    notes: editingApiTokenNotes
                )
            )
            apiTokenEntries = try entryRepository.listApiTokenEntries(projectID: projectID)
            deletedApiTokenEntries = try entryRepository.listDeletedApiTokenEntries(projectID: projectID)
            selectApiTokenEntryForEditing(entry)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .apiToken,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedApiTokenFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingApiTokenEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setApiTokenEntryFavorite(projectID: projectID, entryID: entryID, favorite: favorite)
            apiTokenEntries = try entryRepository.listApiTokenEntries(projectID: projectID)
            selectApiTokenEntryForEditing(updated)
            entryOperationState = .succeeded(favorite ? String(localized: "已收藏 \(updated.title)") : String(localized: "已取消收藏 \(updated.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedApiTokenEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingApiTokenEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingApiTokenTitle
            try entryRepository.deleteApiTokenEntry(projectID: projectID, entryID: entryID)
            apiTokenEntries = try entryRepository.listApiTokenEntries(projectID: projectID)
            deletedApiTokenEntries = try entryRepository.listDeletedApiTokenEntries(projectID: projectID)
            clearEditingApiTokenEntry()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .apiToken,
                itemID: entryID,
                itemTitle: deletedTitle
            )
            entryOperationState = .succeeded(String(localized: "已删除 \(deletedTitle)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func restoreApiTokenEntry(_ entry: LocalApiTokenEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreApiTokenEntry(projectID: projectID, entryID: entry.id)
            apiTokenEntries = try entryRepository.listApiTokenEntries(projectID: projectID)
            deletedApiTokenEntries = try entryRepository.listDeletedApiTokenEntries(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .apiToken,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded(String(localized: "已恢复 \(restored.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func createWifiEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project = try ensureActiveProject(projectTitle: projectTitle, entryRepository: entryRepository)
            let entry = try entryRepository.createWifiEntry(
                projectID: project.id,
                draft: LocalWifiEntryDraft(
                    title: wifiTitle,
                    ssid: wifiSSID,
                    securityType: wifiSecurityType,
                    password: wifiPassword,
                    hidden: wifiHidden,
                    notes: wifiNotes
                )
            )
            wifiPassword = ""
            wifiEntries = try entryRepository.listWifiEntries(projectID: project.id)
            deletedWifiEntries = try entryRepository.listDeletedWifiEntries(projectID: project.id)
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .wifi,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func selectWifiEntryForEditing(_ entry: LocalWifiEntry) {
        recordUserActivity()
        editingWifiEntryID = entry.id
        editingWifiTitle = entry.title
        editingWifiSSID = entry.ssid
        editingWifiSecurityType = entry.securityType
        editingWifiPassword = entry.password
        editingWifiHidden = entry.hidden
        editingWifiNotes = entry.notes
        editingWifiFavorite = entry.favorite
    }

    func updateSelectedWifiEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingWifiEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let entry = try entryRepository.updateWifiEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalWifiEntryDraft(
                    title: editingWifiTitle,
                    ssid: editingWifiSSID,
                    securityType: editingWifiSecurityType,
                    password: editingWifiPassword,
                    hidden: editingWifiHidden,
                    notes: editingWifiNotes
                )
            )
            wifiEntries = try entryRepository.listWifiEntries(projectID: projectID)
            deletedWifiEntries = try entryRepository.listDeletedWifiEntries(projectID: projectID)
            selectWifiEntryForEditing(entry)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .wifi,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedWifiFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingWifiEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setWifiEntryFavorite(projectID: projectID, entryID: entryID, favorite: favorite)
            wifiEntries = try entryRepository.listWifiEntries(projectID: projectID)
            selectWifiEntryForEditing(updated)
            entryOperationState = .succeeded(favorite ? String(localized: "已收藏 \(updated.title)") : String(localized: "已取消收藏 \(updated.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedWifiEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingWifiEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingWifiTitle
            try entryRepository.deleteWifiEntry(projectID: projectID, entryID: entryID)
            wifiEntries = try entryRepository.listWifiEntries(projectID: projectID)
            deletedWifiEntries = try entryRepository.listDeletedWifiEntries(projectID: projectID)
            clearEditingWifiEntry()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .wifi,
                itemID: entryID,
                itemTitle: deletedTitle
            )
            entryOperationState = .succeeded(String(localized: "已删除 \(deletedTitle)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func restoreWifiEntry(_ entry: LocalWifiEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreWifiEntry(projectID: projectID, entryID: entry.id)
            wifiEntries = try entryRepository.listWifiEntries(projectID: projectID)
            deletedWifiEntries = try entryRepository.listDeletedWifiEntries(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .wifi,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded(String(localized: "已恢复 \(restored.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func createSendEntry(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let project = try ensureActiveProject(projectTitle: projectTitle, entryRepository: entryRepository)
            let entry = try entryRepository.createSendEntry(
                projectID: project.id,
                draft: LocalSendEntryDraft(
                    title: sendTitle,
                    body: sendBody,
                    expiresAt: sendExpiresAt,
                    maxViews: sendMaxViews,
                    notes: sendNotes
                )
            )
            sendBody = ""
            sendEntries = try entryRepository.listSendEntries(projectID: project.id)
            deletedSendEntries = try entryRepository.listDeletedSendEntries(projectID: project.id)
            appendOperationTimelineEvent(
                action: .created,
                itemKind: .send,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    @discardableResult
    func createBitwardenFileSend(
        title: String,
        fileName: String,
        fileContent: Data,
        mediaType: String,
        notes: String,
        expiresAt: String,
        maxViews: Int,
        password: String?,
        hideEmail: Bool
    ) async throws -> BitwardenSyncPushResult {
        recordUserActivity()
        bitwardenSyncState = .running
        entryOperationState = .running

        do {
            let session = try requireActiveVaultSession()
            let provider = try requireBitwardenSyncProvider()
            let snapshot = try await provider.pullSnapshot()
            let preview = AppBitwardenSyncPreview(snapshot: snapshot)
            let previousItemStates = try bitwardenItemSyncStateStore.loadStates(vaultID: session.handle.vaultID)
            let previousSendStates = try bitwardenSendSyncStateStore.loadStates(vaultID: session.handle.vaultID)
            try validateBitwardenRemoteSnapshotIsSafe(
                snapshot,
                previousItemStates: previousItemStates,
                previousSendStates: previousSendStates
            )
            bitwardenSyncPreview = preview
            let localID = bitwardenFileSendLocalIDProvider()
            let sanitizedFileName = sanitizedAttachmentPreviewFileName(fileName)
            let mutation = BitwardenSyncMutation.upsertFileSend(
                localID: localID,
                remoteID: nil,
                title: title,
                fileName: sanitizedFileName,
                fileContent: fileContent,
                mediaType: mediaType.nonBlankValue ?? "application/octet-stream",
                notes: notes.nonBlankValue,
                expiresAt: expiresAt,
                maxViews: maxViews,
                password: password?.nonBlankValue,
                hideEmail: hideEmail
            )
            let result: BitwardenSyncPushResult
            do {
                result = try await provider.pushMutations([mutation])
            } catch {
                throw error
            }

            var statesByLocalID = Dictionary(uniqueKeysWithValues: previousSendStates.map { ($0.localID, $0) })
            statesByLocalID[localID] = BitwardenSendSyncState(
                localID: localID,
                remoteID: result.assignedRemoteIDs[localID],
                lastSyncedFingerprint: bitwardenFileSendFingerprint(
                    title: title,
                    fileName: sanitizedFileName,
                    byteCount: fileContent.count,
                    notes: notes.nonBlankValue,
                    expiresAt: expiresAt,
                    maxViews: maxViews,
                    hideEmail: hideEmail
                ),
                lastRemoteRevision: result.revision.nonBlankValue,
                isDeleted: false
            )
            try bitwardenSendSyncStateStore.saveStates(
                statesByLocalID.values.sorted { $0.localID < $1.localID },
                vaultID: session.handle.vaultID
            )
            bitwardenSyncState = .pushed(
                acceptedMutationCount: result.acceptedMutationCount,
                conflictCount: result.conflicts.count
            )
            entryOperationState = .succeeded(title)
            return result
        } catch {
            if case .queuedForRetry = bitwardenSyncState {
                entryOperationState = .failed(readableBitwardenSyncErrorMessage(for: error))
                throw error
            }
            let message = readableBitwardenSyncErrorMessage(for: error)
            bitwardenSyncState = .failed(message)
            entryOperationState = .failed(message)
            throw error
        }
    }

    /// 创建文本型 Bitwarden Send 并保留分享链接。
    /// 与文件型相同，先 pull 一次做安全检查，再推送到远端。
    @discardableResult
    func createBitwardenTextSend(
        title: String,
        text: String,
        notes: String,
        expiresAt: String,
        maxViews: Int,
        password: String?,
        hideEmail: Bool
    ) async throws -> BitwardenTextSendCreateResult {
        recordUserActivity()
        bitwardenSyncState = .running
        entryOperationState = .running

        do {
            let session = try requireActiveVaultSession()
            let provider = try requireBitwardenSyncProvider()
            let snapshot = try await provider.pullSnapshot()
            let previousItemStates = try bitwardenItemSyncStateStore.loadStates(vaultID: session.handle.vaultID)
            let previousSendStates = try bitwardenSendSyncStateStore.loadStates(vaultID: session.handle.vaultID)
            try validateBitwardenRemoteSnapshotIsSafe(
                snapshot,
                previousItemStates: previousItemStates,
                previousSendStates: previousSendStates
            )

            let result = try await provider.createTextSend(
                BitwardenTextSendCreateRequest(
                    title: title,
                    text: text,
                    notes: notes.nonBlankValue,
                    expiresAt: expiresAt,
                    maxViews: maxViews,
                    password: password?.nonBlankValue,
                    hideEmail: hideEmail
                )
            )

            // 记录同步状态，让后续同步不会把它当成新条目重复上传。
            let localID = bitwardenTextSendLocalIDProvider()
            var statesByLocalID = Dictionary(uniqueKeysWithValues: previousSendStates.map { ($0.localID, $0) })
            statesByLocalID[localID] = BitwardenSendSyncState(
                localID: localID,
                remoteID: result.remoteID,
                lastSyncedFingerprint: bitwardenTextSendFingerprint(
                    title: title,
                    body: text,
                    notes: notes.nonBlankValue,
                    expiresAt: expiresAt,
                    maxViews: maxViews
                ),
                lastRemoteRevision: result.revision.isEmpty ? nil : result.revision
            )
            try bitwardenSendSyncStateStore.saveStates(
                Array(statesByLocalID.values),
                vaultID: session.handle.vaultID
            )

            // 链接只在创建时可得；顺带把内容也落成本地 Send 条目，方便在列表里回看。
            if let entryRepository = activeEntryRepository,
               let projectID = activeProject?.id {
                _ = try? entryRepository.createSendEntry(
                    projectID: projectID,
                    draft: LocalSendEntryDraft(
                        title: title,
                        body: text,
                        expiresAt: expiresAt,
                        maxViews: maxViews,
                        notes: notes
                    )
                )
                sendEntries = (try? entryRepository.listSendEntries(projectID: projectID)) ?? sendEntries
            }

            bitwardenSendShareLink = result.link.flatMap { link in
                bitwardenSendLinkURL(link)
            }
            bitwardenSyncState = .idle
            entryOperationState = .succeeded(result.redactedSummary)
            sendTitle = ""
            sendBody = ""
            sendNotes = ""
            sendPassword = ""
            sendMaxViews = 1
            return result
        } catch {
            bitwardenSyncState = .failed(readableBitwardenSyncErrorMessage(for: error))
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    /// 用 web vault 地址拼出完整链接；API 地址与 web 域名不同，需从 session 推导。
    private func bitwardenSendLinkURL(_ link: BitwardenSendLink) -> String? {
        // Bitwarden 约定：api.bitwarden.com ↔ vault.bitwarden.com。
        // 自托管时 serverURL 与 apiURL 通常同源，直接用 serverURL。
        guard let serverURL = bitwardenSendWebVaultURL() else { return nil }
        return link.url(serverBaseURL: serverURL)?.absoluteString
    }

    /// web vault 地址：Bitwarden 官方约定 api.bitwarden.com ↔ vault.bitwarden.com；
    /// 自托管时 serverURL 与 apiURL 同源，直接用 serverURL。
    private func bitwardenSendWebVaultURL() -> URL? {
        guard let session = try? bitwardenAuthenticationSessionStore.loadSession() else {
            return URL(string: "https://vault.bitwarden.com")
        }
        let serverURL = session.serverURL
        if let host = serverURL.host(), !host.isEmpty {
            if host.hasPrefix("api.") {
                return URL(string: "https://vault." + host.dropFirst("api.".count))
            }
            return serverURL
        }
        return URL(string: "https://vault.bitwarden.com")
    }

    /// 匿名接收 Send：不需要登录，只需要链接（和可能的访问密码）。
    @discardableResult
    func receiveBitwardenSend(linkInput: String, password: String) async throws -> BitwardenReceivedSend {
        recordUserActivity()
        bitwardenReceiveState = .running

        do {
            let trimmed = linkInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw AppBitwardenSyncError.invalidSendLink
            }
            guard let serverURL = bitwardenSendWebVaultURL(),
                  let apiURL = bitwardenSendAPIURL()
            else {
                throw AppBitwardenSyncError.invalidSendLink
            }
            guard let link = BitwardenSendLink.parse(urlString: trimmed, serverBaseURL: serverURL) else {
                throw AppBitwardenSyncError.invalidSendLink
            }
            // 接收端不依赖登录态；provider 若未装配就用默认实现（仍可匿名 GET）。
            let provider = bitwardenSyncProvider ?? DefaultBitwardenSyncProvider()
            let received = try await provider.fetchSend(
                BitwardenSendFetchRequest(
                    link: link,
                    password: password.nonBlankValue,
                    apiURL: apiURL
                )
            )
            bitwardenReceivedSend = received
            bitwardenReceiveState = .succeeded(received.title)
            bitwardenReceivePassword = ""
            return received
        } catch {
            bitwardenReceivedSend = nil
            bitwardenReceiveState = .failed(readableBitwardenSyncErrorMessage(for: error))
            throw error
        }
    }

    private func bitwardenSendAPIURL() -> URL? {
        if let session = try? bitwardenAuthenticationSessionStore.loadSession() {
            return session.apiURL
        }
        return URL(string: "https://api.bitwarden.com")
    }

    func clearBitwardenReceiveResult() {
        bitwardenReceivedSend = nil
        bitwardenReceiveState = .idle
        bitwardenReceiveLinkInput = ""
        bitwardenReceivePassword = ""
    }

    func createSelectedBitwardenFileSend() async throws -> BitwardenSyncPushResult {
        guard let fileContent = sendFileContent,
              !sendFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AppBitwardenSyncError.fileSendUnavailable
        }
        let result = try await createBitwardenFileSend(
            title: sendTitle,
            fileName: sendFileName,
            fileContent: fileContent,
            mediaType: sendFileMediaType,
            notes: sendNotes,
            expiresAt: sendExpiresAt,
            maxViews: sendMaxViews,
            password: sendPassword,
            hideEmail: sendHideEmail
        )
        sendFileName = ""
        sendFileContent = nil
        sendFileMediaType = "application/octet-stream"
        sendPassword = ""
        return result
    }

    func selectBitwardenSendFile(url: URL) throws {
        recordUserActivity()
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        sendFileContent = try Data(contentsOf: url)
        sendFileName = sanitizedAttachmentPreviewFileName(url.lastPathComponent)
        sendFileMediaType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        if sendTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sendTitle = sendFileName
        }
    }

    func selectSendEntryForEditing(_ entry: LocalSendEntry) {
        recordUserActivity()
        editingSendEntryID = entry.id
        editingSendTitle = entry.title
        editingSendBody = entry.body
        editingSendExpiresAt = entry.expiresAt
        editingSendMaxViews = entry.maxViews
        editingSendNotes = entry.notes
        editingSendFavorite = entry.favorite
    }

    func updateSelectedSendEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingSendEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let entry = try entryRepository.updateSendEntry(
                projectID: projectID,
                entryID: entryID,
                draft: LocalSendEntryDraft(
                    title: editingSendTitle,
                    body: editingSendBody,
                    expiresAt: editingSendExpiresAt,
                    maxViews: editingSendMaxViews,
                    notes: editingSendNotes
                )
            )
            sendEntries = try entryRepository.listSendEntries(projectID: projectID)
            deletedSendEntries = try entryRepository.listDeletedSendEntries(projectID: projectID)
            selectSendEntryForEditing(entry)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .send,
                itemID: entry.id,
                itemTitle: entry.title
            )
            entryOperationState = .succeeded(entry.title)
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func setSelectedSendFavorite(_ favorite: Bool) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingSendEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let updated = try entryRepository.setSendEntryFavorite(projectID: projectID, entryID: entryID, favorite: favorite)
            sendEntries = try entryRepository.listSendEntries(projectID: projectID)
            selectSendEntryForEditing(updated)
            entryOperationState = .succeeded(favorite ? String(localized: "已收藏 \(updated.title)") : String(localized: "已取消收藏 \(updated.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteSelectedSendEntry() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id,
                  let entryID = editingSendEntryID
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let deletedTitle = editingSendTitle
            try entryRepository.deleteSendEntry(projectID: projectID, entryID: entryID)
            sendEntries = try entryRepository.listSendEntries(projectID: projectID)
            deletedSendEntries = try entryRepository.listDeletedSendEntries(projectID: projectID)
            clearEditingSendEntry()
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .send,
                itemID: entryID,
                itemTitle: deletedTitle
            )
            entryOperationState = .succeeded(String(localized: "已删除 \(deletedTitle)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func restoreSendEntry(_ entry: LocalSendEntry) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreSendEntry(projectID: projectID, entryID: entry.id)
            sendEntries = try entryRepository.listSendEntries(projectID: projectID)
            deletedSendEntries = try entryRepository.listDeletedSendEntries(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .send,
                itemID: restored.id,
                itemTitle: restored.title
            )
            entryOperationState = .succeeded(String(localized: "已恢复 \(restored.title)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteAttachmentEntry(_ entry: LocalAttachmentMetadata) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            try entryRepository.deleteAttachmentMetadata(projectID: projectID, attachmentID: entry.id)
            attachmentEntries = try entryRepository.listAttachmentMetadata(projectID: projectID)
            deletedAttachmentEntries = try entryRepository.listDeletedAttachmentMetadata(projectID: projectID)
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .attachmentRef,
                itemID: entry.id,
                itemTitle: entry.fileName
            )
            entryOperationState = .succeeded(String(localized: "已删除 \(entry.fileName)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func restoreAttachmentEntry(_ entry: LocalAttachmentMetadata) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let restored = try entryRepository.restoreAttachmentMetadata(projectID: projectID, attachmentID: entry.id)
            attachmentEntries = try entryRepository.listAttachmentMetadata(projectID: projectID)
            deletedAttachmentEntries = try entryRepository.listDeletedAttachmentMetadata(projectID: projectID)
            appendOperationTimelineEvent(
                action: .restored,
                itemKind: .attachmentRef,
                itemID: restored.id,
                itemTitle: restored.fileName
            )
            entryOperationState = .succeeded(String(localized: "已恢复 \(restored.fileName)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func refreshExtendedParityEntries() throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            sshKeyEntries = try entryRepository.listSshKeyEntries(projectID: projectID)
            deletedSshKeyEntries = try entryRepository.listDeletedSshKeyEntries(projectID: projectID)
            apiTokenEntries = try entryRepository.listApiTokenEntries(projectID: projectID)
            deletedApiTokenEntries = try entryRepository.listDeletedApiTokenEntries(projectID: projectID)
            wifiEntries = try entryRepository.listWifiEntries(projectID: projectID)
            deletedWifiEntries = try entryRepository.listDeletedWifiEntries(projectID: projectID)
            ssoEntries = try entryRepository.listSSOEntries(projectID: projectID)
            deletedSSOEntries = try entryRepository.listDeletedSSOEntries(projectID: projectID)
            sendEntries = try entryRepository.listSendEntries(projectID: projectID)
            deletedSendEntries = try entryRepository.listDeletedSendEntries(projectID: projectID)
            attachmentEntries = try entryRepository.listAttachmentMetadata(projectID: projectID)
            deletedAttachmentEntries = try entryRepository.listDeletedAttachmentMetadata(projectID: projectID)
            entryOperationState = .succeeded(String(localized: "已刷新扩展通行条目"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func previewCSVImport(_ csv: String) -> CSVImportPreview {
        recordUserActivity()
        let report = VaultCSVCodec.importItems(from: csv)
        let preview = CSVImportPreview(report: report)
        csvImportPreview = preview
        androidBackupImportPreview = nil
        clearKeePassImportState()
        entryOperationState = .succeeded(String(localized: "CSV 预览：\(report.items.count) 项可导入，\(report.issues.count) 个问题"))
        return preview
    }

    func previewCSVImport(from fileURL: URL) throws -> CSVImportPreview {
        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        let csv = try String(contentsOf: fileURL, encoding: .utf8)
        return previewCSVImport(csv)
    }

    func confirmCSVImport(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let preview = csvImportPreview else {
                throw LocalVaultRepositoryError.invalidEntryPayload
            }
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }

            let project = try ensureActiveProject(projectTitle: projectTitle, entryRepository: entryRepository)
            for item in preview.items {
                _ = try createCSVImportedItem(item, projectID: project.id, entryRepository: entryRepository)
            }
            try refreshAllEntryLists(projectID: project.id, entryRepository: entryRepository)
            try refreshAutoFillEncryptedIndexIfConfigured()
            csvImportPreview = nil
            entryOperationState = .succeeded(String(localized: "CSV 已导入 \(preview.items.count) 项"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    // MARK: - 凭据交换（CXF，iOS 26+）

    /// 系统完成导入握手后通过 NSUserActivity 调用；令牌只保留在内存里。
    func handleCredentialExchangeActivity(_ activity: NSUserActivity) {
        guard #available(iOS 26.0, *) else { return }
        guard activity.activityType == ASCredentialExchangeActivity else { return }
        guard let token = activity.userInfo?[ASCredentialImportToken] as? UUID else {
            credentialExchange.importError = "系统没有提供可用的凭据导入令牌，本地保险库未做改动。"
            return
        }
        recordUserActivity()
        credentialExchange.importError = nil
        guard vaultState == .unlocked else {
            credentialExchange.pendingImportToken = token
            return
        }
        Task { await fetchCredentialExchangeImport(token: token) }
    }

    /// 解锁完成后继续处理系统已经交给 App 的导入令牌。
    func continuePendingCredentialExchangeImportIfAvailable() {
        guard #available(iOS 26.0, *) else { return }
        guard vaultState == .unlocked, let token = credentialExchange.pendingImportToken else { return }
        credentialExchange.pendingImportToken = nil
        Task { await fetchCredentialExchangeImport(token: token) }
    }

    private func fetchCredentialExchangeImport(token: UUID) async {
        guard #available(iOS 26.0, *), vaultState == .unlocked else {
            credentialExchange.pendingImportToken = token
            return
        }
        if credentialExchange.isFetchingImport {
            credentialExchange.pendingImportToken = token
            return
        }
        credentialExchange.isFetchingImport = true
        credentialExchange.importError = nil
        entryOperationState = .running
        defer { credentialExchange.isFetchingImport = false }

        do {
            let data = try await ASCredentialImportManager().importCredentials(token: token)
            guard data.formatVersion.rawValue == CredentialExchangeFormat.supportedVersion else {
                credentialExchange.importError = "不支持的凭据交换版本 \(data.formatVersion.rawValue)。本地保险库未做改动。"
                entryOperationState = .failed("不支持的凭据交换版本")
                return
            }
            let plan = CredentialExchangeCodec.importPlan(
                accounts: AppCredentialExchangeBridge.accounts(from: data),
                existingLoginEntries: loginEntries,
                existingTOTPEntries: totpEntries
            )
            guard !plan.isEmpty else {
                credentialExchange.importError = emptyCredentialExchangeMessage(plan)
                entryOperationState = .failed("没有可导入的凭据")
                return
            }
            credentialExchange.importPreview = AppCredentialExchangeImportPreview(
                plan: plan,
                exporterDisplayName: data.exporterDisplayName,
                formatVersion: data.formatVersion.rawValue
            )
            entryOperationState = .idle
        } catch {
            credentialExchange.importError = credentialExchangeFailureMessage(
                prefix: "无法读取系统提供的凭据",
                error: error
            )
            entryOperationState = .failed("系统凭据读取失败")
        }
    }

    func confirmCredentialExchangeImport() throws {
        recordUserActivity()
        guard let preview = credentialExchange.importPreview else {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        guard let entryRepository = activeEntryRepository else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }

        credentialExchange.isImporting = true
        credentialExchange.importError = nil
        entryOperationState = .running
        defer { credentialExchange.isImporting = false }

        var projectID: String?
        var created: [(VaultCSVItemDraft, String)] = []
        do {
            let project = try ensureActiveProject(projectTitle: "凭据交换", entryRepository: entryRepository)
            projectID = project.id
            for item in preview.plan.drafts {
                if let entryID = try createCSVImportedItem(
                    item,
                    projectID: project.id,
                    entryRepository: entryRepository
                ) {
                    created.append((item, entryID))
                }
            }
            try refreshAllEntryLists(projectID: project.id, entryRepository: entryRepository)
            try refreshAutoFillEncryptedIndexIfConfigured()
            credentialExchange.importPreview = nil
            credentialExchange.importError = nil
            entryOperationState = .succeeded("凭据已导入 \(created.count) 项")
        } catch {
            let rollbackIncomplete = rollbackCredentialExchangeImport(
                created,
                projectID: projectID,
                entryRepository: entryRepository
            )
            credentialExchange.importError = rollbackIncomplete
                ? "导入失败，且部分条目未能回滚，请检查「凭据交换」项目：\(error.localizedDescription)"
                : "导入失败，已回滚本次改动：\(error.localizedDescription)"
            entryOperationState = .failed("凭据导入失败")
            throw error
        }
    }

    func cancelCredentialExchangeImport() {
        credentialExchange.importPreview = nil
        credentialExchange.importError = nil
        credentialExchange.isImporting = false
        credentialExchange.pendingImportToken = nil
    }

    @discardableResult
    private func rollbackCredentialExchangeImport(
        _ created: [(VaultCSVItemDraft, String)],
        projectID: String?,
        entryRepository: LocalVaultEntryRepository
    ) -> Bool {
        guard let projectID else {
            return !created.isEmpty
        }
        var incomplete = false
        for (item, entryID) in created.reversed() {
            do {
                try deleteCSVImportedItem(
                    item,
                    entryID: entryID,
                    projectID: projectID,
                    entryRepository: entryRepository
                )
            } catch {
                incomplete = true
            }
        }
        try? refreshAllEntryLists(projectID: projectID, entryRepository: entryRepository)
        try? refreshAutoFillEncryptedIndexIfConfigured()
        return incomplete
    }

    private func emptyCredentialExchangeMessage(_ plan: CredentialExchangeImportPlan) -> String {
        if plan.skippedDuplicateCount > 0,
           plan.unsupportedCredentialCount == 0,
           plan.invalidCredentialCount == 0 {
            return "这些凭据已经存在于本地保险库，没有新增任何条目。"
        }
        if plan.unsupportedCredentialCount > 0,
           plan.skippedDuplicateCount == 0,
           plan.invalidCredentialCount == 0 {
            return "系统提供的条目暂不支持迁移（例如通行密钥），本地保险库未做改动。"
        }
        return "没有找到可导入的密码或 TOTP，本地保险库未做改动。"
    }

    /// 系统错误只暴露 domain/code，避免把凭据内容带进日志或界面。
    private func credentialExchangeFailureMessage(prefix: String, error: Error) -> String {
        let nsError = error as NSError
        return "\(prefix)（\(nsError.domain) \(nsError.code)）。本地保险库未做改动。"
    }

    @discardableResult
    func prepareCredentialExchangeExport() -> Bool {
        guard #available(iOS 26.0, *) else {
            credentialExchange.exportError = "凭据交换需要 iOS 26 或更新版本。"
            return false
        }
        guard vaultState == .unlocked else {
            credentialExchange.exportError = "请先解锁保险库再导出。"
            return false
        }
        credentialExchange.exportError = nil
        credentialExchange.exportMessage = nil
        let plan = CredentialExchangeCodec.exportPlan(
            loginEntries: loginEntries,
            totpEntries: totpEntries
        )
        guard !plan.isEmpty else {
            credentialExchange.exportError = plan.skippedCount > 0
                ? "没有可导出的密码或 TOTP；另有 \(plan.skippedCount) 条 TOTP 密钥无效。"
                : "没有可导出的密码或 TOTP。"
            return false
        }
        credentialExchange.exportPlan = plan
        return true
    }

    @discardableResult
    func performCredentialExchangeExport() async -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        guard let plan = credentialExchange.exportPlan else { return false }
        guard let anchor = AppCredentialExchangePresenter.keyWindow() else {
            credentialExchange.exportError = "找不到可用于系统导出面板的窗口。"
            return false
        }

        credentialExchange.isExporting = true
        credentialExchange.exportError = nil
        defer { credentialExchange.isExporting = false }

        do {
            let manager = ASCredentialExportManager(presentationAnchor: anchor)
            let options = try await manager.requestExport(for: nil)
            guard options.formatVersion.rawValue == CredentialExchangeFormat.supportedVersion else {
                credentialExchange.exportError = "接收方请求了不支持的版本 \(options.formatVersion.rawValue)。"
                return false
            }
            try await manager.exportCredentials(AppCredentialExchangeBridge.exportedData(from: plan))
            credentialExchange.exportPlan = nil
            credentialExchange.exportMessage = "已导出 \(plan.passwordCount) 条密码、\(plan.totpCount) 条 TOTP。"
            entryOperationState = .idle
            return true
        } catch {
            credentialExchange.exportError = credentialExchangeFailureMessage(
                prefix: "导出没有完成",
                error: error
            )
            return false
        }
    }

    func cancelCredentialExchangeExport() {
        credentialExchange.exportPlan = nil
        credentialExchange.exportError = nil
        credentialExchange.isExporting = false
    }

    func previewKeePassImport(
        _ data: Data,
        fileName: String? = nil
    ) throws -> KeePassImportPreview {
        recordUserActivity()
        let report = KeePassFormatInspector.inspect(data, sourceName: fileName)
        if let issue = report.issue {
            clearKeePassImportState()
            csvImportPreview = nil
            androidBackupImportPreview = nil
            entryOperationState = .failed(issue.message)
            throw KeePassOperationError(code: issue.code, message: issue.message)
        }

        let preview = KeePassImportPreview(report: report, unlockPreflight: nil)
        keePassImportPreview = preview
        keePassPendingDatabaseData = data
        keePassPendingDatabaseName = fileName
        keePassSourceFileURL = nil
        keePassCloudFileSource = nil
        keePassReadOnlySnapshot = nil
        keePassReadOnlyImportPlan = nil
        keePassLastMetadataImportReferences = []
        keePassUnlockPassword = ""
        keePassKeyFileData = nil
        keePassKeyFileName = ""
        csvImportPreview = nil
        androidBackupImportPreview = nil
        clearPendingAndroidEncryptedBackup()
        entryOperationState = .succeeded(String(localized: "KeePass 预览：\(report.format.localizedDisplayName) 数据库，等待密码或密钥文件解锁"))
        return preview
    }

    func previewKeePassImport(from fileURL: URL) throws -> KeePassImportPreview {
        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: fileURL)
        let preview = try previewKeePassImport(data, fileName: fileURL.lastPathComponent)
        keePassSourceFileURL = fileURL
        return preview
    }

    func previewKeePassImport(
        fromCloudFile download: CloudFileDownload,
        provider kind: CloudFileProviderKind
    ) throws -> KeePassImportPreview {
        let fileName = sanitizedCloudFileName(download.item.name)
        let preview = try previewKeePassImport(download.data, fileName: fileName)
        keePassSourceFileURL = nil
        keePassCloudFileSource = AppKeePassCloudFileSource(
            provider: kind,
            itemID: download.item.id,
            fileName: fileName,
            revision: download.revision
        )
        cloudFileRestorePreview = AppCloudFileRestorePreview(
            provider: kind,
            download: download
        )
        downloadedCloudFileRestore = download
        return preview
    }

    func prepareKeePassUnlockPreflight(
        password: String? = nil,
        keyFile: Data? = nil,
        keyFileName: String? = nil
    ) throws -> KeePassUnlockPreflightReport {
        recordUserActivity()
        guard let databaseData = keePassPendingDatabaseData else {
            let message = String(localized: "请先选择 KDBX 数据库文件")
            entryOperationState = .failed(message)
            throw KeePassOperationError(code: .formatUnsupported, message: message)
        }

        if let password {
            keePassUnlockPassword = password
        }
        if let keyFile {
            keePassKeyFileData = keyFile
        }
        if let keyFileName {
            keePassKeyFileName = sanitizedKeePassFileName(keyFileName) ?? ""
        }
        keePassReadOnlySnapshot = nil
        keePassReadOnlyImportPlan = nil
        keePassLastSuccessfulUnlockCredentials = nil

        let preflight = KeePassFormatInspector.prepareUnlock(
            databaseData,
            sourceName: keePassPendingDatabaseName,
            password: password ?? keePassUnlockPassword,
            keyFile: keyFile ?? keePassKeyFileData,
            keyFileName: keyFileName ?? keePassKeyFileName
        )

        if let issue = preflight.issue {
            entryOperationState = .failed(issue.message)
            throw KeePassOperationError(code: issue.code, message: issue.message)
        }

        if let preview = keePassImportPreview {
            keePassImportPreview = KeePassImportPreview(
                report: preview.report,
                unlockPreflight: preflight
            )
        }
        let version = preflight.headerSummary?.displayName ?? preflight.format.localizedDisplayName
        entryOperationState = .succeeded(String(localized: "KeePass 解锁输入已准备：\(version)，\(preflight.credentials.localizedDisplayName)"))
        return preflight
    }

    func previewKeePassReadOnlyTree() throws -> KeePassReadOnlySnapshot {
        recordUserActivity()
        guard let databaseData = keePassPendingDatabaseData else {
            let message = String(localized: "请先选择 KDBX 数据库文件")
            entryOperationState = .failed(message)
            throw KeePassOperationError(code: .formatUnsupported, message: message)
        }

        do {
            _ = try prepareKeePassUnlockPreflight()
            let (snapshot, successfulCredentials) = try readKeePassSnapshotTryingCredentialCandidates(
                database: databaseData,
                sourceName: keePassPendingDatabaseName,
                credentials: KeePassUnlockCredentials(
                    password: keePassUnlockPassword,
                    keyFile: keePassKeyFileData,
                    keyFileName: keePassKeyFileName
                )
            )
            keePassReadOnlySnapshot = snapshot
            keePassLastSuccessfulUnlockCredentials = successfulCredentials
            keePassReadOnlyImportPlan = nil
            entryOperationState = .succeeded(String(localized: "KeePass 只读预览：\(snapshot.displaySummary)"))
            return snapshot
        } catch {
            keePassReadOnlySnapshot = nil
            keePassReadOnlyImportPlan = nil
            keePassLastSuccessfulUnlockCredentials = nil
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func previewKeePassReadOnlyImportPlan() throws -> KeePassReadOnlyImportPlan {
        recordUserActivity()

        do {
            let snapshot: KeePassReadOnlySnapshot
            if let existingSnapshot = keePassReadOnlySnapshot {
                snapshot = existingSnapshot
            } else {
                snapshot = try previewKeePassReadOnlyTree()
            }
            let plan = KeePassReadOnlyImportPlanner.plan(snapshot)
            keePassReadOnlyImportPlan = plan
            entryOperationState = .succeeded(String(localized: "KeePass 导入计划：\(plan.displaySummary)"))
            return plan
        } catch {
            keePassReadOnlyImportPlan = nil
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func confirmKeePassReadOnlyImport(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            let plan: KeePassReadOnlyImportPlan
            if let existingPlan = keePassReadOnlyImportPlan {
                plan = existingPlan
            } else {
                plan = try previewKeePassReadOnlyImportPlan()
            }
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let vaultSession = try requireActiveVaultSession()

            var firstImportedProject: LocalVaultProject?
            var importedReferences: [AppKeePassImportedEntryReference] = []
            var importedTotpPlaceholderCount = 0
            var importedDecodedPasswordCount = 0
            var importedDecodedTotpSecretCount = 0
            var importedAttachmentPlaceholderCount = 0
            var importedDecodedAttachmentContentCount = 0
            var importedNotesFieldCount = 0
            var importedDeletedMetadataCount = 0
            for candidate in plan.candidates {
                let project = try ensureKeePassImportProject(
                    baseTitle: projectTitle,
                    groupPath: candidate.groupPath,
                    entryRepository: entryRepository
                )
                if firstImportedProject == nil {
                    firstImportedProject = project
                }
                let importedEntry = try entryRepository.createLoginEntry(
                    projectID: project.id,
                    draft: LocalLoginEntryDraft(
                        title: candidate.title,
                        username: candidate.username,
                        password: candidate.decodedPassword ?? "",
                        url: candidate.url,
                        notes: keePassLoginNotes(for: candidate)
                    )
                )
                if !candidate.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    !candidate.customFields.isEmpty {
                    importedNotesFieldCount += 1
                }
                if candidate.hasPassword && candidate.decodedPassword != nil {
                    importedDecodedPasswordCount += 1
                }
                let importedTotpEntryID: String?
                if candidate.hasTotp {
                    let importedTotpEntry = try entryRepository.createTotpEntry(
                        projectID: project.id,
                        draft: keePassTotpDraft(for: candidate)
                    )
                    importedTotpEntryID = importedTotpEntry.id
                    if candidate.decodedTotp == nil {
                        importedTotpPlaceholderCount += 1
                    } else {
                        importedDecodedTotpSecretCount += 1
                    }
                    if candidate.isDeleted {
                        try entryRepository.deleteTotpEntry(
                            projectID: project.id,
                            entryID: importedTotpEntry.id
                        )
                    }
                } else {
                    importedTotpEntryID = nil
                }
                var importedAttachmentEntryIDs: [String] = []
                for attachment in candidate.attachments {
                    let attachmentFileName = keePassAttachmentFileName(attachment)
                    let decodedAttachmentLocalPath: String?
                    if let decodedContent = attachment.decodedContent {
                        decodedAttachmentLocalPath = try androidBackupAttachmentBlobStore.saveEncryptedBlob(
                            decodedContent,
                            vaultID: vaultSession.handle.vaultID,
                            localPath: keePassDecodedAttachmentLocalPath(
                                attachment,
                                fileName: attachmentFileName
                            )
                        )
                        importedDecodedAttachmentContentCount += 1
                    } else {
                        decodedAttachmentLocalPath = nil
                    }
                    let importedAttachment = try entryRepository.createAttachmentMetadata(
                        projectID: project.id,
                        entryID: importedEntry.id,
                        fileName: attachmentFileName,
                        mediaType: attachment.mediaType,
                        originalSize: attachment.originalSize,
                        storedSize: Int64(attachment.decodedContent?.count ?? 0),
                        contentHash: attachment.contentHash,
                        storageMode: decodedAttachmentLocalPath == nil
                            ? "keepass-kdbx-placeholder"
                            : "keepass-kdbx-decoded-content",
                        source: "KeePass",
                        downloadState: decodedAttachmentLocalPath == nil
                            ? "pending-kdbx-decode"
                            : "downloaded",
                        localPath: decodedAttachmentLocalPath
                    )
                    importedAttachmentEntryIDs.append(importedAttachment.id)
                    if decodedAttachmentLocalPath == nil {
                        importedAttachmentPlaceholderCount += 1
                    }
                    if candidate.isDeleted {
                        try entryRepository.deleteAttachmentMetadata(
                            projectID: project.id,
                            attachmentID: importedAttachment.id
                        )
                    }
                }
                if candidate.isDeleted {
                    try entryRepository.deleteLoginEntry(
                        projectID: project.id,
                        entryID: importedEntry.id
                    )
                    importedDeletedMetadataCount += 1
                }
                importedReferences.append(
                    AppKeePassImportedEntryReference(
                        sourceEntryID: candidate.id,
                        sourceGroupID: candidate.groupID,
                        sourceGroupPath: candidate.groupPath,
                        importedLoginEntryID: importedEntry.id,
                        importedTotpEntryID: importedTotpEntryID,
                        importedProjectID: project.id,
                        importedAsDeleted: candidate.isDeleted,
                        importedAttachmentEntryIDs: importedAttachmentEntryIDs
                    )
                )
            }
            if let firstImportedProject {
                activeProject = firstImportedProject
            }
            if let activeProject {
                try refreshAllEntryLists(projectID: activeProject.id, entryRepository: entryRepository)
                selectedVaultQuickFilterID = "category-\(activeProject.id)"
            }
            try refreshAutoFillEncryptedIndexIfConfigured()
            keePassLastMetadataImportReferences = importedReferences
            clearKeePassImportState(preservingLastMetadataImportReferences: true)
            let pendingSummary = plan.pendingCapabilitySummary
            let importedDecodedContentCount = importedDecodedPasswordCount
                + importedDecodedTotpSecretCount
                + importedDecodedAttachmentContentCount
                + importedNotesFieldCount
            let pendingText = pendingSummary.isEmpty
                ? (importedDecodedContentCount > 0 ? "" : String(localized: "，秘密字段待 KDBX 解码器接入"))
                : "；\(pendingSummary)"
            let totpPlaceholderText = importedTotpPlaceholderCount > 0
                ? String(localized: "，并创建 \(importedTotpPlaceholderCount) 个 TOTP 占位项")
                : ""
            let decodedPasswordText = importedDecodedPasswordCount > 0
                ? String(localized: "，并导入 \(importedDecodedPasswordCount) 个密码字段")
                : ""
            let decodedTotpText = importedDecodedTotpSecretCount > 0
                ? String(localized: "，并导入 \(importedDecodedTotpSecretCount) 个 TOTP 密钥")
                : ""
            let decodedAttachmentText = importedDecodedAttachmentContentCount > 0
                ? String(localized: "，并导入 \(importedDecodedAttachmentContentCount) 个附件内容")
                : ""
            let notesFieldText = importedNotesFieldCount > 0
                ? String(localized: "，并导入 \(importedNotesFieldCount) 项备注/自定义字段")
                : ""
            let attachmentPlaceholderText = importedAttachmentPlaceholderCount > 0
                ? String(localized: "，并创建 \(importedAttachmentPlaceholderCount) 个附件占位项")
                : ""
            let deletedText = importedDeletedMetadataCount > 0
                ? String(localized: "，并保留 \(importedDeletedMetadataCount) 项回收站元数据")
                : ""
            entryOperationState = .succeeded(String(localized: "KeePass 已导入 \(plan.candidateCount) 项元数据\(decodedPasswordText)\(decodedTotpText)\(decodedAttachmentText)\(notesFieldText)\(totpPlaceholderText)\(attachmentPlaceholderText)\(deletedText)\(pendingText)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func importKeePassKeyFile(from fileURL: URL) throws {
        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        keePassKeyFileData = try Data(contentsOf: fileURL)
        keePassKeyFileName = sanitizedKeePassFileName(fileURL.lastPathComponent) ?? "keyfile"
        keePassReadOnlySnapshot = nil
        keePassReadOnlyImportPlan = nil
        entryOperationState = .succeeded(String(localized: "KeePass 密钥文件已选择：\(keePassKeyFileName)"))
    }

    func writeKeePassKdbx4Database(_ result: KeePassKdbx4WritebackResult) throws {
        try writeKeePassKdbxDatabase(AppKeePassKdbxWritebackResult(result))
    }

    private func writeKeePassKdbxDatabase(_ result: AppKeePassKdbxWritebackResult) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let sourceURL = keePassSourceFileURL else {
                throw AppKeePassKdbxWritebackError.sourceFileUnavailable
            }
            let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }
            try keePassKdbxFileWritebackService.replaceFile(
                at: sourceURL,
                with: result.database
            )
            keePassPendingDatabaseData = result.database
            keePassPendingDatabaseName = sourceURL.lastPathComponent
            entryOperationState = .succeeded(
                String(localized: "KeePass 数据库已写回：\(result.entryCount) 个条目，\(result.attachmentCount) 个附件，\(result.database.count) bytes")
            )
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    private func makeKeePassReadOnlySnapshotWritebackResult() throws -> AppKeePassKdbxWritebackResult {
        let snapshot: KeePassReadOnlySnapshot
        if let existingSnapshot = keePassReadOnlySnapshot {
            snapshot = existingSnapshot
        } else {
            snapshot = try previewKeePassReadOnlyTree()
        }
        switch try currentKeePassKdbxEnvelope().headerSummary.formatVersion {
        case .kdbx3:
            return AppKeePassKdbxWritebackResult(
                try keePassKdbx3WritebackCoordinator.writeDatabase(
                    try makeKeePassKdbx3WritebackRequest(snapshot: snapshot)
                )
            )
        case .kdbx4:
            return AppKeePassKdbxWritebackResult(
                try keePassKdbx4WritebackCoordinator.writeDatabase(
                    try makeKeePassKdbx4WritebackRequest(snapshot: snapshot)
                )
            )
        case .unknown:
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: String(localized: "无法写回未知版本的 KDBX 文件。")
            )
        }
    }

    func writeKeePassReadOnlySnapshotBackToSource() throws -> AppKeePassKdbxWritebackResult {
        recordUserActivity()
        entryOperationState = .running

        do {
            let result = try makeKeePassReadOnlySnapshotWritebackResult()
            try writeKeePassKdbxDatabase(result)
            return result
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func writeKeePassReadOnlySnapshotBackToCloudSource() async throws -> AppKeePassKdbxWritebackResult {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let source = keePassCloudFileSource else {
                throw AppKeePassKdbxWritebackError.cloudSourceUnavailable
            }
            let result = try makeKeePassReadOnlySnapshotWritebackResult()
            cloudFileState = .running(source.provider)
            let provider = try cloudFileProvider(for: source.provider)
            let receipt = try await provider.overwriteFile(
                id: source.itemID,
                data: result.database,
                fileName: source.fileName,
                expectedRevision: source.revision
            )
            let fileName = sanitizedCloudFileName(receipt.name)
            keePassPendingDatabaseData = result.database
            keePassPendingDatabaseName = fileName
            keePassSourceFileURL = nil
            keePassCloudFileSource = AppKeePassCloudFileSource(
                provider: source.provider,
                itemID: source.itemID,
                fileName: fileName,
                revision: receipt.revision ?? source.revision
            )
            cloudFileState = .writeSucceeded(
                provider: source.provider,
                fileName: fileName,
                byteCount: receipt.byteCount
            )
            entryOperationState = .succeeded(
                String(localized: "KeePass 云文件已写回：\(source.provider.displayName) \(fileName)，\(result.entryCount) 个条目，\(result.attachmentCount) 个附件，\(result.database.count) bytes")
            )
            return result
        } catch {
            if let source = keePassCloudFileSource {
                cloudFileState = .failed(readableCloudFileErrorMessage(for: error, provider: source.provider))
            }
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func keePassAttachmentEditCandidates(
        matching query: String = ""
    ) throws -> [AppKeePassAttachmentEditCandidate] {
        let snapshot: KeePassReadOnlySnapshot
        if let existingSnapshot = keePassReadOnlySnapshot {
            snapshot = existingSnapshot
        } else {
            snapshot = try previewKeePassReadOnlyTree()
        }
        let normalizedQuery = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return snapshot.entries
            .flatMap { entry in
                entry.attachments.map { attachment in
                    let fileName = sanitizedAttachmentPreviewFileName(attachment.fileName)
                    let searchableText = [
                        entry.title,
                        entry.username,
                        entry.groupPath,
                        fileName,
                        attachment.mediaType,
                        attachment.id
                    ]
                    .joined(separator: " ")
                    return AppKeePassAttachmentEditCandidate(
                        id: "\(entry.id)::\(attachment.id)",
                        entryID: entry.id,
                        attachmentID: attachment.id,
                        entryTitle: entry.title,
                        entryUsername: entry.username,
                        groupPath: entry.groupPath,
                        fileName: fileName,
                        mediaType: attachment.mediaType,
                        originalSize: attachment.originalSize,
                        isDeletedEntry: entry.isDeleted,
                        searchableText: searchableText
                    )
                }
            }
            .filter { candidate in
                normalizedQuery.isEmpty || candidate.searchableText.lowercased().contains(normalizedQuery)
            }
    }

    func replaceKeePassReadOnlyAttachmentContent(
        entryID: String,
        attachmentID: String,
        decodedContent content: Data,
        fileName: String? = nil,
        mediaType: String? = nil
    ) throws -> KeePassReadOnlySnapshot {
        recordUserActivity()
        entryOperationState = .running

        do {
            let snapshot: KeePassReadOnlySnapshot
            if let existingSnapshot = keePassReadOnlySnapshot {
                snapshot = existingSnapshot
            } else {
                snapshot = try previewKeePassReadOnlyTree()
            }
            guard let entryIndex = snapshot.entries.firstIndex(where: { $0.id == entryID }) else {
                throw AppKeePassSnapshotEditError.entryUnavailable
            }
            let entry = snapshot.entries[entryIndex]
            guard let attachmentIndex = entry.attachments.firstIndex(where: { $0.id == attachmentID }) else {
                throw AppKeePassSnapshotEditError.attachmentUnavailable
            }
            let attachment = entry.attachments[attachmentIndex]
            let updatedAttachment = KeePassReadOnlyAttachment(
                id: attachment.id,
                fileName: sanitizedAttachmentPreviewFileName(fileName ?? attachment.fileName),
                mediaType: mediaType ?? attachment.mediaType,
                originalSize: Int64(content.count),
                contentHash: "sha256:\(sha256Hex(content))",
                decodedContent: content
            )
            var updatedAttachments = entry.attachments
            updatedAttachments[attachmentIndex] = updatedAttachment
            let updatedEntry = KeePassReadOnlyEntry(
                id: entry.id,
                title: entry.title,
                username: entry.username,
                url: entry.url,
                groupPath: entry.groupPath,
                groupID: entry.groupID,
                originalGroupPath: entry.originalGroupPath,
                originalGroupID: entry.originalGroupID,
                notes: entry.notes,
                customFields: entry.customFields,
                hasPassword: entry.hasPassword,
                decodedPassword: entry.decodedPassword,
                hasTotp: entry.hasTotp,
                decodedTotp: entry.decodedTotp,
                attachmentCount: updatedAttachments.count,
                isDeleted: entry.isDeleted,
                attachments: updatedAttachments
            )
            var updatedEntries = snapshot.entries
            updatedEntries[entryIndex] = updatedEntry
            let updatedSnapshot = KeePassReadOnlySnapshot(
                sourceName: snapshot.sourceName,
                headerSummary: snapshot.headerSummary,
                groups: snapshot.groups,
                entries: updatedEntries
            )
            keePassReadOnlySnapshot = updatedSnapshot
            keePassReadOnlyImportPlan = nil
            entryOperationState = .succeeded(
                String(localized: "KeePass 附件内容已替换：\(updatedAttachment.fileName) \(content.count) 字节")
            )
            return updatedSnapshot
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func addKeePassReadOnlyAttachmentContent(
        entryID: String,
        decodedContent content: Data,
        fileName: String,
        mediaType: String? = nil
    ) throws -> KeePassReadOnlySnapshot {
        recordUserActivity()
        entryOperationState = .running

        do {
            let snapshot: KeePassReadOnlySnapshot
            if let existingSnapshot = keePassReadOnlySnapshot {
                snapshot = existingSnapshot
            } else {
                snapshot = try previewKeePassReadOnlyTree()
            }
            guard let entryIndex = snapshot.entries.firstIndex(where: { $0.id == entryID }) else {
                throw AppKeePassSnapshotEditError.entryUnavailable
            }
            let entry = snapshot.entries[entryIndex]
            let sanitizedFileName = sanitizedAttachmentPreviewFileName(fileName)
            let attachment = KeePassReadOnlyAttachment(
                id: "ios-added-\(UUID().uuidString)",
                fileName: sanitizedFileName,
                mediaType: mediaType ?? "application/octet-stream",
                originalSize: Int64(content.count),
                contentHash: "sha256:\(sha256Hex(content))",
                decodedContent: content
            )
            let updatedAttachments = entry.attachments + [attachment]
            let updatedEntry = KeePassReadOnlyEntry(
                id: entry.id,
                title: entry.title,
                username: entry.username,
                url: entry.url,
                groupPath: entry.groupPath,
                groupID: entry.groupID,
                originalGroupPath: entry.originalGroupPath,
                originalGroupID: entry.originalGroupID,
                notes: entry.notes,
                customFields: entry.customFields,
                hasPassword: entry.hasPassword,
                decodedPassword: entry.decodedPassword,
                hasTotp: entry.hasTotp,
                decodedTotp: entry.decodedTotp,
                attachmentCount: updatedAttachments.count,
                isDeleted: entry.isDeleted,
                attachments: updatedAttachments
            )
            var updatedEntries = snapshot.entries
            updatedEntries[entryIndex] = updatedEntry
            let updatedSnapshot = KeePassReadOnlySnapshot(
                sourceName: snapshot.sourceName,
                headerSummary: snapshot.headerSummary,
                groups: snapshot.groups,
                entries: updatedEntries
            )
            keePassReadOnlySnapshot = updatedSnapshot
            keePassReadOnlyImportPlan = nil
            entryOperationState = .succeeded(
                String(localized: "KeePass 附件已添加：\(sanitizedFileName) \(content.count) 字节")
            )
            return updatedSnapshot
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func addKeePassReadOnlyAttachmentContentFromFileAndWriteBack(
        entryID: String,
        fileURL: URL,
        mediaType: String? = nil
    ) throws -> AppKeePassKdbxWritebackResult {
        recordUserActivity()
        entryOperationState = .running

        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let content = try Data(contentsOf: fileURL)
            let fileName = sanitizedAttachmentPreviewFileName(fileURL.lastPathComponent)
            _ = try addKeePassReadOnlyAttachmentContent(
                entryID: entryID,
                decodedContent: content,
                fileName: fileName,
                mediaType: mediaType
            )
            let result = try writeKeePassReadOnlySnapshotBackToSource()
            entryOperationState = .succeeded(
                String(localized: "KeePass 附件已添加并写回：\(fileName) \(content.count) 字节")
            )
            return result
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func deleteKeePassReadOnlyAttachmentAndWriteBack(
        entryID: String,
        attachmentID: String
    ) throws -> AppKeePassKdbxWritebackResult {
        recordUserActivity()
        entryOperationState = .running

        do {
            let snapshot: KeePassReadOnlySnapshot
            if let existingSnapshot = keePassReadOnlySnapshot {
                snapshot = existingSnapshot
            } else {
                snapshot = try previewKeePassReadOnlyTree()
            }
            guard let entryIndex = snapshot.entries.firstIndex(where: { $0.id == entryID }) else {
                throw AppKeePassSnapshotEditError.entryUnavailable
            }
            let entry = snapshot.entries[entryIndex]
            guard let attachmentIndex = entry.attachments.firstIndex(where: { $0.id == attachmentID }) else {
                throw AppKeePassSnapshotEditError.attachmentUnavailable
            }
            let attachment = entry.attachments[attachmentIndex]
            var updatedAttachments = entry.attachments
            updatedAttachments.remove(at: attachmentIndex)
            let updatedEntry = KeePassReadOnlyEntry(
                id: entry.id,
                title: entry.title,
                username: entry.username,
                url: entry.url,
                groupPath: entry.groupPath,
                groupID: entry.groupID,
                originalGroupPath: entry.originalGroupPath,
                originalGroupID: entry.originalGroupID,
                notes: entry.notes,
                customFields: entry.customFields,
                hasPassword: entry.hasPassword,
                decodedPassword: entry.decodedPassword,
                hasTotp: entry.hasTotp,
                decodedTotp: entry.decodedTotp,
                attachmentCount: updatedAttachments.count,
                isDeleted: entry.isDeleted,
                attachments: updatedAttachments
            )
            var updatedEntries = snapshot.entries
            updatedEntries[entryIndex] = updatedEntry
            let updatedSnapshot = KeePassReadOnlySnapshot(
                sourceName: snapshot.sourceName,
                headerSummary: snapshot.headerSummary,
                groups: snapshot.groups,
                entries: updatedEntries
            )
            keePassReadOnlySnapshot = updatedSnapshot
            keePassReadOnlyImportPlan = nil
            let result = try writeKeePassReadOnlySnapshotBackToSource()
            entryOperationState = .succeeded(
                String(localized: "KeePass 附件已删除并写回：\(sanitizedAttachmentPreviewFileName(attachment.fileName))")
            )
            return result
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func replaceKeePassReadOnlyAttachmentContentFromFileAndWriteBack(
        entryID: String,
        attachmentID: String,
        fileURL: URL,
        mediaType: String? = nil
    ) throws -> AppKeePassKdbxWritebackResult {
        recordUserActivity()
        entryOperationState = .running

        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let content = try Data(contentsOf: fileURL)
            let fileName = sanitizedAttachmentPreviewFileName(fileURL.lastPathComponent)
            _ = try replaceKeePassReadOnlyAttachmentContent(
                entryID: entryID,
                attachmentID: attachmentID,
                decodedContent: content,
                fileName: fileName,
                mediaType: mediaType
            )
            let result = try writeKeePassReadOnlySnapshotBackToSource()
            entryOperationState = .succeeded(
                String(localized: "KeePass 附件已替换并写回：\(fileName) \(content.count) 字节")
            )
            return result
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func restoreKeePassReadOnlyRecycleBinEntryAndWriteBack(
        entryID: String,
        targetGroupID: String? = nil
    ) throws -> AppKeePassKdbxWritebackResult {
        recordUserActivity()
        entryOperationState = .running

        do {
            let snapshot: KeePassReadOnlySnapshot
            if let existingSnapshot = keePassReadOnlySnapshot {
                snapshot = existingSnapshot
            } else {
                snapshot = try previewKeePassReadOnlyTree()
            }
            guard let entryIndex = snapshot.entries.firstIndex(where: { $0.id == entryID }) else {
                throw AppKeePassSnapshotEditError.entryUnavailable
            }
            let entry = snapshot.entries[entryIndex]
            guard entry.isDeleted else {
                throw AppKeePassSnapshotEditError.entryNotInRecycleBin
            }
            let recycleBinGroupIDs = Set(snapshot.entries.compactMap { candidate in
                candidate.isDeleted ? candidate.groupID : nil
            })
            let targetGroup: KeePassReadOnlyGroup
            if let originalGroupID = entry.originalGroupID,
               let originalGroup = snapshot.groups.first(where: { group in
                   group.id == originalGroupID && !recycleBinGroupIDs.contains(group.id)
               }) {
                targetGroup = originalGroup
            } else if let originalGroupPath = entry.originalGroupPath,
                      let originalGroup = snapshot.groups.first(where: { group in
                          group.path == originalGroupPath && !recycleBinGroupIDs.contains(group.id)
                      }) {
                targetGroup = originalGroup
            } else if let targetGroupID {
                guard let explicitGroup = snapshot.groups.first(where: { $0.id == targetGroupID }),
                      !recycleBinGroupIDs.contains(explicitGroup.id) else {
                    throw AppKeePassSnapshotEditError.targetGroupUnavailable
                }
                targetGroup = explicitGroup
            } else if let rootGroup = snapshot.groups.first(where: { group in
                group.path == "/" && !recycleBinGroupIDs.contains(group.id)
            }) {
                targetGroup = rootGroup
            } else if let fallbackGroup = snapshot.groups.first(where: { group in
                !recycleBinGroupIDs.contains(group.id)
            }) {
                targetGroup = fallbackGroup
            } else {
                throw AppKeePassSnapshotEditError.targetGroupUnavailable
            }
            let restoredEntry = KeePassReadOnlyEntry(
                id: entry.id,
                title: entry.title,
                username: entry.username,
                url: entry.url,
                groupPath: targetGroup.path,
                groupID: targetGroup.id,
                notes: entry.notes,
                customFields: entry.customFields,
                hasPassword: entry.hasPassword,
                decodedPassword: entry.decodedPassword,
                hasTotp: entry.hasTotp,
                decodedTotp: entry.decodedTotp,
                attachmentCount: entry.attachmentCount,
                isDeleted: false,
                attachments: entry.attachments
            )
            var updatedEntries = snapshot.entries
            updatedEntries[entryIndex] = restoredEntry
            let updatedSnapshot = KeePassReadOnlySnapshot(
                sourceName: snapshot.sourceName,
                headerSummary: snapshot.headerSummary,
                groups: snapshot.groups,
                entries: updatedEntries
            )
            keePassReadOnlySnapshot = updatedSnapshot
            keePassReadOnlyImportPlan = nil
            let result = try writeKeePassReadOnlySnapshotBackToSource()
            let displayTitle = restoredEntry.title.isEmpty ? String(localized: "未命名条目") : restoredEntry.title
            entryOperationState = .succeeded(
                String(localized: "KeePass 回收站条目已还原并写回：\(displayTitle) -> \(targetGroup.path)")
            )
            return result
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func previewAndroidBackupImport(
        _ data: Data,
        fileName: String? = nil,
        decryptPassword: String? = nil
    ) throws -> AndroidBackupImportPreview {
        recordUserActivity()
        let report = try AndroidBackupCodec.importItems(
            from: data,
            fileName: fileName,
            decryptPassword: decryptPassword
        )
        if let encryptedIssue = report.issues.first(where: { $0.code == .encryptedBackupUnsupported }) {
            androidBackupImportPreview = nil
            csvImportPreview = nil
            clearKeePassImportState()
            entryOperationState = .failed(encryptedIssue.message)
            throw AppAndroidBackupImportError.unsupportedEncryptedBackup(encryptedIssue.message)
        }
        if let decryptIssue = report.issues.first(where: { $0.code == .encryptedBackupDecryptionFailed }) {
            androidBackupImportPreview = nil
            csvImportPreview = nil
            clearKeePassImportState()
            entryOperationState = .failed(decryptIssue.message)
            throw AppAndroidBackupImportError.encryptedBackupDecryptionFailed(decryptIssue.message)
        }
        let preview = AndroidBackupImportPreview(report: report)
        androidBackupImportPreview = preview
        csvImportPreview = nil
        clearKeePassImportState()
        clearPendingAndroidEncryptedBackup()
        let trashText = report.deletedItems.isEmpty ? "" : String(localized: "，\(report.deletedItems.count) 项回收站")
        let attachmentText = report.attachments.isEmpty ? "" : String(localized: "，\(report.attachments.count) 个附件")
        entryOperationState = .succeeded(String(localized: "移动端备份预览：\(report.items.count) 项可导入\(trashText)\(attachmentText)，\(report.issues.count) 个问题"))
        return preview
    }

    func previewAndroidBackupImport(from fileURL: URL) throws -> AndroidBackupImportPreview {
        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: fileURL)
        return try previewAndroidBackupImport(data, fileName: fileURL.lastPathComponent)
    }

    func prepareAndroidBackupImport(from fileURL: URL) throws -> AndroidBackupImportPreview? {
        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: fileURL)
        do {
            let preview = try previewAndroidBackupImport(data, fileName: fileURL.lastPathComponent)
            clearPendingAndroidEncryptedBackup()
            return preview
        } catch AppAndroidBackupImportError.unsupportedEncryptedBackup {
            pendingAndroidEncryptedBackupData = data
            pendingAndroidEncryptedBackupFileName = fileURL.lastPathComponent
            androidBackupDecryptPassword = ""
            entryOperationState = .failed(String(localized: "请输入移动端加密备份密码。"))
            return nil
        } catch {
            clearPendingAndroidEncryptedBackup()
            throw error
        }
    }

    func previewPendingAndroidEncryptedBackupImport() throws -> AndroidBackupImportPreview {
        recordUserActivity()
        guard let data = pendingAndroidEncryptedBackupData,
              let fileName = pendingAndroidEncryptedBackupFileName else {
            throw AppAndroidBackupImportError.encryptedBackupUnavailable
        }
        let password = androidBackupDecryptPassword
        androidBackupDecryptPassword = ""

        do {
            let preview = try previewAndroidBackupImport(
                data,
                fileName: fileName,
                decryptPassword: password
            )
            clearPendingAndroidEncryptedBackup()
            return preview
        } catch AppAndroidBackupImportError.encryptedBackupDecryptionFailed(let message) {
            throw AppAndroidBackupImportError.encryptedBackupDecryptionFailed(message)
        } catch {
            clearPendingAndroidEncryptedBackup()
            throw error
        }
    }

    func cancelPendingAndroidEncryptedBackupImport() {
        recordUserActivity()
        clearPendingAndroidEncryptedBackup()
        if androidBackupImportPreview == nil {
            entryOperationState = .idle
        }
    }

    func confirmAndroidBackupImport(projectTitle: String) throws {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let preview = androidBackupImportPreview else {
                throw LocalVaultRepositoryError.invalidEntryPayload
            }
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let vaultSession = try requireActiveVaultSession()

            let project = try ensureActiveProject(projectTitle: projectTitle, entryRepository: entryRepository)
            var importedLoginIDsByAndroidID: [Int64: String] = [:]
            for importedItem in preview.report.importedItems {
                let createdEntryID = try createCSVImportedItem(
                    importedItem.draft,
                    projectID: project.id,
                    entryRepository: entryRepository
                )
                if case .login = importedItem.draft,
                   let sourceID = importedItem.sourceID,
                   let createdEntryID {
                    importedLoginIDsByAndroidID[sourceID] = createdEntryID
                }
            }
            var deletedItemCount = 0
            for importedItem in preview.deletedItems {
                guard let createdEntryID = try createCSVImportedItem(
                    importedItem.draft,
                    projectID: project.id,
                    entryRepository: entryRepository
                ) else {
                    continue
                }
                try deleteCSVImportedItem(
                    importedItem.draft,
                    entryID: createdEntryID,
                    projectID: project.id,
                    entryRepository: entryRepository
                )
                deletedItemCount += 1
            }
            var savedAttachmentBlobCount = 0
            for attachment in preview.attachments {
                let encryptedBlobLocalPath: String?
                if let encryptedBlob = attachment.encryptedBlob {
                    encryptedBlobLocalPath = try androidBackupAttachmentBlobStore.saveEncryptedBlob(
                        encryptedBlob,
                        vaultID: vaultSession.handle.vaultID,
                        localPath: attachment.localPath
                    )
                    savedAttachmentBlobCount += 1
                } else {
                    encryptedBlobLocalPath = nil
                }
                _ = try entryRepository.createAttachmentMetadata(
                    projectID: project.id,
                    entryID: importedLoginIDsByAndroidID[attachment.parentPasswordID],
                    fileName: attachment.fileName,
                    mediaType: attachment.mediaType,
                    originalSize: attachment.originalSize,
                    storedSize: Int64(attachment.encryptedBlob?.count ?? 0),
                    contentHash: attachment.contentHash,
                    storageMode: encryptedBlobLocalPath == nil ? "android-backup-pending" : "android-backup-encrypted-blob",
                    source: "android-backup-local",
                    downloadState: encryptedBlobLocalPath == nil ? "missing-blob" : "downloaded",
                    wrappedContentEncryptionKey: encryptedBlobLocalPath == nil ? nil : attachment.wrappedContentEncryptionKey,
                    localPath: encryptedBlobLocalPath
                )
            }
            try refreshAllEntryLists(projectID: project.id, entryRepository: entryRepository)
            try refreshAutoFillEncryptedIndexIfConfigured()
            androidBackupImportPreview = nil
            let attachmentText: String
            if preview.attachments.isEmpty {
                attachmentText = ""
            } else if savedAttachmentBlobCount == preview.attachments.count {
                attachmentText = String(localized: "；\(savedAttachmentBlobCount) 个附件密文待恢复")
            } else if savedAttachmentBlobCount > 0 {
                attachmentText = String(localized: "；\(savedAttachmentBlobCount) 个附件密文待恢复，\(preview.attachments.count - savedAttachmentBlobCount) 个附件元数据待恢复")
            } else {
                attachmentText = String(localized: "；\(preview.attachments.count) 个附件元数据待恢复")
            }
            let trashText = deletedItemCount == 0 ? "" : String(localized: "；\(deletedItemCount) 项进入回收站")
            entryOperationState = .succeeded(String(localized: "移动端备份已导入 \(preview.items.count) 项\(attachmentText)\(trashText)"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func androidBackupExportDocument() throws -> AndroidBackupExportDocument {
        AndroidBackupExportDocument(data: try exportAndroidBackup())
    }

    func exportAndroidBackup() throws -> Data {
        recordUserActivity()
        entryOperationState = .running

        do {
            _ = try requireActiveVaultSession()
            let drafts = csvExportDrafts()
            let data = try AndroidBackupCodec.exportItems(drafts)
            entryOperationState = .succeeded(String(localized: "移动端备份已导出 \(drafts.count) 项"))
            return data
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func csvExportDocument() throws -> CSVExportDocument {
        CSVExportDocument(text: try exportCSV())
    }

    func exportCSV() throws -> String {
        recordUserActivity()
        entryOperationState = .running

        do {
            _ = try requireActiveVaultSession()
            let drafts = csvExportDrafts()
            let csv = VaultCSVCodec.exportItems(drafts)
            entryOperationState = .succeeded(String(localized: "CSV 已导出 \(drafts.count) 项"))
            return csv
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    func totpCode(for entry: LocalTotpEntry, at date: Date = Date()) throws -> String {
        switch OtpType(storageValue: entry.otpType) {
        case .totp:
            return try TotpGenerator.generate(
                secret: entry.secret,
                algorithm: totpAlgorithm(from: entry.algorithm),
                digits: Int(entry.digits),
                period: Int(entry.period),
                timestamp: date.timeIntervalSince1970
            )
        case .hotp:
            return try HotpGenerator.generate(
                secret: entry.secret,
                algorithm: totpAlgorithm(from: entry.algorithm),
                digits: Int(entry.digits),
                counter: entry.counter
            )
        }
    }

    func totpTimeRemaining(for entry: LocalTotpEntry, at date: Date = Date()) -> Int {
        guard OtpType(storageValue: entry.otpType) == .totp else {
            return 0
        }
        let period = max(Int(entry.period), 1)
        let elapsed = Int(date.timeIntervalSince1970) % period
        return elapsed == 0 ? period : period - elapsed
    }

    var canPrepareVaultKeychainUnlock: Bool {
        vaultState == .unlocked
            && vaultKeychainService != nil
            && vaultWrappedKeyProvider != nil
    }

    var canUnlockRememberedVaultWithKeychain: Bool {
        vaultState == .locked
            && vaultKeychainService != nil
            && rememberedVaultDescriptor != nil
            && rememberedVaultID != nil
    }

    func prepareVaultKeychainUnlock() async throws {
        recordUserActivity()
        vaultKeychainState = .running

        do {
            guard let activeVaultSession else {
                throw AppVaultKeychainError.vaultLocked
            }
            guard let vaultKeychainService else {
                throw AppVaultKeychainError.keychainUnavailable
            }
            guard let vaultWrappedKeyProvider else {
                throw AppVaultKeychainError.wrappedKeyProviderUnavailable
            }
            if let kind = biometricUnlockKind {
                try await biometricUnlockAuthorizer.authenticate(
                    reason: String(localized: "启用 \(kind.displayName) 解锁")
                )
            }

            let wrappedKey = try vaultWrappedKeyProvider(activeVaultSession)
            guard wrappedKey.vaultID == activeVaultSession.handle.vaultID else {
                throw AppVaultKeychainError.vaultMismatch
            }

            try vaultRepository.setupLocalSecurityKeyUnlock(
                for: activeVaultSession,
                securityKeyMaterial: wrappedKey.wrappedKeyMaterial
            )
            try await vaultKeychainService.saveWrappedKey(wrappedKey)
            setBiometricUnlockEnabled(true)
            rememberVault(activeVaultSession)
            vaultKeychainState = .saved(wrappedKey.vaultID)
        } catch {
            vaultKeychainState = .failed(readableVaultKeychainErrorMessage(for: error))
            throw error
        }
    }

    func setBiometricUnlockEnabled(_ isEnabled: Bool) {
        isBiometricUnlockEnabled = isEnabled
    }

    func unlockRememberedVaultWithKeychain(
        deviceID: String,
        now: Date = Date(),
        fallbackDirectory: URL? = nil
    ) async throws {
        vaultOperationState = .running
        vaultKeychainState = .running

        do {
            guard vaultState == .locked else {
                throw AppVaultKeychainError.vaultAlreadyUnlocked
            }
            guard let rememberedVaultDescriptor,
                  let rememberedVaultID else {
                throw AppVaultKeychainError.rememberedVaultUnavailable
            }
            guard let vaultKeychainService else {
                throw AppVaultKeychainError.keychainUnavailable
            }

            let wrappedKey = try await vaultKeychainService.loadWrappedKeyAfterAuthentication(
                vaultID: rememberedVaultID,
                reason: String(localized: "解锁 Monica 保险库")
            )
            guard wrappedKey.vaultID == rememberedVaultID else {
                throw AppVaultKeychainError.vaultMismatch
            }

            let descriptor = resolvedRememberedVaultDescriptor(
                rememberedVaultDescriptor,
                fallbackDirectory: fallbackDirectory
            )
            let session = try vaultRepository.openVaultWithSecurityKey(
                at: descriptor.fileURL,
                securityKeyMaterial: wrappedKey.wrappedKeyMaterial,
                deviceID: deviceID
            )
            guard session.handle.vaultID == rememberedVaultID else {
                vaultRepository.closeVault(for: session)
                throw AppVaultKeychainError.vaultMismatch
            }

            vaultPassword = ""
            isPrivacyShieldVisible = false
            vaultState = .unlocked
            activeVaultName = session.descriptor.displayName
            activeVaultSession = session
            let entryRepository = vaultRepository.entryRepository(for: session)
            activeEntryRepository = entryRepository
            activeProject = nil
            vaultProjects = try entryRepository.listProjects()
            rememberVault(session)
            loginEntries = []
            deletedLoginEntries = []
            noteEntries = []
            deletedNoteEntries = []
            totpEntries = []
            deletedTotpEntries = []
            totpImportURI = ""
            cardEntries = []
            deletedCardEntries = []
            identityEntries = []
            deletedIdentityEntries = []
            passkeyEntries = []
            deletedPasskeyEntries = []
            clearExtendedParityEntries()
            recordUserActivity(at: now)
            vaultOperationState = .succeeded(session.descriptor.displayName)
            vaultKeychainState = .unlocked(session.handle.vaultID)
            publishWidgetSnapshots(now: now, reloadImmediately: true)
        } catch {
            clearVaultAccessAfterFailure()
            vaultKeychainState = .failed(readableVaultKeychainErrorMessage(for: error))
            vaultOperationState = .failed(readableVaultKeychainErrorMessage(for: error))
            throw error
        }
    }

    func refreshAutoFillEncryptedIndex(updatedAt: Date = Date()) throws {
        recordUserActivity()
        if let vaultID = activeVaultSession?.handle.vaultID, !vaultID.isEmpty {
            let controller = autoFillDomainRules
            Task { @MainActor in
                await controller.attach(vaultID: vaultID)
                await controller.reload()
            }
        }
        autoFillIndexState = .running

        do {
            guard vaultState == .unlocked,
                  let activeVaultSession
            else {
                throw AppAutoFillIndexError.vaultLocked
            }
            let shouldWriteEncryptedAutoFillArtifacts = autoFillIndexStore != nil
                || autoFillCredentialSecretStore != nil
            let shouldSyncCredentialIdentities = autoFillCredentialIdentityStore != nil
            guard shouldWriteEncryptedAutoFillArtifacts || shouldSyncCredentialIdentities else {
                throw AppAutoFillIndexError.indexStoreUnavailable
            }

            if shouldWriteEncryptedAutoFillArtifacts {
                guard let autoFillIndexKeyMaterialProvider
                else {
                    throw AppAutoFillIndexError.indexStoreUnavailable
                }
                let keyMaterial = try autoFillIndexKeyMaterialProvider(activeVaultSession.handle.vaultID)
                guard keyMaterial.vaultID == activeVaultSession.handle.vaultID else {
                    throw AppAutoFillIndexError.indexKeyVaultMismatch
                }

                let storageKey = try AutoFillIndexEncryptionKey(rawValue: keyMaterial.keyMaterial)
                if let autoFillIndexStore {
                    let indexRecords = loginEntries.map { entry in
                        AutoFillCredentialIndexRecord(
                            id: entry.id,
                            title: entry.title,
                            username: entry.username,
                            serviceIdentifiers: serviceIdentifiers(for: entry.url)
                        )
                    }
                    let index = try autoFillIndexCodec.encrypt(
                        indexRecords,
                        vaultID: activeVaultSession.handle.vaultID,
                        keyIdentifier: keyMaterial.keyIdentifier,
                        updatedAt: updatedAt,
                        key: storageKey
                    )
                    try autoFillIndexStore.save(index)
                }

                if let autoFillCredentialSecretStore {
                    let secretRecords = loginEntries.map { entry in
                        AutoFillCredentialSecretRecord(
                            id: entry.id,
                            username: entry.username,
                            password: entry.password
                        )
                    }
                    let secretSnapshot = try autoFillCredentialSecretCodec.encrypt(
                        secretRecords,
                        vaultID: activeVaultSession.handle.vaultID,
                        keyIdentifier: keyMaterial.keyIdentifier,
                        updatedAt: updatedAt,
                        key: storageKey
                    )
                    try autoFillCredentialSecretStore.save(secretSnapshot)
                }
            }

            if let autoFillCredentialIdentityStore {
                let identities = loginEntries.flatMap { entry in
                    autoFillCredentialIdentities(for: entry)
                }
                let passkeyIdentities = passkeyEntries.compactMap { entry in
                    autoFillPasskeyCredentialIdentity(for: entry)
                }
                autoFillCredentialIdentityStore.replaceCredentialIdentities(
                    identities,
                    passkeyIdentities: passkeyIdentities
                )
            }
            autoFillIndexState = .succeeded(loginEntries.count)
        } catch {
            autoFillIndexState = .failed(error.localizedDescription)
            throw error
        }
    }

    func refreshAutoFillEncryptedIndexIfConfigured() throws {
        guard autoFillIndexStore != nil
                || autoFillCredentialSecretStore != nil
                || autoFillCredentialIdentityStore != nil
                || autoFillIndexKeyMaterialProvider != nil else {
            return
        }

        try refreshAutoFillEncryptedIndex()
    }

    func uploadActiveVaultBackup() async throws {
        recordUserActivity()
        webDAVBackupState = .running

        do {
            let session = try requireActiveVaultSession()
            let endpoint = try makeWebDAVEndpoint()
            let fileName = try normalizedWebDAVRemoteFileName(
                fallback: session.descriptor.fileURL.lastPathComponent
            )
            let data = try Data(contentsOf: session.descriptor.fileURL)
            let receipt = try await webDAVBackupService.upload(
                endpoint: endpoint,
                package: WebDAVBackupPackage(fileName: fileName, data: data)
            )
            webDAVPassword = ""
            webDAVRestorePreview = nil
            webDAVBackupState = .backupSucceeded(
                byteCount: receipt.byteCount,
                sha256: receipt.sha256
            )
            appendOperationTimelineEvent(
                action: .backedUp,
                itemKind: .attachmentRef,
                itemID: "webdav-upload",
                itemTitle: "WebDAV \(fileName)"
            )
        } catch {
            webDAVBackupState = .failed(readableWebDAVErrorMessage(for: error))
            appendOperationTimelineEvent(
                action: .backedUp,
                itemKind: .attachmentRef,
                itemID: "webdav-upload",
                itemTitle: "WebDAV backup",
                result: "failed",
                errorCategory: "WebDAV"
            )
            throw error
        }
    }

    func refreshCloudFileItems(provider kind: CloudFileProviderKind) async throws -> [CloudFileItem] {
        recordUserActivity()
        cloudFileState = .running(kind)

        do {
            let provider = try cloudFileProvider(for: kind)
            if kind == .oneDrive,
               let directoryProvider = provider as? any CloudFileBackupDirectoryProviding {
                return try await refreshOneDriveBackupDirectory(using: directoryProvider)
            }
            let items = try await provider.listFiles()
            cloudFileItemsByProvider[kind] = items
            cloudFileState = .listed(provider: kind, count: items.count)
            return items
        } catch {
            cloudFileState = .failed(readableCloudFileErrorMessage(for: error, provider: kind))
            throw error
        }
    }

    private func refreshOneDriveBackupDirectory(
        using provider: any CloudFileBackupDirectoryProviding
    ) async throws -> [CloudFileItem] {
        let selectedDirectoryID = oneDriveBackupPreferences.directory?.id
        do {
            let listing = try await provider.listBackupDirectory(id: selectedDirectoryID)
            if let directory = listing.directory {
                if oneDriveBackupPreferences.directory != directory {
                    oneDriveBackupPreferences.directory = directory
                    persistOneDriveBackupPreferences()
                }
                oneDriveBackupDirectoryState = .available(directory.displayPath)
                await loadOneDriveDefaultLocationFiles(using: provider)
            } else {
                oneDriveBackupDirectoryState = .unknown
                oneDriveDefaultLocationFiles = []
            }
            cloudFileItemsByProvider[.oneDrive] = listing.files
            cloudFileState = .listed(provider: .oneDrive, count: listing.files.count)
            return listing.files
        } catch let error as CloudFileProviderError
            where error == .itemNotFound(provider: .oneDrive) {
            oneDriveBackupDirectoryState = .missing
            cloudFileItemsByProvider[.oneDrive] = []
            await loadOneDriveDefaultLocationFiles(using: provider)
            throw error
        }
    }

    private func loadOneDriveDefaultLocationFiles(
        using provider: any CloudFileBackupDirectoryProviding
    ) async {
        guard let listing = try? await provider.listBackupDirectory(id: nil) else {
            return
        }
        oneDriveDefaultLocationFiles = listing.files
    }

    func refreshWebDAVBackupItems() async throws -> [WebDAVBackupItem] {
        recordUserActivity()
        webDAVBackupState = .running
        do {
            _ = try requireActiveVaultSession()
            let endpoint = try makeWebDAVEndpoint()
            let backups = try await webDAVBackupService.listBackups(endpoint: endpoint)
            webDAVBackupItems = backups
            webDAVPassword = ""
            webDAVBackupState = .listed(count: backups.count)
            return backups
        } catch {
            webDAVBackupState = .failed(readableWebDAVErrorMessage(for: error))
            throw error
        }
    }

    func deleteWebDAVBackupItem(_ item: WebDAVBackupItem) async throws {
        recordUserActivity()
        webDAVBackupState = .running
        do {
            _ = try requireActiveVaultSession()
            let endpoint = try makeWebDAVEndpoint()
            try await webDAVBackupService.deleteBackup(endpoint: endpoint, fileName: item.fileName)
            webDAVBackupItems.removeAll { $0.id == item.id }
            webDAVPassword = ""
            webDAVBackupState = .deleted(fileName: item.fileName)
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .attachmentRef,
                itemID: "webdav-\(item.id)",
                itemTitle: "WebDAV \(item.fileName)"
            )
        } catch {
            webDAVBackupState = .failed(readableWebDAVErrorMessage(for: error))
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .attachmentRef,
                itemID: "webdav-delete",
                itemTitle: "WebDAV backup",
                result: "failed",
                errorCategory: "WebDAV"
            )
            throw error
        }
    }

    func setWebDAVBackupItemPermanent(_ item: WebDAVBackupItem, isPermanent: Bool) async throws {
        recordUserActivity()
        webDAVBackupState = .running
        do {
            _ = try requireActiveVaultSession()
            let endpoint = try makeWebDAVEndpoint()
            let updated = try await webDAVBackupService.setBackupPermanent(
                endpoint: endpoint,
                fileName: item.fileName,
                isPermanent: isPermanent
            )
            if let index = webDAVBackupItems.firstIndex(where: { $0.id == item.id }) {
                webDAVBackupItems[index] = WebDAVBackupItem(
                    fileName: updated.fileName,
                    byteCount: item.byteCount,
                    modifiedAt: item.modifiedAt
                )
            }
            webDAVPassword = ""
            webDAVBackupState = .permanentUpdated(fileName: updated.fileName, isPermanent: isPermanent)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .attachmentRef,
                itemID: "webdav-\(updated.id)",
                itemTitle: "WebDAV \(updated.fileName)"
            )
        } catch {
            webDAVBackupState = .failed(readableWebDAVErrorMessage(for: error))
            throw error
        }
    }

    func cleanupExpiredWebDAVBackups() async throws {
        recordUserActivity()
        webDAVBackupState = .running
        do {
            _ = try requireActiveVaultSession()
            let endpoint = try makeWebDAVEndpoint()
            let cutoff = Calendar.current.date(
                byAdding: .day,
                value: -max(1, webDAVBackupRetentionDays),
                to: Date()
            ) ?? Date(timeIntervalSinceNow: -30 * 24 * 60 * 60)
            let deleted = try await webDAVBackupService.cleanupBackups(
                endpoint: endpoint,
                backups: webDAVBackupItems,
                olderThan: cutoff
            )
            let deletedIDs = Set(deleted.map(\.id))
            webDAVBackupItems.removeAll { deletedIDs.contains($0.id) }
            webDAVPassword = ""
            webDAVBackupState = .cleanupSucceeded(count: deleted.count)
            appendOperationTimelineEvent(
                action: .cleanedUp,
                itemKind: .attachmentRef,
                itemID: "webdav-cleanup",
                itemTitle: "WebDAV \(deleted.count) backups"
            )
        } catch {
            webDAVBackupState = .failed(readableWebDAVErrorMessage(for: error))
            throw error
        }
    }

    func scheduleBackgroundWebDAVBackup() async {
        webDAVBackgroundBackupEnabled = true
        webDAVBackgroundBackupSchedulerState = await backgroundBackupScheduler.scheduleNextBackup(after: 12 * 60 * 60)
        appendOperationTimelineEvent(
            action: .updated,
            itemKind: .attachmentRef,
            itemID: "webdav-background",
            itemTitle: String(localized: "自动备份")
        )
    }

    func disableBackgroundWebDAVBackup() {
        webDAVBackgroundBackupEnabled = false
        webDAVBackgroundBackupSchedulerState = .idle
        appendOperationTimelineEvent(
            action: .updated,
            itemKind: .attachmentRef,
            itemID: "webdav-background",
            itemTitle: String(localized: "自动备份")
        )
    }

    func signInToOneDrive() async throws -> AppOneDriveAuthenticationSession {
        recordUserActivity()
        guard let oneDriveAuthenticationService else {
            let error = AppOneDriveAuthenticationError.serviceUnavailable
            oneDriveAuthenticationState = .failed(error.localizedDescription)
            throw error
        }
        oneDriveAuthenticationState = .running
        clearOneDriveSessionState()
        do {
            let session = try await oneDriveAuthenticationService.signIn()
            oneDriveAuthenticationState = .connected(accountLabel: session.accountLabel)
            applyOneDriveSession(session)
            await loadOneDriveAccounts()
            return session
        } catch {
            oneDriveAuthenticationState = .failed(readableOneDriveAuthenticationErrorMessage(error))
            throw error
        }
    }

    @discardableResult
    func restoreOneDriveAuthenticationSession() async throws -> AppOneDriveAuthenticationSession? {
        guard let oneDriveAuthenticationService else {
            clearOneDriveSessionState()
            oneDriveAuthenticationState = .disconnected
            return nil
        }

        do {
            let session = try await oneDriveAuthenticationService.restoreSession()
            clearOneDriveSessionState()
            guard let session else {
                oneDriveAuthenticationState = .disconnected
                oneDriveAccounts = []
                return nil
            }
            oneDriveAuthenticationState = .connected(accountLabel: session.accountLabel)
            applyOneDriveSession(session)
            await loadOneDriveAccounts()
            return session
        } catch {
            oneDriveAuthenticationState = .failed(readableOneDriveAuthenticationErrorMessage(error))
            throw error
        }
    }

    func signOutFromOneDrive() async throws {
        recordUserActivity()
        guard let oneDriveAuthenticationService else {
            let error = AppOneDriveAuthenticationError.serviceUnavailable
            oneDriveAuthenticationState = .failed(error.localizedDescription)
            throw error
        }
        oneDriveAuthenticationState = .running
        do {
            try await oneDriveAuthenticationService.signOut()
            clearOneDriveSessionState()
            oneDriveAuthenticationState = .disconnected
            if let remaining = try? await oneDriveAuthenticationService.restoreSession() {
                oneDriveAuthenticationState = .connected(accountLabel: remaining.accountLabel)
                applyOneDriveSession(remaining)
            } else {
                oneDriveAccounts = []
            }
            await loadOneDriveAccounts()
        } catch {
            oneDriveAuthenticationState = .failed(readableOneDriveAuthenticationErrorMessage(error))
            throw error
        }
    }

    @discardableResult
    func switchOneDriveAccount(identifier: String) async throws -> AppOneDriveAuthenticationSession {
        recordUserActivity()
        guard let oneDriveAuthenticationService else {
            let error = AppOneDriveAuthenticationError.serviceUnavailable
            oneDriveAuthenticationState = .failed(error.localizedDescription)
            throw error
        }
        oneDriveAuthenticationState = .running
        clearOneDriveSessionState()
        do {
            let session = try await oneDriveAuthenticationService.switchAccount(identifier: identifier)
            oneDriveAuthenticationState = .connected(accountLabel: session.accountLabel)
            applyOneDriveSession(session)
            await loadOneDriveAccounts()
            _ = try? await refreshCloudFileItems(provider: .oneDrive)
            return session
        } catch {
            oneDriveAuthenticationState = .failed(readableOneDriveAuthenticationErrorMessage(error))
            throw error
        }
    }

    private func loadOneDriveAccounts() async {
        guard let oneDriveAuthenticationService else {
            oneDriveAccounts = []
            return
        }
        oneDriveAccounts = (try? await oneDriveAuthenticationService.availableAccounts()) ?? []
    }

    private func applyOneDriveSession(_ session: AppOneDriveAuthenticationSession) {
        currentOneDriveAccountIdentifier = session.accountIdentifier
        oneDriveBackupPreferences = oneDriveBackupPreferencesStore.loadPreferences(
            accountIdentifier: session.accountIdentifier
        )
        oneDriveBackupDirectoryState = .unknown
        oneDriveBackupNotice = nil
    }

    private func clearOneDriveSessionState() {
        cloudFileItemsByProvider[.oneDrive] = nil
        cloudFileSelectedBackupItemByProvider[.oneDrive] = nil
        if cloudFileRestorePreview?.provider == .oneDrive {
            cloudFileRestorePreview = nil
            downloadedCloudFileRestore = nil
        }
        if cloudFileState.providerKind == .oneDrive {
            cloudFileState = .idle
        }
        oneDriveDefaultLocationFiles = []
        oneDriveBackupNotice = nil
        oneDriveBackupPreferences = CloudFileBackupPreferences()
        oneDriveBackupDirectoryState = .unknown
        currentOneDriveAccountIdentifier = ""
    }

    func handleOneDriveRedirectURL(_ url: URL) -> Bool {
        guard let oneDriveAuthenticationService,
              oneDriveAuthenticationService.handleRedirectURL(url)
        else {
            return false
        }
        oneDriveAuthenticationState = .redirectHandled
        return true
    }

    @discardableResult
    func signInToBitwarden() async throws -> BitwardenAuthenticationSession {
        recordUserActivity()
        bitwardenSyncState = .running

        do {
            guard let bitwardenPasswordAuthenticationService else {
                throw AppBitwardenSyncError.providerUnavailable
            }
            guard let serverURL = validBitwardenServerURL(bitwardenServerURL) else {
                throw AppBitwardenSyncError.invalidServerURL
            }
            let result = try await bitwardenPasswordAuthenticationService.beginSignIn(
                email: bitwardenEmail,
                masterPassword: bitwardenMasterPassword,
                serverURL: serverURL
            )
            switch result {
            case .authenticated(let session):
                clearBitwardenTwoFactorState()
                bitwardenMasterPassword = ""
                bitwardenAuthenticationState = .connected(accountLabel: session.accountLabel)
                bitwardenSyncState = .idle
                return session
            case .twoFactorRequired(let challenge):
                pendingBitwardenTwoFactorChallenge = challenge
                bitwardenTwoFactorProviderID = challenge.providers.first?.providerID ?? 0
                bitwardenMasterPassword = ""
                bitwardenAuthenticationState = .twoFactorRequired(
                    accountLabel: challenge.accountLabel,
                    providers: challenge.providers
                )
                bitwardenSyncState = .failed(String(localized: "Bitwarden 需要两步验证"))
                throw BitwardenSyncProviderError.twoFactorRequired
            }
        } catch {
            if case BitwardenSyncProviderError.twoFactorRequired = error {
                throw error
            }
            let message = readableBitwardenSyncErrorMessage(for: error)
            clearBitwardenTwoFactorState()
            bitwardenMasterPassword = ""
            bitwardenAuthenticationState = .failed(message)
            bitwardenSyncState = .failed(message)
            throw error
        }
    }

    @discardableResult
    func restoreBitwardenAuthenticationSession() throws -> BitwardenAuthenticationSession? {
        do {
            guard let session = try bitwardenAuthenticationSessionStore.loadSession() else {
                bitwardenAuthenticationState = .disconnected
                return nil
            }
            bitwardenAuthenticationState = .connected(accountLabel: session.accountLabel)
            return session
        } catch {
            bitwardenAuthenticationState = .failed(readableBitwardenSyncErrorMessage(for: error))
            throw error
        }
    }

    func signOutFromBitwarden() throws {
        recordUserActivity()
        do {
            let accountLabel = try bitwardenAuthenticationSessionStore.loadSession()?.accountLabel
            try bitwardenAuthenticationSessionStore.clearSession()
            try bitwardenVaultKeyStore?.clearVaultKey(accountLabel: accountLabel)
            clearBitwardenTwoFactorState()
            bitwardenAuthenticationState = .disconnected
            bitwardenSyncState = .idle
            bitwardenSyncPreview = nil
            bitwardenPendingMutationBatches = []
        } catch {
            bitwardenAuthenticationState = .failed(readableBitwardenSyncErrorMessage(for: error))
            throw error
        }
    }

    func completeBitwardenTwoFactorSignIn() async throws -> BitwardenAuthenticationSession {
        recordUserActivity()
        guard let challenge = pendingBitwardenTwoFactorChallenge else {
            throw AppBitwardenSyncError.providerUnavailable
        }
        guard let bitwardenPasswordAuthenticationService else {
            throw AppBitwardenSyncError.providerUnavailable
        }
        do {
            let session = try await bitwardenPasswordAuthenticationService.completeTwoFactorSignIn(
                challenge,
                code: bitwardenTwoFactorCode,
                providerID: bitwardenTwoFactorProviderID,
                rememberDevice: bitwardenRememberTwoFactorDevice
            )
            bitwardenMasterPassword = ""
            clearBitwardenTwoFactorState()
            bitwardenAuthenticationState = .connected(accountLabel: session.accountLabel)
            bitwardenSyncState = .idle
            return session
        } catch {
            let message = readableBitwardenSyncErrorMessage(for: error)
            bitwardenAuthenticationState = .failed(message)
            bitwardenSyncState = .failed(message)
            throw error
        }
    }

    func requestBitwardenEmailTwoFactorCode() async throws {
        recordUserActivity()
        guard let challenge = pendingBitwardenTwoFactorChallenge else {
            throw AppBitwardenSyncError.providerUnavailable
        }
        guard let bitwardenPasswordAuthenticationService else {
            throw AppBitwardenSyncError.providerUnavailable
        }
        do {
            try await bitwardenPasswordAuthenticationService.requestEmailTwoFactorCode(for: challenge)
            bitwardenSyncState = .twoFactorEmailSent
        } catch {
            let message = readableBitwardenSyncErrorMessage(for: error)
            bitwardenAuthenticationState = .failed(message)
            bitwardenSyncState = .failed(message)
            throw error
        }
    }

    private func clearBitwardenTwoFactorState() {
        pendingBitwardenTwoFactorChallenge = nil
        bitwardenTwoFactorCode = ""
        bitwardenRememberTwoFactorDevice = false
        bitwardenTwoFactorProviderID = 0
    }

    @discardableResult
    func refreshBitwardenPendingMutationQueue() throws -> [AppBitwardenPendingMutationBatch] {
        let session = try requireActiveVaultSession()
        let batches = try bitwardenPendingMutationQueueStore.loadBatches(vaultID: session.handle.vaultID)
        bitwardenPendingMutationBatches = batches
        return batches
    }

    func clearBitwardenPendingMutationQueue() throws {
        recordUserActivity()
        do {
            let session = try requireActiveVaultSession()
            try bitwardenPendingMutationQueueStore.saveBatches([], vaultID: session.handle.vaultID)
            bitwardenPendingMutationBatches = []
            bitwardenSyncState = .queueCleared
        } catch {
            bitwardenSyncState = .failed(readableBitwardenSyncErrorMessage(for: error))
            throw error
        }
    }

    @discardableResult
    func retryBitwardenPendingMutationQueue() async throws -> BitwardenSyncPushResult {
        recordUserActivity()
        do {
            let pendingBatches = try refreshBitwardenPendingMutationQueue()
            guard !pendingBatches.isEmpty else {
                bitwardenSyncState = .queueCleared
                return BitwardenSyncPushResult(acceptedMutationCount: 0)
            }
            return try await pushLocalBitwardenChanges()
        } catch {
            if case .queuedForRetry = bitwardenSyncState {
                throw error
            }
            bitwardenSyncState = .failed(readableBitwardenSyncErrorMessage(for: error))
            throw error
        }
    }

    func downloadCloudFileRestorePreview(
        itemID: String,
        provider kind: CloudFileProviderKind
    ) async throws -> CloudFileDownload {
        recordUserActivity()
        cloudFileState = .running(kind)

        do {
            _ = try requireActiveVaultSession()
            let provider = try cloudFileProvider(for: kind)
            let download = try await provider.downloadFile(id: itemID)
            let preview = AppCloudFileRestorePreview(provider: kind, download: download)
            downloadedCloudFileRestore = download
            cloudFileRestorePreview = preview
            cloudFileState = .restorePreviewReady(
                provider: kind,
                fileName: preview.fileName,
                byteCount: preview.byteCount
            )
            cloudFileSelectedBackupItemByProvider[kind] = download.item
            return download
        } catch {
            cloudFileState = .failed(readableCloudFileErrorMessage(for: error, provider: kind))
            throw error
        }
    }

    func uploadActiveVaultToCloud(provider kind: CloudFileProviderKind) async throws -> CloudFileWriteReceipt {
        recordUserActivity()
        cloudFileState = .running(kind)

        do {
            let session = try requireActiveVaultSession()
            let provider = try cloudFileProvider(for: kind)
            let data = try Data(contentsOf: session.descriptor.fileURL)
            let receipt: CloudFileWriteReceipt
            if kind == .oneDrive,
               let directoryProvider = provider as? any CloudFileBackupDirectoryProviding {
                receipt = try await uploadOneDriveVault(
                    data: data,
                    cloudProvider: provider,
                    directoryProvider: directoryProvider,
                    baseName: kind.defaultBackupFileName
                )
            } else {
                receipt = try await provider.uploadFile(
                    named: kind.defaultBackupFileName,
                    data: data
                )
            }
            cloudFileState = .backupSucceeded(
                provider: kind,
                fileName: sanitizedCloudFileName(receipt.name),
                byteCount: receipt.byteCount
            )
            appendOperationTimelineEvent(
                action: .backedUp,
                itemKind: .attachmentRef,
                itemID: "\(kind.rawValue)-upload",
                itemTitle: "\(kind.displayName) \(sanitizedCloudFileName(receipt.name))"
            )
            return receipt
        } catch {
            cloudFileState = .failed(readableCloudFileErrorMessage(for: error, provider: kind))
            appendOperationTimelineEvent(
                action: .backedUp,
                itemKind: .attachmentRef,
                itemID: "\(kind.rawValue)-upload",
                itemTitle: "\(kind.displayName) backup",
                result: "failed",
                errorCategory: kind.displayName
            )
            throw error
        }
    }

    private func uploadOneDriveVault(
        data: Data,
        cloudProvider: any CloudFileProvider,
        directoryProvider: any CloudFileBackupDirectoryProviding,
        baseName: String
    ) async throws -> CloudFileWriteReceipt {
        let directoryID = oneDriveBackupPreferences.directory?.id
        let listing: CloudFileBackupDirectoryListing
        do {
            listing = try await directoryProvider.listBackupDirectory(id: directoryID)
        } catch let error as CloudFileProviderError
            where error == .itemNotFound(provider: .oneDrive) {
            oneDriveBackupDirectoryState = .missing
            oneDriveBackupNotice = "备份目录已不存在，请重建目录或选择新的位置。"
            throw error
        }
        if let directory = listing.directory {
            oneDriveBackupDirectoryState = .available(directory.displayPath)
        }
        cloudFileItemsByProvider[.oneDrive] = listing.files

        do {
            let receipt: CloudFileWriteReceipt
            if oneDriveBackupPreferences.usesTimestampedFileNames {
                let fileName = CloudFileBackupFileNameFormatter.timestampedFileName(
                    baseName: baseName,
                    date: oneDriveNow()
                )
                receipt = try await directoryProvider.uploadFile(
                    named: fileName,
                    data: data,
                    inDirectory: directoryID,
                    conflictBehavior: .fail
                )
                return try await pruneOneDriveBackups(
                    cloudProvider: cloudProvider,
                    directoryProvider: directoryProvider,
                    directoryID: directoryID,
                    baseName: baseName,
                    uploadedReceipt: receipt
                )
            }

            if let existing = listing.files.first(where: { $0.name == baseName }) {
                receipt = try await cloudProvider.overwriteFile(
                    id: existing.id,
                    data: data,
                    fileName: baseName,
                    expectedRevision: existing.revision
                )
            } else {
                receipt = try await directoryProvider.uploadFile(
                    named: baseName,
                    data: data,
                    inDirectory: directoryID,
                    conflictBehavior: .fail
                )
            }
            var items = cloudFileItemsByProvider[.oneDrive] ?? []
            let uploadedItem = CloudFileItem(
                id: receipt.itemID,
                name: receipt.name,
                path: receipt.name,
                byteCount: receipt.byteCount,
                modifiedAt: oneDriveNow(),
                sha256: receipt.sha256,
                revision: receipt.revision
            )
            if let existingIndex = items.firstIndex(where: {
                $0.name == receipt.name || $0.id == receipt.itemID
            }) {
                items[existingIndex] = uploadedItem
            } else {
                items.append(uploadedItem)
            }
            cloudFileItemsByProvider[.oneDrive] = items
            return receipt
        } catch let error as CloudFileProviderError
            where error == .itemNotFound(provider: .oneDrive) {
            oneDriveBackupDirectoryState = .missing
            oneDriveBackupNotice = "备份目录已不存在，请重建目录或选择新的位置。"
            throw error
        }
    }

    private func pruneOneDriveBackups(
        cloudProvider: any CloudFileProvider,
        directoryProvider: any CloudFileBackupDirectoryProviding,
        directoryID: String?,
        baseName: String,
        uploadedReceipt: CloudFileWriteReceipt
    ) async throws -> CloudFileWriteReceipt {
        guard let listing = try? await directoryProvider.listBackupDirectory(id: directoryID) else {
            oneDriveBackupNotice = "备份已上传，但暂时无法读取目录以清理旧版本。"
            return uploadedReceipt
        }
        var files = listing.files
        if !files.contains(where: { $0.id == uploadedReceipt.itemID }) {
            files.append(
                CloudFileItem(
                    id: uploadedReceipt.itemID,
                    name: uploadedReceipt.name,
                    path: uploadedReceipt.name,
                    byteCount: uploadedReceipt.byteCount,
                    modifiedAt: oneDriveNow(),
                    sha256: uploadedReceipt.sha256,
                    revision: uploadedReceipt.revision
                )
            )
        }
        let pruned = CloudFileBackupRetention.filesToPrune(
            from: files,
            baseName: baseName,
            retainedVersions: oneDriveBackupPreferences.retainedVersionCount
        )
        var removedIDs = Set<String>()
        var failureCount = 0
        for item in pruned {
            do {
                _ = try await cloudProvider.deleteFile(id: item.id)
                removedIDs.insert(item.id)
            } catch let error as CloudFileProviderError
                where error == .itemNotFound(provider: .oneDrive) {
                removedIDs.insert(item.id)
            } catch {
                failureCount += 1
            }
        }
        if let items = cloudFileItemsByProvider[.oneDrive] {
            cloudFileItemsByProvider[.oneDrive] = items.filter { !removedIDs.contains($0.id) }
        }
        if failureCount > 0 {
            oneDriveBackupNotice = "备份已上传，但有 \(failureCount) 个旧版本未能清理。"
        } else if !pruned.isEmpty {
            oneDriveBackupNotice = "已清理 \(pruned.count) 个旧版本备份。"
        }
        return uploadedReceipt
    }

    func selectOneDriveBackupDirectory(_ directory: CloudFileBackupDirectory) {
        oneDriveBackupPreferences.directory = directory
        oneDriveBackupDirectoryState = .available(directory.displayPath)
        oneDriveBackupNotice = nil
        cloudFileItemsByProvider[.oneDrive] = nil
        persistOneDriveBackupPreferences()
    }

    func useDefaultOneDriveBackupLocation() {
        oneDriveBackupPreferences.directory = nil
        oneDriveBackupDirectoryState = .unknown
        oneDriveBackupNotice = nil
        cloudFileItemsByProvider[.oneDrive] = nil
        persistOneDriveBackupPreferences()
    }

    func updateOneDriveBackupFileNamePolicy(
        usesTimestampedFileNames: Bool,
        retainedVersionCount: Int? = nil
    ) {
        oneDriveBackupPreferences.usesTimestampedFileNames = usesTimestampedFileNames
        if let retainedVersionCount {
            oneDriveBackupPreferences.retainedVersionCount = retainedVersionCount
        }
        persistOneDriveBackupPreferences()
    }

    func loadOneDriveBackupDirectory(id: String?) async throws -> CloudFileBackupDirectoryListing {
        recordUserActivity()
        let provider = try cloudFileProvider(for: .oneDrive)
        guard let directoryProvider = provider as? any CloudFileBackupDirectoryProviding else {
            throw AppCloudFileError.directoryUnavailable
        }
        return try await directoryProvider.listBackupDirectory(id: id)
    }

    @discardableResult
    func createOneDriveBackupDirectory(
        named name: String,
        parentID: String?
    ) async throws -> CloudFileBackupDirectory {
        recordUserActivity()
        let provider = try cloudFileProvider(for: .oneDrive)
        guard let directoryProvider = provider as? any CloudFileBackupDirectoryProviding else {
            throw AppCloudFileError.directoryUnavailable
        }
        do {
            let directory = try await directoryProvider.createBackupDirectory(named: name, parentID: parentID)
            selectOneDriveBackupDirectory(directory)
            _ = try? await refreshCloudFileItems(provider: .oneDrive)
            return directory
        } catch {
            oneDriveBackupDirectoryState = .failed(
                readableCloudFileErrorMessage(for: error, provider: .oneDrive)
            )
            throw error
        }
    }

    func recreateOneDriveBackupDirectory() async throws {
        recordUserActivity()
        let provider = try cloudFileProvider(for: .oneDrive)
        guard let directoryProvider = provider as? any CloudFileBackupDirectoryProviding else {
            throw AppCloudFileError.directoryUnavailable
        }
        let path = (oneDriveBackupPreferences.directory?.displayPath ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let components = path
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        guard !components.isEmpty else {
            oneDriveBackupNotice = nil
            _ = try? await refreshCloudFileItems(provider: .oneDrive)
            return
        }

        var parentID: String?
        do {
            for component in components {
                let listing = try await directoryProvider.listBackupDirectory(id: parentID)
                if let existing = listing.directories.first(where: { $0.name == component }) {
                    parentID = existing.id
                    continue
                }
                do {
                    let created = try await directoryProvider.createBackupDirectory(
                        named: component,
                        parentID: parentID
                    )
                    parentID = created.id
                } catch let error as CloudFileProviderError
                    where error == .conflict(provider: .oneDrive) {
                    let refreshed = try await directoryProvider.listBackupDirectory(id: parentID)
                    guard let existing = refreshed.directories.first(where: { $0.name == component }) else {
                        throw error
                    }
                    parentID = existing.id
                }
            }
            if let directory = try await directoryProvider.listBackupDirectory(id: parentID).directory {
                selectOneDriveBackupDirectory(directory)
            }
            oneDriveBackupNotice = "已重建备份目录。"
            _ = try? await refreshCloudFileItems(provider: .oneDrive)
        } catch {
            oneDriveBackupDirectoryState = .failed(
                readableCloudFileErrorMessage(for: error, provider: .oneDrive)
            )
            throw error
        }
    }

    private func persistOneDriveBackupPreferences() {
        let identifier = currentOneDriveAccountIdentifier
        guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        oneDriveBackupPreferencesStore.savePreferences(
            oneDriveBackupPreferences,
            accountIdentifier: identifier
        )
    }

    func overwriteCloudFile(
        provider kind: CloudFileProviderKind,
        itemID: String,
        data: Data,
        fileName: String
    ) async throws -> CloudFileWriteReceipt {
        recordUserActivity()
        cloudFileState = .running(kind)

        do {
            _ = try requireActiveVaultSession()
            let provider = try cloudFileProvider(for: kind)
            let receipt = try await provider.overwriteFile(
                id: itemID,
                data: data,
                fileName: sanitizedCloudFileName(fileName)
            )
            cloudFileState = .writeSucceeded(
                provider: kind,
                fileName: sanitizedCloudFileName(receipt.name),
                byteCount: receipt.byteCount
            )
            appendOperationTimelineEvent(
                action: .synced,
                itemKind: .attachmentRef,
                itemID: "\(kind.rawValue)-overwrite",
                itemTitle: "\(kind.displayName) \(sanitizedCloudFileName(receipt.name))"
            )
            return receipt
        } catch {
            cloudFileState = .failed(readableCloudFileErrorMessage(for: error, provider: kind))
            throw error
        }
    }

    func deleteCloudFileBackupItem(
        provider kind: CloudFileProviderKind,
        item: CloudFileItem
    ) async throws {
        recordUserActivity()
        cloudFileState = .running(kind)
        do {
            _ = try requireActiveVaultSession()
            let provider = try cloudFileProvider(for: kind)
            _ = try await provider.deleteFile(id: item.id)
            cloudFileItemsByProvider[kind]?.removeAll { $0.id == item.id }
            oneDriveDefaultLocationFiles.removeAll { $0.id == item.id }
            cloudFileState = .deleted(provider: kind, fileName: sanitizedCloudFileName(item.name))
            appendOperationTimelineEvent(
                action: .deleted,
                itemKind: .attachmentRef,
                itemID: "\(kind.rawValue)-delete",
                itemTitle: "\(kind.displayName) \(sanitizedCloudFileName(item.name))"
            )
        } catch {
            cloudFileState = .failed(readableCloudFileErrorMessage(for: error, provider: kind))
            throw error
        }
    }

    func setCloudFileBackupItemPermanent(
        provider kind: CloudFileProviderKind,
        item: CloudFileItem,
        isPermanent: Bool
    ) async throws {
        recordUserActivity()
        cloudFileState = .running(kind)
        do {
            _ = try requireActiveVaultSession()
            let provider = try cloudFileProvider(for: kind)
            let newName = permanentBackupFileName(for: item.name, isPermanent: isPermanent)
            let receipt = try await provider.renameFile(id: item.id, newName: newName)
            let updated = CloudFileItem(
                id: receipt.itemID,
                name: receipt.name,
                path: receipt.name,
                byteCount: item.byteCount,
                modifiedAt: item.modifiedAt,
                sha256: item.sha256,
                revision: receipt.revision ?? item.revision
            )
            if let index = cloudFileItemsByProvider[kind]?.firstIndex(where: { $0.id == item.id }) {
                cloudFileItemsByProvider[kind]?[index] = updated
            }
            if let defaultIndex = oneDriveDefaultLocationFiles.firstIndex(where: { $0.id == item.id }) {
                oneDriveDefaultLocationFiles[defaultIndex] = updated
            }
            cloudFileState = .permanentUpdated(
                provider: kind,
                fileName: sanitizedCloudFileName(receipt.name),
                isPermanent: isPermanent
            )
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .attachmentRef,
                itemID: "\(kind.rawValue)-permanent",
                itemTitle: "\(kind.displayName) \(sanitizedCloudFileName(receipt.name))"
            )
        } catch {
            cloudFileState = .failed(readableCloudFileErrorMessage(for: error, provider: kind))
            throw error
        }
    }

    private func permanentBackupFileName(for fileName: String, isPermanent: Bool) -> String {
        let sanitized = sanitizedCloudFileName(fileName)
        let marker = "_permanent"
        let ext = ".mdbx"
        guard sanitized.lowercased().hasSuffix(ext) else {
            return isPermanent && !sanitized.hasSuffix(marker)
                ? sanitized + marker
                : sanitized.replacingOccurrences(of: marker, with: "")
        }
        let base = String(sanitized.dropLast(ext.count))
        if isPermanent {
            return base.hasSuffix(marker) ? sanitized : "\(base)\(marker)\(ext)"
        }
        return "\(base.replacingOccurrences(of: marker, with: ""))\(ext)"
    }

    func previewBitwardenSync() async throws -> AppBitwardenSyncPreview {
        recordUserActivity()
        bitwardenSyncState = .running

        do {
            _ = try requireActiveVaultSession()
            let provider = try requireBitwardenSyncProvider()
            let snapshot = try await provider.pullSnapshot()
            let preview = AppBitwardenSyncPreview(snapshot: snapshot)
            bitwardenSyncPreview = preview
            bitwardenSyncState = .previewReady(
                itemCount: preview.remoteItemCount,
                sendCount: preview.remoteSendCount
            )
            return preview
        } catch {
            bitwardenSyncState = .failed(readableBitwardenSyncErrorMessage(for: error))
            throw error
        }
    }

    func syncBitwardenVaultData(projectTitle: String) async throws -> AppBitwardenSyncPreview {
        recordUserActivity()
        bitwardenSyncState = .running

        do {
            let session = try requireActiveVaultSession()
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let provider = try requireBitwardenSyncProvider()
            let snapshot = try await provider.pullSnapshot()
            let preview = AppBitwardenSyncPreview(snapshot: snapshot)
            let previousItemStates = try bitwardenItemSyncStateStore.loadStates(vaultID: session.handle.vaultID)
            let previousSendStates = try bitwardenSendSyncStateStore.loadStates(vaultID: session.handle.vaultID)
            try validateBitwardenRemoteSnapshotIsSafe(
                snapshot,
                previousItemStates: previousItemStates,
                previousSendStates: previousSendStates
            )
            let project = try ensureActiveProject(
                projectTitle: projectTitle,
                entryRepository: entryRepository
            )
            try importBitwardenSnapshot(
                snapshot,
                projectID: project.id,
                vaultID: session.handle.vaultID,
                entryRepository: entryRepository
            )
            try refreshAllEntryLists(projectID: project.id, entryRepository: entryRepository)
            try refreshAutoFillEncryptedIndexIfConfigured()
            bitwardenSyncPreview = preview
            bitwardenSyncState = .synced(
                itemCount: preview.remoteItemCount,
                sendCount: preview.remoteSendCount
            )
            return preview
        } catch {
            bitwardenSyncState = .failed(readableBitwardenSyncErrorMessage(for: error))
            throw error
        }
    }

    func pushLocalBitwardenChanges() async throws -> BitwardenSyncPushResult {
        recordUserActivity()
        bitwardenSyncState = .running

        do {
            let session = try requireActiveVaultSession()
            let provider = try requireBitwardenSyncProvider()
            let snapshot = try await provider.pullSnapshot()
            let preview = AppBitwardenSyncPreview(snapshot: snapshot)
            let previousItemStates = try bitwardenItemSyncStateStore.loadStates(vaultID: session.handle.vaultID)
            let previousSendStates = try bitwardenSendSyncStateStore.loadStates(vaultID: session.handle.vaultID)
            let previousFolderStates = try bitwardenFolderSyncStateStore.loadStates(vaultID: session.handle.vaultID)
            try validateBitwardenRemoteSnapshotIsSafe(
                snapshot,
                previousItemStates: previousItemStates,
                previousSendStates: previousSendStates
            )
            bitwardenSyncPreview = preview
            let itemPlan = makeBitwardenItemSyncPlan(
                remoteItems: snapshot.items,
                previousStates: previousItemStates,
                folderStates: previousFolderStates
            )
            let sendPlan = makeBitwardenSendSyncPlan(
                remoteSends: snapshot.sends,
                previousStates: previousSendStates
            )
            let pendingBatches = try bitwardenPendingMutationQueueStore.loadBatches(vaultID: session.handle.vaultID)
            bitwardenPendingMutationBatches = pendingBatches
            let mutations = itemPlan.mutations + sendPlan.mutations
            let result: BitwardenSyncPushResult
            do {
                result = try await provider.pushMutations(mutations)
            } catch {
                if isRetryableBitwardenPushError(error), !mutations.isEmpty {
                    try queueBitwardenPendingMutations(
                        mutations,
                        vaultID: session.handle.vaultID,
                        existingBatches: pendingBatches,
                        error: error
                    )
                    bitwardenSyncState = .queuedForRetry(mutationCount: mutations.count)
                }
                throw error
            }
            let itemStates = bitwardenItemStates(
                itemPlan.updatedStates.values,
                assigningRemoteIDs: result.assignedRemoteIDs,
                revision: result.revision
            )
            let sendStates = bitwardenSendStates(
                sendPlan.updatedStates.values,
                assigningRemoteIDs: result.assignedRemoteIDs,
                revision: result.revision
            )
            try bitwardenItemSyncStateStore.saveStates(
                sortedBitwardenItemStates(itemStates),
                vaultID: session.handle.vaultID
            )
            try bitwardenSendSyncStateStore.saveStates(
                sendStates.sorted { $0.localID < $1.localID },
                vaultID: session.handle.vaultID
            )
            if !pendingBatches.isEmpty {
                try bitwardenPendingMutationQueueStore.saveBatches([], vaultID: session.handle.vaultID)
            }
            bitwardenPendingMutationBatches = []
            let conflicts = itemPlan.conflicts + sendPlan.conflicts + result.conflicts
            bitwardenSyncState = .pushed(
                acceptedMutationCount: result.acceptedMutationCount,
                conflictCount: conflicts.count
            )
            return BitwardenSyncPushResult(
                acceptedMutationCount: result.acceptedMutationCount,
                conflicts: conflicts,
                revision: result.revision,
                assignedRemoteIDs: result.assignedRemoteIDs
            )
        } catch {
            if case .queuedForRetry = bitwardenSyncState {
                throw error
            }
            bitwardenSyncState = .failed(readableBitwardenSyncErrorMessage(for: error))
            throw error
        }
    }

    @discardableResult
    func downloadBitwardenAttachmentContent(
        _ entry: LocalAttachmentMetadata
    ) async throws -> LocalAttachmentMetadata {
        recordUserActivity()
        entryOperationState = .running

        do {
            let session = try requireActiveVaultSession()
            guard let entryRepository = activeEntryRepository,
                  let projectID = activeProject?.id
            else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            guard entry.source == "bitwarden",
                  entry.downloadState == "pending-bitwarden-download",
                  let localEntryID = entry.entryID,
                  !localEntryID.isEmpty
            else {
                throw AppBitwardenSyncError.attachmentUnavailable
            }
            let provider = try requireBitwardenSyncProvider()
            let itemStates = try bitwardenItemSyncStateStore.loadStates(vaultID: session.handle.vaultID)
            guard let remoteCipherID = itemStates
                .first(where: { $0.localID == localEntryID })?
                .remoteID?
                .nonBlankValue
            else {
                throw AppBitwardenSyncError.attachmentUnavailable
            }
            let snapshot = try await provider.pullSnapshot()
            guard let remoteItem = snapshot.items.first(where: { $0.remoteID == remoteCipherID }),
                  let remoteAttachment = remoteItem.attachments.first(where: {
                      bitwardenAttachmentContentHash($0) == entry.contentHash
                  })
            else {
                throw AppBitwardenSyncError.attachmentUnavailable
            }

            let download = try await provider.downloadAttachment(
                BitwardenAttachmentDownloadRequest(
                    cipherRemoteID: remoteAttachment.cipherRemoteID,
                    attachmentRemoteID: remoteAttachment.remoteID
                )
            )
            let fileName = sanitizedAttachmentPreviewFileName(entry.fileName)
            let localPath = try androidBackupAttachmentBlobStore.saveEncryptedBlob(
                download.encryptedContent,
                vaultID: session.handle.vaultID,
                localPath: bitwardenDownloadedAttachmentLocalPath(entry, fileName: fileName)
            )
            let updated = try entryRepository.updateAttachmentMetadata(
                projectID: projectID,
                attachmentID: entry.id,
                entryID: entry.entryID,
                fileName: fileName,
                mediaType: entry.mediaType.isEmpty ? "application/octet-stream" : entry.mediaType,
                originalSize: Int64(remoteAttachment.byteCount),
                storedSize: Int64(download.encryptedContent.count),
                contentHash: entry.contentHash,
                storageMode: "bitwarden-downloaded-content",
                source: "bitwarden",
                downloadState: "downloaded",
                wrappedContentEncryptionKey: remoteAttachment.encryptedKey ?? entry.wrappedContentEncryptionKey,
                localPath: localPath
            )
            attachmentEntries = try entryRepository.listAttachmentMetadata(projectID: projectID)
            appendOperationTimelineEvent(
                action: .updated,
                itemKind: .attachmentRef,
                itemID: updated.id,
                itemTitle: updated.fileName
            )
            entryOperationState = .succeeded(String(localized: "Bitwarden 附件已下载：\(updated.fileName) \(download.encryptedContent.count) 字节"))
            return updated
        } catch {
            entryOperationState = .failed(readableBitwardenSyncErrorMessage(for: error))
            throw error
        }
    }

    private func queueBitwardenPendingMutations(
        _ mutations: [BitwardenSyncMutation],
        vaultID: String,
        existingBatches: [AppBitwardenPendingMutationBatch],
        error: Error
    ) throws {
        let retryCount = (existingBatches.map(\.retryCount).max() ?? 0) + 1
        let batch = AppBitwardenPendingMutationBatch(
            vaultID: vaultID,
            mutationCount: mutations.count,
            redactedSummaries: mutations.map(\.redactedSummary),
            retryCount: retryCount,
            lastErrorSummary: readableBitwardenSyncErrorMessage(for: error)
        )
        try bitwardenPendingMutationQueueStore.saveBatches([batch], vaultID: vaultID)
        bitwardenPendingMutationBatches = [batch]
    }

    private func isRetryableBitwardenPushError(_ error: Error) -> Bool {
        if error is URLError {
            return true
        }
        if case .serverRejected(let statusCode) = error as? BitwardenSyncProviderError {
            return (500...599).contains(statusCode)
        }
        return false
    }

    private func validateBitwardenRemoteSnapshotIsSafe(
        _ snapshot: BitwardenSyncSnapshot,
        previousItemStates: [BitwardenItemSyncState],
        previousSendStates: [BitwardenSendSyncState]
    ) throws {
        guard snapshot.items.isEmpty, snapshot.sends.isEmpty else {
            return
        }
        let activeSyncedItemCount = previousItemStates.filter { state in
            state.remoteID?.nonBlankValue != nil && !state.isDeleted
        }.count
        let activeSyncedSendCount = previousSendStates.filter { state in
            state.remoteID?.nonBlankValue != nil && !state.isDeleted
        }.count
        let localCount = activeSyncedItemCount + activeSyncedSendCount
        guard localCount > 0 else {
            return
        }
        throw AppBitwardenSyncError.emptyRemoteVault(localCount: localCount)
    }

    func downloadWebDAVRestorePreview() async throws {
        recordUserActivity()
        webDAVBackupState = .running

        do {
            _ = try requireActiveVaultSession()
            let endpoint = try makeWebDAVEndpoint()
            let fileName = try normalizedWebDAVRemoteFileName(fallback: nil)
            let downloaded = try await webDAVBackupService.download(
                endpoint: endpoint,
                fileName: fileName
            )
            let preview = try WebDAVRestorePreview(downloaded)
            webDAVPassword = ""
            webDAVRestoreVaultPassword = ""
            webDAVRestorePreview = preview
            downloadedWebDAVRestoreBackup = downloaded
            webDAVBackupState = .restorePreviewReady(
                fileName: preview.fileName,
                byteCount: preview.byteCount
            )
        } catch {
            webDAVBackupState = .failed(readableWebDAVErrorMessage(for: error))
            throw error
        }
    }

    func confirmWebDAVRestore() throws {
        recordUserActivity()
        webDAVBackupState = .running

        do {
            guard let activeVaultSession else {
                throw AppWebDAVBackupError.vaultLocked
            }
            guard let preview = webDAVRestorePreview,
                  let downloaded = downloadedWebDAVRestoreBackup else {
                throw AppWebDAVBackupError.restorePreviewUnavailable
            }
            let restorePassword = webDAVRestoreVaultPassword
            guard !restorePassword.isEmpty else {
                throw AppWebDAVBackupError.emptyRestoreVaultPassword
            }

            let destinationURL = activeVaultSession.descriptor.fileURL
            try validateDownloadedWebDAVRestore(
                downloaded,
                near: destinationURL,
                password: restorePassword,
                deviceID: activeVaultSession.handle.deviceID
            )
            webDAVRestoreVaultPassword = ""
            vaultRepository.closeVault(for: activeVaultSession)
            clearUnlockedVaultSession()
            try replaceVaultFile(
                at: destinationURL,
                with: downloaded.data
            )
            webDAVRestorePreview = nil
            downloadedWebDAVRestoreBackup = nil
            webDAVBackupState = .restoreSucceeded(
                fileName: preview.fileName,
                byteCount: preview.byteCount
            )
            appendOperationTimelineEvent(
                action: .restoredBackup,
                itemKind: .attachmentRef,
                itemID: "webdav-restore",
                itemTitle: "WebDAV \(preview.fileName)"
            )
        } catch {
            webDAVRestoreVaultPassword = ""
            webDAVBackupState = .failed(readableWebDAVErrorMessage(for: error))
            appendOperationTimelineEvent(
                action: .restoredBackup,
                itemKind: .attachmentRef,
                itemID: "webdav-restore",
                itemTitle: "WebDAV backup",
                result: "failed",
                errorCategory: "WebDAV"
            )
            throw error
        }
    }

    private func readableWebDAVErrorMessage(for error: Error) -> String {
        if let appError = error as? AppWebDAVBackupError {
            return appError.localizedDescription
        }

        if let webDAVError = error as? WebDAVError {
            switch webDAVError {
            case .unexpectedStatus(_, let statusCode) where statusCode == 401 || statusCode == 403:
                return String(localized: "WebDAV 登录失败，请检查用户名和密码。")
            case .unexpectedStatus("download", 404):
                return String(localized: "未找到远端备份文件。")
            case .unexpectedStatus(_, let statusCode) where (500...599).contains(statusCode):
                return String(localized: "WebDAV 服务器当前不可用，请稍后再试。")
            case .unexpectedStatus:
                return String(localized: "WebDAV 请求失败，请检查服务器设置后重试。")
            case .integrityCheckFailed:
                return String(localized: "远端备份未通过完整性校验，可能已经损坏。")
            case .nonHTTPResponse:
                return String(localized: "WebDAV 服务器返回了无效响应。")
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return String(localized: "网络不可用，请检查连接后重试。")
            case .timedOut:
                return String(localized: "WebDAV 请求超时，请稍后再试。")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return String(localized: "无法连接 WebDAV 服务器，请检查服务器 URL。")
            case .userAuthenticationRequired, .userCancelledAuthentication:
                return String(localized: "WebDAV 登录失败，请检查用户名和密码。")
            default:
                return String(localized: "WebDAV 连接失败，请检查网络和服务器设置。")
            }
        }

        return error.localizedDescription
    }

    func cloudFileProvider(for kind: CloudFileProviderKind) throws -> any CloudFileProvider {
        guard let provider = cloudFileProviders[kind] else {
            throw AppCloudFileError.providerUnavailable(kind)
        }
        return provider
    }

    private func requireBitwardenSyncProvider() throws -> any BitwardenSyncProvider {
        guard let bitwardenSyncProvider else {
            throw AppBitwardenSyncError.providerUnavailable
        }
        return bitwardenSyncProvider
    }

    private func importBitwardenSnapshot(
        _ snapshot: BitwardenSyncSnapshot,
        projectID: String,
        vaultID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws {
        var existingLogins = try entryRepository.listLoginEntries(projectID: projectID)
        var existingNotes = try entryRepository.listNoteEntries(projectID: projectID)
        var existingCards = try entryRepository.listCardEntries(projectID: projectID)
        var existingIdentities = try entryRepository.listIdentityEntries(projectID: projectID)
        var existingPasskeys = try entryRepository.listPasskeyEntries(projectID: projectID)
        var existingSshKeys = try entryRepository.listSshKeyEntries(projectID: projectID)
        var existingTotps = try entryRepository.listTotpEntries(projectID: projectID)
        var existingSends = try entryRepository.listSendEntries(projectID: projectID)
        var itemStates = Dictionary(
            uniqueKeysWithValues: try bitwardenItemSyncStateStore
                .loadStates(vaultID: vaultID)
                .map { ($0.localID, $0) }
        )
        var sendStates = Dictionary(
            uniqueKeysWithValues: try bitwardenSendSyncStateStore
                .loadStates(vaultID: vaultID)
                .map { ($0.localID, $0) }
        )
        var folderStates = Dictionary(
            uniqueKeysWithValues: try bitwardenFolderSyncStateStore
                .loadStates(vaultID: vaultID)
                .map { ($0.localID, $0) }
        )
        var projectIDByFolderRemoteID: [String: String] = [:]
        if !snapshot.folders.isEmpty {
            var projects = try entryRepository.listProjects()
            for folder in snapshot.folders {
                let title = bitwardenImportTitle(folder.name)
                let project: LocalVaultProject
                if let existing = projects.first(where: { $0.title == title }) {
                    project = existing
                } else {
                    project = try entryRepository.createProject(title: title)
                    projects.append(project)
                }
                projectIDByFolderRemoteID[folder.remoteID] = project.id
                folderStates[project.id] = BitwardenFolderSyncState(
                    localID: project.id,
                    remoteID: folder.remoteID,
                    name: title,
                    lastSyncedFingerprint: title,
                    lastRemoteRevision: folder.updatedAt.map { String($0.timeIntervalSince1970) },
                    isDeleted: false
                )
            }
        }

        for item in snapshot.items {
            let targetProjectID = item.folderID.flatMap { projectIDByFolderRemoteID[$0] } ?? projectID
            switch item.kind {
            case .login:
                var localEntry: LocalLoginEntry
                if targetProjectID == projectID,
                   let existing = existingLogins.first(where: { isSameBitwardenLogin($0, item) }) {
                    localEntry = existing
                } else {
                    localEntry = try entryRepository.createLoginEntry(
                        projectID: targetProjectID,
                        draft: LocalLoginEntryDraft(
                            title: bitwardenImportTitle(item.title),
                            username: item.username,
                            password: item.password ?? "",
                            url: item.url,
                            notes: item.notes ?? ""
                        )
                    )
                }
                localEntry = try applyBitwardenRemoteState(
                    item,
                    to: localEntry,
                    projectID: targetProjectID,
                    entryRepository: entryRepository
                )
                if targetProjectID == projectID {
                    existingLogins.removeAll { $0.id == localEntry.id }
                    if item.deletedAt == nil {
                        existingLogins.append(localEntry)
                    }
                }
                let localItem = bitwardenLocalItem(from: localEntry, folderID: item.folderID, folderName: item.folderName)
                itemStates[localEntry.id] = bitwardenItemSyncState(
                    localItem: localItem,
                    remoteItem: item
                )
                try reconcileBitwardenAttachments(
                    item.attachments,
                    localEntryID: localEntry.id,
                    projectID: targetProjectID,
                    entryRepository: entryRepository
                )
                if let totpSecret = item.totpSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !totpSecret.isEmpty,
                   !existingTotps.contains(where: { $0.title == bitwardenImportTitle(item.title) && $0.secret == totpSecret }) {
                    let created = try entryRepository.createTotpEntry(
                        projectID: projectID,
                        draft: LocalTotpEntryDraft(
                            title: bitwardenImportTitle(item.title),
                            secret: totpSecret,
                            issuer: item.folderName ?? snapshot.accountLabel,
                            accountName: item.username,
                            period: 30,
                            digits: 6,
                            algorithm: "SHA1",
                            otpType: "TOTP",
                            counter: 0
                        )
                    )
                    existingTotps.append(created)
                }
            case .passkey:
                var localEntry: LocalPasskeyEntry
                if targetProjectID == projectID,
                   let existing = existingPasskeys.first(where: { isSameBitwardenPasskey($0, item) }) {
                    localEntry = existing
                } else {
                    localEntry = try entryRepository.createPasskeyEntry(
                        projectID: targetProjectID,
                        draft: LocalPasskeyEntryDraft(
                            title: bitwardenImportTitle(item.title),
                            relyingPartyID: bitwardenPasskeyRelyingPartyID(for: item),
                            username: item.username,
                            userHandle: item.passkeyUserHandle,
                            credentialID: item.passkeyCredentialID,
                            publicKeyCOSE: item.passkeyPublicKeyCOSE,
                            privateKeyReference: item.passkeyPrivateKeyReference,
                            notes: item.notes ?? ""
                        )
                    )
                }
                localEntry = try applyBitwardenRemoteState(
                    item,
                    to: localEntry,
                    projectID: targetProjectID,
                    entryRepository: entryRepository
                )
                if targetProjectID == projectID {
                    existingPasskeys.removeAll { $0.id == localEntry.id }
                    if item.deletedAt == nil {
                        existingPasskeys.append(localEntry)
                    }
                }
                let localItem = bitwardenLocalItem(from: localEntry, folderID: item.folderID, folderName: item.folderName)
                itemStates[localEntry.id] = bitwardenItemSyncState(
                    localItem: localItem,
                    remoteItem: item
                )
                try reconcileBitwardenAttachments(
                    item.attachments,
                    localEntryID: localEntry.id,
                    projectID: targetProjectID,
                    entryRepository: entryRepository
                )
            case .sshKey:
                var localEntry: LocalSshKeyEntry
                if targetProjectID == projectID,
                   let existing = existingSshKeys.first(where: { isSameBitwardenSshKey($0, item) }) {
                    localEntry = existing
                } else {
                    localEntry = try entryRepository.createSshKeyEntry(
                        projectID: targetProjectID,
                        draft: LocalSshKeyEntryDraft(
                            title: bitwardenImportTitle(item.title),
                            username: item.username,
                            host: item.url,
                            publicKey: item.sshPublicKey,
                            privateKeyReference: item.sshPrivateKey,
                            passphraseHint: item.sshKeyFingerprint,
                            notes: item.notes ?? ""
                        )
                    )
                }
                localEntry = try applyBitwardenRemoteState(
                    item,
                    to: localEntry,
                    projectID: targetProjectID,
                    entryRepository: entryRepository
                )
                if targetProjectID == projectID {
                    existingSshKeys.removeAll { $0.id == localEntry.id }
                    if item.deletedAt == nil {
                        existingSshKeys.append(localEntry)
                    }
                }
                let localItem = bitwardenLocalItem(from: localEntry, folderID: item.folderID, folderName: item.folderName)
                itemStates[localEntry.id] = bitwardenItemSyncState(
                    localItem: localItem,
                    remoteItem: item
                )
                try reconcileBitwardenAttachments(
                    item.attachments,
                    localEntryID: localEntry.id,
                    projectID: targetProjectID,
                    entryRepository: entryRepository
                )
            case .secureNote:
                var localEntry: LocalNoteEntry
                if targetProjectID == projectID,
                   let existing = existingNotes.first(where: { $0.title == bitwardenImportTitle(item.title) && $0.body == (item.notes ?? "") }) {
                    localEntry = existing
                } else {
                    localEntry = try entryRepository.createNoteEntry(
                        projectID: targetProjectID,
                        draft: LocalNoteEntryDraft(
                            title: bitwardenImportTitle(item.title),
                            body: item.notes ?? ""
                        )
                    )
                }
                localEntry = try applyBitwardenRemoteState(
                    item,
                    to: localEntry,
                    projectID: targetProjectID,
                    entryRepository: entryRepository
                )
                if targetProjectID == projectID {
                    existingNotes.removeAll { $0.id == localEntry.id }
                    if item.deletedAt == nil {
                        existingNotes.append(localEntry)
                    }
                }
                let localItem = bitwardenLocalItem(from: localEntry, folderID: item.folderID, folderName: item.folderName)
                itemStates[localEntry.id] = bitwardenItemSyncState(
                    localItem: localItem,
                    remoteItem: item
                )
                try reconcileBitwardenAttachments(
                    item.attachments,
                    localEntryID: localEntry.id,
                    projectID: targetProjectID,
                    entryRepository: entryRepository
                )
            case .card:
                var localEntry: LocalCardEntry
                if targetProjectID == projectID,
                   let existing = existingCards.first(where: { $0.title == bitwardenImportTitle(item.title) && $0.notes == (item.notes ?? "") }) {
                    localEntry = existing
                } else {
                    localEntry = try entryRepository.createCardEntry(
                        projectID: targetProjectID,
                        draft: LocalCardEntryDraft(
                            title: bitwardenImportTitle(item.title),
                            cardholderName: item.cardholderName,
                            number: item.cardNumber,
                            expiryMonth: item.cardExpiryMonth,
                            expiryYear: item.cardExpiryYear,
                            cvv: item.cardCode,
                            issuer: item.folderName ?? "",
                            network: item.cardBrand,
                            notes: item.notes ?? ""
                        )
                    )
                }
                localEntry = try applyBitwardenRemoteState(
                    item,
                    to: localEntry,
                    projectID: targetProjectID,
                    entryRepository: entryRepository
                )
                if targetProjectID == projectID {
                    existingCards.removeAll { $0.id == localEntry.id }
                    if item.deletedAt == nil {
                        existingCards.append(localEntry)
                    }
                }
                let localItem = bitwardenLocalItem(from: localEntry, folderID: item.folderID)
                itemStates[localEntry.id] = bitwardenItemSyncState(
                    localItem: localItem,
                    remoteItem: item
                )
                try reconcileBitwardenAttachments(
                    item.attachments,
                    localEntryID: localEntry.id,
                    projectID: targetProjectID,
                    entryRepository: entryRepository
                )
            case .identity:
                var localEntry: LocalIdentityEntry
                if targetProjectID == projectID,
                   let existing = existingIdentities.first(where: { $0.title == bitwardenImportTitle(item.title) && $0.notes == (item.notes ?? "") }) {
                    localEntry = existing
                } else {
                    localEntry = try entryRepository.createIdentityEntry(
                        projectID: targetProjectID,
                        draft: LocalIdentityEntryDraft(
                            title: bitwardenImportTitle(item.title),
                            documentType: "Bitwarden Identity",
                            fullName: item.identityFullName.isEmpty ? item.username : item.identityFullName,
                            documentNumber: item.identityDocumentNumber,
                            issuer: item.identityIssuer.isEmpty ? (item.folderName ?? "") : item.identityIssuer,
                            country: item.identityCountry,
                            issueDate: "",
                            expiryDate: "",
                            notes: item.notes ?? ""
                        )
                    )
                }
                localEntry = try applyBitwardenRemoteState(
                    item,
                    to: localEntry,
                    projectID: targetProjectID,
                    entryRepository: entryRepository
                )
                if targetProjectID == projectID {
                    existingIdentities.removeAll { $0.id == localEntry.id }
                    if item.deletedAt == nil {
                        existingIdentities.append(localEntry)
                    }
                }
                let localItem = bitwardenLocalItem(from: localEntry, folderID: item.folderID)
                itemStates[localEntry.id] = bitwardenItemSyncState(
                    localItem: localItem,
                    remoteItem: item
                )
                try reconcileBitwardenAttachments(
                    item.attachments,
                    localEntryID: localEntry.id,
                    projectID: targetProjectID,
                    entryRepository: entryRepository
                )
            }
        }

        for send in snapshot.sends {
            let remoteFingerprint = BitwardenLocalSendSyncItem(
                localID: send.remoteID,
                title: send.title,
                body: send.body,
                notes: send.notes,
                expiresAt: send.expiresAt,
                maxViews: send.maxViews
            ).syncFingerprint
            if let existing = existingSends.first(where: { isSameBitwardenSend($0, send) }) {
                sendStates[existing.id] = BitwardenSendSyncState(
                    localID: existing.id,
                    remoteID: send.remoteID,
                    lastSyncedFingerprint: remoteFingerprint,
                    lastRemoteRevision: send.updatedAt.map { String($0.timeIntervalSince1970) },
                    isDeleted: false
                )
                continue
            }
            let created = try entryRepository.createSendEntry(
                projectID: projectID,
                draft: LocalSendEntryDraft(
                    title: bitwardenImportTitle(send.title),
                    body: send.body,
                    expiresAt: send.expiresAt,
                    maxViews: send.maxViews,
                    notes: send.notes ?? ""
                )
            )
            existingSends.append(created)
            sendStates[created.id] = BitwardenSendSyncState(
                localID: created.id,
                remoteID: send.remoteID,
                lastSyncedFingerprint: remoteFingerprint,
                lastRemoteRevision: send.updatedAt.map { String($0.timeIntervalSince1970) },
                isDeleted: false
            )
        }

        try bitwardenItemSyncStateStore.saveStates(
            sortedBitwardenItemStates(itemStates.values),
            vaultID: vaultID
        )
        try bitwardenFolderSyncStateStore.saveStates(
            folderStates.values.sorted { $0.localID < $1.localID },
            vaultID: vaultID
        )
        try bitwardenSendSyncStateStore.saveStates(
            sendStates.values.sorted { $0.localID < $1.localID },
            vaultID: vaultID
        )
    }

    private func isSameBitwardenLogin(_ entry: LocalLoginEntry, _ item: BitwardenSyncItem) -> Bool {
        entry.title == bitwardenImportTitle(item.title)
            && entry.username == item.username
            && entry.url == item.url
    }

    private func isSameBitwardenPasskey(_ entry: LocalPasskeyEntry, _ item: BitwardenSyncItem) -> Bool {
        entry.title == bitwardenImportTitle(item.title)
            && entry.relyingPartyID == bitwardenPasskeyRelyingPartyID(for: item)
            && entry.username == item.username
            && entry.credentialID == item.passkeyCredentialID
    }

    private func isSameBitwardenSshKey(_ entry: LocalSshKeyEntry, _ item: BitwardenSyncItem) -> Bool {
        entry.title == bitwardenImportTitle(item.title)
            && entry.username == item.username
            && entry.host == item.url
            && entry.publicKey == item.sshPublicKey
    }

    private func isSameBitwardenSend(_ entry: LocalSendEntry, _ send: BitwardenSendSyncItem) -> Bool {
        entry.title == bitwardenImportTitle(send.title)
            && entry.body == send.body
            && entry.expiresAt == send.expiresAt
            && entry.maxViews == send.maxViews
            && entry.notes == (send.notes ?? "")
    }

    private func bitwardenImportTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Bitwarden 项目") : trimmed
    }

    private func bitwardenPasskeyRelyingPartyID(for item: BitwardenSyncItem) -> String {
        if let relyingPartyID = item.passkeyRelyingPartyID.nonBlankValue {
            return relyingPartyID
        }
        guard let host = URLComponents(string: item.url)?.host?.nonBlankValue else {
            return ""
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func applyBitwardenRemoteState(
        _ item: BitwardenSyncItem,
        to entry: LocalLoginEntry,
        projectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> LocalLoginEntry {
        var current = entry
        if current.favorite != item.favorite {
            current = try entryRepository.setLoginEntryFavorite(
                projectID: projectID,
                entryID: current.id,
                favorite: item.favorite
            )
        }
        if item.deletedAt != nil {
            try entryRepository.deleteLoginEntry(projectID: projectID, entryID: current.id)
        }
        return current
    }

    private func applyBitwardenRemoteState(
        _ item: BitwardenSyncItem,
        to entry: LocalNoteEntry,
        projectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> LocalNoteEntry {
        var current = entry
        if current.favorite != item.favorite {
            current = try entryRepository.setNoteEntryFavorite(
                projectID: projectID,
                entryID: current.id,
                favorite: item.favorite
            )
        }
        if item.deletedAt != nil {
            try entryRepository.deleteNoteEntry(projectID: projectID, entryID: current.id)
        }
        return current
    }

    private func applyBitwardenRemoteState(
        _ item: BitwardenSyncItem,
        to entry: LocalCardEntry,
        projectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> LocalCardEntry {
        var current = entry
        if current.favorite != item.favorite {
            current = try entryRepository.setCardEntryFavorite(
                projectID: projectID,
                entryID: current.id,
                favorite: item.favorite
            )
        }
        if item.deletedAt != nil {
            try entryRepository.deleteCardEntry(projectID: projectID, entryID: current.id)
        }
        return current
    }

    private func applyBitwardenRemoteState(
        _ item: BitwardenSyncItem,
        to entry: LocalIdentityEntry,
        projectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> LocalIdentityEntry {
        var current = entry
        if current.favorite != item.favorite {
            current = try entryRepository.setIdentityEntryFavorite(
                projectID: projectID,
                entryID: current.id,
                favorite: item.favorite
            )
        }
        if item.deletedAt != nil {
            try entryRepository.deleteIdentityEntry(projectID: projectID, entryID: current.id)
        }
        return current
    }

    private func applyBitwardenRemoteState(
        _ item: BitwardenSyncItem,
        to entry: LocalPasskeyEntry,
        projectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> LocalPasskeyEntry {
        var current = entry
        if current.favorite != item.favorite {
            current = try entryRepository.setPasskeyEntryFavorite(
                projectID: projectID,
                entryID: current.id,
                favorite: item.favorite
            )
        }
        if item.deletedAt != nil {
            try entryRepository.deletePasskeyEntry(projectID: projectID, entryID: current.id)
        }
        return current
    }

    private func applyBitwardenRemoteState(
        _ item: BitwardenSyncItem,
        to entry: LocalSshKeyEntry,
        projectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> LocalSshKeyEntry {
        var current = entry
        if current.favorite != item.favorite {
            current = try entryRepository.setSshKeyEntryFavorite(
                projectID: projectID,
                entryID: current.id,
                favorite: item.favorite
            )
        }
        if item.deletedAt != nil {
            try entryRepository.deleteSshKeyEntry(projectID: projectID, entryID: current.id)
        }
        return current
    }

    private func reconcileBitwardenAttachments(
        _ remoteAttachments: [BitwardenSyncAttachment],
        localEntryID: String,
        projectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws {
        let localAttachments = try entryRepository.listAttachmentMetadata(projectID: projectID)
            .filter { $0.entryID == localEntryID && $0.source == "bitwarden" }
        let remoteByHash = Dictionary(uniqueKeysWithValues: remoteAttachments.map { attachment in
            (bitwardenAttachmentContentHash(attachment), attachment)
        })
        for local in localAttachments where remoteByHash[local.contentHash] == nil {
            try entryRepository.deleteAttachmentMetadata(projectID: projectID, attachmentID: local.id)
        }
        for attachment in remoteAttachments {
            let contentHash = bitwardenAttachmentContentHash(attachment)
            if let existing = localAttachments.first(where: { $0.contentHash == contentHash }) {
                if existing.fileName != bitwardenAttachmentFileName(attachment)
                    || existing.originalSize != Int64(attachment.byteCount)
                    || existing.wrappedContentEncryptionKey != attachment.encryptedKey {
                    _ = try entryRepository.updateAttachmentMetadata(
                        projectID: projectID,
                        attachmentID: existing.id,
                        entryID: localEntryID,
                        fileName: bitwardenAttachmentFileName(attachment),
                        mediaType: "application/octet-stream",
                        originalSize: Int64(attachment.byteCount),
                        storedSize: 0,
                        contentHash: contentHash,
                        storageMode: "remote-bitwarden",
                        source: "bitwarden",
                        downloadState: "pending-bitwarden-download",
                        wrappedContentEncryptionKey: attachment.encryptedKey,
                        localPath: nil
                    )
                }
                continue
            }
            _ = try entryRepository.createAttachmentMetadata(
                projectID: projectID,
                entryID: localEntryID,
                fileName: bitwardenAttachmentFileName(attachment),
                mediaType: "application/octet-stream",
                originalSize: Int64(attachment.byteCount),
                storedSize: 0,
                contentHash: contentHash,
                storageMode: "remote-bitwarden",
                source: "bitwarden",
                downloadState: "pending-bitwarden-download",
                wrappedContentEncryptionKey: attachment.encryptedKey,
                localPath: nil
            )
        }
    }

    private func bitwardenAttachmentContentHash(_ attachment: BitwardenSyncAttachment) -> String {
        let digest = SHA256.hash(data: Data(attachment.syncFingerprint.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func bitwardenAttachmentFileName(_ attachment: BitwardenSyncAttachment) -> String {
        sanitizedAttachmentPreviewFileName(bitwardenImportTitle(attachment.fileName))
    }

    private func bitwardenItemSyncState(
        localItem: BitwardenLocalItemSyncItem,
        remoteItem: BitwardenSyncItem
    ) -> BitwardenItemSyncState {
        BitwardenItemSyncState(
            localID: localItem.localID,
            remoteID: remoteItem.remoteID,
            kind: localItem.kind,
            lastSyncedFingerprint: localItem.syncFingerprint,
            lastRemoteRevision: remoteItem.updatedAt.map { String($0.timeIntervalSince1970) },
            isDeleted: remoteItem.deletedAt != nil
        )
    }

    private func sortedBitwardenItemStates(
        _ states: Dictionary<String, BitwardenItemSyncState>.Values
    ) -> [BitwardenItemSyncState] {
        sortedBitwardenItemStates(Array(states))
    }

    private func sortedBitwardenItemStates(
        _ states: [BitwardenItemSyncState]
    ) -> [BitwardenItemSyncState] {
        states.sorted { lhs, rhs in
            let lhsRemoteID = lhs.remoteID ?? ""
            let rhsRemoteID = rhs.remoteID ?? ""
            if lhsRemoteID != rhsRemoteID {
                return lhsRemoteID < rhsRemoteID
            }
            return lhs.localID < rhs.localID
        }
    }

    private func bitwardenItemStates(
        _ states: Dictionary<String, BitwardenItemSyncState>.Values,
        assigningRemoteIDs assignedRemoteIDs: [String: String],
        revision: String
    ) -> [BitwardenItemSyncState] {
        states.map { state in
            guard let assignedRemoteID = assignedRemoteIDs[state.localID],
                  state.remoteID == nil,
                  !state.isDeleted else {
                return state
            }
            return BitwardenItemSyncState(
                localID: state.localID,
                remoteID: assignedRemoteID,
                kind: state.kind,
                lastSyncedFingerprint: state.lastSyncedFingerprint,
                lastRemoteRevision: revision.isEmpty ? state.lastRemoteRevision : revision,
                isDeleted: false
            )
        }
    }

    private func bitwardenSendStates(
        _ states: Dictionary<String, BitwardenSendSyncState>.Values,
        assigningRemoteIDs assignedRemoteIDs: [String: String],
        revision: String
    ) -> [BitwardenSendSyncState] {
        states.map { state in
            guard let assignedRemoteID = assignedRemoteIDs[state.localID],
                  state.remoteID == nil,
                  !state.isDeleted else {
                return state
            }
            return BitwardenSendSyncState(
                localID: state.localID,
                remoteID: assignedRemoteID,
                lastSyncedFingerprint: state.lastSyncedFingerprint,
                lastRemoteRevision: revision.isEmpty ? state.lastRemoteRevision : revision,
                isDeleted: false
            )
        }
    }

    private func bitwardenTextSendFingerprint(
        title: String,
        body: String,
        notes: String?,
        expiresAt: String,
        maxViews: Int
    ) -> String {
        [
            "text",
            title,
            body,
            notes ?? "",
            expiresAt,
            String(maxViews)
        ].joined(separator: "\u{1F}")
    }

    private func bitwardenFileSendFingerprint(
        title: String,
        fileName: String,
        byteCount: Int,
        notes: String?,
        expiresAt: String,
        maxViews: Int,
        hideEmail: Bool
    ) -> String {
        [
            "file",
            title,
            fileName,
            String(byteCount),
            notes ?? "",
            expiresAt,
            String(maxViews),
            String(hideEmail)
        ].joined(separator: "\u{1F}")
    }

    private func bitwardenLocalItem(from entry: LocalLoginEntry, folderID: String? = nil, folderName: String? = nil) -> BitwardenLocalItemSyncItem {
        BitwardenLocalItemSyncItem(
            localID: entry.id,
            kind: .login,
            title: entry.title,
            username: entry.username,
            url: entry.url,
            password: entry.password,
            notes: entry.notes,
            folderID: folderID,
            folderName: folderName,
            favorite: entry.favorite
        )
    }

    private func bitwardenLocalItem(from entry: LocalNoteEntry, folderID: String? = nil, folderName: String? = nil) -> BitwardenLocalItemSyncItem {
        BitwardenLocalItemSyncItem(
            localID: entry.id,
            kind: .secureNote,
            title: entry.title,
            notes: entry.body,
            folderID: folderID,
            folderName: folderName,
            favorite: entry.favorite
        )
    }

    private func bitwardenLocalItem(from entry: LocalTotpEntry, folderID: String? = nil, folderName: String? = nil) -> BitwardenLocalItemSyncItem {
        BitwardenLocalItemSyncItem(
            localID: entry.id,
            kind: .login,
            title: entry.title,
            username: entry.accountName,
            url: bitwardenTotpURLHint(from: entry),
            totpSecret: bitwardenTotpPayload(from: entry),
            folderID: folderID,
            folderName: folderName,
            favorite: entry.favorite
        )
    }

    private func bitwardenLocalItem(from entry: LocalCardEntry, folderID: String? = nil) -> BitwardenLocalItemSyncItem {
        BitwardenLocalItemSyncItem(
            localID: entry.id,
            kind: .card,
            title: entry.title,
            notes: entry.notes,
            folderID: folderID,
            folderName: entry.issuer.nonBlankValue,
            favorite: entry.favorite,
            cardholderName: entry.cardholderName,
            cardNumber: entry.number,
            cardExpiryMonth: entry.expiryMonth,
            cardExpiryYear: entry.expiryYear,
            cardCode: entry.cvv,
            cardBrand: entry.network
        )
    }

    private func bitwardenLocalItem(from entry: LocalIdentityEntry, folderID: String? = nil) -> BitwardenLocalItemSyncItem {
        BitwardenLocalItemSyncItem(
            localID: entry.id,
            kind: .identity,
            title: entry.title,
            username: entry.fullName,
            notes: entry.notes,
            folderID: folderID,
            folderName: entry.issuer.nonBlankValue,
            favorite: entry.favorite,
            identityFullName: entry.fullName,
            identityDocumentNumber: entry.documentNumber,
            identityIssuer: entry.issuer,
            identityCountry: entry.country
        )
    }

    private func bitwardenLocalItem(from entry: LocalPasskeyEntry, folderID: String? = nil, folderName: String? = nil) -> BitwardenLocalItemSyncItem {
        let relyingPartyID = entry.relyingPartyID.trimmingCharacters(in: .whitespacesAndNewlines)
        return BitwardenLocalItemSyncItem(
            localID: entry.id,
            kind: .passkey,
            title: entry.title,
            username: entry.username,
            url: relyingPartyID.isEmpty ? "" : "https://\(relyingPartyID)",
            notes: entry.notes,
            folderID: folderID,
            folderName: folderName,
            favorite: entry.favorite,
            passkeyRelyingPartyID: relyingPartyID,
            passkeyRelyingPartyName: entry.title,
            passkeyCredentialID: entry.credentialID,
            passkeyUserHandle: entry.userHandle,
            passkeyPublicKeyCOSE: entry.publicKeyCOSE,
            passkeyPrivateKeyReference: entry.privateKeyReference,
            passkeyPublicKeyAlgorithm: "ECDSA",
            passkeyCounter: "0",
            passkeyDiscoverable: true
        )
    }

    private func bitwardenLocalItem(from entry: LocalSshKeyEntry, folderID: String? = nil, folderName: String? = nil) -> BitwardenLocalItemSyncItem {
        BitwardenLocalItemSyncItem(
            localID: entry.id,
            kind: .sshKey,
            title: entry.title,
            username: entry.username,
            url: entry.host,
            notes: entry.notes,
            folderID: folderID,
            folderName: folderName,
            favorite: entry.favorite,
            sshPublicKey: entry.publicKey,
            sshPrivateKey: entry.privateKeyReference,
            sshKeyFingerprint: entry.passphraseHint
        )
    }

    private func bitwardenTotpURLHint(from entry: LocalTotpEntry) -> String {
        let label = entry.issuer.nonBlankValue ?? entry.title
        return "otpauth://\(bitwardenOtpAuthKind(from: entry))/\(bitwardenPercentEncode(label))"
    }

    private func bitwardenTotpPayload(from entry: LocalTotpEntry) -> String {
        let issuer = entry.issuer.nonBlankValue ?? entry.title
        let account = entry.accountName.nonBlankValue ?? ""
        let encodedLabel = account.isEmpty
            ? bitwardenPercentEncode(issuer)
            : "\(bitwardenPercentEncode(issuer)):\(bitwardenPercentEncode(account))"
        var query = [
            ("secret", entry.secret)
        ]
        if let explicitIssuer = entry.issuer.nonBlankValue {
            query.append(("issuer", explicitIssuer))
        }
        query.append(("period", "\(entry.period)"))
        query.append(("digits", "\(entry.digits)"))
        if let algorithm = entry.algorithm.nonBlankValue {
            query.append(("algorithm", algorithm.uppercased()))
        }
        if bitwardenOtpAuthKind(from: entry) == "hotp" {
            query.append(("counter", "\(entry.counter)"))
        }
        return "otpauth://\(bitwardenOtpAuthKind(from: entry))/\(encodedLabel)?"
            + query.map { "\(bitwardenPercentEncode($0.0))=\(bitwardenPercentEncode($0.1))" }.joined(separator: "&")
    }

    private func bitwardenOtpAuthKind(from entry: LocalTotpEntry) -> String {
        entry.otpType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "hotp" ? "hotp" : "totp"
    }

    private func bitwardenPercentEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func makeBitwardenItemSyncPlan(
        remoteItems: [BitwardenSyncItem],
        previousStates: [BitwardenItemSyncState],
        folderStates: [BitwardenFolderSyncState] = []
    ) -> BitwardenItemSyncPlan {
        let folderStateByProjectID = Dictionary(uniqueKeysWithValues: folderStates.map { ($0.localID, $0) })
        let localLoginItems: [BitwardenLocalItemSyncItem] = loginEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID, folderName: folderStateByProjectID[$0.projectID]?.name)
        }
        let localNoteItems: [BitwardenLocalItemSyncItem] = noteEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID, folderName: folderStateByProjectID[$0.projectID]?.name)
        }
        let localTotpItems: [BitwardenLocalItemSyncItem] = totpEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID, folderName: folderStateByProjectID[$0.projectID]?.name)
        }
        let localCardItems: [BitwardenLocalItemSyncItem] = cardEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID)
        }
        let localIdentityItems: [BitwardenLocalItemSyncItem] = identityEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID)
        }
        let localPasskeyItems: [BitwardenLocalItemSyncItem] = passkeyEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID, folderName: folderStateByProjectID[$0.projectID]?.name)
        }
        let localSshKeyItems: [BitwardenLocalItemSyncItem] = sshKeyEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID, folderName: folderStateByProjectID[$0.projectID]?.name)
        }
        let deletedLoginItems: [BitwardenLocalItemSyncItem] = deletedLoginEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID, folderName: folderStateByProjectID[$0.projectID]?.name)
        }
        let deletedNoteItems: [BitwardenLocalItemSyncItem] = deletedNoteEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID, folderName: folderStateByProjectID[$0.projectID]?.name)
        }
        let deletedTotpItems: [BitwardenLocalItemSyncItem] = deletedTotpEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID, folderName: folderStateByProjectID[$0.projectID]?.name)
        }
        let deletedCardItems: [BitwardenLocalItemSyncItem] = deletedCardEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID)
        }
        let deletedIdentityItems: [BitwardenLocalItemSyncItem] = deletedIdentityEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID)
        }
        let deletedPasskeyItems: [BitwardenLocalItemSyncItem] = deletedPasskeyEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID, folderName: folderStateByProjectID[$0.projectID]?.name)
        }
        let deletedSshKeyItems: [BitwardenLocalItemSyncItem] = deletedSshKeyEntries.map {
            bitwardenLocalItem(from: $0, folderID: folderStateByProjectID[$0.projectID]?.remoteID, folderName: folderStateByProjectID[$0.projectID]?.name)
        }
        let localItems = localLoginItems + localTotpItems + localNoteItems + localCardItems + localIdentityItems + localPasskeyItems + localSshKeyItems
        let deletedLocalItems = deletedLoginItems + deletedTotpItems + deletedNoteItems + deletedCardItems + deletedIdentityItems + deletedPasskeyItems + deletedSshKeyItems

        return BitwardenItemSyncPlanner().plan(
            localItems: localItems,
            deletedLocalItems: deletedLocalItems,
            remoteItems: remoteItems,
            previousStates: previousStates
        )
    }

    private func makeBitwardenSendSyncPlan(
        remoteSends: [BitwardenSendSyncItem],
        previousStates: [BitwardenSendSyncState]
    ) -> BitwardenSendSyncPlan {
        BitwardenSendSyncPlanner().plan(
            localSends: sendEntries.map { entry in
                BitwardenLocalSendSyncItem(
                    localID: entry.id,
                    title: entry.title,
                    body: entry.body,
                    notes: entry.notes,
                    expiresAt: entry.expiresAt,
                    maxViews: entry.maxViews
                )
            },
            deletedLocalSends: deletedSendEntries.map { entry in
                BitwardenLocalSendSyncItem(
                    localID: entry.id,
                    title: entry.title,
                    body: entry.body,
                    notes: entry.notes,
                    expiresAt: entry.expiresAt,
                    maxViews: entry.maxViews
                )
            },
            remoteSends: remoteSends,
            previousStates: previousStates
        )
    }

    private func readableCloudFileErrorMessage(
        for error: Error,
        provider kind: CloudFileProviderKind
    ) -> String {
        if let appError = error as? AppCloudFileError {
            return appError.localizedDescription
        }
        if let providerError = error as? CloudFileProviderError {
            return providerError.localizedDescription
        }
        if kind == .oneDrive {
            return readableOneDriveAuthenticationErrorMessage(error)
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return String(localized: "网络不可用，请检查连接后重试。")
            case .timedOut:
                return String(localized: "\(kind.displayName) 请求超时，请稍后再试。")
            default:
                return String(localized: "\(kind.displayName) 连接失败，请检查网络后重试。")
            }
        }
        return String(localized: "\(kind.displayName) 操作失败，请稍后重试。")
    }

    private func readableBitwardenSyncErrorMessage(for error: Error) -> String {
        if let appError = error as? AppBitwardenSyncError {
            return appError.localizedDescription
        }
        if let providerError = error as? BitwardenSyncProviderError {
            return providerError.localizedDescription
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return String(localized: "网络不可用，请检查连接后重试。")
            case .timedOut:
                return String(localized: "Bitwarden 请求超时，请稍后再试。")
            default:
                return String(localized: "Bitwarden 连接失败，请检查网络后重试。")
            }
        }
        return String(localized: "Bitwarden 同步失败，请稍后重试。")
    }

    private func validBitwardenServerURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host,
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return url
    }

    private func sanitizedCloudFileName(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? value
        let sanitized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? String(localized: "未命名文件") : sanitized
    }

    func lockLocalVault() {
        isPrivacyShieldVisible = false
        pendingControlPage = nil
        // 锁库立即恢复敏感预览掩码；临时显示状态只在内存里，不跨解锁会话。
        resetSensitivePreviewReveal()
        if let activeVaultSession {
            vaultRepository.closeVault(for: activeVaultSession)
        }
        clearUnlockedVaultSession()
        vaultOperationState = .idle
        autoFillIndexState = .idle
        webDAVBackupState = .idle
        webDAVRestorePreview = nil
        webDAVRestoreVaultPassword = ""
        downloadedWebDAVRestoreBackup = nil
        cloudFileState = .idle
        cloudFileRestorePreview = nil
        downloadedCloudFileRestore = nil
        bitwardenSyncState = .idle
        bitwardenSyncPreview = nil
        bitwardenPendingMutationBatches = []
        clearPendingAndroidEncryptedBackup()
        dismissAttachmentQuickLookPreview()
    }

    private func rememberVault(_ session: LocalVaultSession) {
        rememberedVaultDescriptor = session.descriptor
        rememberedVaultID = session.handle.vaultID
        try? rememberedVaultStore.save(
            RememberedVaultRecord(
                fileURL: session.descriptor.fileURL,
                displayName: session.descriptor.displayName,
                vaultID: session.handle.vaultID
            )
        )
    }

    private func resolvedRememberedVaultDescriptor(
        _ descriptor: LocalVaultDescriptor,
        fallbackDirectory: URL?
    ) -> LocalVaultDescriptor {
        if FileManager.default.fileExists(atPath: descriptor.fileURL.path) {
            return descriptor
        }

        guard let fallbackDirectory else {
            return descriptor
        }

        let relocatedURL = fallbackDirectory.appendingPathComponent(
            descriptor.fileURL.lastPathComponent,
            isDirectory: false
        )
        guard FileManager.default.fileExists(atPath: relocatedURL.path) else {
            return descriptor
        }

        let relocatedDescriptor = LocalVaultDescriptor(
            fileURL: relocatedURL,
            displayName: descriptor.displayName
        )
        rememberedVaultDescriptor = relocatedDescriptor
        if let rememberedVaultID {
            try? rememberedVaultStore.save(
                RememberedVaultRecord(
                    fileURL: relocatedDescriptor.fileURL,
                    displayName: relocatedDescriptor.displayName,
                    vaultID: rememberedVaultID
                )
            )
        }
        return relocatedDescriptor
    }

    private func readableVaultKeychainErrorMessage(for error: Error) -> String {
        if let appError = error as? AppVaultKeychainError {
            return appError.localizedDescription
        }

        if let securityError = error as? MonicaSecurityError {
            return securityError.localizedDescription
        }

        return error.localizedDescription
    }

    private func readableOneDriveAuthenticationErrorMessage(_ error: Error) -> String {
        if let appError = error as? AppOneDriveAuthenticationError {
            return appError.localizedDescription
        }
        if let providerError = error as? CloudFileProviderError,
           case .authenticationRequired = providerError {
            return String(localized: "OneDrive 需要先登录。")
        }
        let nsError = error as NSError
        return AppOneDriveAuthenticationError.authenticationFailed(
            domain: nsError.domain,
            code: nsError.code,
            message: DefaultAppOneDriveMSALAuthenticationService.diagnosticMessage(for: nsError)
        ).localizedDescription
    }

    private func clearUnlockedVaultSession() {
        autoFillDomainRules.detach()
        clearNoteImageCache()
        vaultPassword = ""
        clearMasterPasswordChangeInput()
        vaultState = .locked
        activeVaultName = nil
        activeVaultSession = nil
        activeEntryRepository = nil
        activeProject = nil
        vaultProjects = []
        lastUserActivityAt = nil
        resetVaultQuickFilters()
        loginEntries = []
        deletedLoginEntries = []
        loginPassword = ""
        clearEditingLoginEntry()
        noteEntries = []
        deletedNoteEntries = []
        noteBody = ""
        clearEditingNoteEntry()
        totpEntries = []
        deletedTotpEntries = []
        totpSecret = ""
        totpImportURI = ""
        clearEditingTotpEntry()
        cardEntries = []
        deletedCardEntries = []
        cardNumber = ""
        cardCVV = ""
        clearEditingCardEntry()
        identityEntries = []
        deletedIdentityEntries = []
        identityDocumentNumber = ""
        clearEditingIdentityEntry()
        passkeyEntries = []
        deletedPasskeyEntries = []
        passkeyPrivateKeyReference = ""
        clearEditingPasskeyEntry()
        clearExtendedParityEntries()
        csvImportPreview = nil
        androidBackupImportPreview = nil
        bitwardenSyncState = .idle
        bitwardenSyncPreview = nil
        bitwardenPendingMutationBatches = []
        clearKeePassImportState()
        entryOperationState = .idle
        clearOperationTimelineEvents()
        clearVaultSearchIndex()
        publishWidgetSnapshots(reloadImmediately: true)
    }

    private func clearVaultAccessAfterFailure() {
        clearNoteImageCache()
        isPrivacyShieldVisible = false
        vaultPassword = ""
        clearMasterPasswordChangeInput()
        guard activeVaultSession == nil else {
            return
        }

        vaultState = .locked
        activeVaultName = nil
        activeEntryRepository = nil
        activeProject = nil
        vaultProjects = []
        lastUserActivityAt = nil
        resetVaultQuickFilters()
        loginEntries = []
        deletedLoginEntries = []
        loginPassword = ""
        clearEditingLoginEntry()
        noteEntries = []
        deletedNoteEntries = []
        noteBody = ""
        clearEditingNoteEntry()
        totpEntries = []
        deletedTotpEntries = []
        totpSecret = ""
        totpImportURI = ""
        clearEditingTotpEntry()
        cardEntries = []
        deletedCardEntries = []
        cardNumber = ""
        cardCVV = ""
        clearEditingCardEntry()
        identityEntries = []
        deletedIdentityEntries = []
        identityDocumentNumber = ""
        clearEditingIdentityEntry()
        passkeyEntries = []
        deletedPasskeyEntries = []
        passkeyPrivateKeyReference = ""
        clearEditingPasskeyEntry()
        clearExtendedParityEntries()
        entryOperationState = .idle
        autoFillIndexState = .idle
        webDAVBackupState = .idle
        webDAVRestorePreview = nil
        webDAVRestoreVaultPassword = ""
        downloadedWebDAVRestoreBackup = nil
        bitwardenSyncState = .idle
        bitwardenSyncPreview = nil
        bitwardenPendingMutationBatches = []
        clearPendingAndroidEncryptedBackup()
        clearKeePassImportState()
        clearVaultSearchIndex()
        publishWidgetSnapshots(reloadImmediately: true)
    }

    private func clearPendingAndroidEncryptedBackup() {
        pendingAndroidEncryptedBackupData = nil
        pendingAndroidEncryptedBackupFileName = nil
        androidBackupDecryptPassword = ""
    }

    private func clearKeePassImportState(
        preservingLastMetadataImportReferences: Bool = false
    ) {
        keePassImportPreview = nil
        keePassReadOnlySnapshot = nil
        keePassReadOnlyImportPlan = nil
        keePassPendingDatabaseData = nil
        keePassPendingDatabaseName = nil
        keePassSourceFileURL = nil
        keePassCloudFileSource = nil
        keePassUnlockPassword = ""
        keePassKeyFileData = nil
        keePassKeyFileName = ""
        keePassLastSuccessfulUnlockCredentials = nil
        if !preservingLastMetadataImportReferences {
            keePassLastMetadataImportReferences = []
        }
    }

    private func clearExtendedParityEntries() {
        sshKeyEntries = []
        deletedSshKeyEntries = []
        sshKeySearchQuery = ""
        showFavoriteSshKeyEntriesOnly = false
        sshKeyPrivateKeyReference = ""
        clearEditingSshKeyEntry()
        apiTokenEntries = []
        deletedApiTokenEntries = []
        apiTokenSearchQuery = ""
        showFavoriteApiTokenEntriesOnly = false
        apiTokenToken = ""
        clearEditingApiTokenEntry()
        wifiEntries = []
        deletedWifiEntries = []
        wifiSearchQuery = ""
        showFavoriteWifiEntriesOnly = false
        wifiPassword = ""
        clearEditingWifiEntry()
        ssoEntries = []
        deletedSSOEntries = []
        ssoSearchQuery = ""
        showFavoriteSSOEntriesOnly = false
        ssoSecret = ""
        clearEditingSSOEntry()
        sendEntries = []
        deletedSendEntries = []
        sendSearchQuery = ""
        showFavoriteSendEntriesOnly = false
        sendBody = ""
        clearEditingSendEntry()
        attachmentEntries = []
        deletedAttachmentEntries = []
        attachmentSearchQuery = ""
        dismissAttachmentQuickLookPreview()
    }

    private func requireActiveVaultSession() throws -> LocalVaultSession {
        guard vaultState == .unlocked,
              let activeVaultSession else {
            throw AppWebDAVBackupError.vaultLocked
        }
        return activeVaultSession
    }

    private func readKeePassSnapshotTryingCredentialCandidates(
        database: Data,
        sourceName: String?,
        credentials: KeePassUnlockCredentials
    ) throws -> (snapshot: KeePassReadOnlySnapshot, credentials: KeePassUnlockCredentials) {
        let candidates = credentials.credentialCandidates
        guard !candidates.isEmpty else {
            let snapshot = try keePassDatabaseReader.readSnapshot(
                database: database,
                sourceName: sourceName,
                credentials: credentials
            )
            return (snapshot, credentials)
        }

        var attemptedLabels: [String] = []
        for candidate in candidates {
            attemptedLabels.append(candidate.label)
            let attemptCredentials = KeePassUnlockCredentials(
                password: candidate.password,
                keyFile: candidate.keyMaterial,
                keyFileName: credentials.keyFileName,
                candidateLabel: candidate.label
            )
            do {
                let snapshot = try keePassDatabaseReader.readSnapshot(
                    database: database,
                    sourceName: sourceName,
                    credentials: attemptCredentials
                )
                return (snapshot, attemptCredentials)
            } catch let error as KeePassOperationError where error.code == .invalidCredential {
                continue
            }
        }

        throw KeePassOperationError(
            code: .invalidCredential,
            message: KeePassCredentialSupport.invalidCredentialMessage(attemptedLabels: attemptedLabels)
        )
    }

    private func currentKeePassKdbxEnvelope() throws -> KeePassKdbxPayloadEnvelope {
        guard let databaseData = keePassPendingDatabaseData else {
            let message = String(localized: "请先选择 KDBX 数据库文件")
            throw KeePassOperationError(code: .formatUnsupported, message: message)
        }
        return try KeePassKdbxPayloadEnvelope.parse(databaseData)
    }

    private func keePassKdbxWritebackParameters() throws -> (
        envelope: KeePassKdbxPayloadEnvelope,
        cipher: KeePassKdbxCipherAlgorithm,
        compression: KeePassKdbxCompressionAlgorithm,
        cryptoInputs: KeePassKdbxPayloadCryptoInputs,
        kdfParameters: KeePassKdbxKdfParameters,
        credentials: KeePassUnlockCredentials
    ) {
        let envelope = try currentKeePassKdbxEnvelope()
        guard let cipher = envelope.headerSummary.cryptoSummary?.cipher else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: String(localized: "KDBX cipher 参数缺失；请确认文件未损坏。")
            )
        }
        guard let compression = envelope.headerSummary.cryptoSummary?.compression else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: String(localized: "KDBX compression 参数缺失；请确认文件未损坏。")
            )
        }
        guard let kdfParameters = envelope.headerSummary.kdfParameters else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: String(localized: "KDBX KDF 参数缺失；请确认文件未损坏。")
            )
        }
        let credentials = keePassLastSuccessfulUnlockCredentials ?? KeePassUnlockCredentials(
            password: keePassUnlockPassword,
            keyFile: keePassKeyFileData,
            keyFileName: keePassKeyFileName
        )
        return (
            envelope,
            cipher,
            compression,
            KeePassFormatInspector.parseKdbxPayloadCryptoInputs(from: envelope),
            kdfParameters,
            credentials
        )
    }

    private func makeKeePassKdbx3WritebackRequest(
        snapshot: KeePassReadOnlySnapshot
    ) throws -> KeePassKdbx3WritebackRequest {
        let parameters = try keePassKdbxWritebackParameters()
        guard parameters.envelope.headerSummary.formatVersion == .kdbx3 else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: String(localized: "当前仅支持 KDBX3 数据库写回。")
            )
        }
        return KeePassKdbx3WritebackRequest(
            snapshot: snapshot,
            credentials: parameters.credentials,
            cipher: parameters.cipher,
            compression: parameters.compression,
            cryptoInputs: parameters.cryptoInputs,
            kdfParameters: parameters.kdfParameters,
            existingHeaderBytes: parameters.envelope.headerBytes
        )
    }

    private func makeKeePassKdbx4WritebackRequest(
        snapshot: KeePassReadOnlySnapshot
    ) throws -> KeePassKdbx4WritebackRequest {
        let parameters = try keePassKdbxWritebackParameters()
        let envelope = parameters.envelope
        guard envelope.headerSummary.formatVersion == .kdbx4 else {
            throw KeePassOperationError(
                code: .formatUnsupported,
                message: String(localized: "当前仅支持 KDBX4 数据库写回。")
            )
        }
        return KeePassKdbx4WritebackRequest(
            snapshot: snapshot,
            credentials: parameters.credentials,
            cipher: parameters.cipher,
            compression: parameters.compression,
            cryptoInputs: parameters.cryptoInputs,
            kdfParameters: parameters.kdfParameters,
            existingHeaderBytes: envelope.headerBytes
        )
    }

    private func activateVaultCategory(
        _ project: LocalVaultProject,
        entryRepository: LocalVaultEntryRepository
    ) throws {
        activeProject = project
        try refreshAllEntryLists(projectID: project.id, entryRepository: entryRepository)
        resetVaultQuickFilters()
        selectedVaultQuickFilterID = "category-\(project.id)"
    }

    func ensureActiveProject(
        projectTitle: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> LocalVaultProject {
        if let activeProject {
            return activeProject
        }
        let project = try entryRepository.createProject(title: projectTitle)
        activeProject = project
        if !vaultProjects.contains(where: { $0.id == project.id }) {
            vaultProjects.append(project)
        }
        return project
    }

    private func ensureKeePassImportProject(
        baseTitle: String,
        groupPath: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> LocalVaultProject {
        let title = keePassImportProjectTitle(baseTitle: baseTitle, groupPath: groupPath)
        if let project = vaultProjects.first(where: { $0.title == title }) {
            return project
        }
        let project = try entryRepository.createProject(title: title)
        vaultProjects.append(project)
        return project
    }

    private func keePassImportProjectTitle(baseTitle: String, groupPath: String) -> String {
        let trimmedBase = baseTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmedBase.isEmpty ? "KeePass" : trimmedBase
        let components = groupPath
            .split(separator: "/")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !components.isEmpty else {
            return base
        }
        return ([base] + components).joined(separator: " / ")
    }

    private func keePassTotpDraft(
        for candidate: KeePassReadOnlyImportCandidate
    ) -> LocalTotpEntryDraft {
        let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseTitle = title.isEmpty ? "KeePass TOTP" : title
        let decodedTotp = candidate.decodedTotp
        return LocalTotpEntryDraft(
            title: keePassTotpPlaceholderTitle(from: baseTitle),
            secret: decodedTotp?.secret ?? "",
            issuer: decodedTotp?.issuer?.nonBlankValue ?? baseTitle,
            accountName: decodedTotp?.accountName?.nonBlankValue ?? candidate.username,
            period: decodedTotp?.period ?? 30,
            digits: decodedTotp?.digits ?? 6,
            algorithm: decodedTotp?.algorithm?.nonBlankValue ?? "SHA1",
            otpType: "TOTP",
            counter: 0
        )
    }

    private func keePassLoginNotes(for candidate: KeePassReadOnlyImportCandidate) -> String {
        var sections: [String] = []
        let notes = candidate.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            sections.append(notes)
        }
        let fieldLines = candidate.customFields
            .filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { field in
                let title = field.title.trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(title): \(field.value)"
            }
        if !fieldLines.isEmpty {
            sections.append(([String(localized: "KeePass 字段：")] + fieldLines).joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    private func keePassTotpPlaceholderTitle(from baseTitle: String) -> String {
        let lowercased = baseTitle.lowercased()
        if lowercased.contains("totp") ||
            lowercased.contains("2fa") ||
            lowercased.contains("authenticator") {
            return baseTitle
        }
        return "\(baseTitle) TOTP"
    }

    private func keePassAttachmentFileName(_ attachment: KeePassReadOnlyAttachment) -> String {
        let trimmed = attachment.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "KeePass Attachment"
        }
        return sanitizedAttachmentPreviewFileName(trimmed)
    }

    private func keePassDecodedAttachmentLocalPath(
        _ attachment: KeePassReadOnlyAttachment,
        fileName: String
    ) -> String {
        let rawIdentifier = attachment.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = rawIdentifier.isEmpty ? UUID().uuidString : rawIdentifier
        return sanitizedAttachmentPreviewFileName(
            "keepass-kdbx-attachment-\(identifier)-\(fileName)"
        )
    }

    private func bitwardenDownloadedAttachmentLocalPath(
        _ attachment: LocalAttachmentMetadata,
        fileName: String
    ) -> String {
        let rawIdentifier = attachment.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = rawIdentifier.isEmpty ? UUID().uuidString : rawIdentifier
        return sanitizedAttachmentPreviewFileName(
            "bitwarden-attachment-\(identifier)-\(fileName)"
        )
    }

    private func createCSVImportedItem(
        _ item: VaultCSVItemDraft,
        projectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws -> String? {
        switch item {
        case .login(let draft):
            return try entryRepository.createLoginEntry(projectID: projectID, draft: draft).id
        case .note(let draft):
            return try entryRepository.createNoteEntry(projectID: projectID, draft: draft).id
        case .totp(let draft):
            return try entryRepository.createTotpEntry(projectID: projectID, draft: draft).id
        case .card(let draft):
            return try entryRepository.createCardEntry(projectID: projectID, draft: draft).id
        case .identity(let draft):
            return try entryRepository.createIdentityEntry(projectID: projectID, draft: draft).id
        case .passkey(let draft):
            return try entryRepository.createPasskeyEntry(projectID: projectID, draft: draft).id
        case .sshKey(let draft):
            return try entryRepository.createSshKeyEntry(projectID: projectID, draft: draft).id
        case .apiToken(let draft):
            return try entryRepository.createApiTokenEntry(projectID: projectID, draft: draft).id
        case .wifi(let draft):
            return try entryRepository.createWifiEntry(projectID: projectID, draft: draft).id
        case .sso(let draft):
            return try entryRepository.createSSOEntry(projectID: projectID, draft: draft).id
        case .send(let draft):
            return try entryRepository.createSendEntry(projectID: projectID, draft: draft).id
        }
    }

    private func deleteCSVImportedItem(
        _ item: VaultCSVItemDraft,
        entryID: String,
        projectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws {
        switch item {
        case .login:
            try entryRepository.deleteLoginEntry(projectID: projectID, entryID: entryID)
        case .note:
            try entryRepository.deleteNoteEntry(projectID: projectID, entryID: entryID)
        case .totp:
            try entryRepository.deleteTotpEntry(projectID: projectID, entryID: entryID)
        case .card:
            try entryRepository.deleteCardEntry(projectID: projectID, entryID: entryID)
        case .identity:
            try entryRepository.deleteIdentityEntry(projectID: projectID, entryID: entryID)
        case .passkey:
            try entryRepository.deletePasskeyEntry(projectID: projectID, entryID: entryID)
        case .sshKey:
            try entryRepository.deleteSshKeyEntry(projectID: projectID, entryID: entryID)
        case .apiToken:
            try entryRepository.deleteApiTokenEntry(projectID: projectID, entryID: entryID)
        case .wifi:
            try entryRepository.deleteWifiEntry(projectID: projectID, entryID: entryID)
        case .sso:
            try entryRepository.deleteSSOEntry(projectID: projectID, entryID: entryID)
        case .send:
            try entryRepository.deleteSendEntry(projectID: projectID, entryID: entryID)
        }
    }

    func refreshAllEntryLists(
        projectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws {
        loginEntries = try entryRepository.listLoginEntries(projectID: projectID)
        deletedLoginEntries = try entryRepository.listDeletedLoginEntries(projectID: projectID)
        noteEntries = try entryRepository.listNoteEntries(projectID: projectID)
        deletedNoteEntries = try entryRepository.listDeletedNoteEntries(projectID: projectID)
        totpEntries = try entryRepository.listTotpEntries(projectID: projectID)
        deletedTotpEntries = try entryRepository.listDeletedTotpEntries(projectID: projectID)
        cardEntries = try entryRepository.listCardEntries(projectID: projectID)
        deletedCardEntries = try entryRepository.listDeletedCardEntries(projectID: projectID)
        identityEntries = try entryRepository.listIdentityEntries(projectID: projectID)
        deletedIdentityEntries = try entryRepository.listDeletedIdentityEntries(projectID: projectID)
        passkeyEntries = try entryRepository.listPasskeyEntries(projectID: projectID)
        deletedPasskeyEntries = try entryRepository.listDeletedPasskeyEntries(projectID: projectID)
        sshKeyEntries = try entryRepository.listSshKeyEntries(projectID: projectID)
        deletedSshKeyEntries = try entryRepository.listDeletedSshKeyEntries(projectID: projectID)
        apiTokenEntries = try entryRepository.listApiTokenEntries(projectID: projectID)
        deletedApiTokenEntries = try entryRepository.listDeletedApiTokenEntries(projectID: projectID)
        wifiEntries = try entryRepository.listWifiEntries(projectID: projectID)
        deletedWifiEntries = try entryRepository.listDeletedWifiEntries(projectID: projectID)
        ssoEntries = try entryRepository.listSSOEntries(projectID: projectID)
        deletedSSOEntries = try entryRepository.listDeletedSSOEntries(projectID: projectID)
        sendEntries = try entryRepository.listSendEntries(projectID: projectID)
        deletedSendEntries = try entryRepository.listDeletedSendEntries(projectID: projectID)
        attachmentEntries = try entryRepository.listAttachmentMetadata(projectID: projectID)
        deletedAttachmentEntries = try entryRepository.listDeletedAttachmentMetadata(projectID: projectID)
        publishWidgetSnapshots()
        refreshVaultSearchIndex(entryRepository: entryRepository)
    }

    // MARK: - 全局搜索（解锁会话内存索引）

    /// 从仓库读取全部保险箱的非敏感元数据，重建跨类型搜索索引。
    ///
    /// 只投影标题 / 账号 / 网址 / 备注等元数据；密码、TOTP 密钥、私钥、
    /// 卡号等 secret 字段在投影时即被丢弃。索引只存在于解锁会话内存中，
    /// 锁库时由 `clearVaultSearchIndex()` 清空，不写入任何持久化存储。
    private func refreshVaultSearchIndex(entryRepository: LocalVaultEntryRepository) {
        guard vaultState == .unlocked else {
            clearVaultSearchIndex()
            return
        }

        var snapshot = VaultSearchEntrySnapshot()
        for project in vaultProjects {
            let projectID = project.id
            snapshot.loginEntries += (try? entryRepository.listLoginEntries(projectID: projectID)) ?? []
            snapshot.deletedLoginEntries += (try? entryRepository.listDeletedLoginEntries(projectID: projectID)) ?? []
            snapshot.noteEntries += (try? entryRepository.listNoteEntries(projectID: projectID)) ?? []
            snapshot.deletedNoteEntries += (try? entryRepository.listDeletedNoteEntries(projectID: projectID)) ?? []
            snapshot.totpEntries += (try? entryRepository.listTotpEntries(projectID: projectID)) ?? []
            snapshot.deletedTotpEntries += (try? entryRepository.listDeletedTotpEntries(projectID: projectID)) ?? []
            snapshot.cardEntries += (try? entryRepository.listCardEntries(projectID: projectID)) ?? []
            snapshot.deletedCardEntries += (try? entryRepository.listDeletedCardEntries(projectID: projectID)) ?? []
            snapshot.identityEntries += (try? entryRepository.listIdentityEntries(projectID: projectID)) ?? []
            snapshot.deletedIdentityEntries += (try? entryRepository.listDeletedIdentityEntries(projectID: projectID)) ?? []
            snapshot.passkeyEntries += (try? entryRepository.listPasskeyEntries(projectID: projectID)) ?? []
            snapshot.deletedPasskeyEntries += (try? entryRepository.listDeletedPasskeyEntries(projectID: projectID)) ?? []
            snapshot.sshKeyEntries += (try? entryRepository.listSshKeyEntries(projectID: projectID)) ?? []
            snapshot.deletedSshKeyEntries += (try? entryRepository.listDeletedSshKeyEntries(projectID: projectID)) ?? []
            snapshot.apiTokenEntries += (try? entryRepository.listApiTokenEntries(projectID: projectID)) ?? []
            snapshot.deletedApiTokenEntries += (try? entryRepository.listDeletedApiTokenEntries(projectID: projectID)) ?? []
            snapshot.wifiEntries += (try? entryRepository.listWifiEntries(projectID: projectID)) ?? []
            snapshot.deletedWifiEntries += (try? entryRepository.listDeletedWifiEntries(projectID: projectID)) ?? []
            snapshot.sendEntries += (try? entryRepository.listSendEntries(projectID: projectID)) ?? []
            snapshot.deletedSendEntries += (try? entryRepository.listDeletedSendEntries(projectID: projectID)) ?? []
            snapshot.attachmentEntries += (try? entryRepository.listAttachmentMetadata(projectID: projectID)) ?? []
            snapshot.deletedAttachmentEntries += (try? entryRepository.listDeletedAttachmentMetadata(projectID: projectID)) ?? []
        }

        vaultSearch.replaceDocuments(
            VaultSearchDocumentBuilder.documents(from: snapshot, usage: vaultSearchUsage())
        )
        vaultSearchRevision += 1
    }

    /// 搜索界面出现时确保索引存在：解锁后尚未激活分类也能跨全部保险箱搜索。
    func ensureVaultSearchIndex() {
        guard let entryRepository = activeEntryRepository else {
            clearVaultSearchIndex()
            return
        }
        refreshVaultSearchIndex(entryRepository: entryRepository)
    }

    /// 最近查看 / 查看次数复用已有的操作时间线（`.viewed` 事件），不新增持久化结构。
    private func vaultSearchUsage() -> [VaultSearchItemKey: VaultSearchUsage] {
        var usage: [VaultSearchItemKey: VaultSearchUsage] = [:]
        for event in operationTimelineEvents where event.action == .viewed {
            let key = VaultSearchItemKey(kind: event.itemKind, id: event.itemID)
            let previous = usage[key]
            usage[key] = VaultSearchUsage(
                viewCount: (previous?.viewCount ?? 0) + 1,
                lastViewedAt: max(previous?.lastViewedAt ?? .distantPast, event.occurredAt)
            )
        }
        return usage
    }

    /// 记录一次详情查看；锁库后索引为空，这里不会重建任何数据。
    private func recordVaultSearchView(kind: UnifiedVaultItemKind, entryID: String) {
        vaultSearch.recordView(VaultSearchItemKey(kind: kind, id: entryID))
        vaultSearchRevision += 1
    }

    /// 锁库 / 访问失效时清空索引，确保内存中不残留明文元数据。
    private func clearVaultSearchIndex() {
        vaultSearch.lock()
        vaultSearchRevision += 1
        isGlobalSearchPresented = false
    }

    private func clearAllEntryLists() {
        loginEntries = []
        deletedLoginEntries = []
        noteEntries = []
        deletedNoteEntries = []
        totpEntries = []
        deletedTotpEntries = []
        cardEntries = []
        deletedCardEntries = []
        identityEntries = []
        deletedIdentityEntries = []
        passkeyEntries = []
        deletedPasskeyEntries = []
        clearExtendedParityEntries()
    }

    private func csvExportDrafts() -> [VaultCSVItemDraft] {
        var drafts: [VaultCSVItemDraft] = []
        drafts += loginEntries.map {
            .login(LocalLoginEntryDraft(
                title: $0.title,
                username: $0.username,
                password: $0.password,
                url: $0.url
            ))
        }
        drafts += noteEntries.map {
            .note(LocalNoteEntryDraft(title: $0.title, body: $0.body))
        }
        drafts += totpEntries.map {
            .totp(LocalTotpEntryDraft(
                title: $0.title,
                secret: $0.secret,
                issuer: $0.issuer,
                accountName: $0.accountName,
                period: $0.period,
                digits: $0.digits,
                algorithm: $0.algorithm,
                otpType: $0.otpType,
                counter: $0.counter
            ))
        }
        drafts += cardEntries.map {
            .card(LocalCardEntryDraft(
                title: $0.title,
                cardholderName: $0.cardholderName,
                number: $0.number,
                expiryMonth: $0.expiryMonth,
                expiryYear: $0.expiryYear,
                cvv: $0.cvv,
                issuer: $0.issuer,
                network: $0.network,
                notes: $0.notes
            ))
        }
        drafts += identityEntries.map {
            .identity(LocalIdentityEntryDraft(
                title: $0.title,
                documentType: $0.documentType,
                fullName: $0.fullName,
                documentNumber: $0.documentNumber,
                issuer: $0.issuer,
                country: $0.country,
                issueDate: $0.issueDate,
                expiryDate: $0.expiryDate,
                notes: $0.notes
            ))
        }
        drafts += passkeyEntries.map {
            .passkey(LocalPasskeyEntryDraft(
                title: $0.title,
                relyingPartyID: $0.relyingPartyID,
                username: $0.username,
                userHandle: $0.userHandle,
                credentialID: $0.credentialID,
                publicKeyCOSE: $0.publicKeyCOSE,
                privateKeyReference: $0.privateKeyReference,
                notes: $0.notes
            ))
        }
        drafts += sshKeyEntries.map {
            .sshKey(LocalSshKeyEntryDraft(
                title: $0.title,
                username: $0.username,
                host: $0.host,
                publicKey: $0.publicKey,
                privateKeyReference: $0.privateKeyReference,
                passphraseHint: $0.passphraseHint,
                notes: $0.notes
            ))
        }
        drafts += apiTokenEntries.map {
            .apiToken(LocalApiTokenEntryDraft(
                title: $0.title,
                issuer: $0.issuer,
                accountName: $0.accountName,
                token: $0.token,
                scopes: $0.scopes,
                expiresAt: $0.expiresAt,
                notes: $0.notes
            ))
        }
        drafts += wifiEntries.map {
            .wifi(LocalWifiEntryDraft(
                title: $0.title,
                ssid: $0.ssid,
                securityType: $0.securityType,
                password: $0.password,
                hidden: $0.hidden,
                notes: $0.notes
            ))
        }
        drafts += ssoEntries.map {
            .sso(LocalSSOEntryDraft(
                title: $0.title,
                provider: $0.provider,
                providerName: $0.providerName,
                issuer: $0.issuer,
                accountName: $0.accountName,
                loginURL: $0.loginURL,
                linkedLoginEntryID: $0.linkedLoginEntryID,
                notes: $0.notes,
                secret: $0.secret
            ))
        }
        drafts += sendEntries.map {
            .send(LocalSendEntryDraft(
                title: $0.title,
                body: $0.body,
                expiresAt: $0.expiresAt,
                maxViews: $0.maxViews,
                notes: $0.notes
            ))
        }
        return drafts
    }

    func makeWebDAVEndpoint() throws -> WebDAVEndpoint {
        let baseURLString = webDAVBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: baseURLString),
              baseURL.scheme != nil,
              baseURL.host() != nil else {
            throw AppWebDAVBackupError.invalidEndpoint
        }

        let username = webDAVUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            throw AppWebDAVBackupError.emptyUsername
        }
        guard !webDAVPassword.isEmpty else {
            throw AppWebDAVBackupError.emptyPassword
        }

        return WebDAVEndpoint(
            baseURL: baseURL,
            username: username,
            password: webDAVPassword
        )
    }

    private func normalizedWebDAVRemoteFileName(fallback: String?) throws -> String {
        let normalized = webDAVRemoteFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty {
            return normalized
        }
        if let fallback, !fallback.isEmpty {
            return fallback
        }
        throw AppWebDAVBackupError.emptyRemoteFileName
    }

    private func replaceVaultFile(at destinationURL: URL, with data: Data) throws {
        let directoryURL = destinationURL.deletingLastPathComponent()
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).restore-\(UUID().uuidString)",
            isDirectory: false
        )
        try data.write(to: temporaryURL, options: [.atomic])
        _ = try FileManager.default.replaceItemAt(
            destinationURL,
            withItemAt: temporaryURL,
            backupItemName: nil,
            options: [.usingNewMetadataOnly]
        )
    }

    func appendOperationTimelineEvent(
        action: AppOperationTimelineAction,
        itemKind: UnifiedVaultItemKind,
        itemID: String,
        itemTitle: String,
        result: String = "success",
        errorCategory: String? = nil
    ) {
        nextOperationTimelineEventSequence += 1
        let trimmedTitle = Self.redactedTimelineTitle(itemTitle)
        operationTimelineEvents.insert(
            AppOperationTimelineEvent(
                id: "operation-\(nextOperationTimelineEventSequence)-\(itemID)",
                action: action,
                itemKind: itemKind,
                itemID: itemID,
                itemTitle: trimmedTitle,
                occurredAt: Date(),
                result: result,
                errorCategory: errorCategory
            ),
            at: 0
        )
        if operationTimelineEvents.count > 500 {
            operationTimelineEvents.removeLast(operationTimelineEvents.count - 500)
        }
        operationTimelineStore.saveEvents(operationTimelineEvents)
        publishWidgetSnapshots()
    }

    private static func redactedTimelineTitle(_ value: String) -> String {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"://[^\s]+"#, with: "://<redacted>", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)(password|token|secret|key|code)=\S+"#, with: "$1=<redacted>", options: .regularExpression)
        guard !trimmed.isEmpty else {
            return String(localized: "未命名条目")
        }
        return String(trimmed.prefix(80))
    }

    private func sanitizedAttachmentPreviewFileName(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? value
        let sanitized = normalized.unicodeScalars
            .map { scalar -> String in
                switch scalar.value {
                case 48...57, 65...90, 97...122:
                    String(scalar)
                case 45, 46, 95:
                    String(scalar)
                default:
                    "_"
                }
            }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return sanitized.isEmpty ? "attachment-\(UUID().uuidString).bin" : sanitized
    }

    private func sanitizedKeePassFileName(_ value: String) -> String? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? value
        let sanitized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? nil : sanitized
    }

    private func clearOperationTimelineEvents() {
        operationTimelineEvents = []
        nextOperationTimelineEventSequence = 0
        operationTimelineStore.saveEvents([])
    }

    private func validateDownloadedWebDAVRestore(
        _ downloaded: WebDAVDownloadedBackup,
        near destinationURL: URL,
        password: String,
        deviceID: String
    ) throws {
        let directoryURL = destinationURL.deletingLastPathComponent()
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(downloaded.fileName).validate-\(UUID().uuidString).mdbx",
            isDirectory: false
        )

        do {
            try downloaded.data.write(to: temporaryURL, options: [.atomic])
            let validationSession = try vaultRepository.openVault(
                at: temporaryURL,
                password: password,
                deviceID: deviceID
            )
            vaultRepository.closeVault(for: validationSession)
            try? FileManager.default.removeItem(at: temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw AppWebDAVBackupError.restoreValidationFailed
        }
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        // 遮罩范围与会话锁定规则集中在 MonicaCore.ScreenPrivacyPolicy：
        // 非 active 阶段（含 App Switcher 手势先进入的 inactive）一律遮罩，
        // 只有后台阶段才真正锁定 Vault。
        let decision = ScreenPrivacyPolicy.decision(
            for: ScreenPrivacyPhase(phase),
            isVaultUnlocked: vaultState == .unlocked
        )
        switch phase {
        case .active:
            isPrivacyShieldVisible = decision.showsShield
            refreshNotificationPermissionStatus()
            refreshSystemAutoFillProviderStatus()
            lockIfIdle()
            // 挂起期间计时器不会运行，回到前台补做到期检查并重启前台轮询。
            resumeSensitivePasteboardExpiryMonitoringIfNeeded()
        case .inactive:
            isPrivacyShieldVisible = decision.showsShield
        case .background:
            widgetReloadScheduler?.flushPendingReload()
            sensitivePasteboardExpiryTask?.cancel()
            sensitivePasteboardExpiryTask = nil
            if decision.locksVault {
                lockLocalVault()
            }
            isPrivacyShieldVisible = decision.showsShield
        @unknown default:
            isPrivacyShieldVisible = decision.showsShield
        }
    }

    func recordUserActivity(at date: Date = Date()) {
        guard vaultState == .unlocked else {
            return
        }

        lastUserActivityAt = date
    }

    func updateAutoLockPolicy(_ policy: AppAutoLockPolicy, now: Date = Date()) {
        autoLockPolicy = policy
        recordUserActivity(at: now)
    }

    func lockIfIdle(now: Date = Date()) {
        guard vaultState == .unlocked,
              let lastUserActivityAt,
              now.timeIntervalSince(lastUserActivityAt) >= autoLockPolicy.idleTimeout
        else {
            return
        }

        lockLocalVault()
    }

    func clearEditingLoginEntry() {
        editingLoginEntryID = nil
        editingLoginTitle = ""
        editingLoginUsername = ""
        editingLoginPassword = ""
        editingLoginURL = ""
        editingLoginFavorite = false
        editingLoginAdditionalURLs = []
        editingLoginAppBundleID = ""
        editingLoginAppName = ""
        editingLoginNotes = ""
        editingLoginPasswordHistory = []
    }

    func clearEditingNoteEntry() {
        editingNoteEntryID = nil
        editingNoteTitle = ""
        editingNoteBody = ""
        editingNoteFavorite = false
    }

    func clearEditingTotpEntry() {
        editingTotpEntryID = nil
        editingTotpTitle = ""
        editingTotpSecret = ""
        editingTotpIssuer = ""
        editingTotpAccountName = ""
        editingTotpPeriod = 30
        editingTotpDigits = 6
        editingTotpAlgorithm = "SHA1"
        editingTotpFavorite = false
    }

    func clearEditingCardEntry() {
        editingCardEntryID = nil
        editingCardTitle = ""
        editingCardholderName = ""
        editingCardNumber = ""
        editingCardExpiryMonth = ""
        editingCardExpiryYear = ""
        editingCardCVV = ""
        editingCardIssuer = ""
        editingCardNetwork = ""
        editingCardNotes = ""
        editingCardFavorite = false
    }

    func clearEditingIdentityEntry() {
        editingIdentityEntryID = nil
        editingIdentityTitle = ""
        editingIdentityDocumentType = ""
        editingIdentityFullName = ""
        editingIdentityDocumentNumber = ""
        editingIdentityIssuer = ""
        editingIdentityCountry = ""
        editingIdentityIssueDate = ""
        editingIdentityExpiryDate = ""
        editingIdentityNotes = ""
        editingIdentityFavorite = false
    }

    func clearEditingPasskeyEntry() {
        editingPasskeyEntryID = nil
        editingPasskeyTitle = ""
        editingPasskeyRelyingPartyID = ""
        editingPasskeyUsername = ""
        editingPasskeyUserHandle = ""
        editingPasskeyCredentialID = ""
        editingPasskeyPublicKeyCOSE = ""
        editingPasskeyPrivateKeyReference = ""
        editingPasskeyNotes = ""
        editingPasskeyFavorite = false
    }

    func clearEditingSshKeyEntry() {
        editingSshKeyEntryID = nil
        editingSshKeyTitle = ""
        editingSshKeyUsername = ""
        editingSshKeyHost = ""
        editingSshKeyPublicKey = ""
        editingSshKeyPrivateKeyReference = ""
        editingSshKeyPassphraseHint = ""
        editingSshKeyNotes = ""
        editingSshKeyFavorite = false
    }

    func clearEditingApiTokenEntry() {
        editingApiTokenEntryID = nil
        editingApiTokenTitle = ""
        editingApiTokenIssuer = ""
        editingApiTokenAccountName = ""
        editingApiTokenToken = ""
        editingApiTokenScopes = ""
        editingApiTokenExpiresAt = ""
        editingApiTokenNotes = ""
        editingApiTokenFavorite = false
    }

    func clearEditingWifiEntry() {
        editingWifiEntryID = nil
        editingWifiTitle = ""
        editingWifiSSID = ""
        editingWifiSecurityType = "WPA2"
        editingWifiPassword = ""
        editingWifiHidden = false
        editingWifiNotes = ""
        editingWifiFavorite = false
    }

    func clearEditingSendEntry() {
        editingSendEntryID = nil
        editingSendTitle = ""
        editingSendBody = ""
        editingSendExpiresAt = ""
        editingSendMaxViews = 1
        editingSendNotes = ""
        editingSendFavorite = false
    }

    private func serviceIdentifiers(for urlString: String) -> [String] {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        var identifiers: [String] = []
        if let url = URL(string: trimmed),
           let host = url.host(),
           !host.isEmpty {
            identifiers.append(host)
        }
        identifiers.append(trimmed)
        return Array(NSOrderedSet(array: identifiers)) as? [String] ?? identifiers
    }

    private func normalizedAutoFillSaveRequest(
        _ request: AppAutoFillCredentialSaveRequest
    ) throws -> AppAutoFillCredentialSaveRequest {
        let serviceIdentifier = request.serviceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = request.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = request.password
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serviceIdentifier.isEmpty else {
            throw LocalVaultRepositoryError.emptyEntryTitle
        }
        guard !username.isEmpty else {
            throw LocalVaultRepositoryError.emptyEntryTitle
        }
        guard !password.isEmpty else {
            throw LocalVaultRepositoryError.emptyPassword
        }
        return AppAutoFillCredentialSaveRequest(
            serviceIdentifier: serviceIdentifier,
            username: username,
            password: password,
            title: title
        )
    }

    private func autoFillSaveTitle(
        for request: AppAutoFillCredentialSaveRequest
    ) -> String {
        if !request.title.isEmpty {
            return request.title
        }
        return serviceIdentifiers(for: request.serviceIdentifier).first ?? String(localized: "自动填充登录")
    }

    private func matchingLoginEntry(
        for request: AppAutoFillCredentialSaveRequest,
        in entries: [LocalLoginEntry]
    ) -> LocalLoginEntry? {
        let username = request.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestIdentifiers = Set(serviceIdentifiers(for: request.serviceIdentifier).map(normalizedAutoFillIdentifier))
        guard !username.isEmpty, !requestIdentifiers.isEmpty else {
            return nil
        }

        return entries.first { entry in
            guard entry.username.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(username) == .orderedSame else {
                return false
            }
            let entryIdentifiers = Set(serviceIdentifiers(for: entry.url).map(normalizedAutoFillIdentifier))
            return !entryIdentifiers.isDisjoint(with: requestIdentifiers)
        }
    }

    private func normalizedAutoFillIdentifier(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: trimmed),
           let host = url.host(),
           !host.isEmpty {
            return host.lowercased()
        }
        return trimmed
    }

    private func autoFillCredentialIdentities(
        for entry: LocalLoginEntry
    ) -> [AppAutoFillCredentialIdentity] {
        let username = entry.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            return []
        }

        return serviceIdentifiers(for: entry.url)
            .filter { !autoFillDomainRules.hidesServiceIdentifier($0) }
            .map { serviceIdentifier in
            AppAutoFillCredentialIdentity(
                recordIdentifier: entry.id,
                serviceIdentifier: serviceIdentifier,
                username: username
            )
        }
    }

    private func autoFillPasskeyCredentialIdentity(
        for entry: LocalPasskeyEntry
    ) -> AppAutoFillPasskeyCredentialIdentity? {
        guard let relyingPartyIdentifier = PasskeyRelyingPartyIDNormalizer.normalize(entry.relyingPartyID) else {
            return nil
        }
        let username = entry.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty,
              let credentialID = Data(base64Encoded: entry.credentialID),
              !credentialID.isEmpty,
              let userHandle = Data(base64Encoded: entry.userHandle),
              !userHandle.isEmpty
        else {
            return nil
        }

        return AppAutoFillPasskeyCredentialIdentity(
            recordIdentifier: entry.id,
            relyingPartyIdentifier: relyingPartyIdentifier,
            username: username,
            credentialID: credentialID,
            userHandle: userHandle
        )
    }

    private func normalizedPasskeyRelyingPartyID(_ value: String) throws -> String {
        guard let relyingPartyID = PasskeyRelyingPartyIDNormalizer.normalize(value) else {
            throw PasskeyCredentialError.invalidRelyingPartyID
        }
        return relyingPartyID
    }

    private func normalizedPasskeyDraft(_ draft: LocalPasskeyEntryDraft) throws -> LocalPasskeyEntryDraft {
        LocalPasskeyEntryDraft(
            title: draft.title,
            relyingPartyID: try normalizedPasskeyRelyingPartyID(draft.relyingPartyID),
            username: draft.username,
            userHandle: draft.userHandle,
            credentialID: draft.credentialID,
            publicKeyCOSE: draft.publicKeyCOSE,
            privateKeyReference: draft.privateKeyReference,
            notes: draft.notes
        )
    }

    func totpAlgorithm(from value: String) -> TotpAlgorithm {
        TotpAlgorithm(rawValue: value.uppercased()) ?? .sha1
    }

    func runMDBXVerification() {
        mdbxVerificationState = .running

        Task {
            do {
                let directory = FileManager.default.urls(
                    for: .documentDirectory,
                    in: .userDomainMask
                ).first ?? FileManager.default.temporaryDirectory
                let result = try MonicaMDBXTechnicalVerifier.runProjectScopedLoginRoundTrip(
                    in: directory
                )
                mdbxVerificationState = .passed(
                    String(localized: "保险库 \(result.vaultID.prefix(8)) / \(result.entryTitle)")
                )
            } catch {
                mdbxVerificationState = .failed(error.localizedDescription)
            }
        }
    }
}
