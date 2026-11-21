import Foundation
import MonicaCore
import MonicaStorage
import MonicaWidgetShared
import XCTest

@testable import Monica

/// #155：验证码进度条的三组设置要在会话层可读可写、跨启动保留，并且同步到 Widget 快照。
@MainActor
final class TotpCardStyleSettingsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "monica.totp-progress.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private func makeSession(store: any TotpProgressPreferenceStore) -> AppSessionModel {
        AppSessionModel(vaultRepository: LocalVaultRepository(), totpCardPreferenceStore: store)
    }

    func testPreferencesStartAtDefaults() {
        let session = makeSession(store: MemoryTotpProgressPreferenceStore())

        XCTAssertFalse(session.totpCardPreferences.usesUnifiedProgressBar)
        XCTAssertEqual(session.totpCardPreferences.style, .linear)
        XCTAssertTrue(session.totpCardPreferences.usesSmoothAnimation)
    }

    func testPreferencesAreWrittenToTheStoreAndReflectedByThePolicy() {
        let store = MemoryTotpProgressPreferenceStore()
        let session = makeSession(store: store)

        session.updateTotpCardPreferences(
            TotpProgressPreferences(usesUnifiedProgressBar: true, style: .circular, usesSmoothAnimation: false)
        )

        XCTAssertEqual(store.loadPreferences(), session.totpCardPreferences)
        let policy = session.totpCardStylePolicy(reduceMotion: false)
        XCTAssertTrue(policy.usesUnifiedProgressBar)
        XCTAssertEqual(policy.style, .circular)
        XCTAssertFalse(policy.isSmoothAnimationEnabled)
    }

    func testPreferencesSurviveRelaunchWithUserDefaultsStore() {
        let defaults = makeDefaults()
        let updated = TotpProgressPreferences(
            usesUnifiedProgressBar: true,
            style: .circular,
            usesSmoothAnimation: false
        )

        let firstLaunch = makeSession(store: UserDefaultsTotpProgressPreferenceStore(defaults: defaults))
        firstLaunch.updateTotpCardPreferences(updated)

        let secondLaunch = makeSession(store: UserDefaultsTotpProgressPreferenceStore(defaults: defaults))
        XCTAssertEqual(secondLaunch.totpCardPreferences, updated)
    }

    func testRestoreDefaultsResetsEverySetting() {
        let store = MemoryTotpProgressPreferenceStore()
        let session = makeSession(store: store)
        session.updateTotpCardPreferences(
            TotpProgressPreferences(usesUnifiedProgressBar: true, style: .circular, usesSmoothAnimation: false)
        )

        session.restoreDefaultTotpCardPreferences()

        XCTAssertEqual(session.totpCardPreferences, .default)
        XCTAssertEqual(store.loadPreferences(), .default)
    }

    func testReduceMotionForcesNoSmoothAnimation() {
        let session = makeSession(store: MemoryTotpProgressPreferenceStore())
        session.updateTotpCardPreferences(
            TotpProgressPreferences(usesUnifiedProgressBar: false, style: .linear, usesSmoothAnimation: true)
        )

        XCTAssertTrue(session.totpCardStylePolicy(reduceMotion: false).isSmoothAnimationEnabled)
        XCTAssertFalse(session.totpCardStylePolicy(reduceMotion: true).isSmoothAnimationEnabled)
        // 「减弱动态效果」只影响动画，不会改掉用户选的样式。
        XCTAssertEqual(session.totpCardStylePolicy(reduceMotion: true).style, .linear)
    }

    func testWidgetSnapshotCarriesTheProgressStyle() {
        let session = makeSession(store: MemoryTotpProgressPreferenceStore())
        XCTAssertEqual(session.widgetSnapshot(now: Date()).totpProgressStyle, .linear)

        session.updateTotpCardPreferences(
            TotpProgressPreferences(usesUnifiedProgressBar: false, style: .circular, usesSmoothAnimation: true)
        )

        XCTAssertEqual(session.widgetSnapshot(now: Date()).totpProgressStyle, .circular)
    }
}
