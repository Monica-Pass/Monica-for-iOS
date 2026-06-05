# iOS Android Parity PR

## Summary

This PR aligns the iOS app with the current Android parity surface while keeping platform-specific decisions explicit:

- Google Drive is intentionally not implemented for iOS in this PR.
- Android IME is intentionally not implemented; iOS uses AutoFill, AppIntents/Shortcuts, widgets, and the share extension as native equivalents.
- Plus remains a local one-button unlock with no payment, order, price, or external payment behavior.
- Signed-device-only validation remains listed below for follow-up hardware verification.

## Implemented

- Bitwarden password login, 2FA, full vault pull/push, folders, Sends, file Sends, attachments, retryable mutation queue, queue retry/clear, conflict summaries, and empty-vault guard.
- Android backup import/export coverage for active entries, trash restore, encrypted backup retry, attachment metadata/blob migration, and MDK migration status.
- Security center with weak password, reused password, missing TOTP, risky URL, duplicate login, and repair suggestions.
- Dedup engine as preview-first duplicate login merge, requiring user confirmation before mutations.
- Passkey storage, RP ID normalization, system registration inbox, assertion/registration metadata, and credential identity sync.
- OneDrive and WebDAV cloud file flows for list, upload, download, restore preview, writeback, and conditional overwrite.
- AutoFill encrypted index refresh, App Group/Keychain/identity diagnostics, system save inbox, blocked fields policy, and save blocked targets.
- Steam authenticator maFile/JSON import into an iOS TOTP draft without saving automatically.
- Monica Plus one-button local entitlement/resource unlock with persistence and no payment UI.
- Appearance, bottom bar, card/list/icon/color customization, templates/developer diagnostics/permission management entry points already present in iOS settings.

## iOS Native Equivalents

- Android Accessibility Service: represented as iOS AutoFill + Credential Provider diagnostics; no Accessibility copy/fill API is added.
- Android Quick Settings tile/manual fill: represented by AppIntents/Shortcuts and redacted shortcut snapshots.
- Android notification/foreground surfaces: represented by widgets and locked-state safe summaries.
- Android storage picker and cloud backup flows: represented by iOS document import/export, WebDAV, OneDrive, and local MDBX/KeePass flows.

## Platform Not Supported / Not Done

- Android IME.
- Google Drive.
- Android Accessibility overlay automation.
- Android payment screen behavior; iOS Plus intentionally stays local unlock only.

## Pending Signed-Device Validation

- AutoFill QuickType and Credential Provider identity presentation.
- Passkey associated domains and relying-party real registration/assertion.
- App Group sharing across app, AutoFill extension, widget, and share extension.
- Widget refresh timing on a physical device.
- OneDrive real account sign-in and app-folder read/write.
- WebDAV real endpoint upload/download/overwrite.

## Validation

- `swift test --package-path SwiftPackages/MonicaCore`
- `swift test --package-path SwiftPackages/MonicaStorage`
- `swift test --package-path SwiftPackages/MonicaSync`
- `swift test --package-path SwiftPackages/MonicaSecurity`
- `swift test --package-path SwiftPackages/MonicaUI`
- `git diff --check`
- Targeted simulator XCTest:
  - `VaultSessionModelTests/testSteamAuthenticatorImportPopulatesTotpDraftWithoutSavingOrLeakingSecrets`
  - `VaultSessionModelTests/testSettingsExposeSteamImportAndAutoFillPolicyManagement`
  - `VaultSessionModelTests/testAutoFillPolicyPersistsAndBlocksConfiguredSaveTargetsWithoutLeakingRequestSecrets`
- Debug simulator builds:
  - `Monica`
  - `MonicaAutoFillExtension`
  - `MonicaShareExtension`
  - `MonicaWidgetExtension`
- Release simulator build:
  - `Monica`
