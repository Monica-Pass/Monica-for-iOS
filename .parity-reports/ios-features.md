# Monica iOS 用户可见功能清单（对照 Android 的穷举盘点）

> 代码基线：`App/MonicaApp/Info.plist`（CFBundleShortVersionString 0.1 / CFBundleVersion 1），`IPHONEOS_DEPLOYMENT_TARGET = 17.0`，`TARGETED_DEVICE_FAMILY = 1`（仅 iPhone），仅竖屏。
> 判定口径：✅ 完整（用户可完成闭环）｜◐ 部分（有真实实现但缺关键字段/入口/环节）｜○ 占位（只有模型、占位文案或不可达界面）｜✕ 未实现。
> 括号中的 `Android #n` 指 `.parity-reports/android-features.md` 的条目号，便于 Lead 直接开 issue。
> 结论先行：iOS 是一个可用的「密码 + TOTP + 笔记 + 卡包」本地 MDBX 保险库，带真实 KeePass 只读导入/写回、CSV/Android 备份迁移、WebDAV 整库备份恢复、密码自动填充扩展；但 Passkey、Steam、Bitwarden、Send、附件、通知、Plus 支付、自动备份、多库管理等均为占位或缺失；分享扩展与 App Intents 深链当前不可用。

## 0. 平台与导航基线

1. **应用骨架** ✅ — `App/MonicaApp/AppRootView.swift:10371`（`struct AppRootView`），`body` 在 `:10383`：未解锁渲染 `MonicaLockScreen`，解锁后 `VStack(tabContent + AndroidParityBottomNavigation)`，失焦时叠加 `PrivacyShieldView`。
2. **底部 7 个 Tab** ✅ — `App/MonicaApp/AppRootView.swift:9645` `enum MonicaAppTab`：密码 / 验证 / 笔记 / 卡包 / 通行 / 生成 / 设置；`phaseOneAndroidParityTabs` 固定顺序，无自定义（`:9645-9718`，列表 `:9654`）。仅 5 个 Tab 映射保险箱类型（`coreItemKind`）。
3. **条目类型 11 种、仅 5 类有 Tab** ◐ — `SwiftPackages/MonicaStorage/Sources/MonicaStorage/MonicaStorage.swift:5820` `UnifiedVaultItemKind`（login/totp/note/card/identity/passkey/sshKey/apiToken/wifi/send/attachmentRef）。`sshKey/apiToken/wifi/send/attachmentRef` 没有 Tab，列表不可达（`App/MonicaApp/AndroidParityVaultHomeView.swift:356-448` 的 list 只能由 `itemKind` 触发，而 `itemKind` 只来自 7 个 Tab）。
4. **单保险库、单窗口** ◐ — 只记住一个库（`App/MonicaApp/AppRootView.swift:1200` `RememberedVaultRecord`；`UserDefaultsRememberedVaultStore:1322`）；`UIApplicationSupportsMultipleScenes=false`（`App/MonicaApp/Info.plist`）。

## 1. 保险箱条目类型（11 种 kind）

5. **密码登录（login）** ◐ — 创建/编辑/收藏/删除/恢复/列表/搜索/批量均实现：`App/MonicaApp/AppRootView.swift:4493`（create）、`:4556`（update）、`:4796`（favorite）、`:4931`（restore）、列表 `App/MonicaApp/AndroidParityVaultHomeView.swift:212`。缺：无只读详情页、无复制用户名/密码、编辑器无备注字段（`LocalLoginEntryDraft.notes` 存在于 `SwiftPackages/MonicaStorage/Sources/MonicaStorage/MonicaStorage.swift:8360` 但表单未暴露）；「+ 添加 URL」「绑定应用」是空按钮、登录方式 Picker 固定 0（`App/MonicaApp/AndroidParityVaultHomeView.swift:1730/1731/1734`）。
6. **验证器（totp）** ◐ — CRUD + 收藏 + 回收站（`App/MonicaApp/AppRootView.swift:5124/5247/5290`）；列表显示实时验证码、倒计时与进度条（`App/MonicaApp/AndroidParityVaultHomeView.swift:247`，卡片 `:1234-1270`）；支持相机扫码（`App/MonicaApp/ScannerAndStatusViews.swift:9`）与 otpauth URI 导入（`App/MonicaApp/AppRootView.swift:5178`）。缺：不能复制验证码（全 App 仅生成器用剪贴板，`App/MonicaApp/GeneratorRootView.swift:96/199`）；编辑器无算法/位数/周期（表单仅标题/密钥/签发方/账号/扫码，`App/MonicaApp/AndroidParityVaultHomeView.swift:1762`）；仅 TOTP，`totpCode` 忽略 `otpType/counter`（`App/MonicaApp/AppRootView.swift:7863`）→ 无 HOTP/Steam；无图标/磁贴布局。
7. **笔记（note）** ◐ — 标题 + 正文 `TextEditor`，CRUD/收藏/搜索（标题与正文）/回收站：`App/MonicaApp/AppRootView.swift:4962/5005/5038`，表单 `App/MonicaApp/AndroidParityVaultHomeView.swift:1750`，搜索 `AppRootView.swift:2052`。缺 Markdown 双模式、标签、图片、草稿、绑定条目。
8. **银行卡（card）** ◐ — 持卡人/卡号/CVV/有效期/银行/卡组织（`App/MonicaApp/AndroidParityVaultHomeView.swift:1776`），列表摘要 `issuer network ****last4`（`AndroidParityVaultHomeView.swift:940` `cardSummary`）。缺 NFC 读卡、卡面自定义/图片附件、复制卡号、备注字段。
9. **证件（identity）** ◐ — 类型/姓名/证件号/签发方/国家（`App/MonicaApp/AndroidParityVaultHomeView.swift:1791`），与银行卡合并在卡包 Tab（`:283`）。缺正反面图片、签发/到期日期（draft 有 `issueDate/expiryDate`，编辑器未暴露）、号码掩码切换。
10. **通行密钥（passkey）** ○ — 仅手工录入 RP ID / 账号 / Credential ID / PublicKeyCOSE / Keychain 引用（`App/MonicaApp/AppRootView.swift:5756`，表单 `AndroidParityVaultHomeView.swift:1802` `passkeyFields`）。无 `AuthenticationServices` 创建/认证，无系统 Passkey 提供者（`Extensions/MonicaAutoFillExtension/Info.plist` 只有 `ProvidesPasswords=true`），`App/MonicaApp/AppRootView.swift:12` 仅 import LocalAuthentication。
11. **SSH 密钥（sshKey）** ○ — 表单（用户名/主机/公钥/私钥引用/口令提示/备注）与 CRUD 存在（`App/MonicaApp/AppRootView.swift:5942/6033`，`AndroidParityVaultHomeView.swift:1813`），但列表无 Tab 不可达；无私钥生成/导入、无公钥复制。
12. **API Token（apiToken）** ○ — 表单（签发方/账号/Token/权限范围/过期时间/备注）与 CRUD（`AppRootView.swift:6112/6203`，`AndroidParityVaultHomeView.swift:1825`），列表不可达；无复制、无过期提醒。
13. **Wi-Fi（wifi）** ○ — 表单含 SSID/安全类型/密码/隐藏/备注 + 本地生成二维码 + `ShareLink` 分享（`AndroidParityVaultHomeView.swift:1837-1865`，`WifiQRCodeRenderer:24`），列表不可达；无「加入网络」。
14. **安全发送 Send** ○ — 仅本地记录（标题/内容/过期时间/最多查看次数/备注，`AndroidParityVaultHomeView.swift:1867`），无服务端、无分享链接、不强制次数/过期；列表不可达。
15. **附件引用（attachmentRef）** ○ — 只有元数据 + QuickLook 预览 + 删除（`AndroidParityVaultHomeView.swift:420`；模型 `MonicaStorage.swift:9017`）；无添加入口、列表不可达；编辑器显示「该类型当前只支持列表展示。」
16. **缺失的 Android 条目类型** ✕ — 条码 Barcode、账单地址、支付方式、GPG 密钥、Steam 账号、登机牌、自定义字段（Android #4/#5/#7/#8/#14/#17）。

## 2. 组织与检索

17. **分类（MDBX project）** ◐ — 新建/重命名/删除/切换：`App/MonicaApp/AppRootView.swift:2949/3009`，分类条 `AndroidParityVaultHomeView.swift:730`。无排序、无图标、无嵌套文件夹。
18. **收藏** ◐ — 每类可收藏 + 「仅收藏」开关（`AppRootView.swift:4796` 等 10 个 setSelected*Favorite；搜索面板 Toggle `AndroidParityVaultHomeView.swift:1081`）。无收藏夹分组/排序。
19. **搜索** ◐ — 每种类型独立搜索框；登录匹配标题/用户名/网址（`AppRootView.swift:2003`），笔记匹配标题/正文（`:2052`）；有「仅收藏」「堆叠分组」开关（`AndroidParityVaultHomeView.swift:1081`）。无全局跨类型搜索、无标签搜索、无结果高亮。
20. **快速筛选** ◐ — 全部 / 当前分类 / 收藏 / 回收站四个 chip（`AppRootView.swift:2832`，`AndroidParityVaultHomeView.swift:1098`）。无来源/未分类/最近使用筛选。
21. **批量选择** ◐ — 进入选择、全选、移动到分类、删除、恢复：`AndroidParityVaultHomeView.swift:786-853`，会话方法 `AppRootView.swift:3035+`。无归档、无跨库迁移、无批量收藏。
22. **堆叠分组** ◐ — 仅登录，按标题分组，点击分组把搜索词设为标题（`AppRootView.swift:2019-2040`）；无网站堆叠匹配规则设置。
23. **回收站** ◐ — 每类 `deleted*Entries` 平铺在列表底部，可恢复；无彻底删除、无按天自动清理、无保留策略（全局搜索 `purge/永久删除` 无结果）。
24. **排序** ✕ — 没有用户可见的排序状态或入口（只有内部 `.sorted`）。
25. **标签** ✕ — 无标签模型、无标签 UI（grep `tag/标签` 仅命中 SwiftUI `.tag` 与 DBF 错误标签）。
26. **保险箱总览 / 层级浏览 / 最近使用 / 快速访问** ✕ — 无 Vault Overview、无层级树、无最近使用记录。
27. **条目互链** ✕ — 无密码↔笔记/TOTP/Passkey/SSO 绑定（登录编辑器的「绑定应用」为空实现）。
28. **智能去重** ◐ — 重复登录检测、合并预览、撤销上次合并、忽略/恢复忽略：`AppRootView.swift:3331`（securityCenterRows）、`duplicateLoginMergePreviews:855`。
29. **归档** ✕ — 只有回收站，无归档状态。

## 3. MDBX 数据库

30. **创建本地库** ✅ — 主密码 + 库名，生成 `<name>.mdbx`：`AppRootView.swift:4065`；仓库 `SwiftPackages/MonicaStorage/Sources/MonicaStorage/MonicaStorage.swift:9866`。仅密码，无密钥文件（对比 Android #37 密码+密钥文件）。
31. **打开已有 .mdbx** ✅ — 锁屏「打开已有保险库」fileImporter `.mdbx`：`App/MonicaApp/LockScreenViews.swift:22`、`AppRootView.swift:4118`。
32. **解锁** ✅ — 主密码（`:4167`）或 Keychain 包装密钥 + 生物识别（`:7935`，`MonicaSecurity.swift:102/246`）。
33. **MDBX 引擎** ✅ — `MonicaMDBXRuntime.createVault` / `openVault` / `openVaultWithSecurityKey`（`SwiftPackages/MonicaMDBX/Sources/MonicaMDBX/MonicaMDBX.swift:1845/1863/1881`），11 类条目读写（`:152/618/635/655/691`）。
34. **技术检查** ◐ — 设置「运行 MDBX 检查」执行一次项目级登录往返 smoke test（`AppRootView.swift:9623`），不是对用户库的完整性校验/修复。
35. **主密码修改** ✕ — 无「修改主密码」入口；仅有「忘记密码」重置（`:4279`，且依赖 Keychain 包装密钥 + 密保，见 13 节）。
36. **多库管理** ✕ — 无库列表/切换/重命名/双库并列/默认库（`RememberedVaultStore` 只存一个记录，`AppRootView.swift:1200`）。
37. **WebDAV / OneDrive 建库与开库** ✕ — 云端只做整库备份上传/下载，不能直接以远端库打开（见 11 节）。
38. **Tiga 安全模式 / 引擎选择 / 操作仪表盘 / 冲突队列 / 快照 / 提交历史 / 原生对象编辑器 / 未知条目页 / 技术参数页 / 自动同步** ✕ — 均无对应 UI（对比 Android #41-#54）。

## 4. KeePass

39. **KDBX 文件检查** ✅ — 「检查 KDBX」读取格式/状态/KDBX 版本/加密算法/压缩/KDF 摘要：`AppRootView.swift:6743/6776`；解析 `MonicaStorage.swift:3298`（`DefaultKeePassDatabaseReader`）、格式探测 `:4952`。
40. **密码 + 密钥文件双凭据** ✅ — SecureField 数据库密码、选择密钥文件、解锁预检：`AppRootView.swift:6810`；`KeePassCredentialSupport:2431`。
41. **只读结构浏览** ✅ — 分组/条目/附件/TOTP/自定义字段快照：`AppRootView.swift:6859`；模型 `MonicaStorage.swift:2494-2647`。
42. **导入计划与元数据导入** ✅ — 预览可导入/跳过/待解码，确认后创建登录条目（含密码、TOTP/附件占位）：`AppRootView.swift:6892/6913`（写库 `:6947-6952`）。
43. **KDBX3 / KDBX4 写回** ✅ — `makeKeePassReadOnlySnapshotWritebackResult` 分派（`AppRootView.swift:7143`），协调器 `MonicaStorage.swift:3726/3865`；未知版本报错「未知 KDBX 版本写回尚未接入。」（`:7166`）。
44. **回收站条目还原并写回** ✅ — 设置页「恢复并写回」→ `restoreKeePassReadOnlyRecycleBinEntryAndWriteBack`（`AppRootView.swift:7554`，写回 `:7171`）。
45. **附件写回** ✅ — 添加/替换/删除附件并写回：`AppRootView.swift:7418`（add）、`:7453`（delete）、`keePassAttachmentEditCandidates` 列表；附件模型 `MonicaStorage.swift:2508`。
46. **远端 KDBX 写回** ✅ — 选择云文件后 `overwriteFile`（`AppRootView.swift:7202`）。
47. **新建 KDBX / 组与条目编辑 / 原生搜索 / 历史版本 / 模板 / 批量排序 / 库设置 / 完整性检查 / 修复 / 合并** ✕ — 全部缺失（对比 Android #55-#76）；iOS 侧只有「只读 + 附件/回收站写回」。

## 5. Bitwarden

48. **同步数据模型** ✅ — `BitwardenSyncItem/Send/Mutation/Snapshot/Provider`：`SwiftPackages/MonicaSync/Sources/MonicaSync/MonicaSync.swift:84/128/151/233`。
49. **默认 Provider** ○ — 永远抛 `authenticationRequired`（「Bitwarden 需要先登录。」）或 `unsupportedOperation`（`MonicaSync.swift:238-248`）。
50. **登录/自托管/2FA/同步/队列/请求历史/Send/导入导出** ✕ — App 内无任何 Bitwarden UI；`BitwardenSync` 状态只在会话与开发者诊断里出现。
51. **Plus 行** ○ — `AppRootView.swift:3241` 的 `bitwarden_sync` 行仅做锁定样式展示。

## 6. 附件与 Send

52. **本地附件内容存储** ✅ — 加密 blob + Android 兼容包装密钥：`MonicaStorage.swift:5530-5703`（`FileLocalAttachmentContentStore`、`AndroidAttachmentContentWrappingKey`）。
53. **附件预览** ✅ — QuickLook（`AndroidParityVaultHomeView.swift:420`，`.quickLookPreview` 绑定）。
54. **附件添加入口** ✕ — 无 UI 添加/替换附件（只有 KeePass 写回路径与 Android 备份导入可产生附件）。
55. **附件列表可达性** ○ — 附件 Tab 不存在，`attachmentList` 不可达。
56. **Send 分享/服务端** ✕ — 只有本地字段，无上传、无链接、无最大查看次数/过期执行。

## 7. Steam

57. **Steam 数据结构** ○ — `MonicaMDBX.swift:1293-1300` 有空字符串字段 `steamFingerprint/steamDeviceId/steamSerialNumber/steamSharedSecretBase64/steamRevocationCode/steamIdentitySecret/steamTokenGid/steamRawJson`。
58. **Steam UI / Steam Guard / 确认 / maFile** ✕ — 全仓库 grep `steam` 仅上述字段；`TotpGenerator` 只有标准 TOTP（无 5 位 Steam 字母表）。

## 8. Passkey

59. **条目记录 CRUD** ○ — `AppRootView.swift:5756/5814`，仅元数据字段（RP ID、Credential ID、COSE 公钥、Keychain 引用）。
60. **系统 Passkey 提供者** ✕ — AutoFill 扩展 `Info.plist` 无 `ProvidesPasskeys`；无 `ASAuthorization`/`ASCredentialProvider` passkey API；`AppRootView.swift:12` 只 import LocalAuthentication。
61. **创建/认证/详情/删除/跨设备 QR/硬件密钥/诊断** ✕ — 除手动删除条目外均无。

## 9. 自动填充

62. **Credential Provider 扩展** ✅ — `Extensions/MonicaAutoFillExtension/AutoFillCredentialProviderViewController.swift`（359 行）：列表、搜索、`provideCredentialWithoutUserInteraction`、`prepareCredentialList`。
63. **加密索引与密钥** ✅ — AES-GCM 记录（`MonicaStorage.swift:9066/9393`）；索引密钥存 Keychain（`MonicaSecurity.swift:141/313`），解锁需设备所有者认证（`:380`）。
64. **QuickType 身份注册** ✅ — `SystemAutoFillCredentialIdentityStore` + `ASPasswordCredentialIdentity`（`App/MonicaApp/MonicaAppEnvironment.swift` 生产装配）。
65. **索引刷新** ✅ — 每次条目变更后自动重建（`refreshAutoFillEncryptedIndexIfConfigured` 在 `AppRootView.swift:3114/4520/4581/4839/6734/7057/7804` 等处调用），另有设置页「更新自动填充索引」（`SettingsRootView.swift:310-330`）。
66. **保存/更新凭据提示** ✕ — `saveAutoFillCredential(...)`（`AppRootView.swift:4715`）零调用点；扩展无保存 UI。
67. **Passkey / TOTP 自动填充** ✕ — 仅密码。
68. **内联建议 / 强密码建议 / 阻止字段 / 域名规则 / 设为默认密码管理器** ✕ — iOS 平台限制 + 未实现；权限管理页只展示 AutoFill 已配置状态（`AppRootView.swift:3300`）。

## 10. 系统集成

69. **WidgetKit 小组件** ◐ — Small/Medium，展示锁定状态/条目数/第一个 TOTP 的标题与剩余秒数/第一个快捷条目（`Extensions/MonicaWidgetExtension/MonicaWidget.swift`）。不含验证码本身（`AppRootView.swift:2287-2310` 只写 `secondsRemaining`）；无 `WidgetCenter.reloadTimelines`，只在解锁/建库/锁库时写快照（`:4108/4157/8549/9101`）；无锁屏 accessory 家族。
70. **App Intents / 快捷指令** ○ — 仅 iOS 18+「打开条目」意图（`App/MonicaApp/MonicaShortcutsAppIntents.swift:85-120`，`OpenURLIntent`），且生成的 `monica://shortcut/...`（`AppRootView.swift:634`）**未在 Info.plist 注册 URL scheme**（仅 `msauth.com.monica-pass.monica`）→ 深链无法拉起 App。
71. **分享扩展** ○ — `Extensions/MonicaShareExtension/ShareViewController.swift` 只把 URL/文本/文件写入 App Group 收件箱；主 App 从未实例化 `AppShareExtensionInboxStore`，`importPendingShareExtensionItems`（`AppRootView.swift:4596`）零调用点 → 分享内容永远不会被导入。
72. **文件导入/导出面板** ✅ — `.fileImporter`（KDBX/MDBX/CSV/zip/密钥文件）与 `.fileExporter`（CSV/zip）：`SettingsRootView.swift:405-706`。
73. **Quick Look 预览** ✅ — 附件（见 53）。
74. **相机 / 二维码扫描** ✅ — `ScannerAndStatusViews.swift:9`，`NSCameraUsageDescription`。
75. **ShareLink** ◐ — 仅 Wi-Fi 二维码内容（`AndroidParityVaultHomeView.swift:1865`）。
76. **OneDrive OAuth 回跳** ✅ — `msauth.com.monica-pass.monica` URL scheme + MSAL（`Info.plist`、`OneDriveMSALAuthenticationService.swift`）。
77. **Safari 扩展 / Watch / App Clip / Live Activity / 控制中心 / Handoff / Universal Links / CloudKit** ✕ — 均无 target 或声明。
78. **iPad / 横屏** ✕ — `TARGETED_DEVICE_FAMILY=1`，仅 Portrait。
79. **输入法 / 无障碍 / NFC / 后台任务 / 局域网同步** ✕ — 无对应 API 使用（无 BGTaskScheduler、无 MultipeerConnectivity）。

## 11. 同步与备份

80. **WebDAV 手动备份** ✅ — URL/用户名/密码/远端文件名，上传当前 .mdbx 原始文件：`AppRootView.swift:8102`（`WebDAVBackupPackage` `MonicaSync.swift:835`，传输 `:1054`）。
81. **WebDAV 恢复** ✅ — 下载预览（文件名/字节/SHA-256）+ 保险库密码校验 + 关闭并替换本地库文件：`AppRootView.swift:8362`（`replaceVaultFile:9262`）。
82. **OneDrive 备份** ✅ — MSAL 登录 / 刷新文件列表 / 上传 .mdbx（每次新建文件，`uploadFile` `:8241`）/ 下载预览（`:8215`）。
83. **OneDrive 恢复** ✕ — 只有预览，无「恢复」动作；`replaceVaultFile` 仅被 WebDAV 调用。
84. **Google Drive** ○ — `GoogleDriveCloudFileProvider` 永远 `.disconnected` 并抛 `unsupportedOperation`（`MonicaSync.swift:764`），且未装配进 `productionCloudFileProviders`（`MonicaAppEnvironment.swift` 仅 oneDrive）。
85. **Bitwarden 同步** ✕ — 见 5 节。
86. **自动/定时备份** ✕ — 无后台任务/定时器；只有手动按钮。
87. **备份版本保留 / 列表 / 配置备份** ✕ — 无备份列表 UI（OneDrive 仅列前 3 个文件）；WebDAV 单文件名覆盖。
88. **局域网 / 热点同步** ✕。
89. **同步范围/方向/队列/冲突中心** ✕ — 仅 KeePass 写回有 `expectedRevision` 冲突错误。

## 12. 导入导出

90. **CSV 导入** ✅ — 41 列自定义格式（kind 必填），预览问题与可导入数后确认：`AppRootView.swift:6695/6717`；编解码 `MonicaStorage.swift:7157`（列 `:7158-7201`，缺 kind 拒绝 `:7215`）。
91. **CSV 导出** ✅ — `AppRootView.swift:7847` + `CSVExportDocument:1115`，默认文件名 `monica-vault.csv`。
92. **CSV 附件** ✕ — 明确不导入附件内容（`MonicaStorage.swift:7370`「CSV 暂不导入附件内容」）。
93. **Android 备份导入** ✅ — .zip，支持附件清单与加密备份（PBKDF2-SHA256 100k + AES-GCM，`MonicaStorage.swift:6084/6228`）；预览/确认 `AppRootView.swift:7645/7748`。
94. **Android 备份导出** ◐ — 仅 6 类（password/totp/note/card/identity/passkey）条目 JSON（`MonicaStorage.swift:6349-6371`），不含附件 blob。
95. **KeePass 导入** ✅ — 见 4 节（只读元数据导入）。
96. **KDBX 导出 / Bitwarden JSON / Aegis / Stratum / Steam maFile / 多 CSV 子格式** ✕ — 均无。
97. **otpauth URI 导入** ✅ — `AppRootView.swift:5178`（`importTotpURI`）。
98. **冲突/重复处理 UI** ◐ — 导入报告有 issues 列表；无逐条冲突合并界面（仅登录重复合并）。

## 13. 安全与隐私

99. **主密码与首次设置** ✅ — `LockScreenViews.swift:22`（输入→确认→创建），`AppRootView.swift:4065`。
100. **生物识别解锁** ◐ — LocalAuthentication + Keychain 包装密钥（`AppRootView.swift:7935`，`MonicaSecurity.swift:380`）；但 `Info.plist` 无 `NSFaceIDUsageDescription`，Face ID 可能不可用/回退。
101. **自动锁定** ◐ — 预设 1/5/15/30 分钟（`AppRootView.swift:10340` `AppAutoLockPolicy`），仅前台空闲计时；进入后台立即锁库（`handleScenePhaseChange:9374-9379` 无条件 `lockLocalVault()`）。
102. **隐私遮罩** ✅ — `.inactive` 显示 `PrivacyShieldView`（`LockScreenViews.swift:5`，`AppRootView.swift:9372`）。
103. **密保问题找回** ◐ — 11 个问题选 2、答案 SHA-256 无盐存 UserDefaults（`AppRootView.swift:4348`），3 次尝试限制，重置需 Keychain 包装密钥 + 已记住库（`:4297-4317`）。
104. **安全中心** ◐ — 弱密码/复用/泄露/重复统计（`AppRootView.swift:3331`）；`breachedPasswordSHA256Fingerprints:1619` 从未写入，泄露计数恒为 0（`:3490`）。
105. **操作时间线** ◐ — 内存态、上限 50、锁库清空（`AppRootView.swift:1620/9296/9335`）；无持久化、无字段级差异。
106. **剪贴板自动清除 / 密码历史 / 截屏保护 / 预览掩码切换** ✕ — 无；仅生成器复制后提示「已复制」（`GeneratorRootView.swift:96`）。
107. **主密码修改** ✕ — 见 35。
108. **字段级加密** ？ — Swift 侧未见字段级 AES-GCM；库加密由 MonicaMDBX C 引擎负责（`MonicaMDBX.swift:1845+`），无法在本仓库核实与 Android 600k PBKDF2 的等价性。

## 14. 界面与个性化

109. **Android 风格设计系统** ✅ — `App/MonicaApp/AndroidParityDesign.swift`（348 行：palette/card/button/section/screen 组件）。
110. **颜色模式** ✅ — 跟随系统/浅色/深色（`AppRootView.swift:286`）。
111. **强调色** ◐ — 4 种：Monica/绿/蓝/橙（`AppRootView.swift:316`）；无自定义取色、无 15+ 配色。
112. **密码列表图标** ✅ — 彩色/单色/隐藏（`AppRootView.swift:351`）。
113. **卡片密度** ✅ — 舒适/紧凑（`AppRootView.swift:238`）。
114. **字段显示开关** ✅ — 账号、网址、底部导航文字（`VaultDisplayPreferences:272`，`SettingsRootView.swift:112-198`）。
115. **界面缩放 / 15 语言 / 底部导航排序 / 页面调整 / 卡片与字段定制 / 自定义图标 / 模板 / 触感 / 初始化向导** ✕ — 均无。
116. **本地化** ✕ — 无 `.lproj`、无 `NSLocalizedString`，全部硬编码中文。

## 15. 通知 / 小组件 / 快捷方式

117. **本地通知** ✕ — 仅读取 `UNUserNotificationCenter` 权限状态（`AppRootView.swift:3698` `refreshNotificationPermissionStatus`），从不请求/调度通知；权限页却写「TOTP 快捷查看会使用 iOS 安全通知替代常驻验证码」（`:3311`）。
118. **验证器常驻通知 / Live Activity** ✕。
119. **桌面小组件** ◐ — 见 69（无验证码、无主动刷新、无锁屏家族）。
120. **App Shortcuts** ○ — 见 70（仅有打开意图且深链未注册）。
121. **控制中心控件 / 锁屏小组件 / 动态岛** ✕。

## 16. 其他（更新、支持作者、Plus/支付、权限管理、开发者工具）

122. **应用更新检查 / 更新安全校验** ✕ — 无版本检查、无「关于/版本」页、无 App Store 跳转。
123. **支持作者 / 赞助 / 收款码** ✕ — 无。
124. **Monica Plus** ○ — 本地解锁（`AppRootView.swift:3254` `activatePlusFromResource`，`UserDefaultsAppPlusEntitlementStore:1498`），关闭（`:3274`）；4 个功能行仅显示锁/解锁样式（`:3217-3252`），无任何功能被门禁。
125. **StoreKit / IAP / 激活码校验** ✕ — 无 `import StoreKit`；Plus 无服务端校验。
126. **权限管理页** ✅ — 5 行：相机/AutoFill/通知/App Group/Keychain，含跳转系统设置（`AppRootView.swift:3289-3329`）。
127. **开发者设置** ✅ — 7 行诊断（主存储/MDBX 桥接/App Group/本机标识/AutoFill 索引/同步日志/Bitwarden）：`AppRootView.swift:899-956`，`SettingsRootView.swift:721`。
128. **密码生成器** ◐ — 4 种模式（密码/PIN/短语/API Token）、长度/字符集、复制、最近 6 条内存历史（`App/MonicaApp/GeneratorRootView.swift:5`）。无用户名/SSH/GPG 生成、无历史持久化、无常见密码分析、无排除易混字符/自定义符号。
129. **数据库管理器** ✕ — 无（见 36）。
130. **测试基线** ✅ — `Tests/MonicaTests/MDBXRoundTripTests.swift`、`VaultSessionModelTests.swift`；6 个 SwiftPackage 有测试目录。

## 明确的缺口与占位

> 逐条可与上面条目对应；给 Lead 开 issue 用。

- **工具栏「更多」无任何面板**：`App/MonicaApp/AndroidParityVaultHomeView.swift:1073` 的 `.more` 按钮只切换状态，`selectedAction == .more` 无分支（只有 `.search` 在 `:1039`）。
- **登录编辑器三个假控件**：`+ 添加 URL` 空闭包、`绑定应用` 空闭包、`登录方式` Picker `.constant(0)`（`App/MonicaApp/AndroidParityVaultHomeView.swift:1730/1731/1734`）。
- **「多数据库存储 / 未分类」横幅不可点**：`AndroidParityVaultHomeView.swift:1674`（装饰性 chevron）。
- **列表卡片尾部省略号无菜单**：`AndroidParityVaultHomeView.swift:1178`。
- **5 类条目不可达**：sshKey/apiToken/wifi/send/attachmentRef 的 list 都在 `AndroidParityVaultHomeView.swift:356-448`，但没有 Tab 能传入对应 `itemKind`（`AppRootView.swift:9645-9718` 只映射 5 类，`coreItemKind:9702`）。
- **附件无添加入口**：`attachmentRef` 编辑器仅提示「该类型当前只支持列表展示。」
- **分享扩展死路**：`Extensions/MonicaShareExtension/ShareViewController.swift` 写入收件箱，但 `AppShareExtensionInboxStore` 在主 App 零实例化；`AppRootView.swift:4596` `importPendingShareExtensionItems` 零调用点。
- **自动填充保存死路**：`AppRootView.swift:4715` `saveAutoFillCredential` 零调用点。
- **自动填充只有「密码」语义**：索引只包含登录条目用户名/密码（`MonicaStorage.swift:9085`），TOTP/Passkey/银行卡不会出现在系统填充面板。
- **验证码/密码不能复制**：全仓库 `UIPasteboard` 仅 `GeneratorRootView.swift:96/199`。
- **泄露密码检测恒为 0**：`AppRootView.swift:1619` 只读、`:3490` 计数；无任何写入/网络查询。
- **通知不存在但文案宣称存在**：`AppRootView.swift:3311`「TOTP 快捷查看会使用 iOS 安全通知…」；全仓库无通知调度。
- **小组件不含验证码**：`AppRootView.swift:2287-2310` 只写 `secondsRemaining`；`Extensions/MonicaWidgetExtension/MonicaWidget.swift` 无 code 字段。
- **小组件不主动刷新**：无 `WidgetCenter.reloadTimelines`；快照只在建库/开库/锁库/解锁时写入（`AppRootView.swift:4108/4157/8549/9101`），其余时间显示旧数据。
- **App Intents 深链未注册**：`AppRootView.swift:634` 生成 `monica://shortcut/...`，`App/MonicaApp/Info.plist` 只有 `msauth.com.monica-pass.monica`。
- **OneDrive 不能恢复**：`AppRootView.swift:8215` 只下载预览；`replaceVaultFile` 仅 WebDAV（`:9262/8389`）。
- **OneDrive 备份每次新建文件**：`:8241` 调 `uploadFile` 而非 `overwriteFile`。
- **Google Drive 未接入**：`MonicaSync.swift:764` 全抛 `unsupportedOperation`；`MonicaAppEnvironment.swift` 未装配。
- **Bitwarden 未接入**：`MonicaSync.swift:238-248` 永远抛错；无 UI。
- **Passkey 未接入系统**：`Extensions/MonicaAutoFillExtension/Info.plist` 无 `ProvidesPasskeys`；无 AuthenticationServices 创建/认证。
- **Steam 仅 schema**：`MonicaMDBX.swift:1293-1300`；无 UI/算法。
- **KeePass 未知版本不能写回**：`AppRootView.swift:7166`「未知 KDBX 版本写回尚未接入。」
- **CSV 不含附件**：`MonicaStorage.swift:7370`。
- **Android 加密备份提示文案过时**：`MonicaStorage.swift:6087` 说「暂未支持解密」，但 `:6228` 已实现 AES-GCM/PBKDF2 解密；无密码时返回该文案（`:6102`）。
- **主密码不能修改**：无 `changeMasterPassword/resetMasterPassword` 的常规入口（仅忘记密码路径 `AppRootView.swift:4279`）。
- **密保答案弱哈希**：`AppRootView.swift:4348` 未加盐 SHA-256。
- **后台立即锁库**：`AppRootView.swift:9374-9379`，自动锁定档位只在前后台存活期间生效。
- **无 Face ID 用途说明**：`App/MonicaApp/Info.plist` 缺 `NSFaceIDUsageDescription`。
- **无排序/标签/归档/最近使用/总览/互链/多库**：见 24-29、36。
- **无自动备份/定时任务**：无 BGTaskScheduler 使用。
- **无更新检查/关于/支持作者/StoreKit**：见 122-125。
- **本地化缺失**：无 `.lproj`/`NSLocalizedString`。
- **仅 iPhone 竖屏**：`project.pbxproj` `TARGETED_DEVICE_FAMILY=1`；`Info.plist` Portrait only。
- **ParityFeatureFlag 的 disabledReason 文案已过时**（backup/keepass/bitwarden/passkeys/attachments 均称「后续阶段接入」，但部分已实现）：`MonicaStorage.swift:7617-7670`；该 flag 在 App 内只有 `SettingsRootView.swift:314` 一处使用。

## 已声明的系统能力（entitlements / Info.plist / 扩展）

- **App Group**：`group.monica-pass.monica`（主 App、AutoFill、Share、Widget 四个 target 全部声明）。
- **Keychain 访问组**：主 App `$(AppIdentifierPrefix)com.monica-pass.monica`；AutoFill `$(AppIdentifierPrefix)com.monica-pass.monica.autofill`。
- **URL Scheme**：`msauth.com.monica-pass.monica`（OneDrive OAuth 回调）；`LSApplicationQueriesSchemes` = `msauthv2`、`msauthv3`。**无 `monica` scheme**（App Intents 深链依赖它）。
- **后台模式 / Associated Domains / 推送**：均未声明（无 `UIBackgroundModes`、无 `com.apple.developer.associated-domains`、无 `aps-environment`）。
- **隐私用途字符串**：仅 `NSCameraUsageDescription`（TOTP 扫码）；无 Face ID、无照片、无本地网络。
- **扩展 target（3 个）**：
  - `MonicaAutoFillExtension` — `com.apple.authentication-services-credential-provider`，`ProvidesPasswords=true`（无 `ProvidesPasskeys`）。
  - `MonicaShareExtension` — `com.apple.share-services`，接受 file（≤10）/text/web URL（≤10）。
  - `MonicaWidgetExtension` — `com.apple.widgetkit-extension`。
- **无** Watch、Safari、Notification Service/Content、App Clip、Intent Extension、Credential Exchange 扩展。
- **设备**：iPhone only（`TARGETED_DEVICE_FAMILY=1`）、竖屏、`UIApplicationSupportsMultipleScenes=false`、Catalyst 关闭。

## iOS 独有能力（相对 Android 的新增/替代）

1. **WidgetKit 小组件** ◐ — 已实现 small/medium 快照视图（`Extensions/MonicaWidgetExtension/MonicaWidget.swift`），但无验证码、无主动刷新、无锁屏家族。
2. **App Intents / 快捷指令** ○ — 仅 iOS 18+「打开条目」意图（`MonicaShortcutsAppIntents.swift`），深链 scheme 未注册，实际不可用。
3. **Share Extension** ○ — 有 target 与写入逻辑，主 App 未消费，端到端不可用。
4. **Credential Provider 自动填充（密码）** ✅ — 列表/搜索/直接填充/交互回退（`AutoFillCredentialProviderViewController.swift`），并用 `ASPasswordCredentialIdentity` 注册 QuickType。
5. **Quick Look 附件预览** ✅ — `AndroidParityVaultHomeView.swift:420`。
6. **OneDrive（MSAL）云备份** ◐ — 登录/列表/上传/下载预览；无恢复。
7. **Wi-Fi 二维码本地渲染 + ShareLink** ✅ — `WifiQRCodeRenderer:24`，`AndroidParityVaultHomeView.swift:1837-1865`。
8. **相机二维码扫描（AVFoundation）** ✅ — `ScannerAndStatusViews.swift:9`。
9. **iPad / 多窗口 / 横屏 / Live Activity / 控制中心 / Handoff / Universal Links** ✕ — 未实现或未声明。

## 与 Android 分类的覆盖概况（供开 issue 排序）

| Android 分类 | iOS 覆盖 | 主要缺口 |
| --- | --- | --- |
| 1 保险箱条目类型（19） | 11 种模型，5 类有 UI | 条码/地址/支付/GPG/Steam/登机牌/自定义字段；SSO；条目详情与复制 |
| 2 组织与检索（17） | 分类/收藏/搜索/批量/去重 6 项 | 标签、排序、归档、最近使用、总览、层级、互链、回收站清理 |
| 3 MDBX（18） | 建库/开库/解锁/技术检查 4 项 | 密钥文件、WebDAV/OneDrive 建库、多库、快照/历史/仪表盘/冲突/自动同步 |
| 4 KeePass（22） | 打开/只读/导入/写回/附件 8 项 | 新建、组/条目编辑、搜索、历史、模板、库设置、修复、合并 |
| 5 Bitwarden（16） | 仅类型定义 | 全部用户功能 |
| 6 附件与 Send（6） | 存储/预览 2 项 | 添加入口、列表可达、Send 服务端 |
| 7 Steam（12） | 仅 schema | 全部 |
| 8 Passkey（13） | 手动记录 CRUD | 系统提供者、创建/认证、QR、诊断 |
| 9 自动填充（19） | 密码提供者/索引/QuickType 5 项 | 保存提示、Passkey/TOTP、域名规则、默认管理器、诊断 |
| 10 系统集成（13） | Widget/Intents/Share/AutoFill/相机 5 项（其中 3 项不完整） | 输入法、无障碍、NFC、后台、局域网、深链 |
| 11 同步与备份（11） | WebDAV 备份/恢复、OneDrive 备份 3 项 | 自动备份、保留策略、OneDrive 恢复、局域网、队列 |
| 12 导入导出（9） | CSV、Android 备份、KeePass、otpauth 4 项 | KDBX/Bitwarden/Steam 导出、多 CSV 子格式、后台导入 |
| 13 安全与隐私（17） | 主密码/生物识别/自动锁/遮罩/密保/安全中心/时间线 7 项 | 主密码修改、剪贴板清除、截屏保护、字段级加密核验、弱哈希 |
| 14 界面与个性化（17） | 颜色模式/4 强调色/图标/密度/字段开关 5 项 | 主题库、缩放、15 语言、导航定制、卡片定制、图标库、模板 |
| 15 通知/小组件/快捷方式（5） | Widget 1 项（不含验证码） | 通知、Live Activity、App Shortcuts 可用性 |
| 16 其他（12） | Plus 本地解锁、权限页、开发者设置、生成器 4 项 | 更新、支持作者、支付、数据库管理器、生成器高级项 |
