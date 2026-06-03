@testable import Monica
import CryptoKit
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

    func testShortcutEntrySearchSummarizesEntriesAndOpensEditorWithoutLeakingSecrets() throws {
        let model = AppSessionModel(vaultRepository: LocalVaultRepository(engine: RecordingVaultEngine()))

        XCTAssertEqual(model.shortcutEntrySummaries(matching: "github"), [])

        try unlockNewVault(model)
        model.loginTitle = "GitHub"
        model.loginUsername = "alice@example.com"
        model.loginPassword = "github-password-secret"
        model.loginURL = "https://github.com/login"
        try model.createLoginEntry(projectTitle: "Personal")
        model.noteTitle = "GitHub Recovery"
        model.noteBody = "backup-code-secret"
        try model.createNoteEntry(projectTitle: "Personal")
        model.totpTitle = "GitHub TOTP"
        model.totpSecret = "JBSWY3DPEHPK3PXP"
        model.totpIssuer = "GitHub"
        model.totpAccountName = "alice@example.com"
        try model.createTotpEntry(projectTitle: "Personal")

        let summaries = model.shortcutEntrySummaries(matching: "github")

        XCTAssertEqual(summaries.map(\.kind), [.login, .note, .totp])
        XCTAssertEqual(summaries.map(\.title), ["GitHub", "GitHub Recovery", "GitHub TOTP"])
        XCTAssertEqual(summaries.first?.subtitle, "alice@example.com / github.com")
        let visibleShortcutText = summaries
            .map { "\($0.title) \($0.subtitle) \($0.searchableText)" }
            .joined(separator: " ")
        XCTAssertFalse(visibleShortcutText.contains("github-password-secret"))
        XCTAssertFalse(visibleShortcutText.contains("backup-code-secret"))
        XCTAssertFalse(visibleShortcutText.contains("JBSWY3DPEHPK3PXP"))

        try model.openShortcutEntry(summaries[0])

        XCTAssertEqual(model.selectedTab, .passwords)
        XCTAssertEqual(model.presentedEditorMode, .edit(VaultItemRoute(kind: .login, entryID: "entry-1")))
        XCTAssertEqual(model.editingLoginTitle, "GitHub")
    }

    func testShortcutSnapshotStorePersistsAppGroupSafeEntriesWithoutLeakingSecrets() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-shortcuts-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = AppShortcutSnapshotFileStore(containerURL: directory)
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: RecordingVaultEngine()),
            shortcutSnapshotStore: store
        )

        try model.refreshShortcutSnapshotIfConfigured()
        var snapshotText = try String(contentsOf: store.snapshotFileURL, encoding: .utf8)
        XCTAssertTrue(snapshotText.contains("locked"))
        XCTAssertFalse(snapshotText.contains("github-password-secret"))

        try unlockNewVault(model)
        model.loginTitle = "GitHub"
        model.loginUsername = "alice@example.com"
        model.loginPassword = "github-password-secret"
        model.loginURL = "https://github.com/login?token=secret-query"
        try model.createLoginEntry(projectTitle: "Personal")
        model.noteTitle = "GitHub Recovery"
        model.noteBody = "backup-code-secret"
        try model.createNoteEntry(projectTitle: "Personal")
        model.totpTitle = "GitHub TOTP"
        model.totpSecret = "JBSWY3DPEHPK3PXP"
        model.totpIssuer = "GitHub"
        model.totpAccountName = "alice@example.com"
        try model.createTotpEntry(projectTitle: "Personal")

        let snapshot = try store.loadSnapshot()
        XCTAssertEqual(snapshot?.vaultState, .unlocked)
        XCTAssertEqual(snapshot?.entries.map(\.kind), [.login, .note, .totp])
        XCTAssertEqual(snapshot?.entries.first?.title, "GitHub")
        XCTAssertEqual(snapshot?.entries.first?.subtitle, "alice@example.com / github.com")
        XCTAssertEqual(snapshot?.entries.first?.openURL.absoluteString, "monica://shortcut/login/entry-1")

        snapshotText = try String(contentsOf: store.snapshotFileURL, encoding: .utf8)
        XCTAssertFalse(snapshotText.contains("github-password-secret"))
        XCTAssertFalse(snapshotText.contains("secret-query"))
        XCTAssertFalse(snapshotText.contains("backup-code-secret"))
        XCTAssertFalse(snapshotText.contains("JBSWY3DPEHPK3PXP"))
    }

    func testShortcutDeepLinkOpensEntryWithoutLeakingSecrets() throws {
        let model = AppSessionModel(vaultRepository: LocalVaultRepository(engine: RecordingVaultEngine()))
        try unlockNewVault(model)
        model.loginTitle = "GitHub"
        model.loginUsername = "alice@example.com"
        model.loginPassword = "github-password-secret"
        model.loginURL = "https://github.com/login?token=secret-query"
        try model.createLoginEntry(projectTitle: "Personal")

        XCTAssertFalse(model.openShortcutURL(URL(string: "https://github.com/shortcut/login/entry-1")!))
        XCTAssertFalse(model.openShortcutURL(URL(string: "monica://wrong/login/entry-1")!))

        XCTAssertTrue(model.openShortcutURL(URL(string: "monica://shortcut/login/entry-1")!))

        XCTAssertEqual(model.selectedTab, .passwords)
        XCTAssertEqual(model.presentedEditorMode, .edit(VaultItemRoute(kind: .login, entryID: "entry-1")))
        XCTAssertEqual(model.editingLoginTitle, "GitHub")
        XCTAssertEqual(model.editingLoginURL, "https://github.com/login?token=secret-query")
        XCTAssertNotEqual(model.vaultOperationState, .failed("github-password-secret"))
    }

    func testShareActionImportCreatesEntriesAndAttachmentWithoutLeakingSecrets() throws {
        let engine = RecordingVaultEngine()
        let blobStore = RecordingAndroidBackupAttachmentBlobStore()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            androidBackupAttachmentBlobStore: blobStore
        )
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("monica-share-secret.txt")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("shared-file-secret".utf8).write(to: fileURL)

        XCTAssertThrowsError(
            try model.importSharedItems(
                [
                    AppShareImportRequest.url(URL(string: "https://vault.example.com/login?token=secret-query")!),
                    AppShareImportRequest.text("shared note body secret"),
                    AppShareImportRequest.file(url: fileURL, mediaType: "text/plain")
                ],
                projectTitle: "Shared"
            )
        )

        try unlockNewVault(model)
        let result = try model.importSharedItems(
            [
                AppShareImportRequest.url(URL(string: "https://vault.example.com/login?token=secret-query")!),
                AppShareImportRequest.text("shared note body secret"),
                AppShareImportRequest.file(url: fileURL, mediaType: "text/plain")
            ],
            projectTitle: "Shared"
        )

        XCTAssertEqual(result.importedCounts[.login], 1)
        XCTAssertEqual(result.importedCounts[.note], 1)
        XCTAssertEqual(result.importedCounts[.attachmentRef], 1)
        XCTAssertEqual(model.loginEntries.map(\.title), ["vault.example.com"])
        XCTAssertEqual(model.loginEntries.first?.url, "https://vault.example.com/login?token=secret-query")
        XCTAssertEqual(model.noteEntries.map(\.title), ["来自分享的文本"])
        XCTAssertEqual(model.noteEntries.first?.body, "shared note body secret")
        XCTAssertEqual(engine.createdAttachmentMetadata.first?.fileName, "monica-share-secret.txt")
        XCTAssertEqual(engine.createdAttachmentMetadata.first?.source, "ios-share-extension")
        XCTAssertEqual(engine.createdAttachmentMetadata.first?.downloadState, "downloaded")
        XCTAssertEqual(blobStore.savedBlobs.first?.data, Data("shared-file-secret".utf8))
        XCTAssertEqual(model.entryOperationState, .succeeded("Share Extension 已导入 3 项"))

        let userVisibleText = ([model.entryOperationState.label] + model.operationTimelineEvents.map(\.detail))
            .joined(separator: " ")
        XCTAssertFalse(userVisibleText.contains("secret-query"))
        XCTAssertFalse(userVisibleText.contains("shared note body secret"))
        XCTAssertFalse(userVisibleText.contains("shared-file-secret"))
        XCTAssertFalse(userVisibleText.contains(blobStore.savedBlobs.first?.localPath ?? ""))
    }

    func testShareExtensionInboxPersistsImportRequestsWithoutManifestSecrets() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-share-inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let sourceFileURL = directory
            .appendingPathComponent("source", isDirectory: true)
            .appendingPathComponent("monica-shared-secret.txt")
        try FileManager.default.createDirectory(
            at: sourceFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("shared-file-secret".utf8).write(to: sourceFileURL)
        let store = AppShareExtensionInboxStore(containerURL: directory)

        try store.saveIncomingItems(
            [
                .url(URL(string: "https://vault.example.com/login?token=secret-query")!),
                .text("shared note body secret"),
                .file(url: sourceFileURL, mediaType: "text/plain")
            ],
            now: Date(timeIntervalSince1970: 1_803_300_000)
        )

        let manifestText = try String(contentsOf: store.manifestURL, encoding: .utf8)
        XCTAssertFalse(manifestText.contains("secret-query"))
        XCTAssertFalse(manifestText.contains("shared note body secret"))
        XCTAssertFalse(manifestText.contains(sourceFileURL.path))
        XCTAssertFalse(manifestText.contains("shared-file-secret"))

        let requests = try store.loadPendingImportRequests()
        XCTAssertEqual(requests.count, 3)
        guard case .url(let importedURL) = requests[0] else {
            return XCTFail("Expected URL request.")
        }
        XCTAssertEqual(importedURL.absoluteString, "https://vault.example.com/login?token=secret-query")
        guard case .text(let importedText) = requests[1] else {
            return XCTFail("Expected text request.")
        }
        XCTAssertEqual(importedText, "shared note body secret")
        guard case .file(let importedFileURL, let mediaType) = requests[2] else {
            return XCTFail("Expected file request.")
        }
        XCTAssertEqual(mediaType, "text/plain")
        XCTAssertEqual(importedFileURL.lastPathComponent, "monica-shared-secret.txt")
        XCTAssertEqual(try Data(contentsOf: importedFileURL), Data("shared-file-secret".utf8))
    }

    func testShareExtensionInboxImportCreatesEntriesAndClearsPendingRequests() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-share-inbox-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let fileURL = directory
            .appendingPathComponent("source", isDirectory: true)
            .appendingPathComponent("imported-share.txt")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("imported-file-secret".utf8).write(to: fileURL)

        let store = AppShareExtensionInboxStore(containerURL: directory)
        try store.saveIncomingItems(
            [
                .url(URL(string: "https://share.example.com/login?token=secret-query")!),
                .text("shared inbox note"),
                .file(url: fileURL, mediaType: "text/plain")
            ]
        )
        let engine = RecordingVaultEngine()
        let blobStore = RecordingAndroidBackupAttachmentBlobStore()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            androidBackupAttachmentBlobStore: blobStore
        )
        try unlockNewVault(model)

        let result = try model.importPendingShareExtensionItems(
            inboxStore: store,
            projectTitle: "Shared"
        )

        XCTAssertEqual(result.totalCount, 3)
        XCTAssertEqual(model.loginEntries.first?.url, "https://share.example.com/login?token=secret-query")
        XCTAssertEqual(model.noteEntries.first?.body, "shared inbox note")
        XCTAssertEqual(blobStore.savedBlobs.first?.data, Data("imported-file-secret".utf8))
        XCTAssertEqual(try store.loadPendingImportRequests(), [])
    }

    func testWidgetSnapshotSummarizesSafeTotpAndShortcutStateWithoutLeakingSecrets() throws {
        let model = AppSessionModel(vaultRepository: LocalVaultRepository(engine: RecordingVaultEngine()))
        let lockedSnapshot = model.widgetSnapshot(
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(lockedSnapshot.vaultState, .locked)
        XCTAssertTrue(lockedSnapshot.totpItems.isEmpty)
        XCTAssertTrue(lockedSnapshot.shortcutItems.isEmpty)

        try unlockNewVault(model)
        model.loginTitle = "GitHub Login"
        model.loginUsername = "alice@example.com"
        model.loginPassword = "github-login-secret"
        model.loginURL = "https://github.com/login?token=private"
        try model.createLoginEntry(projectTitle: "Personal")
        model.noteTitle = "Recovery Note"
        model.noteBody = "backup-code-secret"
        try model.createNoteEntry(projectTitle: "Personal")
        model.totpTitle = "GitHub TOTP"
        model.totpSecret = "JBSWY3DPEHPK3PXP"
        model.totpIssuer = "GitHub"
        model.totpAccountName = "alice@example.com"
        model.totpPeriod = 30
        try model.createTotpEntry(projectTitle: "Personal")

        let snapshot = model.widgetSnapshot(
            now: Date(timeIntervalSince1970: 1_800_000_017)
        )

        XCTAssertEqual(snapshot.vaultState, .unlocked)
        XCTAssertEqual(snapshot.totalEntryCount, 3)
        XCTAssertEqual(snapshot.totpItems.map(\.title), ["GitHub TOTP"])
        XCTAssertEqual(snapshot.totpItems.first?.issuer, "GitHub")
        XCTAssertEqual(snapshot.totpItems.first?.accountName, "alice@example.com")
        XCTAssertEqual(snapshot.totpItems.first?.secondsRemaining, 13)
        XCTAssertEqual(snapshot.shortcutItems.map(\.kind), [.login, .note, .totp])
        XCTAssertEqual(snapshot.shortcutItems.first?.title, "GitHub Login")

        let widgetText = snapshot.redactedDebugSummary
        XCTAssertFalse(widgetText.contains("github-login-secret"))
        XCTAssertFalse(widgetText.contains("backup-code-secret"))
        XCTAssertFalse(widgetText.contains("JBSWY3DPEHPK3PXP"))
        XCTAssertFalse(widgetText.contains("private"))
        XCTAssertFalse(widgetText.contains(try model.totpCode(for: try XCTUnwrap(model.totpEntries.first))))
    }

    func testWidgetSnapshotStorePersistsAppGroupSafeSnapshotWithoutLeakingSecrets() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-widget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let store = AppWidgetSnapshotFileStore(containerURL: directory)
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: RecordingVaultEngine()),
            widgetSnapshotStore: store
        )

        try model.refreshWidgetSnapshotIfConfigured(now: Date(timeIntervalSince1970: 1_800_000_000))
        let lockedSnapshot = try XCTUnwrap(try store.loadSnapshot())
        XCTAssertEqual(lockedSnapshot.vaultState, .locked)
        XCTAssertTrue(lockedSnapshot.totpItems.isEmpty)
        XCTAssertTrue(lockedSnapshot.shortcutItems.isEmpty)

        try unlockNewVault(model)
        model.loginTitle = "GitHub Login"
        model.loginUsername = "alice@example.com"
        model.loginPassword = "github-login-secret"
        model.loginURL = "https://github.com/login?token=private"
        try model.createLoginEntry(projectTitle: "Personal")
        model.noteTitle = "Recovery Note"
        model.noteBody = "backup-code-secret"
        try model.createNoteEntry(projectTitle: "Personal")
        model.totpTitle = "GitHub TOTP"
        model.totpSecret = "JBSWY3DPEHPK3PXP"
        model.totpIssuer = "GitHub"
        model.totpAccountName = "alice@example.com"
        model.totpPeriod = 30
        try model.createTotpEntry(projectTitle: "Personal")

        try model.refreshWidgetSnapshotIfConfigured(now: Date(timeIntervalSince1970: 1_800_000_017))

        let persistedData = try Data(contentsOf: store.snapshotFileURL)
        let persistedText = String(decoding: persistedData, as: UTF8.self)
        XCTAssertFalse(persistedText.contains("github-login-secret"))
        XCTAssertFalse(persistedText.contains("backup-code-secret"))
        XCTAssertFalse(persistedText.contains("JBSWY3DPEHPK3PXP"))
        XCTAssertFalse(persistedText.contains("private"))
        XCTAssertFalse(persistedText.contains(try model.totpCode(for: try XCTUnwrap(model.totpEntries.first))))

        let snapshot = try XCTUnwrap(try store.loadSnapshot())
        XCTAssertEqual(snapshot.vaultState, .unlocked)
        XCTAssertEqual(snapshot.totalEntryCount, 3)
        XCTAssertEqual(snapshot.totpItems.first?.title, "GitHub TOTP")
        XCTAssertEqual(snapshot.totpItems.first?.secondsRemaining, 13)
        XCTAssertEqual(snapshot.shortcutItems.map(\.kind), [.login, .note, .totp])
    }

    func testPlusResourceButtonActivatesAndroidCompatiblePlusWithoutPurchase() async throws {
        let service = RecordingAppPlusResourceUnlockService()
        let model = AppSessionModel(plusResourceUnlockService: service)
        let now = Date(timeIntervalSince1970: 1_803_100_000)

        XCTAssertEqual(model.plusEntitlementStatusRow.value, "未激活")
        XCTAssertFalse(model.isPlusActive)
        XCTAssertTrue(model.plusFeatureRows.allSatisfy { !$0.isUnlocked })

        try await model.activatePlusFromResource(now: now)

        XCTAssertEqual(service.unlockCallCount, 1)
        XCTAssertEqual(model.plusActivationState, .activated)
        XCTAssertTrue(model.isPlusActive)
        XCTAssertEqual(model.plusEntitlementStatusRow.value, "已激活")
        XCTAssertEqual(model.plusEntitlementStatusRow.detail, "已通过 Android 同口径资源按钮解锁 Monica Plus。")
        XCTAssertEqual(
            model.plusFeatureRows.map(\.id),
            ["premium_themes", "validator_vibration", "copy_next_code", "bitwarden_sync"]
        )
        XCTAssertTrue(model.plusFeatureRows.allSatisfy(\.isUnlocked))
        let visibleText = ([model.plusActivationState.label, model.plusEntitlementStatusRow.detail] + model.plusFeatureRows.map { $0.detail })
            .joined(separator: " ")
        XCTAssertFalse(visibleText.localizedCaseInsensitiveContains("storekit"))
        XCTAssertFalse(visibleText.localizedCaseInsensitiveContains("transaction"))
        XCTAssertFalse(visibleText.contains("resource-secret-token"))
    }

    func testPlusResourceButtonFailureDoesNotUnlockOrLeakSecret() async throws {
        let service = RecordingAppPlusResourceUnlockService()
        service.unlockResult = false
        let model = AppSessionModel(plusResourceUnlockService: service)

        do {
            try await model.activatePlusFromResource()
            XCTFail("Plus resource unlock should fail when the resource grant is rejected.")
        } catch {
            XCTAssertEqual(model.plusActivationState, .failed("Plus 解锁未通过。"))
        }

        XCTAssertEqual(model.plusEntitlementStatusRow.value, "未激活")
        XCTAssertFalse(model.isPlusActive)
        XCTAssertTrue(model.plusFeatureRows.allSatisfy { !$0.isUnlocked })
        XCTAssertFalse(model.plusActivationState.label.contains("resource-secret-token"))
    }

    func testPlusResourceButtonCanDeactivatePlusLocally() async throws {
        let service = RecordingAppPlusResourceUnlockService()
        let model = AppSessionModel(plusResourceUnlockService: service)

        try await model.activatePlusFromResource()
        model.deactivatePlus()

        XCTAssertEqual(model.plusActivationState, .deactivated)
        XCTAssertFalse(model.isPlusActive)
        XCTAssertEqual(model.plusEntitlementStatusRow.value, "未激活")
        XCTAssertTrue(model.plusFeatureRows.allSatisfy { !$0.isUnlocked })
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

    func testVaultDisplayPreferencesPersistAndSummarizeIOSFieldCustomization() throws {
        let store = MemoryVaultDisplayPreferenceStore()
        let model = AppSessionModel(vaultDisplayPreferenceStore: store)

        XCTAssertEqual(model.vaultDisplayPreferences.cardDensity, .comfortable)
        XCTAssertTrue(model.vaultDisplayPreferences.showsLoginUsername)
        XCTAssertTrue(model.vaultDisplayPreferences.showsLoginURL)
        XCTAssertTrue(model.vaultDisplayPreferences.showsTabLabels)

        model.updateVaultDisplayPreferences(
            VaultDisplayPreferences(
                cardDensity: .compact,
                showsLoginUsername: false,
                showsLoginURL: true,
                showsTabLabels: false
            )
        )

        XCTAssertEqual(store.preferences?.cardDensity, .compact)
        XCTAssertEqual(model.vaultDisplayPreferenceRows.map(\.title), ["卡片密度", "账号字段", "网址字段", "底部导航文字"])
        XCTAssertEqual(model.vaultDisplayPreferenceRows.map(\.value), ["紧凑", "隐藏", "显示", "隐藏"])

        let restored = AppSessionModel(vaultDisplayPreferenceStore: store)
        XCTAssertEqual(restored.vaultDisplayPreferences.cardDensity, .compact)
        XCTAssertFalse(restored.vaultDisplayPreferences.showsLoginUsername)
        XCTAssertTrue(restored.vaultDisplayPreferences.showsLoginURL)
        XCTAssertFalse(restored.vaultDisplayPreferences.showsTabLabels)
    }

    func testVaultDisplayPreferencesSurviveVaultLock() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            vaultDisplayPreferenceStore: MemoryVaultDisplayPreferenceStore()
        )

        try unlockNewVault(model)
        model.updateVaultDisplayPreferences(
            VaultDisplayPreferences(
                cardDensity: .compact,
                showsLoginUsername: false,
                showsLoginURL: false,
                showsTabLabels: false
            )
        )

        model.lockLocalVault()

        XCTAssertEqual(model.vaultDisplayPreferences.cardDensity, .compact)
        XCTAssertFalse(model.vaultDisplayPreferences.showsLoginUsername)
        XCTAssertFalse(model.vaultDisplayPreferences.showsLoginURL)
        XCTAssertFalse(model.vaultDisplayPreferences.showsTabLabels)
    }

    func testAppearancePreferencesPersistAndSummarizeIOSThemeCustomization() throws {
        let store = MemoryAppAppearancePreferenceStore()
        let model = AppSessionModel(appearancePreferenceStore: store)

        XCTAssertEqual(model.appearancePreferences.colorScheme, .system)
        XCTAssertEqual(model.appearancePreferences.accentColor, .monica)
        XCTAssertEqual(model.appearancePreferences.passwordListIconStyle, .color)
        XCTAssertNil(model.appearancePreferences.swiftUIColorScheme)

        model.updateAppearancePreferences(
            AppAppearancePreferences(
                colorScheme: .dark,
                accentColor: .blue,
                passwordListIconStyle: .hidden
            )
        )

        XCTAssertEqual(store.preferences?.colorScheme, .dark)
        XCTAssertEqual(model.appearancePreferenceRows.map(\.title), ["颜色模式", "强调色", "密码列表图标"])
        XCTAssertEqual(model.appearancePreferenceRows.map(\.value), ["深色", "蓝色", "隐藏"])
        XCTAssertEqual(model.appearancePreferences.swiftUIColorScheme, .dark)
        XCTAssertEqual(model.appearancePreferences.swiftUIAccentColor, .blue)
        XCTAssertFalse(model.appearancePreferences.showsPasswordListIcon)

        let restored = AppSessionModel(appearancePreferenceStore: store)
        XCTAssertEqual(restored.appearancePreferences.colorScheme, .dark)
        XCTAssertEqual(restored.appearancePreferences.accentColor, .blue)
        XCTAssertEqual(restored.appearancePreferences.passwordListIconStyle, .hidden)
    }

    func testAppearancePreferencesSurviveVaultLock() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            appearancePreferenceStore: MemoryAppAppearancePreferenceStore()
        )

        try unlockNewVault(model)
        model.updateAppearancePreferences(
            AppAppearancePreferences(
                colorScheme: .light,
                accentColor: .green,
                passwordListIconStyle: .monochrome
            )
        )

        model.lockLocalVault()

        XCTAssertEqual(model.appearancePreferences.colorScheme, .light)
        XCTAssertEqual(model.appearancePreferences.accentColor, .green)
        XCTAssertEqual(model.appearancePreferences.passwordListIconStyle, .monochrome)
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
            ["主存储", "MDBX 桥接", "App Group", "本机标识", "AutoFill 索引", "同步日志", "Bitwarden"]
        )
        XCTAssertEqual(rows[0].value, "MDBX")
        XCTAssertEqual(rows[1].value, "UniFFI")
        XCTAssertEqual(rows[2].value, "group.takagi.ru.monica")
        XCTAssertFalse(rows[3].value.contains("secret"))
        XCTAssertEqual(rows[4].value, "未生成")
        XCTAssertEqual(rows[5].value, "空闲")
        XCTAssertEqual(rows[6].value, "就绪")
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

        XCTAssertEqual(rows.map(\.title), ["弱密码", "复用密码", "泄露风险", "重复项"])
        XCTAssertEqual(rows[0].value, "1 项")
        XCTAssertEqual(rows[1].value, "2 项")
        XCTAssertEqual(rows[2].value, "0 项")
        XCTAssertEqual(rows[3].value, "0 项")
        XCTAssertFalse(rows.map(\.detail).joined(separator: " ").contains("short"))
        XCTAssertFalse(rows.map(\.detail).joined(separator: " ").contains("RepeatedStrong1!"))
    }

    func testSecurityCenterSummarizesBreachedPasswordsWithoutLeakingSecrets() {
        let breachedPassword = "KnownBreached1!"
        let model = AppSessionModel()
        model.breachedPasswordSHA256Fingerprints = [Self.sha256Fingerprint(for: breachedPassword)]
        model.loginEntries = [
            LocalLoginEntry(
                id: "login-1",
                projectID: "project-1",
                title: "Leaked",
                username: "alice",
                password: breachedPassword,
                url: "https://leaked.example.com"
            ),
            LocalLoginEntry(
                id: "login-2",
                projectID: "project-1",
                title: "Safe",
                username: "alice",
                password: "UniqueStrong1!",
                url: "https://safe.example.com"
            )
        ]

        let breachedRow = model.securityCenterRows.first { $0.id == "breached-passwords" }

        XCTAssertEqual(breachedRow?.title, "泄露风险")
        XCTAssertEqual(breachedRow?.value, "1 项")
        XCTAssertFalse(breachedRow?.detail.contains(breachedPassword) ?? true)
        XCTAssertFalse(model.securityCenterRows.map(\.detail).joined(separator: " ").contains(breachedPassword))
    }

    func testSecurityCenterBuildsRepairSuggestionsWithoutLeakingSecrets() {
        let breachedPassword = "KnownBreached1!"
        let model = AppSessionModel()
        model.breachedPasswordSHA256Fingerprints = [Self.sha256Fingerprint(for: breachedPassword)]
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
                title: "Leaked",
                username: "alice",
                password: breachedPassword,
                url: "https://leaked.example.com"
            ),
            LocalLoginEntry(
                id: "login-5",
                projectID: "project-1",
                title: " Bank ",
                username: "Alice",
                password: "UniqueStrong1!",
                url: "https://bank.example.com"
            ),
            LocalLoginEntry(
                id: "login-6",
                projectID: "project-1",
                title: "bank",
                username: "alice",
                password: "OtherStrong1!",
                url: " https://bank.example.com "
            )
        ]

        let suggestions = model.securityCenterRepairSuggestions

        XCTAssertEqual(
            suggestions.map(\.id),
            [
                "repair-weak-passwords",
                "repair-reused-passwords",
                "repair-breached-passwords",
                "repair-duplicate-logins"
            ]
        )
        XCTAssertEqual(
            suggestions.map(\.relatedRowID),
            ["weak-passwords", "reused-passwords", "breached-passwords", "duplicate-logins"]
        )
        XCTAssertEqual(suggestions.map(\.title), ["生成强密码", "拆分复用密码", "更换泄露密码", "合并重复项"])
        let text = suggestions.map { "\($0.title) \($0.detail)" }.joined(separator: " ")
        XCTAssertFalse(text.contains("short"))
        XCTAssertFalse(text.contains("RepeatedStrong1!"))
        XCTAssertFalse(text.contains(breachedPassword))
        XCTAssertFalse(text.contains("UniqueStrong1!"))
        XCTAssertFalse(text.contains("OtherStrong1!"))
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

        XCTAssertEqual(rows.map(\.title), ["弱密码", "复用密码", "泄露风险", "重复项"])
        let duplicateRow = rows.first { $0.id == "duplicate-logins" }
        XCTAssertEqual(duplicateRow?.value, "2 项")
        XCTAssertFalse(duplicateRow?.detail.contains("UniqueStrong1!") ?? true)
        XCTAssertFalse(duplicateRow?.detail.contains("OtherStrong1!") ?? true)
    }

    private static func sha256Fingerprint(for value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func testSecurityCenterBuildsDuplicateLoginMergePreviewsWithoutLeakingSecrets() {
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
                title: "Bank",
                username: "alice",
                password: "BankStrong1!",
                url: "https://bank.example.com"
            )
        ]

        let previews = model.duplicateLoginMergePreviews

        XCTAssertEqual(previews.count, 1)
        XCTAssertEqual(previews[0].id, "duplicate-login-login-1")
        XCTAssertEqual(previews[0].title, "GitHub")
        XCTAssertEqual(previews[0].username, "alice")
        XCTAssertEqual(previews[0].url, "https://github.com")
        XCTAssertEqual(previews[0].entryCountLabel, "2 项")
        XCTAssertEqual(previews[0].primaryEntryID, "login-1")
        XCTAssertEqual(previews[0].duplicateEntryIDs, ["login-2"])
        XCTAssertFalse(previews[0].detail.contains("UniqueStrong1!"))
        XCTAssertFalse(previews[0].detail.contains("OtherStrong1!"))
    }

    func testSecurityCenterMergesDuplicateLoginPreviewBySoftDeletingDuplicates() throws {
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

        model.loginTitle = " GitHub "
        model.loginUsername = "Alice"
        model.loginPassword = "UniqueStrong1!"
        model.loginURL = "https://github.com"
        try model.createLoginEntry(projectTitle: "Personal")
        let primary = try XCTUnwrap(model.loginEntries.first)

        model.loginTitle = "github"
        model.loginUsername = "alice"
        model.loginPassword = "OtherStrong1!"
        model.loginURL = " https://github.com "
        try model.createLoginEntry(projectTitle: "Personal")
        let duplicate = try XCTUnwrap(model.loginEntries.first { $0.id != primary.id })

        let preview = try XCTUnwrap(model.duplicateLoginMergePreviews.first)

        try model.mergeDuplicateLoginPreview(preview)

        XCTAssertEqual(model.entryOperationState, .succeeded("已合并 GitHub"))
        XCTAssertEqual(model.loginEntries.map(\.id), [primary.id])
        XCTAssertEqual(model.deletedLoginEntries.map(\.id), [duplicate.id])
        XCTAssertTrue(model.duplicateLoginMergePreviews.isEmpty)
        XCTAssertEqual(model.securityCenterRows.first { $0.id == "duplicate-logins" }?.value, "0 项")
        XCTAssertEqual(engine.deletedLoginEntries.map(\.entryID), [duplicate.id])
        XCTAssertTrue(engine.updatedLoginEntries.isEmpty)
    }

    func testSecurityCenterCanUndoLastDuplicateLoginMerge() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine)
        )

        try unlockNewVault(model)

        model.loginTitle = " GitHub "
        model.loginUsername = "Alice"
        model.loginPassword = "UniqueStrong1!"
        model.loginURL = "https://github.com"
        try model.createLoginEntry(projectTitle: "Personal")
        let primary = try XCTUnwrap(model.loginEntries.first)

        model.loginTitle = "github"
        model.loginUsername = "alice"
        model.loginPassword = "OtherStrong1!"
        model.loginURL = " https://github.com "
        try model.createLoginEntry(projectTitle: "Personal")
        let duplicate = try XCTUnwrap(model.loginEntries.first { $0.id != primary.id })

        let preview = try XCTUnwrap(model.duplicateLoginMergePreviews.first)
        try model.mergeDuplicateLoginPreview(preview)

        XCTAssertTrue(model.canUndoLastDuplicateLoginMerge)
        XCTAssertEqual(model.lastDuplicateLoginMergeUndoTitle, "GitHub")

        try model.undoLastDuplicateLoginMerge()

        XCTAssertEqual(model.entryOperationState, .succeeded("已撤销合并 GitHub"))
        XCTAssertFalse(model.canUndoLastDuplicateLoginMerge)
        XCTAssertNil(model.lastDuplicateLoginMergeUndoTitle)
        XCTAssertEqual(model.loginEntries.map(\.id).sorted(), [primary.id, duplicate.id].sorted())
        XCTAssertTrue(model.deletedLoginEntries.isEmpty)
        XCTAssertEqual(model.duplicateLoginMergePreviews.map(\.id), [preview.id])
        XCTAssertEqual(model.securityCenterRows.first { $0.id == "duplicate-logins" }?.value, "2 项")
        XCTAssertEqual(engine.restoredLoginEntries.map(\.entryID), [duplicate.id])
    }

    func testSecurityCenterCanIgnoreAndRestoreDuplicateLoginPreviews() throws {
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
            )
        ]

        let preview = try XCTUnwrap(model.duplicateLoginMergePreviews.first)

        model.ignoreDuplicateLoginPreview(preview)

        XCTAssertEqual(model.ignoredDuplicateLoginGroupCount, 1)
        XCTAssertTrue(model.duplicateLoginMergePreviews.isEmpty)
        XCTAssertEqual(model.securityCenterRows.first { $0.id == "duplicate-logins" }?.value, "0 项")
        XCTAssertEqual(model.loginEntries.map(\.id), ["login-1", "login-2"])
        XCTAssertTrue(model.deletedLoginEntries.isEmpty)
        XCTAssertFalse(model.securityCenterRows.map(\.detail).joined(separator: " ").contains("UniqueStrong1!"))
        XCTAssertFalse(model.securityCenterRows.map(\.detail).joined(separator: " ").contains("OtherStrong1!"))

        model.clearIgnoredDuplicateLoginPreviews()

        XCTAssertEqual(model.ignoredDuplicateLoginGroupCount, 0)
        XCTAssertEqual(model.duplicateLoginMergePreviews.map(\.id), [preview.id])
        XCTAssertEqual(model.securityCenterRows.first { $0.id == "duplicate-logins" }?.value, "2 项")
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

    func testVaultQuickFiltersSummarizeCurrentCategoryFavoritesAndTrash() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine)
        )

        try unlockNewVault(model)

        model.loginTitle = "GitHub"
        model.loginUsername = "alice"
        model.loginPassword = "github-secret"
        model.loginURL = "https://github.com"
        try model.createLoginEntry(projectTitle: "Personal")
        model.selectLoginEntryForEditing(try XCTUnwrap(model.loginEntries.first))
        try model.setSelectedLoginFavorite(true)

        model.noteEntries = [
            LocalNoteEntry(
                id: "note-1",
                projectID: "project-1",
                title: "Recovery Codes",
                body: "secret",
                favorite: true
            )
        ]
        model.deletedTotpEntries = [
            LocalTotpEntry(
                id: "totp-deleted-1",
                projectID: "project-1",
                title: "Old TOTP",
                secret: "JBSWY3DPEHPK3PXP",
                issuer: "GitHub",
                accountName: "alice",
                period: 30,
                digits: 6,
                algorithm: "SHA1",
                otpType: "TOTP",
                counter: 0,
                favorite: false
            )
        ]
        model.deletedAttachmentEntries = [
            LocalAttachmentMetadata(
                id: "attachment-deleted-1",
                projectID: "project-1",
                entryID: "entry-1",
                fileName: "old-contract.pdf",
                mediaType: "application/pdf",
                originalSize: 100,
                storedSize: 80,
                contentHash: "hash-secret",
                storageMode: "local",
                source: "android-backup-local",
                downloadState: "downloaded",
                wrappedContentEncryptionKey: "wrapped-key",
                localPath: "old-contract.enc",
                deleted: true
            )
        ]

        let rows = model.vaultQuickFilterRows

        XCTAssertEqual(rows.map(\.id), ["all", "category-project-1", "favorites", "trash"])
        XCTAssertEqual(rows.map(\.title), ["全部", "Personal", "收藏", "回收站"])
        XCTAssertEqual(rows.map(\.value), ["2 项", "2 项", "2 项", "2 项"])
        XCTAssertEqual(rows.map(\.systemImage), ["tray.full", "folder", "star", "trash"])
        XCTAssertEqual(rows.map(\.isSelected), [true, false, false, false])

        model.loginSearchQuery = "github"
        model.noteSearchQuery = "recovery"
        model.applyVaultQuickFilter("favorites")

        XCTAssertTrue(model.showFavoriteLoginEntriesOnly)
        XCTAssertTrue(model.showFavoriteNoteEntriesOnly)
        XCTAssertEqual(model.loginSearchQuery, "")
        XCTAssertEqual(model.noteSearchQuery, "")
        XCTAssertEqual(model.vaultQuickFilterRows.map(\.isSelected), [false, false, true, false])

        model.applyVaultQuickFilter("category-project-1")

        XCTAssertFalse(model.showFavoriteLoginEntriesOnly)
        XCTAssertFalse(model.showFavoriteNoteEntriesOnly)
        XCTAssertEqual(model.vaultQuickFilterRows.map(\.isSelected), [false, true, false, false])

        model.applyVaultQuickFilter("trash")

        XCTAssertTrue(model.isTrashQuickFilterSelected)
        XCTAssertTrue(model.filteredLoginEntries.isEmpty)
        XCTAssertTrue(model.filteredNoteEntries.isEmpty)
        XCTAssertEqual(model.deletedTotpEntries.map(\.title), ["Old TOTP"])
        XCTAssertEqual(model.deletedAttachmentEntries.map(\.fileName), ["old-contract.pdf"])
        XCTAssertEqual(model.vaultQuickFilterRows.map(\.isSelected), [false, false, false, true])
    }

    func testVaultQuickFiltersResetWhenVaultLocks() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine)
        )

        try unlockNewVault(model)

        model.loginTitle = "GitHub"
        model.loginUsername = "alice"
        model.loginPassword = "github-secret"
        model.loginURL = "https://github.com"
        try model.createLoginEntry(projectTitle: "Personal")

        model.loginSearchQuery = "git"
        model.noteSearchQuery = "note"
        model.applyVaultQuickFilter("favorites")

        XCTAssertEqual(model.selectedVaultQuickFilterID, "favorites")
        XCTAssertTrue(model.showFavoriteLoginEntriesOnly)

        model.lockLocalVault()

        XCTAssertEqual(model.selectedVaultQuickFilterID, "all")
        XCTAssertEqual(model.loginSearchQuery, "")
        XCTAssertEqual(model.noteSearchQuery, "")
        XCTAssertFalse(model.showFavoriteLoginEntriesOnly)
        XCTAssertFalse(model.showFavoriteNoteEntriesOnly)
        XCTAssertTrue(model.vaultQuickFilterRows.map(\.id).contains("all"))
    }

    func testVaultCategoriesCanBeCreatedRenamedSwitchedAndDeletedWhenEmpty() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine)
        )

        try unlockNewVault(model)

        let personal = try model.createVaultCategory(title: " Personal ")
        model.loginTitle = "GitHub"
        model.loginUsername = "alice"
        model.loginPassword = "github-secret"
        model.loginURL = "https://github.com"
        try model.createLoginEntry(projectTitle: "Personal")
        model.loginSearchQuery = "github"
        model.enterVaultBatchSelection(for: .login)
        model.toggleVaultBatchItemSelection("entry-1", for: .login)

        let clients = try model.createVaultCategory(title: "Clients")

        XCTAssertEqual(model.vaultProjects.map(\.title), ["Personal", "Clients"])
        XCTAssertEqual(model.activeVaultCategoryTitle, "Clients")
        XCTAssertTrue(model.loginEntries.isEmpty)
        XCTAssertEqual(model.loginSearchQuery, "")
        XCTAssertFalse(model.isVaultBatchSelectionActive)

        model.loginTitle = "Client Portal"
        model.loginUsername = "team"
        model.loginPassword = "client-secret"
        model.loginURL = "https://client.example"
        try model.createLoginEntry(projectTitle: "Clients")

        try model.switchVaultCategory(projectID: personal.id)

        XCTAssertEqual(model.activeVaultCategoryTitle, "Personal")
        XCTAssertEqual(model.loginEntries.map(\.title), ["GitHub"])
        XCTAssertEqual(model.vaultQuickFilterRows.map(\.title), ["全部", "Personal", "收藏", "回收站"])

        let renamed = try model.renameVaultCategory(projectID: clients.id, title: " Customers ")
        try model.switchVaultCategory(projectID: renamed.id)

        XCTAssertEqual(model.activeVaultCategoryTitle, "Customers")
        XCTAssertEqual(model.loginEntries.map(\.title), ["Client Portal"])
        XCTAssertEqual(engine.renamedProjects.map(\.title), ["Customers"])

        let empty = try model.createVaultCategory(title: "Archive")
        try model.deleteVaultCategory(projectID: empty.id)

        XCTAssertEqual(model.vaultProjects.map(\.title), ["Personal", "Customers"])
        XCTAssertEqual(engine.deletedProjects.map(\.projectID), [empty.id])

        XCTAssertThrowsError(try model.deleteVaultCategory(projectID: renamed.id)) { error in
            XCTAssertEqual(error as? LocalVaultRepositoryError, .projectNotEmpty)
        }
        XCTAssertEqual(model.vaultProjects.map(\.title), ["Personal", "Customers"])
    }

    func testLoginStackedGroupsSummarizeFilteredEntriesWithoutLeakingPasswords() throws {
        let model = AppSessionModel()
        model.loginEntries = [
            LocalLoginEntry(
                id: "login-1",
                projectID: "project-1",
                title: "GitHub Work",
                username: "alice@example.com",
                password: "github-secret-one",
                url: "https://github.com/org/repo",
                favorite: true
            ),
            LocalLoginEntry(
                id: "login-2",
                projectID: "project-1",
                title: "GitHub Personal",
                username: "alice-personal",
                password: "github-secret-two",
                url: "https://www.github.com/settings"
            ),
            LocalLoginEntry(
                id: "login-3",
                projectID: "project-1",
                title: "Linear",
                username: "product@example.com",
                password: "linear-secret",
                url: "https://linear.app/team"
            ),
            LocalLoginEntry(
                id: "login-4",
                projectID: "project-1",
                title: "银行账户",
                username: "primary",
                password: "bank-secret",
                url: ""
            )
        ]

        let groups = model.loginStackedGroups

        XCTAssertEqual(groups.map(\.title), ["github.com", "linear.app", "银行账户"])
        XCTAssertEqual(groups.first?.value, "2 项")
        XCTAssertEqual(groups.first?.entryIDs, ["login-1", "login-2"])
        XCTAssertEqual(groups.first?.preview, "GitHub Work / GitHub Personal")
        XCTAssertFalse(groups.map(\.detail).joined().contains("github-secret"))
        XCTAssertFalse(groups.map(\.preview).joined().contains("linear-secret"))

        model.loginSearchQuery = "linear"
        XCTAssertEqual(model.loginStackedGroups.map(\.title), ["linear.app"])

        model.loginSearchQuery = ""
        model.showFavoriteLoginEntriesOnly = true
        XCTAssertEqual(model.loginStackedGroups.map(\.title), ["github.com"])
        XCTAssertEqual(model.loginStackedGroups.first?.entryIDs, ["login-1"])
    }

    func testLoginStackedGroupModeResetsWhenVaultLocks() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine)
        )

        try unlockNewVault(model)

        model.isLoginStackedGroupModeEnabled = true
        model.loginSearchQuery = "github"
        model.lockLocalVault()

        XCTAssertFalse(model.isLoginStackedGroupModeEnabled)
        XCTAssertTrue(model.loginStackedGroups.isEmpty)
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

    func testBatchSelectionDeletesAndRestoresCurrentFilteredLoginEntries() throws {
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
        model.loginTitle = "GitLab"
        model.loginUsername = "alice"
        model.loginPassword = "gitlab-secret"
        model.loginURL = "https://gitlab.com"
        try model.createLoginEntry(projectTitle: "Personal")
        model.loginTitle = "Bank"
        model.loginUsername = "alice"
        model.loginPassword = "bank-secret"
        model.loginURL = "https://bank.example"
        try model.createLoginEntry(projectTitle: "Personal")

        model.loginSearchQuery = "git"
        model.enterVaultBatchSelection(for: .login)
        model.selectAllVisibleVaultBatchItems(for: .login)

        XCTAssertEqual(model.vaultBatchSelectionTitle, "已选择 2 项")
        XCTAssertEqual(model.selectedVaultBatchItemIDs.sorted(), ["entry-1", "entry-2"])
        XCTAssertTrue(model.canDeleteSelectedVaultBatchItems)
        XCTAssertFalse(model.canRestoreSelectedVaultBatchItems)

        try model.deleteSelectedVaultBatchItems()

        XCTAssertEqual(model.loginEntries.map(\.title), ["Bank"])
        XCTAssertEqual(model.deletedLoginEntries.map(\.title), ["GitHub", "GitLab"])
        XCTAssertEqual(engine.deletedLoginEntries.map(\.entryID), ["entry-1", "entry-2"])
        XCTAssertFalse(model.isVaultBatchSelectionActive)
        XCTAssertEqual(model.entryOperationState, .succeeded("已删除 2 项"))
        XCTAssertEqual(model.operationTimelineEvents.prefix(2).map(\.action), [.deleted, .deleted])
        XCTAssertFalse(model.operationTimelineEvents.map(\.detail).joined().contains("github-secret"))

        model.applyVaultQuickFilter("trash")
        model.enterVaultBatchSelection(for: .login)
        model.selectAllVisibleVaultBatchItems(for: .login)

        XCTAssertEqual(model.selectedVaultBatchItemIDs.sorted(), ["entry-1", "entry-2"])
        XCTAssertFalse(model.canDeleteSelectedVaultBatchItems)
        XCTAssertTrue(model.canRestoreSelectedVaultBatchItems)

        try model.restoreSelectedVaultBatchItems()

        XCTAssertEqual(model.loginEntries.map(\.title), ["Bank", "GitHub", "GitLab"])
        XCTAssertTrue(model.deletedLoginEntries.isEmpty)
        XCTAssertEqual(engine.restoredLoginEntries.map(\.entryID), ["entry-1", "entry-2"])
        XCTAssertFalse(model.isVaultBatchSelectionActive)
        XCTAssertEqual(model.entryOperationState, .succeeded("已恢复 2 项"))
    }

    func testBatchSelectionMovesCurrentFilteredLoginEntriesToTargetCategory() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine)
        )

        try unlockNewVault(model)
        let personal = try model.createVaultCategory(title: "Personal")
        let work = try model.createVaultCategory(title: "Work")
        try model.switchVaultCategory(projectID: personal.id)

        model.loginTitle = "GitHub"
        model.loginUsername = "alice"
        model.loginPassword = "github-secret"
        model.loginURL = "https://github.com"
        try model.createLoginEntry(projectTitle: "Personal")
        model.loginTitle = "GitLab"
        model.loginUsername = "alice"
        model.loginPassword = "gitlab-secret"
        model.loginURL = "https://gitlab.com"
        try model.createLoginEntry(projectTitle: "Personal")
        model.loginTitle = "Bank"
        model.loginUsername = "alice"
        model.loginPassword = "bank-secret"
        model.loginURL = "https://bank.example"
        try model.createLoginEntry(projectTitle: "Personal")

        model.loginSearchQuery = "git"
        model.enterVaultBatchSelection(for: .login)
        model.selectAllVisibleVaultBatchItems(for: .login)

        XCTAssertTrue(model.canMoveSelectedVaultBatchItems)
        XCTAssertEqual(model.availableVaultBatchMoveTargets.map(\.id), [work.id])

        try model.moveSelectedVaultBatchItems(toProjectID: work.id)

        XCTAssertEqual(model.loginEntries.map(\.title), ["Bank"])
        XCTAssertFalse(model.isVaultBatchSelectionActive)
        XCTAssertEqual(model.loginSearchQuery, "")
        XCTAssertEqual(model.entryOperationState, .succeeded("已移动 2 项"))
        XCTAssertEqual(engine.movedVaultEntries.map(\.entryID), ["entry-1", "entry-2"])
        XCTAssertEqual(engine.movedVaultEntries.map(\.toProjectID), [work.id, work.id])
        XCTAssertEqual(model.operationTimelineEvents.prefix(2).map(\.action), [.moved, .moved])
        XCTAssertFalse(model.operationTimelineEvents.map(\.detail).joined().contains("github-secret"))

        try model.switchVaultCategory(projectID: work.id)

        XCTAssertEqual(model.loginEntries.map(\.id), ["entry-1", "entry-2"])
        XCTAssertEqual(model.loginEntries.map(\.projectID), [work.id, work.id])
    }

    func testBatchSelectionResetsWhenVaultLocks() throws {
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

        model.enterVaultBatchSelection(for: .login)
        model.toggleVaultBatchItemSelection(id: "entry-1")

        model.lockLocalVault()

        XCTAssertFalse(model.isVaultBatchSelectionActive)
        XCTAssertTrue(model.selectedVaultBatchItemIDs.isEmpty)
        XCTAssertEqual(model.vaultBatchSelectionTitle, "未选择")
    }

    func testLoginEntryOperationsAppendRedactedTimelineEvents() throws {
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
        model.editingLoginTitle = "GitHub Main"
        model.editingLoginPassword = "new secret value"
        try model.updateSelectedLoginEntry()
        let updated = try XCTUnwrap(model.loginEntries.first)

        model.selectLoginEntryForEditing(updated)
        try model.deleteSelectedLoginEntry()
        let deleted = try XCTUnwrap(model.deletedLoginEntries.first)
        try model.restoreLoginEntry(deleted)

        let events = model.operationTimelineEvents

        XCTAssertEqual(events.map(\.action), [.restored, .deleted, .updated, .created])
        XCTAssertEqual(events.map(\.itemKind), [.login, .login, .login, .login])
        XCTAssertEqual(events.map(\.itemTitle), ["GitHub Main", "GitHub Main", "GitHub Main", "GitHub"])
        XCTAssertEqual(events.map(\.itemID), [created.id, created.id, created.id, created.id])
        XCTAssertTrue(events.allSatisfy { $0.occurredAt > Date(timeIntervalSince1970: 0) })

        let timelineText = events.map { "\($0.title) \($0.detail)" }.joined(separator: " ")
        XCTAssertFalse(timelineText.contains("correct horse battery staple"))
        XCTAssertFalse(timelineText.contains("new secret value"))
        XCTAssertFalse(timelineText.contains("alice"))
    }

    func testCoreEntryOperationsAppendRedactedTimelineEvents() throws {
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
        let createdNote = try XCTUnwrap(model.noteEntries.first)
        model.selectNoteEntryForEditing(createdNote)
        model.editingNoteTitle = "Recovery Codes Main"
        model.editingNoteBody = "rotated note body secret"
        try model.updateSelectedNoteEntry()
        try model.deleteSelectedNoteEntry()
        try model.restoreNoteEntry(try XCTUnwrap(model.deletedNoteEntries.first))

        model.totpTitle = "GitHub TOTP"
        model.totpSecret = "JBSWY3DPEHPK3PXP"
        model.totpIssuer = "GitHub"
        model.totpAccountName = "alice@example.com"
        try model.createTotpEntry(projectTitle: "Personal")
        let createdTotp = try XCTUnwrap(model.totpEntries.first)
        model.selectTotpEntryForEditing(createdTotp)
        model.editingTotpTitle = "GitHub Work TOTP"
        model.editingTotpSecret = "JBSWY3DPEHPK3PXQ"
        try model.updateSelectedTotpEntry()
        try model.deleteSelectedTotpEntry()
        try model.restoreTotpEntry(try XCTUnwrap(model.deletedTotpEntries.first))

        model.cardTitle = "Everyday Visa"
        model.cardholderName = "Alice Example"
        model.cardNumber = "4111111111111111"
        model.cardExpiryMonth = "12"
        model.cardExpiryYear = "2031"
        model.cardCVV = "123"
        try model.createCardEntry(projectTitle: "Personal")
        let createdCard = try XCTUnwrap(model.cardEntries.first)
        model.selectCardEntryForEditing(createdCard)
        model.editingCardTitle = "Travel Mastercard"
        model.editingCardNumber = "5555555555554444"
        model.editingCardCVV = "456"
        try model.updateSelectedCardEntry()
        try model.deleteSelectedCardEntry()
        try model.restoreCardEntry(try XCTUnwrap(model.deletedCardEntries.first))

        model.identityTitle = "Passport"
        model.identityDocumentType = "passport"
        model.identityFullName = "Alice Example"
        model.identityDocumentNumber = "P1234567"
        try model.createIdentityEntry(projectTitle: "Personal")
        let createdIdentity = try XCTUnwrap(model.identityEntries.first)
        model.selectIdentityEntryForEditing(createdIdentity)
        model.editingIdentityTitle = "Driver License"
        model.editingIdentityDocumentNumber = "D7654321"
        try model.updateSelectedIdentityEntry()
        try model.deleteSelectedIdentityEntry()
        try model.restoreIdentityEntry(try XCTUnwrap(model.deletedIdentityEntries.first))

        let events = model.operationTimelineEvents

        XCTAssertEqual(events.map(\.action), [
            .restored, .deleted, .updated, .created,
            .restored, .deleted, .updated, .created,
            .restored, .deleted, .updated, .created,
            .restored, .deleted, .updated, .created
        ])
        XCTAssertEqual(events.map(\.itemKind), [
            .identity, .identity, .identity, .identity,
            .card, .card, .card, .card,
            .totp, .totp, .totp, .totp,
            .note, .note, .note, .note
        ])
        XCTAssertEqual(events.map(\.itemTitle), [
            "Driver License", "Driver License", "Driver License", "Passport",
            "Travel Mastercard", "Travel Mastercard", "Travel Mastercard", "Everyday Visa",
            "GitHub Work TOTP", "GitHub Work TOTP", "GitHub Work TOTP", "GitHub TOTP",
            "Recovery Codes Main", "Recovery Codes Main", "Recovery Codes Main", "Recovery Codes"
        ])
        XCTAssertTrue(events.allSatisfy { $0.occurredAt > Date(timeIntervalSince1970: 0) })

        let timelineText = events.map { "\($0.title) \($0.detail)" }.joined(separator: " ")
        [
            "github: 123456",
            "rotated note body secret",
            "JBSWY3DPEHPK3PXP",
            "JBSWY3DPEHPK3PXQ",
            "alice@example.com",
            "4111111111111111",
            "5555555555554444",
            "123",
            "456",
            "P1234567",
            "D7654321"
        ].forEach { secret in
            XCTAssertFalse(timelineText.contains(secret))
        }
    }

    func testExtendedEntryOperationsAppendRedactedTimelineEvents() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(vaultRepository: LocalVaultRepository(engine: engine))

        try unlockNewVault(model)

        model.passkeyTitle = "Joyin"
        model.passkeyRelyingPartyID = "github.com"
        model.passkeyUsername = "joyin"
        model.passkeyUserHandle = "github-user-handle"
        model.passkeyCredentialID = "credential-1"
        model.passkeyPublicKeyCOSE = "public-key-cose"
        model.passkeyPrivateKeyReference = "keychain://passkeys/github/credential-1"
        try model.createPasskeyEntry(projectTitle: "Personal")
        let createdPasskey = try XCTUnwrap(model.passkeyEntries.first)
        model.selectPasskeyEntryForEditing(createdPasskey)
        model.editingPasskeyTitle = "Joyin Work"
        model.editingPasskeyUsername = "joyin@example.com"
        model.editingPasskeyUserHandle = "github-work-user-handle"
        model.editingPasskeyCredentialID = "credential-2"
        model.editingPasskeyPublicKeyCOSE = "rotated-public-key-cose"
        model.editingPasskeyPrivateKeyReference = "keychain://passkeys/github/credential-2"
        try model.updateSelectedPasskeyEntry()
        try model.deleteSelectedPasskeyEntry()
        try model.restorePasskeyEntry(try XCTUnwrap(model.deletedPasskeyEntries.first))

        model.sshKeyTitle = "Production deploy key"
        model.sshKeyUsername = "deploy"
        model.sshKeyHost = "prod.example.com"
        model.sshKeyPublicKey = "ssh-ed25519 AAAA"
        model.sshKeyPrivateKeyReference = "keychain://ssh/prod"
        model.sshKeyPassphraseHint = "hardware key"
        try model.createSshKeyEntry(projectTitle: "Personal")
        let createdSshKey = try XCTUnwrap(model.sshKeyEntries.first)
        model.selectSshKeyEntryForEditing(createdSshKey)
        model.editingSshKeyTitle = "Production deploy key rotated"
        model.editingSshKeyHost = "prod.internal.example.com"
        model.editingSshKeyPublicKey = "ssh-ed25519 BBBB"
        model.editingSshKeyPrivateKeyReference = "keychain://ssh/prod-rotated"
        try model.updateSelectedSshKeyEntry()
        try model.deleteSelectedSshKeyEntry()
        try model.restoreSshKeyEntry(try XCTUnwrap(model.deletedSshKeyEntries.first))

        model.apiTokenTitle = "Tiga API token"
        model.apiTokenIssuer = "Tiga"
        model.apiTokenAccountName = "joyin"
        model.apiTokenToken = "sk-secret"
        model.apiTokenScopes = "sync,read"
        try model.createApiTokenEntry(projectTitle: "Personal")
        let createdApiToken = try XCTUnwrap(model.apiTokenEntries.first)
        model.selectApiTokenEntryForEditing(createdApiToken)
        model.editingApiTokenTitle = "Tiga write token"
        model.editingApiTokenAccountName = "joyin@example.com"
        model.editingApiTokenToken = "sk-rotated"
        model.editingApiTokenScopes = "sync,write"
        try model.updateSelectedApiTokenEntry()
        try model.deleteSelectedApiTokenEntry()
        try model.restoreApiTokenEntry(try XCTUnwrap(model.deletedApiTokenEntries.first))

        model.wifiTitle = "Studio Wi-Fi"
        model.wifiSSID = "Monica Studio"
        model.wifiSecurityType = "WPA2"
        model.wifiPassword = "wifi-secret"
        try model.createWifiEntry(projectTitle: "Personal")
        let createdWifi = try XCTUnwrap(model.wifiEntries.first)
        model.selectWifiEntryForEditing(createdWifi)
        model.editingWifiTitle = "Studio Wi-Fi 6"
        model.editingWifiSSID = "Monica Studio 6"
        model.editingWifiSecurityType = "WPA3"
        model.editingWifiPassword = "rotated-wifi-secret"
        try model.updateSelectedWifiEntry()
        try model.deleteSelectedWifiEntry()
        try model.restoreWifiEntry(try XCTUnwrap(model.deletedWifiEntries.first))

        model.sendTitle = "One-time send"
        model.sendBody = "share once"
        model.sendExpiresAt = "2026-06-02"
        model.sendMaxViews = 1
        try model.createSendEntry(projectTitle: "Personal")
        let createdSend = try XCTUnwrap(model.sendEntries.first)
        model.selectSendEntryForEditing(createdSend)
        model.editingSendTitle = "One-time send rotated"
        model.editingSendBody = "share twice"
        model.editingSendMaxViews = 2
        try model.updateSelectedSendEntry()
        try model.deleteSelectedSendEntry()
        try model.restoreSendEntry(try XCTUnwrap(model.deletedSendEntries.first))

        let events = model.operationTimelineEvents

        XCTAssertEqual(events.map(\.action), [
            .restored, .deleted, .updated, .created,
            .restored, .deleted, .updated, .created,
            .restored, .deleted, .updated, .created,
            .restored, .deleted, .updated, .created,
            .restored, .deleted, .updated, .created
        ])
        XCTAssertEqual(events.map(\.itemKind), [
            .send, .send, .send, .send,
            .wifi, .wifi, .wifi, .wifi,
            .apiToken, .apiToken, .apiToken, .apiToken,
            .sshKey, .sshKey, .sshKey, .sshKey,
            .passkey, .passkey, .passkey, .passkey
        ])
        XCTAssertEqual(events.map(\.itemTitle), [
            "One-time send rotated", "One-time send rotated", "One-time send rotated", "One-time send",
            "Studio Wi-Fi 6", "Studio Wi-Fi 6", "Studio Wi-Fi 6", "Studio Wi-Fi",
            "Tiga write token", "Tiga write token", "Tiga write token", "Tiga API token",
            "Production deploy key rotated", "Production deploy key rotated", "Production deploy key rotated", "Production deploy key",
            "Joyin Work", "Joyin Work", "Joyin Work", "Joyin"
        ])

        let timelineText = events.map { "\($0.title) \($0.detail)" }.joined(separator: " ")
        [
            "joyin@example.com",
            "github-user-handle",
            "github-work-user-handle",
            "credential-1",
            "credential-2",
            "public-key-cose",
            "rotated-public-key-cose",
            "keychain://passkeys/github/credential-1",
            "keychain://passkeys/github/credential-2",
            "ssh-ed25519 AAAA",
            "ssh-ed25519 BBBB",
            "keychain://ssh/prod",
            "keychain://ssh/prod-rotated",
            "sk-secret",
            "sk-rotated",
            "sync,read",
            "sync,write",
            "wifi-secret",
            "rotated-wifi-secret",
            "share once",
            "share twice"
        ].forEach { secret in
            XCTAssertFalse(timelineText.contains(secret))
        }
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

    func testKeePassImportPreviewDetectsKdbxWithoutWritingVault() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(vaultRepository: LocalVaultRepository(engine: engine))
        let kdbx = Data([
            0x03, 0xD9, 0xA2, 0x9A,
            0x67, 0xFB, 0x4B, 0xB5,
            0x00, 0x00, 0x04, 0x00
        ])

        try unlockNewVault(model)
        let preview = try model.previewKeePassImport(kdbx, fileName: "personal.kdbx")

        XCTAssertEqual(preview.format, .kdbx)
        XCTAssertEqual(preview.status, .requiresCredentials)
        XCTAssertNil(preview.issue)
        XCTAssertNil(model.csvImportPreview)
        XCTAssertNil(model.androidBackupImportPreview)
        XCTAssertTrue(model.loginEntries.isEmpty)
        XCTAssertTrue(engine.createdLoginEntries.isEmpty)
        XCTAssertEqual(model.entryOperationState, .succeeded("KeePass 预览：KDBX 数据库，等待密码或密钥文件解锁"))
    }

    func testKeePassImportPreviewCarriesPublicCryptoSummaryWithoutLeakingSecrets() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(vaultRepository: LocalVaultRepository(engine: engine))
        let kdbx = makeKdbx4Header(
            cipherID: Data([0x31, 0xC1, 0xF2, 0xE6, 0xBF, 0x71, 0x43, 0x50, 0xBE, 0x58, 0x05, 0x21, 0x6A, 0xFC, 0x5A, 0xFF]),
            compressionFlags: Data([0x01, 0x00, 0x00, 0x00]),
            kdfParameters: makeKdbxVariantDictionary(
                uuid: Data([0x9E, 0x29, 0x8B, 0x19, 0x56, 0xDB, 0x47, 0x73, 0xB2, 0x3D, 0xFC, 0x3E, 0xC6, 0xF0, 0xA1, 0xE6])
            )
        )

        try unlockNewVault(model)
        let preview = try model.previewKeePassImport(kdbx, fileName: "personal.kdbx")

        XCTAssertEqual(preview.headerSummary?.cryptoSummary?.displaySummary, "AES-256，GZip，Argon2id")
        XCTAssertTrue(engine.createdLoginEntries.isEmpty)
        XCTAssertFalse(preview.headerSummary!.cryptoSummary!.displaySummary.contains("database-password"))
        XCTAssertFalse(preview.headerSummary!.cryptoSummary!.displaySummary.contains("key-file-secret"))
    }

    func testKeePassImportPreviewRejectsLegacyKdbWithReadableMessage() throws {
        let model = AppSessionModel(vaultRepository: LocalVaultRepository(engine: RecordingVaultEngine()))
        let legacyKdb = Data([
            0x03, 0xD9, 0xA2, 0x9A,
            0x65, 0xFB, 0x4B, 0xB5
        ])

        try unlockNewVault(model)

        XCTAssertThrowsError(try model.previewKeePassImport(legacyKdb, fileName: "old.kdb"))
        XCTAssertNil(model.keePassImportPreview)
        XCTAssertEqual(
            model.entryOperationState,
            .failed("检测到旧版 .kdb（KeePass 1.x）数据库，当前仅支持 .kdbx。请先在 KeePassDX/KeePassXC 中另存为 .kdbx 后再导入。")
        )
    }

    func testKeePassUnlockPreflightAcceptsPasswordAndKeyFileWithoutWritingVaultOrLeakingSecrets() throws {
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(vaultRepository: LocalVaultRepository(engine: engine))
        let kdbx = Data([
            0x03, 0xD9, 0xA2, 0x9A,
            0x67, 0xFB, 0x4B, 0xB5,
            0x00, 0x00, 0x04, 0x00
        ])
        let keyFile = Data("key-file-secret".utf8)

        try unlockNewVault(model)
        _ = try model.previewKeePassImport(kdbx, fileName: "personal.kdbx")

        XCTAssertThrowsError(
            try model.prepareKeePassUnlockPreflight(password: "   ", keyFile: nil, keyFileName: nil)
        )
        XCTAssertEqual(model.entryOperationState, .failed("请输入数据库密码或选择密钥文件"))

        let preflight = try model.prepareKeePassUnlockPreflight(
            password: "database-password",
            keyFile: keyFile,
            keyFileName: "../personal.key"
        )

        XCTAssertEqual(preflight.status, .readyToUnlock)
        XCTAssertEqual(preflight.credentials.keyFileName, "personal.key")
        XCTAssertEqual(preflight.headerSummary?.displayName, "KDBX 4")
        XCTAssertEqual(model.keePassImportPreview?.unlockPreflight?.status, .readyToUnlock)
        XCTAssertEqual(model.keePassKeyFileName, "personal.key")
        XCTAssertTrue(engine.createdLoginEntries.isEmpty)
        XCTAssertFalse(model.entryOperationState.label.contains("database-password"))
        XCTAssertFalse(model.entryOperationState.label.contains("key-file-secret"))
        XCTAssertEqual(
            model.entryOperationState,
            .succeeded("KeePass 解锁输入已准备：KDBX 4，密码 + 密钥文件（3 种 key 解析）")
        )
    }

    func testKeePassReadOnlyTreePreviewUsesInjectedReaderWithoutWritingVaultOrLeakingSecrets() throws {
        let engine = RecordingVaultEngine()
        let reader = RecordingKeePassDatabaseReader(
            snapshot: KeePassReadOnlySnapshot(
                sourceName: "personal.kdbx",
                headerSummary: KeePassHeaderSummary(majorVersion: 4, minorVersion: 0, formatVersion: .kdbx4),
                groups: [
                    KeePassReadOnlyGroup(id: "root", title: "Root", path: "/", depth: 0),
                    KeePassReadOnlyGroup(id: "work", title: "Work", path: "/Work", depth: 1)
                ],
                entries: [
                    KeePassReadOnlyEntry(
                        id: "entry-1",
                        title: "GitHub",
                        username: "alice",
                        url: "https://github.com",
                        groupPath: "/Work",
                        hasPassword: true,
                        hasTotp: false,
                        attachmentCount: 0,
                        isDeleted: false
                    )
                ]
            )
        )
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            keePassDatabaseReader: reader
        )
        let kdbx = Data([
            0x03, 0xD9, 0xA2, 0x9A,
            0x67, 0xFB, 0x4B, 0xB5,
            0x00, 0x00, 0x04, 0x00
        ])

        try unlockNewVault(model)
        _ = try model.previewKeePassImport(kdbx, fileName: "personal.kdbx")
        _ = try model.prepareKeePassUnlockPreflight(
            password: "database-password",
            keyFile: Data("key-file-secret".utf8),
            keyFileName: "personal.key"
        )

        let snapshot = try model.previewKeePassReadOnlyTree()

        XCTAssertEqual(snapshot.groupCount, 2)
        XCTAssertEqual(snapshot.entryCount, 1)
        XCTAssertEqual(model.keePassReadOnlySnapshot?.displaySummary, "KDBX 4，2 个分组，1 个条目")
        XCTAssertEqual(reader.requests.count, 1)
        XCTAssertEqual(reader.requests.first?.sourceName, "personal.kdbx")
        XCTAssertTrue(reader.requests.first?.credentials.hasPassword == true)
        XCTAssertEqual(reader.requests.first?.credentials.candidateLabel, "password-only")
        XCTAssertTrue(reader.requests.first?.credentials.hasKeyFile == false)
        XCTAssertTrue(engine.createdLoginEntries.isEmpty)
        XCTAssertFalse(model.entryOperationState.label.contains("database-password"))
        XCTAssertFalse(model.entryOperationState.label.contains("a2V5LWZpbGUtc2VjcmV0"))
        XCTAssertEqual(model.entryOperationState, .succeeded("KeePass 只读预览：KDBX 4，2 个分组，1 个条目"))
    }

    func testKeePassReadOnlyTreePreviewAttemptsCredentialCandidatesWithoutLeakingInvalidSecrets() throws {
        let engine = RecordingVaultEngine()
        let reader = RecordingKeePassDatabaseReader(
            snapshot: KeePassReadOnlySnapshot(
                sourceName: "personal.kdbx",
                headerSummary: KeePassHeaderSummary(majorVersion: 4, minorVersion: 0, formatVersion: .kdbx4),
                groups: [],
                entries: [
                    KeePassReadOnlyEntry(
                        id: "entry-1",
                        title: "GitHub",
                        username: "alice",
                        url: "https://github.com",
                        groupPath: "/",
                        hasPassword: true,
                        hasTotp: false,
                        attachmentCount: 0,
                        isDeleted: false
                    )
                ]
            )
        )
        reader.queuedResults = [
            .failure(
                KeePassOperationError(
                    code: .invalidCredential,
                    message: "bad database-password key-file-secret"
                )
            ),
            .success(reader.snapshot)
        ]
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            keePassDatabaseReader: reader
        )
        let kdbx = Data([
            0x03, 0xD9, 0xA2, 0x9A,
            0x67, 0xFB, 0x4B, 0xB5,
            0x00, 0x00, 0x04, 0x00
        ])

        try unlockNewVault(model)
        _ = try model.previewKeePassImport(kdbx, fileName: "personal.kdbx")
        _ = try model.prepareKeePassUnlockPreflight(
            password: "database-password",
            keyFile: Data("key-file-secret".utf8),
            keyFileName: "personal.key"
        )

        let snapshot = try model.previewKeePassReadOnlyTree()

        XCTAssertEqual(snapshot.entryCount, 1)
        XCTAssertEqual(reader.requests.map { $0.credentials.candidateLabel }, ["password-only", "raw/password+key"])
        XCTAssertTrue(engine.createdLoginEntries.isEmpty)
        XCTAssertFalse(model.entryOperationState.label.contains("database-password"))
        XCTAssertFalse(model.entryOperationState.label.contains("a2V5LWZpbGUtc2VjcmV0"))
        XCTAssertEqual(model.entryOperationState, .succeeded("KeePass 只读预览：KDBX 4，0 个分组，1 个条目"))
    }

    func testKeePassReadOnlyImportPlanUsesSnapshotWithoutWritingVaultOrLeakingSecrets() throws {
        let engine = RecordingVaultEngine()
        let reader = RecordingKeePassDatabaseReader(
            snapshot: KeePassReadOnlySnapshot(
                sourceName: "personal.kdbx",
                headerSummary: KeePassHeaderSummary(majorVersion: 4, minorVersion: 0, formatVersion: .kdbx4),
                groups: [
                    KeePassReadOnlyGroup(id: "root", title: "Root", path: "/", depth: 0),
                    KeePassReadOnlyGroup(id: "work", title: "Work", path: "/Work", depth: 1)
                ],
                entries: [
                    KeePassReadOnlyEntry(
                        id: "entry-1",
                        title: "GitHub",
                        username: "alice",
                        url: "https://github.com",
                        groupPath: "/Work",
                        hasPassword: true,
                        hasTotp: false,
                        attachmentCount: 0,
                        isDeleted: false
                    ),
                    KeePassReadOnlyEntry(
                        id: "entry-2",
                        title: "Old",
                        username: "bob",
                        url: "https://old.example",
                        groupPath: "/Trash",
                        hasPassword: true,
                        hasTotp: false,
                        attachmentCount: 0,
                        isDeleted: true
                    )
                ]
            )
        )
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            keePassDatabaseReader: reader
        )
        let kdbx = Data([
            0x03, 0xD9, 0xA2, 0x9A,
            0x67, 0xFB, 0x4B, 0xB5,
            0x00, 0x00, 0x04, 0x00
        ])

        try unlockNewVault(model)
        _ = try model.previewKeePassImport(kdbx, fileName: "personal.kdbx")
        _ = try model.prepareKeePassUnlockPreflight(
            password: "database-password",
            keyFile: Data("key-file-secret".utf8),
            keyFileName: "personal.key"
        )

        let plan = try model.previewKeePassReadOnlyImportPlan()

        XCTAssertEqual(plan.candidateCount, 2)
        XCTAssertEqual(plan.deletedCandidateCount, 1)
        XCTAssertEqual(plan.skippedCount, 0)
        XCTAssertEqual(plan.candidates.first?.title, "GitHub")
        XCTAssertEqual(plan.candidates.last?.title, "Old")
        XCTAssertEqual(plan.candidates.last?.isDeleted, true)
        XCTAssertEqual(model.keePassReadOnlyImportPlan?.displaySummary, "KDBX 4，2 个可预览条目，0 个跳过")
        XCTAssertEqual(reader.requests.count, 1)
        XCTAssertTrue(engine.createdLoginEntries.isEmpty)
        XCTAssertFalse(model.entryOperationState.label.contains("database-password"))
        XCTAssertFalse(model.entryOperationState.label.contains("key-file-secret"))
        XCTAssertEqual(model.entryOperationState, .succeeded("KeePass 导入计划：KDBX 4，2 个可预览条目，0 个跳过"))
    }

    func testKeePassKdbxWritebackReplacesSourceFileWithoutLeakingSecrets() throws {
        let writer = RecordingAppKeePassKdbxFileWritebackService()
        let model = AppSessionModel(keePassKdbxFileWritebackService: writer)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-kdbx-writeback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("personal.kdbx")
        let originalKdbx = Data([
            0x03, 0xD9, 0xA2, 0x9A,
            0x67, 0xFB, 0x4B, 0xB5,
            0x00, 0x00, 0x04, 0x00
        ])
        try originalKdbx.write(to: databaseURL)
        let newDatabaseBytes = Data("rewritten-kdbx-secret-bytes".utf8)
        let result = KeePassKdbx4WritebackResult(
            database: newDatabaseBytes,
            headerBytes: Data([0xAA]),
            payloadSection: Data([0xBB]),
            xmlPayloadByteCount: 77,
            groupCount: 2,
            entryCount: 3,
            attachmentCount: 1
        )

        _ = try model.previewKeePassImport(from: databaseURL)
        _ = try model.prepareKeePassUnlockPreflight(
            password: "database-password",
            keyFile: Data("key-file-secret".utf8),
            keyFileName: "personal.key"
        )

        try model.writeKeePassKdbx4Database(result)

        XCTAssertEqual(
            writer.replacements,
            [
                RecordedKeePassKdbxFileReplacement(
                    url: databaseURL,
                    data: newDatabaseBytes
                )
            ]
        )
        XCTAssertEqual(model.keePassPendingDatabaseData, newDatabaseBytes)
        XCTAssertFalse(model.entryOperationState.label.contains("database-password"))
        XCTAssertFalse(model.entryOperationState.label.contains("key-file-secret"))
        XCTAssertFalse(model.entryOperationState.label.contains("rewritten-kdbx-secret-bytes"))
        XCTAssertEqual(
            model.entryOperationState,
            .succeeded("KeePass 数据库已写回：3 个条目，1 个附件，27 bytes")
        )
    }

    func testKeePassKdbxSnapshotSaveBuildsWritebackRequestAndWritesSourceFileWithoutLeakingSecrets() throws {
        let writer = RecordingAppKeePassKdbxFileWritebackService()
        let coordinator = RecordingKeePassKdbx4WritebackCoordinator()
        let snapshot = KeePassReadOnlySnapshot(
            sourceName: "personal.kdbx",
            headerSummary: KeePassHeaderSummary(majorVersion: 4, minorVersion: 0, formatVersion: .kdbx4),
            groups: [
                KeePassReadOnlyGroup(id: "root", title: "Root", path: "/", depth: 0),
                KeePassReadOnlyGroup(id: "work", title: "Work", path: "/Work", depth: 1)
            ],
            entries: [
                KeePassReadOnlyEntry(
                    id: "entry-1",
                    title: "Edited Login",
                    username: "writer@example.com",
                    url: "https://example.com/login",
                    groupPath: "/Work",
                    groupID: "work",
                    notes: "edited notes secret",
                    hasPassword: true,
                    decodedPassword: "decoded-password-secret",
                    hasTotp: false,
                    attachmentCount: 0,
                    isDeleted: false
                )
            ]
        )
        let reader = RecordingKeePassDatabaseReader(snapshot: snapshot)
        reader.queuedResults = [
            .failure(KeePassOperationError(code: .invalidCredential, message: "invalid password-only candidate")),
            .success(snapshot)
        ]
        let model = AppSessionModel(
            keePassDatabaseReader: reader,
            keePassKdbxFileWritebackService: writer,
            keePassKdbx4WritebackCoordinator: coordinator
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-kdbx-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("personal.kdbx")
        let cryptoInputs = KeePassKdbxPayloadCryptoInputs(
            masterSeed: Data(repeating: 0xA1, count: 32),
            encryptionIV: Data(repeating: 0xA2, count: 16),
            innerRandomStreamKey: Data(repeating: 0xA3, count: 32),
            innerRandomStreamID: 2
        )
        let kdfParameters = KeePassKdbxKdfParameters(
            algorithm: .argon2id,
            argon2: KeePassKdbxArgon2Parameters(
                salt: Data(repeating: 0xA4, count: 32),
                iterations: 2,
                memoryBytes: 8 * 1024,
                parallelism: 1,
                version: 0x13
            )
        )
        let sourceDatabase = try DefaultKeePassKdbx4HeaderWriter().writeHeader(
            cipher: .aes256,
            compression: .gzip,
            cryptoInputs: cryptoInputs,
            kdfParameters: kdfParameters
        ) + Data("encrypted-payload-placeholder".utf8)
        try sourceDatabase.write(to: databaseURL)
        let expectedResult = KeePassKdbx4WritebackResult(
            database: Data("coordinated-kdbx-secret-bytes".utf8),
            headerBytes: Data([0x01]),
            payloadSection: Data([0x02]),
            xmlPayloadByteCount: 88,
            groupCount: 2,
            entryCount: 1,
            attachmentCount: 0
        )
        coordinator.result = expectedResult

        _ = try model.previewKeePassImport(from: databaseURL)
        _ = try model.prepareKeePassUnlockPreflight(
            password: "database-password",
            keyFile: Data("key-file-secret".utf8),
            keyFileName: "personal.key"
        )
        _ = try model.previewKeePassReadOnlyTree()

        let result = try model.writeKeePassReadOnlySnapshotBackToSource()

        let request = try XCTUnwrap(coordinator.requests.first)
        XCTAssertEqual(request.snapshot, snapshot)
        XCTAssertEqual(request.credentials.password, "database-password")
        XCTAssertEqual(request.credentials.keyFile, Data("key-file-secret".utf8))
        XCTAssertEqual(request.credentials.keyFileName, "personal.key")
        XCTAssertEqual(request.cipher, .aes256)
        XCTAssertEqual(request.compression, .gzip)
        XCTAssertEqual(request.cryptoInputs, cryptoInputs)
        XCTAssertEqual(request.kdfParameters, kdfParameters)
        XCTAssertEqual(result.database, expectedResult.database)
        XCTAssertEqual(
            writer.replacements,
            [
                RecordedKeePassKdbxFileReplacement(
                    url: databaseURL,
                    data: expectedResult.database
                )
            ]
        )
        XCTAssertEqual(model.keePassPendingDatabaseData, expectedResult.database)
        XCTAssertFalse(model.entryOperationState.label.contains("database-password"))
        XCTAssertFalse(model.entryOperationState.label.contains("key-file-secret"))
        XCTAssertFalse(model.entryOperationState.label.contains("decoded-password-secret"))
        XCTAssertFalse(model.entryOperationState.label.contains("coordinated-kdbx-secret-bytes"))
        XCTAssertEqual(
            model.entryOperationState,
            .succeeded("KeePass 数据库已写回：1 个条目，0 个附件，29 bytes")
        )
    }

    func testKeePassKdbx3SnapshotSaveBuildsWritebackRequestAndWritesSourceFileWithoutLeakingSecrets() throws {
        let writer = RecordingAppKeePassKdbxFileWritebackService()
        let kdbx4Coordinator = RecordingKeePassKdbx4WritebackCoordinator()
        let kdbx3Coordinator = RecordingKeePassKdbx3WritebackCoordinator()
        let snapshot = KeePassReadOnlySnapshot(
            sourceName: "legacy.kdbx",
            headerSummary: KeePassHeaderSummary(majorVersion: 3, minorVersion: 1, formatVersion: .kdbx3),
            groups: [
                KeePassReadOnlyGroup(id: "root", title: "Root", path: "/", depth: 0)
            ],
            entries: [
                KeePassReadOnlyEntry(
                    id: "entry-legacy",
                    title: "Legacy Login",
                    username: "legacy@example.com",
                    url: "https://legacy.example.com",
                    groupPath: "/",
                    groupID: "root",
                    notes: "legacy edited notes secret",
                    hasPassword: true,
                    decodedPassword: "legacy decoded password secret",
                    hasTotp: false,
                    attachmentCount: 0,
                    isDeleted: false
                )
            ]
        )
        let reader = RecordingKeePassDatabaseReader(snapshot: snapshot)
        let model = AppSessionModel(
            keePassDatabaseReader: reader,
            keePassKdbxFileWritebackService: writer,
            keePassKdbx3WritebackCoordinator: kdbx3Coordinator,
            keePassKdbx4WritebackCoordinator: kdbx4Coordinator
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-kdbx3-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("legacy.kdbx")
        let cryptoInputs = KeePassKdbxPayloadCryptoInputs(
            masterSeed: Data(repeating: 0xB1, count: 32),
            encryptionIV: Data(repeating: 0xB2, count: 16),
            innerRandomStreamKey: Data(repeating: 0xB3, count: 32),
            streamStartBytes: Data(repeating: 0xB4, count: 32),
            innerRandomStreamID: 2
        )
        let kdfParameters = KeePassKdbxKdfParameters(
            algorithm: .aesKdf,
            aesKdf: KeePassKdbxAesKdfParameters(
                seed: Data(repeating: 0xB5, count: 32),
                rounds: 2
            )
        )
        let sourceDatabase = try DefaultKeePassKdbx3HeaderWriter().writeHeader(
            cipher: .aes256,
            compression: .gzip,
            cryptoInputs: cryptoInputs,
            kdfParameters: kdfParameters
        ) + Data("legacy-encrypted-payload-placeholder".utf8)
        try sourceDatabase.write(to: databaseURL)
        let expectedResult = KeePassKdbx3WritebackResult(
            database: Data("coordinated-kdbx3-secret-bytes".utf8),
            headerBytes: Data([0x03]),
            encryptedPayload: Data([0x04]),
            xmlPayloadByteCount: 91,
            groupCount: 1,
            entryCount: 1,
            attachmentCount: 0
        )
        kdbx3Coordinator.result = expectedResult

        _ = try model.previewKeePassImport(from: databaseURL)
        _ = try model.prepareKeePassUnlockPreflight(password: "database-password")
        _ = try model.previewKeePassReadOnlyTree()

        let result = try model.writeKeePassReadOnlySnapshotBackToSource()

        let request = try XCTUnwrap(kdbx3Coordinator.requests.first)
        XCTAssertEqual(request.snapshot, snapshot)
        XCTAssertEqual(request.credentials.password, "database-password")
        XCTAssertEqual(request.cipher, .aes256)
        XCTAssertEqual(request.compression, .gzip)
        XCTAssertEqual(request.cryptoInputs, cryptoInputs)
        XCTAssertEqual(request.kdfParameters, kdfParameters)
        XCTAssertTrue(kdbx4Coordinator.requests.isEmpty)
        XCTAssertEqual(result.database, expectedResult.database)
        XCTAssertEqual(
            writer.replacements,
            [
                RecordedKeePassKdbxFileReplacement(
                    url: databaseURL,
                    data: expectedResult.database
                )
            ]
        )
        XCTAssertFalse(model.entryOperationState.label.contains("database-password"))
        XCTAssertFalse(model.entryOperationState.label.contains("legacy decoded password secret"))
        XCTAssertFalse(model.entryOperationState.label.contains("coordinated-kdbx3-secret-bytes"))
        XCTAssertEqual(model.entryOperationState, .succeeded("KeePass 数据库已写回：1 个条目，0 个附件，30 bytes"))
    }

    func testKeePassSnapshotAttachmentContentEditWritesUpdatedAttachmentWithoutLeakingSecrets() throws {
        let writer = RecordingAppKeePassKdbxFileWritebackService()
        let coordinator = RecordingKeePassKdbx4WritebackCoordinator()
        let oldAttachmentSecret = Data("old keepass attachment secret".utf8)
        let newAttachmentSecret = Data("new keepass attachment secret".utf8)
        let snapshot = KeePassReadOnlySnapshot(
            sourceName: "personal.kdbx",
            headerSummary: KeePassHeaderSummary(majorVersion: 4, minorVersion: 0, formatVersion: .kdbx4),
            groups: [
                KeePassReadOnlyGroup(id: "root", title: "Root", path: "/", depth: 0)
            ],
            entries: [
                KeePassReadOnlyEntry(
                    id: "entry-attachment",
                    title: "Contract",
                    username: "owner@example.com",
                    url: "https://example.com/contract",
                    groupPath: "/",
                    groupID: "root",
                    notes: "entry note",
                    hasPassword: true,
                    decodedPassword: "entry-password-secret",
                    hasTotp: false,
                    attachmentCount: 1,
                    isDeleted: false,
                    attachments: [
                        KeePassReadOnlyAttachment(
                            id: "attachment-1",
                            fileName: "contract.pdf",
                            mediaType: "application/pdf",
                            originalSize: Int64(oldAttachmentSecret.count),
                            contentHash: "sha256:old-attachment-secret-hash",
                            decodedContent: oldAttachmentSecret
                        )
                    ]
                )
            ]
        )
        let reader = RecordingKeePassDatabaseReader(snapshot: snapshot)
        let model = AppSessionModel(
            keePassDatabaseReader: reader,
            keePassKdbxFileWritebackService: writer,
            keePassKdbx4WritebackCoordinator: coordinator
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-kdbx-attachment-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("personal.kdbx")
        let cryptoInputs = KeePassKdbxPayloadCryptoInputs(
            masterSeed: Data(repeating: 0xB1, count: 32),
            encryptionIV: Data(repeating: 0xB2, count: 16),
            innerRandomStreamKey: Data(repeating: 0xB3, count: 32),
            innerRandomStreamID: 2
        )
        let kdfParameters = KeePassKdbxKdfParameters(
            algorithm: .argon2id,
            argon2: KeePassKdbxArgon2Parameters(
                salt: Data(repeating: 0xB4, count: 32),
                iterations: 2,
                memoryBytes: 8 * 1024,
                parallelism: 1,
                version: 0x13
            )
        )
        let sourceDatabase = try DefaultKeePassKdbx4HeaderWriter().writeHeader(
            cipher: .aes256,
            compression: .gzip,
            cryptoInputs: cryptoInputs,
            kdfParameters: kdfParameters
        ) + Data("encrypted-payload-placeholder".utf8)
        try sourceDatabase.write(to: databaseURL)
        let expectedResult = KeePassKdbx4WritebackResult(
            database: Data("coordinated-kdbx-with-edited-attachment".utf8),
            headerBytes: Data([0x03]),
            payloadSection: Data([0x04]),
            xmlPayloadByteCount: 128,
            groupCount: 1,
            entryCount: 1,
            attachmentCount: 1
        )
        coordinator.result = expectedResult

        _ = try model.previewKeePassImport(from: databaseURL)
        _ = try model.prepareKeePassUnlockPreflight(password: "database-password")
        _ = try model.previewKeePassReadOnlyTree()

        let editedSnapshot = try model.replaceKeePassReadOnlyAttachmentContent(
            entryID: "entry-attachment",
            attachmentID: "attachment-1",
            decodedContent: newAttachmentSecret
        )
        let editedEntry = try XCTUnwrap(editedSnapshot.entries.first)
        let editedAttachment = try XCTUnwrap(editedEntry.attachments.first)

        _ = try model.writeKeePassReadOnlySnapshotBackToSource()

        let request = try XCTUnwrap(coordinator.requests.first)
        let writtenAttachment = try XCTUnwrap(request.snapshot.entries.first?.attachments.first)
        let expectedHash = Data(SHA256.hash(data: newAttachmentSecret))
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(editedAttachment.decodedContent, newAttachmentSecret)
        XCTAssertEqual(editedAttachment.originalSize, Int64(newAttachmentSecret.count))
        XCTAssertEqual(editedAttachment.contentHash, "sha256:\(expectedHash)")
        XCTAssertEqual(writtenAttachment, editedAttachment)
        XCTAssertEqual(writer.replacements.first?.data, expectedResult.database)
        [
            "old keepass attachment secret",
            "new keepass attachment secret",
            "entry-password-secret",
            "old-attachment-secret-hash",
            expectedHash,
            "coordinated-kdbx-with-edited-attachment"
        ].forEach { secret in
            XCTAssertFalse(model.entryOperationState.label.contains(secret))
        }
    }

    func testKeePassSnapshotAttachmentFileReplacementWritesBackSelectedFileWithoutLeakingSecrets() throws {
        let writer = RecordingAppKeePassKdbxFileWritebackService()
        let coordinator = RecordingKeePassKdbx4WritebackCoordinator()
        let oldAttachmentSecret = Data("old keepass attachment secret".utf8)
        let selectedFileSecret = Data("selected replacement keepass file secret".utf8)
        let snapshot = KeePassReadOnlySnapshot(
            sourceName: "personal.kdbx",
            headerSummary: KeePassHeaderSummary(majorVersion: 4, minorVersion: 0, formatVersion: .kdbx4),
            groups: [
                KeePassReadOnlyGroup(id: "root", title: "Root", path: "/", depth: 0)
            ],
            entries: [
                KeePassReadOnlyEntry(
                    id: "entry-attachment",
                    title: "Contract",
                    username: "owner@example.com",
                    url: "https://example.com/contract",
                    groupPath: "/",
                    groupID: "root",
                    notes: "entry note",
                    hasPassword: true,
                    decodedPassword: "entry-password-secret",
                    hasTotp: false,
                    attachmentCount: 1,
                    isDeleted: false,
                    attachments: [
                        KeePassReadOnlyAttachment(
                            id: "attachment-1",
                            fileName: "contract.pdf",
                            mediaType: "application/pdf",
                            originalSize: Int64(oldAttachmentSecret.count),
                            contentHash: "sha256:old-attachment-secret-hash",
                            decodedContent: oldAttachmentSecret
                        )
                    ]
                )
            ]
        )
        let model = AppSessionModel(
            keePassDatabaseReader: RecordingKeePassDatabaseReader(snapshot: snapshot),
            keePassKdbxFileWritebackService: writer,
            keePassKdbx4WritebackCoordinator: coordinator
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-kdbx-attachment-file-replace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("personal.kdbx")
        let replacementURL = directory.appendingPathComponent("replacement report.txt")
        let cryptoInputs = KeePassKdbxPayloadCryptoInputs(
            masterSeed: Data(repeating: 0xC1, count: 32),
            encryptionIV: Data(repeating: 0xC2, count: 16),
            innerRandomStreamKey: Data(repeating: 0xC3, count: 32),
            innerRandomStreamID: 2
        )
        let kdfParameters = KeePassKdbxKdfParameters(
            algorithm: .argon2id,
            argon2: KeePassKdbxArgon2Parameters(
                salt: Data(repeating: 0xC4, count: 32),
                iterations: 2,
                memoryBytes: 8 * 1024,
                parallelism: 1,
                version: 0x13
            )
        )
        let sourceDatabase = try DefaultKeePassKdbx4HeaderWriter().writeHeader(
            cipher: .aes256,
            compression: .gzip,
            cryptoInputs: cryptoInputs,
            kdfParameters: kdfParameters
        ) + Data("encrypted-payload-placeholder".utf8)
        try sourceDatabase.write(to: databaseURL)
        try selectedFileSecret.write(to: replacementURL)
        let expectedResult = KeePassKdbx4WritebackResult(
            database: Data("coordinated-kdbx-with-selected-file".utf8),
            headerBytes: Data([0x05]),
            payloadSection: Data([0x06]),
            xmlPayloadByteCount: 144,
            groupCount: 1,
            entryCount: 1,
            attachmentCount: 1
        )
        coordinator.result = expectedResult

        _ = try model.previewKeePassImport(from: databaseURL)
        _ = try model.prepareKeePassUnlockPreflight(password: "database-password")
        _ = try model.previewKeePassReadOnlyTree()

        let result = try model.replaceKeePassReadOnlyAttachmentContentFromFileAndWriteBack(
            entryID: "entry-attachment",
            attachmentID: "attachment-1",
            fileURL: replacementURL,
            mediaType: "text/plain"
        )

        let request = try XCTUnwrap(coordinator.requests.first)
        let writtenAttachment = try XCTUnwrap(request.snapshot.entries.first?.attachments.first)
        let expectedHash = Data(SHA256.hash(data: selectedFileSecret))
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(result.database, expectedResult.database)
        XCTAssertEqual(writtenAttachment.fileName, "replacement_report.txt")
        XCTAssertEqual(writtenAttachment.mediaType, "text/plain")
        XCTAssertEqual(writtenAttachment.originalSize, Int64(selectedFileSecret.count))
        XCTAssertEqual(writtenAttachment.contentHash, "sha256:\(expectedHash)")
        XCTAssertEqual(writtenAttachment.decodedContent, selectedFileSecret)
        XCTAssertEqual(writer.replacements.first?.data, expectedResult.database)
        [
            "old keepass attachment secret",
            "selected replacement keepass file secret",
            "entry-password-secret",
            "old-attachment-secret-hash",
            expectedHash,
            "coordinated-kdbx-with-selected-file"
        ].forEach { secret in
            XCTAssertFalse(model.entryOperationState.label.contains(secret))
        }
        XCTAssertEqual(
            model.entryOperationState,
            .succeeded("KeePass 附件已替换并写回：replacement_report.txt \(selectedFileSecret.count) 字节")
        )
    }

    func testKeePassAttachmentEditCandidatesSearchAllAttachmentsWithoutLeakingSecrets() throws {
        let hiddenSecret = Data("hidden attachment decoded secret".utf8)
        let snapshot = KeePassReadOnlySnapshot(
            sourceName: "personal.kdbx",
            headerSummary: KeePassHeaderSummary(majorVersion: 4, minorVersion: 0, formatVersion: .kdbx4),
            groups: [
                KeePassReadOnlyGroup(id: "root", title: "Root", path: "/", depth: 0)
            ],
            entries: [
                KeePassReadOnlyEntry(
                    id: "entry-1",
                    title: "First",
                    username: "first@example.com",
                    url: "https://example.com/first",
                    groupPath: "/Root",
                    notes: "first note secret",
                    hasPassword: true,
                    decodedPassword: "first-password-secret",
                    hasTotp: false,
                    attachmentCount: 1,
                    isDeleted: false,
                    attachments: [
                        KeePassReadOnlyAttachment(
                            id: "attachment-1",
                            fileName: "first.txt",
                            originalSize: 1,
                            contentHash: "sha256:first-secret-hash",
                            decodedContent: Data([0x01])
                        )
                    ]
                ),
                KeePassReadOnlyEntry(
                    id: "entry-2",
                    title: "Second",
                    username: "second@example.com",
                    url: "https://example.com/second",
                    groupPath: "/Root",
                    hasPassword: true,
                    hasTotp: false,
                    attachmentCount: 1,
                    isDeleted: false,
                    attachments: [
                        KeePassReadOnlyAttachment(
                            id: "attachment-2",
                            fileName: "second.txt",
                            originalSize: 2,
                            contentHash: "sha256:second-secret-hash",
                            decodedContent: Data([0x02])
                        )
                    ]
                ),
                KeePassReadOnlyEntry(
                    id: "entry-3",
                    title: "Third",
                    username: "third@example.com",
                    url: "https://example.com/third",
                    groupPath: "/Root",
                    hasPassword: true,
                    hasTotp: false,
                    attachmentCount: 1,
                    isDeleted: false,
                    attachments: [
                        KeePassReadOnlyAttachment(
                            id: "attachment-3",
                            fileName: "third.txt",
                            originalSize: 3,
                            contentHash: "sha256:third-secret-hash",
                            decodedContent: Data([0x03])
                        )
                    ]
                ),
                KeePassReadOnlyEntry(
                    id: "entry-4",
                    title: "Archive",
                    username: "owner@example.com",
                    url: "https://example.com/archive",
                    groupPath: "/Root/Later",
                    notes: "late note secret",
                    hasPassword: true,
                    decodedPassword: "late-password-secret",
                    hasTotp: false,
                    attachmentCount: 3,
                    isDeleted: true,
                    attachments: [
                        KeePassReadOnlyAttachment(
                            id: "attachment-4-a",
                            fileName: "later-a.txt",
                            originalSize: 4,
                            contentHash: "sha256:later-a-secret-hash",
                            decodedContent: Data([0x04])
                        ),
                        KeePassReadOnlyAttachment(
                            id: "attachment-4-b",
                            fileName: "later-b.txt",
                            originalSize: 5,
                            contentHash: "sha256:later-b-secret-hash",
                            decodedContent: Data([0x05])
                        ),
                        KeePassReadOnlyAttachment(
                            id: "attachment-hidden",
                            fileName: "quarterly-hidden.txt",
                            mediaType: "text/plain",
                            originalSize: Int64(hiddenSecret.count),
                            contentHash: "sha256:hidden-secret-hash",
                            decodedContent: hiddenSecret
                        )
                    ]
                )
            ]
        )
        let model = AppSessionModel(
            keePassDatabaseReader: RecordingKeePassDatabaseReader(snapshot: snapshot)
        )
        model.keePassReadOnlySnapshot = snapshot

        let allCandidates = try model.keePassAttachmentEditCandidates()
        let filteredCandidates = try model.keePassAttachmentEditCandidates(matching: "quarterly")
        let candidate = try XCTUnwrap(filteredCandidates.first)

        XCTAssertEqual(allCandidates.map(\.attachmentID), [
            "attachment-1",
            "attachment-2",
            "attachment-3",
            "attachment-4-a",
            "attachment-4-b",
            "attachment-hidden"
        ])
        XCTAssertEqual(filteredCandidates.count, 1)
        XCTAssertEqual(candidate.entryID, "entry-4")
        XCTAssertEqual(candidate.attachmentID, "attachment-hidden")
        XCTAssertEqual(candidate.entryTitle, "Archive")
        XCTAssertEqual(candidate.entryUsername, "owner@example.com")
        XCTAssertEqual(candidate.groupPath, "/Root/Later")
        XCTAssertEqual(candidate.fileName, "quarterly-hidden.txt")
        XCTAssertEqual(candidate.mediaType, "text/plain")
        XCTAssertEqual(candidate.originalSize, Int64(hiddenSecret.count))
        XCTAssertTrue(candidate.isDeletedEntry)
        [
            "hidden attachment decoded secret",
            "hidden-secret-hash",
            "late-password-secret",
            "late note secret",
            "first-secret-hash"
        ].forEach { secret in
            XCTAssertFalse(candidate.searchableText.contains(secret))
        }
    }

    func testKeePassSnapshotAttachmentAddAndDeleteWriteBackWithoutLeakingSecrets() throws {
        let writer = RecordingAppKeePassKdbxFileWritebackService()
        let coordinator = RecordingKeePassKdbx4WritebackCoordinator()
        let addedAttachmentSecret = Data("added keepass attachment secret".utf8)
        let removedAttachmentSecret = Data("removed keepass attachment secret".utf8)
        let snapshot = KeePassReadOnlySnapshot(
            sourceName: "personal.kdbx",
            headerSummary: KeePassHeaderSummary(majorVersion: 4, minorVersion: 0, formatVersion: .kdbx4),
            groups: [
                KeePassReadOnlyGroup(id: "root", title: "Root", path: "/", depth: 0)
            ],
            entries: [
                KeePassReadOnlyEntry(
                    id: "entry-attachment",
                    title: "Contract",
                    username: "owner@example.com",
                    url: "https://example.com/contract",
                    groupPath: "/",
                    groupID: "root",
                    notes: "entry note secret",
                    hasPassword: true,
                    decodedPassword: "entry-password-secret",
                    hasTotp: false,
                    attachmentCount: 1,
                    isDeleted: false,
                    attachments: [
                        KeePassReadOnlyAttachment(
                            id: "attachment-remove",
                            fileName: "remove.txt",
                            mediaType: "text/plain",
                            originalSize: Int64(removedAttachmentSecret.count),
                            contentHash: "sha256:removed-secret-hash",
                            decodedContent: removedAttachmentSecret
                        )
                    ]
                )
            ]
        )
        let model = AppSessionModel(
            keePassDatabaseReader: RecordingKeePassDatabaseReader(snapshot: snapshot),
            keePassKdbxFileWritebackService: writer,
            keePassKdbx4WritebackCoordinator: coordinator
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-kdbx-attachment-add-delete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("personal.kdbx")
        let addedFileURL = directory.appendingPathComponent("added report.txt")
        let cryptoInputs = KeePassKdbxPayloadCryptoInputs(
            masterSeed: Data(repeating: 0xD1, count: 32),
            encryptionIV: Data(repeating: 0xD2, count: 16),
            innerRandomStreamKey: Data(repeating: 0xD3, count: 32),
            innerRandomStreamID: 2
        )
        let kdfParameters = KeePassKdbxKdfParameters(
            algorithm: .argon2id,
            argon2: KeePassKdbxArgon2Parameters(
                salt: Data(repeating: 0xD4, count: 32),
                iterations: 2,
                memoryBytes: 8 * 1024,
                parallelism: 1,
                version: 0x13
            )
        )
        let sourceDatabase = try DefaultKeePassKdbx4HeaderWriter().writeHeader(
            cipher: .aes256,
            compression: .gzip,
            cryptoInputs: cryptoInputs,
            kdfParameters: kdfParameters
        ) + Data("encrypted-payload-placeholder".utf8)
        let addResultDatabase = try DefaultKeePassKdbx4HeaderWriter().writeHeader(
            cipher: .aes256,
            compression: .gzip,
            cryptoInputs: cryptoInputs,
            kdfParameters: kdfParameters
        ) + Data("encrypted-payload-after-add".utf8)
        let deleteResultDatabase = try DefaultKeePassKdbx4HeaderWriter().writeHeader(
            cipher: .aes256,
            compression: .gzip,
            cryptoInputs: cryptoInputs,
            kdfParameters: kdfParameters
        ) + Data("encrypted-payload-after-delete".utf8)
        try sourceDatabase.write(to: databaseURL)
        try addedAttachmentSecret.write(to: addedFileURL)
        let addResult = KeePassKdbx4WritebackResult(
            database: addResultDatabase,
            headerBytes: Data([0x07]),
            payloadSection: Data([0x08]),
            xmlPayloadByteCount: 160,
            groupCount: 1,
            entryCount: 1,
            attachmentCount: 2
        )
        let deleteResult = KeePassKdbx4WritebackResult(
            database: deleteResultDatabase,
            headerBytes: Data([0x09]),
            payloadSection: Data([0x0A]),
            xmlPayloadByteCount: 96,
            groupCount: 1,
            entryCount: 1,
            attachmentCount: 1
        )

        _ = try model.previewKeePassImport(from: databaseURL)
        _ = try model.prepareKeePassUnlockPreflight(password: "database-password")
        _ = try model.previewKeePassReadOnlyTree()

        coordinator.result = addResult
        let addedResult = try model.addKeePassReadOnlyAttachmentContentFromFileAndWriteBack(
            entryID: "entry-attachment",
            fileURL: addedFileURL,
            mediaType: "text/plain"
        )

        let addRequest = try XCTUnwrap(coordinator.requests.first)
        let addedAttachment = try XCTUnwrap(
            addRequest.snapshot.entries.first?.attachments.first {
                $0.fileName == "added_report.txt"
            }
        )
        let addedHash = Data(SHA256.hash(data: addedAttachmentSecret))
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(addedResult.database, addResult.database)
        XCTAssertEqual(addRequest.snapshot.entries.first?.attachmentCount, 2)
        XCTAssertEqual(addedAttachment.mediaType, "text/plain")
        XCTAssertEqual(addedAttachment.originalSize, Int64(addedAttachmentSecret.count))
        XCTAssertEqual(addedAttachment.contentHash, "sha256:\(addedHash)")
        XCTAssertEqual(addedAttachment.decodedContent, addedAttachmentSecret)
        XCTAssertEqual(writer.replacements.first?.data, addResult.database)

        coordinator.result = deleteResult
        let deletedResult = try model.deleteKeePassReadOnlyAttachmentAndWriteBack(
            entryID: "entry-attachment",
            attachmentID: "attachment-remove"
        )

        let deleteRequest = try XCTUnwrap(coordinator.requests.last)
        let remainingAttachments = try XCTUnwrap(deleteRequest.snapshot.entries.first?.attachments)
        XCTAssertEqual(deletedResult.database, deleteResult.database)
        XCTAssertEqual(remainingAttachments.map(\.fileName), ["added_report.txt"])
        XCTAssertEqual(deleteRequest.snapshot.entries.first?.attachmentCount, 1)
        XCTAssertEqual(writer.replacements.map(\.data), [addResult.database, deleteResult.database])
        [
            "added keepass attachment secret",
            "removed keepass attachment secret",
            "entry-password-secret",
            "entry note secret",
            "removed-secret-hash",
            addedHash,
            "encrypted-payload-after-add",
            "encrypted-payload-after-delete"
        ].forEach { secret in
            XCTAssertFalse(model.entryOperationState.label.contains(secret))
        }
        XCTAssertEqual(
            model.entryOperationState,
            .succeeded("KeePass 附件已删除并写回：remove.txt")
        )
    }

    func testKeePassSnapshotRecycleBinEntryRestoreMovesEntryToTargetGroupAndWritesBackWithoutLeakingSecrets() throws {
        let writer = RecordingAppKeePassKdbxFileWritebackService()
        let coordinator = RecordingKeePassKdbx4WritebackCoordinator()
        let attachmentSecret = Data("restored recycle attachment secret".utf8)
        let snapshot = KeePassReadOnlySnapshot(
            sourceName: "personal.kdbx",
            headerSummary: KeePassHeaderSummary(majorVersion: 4, minorVersion: 0, formatVersion: .kdbx4),
            groups: [
                KeePassReadOnlyGroup(id: "root", title: "Root", path: "/", depth: 0),
                KeePassReadOnlyGroup(id: "work", title: "Work", path: "/Work", depth: 1),
                KeePassReadOnlyGroup(id: "recycle-bin", title: "Recycle Bin", path: "/Recycle Bin", depth: 1)
            ],
            entries: [
                KeePassReadOnlyEntry(
                    id: "deleted-entry",
                    title: "Deleted Login",
                    username: "deleted@example.com",
                    url: "https://deleted.example.com",
                    groupPath: "/Recycle Bin",
                    groupID: "recycle-bin",
                    notes: "deleted entry note secret",
                    hasPassword: true,
                    decodedPassword: "deleted-entry-password-secret",
                    hasTotp: false,
                    attachmentCount: 1,
                    isDeleted: true,
                    attachments: [
                        KeePassReadOnlyAttachment(
                            id: "deleted-attachment",
                            fileName: "deleted.txt",
                            mediaType: "text/plain",
                            originalSize: Int64(attachmentSecret.count),
                            contentHash: "sha256:deleted-attachment-secret-hash",
                            decodedContent: attachmentSecret
                        )
                    ]
                )
            ]
        )
        let model = AppSessionModel(
            keePassDatabaseReader: RecordingKeePassDatabaseReader(snapshot: snapshot),
            keePassKdbxFileWritebackService: writer,
            keePassKdbx4WritebackCoordinator: coordinator
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-kdbx-recycle-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("personal.kdbx")
        let cryptoInputs = KeePassKdbxPayloadCryptoInputs(
            masterSeed: Data(repeating: 0xE1, count: 32),
            encryptionIV: Data(repeating: 0xE2, count: 16),
            innerRandomStreamKey: Data(repeating: 0xE3, count: 32),
            innerRandomStreamID: 2
        )
        let kdfParameters = KeePassKdbxKdfParameters(
            algorithm: .argon2id,
            argon2: KeePassKdbxArgon2Parameters(
                salt: Data(repeating: 0xE4, count: 32),
                iterations: 2,
                memoryBytes: 8 * 1024,
                parallelism: 1,
                version: 0x13
            )
        )
        let sourceDatabase = try DefaultKeePassKdbx4HeaderWriter().writeHeader(
            cipher: .aes256,
            compression: .gzip,
            cryptoInputs: cryptoInputs,
            kdfParameters: kdfParameters
        ) + Data("encrypted-payload-placeholder".utf8)
        let restoreResultDatabase = try DefaultKeePassKdbx4HeaderWriter().writeHeader(
            cipher: .aes256,
            compression: .gzip,
            cryptoInputs: cryptoInputs,
            kdfParameters: kdfParameters
        ) + Data("encrypted-payload-after-recycle-restore".utf8)
        try sourceDatabase.write(to: databaseURL)
        let restoreResult = KeePassKdbx4WritebackResult(
            database: restoreResultDatabase,
            headerBytes: Data([0x0B]),
            payloadSection: Data([0x0C]),
            xmlPayloadByteCount: 192,
            groupCount: 3,
            entryCount: 1,
            attachmentCount: 1
        )
        coordinator.result = restoreResult

        _ = try model.previewKeePassImport(from: databaseURL)
        _ = try model.prepareKeePassUnlockPreflight(password: "database-password")
        _ = try model.previewKeePassReadOnlyTree()

        let result = try model.restoreKeePassReadOnlyRecycleBinEntryAndWriteBack(
            entryID: "deleted-entry",
            targetGroupID: "work"
        )

        let request = try XCTUnwrap(coordinator.requests.first)
        let restoredEntry = try XCTUnwrap(request.snapshot.entries.first)
        XCTAssertEqual(result.database, restoreResult.database)
        XCTAssertEqual(restoredEntry.id, "deleted-entry")
        XCTAssertEqual(restoredEntry.groupID, "work")
        XCTAssertEqual(restoredEntry.groupPath, "/Work")
        XCTAssertFalse(restoredEntry.isDeleted)
        XCTAssertEqual(restoredEntry.decodedPassword, "deleted-entry-password-secret")
        XCTAssertEqual(restoredEntry.attachments.first?.decodedContent, attachmentSecret)
        XCTAssertEqual(writer.replacements.first?.data, restoreResult.database)
        [
            "deleted-entry-password-secret",
            "deleted entry note secret",
            "restored recycle attachment secret",
            "deleted-attachment-secret-hash",
            "encrypted-payload-after-recycle-restore",
            "database-password"
        ].forEach { secret in
            XCTAssertFalse(model.entryOperationState.label.contains(secret))
        }
        XCTAssertEqual(
            model.entryOperationState,
            .succeeded("KeePass 回收站条目已还原并写回：Deleted Login -> /Work")
        )
    }

    func testKeePassSnapshotAttachmentContentEditFailureIsRedactedAndKeepsSnapshot() throws {
        let snapshot = KeePassReadOnlySnapshot(
            sourceName: "personal.kdbx",
            headerSummary: KeePassHeaderSummary(majorVersion: 4, minorVersion: 0, formatVersion: .kdbx4),
            groups: [
                KeePassReadOnlyGroup(id: "root", title: "Root", path: "/", depth: 0)
            ],
            entries: [
                KeePassReadOnlyEntry(
                    id: "entry-1",
                    title: "Login",
                    username: "user@example.com",
                    url: "https://example.com",
                    groupPath: "/",
                    hasPassword: true,
                    decodedPassword: "existing-entry-password-secret",
                    hasTotp: false,
                    attachmentCount: 1,
                    isDeleted: false,
                    attachments: [
                        KeePassReadOnlyAttachment(
                            id: "attachment-1",
                            fileName: "secret.txt",
                            originalSize: 9,
                            contentHash: "sha256:existing-secret-hash",
                            decodedContent: Data("old bytes".utf8)
                        )
                    ]
                )
            ]
        )
        let model = AppSessionModel(
            keePassDatabaseReader: RecordingKeePassDatabaseReader(snapshot: snapshot)
        )
        model.keePassReadOnlySnapshot = snapshot

        XCTAssertThrowsError(
            try model.replaceKeePassReadOnlyAttachmentContent(
                entryID: "entry-1",
                attachmentID: "missing-attachment-secret-id",
                decodedContent: Data("replacement secret bytes".utf8)
            )
        ) { error in
            XCTAssertEqual(error as? AppKeePassSnapshotEditError, .attachmentUnavailable)
        }

        XCTAssertEqual(model.keePassReadOnlySnapshot, snapshot)
        XCTAssertEqual(model.entryOperationState, .failed("未找到可编辑的 KeePass 附件。"))
        [
            "existing-entry-password-secret",
            "existing-secret-hash",
            "missing-attachment-secret-id",
            "replacement secret bytes"
        ].forEach { secret in
            XCTAssertFalse(model.entryOperationState.label.contains(secret))
        }
    }

    func testKeePassConfirmImportCreatesLoginMetadataWithoutSecretsAndClearsPreviewState() throws {
        let engine = RecordingVaultEngine()
        let reader = RecordingKeePassDatabaseReader(
            snapshot: KeePassReadOnlySnapshot(
                sourceName: "personal.kdbx",
                headerSummary: KeePassHeaderSummary(majorVersion: 4, minorVersion: 0, formatVersion: .kdbx4),
                groups: [
                    KeePassReadOnlyGroup(id: "root", title: "Root", path: "/", depth: 0),
                    KeePassReadOnlyGroup(id: "work", title: "Work", path: "/Work", depth: 1)
                ],
                entries: [
                    KeePassReadOnlyEntry(
                        id: "entry-1",
                        title: "GitHub",
                        username: "alice",
                        url: "https://github.com",
                        groupPath: "/Work",
                        hasPassword: true,
                        hasTotp: true,
                        attachmentCount: 2,
                        isDeleted: false
                    )
                ]
            )
        )
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            keePassDatabaseReader: reader
        )
        let kdbx = Data([
            0x03, 0xD9, 0xA2, 0x9A,
            0x67, 0xFB, 0x4B, 0xB5,
            0x00, 0x00, 0x04, 0x00
        ])

        try unlockNewVault(model)
        _ = try model.previewKeePassImport(kdbx, fileName: "personal.kdbx")
        _ = try model.prepareKeePassUnlockPreflight(
            password: "database-password",
            keyFile: Data("key-file-secret".utf8),
            keyFileName: "personal.key"
        )
        _ = try model.previewKeePassReadOnlyImportPlan()

        try model.confirmKeePassReadOnlyImport(projectTitle: "KeePass")

        XCTAssertEqual(engine.createdProjects.map(\.title), ["KeePass / Work"])
        XCTAssertEqual(engine.createdLoginEntries.count, 1)
        XCTAssertEqual(engine.createdLoginEntries.first?.draft.title, "GitHub")
        XCTAssertEqual(engine.createdLoginEntries.first?.draft.username, "alice")
        XCTAssertEqual(engine.createdLoginEntries.first?.draft.url, "https://github.com")
        XCTAssertEqual(engine.createdLoginEntries.first?.draft.password, "")
        XCTAssertEqual(engine.createdTotpEntries.count, 1)
        XCTAssertEqual(engine.createdTotpEntries.first?.draft.title, "GitHub TOTP")
        XCTAssertEqual(engine.createdTotpEntries.first?.draft.secret, "")
        XCTAssertEqual(model.loginEntries.map(\.title), ["GitHub"])
        XCTAssertEqual(model.totpEntries.map(\.title), ["GitHub TOTP"])
        XCTAssertNil(model.keePassImportPreview)
        XCTAssertNil(model.keePassReadOnlySnapshot)
        XCTAssertNil(model.keePassReadOnlyImportPlan)
        XCTAssertEqual(model.keePassUnlockPassword, "")
        XCTAssertNil(model.keePassKeyFileData)
        XCTAssertEqual(model.keePassKeyFileName, "")
        XCTAssertFalse(model.entryOperationState.label.contains("database-password"))
        XCTAssertFalse(model.entryOperationState.label.contains("key-file-secret"))
        XCTAssertEqual(
            model.entryOperationState,
            .succeeded("KeePass 已导入 1 项元数据，并创建 1 个 TOTP 占位项；待解码：1 个密码字段，1 个 TOTP，2 个附件")
        )
    }

    func testKeePassConfirmImportMapsGroupPathsToVaultCategories() throws {
        let engine = RecordingVaultEngine()
        let reader = RecordingKeePassDatabaseReader(
            snapshot: KeePassReadOnlySnapshot(
                sourceName: "personal.kdbx",
                headerSummary: KeePassHeaderSummary(majorVersion: 4, minorVersion: 0, formatVersion: .kdbx4),
                groups: [
                    KeePassReadOnlyGroup(id: "root", title: "Root", path: "/", depth: 0),
                    KeePassReadOnlyGroup(id: "work", title: "Work", path: "/Work", depth: 1),
                    KeePassReadOnlyGroup(id: "personal", title: "Personal", path: "/Personal", depth: 1)
                ],
                entries: [
                    KeePassReadOnlyEntry(
                        id: "entry-uuid-github",
                        title: "GitHub",
                        username: "alice",
                        url: "https://github.com",
                        groupPath: "/Work",
                        groupID: "group-uuid-work",
                        hasPassword: true,
                        hasTotp: false,
                        attachmentCount: 0,
                        isDeleted: false
                    ),
                    KeePassReadOnlyEntry(
                        id: "entry-uuid-bank",
                        title: "Bank",
                        username: "alice",
                        url: "https://bank.example",
                        groupPath: "/Personal",
                        groupID: "group-uuid-personal",
                        hasPassword: true,
                        hasTotp: false,
                        attachmentCount: 0,
                        isDeleted: false
                    )
                ]
            )
        )
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            keePassDatabaseReader: reader
        )
        let kdbx = Data([
            0x03, 0xD9, 0xA2, 0x9A,
            0x67, 0xFB, 0x4B, 0xB5,
            0x00, 0x00, 0x04, 0x00
        ])

        try unlockNewVault(model)
        _ = try model.previewKeePassImport(kdbx, fileName: "personal.kdbx")
        _ = try model.prepareKeePassUnlockPreflight(password: "database-password")
        _ = try model.previewKeePassReadOnlyImportPlan()

        try model.confirmKeePassReadOnlyImport(projectTitle: "KeePass")

        XCTAssertEqual(engine.createdProjects.map(\.title), ["KeePass / Work", "KeePass / Personal"])
        XCTAssertEqual(model.vaultProjects.map(\.title), ["KeePass / Work", "KeePass / Personal"])
        XCTAssertEqual(engine.createdLoginEntries.map(\.draft.title), ["GitHub", "Bank"])
        XCTAssertEqual(engine.createdLoginEntries.map(\.projectID), ["project-1", "project-2"])
        XCTAssertEqual(model.activeVaultCategoryTitle, "KeePass / Work")
        XCTAssertEqual(model.loginEntries.map(\.title), ["GitHub"])
        XCTAssertEqual(
            model.keePassLastMetadataImportReferences,
            [
                AppKeePassImportedEntryReference(
                    sourceEntryID: "entry-uuid-github",
                    sourceGroupID: "group-uuid-work",
                    sourceGroupPath: "/Work",
                    importedLoginEntryID: "entry-1",
                    importedProjectID: "project-1"
                ),
                AppKeePassImportedEntryReference(
                    sourceEntryID: "entry-uuid-bank",
                    sourceGroupID: "group-uuid-personal",
                    sourceGroupPath: "/Personal",
                    importedLoginEntryID: "entry-2",
                    importedProjectID: "project-2"
                )
            ]
        )
        XCTAssertFalse(model.entryOperationState.label.contains("entry-uuid-github"))
        XCTAssertFalse(model.entryOperationState.label.contains("group-uuid-work"))
        XCTAssertEqual(model.entryOperationState, .succeeded("KeePass 已导入 2 项元数据；待解码：2 个密码字段"))

        _ = try model.previewKeePassImport(kdbx, fileName: "other.kdbx")

        XCTAssertTrue(model.keePassLastMetadataImportReferences.isEmpty)
    }

    func testKeePassConfirmImportCreatesTotpPlaceholdersForPendingTotpMetadata() throws {
        let engine = RecordingVaultEngine()
        let reader = RecordingKeePassDatabaseReader(
            snapshot: KeePassReadOnlySnapshot(
                sourceName: "personal.kdbx",
                headerSummary: KeePassHeaderSummary(majorVersion: 4, minorVersion: 0, formatVersion: .kdbx4),
                groups: [
                    KeePassReadOnlyGroup(id: "root", title: "Root", path: "/", depth: 0),
                    KeePassReadOnlyGroup(id: "work", title: "Work", path: "/Work", depth: 1)
                ],
                entries: [
                    KeePassReadOnlyEntry(
                        id: "entry-uuid-github",
                        title: "GitHub",
                        username: "alice@example.com",
                        url: "https://github.com",
                        groupPath: "/Work",
                        groupID: "group-uuid-work",
                        hasPassword: true,
                        hasTotp: true,
                        attachmentCount: 0,
                        isDeleted: false
                    )
                ]
            )
        )
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            keePassDatabaseReader: reader
        )
        let kdbx = Data([
            0x03, 0xD9, 0xA2, 0x9A,
            0x67, 0xFB, 0x4B, 0xB5,
            0x00, 0x00, 0x04, 0x00
        ])

        try unlockNewVault(model)
        _ = try model.previewKeePassImport(kdbx, fileName: "personal.kdbx")
        _ = try model.prepareKeePassUnlockPreflight(
            password: "database-password",
            keyFile: Data("key-file-secret".utf8),
            keyFileName: "personal.key"
        )
        _ = try model.previewKeePassReadOnlyImportPlan()

        try model.confirmKeePassReadOnlyImport(projectTitle: "KeePass")

        XCTAssertEqual(engine.createdLoginEntries.count, 1)
        XCTAssertEqual(engine.createdTotpEntries.count, 1)
        XCTAssertEqual(engine.createdTotpEntries.first?.projectID, "project-1")
        XCTAssertEqual(engine.createdTotpEntries.first?.draft.title, "GitHub TOTP")
        XCTAssertEqual(engine.createdTotpEntries.first?.draft.secret, "")
        XCTAssertEqual(engine.createdTotpEntries.first?.draft.issuer, "GitHub")
        XCTAssertEqual(engine.createdTotpEntries.first?.draft.accountName, "alice@example.com")
        XCTAssertEqual(engine.createdTotpEntries.first?.draft.period, 30)
        XCTAssertEqual(engine.createdTotpEntries.first?.draft.digits, 6)
        XCTAssertEqual(engine.createdTotpEntries.first?.draft.algorithm, "SHA1")
        XCTAssertEqual(model.totpEntries.map(\.title), ["GitHub TOTP"])
        XCTAssertEqual(model.totpEntries.first?.secret, "")
        XCTAssertEqual(
            model.keePassLastMetadataImportReferences,
            [
                AppKeePassImportedEntryReference(
                    sourceEntryID: "entry-uuid-github",
                    sourceGroupID: "group-uuid-work",
                    sourceGroupPath: "/Work",
                    importedLoginEntryID: "entry-1",
                    importedTotpEntryID: "totp-1",
                    importedProjectID: "project-1"
                )
            ]
        )
        XCTAssertFalse(model.entryOperationState.label.contains("entry-uuid-github"))
        XCTAssertFalse(model.entryOperationState.label.contains("group-uuid-work"))
        XCTAssertFalse(model.entryOperationState.label.contains("database-password"))
        XCTAssertFalse(model.entryOperationState.label.contains("key-file-secret"))
        XCTAssertEqual(
            model.entryOperationState,
            .succeeded("KeePass 已导入 1 项元数据，并创建 1 个 TOTP 占位项；待解码：1 个密码字段，1 个 TOTP")
        )
    }

    func testKeePassConfirmImportImportsDecodedPasswordAndTotpSecretWithoutLeakingSecrets() throws {
        let engine = RecordingVaultEngine()
        let reader = RecordingKeePassDatabaseReader(
            snapshot: KeePassReadOnlySnapshot(
                sourceName: "personal.kdbx",
                headerSummary: KeePassHeaderSummary(majorVersion: 4, minorVersion: 0, formatVersion: .kdbx4),
                groups: [
                    KeePassReadOnlyGroup(id: "root", title: "Root", path: "/", depth: 0),
                    KeePassReadOnlyGroup(id: "work", title: "Work", path: "/Work", depth: 1)
                ],
                entries: [
                    KeePassReadOnlyEntry(
                        id: "entry-uuid-github",
                        title: "GitHub",
                        username: "alice@example.com",
                        url: "https://github.com",
                        groupPath: "/Work",
                        groupID: "group-uuid-work",
                        hasPassword: true,
                        decodedPassword: "decoded-login-password",
                        hasTotp: true,
                        decodedTotp: KeePassReadOnlyTotpSecret(
                            secret: "JBSWY3DPEHPK3PXP",
                            issuer: "GitHub",
                            accountName: "alice@example.com",
                            period: 45,
                            digits: 8,
                            algorithm: "SHA256"
                        ),
                        attachmentCount: 0,
                        isDeleted: false
                    )
                ]
            )
        )
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            keePassDatabaseReader: reader
        )
        let kdbx = Data([
            0x03, 0xD9, 0xA2, 0x9A,
            0x67, 0xFB, 0x4B, 0xB5,
            0x00, 0x00, 0x04, 0x00
        ])

        try unlockNewVault(model)
        _ = try model.previewKeePassImport(kdbx, fileName: "personal.kdbx")
        _ = try model.prepareKeePassUnlockPreflight(password: "database-password")
        _ = try model.previewKeePassReadOnlyImportPlan()

        try model.confirmKeePassReadOnlyImport(projectTitle: "KeePass")

        XCTAssertEqual(engine.createdLoginEntries.count, 1)
        XCTAssertEqual(engine.createdLoginEntries.first?.draft.password, "decoded-login-password")
        XCTAssertEqual(engine.createdTotpEntries.count, 1)
        XCTAssertEqual(engine.createdTotpEntries.first?.draft.secret, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(engine.createdTotpEntries.first?.draft.issuer, "GitHub")
        XCTAssertEqual(engine.createdTotpEntries.first?.draft.accountName, "alice@example.com")
        XCTAssertEqual(engine.createdTotpEntries.first?.draft.period, 45)
        XCTAssertEqual(engine.createdTotpEntries.first?.draft.digits, 8)
        XCTAssertEqual(engine.createdTotpEntries.first?.draft.algorithm, "SHA256")
        XCTAssertEqual(model.loginEntries.first?.password, "decoded-login-password")
        XCTAssertEqual(model.totpEntries.first?.secret, "JBSWY3DPEHPK3PXP")
        XCTAssertFalse(model.entryOperationState.label.contains("decoded-login-password"))
        XCTAssertFalse(model.entryOperationState.label.contains("JBSWY3DPEHPK3PXP"))
        XCTAssertFalse(model.entryOperationState.label.contains("database-password"))
        XCTAssertEqual(
            model.entryOperationState,
            .succeeded("KeePass 已导入 1 项元数据，并导入 1 个密码字段，并导入 1 个 TOTP 密钥")
        )
    }

    func testKeePassConfirmImportImportsNotesAndCustomFieldsWithoutLeakingValues() throws {
        let engine = RecordingVaultEngine()
        let reader = RecordingKeePassDatabaseReader(
            snapshot: KeePassReadOnlySnapshot(
                sourceName: "personal.kdbx",
                headerSummary: KeePassHeaderSummary(majorVersion: 4, minorVersion: 0, formatVersion: .kdbx4),
                groups: [
                    KeePassReadOnlyGroup(id: "root", title: "Root", path: "/", depth: 0),
                    KeePassReadOnlyGroup(id: "work", title: "Work", path: "/Work", depth: 1)
                ],
                entries: [
                    KeePassReadOnlyEntry(
                        id: "entry-uuid-github",
                        title: "GitHub",
                        username: "alice",
                        url: "https://github.com",
                        groupPath: "/Work",
                        groupID: "group-uuid-work",
                        notes: "decoded KeePass notes secret",
                        customFields: [
                            KeePassReadOnlyCustomField(
                                title: "Recovery Code",
                                value: "decoded recovery code secret",
                                isProtected: true,
                                sortOrder: 2
                            ),
                            KeePassReadOnlyCustomField(
                                title: "Environment",
                                value: "Production",
                                isProtected: false,
                                sortOrder: 1
                            )
                        ],
                        hasPassword: false,
                        hasTotp: false,
                        attachmentCount: 0,
                        isDeleted: false
                    )
                ]
            )
        )
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            keePassDatabaseReader: reader
        )
        let kdbx = Data([
            0x03, 0xD9, 0xA2, 0x9A,
            0x67, 0xFB, 0x4B, 0xB5,
            0x00, 0x00, 0x04, 0x00
        ])

        try unlockNewVault(model)
        _ = try model.previewKeePassImport(kdbx, fileName: "personal.kdbx")
        _ = try model.prepareKeePassUnlockPreflight(password: "database-password")
        _ = try model.previewKeePassReadOnlyImportPlan()

        try model.confirmKeePassReadOnlyImport(projectTitle: "KeePass")

        let expectedNotes = """
        decoded KeePass notes secret

        KeePass 字段：
        Environment: Production
        Recovery Code: decoded recovery code secret
        """
        XCTAssertEqual(engine.createdLoginEntries.first?.draft.notes, expectedNotes)
        XCTAssertEqual(model.loginEntries.first?.notes, expectedNotes)
        [
            "decoded KeePass notes secret",
            "decoded recovery code secret",
            "Production",
            "database-password"
        ].forEach { secret in
            XCTAssertFalse(model.entryOperationState.label.contains(secret))
        }
        XCTAssertEqual(
            model.entryOperationState,
            .succeeded("KeePass 已导入 1 项元数据，并导入 1 项备注/自定义字段")
        )
    }

    func testKeePassConfirmImportCreatesAttachmentPlaceholdersForPendingAttachmentMetadata() throws {
        let engine = RecordingVaultEngine()
        let reader = RecordingKeePassDatabaseReader(
            snapshot: KeePassReadOnlySnapshot(
                sourceName: "personal.kdbx",
                headerSummary: KeePassHeaderSummary(majorVersion: 4, minorVersion: 0, formatVersion: .kdbx4),
                groups: [
                    KeePassReadOnlyGroup(id: "root", title: "Root", path: "/", depth: 0),
                    KeePassReadOnlyGroup(id: "work", title: "Work", path: "/Work", depth: 1)
                ],
                entries: [
                    KeePassReadOnlyEntry(
                        id: "entry-uuid-github",
                        title: "GitHub",
                        username: "alice",
                        url: "https://github.com",
                        groupPath: "/Work",
                        groupID: "group-uuid-work",
                        hasPassword: true,
                        hasTotp: false,
                        attachmentCount: 2,
                        isDeleted: false,
                        attachments: [
                            KeePassReadOnlyAttachment(
                                id: "attachment-uuid-contract",
                                fileName: "contract.pdf",
                                mediaType: "application/pdf",
                                originalSize: 2048,
                                contentHash: "sha256:contract"
                            ),
                            KeePassReadOnlyAttachment(
                                id: "attachment-uuid-notes",
                                fileName: "notes.txt",
                                mediaType: "text/plain",
                                originalSize: 512,
                                contentHash: "sha256:notes"
                            )
                        ]
                    )
                ]
            )
        )
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            keePassDatabaseReader: reader
        )
        let kdbx = Data([
            0x03, 0xD9, 0xA2, 0x9A,
            0x67, 0xFB, 0x4B, 0xB5,
            0x00, 0x00, 0x04, 0x00
        ])

        try unlockNewVault(model)
        _ = try model.previewKeePassImport(kdbx, fileName: "personal.kdbx")
        _ = try model.prepareKeePassUnlockPreflight(
            password: "database-password",
            keyFile: Data("key-file-secret".utf8),
            keyFileName: "personal.key"
        )
        _ = try model.previewKeePassReadOnlyImportPlan()

        try model.confirmKeePassReadOnlyImport(projectTitle: "KeePass")

        XCTAssertEqual(engine.createdLoginEntries.map(\.draft.title), ["GitHub"])
        XCTAssertEqual(
            engine.createdAttachmentMetadata,
            [
                RecordedAttachmentMetadataCall(
                    vaultID: "created-vault",
                    projectID: "project-1",
                    entryID: "entry-1",
                    fileName: "contract.pdf",
                    mediaType: "application/pdf",
                    originalSize: 2048,
                    storedSize: 0,
                    contentHash: "sha256:contract",
                    storageMode: "keepass-kdbx-placeholder",
                    source: "KeePass",
                    downloadState: "pending-kdbx-decode",
                    wrappedContentEncryptionKey: nil,
                    localPath: nil
                ),
                RecordedAttachmentMetadataCall(
                    vaultID: "created-vault",
                    projectID: "project-1",
                    entryID: "entry-1",
                    fileName: "notes.txt",
                    mediaType: "text/plain",
                    originalSize: 512,
                    storedSize: 0,
                    contentHash: "sha256:notes",
                    storageMode: "keepass-kdbx-placeholder",
                    source: "KeePass",
                    downloadState: "pending-kdbx-decode",
                    wrappedContentEncryptionKey: nil,
                    localPath: nil
                )
            ]
        )
        XCTAssertEqual(model.attachmentEntries.map(\.fileName), ["contract.pdf", "notes.txt"])
        XCTAssertEqual(model.attachmentEntries.map(\.entryID), ["entry-1", "entry-1"])
        XCTAssertEqual(
            model.keePassLastMetadataImportReferences,
            [
                AppKeePassImportedEntryReference(
                    sourceEntryID: "entry-uuid-github",
                    sourceGroupID: "group-uuid-work",
                    sourceGroupPath: "/Work",
                    importedLoginEntryID: "entry-1",
                    importedProjectID: "project-1",
                    importedAttachmentEntryIDs: ["attachment-1", "attachment-2"]
                )
            ]
        )
        XCTAssertFalse(model.entryOperationState.label.contains("attachment-uuid-contract"))
        XCTAssertFalse(model.entryOperationState.label.contains("attachment-uuid-notes"))
        XCTAssertFalse(model.entryOperationState.label.contains("database-password"))
        XCTAssertFalse(model.entryOperationState.label.contains("key-file-secret"))
        XCTAssertEqual(
            model.entryOperationState,
            .succeeded("KeePass 已导入 1 项元数据，并创建 2 个附件占位项；待解码：1 个密码字段，2 个附件")
        )
    }

    func testKeePassConfirmImportStoresDecodedAttachmentContentForPreviewWithoutLeakingSecrets() throws {
        let engine = RecordingVaultEngine()
        let blobStore = RecordingAndroidBackupAttachmentBlobStore()
        let decodedContent = Data("decoded keepass attachment plaintext".utf8)
        let reader = RecordingKeePassDatabaseReader(
            snapshot: KeePassReadOnlySnapshot(
                sourceName: "personal.kdbx",
                headerSummary: KeePassHeaderSummary(majorVersion: 4, minorVersion: 0, formatVersion: .kdbx4),
                groups: [
                    KeePassReadOnlyGroup(id: "root", title: "Root", path: "/", depth: 0),
                    KeePassReadOnlyGroup(id: "work", title: "Work", path: "/Work", depth: 1)
                ],
                entries: [
                    KeePassReadOnlyEntry(
                        id: "entry-uuid-github",
                        title: "GitHub",
                        username: "alice",
                        url: "https://github.com",
                        groupPath: "/Work",
                        groupID: "group-uuid-work",
                        hasPassword: false,
                        hasTotp: false,
                        attachmentCount: 1,
                        isDeleted: false,
                        attachments: [
                            KeePassReadOnlyAttachment(
                                id: "attachment-uuid-contract",
                                fileName: "../contract secret.pdf",
                                mediaType: "application/pdf",
                                originalSize: Int64(decodedContent.count),
                                contentHash: "sha256:decoded-secret",
                                decodedContent: decodedContent
                            )
                        ]
                    )
                ]
            )
        )
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            androidBackupAttachmentBlobStore: blobStore,
            keePassDatabaseReader: reader
        )
        let kdbx = Data([
            0x03, 0xD9, 0xA2, 0x9A,
            0x67, 0xFB, 0x4B, 0xB5,
            0x00, 0x00, 0x04, 0x00
        ])

        try unlockNewVault(model)
        _ = try model.previewKeePassImport(kdbx, fileName: "personal.kdbx")
        _ = try model.prepareKeePassUnlockPreflight(password: "database-password")
        _ = try model.previewKeePassReadOnlyImportPlan()

        try model.confirmKeePassReadOnlyImport(projectTitle: "KeePass")

        XCTAssertEqual(blobStore.savedBlobs.count, 1)
        XCTAssertEqual(blobStore.savedBlobs.first?.vaultID, "created-vault")
        XCTAssertEqual(blobStore.savedBlobs.first?.data, decodedContent)
        XCTAssertEqual(blobStore.savedBlobs.first?.localPath, "keepass-kdbx-attachment-attachment-uuid-contract-contract_secret.pdf")
        XCTAssertEqual(
            engine.createdAttachmentMetadata,
            [
                RecordedAttachmentMetadataCall(
                    vaultID: "created-vault",
                    projectID: "project-1",
                    entryID: "entry-1",
                    fileName: "contract_secret.pdf",
                    mediaType: "application/pdf",
                    originalSize: Int64(decodedContent.count),
                    storedSize: Int64(decodedContent.count),
                    contentHash: "sha256:decoded-secret",
                    storageMode: "keepass-kdbx-decoded-content",
                    source: "KeePass",
                    downloadState: "downloaded",
                    wrappedContentEncryptionKey: nil,
                    localPath: "keepass-kdbx-attachment-attachment-uuid-contract-contract_secret.pdf"
                )
            ]
        )
        XCTAssertEqual(model.attachmentEntries.first?.storageMode, "keepass-kdbx-decoded-content")
        XCTAssertEqual(model.attachmentEntries.first?.downloadState, "downloaded")
        XCTAssertEqual(model.entryOperationState, .succeeded("KeePass 已导入 1 项元数据，并导入 1 个附件内容"))

        let attachment = try XCTUnwrap(model.attachmentEntries.first)
        try model.presentAttachmentQuickLookPreview(attachment)
        defer {
            model.dismissAttachmentQuickLookPreview()
        }

        let previewURL = try XCTUnwrap(model.attachmentQuickLookPreviewURL)
        XCTAssertEqual(try Data(contentsOf: previewURL), decodedContent)
        XCTAssertEqual(previewURL.lastPathComponent, "contract_secret.pdf")
        [
            "decoded keepass attachment plaintext",
            "sha256:decoded-secret",
            "database-password"
        ].forEach { secret in
            XCTAssertFalse(model.entryOperationState.label.contains(secret))
        }
    }

    func testKeePassConfirmImportPreservesRecycleBinEntriesAsDeletedMetadata() throws {
        let engine = RecordingVaultEngine()
        let reader = RecordingKeePassDatabaseReader(
            snapshot: KeePassReadOnlySnapshot(
                sourceName: "personal.kdbx",
                headerSummary: KeePassHeaderSummary(majorVersion: 4, minorVersion: 0, formatVersion: .kdbx4),
                groups: [
                    KeePassReadOnlyGroup(id: "root", title: "Root", path: "/", depth: 0),
                    KeePassReadOnlyGroup(id: "work", title: "Work", path: "/Work", depth: 1),
                    KeePassReadOnlyGroup(id: "trash", title: "Recycle Bin", path: "/Recycle Bin", depth: 1)
                ],
                entries: [
                    KeePassReadOnlyEntry(
                        id: "entry-uuid-active",
                        title: "GitHub",
                        username: "alice",
                        url: "https://github.com",
                        groupPath: "/Work",
                        groupID: "group-uuid-work",
                        hasPassword: true,
                        hasTotp: false,
                        attachmentCount: 0,
                        isDeleted: false
                    ),
                    KeePassReadOnlyEntry(
                        id: "entry-uuid-deleted",
                        title: "Old Login",
                        username: "bob",
                        url: "https://old.example",
                        groupPath: "/Recycle Bin",
                        groupID: "group-uuid-trash",
                        hasPassword: true,
                        hasTotp: false,
                        attachmentCount: 0,
                        isDeleted: true
                    )
                ]
            )
        )
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            keePassDatabaseReader: reader
        )
        let kdbx = Data([
            0x03, 0xD9, 0xA2, 0x9A,
            0x67, 0xFB, 0x4B, 0xB5,
            0x00, 0x00, 0x04, 0x00
        ])

        try unlockNewVault(model)
        _ = try model.previewKeePassImport(kdbx, fileName: "personal.kdbx")
        _ = try model.prepareKeePassUnlockPreflight(
            password: "database-password",
            keyFile: Data("key-file-secret".utf8),
            keyFileName: "personal.key"
        )
        _ = try model.previewKeePassReadOnlyImportPlan()

        try model.confirmKeePassReadOnlyImport(projectTitle: "KeePass")

        XCTAssertEqual(engine.createdProjects.map(\.title), ["KeePass / Work", "KeePass / Recycle Bin"])
        XCTAssertEqual(engine.createdLoginEntries.map(\.draft.title), ["GitHub", "Old Login"])
        XCTAssertEqual(engine.createdLoginEntries.map(\.draft.password), ["", ""])
        XCTAssertEqual(engine.deletedLoginEntries.map(\.entryID), ["entry-2"])
        XCTAssertEqual(model.activeVaultCategoryTitle, "KeePass / Work")
        XCTAssertEqual(model.loginEntries.map(\.title), ["GitHub"])
        XCTAssertTrue(model.deletedLoginEntries.isEmpty)
        XCTAssertFalse(model.entryOperationState.label.contains("entry-uuid-deleted"))
        XCTAssertFalse(model.entryOperationState.label.contains("group-uuid-trash"))
        XCTAssertFalse(model.entryOperationState.label.contains("database-password"))
        XCTAssertFalse(model.entryOperationState.label.contains("key-file-secret"))
        XCTAssertEqual(
            model.entryOperationState,
            .succeeded("KeePass 已导入 2 项元数据，并保留 1 项回收站元数据；待解码：2 个密码字段")
        )
        try model.switchVaultCategory(projectID: "project-2")
        XCTAssertTrue(model.loginEntries.isEmpty)
        XCTAssertEqual(model.deletedLoginEntries.map(\.title), ["Old Login"])
        XCTAssertEqual(
            model.keePassLastMetadataImportReferences,
            [
                AppKeePassImportedEntryReference(
                    sourceEntryID: "entry-uuid-active",
                    sourceGroupID: "group-uuid-work",
                    sourceGroupPath: "/Work",
                    importedLoginEntryID: "entry-1",
                    importedProjectID: "project-1",
                    importedAsDeleted: false
                ),
                AppKeePassImportedEntryReference(
                    sourceEntryID: "entry-uuid-deleted",
                    sourceGroupID: "group-uuid-trash",
                    sourceGroupPath: "/Recycle Bin",
                    importedLoginEntryID: "entry-2",
                    importedProjectID: "project-2",
                    importedAsDeleted: true
                )
            ]
        )
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

    func testAndroidBackupAttachmentContentCanBeLoadedFromLocalBlobStoreWithoutLeakingSecrets() throws {
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

        let attachment = try XCTUnwrap(model.attachmentEntries.first)
        let status = model.attachmentContentStatus(for: attachment)
        let blob = try model.loadAttachmentEncryptedBlob(attachment)

        XCTAssertEqual(status.state, .available)
        XCTAssertEqual(status.value, "10 字节")
        XCTAssertEqual(status.detail, "附件密文已保存在本机，可进入预览恢复流程。")
        XCTAssertEqual(blob, Data("ciphertext".utf8))
        [
            "abc123",
            "wrapped-key",
            "attachment-1.enc",
            "ciphertext",
            "secret-password"
        ].forEach { secret in
            XCTAssertFalse(status.detail.contains(secret))
            XCTAssertFalse(model.entryOperationState.label.contains(secret))
        }
    }

    func testAndroidBackupAttachmentPreviewMaterializesDecryptedTempFileWithoutLeakingSecrets() throws {
        let engine = RecordingVaultEngine()
        let blobStore = RecordingAndroidBackupAttachmentBlobStore()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            androidBackupAttachmentBlobStore: blobStore
        )
        let cek = Data((0..<32).map(UInt8.init))
        let nonceData = Data((100..<112).map(UInt8.init))
        let plaintext = Data("sensitive contract plaintext".utf8)
        let sealedBox = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: cek),
            nonce: try AES.GCM.Nonce(data: nonceData)
        )
        let encryptedBlob = try XCTUnwrap(sealedBox.combined)

        try unlockNewVault(model)
        let project = try model.createVaultCategory(title: "Attachments")
        let attachment = LocalAttachmentMetadata(
            id: "attachment-1",
            projectID: project.id,
            entryID: "entry-1",
            fileName: "../contract secret.pdf",
            mediaType: "application/pdf",
            originalSize: Int64(plaintext.count),
            storedSize: Int64(encryptedBlob.count),
            contentHash: "sha256:secret-hash",
            storageMode: "android-backup-encrypted-blob",
            source: "android-backup-local",
            downloadState: "downloaded",
            wrappedContentEncryptionKey: "wrapped-secret-key",
            localPath: "../attachment-1.enc",
            deleted: false
        )
        model.attachmentEntries = [attachment]
        _ = try blobStore.saveEncryptedBlob(
            encryptedBlob,
            vaultID: "created-vault",
            localPath: "../attachment-1.enc"
        )

        let preview = try model.materializeAttachmentPreview(
            attachment,
            contentEncryptionKey: cek
        )
        defer {
            try? FileManager.default.removeItem(at: preview.fileURL.deletingLastPathComponent())
        }

        XCTAssertEqual(try Data(contentsOf: preview.fileURL), plaintext)
        XCTAssertEqual(preview.displayFileName, "contract_secret.pdf")
        XCTAssertEqual(preview.byteCount, plaintext.count)
        XCTAssertTrue(preview.fileURL.lastPathComponent.hasSuffix(".pdf"))
        XCTAssertFalse(preview.fileURL.lastPathComponent.contains(".."))
        let leakedSecrets: [String] = [
            "sha256:secret-hash",
            "wrapped-secret-key",
            "attachment-1.enc",
            "sensitive contract plaintext"
        ]
        leakedSecrets.forEach { secret in
            XCTAssertFalse(model.entryOperationState.label.contains(secret))
            XCTAssertFalse(preview.displayFileName.contains(secret))
        }
    }

    func testAttachmentQuickLookPreviewUsesInjectedContentKeyAndCleansTemporaryFile() throws {
        let engine = RecordingVaultEngine()
        let blobStore = RecordingAndroidBackupAttachmentBlobStore()
        let cek = Data((0..<32).map(UInt8.init))
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            androidBackupAttachmentBlobStore: blobStore,
            attachmentContentEncryptionKeyProvider: { attachment in
                XCTAssertEqual(attachment.fileName, "contract.pdf")
                return cek
            }
        )
        let nonceData = Data((120..<132).map(UInt8.init))
        let plaintext = Data("quicklook plaintext".utf8)
        let sealedBox = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: cek),
            nonce: try AES.GCM.Nonce(data: nonceData)
        )
        let encryptedBlob = try XCTUnwrap(sealedBox.combined)

        try unlockNewVault(model)
        let project = try model.createVaultCategory(title: "Attachments")
        let attachment = LocalAttachmentMetadata(
            id: "attachment-1",
            projectID: project.id,
            entryID: "entry-1",
            fileName: "contract.pdf",
            mediaType: "application/pdf",
            originalSize: Int64(plaintext.count),
            storedSize: Int64(encryptedBlob.count),
            contentHash: "sha256:quicklook-secret-hash",
            storageMode: "android-backup-encrypted-blob",
            source: "android-backup-local",
            downloadState: "downloaded",
            wrappedContentEncryptionKey: "wrapped-quicklook-secret-key",
            localPath: "attachment-1.enc",
            deleted: false
        )
        model.attachmentEntries = [attachment]
        _ = try blobStore.saveEncryptedBlob(
            encryptedBlob,
            vaultID: "created-vault",
            localPath: "attachment-1.enc"
        )

        try model.presentAttachmentQuickLookPreview(attachment)

        let previewURL = try XCTUnwrap(model.attachmentQuickLookPreviewURL)
        XCTAssertEqual(try Data(contentsOf: previewURL), plaintext)
        XCTAssertEqual(previewURL.lastPathComponent, "contract.pdf")
        XCTAssertFalse(model.entryOperationState.label.contains("sha256:quicklook-secret-hash"))
        XCTAssertFalse(model.entryOperationState.label.contains("wrapped-quicklook-secret-key"))
        XCTAssertFalse(model.entryOperationState.label.contains("attachment-1.enc"))
        XCTAssertFalse(model.entryOperationState.label.contains("quicklook plaintext"))

        model.dismissAttachmentQuickLookPreview()

        XCTAssertNil(model.attachmentQuickLookPreviewURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: previewURL.path))
    }

    func testAttachmentQuickLookPreviewUnwrapsAndroidWrappedCekWithoutRawKeyProvider() throws {
        let engine = RecordingVaultEngine()
        let blobStore = RecordingAndroidBackupAttachmentBlobStore()
        let cek = Data((0..<32).map(UInt8.init))
        let mdk = Data((100..<132).map(UInt8.init))
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            androidBackupAttachmentBlobStore: blobStore,
            androidAttachmentWrappingKeyProvider: { attachment in
                XCTAssertEqual(attachment.id, "attachment-1")
                return .mdk(mdk)
            }
        )
        let nonceData = Data((120..<132).map(UInt8.init))
        let plaintext = Data("wrapped cek quicklook plaintext".utf8)
        let sealedBlob = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: cek),
            nonce: try AES.GCM.Nonce(data: nonceData)
        )
        let encryptedBlob = try XCTUnwrap(sealedBlob.combined)
        let wrappedCekPayload = try AES.GCM.seal(
            Data(cek.base64EncodedString().utf8),
            using: SymmetricKey(data: mdk),
            nonce: try AES.GCM.Nonce(data: Data((40..<52).map(UInt8.init)))
        )
        let wrappedCekCombined = try XCTUnwrap(wrappedCekPayload.combined)
        let wrappedCek = "MDK|" + wrappedCekCombined.base64EncodedString()

        try unlockNewVault(model)
        let project = try model.createVaultCategory(title: "Attachments")
        let attachment = LocalAttachmentMetadata(
            id: "attachment-1",
            projectID: project.id,
            entryID: "entry-1",
            fileName: "contract.pdf",
            mediaType: "application/pdf",
            originalSize: Int64(plaintext.count),
            storedSize: Int64(encryptedBlob.count),
            contentHash: "sha256:wrapped-cek-secret-hash",
            storageMode: "android-backup-encrypted-blob",
            source: "android-backup-local",
            downloadState: "downloaded",
            wrappedContentEncryptionKey: wrappedCek,
            localPath: "attachment-1.enc",
            deleted: false
        )
        model.attachmentEntries = [attachment]
        _ = try blobStore.saveEncryptedBlob(
            encryptedBlob,
            vaultID: "created-vault",
            localPath: "attachment-1.enc"
        )

        try model.presentAttachmentQuickLookPreview(attachment)

        let previewURL = try XCTUnwrap(model.attachmentQuickLookPreviewURL)
        XCTAssertEqual(try Data(contentsOf: previewURL), plaintext)
        XCTAssertEqual(previewURL.lastPathComponent, "contract.pdf")
        [
            "wrapped cek quicklook plaintext",
            "sha256:wrapped-cek-secret-hash",
            wrappedCek,
            cek.base64EncodedString(),
            mdk.map { String(format: "%02x", $0) }.joined()
        ].forEach { secret in
            XCTAssertFalse(model.entryOperationState.label.contains(secret))
        }

        model.dismissAttachmentQuickLookPreview()
        XCTAssertFalse(FileManager.default.fileExists(atPath: previewURL.path))
    }

    func testAttachmentQuickLookPreviewAppendsRedactedContentTimelineEvent() throws {
        let engine = RecordingVaultEngine()
        let blobStore = RecordingAndroidBackupAttachmentBlobStore()
        let cek = Data((0..<32).map(UInt8.init))
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            androidBackupAttachmentBlobStore: blobStore,
            attachmentContentEncryptionKeyProvider: { _ in cek }
        )
        let nonceData = Data((80..<92).map(UInt8.init))
        let plaintext = Data("timeline plaintext".utf8)
        let sealedBox = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: cek),
            nonce: try AES.GCM.Nonce(data: nonceData)
        )
        let encryptedBlob = try XCTUnwrap(sealedBox.combined)

        try unlockNewVault(model)
        let project = try model.createVaultCategory(title: "Attachments")
        let attachment = LocalAttachmentMetadata(
            id: "attachment-1",
            projectID: project.id,
            entryID: "entry-1",
            fileName: "../contract.pdf",
            mediaType: "application/pdf",
            originalSize: Int64(plaintext.count),
            storedSize: Int64(encryptedBlob.count),
            contentHash: "sha256:timeline-secret-hash",
            storageMode: "android-backup-encrypted-blob",
            source: "android-backup-local",
            downloadState: "downloaded",
            wrappedContentEncryptionKey: "wrapped-timeline-secret-key",
            localPath: "attachment-1.enc",
            deleted: false
        )
        model.attachmentEntries = [attachment]
        _ = try blobStore.saveEncryptedBlob(
            encryptedBlob,
            vaultID: "created-vault",
            localPath: "attachment-1.enc"
        )

        try model.presentAttachmentQuickLookPreview(attachment)

        let event = try XCTUnwrap(model.operationTimelineEvents.first)
        XCTAssertEqual(event.action, .viewed)
        XCTAssertEqual(event.itemKind, .attachmentRef)
        XCTAssertEqual(event.itemID, attachment.id)
        XCTAssertEqual(event.itemTitle, "contract.pdf")

        let timelineText = "\(event.title) \(event.detail)"
        [
            "sha256:timeline-secret-hash",
            "wrapped-timeline-secret-key",
            "attachment-1.enc",
            "timeline plaintext"
        ].forEach { secret in
            XCTAssertFalse(timelineText.contains(secret))
        }
    }

    func testReplacingAttachmentContentUpdatesEncryptedBlobMetadataAndTimelineWithoutLeakingSecrets() throws {
        let engine = RecordingVaultEngine()
        let blobStore = RecordingAndroidBackupAttachmentBlobStore()
        let cek = Data((0..<32).map(UInt8.init))
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            androidBackupAttachmentBlobStore: blobStore,
            attachmentContentEncryptionKeyProvider: { attachment in
                XCTAssertEqual(attachment.id, "attachment-1")
                return cek
            }
        )
        let oldPlaintext = Data("old attachment secret".utf8)
        let oldSealedBox = try AES.GCM.seal(
            oldPlaintext,
            using: SymmetricKey(data: cek),
            nonce: try AES.GCM.Nonce(data: Data((40..<52).map(UInt8.init)))
        )
        let oldEncryptedBlob = try XCTUnwrap(oldSealedBox.combined)
        let newPlaintext = Data("replacement attachment secret".utf8)

        try unlockNewVault(model)
        let project = try model.createVaultCategory(title: "Attachments")
        let attachment = LocalAttachmentMetadata(
            id: "attachment-1",
            projectID: project.id,
            entryID: "entry-1",
            fileName: "contract.pdf",
            mediaType: "application/pdf",
            originalSize: Int64(oldPlaintext.count),
            storedSize: Int64(oldEncryptedBlob.count),
            contentHash: "sha256:old-secret-hash",
            storageMode: "android-backup-encrypted-blob",
            source: "android-backup-local",
            downloadState: "downloaded",
            wrappedContentEncryptionKey: "wrapped-replace-secret-key",
            localPath: "attachment-1.enc",
            deleted: false
        )
        engine.seedAttachmentMetadata(attachment, projectID: project.id)
        model.attachmentEntries = [attachment]
        _ = try blobStore.saveEncryptedBlob(
            oldEncryptedBlob,
            vaultID: "created-vault",
            localPath: "attachment-1.enc"
        )

        let updated = try model.replaceAttachmentContent(
            attachment,
            plaintext: newPlaintext,
            mediaType: "application/pdf"
        )

        let storedBlob = try blobStore.encryptedBlobData(
            vaultID: "created-vault",
            localPath: "attachment-1.enc"
        )
        let decrypted = try LocalAttachmentContentDecryptor.decryptAndroidLocalBlob(
            storedBlob,
            contentEncryptionKey: cek
        )
        let expectedHash = Data(SHA256.hash(data: newPlaintext)).map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(decrypted, newPlaintext)
        XCTAssertEqual(updated.id, attachment.id)
        XCTAssertEqual(updated.originalSize, Int64(newPlaintext.count))
        XCTAssertEqual(updated.storedSize, Int64(storedBlob.count))
        XCTAssertEqual(updated.contentHash, "sha256:\(expectedHash)")
        XCTAssertEqual(updated.storageMode, "ios-edited-encrypted-blob")
        XCTAssertEqual(updated.downloadState, "downloaded")
        XCTAssertEqual(updated.localPath, "attachment-1.enc")
        XCTAssertEqual(model.attachmentEntries, [updated])
        XCTAssertEqual(engine.updatedAttachmentMetadata.map(\.attachmentID), ["attachment-1"])

        let event = try XCTUnwrap(model.operationTimelineEvents.first)
        XCTAssertEqual(event.action, .updated)
        XCTAssertEqual(event.itemKind, .attachmentRef)
        XCTAssertEqual(event.itemID, attachment.id)
        XCTAssertEqual(event.itemTitle, "contract.pdf")
        [
            "old attachment secret",
            "replacement attachment secret",
            "sha256:old-secret-hash",
            expectedHash,
            "wrapped-replace-secret-key",
            "attachment-1.enc"
        ].forEach { secret in
            XCTAssertFalse(model.entryOperationState.label.contains(secret))
            XCTAssertFalse("\(event.title) \(event.detail)".contains(secret))
        }
    }

    func testAttachmentQuickLookPreviewWithoutContentKeyProviderUsesRedactedFailure() throws {
        let engine = RecordingVaultEngine()
        let blobStore = RecordingAndroidBackupAttachmentBlobStore()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            androidBackupAttachmentBlobStore: blobStore
        )

        try unlockNewVault(model)
        let attachment = LocalAttachmentMetadata(
            id: "attachment-1",
            projectID: "project-1",
            entryID: "entry-1",
            fileName: "contract.pdf",
            mediaType: "application/pdf",
            originalSize: 128,
            storedSize: 96,
            contentHash: "sha256:missing-key-secret-hash",
            storageMode: "android-backup-encrypted-blob",
            source: "android-backup-local",
            downloadState: "downloaded",
            wrappedContentEncryptionKey: "wrapped-missing-key-secret",
            localPath: "attachment-1.enc",
            deleted: false
        )

        XCTAssertThrowsError(try model.presentAttachmentQuickLookPreview(attachment))

        XCTAssertNil(model.attachmentQuickLookPreviewURL)
        XCTAssertTrue(model.entryOperationState.label.contains("附件内容密钥尚未可用"))
        [
            "sha256:missing-key-secret-hash",
            "wrapped-missing-key-secret",
            "attachment-1.enc"
        ].forEach { secret in
            XCTAssertFalse(model.entryOperationState.label.contains(secret))
        }
    }

    func testAttachmentReferenceDeleteAndRestoreAppendRedactedTimelineEvents() throws {
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

        let attachment = try XCTUnwrap(model.attachmentEntries.first)
        try model.deleteAttachmentEntry(attachment)
        try model.restoreAttachmentEntry(try XCTUnwrap(model.deletedAttachmentEntries.first))

        let events = model.operationTimelineEvents

        XCTAssertEqual(events.map(\.action), [.restored, .deleted])
        XCTAssertEqual(events.map(\.itemKind), [.attachmentRef, .attachmentRef])
        XCTAssertEqual(events.map(\.itemTitle), ["contract.pdf", "contract.pdf"])
        XCTAssertEqual(events.map(\.itemID), [attachment.id, attachment.id])

        let timelineText = events.map { "\($0.title) \($0.detail)" }.joined(separator: " ")
        [
            "abc123",
            "wrapped-key",
            "attachment-1.enc",
            "ciphertext",
            "secret-password"
        ].forEach { secret in
            XCTAssertFalse(timelineText.contains(secret))
        }
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
        XCTAssertTrue(store.encryptedBlobExists(vaultID: "created-vault", localPath: relativePath))
        XCTAssertEqual(
            try store.encryptedBlobData(vaultID: "created-vault", localPath: relativePath),
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

    func testAutoFillSaveRequestCreatesLoginAndRefreshesSharedArtifactsWithoutLeakingSecret() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let indexStore = FileAutoFillEncryptedIndexStore(appGroupContainerURL: directory)
        let secretStore = FileAutoFillCredentialSecretStore(appGroupContainerURL: directory)
        let identityStore = RecordingAutoFillCredentialIdentityStore()
        let keyMaterial = AutoFillIndexKeyMaterial(
            vaultID: "created-vault",
            keyIdentifier: "autofill-key-1",
            keyMaterial: Data(repeating: 37, count: 32),
            createdAt: Date(timeIntervalSince1970: 1_800_710_000)
        )
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: RecordingVaultEngine()),
            autoFillIndexStore: indexStore,
            autoFillCredentialSecretStore: secretStore,
            autoFillCredentialIdentityStore: identityStore,
            autoFillIndexKeyMaterialProvider: { _ in keyMaterial }
        )
        try unlockNewVault(model)

        try model.saveAutoFillCredential(
            AppAutoFillCredentialSaveRequest(
                serviceIdentifier: "https://accounts.example.com/login?token=secret-query",
                username: "saved-user@example.com",
                password: "autofill-generated-secret",
                title: "Example Accounts"
            ),
            projectTitle: "Personal"
        )

        let entry = try XCTUnwrap(model.loginEntries.first)
        XCTAssertEqual(model.loginEntries.count, 1)
        XCTAssertEqual(entry.title, "Example Accounts")
        XCTAssertEqual(entry.username, "saved-user@example.com")
        XCTAssertEqual(entry.password, "autofill-generated-secret")
        XCTAssertEqual(entry.url, "https://accounts.example.com/login?token=secret-query")
        XCTAssertEqual(model.entryOperationState, .succeeded("AutoFill 已保存 Example Accounts"))
        XCTAssertEqual(model.operationTimelineEvents.first?.action, .created)

        let storageKey = try AutoFillIndexEncryptionKey(rawValue: keyMaterial.keyMaterial)
        let unlockedIndex = try AutoFillCredentialIndexUnlocker().unlock(
            try XCTUnwrap(try indexStore.load()),
            vaultID: keyMaterial.vaultID,
            keyIdentifier: keyMaterial.keyIdentifier,
            key: storageKey
        )
        XCTAssertEqual(unlockedIndex.records(matchingServiceIdentifier: "accounts.example.com").map(\.id), [entry.id])

        let unlockedSnapshot = try AutoFillCredentialSecretUnlocker().unlock(
            try XCTUnwrap(try secretStore.load()),
            vaultID: keyMaterial.vaultID,
            keyIdentifier: keyMaterial.keyIdentifier,
            key: storageKey
        )
        XCTAssertEqual(
            unlockedSnapshot.secret(id: entry.id),
            AutoFillCredentialSecretRecord(
                id: entry.id,
                username: "saved-user@example.com",
                password: "autofill-generated-secret"
            )
        )
        XCTAssertEqual(identityStore.savedIdentities.last?.map(\.recordIdentifier), [entry.id, entry.id])

        let userVisibleText = ([model.entryOperationState.label] + model.operationTimelineEvents.map(\.detail))
            .joined(separator: " ")
        XCTAssertFalse(userVisibleText.contains("autofill-generated-secret"))
        XCTAssertFalse(userVisibleText.contains("saved-user@example.com"))
        XCTAssertFalse(userVisibleText.contains("secret-query"))
    }

    func testAutoFillSaveRequestUpdatesMatchingLoginInsteadOfDuplicating() throws {
        let indexStore = RecordingAutoFillEncryptedIndexStore()
        let secretStore = RecordingAutoFillCredentialSecretStore()
        let keyMaterial = AutoFillIndexKeyMaterial(
            vaultID: "created-vault",
            keyIdentifier: "autofill-key-1",
            keyMaterial: Data(repeating: 41, count: 32),
            createdAt: Date(timeIntervalSince1970: 1_800_720_000)
        )
        let engine = RecordingVaultEngine()
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            autoFillIndexStore: indexStore,
            autoFillCredentialSecretStore: secretStore,
            autoFillIndexKeyMaterialProvider: { _ in keyMaterial }
        )
        try unlockNewVault(model)

        model.loginTitle = "GitHub"
        model.loginUsername = "alice@example.com"
        model.loginPassword = "old-secret"
        model.loginURL = "https://github.com/login"
        try model.createLoginEntry(projectTitle: "Personal")

        try model.saveAutoFillCredential(
            AppAutoFillCredentialSaveRequest(
                serviceIdentifier: "https://github.com/session",
                username: "alice@example.com",
                password: "new-autofill-secret",
                title: "Ignored Suggested Title"
            ),
            projectTitle: "Personal"
        )

        let entry = try XCTUnwrap(model.loginEntries.first)
        XCTAssertEqual(model.loginEntries.count, 1)
        XCTAssertEqual(entry.id, "entry-1")
        XCTAssertEqual(entry.title, "GitHub")
        XCTAssertEqual(entry.username, "alice@example.com")
        XCTAssertEqual(entry.password, "new-autofill-secret")
        XCTAssertEqual(entry.url, "https://github.com/login")
        XCTAssertEqual(engine.createdLoginEntries.count, 1)
        XCTAssertEqual(engine.updatedLoginEntries.last?.entryID, "entry-1")
        XCTAssertEqual(model.entryOperationState, .succeeded("AutoFill 已更新 GitHub"))
        XCTAssertEqual(model.operationTimelineEvents.first?.action, .updated)
        XCTAssertEqual(model.autoFillIndexState, .succeeded(1))
        XCTAssertEqual(indexStore.savedIndexes.last?.records.count, 1)
        XCTAssertEqual(secretStore.savedSnapshots.last?.records.count, 1)

        let userVisibleText = ([model.entryOperationState.label] + model.operationTimelineEvents.map(\.detail))
            .joined(separator: " ")
        XCTAssertFalse(userVisibleText.contains("new-autofill-secret"))
        XCTAssertFalse(userVisibleText.contains("alice@example.com"))
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

    func testCloudFileSourcesListDownloadUploadAndOverwriteWithoutLeakingSecrets() async throws {
        let engine = RecordingVaultEngine()
        let oneDrive = RecordingCloudFileProvider(kind: .oneDrive)
        let googleDrive = RecordingCloudFileProvider(kind: .googleDrive)
        oneDrive.items = [
            CloudFileItem(
                id: "onedrive-remote-secret-id",
                name: "Mobile-OneDrive.mdbx",
                path: "/Apps/Monica/private-folder/Mobile-OneDrive.mdbx",
                byteCount: 17,
                modifiedAt: Date(timeIntervalSince1970: 1_804_010_000),
                sha256: "onedrive-list-sha-secret"
            )
        ]
        oneDrive.downloads["onedrive-remote-secret-id"] = CloudFileDownload(
            item: oneDrive.items[0],
            data: Data("onedrive-remote-vault-secret".utf8),
            sha256: "onedrive-download-sha-secret"
        )
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            cloudFileProviders: [.oneDrive: oneDrive, .googleDrive: googleDrive]
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
        try Data("local-vault-backup-secret".utf8).write(to: directory.appendingPathComponent("Mobile.mdbx"))

        let listed = try await model.refreshCloudFileItems(provider: .oneDrive)
        let downloaded = try await model.downloadCloudFileRestorePreview(
            itemID: "onedrive-remote-secret-id",
            provider: .oneDrive
        )
        let uploadReceipt = try await model.uploadActiveVaultToCloud(provider: .googleDrive)
        let overwriteReceipt = try await model.overwriteCloudFile(
            provider: .oneDrive,
            itemID: "onedrive-remote-secret-id",
            data: Data("keepass-writeback-secret-bytes".utf8),
            fileName: "Mobile-OneDrive.mdbx"
        )

        XCTAssertEqual(listed.map(\.name), ["Mobile-OneDrive.mdbx"])
        XCTAssertEqual(model.cloudFileItemsByProvider[.oneDrive]?.map(\.name), ["Mobile-OneDrive.mdbx"])
        XCTAssertEqual(downloaded.item.name, "Mobile-OneDrive.mdbx")
        XCTAssertEqual(model.cloudFileRestorePreview?.fileName, "Mobile-OneDrive.mdbx")
        XCTAssertEqual(oneDrive.downloadRequests, ["onedrive-remote-secret-id"])
        XCTAssertEqual(googleDrive.uploads.first?.fileName, "monica-google-drive.mdbx")
        XCTAssertEqual(googleDrive.uploads.first?.data, Data("local-vault-backup-secret".utf8))
        XCTAssertEqual(oneDrive.overwrites.first?.itemID, "onedrive-remote-secret-id")
        XCTAssertEqual(oneDrive.overwrites.first?.data, Data("keepass-writeback-secret-bytes".utf8))
        XCTAssertEqual(uploadReceipt.provider, .googleDrive)
        XCTAssertEqual(overwriteReceipt.provider, .oneDrive)

        let visibleText = ([model.cloudFileState.label] + model.cloudFileItemsByProvider.values.flatMap { $0.map(\.redactedSummary) })
            .joined(separator: " ")
        XCTAssertFalse(visibleText.contains("onedrive-remote-secret-id"))
        XCTAssertFalse(visibleText.contains("private-folder"))
        XCTAssertFalse(visibleText.contains("onedrive-list-sha-secret"))
        XCTAssertFalse(visibleText.contains("onedrive-remote-vault-secret"))
        XCTAssertFalse(visibleText.contains("local-vault-backup-secret"))
        XCTAssertFalse(visibleText.contains("keepass-writeback-secret-bytes"))
        XCTAssertFalse(visibleText.contains("google-drive-access-token-secret"))
    }

    func testBitwardenSyncPreviewAndPushLocalSendWithoutLeakingSecrets() async throws {
        let engine = RecordingVaultEngine()
        let bitwarden = RecordingBitwardenSyncProvider()
        bitwarden.snapshot = BitwardenSyncSnapshot(
            accountLabel: "alice@example.com",
            revision: "bw-revision-secret",
            items: [
                BitwardenSyncItem(
                    remoteID: "remote-login-secret-id",
                    kind: .login,
                    title: "GitHub",
                    username: "alice",
                    url: "https://github.com/session?token=query-secret",
                    password: "login-password-secret",
                    totpSecret: "totp-secret",
                    notes: "login-note-secret",
                    folderName: "Engineering",
                    collectionNames: ["Private"],
                    attachmentByteCount: 19,
                    updatedAt: Date(timeIntervalSince1970: 1_804_020_000)
                )
            ],
            sends: [
                BitwardenSendSyncItem(
                    remoteID: "remote-send-secret-id",
                    title: "Deploy link",
                    body: "remote-send-body-secret",
                    notes: "remote-send-note-secret",
                    expiresAt: "2026-06-03",
                    maxViews: 2,
                    attachmentByteCount: 23,
                    updatedAt: Date(timeIntervalSince1970: 1_804_020_001)
                )
            ]
        )
        bitwarden.pushResult = BitwardenSyncPushResult(
            acceptedMutationCount: 1,
            conflicts: [
                BitwardenSyncConflict(
                    localID: "send-1",
                    remoteID: "remote-send-secret-id",
                    title: "Local secure link",
                    reason: .bothModified
                )
            ],
            revision: "bw-push-revision-secret"
        )
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(engine: engine),
            bitwardenSyncProvider: bitwarden
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
        model.sendTitle = "Local secure link"
        model.sendBody = "local-send-body-secret"
        model.sendNotes = "local-send-note-secret"
        model.sendExpiresAt = "2026-06-03"
        model.sendMaxViews = 3
        try model.createSendEntry(projectTitle: "Personal")

        let preview = try await model.previewBitwardenSync()
        let pushResult = try await model.pushLocalBitwardenChanges()

        XCTAssertEqual(bitwarden.pullCallCount, 1)
        XCTAssertEqual(bitwarden.pushedMutations.count, 1)
        XCTAssertEqual(bitwarden.pushedMutations.first?.redactedSummary, "upsert Send Local secure link 3 次")
        XCTAssertEqual(preview.accountLabel, "alice@example.com")
        XCTAssertEqual(preview.remoteItemCount, 1)
        XCTAssertEqual(preview.remoteSendCount, 1)
        XCTAssertEqual(model.bitwardenSyncPreview?.remoteSendTitles, ["Deploy link"])
        XCTAssertEqual(pushResult.acceptedMutationCount, 1)
        XCTAssertEqual(model.bitwardenSyncState.label, "Bitwarden 已推送 1 个变更，1 个冲突")

        let visibleText = [
            model.bitwardenSyncState.label,
            model.bitwardenSyncPreview?.redactedSummary ?? "",
            bitwarden.pushedMutations.first?.redactedSummary ?? ""
        ].joined(separator: " ")
        XCTAssertFalse(visibleText.contains("bw-revision-secret"))
        XCTAssertFalse(visibleText.contains("bw-push-revision-secret"))
        XCTAssertFalse(visibleText.contains("remote-login-secret-id"))
        XCTAssertFalse(visibleText.contains("remote-send-secret-id"))
        XCTAssertFalse(visibleText.contains("query-secret"))
        XCTAssertFalse(visibleText.contains("login-password-secret"))
        XCTAssertFalse(visibleText.contains("totp-secret"))
        XCTAssertFalse(visibleText.contains("login-note-secret"))
        XCTAssertFalse(visibleText.contains("remote-send-body-secret"))
        XCTAssertFalse(visibleText.contains("remote-send-note-secret"))
        XCTAssertFalse(visibleText.contains("local-send-body-secret"))
        XCTAssertFalse(visibleText.contains("local-send-note-secret"))
        XCTAssertFalse(visibleText.contains("google-drive-access-token-secret"))
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

private final class RecordingKeePassKdbx4WritebackCoordinator: KeePassKdbx4WritebackCoordinator, @unchecked Sendable {
    private(set) var requests: [KeePassKdbx4WritebackRequest] = []
    var result = KeePassKdbx4WritebackResult(
        database: Data("recorded-kdbx".utf8),
        headerBytes: Data(),
        payloadSection: Data(),
        xmlPayloadByteCount: 0,
        groupCount: 0,
        entryCount: 0,
        attachmentCount: 0
    )
    var error: Error?

    func writeDatabase(_ request: KeePassKdbx4WritebackRequest) throws -> KeePassKdbx4WritebackResult {
        requests.append(request)
        if let error {
            throw error
        }
        return result
    }
}

private final class RecordingKeePassKdbx3WritebackCoordinator: KeePassKdbx3WritebackCoordinator, @unchecked Sendable {
    private(set) var requests: [KeePassKdbx3WritebackRequest] = []
    var result = KeePassKdbx3WritebackResult(
        database: Data("recorded-kdbx3".utf8),
        headerBytes: Data(),
        encryptedPayload: Data(),
        xmlPayloadByteCount: 0,
        groupCount: 0,
        entryCount: 0,
        attachmentCount: 0
    )
    var error: Error?

    func writeDatabase(_ request: KeePassKdbx3WritebackRequest) throws -> KeePassKdbx3WritebackResult {
        requests.append(request)
        if let error {
            throw error
        }
        return result
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

private final class RecordingCloudFileProvider: CloudFileProvider, @unchecked Sendable {
    let kind: CloudFileProviderKind
    var connection: CloudFileConnectionState
    var items: [CloudFileItem] = []
    var downloads: [String: CloudFileDownload] = [:]
    private(set) var listCallCount = 0
    private(set) var downloadRequests: [String] = []
    private(set) var uploads: [(fileName: String, data: Data)] = []
    private(set) var overwrites: [(itemID: String, fileName: String, data: Data)] = []
    var error: Error?

    init(kind: CloudFileProviderKind) {
        self.kind = kind
        self.connection = .connected(accountLabel: "\(kind.displayName) account")
    }

    func connectionState() async throws -> CloudFileConnectionState {
        if let error {
            throw error
        }
        return connection
    }

    func listFiles() async throws -> [CloudFileItem] {
        listCallCount += 1
        if let error {
            throw error
        }
        return items
    }

    func downloadFile(id: String) async throws -> CloudFileDownload {
        downloadRequests.append(id)
        if let error {
            throw error
        }
        guard let download = downloads[id] else {
            throw CloudFileProviderError.itemNotFound(provider: kind)
        }
        return download
    }

    func uploadFile(named fileName: String, data: Data) async throws -> CloudFileWriteReceipt {
        uploads.append((fileName, data))
        if let error {
            throw error
        }
        return CloudFileWriteReceipt(
            provider: kind,
            itemID: "\(kind.rawValue)-uploaded-secret-id",
            name: fileName,
            byteCount: data.count,
            sha256: "\(kind.rawValue)-upload-sha-secret"
        )
    }

    func overwriteFile(id: String, data: Data, fileName: String) async throws -> CloudFileWriteReceipt {
        overwrites.append((id, fileName, data))
        if let error {
            throw error
        }
        return CloudFileWriteReceipt(
            provider: kind,
            itemID: id,
            name: fileName,
            byteCount: data.count,
            sha256: "\(kind.rawValue)-overwrite-sha-secret"
        )
    }
}

private final class RecordingBitwardenSyncProvider: BitwardenSyncProvider, @unchecked Sendable {
    var snapshot = BitwardenSyncSnapshot(
        accountLabel: "alice@example.com",
        revision: "initial-revision"
    )
    var pushResult = BitwardenSyncPushResult(acceptedMutationCount: 0)
    var pullError: Error?
    var pushError: Error?
    private(set) var pullCallCount = 0
    private(set) var pushedMutations: [BitwardenSyncMutation] = []

    func pullSnapshot() async throws -> BitwardenSyncSnapshot {
        pullCallCount += 1
        if let pullError {
            throw pullError
        }
        return snapshot
    }

    func pushMutations(_ mutations: [BitwardenSyncMutation]) async throws -> BitwardenSyncPushResult {
        pushedMutations.append(contentsOf: mutations)
        if let pushError {
            throw pushError
        }
        return pushResult
    }
}

private final class RecordingAppPlusResourceUnlockService: AppPlusResourceUnlockService, @unchecked Sendable {
    var unlockResult = true
    private(set) var unlockCallCount = 0

    func unlockPlus() async throws -> Bool {
        unlockCallCount += 1
        return unlockResult
    }
}

private struct RecordedKeePassKdbxFileReplacement: Equatable {
    let url: URL
    let data: Data
}

private final class RecordingAppKeePassKdbxFileWritebackService: AppKeePassKdbxFileWritebackService, @unchecked Sendable {
    private(set) var replacements: [RecordedKeePassKdbxFileReplacement] = []
    var error: Error?

    func replaceFile(at url: URL, with data: Data) throws {
        replacements.append(RecordedKeePassKdbxFileReplacement(url: url, data: data))
        if let error {
            throw error
        }
    }
}

private final class RecordingAndroidBackupAttachmentBlobStore: AndroidBackupAttachmentBlobStore, @unchecked Sendable {
    private(set) var savedBlobs: [RecordedAndroidBackupAttachmentBlob] = []

    func saveEncryptedBlob(_ data: Data, vaultID: String, localPath: String) throws -> String {
        savedBlobs.removeAll {
            $0.vaultID == vaultID && $0.localPath == localPath
        }
        savedBlobs.append(
            RecordedAndroidBackupAttachmentBlob(
                vaultID: vaultID,
                localPath: localPath,
                data: data
            )
        )
        return localPath
    }

    func encryptedBlobExists(vaultID: String, localPath: String) -> Bool {
        savedBlobs.contains {
            $0.vaultID == vaultID && $0.localPath == localPath
        }
    }

    func encryptedBlobData(vaultID: String, localPath: String) throws -> Data {
        guard let blob = savedBlobs.last(where: {
            $0.vaultID == vaultID && $0.localPath == localPath
        }) else {
            throw LocalAttachmentContentStoreError.missingBlob(localPath)
        }
        return blob.data
    }
}

private struct RecordedAndroidBackupAttachmentBlob: Equatable {
    let vaultID: String
    let localPath: String
    let data: Data
}

private final class RecordingKeePassDatabaseReader: KeePassDatabaseReader, @unchecked Sendable {
    struct Request: Equatable {
        let database: Data
        let sourceName: String?
        let credentials: KeePassUnlockCredentials
    }

    private(set) var requests: [Request] = []
    var snapshot: KeePassReadOnlySnapshot
    var error: Error?
    var queuedResults: [Result<KeePassReadOnlySnapshot, Error>] = []

    init(snapshot: KeePassReadOnlySnapshot) {
        self.snapshot = snapshot
    }

    func readSnapshot(
        database: Data,
        sourceName: String?,
        credentials: KeePassUnlockCredentials
    ) throws -> KeePassReadOnlySnapshot {
        requests.append(
            Request(
                database: database,
                sourceName: sourceName,
                credentials: credentials
            )
        )
        if !queuedResults.isEmpty {
            switch queuedResults.removeFirst() {
            case let .success(snapshot):
                return snapshot
            case let .failure(error):
                throw error
            }
        }
        if let error {
            throw error
        }
        return snapshot
    }
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
    private(set) var renamedProjects: [RecordedRenamedProjectCall] = []
    private(set) var deletedProjects: [RecordedDeletedProjectCall] = []
    private(set) var movedVaultEntries: [RecordedMoveEntryCall] = []
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
    private(set) var updatedAttachmentMetadata: [RecordedUpdatedAttachmentMetadataCall] = []
    private var projects: [String: [LocalVaultProject]] = [:]
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

    func seedAttachmentMetadata(_ metadata: LocalAttachmentMetadata, projectID: String) {
        attachmentMetadata[projectID, default: []].append(metadata)
    }

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
        let project = LocalVaultProject(id: "project-\(createdProjects.count)", title: title)
        projects[handle.vaultID, default: []].append(project)
        return project
    }

    func listProjects(in handle: LocalVaultHandle) throws -> [LocalVaultProject] {
        projects[handle.vaultID, default: []]
    }

    func renameProject(
        in handle: LocalVaultHandle,
        projectID: String,
        title: String
    ) throws -> LocalVaultProject {
        guard let index = projects[handle.vaultID, default: []].firstIndex(where: { $0.id == projectID }) else {
            throw LocalVaultRepositoryError.projectNotFound
        }
        let renamed = LocalVaultProject(id: projectID, title: title)
        renamedProjects.append(.init(vaultID: handle.vaultID, projectID: projectID, title: title))
        projects[handle.vaultID, default: []][index] = renamed
        return renamed
    }

    func deleteProject(in handle: LocalVaultHandle, projectID: String) throws {
        guard projects[handle.vaultID, default: []].contains(where: { $0.id == projectID }) else {
            throw LocalVaultRepositoryError.projectNotFound
        }
        guard !projectContainsEntries(projectID: projectID) else {
            throw LocalVaultRepositoryError.projectNotEmpty
        }
        deletedProjects.append(.init(vaultID: handle.vaultID, projectID: projectID))
        projects[handle.vaultID, default: []].removeAll { $0.id == projectID }
    }

    func moveEntry(
        in handle: LocalVaultHandle,
        kind: UnifiedVaultItemKind,
        entryID: String,
        fromProjectID: String,
        toProjectID: String
    ) throws -> LocalVaultMovedEntry {
        movedVaultEntries.append(
            .init(
                vaultID: handle.vaultID,
                kind: kind,
                entryID: entryID,
                fromProjectID: fromProjectID,
                toProjectID: toProjectID
            )
        )

        switch kind {
        case .login:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &loginEntries, title: \.title) { entry, projectID in
                LocalLoginEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    username: entry.username,
                    password: entry.password,
                    url: entry.url,
                    favorite: entry.favorite
                )
            }
        case .note:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &noteEntries, title: \.title) { entry, projectID in
                LocalNoteEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    body: entry.body,
                    favorite: entry.favorite
                )
            }
        case .totp:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &totpEntries, title: \.title) { entry, projectID in
                LocalTotpEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    secret: entry.secret,
                    issuer: entry.issuer,
                    accountName: entry.accountName,
                    period: entry.period,
                    digits: entry.digits,
                    algorithm: entry.algorithm,
                    otpType: entry.otpType,
                    counter: entry.counter,
                    favorite: entry.favorite
                )
            }
        case .card:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &cardEntries, title: \.title) { entry, projectID in
                LocalCardEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    cardholderName: entry.cardholderName,
                    number: entry.number,
                    expiryMonth: entry.expiryMonth,
                    expiryYear: entry.expiryYear,
                    cvv: entry.cvv,
                    issuer: entry.issuer,
                    network: entry.network,
                    notes: entry.notes,
                    favorite: entry.favorite
                )
            }
        case .identity:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &identityEntries, title: \.title) { entry, projectID in
                LocalIdentityEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    documentType: entry.documentType,
                    fullName: entry.fullName,
                    documentNumber: entry.documentNumber,
                    issuer: entry.issuer,
                    country: entry.country,
                    issueDate: entry.issueDate,
                    expiryDate: entry.expiryDate,
                    notes: entry.notes,
                    favorite: entry.favorite
                )
            }
        case .passkey:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &passkeyEntries, title: \.title) { entry, projectID in
                LocalPasskeyEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    relyingPartyID: entry.relyingPartyID,
                    username: entry.username,
                    userHandle: entry.userHandle,
                    credentialID: entry.credentialID,
                    publicKeyCOSE: entry.publicKeyCOSE,
                    privateKeyReference: entry.privateKeyReference,
                    notes: entry.notes,
                    favorite: entry.favorite
                )
            }
        case .sshKey:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &sshKeyEntries, title: \.title) { entry, projectID in
                LocalSshKeyEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    username: entry.username,
                    host: entry.host,
                    publicKey: entry.publicKey,
                    privateKeyReference: entry.privateKeyReference,
                    passphraseHint: entry.passphraseHint,
                    notes: entry.notes,
                    favorite: entry.favorite
                )
            }
        case .apiToken:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &apiTokenEntries, title: \.title) { entry, projectID in
                LocalApiTokenEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    issuer: entry.issuer,
                    accountName: entry.accountName,
                    token: entry.token,
                    scopes: entry.scopes,
                    expiresAt: entry.expiresAt,
                    notes: entry.notes,
                    favorite: entry.favorite
                )
            }
        case .wifi:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &wifiEntries, title: \.title) { entry, projectID in
                LocalWifiEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    ssid: entry.ssid,
                    securityType: entry.securityType,
                    password: entry.password,
                    hidden: entry.hidden,
                    notes: entry.notes,
                    favorite: entry.favorite
                )
            }
        case .send:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &sendEntries, title: \.title) { entry, projectID in
                LocalSendEntry(
                    id: entry.id,
                    projectID: projectID,
                    title: entry.title,
                    body: entry.body,
                    expiresAt: entry.expiresAt,
                    maxViews: entry.maxViews,
                    notes: entry.notes,
                    favorite: entry.favorite
                )
            }
        case .attachmentRef:
            return try moveRecordedEntry(entryID: entryID, fromProjectID: fromProjectID, toProjectID: toProjectID, kind: kind, entries: &attachmentMetadata, title: \.fileName) { entry, projectID in
                LocalAttachmentMetadata(
                    id: entry.id,
                    projectID: projectID,
                    entryID: entry.entryID,
                    fileName: entry.fileName,
                    mediaType: entry.mediaType,
                    originalSize: entry.originalSize,
                    storedSize: entry.storedSize,
                    contentHash: entry.contentHash,
                    storageMode: entry.storageMode,
                    source: entry.source,
                    downloadState: entry.downloadState,
                    wrappedContentEncryptionKey: entry.wrappedContentEncryptionKey,
                    localPath: entry.localPath,
                    deleted: entry.deleted
                )
            }
        }
    }

    private func moveRecordedEntry<Entry: Identifiable>(
        entryID: String,
        fromProjectID: String,
        toProjectID: String,
        kind: UnifiedVaultItemKind,
        entries: inout [String: [Entry]],
        title: KeyPath<Entry, String>,
        moving: (Entry, String) -> Entry
    ) throws -> LocalVaultMovedEntry where Entry.ID == String {
        guard var sourceEntries = entries[fromProjectID],
              let index = sourceEntries.firstIndex(where: { $0.id == entryID }) else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        let entry = sourceEntries.remove(at: index)
        entries[fromProjectID] = sourceEntries
        let moved = moving(entry, toProjectID)
        entries[toProjectID, default: []].append(moved)
        return LocalVaultMovedEntry(id: moved.id, title: moved[keyPath: title], kind: kind)
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
            url: draft.url,
            notes: draft.notes
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
            notes: draft.notes,
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
            notes: current.notes,
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

    func updateAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String,
        attachmentID: String,
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
        guard let index = attachmentMetadata[projectID, default: []].firstIndex(where: { $0.id == attachmentID }) else {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        let metadata = LocalAttachmentMetadata(
            id: attachmentID,
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
        updatedAttachmentMetadata.append(
            .init(
                vaultID: handle.vaultID,
                projectID: projectID,
                attachmentID: attachmentID,
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
        attachmentMetadata[projectID, default: []][index] = metadata
        return metadata
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

    private func projectContainsEntries(projectID: String) -> Bool {
        !loginEntries[projectID, default: []].isEmpty
            || !deletedEntries[projectID, default: []].isEmpty
            || !noteEntries[projectID, default: []].isEmpty
            || !deletedNotes[projectID, default: []].isEmpty
            || !totpEntries[projectID, default: []].isEmpty
            || !deletedTotp[projectID, default: []].isEmpty
            || !cardEntries[projectID, default: []].isEmpty
            || !deletedCards[projectID, default: []].isEmpty
            || !identityEntries[projectID, default: []].isEmpty
            || !deletedIdentities[projectID, default: []].isEmpty
            || !passkeyEntries[projectID, default: []].isEmpty
            || !deletedPasskeys[projectID, default: []].isEmpty
            || !sshKeyEntries[projectID, default: []].isEmpty
            || !deletedSshKeys[projectID, default: []].isEmpty
            || !apiTokenEntries[projectID, default: []].isEmpty
            || !deletedApiTokens[projectID, default: []].isEmpty
            || !wifiEntries[projectID, default: []].isEmpty
            || !deletedWifi[projectID, default: []].isEmpty
            || !sendEntries[projectID, default: []].isEmpty
            || !deletedSends[projectID, default: []].isEmpty
            || !attachmentMetadata[projectID, default: []].isEmpty
            || !deletedAttachmentMetadata[projectID, default: []].isEmpty
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

private struct RecordedRenamedProjectCall {
    let vaultID: String
    let projectID: String
    let title: String
}

private struct RecordedDeletedProjectCall {
    let vaultID: String
    let projectID: String
}

private struct RecordedMoveEntryCall {
    let vaultID: String
    let kind: UnifiedVaultItemKind
    let entryID: String
    let fromProjectID: String
    let toProjectID: String
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

private struct RecordedUpdatedAttachmentMetadataCall: Equatable {
    let vaultID: String
    let projectID: String
    let attachmentID: String
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

private func makeKdbx4Header(
    cipherID: Data,
    compressionFlags: Data,
    kdfParameters: Data
) -> Data {
    var data = Data([
        0x03, 0xD9, 0xA2, 0x9A,
        0x67, 0xFB, 0x4B, 0xB5,
        0x00, 0x00, 0x04, 0x00
    ])
    data.append(kdbx4HeaderField(id: 2, value: cipherID))
    data.append(kdbx4HeaderField(id: 3, value: compressionFlags))
    data.append(kdbx4HeaderField(id: 11, value: kdfParameters))
    data.append(kdbx4HeaderField(id: 0, value: Data([0x0D, 0x0A, 0x0D, 0x0A])))
    return data
}

private func kdbx4HeaderField(id: UInt8, value: Data) -> Data {
    var field = Data([id])
    field.append(littleEndianUInt32(UInt32(value.count)))
    field.append(value)
    return field
}

private func makeKdbxVariantDictionary(uuid: Data) -> Data {
    var data = Data([0x00, 0x01])
    data.append(kdbxVariantByteArray(key: "$UUID", value: uuid))
    data.append(Data([0x00]))
    return data
}

private func kdbxVariantByteArray(key: String, value: Data) -> Data {
    var data = Data([0x42])
    let keyData = Data(key.utf8)
    data.append(littleEndianUInt32(UInt32(keyData.count)))
    data.append(keyData)
    data.append(littleEndianUInt32(UInt32(value.count)))
    data.append(value)
    return data
}

private func littleEndianUInt32(_ value: UInt32) -> Data {
    var little = value.littleEndian
    return Data(bytes: &little, count: MemoryLayout<UInt32>.size)
}
