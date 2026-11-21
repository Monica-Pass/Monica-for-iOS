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
    // issue #144：打开/解锁失败后交给恢复页的上下文；打开成功会清空。
    var vaultRecoveryContext: AppVaultRecoveryContext?
    /// 最近一次成功打开时间的持久化记录（只存文件路径与时间，不存密钥）。
    var vaultRecoveryHistory = AppVaultRecoveryHistory()
    var firstTimePasswordSetupStep: FirstTimePasswordSetupStep = .enterPassword
    var activeVaultName: String?
    var entryOperationState: EntryOperationState = .idle
    // issue #28：回收站保留策略与清理预览（策略本身不含敏感信息，删除时间账本另存加密文件）。
    var trashRetentionPolicy: TrashRetentionPolicy = .standard
    var trashPreviewTotalCount = 0
    var trashPreviewExpiredCount = 0
    var trashMaintenanceMessage: String?
    var loginTitle = ""
    var loginUsername = ""
    /// 新建登录条目的账号（邮箱 / 手机号 / 账号 ID），与用户名分开保存。
    var loginAccount = ""
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
    /// 安全分析状态：只保存条目 ID → 密码修订的「疑似已泄露」手动标记，以及每日聚合趋势。
    var securityInsightState: SecurityInsightState = .empty
    /// 已从存储载入状态的 Vault；切换 Vault 后重新载入，避免串库。
    var securityInsightLoadedVaultID: String?
    @ObservationIgnored var securityInsightSaveTask: Task<Void, Never>?
    /// 安全分析状态的持久化后端：默认内存实现，生产环境注入文件存储。
    let securityInsightStore: any SecurityInsightPersisting
    /// 审计“当前时间”的来源，测试可注入固定时钟。
    let securityInsightNow: () -> Date
    var operationTimelineEvents: [AppOperationTimelineEvent] = []
    var operationTimelineFilterKind: UnifiedVaultItemKind?
    var operationTimelineFilterAction: AppOperationTimelineAction?
    var ignoredDuplicateLoginKeys: Set<DuplicateLoginEntryKey> = []
    /// 加密格式文件：保留原始数据，用户重新输入密码时再解析一次。
    var pendingFormatImportData: Data?
    var pendingFormatImportFileName: String?
    var pendingFormatImportContentType: String?
    var lastDuplicateLoginMergeUndo: AppDuplicateLoginMergeUndo?
    private var nextOperationTimelineEventSequence = 0
    var editingLoginEntryID: String?
    var editingLoginTitle = ""
    var editingLoginUsername = ""
    var editingLoginAccount = ""
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
    /// otpauth 链接导入面板：粘贴/剪贴板/外部 deep link 都落到同一个确认流程。
    var isOtpAuthImportSheetPresented = false
    var otpAuthImportInput = ""
    var otpAuthImportReview: AppOtpAuthImportReview?
    var otpAuthImportFeedback: String?
    /// 锁定时收到的单条 otpauth URI，解锁后再解析并展示确认，不写入任何明文日志。
    @ObservationIgnored var pendingOtpAuthURIAfterUnlock: String?
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
    var cardIBAN = ""
    var cardSwiftCode = ""
    var cardBillingAddress = ""
    var cardArtwork = ""
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
    var editingCardIBAN = ""
    var editingCardSwiftCode = ""
    var editingCardBillingAddress = ""
    var editingCardArtwork = ""
    var editingCardNotes = ""
    var editingCardFavorite = false
    var billingAddressEntries: [LocalBillingAddressEntry] = []
    var deletedBillingAddressEntries: [LocalBillingAddressEntry] = []
    var billingAddressSearchQuery = ""
    var showFavoriteBillingAddressEntriesOnly = false
    var billingAddressForm = BillingAddressFormState()
    var editingBillingAddressEntryID: String?
    var editingBillingAddressForm = BillingAddressFormState()
    var editingBillingAddressFavorite = false
    var paymentAccountEntries: [LocalPaymentAccountEntry] = []
    var deletedPaymentAccountEntries: [LocalPaymentAccountEntry] = []
    var paymentAccountSearchQuery = ""
    var showFavoritePaymentAccountEntriesOnly = false
    var paymentAccountForm = PaymentAccountFormState()
    var editingPaymentAccountEntryID: String?
    var editingPaymentAccountForm = PaymentAccountFormState()
    var editingPaymentAccountFavorite = false
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
    var gpgKeyEntries: [LocalGPGKeyEntry] = []
    var deletedGPGKeyEntries: [LocalGPGKeyEntry] = []
    var gpgKeyTitle = ""
    var gpgKeyNotes = ""
    var gpgKeyImportInput = ""
    /// 是否显式允许把 armored 私钥块随条目一起保存（默认 false，只导入公钥）。
    var gpgKeyImportIncludesPrivateKey = false
    var gpgKeyImportPreview: GPGKeyMetadata?
    var gpgKeyImportError: String?
    var gpgKeyImportDuplicateEntryID: String?
    var gpgKeySearchQuery = ""
    var showFavoriteGPGKeyEntriesOnly = false
    var editingGPGKeyEntryID: String?
    var editingGPGKeyTitle = ""
    var editingGPGKeyNotes = ""
    var editingGPGKeyFavorite = false
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
    var barcodeEntries: [LocalBarcodeEntry] = []
    var deletedBarcodeEntries: [LocalBarcodeEntry] = []
    var barcodeTitle = ""
    var barcodeSymbology: BarcodeSymbology = .qr
    var barcodePayload = ""
    var barcodeLabel = ""
    var barcodeNotes = ""
    var barcodeSearchQuery = ""
    var showFavoriteBarcodeEntriesOnly = false
    var editingBarcodeEntryID: String?
    var editingBarcodeTitle = ""
    var editingBarcodeSymbology: BarcodeSymbology = .qr
    var editingBarcodePayload = ""
    var editingBarcodeLabel = ""
    var editingBarcodeNotes = ""
    var editingBarcodeFavorite = false
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
    var steamEntries: [LocalSteamEntry] = []
    var deletedSteamEntries: [LocalSteamEntry] = []
    var steamTitle = ""
    var steamAccountName = ""
    var steamID = ""
    var steamSharedSecret = ""
    var steamIssuer = "Steam"
    var steamNotes = ""
    var steamSearchQuery = ""
    var showFavoriteSteamEntriesOnly = false
    var steamImportInput = ""
    var editingSteamEntryID: String?
    var editingSteamTitle = ""
    var editingSteamAccountName = ""
    var editingSteamID = ""
    var editingSteamSharedSecret = ""
    var editingSteamIssuer = "Steam"
    var editingSteamNotes = ""
    var editingSteamFavorite = false
    var totpModule: TotpModule = .totp
    var attachmentEntries: [LocalAttachmentMetadata] = []
    var deletedAttachmentEntries: [LocalAttachmentMetadata] = []
    var attachmentSearchQuery = ""
    var attachmentQuickLookPreviewURL: URL?
    var vaultProjects: [LocalVaultProject] = []
    /// #27：文件夹森林（父/子目录 + 面包屑）。主键是 projectID，绝不用显示路径。
    var vaultFolderTree: VaultFolderTree = .empty
    /// #27：总览统计（每类条目数、收藏、回收站、最近使用）。
    var vaultFolderOverview: VaultFolderOverview = .builder(documents: [], tree: .empty)
    /// #27：是否正在展示保险箱总览页。
    var isVaultOverviewPresented = false
    /// #27：保存文件夹索引锚点的本地存储（只存一个 UUID，不含用户内容）。
    var vaultFolderAnchorStore: any VaultFolderAnchorStore = appDefaultVaultFolderAnchorStore()
    var selectedVaultQuickFilterID = "all"

    /// 列表排序偏好（标题/创建时间/修改时间/最近使用 + 升降序），持久化到 UserDefaults。
    var vaultSortPreference = VaultEntrySortPreferenceStore.load()
    /// 当前生效的标签筛选（多选为「任一匹配」）。
    var selectedVaultTagIDs: Set<String> = []
    /// 当前分类下汇总出来的标签目录，数据来自各条目加密 metadata。
    var vaultTagCatalog: [VaultTag] = []
    var selectedVaultBatchItemIDs: Set<String> = []
    var vaultBatchSelectionKind: UnifiedVaultItemKind?
    var vaultDisplayPreferences: VaultDisplayPreferences
    var appearancePreferences: AppAppearancePreferences
    var vaultLayoutPreferences: VaultLayoutPreferences
    /// #155：验证码卡片进度条（统一进度条 / 线性环形 / 平滑动画）偏好。
    var totpCardPreferences: TotpProgressPreferences
    /// #149：条目图标全局体系（总开关 / 分页面开关 / 未匹配策略 / 来源优先级）。
    var itemIconPreferences: ItemIconPreferences    /// #58：剪贴板自动清除时长与敏感预览掩码偏好。
    var sensitiveClipboardTTL: SensitiveClipboardTTL
    var sensitivePreviewPreferences: SensitivePreviewPreferences
    /// 本次解锁会话内的「显示敏感字段」状态；锁库立即清空，不持久化。
    var sensitivePreviewSession = SensitivePreviewSession()
    var sensitivePasteboardHasPendingAutoClear = false
    /// #148：验证码到期自动复制下一个码（默认关闭，只对 TOTP 生效）。
    var totpAutoCopyEnabled: Bool
    var mdbxVerificationState: MDBXVerificationState = .idle
    var isPrivacyShieldVisible = false
    var autoLockPolicy: AppAutoLockPolicy
    var autoFillIndexState: AutoFillIndexState = .idle
    let autoFillDomainRules = AutoFillDomainRuleController()
    var notificationPermissionState: AppPermissionStatusRow.State = .checkable
    var systemAutoFillProviderState: AppPermissionStatusRow.State = .checkable
    var autoFillPolicy: AppAutoFillPolicy
    /// 自动填充守护策略：只作用于 Monica 自己的候选与身份发布行为，不影响系统或其它 App。
    var autoFillGuardPolicy: AutoFillGuardPolicy
    /// 当前解锁会话是否通过了设备所有者认证（Face ID / Touch ID / 设备密码）。
    private(set) var unlockedWithDeviceOwnerAuthentication = false
    /// 最近一次被守护策略拦下的发布原因；发布成功后清空。
    private(set) var autoFillGuardBlockedReason: AutoFillGuardPublishBlockReason?
    /// 锁定后清空过系统身份，等解锁后条目重新载入时补一次发布。
    private var autoFillGuardNeedsIdentityRepublish = false
    /// 自动填充诊断面板：只读系统状态与发布记录，不读取凭据内容。
    let autoFillDiagnostics: AppAutoFillDiagnosticsModel
    var vaultKeychainState: VaultKeychainState = .idle
    /// Monica Plus 支持者权益：离线时来自上次已验证快照，联网后由 StoreKit 校准。
    private(set) var plusEntitlement = PlusEntitlement.inactive(verifiedAt: Date())
    /// 购买 / 恢复的状态机。失败或取消只影响提示，不影响任何功能可用性。
    private(set) var plusPurchaseState: AppPlusPurchaseState = .idle
    private(set) var plusProducts: [AppPlusProductInfo] = []
    private(set) var plusProductLoadState: AppPlusProductLoadState = .idle
    private var plusPurchaseUpdatesTask: Task<Void, Never>?
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
    /// 已确认的 WebDAV 服务器证书指纹，按 host:port + 用户名区分。
    var webDAVCertificateTrustRecords: [WebDAVTrustedCertificateRecord] = []
    /// 最近一次因证书问题被阻断的连接；设置页据此给出「查看指纹并信任」入口。
    var webDAVPendingCertificateChallenge: WebDAVCertificateChallenge?
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
    /// issue #37：CSV / JSON / Bitwarden / Aegis / Stratum 的格式导入预览（确认前不写库）。
    var formatImportPreview: FormatImportPreview?
    var formatImportPassword = ""
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
    /// issue #32：KeePass 原生库页面是否展示（设置页与密码页「更多」共用）。
    var isKeePassLibraryPresented = false
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
    // issue #127：常用账号模板。模板正文只存在加密侧表，这里是解锁会话内的内存副本。
    var accountTemplates: [AccountTemplate] = []
    /// 套用模板后账号输入框要显示的占位提示（模板只存占位，不存账号值）。
    var accountTemplateUsernamePrompt = ""
    /// 套用模板后给用户的一句结果说明（例如「已填写 3 个空字段」）。
    var accountTemplatePrefillMessage: String?
    var accountTemplateStatusMessage: String?
    var isAccountTemplatesPresented = false
    var isAccountTemplateImportPickerPresented = false
    var accountTemplateImportPreview: AccountTemplateImportPreview?
    var accountTemplateImportData: Data?
    var accountTemplateImportOverwrite = false
    var isAccountTemplateExportPresented = false
    var accountTemplateExportDocument: AccountTemplateExportDocument?
    /// issue #36：Monica Send 分享包接收入口（URL scheme 或 `.send` 文件导入时填充）。
    var monicaSendIncoming: MonicaSendIncoming?
    var expandedToolbarAction: AndroidParityToolbarAction?
    /// issue #153：启动时是否自动展开并聚焦密码页搜索框（默认关闭）。
    var isSearchAutoFocusOnLaunchEnabled = false
    /// 本次启动是否已经结算过自动聚焦，保证同一个进程只聚焦一次。
    var didHandleLaunchSearchAutoFocus = false
    /// 是否还有一次待执行的搜索框聚焦（密码页消费后清零）。
    var isSearchAutoFocusPendingForPasswordPage = false
    /// 本次启动是否收到过深链 / 控制中心 / 快捷指令导航目标；被导航覆盖时不抢焦点。
    var didReceiveLaunchNavigationTarget = false
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
    var downloadedWebDAVRestoreBackup: WebDAVDownloadedBackup?
    var downloadedCloudFileRestore: CloudFileDownload?
    let oneDriveBackupPreferencesStore: any AppOneDriveBackupPreferencesStore
    let oneDriveNow: () -> Date

    let vaultRepository: LocalVaultRepository
    @ObservationIgnored let trashMaintenance = AppTrashMaintenance()
    private let vaultKeychainService: (any AppVaultKeychainService)?
    private let vaultWrappedKeyProvider: ((LocalVaultSession) throws -> WrappedVaultKey)?
    private let rememberedVaultStore: any RememberedVaultStore
    let vaultRegistryStore: any AppVaultRegistryStore
    private let biometricUnlockPreferenceStore: any BiometricUnlockPreferenceStore
    private let vaultDisplayPreferenceStore: any VaultDisplayPreferenceStore
    private let appearancePreferenceStore: any AppAppearancePreferenceStore
    private let vaultLayoutPreferenceStore: any VaultLayoutPreferenceStore
    let searchAutoFocusPreferenceStore: any AppSearchAutoFocusPreferenceStore
    let totpCardPreferenceStore: any TotpProgressPreferenceStore
    let sensitivePreviewPreferenceStore: any SensitivePreviewPreferenceStore
    private let itemIconPreferenceStore: any AppItemIconPreferenceStore
    let sensitiveClipboardPreferenceStore: any SensitiveClipboardPreferenceStore
    let sensitivePasteboard: MonicaSensitivePasteboard
    let totpAutoCopyPreferenceStore: any TotpAutoCopyPreferenceStore
    /// #148：自动续写下一码的控制器；写入同样经过 #58 的敏感剪贴板与 TTL。
    let totpAutoCopyController: TotpAutoCopyController
    @ObservationIgnored var sensitivePasteboardExpiryTask: Task<Void, Never>?
    private let biometricUnlockAuthorizer: any BiometricUnlockAuthorizer
    /// 导出通行密钥前要求生物识别/设备密码确认；复用 MonicaSecurity 的设备所有者认证。
    private let deviceOwnerAuthenticator: any BiometricUnlockAuthorizer
    /// 通行密钥导入准备、钥匙串写入与导出读取；私钥只停留在钥匙串与内存。
    private let passkeyExchangeService: PasskeyExchangeService
    /// #154：SSH 生成器保存条目时把 OpenSSH 私钥写入钥匙串，条目里只保留引用。
    let sshPrivateKeyStore: any SSHPrivateKeyStore
    private let biometricCapabilityProvider: () -> BiometricUnlockCapability
    private let securityQuestionStore: any SecurityQuestionRecoveryStore
    private let securityQuestionVerifier: SecurityQuestionAnswerVerifier
    private let securityQuestionThrottle: SecurityQuestionVerificationThrottle
    private let securityQuestionClock: () -> Date
    let webDAVBackupService: any AppWebDAVBackupService
    /// TOFU 证书指纹存储；设置页与备份服务共用同一个 Keychain 记录。
    let webDAVCertificateTrustStore: any WebDAVCertificateTrustStore
    private let operationTimelineStore: any AppOperationTimelineStore
    private let quickSetupStateStore: any AppQuickSetupStateStore
    let backgroundBackupScheduler: any AppBackgroundBackupScheduler
    let cloudFileProviders: [CloudFileProviderKind: any CloudFileProvider]
    let oneDriveAuthenticationService: (any AppOneDriveAuthenticationService)?
    let bitwardenPasswordAuthenticationService: (any AppBitwardenPasswordAuthenticationService)?
    let bitwardenSyncProvider: (any BitwardenSyncProvider)?
    let bitwardenAuthenticationSessionStore: any BitwardenAuthenticationSessionStore
    let bitwardenVaultKeyStore: (any BitwardenVaultKeyStore)?
    let bitwardenSendSyncStateStore: any AppBitwardenSendSyncStateStore
    let bitwardenFolderSyncStateStore: any AppBitwardenFolderSyncStateStore
    let bitwardenItemSyncStateStore: any AppBitwardenItemSyncStateStore
    let bitwardenPendingMutationQueueStore: any AppBitwardenPendingMutationQueueStore
    let bitwardenSyncCheckpointStore: any AppBitwardenSyncCheckpointStore
    private let autoFillIndexStore: (any AutoFillEncryptedIndexStore)?
    private let autoFillCredentialSecretStore: (any AutoFillCredentialSecretStore)?
    private let autoFillCredentialIdentityStore: (any AppAutoFillCredentialIdentityStore)?
    private let autoFillPolicyStore: any AppAutoFillPolicyStore
    private let autoFillGuardPolicyStore: any AppAutoFillGuardPolicyStore
    private let autoFillPublishLogStore: any AppAutoFillPublishLogStore
    private let autoFillIndexKeyMaterialProvider: ((String) throws -> AutoFillIndexKeyMaterial)?
    private let autoFillIndexCodec: AutoFillEncryptedIndexCodec
    private let autoFillCredentialSecretCodec: AutoFillCredentialSecretCodec
    private let plusPurchaseService: (any AppPlusPurchaseService)?
    private let plusEntitlementStore: any AppPlusEntitlementStore
    let androidBackupAttachmentBlobStore: any AndroidBackupAttachmentBlobStore
    let keePassDatabaseReader: any KeePassDatabaseReader
    let keePassKdbxFileWritebackService: any AppKeePassKdbxFileWritebackService
    let keePassKdbx3WritebackCoordinator: any KeePassKdbx3WritebackCoordinator
    let keePassKdbx4WritebackCoordinator: any KeePassKdbx4WritebackCoordinator
    let widgetSnapshotStore: AppWidgetSnapshotFileStore?
    let shortcutSnapshotStore: AppShortcutSnapshotFileStore?
    let widgetReloadScheduler: (any MonicaWidgetReloadScheduling)?
    /// 全 App 唯一触感入口（#147）：关闭总开关后不会触发任何反馈。
    let haptics: AppHaptics
    var widgetSnapshotSyncError: String?
    let controlNavigationDefaults: UserDefaults?
    let attachmentContentEncryptionKeyProvider: ((LocalAttachmentMetadata) throws -> Data)?
    let androidAttachmentWrappingKeyProvider: ((LocalAttachmentMetadata) throws -> AndroidAttachmentContentWrappingKey)?
    let passwordGenerator: () throws -> String
    let bitwardenFileSendLocalIDProvider: () -> String
    let bitwardenTextSendLocalIDProvider: () -> String
    var activeVaultSession: LocalVaultSession?
    var activeEntryRepository: LocalVaultEntryRepository?
    var activeProject: LocalVaultProject?
    private var rememberedVaultDescriptor: LocalVaultDescriptor?
    private var rememberedVaultID: String?
    /// 本地多库注册表：只存名称/路径/时间/默认标记，绝不存主密码或密钥。
    var vaultRegistry: LocalVaultRegistry
    var vaultRegistryOperationState: VaultOperationState = .idle
    /// 从多库列表里新建库时，锁屏需要先让用户设置主密码；这个字段只记录待创建的库名。
    var pendingVaultCreationName: String?
    private var lastUserActivityAt: Date?
    var pendingAndroidEncryptedBackupData: Data?
    var keePassLastSuccessfulUnlockCredentials: KeePassUnlockCredentials?
    var pendingBitwardenTwoFactorChallenge: BitwardenTwoFactorLoginChallenge?
    private var quickSetupState: AppQuickSetupState

    init(
        vaultRepository: LocalVaultRepository = LocalVaultRepository(),
        vaultKeychainService: (any AppVaultKeychainService)? = nil,
        vaultWrappedKeyProvider: ((LocalVaultSession) throws -> WrappedVaultKey)? = nil,
        rememberedVaultStore: any RememberedVaultStore = MemoryRememberedVaultStore(),
        vaultRegistryStore: any AppVaultRegistryStore = MemoryAppVaultRegistryStore(),
        biometricUnlockPreferenceStore: any BiometricUnlockPreferenceStore = MemoryBiometricUnlockPreferenceStore(),
        vaultDisplayPreferenceStore: any VaultDisplayPreferenceStore = MemoryVaultDisplayPreferenceStore(),
        appearancePreferenceStore: any AppAppearancePreferenceStore = MemoryAppAppearancePreferenceStore(),
        vaultLayoutPreferenceStore: any VaultLayoutPreferenceStore = MemoryVaultLayoutPreferenceStore(),
        searchAutoFocusPreferenceStore: any AppSearchAutoFocusPreferenceStore = MemoryAppSearchAutoFocusPreferenceStore(),
        totpCardPreferenceStore: any TotpProgressPreferenceStore = MemoryTotpProgressPreferenceStore(),
        biometricUnlockAuthorizer: any BiometricUnlockAuthorizer = DeviceBiometricUnlockAuthorizer(),
        itemIconPreferenceStore: any AppItemIconPreferenceStore = MemoryAppItemIconPreferenceStore(),
        deviceOwnerAuthenticator: any BiometricUnlockAuthorizer = DeviceOwnerLocalAuthenticator(),
        passkeyExchangeService: PasskeyExchangeService = PasskeyExchangeService(
            privateKeyStore: KeychainPasskeyPrivateKeyStore()
        ),
        sshPrivateKeyStore: any SSHPrivateKeyStore = KeychainSSHPrivateKeyStore(),
        biometricCapabilityProvider: @escaping () -> BiometricUnlockCapability = { .unavailable },
        securityQuestionStore: any SecurityQuestionRecoveryStore = MigratingSecurityQuestionRecoveryStore(),
        securityQuestionVerifier: SecurityQuestionAnswerVerifier = SecurityQuestionAnswerVerifier(),
        securityQuestionThrottle: SecurityQuestionVerificationThrottle = .default,
        securityQuestionClock: @escaping () -> Date = { Date() },
        webDAVBackupService: any AppWebDAVBackupService = URLSessionAppWebDAVBackupService(),
        webDAVCertificateTrustStore: any WebDAVCertificateTrustStore = KeychainWebDAVCertificateTrustStore(),
        operationTimelineStore: any AppOperationTimelineStore = MemoryAppOperationTimelineStore(),
        quickSetupStateStore: any AppQuickSetupStateStore = MemoryAppQuickSetupStateStore(),
        securityInsightStore: any SecurityInsightPersisting = MemorySecurityInsightStore(),
        securityInsightNow: @escaping () -> Date = Date.init,
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
        bitwardenSyncCheckpointStore: any AppBitwardenSyncCheckpointStore = MemoryAppBitwardenSyncCheckpointStore(),
        autoFillIndexStore: (any AutoFillEncryptedIndexStore)? = nil,
        autoFillCredentialSecretStore: (any AutoFillCredentialSecretStore)? = nil,
        autoFillCredentialIdentityStore: (any AppAutoFillCredentialIdentityStore)? = nil,
        autoFillPolicyStore: any AppAutoFillPolicyStore = MemoryAppAutoFillPolicyStore(),
        autoFillGuardPolicyStore: any AppAutoFillGuardPolicyStore = MemoryAppAutoFillGuardPolicyStore(),
        autoFillPublishLogStore: any AppAutoFillPublishLogStore = MemoryAppAutoFillPublishLogStore(),
        autoFillIndexKeyMaterialProvider: ((String) throws -> AutoFillIndexKeyMaterial)? = nil,
        autoFillIndexCodec: AutoFillEncryptedIndexCodec = AutoFillEncryptedIndexCodec(),
        autoFillCredentialSecretCodec: AutoFillCredentialSecretCodec = AutoFillCredentialSecretCodec(),
        plusPurchaseService: (any AppPlusPurchaseService)? = nil,
        plusEntitlementStore: any AppPlusEntitlementStore = MemoryAppPlusEntitlementStore(),
        androidBackupAttachmentBlobStore: any AndroidBackupAttachmentBlobStore = FileAndroidBackupAttachmentBlobStore(),
        keePassDatabaseReader: any KeePassDatabaseReader = DefaultKeePassDatabaseReader(),
        keePassKdbxFileWritebackService: any AppKeePassKdbxFileWritebackService = FileSystemAppKeePassKdbxFileWritebackService(),
        keePassKdbx3WritebackCoordinator: any KeePassKdbx3WritebackCoordinator = DefaultKeePassKdbx3WritebackCoordinator(),
        keePassKdbx4WritebackCoordinator: any KeePassKdbx4WritebackCoordinator = DefaultKeePassKdbx4WritebackCoordinator(),
        widgetSnapshotStore: AppWidgetSnapshotFileStore? = nil,
        shortcutSnapshotStore: AppShortcutSnapshotFileStore? = nil,
        widgetReloadScheduler: (any MonicaWidgetReloadScheduling)? = nil,
        haptics: AppHaptics = AppHaptics(),
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
        sensitiveClipboardPreferenceStore: any SensitiveClipboardPreferenceStore = MemorySensitiveClipboardPreferenceStore(),
        totpAutoCopyPreferenceStore: any TotpAutoCopyPreferenceStore = MemoryTotpAutoCopyPreferenceStore()
    ) {
        self.vaultRepository = vaultRepository
        self.vaultKeychainService = vaultKeychainService
        self.vaultWrappedKeyProvider = vaultWrappedKeyProvider
        self.rememberedVaultStore = rememberedVaultStore
        self.vaultRegistryStore = vaultRegistryStore
        self.vaultRegistry = (try? vaultRegistryStore.load()) ?? LocalVaultRegistry()
        self.biometricUnlockPreferenceStore = biometricUnlockPreferenceStore
        self.vaultDisplayPreferenceStore = vaultDisplayPreferenceStore
        self.appearancePreferenceStore = appearancePreferenceStore
        self.vaultLayoutPreferenceStore = vaultLayoutPreferenceStore
        self.searchAutoFocusPreferenceStore = searchAutoFocusPreferenceStore
        self.totpCardPreferenceStore = totpCardPreferenceStore
        self.biometricUnlockAuthorizer = biometricUnlockAuthorizer
        self.itemIconPreferenceStore = itemIconPreferenceStore
        self.deviceOwnerAuthenticator = deviceOwnerAuthenticator
        self.passkeyExchangeService = passkeyExchangeService
        self.sshPrivateKeyStore = sshPrivateKeyStore
        self.biometricCapabilityProvider = biometricCapabilityProvider
        self.securityQuestionStore = securityQuestionStore
        self.securityQuestionVerifier = securityQuestionVerifier
        self.securityQuestionThrottle = securityQuestionThrottle
        self.securityQuestionClock = securityQuestionClock
        self.webDAVBackupService = webDAVBackupService
        self.webDAVCertificateTrustStore = webDAVCertificateTrustStore
        self.operationTimelineStore = operationTimelineStore
        self.quickSetupStateStore = quickSetupStateStore
        self.securityInsightStore = securityInsightStore
        self.securityInsightNow = securityInsightNow
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
        self.bitwardenSyncCheckpointStore = bitwardenSyncCheckpointStore
        self.autoFillIndexStore = autoFillIndexStore
        self.autoFillCredentialSecretStore = autoFillCredentialSecretStore
        self.autoFillCredentialIdentityStore = autoFillCredentialIdentityStore
        self.autoFillPolicyStore = autoFillPolicyStore
        self.autoFillGuardPolicyStore = autoFillGuardPolicyStore
        self.autoFillPublishLogStore = autoFillPublishLogStore
        self.autoFillGuardPolicy = autoFillGuardPolicyStore.loadPolicy()
        self.autoFillDiagnostics = AppAutoFillDiagnosticsModel(
            identityStore: autoFillCredentialIdentityStore,
            publishLogStore: autoFillPublishLogStore
        )
        self.autoFillIndexKeyMaterialProvider = autoFillIndexKeyMaterialProvider
        self.autoFillIndexCodec = autoFillIndexCodec
        self.autoFillCredentialSecretCodec = autoFillCredentialSecretCodec
        self.plusPurchaseService = plusPurchaseService
        self.plusEntitlementStore = plusEntitlementStore
        self.androidBackupAttachmentBlobStore = androidBackupAttachmentBlobStore
        self.keePassDatabaseReader = keePassDatabaseReader
        self.keePassKdbxFileWritebackService = keePassKdbxFileWritebackService
        self.keePassKdbx3WritebackCoordinator = keePassKdbx3WritebackCoordinator
        self.keePassKdbx4WritebackCoordinator = keePassKdbx4WritebackCoordinator
        self.widgetSnapshotStore = widgetSnapshotStore
        self.shortcutSnapshotStore = shortcutSnapshotStore
        self.widgetReloadScheduler = widgetReloadScheduler
        self.haptics = haptics
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
        self.isSearchAutoFocusOnLaunchEnabled = searchAutoFocusPreferenceStore.loadIsSearchAutoFocusEnabled()
        self.totpCardPreferences = totpCardPreferenceStore.loadPreferences()
        self.sensitivePreviewPreferenceStore = sensitivePreviewPreferenceStore
        self.itemIconPreferences = itemIconPreferenceStore.loadPreferences()
        self.sensitivePreviewPreferences = sensitivePreviewPreferenceStore.loadPreferences()
        self.sensitiveClipboardPreferenceStore = sensitiveClipboardPreferenceStore
        self.sensitiveClipboardTTL = sensitiveClipboardPreferenceStore.loadTTL()
        self.sensitivePasteboard = sensitivePasteboard
            ?? MonicaSensitivePasteboard(pasteboard: UnavailableSensitivePasteboard())
        self.totpAutoCopyPreferenceStore = totpAutoCopyPreferenceStore
        self.totpAutoCopyEnabled = totpAutoCopyPreferenceStore.loadIsEnabled()
        self.totpAutoCopyController = TotpAutoCopyController(pasteboard: self.sensitivePasteboard)
        self.autoFillPolicy = autoFillPolicyStore.loadPolicy()
        if let snapshot = plusEntitlementStore.loadEntitlement() {
            // 离线时只用上次已验证快照做展示；联网后由 StoreKit 的当前权益重新校准。
            self.plusEntitlement = snapshot.isActive(at: Date())
                ? snapshot
                : .inactive(verifiedAt: snapshot.verifiedAt)
        }
        if let remembered = try? rememberedVaultStore.load() {
            self.rememberedVaultDescriptor = LocalVaultDescriptor(
                fileURL: remembered.fileURL,
                displayName: remembered.displayName
            )
            self.rememberedVaultID = remembered.vaultID
        }
        bootstrapVaultRegistry()
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

    var filteredGPGKeyEntries: [LocalGPGKeyEntry] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = gpgKeySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = gpgKeyEntries.enumerated().filter { _, entry in
            (!showFavoriteGPGKeyEntriesOnly || entry.favorite)
                && (query.isEmpty
                    || entry.title.localizedCaseInsensitiveContains(query)
                    || entry.ownerName.localizedCaseInsensitiveContains(query)
                    || entry.ownerEmail.localizedCaseInsensitiveContains(query)
                    || entry.fingerprint.localizedCaseInsensitiveContains(query.replacingOccurrences(of: " ", with: ""))
                    || entry.keyID.localizedCaseInsensitiveContains(query)
                    || entry.algorithm.localizedCaseInsensitiveContains(query)
                    || entry.notes.localizedCaseInsensitiveContains(query))
        }
        return filtered.map(\.element)
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

    var filteredBarcodeEntries: [LocalBarcodeEntry] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = barcodeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = barcodeEntries.enumerated().filter { _, entry in
            (!showFavoriteBarcodeEntriesOnly || entry.favorite)
                && (query.isEmpty
                    || entry.title.localizedCaseInsensitiveContains(query)
                    || entry.payload.localizedCaseInsensitiveContains(query)
                    || entry.label.localizedCaseInsensitiveContains(query)
                    || entry.symbology.displayName.localizedCaseInsensitiveContains(query)
                    || entry.notes.localizedCaseInsensitiveContains(query))
        }
        return filtered.map(\.element)
    }

    var editingBarcodeDraft: LocalBarcodeEntryDraft {
        LocalBarcodeEntryDraft(
            title: editingBarcodeTitle,
            symbology: editingBarcodeSymbology,
            payload: editingBarcodePayload,
            label: editingBarcodeLabel,
            notes: editingBarcodeNotes
        )
    }

    var editingBarcodePreviewPayload: String {
        guard let entryID = editingBarcodeEntryID else {
            return ""
        }
        return LocalBarcodeEntry(
            id: entryID,
            projectID: activeProject?.id ?? "",
            title: editingBarcodeTitle,
            symbology: editingBarcodeSymbology,
            payload: editingBarcodePayload,
            label: editingBarcodeLabel,
            notes: editingBarcodeNotes,
            favorite: editingBarcodeFavorite
        ).payload
    }

    var filteredAttachmentEntries: [LocalAttachmentMetadata] {
        guard !isTrashQuickFilterSelected else {
            return []
        }
        let query = attachmentSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = attachmentEntries.enumerated().filter { _, entry in
            guard vaultEntryPassesArchiveAndTagFilter(entry) else {
                return false
            }
            guard !query.isEmpty else {
                return true
            }
            return entry.fileName.localizedCaseInsensitiveContains(query)
                || entry.mediaType.localizedCaseInsensitiveContains(query)
                || entry.storageMode.localizedCaseInsensitiveContains(query)
                || entry.downloadState.localizedCaseInsensitiveContains(query)
                || entry.source.localizedCaseInsensitiveContains(query)
                || entry.contentHash.localizedCaseInsensitiveContains(query)
                || (entry.entryID?.localizedCaseInsensitiveContains(query) ?? false)
                || (entry.localPath?.localizedCaseInsensitiveContains(query) ?? false)
        }
        return vaultSortedEntries(filtered, isFavorite: { _ in false })
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
                id: "archived",
                title: String(localized: "归档"),
                value: itemCountLabel(archivedVaultEntryCount),
                detail: String(localized: "只显示已归档条目；归档条目不会出现在默认列表与自动填充候选中。"),
                systemImage: "archivebox",
                isSelected: selectedVaultQuickFilterID == "archived"
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

    @discardableResult
    func createVaultCategory(title: String) throws -> LocalVaultProject {
        recordUserActivity()
        entryOperationState = .running

        do {
            guard let entryRepository = activeEntryRepository else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            let node = try createVaultFolder(
                title: title,
                parentID: activeVaultFolder?.id,
                entryRepository: entryRepository
            )
            let project = LocalVaultProject(id: node.id, title: node.title)
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
            let node = try renameVaultFolder(
                folderID: projectID,
                title: title,
                entryRepository: entryRepository
            )
            let renamed = LocalVaultProject(id: node.id, title: node.title)
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
            guard let folderRepository = vaultFolderRepository(entryRepository: entryRepository) else {
                throw LocalVaultRepositoryError.vaultUnavailable
            }
            // 保留旧行为：非空分类仍然拒绝删除，需要走新的文件夹删除流程显式选择处置方式。
            let plan = try folderRepository.deletionPlan(folderID: projectID)
            guard plan.isEffectivelyEmpty else {
                // 保留旧语义：分类非空时抛出 projectNotEmpty，调用方据此提示“请先清空分类”。
                throw LocalVaultRepositoryError.projectNotEmpty
            }
            _ = try folderRepository.deleteFolder(folderID: projectID, strategy: .reparent)
            refreshVaultFolders(entryRepository: entryRepository)
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
    /// 生成器与 KeePass 库作为工具页始终保留在此，保证任何布局下都能从「更多」找到。
    var moreMenuLayoutModules: [PasswordLayoutModule] {
        var modules = vaultLayoutPreferences.hiddenModules
        if !modules.contains(.generator) {
            modules.append(.generator)
        }
        if !modules.contains(.keePass) {
            modules.append(.keePass)
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

    /// #149：写入条目图标偏好。先归一化（保证来源优先级是完整排列）再落盘，
    /// 存储独立于保险库，不触发任何数据迁移。
    func updateItemIconPreferences(_ preferences: ItemIconPreferences) {
        let normalized = preferences.normalized()
        guard normalized != itemIconPreferences else { return }
        itemIconPreferences = normalized
        itemIconPreferenceStore.savePreferences(normalized)
        recordUserActivity()
    }

    func restoreDefaultItemIconPreferences() {
        updateItemIconPreferences(.default)
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
        AppPlusEntitlementStatusRow(
            id: "plus-entitlement",
            title: "Monica Plus",
            value: isPlusSupporter ? String(localized: "支持者") : String(localized: "免费使用"),
            detail: plusEntitlementDetail,
            systemImage: isPlusSupporter ? "checkmark.seal.fill" : "seal"
        )
    }

    /// 支持者徽章只用于展示与感谢，绝不参与任何功能可用性判断。
    var isPlusSupporter: Bool {
        plusEntitlement.isActive(at: Date())
    }

    /// 所有功能永久免费；这里列出的每一项都不受 Monica Plus 影响。
    var plusFeatureRows: [AppPlusFeatureRow] {
        [
            AppPlusFeatureRow(
                id: "vault",
                title: String(localized: "密码库与附件"),
                detail: String(localized: "登录、笔记、卡片、身份、通行密钥、SSH、API Token、Wi-Fi、Send 与加密附件。"),
                systemImage: "key.horizontal"
            ),
            AppPlusFeatureRow(
                id: "autofill",
                title: String(localized: "自动填充与通行密钥"),
                detail: String(localized: "系统自动填充、通行密钥提供器与安全策略。"),
                systemImage: "key.viewfinder"
            ),
            AppPlusFeatureRow(
                id: "totp",
                title: String(localized: "验证器与安全中心"),
                detail: String(localized: "TOTP、Steam 令牌、安全洞察与安全中心。"),
                systemImage: "shield.lefthalf.filled"
            ),
            AppPlusFeatureRow(
                id: "sync",
                title: String(localized: "同步与备份"),
                detail: String(localized: "WebDAV、OneDrive、iCloud、局域网同步与加密备份。"),
                systemImage: "arrow.triangle.2.circlepath"
            )
        ]
    }

    /// 商品列表：未配置或加载失败时为空，界面显示「暂不可用」，免费功能照常。
    func loadPlusProducts() async {
        guard let plusPurchaseService else {
            plusProducts = []
            plusProductLoadState = .unavailable(String(localized: "Monica Plus 尚未在此版本开放。"))
            return
        }
        plusProductLoadState = .loading
        do {
            let products = try await plusPurchaseService.loadProducts()
            plusProducts = products
            plusProductLoadState = products.isEmpty
                ? .unavailable(String(localized: "Monica Plus 尚未在此版本开放。"))
                : .loaded
        } catch {
            plusProducts = []
            plusProductLoadState = .unavailable(readablePlusPurchaseErrorMessage(for: error))
        }
    }

    func purchasePlus(productID: String, now: Date = Date()) async {
        recordUserActivity()
        guard let plusPurchaseService else {
            plusPurchaseState = .failed(String(localized: "Monica Plus 尚未在此版本开放。"))
            return
        }
        plusPurchaseState = .purchasing(productID: productID)
        do {
            let result = try await plusPurchaseService.purchase(productID: productID)
            switch result {
            case .purchased:
                // 购买成功后仍以 StoreKit 的当前权益为准，避免把未验证事务当成权益。
                await refreshPlusEntitlement(now: now)
                plusPurchaseState = plusEntitlement.isActive(at: now)
                    ? .succeeded
                    : .failed(String(localized: "购买已完成，但未取得有效支持者权益。"))
            case .userCancelled:
                plusPurchaseState = .userCancelled
            case .pending:
                plusPurchaseState = .pending
            case .unverified:
                plusPurchaseState = .failed(String(localized: "购买凭据未通过验证，未取得支持者身份。"))
            case .nothingToRestore:
                plusPurchaseState = .nothingToRestore
            }
        } catch {
            if let appError = error as? AppPlusPurchaseError, appError == .userCancelled {
                plusPurchaseState = .userCancelled
            } else {
                plusPurchaseState = .failed(readablePlusPurchaseErrorMessage(for: error))
            }
        }
        recordUserActivity(at: now)
    }

    func restorePlusPurchases(now: Date = Date()) async {
        recordUserActivity()
        guard let plusPurchaseService else {
            plusPurchaseState = .failed(String(localized: "Monica Plus 尚未在此版本开放。"))
            return
        }
        plusPurchaseState = .restoring
        do {
            let entitlement = try await plusPurchaseService.restore()
            applyPlusEntitlement(entitlement, now: now)
            plusPurchaseState = entitlement.isActive(at: now) ? .succeeded : .nothingToRestore
        } catch {
            if let appError = error as? AppPlusPurchaseError, appError == .userCancelled {
                plusPurchaseState = .userCancelled
            } else {
                plusPurchaseState = .failed(readablePlusPurchaseErrorMessage(for: error))
            }
        }
        recordUserActivity(at: now)
    }

    /// 以 StoreKit 的当前已验证权益校准本地快照；无购买服务（测试 / 未配置）时保留快照。
    func refreshPlusEntitlement(now: Date = Date()) async {
        guard let plusPurchaseService else {
            return
        }
        applyPlusEntitlement(await plusPurchaseService.currentEntitlement(), now: now)
    }

    /// 监听 Ask-to-Buy 批准、退款与撤销；只接受已验证事务（由服务层过滤）。
    func startObservingPlusPurchases() {
        guard plusPurchaseUpdatesTask == nil, let plusPurchaseService else {
            return
        }
        plusPurchaseUpdatesTask = Task { [weak self] in
            for await entitlement in plusPurchaseService.updatesStream {
                guard !Task.isCancelled, let self else {
                    return
                }
                self.applyPlusEntitlement(entitlement, now: Date())
            }
        }
    }

    private func applyPlusEntitlement(_ entitlement: PlusEntitlement, now: Date) {
        if entitlement.isActive(at: now) {
            plusEntitlement = entitlement
            plusEntitlementStore.saveEntitlement(entitlement)
        } else {
            plusEntitlement = .inactive(verifiedAt: entitlement.verifiedAt)
            plusEntitlementStore.clearEntitlement()
        }
    }

    private func readablePlusPurchaseErrorMessage(for error: Error) -> String {
        if let appError = error as? AppPlusPurchaseError {
            return appError.localizedDescription
        }
        return String(localized: "购买失败，请稍后重试。")
    }

    private var plusEntitlementDetail: String {
        guard isPlusSupporter else {
            return String(localized: "Monica Plus 只是支持作者的心意，所有功能永久免费，无需购买。")
        }
        if let expiresAt = plusEntitlement.expiresAt {
            return String(
                localized: "感谢支持！支持者身份有效期至 \(expiresAt.formatted(date: .numeric, time: .omitted))。"
            )
        }
        return String(localized: "感谢支持！你的支持者身份永久有效。")
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
                value: String(localized: "永久免费"),
                detail: String(localized: "支持作者的可选赞助，不会解锁或锁定任何功能。"),
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

    /// 已被忽略合并的条目 ID：这些条目不再参与“重复项”的统计，保证安全中心行、合并预览与仪表盘口径一致。
    var ignoredDuplicateLoginEntryIDs: Set<String> {
        loginEntries.reduce(into: Set<String>()) { ids, entry in
            guard let key = DuplicateLoginEntryKey(entry: entry),
                  ignoredDuplicateLoginKeys.contains(key) else {
                return
            }
            ids.insert(entry.id)
        }
    }

    /// 锁定态只给一行提示：不显示任何条目数量、分数或命中，避免从锁屏预览里读出仓库规模。
    private static var lockedSecurityCenterRows: [AppSecurityCenterRow] {
        [
            AppSecurityCenterRow(
                id: "security-center-locked",
                title: String(localized: "安全中心"),
                value: String(localized: "需解锁"),
                detail: String(localized: "解锁后会在本机完成统计，数据不会离开设备。"),
                systemImage: "lock.shield"
            )
        ]
    }

    var securityCenterRows: [AppSecurityCenterRow] {
        guard vaultState == .unlocked else {
            return Self.lockedSecurityCenterRows
        }
        let report = securityInsightReport
        let breachMarkCount = securityInsightBreachMarkCount
        let breachValue = (breachMarkCount == 0 && report.count(for: .flaggedBreach) == 0)
            ? String(localized: "未标记")
            : itemCountLabel(report.count(for: .flaggedBreach))
        return [
            AppSecurityCenterRow(
                id: "security-score",
                title: String(localized: "安全评分"),
                value: "\(report.score) / \(SecurityInsightScoring.maximumScore)",
                detail: securityScoreDetail(for: report.score),
                systemImage: "gauge.with.dots.needle.50percent"
            ),
            AppSecurityCenterRow(
                id: "weak-passwords",
                title: String(localized: "弱密码"),
                value: itemCountLabel(report.count(for: .weakPassword)),
                detail: report.count(for: .weakPassword) == 0
                    ? String(localized: "当前登录条目未发现明显弱密码。")
                    : String(localized: "建议优先为这些登录条目生成更长且包含多类字符的密码。"),
                systemImage: "exclamationmark.shield"
            ),
            AppSecurityCenterRow(
                id: "reused-passwords",
                title: String(localized: "复用密码"),
                value: itemCountLabel(report.count(for: .reusedPassword)),
                detail: report.count(for: .reusedPassword) == 0
                    ? String(localized: "当前登录条目未发现密码复用。")
                    : String(localized: "建议为复用密码的登录条目分别设置唯一密码。"),
                systemImage: "rectangle.2.swap"
            ),
            AppSecurityCenterRow(
                id: "missing-two-factor",
                title: String(localized: "未开启 2FA"),
                value: itemCountLabel(report.count(for: .missingTwoFactor)),
                detail: report.count(for: .missingTwoFactor) == 0
                    ? String(localized: "本机每个登录条目都找到了匹配的验证器。")
                    : String(localized: "这些条目在本机没有匹配的验证器条目，按本地规则推断为未开启 2FA。"),
                systemImage: "lock.rotation"
            ),
            AppSecurityCenterRow(
                id: "stale-passwords",
                title: String(localized: "长期未改密码"),
                value: itemCountLabel(report.count(for: .stalePassword)),
                detail: report.count(for: .stalePassword) == 0
                    ? String(localized: "未发现太久没有更换的密码。")
                    : String(localized: "距离上次更换已超过一年；没有修改记录的条目不计入。"),
                systemImage: "clock.badge.exclamationmark"
            ),
            AppSecurityCenterRow(
                id: "breached-passwords",
                title: String(localized: "泄露标记"),
                value: breachValue,
                detail: report.count(for: .flaggedBreach) == 0
                    ? String(localized: "标记完全由你手动完成；本 App 不会联网查询泄露数据库。")
                    : String(localized: "这些条目已被你标记为疑似泄露，建议立即更换密码。"),
                systemImage: "bolt.shield"
            ),
            AppSecurityCenterRow(
                id: "duplicate-logins",
                title: String(localized: "重复项"),
                value: itemCountLabel(report.count(for: .duplicateEntry)),
                detail: report.count(for: .duplicateEntry) == 0
                    ? String(localized: "当前登录条目未发现明显重复项。")
                    : String(localized: "建议检查这些登录条目，确认是否需要合并或保留。"),
                systemImage: "doc.on.doc"
            )
        ]
    }

    private func securityScoreDetail(for score: Int) -> String {
        switch SecurityInsightScoreBand.band(for: score) {
        case .excellent:
            return String(localized: "当前没有需要立即处理的严重问题。")
        case .good:
            return String(localized: "整体不错，仍有少量问题可以优化。")
        case .fair:
            return String(localized: "建议集中处理下面的问题后再评估。")
        case .atRisk:
            return String(localized: "问题较多，建议优先处理泄露与弱密码。")
        }
    }

    var securityCenterRepairSuggestions: [AppSecurityCenterRepairSuggestion] {
        guard vaultState == .unlocked else {
            return []
        }
        let report = securityInsightReport
        let weakPasswordCount = report.count(for: .weakPassword)
        let reusedPasswordCount = report.count(for: .reusedPassword)
        let missingTwoFactorCount = report.count(for: .missingTwoFactor)
        let stalePasswordCount = report.count(for: .stalePassword)
        let breachedPasswordCount = report.count(for: .flaggedBreach)
        let duplicateLoginCount = report.count(for: .duplicateEntry)
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
        if missingTwoFactorCount > 0 {
            suggestions.append(
                AppSecurityCenterRepairSuggestion(
                    id: "repair-missing-two-factor",
                    relatedRowID: "missing-two-factor",
                    title: String(localized: "补充验证器"),
                    detail: String(localized: "为这些登录条目添加匹配的验证器，登录时多一道验证。"),
                    systemImage: "lock.rotation"
                )
            )
        }
        if stalePasswordCount > 0 {
            suggestions.append(
                AppSecurityCenterRepairSuggestion(
                    id: "repair-stale-passwords",
                    relatedRowID: "stale-passwords",
                    title: String(localized: "更新长期未改密码"),
                    detail: String(localized: "为超过一年没有更换的密码生成新的唯一密码。"),
                    systemImage: "clock.arrow.circlepath"
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

    func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }

    func duplicateLoginGroups(
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

    var activeVaultEntryCount: Int {
        loginEntries.count
            + noteEntries.count
            + totpEntries.count
            + cardEntries.count
            + identityEntries.count
            + passkeyEntries.count
            + sshKeyEntries.count
            + gpgKeyEntries.count
            + apiTokenEntries.count
            + wifiEntries.count
            + barcodeEntries.count
            + sendEntries.count
            + steamEntries.count
            + attachmentEntries.count
            + billingAddressEntries.count
            + paymentAccountEntries.count
    }

    private var favoriteVaultEntryCount: Int {
        loginEntries.filter(\.favorite).count
            + noteEntries.filter(\.favorite).count
            + totpEntries.filter(\.favorite).count
            + cardEntries.filter(\.favorite).count
            + identityEntries.filter(\.favorite).count
            + passkeyEntries.filter(\.favorite).count
            + sshKeyEntries.filter(\.favorite).count
            + gpgKeyEntries.filter(\.favorite).count
            + apiTokenEntries.filter(\.favorite).count
            + wifiEntries.filter(\.favorite).count
            + barcodeEntries.filter(\.favorite).count
            + sendEntries.filter(\.favorite).count
            + steamEntries.filter(\.favorite).count
            + billingAddressEntries.filter(\.favorite).count
            + paymentAccountEntries.filter(\.favorite).count
    }

    private var deletedVaultEntryCount: Int {
        deletedLoginEntries.count
            + deletedNoteEntries.count
            + deletedTotpEntries.count
            + deletedCardEntries.count
            + deletedIdentityEntries.count
            + deletedPasskeyEntries.count
            + deletedSshKeyEntries.count
            + deletedGPGKeyEntries.count
            + deletedApiTokenEntries.count
            + deletedWifiEntries.count
            + deletedBarcodeEntries.count
            + deletedSendEntries.count
            + deletedSteamEntries.count
            + deletedAttachmentEntries.count
            + deletedBillingAddressEntries.count
            + deletedPaymentAccountEntries.count
    }

    func itemCountLabel(_ count: Int) -> String {
        String(localized: "\(count) 项")
    }

    func normalizedLoginHost(from url: String) -> String? {
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

    func filteredFavoriteEntries<Entry: VaultTaggedEntry>(
        _ entries: [Entry],
        query: String,
        favoritesOnly: Bool,
        isFavorite: (Entry) -> Bool,
        matches: (Entry, String) -> Bool
    ) -> [Entry] {
        let filtered = entries.enumerated().filter { _, entry in
            guard vaultEntryPassesArchiveAndTagFilter(entry) else {
                return false
            }
            return (!favoritesOnly || isFavorite(entry))
                && (query.isEmpty || matches(entry, query))
        }
        return vaultSortedEntries(filtered, isFavorite: isFavorite)
    }

    func clearVaultSearchQueries() {
        loginSearchQuery = ""
        noteSearchQuery = ""
        totpSearchQuery = ""
        cardSearchQuery = ""
        identitySearchQuery = ""
        passkeySearchQuery = ""
        sshKeySearchQuery = ""
        gpgKeySearchQuery = ""
        apiTokenSearchQuery = ""
        wifiSearchQuery = ""
        ssoSearchQuery = ""
        barcodeSearchQuery = ""
        sendSearchQuery = ""
        steamSearchQuery = ""
        attachmentSearchQuery = ""
        billingAddressSearchQuery = ""
        paymentAccountSearchQuery = ""
    }

    func setAllFavoriteFilters(_ favoritesOnly: Bool) {
        showFavoriteLoginEntriesOnly = favoritesOnly
        showFavoriteNoteEntriesOnly = favoritesOnly
        showFavoriteTotpEntriesOnly = favoritesOnly
        showFavoriteCardEntriesOnly = favoritesOnly
        showFavoriteIdentityEntriesOnly = favoritesOnly
        showFavoritePasskeyEntriesOnly = favoritesOnly
        showFavoriteSshKeyEntriesOnly = favoritesOnly
        showFavoriteGPGKeyEntriesOnly = favoritesOnly
        showFavoriteApiTokenEntriesOnly = favoritesOnly
        showFavoriteWifiEntriesOnly = favoritesOnly
        showFavoriteSSOEntriesOnly = favoritesOnly
        showFavoriteBarcodeEntriesOnly = favoritesOnly
        showFavoriteSendEntriesOnly = favoritesOnly
        showFavoriteSteamEntriesOnly = favoritesOnly
        showFavoriteBillingAddressEntriesOnly = favoritesOnly
        showFavoritePaymentAccountEntriesOnly = favoritesOnly
    }

    func resetVaultQuickFilters() {
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
            unlockedWithDeviceOwnerAuthentication = false
            activeVaultName = session.descriptor.displayName
            activeVaultSession = session
            let entryRepository = vaultRepository.entryRepository(for: session)
            activeEntryRepository = entryRepository
            activeProject = nil
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
            refreshVaultFolders(entryRepository: entryRepository)
            activateInitialVaultCategoryIfNeeded(entryRepository: entryRepository)
            rememberVault(session)
            bitwardenPendingMutationBatches = (try? bitwardenPendingMutationQueueStore.loadBatches(
                vaultID: session.handle.vaultID
            )) ?? []
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
            unlockedWithDeviceOwnerAuthentication = false
            activeVaultName = session.descriptor.displayName
            activeVaultSession = session
            let entryRepository = vaultRepository.entryRepository(for: session)
            activeEntryRepository = entryRepository
            activeProject = nil
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
            refreshVaultFolders(entryRepository: entryRepository)
            activateInitialVaultCategoryIfNeeded(entryRepository: entryRepository)
            rememberVault(session)
            bitwardenPendingMutationBatches = (try? bitwardenPendingMutationQueueStore.loadBatches(
                vaultID: session.handle.vaultID
            )) ?? []
            recordUserActivity(at: now)
            publishWidgetSnapshots(now: now, reloadImmediately: true)
            vaultOperationState = .succeeded(session.descriptor.displayName)
            vaultRecoveryContext = nil
            vaultRecoveryHistory.recordOpened(fileURL: fileURL, at: now)
        } catch {
            AppDiagnosticEmission.vaultFailure(error, stage: .open)
            clearVaultAccessAfterFailure()
            vaultRecoveryContext = AppVaultRecoveryContext(
                failure: AppVaultRecoveryFailure.classify(error, stage: .openVault),
                stage: .openVault,
                fileURL: fileURL,
                displayName: fileURL.deletingPathExtension().lastPathComponent,
                retryMode: .password
            )
            vaultOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    /// issue #144：恢复页在覆盖真实库之前，先用候选主密码打开一份快照副本做校验。
    /// 校验后立刻关闭副本，避免临时库的 `-wal` / `-shm` 侧车残留。
    func verifyCandidateVaultForRecovery(at fileURL: URL, password: String, deviceID: String) throws {
        let candidate = try vaultRepository.openVault(at: fileURL, password: password, deviceID: deviceID)
        vaultRepository.closeVault(for: candidate)
    }

    func unlockRememberedVaultWithPassword(
        deviceID: String,
        now: Date = Date(),
        fallbackDirectory: URL? = nil
    ) throws {
        guard let rememberedVaultDescriptor else {
            vaultOperationState = .failed(AppVaultKeychainError.rememberedVaultUnavailable.localizedDescription)
            vaultRecoveryContext = AppVaultRecoveryContext(
                failure: .vaultNotRemembered,
                stage: .passwordUnlock,
                fileURL: nil,
                displayName: nil,
                retryMode: .password
            )
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
            // issue #127：新建登录条目前先清掉上一次的模板提示，再载入模板列表。
            resetAccountTemplatePrefill()
            prepareAccountTemplatesForEditor()
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

    func presentEditEditor(for entry: LocalGPGKeyEntry) {
        selectGPGKeyEntryForEditing(entry)
        presentedEditorMode = .edit(VaultItemRoute(kind: .gpgKey, entryID: entry.id))
    }

    func presentEditEditor(for entry: LocalApiTokenEntry) {
        selectApiTokenEntryForEditing(entry)
        presentedEditorMode = .edit(VaultItemRoute(kind: .apiToken, entryID: entry.id))
    }

    func presentEditEditor(for entry: LocalWifiEntry) {
        selectWifiEntryForEditing(entry)
        presentedEditorMode = .edit(VaultItemRoute(kind: .wifi, entryID: entry.id))
    }

    func presentEditEditor(for entry: LocalBarcodeEntry) {
        selectBarcodeEntryForEditing(entry)
        presentedEditorMode = .edit(VaultItemRoute(kind: .barcode, entryID: entry.id))
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
        case .gpgKey:
            if let entry = gpgKeyEntries.first(where: { $0.id == route.entryID }) { presentEditEditor(for: entry) }
        case .apiToken:
            if let entry = apiTokenEntries.first(where: { $0.id == route.entryID }) { presentEditEditor(for: entry) }
        case .wifi:
            if let entry = wifiEntries.first(where: { $0.id == route.entryID }) { presentEditEditor(for: entry) }
        case .sso:
            if let entry = ssoEntries.first(where: { $0.id == route.entryID }) { presentEditEditor(for: entry) }
        case .barcode:
            if let entry = barcodeEntries.first(where: { $0.id == route.entryID }) { presentEditEditor(for: entry) }
        case .send:
            if let entry = sendEntries.first(where: { $0.id == route.entryID }) { presentEditEditor(for: entry) }
        case .steam:
            if let entry = steamEntries.first(where: { $0.id == route.entryID }) { presentEditEditor(for: entry) }
        case .billingAddress:
            if let entry = billingAddressEntries.first(where: { $0.id == route.entryID }) { presentEditEditor(for: entry) }
        case .paymentAccount:
            if let entry = paymentAccountEntries.first(where: { $0.id == route.entryID }) { presentEditEditor(for: entry) }
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
        case .gpgKey:
            return gpgKeyEntries.first { $0.id == entryID }?.title ?? String(localized: "GPG 密钥")
        case .apiToken:
            return apiTokenEntries.first { $0.id == entryID }?.title ?? "API Token"
        case .wifi:
            return wifiEntries.first { $0.id == entryID }?.title ?? "Wi-Fi"
        case .sso:
            return ssoEntries.first { $0.id == entryID }?.title ?? "SSO"
        case .barcode:
            return barcodeEntries.first { $0.id == entryID }?.title ?? String(localized: "条码")
        case .send:
            return sendEntries.first { $0.id == entryID }?.title ?? "Send"
        case .steam:
            return steamEntries.first { $0.id == entryID }?.title ?? "Steam"
        case .billingAddress:
            return billingAddressEntries.first { $0.id == entryID }?.title ?? String(localized: "账单地址")
        case .paymentAccount:
            return paymentAccountEntries.first { $0.id == entryID }?.title ?? String(localized: "支付账户")
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
        case .gpgKey:
            try createGPGKeyEntry(projectTitle: projectTitle)
        case .apiToken:
            try createApiTokenEntry(projectTitle: projectTitle)
        case .wifi:
            try createWifiEntry(projectTitle: projectTitle)
        case .sso:
            try createSSOEntry(projectTitle: projectTitle)
        case .barcode:
            try createBarcodeEntry(projectTitle: projectTitle)
        case .send:
            try createSendEntry(projectTitle: projectTitle)
        case .steam:
            try createSteamEntry(projectTitle: projectTitle)
        case .billingAddress:
            try createBillingAddressEntry(projectTitle: projectTitle)
        case .paymentAccount:
            try createPaymentAccountEntry(projectTitle: projectTitle)
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
        case .gpgKey:
            try updateSelectedGPGKeyEntry()
        case .apiToken:
            try updateSelectedApiTokenEntry()
        case .wifi:
            try updateSelectedWifiEntry()
        case .sso:
            try updateSelectedSSOEntry()
        case .barcode:
            try updateSelectedBarcodeEntry()
        case .send:
            try updateSelectedSendEntry()
        case .steam:
            try updateSelectedSteamEntry()
        case .billingAddress:
            try updateSelectedBillingAddressEntry()
        case .paymentAccount:
            try updateSelectedPaymentAccountEntry()
        case .attachmentRef:
            throw LocalVaultRepositoryError.unsupportedEntryType(kind)
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
                project = try createOrReuseVaultProject(title: projectTitle, entryRepository: entryRepository)
                activeProject = project
            }

            if let existing = matchingLoginEntry(for: normalizedRequest, in: loginEntries) {
                let updated = try entryRepository.updateLoginEntry(
                    projectID: project.id,
                    entryID: existing.id,
                    draft: LocalLoginEntryDraft(
                        title: existing.title,
                        username: normalizedRequest.username,
                        account: existing.account,
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

    private func readableSteamImportErrorMessage(for error: Error) -> String {
        guard let totpError = error as? TotpError else {
            return error.localizedDescription
        }

        switch totpError {
        case .invalidSecret:
            return String(localized: "Steam 验证器文件缺少有效密钥。")
        case .invalidURI:
            return String(localized: "请输入有效的 Steam maFile/JSON 验证器文件。")
        case .invalidDigits, .invalidPeriod, .invalidAlgorithm, .missingCounter, .invalidCounter, .uriTooLong:
            return String(localized: "无法导入该 Steam 验证器文件。")
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
                project = try createOrReuseVaultProject(title: projectTitle, entryRepository: entryRepository)
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
            barcodeEntries = try entryRepository.listBarcodeEntries(projectID: projectID)
            deletedBarcodeEntries = try entryRepository.listDeletedBarcodeEntries(projectID: projectID)
            sendEntries = try entryRepository.listSendEntries(projectID: projectID)
            deletedSendEntries = try entryRepository.listDeletedSendEntries(projectID: projectID)
            steamEntries = try entryRepository.listSteamEntries(projectID: projectID)
            deletedSteamEntries = try entryRepository.listDeletedSteamEntries(projectID: projectID)
            attachmentEntries = try entryRepository.listAttachmentMetadata(projectID: projectID)
            deletedAttachmentEntries = try entryRepository.listDeletedAttachmentMetadata(projectID: projectID)
            entryOperationState = .succeeded(String(localized: "已刷新扩展通行条目"))
        } catch {
            entryOperationState = .failed(error.localizedDescription)
            throw error
        }
    }

    // MARK: - 通用导入导出（CSV / JSON / Bitwarden / Aegis / Stratum）

    // MARK: - 格式导入（issue #37）

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
        credentialExchange.importIssues = []
        credentialExchange.importIsFinished = false
        credentialExchange.importMessage = nil
        entryOperationState = .running
        defer { credentialExchange.isFetchingImport = false }

        do {
            let data = try await ASCredentialImportManager().importCredentials(token: token)
            guard data.formatVersion.rawValue == CredentialExchangeFormat.supportedVersion else {
                credentialExchange.importError = "不支持的凭据交换版本 \(data.formatVersion.rawValue)。本地保险库未做改动。"
                entryOperationState = .failed("不支持的凭据交换版本")
                return
            }
            let sourcePlan = CredentialExchangeCodec.importPlan(
                accounts: AppCredentialExchangeBridge.accounts(from: data),
                existingLoginEntries: loginEntries,
                existingTOTPEntries: totpEntries,
                existingPasskeyEntries: passkeyEntries
            )
            // 通行密钥在写入钥匙串之前先做一次加密层预检：只校验和派生公钥，不产生任何副作用。
            var issues = sourcePlan.passkeyIssues.map(AppCredentialExchangeIssue.init(storageIssue:))
            var preparedPasskeys: [PasskeyExchangeImport] = []
            for item in sourcePlan.passkeys {
                do {
                    preparedPasskeys.append(try passkeyExchangeService.prepareImport(
                        PasskeyExchangeCredential(item.credential),
                        title: item.title,
                        notes: ""
                    ))
                } catch {
                    issues.append(AppCredentialExchangeIssue(
                        error: error,
                        title: item.title,
                        relyingPartyIdentifier: item.credential.relyingPartyIdentifier
                    ))
                }
            }
            let plan = adjustedCredentialExchangeImportPlan(
                sourcePlan,
                preparedPasskeys: preparedPasskeys
            )
            // 全部条目都不可用时也打开预览，让用户看到逐条降级原因，而不是只弹一条错误。
            guard !plan.isEmpty || !issues.isEmpty else {
                credentialExchange.importError = emptyCredentialExchangeMessage(plan)
                entryOperationState = .failed("没有可导入的凭据")
                return
            }
            credentialExchange.importIssues = issues
            credentialExchange.importPreview = AppCredentialExchangeImportPreview(
                plan: plan,
                passkeys: preparedPasskeys,
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

    /// 预检失败的通行密钥从可导入列表里剔除，并计入无效数据，避免确认时整批失败。
    private func adjustedCredentialExchangeImportPlan(
        _ plan: CredentialExchangeImportPlan,
        preparedPasskeys: [PasskeyExchangeImport]
    ) -> CredentialExchangeImportPlan {
        let validCredentialIDs = Set(preparedPasskeys.map(\.credentialID))
        let acceptedItems = plan.passkeys.filter { validCredentialIDs.contains($0.credential.credentialID) }
        guard acceptedItems.count != plan.passkeys.count else { return plan }
        return CredentialExchangeImportPlan(
            drafts: plan.drafts,
            passkeys: acceptedItems,
            passkeyIssues: plan.passkeyIssues,
            sourceAccountCount: plan.sourceAccountCount,
            sourceItemCount: plan.sourceItemCount,
            passwordCount: plan.passwordCount,
            totpCount: plan.totpCount,
            skippedDuplicateCount: plan.skippedDuplicateCount,
            unsupportedCredentialCount: plan.unsupportedCredentialCount,
            invalidCredentialCount: plan.invalidCredentialCount
                + (plan.passkeys.count - acceptedItems.count)
        )
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
        var committedPasskeys: [PasskeyExchangeImport] = []
        var issues = credentialExchange.importIssues
        var importedCount = 0
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
                    importedCount += 1
                }
            }
            // 通行密钥逐条写入：单条钥匙串或落库失败只记录问题并继续，最后统一汇总。
            for prepared in preview.passkeys {
                do {
                    try passkeyExchangeService.commitImport(prepared)
                    committedPasskeys.append(prepared)
                    let metadata = prepared.metadata
                    let draft = LocalPasskeyEntryDraft(
                        title: metadata.title,
                        relyingPartyID: metadata.relyingPartyID,
                        username: metadata.username,
                        userHandle: metadata.userHandle,
                        credentialID: metadata.credentialID,
                        publicKeyCOSE: metadata.publicKeyCOSE,
                        privateKeyReference: metadata.privateKeyReference,
                        notes: metadata.notes
                    )
                    if let entryID = try createCSVImportedItem(
                        .passkey(draft),
                        projectID: project.id,
                        entryRepository: entryRepository
                    ) {
                        created.append((.passkey(draft), entryID))
                        importedCount += 1
                    } else {
                        try? passkeyExchangeService.rollbackImport(prepared)
                        issues.append(AppCredentialExchangeIssue(
                            title: metadata.title,
                            relyingPartyIdentifier: metadata.relyingPartyID,
                            reason: .duplicate
                        ))
                    }
                } catch {
                    try? passkeyExchangeService.rollbackImport(prepared)
                    issues.append(AppCredentialExchangeIssue(
                        error: error,
                        title: prepared.metadata.title,
                        relyingPartyIdentifier: prepared.metadata.relyingPartyID
                    ))
                }
            }
            try refreshAllEntryLists(projectID: project.id, entryRepository: entryRepository)
            try refreshAutoFillEncryptedIndexIfConfigured()
            credentialExchange.importIssues = issues
            credentialExchange.importIsFinished = true
            credentialExchange.importMessage = importedCredentialMessage(
                importedCount: importedCount,
                issueCount: issues.count
            )
            credentialExchange.importError = nil
            if issues.isEmpty {
                credentialExchange.importPreview = nil
            }
            entryOperationState = .succeeded("凭据已导入 \(importedCount) 项")
        } catch {
            rollbackCredentialExchangeImportPasskeys(committedPasskeys)
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

    private func rollbackCredentialExchangeImportPasskeys(_ prepared: [PasskeyExchangeImport]) {
        for item in prepared.reversed() {
            try? passkeyExchangeService.rollbackImport(item)
        }
    }

    private func importedCredentialMessage(importedCount: Int, issueCount: Int) -> String {
        if issueCount == 0 {
            return String(localized: "已导入 \(importedCount) 项。")
        }
        return String(localized: "已导入 \(importedCount) 项，另有 \(issueCount) 项已跳过。")
    }

    func cancelCredentialExchangeImport() {
        credentialExchange.importPreview = nil
        credentialExchange.importError = nil
        credentialExchange.importIssues = []
        credentialExchange.importIsFinished = false
        credentialExchange.importMessage = nil
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
            return "系统提供的条目暂不支持迁移，本地保险库未做改动。"
        }
        return "没有找到可导入的密码、TOTP 或通行密钥，本地保险库未做改动。"
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
        credentialExchange.exportIsFinished = false

        // 导出前只检查通行密钥元数据（不读私钥），明显无效的条目先列成问题。
        let candidates = AppCredentialExchangePasskeys.exportCandidates(from: passkeyEntries)
        let plan = CredentialExchangeCodec.exportPlan(
            loginEntries: loginEntries,
            totpEntries: totpEntries
        )
        credentialExchange.exportIssues = candidates.issues
        guard !plan.isEmpty || !candidates.entries.isEmpty else {
            credentialExchange.exportPasskeyCount = 0
            let invalidCount = plan.skippedCount + candidates.issues.count
            credentialExchange.exportError = invalidCount > 0
                ? String(localized: "没有可导出的密码、TOTP 或通行密钥；另有 \(invalidCount) 条条目无效。")
                : "没有可导出的密码、TOTP 或通行密钥。"
            return false
        }
        credentialExchange.exportPlan = plan
        credentialExchange.exportPasskeyCount = candidates.entries.count
        return true
    }

    @discardableResult
    func performCredentialExchangeExport() async -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        guard credentialExchange.exportPlan != nil else { return false }
        guard let anchor = AppCredentialExchangePresenter.keyWindow() else {
            credentialExchange.exportError = "找不到可用于系统导出面板的窗口。"
            return false
        }

        credentialExchange.isExporting = true
        credentialExchange.exportError = nil
        defer { credentialExchange.isExporting = false }

        // 先做纯元数据筛选，避免把密码/TOTP 导出也拖进设备确认（无密码设备会直接失败）。
        let candidates = AppCredentialExchangePasskeys.exportCandidates(from: passkeyEntries)
        if !candidates.entries.isEmpty {
            // 读私钥之前先要求生物识别/设备密码确认；被拒绝时完全不接触钥匙串。
            do {
                try await deviceOwnerAuthenticator.authenticate(
                    reason: String(localized: "导出通行密钥前需要确认你的身份")
                )
            } catch {
                credentialExchange.exportError = "未通过设备确认，未导出任何数据。"
                entryOperationState = .failed("设备确认未通过")
                return false
            }
        }

        var issues = candidates.issues
        var passkeyExports: [CredentialExchangePasskeyExport] = []
        for entry in candidates.entries {
            guard let credentialID = Data(base64Encoded: entry.credentialID),
                  let userHandle = Data(base64Encoded: entry.userHandle) else {
                issues.append(AppCredentialExchangeIssue(
                    title: entry.title,
                    relyingPartyIdentifier: entry.relyingPartyID,
                    reason: .invalidData
                ))
                continue
            }
            do {
                let credential = try passkeyExchangeService.exportCredential(
                    credentialID: credentialID,
                    relyingPartyID: entry.relyingPartyID,
                    userName: entry.username,
                    userHandle: userHandle
                )
                passkeyExports.append(CredentialExchangePasskeyExport(
                    title: entry.title,
                    favorite: entry.favorite,
                    credential: CredentialExchangePasskey(credential)
                ))
            } catch {
                issues.append(AppCredentialExchangeIssue(
                    error: error,
                    title: entry.title,
                    relyingPartyIdentifier: entry.relyingPartyID
                ))
            }
        }
        credentialExchange.exportIssues = issues

        let plan = CredentialExchangeCodec.exportPlan(
            loginEntries: loginEntries,
            totpEntries: totpEntries,
            passkeyExports: passkeyExports
        )
        guard !plan.isEmpty else {
            credentialExchange.exportError = "没有可导出的条目。"
            credentialExchange.exportIsFinished = true
            entryOperationState = .failed("没有可导出的条目")
            return false
        }

        do {
            let manager = ASCredentialExportManager(presentationAnchor: anchor)
            let options = try await manager.requestExport(for: nil)
            guard options.formatVersion.rawValue == CredentialExchangeFormat.supportedVersion else {
                credentialExchange.exportError = "接收方请求了不支持的版本 \(options.formatVersion.rawValue)。"
                return false
            }
            try await manager.exportCredentials(AppCredentialExchangeBridge.exportedData(from: plan))
            credentialExchange.exportMessage = "已导出 \(plan.passwordCount) 条密码、\(plan.totpCount) 条 TOTP、\(plan.passkeyCount) 条通行密钥。"
            credentialExchange.exportIsFinished = true
            if issues.isEmpty {
                credentialExchange.exportPlan = nil
            }
            entryOperationState = .idle
            return issues.isEmpty
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
        credentialExchange.exportMessage = nil
        credentialExchange.exportPasskeyCount = 0
        credentialExchange.exportIssues = []
        credentialExchange.exportIsFinished = false
        credentialExchange.isExporting = false
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
            unlockedWithDeviceOwnerAuthentication = true
            activeVaultName = session.descriptor.displayName
            activeVaultSession = session
            let entryRepository = vaultRepository.entryRepository(for: session)
            activeEntryRepository = entryRepository
            activeProject = nil
            refreshVaultFolders(entryRepository: entryRepository)
            activateInitialVaultCategoryIfNeeded(entryRepository: entryRepository)
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
            vaultRecoveryContext = nil
            vaultRecoveryHistory.recordOpened(fileURL: session.descriptor.fileURL, at: now)
        } catch {
            clearVaultAccessAfterFailure()
            vaultRecoveryContext = AppVaultRecoveryContext(
                failure: AppVaultRecoveryFailure.classify(error, stage: .keychainUnlock),
                stage: .keychainUnlock,
                fileURL: rememberedVaultDescriptor?.fileURL,
                displayName: rememberedVaultDescriptor?.displayName,
                retryMode: .keychain
            )
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

            // 归档条目不参与自动填充候选。
            let autoFillLoginEntries = loginEntries.filter { !$0.isArchived }

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
                    let indexRecords = autoFillLoginEntries.map { entry in
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
                    let secretRecords = autoFillLoginEntries.map { entry in
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
                // 守护策略只决定 Monica 自己要不要发布身份；这里永远不可能在锁定时走到
                // （上面已经要求 vaultState == .unlocked 且有 activeVaultSession）。
                let publishDecision = autoFillGuardPolicy.publishDecision(
                    vaultIsUnlocked: vaultState == .unlocked,
                    unlockedWithBiometrics: unlockedWithDeviceOwnerAuthentication
                )
                switch publishDecision {
                case .allowed:
                    let identities = autoFillLoginEntries.flatMap { entry in
                        autoFillCredentialIdentities(for: entry)
                    }
                    let passkeyIdentities = passkeyEntries.compactMap { entry in
                        autoFillPasskeyCredentialIdentity(for: entry)
                    }
                    autoFillCredentialIdentityStore.replaceCredentialIdentities(
                        identities,
                        passkeyIdentities: passkeyIdentities
                    )
                    autoFillGuardBlockedReason = nil
                case .blocked(let reason):
                    autoFillGuardBlockedReason = reason
                    autoFillPublishLogStore.recordSkip(
                        reason: reason.skipReasonText,
                        at: updatedAt
                    )
                }
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
        let entry = registerVaultInRegistry(session)
        let displayName = entry?.displayName ?? session.descriptor.displayName
        let descriptor = LocalVaultDescriptor(
            fileURL: session.descriptor.fileURL,
            displayName: displayName
        )
        rememberedVaultDescriptor = descriptor
        rememberedVaultID = session.handle.vaultID
        activeVaultName = displayName
        activeVaultSession = LocalVaultSession(
            descriptor: descriptor,
            handle: session.handle,
            state: session.state
        )
        pendingVaultCreationName = nil
        try? rememberedVaultStore.save(
            RememberedVaultRecord(
                fileURL: descriptor.fileURL,
                displayName: displayName,
                vaultID: session.handle.vaultID
            )
        )
    }

    /// 当前记住的库身份（路径 + 显示名 + MDBX 库 ID），供多库逻辑读写。
    var rememberedVaultIdentity: (fileURL: URL, displayName: String, vaultID: String)? {
        guard let descriptor = rememberedVaultDescriptor, let rememberedVaultID else {
            return nil
        }
        return (descriptor.fileURL, descriptor.displayName, rememberedVaultID)
    }

    var rememberedVaultFileURL: URL? {
        rememberedVaultDescriptor?.fileURL
    }

    /// 只改写「上次打开库」指针，不碰任何密钥材料。
    func storeRememberedVault(fileURL: URL, displayName: String, vaultID: String) {
        rememberedVaultDescriptor = LocalVaultDescriptor(fileURL: fileURL, displayName: displayName)
        rememberedVaultID = vaultID
        try? rememberedVaultStore.save(
            RememberedVaultRecord(
                fileURL: fileURL,
                displayName: displayName,
                vaultID: vaultID
            )
        )
    }

    func discardRememberedVault() {
        rememberedVaultDescriptor = nil
        rememberedVaultID = nil
        try? rememberedVaultStore.delete()
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

    /// 保险库锁定或解锁失败时的守护动作：按策略清空已发布到系统的身份条目。
    ///
    /// 只影响 Monica 自己的身份条目，不会改变系统自动填充来源，也读不到系统默认密码管理器是谁。
    private func autoFillGuardDidLock() {
        guard autoFillGuardPolicy.clearsPublishedIdentitiesWhenVaultLocks,
              let autoFillCredentialIdentityStore else {
            return
        }
        autoFillGuardNeedsIdentityRepublish = true
        let diagnostics = autoFillDiagnostics
        Task {
            await autoFillCredentialIdentityStore.removeAllPublishedIdentities()
            await diagnostics.refresh()
        }
    }

    /// 切换「仅在生物识别解锁后发布身份」。
    func setAutoFillGuardPublishesOnlyAfterBiometricUnlock(_ isEnabled: Bool) {
        guard autoFillGuardPolicy.publishesOnlyAfterBiometricUnlock != isEnabled else { return }
        autoFillGuardPolicy.publishesOnlyAfterBiometricUnlock = isEnabled
        autoFillGuardPolicyStore.savePolicy(autoFillGuardPolicy)
        autoFillGuardBlockedReason = nil
        // 关闭限制后立刻补一次发布，让系统凭据列表与当前解锁状态保持一致。
        if isEnabled == false, vaultState == .unlocked {
            try? refreshAutoFillEncryptedIndexIfConfigured()
        }
    }

    /// 切换「保险库锁定后清空已发布身份」。
    func setAutoFillGuardClearsIdentitiesOnLock(_ isEnabled: Bool) {
        guard autoFillGuardPolicy.clearsPublishedIdentitiesWhenVaultLocks != isEnabled else { return }
        autoFillGuardPolicy.clearsPublishedIdentitiesWhenVaultLocks = isEnabled
        autoFillGuardPolicyStore.savePolicy(autoFillGuardPolicy)
        // 开启时如果当前已锁定，残留的身份条目应立即清空（解锁后条目载入时会自动补发）。
        if isEnabled, vaultState == .locked {
            autoFillGuardDidLock()
        }
    }

    func clearUnlockedVaultSession() {
        autoFillDomainRules.detach()
        unlockedWithDeviceOwnerAuthentication = false
        autoFillGuardBlockedReason = nil
        autoFillGuardDidLock()
        clearNoteImageCache()
        vaultPassword = ""
        clearMasterPasswordChangeInput()
        vaultState = .locked
        activeVaultName = nil
        activeVaultSession = nil
        activeEntryRepository = nil
        activeProject = nil
        vaultProjects = []
        vaultFolderTree = .empty
        vaultFolderOverview = .builder(documents: [], tree: .empty)
        isVaultOverviewPresented = false
        trashMaintenance.reset()
        trashPreviewTotalCount = 0
        trashPreviewExpiredCount = 0
        trashMaintenanceMessage = nil
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
        isOtpAuthImportSheetPresented = false
        otpAuthImportInput = ""
        otpAuthImportReview = nil
        otpAuthImportFeedback = nil
        pendingOtpAuthURIAfterUnlock = nil
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
        clearAccountTemplateSession()
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

        unlockedWithDeviceOwnerAuthentication = false
        autoFillGuardBlockedReason = nil
        autoFillGuardDidLock()
        vaultState = .locked
        activeVaultName = nil
        activeEntryRepository = nil
        activeProject = nil
        vaultProjects = []
        vaultFolderTree = .empty
        vaultFolderOverview = .builder(documents: [], tree: .empty)
        isVaultOverviewPresented = false
        trashMaintenance.reset()
        trashPreviewTotalCount = 0
        trashPreviewExpiredCount = 0
        trashMaintenanceMessage = nil
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
        isOtpAuthImportSheetPresented = false
        otpAuthImportInput = ""
        otpAuthImportReview = nil
        otpAuthImportFeedback = nil
        pendingOtpAuthURIAfterUnlock = nil
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

    func clearPendingAndroidEncryptedBackup() {
        pendingAndroidEncryptedBackupData = nil
        pendingAndroidEncryptedBackupFileName = nil
        androidBackupDecryptPassword = ""
    }

    private func clearExtendedParityEntries() {
        sshKeyEntries = []
        deletedSshKeyEntries = []
        sshKeySearchQuery = ""
        showFavoriteSshKeyEntriesOnly = false
        sshKeyPrivateKeyReference = ""
        clearEditingSshKeyEntry()
        gpgKeyEntries = []
        deletedGPGKeyEntries = []
        gpgKeySearchQuery = ""
        showFavoriteGPGKeyEntriesOnly = false
        resetGPGKeyImportState()
        clearEditingGPGKeyEntry()
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
        barcodeEntries = []
        deletedBarcodeEntries = []
        barcodeSearchQuery = ""
        showFavoriteBarcodeEntriesOnly = false
        barcodePayload = ""
        clearEditingBarcodeEntry()
        sendEntries = []
        deletedSendEntries = []
        sendSearchQuery = ""
        showFavoriteSendEntriesOnly = false
        sendBody = ""
        clearEditingSendEntry()
        steamEntries = []
        deletedSteamEntries = []
        steamSearchQuery = ""
        showFavoriteSteamEntriesOnly = false
        steamSharedSecret = ""
        steamImportInput = ""
        clearEditingSteamEntry()
        attachmentEntries = []
        deletedAttachmentEntries = []
        attachmentSearchQuery = ""
        dismissAttachmentQuickLookPreview()
        billingAddressEntries = []
        deletedBillingAddressEntries = []
        billingAddressSearchQuery = ""
        showFavoriteBillingAddressEntriesOnly = false
        clearEditingBillingAddressEntry()
        paymentAccountEntries = []
        deletedPaymentAccountEntries = []
        paymentAccountSearchQuery = ""
        showFavoritePaymentAccountEntriesOnly = false
        clearEditingPaymentAccountEntry()
    }

    func requireActiveVaultSession() throws -> LocalVaultSession {
        guard vaultState == .unlocked,
              let activeVaultSession else {
            throw AppWebDAVBackupError.vaultLocked
        }
        return activeVaultSession
    }

    func activateVaultCategory(
        _ project: LocalVaultProject,
        entryRepository: LocalVaultEntryRepository
    ) throws {
        activeProject = project
        try refreshAllEntryLists(projectID: project.id, entryRepository: entryRepository)
        runTrashAutoPurge(projectID: project.id, entryRepository: entryRepository)
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
        let project = try createOrReuseVaultProject(title: projectTitle, entryRepository: entryRepository)
        activeProject = project
        if !vaultProjects.contains(where: { $0.id == project.id }) {
            vaultProjects.append(project)
        }
        return project
    }

    func createCSVImportedItem(
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
        case .barcode(let draft):
            return try entryRepository.createBarcodeEntry(projectID: projectID, draft: draft).id
        case .send(let draft):
            return try entryRepository.createSendEntry(projectID: projectID, draft: draft).id
        case .steam(let draft):
            return try entryRepository.createSteamEntry(projectID: projectID, draft: draft).id
        case .billingAddress(let draft):
            return try entryRepository.createBillingAddressEntry(projectID: projectID, draft: draft).id
        case .paymentAccount(let draft):
            return try entryRepository.createPaymentAccountEntry(projectID: projectID, draft: draft).id
        }
    }

    func deleteCSVImportedItem(
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
        case .barcode:
            try entryRepository.deleteBarcodeEntry(projectID: projectID, entryID: entryID)
        case .send:
            try entryRepository.deleteSendEntry(projectID: projectID, entryID: entryID)
        case .steam:
            try entryRepository.deleteSteamEntry(projectID: projectID, entryID: entryID)
        case .billingAddress:
            try entryRepository.deleteBillingAddressEntry(projectID: projectID, entryID: entryID)
        case .paymentAccount:
            try entryRepository.deletePaymentAccountEntry(projectID: projectID, entryID: entryID)
        }
    }

    /// 解锁 / 切换分类后同步删除时间账本，并按保留策略静默清理已到期条目。
    /// 只处理仓库确认仍在删除态的条目，失败时保留条目并提示原因。
    private func runTrashAutoPurge(
        projectID: String,
        entryRepository: LocalVaultEntryRepository
    ) {
        guard let session = activeVaultSession,
              trashMaintenance.prepareIfNeeded(vaultID: session.handle.vaultID) else {
            return
        }
        trashRetentionPolicy = trashMaintenance.policy
        try? trashMaintenance.sync(projectID: projectID, repository: entryRepository)
        refreshTrashPreviewFromLoadedLists()
        let outcome = trashMaintenance.autoPurgeIfNeeded(
            projectID: projectID,
            repository: entryRepository
        )
        guard outcome.purgedCount > 0 || outcome.hasFailures else {
            return
        }
        try? refreshAllEntryLists(projectID: projectID, entryRepository: entryRepository)
        applyTrashPurgeOutcome(outcome, isAutomatic: true)
    }

    func refreshAllEntryLists(
        projectID: String,
        entryRepository: LocalVaultEntryRepository
    ) throws {
        loginEntries = try entryRepository.listLoginEntries(projectID: projectID)
        deletedLoginEntries = try entryRepository.listDeletedLoginEntries(projectID: projectID)
            .filter { !trashMaintenance.isPurged($0.id) }
        noteEntries = try entryRepository.listNoteEntries(projectID: projectID)
        deletedNoteEntries = try entryRepository.listDeletedNoteEntries(projectID: projectID)
            .filter { !trashMaintenance.isPurged($0.id) }
        totpEntries = try entryRepository.listTotpEntries(projectID: projectID)
        deletedTotpEntries = try entryRepository.listDeletedTotpEntries(projectID: projectID)
            .filter { !trashMaintenance.isPurged($0.id) }
        cardEntries = try entryRepository.listCardEntries(projectID: projectID)
        deletedCardEntries = try entryRepository.listDeletedCardEntries(projectID: projectID)
            .filter { !trashMaintenance.isPurged($0.id) }
        identityEntries = try entryRepository.listIdentityEntries(projectID: projectID)
        deletedIdentityEntries = try entryRepository.listDeletedIdentityEntries(projectID: projectID)
            .filter { !trashMaintenance.isPurged($0.id) }
        passkeyEntries = try entryRepository.listPasskeyEntries(projectID: projectID)
        deletedPasskeyEntries = try entryRepository.listDeletedPasskeyEntries(projectID: projectID)
            .filter { !trashMaintenance.isPurged($0.id) }
        sshKeyEntries = try entryRepository.listSshKeyEntries(projectID: projectID)
        deletedSshKeyEntries = try entryRepository.listDeletedSshKeyEntries(projectID: projectID)
            .filter { !trashMaintenance.isPurged($0.id) }
        gpgKeyEntries = try entryRepository.listGPGKeyEntries(projectID: projectID)
        deletedGPGKeyEntries = try entryRepository.listDeletedGPGKeyEntries(projectID: projectID)
            .filter { !trashMaintenance.isPurged($0.id) }
        apiTokenEntries = try entryRepository.listApiTokenEntries(projectID: projectID)
        deletedApiTokenEntries = try entryRepository.listDeletedApiTokenEntries(projectID: projectID)
            .filter { !trashMaintenance.isPurged($0.id) }
        wifiEntries = try entryRepository.listWifiEntries(projectID: projectID)
        deletedWifiEntries = try entryRepository.listDeletedWifiEntries(projectID: projectID)
            .filter { !trashMaintenance.isPurged($0.id) }
        ssoEntries = try entryRepository.listSSOEntries(projectID: projectID)
        deletedSSOEntries = try entryRepository.listDeletedSSOEntries(projectID: projectID)
            .filter { !trashMaintenance.isPurged($0.id) }
        barcodeEntries = try entryRepository.listBarcodeEntries(projectID: projectID)
        deletedBarcodeEntries = try entryRepository.listDeletedBarcodeEntries(projectID: projectID)
            .filter { !trashMaintenance.isPurged($0.id) }
        sendEntries = try entryRepository.listSendEntries(projectID: projectID)
        deletedSendEntries = try entryRepository.listDeletedSendEntries(projectID: projectID)
            .filter { !trashMaintenance.isPurged($0.id) }
        steamEntries = try entryRepository.listSteamEntries(projectID: projectID)
        deletedSteamEntries = try entryRepository.listDeletedSteamEntries(projectID: projectID)
            .filter { !trashMaintenance.isPurged($0.id) }
        attachmentEntries = try entryRepository.listAttachmentMetadata(projectID: projectID)
        deletedAttachmentEntries = try entryRepository.listDeletedAttachmentMetadata(projectID: projectID)
            .filter { !trashMaintenance.isPurged($0.id) }
        billingAddressEntries = try entryRepository.listBillingAddressEntries(projectID: projectID)
        deletedBillingAddressEntries = try entryRepository.listDeletedBillingAddressEntries(projectID: projectID)
            .filter { !trashMaintenance.isPurged($0.id) }
        paymentAccountEntries = try entryRepository.listPaymentAccountEntries(projectID: projectID)
        deletedPaymentAccountEntries = try entryRepository.listDeletedPaymentAccountEntries(projectID: projectID)
            .filter { !trashMaintenance.isPurged($0.id) }
        refreshVaultTags()
        publishWidgetSnapshots()
        refreshVaultSearchIndex(entryRepository: entryRepository)
        // 锁定清空过系统身份时，条目重新载入后就补一次发布，避免解锁后自动填充一直为空。
        if autoFillGuardNeedsIdentityRepublish, vaultState == .unlocked {
            autoFillGuardNeedsIdentityRepublish = false
            try? refreshAutoFillEncryptedIndexIfConfigured()
        }
    }

    // MARK: - 全局搜索（解锁会话内存索引）

    /// 从仓库读取全部保险箱的非敏感元数据，重建跨类型搜索索引。
    ///
    /// 只投影标题 / 账号 / 网址 / 备注等元数据；密码、TOTP 密钥、私钥、
    /// 卡号等 secret 字段在投影时即被丢弃。索引只存在于解锁会话内存中，
    /// 锁库时由 `clearVaultSearchIndex()` 清空，不写入任何持久化存储。
    func refreshVaultSearchIndex(entryRepository: LocalVaultEntryRepository) {
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
            snapshot.gpgKeyEntries += (try? entryRepository.listGPGKeyEntries(projectID: projectID)) ?? []
            snapshot.deletedGPGKeyEntries += (try? entryRepository.listDeletedGPGKeyEntries(projectID: projectID)) ?? []
            snapshot.apiTokenEntries += (try? entryRepository.listApiTokenEntries(projectID: projectID)) ?? []
            snapshot.deletedApiTokenEntries += (try? entryRepository.listDeletedApiTokenEntries(projectID: projectID)) ?? []
            snapshot.wifiEntries += (try? entryRepository.listWifiEntries(projectID: projectID)) ?? []
            snapshot.deletedWifiEntries += (try? entryRepository.listDeletedWifiEntries(projectID: projectID)) ?? []
            snapshot.sendEntries += (try? entryRepository.listSendEntries(projectID: projectID)) ?? []
            snapshot.deletedSendEntries += (try? entryRepository.listDeletedSendEntries(projectID: projectID)) ?? []
            snapshot.steamEntries += (try? entryRepository.listSteamEntries(projectID: projectID)) ?? []
            snapshot.deletedSteamEntries += (try? entryRepository.listDeletedSteamEntries(projectID: projectID)) ?? []
            snapshot.attachmentEntries += (try? entryRepository.listAttachmentMetadata(projectID: projectID)) ?? []
            snapshot.deletedAttachmentEntries += (try? entryRepository.listDeletedAttachmentMetadata(projectID: projectID)) ?? []
            snapshot.billingAddressEntries += (try? entryRepository.listBillingAddressEntries(projectID: projectID)) ?? []
            snapshot.deletedBillingAddressEntries += (try? entryRepository.listDeletedBillingAddressEntries(projectID: projectID)) ?? []
            snapshot.paymentAccountEntries += (try? entryRepository.listPaymentAccountEntries(projectID: projectID)) ?? []
            snapshot.deletedPaymentAccountEntries += (try? entryRepository.listDeletedPaymentAccountEntries(projectID: projectID)) ?? []
        }

        snapshot.deletedLoginEntries = snapshot.deletedLoginEntries.filter { !trashMaintenance.isPurged($0.id) }
        snapshot.deletedNoteEntries = snapshot.deletedNoteEntries.filter { !trashMaintenance.isPurged($0.id) }
        snapshot.deletedTotpEntries = snapshot.deletedTotpEntries.filter { !trashMaintenance.isPurged($0.id) }
        snapshot.deletedCardEntries = snapshot.deletedCardEntries.filter { !trashMaintenance.isPurged($0.id) }
        snapshot.deletedIdentityEntries = snapshot.deletedIdentityEntries.filter { !trashMaintenance.isPurged($0.id) }
        snapshot.deletedPasskeyEntries = snapshot.deletedPasskeyEntries.filter { !trashMaintenance.isPurged($0.id) }
        snapshot.deletedSshKeyEntries = snapshot.deletedSshKeyEntries.filter { !trashMaintenance.isPurged($0.id) }
        snapshot.deletedApiTokenEntries = snapshot.deletedApiTokenEntries.filter { !trashMaintenance.isPurged($0.id) }
        snapshot.deletedWifiEntries = snapshot.deletedWifiEntries.filter { !trashMaintenance.isPurged($0.id) }
        snapshot.deletedSendEntries = snapshot.deletedSendEntries.filter { !trashMaintenance.isPurged($0.id) }
        snapshot.deletedSteamEntries = snapshot.deletedSteamEntries.filter { !trashMaintenance.isPurged($0.id) }
        snapshot.deletedAttachmentEntries = snapshot.deletedAttachmentEntries.filter { !trashMaintenance.isPurged($0.id) }

        let documents = VaultSearchDocumentBuilder.documents(from: snapshot, usage: vaultSearchUsage())
        vaultSearch.replaceDocuments(documents)
        vaultFolderOverview = VaultFolderOverview.builder(documents: documents, tree: vaultFolderTree)
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
        vaultFolderOverview = .builder(documents: [], tree: .empty)
    }

    func clearAllEntryLists() {
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
        billingAddressEntries = []
        deletedBillingAddressEntries = []
        paymentAccountEntries = []
        deletedPaymentAccountEntries = []
        clearExtendedParityEntries()
    }

    func replaceVaultFile(at destinationURL: URL, with data: Data) throws {
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

    func sanitizedAttachmentPreviewFileName(_ value: String) -> String {
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

    private func clearOperationTimelineEvents() {
        operationTimelineEvents = []
        nextOperationTimelineEventSequence = 0
        operationTimelineStore.saveEvents([])
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

    func clearEditingNoteEntry() {
        editingNoteEntryID = nil
        editingNoteTitle = ""
        editingNoteBody = ""
        editingNoteFavorite = false
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
        editingCardIBAN = ""
        editingCardSwiftCode = ""
        editingCardBillingAddress = ""
        editingCardArtwork = ""
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

    func clearEditingBarcodeEntry() {
        editingBarcodeEntryID = nil
        editingBarcodeTitle = ""
        editingBarcodeSymbology = .qr
        editingBarcodePayload = ""
        editingBarcodeLabel = ""
        editingBarcodeNotes = ""
        editingBarcodeFavorite = false
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

    func normalizedPasskeyRelyingPartyID(_ value: String) throws -> String {
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

// MARK: - #27 文件夹锚点存储

/// 文件夹索引锚点落在 App 支持目录下的独立命名空间文件里。
///
/// 文件内容只有一个随机 UUID（锚点 project 的 id），不含任何用户内容；
/// 文件夹名与层级仍然只存在于 MDBX 的加密侧表里。
private func appDefaultVaultFolderAnchorStore() -> any VaultFolderAnchorStore {
    guard let supportURL = try? FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    ) else {
        return InMemoryVaultFolderAnchorStore()
    }
    return FileVaultFolderAnchorStore(directoryURL: supportURL)
}
