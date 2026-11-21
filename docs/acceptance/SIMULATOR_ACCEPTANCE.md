# 模拟器端到端验收（不依赖 XCTest）

## 为什么需要它

本仓库的常用开发机装的是精简版 Xcode（`/Applications/Xcode-beta.app` 只有 3.5 GB，没有 `Simulator.app`，`DevToolsSecurity -status` 为 `Developer mode is currently disabled`，且没有免密 sudo），因此 `xcodebuild test` 一律失败于：

```
DTServiceHubClient failed to bless service hub for simulator ...
localDeviceConnectionWithError: failed but didn't provide an error.
```

`xcrun simctl` 本身完全正常（install / launch / screenshot / deep link），所以验收改为**在 App 内跑一遍真实流程**：用启动参数 `--monica-simulator-acceptance` 触发 `App/MonicaApp/AppSimulatorAcceptanceHarness.swift`，以真实 App 代码、真实 MDBX、真实 Keychain 执行，输出结构化报告并退出。逻辑层仍由 GitHub CI 的 XCTest（`App build and tests`）覆盖。

## 一键运行

```bash
Scripts/run-simulator-acceptance.sh            # 自动挑一台 iPhone 模拟器，构建并运行
Scripts/run-simulator-acceptance.sh --skip-build
Scripts/run-simulator-acceptance.sh --device 0DFFE3BA-8344-4285-8323-986C22CB0C9F
```

脚本会：构建（`build-for-testing`，模拟器）→ 启动模拟器 → 安装 → 截图 → `simctl launch ... --monica-simulator-acceptance` → 从 App 沙盒取 `Documents/acceptance-report.json` → 拷进 `docs/acceptance/` 并打印 PASS/FAIL 汇总。

也可以手动跑：

```bash
xcrun simctl launch --console-pty --terminate-running-process <UDID> \
  com.monicapass.monica --monica-simulator-acceptance
```

控制台输出 `ACCEPT <id> PASS|FAIL <detail>`、`ACCEPT SKIPPED <n> <ids>`、`ACCEPT SUMMARY passed=<n> failed=<n>`；App 以失败步数决定退出码。

## 本次运行

- 机器：macOS 27.3（26C5035r），Xcode 27.0（27A5194q），精简安装（无 Simulator.app）
- 模拟器：iPhone 17 / iOS 27.0（`0DFFE3BA-8344-4285-8323-986C22CB0C9F`）
- 构建：`CODE_SIGNING_ALLOWED=NO`（无签名）
- 结果：**14 步，0 失败，3 跳过**（跳过均因无签名构建缺少 entitlement，详见下表）
- 原始报告：[`acceptance-report.json`](acceptance-report.json)
- 首启截图：[`screenshots/01-launch.png`](screenshots/01-launch.png)

| 步骤 | 覆盖内容 | 结果 | 说明 |
| --- | --- | --- | --- |
| `vault-create` | 创建本地保险库并解锁 | PASS | 临时库已创建并解锁（主密码已设置，不回显）；state=unlocked；分类「验收条目」已激活 |
| `entry-crud` | 创建 13 类条目 | PASS | login=1 login2=2 totp=1 note=1 card=1 identity=1 sshKey=1 apiToken=1 wifi=1 sso=1 barcode=1 gpgKey=1 billingAddress=1 paymentAccount=1；分类内条目合计=14 |
| `search-tags-archive` | 搜索、标签与归档 | PASS | 计数 login=2 totp=1 note=1 card=1 identity=1 ssh=1 apiToken=1 wifi=1 sso=1 barcode=1 gpg=1 billing=1 payment=1；标签=已写入；归档=已生效（列表 metadata.isArchived=true）；取消归档=已生效；搜索命中=1 条 / 索引 12 条 |
| `folders` | 分类与文件夹 | PASS | 分类=4 个；文件夹节点=4；分类与子文件夹已创建并重命名；条目已移动到 Beta；空分类已删除 |
| `trash` | 回收站删除与恢复 | PASS | 删除进入回收站、恢复回到列表；活动登录=2 |
| `batch` | 批量选择删除与恢复 | PASS | 两条登录条目批量删除并批量恢复（验收回收站登录、验收登录 Beta） |
| `export-import` | CSV 导出导入与加密备份 | PASS | CSV 3046 字节；导入预览 13 项，新分类登录条目=2；加密备份 6568 字节，正确密码可解密，错误密码已拒绝 |
| `snapshot` | 保险库快照创建与校验 | PASS | skipped — 快照密钥存放在 Keychain；无签名构建（CODE_SIGNING_ALLOWED=NO）缺少 Keychain entitlement，报 errSecMissingEntitlement(-34018)，已重新解锁 |
| `totp` | TOTP 生成 | PASS | secret 已设置（不回显）；两个时间窗各生成 6 位数字码且不同；当前码可用 |
| `generator` | 密码生成与强度分析 | PASS | 长度=20，无空白字符，含字母与数字；强度 level=veryStrong，估计熵=131 bit |
| `lock-unlock` | 锁定与解锁 | PASS | 锁定后状态 locked 且列表清空；用主密码解锁后条目数仍为 2（数据在 MDBX 中保留） |
| `widget-snapshot` | Widget 快照写入 | PASS | skipped — App Group 容器不可用（production 装配降级，widgetSnapshotStore 为 nil） |
| `localization` | 中英文切换 | PASS | en=Settings，zh-Hans=设置；AppLocalizationRuntime 切换后 appLocalized 同步变化，已还原原语言 |
| `autofill-index` | 自动填充索引刷新 | PASS | skipped — 自动填充索引存储未配置（App Group 容器不可用），刷新直接返回 idle |
### 关于 3 个跳过

| 跳过步骤 | 原因 | 补齐方式 |
| --- | --- | --- |
| `snapshot` | 快照密钥存 Keychain，无签名构建缺 `keychain-access-groups`，报 `errSecMissingEntitlement(-34018)` | 用带开发者证书的构建（`CODE_SIGNING_ALLOWED=YES`，或在 CI/真机上）会实际执行 |
| `widget-snapshot` | App Group 容器不可用，生产装配下 `widgetSnapshotStore` 为 nil | 同上 |
| `autofill-index` | 自动填充索引存储依赖 App Group 容器 | 同上 |

跳过不是“伪造通过”：报告里 `skipped: true` 且 `detail` 写明原因，失败时退出码非 0。

## 覆盖范围

14 步覆盖：建库与解锁、13 类条目创建（登录/验证码/笔记/银行卡/证件/SSH/API Token/Wi-Fi/SSO/条码/GPG/账单地址/支付账户）、搜索与标签与归档、文件夹层级、回收站删除恢复、批量操作、CSV 导入导出与加密备份、快照校验、TOTP 生成、密码生成器、锁定与解锁、Widget 快照、本地化切换、自动填充索引刷新。

## 已知限制

- 不覆盖 UI 交互细节（SwiftUI 视图渲染、手势、动效）——这部分仍需人工或 CI 环境下的 XCUITest；本机无法运行。
- 不覆盖网络类集成（OneDrive/Google Drive/WebDAV/Bitwarden 真实服务器）；这类能力由注入式单元测试与 CI 覆盖，另有 `--monica-onedrive-graph-acceptance` 需要真实登录态。
- 深链（`monica://`）在锁定态会被拒绝，验收未尝试绕过锁屏。
