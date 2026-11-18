# NFC 银行卡贴卡读取（#44）技术验证报告

本文件对应 issue #44「NFC 银行卡贴卡读取」。结论先行：**普通 Core NFC 无法读取银行卡的卡号（PAN）、有效期或 CVV，因此本仓库不实现自动采集银行卡数据的功能**。本次交付的是一个默认关闭、可随时移除的只读诊断原型，用于在真机上验证系统能力边界，并为后续决策保留证据。

## 1. 结论与决策

- **停止“贴卡自动采集银行卡信息”方向。** 不是实现难度问题，而是平台与卡组织规则不允许：`NFCTagReaderSession` 明确不支持选择支付类 AID；把支付 AID 写进 `Info.plist` 也不能让系统把银行卡回调给 App，且无法通过 App Review。
- **保留手动录入。** 卡包字段继续由用户手动填写（依赖 #17 的 `LocalCardEntry` 模型）。
- **交付诊断原型。** 仅展示“系统是否支持 NFC / 会话是否成功建立 / 返回了哪类错误 / 标签家族与 NDEF 记录类型数量 / 系统选中的非支付 AID”等非敏感信息，用于确认设备、签名和卡片环境是否符合预期。
- **不把模拟器结果当作真机结论。** 模拟器没有 NFC 硬件，`readingAvailable == false`，只能验证“不支持时给出明确反馈”这一条。

## 2. Apple 能力与合规边界

| 能力 | API | 最低系统 | 地区限制 | 资质要求 | 能否读取 EMV 银行卡数据 |
| --- | --- | --- | --- | --- | --- |
| NDEF 标签读取 | `NFCNDEFReaderSession` | iOS 11 | 无 | NFC entitlement + 用途说明 | 否。银行卡不是 NDEF 标签 |
| 通用标签会话（含 ISO7816） | `NFCTagReaderSession` | iOS 13 | 无 | NFC entitlement + 用途说明 + `Info.plist` AID 列表 | 否。Apple 明确 **不支持选择支付类 AID** |
| 支付标签会话 | `NFCPaymentTagReaderSession` | iOS 26.0 | 仅 EU（账号注册地 + 设备位置） | Apple 特批，面向支付服务商 | 名义上支持，但本 App 不可用 |
| Host Card Emulation | `CardSession` / `com.apple.developer.nfc.hce` | iOS 17.4 | 仅 EEA | PCI DSS / EMVCo / GDPR 合规 | 否。这是“手机模拟卡片”，不是读卡 |

关键事实（均来自 Apple 官方文档 / 本机 iPhoneOS 27.0 SDK 头文件）：

- `NFCTagReaderSession` 文档原文："doesn't support selection of payment-related application IDs. In the European Union (EU), you can use `NFCPaymentTagReaderSession`."
- 任何 Core NFC 会话（包括 NDEF）都要求 `com.apple.developer.nfc.readersession.formats` entitlement 和非空的 `NFCReaderUsageDescription`；缺失时回调 `NFCReaderErrorSecurityViolation`（raw code 2）。
- `NFCTagReaderSession` 只有在 `Info.plist` 的 `com.apple.developer.nfc.readersession.iso7816.select-identifiers` 中声明的 AID 被卡片接受时，才会把 tag 回调给 App；`NFCISO7816Tag.initialSelectedAID` 只会是该列表中的条目。
- `NFCISO7816Tag.identifier` 是硬件 UID，按本项目隐私要求不展示、不保存。
- 会话最长 60 秒；用户取消返回 200，超时返回 201，进入后台返回 202，已有活动会话返回 203。
- Core NFC 在 App Extension 中不可用（`NS_EXTENSION_UNAVAILABLE`），本功能只能放在主 App。

参考：

- <https://developer.apple.com/documentation/corenfc/nfctagreadersession>
- <https://developer.apple.com/documentation/corenfc/nfcpaymenttagreadersession>
- <https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.nfc.readersession.formats>
- <https://developer.apple.com/support/hce-transactions-in-apps/>

## 3. entitlement 与签名条件

`App/MonicaApp/MonicaApp.entitlements` 新增：

```xml
<key>com.apple.developer.nfc.readersession.formats</key>
<array>
    <string>TAG</string>
</array>
```

`App/MonicaApp/Info.plist` 新增：

- `NFCReaderUsageDescription`：面向用户的用途说明（当前文案明确写了“不读取银行卡数据”）。
- `com.apple.developer.nfc.readersession.iso7816.select-identifiers`：仅包含 NDEF 应用 AID `D2760000850100` / `D2760000850101`。**不包含任何支付类 AID**（Visa/Mastercard/Amex/JCB/Discover/UnionPay/PPSE 等）。

真机签名要求：

1. 付费 Apple Developer Program 账号（免费个人团队无法启用 NFC capability）。
2. 在开发者后台为该 App ID 勾选 **Near Field Communication Tag Reading**，并重新生成 provisioning profile。
3. 设备为 iPhone 7 或更新机型（iPad 无 NFC）。
4. 若签名环境缺少该 capability，App 仍可安装启动，但诊断会稳定返回 `NFC-2`（SecurityViolation，缺少 entitlement），UI 会提示配置问题。

CI 的 app job 使用 `CODE_SIGNING_ALLOWED=NO`，不签名、不校验 entitlement，因此新增 entitlement 不影响现有 CI。

## 4. 已实现内容

新增文件：

- `SwiftPackages/MonicaCore/Sources/MonicaCore/NFCCardProbe.swift`：纯逻辑层（策略、feature flag、AID 判定、标签事实脱敏、错误码映射），无 CoreNFC 依赖，可单元测试。
- `SwiftPackages/MonicaCore/Tests/MonicaCoreTests/NFCCardProbeTests.swift`：11 个测试。
- `App/MonicaApp/NFCBankCardProbeView.swift`：Core NFC 适配层与设置页诊断界面。

修改文件：

- `App/MonicaApp/SettingsRootView.swift`：设置页新增「NFC 银行卡诊断」入口。
- `App/MonicaApp/Info.plist`、`App/MonicaApp/MonicaApp.entitlements`：如上。
- `Monica.xcodeproj/project.pbxproj`：注册新 Swift 文件。

行为要点：

- **默认关闭**：feature flag 存于 `UserDefaults`，key 为 `monica.nfc.card-probe.enabled`；未开启时开始按钮不可用，也不会创建任何 Core NFC 会话。
- **两种只读模式**：
  - NDEF 模式：`invalidateAfterFirstRead = true`，只统计记录数量与类型（不解析 payload）。
  - 非支付 ISO7816 模式：只使用 `Info.plist` 中声明的两个 NDEF AID 建会话；不发送任何 APDU。
- **错误反馈**：`NFCReaderError` 原始码映射为稳定诊断码（如 `NFC-1` 不支持、`NFC-2` 缺少 entitlement、`NFC-200` 用户取消、`NFC-201` 未检测到卡、`NFC-202` 会话被系统终止），并给出中文标题、说明与恢复建议。
- **数据边界**：
  - 不读取、不保存、不打印、不上传 PAN、有效期、CVV；
  - 不发送 `SELECT`、`READ RECORD`、`GPO` 等 APDU；
  - 不展示、不保存硬件 UID；
  - 支付类 AID 即使被系统回调，也只记录“已隐藏”布尔值，不保留原文；
  - 错误只保留类别和诊断码，不保留底层 `error.localizedDescription`。

## 5. 设备 / 卡片测试矩阵

| # | 环境 | 操作 | 预期结果 | 是否已执行 |
| --- | --- | --- | --- | --- |
| 1 | iOS 模拟器（任意机型） | 打开诊断页并开始 | 「设备支持：当前设备不支持」，开始时返回 `NFC-1` | ⚠️ 仅完成模拟器构建与代码路径确认，未启动 App 运行 UI |
| 2 | 真机 + 未启用 NFC capability 的签名 | 开启 flag 并开始 | 系统弹窗后返回 `NFC-2`，提示检查签名 / capability | ⏳ 待真机执行 |
| 3 | 真机 + 已启用 capability，普通 NDEF 标签（如 NTAG213 写入 URL） | NDEF 模式贴卡 | 会话成功，展示 NDEF 记录数量与类型，不显示标签内容 | ⏳ 待真机执行 |
| 4 | 真机 + 已启用 capability，银行卡（Visa/Mastercard/银联） | NDEF 模式贴卡 | 60 秒超时 `NFC-201`（银行卡不是 NDEF 标签） | ⏳ 待真机执行 |
| 5 | 真机 + 已启用 capability，银行卡 | 非支付 ISO7816 模式贴卡 | 不会回调 tag，60 秒超时 `NFC-201`；这正是“无法读银行卡”的实证 | ⏳ 待真机执行 |
| 6 | 真机，会话进行中点系统「完成」 | 取消 | 返回 `NFC-200`，界面回到空闲状态，无错误弹窗 | ⏳ 待真机执行 |
| 7 | 真机，会话中 App 进入后台 | 切后台 | 返回 `NFC-202`，界面给出明确说明 | ⏳ 待真机执行 |
| 8 | 真机，同时贴两张卡 | 非支付 ISO7816 模式 | 提示“一次只贴一张”，会话继续 | ⏳ 待真机执行 |
| 9 | 真机，错误模式（例如会话中再次开始） | 重复开始 | `NFC-203` SystemIsBusy 的明确反馈 | ⏳ 待真机执行 |

说明：矩阵中“待真机执行”的条目需要付费开发者账号和实体卡片，属于 issue #44 的后续验收事项；模拟器结果只覆盖“不支持时的反馈”，不能代表真实卡片可用。

## 6. 本地验证记录（2026-11-18）

```text
swift test --package-path SwiftPackages/MonicaCore
→ Test run with 30 tests in 1 suite passed（其中 NFCCardProbe 11 个）

xcodebuild build -scheme Monica -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
→ ** BUILD SUCCEEDED **
```

未执行：`xcodebuild test`（需要具体模拟器 UDID，CI 中执行）、真机安装与贴卡。

## 7. 后续 / 停止条件

- 继续关注 Apple 是否向中国大陆开放 `NFCPaymentTagReaderSession`，或是否提供面向普通 App 的 EMV 只读 API；在此之前不投入自动读卡实现。
- 如未来引入银行卡扫描，必须先取得对应卡组织 / 支付网络的书面许可，并单独做 PCI DSS 影响评估，不复用本诊断代码。
- 本诊断入口可在产品化时移除：删除 feature flag、设置页入口与 `NFCBankCardProbeView.swift`，并从 entitlement / Info.plist 移除 NFC 相关键（Core NFC 不影响其他功能）。
