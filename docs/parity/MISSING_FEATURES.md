# Android 能力在 iOS 的缺失清单（供拆分 issue）

- **Android 基线**：`monica-android/main` @ `e63d0cead`（只读快照 `/tmp/android-main/Monica for Android/`）。
- **iOS 基线**：`origin/main` @ `90b3164`。
- **排序说明**：编号 1–28 是**可立项**差距（`可并行实现` / `需要新依赖`），按用户价值从高到低排列，适合直接按顺序转成 issue；编号 29–36 是 `iOS 不可实现` 的平台差异，单独放在末尾，避免污染可执行排期。两部分内部同样按用户价值排序。
- **去重原则**：每条只覆盖一个可独立验收的能力；与已实现能力的“增强”会写明现状，避免与现有 issue 重复。
- **不列入**：已确认在 iOS 存在的能力（如 Bitwarden 同步、LAN 同步、WebDAV/OneDrive 备份、附件、Passkey 提供者、操作时间线、密保问题 PBKDF2）以及 Android 自己也未启用的能力（如 KeePass Google Drive，`ui/screens/LocalKeePassScreen.kt:73 GOOGLE_DRIVE_ENTRY_ENABLED = false`）。

---

## 一、可立项差距（1–28）

### 1. 登录条目增强：多 URL、应用绑定与密码历史

- **分类**：可并行实现
- **Android 证据**：`data/PasswordEntry.kt:28`（website/username/password/notes 等字段）、`:99`（`ssoProvider`）、`:159`（`isSsoLogin`）；`data/model/PasswordUrlRules.kt:7`（多 URL 规则）；`data/PasswordHistoryEntry.kt:31`（密码历史）；编辑入口 `ui/screens/AddEditPasswordScreen.kt:293`。
- **iOS 现状**：`LocalLoginEntry` 只有 title/username/password/url/notes/favorite/projectID（`SwiftPackages/MonicaStorage/Sources/MonicaStorage/MonicaStorage.swift:8440`）；表单 `AddEditVaultItemView.loginFields` 里的“+ 添加 URL”“绑定应用”是空 action（`App/MonicaApp/AndroidParityVaultHomeView.swift:1975`）；全仓 `passwordHistory`/`urlRules`/`appBinding` grep 均为 0。
- **范围**：把登录条目的单 URL 扩展为多 URL 列表（含匹配规则/优先级），增加“绑定应用”（Bundle ID/Universal Link 关联）与密码历史（每次改密自动留档、可查看/回滚/清理）。需同步升级 MDBX 存储模型、CSV/备份编解码与 Android 备份兼容层，避免破坏现有导入导出。

### 2. 自定义字段与条目互链

- **分类**：可并行实现
- **Android 证据**：`data/CustomField.kt:36`（`CustomField`：entryId/title/value/isProtected/sortOrder）；`data/SecureItem.kt:28`（`itemData` JSON 内也可带自定义字段）；`ui/components/CustomFieldComponents.kt`；登录条目通过 `boundNoteId`、TOTP 通过 `boundPasswordId`（`data/model/SecureItemModels.kt:24` 区域）建立互链。
- **iOS 现状**：只有 KeePass 只读自定义字段 `KeePassReadOnlyCustomField`（`SwiftPackages/MonicaStorage/Sources/MonicaStorage/MonicaStorage.swift:2558`）；本地条目没有可编辑自定义字段，`customField` 在 App 内仅用于重复项合并安全与草稿透传（`App/MonicaApp/AppRootView.swift:9116`、`:9478`）；`boundPassword`/`boundNote`/`linkedEntry` grep 为 0。
- **范围**：为所有本地条目增加自定义字段编辑器（文本/隐藏/布尔，隐藏字段计入敏感内容），并在详情页展示；增加条目互链（登录↔TOTP、登录↔笔记、任意条目↔附件），互链需在删除/回收站/导入导出时保持一致性与防悬挂。

### 3. 全局搜索、最近使用与快速访问

- **分类**：可并行实现
- **Android 证据**：仓库级搜索与筛选在 `ui/vaultv2/VaultV2Pane.kt:1636`（`searchQuery`）、`:1421`（跨来源 `allItems` 过滤）；保险库总览提供 `onSearch`/`onArchive`/`onTrash`（`ui/vaultv2/VaultOverviewContent.kt:25`）；使用统计 `data/VaultOverviewUsageManager.kt:40`（`recordOpen`）、`data/PasswordQuickAccessManager.kt:42`（`recordOpen`）。
- **iOS 现状**：只有每种条目各自的搜索框（`App/MonicaApp/AndroidParityVaultHomeView.swift:748` 的 `searchBinding`，对应 `session.loginSearchQuery` 等），没有跨类型/跨来源的统一搜索；`QuickAccess`/`quickAccess`/`最近使用`/`使用频率`/`usageCount` 全仓为 0。
- **范围**：增加一个跨全部条目类型的搜索入口（标题/用户名/URL/备注/自定义字段/标签），支持作用域（全部/当前项目/当前类型）与结果分组；记录条目打开时间与次数，提供“最近使用”“最常用”快速访问区，并在锁屏后不泄露标题（模糊/占位）。需要新增使用统计存储与索引，注意与回收站、KeePass 只读、Bitwarden 快照的边界。

### 4. 标签、手动排序与归档

- **分类**：可并行实现
- **Android 证据**：笔记标签 `data/model/SecureItemModels.kt:396`（`NoteData.tags`）；条目手动排序 `data/PasswordEntry.kt:42`（`sortOrder`）；归档 `data/PasswordEntry.kt:124`（`isArchived`）、`:126`（`archivedAt`）；归档动作 `viewmodel/PasswordViewModel.kt:4008`（`archivePassword`）、`:4020`（`unarchivePassword`）。
- **iOS 现状**：无标签模型（`tags` 仅 CXF 空数组 `App/MonicaApp/AppCredentialExchange.swift:68`）；无 `isArchived`/`archivedAt`（grep 0）；`sortOrder` 只用于 KeePass 只读自定义字段排序（`MonicaStorage.swift:2563`），不是条目排序；只有“收藏”与项目分组。
- **范围**：增加全局标签（创建/重命名/删除/多选、按标签筛选），条目拖拽/置顶排序（本地持久化，跨设备备份需编码），以及归档区（归档/取消归档/归档内搜索，归档条目不进入默认列表但可被全局搜索命中）。需与批量操作、回收站、导入导出兼容。

### 5. TOTP 高级能力：HOTP/Steam/Yandex/MOTP 与参数 UI

- **分类**：可并行实现
- **Android 证据**：`data/model/SecureItemModels.kt:11`（`OtpType { TOTP, HOTP, STEAM, YANDEX, MOTP }`）、`:24`（`TotpData`：period/digits/algorithm/otpType/counter/steam* 字段）；编辑页 `ui/screens/AddEditTotpScreen.kt:102`。
- **iOS 现状**：`LocalTotpEntry` 已有 period/digits/algorithm/otpType/counter（`MonicaStorage.swift:8537`），但 `totpFields` 只暴露标题/密钥/签发方/账号/扫码（`App/MonicaApp/AndroidParityVaultHomeView.swift:2012`）；`TotpGenerator` 只支持时间型（`SwiftPackages/MonicaCore/Sources/MonicaCore/MonicaCore.swift:447`），无计数器、无 Steam 字母表。
- **范围**：补齐 HOTP（计数器自增/手动校准）、Steam Guard（5 位自定义字母表）、Yandex（8 位/特定算法）、MOTP，并把周期/位数/算法/类型/计数器在编辑器中开放；生成器与自动填充/小组件展示需按类型分支。注意与 #22（Steam 账号）区分：本条只做 OTP 算法与参数，不做 Steam 登录/确认。

### 6. 导入 / 导出格式扩展

- **分类**：可并行实现
- **Android 证据**：`ui/screens/ImportDataScreen.kt:114`（Aegis JSON）、`:115`（加密 Aegis）、`:130`（KeePass CSV）、`:131`（Bitwarden CSV）、`:132`（Bitwarden Authenticator CSV）、`:135`（Proton Pass CSV）、`:136`（Chrome CSV）、`:142`（Bitwarden JSON）；导出 `ui/screens/ExportDataScreen.kt:68`（Bitwarden JSON 入口）、`:233`（明文/加密 Bitwarden JSON）。
- **iOS 现状**：只有自定义 CSV（强制 `kind` 列，`MonicaStorage.swift:7256`、`:7297` 校验）、Android 备份、KDBX 只读导入、Bitwarden 快照、CXF；没有 Bitwarden JSON（明文/加密）、Aegis/2FAS、Chrome/Proton/KeePass CSV 预设。
- **范围**：增加常见格式的识别与字段映射（至少 Bitwarden JSON 明文+加密、Aegis JSON、Chrome/Proton Pass/KeePass CSV、Bitwarden Authenticator CSV），导入前给出预览/冲突策略；导出侧增加 Bitwarden JSON（明文+口令加密）。加密 Bitwarden JSON 若用 Argon2，需要评估系统 CryptoKit 之外的实现（见“需要新依赖”的判定标准）。

### 7. 银行卡 / 证件字段扩展与卡面

- **分类**：可并行实现
- **Android 证据**：`data/model/SecureItemModels.kt:57`（`BankCardData`：brand/nickname/iban/swiftBic/routingNumber/accountNumber/branchCode/currency/customerServicePhone/cardType/cardFace/customFields 等）、`:80`（`cardFace`）、`:92`（`CardFaceDisplayMode`）、`:329`（`DocumentData`）、`:358`/`:370`（证件卡面/登机牌条码）；编辑页 `ui/screens/AddEditBankCardScreen.kt:105`、`ui/screens/AddEditDocumentScreen.kt:93`。
- **iOS 现状**：`LocalCardEntry` 只有 title/cardholderName/number/expiryMonth/expiryYear/cvv/issuer/network/notes/favorite（`MonicaStorage.swift:8614`）；`LocalIdentityEntry` 只有 title/documentType/fullName/documentNumber/issuer/country/issueDate/expiryDate/notes/favorite（`:8691`）；表单 `cardFields`/`identityFields` 暴露更少（`AndroidParityVaultHomeView.swift:2026`、`:2041`），无卡面图片、昵称、IBAN/SWIFT、账单地址。
- **范围**：扩展银行卡（品牌/昵称/IBAN/SWIFT/路由号/账户号/币种/客服电话/卡类型/多行地址）与证件（签发日/到期日、姓/名/中间名、地址、国籍、SSN、护照/驾照号）字段；增加卡面图片导入/渲染（本地加密存储，不进入分享/预览明文）；与 CSV/备份编解码同步。

### 8. 账单地址与支付方式（含加密钱包）

- **分类**：可并行实现
- **Android 证据**：`data/model/SecureItemModels.kt:182`（`BillingAddressData`）、`:249`（`PaymentAccountType { DIGITAL_WALLET, BANK_ACCOUNT, PAYMENT_APP, BUY_NOW_PAY_LATER, CRYPTO_WALLET, OTHER }`）、`:259`（`PaymentAccountData`）；`ui/screens/AddEditBillingAddressScreen.kt:94`、`ui/screens/BillingAddressDetailScreen.kt:70`；钱包路由 `wallet_add/{initialType}`（`navigation/Screens.kt:127`）。
- **iOS 现状**：`BillingAddress`/`PaymentAccount` grep 均为 0；`UnifiedVaultItemKind` 无对应 case（`MonicaStorage.swift:5820`）。
- **范围**：新增“账单地址”与“支付方式”两种条目类型（支付方式含数字钱包/银行账户/支付 App/BNPL/加密钱包/其他），支持默认地址/默认支付方式、与银行卡/登录互链、自定义字段；导入导出与全局搜索需识别新类型。加密钱包只存地址/网络/备注，不引入链上交互。

### 9. 条码与登机牌

- **分类**：可并行实现
- **Android 证据**：`data/model/SecureItemModels.kt:370`（`boardingPassBarcode: BoardingPassBarcode?`）；`data/model/BarcodeEntryExtensions.kt:7`（`isBarcodeEntry`）；`ui/screens/BarcodeDetailScreen.kt:66`（ZXing，QR/CODE_128，`BarcodeRenderMode` 在 `:62`）。
- **iOS 现状**：`UnifiedVaultItemKind` 无 barcode/boardingPass case（`MonicaStorage.swift:5820`）；`Barcode`/`BoardingPass` grep 为 0。
- **范围**：新增条码/登机牌条目类型，支持从图片/相机识别 Aztec/PDF417/QR/Code128，保存原始 payload 与渲染参数，详情页可调亮度全屏展示（登机牌需按机场扫描器优化），支持备注/收藏/搜索；生成条码用 CoreImage，识别用 AVFoundation/Vision，不引入第三方 SDK。

### 10. 保险库总览与嵌套文件夹

- **分类**：可并行实现
- **Android 证据**：保险库总览 `ui/vaultv2/VaultOverviewContent.kt:25`（`onOpenFolder`/`onSearch`/`onArchive`/`onTrash`、来源/类型聚合）；MDBX 文件夹表与层级 `repository/MdbxVaultStore.kt:348`（`folderId`）、`:406`（`folders`）、`:481-494`（创建子文件夹/父文件夹校验）；登录条目 `data/PasswordEntry.kt:82`（`mdbxFolderId`）。
- **iOS 现状**：单一活动 MDBX 库（`App/MonicaApp/AppRootView.swift:5298` 创建、`:5350` 打开），没有库列表/总览；项目是扁平的 `LocalVaultProject`（`createVaultCategory` `:3918`），`folderID`/`parentFolder` 在 MonicaStorage 中 grep 为 0。
- **范围**：在现有项目分组之上增加文件夹层级（创建/重命名/移动/删除、拖拽排序、面包屑导航），并提供保险库总览页（按来源/类型/文件夹/收藏/归档/回收站聚合计数与入口）。需要扩展 MDBX 存储模型与迁移，注意与 KeePass 只读组的映射不要混淆。

### 11. 回收站彻底清理与跨库批量迁移

- **分类**：可并行实现
- **Android 证据**：彻底删除 `viewmodel/PasswordViewModel.kt:3978`（`permanentlyDeleteEntry`）、`:3987`（`permanentlyDeleteEntryLocalOnly`）；跨库迁移 `:2754`（`movePasswordsToKeePassDatabase`）、`:2887`（`movePasswordsToMdbxDatabase`，含目标文件夹）；批量迁移 UI `ui/password/PasswordBatchMoveSupport.kt`。
- **iOS 现状**：只有软删除与逐条恢复（`MonicaStorage.swift:10034` 删除、`listDeletedLoginEntries`），`emptyTrash`/`purgeTrash` grep 为 0；批量移动只能移到当前库的项目（`AppRootView.swift:4050 moveSelectedVaultBatchItems(toProjectID:)`），不能跨库/跨来源。
- **范围**：增加“清空回收站/按时间自动清理/单条彻底删除”（需二次确认与生物识别），以及批量迁移到其他 MDBX 库/KeePass 库/项目/文件夹；迁移需处理附件、互链、TOTP 绑定与冲突策略，并提供迁移报告与回滚点。

### 12. MDBX 多库管理与默认库

- **分类**：可并行实现
- **Android 证据**：`data/LocalMdbxDatabase.kt:205`（`is_default`）、`:269`（查询默认库）、`:294`（`setDefaultDatabase`）；`ui/screens/MdbxManagerScreen.kt:138`（`MdbxManagerScreen`，含来源管理/创建/打开）；`repository/MdbxVaultStore.kt:390`（`MdbxVaultStore`）。
- **iOS 现状**：只有单个活动库，无库列表/切换/默认库（`App/MonicaApp/AppRootView.swift:5298`、`:5350`）；`MdbxManager`/`defaultDatabase` grep 为 0。
- **范围**：增加本地多库管理（创建/打开/重命名/删除/设为默认/最近打开），启动时按默认库打开，锁定后保留库选择；云库（WebDAV/OneDrive）作为同一管理页的来源，但不在本条实现自动同步（见 #15/#13）。需处理多库的密钥/生物识别与迁移。

### 13. MDBX 高级能力：Tiga、快照、提交历史、冲突与仪表盘

- **分类**：需要新依赖（扩展 Rust/MDBX FFI；不是纯 Swift 可完成）
- **Android 证据**：`ui/screens/MdbxManagerScreen.kt:101`（`MdbxTigaMode`）、`:112`（`MdbxSnapshotSummary`）、`:156`（`conflictCounts`）、`:179`（`SnapshotStructure`）、`:246`（`CommitHistory`）；`repository/MdbxVaultStore.kt:390`（提交/快照/冲突存储）。
- **iOS 现状**：`MdbxTigaMode` 只存在于生成的 FFI（`SwiftPackages/MonicaMDBX/Sources/MonicaMDBX/Generated/mdbx_ffi.swift:1031`），`resetMasterPasswordWithTigaMode` 也只出现在 FFI（`:663`）；App/Storage 从未调用，且没有 `createVaultWithTigaMode` 这个 API；`CommitHistory` grep 为 0，`Snapshot` 命中都是小组件快照。
- **范围**：在 iOS 暴露 MDBX 的 Tiga 模式、快照浏览/对比/恢复、提交历史、冲突查看与解决、健康仪表盘（页数/碎片/大小/密钥状态）。需要 Rust 侧补齐或确认 FFI 能力，并在 Swift 侧做只读展示与受控写操作；工作量与风险显著高于普通 UI 条目，建议单独立项。

### 14. KeePass 原生编辑器 / 管理器

- **分类**：可并行实现
- **Android 证据**：`ui/screens/KeePassNativeManagerScreen.kt:202`（`KeePassNativeManagerScreen`）、`:1817`（组卡片）、`:1942`（条目卡片）、`:2713`（历史）；`utils/KeePassKdbxService.kt`（8787 行，KDBX 读写/加密）；`viewmodel/LocalKeePassViewModel.kt`（4277 行）。
- **iOS 现状**：只有只读导入树与有限回写：`App/MonicaApp/SettingsRootView.swift:752`（KDBX 导入）、`:807`（`previewKeePassReadOnlyTree`）、`:836`（回收站恢复回写）、`:851`/`:882`/`:894`（附件增删改回写）、`:944`（导入计划确认）；没有创建/编辑条目或组的管理器。
- **范围**：实现 KeePass 库的原生浏览/创建组/创建条目/编辑字段/删除/移动/历史查看，并安全回写 KDBX；需复用现有 KDBX 读写与 Twofish 加密，处理 KDBX3/4、密钥文件、回收站与并发写冲突。

### 15. KeePass 云端库（WebDAV/OneDrive）持续同步

- **分类**：可并行实现
- **Android 证据**：`ui/screens/LocalKeePassScreen.kt:81`（`LocalKeePassScreen`）、`:105-107`（WebDAV/OneDrive 附加库 sheet）、`:237-239`（来源选择）、`:329-345`（附加库对话框）；`viewmodel/LocalKeePassViewModel.kt:4277`（远程同步状态）。
- **iOS 现状**：只有一次性 KDBX 导入/回写与只读树；`CloudFileProviderKind` 声明 OneDrive/Google Drive（`SwiftPackages/MonicaSync/Sources/MonicaSync/MonicaSync.swift:3952`），但 `MonicaAppEnvironment.swift:42` 只注入 OneDrive provider，且没有 KeePass 远程库的持续同步。
- **范围**：把 KeePass 库作为云端文件源接入（WebDAV/OneDrive），支持打开/保存/检测远端变更/冲突副本/后台刷新；Google Drive 在 Android 也未启用（`LocalKeePassScreen.kt:73`），不要作为本期目标。

### 16. Markdown 笔记与内嵌图片

- **分类**：可并行实现
- **Android 证据**：`data/model/SecureItemModels.kt:393`（`NoteData`：content/tags/isMarkdown/customFields）、`:397`（`isMarkdown`）；`ui/screens/AddEditNoteScreen.kt:134`（编辑/预览切换，`:763` `isMarkdownPreview`）；`ui/components/MarkdownPreviewText.kt:55`。
- **iOS 现状**：`LocalNoteEntry` 只有 title/body/favorite/projectID（`MonicaStorage.swift:8481`）；`noteFields` 是纯文本 `TextEditor`（`App/MonicaApp/AndroidParityVaultHomeView.swift:2000`）；`markdown` 仅用于 CSV 表头检测（`MonicaStorage.swift:6764`）。
- **范围**：笔记支持 Markdown 编辑/预览（标题、列表、代码块、链接、表格），内嵌图片从相册/文件插入并加密存储，导出/备份时保持引用；与附件系统、搜索索引（正文）和标签（#4）衔接。渲染可用系统 AttributedString/SwiftUI，不强制引入第三方 Markdown 库。

### 17. 密码生成器高级选项与 SSH 密钥生成

- **分类**：可并行实现
- **Android 证据**：`ui/screens/GeneratorScreen.kt:121`（`GeneratorScreen`）、`:174-177`（排除符号/相似/歧义字符）、`:241`（分隔符计入长度）、`:246-252`（口令词数/分隔符/大小写/数字/自定义词）、`:261`（PIN 长度）、`:1234`（预设书签）；`data/GeneratorPreferences.kt:22`（SYMBOL/PASSPHRASE/PIN/PASSWORD/SSH_KEY 模式、`sshKeyAlgorithm`/`sshKeyRsaSize`、最小字符类计数）。
- **iOS 现状**：`GeneratorRootView` 支持密码/PIN/口令/API Token 与长度/字符类（`App/MonicaApp/GeneratorRootView.swift:5`、`:299`），但没有排除相似/歧义字符、每类最小数量、自定义符号、口令词数/分隔符/大小写/数字、预设书签、SSH 密钥生成。
- **范围**：补齐生成器参数与预设，增加 SSH 密钥生成（Ed25519/RSA 2048/3072/4096，OpenSSH 公钥格式、私钥口令保护），并把生成结果保存为 SSH 条目（#7 的条目已存在）。RSA 生成需评估 CryptoKit 能力，必要时用 Security.framework/自实现 ASN.1。

### 18. 安全分析增强：HIBP、无 2FA、重复 URL 与范围筛选

- **分类**：可并行实现（HIBP 为 HTTPS API，无 SDK 依赖）
- **Android 证据**：`utils/PwnedPasswordsChecker.kt:27`（`API_URL = "https://api.pwnedpasswords.com/range/"`，k-anonymity）；`viewmodel/SecurityAnalysisViewModel.kt:339`（`supports2FA`）、`:435`（`duplicateUrls`）、`:456`（`no2FAAccounts`）；`ui/screens/SecurityAnalysisScreen.kt:109`（范围 ALL/LOCAL/KEEPASS/MDBX）。
- **iOS 现状**：`securityCenterRows` 只做弱密码/复用/泄露/重复登录（`App/MonicaApp/AppRootView.swift:4528`）；`breachedPasswordSHA256Fingerprints`（`:2288`）全仓没有填充逻辑，泄露检查实际不生效；没有无 2FA、重复 URL、范围筛选。
- **范围**：接入 HIBP range API（只在用户开启时联网、仅发送 SHA-1 前 5 位、缓存结果），增加“未启用 2FA 的账号”“重复 URL/相似域名”“范围筛选（全部/本地/KeePass/MDBX/项目）”，并提供逐条修复入口。需隐私说明与开关，默认关闭联网检查。

### 19. Steam 账号与 Steam Guard

- **分类**：可并行实现
- **Android 证据**：`steam/ui/SteamScreen.kt`（账号列表/登录/确认）、`steam/service/SteamLoginImportService.kt`（登录与 maFile 导入）、`data/model/SecureItemModels.kt:43-48`（`steamSharedSecretBase64`/`steamIdentitySecret`/`steamDeviceId` 等）。
- **iOS 现状**：只有 maFile→标准 TOTP 导入：`SteamAuthenticatorImportParser`（`SwiftPackages/MonicaCore/Sources/MonicaCore/MonicaCore.swift:503`）、`importSteamAuthenticator`（`App/MonicaApp/AppRootView.swift:6685`）；没有 Steam 账号实体、登录、确认、令牌撤销（`SteamGuard` grep 为 0）。
- **范围**：新增 Steam 账号条目（用户名/密码/绑定手机/令牌），支持 maFile 导入后的 Guard 码生成（5 位字母表）、登录确认（如需）与移除令牌；网络层需处理 Steam 的登录/确认接口与验证码，失败要可恢复，不能破坏现有 TOTP 导入。

### 20. 剪贴板自动清除与敏感预览掩码

- **分类**：可并行实现（前台可靠、后台受限）
- **Android 证据**：`utils/ClipboardUtils.kt`（复制后按 `clipboardAutoClearSeconds` 定时清除、`IS_SENSITIVE` extras）；`utils/SettingsManager.kt:185`（`clipboard_auto_clear_seconds`）、`:552`（默认值）。
- **iOS 现状**：只有 3 处直接写 `UIPasteboard`（`App/MonicaApp/AndroidParityVaultHomeView.swift:2166`、`GeneratorRootView.swift:107`/`:210`），没有自动清除、没有敏感标记/掩码；`clipboard`/`autoClear`/`privacySensitive` grep 为 0。
- **范围**：所有复制入口统一走“安全复制”封装：记录期望值、在前台按设置秒数清除（`UIPasteboard` 无过期 API，后台不可靠需在文档/UI 说明），并对密码/验证码/私钥等提供“点按显示/长按复制”的掩码；设置项提供 0/15/30/60/120 秒。若要求后台可靠清除，则属于平台不可实现（见 #33 的说明），本条只承诺前台。

### 21. 主题、配色、图标与布局深度自定义

- **分类**：可并行实现
- **Android 证据**：`ui/screens/ColorSchemeSelectionScreen.kt:37`（主题）、`ui/screens/CustomColorSettingsScreen.kt:117`（自定义色）、`ui/screens/AppLauncherIconSettings.kt:34`（图标）、`ui/screens/PageAdjustmentCustomizationScreen.kt:87`（页面/卡片/字段/添加按钮布局）、`ui/screens/PasswordFieldCustomizationScreen.kt:42`；底部导航 `ui/screens/SettingsScreen.kt:1726`（`BottomNavSettingsScreen`）。
- **iOS 现状**：只有系统/浅色/深色、4 个强调色、图标风格、界面密度、4 个密码页模块的显示/排序、卡片密度/账号/URL/标签显隐（`App/MonicaApp/AppRootView.swift:375`、`:429`、`:4102`）；无应用图标切换（`setAlternateIconName` grep 0）、无自定义配色、无卡片/字段级布局、无底部导航编辑。
- **范围**：增加应用图标主题（alternate icons）、自定义强调色/主题色、密码卡片与字段的显示/顺序/密度配置、底部导航项显隐/排序；所有配置需可备份/恢复默认，且不影响自动填充扩展与小组件的展示。

### 22. Monica Plus 内购与赞助入口

- **分类**：需要新依赖（StoreKit 2；同时受 App Store 3.1.1 约束）
- **Android 证据**：`ui/screens/MonicaPlusScreen.kt:23`（权益页）、`ui/screens/PaymentScreen.kt:35`（支付页，`:191` 爱发电链接）、`ui/screens/SupportAuthorScreen.kt:39`（支持作者，`:265-280` 爱发电）。
- **iOS 现状**：`isPlusActive` 来自 `plusEntitlementSnapshot`，只能通过 `DefaultAppPlusResourceUnlockService` 资源解锁（`App/MonicaApp/AppRootView.swift:179`、`:183`、`:4283`）；Settings 只有激活/停用与权益说明（`SettingsRootView.swift:359`）；无 StoreKit、无购买/赞助入口。
- **范围**：接入 StoreKit 2 的非消耗型/订阅（按实际权益设计），实现购买/恢复/收据校验/权益同步；同时提供“赞助作者”入口（外部链接需符合 App Store 规则，不能解锁数字权益）。需服务端或本地签名校验方案，避免仅客户端开关。

### 23. 开发者日志与预览功能开关

- **分类**：可并行实现
- **Android 证据**：`ui/screens/DeveloperSettingsScreen.kt:85`、`ui/screens/DeveloperLogsScreen.kt:77`（日志查看/导出）、`ui/screens/SettingsScreen.kt:423`（预览功能入口）。
- **iOS 现状**：无开发者设置/日志/预览开关（`DeveloperLog`/`previewFeature` grep 为 0）。
- **范围**：增加仅 Debug/TestFlight 可见的开发者页：结构化日志（脱敏、环形缓冲、导出分享）、关键路径耗时、MDBX/同步/自动填充状态、预览功能开关（远程/本地 flag）；Release 包默认隐藏，日志不得包含主密码/密钥/明文条目。

### 24. 常用账号模板

- **分类**：可并行实现
- **Android 证据**：`ui/screens/CommonAccountTemplatesScreen.kt:111`（`CommonAccountTemplatesScreen`）、`:895`（模板卡片）；`data/model/TemplateCredentialDraft.kt:9`；快速设置里也可选模板（`ui/screens/QuickSetupScreen.kt:171`）。
- **iOS 现状**：有快速设置（`SettingsRootView.swift:2096`）但无账号模板；`Template` 在 App 内 grep 为 0。
- **范围**：提供常用服务模板（如 Apple/Google/GitHub/银行/运营商）与自定义模板，创建条目时一键填充标题/URL/用户名字段/自定义字段/TOTP 绑定；模板可导入导出、可删除，不能存储真实密码。

### 25. CXF 通行密钥导入/导出

- **分类**：可并行实现
- **Android 证据**：`credentialexchange/`（`CredentialExchangeExporter`/`CredentialExchangeRegistrar`/`CxfPasskeyMaterial`/`CxfTotpExport`）；`AndroidManifest.xml` 的 `SupportsCredentialExchange` 能力。
- **iOS 现状**：CXF 导入把 `.passkey` 标为不支持（`App/MonicaApp/AppCredentialExchange.swift:91` `return .unsupported(label: "通行密钥")`）；导出只构造密码+TOTP（`:50`）。
- **范围**：在 CXF 导入/导出中支持 Passkey（依赖方、用户名、用户句柄、credential ID、公钥、私钥材料/签名），并保持与系统 `ASExportedCredentialData` 的兼容；需要处理私钥不出安全区、导出需生物识别确认。与 #2 的“条目互链”无关，独立验收。

### 26. 自动填充阻止字段与域名规则

- **分类**：可并行实现（现有配置未生效，属于缺陷修复+补全）
- **Android 证据**：`ui/screens/AutofillBlockedFieldsScreen.kt:67`（阻止字段）、`ui/screens/AutofillSaveBlockedTargetsScreen.kt`（阻止保存目标）、`autofill_ng/` 的域名/字段匹配逻辑；设置入口 `autofill_settings`。
- **iOS 现状**：`AppAutoFillPolicy` 已存 `blockedFields`/`blockedSaveTargets`（`App/MonicaApp/AppRootView.swift:1075`），App 侧只校验保存目标（`:6216` `throw AppAutoFillPolicyError.saveTargetBlocked`）；自动填充扩展从不读取 `blockedFields`（Extensions 内 grep 无命中），所以“阻止字段”目前无效。
- **范围**：让扩展在列出/填充凭据时读取共享配置，按域名/URL 规则与字段名/类型阻止填充；补全域名规则编辑器（通配符/子域/端口）、导入导出与默认策略；修复现有配置“存了不用”的缺陷，并加回归测试。

### 27. GPG 密钥条目

- **分类**：需要新依赖（OpenPGP 实现，Android 用 BouncyCastle）
- **Android 证据**：`ui/screens/GpgKeyScreen.kt:43`（`GpgKeyScreen`）、`data/model/GpgEntryFields.kt:11`（`GpgEntryFields`）、`utils/GpgKeyGenerator.kt:1`（BouncyCastle OpenPGP，生成 RSA 主钥+加密子钥）；依赖 `app/build.gradle:377`（`bcprov-jdk18on:1.78.1`）、`:378`（`bcpg-jdk18on:1.78.1`）。
- **iOS 现状**：无 GPG/OpenPGP 条目或生成器（`GpgKey`/`OpenPGP`/`gpg` grep 为 0）。
- **范围**：新增 GPG 密钥条目（公钥/私钥/指纹/用户 ID/过期），支持生成（RSA 3072/4096）、导入/导出 armored key、口令保护与复制公钥；需要引入/实现 OpenPGP 库（或Security.framework+自研 ASN.1），并做密钥材料加密存储。与 SSH 密钥条目分开。

### 28. 应用内语言切换

- **分类**：可并行实现
- **Android 证据**：`ui/screens/LanguageSelectionDialog.kt:75`（应用内语言选择）；`SettingsScreen` 语言入口。
- **iOS 现状**：仅跟随系统语言，`Localizable.xcstrings` 只有 `en`/`zh-Hans`（`App/MonicaApp/Localizable.xcstrings` 的 `sourceLanguage: zh-Hans`），没有 `AppleLanguages`/应用内 Locale 覆盖（grep 为 0）。
- **范围**：增加应用内语言选择（跟随系统/简体中文/English），持久化并在启动时应用；需要把现有硬编码中文文案迁移到 `String(localized:)`/xcstrings（新增 UI 必须遵守），并补英文翻译。与 #21 的主题设置可共用“外观”页但独立验收。

---

## 二、iOS 不可实现（29–36）

> 这些不是“还没做”，而是受 iOS 公共 API/审核政策限制。建议在 issue 中标注 `平台限制`，不要按普通功能排期；若要改善体验，只能做降级方案（每条已注明）。

### 29. 自动填充任意字段、内联建议与强密码建议

- **分类**：iOS 不可实现
- **Android 证据**：`autofill_ng/parser/AutofillParserNg.kt:13`（`class AutofillParserNg`，解析任意 AutofillId/字段）、`autofill_ng/processor/AutofillProcessorNg.kt`（按字段填充）、`autofill_ng/builder/StrongPasswordSuggestionPolicy.kt`（强密码建议）、`autofill_ng/builder/FillResponseBuilderNg.kt`（内联建议）；服务声明 `autofill_ng/MonicaAutofillServiceNg.kt:69`。
- **iOS 约束**：`ASCredentialProviderViewController` 只接收系统给的密码/Passkey 请求，不能枚举或填充任意字段，不能主动弹出内联建议，也不能生成强密码（强密码由系统 `Password AutoFill` 提供）。没有 `AutofillService` 等价 API。
- **降级**：把自动填充扩展的凭据选择/搜索/保存体验做好，并在 App 内提供“复制字段”快捷操作；不要承诺任意字段填充。

### 30. 第三方输入法内密码库填充（IME）

- **分类**：iOS 不可实现
- **Android 证据**：`ime/MonicaInputMethodService.kt:75`（`class MonicaInputMethodService : InputMethodService()`，进程 `:ime`，`monica_input_method`）、`ime/ImeUnlockActivity`/`ImeBiometricAuthActivity`；Manifest `BIND_INPUT_METHOD`。
- **iOS 约束**：自定义键盘扩展无法读取宿主 App 的输入框类型/`textContentType`/是否密码框，也不能调用密码自动填充；系统只在键盘上方提供自己的 Passwords 建议。键盘扩展向 `secureTextEntry` 插入文本还受限制。
- **降级**：依赖系统密码自动填充；最多提供“从 Monica 复制到剪贴板”的分享/快捷指令。

### 31. 无障碍服务自动填充守护与默认密码管理器

- **分类**：iOS 不可实现
- **Android 证据**：`service/MonicaAccessibilityService.kt:50`（`class MonicaAccessibilityService : AccessibilityService()`）、`autofill_ng/defaultmanager/RootDefaultManager.kt:10`、`ShizukuDefaultManager.kt:26`、`autofill_ng/protection/AutofillProtectionService.kt:24`；Manifest `BIND_ACCESSIBILITY_SERVICE`。
- **iOS 约束**：iOS 没有第三方 AccessibilityService，也没有“设置默认密码管理器”的公开 API；自动填充提供者由用户在系统设置中选择，App 无法读取/切换/守护其他 App 的界面。
- **降级**：引导用户在“设置 → 密码 → 密码选项”中启用 Monica；提供扩展状态检测与设置跳转。

### 32. TOTP 常驻 / 实时验证码通知

- **分类**：iOS 不可实现
- **Android 证据**：`autofill_ng/service/AutofillOtpNotificationService.kt:54`（前台服务，`specialUse`，常驻通知展示 TOTP）、`service/NotificationValidatorService.kt:42`；`notifications/LiveUpdateNotifications.kt`；`autofill_ng/utils/SmartCopyReceiver.kt`（智能复制）。
- **iOS 约束**：普通 App 不能常驻后台每秒刷新并更新通知；`UNNotificationServiceExtension` 只处理远程推送；Live Activity 面向用户可感知的持续活动，需 iOS 16.1+ 且不能保证高频更新，不适合作为验证器常驻码。
- **降级**：小组件展示当前验证码（时间线刷新）、打开 App 时展示、用户手动添加的本地提醒；不承诺“实时常驻”。

### 33. 截屏 / 录屏内容阻断

- **分类**：iOS 不可实现
- **Android 证据**：`utils/ScreenshotProtectionUtil.kt:20`（`WindowManager.LayoutParams.FLAG_SECURE`）、`MainActivity.kt:438`、`ui/base/BaseMonicaActivity.kt:62`；默认开启 `utils/SettingsManager.kt:551`。
- **iOS 约束**：没有阻止截屏/录屏的公开 API；`UIScreen.main.isCaptured` 只能检测录制/镜像，`UIApplication.userDidTakeScreenshotNotification` 只在截图后通知；`PrivacyShieldView`（`App/MonicaApp/LockScreenViews.swift:5`）只能遮罩 App 自身界面。
- **降级**：检测到录制时显示遮罩/提示，截图后提示“已截图”；敏感页面默认隐藏内容直到点按显示。

### 34. 应用名称 / 图标多马甲与启动器别名

- **分类**：iOS 不可实现
- **Android 证据**：`AndroidManifest.xml` 的 `activity-alias`（`.ModernVisibleLauncherAlias`、`.ClassicVisibleLauncherAlias`、`.ModernVisibleLauncherAliasMonica` 等，`android:label`/`android:icon`）；`ui/screens/AppLauncherIconSettings.kt:34`；`receiver/LauncherEntryRepairReceiver.kt:14`。
- **iOS 约束**：`setAlternateIconName` 只能换图标，桌面名称由 Info.plist/`InfoPlist.strings` 固定，运行时不能改；没有 activity-alias/launcher alias；App Store 审核禁止伪装性名称/图标。
- **降级**：只做多套应用图标（明确标注 Monica），不做名称伪装。

### 35. 应用内检查更新与自更新

- **分类**：iOS 不可实现
- **Android 证据**：`update/AppUpdateController.kt:26`、`update/AppUpdateDialog.kt:33`、`ui/screens/SettingsScreen.kt:175`（检查更新/下载 APK 安装）。
- **iOS 约束**：iOS 不允许 App 下载并安装可执行代码或自更新；只能通过 App Store/TestFlight 更新。可查询 App Store 公开版本并提示，但不能在应用内完成安装。
- **降级**：设置页显示当前版本 + “前往 App Store”链接；不做静默更新。

### 36. NFC 银行卡贴卡读取（EMV/PAN）

- **分类**：iOS 不可实现
- **Android 证据**：`nfc/card/EmvCardReader.kt:9`（`class EmvCardReader`，`EmvCardChannel.transceive` 发送 APDU）、`:14-21`（`BankCard(number, expiryMonth, expiryYear, holder, scheme)`）、`nfc/card/NfcCardDraft.kt:4`（合并进表单）。
- **iOS 约束**：`SwiftPackages/MonicaCore/Sources/MonicaCore/NFCCardProbe.swift:14-20` 明确：`NFCTagReaderSession` 不支持选择支付类 application ID（EMV/PAN）；iOS 26 EU 的 `NFCPaymentTagReaderSession` 需单独申请且不向本 App 开放；因此只能做 NDEF/非支付 ISO7816 诊断，`readablePaymentCardFields` 为空。
- **降级**：保留现有“NFC 银行卡诊断”（标签类型/NDEF），明确提示不能读卡号；提供手动录入/拍照 OCR（如后续需要）。

---

## 三、统计

| 分类 | 数量 |
|------|------|
| 可并行实现 | 25 |
| 需要新依赖 | 3 |
| iOS 不可实现 | 8 |
| **合计** | **36** |

> 边界说明：`剪贴板自动清除`（#20）按“前台可做、后台不可靠”归入可并行，并在正文写明限制；若要求 Android 等价的可靠后台清除，应视为不可实现。`MDBX 高级能力`（#13）需要扩展 Rust/FFI 能力，按“需要新依赖”处理，但不是引入第三方 iOS SDK。
