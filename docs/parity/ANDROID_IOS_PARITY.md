# Android 与 iOS 功能对齐总览

- **Android 基线**：`monica-android/main` @ `e63d0cead`（`fix(android): require device credentials for password recovery [skip ci]`），只读快照路径 `/tmp/android-main/Monica for Android/`。
- **iOS 基线**：`origin/main` @ `90b3164`（`Merge remote-tracking branch 'origin/fix/71-widget-reload' into local-main`）。
- **方法**：两端都从源码、Manifest/Info.plist、导航图与数据模型枚举能力，不采信 README 或历史 issue 状态；每条结论给出 `path:line`。iOS “缺失”结论另见附录 A 的 grep 证据。
- **状态图例**：✅ 已对齐（能力存在且主流程可用）；🟡 部分对齐（有数据/入口但能力不完整）；❌ 缺失（Android 有、iOS 无对应实现）；⛔ 平台不可实现（受 iOS 公共 API/系统策略限制）。

> 说明：Android 仓库当前检出目录（`d4b30488e`）落后于真正的 `monica-android/main`，本文件所有 Android 证据均来自上面声明的快照，因此不会把“旧检出里没有”误判为“Android 没有”。

---

## 1. 能力域总览

| # | 能力域 | Android（main@e63d0ce） | iOS（origin/main@90b3164） | 结论与一句话说明 |
|---|--------|--------------------------|------------------------------|------------------|
| 1 | 保险库与存储 | ✅ Room 本地库 + 多 MDBX 库 + 多 KeePass 库 + Bitwarden 快照；`data/PasswordEntry.kt:28`、`data/SecureItem.kt:28`、`data/LocalMdbxDatabase.kt:205`、`data/LocalKeePassDatabase.kt:330`、`repository/MdbxVaultStore.kt:390` | 🟡 单个活动 MDBX 库 + 扁平项目分组 + KeePass 只读导入/回写 + Bitwarden 快照；`App/MonicaApp/AppRootView.swift:5298`、`:5350`、`SwiftPackages/MonicaStorage/Sources/MonicaStorage/MonicaStorage.swift:8418`、`:9761` | iOS 没有多库切换/默认库、嵌套文件夹与统一保险库总览。 |
| 2 | 条目类型 | ✅ `ItemType` 7 类，另有登录、Passkey、Wi-Fi、SSH、API Token、Send、附件、条码、GPG、Steam 等扩展；`data/SecureItem.kt:107`、`data/model/SecureItemModels.kt:11`、`:24`、`:57`、`:329`、`:393` | 🟡 `UnifiedVaultItemKind` 11 类；编辑器字段明显少于模型；`SwiftPackages/MonicaStorage/Sources/MonicaStorage/MonicaStorage.swift:5820`、`App/MonicaApp/AndroidParityVaultHomeView.swift:1724`、`:1878` | iOS 缺条码/登机牌、GPG、账单地址、支付方式/加密钱包、Steam 账号；卡片/证件字段也不完整。 |
| 3 | TOTP / 2FA | ✅ 5 种 OTP（TOTP/HOTP/Steam/Yandex/MOTP）+ 周期/位数/算法/计数器 + 高级编辑；`data/model/SecureItemModels.kt:11`、`:24`、`ui/screens/AddEditTotpScreen.kt:102` | 🟡 只有标准 TOTP；模型有 period/digits/algorithm/otpType/counter，但表单不暴露；`SwiftPackages/MonicaStorage/Sources/MonicaStorage/MonicaStorage.swift:8537`、`App/MonicaApp/AndroidParityVaultHomeView.swift:2012`、`SwiftPackages/MonicaCore/Sources/MonicaCore/MonicaCore.swift:447` | iOS 缺 HOTP/Steam/Yandex/MOTP 生成与高级参数 UI；Steam 仅 maFile 导入。 |
| 4 | 自动填充 | ✅ AutofillService + 无障碍服务 + 输入法 + QS Tile + 保存/更新 + OTP 通知；`AndroidManifest.xml`、`autofill_ng/MonicaAutofillServiceNg.kt:69`、`service/MonicaAccessibilityService.kt:50`、`ime/MonicaInputMethodService.kt:75`、`autofill_ng/service/AutofillTileService.kt:15` | 🟡 仅 ASCredentialProvider：密码列表、保存、Passkey、CXF；`Extensions/MonicaAutoFillExtension/AutoFillCredentialProviderViewController.swift:38`、`:172`、`App/MonicaApp/AppRootView.swift:1075` | iOS 只能在系统自动填充场景填充用户名/密码；不能任意字段、内联建议、IME 填充或接管默认密码管理器。 |
| 5 | 搜索与组织 | ✅ 跨库搜索、快速筛选、标签、排序、归档、嵌套文件夹、保险库总览、最近/常用；`ui/vaultv2/VaultV2Pane.kt:1636`、`ui/vaultv2/VaultOverviewContent.kt:25`、`data/PasswordEntry.kt:42`、`:124`、`:82`、`data/model/SecureItemModels.kt:396` | 🟡 分类型搜索、收藏、项目分组、快速筛选、批量选择、回收站；`App/MonicaApp/AndroidParityVaultHomeView.swift:748`、`:826`、`App/MonicaApp/AppRootView.swift:3918`、`:4036`、`:4043` | iOS 缺全局跨类型搜索、标签、手动排序、归档、最近使用/快速访问、嵌套文件夹。 |
| 6 | 导入 / 导出 | ✅ CSV 全家桶、Bitwarden JSON（明文/加密）、Aegis、KeePass CSV、Proton Pass、Chrome、Android 备份、KDBX；`ui/screens/ImportDataScreen.kt:114-115`、`:130-132`、`:135-136`、`:142`、`ui/screens/ExportDataScreen.kt:68`、`:233` | 🟡 自有 CSV、Android 备份、KDBX 只读导入、Bitwarden 快照、CXF（仅密码+TOTP）；`SwiftPackages/MonicaStorage/Sources/MonicaStorage/MonicaStorage.swift:7256`、`:7297`、`App/MonicaApp/AppCredentialExchange.swift:89` | iOS 的自有 CSV 强制 `kind` 列，无法直接吃 1Password/Chrome/Bitwarden/Aegis 等常见导出。 |
| 7 | 同步与备份 | ✅ MDBX WebDAV/OneDrive 云端库、KeePass WebDAV/OneDrive 远程库、LAN/热点同步、Bitwarden 同步、WorkManager 自动备份；`ui/screens/MdbxManagerScreen.kt:138`、`ui/screens/LocalKeePassScreen.kt:105`、`lansync/DeviceSyncCoordinator.kt:47`、`workers/AutoBackupWorker.kt:38`、`ui/screens/SyncBackupScreen.kt:29` | 🟡 WebDAV/OneDrive 手动云库同步、LAN 同步、Bitwarden 同步、后台 WebDAV/OneDrive 备份、KeePass 一次性导入/回写；`App/MonicaApp/AppCloudVaultSync.swift:73`、`App/MonicaApp/AppLanSyncCoordinator.swift:219`、`App/MonicaApp/AppRootView.swift:809`、`App/MonicaApp/SettingsRootView.swift:705` | iOS 的 MDBX 云同步需手动触发；KeePass 没有持续云端库会话；后台任务由系统机会式调度。 |
| 8 | 安全与隐私 | ✅ 主密码、PBKDF2 密保答案、FLAG_SECURE 截屏保护、剪贴板自动清除、HIBP 泄露检查、无 2FA/重复 URL 分析；`security/SecurityAnswerHash.kt:9`、`utils/ScreenshotProtectionUtil.kt:20`、`utils/ClipboardUtils.kt`、`utils/PwnedPasswordsChecker.kt:27`、`viewmodel/SecurityAnalysisViewModel.kt:456` | 🟡 主密码、PBKDF2/Argon2 验证器、隐私遮罩（非阻断）、弱密码/复用/重复项；`SwiftPackages/MonicaSecurity/Sources/MonicaSecurity/SecurityQuestionAnswerCredential.swift:55`、`App/MonicaApp/AppRootView.swift:4528`、`:2288` | iOS 的泄露检查指纹集从未被填充（实际不生效）；无剪贴板清除、无 2FA 缺失/重复 URL 分析；截屏只能遮罩不能阻止。 |
| 9 | UI / 主题 | ✅ 主题色/自定义配色/应用图标/页面与卡片布局/字段自定义/界面缩放/应用内语言；`ui/screens/ColorSchemeSelectionScreen.kt:37`、`ui/screens/CustomColorSettingsScreen.kt:117`、`ui/screens/AppLauncherIconSettings.kt:34`、`ui/screens/PageAdjustmentCustomizationScreen.kt:87`、`ui/screens/PasswordFieldCustomizationScreen.kt:42`、`ui/screens/LanguageSelectionDialog.kt:75` | 🟡 系统/浅色/深色、4 个强调色、图标风格、界面密度、4 个模块的显示/排序、卡片密度/字段显隐；`App/MonicaApp/AppRootView.swift:375`、`:429`、`:4102` | iOS 无应用图标选择、无自定义配色/卡片/字段布局、无底部导航编辑、无应用内语言切换。 |
| 10 | 扩展 / 小组件 | 🟡 QS Tile、启动器别名、应用快捷方式；`autofill_ng/service/AutofillTileService.kt:15`、`AndroidManifest.xml`（activity-alias）、`receiver/LauncherEntryRepairReceiver.kt:14` | ✅ WidgetKit 小组件、控制中心控件、分享扩展、自动填充扩展、App Intents；`Extensions/MonicaWidgetExtension/MonicaWidget.swift:117`、`MonicaControlCenterWidget.swift:16`、`Extensions/MonicaShareExtension/ShareViewController.swift:4`、`App/MonicaApp/MonicaShortcutsAppIntents.swift:23` | 两端各有对方没有的扩展形态；iOS 控制中心控件需要 iOS 18，而部署目标是 iOS 17。 |
| 11 | 开发者 / 诊断 | ✅ 开发者设置、日志、预览功能开关、更新日志；`ui/screens/DeveloperSettingsScreen.kt:85`、`ui/screens/DeveloperLogsScreen.kt:77`、`ui/screens/SettingsScreen.kt:423` | ❌ 无开发者日志/预览功能开关；`App/MonicaApp/SettingsRootView.swift` 中无对应 section | iOS 缺可观测性与灰度开关，排障只能依赖系统日志/TestFlight。 |
| 12 | 变现 / 支持 | ✅ Monica Plus 页、支付页（爱发电）、支持作者；`ui/screens/MonicaPlusScreen.kt:23`、`ui/screens/PaymentScreen.kt:35`（`:191` 爱发电）、`ui/screens/SupportAuthorScreen.kt:39` | 🟡 仅资源解锁式 Plus 权益，无购买/赞助入口；`App/MonicaApp/SettingsRootView.swift:359`、`App/MonicaApp/AppRootView.swift:179`、`:183`、`:4283` | iOS 没有 StoreKit 内购，也没有爱发电/赞助链接；Plus 仅靠外部资源解锁。 |
| 13 | 发布 / 运维 | ✅ fastlane、应用内更新检查与 APK 安装、Baseline Profile；`update/AppUpdateController.kt:26`、`update/AppUpdateDialog.kt:33`、`fastlane/`、`baselineprofile/` | 🟡 GitHub Actions CI、App Store/TestFlight 发布，无应用内更新检查；`.github/workflows/ci.yml` | iOS 不允许自更新；只能跳转 App Store，更新提示能力缺位。 |

---

## 2. 条目类型逐项矩阵

| 条目类型 | Android 证据 | iOS 实现（精确符号/文件） | 结论 |
|----------|---------------|----------------------------|------|
| 登录 | `data/PasswordEntry.kt:28`；`ui/screens/AddEditPasswordScreen.kt:293`；字段含 website/username/password/email/phone/address/appPackageName/appName/sso*/wifiMetadata | `UnifiedVaultItemKind.login`（`MonicaStorage.swift:5820`）；`LocalLoginEntry`（`:8440`）；`AddEditVaultItemView.loginFields`（`AndroidParityVaultHomeView.swift:1975`）；列表 `AndroidPasswordListCard`（`:1282`） | 🟡 基础字段可用；“多 URL/绑定应用/登录方式”在 UI 中是空按钮或 `selection: .constant(0)`，未落库。 |
| 安全笔记 | `data/model/SecureItemModels.kt:393`（`NoteData`：content/tags/isMarkdown/customFields）；`ui/screens/AddEditNoteScreen.kt:134` | `UnifiedVaultItemKind.note`；`LocalNoteEntry`（`MonicaStorage.swift:8481`）；`noteFields`（`AndroidParityVaultHomeView.swift:2000`）；`AndroidNoteListCard`（`:1484`） | 🟡 只有标题+纯文本 `TextEditor`；无 Markdown、标签、自定义字段、内嵌图片。 |
| TOTP | `data/model/SecureItemModels.kt:11`、`:24`；`ui/screens/AddEditTotpScreen.kt:102` | `.totp`；`LocalTotpEntry`（`MonicaStorage.swift:8537`）；`totpFields`（`AndroidParityVaultHomeView.swift:2012`）；`TotpGenerator`（`MonicaCore.swift:447`） | 🟡 标准 TOTP 可用；HOTP/Steam/Yandex/MOTP、周期/位数/算法 UI 缺失。 |
| 银行卡 | `data/model/SecureItemModels.kt:57`（`BankCardData`）；`ui/screens/AddEditBankCardScreen.kt:105` | `.card`；`LocalCardEntry`（`MonicaStorage.swift:8614`）；`cardFields`（`AndroidParityVaultHomeView.swift:2026`）；`AndroidBankCardListCard`（`:1408`） | 🟡 仅卡号/持卡人/有效期/CVV/银行/网络；无账单地址、卡面、昵称、IBAN/SWIFT、卡类型。 |
| 证件 / 护照 | `data/model/SecureItemModels.kt:329`、`:373`；`ui/screens/AddEditDocumentScreen.kt:93` | `.identity`；`LocalIdentityEntry`（`MonicaStorage.swift:8691`）；`identityFields`（`AndroidParityVaultHomeView.swift:2041`）；`AndroidIdentityListCard`（`:1459`） | 🟡 只有类型/姓名/号码/签发国；签发日/到期日模型有、表单未暴露；地址、SSN、护照/驾照号等缺失。 |
| 条码 / 登机牌 | `data/model/SecureItemModels.kt:370`（`boardingPassBarcode`）；`data/model/BarcodeEntryExtensions.kt:7`；`ui/screens/BarcodeDetailScreen.kt:66`（ZXing，QR/CODE_128） | 无 `Barcode`/`BoardingPass` 类型；`UnifiedVaultItemKind`（`MonicaStorage.swift:5820`）无对应 case；grep `Barcode`/`BoardingPass` = 0 | ❌ 缺失。 |
| SSH 密钥 | `ui/screens/AddEditSshKeyScreen.kt:115`；`data/model/SshKeyModels.kt:10`；`ui/screens/SshKeyDetailScreen.kt:80` | `.sshKey`；`LocalSshKeyEntry`（`MonicaStorage.swift:8833`）；`sshKeyFields`（`AndroidParityVaultHomeView.swift:2063`）；`AndroidSshKeyListCard`（`:1561`） | 🟡 可存公钥/私钥引用/主机/口令提示；无生成器、无 known_hosts/agent 能力。 |
| Wi-Fi | `ui/screens/AddEditWifiScreen.kt:108`；`data/model/WifiData.kt:20` | `.wifi`；`LocalWifiEntry`（`MonicaStorage.swift:8960`）；`wifiFields`（`AndroidParityVaultHomeView.swift:2087`）；`AndroidWifiListCard`（`:1589`） | ✅ SSID/安全类型/密码/隐藏/备注/二维码展示与分享可用。 |
| 账单地址 | `data/model/SecureItemModels.kt:182`（`BillingAddressData`）；`ui/screens/AddEditBillingAddressScreen.kt:94`；`ui/screens/BillingAddressDetailScreen.kt:70` | 无 `BillingAddress`（grep = 0）；`UnifiedVaultItemKind` 无 case | ❌ 缺失。 |
| 支付方式 / 加密钱包 | `data/model/SecureItemModels.kt:249`（`PaymentAccountType`，含 `CRYPTO_WALLET`）、`:259`（`PaymentAccountData`）；`ui/screens/AddEditPasswordScreen.kt` 的 wallet 路由 | 无 `PaymentAccount`（grep = 0）；无 crypto wallet 类型 | ❌ 缺失。 |
| API Token / API Key | `ui/screens/AddEditApiTokenScreen.kt`；`ui/screens/NativeApiTokensScreen.kt`；`data/model/ApiKeyEntryFields.kt` | `.apiToken`；`LocalApiTokenEntry`（`MonicaStorage.swift:8898`）；`apiTokenFields`（`AndroidParityVaultHomeView.swift:2075`）；`AndroidApiTokenListCard`（`:1575`） | ✅ 标题/签发方/账号/Token/scope/过期/备注可用。 |
| Passkey | `data/PasskeyEntry.kt`；`ui/screens/PasskeyDetailScreen.kt:57`、`PasskeyListScreen.kt:142`；`passkey/MonicaCredentialProviderService` | `.passkey`；`LocalPasskeyEntry`（`MonicaStorage.swift:8765`）；`passkeyFields`（`AndroidParityVaultHomeView.swift:2052`）；自动填充扩展 `:91`、`:597`、`:623` | ✅ 条目+系统凭据提供者已具备。 |
| Monica Send / Bitwarden Send | `ui/screens/SendScreen.kt:191`；`data/bitwarden/BitwardenSend.kt` | `.send`；`LocalSendEntry`（`MonicaStorage.swift:9044`）；`sendFields`（`AndroidParityVaultHomeView.swift:2117`）；`AppRootView.swift:11710`（Bitwarden 快照）、`SettingsRootView.swift:1442`（接收 Send） | ✅ 文本/文件 Send 与分享链接已接入。 |
| 附件 | `attachments/facade/AttachmentFacade.kt:54`；`attachments/ui/AttachmentsEditSection.kt:71`；`attachments/model/Attachment.kt:54` | `.attachmentRef`；`LocalAttachmentMetadata`（`MonicaStorage.swift:9075`）；`AndroidAttachmentListCard`（`AndroidParityVaultHomeView.swift:1617`）；编辑区只读提示 `:1884` | 🟡 列表/预览可用，但 `AddEditVaultItemView` 对该类型只显示“该类型当前只支持列表展示。”；附件编辑受 Plus 门控（`:1907-1960`）。 |
| GPG 密钥 | `ui/screens/GpgKeyScreen.kt:43`；`data/model/GpgEntryFields.kt:11`；`utils/GpgKeyGenerator.kt:1`（BouncyCastle，`app/build.gradle:377`） | 无 `Gpg`/`OpenPGP`（grep = 0） | ❌ 缺失。 |
| Steam 账号 / Steam Guard | `steam/ui/SteamScreen.kt:…`；`steam/service/SteamLoginImportService.kt`；`data/model/SecureItemModels.kt:43-48`（steam 字段） | 仅 maFile→标准 TOTP 导入：`SteamAuthenticatorImportParser`（`MonicaCore.swift:503`）、`importSteamAuthenticator`（`AppRootView.swift:6685`）；无 Steam 账号实体/登录（grep `SteamGuard` = 0） | 🟡 只能导入验证码，没有账号/登录/确认。 |
| 自定义字段 | `data/CustomField.kt:36`；`data/SecureItem.kt` 的 itemData；`ui/components/CustomFieldComponents.kt` | 仅 KeePass 只读字段 `KeePassReadOnlyCustomField`（`MonicaStorage.swift:2558`）；无本地可编辑自定义字段（grep `customField` 仅合并安全/KeePass） | ❌ 缺失（本地库）。 |
| 标签 | `data/model/SecureItemModels.kt:396`（`NoteData.tags`）；`data/PasswordEntry.kt` 的 category 体系 | 无标签模型；`tags` 仅 CXF 空数组（`AppCredentialExchange.swift:68`）与 UI 文案 | ❌ 缺失。 |

---

## 3. iOS 不可实现 / 平台差异

本节只列“Android 有明确机制、iOS 公共 API 无法等价实现”的能力。每条都给出 Android 机制（文件+API）与 iOS 约束；这些不应被当作普通 bug 排期。

### 3.1 无障碍服务自动填充与默认密码管理器接管

- **Android 机制**：`service/MonicaAccessibilityService.kt:50`（`class MonicaAccessibilityService : AccessibilityService()`），Manifest 声明 `BIND_ACCESSIBILITY_SERVICE` + `@xml/accessibility_service_config`；配合 `autofill_ng/defaultmanager/RootDefaultManager.kt:10`、`ShizukuDefaultManager.kt:26` 与 `autofill_ng/privilege/PrivilegeAccess.kt:18` 可在其他 App 的输入框里直接填值、切换系统默认自动填充服务，并在服务被系统杀死后拉起（`autofill_ng/protection/AutofillProtectionService.kt:24`）。
- **iOS 约束**：iOS 没有供第三方读取其他 App 视图层级的 AccessibilityService，也没有 `AutofillManager.setAutofillService()` 之类的 API。App 只能实现 `ASCredentialProviderViewController`，由系统在密码/Passkey 场景调用；无法监听其他 App 的字段、无法成为“默认密码管理器”，也无法守护/重启系统扩展。
- **结论**：⛔ 平台不可实现。iOS 侧能做的是把自动填充扩展的保存/填充体验做深，而不是复刻无障碍服务。

### 3.2 第三方输入法内直接填充密码库

- **Android 机制**：`ime/MonicaInputMethodService.kt:75`（`open class MonicaInputMethodService : InputMethodService()`），Manifest `BIND_INPUT_METHOD`、`process=":ime"`、`@xml/monica_input_method`；输入法内可搜索密码库、验证生物识别后把用户名/密码插入当前输入框（`ime/ImeUnlockActivity`、`ImeBiometricAuthActivity`）。
- **iOS 约束**：自定义键盘扩展（UIInputViewController）不能读取宿主 App 的 `UITextField` 语义/`textContentType`，也不能调用密码自动填充 API；系统不会把“当前是密码框”告知键盘扩展。键盘扩展只能向当前文本插入字符串，无法判断该不该填、填哪个字段，且 `secureTextEntry` 场景受限。
- **结论**：⛔ 平台不可实现。iOS 的等价能力是系统密码自动填充（键盘上方的 Passwords 建议），由系统控制。

### 3.3 验证器常驻通知 / 实时验证码通知

- **Android 机制**：`autofill_ng/service/AutofillOtpNotificationService.kt:54`（前台服务，`foregroundServiceType="specialUse"`，`PROPERTY_SPECIAL_USE_FGS_SUBTYPE="Displaying autofill TOTP codes in notification"`）与 `service/NotificationValidatorService.kt:42`；可常驻通知展示当前 TOTP、复制验证码，并在自动填充场景推送。
- **iOS 约束**：iOS 不允许普通 App 长期驻留后台刷新 TOTP 并更新常驻通知；`UNNotificationServiceExtension` 只处理远程推送，不能在本地定时刷新通知内容。Live Activity 面向用户可感知的持续活动（赛事/配送），不适合作为“常驻验证码”，且需要 iOS 16.1+、用户主动启用，不能保证每秒更新。
- **结论**：⛔ 平台不可实现。iOS 可做的是打开 App/小组件时显示验证码，或用户手动添加的本地通知提醒，但不是 Android 那种常驻实时码。

### 3.4 截屏 / 录屏内容阻断

- **Android 机制**：`utils/ScreenshotProtectionUtil.kt:20`（`WindowManager.LayoutParams.FLAG_SECURE`）；`MainActivity.kt:438` 与 `ui/base/BaseMonicaActivity.kt:62` 对所有 Activity 生效，设置项默认开启（`utils/SettingsManager.kt:551`）。
- **iOS 约束**：iOS 没有公开 API 能阻止截屏或录屏。`UIScreen.main.isCaptured` 只能检测“正在被镜像/录制”，`UIApplication.userDidTakeScreenshotNotification` 只能在截图发生后收到通知；两者都不能阻止内容被捕获。`PrivacyShieldView`（`App/MonicaApp/LockScreenViews.swift:5`）只能在 App 失活/后台时盖住界面，无法阻止系统截图。
- **结论**：⛔ 平台不可实现。可做的是“检测到录制时遮罩/提示”，但不能宣称防截屏。

### 3.5 运行时应用名称 / 图标“马甲”与启动器别名

- **Android 机制**：`AndroidManifest.xml` 中多个 `activity-alias`（`.ModernVisibleLauncherAlias`、`.ClassicVisibleLauncherAlias`、`.ModernVisibleLauncherAliasMonica` 等）配合 `android:label`/`android:icon`，由 `ui/screens/AppLauncherIconSettings.kt:34` 与 `receiver/LauncherEntryRepairReceiver.kt:14` 在运行时切换，实现桌面名称/图标伪装。
- **iOS 约束**：`UIApplication.setAlternateIconName` 只能切换 App 图标，不能改变桌面显示名称；显示名称来自 Info.plist/`InfoPlist.strings`，运行时不可改。iOS 也没有 activity-alias/launcher alias 概念。App Store 审核还禁止伪装/误导性名称。
- **结论**：⛔ 平台不可实现（仅能提供有限的多图标主题，名称固定）。

### 3.6 应用内检查更新与自更新（APK 安装）

- **Android 机制**：`update/AppUpdateController.kt:26`、`update/AppUpdateDialog.kt:33`、`ui/screens/SettingsScreen.kt:175`；可检查新版本、下载 APK 并触发系统安装。
- **iOS 约束**：iOS 不允许 App 下载并安装可执行代码/自更新；只能通过 App Store/TestFlight 更新。App 可以查询 App Store 的公开版本信息并提示用户，但不能在应用内完成安装。
- **结论**：⛔ 平台不可实现（可降级为“跳转 App Store 的版本提示”，价值有限）。

### 3.7 NFC 银行卡贴卡读取（EMV/PAN）

- **Android 机制**：`nfc/card/EmvCardReader.kt:9`（`class EmvCardReader`），通过 `NfcAdapter`/`IsoDep` 发送 EMV APDU，读取 `BankCard(number, expiryMonth, expiryYear, holder, scheme)`（`:14-21`），再由 `nfc/card/NfcCardDraft.kt:4` 合并进银行卡表单。
- **iOS 约束**：`SwiftPackages/MonicaCore/Sources/MonicaCore/NFCCardProbe.swift:14-20` 明确记录：`NFCTagReaderSession` 不支持选择支付类 application ID（EMV/PAN）；iOS 26 起 EU 的 `NFCPaymentTagReaderSession` 需单独申请且不向本 App 开放；因此 iOS 诊断只声明 NDEF AID、不发送 APDU，`readablePaymentCardFields` 为空。
- **结论**：⛔ 平台不可实现。iOS 的 NFC 银行卡诊断只能验证标签类型/NDEF，不能自动读卡号。

### 3.8 剪贴板自动清除（后台可靠版）

- **Android 机制**：`utils/ClipboardUtils.kt` 在复制后启动协程定时器，按 `SettingsManager.clipboardAutoClearSeconds` 清除；API 33+ 还给 `ClipData` 打 `IS_SENSITIVE`，让系统剪贴板预览脱敏；进程存活期间即使界面退到后台也能执行。
- **iOS 约束**：`UIPasteboard` 没有过期/自动清除 API；App 进入后台后很快被挂起，`Timer`/`Task` 不会继续执行，无法保证在设定秒数后清除。只能做到“App 在前台时定时清除”或“下次前台时清除”，且无法给系统剪贴板预览打敏感标记（`UIPasteboard.detectPatterns` 是检测，不是脱敏）。
- **结论**：⛔ 可靠的后台自动清除不可实现；可做前台定时清除作为降级（见 MISSING_FEATURES #9，按“可并行实现（有前台限制）”单列）。

### 3.9 控制中心/快速设置磁贴等价物

- **Android 机制**：`autofill_ng/service/AutofillTileService.kt:15`（`class AutofillTileService : TileService()`），Manifest `BIND_QUICK_SETTINGS_TILE`，可在快捷设置里一键打开自动填充/验证器。
- **iOS 约束**：iOS 18 的 ControlWidget（`Extensions/MonicaWidgetExtension/MonicaControlCenterWidget.swift:16`）只能放置一个按钮并通过 `OpenIntent` 打开 App 指定页面（`MonicaControlCenterIntents.swift:6`、`:50`），不能像 TileService 那样在被点击时就地执行任意逻辑；iOS 17 及以下完全没有控制中心控件。
- **结论**：🟡 部分等价（仅 iOS 18+ 的“打开某页”），不是功能对等。

### 3.10 后台常驻同步/守卫

- **Android 机制**：`workers/AutoBackupWorker.kt:38`（WorkManager 周期任务）、`autofill_ng/protection/AutofillProtectionService.kt:24`（前台服务守卫）、`service/MonicaAccessibilityService.kt:50` 常驻。
- **iOS 约束**：`BGTaskScheduler` 由系统机会式调度，不能保证周期/常驻；后台刷新受低电量、用户习惯、系统预算影响。自动填充扩展只在系统调用时运行，不能常驻守卫。
- **结论**：⛔ “常驻”不可实现；iOS 只能做机会式后台备份（现有 `com.monicapass.monica.backup.refresh`，`App/MonicaApp/AppRootView.swift:809`）。

---

## 附录 A：iOS “缺失”结论的 grep 证据

以下命令在 worktree 根目录执行，范围 `App/MonicaApp Extensions SwiftPackages`（仅 `.swift`）。结果中的数字为命中文件数；0 表示全仓无该符号。

| 结论 | 命令 | 结果 |
|------|------|------|
| 无条码/登机牌 | `grep -rIl --include=*.swift -E "Barcode\|BoardingPass" App Extensions SwiftPackages` | 0 |
| 无 GPG/OpenPGP | `grep -rIl --include=*.swift -E "GpgKey\|OpenPGP\|gpg" App Extensions SwiftPackages` | 0 |
| 无账单地址 | `grep -rIl --include=*.swift "BillingAddress" App Extensions SwiftPackages` | 0 |
| 无支付方式/加密钱包 | `grep -rIl --include=*.swift "PaymentAccount" App Extensions SwiftPackages` | 0 |
| 无 Steam 账号/Guard | `grep -rIl --include=*.swift -E "SteamGuard\|steamGuard" App Extensions SwiftPackages` | 0 |
| 无标签数据模型 | `grep -rn --include=*.swift "\btags\b" App Extensions SwiftPackages` | 仅 `NFCBankCardProbeView.swift:181` 的 `[NFCTag]` 参数、`AppCredentialExchange.swift:68` 的 CXF 空数组、`MonicaStorage.swift:6764` 的 CSV 表头识别；无标签字段 |
| 无归档 | `grep -rIl --include=*.swift -E "isArchived\|archivedAt" App Extensions SwiftPackages` | 0 |
| 无最近/快速访问 | `grep -rIl --include=*.swift -E "QuickAccess\|quickAccess\|最近使用\|使用频率\|usageCount" App Extensions SwiftPackages` | 0 |
| 无全局搜索（仅分类型查询） | `grep -rn --include=*.swift "searchBinding\|loginSearchQuery" App/MonicaApp` | 仅 `AndroidParityVaultHomeView.swift`（视图绑定）与 `AppRootView.swift`（按类型的 `loginSearchQuery` 等状态），无跨类型搜索 |
| 无密码历史 | `grep -rIl --include=*.swift -E "passwordHistory\|PasswordHistory" App Extensions SwiftPackages` | 0 |
| 无多 URL/应用绑定规则 | `grep -rIl --include=*.swift -E "urlRules\|appBinding" App Extensions SwiftPackages` | 0 |
| 无本地可编辑自定义字段 | `grep -rn --include=*.swift "customField" App Extensions SwiftPackages` | 仅 KeePass 只读字段（`MonicaStorage.swift:2558`）、合并安全/KeePass 导入（`AppRootView.swift:9116`、`:9478`、`:13225`）、Bitwarden 映射（`MonicaSync.swift:3683`）；本地草稿无 customFields |
| 无本地嵌套文件夹 | `grep -rn --include=*.swift -E "folderID\|parentFolder" SwiftPackages/MonicaStorage` | 0；App/Sync 的 `folderID` 是 Bitwarden folder DTO（`AppRootView.swift:11764`、`MonicaSync.swift:3548` 区域），不是本地库层级 |
| 无回收站彻底清理 | `grep -rIl --include=*.swift -E "emptyTrash\|purgeTrash" App Extensions SwiftPackages` | 0 |
| 无剪贴板自动清除 | `grep -rn --include=*.swift "UIPasteboard" App Extensions` | 仅 `AndroidParityVaultHomeView.swift:2166`、`GeneratorRootView.swift:107/210`（直接写入） |
| 无截屏阻断 API | `grep -rIl --include=*.swift -E "userDidTakeScreenshot\|isCaptured\|screenCapture" App Extensions SwiftPackages` | 0 |
| 无应用图标切换 | `grep -rIl --include=*.swift "setAlternateIconName" App Extensions SwiftPackages` | 0 |
| 无 StoreKit | `grep -rIl --include=*.swift -E "StoreKit\|Product\.purchase\|Transaction\.updates" App Extensions SwiftPackages` | 0 |
| 无开发者日志/预览开关 | `grep -rIl --include=*.swift -E "DeveloperLog\|developerLog\|previewFeature\|PreviewFeature" App Extensions SwiftPackages` | 0 |
| 无 TOTP 通知 | `grep -rn --include=*.swift -E "UNNotificationRequest\|UNMutableNotificationContent" App Extensions` | 0（仅 `AppRootView.swift:4908` 查询通知权限） |
| 无 MDBX 快照/提交历史/Tiga UI | `grep -rn --include=*.swift -E "CommitHistory|MdbxSnapshot|Tiga" App/MonicaApp SwiftPackages/MonicaStorage` | 0（MonicaMDBX 生成的 FFI 有 `MdbxTigaMode`，App/Storage 未引用） |
| 无 KeePass 原生管理器 | `grep -rIl --include=*.swift -E "KeePassNative\|createKeePassEntry\|updateKeePassGroup" App Extensions SwiftPackages` | 0 |
| 无应用内语言切换 | `grep -rIl --include=*.swift -E "AppleLanguages\|Locale\.current" App Extensions` | 0 |

> 反向核对：`QuickAccess`、`usageCount`、`isArchived`、`tags`、`Barcode` 等在 iOS 全仓为 0 或仅出现在无关上下文；`MonicaStorage.swift` 的 `sortOrder` 只用于 KeePass 只读自定义字段排序（`:2563`），不是条目手动排序。

## 附录 B：Android 侧关键证据索引

| 能力 | Android 证据 |
|------|--------------|
| 条目类型枚举 | `data/SecureItem.kt:107`（PASSWORD/TOTP/BANK_CARD/DOCUMENT/BILLING_ADDRESS/PAYMENT_ACCOUNT/NOTE） |
| 登录/银行卡/证件/笔记模型 | `data/model/SecureItemModels.kt:24`、`:57`、`:329`、`:393` |
| 归档/排序/文件夹 | `data/PasswordEntry.kt:124`、`:42`、`:82` |
| 标签 | `data/model/SecureItemModels.kt:396` |
| 自定义字段 | `data/CustomField.kt:36` |
| 密码历史 | `data/PasswordHistoryEntry.kt:31` |
| URL 规则 | `data/model/PasswordUrlRules.kt:7` |
| 保险库总览/最近使用/搜索/归档入口 | `ui/vaultv2/VaultOverviewContent.kt:25`、`:65`、`:66`；`ui/vaultv2/VaultV2Pane.kt:1636` |
| MDBX 多库/默认库/文件夹 | `data/LocalMdbxDatabase.kt:205`、`:269`、`:294`；`repository/MdbxVaultStore.kt:390`、`:481` |
| MDBX 高级（Tiga/快照/历史/冲突） | `ui/screens/MdbxManagerScreen.kt:101`、`:112`、`:156`、`:179`、`:246` |
| KeePass 原生管理/远程库 | `ui/screens/KeePassNativeManagerScreen.kt:202`；`ui/screens/LocalKeePassScreen.kt:81`、`:105-107`、`:329-345` |
| 导入格式 | `ui/screens/ImportDataScreen.kt:114-115`、`:130-132`、`:135-136`、`:142` |
| 导出格式 | `ui/screens/ExportDataScreen.kt:68`、`:233` |
| 生成器高级 | `ui/screens/GeneratorScreen.kt:121`、`:174-261`、`:1234`；`data/GeneratorPreferences.kt:22` |
| 安全分析 | `viewmodel/SecurityAnalysisViewModel.kt:339`、`:435`、`:456`；`utils/PwnedPasswordsChecker.kt:27` |
| 自动填充增强 | `autofill_ng/parser/AutofillParserNg.kt:13`；`autofill_ng/builder/StrongPasswordSuggestionPolicy.kt`；`autofill_ng/processor/AutofillProcessorNg.kt` |
| 剪贴板/截屏 | `utils/ClipboardUtils.kt`；`utils/ScreenshotProtectionUtil.kt:20`；`utils/SettingsManager.kt:184`、`:551` |
| 主题/布局/图标/语言 | `ui/screens/ColorSchemeSelectionScreen.kt:37`、`CustomColorSettingsScreen.kt:117`、`AppLauncherIconSettings.kt:34`、`PageAdjustmentCustomizationScreen.kt:87`、`PasswordFieldCustomizationScreen.kt:42`、`LanguageSelectionDialog.kt`、`SettingsScreen.kt:1726`（BottomNavSettingsScreen） |
| 开发者/更新/变现 | `ui/screens/DeveloperSettingsScreen.kt:85`、`DeveloperLogsScreen.kt:77`、`update/AppUpdateController.kt:26`、`ui/screens/MonicaPlusScreen.kt:23`、`PaymentScreen.kt:35`、`SupportAuthorScreen.kt:39` |
| 定制模板 | `ui/screens/CommonAccountTemplatesScreen.kt:111` |
