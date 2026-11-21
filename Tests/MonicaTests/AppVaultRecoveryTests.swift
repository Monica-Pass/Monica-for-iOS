//
//  AppVaultRecoveryTests.swift
//  MonicaTests
//
//  issue #144：保险库打开失败恢复页的稳定失败码、脱敏诊断文本，以及
//  「快照恢复失败绝不破坏原库」的回归保护。
//

import Foundation
import MonicaMDBX
import MonicaStorage
import XCTest

@testable import Monica

@MainActor
final class AppVaultRecoveryTests: XCTestCase {

    // MARK: - 错误映射

    func testClassifierMapsKnownErrorsToStableTaxonomy() {
        XCTAssertEqual(
            AppVaultRecoveryFailure.classify(LocalVaultRepositoryError.currentPasswordMismatch, stage: .openVault),
            .masterPasswordMismatch
        )
        XCTAssertEqual(
            AppVaultRecoveryFailure.classify(LocalVaultRepositoryError.emptyPassword, stage: .passwordUnlock),
            .masterPasswordMismatch
        )
        XCTAssertEqual(
            AppVaultRecoveryFailure.classify(LocalVaultRepositoryError.vaultUnavailable, stage: .openVault),
            .vaultFileMissing
        )
        XCTAssertEqual(
            AppVaultRecoveryFailure.classify(MonicaMDBXError.unavailableOnCurrentPlatform, stage: .openVault),
            .storageEngineUnavailable
        )
        XCTAssertEqual(
            AppVaultRecoveryFailure.classify(AppVaultKeychainError.keychainUnavailable, stage: .keychainUnlock),
            .keychainUnavailable
        )
        XCTAssertEqual(
            AppVaultRecoveryFailure.classify(AppVaultKeychainError.rememberedVaultUnavailable, stage: .keychainUnlock),
            .vaultNotRemembered
        )
        XCTAssertEqual(
            AppVaultRecoveryFailure.classify(AppVaultKeychainError.wrappedKeyProviderUnavailable, stage: .keychainUnlock),
            .keyMaterialUnavailable
        )
        XCTAssertEqual(
            AppVaultRecoveryFailure.classify(VaultSnapshotError.snapshotNotFound("snapshot-1"), stage: .snapshotRestore),
            .snapshotUnavailable
        )
        XCTAssertEqual(
            AppVaultRecoveryFailure.classify(VaultSnapshotError.snapshotCorrupted, stage: .snapshotRestore),
            .snapshotCorrupted
        )
        XCTAssertEqual(
            AppVaultRecoveryFailure.classify(VaultSnapshotError.vaultNotQuiesced(["a.mdbx-wal"]), stage: .snapshotRestore),
            .vaultBusy
        )
        XCTAssertEqual(
            AppVaultRecoveryFailure.classify(
                VaultSnapshotError.insufficientDiskSpace(requiredBytes: 10, availableBytes: 1),
                stage: .snapshotRestore
            ),
            .insufficientDiskSpace
        )
        XCTAssertEqual(
            AppVaultRecoveryFailure.classify(MdbxFfiError.Storage(message: "incorrect credential"), stage: .openVault),
            .masterPasswordMismatch
        )
        XCTAssertEqual(
            AppVaultRecoveryFailure.classify(MdbxFfiError.Storage(message: "mdbx: disk io error"), stage: .openVault),
            .vaultFileCorrupted
        )
    }

    func testClassifierUnwrapsSystemErrorsAndFallsBackByStage() {
        let cocoaError = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        XCTAssertEqual(AppVaultRecoveryFailure.classify(cocoaError, stage: .openVault), .vaultFileMissing)

        let permissionError = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        XCTAssertEqual(AppVaultRecoveryFailure.classify(permissionError, stage: .openVault), .vaultFileUnreadable)

        struct UnmappedError: Error {}
        XCTAssertEqual(AppVaultRecoveryFailure.classify(UnmappedError(), stage: .openVault), .unknown)
        XCTAssertEqual(AppVaultRecoveryFailure.classify(UnmappedError(), stage: .snapshotRestore), .snapshotRestoreFailed)

        let wrapped = NSError(
            domain: "ru.takagi.monica.test",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: LocalVaultRepositoryError.currentPasswordMismatch]
        )
        XCTAssertEqual(AppVaultRecoveryFailure.classify(wrapped, stage: .openVault), .masterPasswordMismatch)
    }

    func testEveryFailureCaseHasUniqueStableCodeAndCopy() {
        let codes = AppVaultRecoveryFailure.allCases.map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count)
        XCTAssertEqual(AppVaultRecoveryFailure.masterPasswordMismatch.code, "MVA-144-01")
        XCTAssertEqual(AppVaultRecoveryFailure.snapshotRestoreFailed.code, "MVA-144-15")
        XCTAssertEqual(AppVaultRecoveryFailure.unknown.code, "MVA-144-99")

        for failure in AppVaultRecoveryFailure.allCases {
            XCTAssertTrue(failure.code.hasPrefix("MVA-144-"), "unexpected code for \(failure)")
            XCTAssertFalse(failure.title.isEmpty)
            XCTAssertFalse(failure.explanation.isEmpty)
            XCTAssertFalse(failure.nextStep.isEmpty)
        }
    }

    func testTechnicalReferenceKeepsTypeWithoutErrorMessages() {
        let classifier = AppVaultRecoveryFailureClassifier()
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        let reference = classifier.technicalReference(for: error)
        XCTAssertTrue(reference.contains("NSCocoaErrorDomain"))
        XCTAssertFalse(reference.localizedCaseInsensitiveContains("permission"))

        struct RawError: Error {}
        XCTAssertEqual(classifier.technicalReference(for: RawError()), "RawError")
    }

    // MARK: - 诊断脱敏

    func testDiagnosticTextOmitsMasterPasswordKeyMaterialAndEntryTitles() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sensitiveTitle = "SENSITIVE-ENTRY-TITLE-\(UUID().uuidString)"
        let sensitivePassword = "SENSITIVE-MASTER-PASSWORD-\(UUID().uuidString)"
        let sensitiveKeyMaterial = "SENSITIVE-KEY-MATERIAL-\(UUID().uuidString)"

        let vaultURL = directory.appendingPathComponent("vault.mdbx")
        // 把「密钥材料」写进库文件本身：诊断只应报告大小，绝不应读出内容。
        try Data(sensitiveKeyMaterial.utf8).write(to: vaultURL)

        let session = AppSessionModel()
        session.vaultPassword = sensitivePassword
        session.vaultRecoveryContext = AppVaultRecoveryContext(
            failure: .masterPasswordMismatch,
            stage: .openVault,
            fileURL: vaultURL,
            displayName: sensitiveTitle,
            retryMode: .password
        )

        let model = AppVaultRecoveryModel(
            directoryURL: directory.appendingPathComponent("snapshots", isDirectory: true),
            keyProvider: RecoveryTestKeyProvider()
        )
        model.masterPassword = sensitivePassword
        model.load(session: session)

        let text = model.diagnosticText(session: session)

        // 诊断确实生成了内容，并且带上了稳定失败码与文件元数据。
        XCTAssertTrue(text.contains("MVA-144-01"))
        XCTAssertTrue(text.contains("vault.mdbx"))
        XCTAssertTrue(text.contains("不包含条目内容"))

        // 敏感内容一律不出现。
        XCTAssertFalse(text.contains(sensitiveTitle))
        XCTAssertFalse(text.contains(sensitivePassword))
        XCTAssertFalse(text.contains(sensitiveKeyMaterial))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("sensitive-"))
    }

    // MARK: - 快照救援失败不破坏原库

    func testRestoreFailureLeavesOriginalVaultFileUntouched() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let vaultURL = directory.appendingPathComponent("vault.mdbx")
        let originalBytes = Data("original-vault-bytes-\(UUID().uuidString)".utf8)
        try originalBytes.write(to: vaultURL)

        let snapshotDirectory = directory.appendingPathComponent("snapshots", isDirectory: true)
        let keyProvider = RecoveryTestKeyProvider()
        let store = AppVaultSnapshotLocation.makeStore(
            directoryURL: snapshotDirectory,
            keyProvider: keyProvider
        )
        let manifest = try store.createSnapshot(
            vaultFileURL: vaultURL,
            vaultID: "vault-1",
            vaultDisplayName: "测试保险库",
            reason: .manual,
            index: .empty,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let record = try store.record(snapshotID: manifest.id, vaultID: "vault-1")

        let session = AppSessionModel()
        session.storeRememberedVault(fileURL: vaultURL, displayName: "测试保险库", vaultID: "vault-1")
        session.vaultRecoveryContext = AppVaultRecoveryContext(
            failure: .vaultFileCorrupted,
            stage: .openVault,
            fileURL: vaultURL,
            displayName: "测试保险库",
            retryMode: .password
        )

        let model = AppVaultRecoveryModel(
            directoryURL: snapshotDirectory,
            keyProvider: keyProvider
        )
        model.load(session: session)
        XCTAssertEqual(model.snapshots.count, 1)
        XCTAssertNotNil(model.subject)

        model.masterPassword = "wrong-master-password"
        await model.restore(record, session: session, deviceID: "ios-vault-recovery-test-device")

        // 校验先发生在临时副本上：口令/内容不匹配时不得触碰原库。
        XCTAssertTrue(model.status.isFailure)
        XCTAssertFalse(model.didRestoreSucceed)
        XCTAssertEqual(try Data(contentsOf: vaultURL), originalBytes)
        XCTAssertEqual(model.snapshots.count, 1, "失败时不应写入 .preRestoreSafety 回滚点")

        let leftoverTemporaryFiles = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains("snapshot-restore") || $0.contains("monica-vault-recovery") }
        XCTAssertTrue(leftoverTemporaryFiles.isEmpty, "失败后不应残留临时文件：\(leftoverTemporaryFiles)")
    }

    func testRestoreRejectsSnapshotFromAnotherVaultWithoutTouchingFile() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let vaultURL = directory.appendingPathComponent("vault.mdbx")
        let originalBytes = Data("original".utf8)
        try originalBytes.write(to: vaultURL)

        let snapshotDirectory = directory.appendingPathComponent("snapshots", isDirectory: true)
        let keyProvider = RecoveryTestKeyProvider()
        let store = AppVaultSnapshotLocation.makeStore(
            directoryURL: snapshotDirectory,
            keyProvider: keyProvider
        )
        let foreignManifest = try store.createSnapshot(
            vaultFileURL: vaultURL,
            vaultID: "other-vault",
            vaultDisplayName: "别的保险库",
            reason: .manual,
            index: .empty
        )
        let foreignRecord = try store.record(snapshotID: foreignManifest.id, vaultID: "other-vault")

        let session = AppSessionModel()
        session.storeRememberedVault(fileURL: vaultURL, displayName: "测试保险库", vaultID: "vault-1")
        session.vaultRecoveryContext = AppVaultRecoveryContext(
            failure: .unknown,
            stage: .openVault,
            fileURL: vaultURL,
            displayName: "测试保险库",
            retryMode: .password
        )
        let model = AppVaultRecoveryModel(directoryURL: snapshotDirectory, keyProvider: keyProvider)
        model.load(session: session)
        model.masterPassword = "some-password"

        await model.restore(foreignRecord, session: session, deviceID: "ios-vault-recovery-test-device")

        XCTAssertTrue(model.status.isFailure)
        XCTAssertEqual(try Data(contentsOf: vaultURL), originalBytes)
    }

    // MARK: - 证据

    func testFileSnapshotReportsSizeAndBusySidecars() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let vaultURL = directory.appendingPathComponent("vault.mdbx")
        try Data(repeating: 1, count: 32).write(to: vaultURL)

        let idle = try XCTUnwrap(AppVaultRecoveryFileSnapshot.inspect(vaultURL))
        XCTAssertTrue(idle.exists)
        XCTAssertEqual(idle.byteCount, 32)
        XCTAssertTrue(idle.busySidecars.isEmpty)
        XCTAssertFalse(idle.isBusy)

        let sidecars = AppVaultRecoveryFileSnapshot.sidecars(of: vaultURL)
        XCTAssertEqual(sidecars.count, 2)
        let walURL = try XCTUnwrap(sidecars.first)
        try Data(repeating: 2, count: 8).write(to: walURL)

        let busy = try XCTUnwrap(AppVaultRecoveryFileSnapshot.inspect(vaultURL))
        XCTAssertEqual(busy.busySidecars, ["vault.mdbx-wal"])
        XCTAssertTrue(busy.isBusy)

        AppVaultRecoveryFileSnapshot.removeVaultFiles(at: vaultURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: walURL.path))
    }

    func testRecoveryHistoryPersistsLastOpenedTimestamp() {
        let suiteName = "monica.tests.vaultRecovery.history.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let history = AppVaultRecoveryHistory(defaults: defaults)
        let vaultURL = URL(fileURLWithPath: "/tmp/monica/示例库.mdbx")
        XCTAssertNil(history.lastOpenedAt(for: vaultURL))

        let openedAt = Date(timeIntervalSince1970: 1_800_000_123)
        history.recordOpened(fileURL: vaultURL, at: openedAt)

        let reloaded = AppVaultRecoveryHistory(defaults: defaults)
        let stored = reloaded.lastOpenedAt(for: URL(fileURLWithPath: "/tmp/monica/folder/../示例库.mdbx"))
        XCTAssertEqual(try XCTUnwrap(stored).timeIntervalSince1970, openedAt.timeIntervalSince1970, accuracy: 0.001)

        reloaded.clear()
        XCTAssertNil(AppVaultRecoveryHistory(defaults: defaults).lastOpenedAt(for: vaultURL))
    }

    // MARK: - 上下文路由

    func testOpenFailureRoutesToRecoveryContextAndDismissKeepsFile() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let vaultURL = directory.appendingPathComponent("vault.mdbx")
        try Data("not-a-real-vault".utf8).write(to: vaultURL)

        let session = AppSessionModel()
        session.vaultPassword = "master-password"
        XCTAssertThrowsError(try session.openLocalVault(at: vaultURL, deviceID: "ios-vault-recovery-test-device"))

        // 失败后必须留下恢复上下文（路由到恢复页），而不是静默删库。
        let context = try XCTUnwrap(session.vaultRecoveryContext)
        XCTAssertEqual(context.stage, .openVault)
        XCTAssertEqual(context.retryMode, .password)
        XCTAssertEqual(context.fileURL?.standardizedFileURL.path, vaultURL.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: vaultURL.path))

        // 「退出」只关闭恢复页，绝不删除文件。
        let model = AppVaultRecoveryModel(directoryURL: directory.appendingPathComponent("snapshots"))
        model.load(session: session)
        model.dismiss(session: session)
        XCTAssertNil(session.vaultRecoveryContext)
        XCTAssertEqual(session.vaultState, .locked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: vaultURL.path))
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-vault-recovery-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct RecoveryTestKeyProvider: VaultSnapshotKeyProviding {
    let key: Data

    init(key: Data = Data(repeating: 7, count: 32)) {
        self.key = key
    }

    func snapshotKey(forVaultID vaultID: String) throws -> Data {
        key
    }
}
