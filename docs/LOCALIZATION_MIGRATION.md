# 应用内语言：`String(localized:)` 迁移清单（#133）

`Text("…")` 等 `LocalizedStringKey` 会跟随 `\.locale`；而 `String(localized:)` 固定从
`Bundle.main` 按**系统**语言解析，因此需要字符串的调用点改为 `appLocalized(_:)`
（定义见 `App/MonicaApp/AppRoot/AppLocalizationRuntime.swift`，由
`AppLanguageController` 在启动与切换时写入运行时语言）。

## 本轮已迁移

| 文件 | 迁移处数 |
| --- | --- |
| `App/MonicaApp/AppKeePassLibraryView.swift` | 50 |
| `App/MonicaApp/AppGPGKeySupport.swift` | 43 |
| `App/MonicaApp/AppAutoFillCenterView.swift` | 40 |
| `App/MonicaApp/AppUpdateCheckView.swift` | 16 |
| `App/MonicaApp/AppRoot/AppBillingSupport.swift` | 66 |

## 剩余待迁移（按调用点数量降序）

| 文件 | 调用点数 |
| --- | --- |
| `App/MonicaApp/AppRoot/AppSessionModel.swift` | 360 |
| `App/MonicaApp/AndroidParityVaultHomeView.swift` | 174 |
| `App/MonicaApp/SettingsRootView.swift` | 106 |
| `App/MonicaApp/MonicaSendShareView.swift` | 66 |
| `App/MonicaApp/GeneratorAdvancedSections.swift` | 52 |
| `App/MonicaApp/AppSecurityCenterDashboardView.swift` | 47 |
| `App/MonicaApp/AppRoot/AppOtpAuthImport.swift` | 47 |
| `App/MonicaApp/AppRoot/AppCloudBackupSupport.swift` | 42 |
| `App/MonicaApp/AppRoot/AppBitwardenSyncSupport.swift` | 35 |
| `App/MonicaApp/AppVaultTagViews.swift` | 33 |
| `Extensions/MonicaAutoFillExtension/AutoFillCredentialProviderViewController.swift` | 30 |
| `App/MonicaApp/AppRoot/AppTotpAdvancedSupport.swift` | 29 |
| `App/MonicaApp/AppRoot/AppSSOSupport.swift` | 27 |
| `App/MonicaApp/AppRoot/AppSteamGuardSupport.swift` | 26 |
| `App/MonicaApp/AppBarcodeItemSupport.swift` | 26 |
| `App/MonicaApp/AppAutoFillCapabilitySection.swift` | 26 |
| `App/MonicaApp/AppAccountTemplatesView.swift` | 26 |
| `App/MonicaApp/AndroidParityDesign.swift` | 26 |
| `App/MonicaApp/AppRoot/AppDataClearSupport.swift` | 22 |
| `App/MonicaApp/AppAutoFillDomainRules.swift` | 22 |
| `App/MonicaApp/AppAutoFillDefaultManagerGuideView.swift` | 22 |
| `App/MonicaApp/AppWebDAVCertificateTrustView.swift` | 21 |
| `App/MonicaApp/VaultItemExtrasViews.swift` | 20 |
| `App/MonicaApp/AppGlobalSearchView.swift` | 20 |
| `App/MonicaApp/GeneratorRootView.swift` | 19 |
| `App/MonicaApp/AppRoot/AppUnlockSupport.swift` | 19 |
| `App/MonicaApp/AppKeePassLibraryModel.swift` | 19 |
| `App/MonicaApp/AppRoot/AppNavigationTypes.swift` | 18 |
| `App/MonicaApp/AppAutoFillEnablementSection.swift` | 18 |
| `App/MonicaApp/SensitivePrivacySettingsView.swift` | 16 |
| `App/MonicaApp/AppDataClearView.swift` | 16 |
| `App/MonicaApp/SensitivePrivacyService.swift` | 15 |
| `App/MonicaApp/AppAppearanceCompatibility.swift` | 15 |
| `App/MonicaApp/AppRoot/AppVaultSnapshotSupport.swift` | 14 |
| `App/MonicaApp/AppKeePassCloudSupport.swift` | 14 |
| `App/MonicaApp/VaultFolderBrowserView.swift` | 13 |
| `App/MonicaApp/BankCardFaceView.swift` | 13 |
| `App/MonicaApp/AppVaultTagsSupport.swift` | 13 |
| `App/MonicaApp/AppItemIconPreferences.swift` | 13 |
| `App/MonicaApp/AppCloudKitSync.swift` | 13 |
| `App/MonicaApp/GeneratorSaveLoginSheet.swift` | 12 |
| `App/MonicaApp/AppRoot/AppTrashMaintenance.swift` | 12 |
| `App/MonicaApp/AppRoot/AppOperationTimeline.swift` | 12 |
| `App/MonicaApp/AppRootView.swift` | 10 |
| `App/MonicaApp/AppLoginDetailSupport.swift` | 10 |
| `App/MonicaApp/AppImportExportFormatsView.swift` | 9 |
| `App/MonicaApp/AppDeveloperSettingsView.swift` | 9 |
| `App/MonicaApp/LockScreenViews.swift` | 8 |
| `App/MonicaApp/AppTotpCardStyleSettingsView.swift` | 8 |
| `App/MonicaApp/AppThemeSettingsView.swift` | 8 |
| `App/MonicaApp/AppRoot/AppVaultRegistrySupport.swift` | 8 |
| `App/MonicaApp/AppRoot/AppSessionModel+AccountTemplates.swift` | 8 |
| `App/MonicaApp/AppRoot/AppPlusSupport.swift` | 8 |
| `App/MonicaApp/AppKeyboardInputSupport.swift` | 8 |
| `App/MonicaApp/IdentityDocumentPhotoSection.swift` | 7 |
| `App/MonicaApp/BitwardenSyncMergeSummaryView.swift` | 7 |
| `App/MonicaApp/AppRoot/AppSecurityCenterSupport.swift` | 7 |
| `App/MonicaApp/AppRoot/AppImportExportSupport.swift` | 7 |
| `App/MonicaApp/AppRoot/AppAutoFillSupport.swift` | 7 |
| `App/MonicaApp/AppRoot/AppAppearancePreferences.swift` | 7 |
| `App/MonicaApp/AppCredentialExchange.swift` | 7 |
| `App/MonicaApp/AppGoogleDriveAuthenticationService.swift` | 6 |
| `App/MonicaApp/AppCredentialExchangePasskeys.swift` | 6 |
| `App/MonicaApp/GeneratorHistoryController.swift` | 5 |
| `App/MonicaApp/AppTotpAutoCopySettingsView.swift` | 5 |
| `App/MonicaApp/AppRoot/AppSessionModel+VaultRegistry.swift` | 5 |
| `App/MonicaApp/AppRoot/AppQuickSetupSupport.swift` | 5 |
| `App/MonicaApp/AppPlusStoreKit.swift` | 5 |
| `App/MonicaApp/AppAutoFillGuard.swift` | 5 |
| `App/MonicaApp/AppSettingsSearch.swift` | 4 |
| `App/MonicaApp/AppRoot/AppSessionModel+GeneratedLogin.swift` | 4 |
| `App/MonicaApp/AppNoteTileGrid.swift` | 4 |
| `App/MonicaApp/AppItemIconPickerView.swift` | 4 |
| `App/MonicaApp/AppAutoFillDeviceVerificationSection.swift` | 4 |
| `Extensions/MonicaWidgetExtension/MonicaWidget.swift` | 3 |
| `App/MonicaApp/MonicaAppEnvironment.swift` | 3 |
| `App/MonicaApp/AppRoot/VaultRegistryViews.swift` | 3 |
| `App/MonicaApp/AppRoot/AppAttachmentSupport.swift` | 3 |
| `App/MonicaApp/AppMarkdownNotes.swift` | 3 |
| `App/MonicaApp/AppAuthenticatorLiveActivity.swift` | 3 |
| `Extensions/MonicaShareExtension/ShareViewController.swift` | 2 |
| `App/MonicaApp/AppWidgetSnapshotSupport.swift` | 2 |
| `App/MonicaApp/AppTotpProgressViews.swift` | 2 |
| `App/MonicaApp/AppRoot/AppSessionModel+ItemExtras.swift` | 2 |
| `App/MonicaApp/AppRoot/AppLanguagePreferences.swift` | 2 |
| `App/MonicaApp/AppMarkdownNotesView.swift` | 2 |
| `App/MonicaApp/AppAutoFillDiagnostics.swift` | 2 |
| `App/MonicaApp/AppAlternateAppIcon.swift` | 2 |
| `App/MonicaApp/OneDriveMSALAuthenticationService.swift` | 1 |
| `App/MonicaApp/AppSystemPasskeyRegistrationInboxStore.swift` | 1 |
| `App/MonicaApp/AppRoot/VaultSnapshotViews.swift` | 1 |
| `App/MonicaApp/AppRoot/AppLocalizationRuntime.swift` | 1 |
| `App/MonicaApp/AppRoot/AppImportExportFormatsSupport.swift` | 1 |
| `App/MonicaApp/AppRoot/AppAccountTemplateSupport.swift` | 1 |
| `App/MonicaApp/AppKeePassCloudBrowserView.swift` | 1 |
