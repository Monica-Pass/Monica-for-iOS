<h1 align="center">Monica for iOS</h1>

<div align="center">

<p><strong>Monica 的本地优先 iOS 密码库客户端</strong></p>
<p>iOS 18+ · SwiftUI · MDBX Vault · AutoFill · TOTP · WebDAV</p>

[![Release](https://img.shields.io/github/v/release/Monica-Pass/Monica-for-iOS?style=flat-square)](https://github.com/Monica-Pass/Monica-for-iOS/releases)
[![Downloads](https://img.shields.io/github/downloads/Monica-Pass/Monica-for-iOS/total?style=flat-square)](https://github.com/Monica-Pass/Monica-for-iOS/releases)
[![Last Commit](https://img.shields.io/github/last-commit/Monica-Pass/Monica-for-iOS?style=flat-square)](https://github.com/Monica-Pass/Monica-for-iOS/commits)
[![License](https://img.shields.io/badge/License-GPL--3.0-blue?style=flat-square)](LICENSE)

</div>

Monica for iOS 是 Monica 密码库生态的 SwiftUI 客户端。项目以本地优先为核心，优先落地 MDBX 加密保险库、iOS 原生 AutoFill、TOTP、WebDAV 备份恢复，以及与 Android / MDBX 数据模型兼容的多类型条目管理。

当前开发路线锁定为 **MDBX 优先、iOS 18+、iPhone 优先、Rust/Swift UniFFI 桥接**。首个公开版本聚焦本地 Vault、核心条目、WebDAV 和较完整 AutoFill；Passkey、Bitwarden、附件和更多云能力会在后续阶段继续完善。

---

## 用户先看

### Monica for iOS 适合谁

- 需要本地优先密码管理，不希望核心凭据托管到第三方服务。
- 已在 Monica Android / MDBX 生态中管理密码、TOTP、私密笔记等数据。
- 希望使用 iOS 原生 AutoFill、Face ID / Touch ID 门禁和本地备份恢复。
- 需要在 iPhone 上管理登录项、安全笔记、TOTP、银行卡、证件元数据等多类型条目。

### 当前能力

- 本地 MDBX Vault：创建、打开、锁定本地加密保险库。
- 界面语言：支持简体中文与英语，未覆盖语言回退到英语。
- 多类型条目：登录项、安全笔记、TOTP、银行卡、证件元数据等基础 CRUD。
- 收藏与搜索：支持收藏优先、只看收藏、会话内搜索和软删除恢复。
- TOTP：支持 `otpauth://` URI、二维码导入、验证码生成和剩余秒数刷新。
- iOS AutoFill：通过 Credential Provider Extension 读取加密索引并返回系统填充凭据。
- 安全解锁：Keychain + LocalAuthentication + MDBX `security_key`，不保存主密码。
- WebDAV：支持上传、下载、SHA-256 完整性校验、恢复预览和恢复前打开验证。
- OneDrive：已接入 MSAL 与 Microsoft Graph app-folder provider，真实账号与网络验收仍在推进。
- KeePass / KDBX：已完成现代 KDBX3/KDBX4 主链路读写兼容，后续继续扩展真实场景验收。
- 局域网同步（实验性）：两台 iPhone 在同一 Wi-Fi/热点下通过 Bonjour 手动配对，端到端加密同步登录项、安全笔记与 TOTP；详见 [`LAN_SYNC_NOTES.md`](LAN_SYNC_NOTES.md)。
- 云端保险库（实验性）：把完整加密的 MDBX 保险库文件与版本清单手动 Push/Pull 到 WebDAV/OneDrive，ETag 条件写避免覆盖，冲突时三选一（保留本机/保留云端/先传冲突副本）；详见 [`CLOUD_VAULT_SYNC_NOTES.md`](CLOUD_VAULT_SYNC_NOTES.md)。

### 已知状态

- 项目仍处于 iOS 客户端开发和真机验收阶段。
- 未签名模拟器测试使用 `CODE_SIGNING_ALLOWED=NO` 时，App Group container 不可用属于预期现象。
- AutoFill QuickType 展示、Credential Provider、App Group、Keychain access group、TOTP 相机扫描等能力需要签名真机环境继续验证。

---

## 开发者信息

### 目录结构

```text
.
├── Monica.xcodeproj/
├── App/
│   └── MonicaApp/
├── Extensions/
│   ├── MonicaAutoFillExtension/
│   ├── MonicaShareExtension/
│   └── MonicaWidgetExtension/
├── Tests/
│   └── MonicaTests/
├── Scripts/
│   ├── build-mdbx-xcframework.sh
│   └── generate-mdbx-swift-bindings.sh
├── Artifacts/
│   ├── MDBX/
│   └── MSAL/
├── Generated/
│   └── MDBXUniFFI/
└── SwiftPackages/
    ├── MSAL/
    ├── MonicaCore/
    ├── MonicaMDBX/
    ├── MonicaSecurity/
    ├── MonicaStorage/
    └── MonicaSync/
```

### 技术栈

- App：SwiftUI、Observation、AuthenticationServices、LocalAuthentication、Keychain、WidgetKit。
- 本地 Vault：MDBX Rust workspace + UniFFI + `MonicaMDBX` Swift package。
- 核心逻辑：`MonicaCore` 提供 TOTP、`otpauth://` parser、安全随机密码生成等能力。
- 存储：`MonicaStorage` 负责本地 vault repository、KDBX 兼容、AutoFill 加密索引和 secret snapshot。
- 安全：`MonicaSecurity` 负责 Keychain/LocalAuthentication 边界和本地 key material 管理。
- 同步：`MonicaSync` 提供 WebDAV、OneDrive/CloudFile provider、Bitwarden 同步边界，`LanSync/` 局域网配对/加密传输/三方合并实现，以及 `CloudVault/` 云端保险库清单/条件写/冲突决策实现。

### MDBX UniFFI

Rust 侧桥接 crate 位于上游 MDBX workspace：

```text
mdbx/crates/mdbx-ffi
```

`Artifacts/MDBX/`（约 70MB）与 `Generated/MDBXUniFFI/` 都是 `.gitignore` 排除的构建产物，不入库。

#### 一键准备（推荐）

```bash
Scripts/bootstrap.sh
```

脚本会自动检查前置条件、安装缺失的 Rust target 与 UniFFI CLI，并生成 xcframework。
产物已存在时直接跳过；强制重生成用 `Scripts/bootstrap.sh --force`。

前置条件——上游 MDBX workspace 必须与本仓库同级：

```text
<workspace>/
├── Monica-for-iOS/   ← 本仓库
└── mdbx/            ← 上游 MDBX workspace
```

若还没有：

```bash
cd .. && git clone https://github.com/Monica-Pass/Mdbx.git mdbx
```

#### 产物缺失时的行为

**不再导致包解析失败。** `SwiftPackages/MonicaMDBX/Package.swift` 仅在产物存在时才声明
`binaryTarget`，源码用 `#if canImport(mdbx_ffiFFI)` 守卫：

| 状态 | `xcodebuild -list` | `xcodebuild build` | 运行时 |
| --- | --- | --- | --- |
| 产物存在 | ✅ | ✅ | MDBX 正常 |
| 产物缺失 | ✅ | ✅ | 抛 `unavailableOnCurrentPlatform` |

也就是说缺产物时工程仍可在 IDE 中打开、编译、跑非保险库相关的测试，只是无法解锁保险库。
这避免了以前「连工程都解析不了」的死局。

#### 手动分步构建

```bash
Scripts/generate-mdbx-swift-bindings.sh   # 生成 Swift binding
Scripts/build-mdbx-xcframework.sh        # 打包 xcframework（约 1–2 分钟）
```

需要的 Rust target 与 UniFFI CLI 版本：

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
cargo install uniffi --version 0.31.1 --locked --features cli
```

注意：不要把 `Scripts/build-mdbx-xcframework.sh` 和 Xcode build 并行运行。脚本会替换 `MonicaMDBXGenerated.xcframework`，Xcode 在替换期间读取产物可能失败。

### 验证命令

全部 Swift package 都可以在 macOS 上直接跑：

```bash
cd SwiftPackages/MonicaCore && swift test
cd ../MonicaSecurity && swift test
cd ../MonicaSync && swift test
cd ../MonicaMDBX && swift test
cd ../MonicaStorage && swift test
```

> `MonicaMDBXGenerated.xcframework` 同时携带 iOS 与 **macOS** slice，
> 所以依赖 MDBX 的两个包在 macOS 上走的是真实 FFI 路径，而不是降级 stub。
> 早先版本缺 macOS slice，会让这两个包在新版 SwiftPM 下直接构建失败——
> 补上 slice 后该问题消失（见 `Scripts/build-mdbx-xcframework.sh` 的 `MACOS_ARM64_TARGET`）。

如果 xcframework 缺失或只有旧 slice，`swift test` 仍可能报平台缺失，重跑 `Scripts/bootstrap.sh` 即可。

iOS simulator build：

```bash
xcrun simctl list devices available

xcodebuild \
  -project Monica.xcodeproj \
  -scheme Monica \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination "id=<iPhone simulator UUID>" \
  CODE_SIGNING_ALLOWED=NO \
  build
```

iOS simulator XCTest：

```bash
xcodebuild test \
  -project Monica.xcodeproj \
  -scheme Monica \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination "id=<iPhone simulator UUID>" \
  CODE_SIGNING_ALLOWED=NO
```

### CI

`.github/workflows/ci.yml` 是唯一的构建入口，只开 **3 个 macOS job**：

| Job | Runner | 内容 |
| --- | --- | --- |
| `lint` | ubuntu | plist/entitlements 解析、workflow YAML、可执行位、禁止入库产物、空白与冲突标记 |
| `mdbx-artifact` | macos | 构建 MDBX xcframework，上传为 artifact |
| `swift-packages` | macos | MonicaCore / MonicaSecurity / MonicaSync 并行 `swift test` |
| `app` | macos | 复用 MDBX artifact，跑 MDBX/Storage 包测试 + Release 构建 + XCTest |

设计要点：

- **只构建一次 MDBX**。此前两个 workflow 各自编译 Rust，同一产物造了两遍。
- **只构建一次 App**。`Monica` scheme 已通过 target dependency 包含三个扩展，
  再单独 build 各扩展 scheme 属重复劳动（旧设计是 4 scheme × 2 configuration = 8 个 job）。
- **Debug 构建已删除**。Release 做完整优化与链接，Debug 的增量价值不足以占一个 macOS job。
- **静态检查全部下沉到 ubuntu**。macOS runner 在公共仓库排队很慢，
  曾因容量不足导致 job 直接 cancelled（`The job was not acquired by Runner of type hosted`）。
- 同一 ref 的旧运行会被自动取消（`concurrency`），避免堆积。

### 签名与分发

> iOS 应用**不需要公证（notarization）**——公证是 macOS 分发的要求。
> iOS 的链路是：**签名 → archive → 导出 .ipa → 上传 App Store Connect**。

#### 账号与 Team

| 项目 | 值 |
| --- | --- |
| Team ID | `X84WC7J5JH`（Apple Developer Program，含订阅） |
| 主 App | `com.monicapass.monica` |
| AutoFill 扩展 | `com.monicapass.monica.autofill` |
| Share 扩展 | `com.monicapass.monica.share` |
| Widget 扩展 | `com.monicapass.monica.widget` |
| App Group | `group.com.monicapass.monica` |

所有 target 的 `DEVELOPMENT_TEAM` 必须一致，否则 archive 会失败（App 与扩展必须同一 team 签名）。

> **为什么换掉了 `com.monica-pass.monica`**：旧团队 `4884UYF643`（WENXI ZHAN）的会员资格已过期，
> 它名下仍保留着 `com.monica-pass.monica*` 与 `group.monica-pass.monica`。
> App Group 与 Bundle ID 都是**全局唯一**的，新团队无法复用同名，
> 所以整体迁移到 `com.monicapass.monica` 前缀（去掉连字符）。
> 过期团队的标识符既无法删除也无法续用，这条路是唯一的。

#### 门户侧一次性配置（需账号持有人操作）

在 developer.apple.com 与 App Store Connect 中为 Team `X84WC7J5JH` 完成：

0. **至少注册一台设备**（Certificates, Identifiers & Profiles → Devices）。
   自动签名在 archive 阶段会先生成开发描述文件，而开发描述文件必须包含设备；
   团队里 0 台设备会报 `Your team has no devices from which to generate a
   provisioning profile`。App Store 描述文件本身不含设备，但 Xcode 的自动签名
   流程绕不开这一步。
1. 注册上述 4 个 App ID（显式 Bundle ID）
2. 创建 App Group `group.com.monicapass.monica`，并勾选到全部 4 个 App ID
3. 为各 App ID 开启 Capability：
   - 主 App：App Groups、Keychain Sharing、**AutoFill Credential Provider**、Passkeys
   - AutoFill 扩展：App Groups、Keychain Sharing、AutoFill Credential Provider
   - Share / Widget 扩展：App Groups
4. 在 App Store Connect 创建 App，Bundle ID 选 `com.monicapass.monica`

> 门户尚未创建上述标识符时，Xcode 会报
> `An Application Group with Identifier 'group.com.monicapass.monica' is not available`——
> 这不是代码问题。注意这句报错也可能是「同名已被其他 team 占用」，
> 若确认新名字从未注册过，才是「还没创建」。

#### 已知问题：`exportArchive Copy failed`

macOS 26 起 `/usr/bin/rsync` 换成了 **openrsync**，不再支持 `-E`（extended attributes）。
Xcode 打包 IPA 时会用它拷贝 dSYM 目录，于是必然失败：

```text
rsync: on remote machine: extended-attributes: unknown option
rsync error: syntax or usage error (code 1)
error: exportArchive Copy failed
```

**这不是签名问题**——此时签名已完成，IPA 只差最后一步打包。
`/usr/bin` 受 SIP 保护无法替换，Xcode 也不读 `PATH`，因此 `ExportOptions.plist`
里设了 `uploadSymbols = false` 跳过该步。dSYM 仍在
`Build/Monica.xcarchive/Products/dSYMs`，需要时用 App Store Connect API 或
Xcode Organizer 单独上传，崩溃日志照样能符号化。

#### 归档与上传

```bash
Scripts/archive.sh                                    # 归档 + 导出 ipa
Scripts/archive.sh --version 0.2.0 --build 12         # 指定版本号
Scripts/archive.sh --upload                           # 归档 + 导出 + 上传
```

上传需要 App Store Connect API Key：

```bash
export APP_STORE_CONNECT_API_KEY_PATH=/path/AuthKey_XXX.p8
export APP_STORE_CONNECT_API_KEY_ID=XXXXXXXXXX
export APP_STORE_CONNECT_API_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
Scripts/archive.sh --upload
```

不走脚本时，也可以 `xcodebuild archive` 后在 Xcode Organizer 里手动分发。

#### 证书

```bash
security find-identity -v -p codesigning   # 查看本机可用签名身份
```

Team `X84WC7J5JH` 对应证书：`Apple Development: xia li (X5M4TRM8J7)`。
CI 签名需要把证书与描述文件导出为 secrets，或在 workflow 中使用
`xcodebuild -allowProvisioningUpdates` + App Store Connect API Key 走云签名。

### 功能差异跟踪

Android/iOS 的功能差异**只以 GitHub issue 为事实源**，仓库内不保留审计报告副本。

| 项目 | 位置 |
| --- | --- |
| 总览（含分类索引与基线说明） | issue [#67](https://github.com/Monica-Pass/Monica-for-iOS/issues/67) |
| 单项差异 | issue #10–#66，每条附 `file:line` 取证 |
| 工程债 | issue #68–#75（标签 `工程债`） |

#### 已归档：`.parity-reports/`

两份逐条盘点（`android-features.md` 326 行、`ios-features.md` 273 行）曾作为 57 条差异 issue 的依据，现已移出仓库。

- **基线**：Android `main@e63d0ce` × iOS `e49c83c`，成文于 2026-11-12
- **为何归档**：成文后 `main` 已前进 45 个提交，其中 `6507321`、`59773ad` 两个提交专门补齐了大批差异项。
  报告中的「Bitwarden ✕ / Passkey ○ / 自动填充保存 ✕ / 无 CI / 无 README」等结论均已失效。
  逐条复核后：**关闭 10 条**（#18 #19 #20 #21 #38 #43 #51 #54 #57 #64）、**改写 9 条**（#13 #17 #23 #34 #35 #40 #52 #56 #59）、
  **修正 2 条平台判定**（#38 #40 从 `iOS 不可能` 改为 `iOS 可实现`）。
- **为何不再维护**：平行文档必然随代码漂移，本次失真正是这么产生的。改为 issue 逐条跟踪，每条可独立关闭。
- `.gitignore` 保留 `.parity-reports/`，防止本地副本被误提交。

若需重新盘点，**产出物应是新的 issue**，而非仓库内的 Markdown 快照。

---

## 路线

- 首发重点：MDBX 本地 Vault、核心条目管理、TOTP、WebDAV、iOS AutoFill。
- 持续推进：签名真机验收、Keychain/LocalAuthentication、App Group、QuickType、相机扫描。
- 后续能力：Passkey、Bitwarden 双向同步、附件体验、更多云服务、Widget / Live Activity 等 iOS 原生入口。

---

## 致谢

Monica 的设计、兼容性适配与部分功能方向，受到了以下优秀开源项目和软件的启发与帮助：

- [Bitwarden](https://bitwarden.com/) - 开源密码管理生态、Vault 模型与同步能力的重要参考。
- [KeePass](https://keepass.info/) - 本地密码库理念与 `.kdbx` 生态兼容的重要基础。
- [Keyguard](https://github.com/AChep/keyguard-app) - Android 端密码管理器的交互设计与体验参考。
- [Stratum Auth](https://github.com/stratumauth/app) - 身份验证器体验、图标资源与相关兼容支持参考。

---

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=Monica-Pass/Monica-for-iOS&type=Date)](https://star-history.com/#Monica-Pass/Monica-for-iOS&Date)

---

## 许可证

Copyright (c) 2025 JoyinJoester

Monica for iOS 基于 [GNU General Public License v3.0](LICENSE) 开源发布。

## 第三方图标标注

- 本项目使用的第三方图标资源来自 [Stratum Auth app](https://github.com/stratumauth/app)（版本 [v1.4.0](https://github.com/stratumauth/app/releases/tag/v1.4.0)，目录 [icons](https://github.com/stratumauth/app/tree/v1.4.0/icons) / [extraicons](https://github.com/stratumauth/app/tree/v1.4.0/extraicons)，GPL-3.0）。
- 品牌名称与 Logo 的商标权归各自权利人所有。
