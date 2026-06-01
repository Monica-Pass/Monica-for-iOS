@testable import Monica
import MonicaSecurity
import MonicaStorage
import MonicaSync
import SwiftUI
import UIKit
import XCTest

@MainActor
final class VaultSessionModelTests: XCTestCase {
    private func unlockNewVault(_ model: AppSessionModel) throws {
        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device"
        )
    }

    func testAndroidParityCoreTabsAreFirstClassDestinations() {
        XCTAssertEqual(
            MonicaAppTab.phaseOneAndroidParityTabs,
            [.passwords, .wallet, .totp, .passkeys, .notes, .generator, .settings]
        )
        XCTAssertEqual(MonicaAppTab.passwords.title, "密码")
        XCTAssertEqual(MonicaAppTab.totp.title, "验证")
        XCTAssertEqual(MonicaAppTab.wallet.systemImage, "creditcard")
        XCTAssertEqual(MonicaAppTab.passkeys.title, "通行")
        XCTAssertEqual(MonicaAppTab.generator.title, "生成")
        XCTAssertEqual(MonicaAppTab.settings.title, "设置")
    }

    func testAndroidParityTypographyUsesCompactIOSSizing() {
        XCTAssertLessThanOrEqual(AndroidParityTypography.screenTitleSize, 34)
        XCTAssertLessThanOrEqual(AndroidParityTypography.generatorTitleSize, 34)
        XCTAssertLessThanOrEqual(AndroidParityTypography.editorTitleSize, 24)
        XCTAssertLessThanOrEqual(AndroidParityTypography.prominentValueSize, 28)
        XCTAssertLessThanOrEqual(AndroidParityTypography.controlIconSize, 24)
    }

    func testForgotPasswordShowsNonRecoverableVaultGuidance() {
        let model = AppSessionModel()

        model.showForgotPasswordGuidance()

        XCTAssertEqual(
            model.vaultOperationState,
            .failed("主密码无法找回。可尝试 Keychain 生物识别解锁、打开可记得密码的备份，或新建保险库。")
        )
    }

    func testSecurityQuestionRecoveryResetsRememberedVaultPasswordAfterAnswersMatch() async throws {
        let engine = RecordingVaultEngine()
        engine.securityKeyOpenVaultID = "created-vault"
        let keychainService = RecordingAppVaultKeychainService()
        let wrappedKey = WrappedVaultKey(
            vaultID: "created-vault",
            wrappedKeyMaterial: Data(repeating: 0x2A, count: 32),
            keyAlgorithm: .keychainProtectedData,
            createdAt: Date(timeIntervalSince1970: 1_801_200_000)
        )
        keychainService.loadedWrappedKey = wrappedKey
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            vaultKeychainService: keychainService,
            vaultWrappedKeyProvider: { _ in wrappedKey },
            securityQuestionStore: MemorySecurityQuestionRecoveryStore()
        )
        let directory = URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true)

        model.vaultName = "Mobile"
        model.vaultPassword = "old password"
        try model.createLocalVault(in: directory, deviceID: "ios-app-test-device")
        try await model.prepareVaultKeychainUnlock()
        model.securityQuestion1ID = 1
        model.securityQuestion2ID = 3
        model.securityAnswer1 = "Tokyo"
        model.securityAnswer2 = "Blue"
        try model.saveSecurityQuestions()
        model.lockLocalVault()

        model.showForgotPasswordGuidance()
        XCTAssertEqual(model.forgotPasswordRecoveryStep, .verifySecurityQuestions)
        XCTAssertTrue(model.verifyForgotPasswordSecurityAnswers(answer1: " tokyo ", answer2: "BLUE"))
        model.forgotPasswordNewPassword = "new password"
        model.forgotPasswordConfirmPassword = "new password"

        try await model.resetForgottenPasswordWithVerifiedSecurityAnswers(
            deviceID: "ios-app-test-device"
        )

        XCTAssertEqual(keychainService.loadRequests.last?.vaultID, "created-vault")
        XCTAssertEqual(keychainService.loadRequests.last?.reason, "重设 Monica 主密码")
        XCTAssertEqual(engine.securityKeyOpenedVaults.last?.keyMaterial, Data(repeating: 0x2A, count: 32))
        XCTAssertEqual(engine.resetMasterPasswordCalls, [
            .init(vaultID: "created-vault", newPassword: "new password")
        ])
        XCTAssertEqual(model.vaultOperationState, .succeeded("主密码已重设，请使用新密码解锁。"))
        XCTAssertEqual(model.vaultState, .locked)
        XCTAssertEqual(model.vaultPassword, "")
    }

    func testSecurityQuestionRecoveryRejectsIncorrectAnswersWithoutOpeningVault() async throws {
        let engine = RecordingVaultEngine()
        let keychainService = RecordingAppVaultKeychainService()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            vaultKeychainService: keychainService,
            vaultWrappedKeyProvider: { _ in
                WrappedVaultKey(
                    vaultID: "created-vault",
                    wrappedKeyMaterial: Data(repeating: 0x2A, count: 32),
                    keyAlgorithm: .keychainProtectedData,
                    createdAt: Date(timeIntervalSince1970: 1_801_200_000)
                )
            },
            securityQuestionStore: MemorySecurityQuestionRecoveryStore()
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "old password"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device"
        )
        model.securityQuestion1ID = 1
        model.securityQuestion2ID = 3
        model.securityAnswer1 = "Tokyo"
        model.securityAnswer2 = "Blue"
        try model.saveSecurityQuestions()
        model.lockLocalVault()

        model.showForgotPasswordGuidance()
        XCTAssertFalse(model.verifyForgotPasswordSecurityAnswers(answer1: "Osaka", answer2: "Blue"))

        model.forgotPasswordNewPassword = "new password"
        model.forgotPasswordConfirmPassword = "new password"
        do {
            try await model.resetForgottenPasswordWithVerifiedSecurityAnswers(
                deviceID: "ios-app-test-device"
            )
            XCTFail("Reset should require verified security answers.")
        } catch {
            XCTAssertEqual(
                model.vaultOperationState,
                .failed("请先通过密保问题验证。")
            )
        }
        XCTAssertTrue(keychainService.loadRequests.isEmpty)
        XCTAssertTrue(engine.securityKeyOpenedVaults.isEmpty)
        XCTAssertTrue(engine.resetMasterPasswordCalls.isEmpty)
    }

    func testAndroidParityTabsMapToModuleSpecificVaultItemKinds() {
        XCTAssertEqual(MonicaAppTab.passwords.coreItemKind, .login)
        XCTAssertEqual(MonicaAppTab.totp.coreItemKind, .totp)
        XCTAssertEqual(MonicaAppTab.notes.coreItemKind, .note)
        XCTAssertEqual(MonicaAppTab.wallet.coreItemKind, .card)
        XCTAssertEqual(MonicaAppTab.passkeys.coreItemKind, .passkey)
        XCTAssertNil(MonicaAppTab.generator.coreItemKind)
        XCTAssertNil(MonicaAppTab.settings.coreItemKind)
    }

    func testAndroidParityFabRoutesOpenModuleSpecificAddEditors() {
        let model = AppSessionModel()

        model.presentAddEditor(for: .passwords)
        XCTAssertEqual(model.presentedEditorMode, .add(.login))

        model.presentAddEditor(for: .totp)
        XCTAssertEqual(model.presentedEditorMode, .add(.totp))

        model.presentAddEditor(for: .notes)
        XCTAssertEqual(model.presentedEditorMode, .add(.note))

        model.presentAddEditor(for: .wallet)
        XCTAssertEqual(model.presentedEditorMode, .add(.card))

        model.presentAddEditor(for: .passkeys)
        XCTAssertEqual(model.presentedEditorMode, .add(.passkey))

        model.presentAddEditor(for: .generator)
        XCTAssertNil(model.presentedEditorMode)
    }

    func testSelectingLoginEntryOpensEditEditorRoute() throws {
        let model = AppSessionModel()
        let entry = LocalLoginEntry(
            id: "login-1",
            projectID: "project-1",
            title: "GitHub",
            username: "alice",
            password: "secret",
            url: "https://github.com",
            favorite: true
        )

        model.presentEditEditor(for: entry)

        XCTAssertEqual(model.presentedEditorMode, .edit(VaultItemRoute(kind: .login, entryID: "login-1")))
        XCTAssertEqual(model.editingLoginEntryID, "login-1")
        XCTAssertEqual(model.editingLoginTitle, "GitHub")
        XCTAssertEqual(model.editingLoginFavorite, true)
    }

    func testSavingPresentedAddPasswordEditorUsesExistingCreateFlow() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine)
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device"
        )

        model.presentAddEditor(for: .passwords)
        model.loginTitle = "GitHub"
        model.loginUsername = "alice"
        model.loginPassword = "secret"
        model.loginURL = "https://github.com"

        try model.savePresentedEditor(projectTitle: "Personal")

        XCTAssertNil(model.presentedEditorMode)
        XCTAssertEqual(model.loginEntries.map(\.title), ["GitHub"])
        XCTAssertEqual(engine.createdProjects.first?.title, "Personal")
        XCTAssertEqual(engine.createdLoginEntries.first?.draft.title, "GitHub")
        XCTAssertEqual(model.loginPassword, "")
    }

    func testAutoFillIndexKeyMaterialProviderCreatesAndReusesStoredKeyMaterial() throws {
        let store = RecordingAppAutoFillIndexKeyMaterialStore()
        let provider = AppAutoFillIndexKeyMaterialProvider(
            store: store,
            randomBytes: { count in Data(repeating: 23, count: count) },
            now: { Date(timeIntervalSince1970: 1_800_600_000) }
        )

        let created = try provider.keyMaterial(for: "vault-1")
        let reused = try provider.keyMaterial(for: "vault-1")

        XCTAssertEqual(created, reused)
        XCTAssertEqual(created.vaultID, "vault-1")
        XCTAssertEqual(created.keyIdentifier, "autofill-index-key-v1")
        XCTAssertEqual(created.keyMaterial, Data(repeating: 23, count: 32))
        XCTAssertEqual(store.savedKeyMaterials, [created])
    }

    func testCreateLocalVaultUnlocksSessionThroughRepository() throws {
        let engine = RecordingVaultEngine()
        let rememberedVaultStore = MemoryRememberedVaultStore()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            rememberedVaultStore: rememberedVaultStore
        )
        let directory = URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true)

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(in: directory, deviceID: "ios-app-test-device")

        XCTAssertEqual(model.vaultState, .unlocked)
        XCTAssertEqual(model.activeVaultName, "Mobile")
        XCTAssertEqual(model.vaultOperationState, .succeeded("Mobile"))
        XCTAssertEqual(engine.createdVaults.first?.fileURL.lastPathComponent, "Mobile.mdbx")
        XCTAssertEqual(engine.createdVaults.first?.deviceID, "ios-app-test-device")
        XCTAssertEqual(
            rememberedVaultStore.savedDescriptor,
            LocalVaultDescriptor(
                fileURL: directory.appendingPathComponent("Mobile.mdbx"),
                displayName: "Mobile"
            )
        )
    }

    func testNewSessionRestoresRememberedVaultAndPasswordUnlockOpensIt() throws {
        let rememberedVaultStore = MemoryRememberedVaultStore()
        try rememberedVaultStore.save(
            RememberedVaultRecord(
                fileURL: URL(fileURLWithPath: "/tmp/monica-app-tests/Mobile.mdbx"),
                displayName: "Mobile",
                vaultID: "created-vault"
            )
        )
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            rememberedVaultStore: rememberedVaultStore
        )

        XCTAssertFalse(model.isFirstTimeVaultSetup)
        XCTAssertTrue(model.hasRememberedVault)

        model.vaultPassword = "中文 password 12345!"
        try model.unlockRememberedVaultWithPassword(deviceID: "ios-app-test-device")

        XCTAssertTrue(engine.createdVaults.isEmpty)
        XCTAssertEqual(engine.openedVaults.count, 1)
        XCTAssertEqual(engine.openedVaults.first?.fileURL.lastPathComponent, "Mobile.mdbx")
        XCTAssertEqual(engine.openedVaults.first?.password, "中文 password 12345!")
        XCTAssertEqual(model.vaultState, .unlocked)
        XCTAssertEqual(model.activeVaultName, "Mobile")
    }

    func testFirstTimePasswordSetupRequiresMatchingConfirmationBeforeCreatingVault() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            rememberedVaultStore: MemoryRememberedVaultStore()
        )
        let directory = URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true)

        XCTAssertTrue(model.isFirstTimeVaultSetup)
        model.vaultPassword = "abc123"
        model.beginFirstTimePasswordConfirmation()

        XCTAssertEqual(model.firstTimePasswordSetupStep, .confirmPassword)
        XCTAssertEqual(engine.createdVaults.count, 0)

        model.vaultPassword = "different"
        XCTAssertThrowsError(
            try model.confirmFirstTimePasswordAndCreateVault(
                in: directory,
                deviceID: "ios-app-test-device"
            )
        )

        XCTAssertEqual(model.firstTimePasswordSetupStep, .enterPassword)
        XCTAssertEqual(model.vaultOperationState, .failed("两次输入的主密码不一致。"))
        XCTAssertTrue(engine.createdVaults.isEmpty)

        model.vaultPassword = "abc123"
        model.beginFirstTimePasswordConfirmation()
        model.vaultPassword = "abc123"
        try model.confirmFirstTimePasswordAndCreateVault(
            in: directory,
            deviceID: "ios-app-test-device"
        )

        XCTAssertEqual(engine.createdVaults.count, 1)
        XCTAssertEqual(engine.createdVaults.first?.password, "abc123")
        XCTAssertEqual(model.vaultState, .unlocked)
    }

    func testBiometricUnlockButtonRequiresSettingsOptInAndUsesDeviceLabel() {
        let model = AppSessionModel(
            vaultKeychainService: RecordingAppVaultKeychainService(),
            rememberedVaultStore: MemoryRememberedVaultStore(
                record: RememberedVaultRecord(
                    fileURL: URL(fileURLWithPath: "/tmp/monica-app-tests/Mobile.mdbx"),
                    displayName: "Mobile",
                    vaultID: "created-vault"
                )
            ),
            biometricCapabilityProvider: { .available(.faceID) }
        )

        XCTAssertFalse(model.shouldShowBiometricUnlockOnLockScreen)

        model.isBiometricUnlockEnabled = true

        XCTAssertTrue(model.shouldShowBiometricUnlockOnLockScreen)
        XCTAssertEqual(model.biometricUnlockTitle, "使用 Face ID 解锁")
        XCTAssertEqual(model.biometricUnlockSystemImage, "faceid")
    }

    func testTouchIDDeviceUsesTouchIDBiometricCopy() {
        let model = AppSessionModel(
            vaultKeychainService: RecordingAppVaultKeychainService(),
            rememberedVaultStore: MemoryRememberedVaultStore(
                record: RememberedVaultRecord(
                    fileURL: URL(fileURLWithPath: "/tmp/monica-app-tests/Mobile.mdbx"),
                    displayName: "Mobile",
                    vaultID: "created-vault"
                )
            ),
            biometricCapabilityProvider: { .available(.touchID) }
        )

        model.isBiometricUnlockEnabled = true

        XCTAssertTrue(model.shouldShowBiometricUnlockOnLockScreen)
        XCTAssertEqual(model.biometricUnlockTitle, "使用 Touch ID 解锁")
        XCTAssertEqual(model.biometricUnlockSystemImage, "touchid")
    }

    func testPermissionStatusCenterExposesIOSNativeCapabilities() {
        let model = AppSessionModel()

        XCTAssertEqual(
            model.permissionStatusRows.map(\.title),
            ["相机", "AutoFill", "通知", "App Group", "Keychain"]
        )
        XCTAssertEqual(model.permissionStatusRows[0].value, "可检查")
        XCTAssertEqual(model.permissionStatusRows[1].value, "待配置")
        XCTAssertEqual(model.permissionStatusRows[3].value, "待配置")
        XCTAssertEqual(model.permissionStatusRows[4].value, "待配置")
    }

    func testPermissionStatusCenterUsesNotificationAuthorizationState() {
        let model = AppSessionModel(notificationPermissionStatusProvider: { .granted })

        XCTAssertEqual(model.permissionStatusRows[2].title, "通知")
        XCTAssertEqual(model.permissionStatusRows[2].value, "已允许")
    }

    func testPermissionStatusCenterOffersSettingsLinkForUserManagedPermissionsOnly() {
        let model = AppSessionModel()
        let appSettingsURL = URL(string: UIApplication.openSettingsURLString)

        XCTAssertEqual(model.permissionStatusRows[0].title, "相机")
        XCTAssertEqual(model.permissionStatusRows[0].settingsURL, appSettingsURL)
        XCTAssertEqual(model.permissionStatusRows[2].title, "通知")
        XCTAssertEqual(model.permissionStatusRows[2].settingsURL, appSettingsURL)
        XCTAssertNil(model.permissionStatusRows[3].settingsURL)
        XCTAssertNil(model.permissionStatusRows[4].settingsURL)
    }

    func testDeveloperDiagnosticsExposeRedactedOperationalState() {
        let model = AppSessionModel()
        let environment = MonicaAppEnvironment(
            appGroupIdentifier: "group.takagi.ru.monica",
            minimumIOSVersion: "17.0",
            firstBackupProvider: "WebDAV",
            localDeviceIdentifier: "ios-local-device-secret"
        )

        let rows = AppDeveloperDiagnostics.rows(
            environment: environment,
            session: model,
            storageStrategy: "MDBX",
            mdbxBridge: "UniFFI"
        )

        XCTAssertEqual(
            rows.map(\.title),
            ["主存储", "MDBX 桥接", "App Group", "本机标识", "AutoFill 索引", "同步日志"]
        )
        XCTAssertEqual(rows[0].value, "MDBX")
        XCTAssertEqual(rows[1].value, "UniFFI")
        XCTAssertEqual(rows[2].value, "group.takagi.ru.monica")
        XCTAssertFalse(rows[3].value.contains("secret"))
        XCTAssertEqual(rows[4].value, "未生成")
        XCTAssertEqual(rows[5].value, "空闲")
    }

    func testSecurityCenterSummarizesWeakAndReusedPasswordsWithoutLeakingSecrets() {
        let model = AppSessionModel()
        model.loginEntries = [
            LocalLoginEntry(
                id: "login-1",
                projectID: "project-1",
                title: "Short",
                username: "alice",
                password: "short",
                url: "https://short.example.com"
            ),
            LocalLoginEntry(
                id: "login-2",
                projectID: "project-1",
                title: "GitHub",
                username: "alice",
                password: "RepeatedStrong1!",
                url: "https://github.com"
            ),
            LocalLoginEntry(
                id: "login-3",
                projectID: "project-1",
                title: "GitLab",
                username: "alice",
                password: "RepeatedStrong1!",
                url: "https://gitlab.com"
            ),
            LocalLoginEntry(
                id: "login-4",
                projectID: "project-1",
                title: "Bank",
                username: "alice",
                password: "UniqueStrong1!",
                url: "https://bank.example.com"
            )
        ]

        let rows = model.securityCenterRows

        XCTAssertEqual(rows.map(\.title), ["弱密码", "复用密码", "重复项"])
        XCTAssertEqual(rows[0].value, "1 项")
        XCTAssertEqual(rows[1].value, "2 项")
        XCTAssertEqual(rows[2].value, "0 项")
        XCTAssertFalse(rows.map(\.detail).joined(separator: " ").contains("short"))
        XCTAssertFalse(rows.map(\.detail).joined(separator: " ").contains("RepeatedStrong1!"))
    }

    func testSecurityCenterSummarizesDuplicateLoginEntries() {
        let model = AppSessionModel()
        model.loginEntries = [
            LocalLoginEntry(
                id: "login-1",
                projectID: "project-1",
                title: " GitHub ",
                username: "Alice",
                password: "UniqueStrong1!",
                url: "https://github.com"
            ),
            LocalLoginEntry(
                id: "login-2",
                projectID: "project-1",
                title: "github",
                username: "alice",
                password: "OtherStrong1!",
                url: " https://github.com "
            ),
            LocalLoginEntry(
                id: "login-3",
                projectID: "project-1",
                title: "GitLab",
                username: "alice",
                password: "ThirdStrong1!",
                url: "https://gitlab.com"
            )
        ]

        let rows = model.securityCenterRows

        XCTAssertEqual(rows.map(\.title), ["弱密码", "复用密码", "重复项"])
        let duplicateRow = rows.first { $0.id == "duplicate-logins" }
        XCTAssertEqual(duplicateRow?.value, "2 项")
        XCTAssertFalse(duplicateRow?.detail.contains("UniqueStrong1!") ?? true)
        XCTAssertFalse(duplicateRow?.detail.contains("OtherStrong1!") ?? true)
    }

    func testCreateLocalVaultUsesDefaultNameWhenLockScreenNameIsBlank() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine)
        )
        let directory = URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true)

        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(in: directory, deviceID: "ios-app-test-device")

        XCTAssertEqual(model.vaultState, .unlocked)
        XCTAssertEqual(model.activeVaultName, "Monica")
        XCTAssertEqual(model.vaultOperationState, .succeeded("Monica"))
        XCTAssertEqual(engine.createdVaults.first?.fileURL.lastPathComponent, "Monica.mdbx")
    }

    func testOpenLocalVaultUnlocksSessionThroughRepository() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine)
        )
        let fileURL = URL(fileURLWithPath: "/tmp/monica-app-tests/Work.mdbx")

        model.vaultPassword = "中文 password 12345!"
        try model.openLocalVault(at: fileURL, deviceID: "ios-app-test-device")

        XCTAssertEqual(model.vaultState, .unlocked)
        XCTAssertEqual(model.activeVaultName, "Work")
        XCTAssertEqual(model.vaultOperationState, .succeeded("Work"))
        XCTAssertEqual(engine.openedVaults.first?.fileURL, fileURL)
        XCTAssertEqual(engine.openedVaults.first?.deviceID, "ios-app-test-device")
    }

    func testRememberedVaultPersistsAcrossColdStartForPasswordUnlock() throws {
        let store = MemoryRememberedVaultStore()
        let createEngine = RecordingVaultEngine()
        let directory = URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true)
        let firstLaunch = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: createEngine),
            rememberedVaultStore: store
        )

        XCTAssertTrue(firstLaunch.isFirstVaultSetupRequired)
        firstLaunch.vaultName = "Mobile"
        firstLaunch.vaultPassword = "中文 password 12345!"
        try firstLaunch.createLocalVault(in: directory, deviceID: "ios-app-test-device")

        let secondEngine = RecordingVaultEngine()
        secondEngine.openVaultID = "created-vault"
        let secondLaunch = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: secondEngine),
            rememberedVaultStore: store
        )

        XCTAssertFalse(secondLaunch.isFirstVaultSetupRequired)
        secondLaunch.vaultPassword = "中文 password 12345!"
        try secondLaunch.openRememberedLocalVaultWithPassword(deviceID: "ios-app-test-device")

        XCTAssertTrue(secondEngine.createdVaults.isEmpty)
        XCTAssertEqual(secondEngine.openedVaults.first?.fileURL, directory.appendingPathComponent("Mobile.mdbx"))
        XCTAssertEqual(secondEngine.openedVaults.first?.password, "中文 password 12345!")
        XCTAssertEqual(secondLaunch.vaultState, .unlocked)
        XCTAssertEqual(secondLaunch.activeVaultName, "Mobile")
    }

    func testBiometricUnlockIsOnlyShownAfterSettingsEnableAndUsesFaceIDCopy() async throws {
        let engine = RecordingVaultEngine()
        engine.openVaultID = "created-vault"
        let keychainService = RecordingAppVaultKeychainService()
        let biometricAuthorizer = RecordingBiometricUnlockAuthorizer(kind: .faceID)
        let preferenceStore = MemoryBiometricUnlockPreferenceStore()
        let wrappedKey = WrappedVaultKey(
            vaultID: "created-vault",
            wrappedKeyMaterial: Data([1, 2, 3, 4]),
            keyAlgorithm: .keychainProtectedData,
            createdAt: Date(timeIntervalSince1970: 1_801_000_000)
        )
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            vaultKeychainService: keychainService,
            vaultWrappedKeyProvider: { _ in wrappedKey },
            biometricUnlockPreferenceStore: preferenceStore,
            biometricUnlockAuthorizer: biometricAuthorizer,
            biometricCapabilityProvider: { .available(.faceID) }
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device"
        )
        model.lockLocalVault()
        XCTAssertFalse(model.shouldShowBiometricUnlockOnLockScreen)

        model.vaultPassword = "中文 password 12345!"
        try model.openRememberedLocalVaultWithPassword(deviceID: "ios-app-test-device")
        try await model.prepareVaultKeychainUnlock()
        model.lockLocalVault()

        XCTAssertTrue(preferenceStore.isEnabled)
        XCTAssertEqual(biometricAuthorizer.authenticationReasons, ["启用 Face ID 解锁"])
        XCTAssertTrue(model.shouldShowBiometricUnlockOnLockScreen)
        XCTAssertEqual(model.biometricUnlockButtonTitle, "使用 Face ID")
        XCTAssertEqual(model.biometricUnlockSystemImage, "faceid")
    }

    func testBiometricUnlockCanBeDisabledFromSettingsAndUsesTouchIDCopy() async throws {
        let engine = RecordingVaultEngine()
        let keychainService = RecordingAppVaultKeychainService()
        let biometricAuthorizer = RecordingBiometricUnlockAuthorizer(kind: .touchID)
        let preferenceStore = MemoryBiometricUnlockPreferenceStore()
        let wrappedKey = WrappedVaultKey(
            vaultID: "created-vault",
            wrappedKeyMaterial: Data([1, 2, 3, 4]),
            keyAlgorithm: .keychainProtectedData,
            createdAt: Date(timeIntervalSince1970: 1_801_000_000)
        )
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            vaultKeychainService: keychainService,
            vaultWrappedKeyProvider: { _ in wrappedKey },
            biometricUnlockPreferenceStore: preferenceStore,
            biometricUnlockAuthorizer: biometricAuthorizer,
            biometricCapabilityProvider: { .available(.touchID) }
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device"
        )
        try await model.prepareVaultKeychainUnlock()
        model.lockLocalVault()

        XCTAssertEqual(model.biometricUnlockButtonTitle, "使用 Touch ID")
        XCTAssertEqual(model.biometricUnlockSystemImage, "touchid")
        XCTAssertTrue(model.shouldShowBiometricUnlockOnLockScreen)

        model.setBiometricUnlockEnabled(false)

        XCTAssertFalse(preferenceStore.isEnabled)
        XCTAssertFalse(model.shouldShowBiometricUnlockOnLockScreen)
    }

    func testPreparingVaultKeychainUnlockSavesWrappedKeyWithoutPersistingMasterPassword() async throws {
        let engine = RecordingVaultEngine()
        let keychainService = RecordingAppVaultKeychainService()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            vaultKeychainService: keychainService,
            vaultWrappedKeyProvider: { session in
                WrappedVaultKey(
                    vaultID: session.handle.vaultID,
                    wrappedKeyMaterial: Data([1, 2, 3, 4]),
                    keyAlgorithm: .keychainProtectedData,
                    createdAt: Date(timeIntervalSince1970: 1_801_000_000)
                )
            }
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device"
        )

        try await model.prepareVaultKeychainUnlock()

        XCTAssertEqual(keychainService.savedWrappedKeys.count, 1)
        XCTAssertEqual(keychainService.savedWrappedKeys.first?.vaultID, "created-vault")
        XCTAssertEqual(keychainService.savedWrappedKeys.first?.wrappedKeyMaterial, Data([1, 2, 3, 4]))
        XCTAssertFalse(
            keychainService.savedWrappedKeys.first?.wrappedKeyMaterial
                == Data("中文 password 12345!".utf8)
        )
        XCTAssertEqual(engine.securityKeySetups.count, 1)
        XCTAssertEqual(engine.securityKeySetups.first?.vaultID, "created-vault")
        XCTAssertEqual(engine.securityKeySetups.first?.keyMaterial, Data([1, 2, 3, 4]))
        XCTAssertEqual(model.vaultKeychainState, .saved("created-vault"))
    }

    func testVaultKeychainUnlockUsesSecurityKeyMaterialWithoutMasterPasswordResolver() async throws {
        let engine = RecordingVaultEngine()
        engine.securityKeyOpenVaultID = "created-vault"
        let keychainService = RecordingAppVaultKeychainService()
        let wrappedKey = WrappedVaultKey(
            vaultID: "created-vault",
            wrappedKeyMaterial: Data(repeating: 0x2A, count: 32),
            keyAlgorithm: .keychainProtectedData,
            createdAt: Date(timeIntervalSince1970: 1_801_100_000)
        )
        keychainService.loadedWrappedKey = wrappedKey
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            vaultKeychainService: keychainService,
            vaultWrappedKeyProvider: { _ in wrappedKey }
        )
        let directory = URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true)

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(in: directory, deviceID: "ios-app-test-device")
        try await model.prepareVaultKeychainUnlock()
        model.lockLocalVault()

        try await model.unlockRememberedVaultWithKeychain(
            deviceID: "ios-app-test-device",
            now: Date(timeIntervalSince1970: 1_801_100_100)
        )

        XCTAssertEqual(keychainService.loadRequests.count, 1)
        XCTAssertEqual(keychainService.loadRequests.first?.vaultID, "created-vault")
        XCTAssertEqual(keychainService.loadRequests.first?.reason, "解锁 Monica 保险库")
        XCTAssertTrue(engine.openedVaults.isEmpty)
        XCTAssertEqual(
            engine.securityKeyOpenedVaults.last?.fileURL,
            directory.appendingPathComponent("Mobile.mdbx")
        )
        XCTAssertEqual(engine.securityKeyOpenedVaults.last?.keyMaterial, Data(repeating: 0x2A, count: 32))
        XCTAssertEqual(model.vaultState, .unlocked)
        XCTAssertEqual(model.activeVaultName, "Mobile")
        XCTAssertEqual(model.vaultPassword, "")
        XCTAssertEqual(model.vaultKeychainState, .unlocked("created-vault"))
    }

    func testCreateLocalVaultFailureClearsMasterPasswordAndKeepsVaultLocked() throws {
        let engine = RecordingVaultEngine()
        engine.createVaultError = LocalVaultRepositoryError.vaultUnavailable
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine)
        )

        model.vaultName = "Work"
        model.vaultPassword = "中文 password 12345!"

        XCTAssertThrowsError(
            try model.createLocalVault(
                in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
                deviceID: "ios-app-test-device"
            )
        )

        XCTAssertEqual(model.vaultState, .locked)
        XCTAssertNil(model.activeVaultName)
        XCTAssertEqual(model.vaultPassword, "")
        XCTAssertEqual(model.vaultOperationState, .failed("保险库会话已不可用。"))
        XCTAssertEqual(engine.createdVaults.count, 1)
    }

    func testOpenLocalVaultFailureClearsMasterPasswordAndKeepsVaultLocked() throws {
        let engine = RecordingVaultEngine()
        engine.openVaultError = LocalVaultRepositoryError.vaultUnavailable
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine)
        )
        let fileURL = URL(fileURLWithPath: "/tmp/monica-app-tests/Work.mdbx")

        model.vaultPassword = "中文 password 12345!"

        XCTAssertThrowsError(
            try model.openLocalVault(at: fileURL, deviceID: "ios-app-test-device")
        )

        XCTAssertEqual(model.vaultState, .locked)
        XCTAssertNil(model.activeVaultName)
        XCTAssertEqual(model.vaultPassword, "")
        XCTAssertEqual(model.vaultOperationState, .failed("保险库会话已不可用。"))
        XCTAssertEqual(engine.openedVaults.first?.fileURL, fileURL)
    }

    func testLockLocalVaultClearsActiveSession() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine)
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device"
        )

        model.lockLocalVault()

        XCTAssertEqual(model.vaultState, .locked)
        XCTAssertNil(model.activeVaultName)
        XCTAssertEqual(model.vaultOperationState, .idle)
        XCTAssertTrue(model.loginEntries.isEmpty)
        XCTAssertEqual(model.entryOperationState, .idle)
    }

    func testCreateLoginEntryInActiveVaultCreatesDefaultProjectAndListsEntry() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine)
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device"
        )

        model.loginTitle = "GitHub"
        model.loginUsername = "alice"
        model.loginPassword = "correct horse battery staple"
        model.loginURL = "https://github.com"
        try model.createLoginEntry(projectTitle: "Personal")

        XCTAssertEqual(model.entryOperationState, .succeeded("GitHub"))
        XCTAssertEqual(model.loginEntries.count, 1)
        XCTAssertEqual(model.loginEntries.first?.title, "GitHub")
        XCTAssertEqual(model.loginEntries.first?.username, "alice")
        XCTAssertEqual(model.loginPassword, "")
        XCTAssertEqual(engine.createdProjects.first?.title, "Personal")
        XCTAssertEqual(engine.createdLoginEntries.first?.draft.title, "GitHub")
    }

    func testGenerateLoginPasswordFillsDraftWithoutSavingEntry() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            passwordGenerator: { "Generated-Password-123!" }
        )

        try model.generateLoginPassword()

        XCTAssertEqual(model.loginPassword, "Generated-Password-123!")
        XCTAssertEqual(model.entryOperationState, .succeeded("已生成密码"))
        XCTAssertTrue(engine.createdLoginEntries.isEmpty)
    }

    func testSearchFiltersLoginEntriesByTitleUsernameAndURL() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine)
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device"
        )

        model.loginTitle = "GitHub"
        model.loginUsername = "alice"
        model.loginPassword = "github-secret"
        model.loginURL = "https://github.com"
        try model.createLoginEntry(projectTitle: "Personal")

        model.loginTitle = "Apple ID"
        model.loginUsername = "bob@example.com"
        model.loginPassword = "apple-secret"
        model.loginURL = "https://appleid.apple.com"
        try model.createLoginEntry(projectTitle: "Personal")

        model.loginSearchQuery = "git"
        XCTAssertEqual(model.filteredLoginEntries.map(\.title), ["GitHub"])

        model.loginSearchQuery = "bob@"
        XCTAssertEqual(model.filteredLoginEntries.map(\.title), ["Apple ID"])

        model.loginSearchQuery = "appleid"
        XCTAssertEqual(model.filteredLoginEntries.map(\.title), ["Apple ID"])

        model.loginSearchQuery = "  "
        XCTAssertEqual(model.filteredLoginEntries.map(\.title), ["GitHub", "Apple ID"])

        model.loginSearchQuery = "apple"
        model.lockLocalVault()

        XCTAssertEqual(model.loginSearchQuery, "")
        XCTAssertTrue(model.filteredLoginEntries.isEmpty)
    }

    func testUpdateSelectedLoginEntryRefreshesCurrentSessionList() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine)
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device"
        )

        model.loginTitle = "GitHub"
        model.loginUsername = "alice"
        model.loginPassword = "old-password"
        model.loginURL = "https://github.com"
        try model.createLoginEntry(projectTitle: "Personal")

        let created = try XCTUnwrap(model.loginEntries.first)
        model.selectLoginEntryForEditing(created)

        XCTAssertEqual(model.editingLoginEntryID, created.id)
        XCTAssertEqual(model.editingLoginTitle, "GitHub")
        XCTAssertEqual(model.editingLoginUsername, "alice")

        model.editingLoginTitle = "GitHub Work"
        model.editingLoginUsername = "alice@example.com"
        model.editingLoginPassword = "new-password"
        model.editingLoginURL = "https://github.com/settings/profile"
        try model.updateSelectedLoginEntry()

        XCTAssertEqual(model.entryOperationState, .succeeded("GitHub Work"))
        XCTAssertEqual(model.loginEntries.count, 1)
        XCTAssertEqual(model.loginEntries.first?.id, created.id)
        XCTAssertEqual(model.loginEntries.first?.title, "GitHub Work")
        XCTAssertEqual(model.loginEntries.first?.username, "alice@example.com")
        XCTAssertEqual(model.loginEntries.first?.password, "new-password")
        XCTAssertEqual(model.loginEntries.first?.url, "https://github.com/settings/profile")
        XCTAssertEqual(engine.updatedLoginEntries.first?.entryID, created.id)
        XCTAssertEqual(engine.updatedLoginEntries.first?.draft.title, "GitHub Work")

        model.lockLocalVault()

        XCTAssertNil(model.editingLoginEntryID)
        XCTAssertEqual(model.editingLoginTitle, "")
        XCTAssertEqual(model.editingLoginPassword, "")
    }

    func testSetSelectedLoginFavoriteUpdatesCurrentSessionWithoutChangingPayload() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine)
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device"
        )

        model.loginTitle = "GitHub"
        model.loginUsername = "alice"
        model.loginPassword = "old-password"
        model.loginURL = "https://github.com"
        try model.createLoginEntry(projectTitle: "Personal")

        let created = try XCTUnwrap(model.loginEntries.first)
        model.selectLoginEntryForEditing(created)
        try model.setSelectedLoginFavorite(true)

        XCTAssertEqual(model.entryOperationState, .succeeded("已收藏 GitHub"))
        XCTAssertEqual(model.loginEntries.first?.id, created.id)
        XCTAssertEqual(model.loginEntries.first?.password, "old-password")
        XCTAssertEqual(model.loginEntries.first?.favorite, true)
        XCTAssertEqual(model.editingLoginEntryID, created.id)
        XCTAssertEqual(model.editingLoginFavorite, true)
        XCTAssertEqual(engine.favoritedLoginEntries.first?.entryID, created.id)
        XCTAssertEqual(engine.favoritedLoginEntries.first?.favorite, true)
        XCTAssertTrue(engine.updatedLoginEntries.isEmpty)
    }

    func testSetSelectedTypedEntryFavoritesUpdateCurrentSessionWithoutChangingPayload() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine)
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device"
        )

        model.noteTitle = "Recovery Codes"
        model.noteBody = "github: 123456"
        try model.createNoteEntry(projectTitle: "Personal")
        let note = try XCTUnwrap(model.noteEntries.first)

        model.totpTitle = "GitHub TOTP"
        model.totpSecret = "JBSWY3DPEHPK3PXP"
        model.totpIssuer = "GitHub"
        model.totpAccountName = "alice"
        try model.createTotpEntry(projectTitle: "Personal")
        let totp = try XCTUnwrap(model.totpEntries.first)

        model.cardTitle = "Everyday Visa"
        model.cardholderName = "Alice Example"
        model.cardNumber = "4111111111111111"
        model.cardExpiryMonth = "12"
        model.cardExpiryYear = "2031"
        model.cardCVV = "123"
        model.cardIssuer = "Monica Bank"
        model.cardNetwork = "Visa"
        model.cardNotes = "Primary checking card"
        try model.createCardEntry(projectTitle: "Personal")
        let card = try XCTUnwrap(model.cardEntries.first)

        model.identityTitle = "Passport"
        model.identityDocumentType = "passport"
        model.identityFullName = "Alice Example"
        model.identityDocumentNumber = "P1234567"
        model.identityIssuer = "Monica Authority"
        model.identityCountry = "US"
        model.identityIssueDate = "2026-01-02"
        model.identityExpiryDate = "2036-01-01"
        model.identityNotes = "Primary travel document"
        try model.createIdentityEntry(projectTitle: "Personal")
        let identity = try XCTUnwrap(model.identityEntries.first)

        model.selectNoteEntryForEditing(note)
        try model.setSelectedNoteFavorite(true)

        XCTAssertEqual(model.entryOperationState, .succeeded("已收藏 Recovery Codes"))
        XCTAssertEqual(model.noteEntries.first?.id, note.id)
        XCTAssertEqual(model.noteEntries.first?.body, "github: 123456")
        XCTAssertEqual(model.noteEntries.first?.favorite, true)
        XCTAssertEqual(model.editingNoteEntryID, note.id)
        XCTAssertEqual(model.editingNoteFavorite, true)
        XCTAssertEqual(engine.favoritedNoteEntries.first?.entryID, note.id)
        XCTAssertEqual(engine.favoritedNoteEntries.first?.favorite, true)
        XCTAssertTrue(engine.updatedNoteEntries.isEmpty)

        model.selectTotpEntryForEditing(totp)
        try model.setSelectedTotpFavorite(true)

        XCTAssertEqual(model.entryOperationState, .succeeded("已收藏 GitHub TOTP"))
        XCTAssertEqual(model.totpEntries.first?.id, totp.id)
        XCTAssertEqual(model.totpEntries.first?.secret, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(model.totpEntries.first?.favorite, true)
        XCTAssertEqual(model.editingTotpEntryID, totp.id)
        XCTAssertEqual(model.editingTotpFavorite, true)
        XCTAssertEqual(engine.favoritedTotpEntries.first?.entryID, totp.id)
        XCTAssertEqual(engine.favoritedTotpEntries.first?.favorite, true)
        XCTAssertTrue(engine.updatedTotpEntries.isEmpty)

        model.selectCardEntryForEditing(card)
        try model.setSelectedCardFavorite(true)

        XCTAssertEqual(model.entryOperationState, .succeeded("已收藏 Everyday Visa"))
        XCTAssertEqual(model.cardEntries.first?.id, card.id)
        XCTAssertEqual(model.cardEntries.first?.number, "4111111111111111")
        XCTAssertEqual(model.cardEntries.first?.cvv, "123")
        XCTAssertEqual(model.cardEntries.first?.favorite, true)
        XCTAssertEqual(model.editingCardEntryID, card.id)
        XCTAssertEqual(model.editingCardFavorite, true)
        XCTAssertEqual(engine.favoritedCardEntries.first?.entryID, card.id)
        XCTAssertEqual(engine.favoritedCardEntries.first?.favorite, true)
        XCTAssertTrue(engine.updatedCardEntries.isEmpty)

        model.selectIdentityEntryForEditing(identity)
        try model.setSelectedIdentityFavorite(true)

        XCTAssertEqual(model.entryOperationState, .succeeded("已收藏 Passport"))
        XCTAssertEqual(model.identityEntries.first?.id, identity.id)
        XCTAssertEqual(model.identityEntries.first?.documentNumber, "P1234567")
        XCTAssertEqual(model.identityEntries.first?.favorite, true)
        XCTAssertEqual(model.editingIdentityEntryID, identity.id)
        XCTAssertEqual(model.editingIdentityFavorite, true)
        XCTAssertEqual(engine.favoritedIdentityEntries.first?.entryID, identity.id)
        XCTAssertEqual(engine.favoritedIdentityEntries.first?.favorite, true)
        XCTAssertTrue(engine.updatedIdentityEntries.isEmpty)
    }

    func testFilteredEntryListsPrioritizeAndFilterFavoritesAcrossTypes() throws {
        let model = AppSessionModel()

        model.loginEntries = [
            LocalLoginEntry(
                id: "login-1",
                projectID: "project-1",
                title: "Apple ID",
                username: "alice",
                password: "apple-secret",
                url: "https://appleid.apple.com",
                favorite: false
            ),
            LocalLoginEntry(
                id: "login-2",
                projectID: "project-1",
                title: "GitHub",
                username: "alice",
                password: "github-secret",
                url: "https://github.com",
                favorite: true
            )
        ]
        model.noteEntries = [
            LocalNoteEntry(
                id: "note-1",
                projectID: "project-1",
                title: "Router",
                body: "network notes",
                favorite: false
            ),
            LocalNoteEntry(
                id: "note-2",
                projectID: "project-1",
                title: "Recovery Codes",
                body: "github recovery",
                favorite: true
            )
        ]
        model.totpEntries = [
            LocalTotpEntry(
                id: "totp-1",
                projectID: "project-1",
                title: "Apple TOTP",
                secret: "JBSWY3DPEHPK3PXP",
                issuer: "Apple",
                accountName: "alice",
                period: 30,
                digits: 6,
                algorithm: "SHA1",
                otpType: "TOTP",
                counter: 0,
                favorite: false
            ),
            LocalTotpEntry(
                id: "totp-2",
                projectID: "project-1",
                title: "GitHub TOTP",
                secret: "JBSWY3DPEHPK3PXQ",
                issuer: "GitHub",
                accountName: "alice",
                period: 30,
                digits: 6,
                algorithm: "SHA1",
                otpType: "TOTP",
                counter: 0,
                favorite: true
            )
        ]
        model.cardEntries = [
            LocalCardEntry(
                id: "card-1",
                projectID: "project-1",
                title: "Everyday Visa",
                cardholderName: "Alice Example",
                number: "4111111111111111",
                expiryMonth: "12",
                expiryYear: "2031",
                cvv: "123",
                issuer: "Monica Bank",
                network: "Visa",
                notes: "",
                favorite: false
            ),
            LocalCardEntry(
                id: "card-2",
                projectID: "project-1",
                title: "Travel Mastercard",
                cardholderName: "Alice Example",
                number: "5555555555554444",
                expiryMonth: "01",
                expiryYear: "2032",
                cvv: "456",
                issuer: "Monica Credit Union",
                network: "Mastercard",
                notes: "",
                favorite: true
            )
        ]
        model.identityEntries = [
            LocalIdentityEntry(
                id: "identity-1",
                projectID: "project-1",
                title: "Driver License",
                documentType: "driver_license",
                fullName: "Alice Example",
                documentNumber: "D7654321",
                issuer: "DMV",
                country: "US",
                issueDate: "2026-01-01",
                expiryDate: "2031-01-01",
                notes: "",
                favorite: false
            ),
            LocalIdentityEntry(
                id: "identity-2",
                projectID: "project-1",
                title: "Passport",
                documentType: "passport",
                fullName: "Alice Example",
                documentNumber: "P1234567",
                issuer: "Monica Authority",
                country: "US",
                issueDate: "2026-01-01",
                expiryDate: "2036-01-01",
                notes: "",
                favorite: true
            )
        ]

        XCTAssertEqual(model.filteredLoginEntries.map(\.title), ["GitHub", "Apple ID"])
        XCTAssertEqual(model.filteredNoteEntries.map(\.title), ["Recovery Codes", "Router"])
        XCTAssertEqual(model.filteredTotpEntries.map(\.title), ["GitHub TOTP", "Apple TOTP"])
        XCTAssertEqual(model.filteredCardEntries.map(\.title), ["Travel Mastercard", "Everyday Visa"])
        XCTAssertEqual(model.filteredIdentityEntries.map(\.title), ["Passport", "Driver License"])

        model.showFavoriteLoginEntriesOnly = true
        model.showFavoriteNoteEntriesOnly = true
        model.showFavoriteTotpEntriesOnly = true
        model.showFavoriteCardEntriesOnly = true
        model.showFavoriteIdentityEntriesOnly = true

        XCTAssertEqual(model.filteredLoginEntries.map(\.title), ["GitHub"])
        XCTAssertEqual(model.filteredNoteEntries.map(\.title), ["Recovery Codes"])
        XCTAssertEqual(model.filteredTotpEntries.map(\.title), ["GitHub TOTP"])
        XCTAssertEqual(model.filteredCardEntries.map(\.title), ["Travel Mastercard"])
        XCTAssertEqual(model.filteredIdentityEntries.map(\.title), ["Passport"])

        model.loginSearchQuery = "apple"
        model.noteSearchQuery = "router"
        model.totpSearchQuery = "apple"
        model.cardSearchQuery = "visa"
        model.identitySearchQuery = "driver"

        XCTAssertTrue(model.filteredLoginEntries.isEmpty)
        XCTAssertTrue(model.filteredNoteEntries.isEmpty)
        XCTAssertTrue(model.filteredTotpEntries.isEmpty)
        XCTAssertTrue(model.filteredCardEntries.isEmpty)
        XCTAssertTrue(model.filteredIdentityEntries.isEmpty)
    }

    func testGenerateSelectedLoginPasswordFillsEditingDraftWithoutSavingEntry() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            passwordGenerator: { "Edited-Generated-456!" }
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device"
        )

        model.loginTitle = "GitHub"
        model.loginUsername = "alice"
        model.loginPassword = "old-password"
        model.loginURL = "https://github.com"
        try model.createLoginEntry(projectTitle: "Personal")

        let created = try XCTUnwrap(model.loginEntries.first)
        model.selectLoginEntryForEditing(created)
        try model.generateSelectedLoginPassword()

        XCTAssertEqual(model.editingLoginPassword, "Edited-Generated-456!")
        XCTAssertEqual(model.entryOperationState, .succeeded("已生成密码"))
        XCTAssertTrue(engine.updatedLoginEntries.isEmpty)
        XCTAssertEqual(model.loginEntries.first?.password, "old-password")
    }

    func testDeleteAndRestoreSelectedLoginEntryMovesBetweenActiveListAndTrash() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine)
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device"
        )

        model.loginTitle = "GitHub"
        model.loginUsername = "alice"
        model.loginPassword = "correct horse battery staple"
        model.loginURL = "https://github.com"
        try model.createLoginEntry(projectTitle: "Personal")

        let created = try XCTUnwrap(model.loginEntries.first)
        model.selectLoginEntryForEditing(created)
        try model.deleteSelectedLoginEntry()

        XCTAssertEqual(model.entryOperationState, .succeeded("已删除 GitHub"))
        XCTAssertTrue(model.loginEntries.isEmpty)
        XCTAssertEqual(model.deletedLoginEntries, [created])
        XCTAssertNil(model.editingLoginEntryID)
        XCTAssertEqual(engine.deletedLoginEntries.first?.entryID, created.id)

        try model.restoreLoginEntry(created)

        XCTAssertEqual(model.entryOperationState, .succeeded("已恢复 GitHub"))
        XCTAssertEqual(model.loginEntries, [created])
        XCTAssertTrue(model.deletedLoginEntries.isEmpty)
        XCTAssertEqual(engine.restoredLoginEntries.first?.entryID, created.id)

        model.lockLocalVault()

        XCTAssertTrue(model.deletedLoginEntries.isEmpty)
    }

    func testCreateUpdateDeleteAndRestoreNoteEntryInActiveVault() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine)
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device"
        )

        model.noteTitle = "Recovery Codes"
        model.noteBody = "github: 123456\napple: 654321"
        try model.createNoteEntry(projectTitle: "Personal")

        XCTAssertEqual(model.entryOperationState, .succeeded("Recovery Codes"))
        XCTAssertEqual(model.noteEntries.count, 1)
        XCTAssertEqual(model.noteEntries.first?.title, "Recovery Codes")
        XCTAssertEqual(model.noteEntries.first?.body, "github: 123456\napple: 654321")
        XCTAssertEqual(engine.createdNoteEntries.first?.draft.title, "Recovery Codes")

        model.noteSearchQuery = "apple"
        XCTAssertEqual(model.filteredNoteEntries.map(\.title), ["Recovery Codes"])

        let created = try XCTUnwrap(model.noteEntries.first)
        model.selectNoteEntryForEditing(created)
        model.editingNoteTitle = "Updated Recovery Codes"
        model.editingNoteBody = "github: rotated\napple: 654321"
        try model.updateSelectedNoteEntry()

        XCTAssertEqual(model.entryOperationState, .succeeded("Updated Recovery Codes"))
        XCTAssertEqual(model.noteEntries.first?.id, created.id)
        XCTAssertEqual(model.noteEntries.first?.title, "Updated Recovery Codes")
        XCTAssertEqual(model.noteEntries.first?.body, "github: rotated\napple: 654321")
        XCTAssertEqual(engine.updatedNoteEntries.first?.entryID, created.id)

        try model.deleteSelectedNoteEntry()

        XCTAssertTrue(model.noteEntries.isEmpty)
        XCTAssertEqual(model.deletedNoteEntries.first?.id, created.id)
        XCTAssertNil(model.editingNoteEntryID)
        XCTAssertEqual(engine.deletedNoteEntries.first?.entryID, created.id)

        let deleted = try XCTUnwrap(model.deletedNoteEntries.first)
        try model.restoreNoteEntry(deleted)

        XCTAssertEqual(model.noteEntries.first?.id, created.id)
        XCTAssertTrue(model.deletedNoteEntries.isEmpty)
        XCTAssertEqual(engine.restoredNoteEntries.first?.entryID, created.id)

        model.lockLocalVault()

        XCTAssertTrue(model.noteEntries.isEmpty)
        XCTAssertEqual(model.noteSearchQuery, "")
        XCTAssertNil(model.editingNoteEntryID)
        XCTAssertEqual(model.editingNoteBody, "")
    }

    func testCreateUpdateDeleteAndRestoreTotpEntryInActiveVault() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine)
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device"
        )

        model.totpTitle = "GitHub TOTP"
        model.totpSecret = "JBSWY3DPEHPK3PXP"
        model.totpIssuer = "GitHub"
        model.totpAccountName = "alice"
        model.totpPeriod = 30
        model.totpDigits = 6
        model.totpAlgorithm = "SHA1"
        try model.createTotpEntry(projectTitle: "Personal")

        XCTAssertEqual(model.entryOperationState, .succeeded("GitHub TOTP"))
        XCTAssertEqual(model.totpEntries.count, 1)
        XCTAssertEqual(model.totpEntries.first?.title, "GitHub TOTP")
        XCTAssertEqual(model.totpEntries.first?.secret, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(model.totpEntries.first?.issuer, "GitHub")
        XCTAssertEqual(model.totpEntries.first?.accountName, "alice")
        XCTAssertEqual(engine.createdTotpEntries.first?.draft.secret, "JBSWY3DPEHPK3PXP")

        model.totpSearchQuery = "alice"
        XCTAssertEqual(model.filteredTotpEntries.map(\.title), ["GitHub TOTP"])

        let created = try XCTUnwrap(model.totpEntries.first)
        model.selectTotpEntryForEditing(created)
        model.editingTotpTitle = "GitHub Work TOTP"
        model.editingTotpSecret = "JBSWY3DPEHPK3PXQ"
        model.editingTotpIssuer = "GitHub"
        model.editingTotpAccountName = "alice@example.com"
        model.editingTotpPeriod = 60
        model.editingTotpDigits = 8
        model.editingTotpAlgorithm = "SHA256"
        try model.updateSelectedTotpEntry()

        XCTAssertEqual(model.entryOperationState, .succeeded("GitHub Work TOTP"))
        XCTAssertEqual(model.totpEntries.first?.id, created.id)
        XCTAssertEqual(model.totpEntries.first?.title, "GitHub Work TOTP")
        XCTAssertEqual(model.totpEntries.first?.secret, "JBSWY3DPEHPK3PXQ")
        XCTAssertEqual(model.totpEntries.first?.accountName, "alice@example.com")
        XCTAssertEqual(model.totpEntries.first?.period, 60)
        XCTAssertEqual(model.totpEntries.first?.digits, 8)
        XCTAssertEqual(model.totpEntries.first?.algorithm, "SHA256")
        XCTAssertEqual(engine.updatedTotpEntries.first?.entryID, created.id)

        try model.deleteSelectedTotpEntry()

        XCTAssertTrue(model.totpEntries.isEmpty)
        XCTAssertEqual(model.deletedTotpEntries.first?.id, created.id)
        XCTAssertNil(model.editingTotpEntryID)
        XCTAssertEqual(engine.deletedTotpEntries.first?.entryID, created.id)

        let deleted = try XCTUnwrap(model.deletedTotpEntries.first)
        try model.restoreTotpEntry(deleted)

        XCTAssertEqual(model.totpEntries.first?.id, created.id)
        XCTAssertTrue(model.deletedTotpEntries.isEmpty)
        XCTAssertEqual(engine.restoredTotpEntries.first?.entryID, created.id)

        model.lockLocalVault()

        XCTAssertTrue(model.totpEntries.isEmpty)
        XCTAssertEqual(model.totpSearchQuery, "")
        XCTAssertNil(model.editingTotpEntryID)
        XCTAssertEqual(model.editingTotpSecret, "")
    }

    func testCreateUpdateDeleteAndRestoreCardEntryInActiveVault() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine)
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device"
        )

        model.cardTitle = "Everyday Visa"
        model.cardholderName = "Alice Example"
        model.cardNumber = "4111111111111111"
        model.cardExpiryMonth = "12"
        model.cardExpiryYear = "2031"
        model.cardCVV = "123"
        model.cardIssuer = "Monica Bank"
        model.cardNetwork = "Visa"
        model.cardNotes = "Primary checking card"
        try model.createCardEntry(projectTitle: "Personal")

        XCTAssertEqual(model.entryOperationState, .succeeded("Everyday Visa"))
        XCTAssertEqual(model.cardEntries.count, 1)
        XCTAssertEqual(model.cardEntries.first?.title, "Everyday Visa")
        XCTAssertEqual(model.cardEntries.first?.cardholderName, "Alice Example")
        XCTAssertEqual(model.cardEntries.first?.number, "4111111111111111")
        XCTAssertEqual(model.cardEntries.first?.cvv, "123")
        XCTAssertEqual(model.cardNumber, "")
        XCTAssertEqual(model.cardCVV, "")
        XCTAssertEqual(engine.createdCardEntries.first?.draft.number, "4111111111111111")

        model.cardSearchQuery = "visa"
        XCTAssertEqual(model.filteredCardEntries.map(\.title), ["Everyday Visa"])

        let created = try XCTUnwrap(model.cardEntries.first)
        model.selectCardEntryForEditing(created)
        model.editingCardTitle = "Travel Mastercard"
        model.editingCardholderName = "Alice Q. Example"
        model.editingCardNumber = "5555555555554444"
        model.editingCardExpiryMonth = "01"
        model.editingCardExpiryYear = "2032"
        model.editingCardCVV = "456"
        model.editingCardIssuer = "Monica Credit Union"
        model.editingCardNetwork = "Mastercard"
        model.editingCardNotes = "No foreign transaction fee"
        try model.updateSelectedCardEntry()

        XCTAssertEqual(model.entryOperationState, .succeeded("Travel Mastercard"))
        XCTAssertEqual(model.cardEntries.first?.id, created.id)
        XCTAssertEqual(model.cardEntries.first?.title, "Travel Mastercard")
        XCTAssertEqual(model.cardEntries.first?.number, "5555555555554444")
        XCTAssertEqual(model.cardEntries.first?.cvv, "456")
        XCTAssertEqual(engine.updatedCardEntries.first?.entryID, created.id)

        try model.deleteSelectedCardEntry()

        XCTAssertTrue(model.cardEntries.isEmpty)
        XCTAssertEqual(model.deletedCardEntries.first?.id, created.id)
        XCTAssertNil(model.editingCardEntryID)
        XCTAssertEqual(model.editingCardNumber, "")
        XCTAssertEqual(model.editingCardCVV, "")
        XCTAssertEqual(engine.deletedCardEntries.first?.entryID, created.id)

        let deleted = try XCTUnwrap(model.deletedCardEntries.first)
        try model.restoreCardEntry(deleted)

        XCTAssertEqual(model.cardEntries.first?.id, created.id)
        XCTAssertTrue(model.deletedCardEntries.isEmpty)
        XCTAssertEqual(engine.restoredCardEntries.first?.entryID, created.id)

        model.lockLocalVault()

        XCTAssertTrue(model.cardEntries.isEmpty)
        XCTAssertEqual(model.cardSearchQuery, "")
        XCTAssertNil(model.editingCardEntryID)
        XCTAssertEqual(model.editingCardNumber, "")
        XCTAssertEqual(model.editingCardCVV, "")
    }

    func testCreateUpdateDeleteAndRestoreIdentityEntryInActiveVault() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine)
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device"
        )

        model.identityTitle = "Passport"
        model.identityDocumentType = "passport"
        model.identityFullName = "Alice Example"
        model.identityDocumentNumber = "P1234567"
        model.identityIssuer = "Monica Authority"
        model.identityCountry = "US"
        model.identityIssueDate = "2026-01-02"
        model.identityExpiryDate = "2036-01-01"
        model.identityNotes = "Primary travel document"
        try model.createIdentityEntry(projectTitle: "Personal")

        XCTAssertEqual(model.entryOperationState, .succeeded("Passport"))
        XCTAssertEqual(model.identityEntries.count, 1)
        XCTAssertEqual(model.identityEntries.first?.title, "Passport")
        XCTAssertEqual(model.identityEntries.first?.documentType, "passport")
        XCTAssertEqual(model.identityEntries.first?.fullName, "Alice Example")
        XCTAssertEqual(model.identityEntries.first?.documentNumber, "P1234567")
        XCTAssertEqual(engine.createdIdentityEntries.first?.draft.documentNumber, "P1234567")

        model.identitySearchQuery = "pass"
        XCTAssertEqual(model.filteredIdentityEntries.map(\.title), ["Passport"])

        let created = try XCTUnwrap(model.identityEntries.first)
        model.selectIdentityEntryForEditing(created)
        model.editingIdentityTitle = "Driver License"
        model.editingIdentityDocumentType = "driver_license"
        model.editingIdentityFullName = "Alice Q. Example"
        model.editingIdentityDocumentNumber = "D7654321"
        model.editingIdentityIssuer = "Monica DMV"
        model.editingIdentityCountry = "US-CA"
        model.editingIdentityIssueDate = "2026-05-31"
        model.editingIdentityExpiryDate = "2031-05-30"
        model.editingIdentityNotes = "State license metadata"
        try model.updateSelectedIdentityEntry()

        XCTAssertEqual(model.entryOperationState, .succeeded("Driver License"))
        XCTAssertEqual(model.identityEntries.first?.id, created.id)
        XCTAssertEqual(model.identityEntries.first?.title, "Driver License")
        XCTAssertEqual(model.identityEntries.first?.documentNumber, "D7654321")
        XCTAssertEqual(engine.updatedIdentityEntries.first?.entryID, created.id)

        try model.deleteSelectedIdentityEntry()

        XCTAssertTrue(model.identityEntries.isEmpty)
        XCTAssertEqual(model.deletedIdentityEntries.first?.id, created.id)
        XCTAssertNil(model.editingIdentityEntryID)
        XCTAssertEqual(engine.deletedIdentityEntries.first?.entryID, created.id)

        let deleted = try XCTUnwrap(model.deletedIdentityEntries.first)
        try model.restoreIdentityEntry(deleted)

        XCTAssertEqual(model.identityEntries.first?.id, created.id)
        XCTAssertTrue(model.deletedIdentityEntries.isEmpty)
        XCTAssertEqual(engine.restoredIdentityEntries.first?.entryID, created.id)

        model.lockLocalVault()

        XCTAssertTrue(model.identityEntries.isEmpty)
        XCTAssertEqual(model.identitySearchQuery, "")
        XCTAssertNil(model.editingIdentityEntryID)
        XCTAssertEqual(model.editingIdentityDocumentNumber, "")
    }

    func testCreateUpdateFavoriteDeleteAndRestorePasskeyEntryInActiveVault() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine)
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device"
        )

        model.passkeyTitle = "Joyin"
        model.passkeyRelyingPartyID = "github.com"
        model.passkeyUsername = "joyin"
        model.passkeyUserHandle = "github-user-handle"
        model.passkeyCredentialID = "credential-1"
        model.passkeyPublicKeyCOSE = "public-key-cose"
        model.passkeyPrivateKeyReference = "keychain://passkeys/github/credential-1"
        model.passkeyNotes = "Imported from Android metadata"
        try model.createPasskeyEntry(projectTitle: "Personal")

        XCTAssertEqual(model.entryOperationState, .succeeded("Joyin"))
        XCTAssertEqual(model.passkeyEntries.count, 1)
        XCTAssertEqual(model.passkeyEntries.first?.title, "Joyin")
        XCTAssertEqual(model.passkeyEntries.first?.relyingPartyID, "github.com")
        XCTAssertEqual(model.passkeyEntries.first?.username, "joyin")
        XCTAssertEqual(model.passkeyPrivateKeyReference, "")
        XCTAssertEqual(engine.createdPasskeyEntries.first?.draft.privateKeyReference, "keychain://passkeys/github/credential-1")

        model.passkeySearchQuery = "git"
        XCTAssertEqual(model.filteredPasskeyEntries.map(\.title), ["Joyin"])

        let created = try XCTUnwrap(model.passkeyEntries.first)
        model.selectPasskeyEntryForEditing(created)
        model.editingPasskeyTitle = "Joyin Work"
        model.editingPasskeyRelyingPartyID = "github.com"
        model.editingPasskeyUsername = "joyin@example.com"
        model.editingPasskeyUserHandle = "github-work-user-handle"
        model.editingPasskeyCredentialID = "credential-2"
        model.editingPasskeyPublicKeyCOSE = "rotated-public-key-cose"
        model.editingPasskeyPrivateKeyReference = "keychain://passkeys/github/credential-2"
        model.editingPasskeyNotes = "Rotated on iOS"
        try model.updateSelectedPasskeyEntry()

        XCTAssertEqual(model.entryOperationState, .succeeded("Joyin Work"))
        XCTAssertEqual(model.passkeyEntries.first?.id, created.id)
        XCTAssertEqual(model.passkeyEntries.first?.username, "joyin@example.com")
        XCTAssertEqual(model.passkeyEntries.first?.privateKeyReference, "keychain://passkeys/github/credential-2")
        XCTAssertEqual(engine.updatedPasskeyEntries.first?.entryID, created.id)

        try model.setSelectedPasskeyFavorite(true)

        XCTAssertEqual(model.entryOperationState, .succeeded("已收藏 Joyin Work"))
        XCTAssertEqual(model.passkeyEntries.first?.favorite, true)
        XCTAssertEqual(model.editingPasskeyFavorite, true)
        XCTAssertEqual(engine.updatedPasskeyEntries.count, 1)

        try model.deleteSelectedPasskeyEntry()

        XCTAssertTrue(model.passkeyEntries.isEmpty)
        XCTAssertEqual(model.deletedPasskeyEntries.first?.id, created.id)
        XCTAssertNil(model.editingPasskeyEntryID)
        XCTAssertEqual(model.editingPasskeyPrivateKeyReference, "")
        XCTAssertEqual(engine.deletedPasskeyEntries.first?.entryID, created.id)

        let deleted = try XCTUnwrap(model.deletedPasskeyEntries.first)
        try model.restorePasskeyEntry(deleted)

        XCTAssertEqual(model.passkeyEntries.first?.id, created.id)
        XCTAssertTrue(model.deletedPasskeyEntries.isEmpty)
        XCTAssertEqual(engine.restoredPasskeyEntries.first?.entryID, created.id)

        model.lockLocalVault()

        XCTAssertTrue(model.passkeyEntries.isEmpty)
        XCTAssertEqual(model.passkeySearchQuery, "")
        XCTAssertNil(model.editingPasskeyEntryID)
        XCTAssertEqual(model.editingPasskeyPrivateKeyReference, "")
    }

    func testRefreshExtendedParityEntriesLoadsSshApiWifiAndSendForActiveProject() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine)
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device"
        )

        model.loginTitle = "GitHub"
        model.loginUsername = "joyin"
        model.loginPassword = "old-password"
        model.loginURL = "https://github.com"
        try model.createLoginEntry(projectTitle: "Personal")
        engine.seedExtendedParityEntries(projectID: "project-1")

        try model.refreshExtendedParityEntries()

        XCTAssertEqual(model.sshKeyEntries.map(\.host), ["prod.example.com"])
        XCTAssertEqual(model.apiTokenEntries.map(\.issuer), ["Tiga"])
        XCTAssertEqual(model.wifiEntries.map(\.ssid), ["Monica Studio"])
        XCTAssertEqual(model.sendEntries.map(\.title), ["One-time send"])
        XCTAssertEqual(model.deletedSshKeyEntries.map(\.title), ["Retired deploy key"])
        XCTAssertEqual(model.deletedApiTokenEntries.map(\.title), ["Old API token"])
        XCTAssertEqual(model.deletedWifiEntries.map(\.title), ["Guest Wi-Fi"])
        XCTAssertEqual(model.deletedSendEntries.map(\.title), ["Expired send"])

        model.lockLocalVault()

        XCTAssertTrue(model.sshKeyEntries.isEmpty)
        XCTAssertTrue(model.apiTokenEntries.isEmpty)
        XCTAssertTrue(model.wifiEntries.isEmpty)
        XCTAssertTrue(model.sendEntries.isEmpty)
        XCTAssertTrue(model.deletedSshKeyEntries.isEmpty)
        XCTAssertTrue(model.deletedApiTokenEntries.isEmpty)
        XCTAssertTrue(model.deletedWifiEntries.isEmpty)
        XCTAssertTrue(model.deletedSendEntries.isEmpty)
    }

    func testCreateUpdateFavoriteDeleteAndRestoreSshKeyEntryInActiveVault() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(vaultRepository: LocalVaultRepository(engine: engine))

        try unlockNewVault(model)

        model.sshKeyTitle = "Production deploy key"
        model.sshKeyUsername = "deploy"
        model.sshKeyHost = "prod.example.com"
        model.sshKeyPublicKey = "ssh-ed25519 AAAA"
        model.sshKeyPrivateKeyReference = "keychain://ssh/prod"
        model.sshKeyPassphraseHint = "hardware key"
        model.sshKeyNotes = "Android parity SSH metadata"
        try model.createSshKeyEntry(projectTitle: "Personal")

        XCTAssertEqual(model.entryOperationState, .succeeded("Production deploy key"))
        XCTAssertEqual(model.sshKeyEntries.first?.host, "prod.example.com")
        XCTAssertEqual(model.sshKeyPrivateKeyReference, "")
        XCTAssertEqual(engine.createdSshKeyEntries.first?.draft.privateKeyReference, "keychain://ssh/prod")

        model.sshKeySearchQuery = "prod"
        XCTAssertEqual(model.filteredSshKeyEntries.map(\.title), ["Production deploy key"])

        let created = try XCTUnwrap(model.sshKeyEntries.first)
        model.selectSshKeyEntryForEditing(created)
        model.editingSshKeyTitle = "Production deploy key rotated"
        model.editingSshKeyUsername = "deploy"
        model.editingSshKeyHost = "prod.internal.example.com"
        model.editingSshKeyPublicKey = "ssh-ed25519 BBBB"
        model.editingSshKeyPrivateKeyReference = "keychain://ssh/prod-rotated"
        model.editingSshKeyPassphraseHint = "rotated"
        model.editingSshKeyNotes = "Rotated on iOS"
        try model.updateSelectedSshKeyEntry()

        XCTAssertEqual(model.sshKeyEntries.first?.id, created.id)
        XCTAssertEqual(model.sshKeyEntries.first?.publicKey, "ssh-ed25519 BBBB")
        XCTAssertEqual(engine.updatedSshKeyEntries.first?.entryID, created.id)

        try model.setSelectedSshKeyFavorite(true)

        XCTAssertEqual(model.sshKeyEntries.first?.favorite, true)
        XCTAssertEqual(model.editingSshKeyFavorite, true)
        XCTAssertEqual(engine.favoritedSshKeyEntries.first?.entryID, created.id)

        try model.deleteSelectedSshKeyEntry()

        XCTAssertTrue(model.sshKeyEntries.isEmpty)
        XCTAssertEqual(model.deletedSshKeyEntries.first?.id, created.id)
        XCTAssertNil(model.editingSshKeyEntryID)
        XCTAssertEqual(model.editingSshKeyPrivateKeyReference, "")
        XCTAssertEqual(engine.deletedSshKeyEntries.first?.entryID, created.id)

        let deleted = try XCTUnwrap(model.deletedSshKeyEntries.first)
        try model.restoreSshKeyEntry(deleted)

        XCTAssertEqual(model.sshKeyEntries.first?.id, created.id)
        XCTAssertTrue(model.deletedSshKeyEntries.isEmpty)
        XCTAssertEqual(engine.restoredSshKeyEntries.first?.entryID, created.id)

        model.lockLocalVault()

        XCTAssertTrue(model.sshKeyEntries.isEmpty)
        XCTAssertEqual(model.sshKeySearchQuery, "")
        XCTAssertNil(model.editingSshKeyEntryID)
        XCTAssertEqual(model.editingSshKeyPrivateKeyReference, "")
    }

    func testCreateUpdateFavoriteDeleteAndRestoreApiTokenEntryInActiveVault() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(vaultRepository: LocalVaultRepository(engine: engine))

        try unlockNewVault(model)

        model.apiTokenTitle = "Tiga API token"
        model.apiTokenIssuer = "Tiga"
        model.apiTokenAccountName = "joyin"
        model.apiTokenToken = "sk-secret"
        model.apiTokenScopes = "sync,read"
        model.apiTokenExpiresAt = "2031-01-01"
        model.apiTokenNotes = "Keep secret"
        try model.createApiTokenEntry(projectTitle: "Personal")

        XCTAssertEqual(model.apiTokenEntries.first?.issuer, "Tiga")
        XCTAssertEqual(model.apiTokenToken, "")
        XCTAssertEqual(engine.createdApiTokenEntries.first?.draft.token, "sk-secret")

        model.apiTokenSearchQuery = "sync"
        XCTAssertEqual(model.filteredApiTokenEntries.map(\.title), ["Tiga API token"])

        let created = try XCTUnwrap(model.apiTokenEntries.first)
        model.selectApiTokenEntryForEditing(created)
        model.editingApiTokenTitle = "Tiga write token"
        model.editingApiTokenIssuer = "Tiga"
        model.editingApiTokenAccountName = "joyin@example.com"
        model.editingApiTokenToken = "sk-rotated"
        model.editingApiTokenScopes = "sync,write"
        model.editingApiTokenExpiresAt = "2032-01-01"
        model.editingApiTokenNotes = "Rotated on iOS"
        try model.updateSelectedApiTokenEntry()

        XCTAssertEqual(model.apiTokenEntries.first?.accountName, "joyin@example.com")
        XCTAssertEqual(engine.updatedApiTokenEntries.first?.entryID, created.id)

        try model.setSelectedApiTokenFavorite(true)
        XCTAssertEqual(model.apiTokenEntries.first?.favorite, true)
        XCTAssertEqual(model.editingApiTokenFavorite, true)

        try model.deleteSelectedApiTokenEntry()
        XCTAssertTrue(model.apiTokenEntries.isEmpty)
        XCTAssertEqual(model.deletedApiTokenEntries.first?.id, created.id)
        XCTAssertEqual(model.editingApiTokenToken, "")

        let deleted = try XCTUnwrap(model.deletedApiTokenEntries.first)
        try model.restoreApiTokenEntry(deleted)

        XCTAssertEqual(model.apiTokenEntries.first?.id, created.id)
        XCTAssertTrue(model.deletedApiTokenEntries.isEmpty)

        model.lockLocalVault()
        XCTAssertEqual(model.apiTokenSearchQuery, "")
        XCTAssertEqual(model.editingApiTokenToken, "")
    }

    func testCreateUpdateFavoriteDeleteAndRestoreWifiEntryInActiveVault() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(vaultRepository: LocalVaultRepository(engine: engine))

        try unlockNewVault(model)

        model.wifiTitle = "Studio Wi-Fi"
        model.wifiSSID = "Monica Studio"
        model.wifiSecurityType = "WPA2"
        model.wifiPassword = "wifi-secret"
        model.wifiHidden = true
        model.wifiNotes = "Main office"
        try model.createWifiEntry(projectTitle: "Personal")

        XCTAssertEqual(model.wifiEntries.first?.ssid, "Monica Studio")
        XCTAssertEqual(model.wifiPassword, "")
        XCTAssertEqual(engine.createdWifiEntries.first?.draft.hidden, true)

        model.wifiSearchQuery = "studio"
        XCTAssertEqual(model.filteredWifiEntries.map(\.title), ["Studio Wi-Fi"])

        let created = try XCTUnwrap(model.wifiEntries.first)
        model.selectWifiEntryForEditing(created)
        XCTAssertEqual(model.editingWifiQRCodePayload, "WIFI:T:WPA;S:Monica Studio;P:wifi-secret;H:true;;")

        model.editingWifiTitle = "Studio Wi-Fi 6"
        model.editingWifiSSID = "Monica Studio 6"
        model.editingWifiSecurityType = "WPA3"
        model.editingWifiPassword = "rotated-wifi-secret"
        model.editingWifiHidden = false
        model.editingWifiNotes = "Rotated on iOS"
        try model.updateSelectedWifiEntry()

        XCTAssertEqual(model.wifiEntries.first?.securityType, "WPA3")
        XCTAssertEqual(engine.updatedWifiEntries.first?.entryID, created.id)

        try model.setSelectedWifiFavorite(true)
        XCTAssertEqual(model.wifiEntries.first?.favorite, true)
        XCTAssertEqual(model.editingWifiFavorite, true)

        try model.deleteSelectedWifiEntry()
        XCTAssertTrue(model.wifiEntries.isEmpty)
        XCTAssertEqual(model.deletedWifiEntries.first?.id, created.id)
        XCTAssertEqual(model.editingWifiPassword, "")

        let deleted = try XCTUnwrap(model.deletedWifiEntries.first)
        try model.restoreWifiEntry(deleted)

        XCTAssertEqual(model.wifiEntries.first?.id, created.id)
        XCTAssertTrue(model.deletedWifiEntries.isEmpty)

        model.lockLocalVault()
        XCTAssertEqual(model.wifiSearchQuery, "")
        XCTAssertEqual(model.editingWifiPassword, "")
    }

    func testWifiQRCodeRendererProducesShareableImage() throws {
        let image = try XCTUnwrap(
            WifiQRCodeRenderer.image(
                for: "WIFI:T:WPA;S:Monica Studio;P:wifi-secret;H:true;;",
                size: 192
            )
        )

        XCTAssertEqual(image.size.width, 192)
        XCTAssertEqual(image.size.height, 192)
        XCTAssertGreaterThan(image.pngData()?.count ?? 0, 500)
    }

    func testCreateUpdateFavoriteDeleteAndRestoreSendEntryInActiveVault() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(vaultRepository: LocalVaultRepository(engine: engine))

        try unlockNewVault(model)

        model.sendTitle = "One-time send"
        model.sendBody = "share once"
        model.sendExpiresAt = "2026-06-02"
        model.sendMaxViews = 1
        model.sendNotes = "MVP metadata"
        try model.createSendEntry(projectTitle: "Personal")

        XCTAssertEqual(model.sendEntries.first?.title, "One-time send")
        XCTAssertEqual(model.sendBody, "")
        XCTAssertEqual(engine.createdSendEntries.first?.draft.maxViews, 1)

        model.sendSearchQuery = "once"
        XCTAssertEqual(model.filteredSendEntries.map(\.title), ["One-time send"])

        let created = try XCTUnwrap(model.sendEntries.first)
        model.selectSendEntryForEditing(created)
        model.editingSendTitle = "One-time send rotated"
        model.editingSendBody = "share twice"
        model.editingSendExpiresAt = "2026-06-03"
        model.editingSendMaxViews = 2
        model.editingSendNotes = "Rotated on iOS"
        try model.updateSelectedSendEntry()

        XCTAssertEqual(model.sendEntries.first?.maxViews, 2)
        XCTAssertEqual(engine.updatedSendEntries.first?.entryID, created.id)

        try model.setSelectedSendFavorite(true)
        XCTAssertEqual(model.sendEntries.first?.favorite, true)
        XCTAssertEqual(model.editingSendFavorite, true)

        try model.deleteSelectedSendEntry()
        XCTAssertTrue(model.sendEntries.isEmpty)
        XCTAssertEqual(model.deletedSendEntries.first?.id, created.id)
        XCTAssertEqual(model.editingSendBody, "")

        let deleted = try XCTUnwrap(model.deletedSendEntries.first)
        try model.restoreSendEntry(deleted)

        XCTAssertEqual(model.sendEntries.first?.id, created.id)
        XCTAssertTrue(model.deletedSendEntries.isEmpty)

        model.lockLocalVault()
        XCTAssertEqual(model.sendSearchQuery, "")
        XCTAssertEqual(model.editingSendBody, "")
    }

    func testCSVImportPreviewDoesNotWriteUntilConfirmed() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(vaultRepository: LocalVaultRepository(engine: engine))

        try unlockNewVault(model)

        let csv = VaultCSVCodec.exportItems([
            .login(LocalLoginEntryDraft(
                title: "GitHub",
                username: "alice",
                password: "secret-password",
                url: "https://github.com"
            )),
            .apiToken(LocalApiTokenEntryDraft(
                title: "Deploy token",
                issuer: "Monica Cloud",
                accountName: "alice@example.com",
                token: "sk-secret",
                scopes: "deploy,read",
                expiresAt: "2031-06-01",
                notes: "Imported from Android CSV"
            ))
        ])

        let preview = model.previewCSVImport(csv)

        XCTAssertEqual(preview.items.map(\.kind), [.login, .apiToken])
        XCTAssertTrue(preview.issues.isEmpty)
        XCTAssertTrue(model.loginEntries.isEmpty)
        XCTAssertTrue(model.apiTokenEntries.isEmpty)
        XCTAssertTrue(engine.createdLoginEntries.isEmpty)
        XCTAssertTrue(engine.createdApiTokenEntries.isEmpty)
        XCTAssertEqual(model.entryOperationState, .succeeded("CSV 预览：2 项可导入，0 个问题"))

        try model.confirmCSVImport(projectTitle: "Personal")

        XCTAssertEqual(model.loginEntries.map(\.title), ["GitHub"])
        XCTAssertEqual(model.apiTokenEntries.map(\.title), ["Deploy token"])
        XCTAssertEqual(engine.createdProjects.map(\.title), ["Personal"])
        XCTAssertEqual(engine.createdLoginEntries.first?.draft.password, "secret-password")
        XCTAssertEqual(engine.createdApiTokenEntries.first?.draft.token, "sk-secret")
        XCTAssertNil(model.csvImportPreview)
        XCTAssertEqual(model.entryOperationState, .succeeded("CSV 已导入 2 项"))
    }

    func testCSVExportUsesCurrentVisibleVaultEntries() throws {
        let model = AppSessionModel(vaultRepository: LocalVaultRepository(engine: RecordingVaultEngine()))

        try unlockNewVault(model)

        model.loginTitle = "GitHub"
        model.loginUsername = "alice"
        model.loginPassword = "secret-password"
        model.loginURL = "https://github.com"
        try model.createLoginEntry(projectTitle: "Personal")
        model.noteTitle = "Recovery Codes"
        model.noteBody = "line 1\nline 2"
        try model.createNoteEntry(projectTitle: "Personal")

        let exported = try model.exportCSV()
        let report = VaultCSVCodec.importItems(from: exported)

        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertEqual(report.items, [
            .login(LocalLoginEntryDraft(
                title: "GitHub",
                username: "alice",
                password: "secret-password",
                url: "https://github.com"
            )),
            .note(LocalNoteEntryDraft(title: "Recovery Codes", body: "line 1\nline 2"))
        ])
        XCTAssertEqual(model.entryOperationState, .succeeded("CSV 已导出 2 项"))
    }

    func testCSVImportFileBuildsPreviewWithoutWritingVault() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(vaultRepository: LocalVaultRepository(engine: engine))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("android-export.csv")
        let csv = VaultCSVCodec.exportItems([
            .login(LocalLoginEntryDraft(
                title: "GitHub",
                username: "alice",
                password: "secret-password",
                url: "https://github.com"
            ))
        ])
        try csv.write(to: fileURL, atomically: true, encoding: .utf8)

        try unlockNewVault(model)
        let preview = try model.previewCSVImport(from: fileURL)

        XCTAssertEqual(preview.items.map(\.kind), [.login])
        XCTAssertTrue(preview.issues.isEmpty)
        XCTAssertTrue(model.loginEntries.isEmpty)
        XCTAssertTrue(engine.createdLoginEntries.isEmpty)
        XCTAssertEqual(model.entryOperationState, .succeeded("CSV 预览：1 项可导入，0 个问题"))
    }

    func testCSVExportDocumentWrapsCurrentVaultCSVForFileExporter() throws {
        let model = AppSessionModel(vaultRepository: LocalVaultRepository(engine: RecordingVaultEngine()))

        try unlockNewVault(model)
        model.loginTitle = "GitHub"
        model.loginUsername = "alice"
        model.loginPassword = "secret-password"
        model.loginURL = "https://github.com"
        try model.createLoginEntry(projectTitle: "Personal")

        let document = try model.csvExportDocument()
        let report = VaultCSVCodec.importItems(from: document.text)

        XCTAssertEqual(CSVExportDocument.readableContentTypes, [.commaSeparatedText])
        XCTAssertEqual(report.items.map(\.kind), [.login])
        XCTAssertEqual(model.entryOperationState, .succeeded("CSV 已导出 1 项"))
    }

    func testAndroidBackupImportFileBuildsPreviewWithoutWritingVault() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(vaultRepository: LocalVaultRepository(engine: engine))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("monica_backup.zip")
        let backup = try AndroidBackupCodec.exportZip(entries: [
            "folders/Work/passwords/password_1_1000.json": #"{"id":1,"title":"GitHub","username":"alice","password":"secret-password","website":"https://github.com","categoryName":"Work"}"#,
            "folders/Work/authenticators/totp_2_1000.json": #"{"id":2,"title":"GitHub 2FA","itemData":"{\"secret\":\"JBSWY3DPEHPK3PXP\",\"issuer\":\"GitHub\",\"accountName\":\"alice\",\"period\":30,\"digits\":6,\"algorithm\":\"SHA1\",\"otpType\":\"TOTP\",\"counter\":0}","categoryName":"Work"}"#
        ])
        try backup.write(to: fileURL)

        try unlockNewVault(model)
        let preview = try model.previewAndroidBackupImport(from: fileURL)

        XCTAssertEqual(preview.items.map(\.kind), [.login, .totp])
        XCTAssertTrue(preview.issues.isEmpty)
        XCTAssertTrue(model.loginEntries.isEmpty)
        XCTAssertTrue(model.totpEntries.isEmpty)
        XCTAssertTrue(engine.createdLoginEntries.isEmpty)
        XCTAssertTrue(engine.createdTotpEntries.isEmpty)
        XCTAssertEqual(model.entryOperationState, .succeeded("Android 备份预览：2 项可导入，0 个问题"))
    }

    func testAndroidBackupImportPreviewDoesNotWriteUntilConfirmed() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(vaultRepository: LocalVaultRepository(engine: engine))
        let backup = try AndroidBackupCodec.exportItems([
            .login(LocalLoginEntryDraft(title: "GitHub", username: "alice", password: "secret-password", url: "https://github.com")),
            .note(LocalNoteEntryDraft(title: "Recovery", body: "backup codes"))
        ])

        try unlockNewVault(model)
        let preview = try model.previewAndroidBackupImport(backup)

        XCTAssertEqual(preview.items.map(\.kind), [.login, .note])
        XCTAssertTrue(model.loginEntries.isEmpty)
        XCTAssertTrue(model.noteEntries.isEmpty)
        XCTAssertTrue(engine.createdLoginEntries.isEmpty)
        XCTAssertTrue(engine.createdNoteEntries.isEmpty)

        try model.confirmAndroidBackupImport(projectTitle: "Android 备份")

        XCTAssertEqual(model.loginEntries.map(\.title), ["GitHub"])
        XCTAssertEqual(model.noteEntries.map(\.title), ["Recovery"])
        XCTAssertEqual(engine.createdProjects.map(\.title), ["Android 备份"])
        XCTAssertEqual(engine.createdLoginEntries.first?.draft.password, "secret-password")
        XCTAssertEqual(engine.createdNoteEntries.first?.draft.body, "backup codes")
        XCTAssertNil(model.androidBackupImportPreview)
        XCTAssertEqual(model.entryOperationState, .succeeded("Android 备份已导入 2 项"))
    }

    func testAndroidBackupImportPreviewIncludesAttachmentManifestCount() throws {
        let model = AppSessionModel(vaultRepository: LocalVaultRepository(engine: RecordingVaultEngine()))
        let backup = try AndroidBackupCodec.exportZip(entries: [
            "folders/Work/passwords/password_42_1710000000000.json": #"{"id":42,"title":"GitHub","username":"alice","password":"secret-password","website":"https://github.com","categoryName":"Work"}"#,
            "attachments/attachments_meta.json": #"""
            {"version":1,"entries":[{"parentPasswordId":42,"fileName":"contract.pdf","mimeType":"application/pdf","sizeBytes":2048,"sha256Hex":"abc123","wrappedCek":"wrapped-key","localPath":"attachment-1.enc","createdAt":1710000000000,"updatedAt":1710000001000}]}
            """#,
            "attachments/attachment-1.enc": "ciphertext"
        ])

        try unlockNewVault(model)
        let preview = try model.previewAndroidBackupImport(backup)

        XCTAssertEqual(preview.items.map(\.kind), [.login])
        XCTAssertEqual(preview.attachments.map(\.fileName), ["contract.pdf"])
        XCTAssertEqual(preview.attachments.first?.blobEntryPath, "attachments/attachment-1.enc")
        XCTAssertEqual(model.entryOperationState, .succeeded("Android 备份预览：1 项可导入，1 个附件，0 个问题"))
    }

    func testAndroidBackupEncryptedImportPreviewRequiresUnsupportedDecryptFlow() throws {
        let model = AppSessionModel(vaultRepository: LocalVaultRepository(engine: RecordingVaultEngine()))
        let encryptedBackup = Data("MONICA_ENC_V1".utf8)
            + Data(repeating: 0, count: 32)
            + Data(repeating: 1, count: 12)
            + Data("ciphertext".utf8)

        try unlockNewVault(model)

        XCTAssertThrowsError(try model.previewAndroidBackupImport(encryptedBackup))
        XCTAssertNil(model.androidBackupImportPreview)
        XCTAssertEqual(
            model.entryOperationState,
            .failed("Android 加密备份暂未支持解密，请先从 Android 导出未加密 .zip 后再导入。")
        )
    }

    func testAndroidBackupEncryptedFileNameRequiresUnsupportedDecryptFlow() throws {
        let model = AppSessionModel(vaultRepository: LocalVaultRepository(engine: RecordingVaultEngine()))
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica_backup.enc.zip")
        try Data("not-a-zip".utf8).write(to: fileURL)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        try unlockNewVault(model)

        XCTAssertThrowsError(try model.previewAndroidBackupImport(from: fileURL))
        XCTAssertNil(model.androidBackupImportPreview)
        XCTAssertEqual(
            model.entryOperationState,
            .failed("Android 加密备份暂未支持解密，请先从 Android 导出未加密 .zip 后再导入。")
        )
    }

    func testAndroidBackupEncryptedImportPreviewDecryptsWithPassword() throws {
        let model = AppSessionModel(vaultRepository: LocalVaultRepository(engine: RecordingVaultEngine()))
        let encryptedBackup = Data(base64Encoded: """
        TU9OSUNBX0VOQ19WMQABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fICEiIyQlJicoKSor3Y7UrXnMGjMyxTjucaTvnqyejqWi9PHsimI3t6aeujIinpZ9V4kzgGj5aN0bqpcK8dZ5GxOGeRjuXpPWnGZoN2XLZQEp9wGTrxF8MQqTNxfnOm3kQLENAOEcvxbnkLSso7VQDZGyUtynn3ysNVxGLbij/lWGBVjV0CrKZvKaMiXUJfmE9WSDZRuHDi1YIg2goD3ubLzMkOctElPzm9JF4YFzeYjGmZxMgNFuWJeerzy9HzcqhMYcGJUEvjmuWz3NybBvnurVJAgizdYXM9kIqjqE9wdr67/qVmw7KyUwfI3CFThAxxg57RFWwBTrf/drVNPUrJDknJTSJZLFkX6US+J6J5zYD8kePndLxF4AS6zj2mzVCNzLJzy9HpBYvrj3ZqchQ7/7hFNqbixH1NjH0+u+wz+aHkJ8LF5jb3bMJg==
        """)!

        try unlockNewVault(model)
        let preview = try model.previewAndroidBackupImport(
            encryptedBackup,
            fileName: "monica_backup.enc.zip",
            decryptPassword: "correct horse battery staple"
        )

        XCTAssertEqual(preview.items.map(\.kind), [.login])
        XCTAssertEqual(model.entryOperationState, .succeeded("Android 备份预览：1 项可导入，0 个问题"))
    }

    func testAndroidBackupEncryptedFileCanBePreparedAndRetriedWithPassword() throws {
        let model = AppSessionModel(vaultRepository: LocalVaultRepository(engine: RecordingVaultEngine()))
        let encryptedBackup = Data(base64Encoded: """
        TU9OSUNBX0VOQ19WMQABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fICEiIyQlJicoKSor3Y7UrXnMGjMyxTjucaTvnqyejqWi9PHsimI3t6aeujIinpZ9V4kzgGj5aN0bqpcK8dZ5GxOGeRjuXpPWnGZoN2XLZQEp9wGTrxF8MQqTNxfnOm3kQLENAOEcvxbnkLSso7VQDZGyUtynn3ysNVxGLbij/lWGBVjV0CrKZvKaMiXUJfmE9WSDZRuHDi1YIg2goD3ubLzMkOctElPzm9JF4YFzeYjGmZxMgNFuWJeerzy9HzcqhMYcGJUEvjmuWz3NybBvnurVJAgizdYXM9kIqjqE9wdr67/qVmw7KyUwfI3CFThAxxg57RFWwBTrf/drVNPUrJDknJTSJZLFkX6US+J6J5zYD8kePndLxF4AS6zj2mzVCNzLJzy9HpBYvrj3ZqchQ7/7hFNqbixH1NjH0+u+wz+aHkJ8LF5jb3bMJg==
        """)!
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica_backup.enc.zip")
        try encryptedBackup.write(to: fileURL)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        try unlockNewVault(model)
        let immediatePreview = try model.prepareAndroidBackupImport(from: fileURL)

        XCTAssertNil(immediatePreview)
        XCTAssertEqual(model.pendingAndroidEncryptedBackupFileName, "monica_backup.enc.zip")
        XCTAssertEqual(model.entryOperationState, .failed("请输入 Android 加密备份密码。"))

        model.androidBackupDecryptPassword = "wrong password"
        XCTAssertThrowsError(try model.previewPendingAndroidEncryptedBackupImport())
        XCTAssertEqual(model.pendingAndroidEncryptedBackupFileName, "monica_backup.enc.zip")
        XCTAssertEqual(model.androidBackupDecryptPassword, "")
        XCTAssertNil(model.androidBackupImportPreview)
        XCTAssertEqual(
            model.entryOperationState,
            .failed("Android 加密备份解密失败，请检查密码或文件是否损坏。")
        )

        model.androidBackupDecryptPassword = "correct horse battery staple"
        let preview = try model.previewPendingAndroidEncryptedBackupImport()

        XCTAssertEqual(preview.items.map(\.kind), [.login])
        XCTAssertNil(model.pendingAndroidEncryptedBackupFileName)
        XCTAssertEqual(model.androidBackupDecryptPassword, "")
        XCTAssertEqual(model.entryOperationState, .succeeded("Android 备份预览：1 项可导入，0 个问题"))
    }

    func testAndroidBackupConfirmImportsAttachmentMetadataWithRemappedLoginID() throws {
        let engine = RecordingVaultEngine()
        let blobStore = RecordingAndroidBackupAttachmentBlobStore()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            androidBackupAttachmentBlobStore: blobStore
        )
        let backup = try AndroidBackupCodec.exportZip(entries: [
            "folders/Work/passwords/password_42_1710000000000.json": #"{"id":42,"title":"GitHub","username":"alice","password":"secret-password","website":"https://github.com","categoryName":"Work"}"#,
            "attachments/attachments_meta.json": #"""
            {"version":1,"entries":[{"parentPasswordId":42,"fileName":"contract.pdf","mimeType":"application/pdf","sizeBytes":2048,"sha256Hex":"abc123","wrappedCek":"wrapped-key","localPath":"attachment-1.enc","createdAt":1710000000000,"updatedAt":1710000001000}]}
            """#,
            "attachments/attachment-1.enc": "ciphertext"
        ])

        try unlockNewVault(model)
        _ = try model.previewAndroidBackupImport(backup)

        XCTAssertTrue(engine.createdAttachmentMetadata.isEmpty)

        try model.confirmAndroidBackupImport(projectTitle: "Android 备份")

        XCTAssertEqual(model.loginEntries.map(\.id), ["entry-1"])
        XCTAssertEqual(
            blobStore.savedBlobs,
            [
                RecordedAndroidBackupAttachmentBlob(
                    vaultID: "created-vault",
                    localPath: "attachment-1.enc",
                    data: Data("ciphertext".utf8)
                )
            ]
        )
        XCTAssertEqual(engine.createdAttachmentMetadata.count, 1)
        XCTAssertEqual(model.attachmentEntries.map(\.fileName), ["contract.pdf"])
        XCTAssertEqual(model.attachmentEntries.first?.entryID, "entry-1")
        XCTAssertEqual(model.attachmentEntries.first?.storageMode, "android-backup-encrypted-blob")
        XCTAssertEqual(model.attachmentEntries.first?.downloadState, "downloaded")
        XCTAssertEqual(model.attachmentEntries.first?.localPath, "attachment-1.enc")
        model.attachmentSearchQuery = "entry-1"
        XCTAssertEqual(model.filteredAttachmentEntries.map(\.fileName), ["contract.pdf"])
        XCTAssertEqual(
            engine.createdAttachmentMetadata.first,
            RecordedAttachmentMetadataCall(
                vaultID: "created-vault",
                projectID: "project-1",
                entryID: "entry-1",
                fileName: "contract.pdf",
                mediaType: "application/pdf",
                originalSize: 2048,
                storedSize: 10,
                contentHash: "abc123",
                storageMode: "android-backup-encrypted-blob",
                source: "android-backup-local",
                downloadState: "downloaded",
                wrappedContentEncryptionKey: "wrapped-key",
                localPath: "attachment-1.enc"
            )
        )
        XCTAssertEqual(model.entryOperationState, .succeeded("Android 备份已导入 1 项；1 个附件密文待恢复"))
    }

    func testAndroidBackupAttachmentReferenceCanBeDeletedAndRestored() throws {
        let engine = RecordingVaultEngine()
        let blobStore = RecordingAndroidBackupAttachmentBlobStore()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            androidBackupAttachmentBlobStore: blobStore
        )
        let backup = try AndroidBackupCodec.exportZip(entries: [
            "folders/Work/passwords/password_42_1710000000000.json": #"{"id":42,"title":"GitHub","username":"alice","password":"secret-password","website":"https://github.com","categoryName":"Work"}"#,
            "attachments/attachments_meta.json": #"""
            {"version":1,"entries":[{"parentPasswordId":42,"fileName":"contract.pdf","mimeType":"application/pdf","sizeBytes":2048,"sha256Hex":"abc123","wrappedCek":"wrapped-key","localPath":"attachment-1.enc","createdAt":1710000000000,"updatedAt":1710000001000}]}
            """#,
            "attachments/attachment-1.enc": "ciphertext"
        ])

        try unlockNewVault(model)
        _ = try model.previewAndroidBackupImport(backup)
        try model.confirmAndroidBackupImport(projectTitle: "Android 备份")

        guard let attachment = model.attachmentEntries.first else {
            return XCTFail("Expected imported attachment reference")
        }

        try model.deleteAttachmentEntry(attachment)

        XCTAssertTrue(model.attachmentEntries.isEmpty)
        XCTAssertEqual(model.deletedAttachmentEntries.map(\.fileName), ["contract.pdf"])
        XCTAssertEqual(model.deletedAttachmentEntries.first?.deleted, true)
        XCTAssertEqual(model.entryOperationState, .succeeded("已删除 contract.pdf"))

        guard let deletedAttachment = model.deletedAttachmentEntries.first else {
            return XCTFail("Expected deleted attachment reference")
        }

        try model.restoreAttachmentEntry(deletedAttachment)

        XCTAssertEqual(model.attachmentEntries.map(\.fileName), ["contract.pdf"])
        XCTAssertTrue(model.deletedAttachmentEntries.isEmpty)
        XCTAssertEqual(model.attachmentEntries.first?.deleted, false)
        XCTAssertEqual(model.entryOperationState, .succeeded("已恢复 contract.pdf"))
    }

    func testFileAndroidBackupAttachmentBlobStoreWritesSanitizedEncryptedBlob() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = FileAndroidBackupAttachmentBlobStore(baseDirectory: directory)

        let relativePath = try store.saveEncryptedBlob(
            Data("ciphertext".utf8),
            vaultID: "created-vault",
            localPath: "../合同 attachment-1.enc"
        )

        XCTAssertEqual(relativePath, "___attachment-1.enc")
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("created-vault").appendingPathComponent(relativePath)),
            Data("ciphertext".utf8)
        )
    }

    func testAndroidBackupExportDocumentWrapsCurrentVaultZipForFileExporter() throws {
        let model = AppSessionModel(vaultRepository: LocalVaultRepository(engine: RecordingVaultEngine()))

        try unlockNewVault(model)
        model.loginTitle = "GitHub"
        model.loginUsername = "alice"
        model.loginPassword = "secret-password"
        model.loginURL = "https://github.com"
        try model.createLoginEntry(projectTitle: "Personal")

        let document = try model.androidBackupExportDocument()
        let report = try AndroidBackupCodec.importItems(from: document.data)

        XCTAssertEqual(AndroidBackupExportDocument.readableContentTypes, [.zip])
        XCTAssertEqual(report.items.map(\.kind), [.login])
        XCTAssertEqual(model.entryOperationState, .succeeded("Android 备份已导出 1 项"))
    }

    func testTotpEntryGeneratesCodeFromStoredSeed() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine)
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device"
        )

        model.totpTitle = "GitHub TOTP"
        model.totpSecret = "JBSWY3DPEHPK3PXP"
        model.totpIssuer = "GitHub"
        model.totpAccountName = "alice"
        model.totpPeriod = 30
        model.totpDigits = 6
        model.totpAlgorithm = "SHA1"
        try model.createTotpEntry(projectTitle: "Personal")

        let entry = try XCTUnwrap(model.totpEntries.first)
        let code = try model.totpCode(
            for: entry,
            at: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(code, "282760")
    }

    func testImportTotpURIpopulatesDraftFieldsWithoutSavingEntry() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine)
        )

        try model.importTotpURI(
            "otpauth://totp/GitHub:alice%40example.com?secret=JBSWY3DPEHPK3PXP&issuer=GitHub&period=60&digits=8&algorithm=SHA256"
        )

        XCTAssertEqual(model.totpTitle, "GitHub")
        XCTAssertEqual(model.totpSecret, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(model.totpIssuer, "GitHub")
        XCTAssertEqual(model.totpAccountName, "alice@example.com")
        XCTAssertEqual(model.totpPeriod, 60)
        XCTAssertEqual(model.totpDigits, 8)
        XCTAssertEqual(model.totpAlgorithm, "SHA256")
        XCTAssertTrue(model.totpEntries.isEmpty)
        XCTAssertTrue(engine.createdTotpEntries.isEmpty)
    }

    func testScannedTotpQRCodeImportsDraftFieldsWithoutSavingEntry() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine)
        )

        try model.importScannedTotpQRCode(
            "otpauth://totp/Linear:bob%40example.com?secret=JBSWY3DPEHPK3PXP&issuer=Linear"
        )

        XCTAssertEqual(model.totpTitle, "Linear")
        XCTAssertEqual(model.totpSecret, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(model.totpIssuer, "Linear")
        XCTAssertEqual(model.totpAccountName, "bob@example.com")
        XCTAssertEqual(model.totpImportURI, "")
        XCTAssertTrue(model.totpEntries.isEmpty)
        XCTAssertTrue(engine.createdTotpEntries.isEmpty)
    }

    func testScannedTotpQRCodeFailureUsesReadableMessageWithoutChangingDraft() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine)
        )
        model.totpTitle = "Existing"
        model.totpSecret = "JBSWY3DPEHPK3PXP"
        model.totpIssuer = "GitHub"
        model.totpAccountName = "alice"

        XCTAssertThrowsError(
            try model.importScannedTotpQRCode("https://example.com/not-a-totp-setup-code")
        )

        XCTAssertEqual(
            model.entryOperationState,
            .failed("扫描到的二维码不是 TOTP 设置码。")
        )
        XCTAssertEqual(model.totpTitle, "Existing")
        XCTAssertEqual(model.totpSecret, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(model.totpIssuer, "GitHub")
        XCTAssertEqual(model.totpAccountName, "alice")
        XCTAssertTrue(model.totpEntries.isEmpty)
        XCTAssertTrue(engine.createdTotpEntries.isEmpty)
    }

    func testTotpTimeRemainingUsesEntryPeriod() {
        let model = AppSessionModel()
        let entry = LocalTotpEntry(
            id: "totp-1",
            projectID: "project-1",
            title: "GitHub",
            secret: "JBSWY3DPEHPK3PXP",
            issuer: "GitHub",
            accountName: "alice",
            period: 30,
            digits: 6,
            algorithm: "SHA1",
            otpType: "TOTP",
            counter: 0
        )

        XCTAssertEqual(
            model.totpTimeRemaining(for: entry, at: Date(timeIntervalSince1970: 0)),
            30
        )
        XCTAssertEqual(
            model.totpTimeRemaining(for: entry, at: Date(timeIntervalSince1970: 29)),
            1
        )
        XCTAssertEqual(
            model.totpTimeRemaining(for: entry, at: Date(timeIntervalSince1970: 30)),
            30
        )
    }

    func testBackgroundingLocksUnlockedVaultAndClearsSensitiveSessionState() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine)
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device"
        )

        model.loginTitle = "GitHub"
        model.loginUsername = "alice"
        model.loginPassword = "correct horse battery staple"
        model.loginURL = "https://github.com"
        try model.createLoginEntry(projectTitle: "Personal")

        let created = try XCTUnwrap(model.loginEntries.first)
        model.selectLoginEntryForEditing(created)
        model.loginSearchQuery = "git"
        model.totpImportURI = "otpauth://totp/GitHub:alice?secret=JBSWY3DPEHPK3PXP"

        model.handleScenePhaseChange(.background)

        XCTAssertEqual(model.vaultState, .locked)
        XCTAssertNil(model.activeVaultName)
        XCTAssertEqual(model.vaultPassword, "")
        XCTAssertTrue(model.loginEntries.isEmpty)
        XCTAssertTrue(model.deletedLoginEntries.isEmpty)
        XCTAssertEqual(model.loginSearchQuery, "")
        XCTAssertEqual(model.loginPassword, "")
        XCTAssertEqual(model.totpImportURI, "")
        XCTAssertNil(model.editingLoginEntryID)
        XCTAssertEqual(model.editingLoginPassword, "")
        XCTAssertEqual(model.entryOperationState, .idle)
        XCTAssertEqual(model.vaultOperationState, .idle)
    }

    func testInactiveSceneShowsPrivacyShieldWithoutDroppingUnlockedSession() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine)
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device"
        )

        model.loginTitle = "GitHub"
        model.loginUsername = "alice"
        model.loginPassword = "correct horse battery staple"
        model.loginURL = "https://github.com"
        try model.createLoginEntry(projectTitle: "Personal")

        model.handleScenePhaseChange(.inactive)

        XCTAssertTrue(model.isPrivacyShieldVisible)
        XCTAssertEqual(model.vaultState, .unlocked)
        XCTAssertEqual(model.activeVaultName, "Mobile")
        XCTAssertEqual(model.loginEntries.map(\.title), ["GitHub"])

        model.handleScenePhaseChange(.active)

        XCTAssertFalse(model.isPrivacyShieldVisible)
        XCTAssertEqual(model.vaultState, .unlocked)
    }

    func testAutoLockWindowKeepsRecentSessionUnlocked() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            autoLockPolicy: AppAutoLockPolicy(idleTimeout: 300)
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device",
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        model.lockIfIdle(now: Date(timeIntervalSince1970: 1_800_000_299))

        XCTAssertEqual(model.vaultState, .unlocked)
        XCTAssertEqual(model.activeVaultName, "Mobile")
    }

    func testAutoLockWindowLocksExpiredSessionAndClearsSensitiveState() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            autoLockPolicy: AppAutoLockPolicy(idleTimeout: 300)
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device",
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        model.loginTitle = "GitHub"
        model.loginUsername = "alice"
        model.loginPassword = "correct horse battery staple"
        model.loginURL = "https://github.com"
        try model.createLoginEntry(projectTitle: "Personal")
        model.loginSearchQuery = "git"

        model.lockIfIdle(now: Date(timeIntervalSince1970: 1_800_000_301))

        XCTAssertEqual(model.vaultState, .locked)
        XCTAssertNil(model.activeVaultName)
        XCTAssertTrue(model.loginEntries.isEmpty)
        XCTAssertEqual(model.loginSearchQuery, "")
        XCTAssertEqual(model.loginPassword, "")
    }

    func testUserActivityRefreshesAutoLockWindow() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            autoLockPolicy: AppAutoLockPolicy(idleTimeout: 300)
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device",
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        model.recordUserActivity(at: Date(timeIntervalSince1970: 1_800_000_250))
        model.lockIfIdle(now: Date(timeIntervalSince1970: 1_800_000_500))

        XCTAssertEqual(model.vaultState, .unlocked)
        XCTAssertEqual(model.activeVaultName, "Mobile")
    }

    func testAutoLockPolicyProvidesSelectablePresets() {
        XCTAssertEqual(
            AppAutoLockPolicy.presets.map(\.label),
            ["1 分钟", "5 分钟", "15 分钟", "30 分钟"]
        )
        XCTAssertEqual(AppAutoLockPolicy.default, .fiveMinutes)
    }

    func testChangingAutoLockPolicyUsesNewIdleTimeout() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            autoLockPolicy: .fiveMinutes
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device",
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        model.updateAutoLockPolicy(
            .oneMinute,
            now: Date(timeIntervalSince1970: 1_800_000_010)
        )
        model.lockIfIdle(now: Date(timeIntervalSince1970: 1_800_000_071))

        XCTAssertEqual(model.vaultState, .locked)
        XCTAssertNil(model.activeVaultName)
    }

    func testAuthenticatedAutoFillIndexKeyDecryptsStorageIndexPayload() async throws {
        let store = MemoryAutoFillIndexKeyStore()
        let authenticator = RecordingLocalAuthenticator(result: true)
        let manager = AutoFillIndexKeychainManager(store: store, authenticator: authenticator)
        let keyMaterial = Data(repeating: 11, count: 32)
        try await manager.saveKeyMaterial(
            AutoFillIndexKeyMaterial(
                vaultID: "vault-1",
                keyIdentifier: "autofill-key-1",
                keyMaterial: keyMaterial,
                createdAt: Date(timeIntervalSince1970: 1_800_200_000)
            )
        )

        let codec = AutoFillEncryptedIndexCodec()
        let storageKey = try AutoFillIndexEncryptionKey(rawValue: keyMaterial)
        let records = [
            AutoFillCredentialIndexRecord(
                id: "entry-1",
                title: "GitHub",
                username: "alice@example.com",
                serviceIdentifiers: ["github.com"]
            )
        ]
        let index = try codec.encrypt(
            records,
            vaultID: "vault-1",
            keyIdentifier: "autofill-key-1",
            updatedAt: Date(timeIntervalSince1970: 1_800_200_100),
            key: storageKey
        )

        let unlockedKeyMaterial = try await manager.loadKeyMaterialAfterAuthentication(
            vaultID: "vault-1",
            reason: "解锁 Monica 自动填充"
        )
        let unlockedStorageKey = try AutoFillIndexEncryptionKey(
            rawValue: unlockedKeyMaterial.keyMaterial
        )
        let decrypted = try codec.decrypt(index, key: unlockedStorageKey)

        XCTAssertEqual(decrypted, records)
        XCTAssertEqual(authenticator.reasons, ["解锁 Monica 自动填充"])
    }

    func testAppSessionGeneratesEncryptedAutoFillIndexForCurrentLoginEntries() throws {
        let engine = RecordingVaultEngine()
        let indexStore = RecordingAutoFillEncryptedIndexStore()
        let keyMaterial = AutoFillIndexKeyMaterial(
            vaultID: "created-vault",
            keyIdentifier: "autofill-key-1",
            keyMaterial: Data(repeating: 13, count: 32),
            createdAt: Date(timeIntervalSince1970: 1_800_300_000)
        )
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            autoFillIndexStore: indexStore,
            autoFillCredentialSecretStore: RecordingAutoFillCredentialSecretStore(),
            autoFillIndexKeyMaterialProvider: { _ in keyMaterial }
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device"
        )
        model.loginTitle = "GitHub"
        model.loginUsername = "alice@example.com"
        model.loginPassword = "correct horse battery staple"
        model.loginURL = "https://github.com/login"
        try model.createLoginEntry(projectTitle: "Personal")

        try model.refreshAutoFillEncryptedIndex(
            updatedAt: Date(timeIntervalSince1970: 1_800_300_100)
        )

        let savedIndex = try XCTUnwrap(indexStore.savedIndexes.first)
        XCTAssertEqual(model.autoFillIndexState, .succeeded(1))
        XCTAssertEqual(savedIndex.vaultID, "created-vault")
        XCTAssertEqual(savedIndex.keyIdentifier, "autofill-key-1")
        XCTAssertEqual(savedIndex.records.count, 1)
        XCTAssertEqual(savedIndex.records.first?.id, "entry-1")

        let rawIndexData = try JSONEncoder().encode(savedIndex)
        let rawIndex = try XCTUnwrap(String(data: rawIndexData, encoding: .utf8))
        XCTAssertFalse(rawIndex.contains("github.com"))
        XCTAssertFalse(rawIndex.contains("alice@example.com"))
        XCTAssertFalse(rawIndex.contains("GitHub"))
    }

    func testLoginEntryMutationsKeepEncryptedAutoFillIndexInSync() throws {
        let engine = RecordingVaultEngine()
        let indexStore = RecordingAutoFillEncryptedIndexStore()
        let keyMaterial = AutoFillIndexKeyMaterial(
            vaultID: "created-vault",
            keyIdentifier: "autofill-key-1",
            keyMaterial: Data(repeating: 17, count: 32),
            createdAt: Date(timeIntervalSince1970: 1_800_400_000)
        )
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            autoFillIndexStore: indexStore,
            autoFillCredentialSecretStore: RecordingAutoFillCredentialSecretStore(),
            autoFillIndexKeyMaterialProvider: { _ in keyMaterial }
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device"
        )

        model.loginTitle = "GitHub"
        model.loginUsername = "alice@example.com"
        model.loginPassword = "correct horse battery staple"
        model.loginURL = "https://github.com/login"
        try model.createLoginEntry(projectTitle: "Personal")

        XCTAssertEqual(indexStore.savedIndexes.last?.records.count, 1)

        let created = try XCTUnwrap(model.loginEntries.first)
        model.selectLoginEntryForEditing(created)
        model.editingLoginTitle = "GitHub Enterprise"
        model.editingLoginUsername = "alice@work.example"
        model.editingLoginPassword = "updated secret"
        model.editingLoginURL = "https://github.example.com/login"
        try model.updateSelectedLoginEntry()

        let updatedIndex = try XCTUnwrap(indexStore.savedIndexes.last)
        let storageKey = try AutoFillIndexEncryptionKey(rawValue: keyMaterial.keyMaterial)
        let decryptedRecords = try AutoFillEncryptedIndexCodec().decrypt(
            updatedIndex,
            key: storageKey
        )
        XCTAssertEqual(decryptedRecords.first?.title, "GitHub Enterprise")
        XCTAssertEqual(decryptedRecords.first?.username, "alice@work.example")
        XCTAssertEqual(decryptedRecords.first?.serviceIdentifiers.first, "github.example.com")

        try model.deleteSelectedLoginEntry()

        XCTAssertEqual(indexStore.savedIndexes.last?.records.count, 0)

        let deleted = try XCTUnwrap(model.deletedLoginEntries.first)
        try model.restoreLoginEntry(deleted)

        XCTAssertEqual(indexStore.savedIndexes.last?.records.count, 1)
        XCTAssertEqual(model.autoFillIndexState, .succeeded(1))
    }

    func testLoginEntryMutationsKeepAutoFillCredentialIdentitiesInSync() throws {
        let identityStore = RecordingAutoFillCredentialIdentityStore()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: RecordingVaultEngine()),
            autoFillCredentialIdentityStore: identityStore
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device"
        )

        model.loginTitle = "GitHub"
        model.loginUsername = "alice@example.com"
        model.loginPassword = "correct horse battery staple"
        model.loginURL = "https://github.com/login"
        try model.createLoginEntry(projectTitle: "Personal")

        XCTAssertEqual(
            identityStore.savedIdentities.last,
            [
                AppAutoFillCredentialIdentity(
                    recordIdentifier: "entry-1",
                    serviceIdentifier: "github.com",
                    username: "alice@example.com"
                ),
                AppAutoFillCredentialIdentity(
                    recordIdentifier: "entry-1",
                    serviceIdentifier: "https://github.com/login",
                    username: "alice@example.com"
                )
            ]
        )

        let created = try XCTUnwrap(model.loginEntries.first)
        model.selectLoginEntryForEditing(created)
        model.editingLoginTitle = "GitHub Enterprise"
        model.editingLoginUsername = "alice@work.example"
        model.editingLoginPassword = "updated secret"
        model.editingLoginURL = "https://github.example.com/login"
        try model.updateSelectedLoginEntry()

        XCTAssertEqual(
            identityStore.savedIdentities.last,
            [
                AppAutoFillCredentialIdentity(
                    recordIdentifier: "entry-1",
                    serviceIdentifier: "github.example.com",
                    username: "alice@work.example"
                ),
                AppAutoFillCredentialIdentity(
                    recordIdentifier: "entry-1",
                    serviceIdentifier: "https://github.example.com/login",
                    username: "alice@work.example"
                )
            ]
        )

        try model.deleteSelectedLoginEntry()

        XCTAssertEqual(identityStore.savedIdentities.last, [])

        let deleted = try XCTUnwrap(model.deletedLoginEntries.first)
        try model.restoreLoginEntry(deleted)

        XCTAssertEqual(identityStore.savedIdentities.last?.count, 2)
    }

    func testAppSessionWritesAutoFillIndexThatExtensionCanUnlockAndMatch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let indexStore = FileAutoFillEncryptedIndexStore(appGroupContainerURL: directory)
        let keyMaterial = AutoFillIndexKeyMaterial(
            vaultID: "created-vault",
            keyIdentifier: "autofill-key-1",
            keyMaterial: Data(repeating: 19, count: 32),
            createdAt: Date(timeIntervalSince1970: 1_800_500_000)
        )

        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: RecordingVaultEngine()),
            autoFillIndexStore: indexStore,
            autoFillCredentialSecretStore: FileAutoFillCredentialSecretStore(appGroupContainerURL: directory),
            autoFillIndexKeyMaterialProvider: { _ in keyMaterial }
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device"
        )
        model.loginTitle = "GitHub"
        model.loginUsername = "alice@example.com"
        model.loginPassword = "correct horse battery staple"
        model.loginURL = "https://github.com/login"
        try model.createLoginEntry(projectTitle: "Personal")

        let savedIndex = try XCTUnwrap(try indexStore.load())
        let storageKey = try AutoFillIndexEncryptionKey(rawValue: keyMaterial.keyMaterial)
        let unlockedIndex = try AutoFillCredentialIndexUnlocker().unlock(
            savedIndex,
            vaultID: keyMaterial.vaultID,
            keyIdentifier: keyMaterial.keyIdentifier,
            key: storageKey
        )

        XCTAssertEqual(
            unlockedIndex.records(matchingServiceIdentifier: "https://github.com/session").map(\.id),
            ["entry-1"]
        )
        XCTAssertEqual(unlockedIndex.search("alice").map(\.id), ["entry-1"])
    }

    func testAppSessionWritesAutoFillCredentialSecretsThatExtensionCanUnlockForFilling() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let secretStore = FileAutoFillCredentialSecretStore(appGroupContainerURL: directory)
        let keyMaterial = AutoFillIndexKeyMaterial(
            vaultID: "created-vault",
            keyIdentifier: "autofill-key-1",
            keyMaterial: Data(repeating: 31, count: 32),
            createdAt: Date(timeIntervalSince1970: 1_800_700_000)
        )
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: RecordingVaultEngine()),
            autoFillCredentialSecretStore: secretStore,
            autoFillIndexKeyMaterialProvider: { _ in keyMaterial }
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device"
        )
        model.loginTitle = "GitHub"
        model.loginUsername = "alice@example.com"
        model.loginPassword = "correct horse battery staple"
        model.loginURL = "https://github.com/login"
        try model.createLoginEntry(projectTitle: "Personal")

        let savedSnapshot = try XCTUnwrap(try secretStore.load())
        let storageKey = try AutoFillIndexEncryptionKey(rawValue: keyMaterial.keyMaterial)
        let unlockedSnapshot = try AutoFillCredentialSecretUnlocker().unlock(
            savedSnapshot,
            vaultID: keyMaterial.vaultID,
            keyIdentifier: keyMaterial.keyIdentifier,
            key: storageKey
        )

        XCTAssertEqual(
            unlockedSnapshot.secret(id: "entry-1"),
            AutoFillCredentialSecretRecord(
                id: "entry-1",
                username: "alice@example.com",
                password: "correct horse battery staple"
            )
        )

        let rawSnapshot = try String(contentsOf: secretStore.secretFileURL, encoding: .utf8)
        XCTAssertFalse(rawSnapshot.contains("alice@example.com"))
        XCTAssertFalse(rawSnapshot.contains("correct horse battery staple"))
    }

    func testWebDAVBackupUploadsActiveVaultFileAndStoresReceiptState() async throws {
        let engine = RecordingVaultEngine()
        let webDAVService = RecordingAppWebDAVBackupService()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            webDAVBackupService: webDAVService
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(in: directory, deviceID: "ios-app-test-device")
        try Data("vault-bytes".utf8).write(to: directory.appendingPathComponent("Mobile.mdbx"))
        model.webDAVBaseURL = "https://dav.example.com/backups/"
        model.webDAVUsername = "alice"
        model.webDAVPassword = "secret"
        model.webDAVRemoteFileName = "mobile.mdbx"

        try await model.uploadActiveVaultBackup()

        let upload = try XCTUnwrap(webDAVService.uploads.first)
        XCTAssertEqual(upload.endpoint.baseURL.absoluteString, "https://dav.example.com/backups/")
        XCTAssertEqual(upload.endpoint.username, "alice")
        XCTAssertEqual(upload.endpoint.password, "secret")
        XCTAssertEqual(upload.package.fileName, "mobile.mdbx")
        XCTAssertEqual(upload.package.data, Data("vault-bytes".utf8))
        XCTAssertEqual(model.webDAVBackupState, .backupSucceeded(byteCount: 11, sha256: "receipt-sha"))
    }

    func testWebDAVRestoreDownloadBuildsPreviewWithoutOverwritingActiveVault() async throws {
        let engine = RecordingVaultEngine()
        let webDAVService = RecordingAppWebDAVBackupService()
        webDAVService.downloadedBackup = WebDAVDownloadedBackup(
            fileName: "mobile.mdbx",
            remoteURL: try XCTUnwrap(URL(string: "https://dav.example.com/backups/mobile.mdbx")),
            data: Data("remote-vault".utf8),
            sha256: "remote-sha"
        )
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            webDAVBackupService: webDAVService
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(in: directory, deviceID: "ios-app-test-device")
        let vaultURL = directory.appendingPathComponent("Mobile.mdbx")
        try Data("local-vault".utf8).write(to: vaultURL)
        model.webDAVBaseURL = "https://dav.example.com/backups/"
        model.webDAVUsername = "alice"
        model.webDAVPassword = "secret"
        model.webDAVRemoteFileName = "mobile.mdbx"

        try await model.downloadWebDAVRestorePreview()

        XCTAssertEqual(try Data(contentsOf: vaultURL), Data("local-vault".utf8))
        XCTAssertEqual(model.webDAVRestorePreview?.fileName, "mobile.mdbx")
        XCTAssertEqual(model.webDAVRestorePreview?.byteCount, 12)
        XCTAssertEqual(model.webDAVRestorePreview?.sha256, "remote-sha")
        XCTAssertEqual(model.webDAVBackupState, .restorePreviewReady(fileName: "mobile.mdbx", byteCount: 12))
    }

    func testConfirmWebDAVRestoreAtomicallyReplacesVaultAndLocksSession() async throws {
        let engine = RecordingVaultEngine()
        let webDAVService = RecordingAppWebDAVBackupService()
        webDAVService.downloadedBackup = WebDAVDownloadedBackup(
            fileName: "mobile.mdbx",
            remoteURL: try XCTUnwrap(URL(string: "https://dav.example.com/backups/mobile.mdbx")),
            data: Data("remote-vault".utf8),
            sha256: "remote-sha"
        )
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            webDAVBackupService: webDAVService
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(in: directory, deviceID: "ios-app-test-device")
        let vaultURL = directory.appendingPathComponent("Mobile.mdbx")
        try Data("local-vault".utf8).write(to: vaultURL)
        model.loginTitle = "GitHub"
        model.loginUsername = "alice"
        model.loginPassword = "secret"
        model.loginURL = "https://github.com"
        try model.createLoginEntry(projectTitle: "Personal")
        model.webDAVBaseURL = "https://dav.example.com/backups/"
        model.webDAVUsername = "alice"
        model.webDAVPassword = "secret"
        model.webDAVRemoteFileName = "mobile.mdbx"
        try await model.downloadWebDAVRestorePreview()
        model.webDAVRestoreVaultPassword = "restored vault password"

        try model.confirmWebDAVRestore()

        XCTAssertEqual(engine.openedVaults.last?.password, "restored vault password")
        XCTAssertEqual(try Data(contentsOf: vaultURL), Data("remote-vault".utf8))
        XCTAssertEqual(model.vaultState, .locked)
        XCTAssertNil(model.activeVaultName)
        XCTAssertTrue(model.loginEntries.isEmpty)
        XCTAssertNil(model.webDAVRestorePreview)
        XCTAssertTrue(model.webDAVRestoreVaultPassword.isEmpty)
        XCTAssertEqual(model.webDAVBackupState, .restoreSucceeded(fileName: "mobile.mdbx", byteCount: 12))
    }

    func testConfirmWebDAVRestoreDoesNotReplaceLocalVaultWhenDownloadedVaultCannotOpen() async throws {
        let engine = RecordingVaultEngine()
        let webDAVService = RecordingAppWebDAVBackupService()
        webDAVService.downloadedBackup = WebDAVDownloadedBackup(
            fileName: "mobile.mdbx",
            remoteURL: try XCTUnwrap(URL(string: "https://dav.example.com/backups/mobile.mdbx")),
            data: Data("remote-vault".utf8),
            sha256: "remote-sha"
        )
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            webDAVBackupService: webDAVService
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(in: directory, deviceID: "ios-app-test-device")
        let vaultURL = directory.appendingPathComponent("Mobile.mdbx")
        try Data("local-vault".utf8).write(to: vaultURL)
        model.webDAVBaseURL = "https://dav.example.com/backups/"
        model.webDAVUsername = "alice"
        model.webDAVPassword = "secret"
        model.webDAVRemoteFileName = "mobile.mdbx"
        try await model.downloadWebDAVRestorePreview()
        model.webDAVRestoreVaultPassword = "wrong restored vault password"
        engine.openVaultError = LocalVaultRepositoryError.vaultUnavailable

        XCTAssertThrowsError(try model.confirmWebDAVRestore())

        XCTAssertEqual(try Data(contentsOf: vaultURL), Data("local-vault".utf8))
        XCTAssertEqual(engine.openedVaults.last?.password, "wrong restored vault password")
        XCTAssertEqual(model.vaultState, .unlocked)
        XCTAssertEqual(model.activeVaultName, "Mobile")
        XCTAssertEqual(model.webDAVRestorePreview?.fileName, "mobile.mdbx")
        XCTAssertTrue(model.webDAVRestoreVaultPassword.isEmpty)
        XCTAssertEqual(
            model.webDAVBackupState.label,
            "无法打开恢复备份，请检查保险库密码。"
        )
    }

    func testWebDAVUploadAuthenticationFailureUsesReadableMessage() async throws {
        let engine = RecordingVaultEngine()
        let webDAVService = RecordingAppWebDAVBackupService()
        webDAVService.uploadError = WebDAVError.unexpectedStatus(operation: "upload", statusCode: 401)
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            webDAVBackupService: webDAVService
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(in: directory, deviceID: "ios-app-test-device")
        try Data("vault-bytes".utf8).write(to: directory.appendingPathComponent("Mobile.mdbx"))
        model.webDAVBaseURL = "https://dav.example.com/backups/"
        model.webDAVUsername = "alice"
        model.webDAVPassword = "wrong-password"
        model.webDAVRemoteFileName = "mobile.mdbx"

        do {
            try await model.uploadActiveVaultBackup()
            XCTFail("Expected WebDAV upload to fail")
        } catch {}

        XCTAssertEqual(
            model.webDAVBackupState.label,
            "WebDAV 登录失败，请检查用户名和密码。"
        )
    }

    func testWebDAVDownloadIntegrityFailureUsesReadableMessage() async throws {
        let engine = RecordingVaultEngine()
        let webDAVService = RecordingAppWebDAVBackupService()
        webDAVService.downloadError = WebDAVError.integrityCheckFailed
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            webDAVBackupService: webDAVService
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(in: directory, deviceID: "ios-app-test-device")
        try Data("vault-bytes".utf8).write(to: directory.appendingPathComponent("Mobile.mdbx"))
        model.webDAVBaseURL = "https://dav.example.com/backups/"
        model.webDAVUsername = "alice"
        model.webDAVPassword = "secret"
        model.webDAVRemoteFileName = "mobile.mdbx"

        do {
            try await model.downloadWebDAVRestorePreview()
            XCTFail("Expected WebDAV restore preview to fail")
        } catch {}

        XCTAssertEqual(
            model.webDAVBackupState.label,
            "远端备份未通过完整性校验，可能已经损坏。"
        )
    }

    func testWebDAVNetworkFailureUsesReadableMessage() async throws {
        let engine = RecordingVaultEngine()
        let webDAVService = RecordingAppWebDAVBackupService()
        webDAVService.uploadError = URLError(.notConnectedToInternet)
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            webDAVBackupService: webDAVService
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(in: directory, deviceID: "ios-app-test-device")
        try Data("vault-bytes".utf8).write(to: directory.appendingPathComponent("Mobile.mdbx"))
        model.webDAVBaseURL = "https://dav.example.com/backups/"
        model.webDAVUsername = "alice"
        model.webDAVPassword = "secret"
        model.webDAVRemoteFileName = "mobile.mdbx"

        do {
            try await model.uploadActiveVaultBackup()
            XCTFail("Expected WebDAV upload to fail")
        } catch {}

        XCTAssertEqual(
            model.webDAVBackupState.label,
            "网络不可用，请检查连接后重试。"
        )
    }
}

private final class RecordingAppAutoFillIndexKeyMaterialStore: AppAutoFillIndexKeyMaterialStore {
    private var keys: [String: AutoFillIndexKeyMaterial] = [:]
    private(set) var savedKeyMaterials: [AutoFillIndexKeyMaterial] = []

    func loadKeyMaterial(vaultID: String) throws -> AutoFillIndexKeyMaterial? {
        keys[vaultID]
    }

    func saveKeyMaterial(_ keyMaterial: AutoFillIndexKeyMaterial) throws {
        keys[keyMaterial.vaultID] = keyMaterial
        savedKeyMaterials.append(keyMaterial)
    }
}

private final class RecordingAutoFillEncryptedIndexStore: AutoFillEncryptedIndexStore, @unchecked Sendable {
    private(set) var savedIndexes: [AutoFillEncryptedIndex] = []

    func save(_ index: AutoFillEncryptedIndex) throws {
        savedIndexes.append(index)
    }

    func load() throws -> AutoFillEncryptedIndex? {
        savedIndexes.last
    }

    func delete() throws {
        savedIndexes.removeAll()
    }
}

private final class RecordingAutoFillCredentialSecretStore: AutoFillCredentialSecretStore, @unchecked Sendable {
    private(set) var savedSnapshots: [AutoFillCredentialSecretSnapshot] = []

    func save(_ snapshot: AutoFillCredentialSecretSnapshot) throws {
        savedSnapshots.append(snapshot)
    }

    func load() throws -> AutoFillCredentialSecretSnapshot? {
        savedSnapshots.last
    }

    func delete() throws {
        savedSnapshots.removeAll()
    }
}

private final class RecordingAutoFillCredentialIdentityStore: AppAutoFillCredentialIdentityStore, @unchecked Sendable {
    private(set) var savedIdentities: [[AppAutoFillCredentialIdentity]] = []

    func replaceCredentialIdentities(_ identities: [AppAutoFillCredentialIdentity]) {
        savedIdentities.append(identities)
    }
}

private final class RecordingAppVaultKeychainService: AppVaultKeychainService, @unchecked Sendable {
    private(set) var savedWrappedKeys: [WrappedVaultKey] = []
    private(set) var loadRequests: [(vaultID: String, reason: String)] = []
    var loadedWrappedKey: WrappedVaultKey?
    var saveError: Error?
    var loadError: Error?

    func saveWrappedKey(_ key: WrappedVaultKey) async throws {
        if let saveError {
            throw saveError
        }
        savedWrappedKeys.append(key)
        loadedWrappedKey = key
    }

    func loadWrappedKeyAfterAuthentication(
        vaultID: String,
        reason: String
    ) async throws -> WrappedVaultKey {
        loadRequests.append((vaultID, reason))
        if let loadError {
            throw loadError
        }
        guard let loadedWrappedKey else {
            throw MonicaSecurityError.wrappedKeyNotFound
        }
        return loadedWrappedKey
    }
}

private final class RecordingBiometricUnlockAuthorizer: BiometricUnlockAuthorizer, @unchecked Sendable {
    private(set) var authenticationReasons: [String] = []
    let kind: BiometricUnlockKind

    init(kind: BiometricUnlockKind) {
        self.kind = kind
    }

    func authenticate(reason: String) async throws {
        authenticationReasons.append(reason)
    }
}

private final class RecordingAppWebDAVBackupService: AppWebDAVBackupService, @unchecked Sendable {
    private(set) var uploads: [(endpoint: WebDAVEndpoint, package: WebDAVBackupPackage)] = []
    private(set) var downloads: [(endpoint: WebDAVEndpoint, fileName: String)] = []
    var uploadReceipt = WebDAVBackupReceipt(
        remoteURL: URL(string: "https://dav.example.com/backups/mobile.mdbx")!,
        byteCount: 11,
        sha256: "receipt-sha"
    )
    var uploadError: Error?
    var downloadedBackup = WebDAVDownloadedBackup(
        fileName: "mobile.mdbx",
        remoteURL: URL(string: "https://dav.example.com/backups/mobile.mdbx")!,
        data: Data("remote-vault".utf8),
        sha256: "remote-sha"
    )
    var downloadError: Error?

    func upload(endpoint: WebDAVEndpoint, package: WebDAVBackupPackage) async throws -> WebDAVBackupReceipt {
        uploads.append((endpoint, package))
        if let uploadError {
            throw uploadError
        }
        return uploadReceipt
    }

    func download(endpoint: WebDAVEndpoint, fileName: String) async throws -> WebDAVDownloadedBackup {
        downloads.append((endpoint, fileName))
        if let downloadError {
            throw downloadError
        }
        return downloadedBackup
    }
}

private final class RecordingAndroidBackupAttachmentBlobStore: AndroidBackupAttachmentBlobStore {
    private(set) var savedBlobs: [RecordedAndroidBackupAttachmentBlob] = []

    func saveEncryptedBlob(_ data: Data, vaultID: String, localPath: String) throws -> String {
        savedBlobs.append(
            RecordedAndroidBackupAttachmentBlob(
                vaultID: vaultID,
                localPath: localPath,
                data: data
            )
        )
        return localPath
    }
}

private struct RecordedAndroidBackupAttachmentBlob: Equatable {
    let vaultID: String
    let localPath: String
    let data: Data
}

private final class RecordingVaultEngine: LocalVaultEngine {
    private(set) var createdVaults: [RecordedVaultCall] = []
    private(set) var openedVaults: [RecordedVaultCall] = []
    private(set) var securityKeyOpenedVaults: [RecordedSecurityKeyVaultCall] = []
    private(set) var securityKeySetups: [RecordedSecurityKeySetupCall] = []
    private(set) var resetMasterPasswordCalls: [RecordedResetMasterPasswordCall] = []
    var createVaultError: Error?
    var openVaultError: Error?
    var openVaultID = "opened-vault"
    var securityKeyOpenVaultID = "security-key-opened-vault"
    private(set) var createdProjects: [RecordedProjectCall] = []
    private(set) var createdLoginEntries: [RecordedLoginEntryCall] = []
    private(set) var updatedLoginEntries: [RecordedUpdatedLoginEntryCall] = []
    private(set) var favoritedLoginEntries: [RecordedFavoriteEntryCall] = []
    private(set) var deletedLoginEntries: [RecordedEntryMutationCall] = []
    private(set) var restoredLoginEntries: [RecordedEntryMutationCall] = []
    private(set) var createdNoteEntries: [RecordedNoteEntryCall] = []
    private(set) var updatedNoteEntries: [RecordedUpdatedNoteEntryCall] = []
    private(set) var favoritedNoteEntries: [RecordedFavoriteEntryCall] = []
    private(set) var deletedNoteEntries: [RecordedEntryMutationCall] = []
    private(set) var restoredNoteEntries: [RecordedEntryMutationCall] = []
    private(set) var createdTotpEntries: [RecordedTotpEntryCall] = []
    private(set) var updatedTotpEntries: [RecordedUpdatedTotpEntryCall] = []
    private(set) var favoritedTotpEntries: [RecordedFavoriteEntryCall] = []
    private(set) var deletedTotpEntries: [RecordedEntryMutationCall] = []
    private(set) var restoredTotpEntries: [RecordedEntryMutationCall] = []
    private(set) var createdCardEntries: [RecordedCardEntryCall] = []
    private(set) var updatedCardEntries: [RecordedUpdatedCardEntryCall] = []
    private(set) var favoritedCardEntries: [RecordedFavoriteEntryCall] = []
    private(set) var deletedCardEntries: [RecordedEntryMutationCall] = []
    private(set) var restoredCardEntries: [RecordedEntryMutationCall] = []
    private(set) var createdIdentityEntries: [RecordedIdentityEntryCall] = []
    private(set) var updatedIdentityEntries: [RecordedUpdatedIdentityEntryCall] = []
    private(set) var favoritedIdentityEntries: [RecordedFavoriteEntryCall] = []
    private(set) var deletedIdentityEntries: [RecordedEntryMutationCall] = []
    private(set) var restoredIdentityEntries: [RecordedEntryMutationCall] = []
    private(set) var createdPasskeyEntries: [RecordedPasskeyEntryCall] = []
    private(set) var updatedPasskeyEntries: [RecordedUpdatedPasskeyEntryCall] = []
    private(set) var favoritedPasskeyEntries: [RecordedFavoriteEntryCall] = []
    private(set) var deletedPasskeyEntries: [RecordedEntryMutationCall] = []
    private(set) var restoredPasskeyEntries: [RecordedEntryMutationCall] = []
    private(set) var createdSshKeyEntries: [RecordedSshKeyEntryCall] = []
    private(set) var updatedSshKeyEntries: [RecordedUpdatedSshKeyEntryCall] = []
    private(set) var favoritedSshKeyEntries: [RecordedFavoriteEntryCall] = []
    private(set) var deletedSshKeyEntries: [RecordedEntryMutationCall] = []
    private(set) var restoredSshKeyEntries: [RecordedEntryMutationCall] = []
    private(set) var createdApiTokenEntries: [RecordedApiTokenEntryCall] = []
    private(set) var updatedApiTokenEntries: [RecordedUpdatedApiTokenEntryCall] = []
    private(set) var favoritedApiTokenEntries: [RecordedFavoriteEntryCall] = []
    private(set) var deletedApiTokenEntries: [RecordedEntryMutationCall] = []
    private(set) var restoredApiTokenEntries: [RecordedEntryMutationCall] = []
    private(set) var createdWifiEntries: [RecordedWifiEntryCall] = []
    private(set) var updatedWifiEntries: [RecordedUpdatedWifiEntryCall] = []
    private(set) var favoritedWifiEntries: [RecordedFavoriteEntryCall] = []
    private(set) var deletedWifiEntries: [RecordedEntryMutationCall] = []
    private(set) var restoredWifiEntries: [RecordedEntryMutationCall] = []
    private(set) var createdSendEntries: [RecordedSendEntryCall] = []
    private(set) var updatedSendEntries: [RecordedUpdatedSendEntryCall] = []
    private(set) var favoritedSendEntries: [RecordedFavoriteEntryCall] = []
    private(set) var deletedSendEntries: [RecordedEntryMutationCall] = []
    private(set) var restoredSendEntries: [RecordedEntryMutationCall] = []
    private(set) var createdAttachmentMetadata: [RecordedAttachmentMetadataCall] = []
    private var loginEntries: [String: [LocalLoginEntry]] = [:]
    private var deletedEntries: [String: [LocalLoginEntry]] = [:]
    private var noteEntries: [String: [LocalNoteEntry]] = [:]
    private var deletedNotes: [String: [LocalNoteEntry]] = [:]
    private var totpEntries: [String: [LocalTotpEntry]] = [:]
    private var deletedTotp: [String: [LocalTotpEntry]] = [:]
    private var cardEntries: [String: [LocalCardEntry]] = [:]
    private var deletedCards: [String: [LocalCardEntry]] = [:]
    private var identityEntries: [String: [LocalIdentityEntry]] = [:]
    private var deletedIdentities: [String: [LocalIdentityEntry]] = [:]
    private var passkeyEntries: [String: [LocalPasskeyEntry]] = [:]
    private var deletedPasskeys: [String: [LocalPasskeyEntry]] = [:]
    private var sshKeyEntries: [String: [LocalSshKeyEntry]] = [:]
    private var deletedSshKeys: [String: [LocalSshKeyEntry]] = [:]
    private var apiTokenEntries: [String: [LocalApiTokenEntry]] = [:]
    private var deletedApiTokens: [String: [LocalApiTokenEntry]] = [:]
    private var wifiEntries: [String: [LocalWifiEntry]] = [:]
    private var deletedWifi: [String: [LocalWifiEntry]] = [:]
    private var sendEntries: [String: [LocalSendEntry]] = [:]
    private var deletedSends: [String: [LocalSendEntry]] = [:]
    private var attachmentMetadata: [String: [LocalAttachmentMetadata]] = [:]
    private var deletedAttachmentMetadata: [String: [LocalAttachmentMetadata]] = [:]

    func createVault(
        at fileURL: URL,
        password: String,
        deviceID: String
    ) throws -> LocalVaultHandle {
        createdVaults.append(.init(fileURL: fileURL, password: password, deviceID: deviceID))
        if let createVaultError {
            throw createVaultError
        }
        return LocalVaultHandle(vaultID: "created-vault", deviceID: deviceID)
    }

    func openVault(
        at fileURL: URL,
        password: String,
        deviceID: String
    ) throws -> LocalVaultHandle {
        openedVaults.append(.init(fileURL: fileURL, password: password, deviceID: deviceID))
        if let openVaultError {
            throw openVaultError
        }
        return LocalVaultHandle(vaultID: openVaultID, deviceID: deviceID)
    }

    func openVaultWithSecurityKey(
        at fileURL: URL,
        securityKeyMaterial: Data,
        deviceID: String
    ) throws -> LocalVaultHandle {
        securityKeyOpenedVaults.append(
            .init(fileURL: fileURL, keyMaterial: securityKeyMaterial, deviceID: deviceID)
        )
        if let openVaultError {
            throw openVaultError
        }
        return LocalVaultHandle(vaultID: securityKeyOpenVaultID, deviceID: deviceID)
    }

    func setupLocalSecurityKeyUnlock(
        in handle: LocalVaultHandle,
        securityKeyMaterial: Data
    ) throws {
        securityKeySetups.append(
            .init(vaultID: handle.vaultID, keyMaterial: securityKeyMaterial)
        )
    }

    func resetMasterPassword(
        in handle: LocalVaultHandle,
        newPassword: String
    ) throws {
        resetMasterPasswordCalls.append(
            .init(vaultID: handle.vaultID, newPassword: newPassword)
        )
    }

    func closeVault(_ handle: LocalVaultHandle) {}

    func seedExtendedParityEntries(projectID: String) {
        sshKeyEntries[projectID] = [
            LocalSshKeyEntry(
                id: "ssh-1",
                projectID: projectID,
                title: "Production deploy key",
                username: "deploy",
                host: "prod.example.com",
                publicKey: "ssh-ed25519 AAAA",
                privateKeyReference: "keychain://ssh/prod",
                passphraseHint: "1Password",
                notes: "Android parity SSH metadata",
                favorite: true
            )
        ]
        deletedSshKeys[projectID] = [
            LocalSshKeyEntry(
                id: "ssh-deleted-1",
                projectID: projectID,
                title: "Retired deploy key",
                username: "deploy",
                host: "old.example.com",
                publicKey: "ssh-ed25519 OLD",
                privateKeyReference: "keychain://ssh/old",
                passphraseHint: "",
                notes: ""
            )
        ]
        apiTokenEntries[projectID] = [
            LocalApiTokenEntry(
                id: "api-token-1",
                projectID: projectID,
                title: "Tiga API token",
                issuer: "Tiga",
                accountName: "joyin",
                token: "sk-secret",
                scopes: "sync,read",
                expiresAt: "2031-01-01",
                notes: "Keep secret"
            )
        ]
        deletedApiTokens[projectID] = [
            LocalApiTokenEntry(
                id: "api-token-deleted-1",
                projectID: projectID,
                title: "Old API token",
                issuer: "Tiga",
                accountName: "joyin",
                token: "sk-old",
                scopes: "read",
                expiresAt: "2026-01-01",
                notes: ""
            )
        ]
        wifiEntries[projectID] = [
            LocalWifiEntry(
                id: "wifi-1",
                projectID: projectID,
                title: "Studio Wi-Fi",
                ssid: "Monica Studio",
                securityType: "WPA2",
                password: "wifi-secret",
                hidden: false,
                notes: "Main office"
            )
        ]
        deletedWifi[projectID] = [
            LocalWifiEntry(
                id: "wifi-deleted-1",
                projectID: projectID,
                title: "Guest Wi-Fi",
                ssid: "Monica Guest",
                securityType: "WPA2",
                password: "guest-secret",
                hidden: false,
                notes: ""
            )
        ]
        sendEntries[projectID] = [
            LocalSendEntry(
                id: "send-1",
                projectID: projectID,
                title: "One-time send",
                body: "share once",
                expiresAt: "2026-06-02",
                maxViews: 1,
                notes: "MVP metadata"
            )
        ]
        deletedSends[projectID] = [
            LocalSendEntry(
                id: "send-deleted-1",
                projectID: projectID,
                title: "Expired send",
                body: "expired",
                expiresAt: "2026-01-01",
                maxViews: 1,
                notes: ""
            )
        ]
    }

    func createProject(
        in handle: LocalVaultHandle,
        title: String
    ) throws -> LocalVaultProject {
        createdProjects.append(.init(vaultID: handle.vaultID, title: title))
        return LocalVaultProject(id: "project-\(createdProjects.count)", title: title)
    }

    func createLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalLoginEntryDraft
    ) throws -> LocalLoginEntry {
        let entry = LocalLoginEntry(
            id: "entry-\(createdLoginEntries.count + 1)",
            projectID: projectID,
            title: draft.title,
            username: draft.username,
            password: draft.password,
            url: draft.url
        )
        createdLoginEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, draft: draft)
        )
        loginEntries[projectID, default: []].append(entry)
        return entry
    }

    func listLoginEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalLoginEntry] {
        loginEntries[projectID, default: []]
    }

    func updateLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalLoginEntryDraft
    ) throws -> LocalLoginEntry {
        let currentFavorite = loginEntries[projectID, default: []]
            .first(where: { $0.id == entryID })?
            .favorite ?? false
        let updated = LocalLoginEntry(
            id: entryID,
            projectID: projectID,
            title: draft.title,
            username: draft.username,
            password: draft.password,
            url: draft.url,
            favorite: currentFavorite
        )
        updatedLoginEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, draft: draft)
        )
        loginEntries[projectID, default: []] = loginEntries[projectID, default: []].map {
            $0.id == entryID ? updated : $0
        }
        return updated
    }

    func setLoginEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalLoginEntry {
        favoritedLoginEntries.append(
            .init(
                vaultID: handle.vaultID,
                projectID: projectID,
                entryID: entryID,
                favorite: favorite
            )
        )
        guard let current = loginEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let updated = LocalLoginEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            username: current.username,
            password: current.password,
            url: current.url,
            favorite: favorite
        )
        loginEntries[projectID, default: []] = loginEntries[projectID, default: []].map {
            $0.id == entryID ? updated : $0
        }
        return updated
    }

    func deleteLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        deletedLoginEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = loginEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            return
        }
        loginEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedEntries[projectID, default: []].append(entry)
    }

    func listDeletedLoginEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalLoginEntry] {
        deletedEntries[projectID, default: []]
    }

    func restoreLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalLoginEntry {
        restoredLoginEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = deletedEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedEntries[projectID, default: []].removeAll { $0.id == entryID }
        loginEntries[projectID, default: []].append(entry)
        return entry
    }

    func createNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalNoteEntryDraft
    ) throws -> LocalNoteEntry {
        let entry = LocalNoteEntry(
            id: "note-\(createdNoteEntries.count + 1)",
            projectID: projectID,
            title: draft.title,
            body: draft.body
        )
        createdNoteEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, draft: draft)
        )
        noteEntries[projectID, default: []].append(entry)
        return entry
    }

    func listNoteEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalNoteEntry] {
        noteEntries[projectID, default: []]
    }

    func updateNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalNoteEntryDraft
    ) throws -> LocalNoteEntry {
        let currentFavorite = noteEntries[projectID, default: []]
            .first(where: { $0.id == entryID })?
            .favorite ?? false
        let updated = LocalNoteEntry(
            id: entryID,
            projectID: projectID,
            title: draft.title,
            body: draft.body,
            favorite: currentFavorite
        )
        updatedNoteEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, draft: draft)
        )
        noteEntries[projectID, default: []] = noteEntries[projectID, default: []].map {
            $0.id == entryID ? updated : $0
        }
        return updated
    }

    func setNoteEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalNoteEntry {
        favoritedNoteEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, favorite: favorite)
        )
        guard let current = noteEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let updated = LocalNoteEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            body: current.body,
            favorite: favorite
        )
        noteEntries[projectID, default: []] = noteEntries[projectID, default: []].map {
            $0.id == entryID ? updated : $0
        }
        return updated
    }

    func deleteNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        deletedNoteEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = noteEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            return
        }
        noteEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedNotes[projectID, default: []].append(entry)
    }

    func listDeletedNoteEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalNoteEntry] {
        deletedNotes[projectID, default: []]
    }

    func restoreNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalNoteEntry {
        restoredNoteEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = deletedNotes[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedNotes[projectID, default: []].removeAll { $0.id == entryID }
        noteEntries[projectID, default: []].append(entry)
        return entry
    }

    func createTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalTotpEntryDraft
    ) throws -> LocalTotpEntry {
        let entry = LocalTotpEntry(
            id: "totp-\(createdTotpEntries.count + 1)",
            projectID: projectID,
            title: draft.title,
            secret: draft.secret,
            issuer: draft.issuer,
            accountName: draft.accountName,
            period: draft.period,
            digits: draft.digits,
            algorithm: draft.algorithm,
            otpType: draft.otpType,
            counter: draft.counter
        )
        createdTotpEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, draft: draft)
        )
        totpEntries[projectID, default: []].append(entry)
        return entry
    }

    func listTotpEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalTotpEntry] {
        totpEntries[projectID, default: []]
    }

    func updateTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalTotpEntryDraft
    ) throws -> LocalTotpEntry {
        let currentFavorite = totpEntries[projectID, default: []]
            .first(where: { $0.id == entryID })?
            .favorite ?? false
        let updated = LocalTotpEntry(
            id: entryID,
            projectID: projectID,
            title: draft.title,
            secret: draft.secret,
            issuer: draft.issuer,
            accountName: draft.accountName,
            period: draft.period,
            digits: draft.digits,
            algorithm: draft.algorithm,
            otpType: draft.otpType,
            counter: draft.counter,
            favorite: currentFavorite
        )
        updatedTotpEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, draft: draft)
        )
        totpEntries[projectID, default: []] = totpEntries[projectID, default: []].map {
            $0.id == entryID ? updated : $0
        }
        return updated
    }

    func setTotpEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalTotpEntry {
        favoritedTotpEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, favorite: favorite)
        )
        guard let current = totpEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let updated = LocalTotpEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            secret: current.secret,
            issuer: current.issuer,
            accountName: current.accountName,
            period: current.period,
            digits: current.digits,
            algorithm: current.algorithm,
            otpType: current.otpType,
            counter: current.counter,
            favorite: favorite
        )
        totpEntries[projectID, default: []] = totpEntries[projectID, default: []].map {
            $0.id == entryID ? updated : $0
        }
        return updated
    }

    func deleteTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        deletedTotpEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = totpEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            return
        }
        totpEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedTotp[projectID, default: []].append(entry)
    }

    func listDeletedTotpEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalTotpEntry] {
        deletedTotp[projectID, default: []]
    }

    func restoreTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalTotpEntry {
        restoredTotpEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = deletedTotp[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedTotp[projectID, default: []].removeAll { $0.id == entryID }
        totpEntries[projectID, default: []].append(entry)
        return entry
    }

    func createCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalCardEntryDraft
    ) throws -> LocalCardEntry {
        let entry = LocalCardEntry(
            id: "card-\(createdCardEntries.count + 1)",
            projectID: projectID,
            title: draft.title,
            cardholderName: draft.cardholderName,
            number: draft.number,
            expiryMonth: draft.expiryMonth,
            expiryYear: draft.expiryYear,
            cvv: draft.cvv,
            issuer: draft.issuer,
            network: draft.network,
            notes: draft.notes
        )
        createdCardEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, draft: draft)
        )
        cardEntries[projectID, default: []].append(entry)
        return entry
    }

    func listCardEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalCardEntry] {
        cardEntries[projectID, default: []]
    }

    func updateCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalCardEntryDraft
    ) throws -> LocalCardEntry {
        let currentFavorite = cardEntries[projectID, default: []]
            .first(where: { $0.id == entryID })?
            .favorite ?? false
        let updated = LocalCardEntry(
            id: entryID,
            projectID: projectID,
            title: draft.title,
            cardholderName: draft.cardholderName,
            number: draft.number,
            expiryMonth: draft.expiryMonth,
            expiryYear: draft.expiryYear,
            cvv: draft.cvv,
            issuer: draft.issuer,
            network: draft.network,
            notes: draft.notes,
            favorite: currentFavorite
        )
        updatedCardEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, draft: draft)
        )
        cardEntries[projectID, default: []] = cardEntries[projectID, default: []].map {
            $0.id == entryID ? updated : $0
        }
        return updated
    }

    func setCardEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalCardEntry {
        favoritedCardEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, favorite: favorite)
        )
        guard let current = cardEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let updated = LocalCardEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            cardholderName: current.cardholderName,
            number: current.number,
            expiryMonth: current.expiryMonth,
            expiryYear: current.expiryYear,
            cvv: current.cvv,
            issuer: current.issuer,
            network: current.network,
            notes: current.notes,
            favorite: favorite
        )
        cardEntries[projectID, default: []] = cardEntries[projectID, default: []].map {
            $0.id == entryID ? updated : $0
        }
        return updated
    }

    func deleteCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        deletedCardEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = cardEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            return
        }
        cardEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedCards[projectID, default: []].append(entry)
    }

    func listDeletedCardEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalCardEntry] {
        deletedCards[projectID, default: []]
    }

    func restoreCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalCardEntry {
        restoredCardEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = deletedCards[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedCards[projectID, default: []].removeAll { $0.id == entryID }
        cardEntries[projectID, default: []].append(entry)
        return entry
    }

    func createIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalIdentityEntryDraft
    ) throws -> LocalIdentityEntry {
        let entry = LocalIdentityEntry(
            id: "identity-\(createdIdentityEntries.count + 1)",
            projectID: projectID,
            title: draft.title,
            documentType: draft.documentType,
            fullName: draft.fullName,
            documentNumber: draft.documentNumber,
            issuer: draft.issuer,
            country: draft.country,
            issueDate: draft.issueDate,
            expiryDate: draft.expiryDate,
            notes: draft.notes
        )
        createdIdentityEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, draft: draft)
        )
        identityEntries[projectID, default: []].append(entry)
        return entry
    }

    func listIdentityEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalIdentityEntry] {
        identityEntries[projectID, default: []]
    }

    func updateIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalIdentityEntryDraft
    ) throws -> LocalIdentityEntry {
        let currentFavorite = identityEntries[projectID, default: []]
            .first(where: { $0.id == entryID })?
            .favorite ?? false
        let entry = LocalIdentityEntry(
            id: entryID,
            projectID: projectID,
            title: draft.title,
            documentType: draft.documentType,
            fullName: draft.fullName,
            documentNumber: draft.documentNumber,
            issuer: draft.issuer,
            country: draft.country,
            issueDate: draft.issueDate,
            expiryDate: draft.expiryDate,
            notes: draft.notes,
            favorite: currentFavorite
        )
        updatedIdentityEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, draft: draft)
        )
        identityEntries[projectID, default: []] = identityEntries[projectID, default: []].map {
            $0.id == entryID ? entry : $0
        }
        return entry
    }

    func setIdentityEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalIdentityEntry {
        favoritedIdentityEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, favorite: favorite)
        )
        guard let current = identityEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let updated = LocalIdentityEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            documentType: current.documentType,
            fullName: current.fullName,
            documentNumber: current.documentNumber,
            issuer: current.issuer,
            country: current.country,
            issueDate: current.issueDate,
            expiryDate: current.expiryDate,
            notes: current.notes,
            favorite: favorite
        )
        identityEntries[projectID, default: []] = identityEntries[projectID, default: []].map {
            $0.id == entryID ? updated : $0
        }
        return updated
    }

    func deleteIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        deletedIdentityEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = identityEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            return
        }
        identityEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedIdentities[projectID, default: []].append(entry)
    }

    func listDeletedIdentityEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalIdentityEntry] {
        deletedIdentities[projectID, default: []]
    }

    func restoreIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalIdentityEntry {
        restoredIdentityEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = deletedIdentities[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedIdentities[projectID, default: []].removeAll { $0.id == entryID }
        identityEntries[projectID, default: []].append(entry)
        return entry
    }

    func createPasskeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalPasskeyEntryDraft
    ) throws -> LocalPasskeyEntry {
        let entry = LocalPasskeyEntry(
            id: "passkey-\(createdPasskeyEntries.count + 1)",
            projectID: projectID,
            title: draft.title,
            relyingPartyID: draft.relyingPartyID,
            username: draft.username,
            userHandle: draft.userHandle,
            credentialID: draft.credentialID,
            publicKeyCOSE: draft.publicKeyCOSE,
            privateKeyReference: draft.privateKeyReference,
            notes: draft.notes
        )
        createdPasskeyEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, draft: draft)
        )
        passkeyEntries[projectID, default: []].append(entry)
        return entry
    }

    func listPasskeyEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalPasskeyEntry] {
        passkeyEntries[projectID, default: []]
    }

    func updatePasskeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalPasskeyEntryDraft
    ) throws -> LocalPasskeyEntry {
        let currentFavorite = passkeyEntries[projectID, default: []]
            .first(where: { $0.id == entryID })?
            .favorite ?? false
        let updated = LocalPasskeyEntry(
            id: entryID,
            projectID: projectID,
            title: draft.title,
            relyingPartyID: draft.relyingPartyID,
            username: draft.username,
            userHandle: draft.userHandle,
            credentialID: draft.credentialID,
            publicKeyCOSE: draft.publicKeyCOSE,
            privateKeyReference: draft.privateKeyReference,
            notes: draft.notes,
            favorite: currentFavorite
        )
        updatedPasskeyEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, draft: draft)
        )
        passkeyEntries[projectID, default: []] = passkeyEntries[projectID, default: []].map {
            $0.id == entryID ? updated : $0
        }
        return updated
    }

    func setPasskeyEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalPasskeyEntry {
        favoritedPasskeyEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, favorite: favorite)
        )
        guard let current = passkeyEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let updated = LocalPasskeyEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            relyingPartyID: current.relyingPartyID,
            username: current.username,
            userHandle: current.userHandle,
            credentialID: current.credentialID,
            publicKeyCOSE: current.publicKeyCOSE,
            privateKeyReference: current.privateKeyReference,
            notes: current.notes,
            favorite: favorite
        )
        passkeyEntries[projectID, default: []] = passkeyEntries[projectID, default: []].map {
            $0.id == entryID ? updated : $0
        }
        return updated
    }

    func deletePasskeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        deletedPasskeyEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = passkeyEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            return
        }
        passkeyEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedPasskeys[projectID, default: []].append(entry)
    }

    func listDeletedPasskeyEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalPasskeyEntry] {
        deletedPasskeys[projectID, default: []]
    }

    func restorePasskeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalPasskeyEntry {
        restoredPasskeyEntries.append(
            .init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID)
        )
        guard let entry = deletedPasskeys[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedPasskeys[projectID, default: []].removeAll { $0.id == entryID }
        passkeyEntries[projectID, default: []].append(entry)
        return entry
    }

    func createSshKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalSshKeyEntryDraft
    ) throws -> LocalSshKeyEntry {
        let entry = LocalSshKeyEntry(
            id: "ssh-\(createdSshKeyEntries.count + 1)",
            projectID: projectID,
            title: draft.title,
            username: draft.username,
            host: draft.host,
            publicKey: draft.publicKey,
            privateKeyReference: draft.privateKeyReference,
            passphraseHint: draft.passphraseHint,
            notes: draft.notes
        )
        createdSshKeyEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, draft: draft))
        sshKeyEntries[projectID, default: []].append(entry)
        return entry
    }

    func updateSshKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalSshKeyEntryDraft
    ) throws -> LocalSshKeyEntry {
        let currentFavorite = sshKeyEntries[projectID, default: []].first(where: { $0.id == entryID })?.favorite ?? false
        let updated = LocalSshKeyEntry(
            id: entryID,
            projectID: projectID,
            title: draft.title,
            username: draft.username,
            host: draft.host,
            publicKey: draft.publicKey,
            privateKeyReference: draft.privateKeyReference,
            passphraseHint: draft.passphraseHint,
            notes: draft.notes,
            favorite: currentFavorite
        )
        updatedSshKeyEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, draft: draft))
        sshKeyEntries[projectID, default: []] = sshKeyEntries[projectID, default: []].map { $0.id == entryID ? updated : $0 }
        return updated
    }

    func setSshKeyEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalSshKeyEntry {
        favoritedSshKeyEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, favorite: favorite))
        guard let current = sshKeyEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let updated = LocalSshKeyEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            username: current.username,
            host: current.host,
            publicKey: current.publicKey,
            privateKeyReference: current.privateKeyReference,
            passphraseHint: current.passphraseHint,
            notes: current.notes,
            favorite: favorite
        )
        sshKeyEntries[projectID, default: []] = sshKeyEntries[projectID, default: []].map { $0.id == entryID ? updated : $0 }
        return updated
    }

    func deleteSshKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        deletedSshKeyEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID))
        guard let entry = sshKeyEntries[projectID, default: []].first(where: { $0.id == entryID }) else { return }
        sshKeyEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedSshKeys[projectID, default: []].append(entry)
    }

    func restoreSshKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalSshKeyEntry {
        restoredSshKeyEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID))
        guard let entry = deletedSshKeys[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedSshKeys[projectID, default: []].removeAll { $0.id == entryID }
        sshKeyEntries[projectID, default: []].append(entry)
        return entry
    }

    func createApiTokenEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalApiTokenEntryDraft
    ) throws -> LocalApiTokenEntry {
        let entry = LocalApiTokenEntry(
            id: "api-token-\(createdApiTokenEntries.count + 1)",
            projectID: projectID,
            title: draft.title,
            issuer: draft.issuer,
            accountName: draft.accountName,
            token: draft.token,
            scopes: draft.scopes,
            expiresAt: draft.expiresAt,
            notes: draft.notes
        )
        createdApiTokenEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, draft: draft))
        apiTokenEntries[projectID, default: []].append(entry)
        return entry
    }

    func updateApiTokenEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalApiTokenEntryDraft
    ) throws -> LocalApiTokenEntry {
        let currentFavorite = apiTokenEntries[projectID, default: []].first(where: { $0.id == entryID })?.favorite ?? false
        let updated = LocalApiTokenEntry(
            id: entryID,
            projectID: projectID,
            title: draft.title,
            issuer: draft.issuer,
            accountName: draft.accountName,
            token: draft.token,
            scopes: draft.scopes,
            expiresAt: draft.expiresAt,
            notes: draft.notes,
            favorite: currentFavorite
        )
        updatedApiTokenEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, draft: draft))
        apiTokenEntries[projectID, default: []] = apiTokenEntries[projectID, default: []].map { $0.id == entryID ? updated : $0 }
        return updated
    }

    func setApiTokenEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalApiTokenEntry {
        favoritedApiTokenEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, favorite: favorite))
        guard let current = apiTokenEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let updated = LocalApiTokenEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            issuer: current.issuer,
            accountName: current.accountName,
            token: current.token,
            scopes: current.scopes,
            expiresAt: current.expiresAt,
            notes: current.notes,
            favorite: favorite
        )
        apiTokenEntries[projectID, default: []] = apiTokenEntries[projectID, default: []].map { $0.id == entryID ? updated : $0 }
        return updated
    }

    func deleteApiTokenEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        deletedApiTokenEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID))
        guard let entry = apiTokenEntries[projectID, default: []].first(where: { $0.id == entryID }) else { return }
        apiTokenEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedApiTokens[projectID, default: []].append(entry)
    }

    func restoreApiTokenEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalApiTokenEntry {
        restoredApiTokenEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID))
        guard let entry = deletedApiTokens[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedApiTokens[projectID, default: []].removeAll { $0.id == entryID }
        apiTokenEntries[projectID, default: []].append(entry)
        return entry
    }

    func createWifiEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalWifiEntryDraft
    ) throws -> LocalWifiEntry {
        let entry = LocalWifiEntry(
            id: "wifi-\(createdWifiEntries.count + 1)",
            projectID: projectID,
            title: draft.title,
            ssid: draft.ssid,
            securityType: draft.securityType,
            password: draft.password,
            hidden: draft.hidden,
            notes: draft.notes
        )
        createdWifiEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, draft: draft))
        wifiEntries[projectID, default: []].append(entry)
        return entry
    }

    func updateWifiEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalWifiEntryDraft
    ) throws -> LocalWifiEntry {
        let currentFavorite = wifiEntries[projectID, default: []].first(where: { $0.id == entryID })?.favorite ?? false
        let updated = LocalWifiEntry(
            id: entryID,
            projectID: projectID,
            title: draft.title,
            ssid: draft.ssid,
            securityType: draft.securityType,
            password: draft.password,
            hidden: draft.hidden,
            notes: draft.notes,
            favorite: currentFavorite
        )
        updatedWifiEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, draft: draft))
        wifiEntries[projectID, default: []] = wifiEntries[projectID, default: []].map { $0.id == entryID ? updated : $0 }
        return updated
    }

    func setWifiEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalWifiEntry {
        favoritedWifiEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, favorite: favorite))
        guard let current = wifiEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let updated = LocalWifiEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            ssid: current.ssid,
            securityType: current.securityType,
            password: current.password,
            hidden: current.hidden,
            notes: current.notes,
            favorite: favorite
        )
        wifiEntries[projectID, default: []] = wifiEntries[projectID, default: []].map { $0.id == entryID ? updated : $0 }
        return updated
    }

    func deleteWifiEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        deletedWifiEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID))
        guard let entry = wifiEntries[projectID, default: []].first(where: { $0.id == entryID }) else { return }
        wifiEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedWifi[projectID, default: []].append(entry)
    }

    func restoreWifiEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalWifiEntry {
        restoredWifiEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID))
        guard let entry = deletedWifi[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedWifi[projectID, default: []].removeAll { $0.id == entryID }
        wifiEntries[projectID, default: []].append(entry)
        return entry
    }

    func createSendEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalSendEntryDraft
    ) throws -> LocalSendEntry {
        let entry = LocalSendEntry(
            id: "send-\(createdSendEntries.count + 1)",
            projectID: projectID,
            title: draft.title,
            body: draft.body,
            expiresAt: draft.expiresAt,
            maxViews: draft.maxViews,
            notes: draft.notes
        )
        createdSendEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, draft: draft))
        sendEntries[projectID, default: []].append(entry)
        return entry
    }

    func updateSendEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalSendEntryDraft
    ) throws -> LocalSendEntry {
        let currentFavorite = sendEntries[projectID, default: []].first(where: { $0.id == entryID })?.favorite ?? false
        let updated = LocalSendEntry(
            id: entryID,
            projectID: projectID,
            title: draft.title,
            body: draft.body,
            expiresAt: draft.expiresAt,
            maxViews: draft.maxViews,
            notes: draft.notes,
            favorite: currentFavorite
        )
        updatedSendEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, draft: draft))
        sendEntries[projectID, default: []] = sendEntries[projectID, default: []].map { $0.id == entryID ? updated : $0 }
        return updated
    }

    func setSendEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalSendEntry {
        favoritedSendEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID, favorite: favorite))
        guard let current = sendEntries[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let updated = LocalSendEntry(
            id: current.id,
            projectID: current.projectID,
            title: current.title,
            body: current.body,
            expiresAt: current.expiresAt,
            maxViews: current.maxViews,
            notes: current.notes,
            favorite: favorite
        )
        sendEntries[projectID, default: []] = sendEntries[projectID, default: []].map { $0.id == entryID ? updated : $0 }
        return updated
    }

    func deleteSendEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws {
        deletedSendEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID))
        guard let entry = sendEntries[projectID, default: []].first(where: { $0.id == entryID }) else { return }
        sendEntries[projectID, default: []].removeAll { $0.id == entryID }
        deletedSends[projectID, default: []].append(entry)
    }

    func restoreSendEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalSendEntry {
        restoredSendEntries.append(.init(vaultID: handle.vaultID, projectID: projectID, entryID: entryID))
        guard let entry = deletedSends[projectID, default: []].first(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        deletedSends[projectID, default: []].removeAll { $0.id == entryID }
        sendEntries[projectID, default: []].append(entry)
        return entry
    }

    func listSshKeyEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSshKeyEntry] {
        sshKeyEntries[projectID, default: []]
    }

    func listDeletedSshKeyEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSshKeyEntry] {
        deletedSshKeys[projectID, default: []]
    }

    func listApiTokenEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalApiTokenEntry] {
        apiTokenEntries[projectID, default: []]
    }

    func listDeletedApiTokenEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalApiTokenEntry] {
        deletedApiTokens[projectID, default: []]
    }

    func listWifiEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalWifiEntry] {
        wifiEntries[projectID, default: []]
    }

    func listDeletedWifiEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalWifiEntry] {
        deletedWifi[projectID, default: []]
    }

    func listSendEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSendEntry] {
        sendEntries[projectID, default: []]
    }

    func listDeletedSendEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSendEntry] {
        deletedSends[projectID, default: []]
    }

    func createAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String?,
        fileName: String,
        mediaType: String,
        originalSize: Int64,
        storedSize: Int64,
        contentHash: String,
        storageMode: String,
        source: String,
        downloadState: String,
        wrappedContentEncryptionKey: String?,
        localPath: String?
    ) throws -> LocalAttachmentMetadata {
        let metadata = LocalAttachmentMetadata(
            id: "attachment-\(createdAttachmentMetadata.count + 1)",
            projectID: projectID,
            entryID: entryID,
            fileName: fileName,
            mediaType: mediaType,
            originalSize: originalSize,
            storedSize: storedSize,
            contentHash: contentHash,
            storageMode: storageMode,
            source: source,
            downloadState: downloadState,
            wrappedContentEncryptionKey: wrappedContentEncryptionKey,
            localPath: localPath,
            deleted: false
        )
        createdAttachmentMetadata.append(
            .init(
                vaultID: handle.vaultID,
                projectID: projectID,
                entryID: entryID,
                fileName: fileName,
                mediaType: mediaType,
                originalSize: originalSize,
                storedSize: storedSize,
                contentHash: contentHash,
                storageMode: storageMode,
                source: source,
                downloadState: downloadState,
                wrappedContentEncryptionKey: wrappedContentEncryptionKey,
                localPath: localPath
            )
        )
        attachmentMetadata[projectID, default: []].append(metadata)
        return metadata
    }

    func listAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalAttachmentMetadata] {
        attachmentMetadata[projectID, default: []]
    }

    func deleteAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String,
        attachmentID: String
    ) throws {
        guard let index = attachmentMetadata[projectID, default: []].firstIndex(where: { $0.id == attachmentID }) else {
            return
        }
        let removed = attachmentMetadata[projectID, default: []].remove(at: index)
        deletedAttachmentMetadata[projectID, default: []].append(
            LocalAttachmentMetadata(
                id: removed.id,
                projectID: removed.projectID,
                entryID: removed.entryID,
                fileName: removed.fileName,
                mediaType: removed.mediaType,
                originalSize: removed.originalSize,
                storedSize: removed.storedSize,
                contentHash: removed.contentHash,
                storageMode: removed.storageMode,
                source: removed.source,
                downloadState: removed.downloadState,
                wrappedContentEncryptionKey: removed.wrappedContentEncryptionKey,
                localPath: removed.localPath,
                deleted: true
            )
        )
    }

    func listDeletedAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalAttachmentMetadata] {
        deletedAttachmentMetadata[projectID, default: []]
    }

    func restoreAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String,
        attachmentID: String
    ) throws -> LocalAttachmentMetadata {
        guard let index = deletedAttachmentMetadata[projectID, default: []].firstIndex(where: { $0.id == attachmentID }) else {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        let removed = deletedAttachmentMetadata[projectID, default: []].remove(at: index)
        let restored = LocalAttachmentMetadata(
            id: removed.id,
            projectID: removed.projectID,
            entryID: removed.entryID,
            fileName: removed.fileName,
            mediaType: removed.mediaType,
            originalSize: removed.originalSize,
            storedSize: removed.storedSize,
            contentHash: removed.contentHash,
            storageMode: removed.storageMode,
            source: removed.source,
            downloadState: removed.downloadState,
            wrappedContentEncryptionKey: removed.wrappedContentEncryptionKey,
            localPath: removed.localPath,
            deleted: false
        )
        attachmentMetadata[projectID, default: []].append(restored)
        return restored
    }
}

private struct RecordedVaultCall {
    let fileURL: URL
    let password: String
    let deviceID: String
}

private struct RecordedSecurityKeyVaultCall {
    let fileURL: URL
    let keyMaterial: Data
    let deviceID: String
}

private struct RecordedSecurityKeySetupCall {
    let vaultID: String
    let keyMaterial: Data
}

private struct RecordedResetMasterPasswordCall: Equatable {
    let vaultID: String
    let newPassword: String
}

private struct RecordedProjectCall {
    let vaultID: String
    let title: String
}

private struct RecordedLoginEntryCall {
    let vaultID: String
    let projectID: String
    let draft: LocalLoginEntryDraft
}

private struct RecordedUpdatedLoginEntryCall {
    let vaultID: String
    let projectID: String
    let entryID: String
    let draft: LocalLoginEntryDraft
}

private struct RecordedFavoriteEntryCall {
    let vaultID: String
    let projectID: String
    let entryID: String
    let favorite: Bool
}

private struct RecordedNoteEntryCall {
    let vaultID: String
    let projectID: String
    let draft: LocalNoteEntryDraft
}

private struct RecordedUpdatedNoteEntryCall {
    let vaultID: String
    let projectID: String
    let entryID: String
    let draft: LocalNoteEntryDraft
}

private struct RecordedTotpEntryCall {
    let vaultID: String
    let projectID: String
    let draft: LocalTotpEntryDraft
}

private struct RecordedUpdatedTotpEntryCall {
    let vaultID: String
    let projectID: String
    let entryID: String
    let draft: LocalTotpEntryDraft
}

private struct RecordedCardEntryCall {
    let vaultID: String
    let projectID: String
    let draft: LocalCardEntryDraft
}

private struct RecordedUpdatedCardEntryCall {
    let vaultID: String
    let projectID: String
    let entryID: String
    let draft: LocalCardEntryDraft
}

private struct RecordedIdentityEntryCall {
    let vaultID: String
    let projectID: String
    let draft: LocalIdentityEntryDraft
}

private struct RecordedUpdatedIdentityEntryCall {
    let vaultID: String
    let projectID: String
    let entryID: String
    let draft: LocalIdentityEntryDraft
}

private struct RecordedPasskeyEntryCall {
    let vaultID: String
    let projectID: String
    let draft: LocalPasskeyEntryDraft
}

private struct RecordedUpdatedPasskeyEntryCall {
    let vaultID: String
    let projectID: String
    let entryID: String
    let draft: LocalPasskeyEntryDraft
}

private struct RecordedSshKeyEntryCall {
    let vaultID: String
    let projectID: String
    let draft: LocalSshKeyEntryDraft
}

private struct RecordedUpdatedSshKeyEntryCall {
    let vaultID: String
    let projectID: String
    let entryID: String
    let draft: LocalSshKeyEntryDraft
}

private struct RecordedApiTokenEntryCall {
    let vaultID: String
    let projectID: String
    let draft: LocalApiTokenEntryDraft
}

private struct RecordedUpdatedApiTokenEntryCall {
    let vaultID: String
    let projectID: String
    let entryID: String
    let draft: LocalApiTokenEntryDraft
}

private struct RecordedWifiEntryCall {
    let vaultID: String
    let projectID: String
    let draft: LocalWifiEntryDraft
}

private struct RecordedUpdatedWifiEntryCall {
    let vaultID: String
    let projectID: String
    let entryID: String
    let draft: LocalWifiEntryDraft
}

private struct RecordedSendEntryCall {
    let vaultID: String
    let projectID: String
    let draft: LocalSendEntryDraft
}

private struct RecordedUpdatedSendEntryCall {
    let vaultID: String
    let projectID: String
    let entryID: String
    let draft: LocalSendEntryDraft
}

private struct RecordedAttachmentMetadataCall: Equatable {
    let vaultID: String
    let projectID: String
    let entryID: String?
    let fileName: String
    let mediaType: String
    let originalSize: Int64
    let storedSize: Int64
    let contentHash: String
    let storageMode: String
    let source: String
    let downloadState: String
    let wrappedContentEncryptionKey: String?
    let localPath: String?
}

private struct RecordedEntryMutationCall {
    let vaultID: String
    let projectID: String
    let entryID: String
}
