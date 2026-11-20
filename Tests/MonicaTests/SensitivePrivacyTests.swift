import Foundation
import MonicaCore
@testable import Monica
import XCTest

/// #58：敏感值剪贴板治理与敏感预览掩码。
///
/// 策略本身由 `SwiftPackages/MonicaCore` 的测试覆盖；这里验证 App 会话语义，
/// 以及「不读取剪贴板内容」「不把明文写进持久化」这两条硬约束。
@MainActor
final class SensitivePrivacyTests: XCTestCase {
    private static let secret = "issue58-super-secret-value"
    private static let mask = AppSessionModel.sensitivePreviewMaskPlaceholder

    @MainActor
    private final class RecordingPasteboard: SensitivePasteboardWriting {
        private(set) var changeCount = 0
        private(set) var content: String?
        private(set) var writeCount = 0
        private(set) var clearCount = 0
        private(set) var readCount = 0

        var string: String? {
            readCount += 1
            return content
        }

        func setString(_ value: String) {
            content = value
            changeCount += 1
            writeCount += 1
        }

        func clear() {
            content = nil
            changeCount += 1
            clearCount += 1
        }

        func simulateForeignCopy(_ value: String) {
            content = value
            changeCount += 1
        }
    }

    private func makeSession(
        pasteboard: RecordingPasteboard,
        defaults: UserDefaults? = nil
    ) -> AppSessionModel {
        let previewStore: any SensitivePreviewPreferenceStore
        let clipboardStore: any SensitiveClipboardPreferenceStore
        if let defaults {
            previewStore = UserDefaultsSensitivePreviewPreferenceStore(userDefaults: defaults)
            clipboardStore = UserDefaultsSensitiveClipboardPreferenceStore(userDefaults: defaults)
        } else {
            previewStore = MemorySensitivePreviewPreferenceStore()
            clipboardStore = MemorySensitiveClipboardPreferenceStore()
        }
        return AppSessionModel(
            sensitivePasteboard: MonicaSensitivePasteboard(pasteboard: pasteboard),
            sensitivePreviewPreferenceStore: previewStore,
            sensitiveClipboardPreferenceStore: clipboardStore
        )
    }

    // MARK: - 掩码默认值与锁库重置

    func testSensitivePreviewsAreMaskedByDefault() {
        let session = makeSession(pasteboard: RecordingPasteboard())

        XCTAssertEqual(
            session.sensitivePreviewValue(Self.secret, category: .password, entryID: "login-1"),
            Self.mask
        )
        XCTAssertEqual(
            session.sensitivePreviewValue(Self.secret, category: .totp, entryID: "totp-1"),
            Self.mask
        )
        XCTAssertEqual(
            session.sensitivePreviewValue(Self.secret, category: .cardNumber, entryID: "card-1"),
            Self.mask
        )
        XCTAssertEqual(
            session.sensitivePreviewValue("", category: .password, entryID: "login-1"),
            String(localized: "空")
        )
        XCTAssertFalse(session.canTemporarilyRevealSensitiveFieldsInDetail)
        XCTAssertEqual(session.maskedSensitivePreview(Self.secret), Self.mask)
    }

    func testTemporaryRevealRequiresAllowedCategoryAndResets() {
        let session = makeSession(pasteboard: RecordingPasteboard())

        // 未允许的类别即使打开「显示敏感字段」也不会显示明文。
        session.setSensitivePreviewRevealed(true, entryID: "login-1")
        XCTAssertEqual(
            session.sensitivePreviewValue(Self.secret, category: .password, entryID: "login-1"),
            Self.mask
        )

        var preferences = session.sensitivePreviewPreferences
        preferences.setRevealable(true, for: .password)
        session.updateSensitivePreviewPreferences(preferences)
        XCTAssertTrue(session.canTemporarilyRevealSensitiveFieldsInDetail)
        XCTAssertEqual(
            session.sensitivePreviewValue(Self.secret, category: .password, entryID: "login-1"),
            Self.secret
        )

        // 其它类别与其它条目仍然掩码。
        XCTAssertEqual(
            session.sensitivePreviewValue(Self.secret, category: .totp, entryID: "login-1"),
            Self.mask
        )
        XCTAssertEqual(
            session.sensitivePreviewValue(Self.secret, category: .password, entryID: "login-2"),
            Self.mask
        )

        session.resetSensitivePreviewReveal()
        XCTAssertFalse(session.isSensitivePreviewRevealed(entryID: "login-1"))
        XCTAssertEqual(
            session.sensitivePreviewValue(Self.secret, category: .password, entryID: "login-1"),
            Self.mask
        )
    }

    func testAlwaysMaskOverridesAllowedCategories() {
        let session = makeSession(pasteboard: RecordingPasteboard())

        var preferences = session.sensitivePreviewPreferences
        preferences.setRevealable(true, for: .password)
        preferences.alwaysMask = true
        session.updateSensitivePreviewPreferences(preferences)
        session.setSensitivePreviewRevealed(true, entryID: "login-1")

        XCTAssertFalse(session.canTemporarilyRevealSensitiveFieldsInDetail)
        XCTAssertEqual(
            session.sensitivePreviewValue(Self.secret, category: .password, entryID: "login-1"),
            Self.mask
        )
    }

    // MARK: - 剪贴板清理

    func testCopyClearsWhenPasteboardIsUnchanged() {
        let pasteboard = RecordingPasteboard()
        let session = makeSession(pasteboard: pasteboard)

        XCTAssertEqual(
            session.copySensitiveValueToPasteboard(Self.secret),
            .copiedWithAutoClear(seconds: 30)
        )
        XCTAssertEqual(pasteboard.content, Self.secret)
        XCTAssertEqual(pasteboard.writeCount, 1)
        XCTAssertTrue(session.sensitivePasteboardHasPendingAutoClear)

        let outcome = session.checkSensitivePasteboardExpiry(at: Date().addingTimeInterval(31))
        XCTAssertEqual(outcome, .cleared)
        XCTAssertNil(pasteboard.content)
        XCTAssertEqual(pasteboard.clearCount, 1)
        XCTAssertFalse(session.sensitivePasteboardHasPendingAutoClear)
    }

    func testForeignClipboardValueIsNeverOverwritten() {
        let pasteboard = RecordingPasteboard()
        let session = makeSession(pasteboard: pasteboard)
        session.copySensitiveValueToPasteboard(Self.secret)

        pasteboard.simulateForeignCopy("user-copied-in-another-app")

        let outcome = session.checkSensitivePasteboardExpiry(at: Date().addingTimeInterval(31))
        XCTAssertEqual(outcome, .skippedBecauseReplacedByAnotherApp)
        XCTAssertEqual(pasteboard.content, "user-copied-in-another-app")
        XCTAssertEqual(pasteboard.clearCount, 0)
        XCTAssertFalse(session.sensitivePasteboardHasPendingAutoClear)
    }

    func testExpiryNeverReadsClipboardContents() {
        let pasteboard = RecordingPasteboard()
        let session = makeSession(pasteboard: pasteboard)

        session.copySensitiveValueToPasteboard(Self.secret)
        _ = session.checkSensitivePasteboardExpiry(at: Date().addingTimeInterval(31))
        XCTAssertEqual(pasteboard.readCount, 0, "判断归属只能比较 changeCount，不能读取剪贴板内容")

        session.copySensitiveValueToPasteboard(Self.secret)
        _ = session.clearSensitivePasteboardManually()
        XCTAssertEqual(pasteboard.readCount, 0)
    }

    func testEmptySecretIsNotWritten() {
        let pasteboard = RecordingPasteboard()
        let session = makeSession(pasteboard: pasteboard)

        XCTAssertEqual(session.copySensitiveValueToPasteboard(""), .nothingToCopy)
        XCTAssertEqual(pasteboard.writeCount, 0)
        XCTAssertFalse(session.sensitivePasteboardHasPendingAutoClear)
    }

    func testTurningAutoClearOffDropsPendingRecordWithoutClearing() {
        let pasteboard = RecordingPasteboard()
        let session = makeSession(pasteboard: pasteboard)
        session.copySensitiveValueToPasteboard(Self.secret)

        session.updateSensitiveClipboardTTL(.off)
        XCTAssertFalse(session.sensitivePasteboardHasPendingAutoClear)
        XCTAssertEqual(pasteboard.content, Self.secret)
        XCTAssertEqual(pasteboard.clearCount, 0)

        XCTAssertEqual(
            session.checkSensitivePasteboardExpiry(at: Date().addingTimeInterval(600)),
            .noPendingValue
        )
        XCTAssertEqual(pasteboard.content, Self.secret)

        XCTAssertEqual(session.copySensitiveValueToPasteboard(Self.secret), .copiedWithoutAutoClear)
        XCTAssertFalse(session.sensitivePasteboardHasPendingAutoClear)
    }

    // MARK: - 持久化与源码约束

    func testPreferencesPersistWithoutPlaintextSecrets() throws {
        let suiteName = "monica.issue58.tests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let pasteboard = RecordingPasteboard()
        let session = makeSession(pasteboard: pasteboard, defaults: defaults)

        session.updateSensitiveClipboardTTL(.seconds60)
        var preferences = session.sensitivePreviewPreferences
        preferences.setRevealable(true, for: .password)
        session.updateSensitivePreviewPreferences(preferences)
        session.setSensitivePreviewRevealed(true, entryID: "login-1")
        session.copySensitiveValueToPasteboard(Self.secret)

        XCTAssertEqual(
            UserDefaultsSensitiveClipboardPreferenceStore(userDefaults: defaults).loadTTL(),
            .seconds60
        )
        XCTAssertEqual(
            UserDefaultsSensitivePreviewPreferenceStore(userDefaults: defaults).loadPreferences(),
            preferences
        )

        for (key, value) in defaults.dictionaryRepresentation() {
            let text = String(describing: value)
            XCTAssertFalse(text.contains(Self.secret), "UserDefaults 键 \(key) 不应包含明文敏感值")
            XCTAssertFalse(text.contains("login-1"), "UserDefaults 键 \(key) 不应包含临时显示状态")
        }
    }

    func testLockingVaultResetsTemporaryRevealAndKeepsPasteboardAccessCentralized() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/MonicaApp/AppRootView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        let lockFunction = try XCTUnwrap(source.range(of: "func lockLocalVault()"))
        let lockBody = source[lockFunction.lowerBound...].prefix(900)
        XCTAssertTrue(lockBody.contains("resetSensitivePreviewReveal()"), "锁库必须清空临时显示状态")
        XCTAssertFalse(source.contains("UIPasteboard"), "UIPasteboard 访问必须收敛在 SensitivePrivacyService.swift")
    }
}
