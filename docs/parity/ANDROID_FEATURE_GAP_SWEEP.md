# Android → iOS 功能差距全量清扫（2026-11-21）

> 只读分析产物：不改代码、不提 issue、不合并 PR。文中的 iOS 行号全部在当前 `origin/main` 工作树上重新定位；
> 旧文档 `ANDROID_IOS_PARITY.md` / `MISSING_FEATURES.md` 的行号对应 `origin/main@90b3164`，重构后已失效，本文不沿用。
> 关联：#67（Android 功能对齐跟踪）。范围：Android→iOS 的单向差距，不含 iOS 独有能力与纯设计差异。

## 1. 方法与基线

| 项目 | 值 |
| --- | --- |
| Android 基线 | `e63d0cea`（`monica-android/main`，2026-11-12「fix(android): require device credentials for password recovery [skip ci]」），只读快照 `/tmp/android-main/Monica for Android` |
| Android 本地检出 | `d4b30488e`（2026-06-04）远落后于上游，**不作为基线**，仅用于交叉验证 |
| iOS 基线 | `1bfcf4f2f2bd648afd613f9b4a1cb42b4864ae51`（`origin/main`），worktree `.agents/worktrees/parity-sweep`，分支 `docs/parity-gap-sweep` |
| Android 扫描量 | 499 个 `.kt`：`ui/screens` 165、`viewmodel` 28、`repository` 50、`autofill_ng` 109、`data` 111、`webdav` 15、`external` 1、`sync` 7、`transfer` 13 |
| iOS 扫描量 | 235 个 `.swift`：`App` 87、`SwiftPackages` 129、`Extensions` 7、`Tests` 12 |
| 去重依据 | `gh issue list --state all`（#10–#134）+ 上述两份 parity 文档全文 |

**方法**

1. 先读 `docs/parity/ANDROID_IOS_PARITY.md`、`docs/parity/MISSING_FEATURES.md`，把已记录项全部排除；再按 issue 实际状态区分「已交付（CLOSED）」与「已立项（OPEN）」。
2. 以 Android 的 `navigation/Screens.kt`（81 个路由）、`ui/screens/SettingsSearchCatalog.kt`（设置项索引）和 `ui/screens` 文件清单为功能索引，逐屏提取用户可见能力。
3. 对每个候选，在 iOS 用中文名、英文名、类型名、API 名多轮 grep（`App/`、`SwiftPackages/`、`Extensions/`、`Tests/`），并打开命中文件确认是「同功能」而非同名不同义。
4. 只有同时满足「Android 有真实实现 + iOS 多轮搜索 0 命中 + 无等价入口/替代路径」才判「缺失」；有部分实现判「部分」并写明缺哪一段。
5. 平台能力先按 Apple 公开 API 判断，绝不把「搜不到」直接等同于「不可实现」；不可实现项在第 4 节逐条给系统限制。

**基线漂移提醒**：iOS 已拆分 `AppRootView.swift`（现 1000 行）到 `App/MonicaApp/AppRoot/AppSessionModel.swift`（13852 行），
`MonicaStorage.swift` 现 15306 行；任何引用旧行号的文档/评论都需要重新定位后再使用。

## 2. 差距表

按用户价值排序。分类：`可实现` = iOS 可实现且无需新依赖；`需新依赖` = 需引入第三方库；`不可实现` = 受 iOS 系统限制。

| # | Android 功能（证据 `path:line`） | iOS 现状（证据 / 已搜路径） | 分类 | 建议 issue 标题 | 建议范围 |
| --- | --- | --- | --- | --- | --- |
| 1 | 设置内搜索：`ui/screens/SettingsSearchCatalog.kt:11` 建立全部设置项索引（121 行），`ui/screens/SettingsSearchIndex.kt:20` `searchSettings`（NFKC 归一化、多词 AND、rank 0–6），配套 `SettingsSearchResults.kt`、`SettingsSearchNavigation.kt` | **缺失**。`App/MonicaApp/SettingsRootView.swift:23` 只有 `keePassAttachmentSearchText`（:925「搜索 KeePass 附件」），设置根视图无 `.searchable`。已搜 `App/`、`SwiftPackages/`：`settingsSearch`、`SettingsSearch`、`设置搜索`、`searchable`（13 处均非设置页）、`SettingsSearchIndex` | 可实现 | 设置内搜索：为全部设置项建立可检索索引 | 1. 稳定 id 索引（标题/路径/关键词/同义词），覆盖外观、自动填充、备份、同步、安全；<br>2. 设置页顶部 `.searchable` 实时过滤，结果显示路径面包屑；<br>3. NFKC + 忽略大小写 + 多词 AND，排序 标题 > 关键词 > 路径；<br>4. 点击结果滚动定位并高亮目标 section；<br>5. 索引与 UI 同源，新增设置项未登记时单测失败；<br>6. 纯本地、无网络，锁定态不检索敏感项 |
| 2 | WebDAV 自签名证书信任：`webdav/WebDavCertificateTrustStore.kt:22` `trust(host, fingerprint)`、`webdav/WebDavUntrustedCertificateException.kt:5`、`ui/screens/WebDavCertificateDialog.kt:20`（主机 + SHA-256 指纹 + 继续连接），`:45` `findWebDavCertificateError()` | **缺失**。`SwiftPackages/MonicaSync/Sources/MonicaSync/MonicaSync.swift:5324` `WebDAVClient`、`:5328` 默认 `URLSessionWebDAVTransport`，无证书回调；设置入口 `App/MonicaApp/SettingsRootView.swift:1573`。已搜 `App/`、`SwiftPackages/`：`URLAuthenticationChallenge`、`serverTrust`、`selfSigned`、`自签名`、`证书固定`、`pinning` | 可实现 | WebDAV 自签名证书：TOFU 指纹信任与撤销 | 1. URLSession delegate 处理 server trust，按 host 记录 SHA-256 指纹；<br>2. 未知证书弹窗显示主机、指纹、有效期，用户确认后持久化；<br>3. 支持撤销信任；证书更换必须重新确认；<br>4. 仅作用于 WebDAV 传输，不影响 CloudKit/MSAL 会话；<br>5. 指纹不匹配时硬失败并给出可诊断错误码；<br>6. 单测覆盖新主机/已知指纹/指纹变化 |
| 3 | 保险库打开失败恢复：`ui/screens/SecureStorageRecoveryScreen.kt:28`（重试 / 复制诊断 / 退出 / 主密码恢复），`:114` 诊断按钮；`MainActivity.kt:441` 启动打不开库时进入 | **缺失**。搜索 `App/MonicaApp`：`SecureStorageRecovery`、`恢复保险库`、`打开失败`、`启动诊断`；`AppCloudBackupSupport.swift:350` 与 `AppSessionModel+CloudVaultSync.swift:182` 只是普通错误文案 | 可实现 | 保险库打开失败：重试、诊断复制与主密码救援 | 1. 打开 MDBX/KDBX 失败进入专用恢复页，不静默退回登录；<br>2. 展示错误码/文件路径/大小/校验结果并提供重试；<br>3. 一键复制脱敏诊断（不含条目明文）；<br>4. 主密码确认后尝试从快照/备份恢复（复用 #30），失败不删除原文件；<br>5. 「删除本地库并从备份恢复」需二次确认；<br>6. 全程锁定态不渲染条目内容 |
| 4 | 按类型选择性清空数据：`ui/components/ClearDataSheetContent.kt:24`（密码/验证码/笔记/证件/银行卡/生成历史多选 + 主密码确认）、`:33` 标题；入口 `ui/screens/SettingsScreen.kt:645-646` | **缺失**。已搜 `App/`：`clearAllData`、`eraseAll`、`deleteAllData`、`清空所有数据`、`重置应用` = 0；现有删除只有逐库 `App/MonicaApp/AppRoot/VaultRegistryViews.swift:284`、`:302` | 可实现 | 按数据类型清空数据（主密码确认） | 1. 设置-数据管理入口，多选六类数据；<br>2. 主密码确认（或生物识别 + 主密码）；<br>3. 清空后重建索引、刷新搜索，时间线写一条脱敏记录；<br>4. 不删除设置、主密码与其他保险库；<br>5. 文案明确不可撤销并给二次确认；<br>6. 单测覆盖全选/部分选择/空选择 |
| 5 | 自动填充前设备验证：`ui/screens/AutofillSettingsV2Screen.kt:601`（`autofill_auth_required` 开关）+ `utils/SettingsManager.kt:273` | **部分**。`Extensions/MonicaAutoFillExtension/AutoFillCredentialProviderViewController.swift:641`、`:960`、`:983`、`:995` 仅通行密钥断言用 `LAContext.evaluatePolicy`；密码填充无门禁，`SettingsRootView.swift:528-611` 无该开关。已搜 `App/`、`Extensions/`：`填充需认证`、`autofill_auth`、`requireAuthBeforeFill`、`evaluatePolicy` | 可实现 | 自动填充前要求 Face ID / 设备口令 | 1. 设置开关并持久化；<br>2. 扩展返回密码前 `LAContext` 验证，取消则停留且不泄露；<br>3. 无生物识别回退设备口令，仍失败则拒绝；<br>4. 验证结果单次有效，不缓存；<br>5. 与通行密钥验证复用同一封装；<br>6. 真机覆盖取消/失败/回退分支 |
| 6 | 触感反馈与验证器振动：`ui/screens/ExtensionsScreen.kt:270-274`（haptic_feedback）、`:283-296`（Plus 验证器振动） | **缺失**。已搜 `App/`、`Extensions/`、`SwiftPackages/`：`haptic`、`Haptic`、`UIImpactFeedbackGenerator`、`UINotificationFeedbackGenerator`、`sensoryFeedback`、`震动` = 0 | 可实现 | 触感反馈开关与验证码卡片轻震 | 1. 总开关 + 验证器振动子开关；<br>2. 复制/保存/删除用 notification feedback，切换与选择用 selection；<br>3. 关闭后全 App 零触感调用；<br>4. 设置持久化并在重启后保持；<br>5. 低电量模式下自动降级（可选）；<br>6. 真机 iPhone/iPad 验证 |
| 7 | 到期自动复制下一个验证码（Plus）：`ui/screens/ExtensionsScreen.kt:283-296`、`ui/screens/SettingsSearchCatalog.kt:77` | **缺失**。已搜 `App/`、`Extensions/`、`SwiftPackages/`：`copyNextCode`、`nextCode`、`自动复制`、`autoCopyOTP`、`到期复制` = 0；`SensitivePasteboard` 只是敏感剪贴板封装 | 可实现 | 验证码到期时自动复制下一个码（Plus） | 1. 仅已购/Plus 开关可用；<br>2. 当前码剩余 ≤3s 时预取下一码并写剪贴板（sensitive 标记）；<br>3. 仅验证器页前台可见时生效，后台不写；<br>4. 与 #58 剪贴板自动清除联动；<br>5. 关闭后行为完全不变；<br>6. 单测覆盖跨周期，HOTP 不适用 |
| 8 | 图标全局体系：`ui/screens/PageAdjustmentCustomizationScreen.kt:795` `IconSettingsScreen`、`:832` 总开关、`:836-846` 页面开关、`:856` 未匹配策略（默认/首字母/隐藏）、`:862-873` 来源与优先级 | **部分**。仅逐条目 `App/MonicaApp/AppItemIconPickerView.swift`（catalog/SF Symbols）、`SwiftPackages/MonicaCore/Sources/MonicaCore/ItemIcon.swift:14`；已搜 `App/`、`SwiftPackages/`：`unmatched`、`图标来源`、`favicon`、`iconSource`、`图标优先级`、`iconCardsEnabled` = 0 | 可实现 | 条目图标：全局开关、未匹配回退策略与来源优先级 | 1. 全局「显示条目图标」+ 密码/验证/通行密钥分页面开关；<br>2. 未匹配策略：默认图标 / 首字母 / 隐藏；<br>3. 来源顺序（内置目录 > SF Symbol > 首字母）可配置；<br>4. 关闭图标后列表布局不跳动；<br>5. 迁移旧 `catalog:`/`sf:` 值；<br>6. 备份恢复后设置不变 |
| 9 | 列表批量选择：`ui/screens/ExtensionsScreen.kt:251`（swipe_selection_mode），密码列表/`ui/screens/CardWalletScreen.kt` 批量删除（删除前 `verify_identity_to_delete` 生物识别） | **部分**。回收站已有批量迁移（`SwiftPackages/MonicaStorage/Sources/MonicaStorage/TrashMaintenance.swift:658`），但主列表无多选：`App/MonicaApp` 全目录 `多选`/`selectedIDs`/`isSelecting`/`EditButton`/`editMode` 仅命中 `AppBillingSupport.swift:865`（卡与地址勾选） | 可实现 | 列表多选：批量删除、移动与加标签 | 1. 长按或滑动进入多选，顶部显示已选数量；<br>2. 批量删除前生物识别确认；<br>3. 批量移动到文件夹/分类并可撤销；<br>4. 与搜索/筛选/回收站状态一致；<br>5. 退出多选恢复原列表状态；<br>6. UI 测试覆盖全选、跨页选择与失败回滚 |
| 10 | otpauth 入站导入：`external/ExternalTotpImportController.kt:24-45`（ACTION_VIEW + 参数校验），`AndroidManifest.xml:132-134` 注册 `otpauth` totp/hotp/yaotp | **部分**。`App/MonicaApp/AppRoot/AppSessionModel.swift:1331-1351` `openDeepLinkURL` 只处理 `monica://open/`、快捷指令与 Send；App 内粘贴入口 `AppSessionModel.swift:5653`。已搜 `App/`：`otpauth://`、`onOpenURL`、`handleIncoming`、`URLTypes` | 可实现 | 从其他 App / 浏览器导入 otpauth:// 链接 | 1. Info.plist 注册 `otpauth` scheme（或分享扩展兜底）；<br>2. 解析并校验单条 URI（base32、算法、位数、周期、计数器）；<br>3. 锁定态暂存，解锁后弹确认再导入；<br>4. 重复条目提示合并/覆盖；<br>5. 拒绝批量/超长/非法参数并给错误；<br>6. 单测覆盖合法与非法 URI |
| 11 | 登录表单拆分字段：`ui/screens/PasswordFieldCustomizationScreen.kt:57`（`separate_username_account_title`）、`utils/SettingsManager.kt:292` | **缺失**。`App/MonicaApp/SettingsRootView.swift:219` 的「账号字段」是列表显示开关，不是编辑表单拆字段；已搜 `App/`：`separateUsername`、`单独用户名`、`usernameAccount`、`账号字段` | 可实现 | 登录条目：用户名与账号（邮箱/手机号）拆分字段 | 1. 设置开关，默认保持现状；<br>2. 编辑表单显示两字段并分别保存；<br>3. 旧数据迁移：username 保留、account 为空；<br>4. 复制与自动填充按目标字段语义选择；<br>5. 不破坏 Bitwarden/CXF 映射；<br>6. 单测覆盖迁移、导出与恢复 |
| 12 | 笔记瓷砖布局与图片标记：`ui/screens/NoteTileGridContent.kt:146`（`note_has_image`）、`NoteListControls.kt`（tile/standard 布局）、`NoteTileOrder.kt` | **部分**。`App/MonicaApp/AppMarkdownNotesView.swift` 为列表/编辑器；`LazyVGrid` 仅见于 `AppThemeSettingsView.swift`、`AppItemIconPickerView.swift`；无瓷砖布局与「含图片」角标。已搜 `App/`：`LazyVGrid`、`noteTile`、`瓷砖`、`note_has_image`、`图片角标` | 可实现 | 笔记列表：瓷砖网格布局与图片角标 | 1. 列表/瓷砖切换并持久化；<br>2. 瓷砖显示标题、摘要、更新时间与图片角标；<br>3. 大字体与密度设置下不裁切；<br>4. 与搜索、文件夹、回收站行为一致；<br>5. 列表模式保持现有交互；<br>6. 快照测试两种布局 |
| 13 | 启动自动聚焦搜索：`ui/screens/PageAdjustmentCustomizationScreen.kt:117-122`（含 testTag）、`ui/screens/SettingsSearchCatalog.kt:83` | **缺失**。已搜 `App/`：`autoFocus`、`autofocus`、`searchFocused`、`focusSearch`、`自动聚焦`、`启动搜索` = 0 | 可实现 | 启动时自动聚焦搜索框（可选） | 1. 设置开关；<br>2. 解锁进入密码页后聚焦搜索并弹出键盘；<br>3. 被深链/控制中心导航覆盖时不抢焦点；<br>4. 关闭后不改变现有焦点行为；<br>5. 兼容外接键盘与 Dynamic Type；<br>6. UI 测试验证键盘出现 |
| 14 | SSH 密钥生成：`viewmodel/GeneratorViewModel.kt:14`（`SshKeyGenerator`）、`utils/SshKeyGenerator.kt`、`ui/screens/AddEditSshKeyScreen.kt` | **部分**。条目类型与列表已存在（`SwiftPackages/MonicaStorage/Sources/MonicaStorage/MonicaStorage.swift:5827`、`App/MonicaApp/AndroidParityVaultHomeView.swift:571`），但 `App/MonicaApp/GeneratorAdvancedSections.swift:274-283` 明示「SSH 私钥生成尚未实现（跟踪 #20）」 | 可实现 | 生成 Ed25519 / RSA SSH 密钥对 | 1. 生成器支持 Ed25519 与 RSA 2048/3072/4096；<br>2. 私钥仅本地生成并用 Keychain 保护；<br>3. 展示并复制 OpenSSH 公钥与指纹；<br>4. 可保存为 SSH 条目；<br>5. 失败不产生半成品；<br>6. 单测校验格式与指纹 |
| 15 | 验证码进度条样式：`ui/screens/SettingsSearchCatalog.kt:116-119`（显示内容/统一进度条/进度条样式/平滑进度条）、`Screen.AuthenticatorCardAdjustment` | **部分**。`App/MonicaApp/AndroidParityVaultHomeView.swift:1886` 固定宽度线性进度条 + `:1897` 剩余秒，无样式设置；已搜 `App/`：`unifiedProgress`、`progressBarStyle`、`smoothProgress`、`进度条` = 0 | 可实现 | 验证码卡片进度条样式设置 | 1. 统一进度条开关（全部卡片共享一个周期）；<br>2. 样式：线性/环形；<br>3. 平滑动画开关，尊重「减弱动态效果」；<br>4. 关闭时保持现有线性条；<br>5. 设置持久化并作用于验证页与 Widget 快照；<br>6. 快照测试各样式 |
| 16 | 自动填充建议通知与内联建议：`ui/screens/AutofillSettingsV2Screen.kt:592`（填充通知）、`:654`（内联建议）、`ui/screens/AutofillProtectionScreen.kt:325` | **不可实现**。仅有系统 AutoFill 扩展入口，无跨 App 悬浮建议或通知式填充（详见第 4 节） | 不可实现 | —（不立项，归入 #39/#41 平台限制） | 记录在案，不做 |
| 17 | 后台常驻任务：`workers/AutoBackupWorker.kt`、`workers/MdbxAutoSyncWorker.kt`、`perf/PowerSaveModeController.kt` 的常驻/周期执行模型 | **不可实现**。iOS 仅 BGTaskScheduler 机会式调度（App 已用于「后台自动备份」，`SettingsRootView.swift:1592`），无法保证周期与常驻（详见第 4 节） | 不可实现 | —（不立项） | 记录在案，不做 |

### 2.1 缺失/部分项的搜索记录（补充）

- #1 设置搜索：iOS 搜 `settingsSearch`、`SettingsSearch`、`设置搜索`、`searchable`、`SettingsSearchIndex`；路径 `App/MonicaApp`、`SwiftPackages`。Android 搜 `settingsSearchEntries`、`searchSettings`、`SettingsSearch`。
- #2 WebDAV 证书：iOS 搜 `URLAuthenticationChallenge`、`serverTrust`、`selfSigned`、`自签名`、`pinning`；路径 `SwiftPackages/MonicaSync`、`App/MonicaApp`。Android 搜 `CertificateTrustStore`、`UntrustedCertificate`、`fingerprint`。
- #3 恢复页：iOS 搜 `SecureStorageRecovery`、`恢复保险库`、`打开失败`、`诊断`、`corrupt`；路径 `App/MonicaApp/AppRoot`。Android 搜 `SecureStorageRecoveryScreen`、`startup_diagnostic`。
- #4 清空数据：iOS 搜 `clearAllData`、`eraseAll`、`deleteAllData`、`清空所有数据`、`重置应用`；路径 `App/`。Android 搜 `ClearDataSheetContent`、`clear_all_data`、`data_type_`。
- #5 填充认证：iOS 搜 `autofill_auth`、`填充需认证`、`requireAuthBeforeFill`、`evaluatePolicy`、`LAContext`；路径 `Extensions/MonicaAutoFillExtension`、`App/MonicaApp`。Android 搜 `autofill_auth_required`、`AUTOFILL_AUTH_REQUIRED_KEY`。
- #6 触感：iOS 搜 `haptic`、`Haptic`、`UIImpactFeedbackGenerator`、`UINotificationFeedbackGenerator`、`sensoryFeedback`、`震动`；路径 `App/`、`Extensions/`、`SwiftPackages/`。Android 搜 `haptic_feedback`、`validator_vibration`。
- #7 下一码：iOS 搜 `copyNextCode`、`nextCode`、`自动复制`、`autoCopyOTP`、`到期`；路径 `App/`、`SwiftPackages/MonicaCore`。Android 搜 `copy_next_code_when_expiring`。
- #8 图标：iOS 搜 `unmatched`、`favicon`、`iconSource`、`图标来源`、`图标优先级`、`iconCardsEnabled`；路径 `App/MonicaApp`、`SwiftPackages/MonicaCore`。Android 搜 `IconSettingsScreen`、`UnmatchedIconHandlingStrategy`、`ImageSubscriptionBrowser`。
- #9 多选：iOS 搜 `多选`、`selectedIDs`、`isSelecting`、`EditButton`、`editMode`、`batch`；路径 `App/MonicaApp`。Android 搜 `swipe_selection_mode`、`verify_identity_to_delete`、`selectedIds`。
- #10 otpauth：iOS 搜 `otpauth://`、`onOpenURL`、`URLTypes`、`handleIncomingURL`；路径 `App/MonicaApp/AppRootView.swift`、`AppSessionModel.swift`。Android 搜 `ExternalTotpImportController`、`isExternalOtpAuthIntent`、manifest `scheme="otpauth"`。
- #11 拆字段：iOS 搜 `separateUsername`、`usernameAccount`、`单独用户名`、`账号字段`；路径 `App/`。Android 搜 `separate_username_account_title`、`SEPARATE_USERNAME_ACCOUNT_ENABLED_KEY`。
- #12 笔记瓷砖：iOS 搜 `LazyVGrid`、`noteTile`、`瓷砖`、`note_has_image`、`图片角标`；路径 `App/MonicaApp`。Android 搜 `NoteTileGridContent`、`note_has_image`。
- #13 自动聚焦：iOS 搜 `autoFocus`、`autofocus`、`searchFocused`、`focusSearch`、`自动聚焦`；路径 `App/`。Android 搜 `auto_focus_search_on_startup`。
- #14 SSH 生成：iOS 搜 `SshKeyGenerator`、`Curve25519`、`ed25519`、`ssh-keygen`；路径 `SwiftPackages`、`App/MonicaApp/GeneratorAdvancedSections.swift`。Android 搜 `SshKeyGenerator`、`sshKeyAlgorithm`。
- #15 进度条：iOS 搜 `unifiedProgress`、`progressBarStyle`、`smoothProgress`、`进度条`；路径 `App/MonicaApp`。Android 搜 `unified_progress_bar_title`、`validator_progress_bar_style`、`smooth_progress_bar_title`。

### 2.2 已核对、确认「不是差距」的候选（防止误报）

以下项在 Android 侧看起来像独有能力，逐一打开 iOS 实现后确认已有等价路径，故不立项：

1. **权限管理**：Android `ui/screens/PermissionManagementScreen.kt:47` 有运行时请求与分类统计；iOS 已有 `App/MonicaApp/AppRoot/AppSessionModel.swift:2866 permissionStatusRows` 与设置页 `SettingsRootView.swift:757` 的状态/跳转，属体验增强而非缺失。
2. **Bitwarden 同步队列**：Android `bitwarden/ui/SyncQueueScreen.kt` 更细；iOS `SettingsRootView.swift:1360-1377` 已有「重试队列 / 清空队列」两条恢复路径（`retryBitwardenPendingMutationQueue`、`clearBitwardenPendingMutationQueue`）。
3. **时间线敏感字段脱敏**：Android `ui/screens/TimelineSafetyPolicy.kt:9` 掩码密码字段；iOS `AppSessionModel.swift:13381-13406` 的 `redactedTimelineTitle` 会抹掉 URL 与 `password/token/secret` 参数，且锁定态不展示快照。
4. **扫码（二维码 / 条码 / 快速 TOTP）**：iOS `App/MonicaApp/ScannerAndStatusViews.swift:52-108`（`AVCaptureSession` + `AVCaptureMetadataOutput`）与 `AppBarcodeItemSupport.swift:435` 已具备相机扫码；Android 的多个 QrScanner 路由是入口拆分，不是能力差。
5. **KeePass KDBX 读写**：iOS `AppImportExportSupport.swift:186-188` 已有本地/云端 KDBX 写回；更完整的原生编辑器与云端库已由 #32/#33 立项覆盖，不重复。
6. **自动锁定**：iOS `SettingsRootView.swift:72` + `:209` 的 `Picker("自动锁定")` 已接 `AppAutoLockPolicy`；Android `MasterPasswordLockingSettingsScreen.kt` 多出的重置/密保入口属于 #55/#59 已交付范围。
7. **卡包堆叠与分组**：iOS `App/MonicaApp/AndroidParityVaultHomeView.swift:1707` 已有「堆叠分组」开关；卡包条目本身由 #11/#17 覆盖，剩余差异属视觉细节。
8. **导入格式**：iOS 已支持 monica CSV/JSON、Bitwarden、Aegis、Stratum、1Password、通用 CSV（`SwiftPackages/MonicaStorage/Sources/MonicaStorage/ImportExportFormats.swift:29-36`），与 Android 主流程对齐。
9. **主题 / 界面密度 / 页面布局**：#60、#61、#63 已交付并在规格里明确边界（四 Tab 不可改、不做运行时改应用名），本文不再开新条目。
10. **锁屏/后台隐私遮罩、剪贴板清除、Live Activity 验证码**：#46/#47/#58 已交付，属于第 3 节清单。
11. **凭证交换、OneDrive 目录、WebDAV 备份计划**：#48/#52 与「后台自动备份」开关（`SettingsRootView.swift:1592`）已交付；本文只报 WebDAV 的证书信任缺口。
12. **应用内更新、开发者日志、Widget 刷新**：#49/#65/#71 已交付，代码路径见第 3 节。

> 结论：把「同名不同义」和「已有部分实现」剔除后，真正的新增差距集中在设置可达性、WebDAV 网络信任、数据自救与少量表单/列表交互，而不是功能域缺失。

## 3. 已经覆盖、不要重复提的清单

状态取自 `gh issue list --state all`：`已交付` = CLOSED 且代码在当前 main 可达；`已立项` = OPEN。

| 编号 | 项 | 状态与证据（iOS） |
| --- | --- | --- |
| #16 | 多 URL / 应用绑定 / 密码历史 | 已交付；`LoginEntryDetail.swift`、详情页多 URL 编辑 |
| #15 | 自定义字段与条目关联 | 已交付；`VaultItemExtras.swift`、`LoginEntryDetail.swift` |
| #14 | SSO 条目 | 已交付；`MonicaStorage.swift:5830 case sso`、`:5959 case sso(LocalSSOEntryDraft)`，`MonicaStorageTests.swift:3424` 覆盖 |
| #13 | Steam 条目与 Steam Guard | 已交付；`MonicaSteamEntry.swift`、`SteamGuard.swift`、`AppSteamGuardSupport.swift` |
| #12 | GPG 密钥 | 已交付；`GPGKeyEntry.swift`、`AppGPGKeySupport.swift` |
| #17 | 卡面 / 证件照片 | 已交付；`BankCardFaceView.swift`、`IdentityDocumentPhotoSection.swift` |
| #10 | 条码 / 登机牌 | 已立项（OPEN）；`MonicaBarcodeEntry.swift`、`AppBarcodeItemSupport.swift` 已落地主体 |
| #11 | 账单地址 / 支付账户 | 已立项（OPEN）；`AppBillingSupport.swift:5` |
| #25 | 标签 / 排序 / 归档 | 已立项（OPEN）；标签筛选已有入口 `AppGlobalSearchView.swift:184`（全部标签），完整排序/归档仍在范围内 |
| #26 | 全局搜索 | 已交付；`AppGlobalSearchView.swift`、`VaultSearchIndex.swift` |
| #27 | 文件夹与库总览 | 已交付；`VaultFolderHierarchy.swift`、`VaultFolderBrowserView.swift`、`AppVaultHomeView` 总览 |
| #28 | 回收站保留与批量迁移 | 已交付；`TrashMaintenance.swift:658`、`AppTrashMaintenance.swift` |
| #29 | 多库与默认库 | 已交付；`VaultRegistry.swift`、`VaultRegistryViews.swift` |
| #30 | MDBX 快照 / 检查点 | 已交付；`VaultSnapshot.swift` |
| #32 | KeePass 原生库 | 已立项（OPEN） |
| #33 | KeePass 云端库与 Google Drive | 已立项（OPEN） |
| #34 | Bitwarden 同步 | 已交付；`BitwardenSyncMerge.swift`、`AppBitwardenSyncSupport.swift` |
| #36 | Monica Send | 已交付；`MonicaSendPackage.swift`、`MonicaSendShareView.swift` |
| #37 | 导入导出格式 | 已交付；`ImportExportFormats.swift`（monica/bitwarden/aegis/stratum/1password/generic） |
| #40 | 自动填充屏蔽字段 / 域名规则 | 已交付；`AppAutoFillSupport.swift`、`AppAutoFillDomainRules.swift` |
| #39 | 自动填充引导（引导部分） | 已交付；`AppAutoFillCenterView`、`AppAutoFillDefaultManagerGuideView.swift`（任意字段填充部分 OPEN，属第 4 节平台限制） |
| #41 | 第三方输入法限制引导 | 已立项（OPEN），引导已随 #39 交付 |
| #46 | 隐私遮罩与截图防护 | 已交付；`AppPrivacyShield.swift`、`ScreenPrivacy.swift`、`SensitivePreviewMasking.swift` |
| #47 | Live Activity 验证码 | 已交付；`MonicaAuthenticatorLiveActivityWidget`、`AppAuthenticatorLiveActivity.swift` |
| #49 | 应用内更新检查 | 已交付；`AppUpdateCheckView.swift`、`AppStoreUpdate.swift` |
| #60 / #50 | 主题 / 配色 / 备用图标 | 已交付；`AppThemeSettingsView.swift`、`AlternateAppIcon.swift`（运行时改应用名明确不做） |
| #65 | 开发诊断日志 | 已交付；`AppDiagnostics.swift`、`DiagnosticLog.swift` |
| #66 | 支持作者 Plus | 已立项（OPEN） |
| #76 | iCloud 同步 | 已交付；`AppCloudKitSync.swift` |
| #127 | 账号模板 | 已立项（OPEN） |
| #128 | 应用内语言 | 已立项（OPEN） |
| #129 | CXF 通行密钥往返 | 已立项（OPEN） |
| #56 | 安全洞察 | 已交付；`SecurityInsights.swift` |
| #58 | 剪贴板自动清除 | 已交付；`SensitivePasteboard.swift` |
| #45 | 控件中心 / 快捷指令 | 已交付；`MonicaControlCenterWidget`、`MonicaShortcutsAppIntents.swift` |
| #53 | 局域网同步 | 已交付；`AppLanSyncCoordinator.swift`、`LanSync/` |
| #31 | 云库同步 | 已交付；`AppCloudVaultSync.swift`、`CloudVault/` |
| #48 | 凭证交换 | 已交付；`CredentialExchange.swift`、`AppCredentialExchange.swift` |
| #52 | OneDrive 备份目录 | 已交付；`CloudFileBackupDirectories.swift` |
| #55 | 主密码修改 | 已交付；设置-主密码段 |
| #61 | 界面密度 | 已交付；设置-界面密度 + Dynamic Type |
| #62 | 本地化 | 已交付；`App/MonicaApp/Localizable.xcstrings`（#128 应用内语言仍 OPEN） |
| #63 | 外观定制 | 已交付；密码页模块顺序、卡片密度、列表字段显隐 |
| #72 | 隐私清单与合规 | 已交付；`App/MonicaApp/PrivacyInfo.xcprivacy`（Share/AutoFill/Widget 三个扩展各有一份） |
| #74 | 依赖升级 | 已交付 |
| #71 | Widget 刷新 | 已交付；`Extensions/MonicaWidgetExtension/MonicaWidget.swift:24 MonicaWidgetProvider`、`:35 getTimeline` |
| #59 | 安全问答 KDF | 已交付；`App/MonicaApp/AppRoot/AppSessionModel.swift:4486`（SecurityQuestionCredentialError，问答校验走 KDF） |
| #44 | NFC 银行卡诊断 | 已交付；`NFCCardProbe.swift`、`NFCBankCardProbeView.swift` |

## 4. iOS 不可实现的判定依据

- **自动填充建议通知 / 内联建议（#16）**：iOS 的第三方填充只能通过系统在键盘/QuickType 区域调起的 `ASCredentialProviderExtension` 返回凭据，App 不能在其他 App 界面上绘制悬浮建议、内联填充条或发送可交互的填充通知；没有跨 App overlay API。
- **后台常驻与精确周期任务（#17）**：iOS 不允许第三方 App 常驻后台；`BGAppRefreshTask` / `BGProcessingTask` 由系统按电量、使用习惯机会式调度，无法保证同步/备份在指定时间执行，也没有 Android 的前台服务与精确闹钟等价物。
- **已在 #39 / #41 / #46 / #50 记录、本次不重复立项的平台限制**：
  - 任意字段自动填充（#39）：无 AccessibilityService 等价 API，扩展只能填充系统识别为用户名/密码的字段。
  - 第三方输入法注入（#41）：键盘扩展运行在独立进程，无 Full Access 时不能读宿主文本，且无法读取 secure text field 内容、无法替用户点击宿主控件。
  - 截图/录屏拦截（#46）：iOS 无 FLAG_SECURE 等价 API，只能检测录屏/镜像并自绘遮罩，不能阻止系统截图。
  - 运行时修改应用名/马甲（#50）：显示名来自安装包 `Info.plist`，无公开 API 运行时变更（备用图标已单独交付）。
- **平台机制差异，不计为差距**：iOS 的自动填充域名匹配由系统按 associated domains 与用户选择决定，App 无法实现 Android 的「严格匹配 / 子域匹配 / 尊重 autofill hint / 默认作用域」开关；这些属于 Android 无障碍填充引擎的私有机制，不应照搬。

## 5. 建议的下一批 issue 清单

按价值排序；每条含标题、一句话目标、验收要点。

1. **设置内搜索：为全部设置项建立可检索索引**
 目标：让用户 3 次按键内找到任意设置项。
 - 索引覆盖外观、自动填充、备份、同步、安全、开发者；每项有稳定 id 与路径。
 - 顶部搜索实时过滤，显示面包屑路径，点击滚动定位并高亮。
 - NFKC + 多词 AND + 忽略大小写；排序 标题 > 关键词 > 路径。
 - 新增设置项未登记时单测失败；锁定态不检索敏感项。
2. **WebDAV 自签名证书：TOFU 指纹信任与撤销**
 目标：让自建 NAS/WebDAV 用户能完成备份与恢复。
 - 未知证书弹窗显示主机、SHA-256 指纹、有效期；确认后持久化。
 - 仅按 host 记录，证书更换需重新确认；支持撤销信任。
 - 指纹不匹配硬失败并给可诊断错误码；不影响 CloudKit/MSAL。
 - 单测覆盖新主机、已知指纹、指纹变化与撤销后重连。
3. **保险库打开失败：重试、诊断复制与主密码救援**
 目标：本地库损坏时用户能自救而不是看到登录页。
 - 打开失败进入恢复页，展示错误码、路径、大小、校验结果。
 - 重试、复制脱敏诊断、主密码确认后从快照/备份恢复。
 - 失败不删除原文件；删除本地库需二次确认。
 - 锁定态不渲染任何条目明文。
4. **按数据类型清空数据（主密码确认）**
 目标：支持只清某一类数据，而不必删整个保险库。
 - 六类数据多选：密码、验证码、笔记、证件、银行卡、生成历史。
 - 主密码确认；文案明确不可撤销。
 - 清空后重建索引并写脱敏时间线记录；不动设置与其他库。
 - 单测覆盖全选、部分选择、空选择。
5. **自动填充前要求 Face ID / 设备口令**
 目标：填充密码前增加一次设备属主验证。
 - 设置开关；扩展返回凭据前调用 `LAContext`。
 - 取消则停留且不泄露；无生物识别回退设备口令。
 - 验证结果单次有效；与通行密钥验证复用封装。
 - 真机覆盖取消、失败、回退三种分支。
6. **触感反馈开关与验证码卡片轻震**
 目标：给关键操作提供可关闭的触感反馈。
 - 总开关 + 验证器振动子开关，持久化。
 - 复制/保存/删除用 notification feedback；切换/选择用 selection。
 - 关闭后零调用；真机 iPhone/iPad 验证。
7. **条目图标：全局开关、未匹配回退策略与来源优先级**
 目标：统一控制图标显示，避免缺图标时列表参差。
 - 全局与分页面开关；未匹配策略：默认/首字母/隐藏。
 - 来源优先级可配置并持久化稳定 ID；关闭后布局不跳动。
 - 迁移旧 `catalog:`/`sf:` 值；备份恢复后保持。
8. **列表多选：批量删除、移动与加标签**
 目标：主列表支持多选批量操作，而不是逐条删除。
 - 长按/滑动进入多选，显示已选数量与全选。
 - 批量删除前生物识别确认；批量移动可撤销。
 - 与搜索、筛选、回收站状态一致；退出恢复原状态。
 - UI 测试覆盖全选、跨页选择与失败回滚。
9. **从其他 App / 浏览器导入 otpauth:// 链接**
 目标：点开别处的 otpauth 链接即可存入 Monica。
 - 注册 `otpauth` scheme 或提供分享扩展兜底。
 - 校验单条 URI（base32/算法/位数/周期/计数器）。
 - 锁定态暂存，解锁后确认导入；重复项提示合并/覆盖。
 - 非法/超长/批量 URI 拒绝并给错误；单测覆盖。
10. **笔记列表：瓷砖网格布局与图片角标**
 目标：笔记多时能像 Android 一样快速浏览。
 - 列表/瓷砖切换并持久化；瓷砖显示标题、摘要、时间、图片角标。
 - 大字体与密度设置下不裁切；与搜索/文件夹/回收站一致。
 - 列表模式保持现有交互；快照测试两种布局。
11. **到期自动复制下一个验证码（Plus）**
 目标：验证码翻页时剪贴板自动带上下一个码。
 - 仅 Plus 开关；剩余 ≤3s 预取下一码并敏感标记。
 - 仅验证器页前台可见时写入；与 #58 自动清除联动。
 - 关闭后行为完全不变；单测覆盖跨周期。
12. **登录条目：用户名与账号（邮箱/手机号）拆分字段**
 目标：同时保存用户名和账号，自动填充按字段语义选择。
 - 设置开关，默认保持现状；老数据迁移 username 保留、account 为空。
 - 编辑表单两字段；复制/填充按语义选择。
 - 不破坏 Bitwarden/CXF 映射；单测覆盖迁移与导出。
13. **生成 Ed25519 / RSA SSH 密钥对**
 目标：补齐生成器里长期显示「尚未实现」的 SSH 生成。
 - 支持 Ed25519 与 RSA 2048/3072/4096；私钥 Keychain 保护。
 - 展示并复制 OpenSSH 公钥与指纹；可保存为 SSH 条目。
 - 失败不产生半成品；单测校验格式与指纹。
14. **验证码卡片进度条样式设置**
 目标：统一/环形/平滑三种样式可选。
 - 统一进度条开关；线性/环形样式；平滑动画尊重减弱动态效果。
 - 关闭时保持现有线性条；设置持久化并作用于 Widget 快照。
 - 快照测试各样式。

## 6. 统计与限制

- 差距 17 条：iOS 可实现 15、需要新依赖 0、iOS 不可实现 2。
- 高价值可立即立项 8 条（#1–#8）；其余为体验增强或长尾。
- 限制：本次只读静态分析，未在真机验证 iOS 自动填充扩展与 Widget 行为；#32/#33 等 OPEN 长任务是文档的主要不确定性来源，只按「已立项」登记，不重复建 issue。
- 证据可复核：Android 侧全部使用 `/tmp/android-main/Monica for Android`（`e63d0cead`）行号；iOS 侧全部使用本 worktree（`1bfcf4f2`）行号。

## 附录 A. 功能索引与证据索引

**Android 侧索引（用于确认「功能存在」）**

- 路由总表：`navigation/Screens.kt`（81 个 route，覆盖设置、自动填充、KeePass、MDBX、备份、Plus、支付、同步队列等）。
- 设置项索引：`ui/screens/SettingsSearchCatalog.kt`（121 行，本次用它反查「哪些设置只在 Android 有」）；配套 `SettingsSearchIndex.kt`、`SettingsSearchResults.kt`、`SettingsSearchNavigation.kt`。
- 自动填充：`ui/screens/AutofillSettingsV2Screen.kt`（开关矩阵）、`ui/screens/AutofillBlockedFieldsScreen.kt`、`ui/screens/AutofillSaveBlockedTargetsScreen.kt`、`autofill_ng/`（109 文件）、`service/MonicaAccessibilityService.kt`、`service/BrowserAutofillContextStore.kt`。
- 数据与备份：`ui/screens/ImportDataScreen.kt`、`ExportDataScreen.kt`、`BackupEncryptionFormatSelector.kt`、`ZipBackupOptionsContent.kt`、`OneDriveBackupScreen.kt`、`WebDavBackupScreen.kt`、`transfer/`（13 文件）、`workers/AutoBackupWorker.kt`。
- 安全与锁：`ui/screens/MasterPasswordLockingSettingsScreen.kt`、`SecureStorageRecoveryScreen.kt`、`ui/components/ClearDataSheetContent.kt`、`security/`（33 文件）。
- 列表与外观：`ui/screens/PageAdjustmentCustomizationScreen.kt`、`NoteListControls.kt`、`NoteTileGridContent.kt`、`CardWalletScreen.kt`、`TimelineScreen.kt`。

**iOS 侧索引（用于确认「功能有无」）**

- 设置主入口：`App/MonicaApp/SettingsRootView.swift`（2534 行，全部 section 在此）。
- 会话与业务编排：`App/MonicaApp/AppRoot/AppSessionModel.swift`（13852 行）及 `AppRoot/` 下的 `AppAutoFillSupport.swift`、`AppBillingSupport.swift`、`AppOperationTimeline.swift`、`AppImportExportSupport.swift`、`AppCloudBackupSupport.swift`、`VaultRegistryViews.swift`。
- 自动填充扩展：`Extensions/MonicaAutoFillExtension/AutoFillCredentialProviderViewController.swift`（1057 行）。
- 存储与格式：`SwiftPackages/MonicaStorage/Sources/MonicaStorage/`（`ImportExportFormats.swift`、`VaultSearchIndex.swift`、`VaultFolderHierarchy.swift`、`TrashMaintenance.swift`、`VaultSnapshot.swift`）。
- 同步与云：`SwiftPackages/MonicaSync/Sources/MonicaSync/MonicaSync.swift`（5705 行，WebDAV/Bitwarden/云备份）、`CloudVault/`、`LanSync/`。
- 测试：`SwiftPackages/*/Tests/` 与 `Tests/MonicaTests`（本次用测试文件反向确认 #14/#15/#28/#30 等确有实现）。

**复核方式（给后续维护者）**

1. 先看 `SettingsSearchCatalog.kt` 是否有对应条目，再在 `SettingsRootView.swift` 找同名 section；两边都没有才进入「缺失」候选。
2. 任何「缺失」结论至少给 3 个搜索词（中文、英文、API 名）与 2 个搜索根目录的 0 命中记录。
3. 旧文档的行号一律作废；引用 iOS 代码必须重新 grep，避免 `AppRootView.swift:4528` 这类失效锚点。
4. 平台限制只引用 Apple 公开能力（ASCredentialProvider、BGTaskScheduler、Info.plist、UIScreen 捕获检测），不臆造 API。
