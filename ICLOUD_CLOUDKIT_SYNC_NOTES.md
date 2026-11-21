# iCloud（CloudKit）加密保险库同步（issue #76）实现说明

本文件记录 CloudKit 作为**新的同步 provider** 接入既有「云端保险库」抽象的设计、加密边界、必须人工完成的配置与手动验收步骤。

## 1. 范围与定位

- 目标：用**当前 Apple ID 的 CloudKit 私人数据库**承载「云端保险库」的一份加密保险库文件，实现两台设备之间的**手动 Push/Pull**、首次恢复、版本冲突保护与离线重试。
- 叠放关系：`feat/76-cloudkit-sync` 基于 `main`（含 issue #31 的 `CloudVaultRemoteStore` 抽象与 issue #53 的 LAN 同步工具）。**没有重写同步引擎**：`CloudVaultSyncEngine` 的决策矩阵、同步记录、冲突三选一、密码提示流程全部原样复用，iCloud 只是多了一个 `CloudVaultRemoteKind.iCloud` 的远端实现。
- 不在本 MVP 内（明确**不声称已完成**）：
  - 后台自动增量同步 / `CKSyncEngine` 常驻同步；
  - 条目级增量同步（云端始终是整份保险库文件）；
  - Passkey 私钥的跨设备恢复（issue #43，本分支未触碰）；
  - iCloud 账号切换的自动检测与自动重建同步基线。

## 2. 架构

```
App（设置 → iCloud 同步开关 / 云端保险库页面）
  └── AppCloudVaultSyncCoordinator（既有，未改逻辑）
        └── CloudVaultSyncEngine（既有，未改逻辑）
              └── CloudVaultRemoteStore（既有协议）
                    └── CloudKitCloudVaultRemoteStore   ← 新增
                          └── CloudKitVaultTransport（协议缝）  ← 新增
                                └── CloudKitContainerVaultTransport（真实 CloudKit）
```

- `CloudKitCloudVaultRemoteStore`（`SwiftPackages/MonicaSync/Sources/MonicaSync/CloudVault/CloudKitVaultRemoteStore.swift`）是无状态 `struct`，实现 `readRemote` / `downloadVault` / `createRemote` / `updateRemote` / `writeConflictCopy`，另外暴露 `pollChanges(since:)` 给设置页做「云端有没有变更」的轻量检查。
- `CloudKitVaultTransport`（`CloudKitVaultModels.swift` 内）是**唯一的 CloudKit 依赖面**：`accountAvailability` / `ensureZone` / `fetchRecord`（只取元数据）/ `downloadAsset` / `saveRecord` / `fetchZoneChanges`。单元测试用内存假实现，永不接触真实 CloudKit。
- `CloudKitContainerVaultTransport`（`CloudKitVaultTransport.swift`，`#if canImport(CloudKit)`）用 iOS 17 的 async `CKDatabase` API：`records(for:desiredKeys:)`、`record(for:)`、`modifyRecords(saving:deleting:savePolicy:atomically:)`、`save(_ zone:)`、`recordZoneChanges(inZoneWith:since:desiredKeys:resultsLimit:)`。
- **延迟创建 `CKContainer`**：构建缺少 iCloud entitlement 时，`CKContainer(identifier:)` 会在 CloudKit 内部直接 trap（本机在 iOS 模拟器上实测 `EXC_BREAKPOINT`，Swift 无法捕获）。因此容器只在真正执行一次 CloudKit 操作时惰性创建，App 启动、设置页出现、`.task` 里都不会创建它；缺 entitlement 时映射为 `CloudVaultError.notConfigured`，不会崩。

## 3. 云端对象布局

私人数据库 + 自定义 zone（默认 `MonicaVaultZone`），每个保险库一条记录：

| 记录项 | 值 |
| --- | --- |
| recordType | `MonicaVault` |
| recordName | `monica-vault-<vaultID>`（vaultID 含非 `[a-z0-9-]` 字符时改用 SHA-256 前 40 位；ASCII、≤255） |
| `schemaVersion` | `Int64`，当前 1（明文） |
| `vaultID` | `String`，MDBX 内部不透明随机 id（明文，不可反推内容） |
| `revision` | `Int64`，每次成功上传 +1（明文版本号） |
| `byteCount` | `Int64`，密文字节数（明文） |
| `contentSHA256` | `String`，**密文字节**的小写 hex SHA-256（用于完整性校验，不泄露明文） |
| `updatedAt` | `Date`（明文时间） |
| `vaultAsset` | `CKAsset`：**完整加密的 MDBX 保险库文件字节**（密文） |

`CKRecord.recordChangeTag` 作为不透明的远端版本标识（`CloudVaultRemoteFile.revision`），用于乐观并发。

**没有**任何其他字段：没有保险库名、设备名、条目标题、URL、用户名、密码、TOTP、备注、Passkey 材料。读取时 `CloudKitRecordPayload.redactedManifest` 用固定占位符合成 `CloudVaultManifest`（名称「Monica 加密保险库」、设备「iCloud」），因为云端根本没有这些信息。

## 4. 端到端加密边界

- CloudKit 私人数据库**不是**端到端加密存储（Apple 可读服务端数据），所以本方案不依赖 CloudKit 加密：上传的字节就是 App 本机磁盘上的**MDBX + Monica 加密信封密文**，与 WebDAV/OneDrive 路径逐字节一致。
- 上传前会再次校验：`CloudVaultLocalSnapshot` 的 `contentSHA256` 必须与待上传字节的 SHA-256 一致（`verifyCloudVaultIntegrity`），不一致立即 `integrityMismatch`，绝不写云端。
- 下载后同样先校验字节数与 SHA-256，再交给既有的「解锁 + 原子提交」流程；校验失败不会碰本机文件。
- 解密只需**主密码 / 恢复密钥**，不依赖任何跨设备 Keychain 密钥、也不依赖 iCloud Keychain：换一台设备、重装 App，只要记得主密码即可恢复。
- 日志与诊断只记录 provider、大小、revision、错误码，不记录保险库字节、摘要内容或凭据。

## 5. 并发、冲突与重试

- 首次上传：`.ifServerRecordUnchanged`（CloudKit 语义为「服务端不能已存在该记录」），已存在则 `CKErrorServerRecordChanged`。
- 更新：从云端取回元数据记录，比较 `recordChangeTag` 与上次看到的 tag；不同则抛 `CloudVaultError.preconditionFailed(remoteRevision:)`，由既有引擎判定为冲突，**不覆盖**。
- 冲突副本：另建一条 `monica-cloud-conflict-<yyyyMMdd-HHmmss>-<8hex>` 记录（createOnly，重名自动加 `-1...-8`），永不覆盖主记录；同一快照重试同名同内容时返回既有副本（幂等），不会刷出一堆重复记录。
- `CKErrorServerRecordChanged` → `.preconditionFailed`；`networkUnavailable` / `networkFailure` / `zoneBusy` / `requestRateLimited` / `serviceUnavailable` / `internalError` → `.network`（既有引擎会置 `pendingUpload`，可重试）；`changeTokenExpired` → 以 `nil` token 重新拉取并标记 `didReset`。

## 6. 错误与降级

| CloudKit 状况 | 映射 | 用户可见行为 |
| --- | --- | --- |
| 未登录 iCloud（`notAuthenticated`） | `cloudAccountUnavailable(.iCloud)` | 设置页显示「未登录 iCloud」，本机保险库照常可用 |
| iCloud 受限 / 暂时不可用 | `cloudAccountUnavailable(.iCloud)` | 同上，提示稍后再试 |
| 缺 entitlement / 容器配错（`missingEntitlement` / `badContainer`） | `notConfigured(reason:)` | 提示需要真实 Team 配置 iCloud 容器 |
| iCloud 空间不足（`quotaExceeded`） | `cloudQuotaExceeded(.iCloud)` | 提示清理空间；**本机文件未改动**，同步记录保留 `pendingUpload` 以便重试 |
| 单条记录过大（`limitExceeded`） | `vaultTooLarge(byteCount:)` | 提示保险库超出上限 |
| 网络中断（`network*` / 5xx） | `network(...)` | 可重试，本机不受影响 |
| zone 不存在 / 被删除 / 记录不存在 | 读：视为「云端无记录」；下载：`remoteVaultMissing` | 首次上传会自动建 zone |
| 权限失败 | `forbidden(.iCloud)` | 提示检查 iCloud 容器权限 |

任何 iCloud 失败都不会关库、不会替换本机文件、不会清空同步记录。

## 7. 变更拉取

- 设置页「检查云端变更」调用 `recordZoneChanges`，只取元数据（`desiredKeys` 不含 `vaultAsset`），不下载保险库字节。
- 变更令牌（`CKServerChangeToken` 经 `NSKeyedArchiver` 编码后的不透明 `Data`）按保险库存在 **UserDefaults** 的 `monica.cloudkit.change-token.<vaultID>`：只有令牌，没有内容、没有密钥。
- 令牌过期时自动用 `nil` 重新拉全量并把状态显示为「云端变更记录已重置」，绝不据此自动下载或覆盖。
- **已知缺口**：账号切换后 CloudKit 侧状态会重置，本机令牌可能失效——当前表现为「重置后重新检查」，尚未做账号指纹记录与自动清理。

## 8. 必须人工完成的配置（本分支无法代做）

1. 在 Apple Developer 后台为 App ID（当前 bundle id 为 `com.monicapass.monica`）**创建 iCloud 容器**，标识符与服务端约定一致。本仓库使用占位：`iCloud.ru.takagi.monica`（历史上 Keychain service 前缀即 `ru.takagi.monica.*`，故沿用该前缀）。
2. 勾选 **iCloud → CloudKit** 能力，并让该 App ID 关联上面的容器；重新生成 provisioning profile。
3. 若改用自己 Team 的容器前缀，同时修改：
   - `App/MonicaApp/MonicaApp.entitlements` 的 `com.apple.developer.icloud-container-identifiers`；
   - `CloudKitVaultSpec.defaultContainerIdentifier`（`SwiftPackages/MonicaSync/Sources/MonicaSync/CloudVault/CloudKitVaultModels.swift`）。
4. 在 CloudKit Dashboard 里确认容器 Development 环境可写；上架前需要把 `MonicaVault` 记录类型与 `MonicaVaultZone` 部署到 Production 环境。

**注意**：缺少上述 entitlement 的构建不会在编译期报错，但运行时一旦真的调用 CloudKit 就会在框架内部 trap（Apple 行为）。本分支通过「惰性创建容器 + 只有用户显式操作才触达 CloudKit」把影响限制在同步动作本身，本机功能不受影响。

## 9. 手动验收路径（两台真实设备，同一 Apple ID）

前置：两台设备都用正确的容器/entitlement 构建，均已在系统设置登录同一 Apple ID，且都开启 iCloud 同步开关。

1. **A 上传**：A 解锁保险库 → 设置 → 云端保险库 → provider 选 iCloud → 上传。A 显示成功，云端 revision 1。
2. **B 首次恢复**：B 安装 App → 云端保险库 → provider 选 iCloud → 检查云端版本 → 拉取 → 输入**正确主密码** → B 得到一份可解锁的保险库（首次恢复会另存为新文件，不覆盖 B 现有库）。B 编辑一条 → 上传，云端 revision 2。
3. **A 手动拉取**：A 再检查云端版本 → 显示有更新 → 拉取 → 解锁后看到 B 的修改。
4. **错误密码**：在 B（或干净的第三台设备）用**错误主密码**恢复 → 必须失败且不产生可用保险库；A、B 的本地库都不被改写。
5. **同时编辑**：A、B 都基于 revision 2 各自修改后各自上传 → 后上传一方必须被拒（`preconditionFailed`）→ 选择「先上传冲突副本，再采用云端版本」→ 云端出现 `monica-cloud-conflict-*` 副本，主记录不被覆盖。
6. **降级**：退出 iCloud 账号（或断网 / 删除容器）后打开 App → 本机保险库照常解锁使用；iCloud 状态显示明确原因；恢复网络与账号后可重试成功。
7. **回归**：关闭 iCloud 开关后，WebDAV / OneDrive 两条既有路径行为不变。

## 10. 自动化测试

- `swift test --package-path SwiftPackages/MonicaSync` 覆盖（不连真实 CloudKit）：
  - `CloudKitVaultConfigurationTests`：记录名派生、非法容器/zone/记录名拒绝、明文元数据字段白名单（`Mirror` 断言，防止以后偷偷加明文字段）；
  - `CloudKitVaultStoreTests`：首次创建 / 读取 / 更新往返、changeTag 不匹配拒绝、密文被篡改的下载被 `integrityMismatch` 拒绝、云端缺失、冲突副本命名与幂等、change token 轮询与重置；
  - `CloudKitVaultErrorMappingTests`：未登录 / 受限 / 空间不足 / 缺 entitlement / 网络 / 权限 / 记录过大 / 变更令牌过期到 `CloudVaultError` 与诊断码（SYNC-1013 / SYNC-1023 / provider `iCloud`）的映射；
  - `CloudKitVaultEngineTests`：两设备 A push → B pull → B push → A pull，以及「同时编辑 → 冲突 → 冲突副本」全链路。
- App 侧不新增 UI 自动化测试；本机无法运行模拟器测试（`DTServiceHubClient failed to bless service hub`，环境限制），由 CI 在 PR 上跑真实模拟器测试。

## 11. 已知缺口

1. **无后台/自动增量同步**：只有手动 Push/Pull 与手动「检查云端变更」。`CKSyncEngine` 未接入（留待后续迭代）。
2. **云端没有保险库名/设备名**：隐私优先的取舍——首次恢复时另存的文件名会是占位「Monica 加密保险库」。
3. **账号切换未跟踪**：没有记录账号指纹；切换 Apple ID 后需要点「重置同步记录」并重新建立基线。
4. **同步记录与令牌都是本机文件/UserDefaults**：重装 App 后基线丢失，会退化成保守的「无基线」冲突提示，而不是自动覆盖。
5. **冲突副本不会自动清理**：云端会累积 `monica-cloud-conflict-*` 记录，需要用户或后续清理逻辑处理。
6. **Passkey 跨设备恢复仍未实现**（issue #43），本分支不涉及、也不声称。
7. **未做保险库体积预检**：超限时靠 CloudKit 的 `limitExceeded` 兜底映射为 `vaultTooLarge`。
