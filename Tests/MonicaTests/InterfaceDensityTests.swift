@testable import Monica
import AuthenticationServices
import CryptoKit
import MonicaCore
import MonicaSecurity
import MonicaStorage
import MonicaSync
import MonicaWidgetShared
import SwiftUI
import UIKit
import XCTest

// MARK: - Interface density (issue #61)

@MainActor
final class InterfaceDensityTests: XCTestCase {
    private let appearanceStoreKey = "monica.appAppearancePreferences"

    // MARK: 三档密度模型

    func testDensityCasesLabelsAndScales() {
        XCTAssertEqual(AppInterfaceDensity.allCases.count, 3)
        XCTAssertEqual(
            AppInterfaceDensity.allCases.map(\.rawValue),
            ["default", "compact", "loose"]
        )
        XCTAssertEqual(
            AppInterfaceDensity.allCases.map(\.label),
            ["默认", "紧凑", "宽松"]
        )
        XCTAssertEqual(AppInterfaceDensity.allCases.map(\.id), ["default", "compact", "loose"])
        XCTAssertEqual(AppInterfaceDensity.default.spacingScale, 1.0)
        XCTAssertEqual(AppInterfaceDensity.compact.spacingScale, 0.8)
        XCTAssertEqual(AppInterfaceDensity.loose.spacingScale, 1.3)
        XCTAssertEqual(AppInterfaceDensity.default.lineSpacingDelta, 0)
        XCTAssertEqual(AppInterfaceDensity.compact.lineSpacingDelta, 0)
        XCTAssertEqual(AppInterfaceDensity.loose.lineSpacingDelta, 3)
        XCTAssertEqual(AppInterfaceDensity.default.detail, "标准间距与行高。")
        XCTAssertEqual(AppInterfaceDensity.compact.detail, "收紧间距与行高，一屏显示更多内容。")
        XCTAssertEqual(AppInterfaceDensity.loose.detail, "放宽间距与行高，内容更疏朗易读。")
    }

    func testDensityCodableRoundTrip() throws {
        for density in AppInterfaceDensity.allCases {
            let data = try JSONEncoder().encode(density)
            let decoded = try JSONDecoder().decode(AppInterfaceDensity.self, from: data)
            XCTAssertEqual(decoded, density)
        }
        XCTAssertEqual(
            try JSONDecoder().decode(AppInterfaceDensity.self, from: Data("\"compact\"".utf8)),
            .compact
        )
    }

    func testTouchTargetsNeverShrinkBelowAccessibilityMinimum() {
        XCTAssertEqual(AppInterfaceDensity.minimumTouchTarget, 44)
        for density in AppInterfaceDensity.allCases {
            XCTAssertGreaterThanOrEqual(density.touchTarget(20), 44)
            XCTAssertEqual(density.touchTarget(44), 44)
            XCTAssertEqual(density.touchTarget(56), 56)
        }
    }

    func testTypographyBaselineSizesRemainStable() {
        // `testAndroidParityTypographyUsesCompactIOSSizing()` guards these values.
        XCTAssertEqual(AndroidParityTypography.screenTitleSize, 34)
        XCTAssertEqual(AndroidParityTypography.generatorTitleSize, 34)
        XCTAssertEqual(AndroidParityTypography.editorTitleSize, 24)
        XCTAssertEqual(AndroidParityTypography.prominentValueSize, 26)
        XCTAssertEqual(AndroidParityTypography.controlIconSize, 22)
        XCTAssertEqual(AndroidParityTypography.tileIconSize, 18)
    }

    // MARK: 持久化 / 向后兼容

    func testLegacyAppearanceJSONDecodesToDefaultDensityWithoutLosingOtherFields() throws {
        // JSON written before interface density existed has no `interfaceDensity` key.
        // The custom decoder must not throw (which would reset ALL appearance prefs).
        let legacyJSON = #"{"colorScheme":"dark","accentColor":"blue","passwordListIconStyle":"hidden"}"#
        let decoded = try JSONDecoder().decode(
            AppAppearancePreferences.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertEqual(decoded.colorScheme, .dark)
        XCTAssertEqual(decoded.accentColor, .blue)
        XCTAssertEqual(decoded.passwordListIconStyle, .hidden)
        XCTAssertEqual(decoded.interfaceDensity, .default)
    }

    func testUnknownFutureDensityFallsBackToDefault() throws {
        let json = #"{"colorScheme":"light","accentColor":"green","passwordListIconStyle":"monochrome","interfaceDensity":"ultra"}"#
        let decoded = try JSONDecoder().decode(
            AppAppearancePreferences.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.colorScheme, .light)
        XCTAssertEqual(decoded.interfaceDensity, .default)
    }

    func testAppearancePreferencesCodableRoundTripPersistsDensity() throws {
        var preferences = AppAppearancePreferences.default
        preferences.interfaceDensity = .loose
        preferences.colorScheme = .dark
        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(AppAppearancePreferences.self, from: data)
        XCTAssertEqual(decoded, preferences)
        XCTAssertEqual(decoded.interfaceDensity, .loose)
    }

    func testDensityPersistsAcrossRestartAndCanBeResetToDefault() {
        let store = MemoryAppAppearancePreferenceStore()
        let session = AppSessionModel(appearancePreferenceStore: store)

        var preferences = session.appearancePreferences
        preferences.interfaceDensity = .compact
        session.updateAppearancePreferences(preferences)

        let restarted = AppSessionModel(appearancePreferenceStore: store)
        XCTAssertEqual(restarted.appearancePreferences.interfaceDensity, .compact)
        XCTAssertEqual(
            restarted.appearancePreferenceRows.last?.value,
            "紧凑"
        )

        restarted.restoreDefaultInterfaceDensity()
        XCTAssertEqual(restarted.appearancePreferences.interfaceDensity, .default)

        let restartedAgain = AppSessionModel(appearancePreferenceStore: store)
        XCTAssertEqual(restartedAgain.appearancePreferences.interfaceDensity, .default)
    }

    func testUserDefaultsStoreRoundTripPreservesCustomDensity() throws {
        let suiteName = "InterfaceDensityTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsAppAppearancePreferenceStore(userDefaults: defaults)
        XCTAssertEqual(store.loadPreferences().interfaceDensity, .default)

        var preferences = AppAppearancePreferences.default
        preferences.interfaceDensity = .loose
        preferences.accentColor = .orange
        store.savePreferences(preferences)

        let loaded = store.loadPreferences()
        XCTAssertEqual(loaded.interfaceDensity, .loose)
        XCTAssertEqual(loaded.accentColor, .orange)
        XCTAssertNotNil(defaults.data(forKey: appearanceStoreKey))
        // Other preference keys must remain untouched.
        XCTAssertNil(defaults.data(forKey: "monica.vaultLayoutPreferences"))
    }

    func testCorruptStoredJSONFallsBackToDefaultsWithoutDeletingOriginalData() throws {
        let suiteName = "InterfaceDensityTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: appearanceStoreKey)
        let store = UserDefaultsAppAppearancePreferenceStore(userDefaults: defaults)
        XCTAssertEqual(store.loadPreferences(), AppAppearancePreferences.default)
        // The original bytes are preserved for inspection instead of being silently erased.
        XCTAssertEqual(defaults.data(forKey: appearanceStoreKey), corrupt)
    }
}
