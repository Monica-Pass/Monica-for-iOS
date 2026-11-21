import XCTest
@testable import Monica
import MonicaCore

@MainActor
final class AppHapticsTests: XCTestCase {
    func testMasterSwitchOffSuppressesEveryEvent() {
        let store = MemoryHapticsPreferencesStore(
            preferences: HapticsPreferences(isEnabled: false, isVerificationEnabled: true)
        )
        let player = RecordingHapticPlayer()
        let haptics = AppHaptics(store: store, player: player)

        for kind in HapticEventKind.allCases {
            haptics.play(kind)
        }

        XCTAssertTrue(player.played.isEmpty)
    }

    func testEnabledPlaysMappedEvents() {
        let player = RecordingHapticPlayer()
        let haptics = AppHaptics(store: MemoryHapticsPreferencesStore(), player: player)

        haptics.play(.success)
        haptics.play(.error)
        haptics.play(.selection)
        haptics.play(.verificationTick)

        XCTAssertEqual(player.played, [.success, .error, .selection, .verificationTick])
    }

    func testVerificationSwitchOffKeepsOtherEvents() {
        let store = MemoryHapticsPreferencesStore(
            preferences: HapticsPreferences(isEnabled: true, isVerificationEnabled: false)
        )
        let player = RecordingHapticPlayer()
        let haptics = AppHaptics(store: store, player: player)

        haptics.play(.verificationTick)
        haptics.play(.success)

        XCTAssertEqual(player.played, [.success])
    }

    func testTogglingPersistsAndSurvivesReload() {
        let store = MemoryHapticsPreferencesStore()
        let haptics = AppHaptics(store: store, player: RecordingHapticPlayer())

        haptics.setEnabled(false)
        XCTAssertFalse(haptics.isEnabled)
        XCTAssertFalse(store.load().isEnabled)

        let reloaded = AppHaptics(store: store, player: RecordingHapticPlayer())
        XCTAssertFalse(reloaded.isEnabled)

        reloaded.setEnabled(true)
        XCTAssertTrue(store.load().isEnabled)
    }

    func testDisablingVerificationKeepsMasterOn() {
        let store = MemoryHapticsPreferencesStore()
        let haptics = AppHaptics(store: store, player: RecordingHapticPlayer())

        haptics.setVerificationEnabled(false)

        XCTAssertTrue(store.load().isEnabled)
        XCTAssertFalse(store.load().isVerificationEnabled)
    }
}
