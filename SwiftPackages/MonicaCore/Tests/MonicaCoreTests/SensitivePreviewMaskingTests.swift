import Foundation
import Testing
@testable import MonicaCore

@Suite("敏感预览掩码偏好")
struct SensitivePreviewMaskingTests {
    @Test func defaultsMaskEveryCategory() {
        let preferences = SensitivePreviewPreferences.default

        #expect(preferences.alwaysMask == false)
        #expect(preferences.revealableCategories.isEmpty)
        #expect(preferences.hasRevealableCategories == false)
        for category in SensitivePreviewCategory.allCases {
            #expect(preferences.masks(category))
            #expect(preferences.allowsTemporaryReveal(category) == false)
            #expect(
                preferences.previewValue("s3cret", category: category, temporarilyRevealed: true) == "••••••"
            )
        }
    }

    @Test func revealableCategoryCanBeShownTemporarily() {
        var preferences = SensitivePreviewPreferences.default
        preferences.setRevealable(true, for: .password)

        #expect(preferences.masks(.password) == false)
        #expect(preferences.allowsTemporaryReveal(.password))
        #expect(preferences.masks(.totp))
        #expect(preferences.revealableCategories == [.password])
        #expect(preferences.previewValue("s3cret", category: .password, temporarilyRevealed: true) == "s3cret")
        #expect(preferences.previewValue("s3cret", category: .password, temporarilyRevealed: false) == "••••••")
        #expect(preferences.previewValue("s3cret", category: .totp, temporarilyRevealed: true) == "••••••")

        preferences.setRevealable(false, for: .password)
        #expect(preferences.masks(.password))
    }

    @Test func alwaysMaskOverridesRevealableCategories() {
        let preferences = SensitivePreviewPreferences(alwaysMask: true, revealableCategories: Set(SensitivePreviewCategory.allCases))

        for category in SensitivePreviewCategory.allCases {
            #expect(preferences.masks(category))
            #expect(preferences.allowsTemporaryReveal(category) == false)
        }
        #expect(preferences.previewValue("s3cret", category: .password, temporarilyRevealed: true) == "••••••")
    }

    @Test func previewKeepsEmptyValuesEmpty() {
        let preferences = SensitivePreviewPreferences(alwaysMask: true, revealableCategories: [])
        #expect(preferences.previewValue("", category: .password, temporarilyRevealed: false) == "")
    }

    @Test func sessionRevealIsMemoryOnlyAndResets() {
        var session = SensitivePreviewSession()
        #expect(session.isEmpty)

        session.setRevealed(true, forEntryID: "entry-1")
        #expect(session.isRevealed(entryID: "entry-1"))
        #expect(session.isRevealed(entryID: "entry-2") == false)
        #expect(session.revealedEntryIDs == ["entry-1"])

        session.setRevealed(false, forEntryID: "entry-1")
        #expect(session.isEmpty)

        session.setRevealed(true, forEntryID: "entry-1")
        session.setRevealed(true, forEntryID: "entry-2")
        session.reset()
        #expect(session.isEmpty)
        #expect(session == SensitivePreviewSession())
    }

    @Test func preferencesRoundTripThroughUserDefaults() {
        let suiteName = "SensitivePreviewMaskingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsSensitivePreviewPreferenceStore(userDefaults: defaults)
        #expect(store.loadPreferences() == .default)

        let preferences = SensitivePreviewPreferences(
            alwaysMask: true,
            revealableCategories: [.password, .cardNumber]
        )
        store.savePreferences(preferences)
        #expect(UserDefaultsSensitivePreviewPreferenceStore(userDefaults: defaults).loadPreferences() == preferences)

        // 损坏的持久化数据回落到安全的默认值（全部掩码）。
        defaults.set(Data("not-json".utf8), forKey: UserDefaultsSensitivePreviewPreferenceStore.userDefaultsKey)
        #expect(store.loadPreferences() == .default)

        let persistedKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("monica.sensitivePreview") }
        #expect(persistedKeys == [UserDefaultsSensitivePreviewPreferenceStore.userDefaultsKey])
    }

    @Test func memoryStoreKeepsPreferencesInMemory() {
        let store = MemorySensitivePreviewPreferenceStore()
        #expect(store.loadPreferences() == .default)

        var preferences = SensitivePreviewPreferences.default
        preferences.alwaysMask = true
        store.savePreferences(preferences)
        #expect(store.loadPreferences() == preferences)
    }

    @Test func storedPreferencesNeverContainEntryContent() {
        let suiteName = "SensitivePreviewMaskingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsSensitivePreviewPreferenceStore(userDefaults: defaults)
        store.savePreferences(SensitivePreviewPreferences(alwaysMask: false, revealableCategories: [.cvv]))

        let serialized = defaults.data(forKey: UserDefaultsSensitivePreviewPreferenceStore.userDefaultsKey)
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        #expect(serialized.contains("cvv"))
        #expect(!serialized.contains("s3cret"))
    }
}
