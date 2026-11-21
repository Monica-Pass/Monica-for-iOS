# 局域网 / 热点同步（#53）实现说明

本文件对应 issue #53「局域网 / 热点同步」。目标是在**两台 iPhone 连接同一个 Wi-Fi 或热点**时，通过手动配对把保险库中的登录项、安全笔记和 TOTP 同步到另一台设备。实现只使用 Apple 的 Network.framework + Bonjour，不依赖手机创建 Android `LocalOnlyHotspot`，也没有默认开启的常驻广播或后台守护进程。

## 1. 结论与范围

已交付：

- `MonicaSync` 包内新增 `LanSync/` 分层：协议帧、设备身份、配对/握手状态机、加密通道、快照、三方合并、同步状态与幂等账本。
- App 新增「设置 → 局域网同步」入口，完整覆盖发起、加入、配对码、验证码比对、传输、结果/冲突展示和失败引导。
- `Info.plist` 声明的本地网络用途与 `_monica-sync._tcp` Bonjour 服务。
- 71 个新的 Swift Testing 测试；`swift test --package-path SwiftPackages/MonicaSync` 共 121 个测试全部通过。

MVP 范围（明确不做）：

- 不实现 Android 手机开热点、或自动发现/静默同步；两端必须在本页面主动操作。
- 不实现后台同步；离开页面、锁屏、App 进入后台都会中断当前会话。
- 只同步登录项、安全笔记、TOTP；银行卡/证件等条目留待后续（合并引擎已为扩展留好类型位）。
- 不依赖尚未实现的 #31 云库快照；本实现自带版本化快照与冲突策略，后续可把 `LanSyncVaultSnapshot` 适配到 #31 的统一快照格式。

## 2. 分层

```
SwiftPackages/MonicaSync/Sources/MonicaSync/LanSync/
├── LanSyncProtocol.swift   帧格式、长度前缀编解码、服务类型与上限常量
├── LanSyncCrypto.swift     设备身份、配对码、HKDF、AES-GCM 加密通道
├── LanSyncHandshake.swift  配对握手状态机（与传输层无关）
├── LanSyncSnapshot.swift   版本化快照、条目内容、内容哈希与摘要校验
├── LanSyncMerge.swift      三方合并引擎、冲突原因
└── LanSyncState.swift      对端记录、条目映射、合并基线、幂等账本、状态文件编解码
```

App 层：

| 文件 | 职责 |
| --- | --- |
| `App/MonicaApp/AppLanSyncNetwork.swift` | NWListener / NWBrowser / NWConnection 封装、本地网络权限拒绝识别、帧流读取 |
| `App/MonicaApp/AppLanSyncCoordinator.swift` | 身份持久化、握手编排、快照生成与应用、合并结果落库、幂等重试 |
| `App/MonicaApp/AppLanSyncView.swift` | 「设置 → 局域网同步」全部页面与状态展示 |
| `App/MonicaApp/AppRootView.swift`（扩展） | `AppSessionModel` ↔ 保险库仓储之间的桥：读取条目、应用 create/update/delete、刷新列表 |
| `App/MonicaApp/SettingsRootView.swift` | 设置页入口 |

## 3. 安全模型

### 3.1 设备身份

- 每台设备首次使用时生成 Ed25519 签名密钥 + X25519 协商密钥，私钥材料保存在 Keychain（service `com.monicapass.monica.lansync`，account `device-identity-v1`，`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`）。
- `deviceID = SHA256(签名公钥)[0..16]` 的十六进制；指纹是签名公钥的分组大写十六进制，在验证码页面展示，供用户核对。
- 身份与保险库解锁密钥分开存放；锁屏后 Keychain 条目不可读。

### 3.2 配对方式

- 发起方显示 **6 位配对码**（2 分钟有效）；加入方输入该码。
- 配对码不是会话密钥本身：它作为 HKDF 盐的一部分参与派生，`sessionKey = HKDF-SHA256(X25519 共享密钥, salt = transcriptHash || "code:" + 配对码, info = "monica-lan-sync-v1:session")`。因此仅监听 Bonjour 广播、不知道配对码的第三方无法派生出会话密钥。
- 预留 QR 配对：`LanSyncPairingSecret.qrToken` 为 256-bit 随机令牌，同样混入 HKDF 盐；后续可以复用现有的二维码生成/扫描组件把配对信息编码进二维码。

### 3.3 握手与验证

明文帧只包含公钥、随机数和签名，不包含任何保险库数据：

1. 发起方 → `hello`（sessionID、deviceID、显示名、Ed25519 公钥、临时 X25519 公钥、nonce）
2. 加入方 → `helloReply`（同上 + 对握手 transcript 的 Ed25519 签名）
3. 发起方 → `keyConfirmation`（签名 + 基于会话密钥的 HMAC 证明）
4. 加入方 → `keyConfirmationReply`（HMAC 证明）
5. 双方各自计算 6 位 SAS 并显示，用户在两台设备上比对一致后点「验证码一致」
6. 双方交换 `sessionConfirm`（HMAC 证明），只有**自己确认且收到对方确认**时才进入已建立状态

任何密钥替换（MITM）都会让 HMAC 证明失败；已配对设备的身份固定，签名公钥不匹配时以 `identityMismatch` 拒绝。连续 3 次配对失败后停止广播并冷却 30 秒。

### 3.4 加密通道

- 建立后所有应用消息走 `LanSyncSecureChannel`：AES-256-GCM，方向独立的密钥由 HKDF 从会话密钥派生。
- 12 字节 nonce = 角色前缀 + 8 字节单调递增序号；AAD 绑定 magic、版本和序号；接收端严格按序递增，重放、乱序、丢帧都会被拒绝（`replayedSequence`）。
- 帧序号从 1000 开始，与握手帧（从 1 开始）分离。

### 3.5 威胁与边界

| 威胁 | 处理 |
| --- | --- |
| 同一 Wi-Fi 下第三方看到 Bonjour 广播 | 广播只有显示名、协议版本、随机 deviceID；无数据、无配对秘密 |
| 未配对设备直接连接 | 需要配对码派生会话密钥；未提供/错误配对码会在 key confirmation 阶段失败 |
| 中间人替换公钥 | transcript 绑定双方公钥与 nonce，密钥确认 HMAC 失败；另有 SAS 人工比对 |
| 重放/篡改已传输数据 | AES-GCM + 单调序号 + 摘要校验 |
| 两台设备打开不同保险库 | 快照中带 `vaultID`，不一致直接拒绝，不落任何数据 |
| 合并误删/覆盖 | 三方合并只报告冲突；本地已修改的条目不会被远端覆盖或删除 |

已知限制（MVP 有意接受）：

- Bonjour 广播本身不加密，局域网内可见「附近有一台 Monica 设备」；不广播保险库内容。
- 采用 Ed25519/X25519 的一次性临时密钥完成会话，没有额外的 PFS 密钥轮换。
- iOS 的本地网络权限只在真机上有完整行为；模拟器不支持该权限流程，真机才能验收配对。
- 只在前台工作；锁屏或切后台会让系统挂起连接。
- 冲突只展示原因，MVP 不提供逐条「保留哪一边」的操作；用户可以之后在保险库中手动编辑或删除。
- 重装 App 会丢失本地状态文件，重新配对时同一批条目会被当作新条目再同步一次，可能出现重复；需要人工清理。

## 4. 协议概要

- 服务类型：`_monica-sync._tcp`，域 `local.`，TXT 记录只含 `v=1` 与 `id=<deviceID>`。
- 帧编码：4 字节大端长度 + UTF-8 JSON（`sortedKeys`），单帧上限 24 MiB。
- 帧种类：`hello`、`helloReply`、`keyConfirmation`、`keyConfirmationReply`、`sessionConfirm`、`sealed`、`error`。
- 版本字段为 `UInt16`；协议版本不一致时以 `unsupportedProtocolVersion` 明确拒绝。

## 5. 同步一致性与幂等

### 5.1 快照

`LanSyncVaultSnapshot` 是带 `formatVersion` 的版本化快照，包含：

- `vaultID`、发送方 deviceID/显示名、revision、exportedAt；
- 条目列表：`syncID`（设备无关的稳定 UUID）、`projectTitle`、标题、收藏、类型化内容；
- 删除墓碑（`syncID` + 删除时间 + 最后内容哈希）；
- 整份快照的 SHA-256 摘要，接收端先 `verifyIntegrity()`。

本机条目与 `syncID` 通过 `LanSyncEntryMapping` 关联；本地条目 ID 只在设备内使用，**不会发送给对端**。

### 5.2 三方合并

以每对设备各自持久化的 `LanSyncMergeBase`（上次同步成功后的内容哈希 + 本地 ID）为基线：

- 远端未变 → 保留本地；
- 远端变了、本地没变 → 更新本地；
- 双方都变且内容相同 → 收敛；
- 双方都变且不同 → **冲突**，不覆盖，列入结果页等用户处理；
- 删除只在本地自上次同步后未修改、且墓碑哈希与基线一致时执行；
- 一边删除一边修改 → 冲突；远端拿旧内容试图复活已删除条目 → 冲突；
- 基准里存在但本地条目消失且没有墓碑 → `localEntryMissing` 冲突。

### 5.3 断线重试幂等

- 发送方使用基于**内容**的稳定幂等键：对排序后的 `(syncID, contentHash)` 与墓碑求 SHA-256，得到 `transferID = "ls-" + hash 前缀`。
- 接收方在 `LanSyncTransferLedger`（最多 32 条）里记录已应用的传入快照；重试命中时直接返回 `alreadyApplied: true` 的回执，不会重复创建条目。
- 每应用完一批动作就把合并基线写回状态文件，因此中途断线后重试会从已完成的进度继续。
- 创建失败的条目不会写进合并基线，下一次同步会自然重试。

## 6. UI 流程

设置页新增「局域网同步」入口（「在两台 iPhone 之间同步」），进入后：

1. **菜单**：发起同步 / 加入同步；安全说明；已配对设备列表与最近同步时间；重置同步记录（只清同步状态，不动保险库）。
2. **发起**：显示 6 位配对码，等待加入方连接。
3. **加入**：浏览附近设备，选中后输入配对码。
4. **验证码**：显示 6 位 SAS、对端显示名与指纹，选择「一致」或「不一致」。
5. **同步中**：显示进度与「保持两台设备停留在本页面」提示。
6. **完成**：分别展示本机接收与对端接收的新增/更新/删除/冲突数，冲突逐条列出原因。
7. **失败**：中文错误原因 + 本地网络权限 / Wi-Fi 隔离 / 配对码过期等排查建议 + 重试按钮。

离开页面、保险库锁定、App 进入后台都会立即取消监听/浏览/连接。同步失败不会修改原保险库，也不会删除任何条目。

## 7. 系统配置

`App/MonicaApp/Info.plist` 新增：

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>用于在同一个 Wi-Fi 或热点下发现并连接你自己发起的 Monica 设备，通过端到端加密在两台设备之间同步保险库条目。只会在你主动发起或加入同步时使用。</string>
<key>NSBonjourServices</key>
<array>
    <string>_monica-sync._tcp</string>
</array>
```

注意事项：

- 首次点「发起同步」或「加入同步」时系统才会弹出本地网络权限；被拒绝时页面会给出「设置 → 隐私与安全性 → 本地网络」的指引。
- 模拟器不支持本地网络权限流程，配对验收必须用两台真机。
- 路由器开启 AP 隔离、或两台设备不在同一子网时会搜不到设备；热点场景由一台设备开个人热点、另一台连接即可。
- 使用 Bonjour 的声明式服务类型不需要 multicast entitlement。

## 8. 测试

```bash
swift test --package-path SwiftPackages/MonicaSync
```

当前 `MonicaSync` 共 121 个测试通过（其中 71 个是本次 `LanSyncTests.swift` 新增），覆盖：

- 帧编解码、超大帧、流式解码边界；
- 身份生成/恢复/签名、配对码校验与 KDF 域分离；
- 握手成功、错误配对码、MITM 替换公钥、重放序号、拒绝验证码；
- 加密通道加解密、篡改拒绝、重放拒绝、序号连续性；
- 快照摘要与完整性校验；
- 三方合并的创建/更新/删除/双向修改冲突/删除修改冲突/复活冲突；
- 状态文件编解码、对端固定、幂等账本命中。

App 侧编译命令：

```bash
xcodebuild build -scheme Monica -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/monica-dd CODE_SIGNING_ALLOWED=NO
```

## 9. 手动验收步骤（需要两台 iPhone）

准备：两台 iPhone（iOS 17+），登录不同 Monica 保险库，或一台新建空保险库；连同一个 Wi-Fi（或 A 开热点、B 连接）。

1. 在 A 上进入「设置 → 局域网同步」，点「发起同步」，记下 6 位配对码。
2. 在 B 上进入同一入口，点「加入同步」，选中 A 的设备名，输入配对码，点「连接并验证」。
3. 两台设备都应显示同一个 6 位验证码；确认一致后分别点「验证码一致，开始同步」。
4. 等待完成页出现：检查 A 的「从对方设备接收」与 B 的「对方设备接收」计数是否与预期一致；在 B 的保险库中确认 A 的登录项/笔记/TOTP 已出现且内容正确。
5. 重试幂等：在同步过程中把 B 切到后台或关 Wi-Fi 制造中断，再重试一次；不应出现重复条目，完成页应提示「此前已经应用过」。
6. 拒绝权限：在「设置 → 隐私与安全性 → 本地网络」关闭 Monica，再发起同步，应看到明确的权限引导而不是静默失败。
7. 不同保险库：让两台设备打开不同保险库后配对，应提示保险库不一致并拒绝同步。
8. 冲突：在 A、B 上分别修改同一个原本相同的条目后再同步，应列出冲突且双方本地内容都不被覆盖。

当前仓库内已完成的是模拟器编译与 121 个包测试；上述真机步骤需要在有设备的环境执行并回填到 PR。

## 10. 后续

- 把快照适配到 #31 统一云库快照/冲突策略，避免两套合并逻辑长期并存。
- 支持银行卡、证件等更多条目类型（需要先确认这些条目的稳定内容编码）。
- QR 配对：复用 `WifiQRCodeRenderer` 与 `TotpQRCodeScannerSheet` 把 deviceID/公钥/一次性令牌放进二维码。
- 已配对设备的「跳过配对码」重连流程（当前仍需每次输入配对码）。
