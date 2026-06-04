<h1 align="center">Monica for iOS</h1>

<div align="center">

<p><strong>Monica 的本地优先 iOS 密码库客户端</strong></p>
<p>iOS 17+ · SwiftUI · MDBX Vault · AutoFill · TOTP · WebDAV</p>

[![Release](https://img.shields.io/github/v/release/Monica-Pass/Monica-for-iOS?style=flat-square)](https://github.com/Monica-Pass/Monica-for-iOS/releases)
[![Downloads](https://img.shields.io/github/downloads/Monica-Pass/Monica-for-iOS/total?style=flat-square)](https://github.com/Monica-Pass/Monica-for-iOS/releases)
[![Last Commit](https://img.shields.io/github/last-commit/Monica-Pass/Monica-for-iOS?style=flat-square)](https://github.com/Monica-Pass/Monica-for-iOS/commits)
[![License](https://img.shields.io/badge/License-GPL--3.0-blue?style=flat-square)](LICENSE)

</div>

Monica for iOS 是 Monica 密码库生态的 SwiftUI 客户端。项目以本地优先为核心，优先落地 MDBX 加密保险库、iOS 原生 AutoFill、TOTP、WebDAV 备份恢复，以及与 Android / MDBX 数据模型兼容的多类型条目管理。

当前开发路线锁定为 **MDBX 优先、iOS 17+、iPhone 优先、Rust/Swift UniFFI 桥接**。首个公开版本聚焦本地 Vault、核心条目、WebDAV 和较完整 AutoFill；Passkey、Bitwarden、附件和更多云能力会在后续阶段继续完善。

---

## 用户先看

### Monica for iOS 适合谁

- 需要本地优先密码管理，不希望核心凭据托管到第三方服务。
- 已在 Monica Android / MDBX 生态中管理密码、TOTP、私密笔记等数据。
- 希望使用 iOS 原生 AutoFill、Face ID / Touch ID 门禁和本地备份恢复。
- 需要在 iPhone 上管理登录项、安全笔记、TOTP、银行卡、证件元数据等多类型条目。

### 当前能力

- 本地 MDBX Vault：创建、打开、锁定本地加密保险库。
- 多类型条目：登录项、安全笔记、TOTP、银行卡、证件元数据等基础 CRUD。
- 收藏与搜索：支持收藏优先、只看收藏、会话内搜索和软删除恢复。
- TOTP：支持 `otpauth://` URI、二维码导入、验证码生成和剩余秒数刷新。
- iOS AutoFill：通过 Credential Provider Extension 读取加密索引并返回系统填充凭据。
- 安全解锁：Keychain + LocalAuthentication + MDBX `security_key`，不保存主密码。
- WebDAV：支持上传、下载、SHA-256 完整性校验、恢复预览和恢复前打开验证。
- OneDrive：已接入 MSAL 与 Microsoft Graph app-folder provider，真实账号与网络验收仍在推进。
- KeePass / KDBX：已完成现代 KDBX3/KDBX4 主链路读写兼容，后续继续扩展真实场景验收。

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
    ├── MonicaSync/
    └── MonicaUI/
```

### 技术栈

- App：SwiftUI、Observation、AuthenticationServices、LocalAuthentication、Keychain、WidgetKit。
- 本地 Vault：MDBX Rust workspace + UniFFI + `MonicaMDBX` Swift package。
- 核心逻辑：`MonicaCore` 提供 TOTP、`otpauth://` parser、安全随机密码生成等能力。
- 存储：`MonicaStorage` 负责本地 vault repository、KDBX 兼容、AutoFill 加密索引和 secret snapshot。
- 安全：`MonicaSecurity` 负责 Keychain/LocalAuthentication 边界和本地 key material 管理。
- 同步：`MonicaSync` 提供 WebDAV、OneDrive/CloudFile provider 和 Bitwarden 同步边界。

### MDBX UniFFI

Rust 侧桥接 crate 位于上游 MDBX workspace：

```text
mdbx/crates/mdbx-ios-ffi
```

生成 Swift binding：

```bash
Scripts/generate-mdbx-swift-bindings.sh
```

生成 iOS XCFramework：

```bash
Scripts/build-mdbx-xcframework.sh
```

如果缺少 UniFFI CLI：

```bash
cargo install uniffi --version 0.31.1 --locked --features cli
```

注意：不要把 `Scripts/build-mdbx-xcframework.sh` 和 Xcode build 并行运行。脚本会替换 `MonicaMDBXGenerated.xcframework`，Xcode 在替换期间读取产物可能失败。

### 验证命令

Swift package 测试：

```bash
cd SwiftPackages/MonicaCore && swift test
cd ../MonicaMDBX && swift test
cd ../MonicaStorage && swift test
cd ../MonicaSecurity && swift test
cd ../MonicaSync && swift test
cd ../MonicaUI && swift test
```

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
