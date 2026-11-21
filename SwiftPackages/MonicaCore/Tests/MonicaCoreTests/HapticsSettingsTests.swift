import Foundation
import Testing
@testable import MonicaCore

@Suite("触感反馈设置")
struct HapticsSettingsTests {
    @Test func defaultsKeepEverythingEnabled() {
        let preferences = HapticsPreferences.default
        #expect(preferences.isEnabled)
        #expect(preferences.isVerificationEnabled)
    }

    @Test func masterSwitchDisablesEveryEvent() {
        let policy = HapticsPolicy(preferences: HapticsPreferences(isEnabled: false, isVerificationEnabled: true))
        for kind in HapticEventKind.allCases {
            #expect(!policy.shouldPlay(kind))
        }
    }

    @Test func verificationSubSwitchOnlyAffectsTicks() {
        let policy = HapticsPolicy(preferences: HapticsPreferences(isEnabled: true, isVerificationEnabled: false))
        #expect(policy.shouldPlay(.success))
        #expect(policy.shouldPlay(.error))
        #expect(policy.shouldPlay(.selection))
        #expect(!policy.shouldPlay(.verificationTick))
    }

    @Test func tickAllowedWhenBothSwitchesOn() {
        let policy = HapticsPolicy(preferences: .default)
        #expect(policy.shouldPlay(.verificationTick))
    }

    @Test func userDefaultsStoreRoundTripsAndDefaultsWhenMissing() {
        let suiteName = "monica.haptics.tests.\(UUID().uuidString)"
        let defaults = try! #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsHapticsPreferencesStore(userDefaults: defaults)

        #expect(store.load() == .default)

        store.save(HapticsPreferences(isEnabled: false, isVerificationEnabled: false))
        let loaded = store.load()
        #expect(!loaded.isEnabled)
        #expect(!loaded.isVerificationEnabled)
    }

    @Test func userDefaultsStoreReadsLegacyPartialValues() {
        let suiteName = "monica.haptics.tests.\(UUID().uuidString)"
        let defaults = try! #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: HapticsPreferenceKeys.isEnabled)

        let loaded = UserDefaultsHapticsPreferencesStore(userDefaults: defaults).load()
        #expect(!loaded.isEnabled)
        #expect(loaded.isVerificationEnabled)
    }

    @Test func memoryStoreIsIndependent() {
        let store = MemoryHapticsPreferencesStore()
        store.save(HapticsPreferences(isEnabled: false, isVerificationEnabled: true))
        #expect(!store.load().isEnabled)
        #expect(store.load().isVerificationEnabled)
    }
}
