# 云端保险库（issue #31）实现说明

本文件记录 `CloudVault/` + App 层「云端保险库」MVP 的设计、边界与手动验收步骤。

## 1. 范围与定位

- 目标：在已有 WebDAV / OneDrive 云服务之上，提供**加密保险库文件的云端创建与手动同步**（Push/Pull），并带版本冲突检测与三选一处理。
- 叠放关系：本分支 `feat/31-cloud-vault-sync` 基于 PR #85（局域网同步，issue #53）的 `feat/53-lan-sync`，复用其 `LanSyncEncoding`（SHA-256 / hex）等基础工具；云端同步与局域网同步互相独立，可分别启用。
- 不在本 MVP 内：自动后台同步/定时轮询（见 #54 已关闭的规划与 #76 iCloud 方向）、多库选择（#29 仍开放，当前按单库实现）、条目级增量同步。
- 所有云端操作只在用户主动点击时发生，App 退到后台或锁屏时不会继续联网。

## 2. 云端对象布局

每个保险库在远端存两个对象（同一目录）：

1. `<vault-file-name>`：**完整加密的 MDBX 保险库文件**，与 App 本机磁盘上的文件逐字节一致；
2. `<vault-file-name>.monica-cloud.json`：`CloudVaultManifest` 清单，字段为
   - `formatVersion`（当前 1）
   - `vaultID` / `vaultName`
   - `revision`（每次成功上传 +1）
   - `contentSHA256`（对应 vault 文件字节的 SHA-256）与 `byteCount`
   - `updatedAt` / `updatedByDeviceID` / `updatedByDeviceName`

写入顺序固定为**先文件、后清单**：清单是提交标记。读取时先拿清单，再校验下载字节的 SHA-256 与字节数；不一致直接报完整性错误（`integrityMismatch`），不会信任任何一侧继续覆盖。

保险库文件本身由 MDBX 加密，云端与网络上永远只有密文；Manifest 不包含任何条目内容或密码。

## 3. 本机同步记录

状态文件：与保险库文件同目录的 `cloud-vault-sync-state-v1.json`（`CloudVaultStateStore`，原子写）。

- `CloudVaultSyncState.records` 以 `"<remoteKind>|<remotePath>|<vaultID>"` 为键；
- 每条 `CloudVaultSyncRecord` 保存：上次远端 ETag（`lastRemoteRevision`）、远端清单版本、远端内容摘要、**上次同步时本机内容摘要**（`lastLocalContentSHA256`）、时间、`pendingUpload`、最近失败原因；
- 记录只用于本机「三方比较」：本机是否变、云端是否变，都相对上次成功同步的状态判断；重装 App 丢失该文件时会退化为保守的「无基线」冲突，而不是猜测覆盖。

## 4. 决策矩阵

`CloudVaultSyncEngine.plan(local:record:remote:)`：

| 云端 | 本机记录 | 结果 |
| --- | --- | --- |
| 无 | 无 | `.pushNew`（首次上传，revision 1） |
| 无 | 有 | `.conflict(.remoteRemoved)`（保守，不自动新建） |
| 有，vaultID 不同 | 任意 | `.conflict(.vaultIdentityMismatch)`（禁止覆盖本机库） |
| 有 | 无 | 摘要相同 → `.upToDate`；否则 `.conflict(.noBaseline)` |
| 有 | 有 | 仅本机变 → `.pushUpdate`；仅云端变 → `.pullRemoteNewer`；都变 → `.conflict(.bothChanged)`；都没变 → `.upToDate` |

「云端是否变化」优先用 ETag 比较；服务器不返回 ETag 时退回比较清单 `revision` 与 `contentSHA256`，任一信号不同即视为变化（保守取向）。

## 5. 冲突三选一

| 选择 | 行为 |
| --- | --- |
| 保留本机版本并覆盖云端 | 以 `remote.revision + 1` 条件写覆盖云端；本机文件不动 |
| 保留云端版本并覆盖本机 | 下载校验后应用（同库：关库→原子替换→要求重新解锁） |
| 先上传本机冲突副本，再采用云端版本 | 先用 `If-None-Match: *` 上传一份**绝不覆盖**的副本，再执行拉取 |

冲突副本命名 `monica-cloud-conflict-<yyyyMMdd-HHmmss>-<device>-<8hex>.mdbx`，短 token 由 `SHA-256(vaultSHA256 + 时间戳)` 派生（重试同一快照得到同一文件名，避免刷屏）。

## 6. 拉取后的应用语义

- **云端 vaultID == 本机当前库**：下载完毕并校验摘要后，关闭当前保险库、把新字节原子写回原文件，随后要求用户用保险库密码重新解锁。写回前若本机存在未同步修改，用户应选择「冲突副本」路径保底。
- **云端 vaultID != 本机当前库**（新设备开库）：界面要求输入**该云端保险库的密码**；实现把下载数据写入临时文件，用 `LocalVaultRepository.openVault` 打开并校验 `handle.vaultID == manifest.vaultID`，通过后另存为 Documents 下 `<净化后的库名>.mdbx`（重名自动加时间后缀）；**绝不覆盖本机现有保险库**，提示用户锁定后从锁屏「打开已有保险库」打开新文件。
- 完整性校验失败、清单缺失、密码错误时，本机文件保持不变。

## 7. 失败与重试

- HTTP/传输错误映射：401 → `unauthorized`（要求重新登录）、403 → `forbidden`（检查目录写权限）、409/412 → `preconditionFailed`（云端已被其他设备更新，暂停本次写入）、5xx → `server`、传输异常 → `network`。
- 可重试错误写入 `pendingUpload` 与 `lastFailureMessage`，重新检查/上传时继续；不会因为失败自动清空或半覆盖云端对象。
- 条件写缺失 ETag 的 WebDAV 服务器：写入前重新读取清单，若 `revision` 与规划时不同则拒绝写入并提示，绝不盲覆盖。

## 8. 安全与隐私

- 上传/下载均为密文 MDBX 字节；Manifest 只含标识、版本、摘要与设备显示名。
- 不记录条目明文、密码、TOTP 密钥；不写剪贴板；不使用普通日志打印云端内容。
- 不在后台运行；无新增系统权限（WebDAV 凭据沿用现有设置存储，OneDrive 沿用现有 OAuth 会话）。
- 完整性校验失败或保险库标识不一致时一律停止，避免「信任任意一侧」的数据损坏。

## 9. 一致性快照的限制

`MonicaMDBX` / `MonicaStorage` 当前没有 vault 级 snapshot/copy API。本实现与本仓库既有 WebDAV 备份保持一致：在**主线程、无写入在飞**时读取 `session.descriptor.fileURL` 原始字节作为快照。所有仓储写操作都在 `AppSessionModel`（MainActor）串行执行，因此该快照对单人使用的 MVP 足够；真正的事务级快照需要 Rust/MDBX 侧能力，已在后续工作中记录。

## 10. 测试

```bash
swift test --package-path SwiftPackages/MonicaSync          # 包测试（含 CloudVault 模型/引擎/适配器）
xcodebuild build -scheme Monica -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/monica-dd CODE_SIGNING_ALLOWED=NO
```

云端同步的协议/决策/冲突逻辑全部在包内，用注入的 fake `CloudVaultRemoteStore` 覆盖成功、失败、重试与冲突路径；WebDAV/OneDrive 适配器用注入的 transport/provider 覆盖状态码与条件写行为。

## 11. 两台真机手动验收步骤

准备：两台 iPhone（示例 A：iOS 26.4，B：iOS 26.5），同一 WebDAV 服务器（或各自登录同一 OneDrive 账号），两台都安装本分支构建。

1. A 打开「设置 → 云端保险库」，选择 WebDAV，点「检查云端版本」→ 显示云端没有保险库；点「上传本机保险库到云端」→ 显示已上传第 1 版。
2. B 打开同一设置页（未建库时先建一个空库以便进入设置），选 WebDAV，点「检查云端版本」→ 显示云端有第 1 版、本机无基线；点「从云端更新本机」→ 输入 A 库密码 → 提示已保存为新文件。
3. B 锁定保险库，在锁屏点「打开已有保险库」选择刚保存的文件并解锁；确认 A 创建的登录条目与 TOTP 存在。
4. B 修改一个登录条目并新增一个 TOTP；「云端保险库 → 上传本机保险库到云端」；云端变为第 2 版。
5. A 点「检查云端版本」→ 显示云端有新版本；点「从云端更新本机」→ 应用后要求重新解锁；解锁后确认 B 的修改存在。
6. 冲突场景：两台都离线修改同一库；A 先上传（第 3 版）；B 再点上传 → 应提示冲突而非直接覆盖；分别验证「保留本机」「保留云端」「先上传冲突副本」三种选择；确认云端出现 `monica-cloud-conflict-…` 副本且本地数据未被破坏。
7. 失败场景：在 B 上改错密码后拉取 → 提示密码错误且本机库不变；断网后上传 → 提示网络错误、`pendingUpload` 标记出现，恢复网络后重试成功；把 WebDAV 目录改为只读 → 上传提示 403 且云端版本不变。
8. 旧备份回归：确认原有「云端备份」WebDAV/OneDrive 上传、列表、恢复预览仍可用；确认本地库解锁、AutoFill、局域网同步不受影响。

## 12. 已知限制

- 手动同步，无自动后台/定时同步（遵循 #54/#76 的边界）。
- 整库文件上传，附件较大时流量与云盘容量消耗明显。
- 同库拉取会替换本地文件并要求重新解锁；如果本机有未同步修改，必须先处理冲突（默认不自动合并）。
- 新设备采用云端库时保存为新文件，需要从锁屏「打开已有保险库」打开（暂不做锁屏内的云库直接打开流程，等多库 #29 落地后再收敛）。
- 状态文件随 App 删除而丢失；重装后首次同步会走「无基线」保守冲突，不会覆盖任何一侧。
- 新设备采用云端库时若保存文件重名而加了时间后缀，该文件的云端同步记录会重新建立；首次上传/检查可能提示「无基线」冲突，按提示确认一次即可，不会覆盖任何一侧。
