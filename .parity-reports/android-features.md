# Monica Android 用户可见功能清单

- **来源**：`/tmp/monica-android-latest`（Monica-Pass/Monica `main` @ `e63d0ce`，版本 1.0.327，2026-11-12）。
- **取证方法**：README.md / Monica Android发行说明.md / `AndroidManifest.xml` / `navigation/Screens.kt` / `res/values/` 字符串表 / 各功能包目录与关键类名。未逐行阅读全部源码，功能粒度以"有独立界面或独立系统入口"为准。
- **路径简写**：`src/` = `Monica for Android/app/src/main/java/takagi/ru/monica/`；`res/` = `Monica for Android/app/src/main/res/`。

---

## 1. 保险箱条目类型（19 项）

1. **登录/密码条目** — 标题、网址、用户名、密码、备注、邮箱、电话、地址、收藏、排序、分组封面、绑定笔记、绑定 TOTP、绑定 Passkey、应用包名绑定。证据：`src/data/PasswordEntry.kt:33-141`。
2. **SSO 登录条目** — `loginType=PASSWORD|SSO`，10 个 SSO 提供商（Google/Apple/Facebook/Microsoft/GitHub/Twitter/X/微信/QQ/微博/其他），可引用另一条目作为凭据来源。证据：`src/data/LoginType.kt:7-40`、`src/data/PasswordEntry.kt:97-101`。
3. **Wi-Fi 条目** — SSID/密码/加密方式/隐藏网络等元数据，独立详情页，可被自动填充辅助选中。证据：`src/data/PasswordEntry.kt:106`、`src/navigation/Screens.kt:58-71`、`src/autofill_ng/WifiAutofillAssist.kt`。
4. **SSH 密钥条目** — 生成/导入 SSH 私钥、公钥展示与复制、独立详情页。证据：`src/navigation/Screens.kt:72-85`、`src/ui/screens/SshGeneratedResult.kt`、`src/ui/screens/GeneratorSshKeySection.kt`。
5. **条码条目（Barcode）** — 保存一维/二维码内容并在详情页渲染、可扫码新增。证据：`src/navigation/Screens.kt:86-90`、`res/values/strings.xml`（`barcode_*`）。
6. **银行卡** — 卡号/持卡人/有效期/CVV、卡类型选择、卡面图案与自定义卡面图、NFC 贴卡读取填入、卡包（堆叠）视图。证据：`src/data/PasswordEntry.kt:59-62`、`src/nfc/card/NfcCardEntryController.kt:20-31`、`src/ui/cardwallet/`。
7. **证件 Document** — 证件类型、号码、签发/到期、正反面图片；证件号预览掩码。证据：`src/ui/screens/AddEditDocumentScreen.kt`、`src/security/DocumentNumberPreviewMask.kt`。
8. **账单地址 Billing Address** — 收件人、地址行、城市、州、邮编、国家，独立 `BILLING_ADDRESS` 条目类型。证据：`src/data/SecureItem.kt:112`、`src/navigation/Screens.kt:118-141`、`src/ui/screens/AddEditBillingAddressScreen.kt`。
9. **支付方式 Payment Account** — 独立条目类型 `PAYMENT_ACCOUNT`，用于支付信息自动填充。证据：`src/data/SecureItem.kt:107-115`。
10. **私密笔记 Note** — Markdown 编辑/预览双模式、标签、分类、收藏、图片（相机/相册）、草稿恢复、内嵌内容复制、绑定密码条目。证据：`src/ui/screens/AddEditNoteScreen.kt`、`src/ui/screens/NoteListScreen.kt`。
11. **TOTP 验证器** — otpauth 解析、算法/位数/周期、图标、分类、标准/磁贴两种布局、倒计时与进度条、复制下一个验证码（Plus）。证据：`src/ui/screens/AddEditTotpScreen.kt`、`src/ui/totp/`、`res/values/otp_editor_strings.xml`。
12. **Passkey 条目** — 独立 `PasskeyEntry` 实体，可从系统凭据提供者创建，也可存于 KeePass。证据：`src/data/PasskeyEntry.kt`、`src/passkey/`。
13. **API Key 条目** — 提供商、网站、URL、密钥（隐藏/显示）、打开网站。证据：`res/values/strings_api_key.xml`、`src/ui/screens/ApiKeyScreen.kt`。
14. **API Token 条目（MDBX gateway credential）** — `monica.gateway.credential.v1` / `monica.api-token.v1` schema，含 provider/api_base/token/note，可导入 JSON、校验、按集合/文件夹归档，≤16KB。证据：`src/data/ApiTokenPayload.kt:8-26`、`src/ui/screens/AddEditApiTokenScreen.kt`、`src/ui/screens/ApiTokenDetailScreen.kt`。
15. **GPG 密钥条目** — 生成/导入 GPG 密钥对、指纹复制、公钥/私钥复制与导出、口令、有效期、独立条目页。证据：`res/values/gpg_strings.xml`、`src/ui/screens/GpgKeyScreen.kt`。
16. **Steam 账号条目** — 独立于密码库的 Steam 账号实体（可存本地/KeePass/Bitwarden/MDBX）。证据：`src/steam/data/SteamAccountEntity.kt`、`src/steam/data/SteamStorageTarget.kt`。
17. **Send（Bitwarden Send）** — 文本/文件两种类型、访问密码、最大访问次数、有效天数、隐藏邮箱/文本、草稿、复制链接；文件型提示需 premium。证据：`src/ui/screens/SendScreen.kt`、`res/values/strings_send_entry.xml`。
18. **登机牌条码** — 扫描登机牌条码（PDF417/Aztec）并附加到卡包条目，可展开/收起、重扫、移除。证据：`res/values/boarding_code_strings.xml`、`src/data/model/BoardingPassBarcode.kt`。
19. **自定义字段** — 每个条目可加任意字段（名称/值/是否受保护），用于密码、KeePass 条目、API Token 等。证据：`src/data/CustomField.kt`、`src/data/CustomFieldDao.kt`。

## 2. 组织与检索（17 项）

20. **分类（Category）** — 用户自定义分类，支持排序、图标、按类型过滤。证据：`src/data/Category.kt`、`src/ui/category/`。
21. **标签** — 笔记标签、条目标签，可按标签过滤与批量管理。证据：`res/values/strings.xml`（`note_tags`、`note_all_tags`）。
22. **收藏** — 各类型条目 `isFavorite`，列表过滤器与总览"收藏"分区。证据：`src/data/SecureItem.kt:32`、`res/values/vault_overview_strings.xml`。
23. **嵌套文件夹** — 本地分类、KeePass 组树、MDBX 嵌套文件夹三种层级并存，支持拖拽移动。证据：`src/ui/screens/MdbxFolderBrowser.kt`、`src/keepass/`。
24. **主界面多标签与聚合列表** — 底部标签：密码 / 验证器 / 卡包 / 笔记 / Passkey / Steam / Send，可定制显隐与顺序；密码页支持聚合多来源列表。证据：`src/ui/SimpleMainScreen.kt`、`src/ui/password/PasswordAggregateListContent.kt`、`res/values/strings.xml`（`nav_*`）。
25. **全局搜索** — 按标题/用户名/网址/标签/备注搜索；支持搜索范围与结果高亮；启动可自动聚焦搜索框。证据：`src/ui/screens/SettingsScreen.kt`（`auto_focus_search`）、`src/ui/screens/NoteListScreen.kt`、`src/ui/main/`。
26. **排序** — 标题/创建时间/更新时间，升/降序，作用域可限定为当前列表或全库。证据：`res/values/vault_sort_strings.xml`。
27. **快速筛选 / 分类快捷筛选** — 列表顶部快捷筛选条，可按分类、来源（Monica/KeePass/Bitwarden）、收藏、未分类过滤。证据：`res/values/strings.xml`（`quick_filters`、`category_quick_filters`）、`src/ui/screens/NoteListScreen.kt`（`filter_monica/keepass/bitwarden`）。
28. **最近使用** — `vault_overview_recent` 分区，记录最近打开条目。证据：`res/values/strings_vault_recent.xml`。
29. **快速访问** — 按打开次数与最近打开时间统计高频条目，列表页提供快速入口。证据：`src/data/PasswordQuickAccessManager.kt:10-30`。
30. **保险箱总览 Vault Overview** — 卡片/条目/收藏/类型/文件夹/数据库多维分区，可置顶卡片与条目、上下移动、重置、跨库搜索、显示隐藏项、锁定库提示。证据：`res/values/vault_overview_strings.xml`、`src/ui/vaultv2/`。
31. **层级布局（Vault V2）** — 可选层级式保险箱布局（文件夹导航、返回父文件夹、文件夹路径横幅）。证据：`src/ui/screens/SettingsScreen.kt`（`vault_v2_hierarchical_layout`）、`src/ui/vaultv2/`。
32. **批量选择与批量操作** — 多选后批量删除/移动/归档/迁移（含跨库迁移与进度通知）。证据：`res/values/bulk_delete.xml`、`src/ui/screens/SettingsScreen.kt`（`batch_delete_*`、`password_batch_transfer_*`）。
33. **回收站** — 软删除、按天数自动清理、可关闭（关闭后永久删除）、批量恢复/彻底删除。证据：`src/data/SecureItem.kt:76-80`、`res/values/strings.xml`（`trash_*`）、`src/ui/screens/TrashScope.kt`。
34. **归档** — 归档/取消归档，归档前可要求主密码确认。证据：`res/values/strings.xml`（`archive_action`、`archive_password_confirmation_*`）、`src/data/SecureItem.kt:73-75`。
35. **条目互链** — 密码↔笔记（`boundNoteId`）、密码↔TOTP（`authenticatorKey`）、密码↔Passkey（`passkeyBindings`）、SSO↔凭据条目（`ssoRefEntryId`）。证据：`src/data/PasswordEntry.kt:66-101`。
36. **智能去重** — 识别重复条目并合并（保留副本组 `replica_group_id`），可配置。证据：`src/data/PasswordEntry.kt:129`、`res/values/strings.xml`（`smart_deduplication`）、`src/data/LegacyDedupRecoveryEntity.kt`。

## 3. MDBX 数据库（18 项）

37. **创建本地库** — 内部存储或外部自定义目录，选择目录/文件名，密码 + 可选密钥文件。证据：`src/ui/screens/MdbxLocalCreateScreen.kt`、`src/data/LocalMdbxDatabase.kt:123`。
38. **打开本地库** — 文件选择器打开已有 `.mdbx` 库并注册。证据：`src/ui/screens/MdbxLocalOpenScreen.kt`、`src/navigation/Screens.kt:203-208`。
39. **WebDAV 建库/开库** — URL/用户名/密码/远端目录/父目录选择、刷新、测试连接、远端文件选择。证据：`src/ui/screens/MdbxWebDavCreateScreen.kt`、`src/ui/screens/MdbxWebDavOpenScreen.kt`。
40. **OneDrive 建库/开库** — Microsoft 账号登录、目录选择、远端文件浏览。证据：`src/ui/screens/MdbxOneDriveCreateScreen.kt`、`src/ui/screens/MdbxOneDriveOpenScreen.kt`、`AndroidManifest.xml`（msauth BrowserTabActivity）。
41. **Tiga 安全模式** — `SKY`（8MB Argon2id，快速）/`MULTI`（64MB，推荐）/`POWER`（256MB，最强）；`GLITTER`(512MB) 仅格式兼容，Android 不提供创建。证据：`src/data/LocalMdbxDatabase.kt:100-111`、`src/ui/screens/MdbxTigaModeAvailability.kt:7-13`。
42. **引擎选择** — `KOTLIN_MDBX1`（基础 CRUD）与 `RUST_MDBX2`（附件、外部存储、远端同步、嵌套文件夹、项目标签、增量历史、快照、冲突、同步包、基准测试全部能力）。证据：`src/data/LocalMdbxDatabase.kt:31-52`、`src/rustcore/`。
43. **解锁方式** — 主密码或密钥文件（`MdbxUnlockMethod`），解锁/锁定状态在库列表可见。证据：`src/data/LocalMdbxDatabase.kt:123`、`src/ui/screens/MdbxManagerScreen.kt`。
44. **操作仪表盘** — 条目数、冲突数、健康度、增量、附件数、同步状态、格式/Tiga 模式、可恢复性、文件大小、兼容性。证据：`src/ui/screens/MdbxDashboardDetailPages.kt`、`src/ui/screens/MdbxExpressiveComponents.kt`。
45. **冲突队列** — 按字段/提交查看冲突，可选本地优先/远端优先/自定义合并/标记已解决。证据：`src/ui/screens/MdbxManagerScreen.kt`、`res/values/strings.xml`（`mdbx_conflict_*`）。
46. **快照** — 手动快速快照、变更时自动快照、始终全量或增量、无变更时提示。证据：`src/ui/screens/MdbxSnapshotBrowser.kt`、`res/values/strings.xml`（`mdbx_snapshot_*`）。
47. **提交历史** — 逐次提交查看与恢复（时间线式）。证据：`src/ui/screens/MdbxCommitHistoryPresentation.kt`、`src/ui/screens/MdbxManagerScreen.kt`。
48. **快照浏览与恢复** — 浏览历史快照内容并回滚到指定快照。证据：`src/ui/screens/MdbxSnapshotBrowser.kt`。
49. **嵌套文件夹浏览** — 项目制文件夹树、面包屑、子文件夹创建/重命名/移动。证据：`src/ui/screens/MdbxFolderBrowser.kt`。
50. **原生对象编辑器** — 直接编辑 MDBX 原生对象/字段（含未知扩展字段保留）。证据：`src/ui/screens/MdbxNativeObjectEditor.kt`、`src/ui/screens/MdbxNativeManagerScreen.kt`。
51. **未知条目页** — 打开到未知/不支持的条目类型时展示降级页面而非崩溃。证据：`src/ui/screens/MdbxUnknownEntryScreen.kt`、`src/ui/screens/MdbxUnsupportedModePage.kt`。
52. **技术参数页** — 展示格式版本、Tiga 参数、KDF、文件布局等技术信息。证据：`src/ui/screens/MdbxTechnicalParameters.kt`。
53. **多库管理与默认库** — 库列表、设为默认（`default_badge`）、删除库（本地文件同时删除）、状态徽标。证据：`src/ui/screens/MdbxManagerScreen.kt`、`src/data/MdbxSyncState.kt`。
54. **MDBX 自动同步** — WorkManager 周期任务（`MdbxAutoSyncWorker`）按库配置自动拉取/推送，支持仅 WiFi 等约束。证据：`src/workers/MdbxAutoSyncWorker.kt`、`src/workers/MdbxAutoSyncPreferences.kt`。

## 4. KeePass（22 项）

55. **本地 KDBX 库** — 打开/新建本地 `.kdbx`，记住上次路径。证据：`src/ui/screens/LocalKeePassScreen.kt`、`src/data/LocalKeePassDatabase.kt`。
56. **WebDAV 远端库** — 浏览/新建目录/上传/下载、记住密码、强制覆盖、冲突保护（auto/strict）。证据：`src/ui/screens/LocalKeePassWebDavBrowser.kt`、`res/values/strings.xml`（`keepass_webdav_*`）。
57. **OneDrive 远端库** — 登录、目录浏览、文件选择。证据：`src/ui/screens/LocalKeePassOneDriveBrowser.kt`。
58. **Google Drive 远端库** — 登录与文件浏览。证据：`src/ui/screens/LocalKeePassGoogleDriveBrowser.kt`、`res/values/strings.xml`（`keepass_gdrive_*`）。
59. **库格式与加密选项** — KDBX3/KDBX4；cipher AES/ChaCha20/Twofish；KDF AES-KDF/Argon2d/Argon2id；transform rounds、memory MB、parallelism、decrypt time。证据：`res/values/strings.xml`（`keepass_create_*`）、`src/keepass/`。
60. **密钥文件** — 使用已有密钥文件、生成新密钥文件、保留私有副本、导出副本、删除副本。证据：`res/values/keepass_file_actions.xml`、`src/ui/screens/KeePassKdbxViewModel.kt`。
61. **双凭据与重验** — 密码 + 密钥文件组合解锁；重新验证密码、修复凭据流程。证据：`res/values/strings.xml`（`keepass_reverify_*`）、`src/ui/screens/KeePassNativeEntrySaveCoordinator.kt`。
62. **原生组/条目树** — 组与子组创建、重命名、删除、拖拽移动；条目树浏览。证据：`src/ui/screens/KeePassNativeManagerScreen.kt`、`src/keepass/`。
63. **原生搜索** — 字段选择、限定当前组、大小写敏感、正则、包含受保护/过期/回收站/模板。证据：`src/ui/screens/KeePassNativeManagerScreen.kt`、`res/values/strings_keepass_list.xml`。
64. **条目详情/编辑** — 标准字段、原始值视图、元数据、创建/修改时间、标签、Auto-Type、历史数、自定义数据。证据：`src/ui/screens/KeePassNativeEntryDetailScreen.kt`。
65. **自定义字段** — 新增字段（名称/值/是否受保护），可隐藏显示。证据：`src/ui/screens/KeePassNativeEntryEditorScreen.kt`、`res/values/keepass_password_history.xml`。
66. **历史版本** — 查看条目历史并恢复或删除某版本。证据：`res/values/keepass_password_history.xml`、`src/ui/screens/KeePassNativeEntryDetailScreen.kt`。
67. **附件** — 添加/导出/重命名/删除附件，显示大小。证据：`res/values/strings.xml`（`keepass_attachment_*`）。
68. **模板** — 模板管理、创建/编辑/另存为模板/使用模板/删除，可按目标条目类型套用。证据：`src/ui/screens/KeePassNativeDatabaseToolsScreen.kt`、`res/values/strings.xml`（`keepass_template_*`）。
69. **批量与排序** — 批量选择、批量移动/删除；排序：自然/标题升/标题降/修改时间/创建时间。证据：`src/ui/screens/KeePassNativeManagerScreen.kt`。
70. **库设置** — 描述、默认用户名、颜色、历史维护（天数/条数/大小 MB）、回收站组名与自动创建、模板组、压缩（none/gzip）、改主密码/密钥文件模式、只读访问控制、立即锁定。证据：`src/ui/screens/KeePassNativeDatabaseSettingsScreen.kt`。
71. **完整性检查** — 重复组/条目 UUID、缺失/未引用附件、缺失/未引用自定义图标。证据：`src/ui/screens/KeePassNativeDatabaseToolsScreen.kt`、`res/values/keepass_operation_strings.xml`。
72. **数据库修复** — 修复损坏的 KDBX 结构。证据：`res/values/strings.xml`（`keepass_repair_*`）、`src/keepass/`。
73. **恢复副本** — 列出 recovery copies（大小/时间），可恢复或删除。证据：`res/values/strings.xml`（`keepass_recovery_*`）、`src/keepass/`。
74. **合并与冲突中心** — 从另一 KDBX "merge from"；冲突中心按 local/remote/字段/位置/存在性/属性展示并解决。证据：`res/values/keepass_conflict_strings.xml`、`res/values/strings.xml`（`keepass_merge_*`）。
75. **远端自动上传** — `KeePassRemoteUploadWorker` 在保存后自动上传远端库。证据：`src/workers/KeePassRemoteUploadWorker.kt`。
76. **统一目标选择器** — 新建/编辑密码、验证器、银行卡等时可选择写入本地库、KeePass 库或 MDBX 库。证据：`src/ui/screens/DatabaseManagerScreen.kt`、`src/data/PasswordOwnership.kt`、`src/data/SecureItemOwnership.kt`。

## 5. Bitwarden（16 项）

77. **账号登录** — 邮箱 + 主密码登录，可记住账号。证据：`src/bitwarden/ui/BitwardenLoginScreen.kt`。
78. **自托管服务器** — 自定义服务器 URL、环境解析、TLS 配置（自定义信任）。证据：`src/bitwarden/api/BitwardenEnvironment.kt`、`src/bitwarden/api/BitwardenTlsConfig.kt`、`src/bitwarden/ui/BitwardenServerConfigurationDialog.kt`。
79. **TLS 指纹确认** — 首次连接展示证书指纹供用户核对。证据：`src/bitwarden/ui/BitwardenFingerprintSheet.kt`。
80. **两步验证** — 支持 TOTP/邮件验证码方式选择、切换方式、记住 2FA；不支持的方式给出提示。证据：`res/values/strings_bitwarden_two_factor.xml`、`src/bitwarden/ui/BitwardenTotpPickerDialog.kt`。
81. **保险箱同步** — 手动/自动同步，可选择同步的数据类型与目标文件夹；`sync_all_types`。证据：`src/bitwarden/ui/BitwardenSettingsScreen.kt`、`res/values/strings_bitwarden_management.xml`。
82. **周期同步** — WorkManager 周期任务，默认 15 分钟，可要求 WiFi（不计费网络）、电量不低。证据：`src/bitwarden/sync/BitwardenSyncWorker.kt:92-110`。
83. **同步队列** — 待上传/重试/失败任务队列页，可查看与重试。证据：`src/bitwarden/ui/SyncQueueScreen.kt`、`src/navigation/Screens.kt:249`。
84. **同步状态与汇总** — 底部状态栏（需认证/等待解锁/重试中/排队/已同步）、离线/冲突/上传失败/本地脏数据汇总。证据：`res/values/strings_bitwarden_management.xml`、`src/bitwarden/ui/BitwardenSyncIssuesSheet.kt`。
85. **原始请求/响应历史** — 保存并预览同步请求、响应、同步快照，可隐藏原始数据。证据：`res/values/strings.xml`（`sync_raw_history`）、`src/bitwarden/api/BitwardenTransportBackup.kt`。
86. **Send 创建** — 文本/文件 Send，访问控制（密码/邮箱）、最大访问次数、有效天数、隐藏邮箱/文本。证据：`src/ui/screens/SendScreen.kt`、`src/ui/screens/BitwardenSendDraftUi.kt`。
87. **Send 接收** — 识别粘贴的 Send 链接、预览后打开；自托管服务需先确认目标；文件型提示 premium。证据：`src/bitwarden/api/BitwardenSendReceiverApi.kt`、`src/bitwarden/ui/BitwardenSendReceiverDialog.kt`、`res/values/strings_send_entry.xml`。
88. **Bitwarden JSON 导入** — 从 Bitwarden 导出 JSON 导入（含文件夹、Send、TOTP）。证据：`src/ui/screens/BitwardenJsonImportDialog.kt`、`src/bitwarden/export/`。
89. **Bitwarden JSON 导出** — 明文 JSON 与加密 JSON 两种导出。证据：`src/ui/screens/BitwardenJsonExportRequest.kt`、`src/ui/screens/ExportModels.kt`（`BITWARDEN_JSON`、`BITWARDEN_JSON_ENCRYPTED`）。
90. **缓存清理** — 安全清理与强制清理两档。证据：`res/values/strings.xml`（`clear_cache_safe/force`）、`src/bitwarden/cache/`。
91. **归档与回收站** — Bitwarden 条目归档/取消归档、回收站恢复，归档意图单独同步。证据：`src/bitwarden/BitwardenTrashRestoreStateHelper.kt`、`src/data/SecureItem.kt:71-73`。
92. **前台同步通知** — 同步过程显示前台通知（可配置渠道）。证据：`src/bitwarden/ui/BitwardenForegroundNotificationEffect.kt`、`src/bitwarden/ui/BitwardenAutoSyncEffect.kt`。

## 6. 附件与 Send（6 项）

93. **条目图片附件** — 证件正反面、银行卡、笔记均可附加图片，加密存储、轮播预览、可删除。证据：`src/attachments/ui/AttachmentCarousel.kt`、`src/attachments/ui/AttachmentsDetailSection.kt`、`src/attachments/data/AttachmentDao.kt`。
94. **卡面附件** — 银行卡自定义卡面图（裁剪、旋转、品牌图标、素材库）。证据：`src/ui/cardwallet/CardFaceCustomizer.kt`、`src/ui/cardwallet/CardFaceCropper.kt`、`src/ui/cardwallet/BankCardFaceArtwork.kt`。
95. **附件编辑与预览** — 附件编辑区、预览对话框、错误提示（加密不支持/远程数据/解密失败）。证据：`src/attachments/ui/AttachmentEditorContent.kt`、`src/attachments/ui/AttachmentPreviewDialog.kt`、`res/values/attachment_errors.xml`。
96. **附件随条目迁移** — 移动/复制条目时一并迁移附件（含 Bitwarden 上下文记忆）。证据：`src/attachments/ui/AttachmentAwareMoveDialog.kt`、`src/attachments/ui/RememberAttachmentBitwardenContext.kt`。
97. **附件纳入备份** — ZIP 备份可勾选 `images`/attachments，Passkey 与附件强制加密。证据：`res/values/zip_config_strings.xml`、`Monica Android发行说明.md`（导出加密要求）。
98. **Send 文件上传** — 选择文件、显示文件名/大小、上传后生成链接；文件型 Send 需要 premium。证据：`src/ui/screens/SendScreen.kt`（`send_select_file`、`send_file_premium_required_hint`）。

## 7. Steam（12 项）

99. **添加账号（4 种方式）** — maFile 导入、仅共享密钥、账号密码登录、二维码登录。证据：`src/steam/ui/SteamScreen.kt`、`res/values/strings.xml`（`steam_add_method_*`）。
100. **Steam Guard 验证码** — 5 位码生成、倒计时、复制、验证码选择器。证据：`src/steam/core/SteamTotp.kt`、`res/values/strings.xml`（`steam_authenticator_code_picker_*`）。
101. **确认管理** — 列出待确认交易，单个/批量批准或拒绝。证据：`src/steam/network/SteamConfirmationService.kt`、`res/values/strings.xml`（`steam_approve`、`steam_confirmation_*`）。
102. **登录批准** — 处理 QR 登录请求，批准/拒绝，含超时。证据：`src/steam/network/SteamLoginApprovalService.kt`、`src/steam/core/SteamLoginApprovalSigner.kt`。
103. **授权设备管理** — 列出已授权设备、撤销单台、全部注销（需密码确认）。证据：`src/steam/network/SteamAuthorizedDeviceService.kt`、`res/values/strings.xml`（`steam_authorized_device_*`）。
104. **身份信息** — SteamID64/SteamID3/SteamID2、好友码、资料页跳转、IP/位置/设备信息。证据：`res/values/strings.xml`（`steam_identity_*`、`steam_ip_label`）。
105. **maFile 导入/导出** — 单选/多选、格式校验、SteamID 补全、加密导出、导出前验证身份。证据：`src/steam/importer/SteamMaFileParser.kt`、`src/steam/importer/SteamMaFileCrypto.kt`、`src/data/SteamMaFileExportModels.kt`。
106. **库存与市场** — 库存搜索、最低价/中位价/近期高低/手动定价、上架/取消、批量出售、自动确认、手续费说明、高低价提示。证据：`src/steam/market/SteamInventoryService.kt`、`src/steam/market/SteamMarketService.kt`、`src/steam/ui/SteamBatchSellSheet.kt`。
107. **账号备注** — 为每个 Steam 账号添加备注并搜索。证据：`res/values/strings.xml`（`steam_edit_remark_title`）、`src/steam/ui/SteamSearchFilters.kt`。
108. **迷你资料背景** — 为账号设置迷你资料背景图，支持裁剪。证据：`src/steam/profile/SteamMiniProfileBackground.kt`、`src/steam/ui/SteamMiniProfileCrop.kt`。
109. **多存储源** — Steam 账号可存于本地、KeePass、Bitwarden、MDBX，并随之同步。证据：`src/steam/data/SteamKeePassAccountStore.kt`、`src/steam/data/SteamBitwardenAccountStore.kt`、`src/steam/data/SteamMdbxAccountStore.kt`。
110. **诊断日志** — Steam 模块独立诊断日志（可开关、可导出）。证据：`src/steam/diagnostics/SteamDiagLogger.kt`。

## 8. Passkey（13 项）

111. **系统凭据提供者** — 注册为 Android 14+ 凭据提供者（`BIND_CREDENTIAL_PROVIDER_SERVICE`），接管应用/网页 passkey 创建与登录。证据：`AndroidManifest.xml:303-318`、`res/xml/credential_provider_config.xml`、`src/passkey/MonicaCredentialProviderService.kt`。
112. **创建 Passkey** — 应用内创建页（选择账号、RP ID、用户名、可发现性、UV 要求）。证据：`src/passkey/PasskeyCreateActivity.kt`、`src/passkey/`。
113. **认证 Passkey** — 认证页选择凭据并完成断言，支持生物识别。证据：`src/passkey/PasskeyAuthActivity.kt`。
114. **Passkey 列表与搜索** — 列表、搜索、使用次数、可发现性标记、按 RP 分组。证据：`src/ui/screens/PasskeyListScreen.kt`、`src/ui/passkey/`。
115. **Passkey 详情** — rpId、用户名、创建时间、最近使用、使用次数、算法、transports、UV、同步状态、存储位置、绑定条目。证据：`src/ui/screens/PasskeyDetailScreen.kt`。
116. **删除 Passkey** — 删除并同步清理绑定。证据：`src/passkey/`（`PasskeyDelete*`）、`res/values/strings.xml`（`passkey_delete_*`）。
117. **跨设备 QR 扫描** — 扫描二维码完成 passkey 创建/认证（FIDO 混合流程）。证据：`src/navigation/Screens.kt:153`（`FidoQrScan`）、`src/ui/screens/QrScannerScreen.kt`。
118. **硬件安全密钥** — USB/NFC 安全密钥：连接、协议、AAGUID、固件、PIN 设置/修改、resident 凭据、创建/认证。证据：`src/passkey/hardware/HardwareSecurityKeyActivity.kt`、`res/values/hardware_key_strings.xml`。
119. **诊断** — 统计（保存数、top bucket）、诊断日志复制/清空/刷新。证据：`src/ui/screens/PasskeySettingsScreen.kt`、`res/values/strings_passkey_backup_diagnostics.xml`。
120. **严格/影子验证** — `strict` 与 `shadow` 两种校验模式，严格模式有风险提示。证据：`res/values/strings.xml`（`passkey_strict_validation_*`、`passkey_shadow_validation_*`）。
121. **批量移动** — 批量将 passkey 移动到其他库/存储（含可移植性策略）。证据：`src/passkey/PasskeyBatchMoveExecutor.kt`、`src/passkey/PasskeyBackupPortabilityPolicy.kt`、`res/values/strings_passkey_move.xml`。
122. **存储与备份策略** — 支持 KeePass 格式存储、备份可移植性判断、Bitwarden 旧格式迁移限制、view-only 模式。证据：`src/passkey/PasskeyCredentialDiscoveryPolicy.kt`、`src/passkey/PasskeyTransferPolicy.kt`、`res/values/strings_passkey_portability.xml`。
123. **Passkey 设置页** — 系统要求、安全、生物识别、同步、防钓鱼四项说明与开关。证据：`src/ui/screens/PasskeySettingsScreen.kt`、`src/navigation/Screens.kt:219`。

## 9. 自动填充（19 项）

124. **自动填充服务 V2** — 实现 `AutofillService`，支持字段解析、分区、数据集构建。证据：`src/autofill_ng/MonicaAutofillServiceNg.kt`、`res/xml/autofill_service_config.xml`。
125. **填充选择器** — V1 与 V2 两套 Picker，支持搜索、分类切换（密码/验证器/证件/银行卡）、收藏标记。证据：`src/autofill_ng/AutofillPickerActivity.kt`、`src/autofill_ng/AutofillPickerActivityV2.kt`。
126. **内联建议** — 在输入框下方内联展示建议（`autofill_inline_suggestions` + InlinePlaceholderActivity）。证据：`src/autofill_ng/AutofillInlinePlaceholderActivity.kt`、`src/ui/screens/SettingsSearchCatalog.kt`。
127. **保存提示** — 登录成功/表单提交后提示保存或更新；可关闭；可配置是否显示通知、智能标题、应用信息、网址信息。证据：`src/autofill_ng/AutofillSaveActivity.kt`、`src/autofill_ng/AutofillSaveTransparentActivity.kt`。
128. **强密码建议** — 注册/改密场景提供一键生成强密码并保存。证据：`src/autofill_ng/PasswordSuggestionActivity.kt`。
129. **阻止字段** — 用户指定永不填充的字段（按字段名/ID 规则），独立管理页。证据：`src/ui/screens/AutofillBlockedFieldsScreen.kt`、`src/navigation/Screens.kt:217`。
130. **阻止保存目标** — 指定永不提示保存的应用/网站，独立管理页。证据：`src/ui/screens/AutofillSaveBlockedTargetsScreen.kt`、`src/navigation/Screens.kt:218`。
131. **域名匹配策略** — 严格匹配、子域匹配、尊重 `autofillHints` 关闭标记、默认填充作用域，可配置。证据：`src/autofill_ng/DomainMatchStrategy.kt`、`src/ui/screens/SettingsSearchCatalog.kt`（`autofill_v2_strict_match`、`autofill_v2_subdomain_match`、`autofill_v2_respect_off`）。
132. **网址规则与黑名单** — 条目的 URL 规则存储、黑名单管理。证据：`src/autofill_ng/PasswordUrlRuleStore.kt`、`res/values/strings.xml`（`autofill_blacklist_manage`）。
133. **OTP 通知** — 通知栏常驻显示当前验证码（可选验证器、时长可调），支持自动复制到剪贴板。证据：`src/autofill_ng/service/AutofillOtpNotificationService.kt`、`AndroidManifest.xml:386`。
134. **活动填充通知** — 填充进行时显示通知，可关闭。证据：`res/values/autofill_protection_strings.xml`（`autofill_active_fill_notification_*`）。
135. **填充前认证** — 可选要求生物识别/主密码后才能使用自动填充（`autofill_auth_required`），含独立解锁/认证 Activity。证据：`src/autofill_ng/BiometricAuthActivity.kt`、`src/autofill_ng/AutofillAuthenticationActivity.kt`、`src/autofill_ng/AutofillUnlockActivity.kt`。
136. **应用绑定** — 条目可绑定应用包名/应用名，自动填充按前台应用匹配。证据：`src/data/PasswordEntryAppBindings.kt`、`src/data/PasswordEntry.kt:44-45`。
137. **钱包与 Wi-Fi 自动填充辅助** — 银行卡/地址/Wi-Fi 类型的专用填充分支。证据：`src/autofill_ng/WalletAutofillRepository.kt`、`src/autofill_ng/WifiAutofillAssist.kt`。
138. **快速设置磁贴** — 通知栏快捷开关直接唤出填充选择器（手动模式）。证据：`src/autofill_ng/service/AutofillTileService.kt:10-40`、`AndroidManifest.xml:374`。
139. **智能复制** — 复制后可排队继续复制用户名/验证码，通过实时通知提供"复制"动作并限时失效，避免剪贴板长期驻留。证据：`src/autofill_ng/utils/SmartCopyNotificationHelper.kt`、`src/autofill_ng/utils/SmartCopyReceiver.kt`。
140. **自动填充守护** — 无障碍服务常驻守护，配合 Shizuku/root 提权、后台保活、开机自启、电池优化豁免、通知权限，并提供"立即恢复"。证据：`src/autofill_ng/protection/AutofillProtectionService.kt`、`src/service/MonicaAccessibilityService.kt`、`res/values/autofill_protection_strings.xml`。
141. **设为系统默认密码管理器** — Android 14+ 系统"默认密码管理器"角色，或通过 Shizuku/root 写入设置；可恢复原管理器、可选择是否同时接管自动填充。证据：`src/ui/screens/DefaultPasswordManagerSheet.kt`、`res/values/default_manager.xml`、`src/autofill_ng/privilege/PrivilegeAccess.kt:14`。
142. **自动填充诊断** — 记录字段识别/匹配过程，导出诊断信息。证据：`res/values/autofill_diagnostic_strings.xml`。

## 10. 系统集成（13 项）

143. **内置输入法（IME）** — 独立输入法进程 `:ime`，键盘上方工具栏提供密码库填充、按账号搜索、排序（字母/相关度）、分类切换（密码/验证器/证件/银行卡）、TOTP 倒计时、收藏、内置密码生成器、按键震动、数字键随机化、隐藏 PIN 预览。证据：`src/ime/MonicaInputMethodService.kt`、`src/ime/MonicaInputMethodUi.kt`、`AndroidManifest.xml:455`、`res/values/strings.xml`（`ime_*`）。
144. **输入法解锁** — 输入法内独立解锁（密码或生物识别），不与主应用会话共享解锁状态，锁定时提供"打开应用"入口。证据：`src/ime/ImeUnlockActivity.kt`、`src/ime/ImeBiometricAuthActivity.kt`、`src/security/SecondarySessionManager.kt:9-30`。
145. **无障碍服务** — 用于自动填充守护与跨应用上下文识别。证据：`src/service/MonicaAccessibilityService.kt`、`res/xml/accessibility_service_config.xml`、`AndroidManifest.xml:443`。
146. **凭据提供者服务** — 见 111；系统级 passkey 入口。证据：`AndroidManifest.xml:303`。
147. **凭据交换（Credential Exchange）** — Android 14 `IMPORT_CREDENTIALS`：导出到其他密码管理器/文件（含密码、passkey、TOTP 计数与跳过原因），也接收其他应用导入。证据：`src/credentialexchange/CredentialExportActivity.kt`、`src/credentialexchange/CxfCredentialCodec.kt`、`res/values/credential_exchange.xml`。
148. **快速设置磁贴** — 见 138。证据：`src/autofill_ng/service/AutofillTileService.kt`。
149. **通知渠道族** — 验证器通知、智能复制实时通知、自动填充守护通知、同步前台通知、批量删除/迁移进度、更新提示。证据：`src/notifications/LiveUpdateNotifications.kt`、`src/service/NotificationValidatorService.kt`、`res/values/strings_live_updates.xml`。
150. **NFC 银行卡读取** — 贴卡读取公开 EMV 数据（卡号、可选持卡人/有效期），自动填入新建银行卡页，可确认替换已有值。证据：`src/nfc/card/NfcCardEntryController.kt`、`src/nfc/card/EmvCardReader.kt`、`AndroidManifest.xml`（`nfc_payment_tech`）。
151. **局域网/热点同步** — 见 178-180；二维码配对、LocalOnlyHotspot、mDNS 发现。证据：`src/lansync/NearbyHotspotSession.kt:36-130`、`src/lansync/DeviceSyncPresence.kt`。
152. **WorkManager 后台任务** — 自动备份（12h）、Bitwarden 同步（15min）、MDBX 自动同步、KeePass 远端上传。证据：`src/utils/AutoBackupManager.kt:48-60`、`src/bitwarden/sync/BitwardenSyncWorker.kt:92`、`src/workers/`。
153. **Shizuku / Root 提权** — 通过 Shizuku 或 `su` 执行特权操作（默认密码管理器、自动填充守护恢复）。证据：`src/autofill_ng/privilege/PrivilegeAccess.kt:14-17`、`AndroidManifest.xml:435-441`。
154. **otpauth 深链** — `otpauth://totp|hotp|yaotp` 直接打开新增验证器页。证据：`AndroidManifest.xml`（MainActivity intent-filter）。
155. **启动器别名伪装** — 多组 activity-alias（Monica / Snow Leopard / Classic / Lock / Home）与图标切换，用于隐藏应用真实身份。证据：`AndroidManifest.xml:160-270`、`src/ui/screens/AppLauncherIconSettings.kt`、`res/values/launcher_icon_strings.xml`。

## 11. 同步与备份（11 项）

156. **WebDAV 备份** — 服务器 URL/账号/密码、测试连接、立即备份、备份列表、删除/恢复、每次备份独立密码。证据：`src/ui/screens/WebDavBackupScreen.kt`、`src/webdav/WebDavBackupTransport.kt`。
157. **WebDAV 自动备份** — 开关 + 保留份数 + 变更触发（最小间隔、静默时段）+ 静默失败重试。证据：`res/values/strings.xml`（`webdav_auto_backup`、`webdav_change_triggered_*`、`webdav_retention_*`）。
158. **WebDAV 恢复** — 恢复前解密、恢复摘要（成功/重复/失败分项）、配置恢复检测（保留本地或覆盖）、恢复后重启倒计时。证据：`src/ui/screens/WebDavBackupScreen.kt`、`res/values/strings.xml`（`webdav_restore_*`）。
159. **OneDrive 备份** — 登录、选择/创建目录、上传备份、切换账号、目录缺失提示。证据：`src/ui/screens/OneDriveBackupScreen.kt`、`res/values/strings.xml`（`onedrive_backup_*`）。
160. **定时自动备份** — WorkManager 每 12 小时检查，按设定时间与网络/充电约束执行。证据：`src/utils/AutoBackupManager.kt:48-60`、`src/workers/AutoBackupWorker.kt:145-165`。
161. **备份加密格式** — V1（PBKDF2 100k，兼容默认）与 V2（PBKDF2 600k，增强），可选符合条件时明文导出；Passkey/附件/配置强制加密。证据：`src/data/BackupEncryptionFormat.kt`、`res/values/strings_backup_kdf.xml`、`Monica Android发行说明.md`。
162. **备份内容选择** — 密码、验证器、笔记、钱包、回收站、图片、时间线、本地 KeePass、WebDAV 配置、生成器历史、Passkey，全选/取消全选。证据：`src/ui/screens/ZipBackupOptionsContent.kt`、`res/values/zip_config_strings.xml`。
163. **局域网同步（LAN Sync）** — 二维码配对（生成/扫描/粘贴链接）、过期时间、连接状态、设备列表、删除配对设备。证据：`src/ui/screens/NearbySyncScreen.kt`、`src/lansync/LanPairing.kt`、`res/values/lan_sync.xml`。
164. **热点直连同步** — 创建 LocalOnlyHotspot 或加入对方热点，二维码传递 SSID/密码，mDNS/DNS-SD 发现。证据：`src/lansync/NearbyHotspotSession.kt:36-130`、`src/lansync/DeviceSyncPresence.kt:20-40`。
165. **同步范围与方向** — 选择数据库/范围、方向（发送/接收/双向）、频率（实时/每 N 分钟/自动）、冲突提示。证据：`res/values/nearby_sync.xml`、`src/ui/screens/NearbySyncScreen.kt`。
166. **同步队列页** — 集中查看待同步任务与失败原因。证据：`src/navigation/Screens.kt:249`、`src/bitwarden/ui/SyncQueueScreen.kt`。

## 12. 导入导出（9 项）

167. **导入来源** — Bitwarden JSON、Monica ZIP、KDBX、CSV 组、Aegis、Stratum 六类。证据：`src/ui/screens/ImportTypeOptions.kt:18-63`。
168. **CSV 子格式** — Monica 标准、KeePass CSV、Bitwarden CSV、Bitwarden Authenticator CSV、Proton Pass CSV、Chrome CSV、密码键盘 CSV。证据：`src/ui/screens/ImportTypeOptions.kt:66-135`。
169. **导入格式自动检测** — 读取文件头/结构自动判断格式并给出选项。证据：`src/ui/screens/ImportFormatDetection.kt`。
170. **导入冲突与重复处理** — 重复条目提示、跳过/覆盖策略、导入结果统计。证据：`src/ui/screens/ImportDialogs.kt`、`res/values/strings.xml`（`import_*`）。
171. **后台导入** — 大文件在后台执行并显示进度/可中断。证据：`src/transfer/BackgroundImportExecutor.kt`、`src/transfer/DatabaseExportService.kt`。
172. **导出格式** — ZIP 备份、KDBX、Steam maFile、Bitwarden JSON（明文/加密）五种。证据：`src/ui/screens/ExportModels.kt:6-12`。
173. **导出内容与加密选择** — 勾选内容 + 选择 V1/V2/明文加密档，先确认后执行。证据：`src/ui/screens/ExportDataScreen.kt`、`src/ui/screens/BackupEncryptionFormatSelector.kt`。
174. **Steam maFile 批量导出** — 多选账号、导出前校验与身份确认、可清空选择。证据：`res/values/strings.xml`（`steam_mafile_export_*`）、`src/data/SteamMaFileExportModels.kt`。
175. **外部 TOTP 导入** — 从其他应用通过 `content://` 分享的 otpauth 批量导入。证据：`src/external/ExternalTotpImportController.kt`。

## 13. 安全与隐私（17 项）

176. **主密码** — 本地主密码保护，PBKDF2-SHA256 600,000 次派生（1.0.327 起统一，移除算法切换）。证据：`src/security/PasswordKdf.kt`、`README.md`（安全模型段）。
177. **旧格式兼容迁移** — 兼容读取历史 PBKDF2 100k 与 Argon2id，验证原密码成功后迁移，保留原 MDK 与密文。证据：`src/security/PortableLocalCipherMigration.kt`、`Monica Android发行说明.md`。
178. **字段级加密** — AES-256-GCM 认证加密敏感字段，Android Keystore + EncryptedSharedPreferences 存密钥/配置。证据：`src/security/SecurityManager.kt`、`src/security/SensitiveValueEncryptor.kt`、`src/security/SecurePreferencesStore.kt`。
179. **生物识别解锁** — BiometricPrompt 解锁，含"弱生物识别"风险警告与确认。证据：`src/security/BiometricHelper.kt`、`src/ui/screens/SettingsScreen.kt`（`biometric_weak_warning_*`）。
180. **自动锁定** — 立即/1/5/10/15/30 分钟/1/5 小时/1 天/从不，可分别作用于主应用与次级入口。证据：`src/ui/screens/MasterPasswordLockingSettingsScreen.kt`、`src/security/lock/MainAppLockPolicy.kt`、`src/security/SecondarySessionManager.kt:17`。
181. **截屏保护** — 开启后阻止系统截屏/录屏（FLAG_SECURE）。证据：`src/ui/screens/SettingsScreen.kt`（`screenshot_protection`）、`res/values/strings.xml`（`screenshot_protection_enabled/disabled`）。
182. **安全问题找回** — 设置安全问题、验证答案重置主密码；答案加盐 PBKDF2 600k；尝试次数跨进程持久限制。证据：`src/ui/screens/SecurityQuestionsSetupScreen.kt`、`src/security/SecurityAnswerHash.kt`、`src/security/RecoveryAttemptLimiter.kt`。
183. **系统锁屏凭据二次确认** — Android 11+ 找回主密码需本次设备锁屏凭据确认；取消/后台/锁定即撤销授权。证据：`src/security/RecoveryAuthorization.kt`、`src/ui/screens/SecurityQuestionsVerificationScreen.kt`、`res/values/strings_recovery_authorization.xml`。
184. **主密码修改/重置** — 修改主密码（需当前密码）、忘记密码流程、重置（可跳过当前密码）、恢复后重启引导。证据：`src/ui/screens/ChangePasswordScreen.kt`、`src/ui/screens/ForgotPasswordScreen.kt`、`src/ui/screens/ResetPasswordScreen.kt`。
185. **本地存储恢复** — 检测存储损坏/密钥缺失，提供 `ConfirmedStorageRecovery` 与 `LocalVaultRecovery` 恢复路径、启动存储守卫。证据：`src/security/ConfirmedStorageRecovery.kt`、`src/security/LocalVaultRecovery.kt`、`src/security/StartupStorageGuard.kt`。
186. **安全分析** — 安全评分（0-100）、弱/中/强分布、重复密码、重复 URL、泄露次数、2FA 覆盖率、Passkey 覆盖率、不活跃 Passkey、可按来源（本地/KeePass/Bitwarden）分析、可自动分析。证据：`src/ui/screens/SecurityAnalysisScreen.kt`、`src/security/SecurityScoreCalculator.kt`、`src/data/SecurityAnalysisData.kt`。
187. **时间线与变更历史** — 记录创建/更新/删除/同步/快照/维护操作，字段级差异、批量复制/移动字段、恢复到编辑前/后、另存为新条目、敏感值默认隐藏、按类型/来源/时间过滤、自动清理。证据：`src/ui/screens/TimelineScreen.kt`、`src/ui/screens/TimelineSafetyPolicy.kt`、`src/data/OperationLog.kt`。
188. **剪贴板自动清除** — 可配置秒数或"从不"，复制后自动清空剪贴板。证据：`src/ui/screens/ExtensionsScreen.kt:206-332`、`res/values/strings.xml`（`clipboard_auto_clear`）。
189. **预览掩码** — 列表密码预览掩码、证件号掩码、敏感字段显示开关。证据：`src/security/PasswordListPreviewMask.kt`、`src/security/DocumentNumberPreviewMask.kt`、`src/ui/screens/TimelineScreen.kt`（`timeline_show_sensitive_values`）。
190. **会话与启动守卫** — 主/次会话分离、`MainTaskSessionGuard`、`StartupStorageGuard`、锁屏/后台自动锁定。证据：`src/security/SessionManager.kt`、`src/security/MainTaskSessionGuard.kt`、`src/security/SecondarySessionManager.kt`。
191. **开发者验证策略** — 开发者设置入口需额外验证（`DeveloperVerificationPolicy`），可禁用密码验证（仅调试）。证据：`src/security/DeveloperVerificationPolicy.kt`、`src/ui/screens/DeveloperSettingsScreen.kt`。
192. **敏感数据边界** — 日志脱敏、条码/卡号 toString 脱敏、诊断数据不含敏感值。证据：`src/security/BoundedSecureDataRead.kt`、`src/security/SecurityDiagLogger.kt`、`src/nfc/card/EmvCardReader.kt:15-25`。

## 14. 界面与个性化（17 项）

193. **主题模式** — 跟随系统/浅色/深色，OLED 纯黑（仅深色）。证据：`src/ui/screens/SettingsScreen.kt`（`theme_*`、`oled_pure_black`）。
194. **配色方案** — 15+ 内置配色（Black Mamba、Catppuccin 四款、Forest Green、Grey Style、Haystacks、Impression Sunrise、Japanese Bridge、Ocean Blue、Parliament Fog、Rouen Cathedral、Sunset Orange、Tech Purple、Water Lilies）+ 自定义取色。证据：`src/ui/screens/ColorSchemeSelectionScreen.kt`、`src/ui/screens/CustomColorSettingsScreen.kt`、`res/values/themes.xml`。
195. **进度条样式** — 线性 / 波浪（验证器倒计时进度条）。证据：`res/values/strings.xml`（`progress_bar_style_linear/wave`）、`src/ui/screens/PageAdjustmentCustomizationScreen.kt:653`。
196. **界面缩放** — 80%–120% 全局缩放（DP 密度换算）。证据：`src/data/InterfaceScale.kt:6-22`、`src/ui/screens/InterfaceScaleSettingsContent.kt`。
197. **语言** — 15 种：跟随系统、英、简中、繁中、文言文（`b+lzh`）、日、韩、俄、德、西、法、葡（葡/巴）、波兰、意大利、越南。证据：`res/` 下 15 个 `values-*` 语言目录、`src/ui/screens/LanguageSelectionDialog.kt`、`res/values/language_selection.xml`。
198. **底部导航定制** — 显示/隐藏标签（至少保留一个）、拖动排序、单标签自动隐藏。证据：`src/ui/screens/SettingsScreen.kt:1726`、`res/values/strings.xml`（`bottom_nav_*`）。
199. **页面调整** — 层级布局开关、启动自动聚焦搜索、总览开关、钱包堆叠循环。证据：`src/ui/screens/PageAdjustmentCustomizationScreen.kt`、`res/values/page_adjustment_strings.xml`。
200. **密码卡片调整** — 显示内容（全部/标题+用户名/仅标题）、显示绑定验证器、验证器存在时隐藏其他内容、分组模式、堆叠模式、网站堆叠匹配。证据：`src/ui/screens/PageAdjustmentCustomizationScreen.kt:520`、`res/values/strings.xml`（`password_card_*`）。
201. **验证器卡片调整** — 显示内容、统一进度条、进度条样式。证据：`src/ui/screens/PageAdjustmentCustomizationScreen.kt:653`。
202. **密码字段定制** — 用户名/账号分离显示、自定义显示字段顺序与可见性。证据：`src/ui/screens/PasswordFieldCustomizationScreen.kt`、`res/values/strings_customization_children.xml`。
203. **密码列表自定义** — 聚合开关、快速筛选、分类快捷筛选、文件夹路径横幅、系统返回键回到父文件夹、快速访问。证据：`src/ui/screens/PageAdjustmentCustomizationScreen.kt:275`、`res/values/strings.xml`（`password_list_*`）。
204. **图标设置** — 应用图标与名称（启动器别名）、页面级图标开关、主开关、未匹配策略、来源优先级、图标源。证据：`src/ui/screens/PageAdjustmentCustomizationScreen.kt:792`、`src/ui/screens/AppLauncherIconSettings.kt`、`res/values/launcher_icon_colors.xml`。
205. **条目自定义图标** — 内置简单图标（slug）、本地上传图片、内置品牌图标库（可搜索）、远程图标源（URL 添加/刷新/删除/搜索）。证据：`src/data/PasswordEntry.kt:110-114`、`res/values/image_subscriptions.xml`。
206. **常用账号模板** — 预置用户名/邮箱/电话，创建条目时一键套用并自动填充。证据：`src/ui/screens/CommonAccountTemplatesScreen.kt`、`src/data/CommonAccountPreferences.kt`。
207. **交互细节** — 触感反馈开关、滑动选择模式（单选/连续）、卡片显示模式、堆叠展开/收起。证据：`src/ui/screens/ExtensionsScreen.kt:206-332`、`res/values/wallet_selection_strings.xml`。
208. **快速初始化向导** — 多步引导：欢迎、预设布局（极简/日常/分页/验证器/预留）、外观、底部导航、密码卡片、验证器卡片、数据导入、Plus、完成；支持实时预览。证据：`src/ui/screens/QuickSetupScreen.kt`、`src/data/QuickSetupPreset.kt`、`res/values/quick_setup_strings.xml`。
209. **主题化外观细节** — Material 3 Expressive 组件、卡片组/连续字段卡片、页面对话框动效。证据：`README.md`（UI 层说明）、`res/values/page_dialog_motion.xml`。

## 15. 通知 / 小组件 / 快捷方式（5 项）

210. **无桌面小组件** — `res/` 下无 `appwidget` 目录与 `AppWidgetProvider`，Android 版不提供桌面小组件。证据：`res/` 目录树、`AndroidManifest.xml`。
211. **无应用快捷方式（App Shortcuts）** — 无 shortcuts.xml，长按图标无静态快捷方式。证据：`res/xml/` 仅 6 个配置文件。
212. **验证器通知** — 常驻通知显示所选验证器的实时验证码与倒计时（`NotificationValidatorService` + `AutofillOtpNotificationService`）。证据：`src/service/NotificationValidatorService.kt`、`src/service/ValidatorContextManager.kt`、`AndroidManifest.xml:386-412`。
213. **实时通知（Live Updates）** — 智能复制状态以实时通知呈现（秒级倒计时、解锁后可复制）。证据：`src/notifications/LiveUpdateNotifications.kt`、`res/values/strings_live_updates.xml`。
214. **后台任务与进度通知** — 批量删除、批量迁移、导入、导出（前台服务 `dataSync`）显示进度与完成汇总。证据：`src/transfer/DatabaseExportService.kt`、`res/values/background_tasks.xml`、`res/values/bulk_delete.xml`。

## 16. 其他（更新、支持作者、Plus/支付、权限管理、开发者工具）（12 项）

215. **应用更新检查** — 每日自动检查（默认开，可关）、仅解锁后前台检查、版本对比、Markdown 更新说明滚动、跳过此版本、查看详情/稍后、F-Droid 来源跳转。证据：`src/update/AppUpdateController.kt`、`src/update/AppUpdateDialog.kt`、`res/values/strings_app_updates.xml`。
216. **更新安全校验** — 下载 APK 校验（签名/包名），`AppUpdateSecurityGuard`。证据：`src/security/AppUpdateSecurityGuard.kt`、`src/update/AppUpdatePolicy.kt`。
217. **支持作者** — 爱发电 / Ko-fi / PayPal / Liberapay 链接、收款二维码展示与保存。证据：`src/ui/screens/SupportAuthorScreen.kt`、`res/values/liberapay.xml`。
218. **Monica Plus** — 激活码激活状态、功能列表与锁定态、Plus 引导页。证据：`src/ui/screens/MonicaPlusScreen.kt`、`src/data/PlusFeature.kt`。
219. **Plus 付费功能** — 高级主题、通知验证器、验证器震动、复制下一个验证码、Bitwarden 同步、KeePass WebDAV。证据：`res/values/strings.xml`（`plus_feature_*`）、`src/data/PlusFeature.kt:20-55`。
220. **支付页** — 爱发电 / Liberapay / PayPal 三种渠道、二维码、付款确认与解锁确认。证据：`src/ui/screens/PaymentScreen.kt`、`res/values/plus_payment_confirmation.xml`。
221. **权限管理页** — 清单式列出运行时/特殊/自动权限，显示已授予/未授予/受版本限制，可跳转系统设置；含 Shizuku、无障碍、输入法、凭据提供者等特殊项。证据：`src/ui/screens/PermissionManagementScreen.kt`、`src/repository/PermissionRepository.kt:100-160`、`res/values/permission_inventory.xml`。
222. **开发者设置** — 日志缓冲区（查看/复制/分享/清空）、Bitwarden 取证目录与原始报文开关、禁用密码验证、会话状态、默认密码管理器、MDBX 格式说明。证据：`src/ui/screens/DeveloperSettingsScreen.kt`、`res/values/developer_logs.xml`。
223. **开发者日志页** — 按来源过滤、搜索、事件详情展开、结果计数、导出。证据：`src/ui/screens/DeveloperLogsScreen.kt`、`src/ui/screens/DeveloperLogModels.kt`。
224. **预览功能** — 实验性功能开关入口（`preview_features_title`）。证据：`src/ui/screens/SettingsScreen.kt:836-838`、`src/ui/screens/PreviewFeaturesDialog.kt`。
225. **密码生成器** — 密码/口令/PIN/随机符号/用户名/SSH 密钥/GPG 密钥七类；长度、字符集、排除易混字符、自定义符号、自定义分隔符/词表、最小字符数要求、强度评估、生成历史（按类型过滤/删除）、常见密码分析。证据：`src/ui/screens/GeneratorScreen.kt`、`src/data/SymbolPasswordGeneratorOptions.kt`、`src/data/PasswordGenerationHistory.kt`。
226. **数据库管理器** — 本地库列表、打开/切换、重命名、双库并列、字段转移、只读标记、技术详情、搜索与刷新。证据：`src/ui/screens/DatabaseManagerScreen.kt`、`src/ui/screens/DatabaseManagerMenu.kt`。

---

## Android 平台专属能力

以下能力依赖 Android 独有 API/系统角色，iOS 无等价物或需完全不同的实现路径。

1. **自动填充框架（AutofillService）** — `BIND_AUTOFILL_SERVICE` 权限 + `res/xml/autofill_service_config.xml` 声明字段/保存类型；通过 `AssistStructure` 解析视图树，`Dataset` 回填。iOS 对应物只有 Credential Provider Extension（ASI 完全不同，且不能任意读取第三方 App 的输入框）。
2. **无障碍服务（AccessibilityService）** — `BIND_ACCESSIBILITY_SERVICE` + `accessibility_service_config`；用于自动填充守护/保活与跨应用上下文捕获（`src/service/MonicaAccessibilityService.kt`）。
3. **输入法（InputMethodService）** — 独立进程 `:ime` 的自绘键盘（`MonicaInputMethodService` + `MonicaKeyboardLayout`），在键盘内直接检索/填充密码库；iOS 的自定义键盘受"不允许访问网络/共享容器受限"限制，无法做到同等体验。
4. **凭据提供者（CredentialProviderService，Android 14+）** — `BIND_CREDENTIAL_PROVIDER_SERVICE` + `credential_provider_config`，是系统 passkey 的官方接入点；iOS 对应 AuthenticationServices 的 Credential Provider Extension，但 API/能力不同。
5. **凭据交换（Credential Exchange，Android 14+）** — `androidx.identitycredentials.action.IMPORT_CREDENTIALS` intent + CXF 编解码；iOS 无同名机制（有 Credential Exchange 概念但实现与限制不同）。
6. **快速设置磁贴（TileService）** — `android.service.quicksettings.TileService`，通知栏下拉一键唤出填充面板（`AutofillTileService`）。
7. **前台服务（Foreground Service）** — `connectedDevice`（局域网同步）、`dataSync`（导入导出）、`specialUse`（自动填充守护/验证器通知）；对应常驻通知与后台持续运行能力。
8. **NFC（IsoDep/EMV）** — `TECH_DISCOVERED` + `nfc_payment_tech` + `NfcAdapter.enableReaderMode` 风格读取；读取公开 EMV 应用数据（卡号/有效期/持卡人）。iOS 的 Core NFC 对支付卡 EMV 读取限制严格得多（需 entitlement，且通常不允许读取 PAN）。
9. **WorkManager 周期任务** — 12 小时自动备份、15 分钟 Bitwarden 同步、MDBX 自动同步；iOS 只能依赖 BGTaskScheduler（执行时机不可控）。
10. **LocalOnlyHotspot + WifiNetworkSpecifier + NsdManager（DNS-SD）** — 无网络环境下的设备间直连同步（`NearbyHotspotSession.kt`、`DeviceSyncPresence.kt`）；iOS 对应 MultipeerConnectivity/AWDL 完全不同。
11. **开机自启与包替换广播** — `BOOT_COMPLETED`（自动填充守护恢复）、`PACKAGE_REPLACED`（凭据提供者刷新）、`MY_PACKAGE_REPLACED`；iOS 无等价广播。
12. **电池优化豁免** — `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` + `isIgnoringBatteryOptimizations` 检测，保证自动填充守护存活。
13. **悬浮窗（SYSTEM_ALERT_WINDOW / TYPE_APPLICATION_OVERLAY）** — HyperOS 等系统上的"保存提示"悬浮层（`AutofillSaveOverlay.kt`、`HyperOsSaveOverlayPermission.kt`）。
14. **Shizuku / Root 提权** — 通过 `ShizukuProvider`（`moe.shizuku.privileged.api`）或 `su` 执行特权命令，用于强制设置默认密码管理器、恢复自动填充守护（`PrivilegeAccess.kt`）。
15. **启动器 activity-alias 伪装** — 多组 `activity-alias` 动态启停，实现应用图标/名称切换（Monica / Snow Leopard / Classic / Lock / Home）。
16. **Promoted / Live Update 通知** — `POST_PROMOTED_NOTIFICATIONS` 权限与实时通知样式（Android 16 特性），用于智能复制倒计时（`LiveUpdateNotifications.kt`）。
17. **otpauth 深链** — `otpauth://totp|hotp|yaotp` intent-filter，可从任意应用/浏览器直接新增验证器。
18. **NFC 支付卡读取的 UnionPay 兼容** — 自定义 APDU 应用选择与 Track 1 解析（`EmvCardReader.kt`，1.0.327 改进）。

## 可能受 iOS 限制或需付费开发者账号的能力

> 以下仅为候选清单，未核实 Apple 具体条款；需在开 issue 前逐条确认。

1. **自动填充的"任意字段"填充** — iOS Credential Provider Extension 只能填充被系统识别的用户名/密码/验证码字段，无法像 Android 那样解析任意视图树并按自定义规则匹配（影响阻塞字段、内联建议、强密码建议）。
2. **输入法内直接检索密码库** — iOS 自定义键盘默认无网络与共享容器访问权限（需 `RequestsOpenAccess`），且不能与主 App 实时共享解锁会话；Android 的 `:ime` 进程 + 次级会话模型难以复刻。
3. **应用图标/名称伪装（Launcher alias）** — iOS 不允许运行时切换 App 图标名称的多套"马甲"（`CFBundleAlternateIcons` 只能换图标，名称与图标数量受限，且需预先打包）。
4. **后台常驻自动填充守护** — iOS 无长期后台服务/无障碍服务，无法保持守护进程与开机自启。
5. **快速设置磁贴 / 通知栏快捷入口** — iOS 无 QS Tile；只能通过快捷指令/锁屏控件部分替代。
6. **NFC 银行卡号读取** — iOS Core NFC 读取支付卡 PAN 通常需要特定 entitlement 与卡组织授权，普通开发者账号大概率不可用。
7. **局域网直连同步（热点 + mDNS）** — iOS 无 LocalOnlyHotspot；需改用 MultipeerConnectivity/AWDL，且后台受限；本地网络权限需 `NSLocalNetworkUsageDescription`。
8. **凭据提供者（Passkey）** — iOS 需 `AuthenticationServices` Credential Provider Extension，需付费开发者账号与特定 entitlement；且不能像 Android 那样自由选择存储后端（KeePass/MDBX）。
9. **凭据交换批量导出** — iOS 的密码管理器导入导出受系统分享/文件访问限制，跨 App 批量迁移能力弱于 Android CXF。
10. **应用更新自更新（APK 下载安装）** — iOS 禁止侧载/自更新，只能跳转 App Store；`REQUEST_INSTALL_PACKAGES` 与 F-Droid 渠道不可移植。
11. **默认密码管理器角色** — iOS 只允许在"设置 → 密码"中选择，且不允许应用主动写入/切换（Android 14 RoleManager + Shizuku 可编程）。
12. **屏幕截图保护** — iOS 只能对特定视图使用 `isSecureTextEntry`/截屏检测，无法全局 FLAG_SECURE。
13. **文件系统任意目录访问** — Android 可通过 SAF/自定义目录保存 MDBX/KDBX，iOS 仅 App 沙盒 + 文件 App 暴露目录。
14. **TOTP 通知常驻显示** — iOS 通知不能长期驻留并每秒刷新倒计时；需改用 Live Activity（需 WidgetKit + 推送/ActivityKit，成本更高）。
15. **Shizuku/Root 类提权** — iOS 完全不存在，相关"强制设为默认/守护恢复"功能需删除或改为引导用户手动设置。
