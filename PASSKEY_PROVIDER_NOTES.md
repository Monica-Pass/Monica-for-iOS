# Passkey 凭据提供者实现调研（开源项目对照）

调研对象（只看开源、可读源码的 Swift/Kotlin 凭据提供者实现）：

| 项目 | 位置 | 说明 |
|---|---|---|
| KeePassium | `KeePassium AutoFill/`, `KeePassiumLib/db/passkey/Passkey.swift`, `util/autofill/QuickTypeAutoFillStorage.swift` | 成熟 Swift 实现，注释完整 |
| Bitwarden iOS | `BitwardenAutoFillExtension/CredentialProviderViewController.swift`, `BitwardenShared/UI/Autofill/Application/CredentialProviderExtensionDelegate.swift` | 扩展内跑完整 UI 栈 |
| Keyguard | `appleAutofill/CredentialProviderViewController.swift`, `appleUi/.../AutofillIndexService.swift` | Compose/KMP + Swift 外壳，注释细致 |
| AliasVault | `apps/mobile-app/ios/Autofill/CredentialProviderViewController(+Passkey).swift` | SwiftUI 列表，忽略 allow-list |
| Proton Pass | `AutoFill/Shared/UseCases/AutoFillPasskey.swift` | 精简用例层 |

## 1. 扩展点与能力声明

- 全部使用 `com.apple.authentication-services-credential-provider-ui`（ExtensionKit）。
  旧值 `com.apple.authentication-services-credential-provider` 在 iOS 17+ 没有注册点，扩展不会注册。
- 能力字典位于 `NSExtension → NSExtensionAttributes → ASCredentialProviderExtensionCapabilities`，
  `ProvidesPasswords` / `ProvidesPasskeys` / (`ProvidesOneTimeCodes` / `SupportsSavePasswordCredentials` 视功能)。

## 2. 凭据身份库（ASCredentialIdentityStore）的写入策略

| 项目 | 谁是权威 | 增量/全量 |
|---|---|---|
| KeePassium | 主 App（扩展**完全不碰**身份库） | 支持增量用 `saveCredentialIdentities`，否则 `replaceCredentialIdentities`；写入前先 `getState { isEnabled }` |
| Keyguard | 主 App 全量 + 扩展注册后增量补一条 | App 用带 revision 校验的 `replaceCredentialIdentities`；扩展用 `saveCredentialIdentities([new])`，失败只记日志 |
| Bitwarden | App（`AutofillCredentialService`） | 同上思路 |
| AliasVault | App | 全量 |

关键结论：
- **扩展在 WebAuthn 请求进行中做「全量替换」是危险动作**（可能影响正在进行的 ceremony）。
  业界做法是扩展只做**增量补一条**，权威全量同步留给主 App。
- 写入前检查 `isEnabled`；`supportsIncrementalUpdates == false` 时不要用增量接口期待成功（Keyguard 只容忍失败）。

## 3. 用户验证（UV）与解锁

- **没有任何一个项目在凭据提供者扩展里直接对 passkey 调用 `LAContext.evaluatePolicy`**。
  通行密钥的「验证」等同于**解锁保险库**：
  - KeePassium：自有 `passcodeInputVC`（`isBiometricsAllowed`），解锁数据库后再生成凭据，断言时 `userVerified: true`。
  - Keyguard：`presentUnlock { ... }` → 解锁 core → 匹配身份。
  - AliasVault：PIN/Face ID 解锁 `VaultStore`。
  - Bitwarden：扩展里跑完整应用上下文，由 `BiometricsService` 在自己 UI 内验证。
- 因此 authenticatorData 里 `UV` 位的含义是「本次操作前已完成设备所有者/保险库解锁」，不是「扩展自己弹了一次生物识别」。
- 若确实要弹生物识别：必须等自有 UI `viewDidAppear` 之后再调用（Bitwarden 为此专门暴露了 `getDidAppearPublisher()`），
  否则 `LAContext` 返回 `LAError.notInteractive (-1004)`。

## 4. 注册流程

- Keyguard：先列条目让用户选挂到哪个条目 → 检查 `request.excludedCredentials`（iOS 18+，
  `core.hasExcludedPasskeyCredential`）→ 检查 `supportedAlgorithms.contains(.ES256)` → 生成凭据 → 增量发布身份 → 完成请求。
- AliasVault：从 `supportedAlgorithms` 里按 RP 顺序挑选算法（iOS 只转发 ES256），注册参数存起来在 `viewWillAppear` 完成。
- Bitwarden：`setMatchedExcludedCredentialFound()` 表示命中排除列表并失败。
- 完成顺序（KeePassium）：`completeRegistrationRequest(using:completionHandler:)` 里再落库，避免请求中途改状态。

## 5. 断言流程

- Keyguard：按 `rpId + allowedCredentialIds` 匹配；为空时明确报错（`autofill_no_matching_logins`）；用户选中后
  用**存储记录里的** `userHandle`/`credentialID` 生成断言。
- AliasVault：**不按 allow-list 过滤**，列出该 RP 的全部 passkey（用户可自行选择），断言前只校验 `passkey.rpId == rpId`。
- KeePassium：`Passkey.makeAssertionCredential`，`rpIDHash = sha256(rpId)`，`flags = uv|up(+be/bs)`，
  **signCount = 0**，签名 `derRepresentation`，`userHandle`/`credentialID` 来自存储记录。

## 6. 与本项目当前实现的差异（重要度排序）

1. **断言缺了「解锁」语义**：我们从 Keychain 直接取私钥签名，没有保险库解锁步骤；
   现实做法是解锁保险库（或至少设备所有者验证）后再签。
2. **注册后全量替换身份库**：改为扩展增量 `saveCredentialIdentities([new])`，主 App 继续做权威全量同步。
3. **未处理 `excludedCredentials`**（iOS 18+）：命中排除列表应当让注册失败。
4. **未校验 `supportedAlgorithms`**：至少要求包含 ES256，否则应拒绝。
5. **断言 userHandle 取自系统 identity**，业界取自存储记录（差异一般无害，但更严谨的是用本地记录）。
6. 断言在 allow-list 无匹配时的 UX：Keyguard 明确报错，AliasVault 回退列出该 RP 全部 passkey，二选一即可。

已对齐的部分：`counter = 0`、`flags = UP|UV`、`derRepresentation` 签名、`fmt: none` + 16 字节 AAGUID、
`rpIDHash = sha256(rpId)`、注册/断言完成调用、`provideCredentialWithoutUserInteraction` 一律回
`userInteractionRequired`。
