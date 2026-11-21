# 修改主密码（#55）实现说明

## 1. 结论：主密码是 KEK，不是数据密钥

MDBX 保险库的密钥层次（`crates/mdbx-storage/src/unlock.rs` 文档注释原文）：

```
用户凭据 ──[Argon2id]──► unlock_key ──[AEAD 解包]──► vault_key
```

- `vault_key` 是随机生成的 DEK，条目、附件、TOTP、Passkey 以及记录/附件/元数据子密钥都由它派生。
- 主密码（或 PIN、security key）只负责派生 `unlock_key`，再用它解包 `vault_key`。
- 因此「修改主密码」= 重新包裹 `unlock_methods.wrapped_vault_key_ct`，**不需要重加密数据库**，
  条目数据在修改过程中不会被触碰。

## 2. 关键代码路径

| 层 | 文件 | 行为 |
|---|---|---|
| 上游 Rust | `crates/mdbx-storage/src/unlock.rs` `UnlockService::change_password` | 用旧口令派生 unlock key、解包 vault_key、生成新 salt/KdfParams、重新包裹并写回 |
| 上游 Rust | 同上 `update_method_key` | `BEGIN IMMEDIATE` → `UPDATE unlock_methods` → `bind_active_key_epoch` → `validate_active_key_epoch` → `COMMIT`，出错 `ROLLBACK` |
| FFI | `crates/mdbx-ffi/src/lib.rs` `MdbxVault::reset_master_password` | 复用已解锁连接的 `vault_key`，以默认 Tiga 模式重新包裹（不校验旧口令） |
| MonicaStorage | `LocalVaultRepository.changeMasterPassword(for:currentPassword:newPassword:)` | 校验输入 → 独立连接校验旧口令 → 调用引擎重包裹 |
| MonicaStorage | `MDBXLocalVaultEngine.verifyMasterPassword(at:password:deviceID:)` | 用 `MonicaMDBXRuntime.openVault` 开一个**临时连接**验证旧口令，不注册进 `vaults` 字典，句柄随对象释放关闭 |
| App | `AppSessionModel.changeMasterPassword()` | 输入校验、防重复提交、状态机、成功后清空输入并同步钥匙串状态 |
| App | `SettingsRootView` 的「主密码」分区 | 当前/新/确认三个 `SecureField`、强度提示、状态行、提交按钮 |

### 为什么用临时连接校验旧口令

- 现有 FFI 没有 `verify_password` 导出（只有 `resetMasterPassword`），而 `resetMasterPassword` 不校验旧口令。
- 直接以错误旧口令调用重包裹会**真的改掉主密码**，所以必须先验证。
- 关闭当前会话再重开（方案 B）会让「旧口令输错」也打断用户的编辑状态；临时连接（方案 A）在 SQLite WAL
  模式下与现有连接并存，验证失败时活动会话完全不受影响。
- `unlock_with_password` 是只读的：找 `Password` 方法 → 派生 key → 解包 vault key → 挂载 keyring → 建会话，
  不写任何行，因此临时连接没有副作用。

## 3. 原子性与失败语义

- 重包裹本身在**单个 SQLite 事务**内完成；进程被杀/断电时事务回滚，`wrapped_vault_key_ct` 仍是旧值，
  旧主密码继续可用。不存在「先毁掉恢复材料再加密」的窗口。
- 旧口令错误 → `LocalVaultRepositoryError.currentPasswordMismatch`（「当前主密码不正确。」），
  不写库、不关闭会话、输入保留以便重试。
- 新口令为空/仅空白 → `.emptyPassword`；新旧相同 → `.passwordUnchanged`；两次输入不一致 →
  `MasterPasswordChangeError.confirmationMismatch`；少于 8 个字符 → `.insufficientStrength`。
- 钥匙串**不需要**重写：`wrappedKey` 里的安全密钥材料在 `prepareVaultKeychainUnlock` 时已经通过
  `setupLocalSecurityKeyUnlock` 注册进保险库，包的是 `vault_key` 而不是主密码。改密后直接复用即可，
  写新条目反而会写入一份未注册的新材料、让下次钥匙串解锁失败（实现里专门避免了这个回归）。
- 锁屏/后台/解锁失败路径都会调用 `clearMasterPasswordChangeInput()`，明文口令不会留在内存状态里。

## 4. 已知限制

1. **KDF 档位会被归一化为 Multi**。FFI 的 `reset_master_password` 固定传 `MdbxTigaMode::Multi`（64 MiB / 3 次），
   而上游 `change_password` 会保留原档位（`old_kdf_params.infer_tiga_mode()`）。若要保档，需要上游导出
   `change_password` 或带模式的 reset。现有「忘记密码重设」走的是同一条 FFI 路径，行为一致。
2. **无法从 FFI 读取当前档位**：`VaultInfo` 只有 `vault_id`/`device_id`，UI 不能展示「当前档位 → 新档位」。
3. 新主密码只做客户端校验（长度 ≥ 8，混合字符仅作提示，不阻塞），与引擎的实际口令策略解耦；
   旧主密码不套用任何策略，避免历史保险库被策略升级锁死。

## 5. 多设备 / 备份 / iCloud（与 #31、#76、#59 的关系）

- 修改主密码只改**本机保险库文件**的 `unlock_methods` 行；钥匙串里的 security key 包裹的是同一个
  `vault_key`，所以改完密码后钥匙串/生物识别解锁依然有效（测试覆盖）。
- 多设备同步场景下，其他设备仍持有旧口令派生的 unlock key。本实现不会静默覆盖远端元数据：
  同步方需要在 #31/#76 里引入密钥版本号/冲突检测，否则 A 设备改密后，B 设备用旧口令打开同一份
  同步文件会得到「口令不正确」而不是冲突提示。备注：#59「密保材料迁移」完成前，密保问题答案仍与
  主密码解耦，不需要在改密时迁移。

## 6. 手工验收步骤

环境：iPhone 17 Pro 模拟器，iOS 26.5 运行时；Xcode 27.2（`/Applications/Xcode.app`）。
注意：本机若 `xcode-select` 指向 Xcode 27.0 beta，`xcodebuild test` 会因 CoreSimulator 无法完成
testmanagerd 握手而报 `The test runner hung before establishing connection`，需要
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 才可运行。
真机建议 iPhone 15 及以上、iOS 18.x 与 iOS 26.x 各跑一遍。

1. 新建保险库（口令 `中文 password 12345!`），添加一条登录、一条笔记、一条 TOTP，从设置启用钥匙串解锁。
2. 设置 → 主密码：只填新密码不填旧密码 → 按钮不可点。
3. 旧密码输错、新密码合法 → 提示「当前主密码不正确。」；返回列表、编辑条目、锁定后用旧密码解锁均正常。
4. 新密码 7 位 → 提示「新主密码至少需要 8 个字符。」，按钮不可点。
5. 两次新密码不一致 → 按钮不可点（强行调用则提示「两次输入的新主密码不一致。」）。
6. 正确旧密码 + 合法新密码 → 提示「主密码已更新，请使用新主密码解锁。」；锁定后旧密码解锁失败、
   新密码解锁成功；条目、附件、TOTP、Passkey 均在。
7. 完成后用 Face ID / 钥匙串解锁 → 仍可进入（不需要重新启用）。
8. 修改过程中按 Home 键/切后台 → 隐私遮罩出现，锁屏后输入框内容被清空；再次进入时没有残留明文。
9. 断网/飞行模式下重复第 6 步 → 行为不变（该流程不依赖网络）。
10. 修改后把保险库文件复制一份、用旧密码打开副本 → 失败（符合预期），用新密码打开副本 → 成功。

## 7. 自动化测试

- `SwiftPackages/MonicaSecurity/Tests/.../MasterPasswordPolicyTests.swift`：强度评分、中文口令、
  阻塞项与非阻塞项、长度下限。
- `SwiftPackages/MonicaStorage/Tests/.../MonicaStorageTests.swift`：
  `changeMasterPasswordVerifiesCurrentPasswordThenRewraps`、
  `changeMasterPasswordStopsBeforeRewrapWhenCurrentPasswordIsWrong`、
  `changeMasterPasswordRejectsVerificationOfAnotherVault`、
  `changeMasterPasswordRejectsReusedPassword`、`changeMasterPasswordRejectsEmptyPasswords`。
- `Tests/MonicaTests/VaultSessionModelTests.swift`：成功改密、旧口令错误后会话仍可用、
  两次输入不一致、新口令过短、钥匙串材料不被重写、改密后钥匙串解锁仍可进入、锁定清空输入。
- `SwiftPackages/MonicaMDBX/Tests/.../MonicaMDBXTests.swift::resetMasterPasswordRewrapsVaultKeyAndKeepsSecurityKeyMethod`：
  真实 FFI 上「建库 → 注册 security key → 改密 → 新口令打开、旧口令失败、security key 仍可解锁」。
- `Tests/MonicaTests/MDBXRoundTripTests.swift::testChangeMasterPasswordKeepsVaultKeyAndRejectsOldPassword`：
  真实 MDBX 引擎上「错误旧口令被拒 → 成功改密 → 旧口令无法再打开 → 新口令打开且条目完整 →
  security key 仍能解锁」。

## 8. 本地验证记录

| 命令 | 结果 |
|---|---|
| `swift test --package-path SwiftPackages/MonicaSecurity` | 通过（含强度策略用例） |
| `swift test --package-path SwiftPackages/MonicaStorage` | 112 个用例全部通过 |
| `swift test --package-path SwiftPackages/MonicaMDBX` | 3 个用例通过（macOS arm64 真实 FFI slice） |
| `xcodebuild build-for-testing -scheme Monica` | `** TEST BUILD SUCCEEDED **` |
| `xcodebuild test`（8 个改密相关用例，iPhone 17 Pro / iOS 26.5） | 全部 passed，`** TEST SUCCEEDED **` |
