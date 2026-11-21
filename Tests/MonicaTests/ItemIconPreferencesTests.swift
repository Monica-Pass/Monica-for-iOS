//
//  ItemIconPreferencesTests.swift
//  MonicaTests
//
//  Issue #149：条目图标偏好的 App 侧存储与接线。
//  纯解析规则的完整矩阵在 MonicaCore 的 ItemIconPreferencesTests 中。
//

import MonicaCore
import MonicaStorage
import XCTest

@testable import Monica

@MainActor
final class AppItemIconPreferenceStoreTests: XCTestCase {
    func testMemoryStoreRoundTripsNormalizedPreferences() {
        let store = MemoryAppItemIconPreferenceStore()
        XCTAssertEqual(store.loadPreferences(), .default)

        var preferences = ItemIconPreferences.default
        preferences.unmatchedPolicy = .hidden
        // 故意给一份不完整的优先级，存储层负责归一化。
        preferences.sourcePriority = [.firstLetter]
        store.savePreferences(preferences)

        let loaded = store.loadPreferences()
        XCTAssertEqual(loaded.unmatchedPolicy, .hidden)
        XCTAssertEqual(loaded.orderedSources, [.firstLetter, .catalog, .symbol])
    }

    func testUserDefaultsStoreRoundTripsAndUsesItsOwnKey() throws {
        let suiteName = "AppItemIconPreferenceStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsAppItemIconPreferenceStore(userDefaults: defaults)

        XCTAssertEqual(store.loadPreferences(), .default)

        var preferences = ItemIconPreferences.default
        preferences.isEnabled = false
        preferences.showsTotpPageIcons = false
        preferences.unmatchedPolicy = .defaultIcon
        preferences.sourcePriority = [.symbol, .catalog, .firstLetter]
        store.savePreferences(preferences)

        XCTAssertEqual(store.loadPreferences(), preferences.normalized())
        // 独立 key，不会写进其它偏好，也不会进保险库。
        let data = try XCTUnwrap(defaults.data(forKey: UserDefaultsAppItemIconPreferenceStore.storageKey))
        XCTAssertEqual(try JSONDecoder().decode(ItemIconPreferences.self, from: data), preferences.normalized())
    }

    func testCorruptOrFuturePreferencesFallBackToDefaults() throws {
        let suiteName = "AppItemIconPreferenceStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsAppItemIconPreferenceStore(userDefaults: defaults)

        defaults.set(Data("not json".utf8), forKey: UserDefaultsAppItemIconPreferenceStore.storageKey)
        XCTAssertEqual(store.loadPreferences(), .default)

        // 未知 schema 版本整份回退，不猜测新字段。
        let future = Data(#"{"version":99,"isEnabled":false}"#.utf8)
        defaults.set(future, forKey: UserDefaultsAppItemIconPreferenceStore.storageKey)
        XCTAssertEqual(store.loadPreferences(), .default)
    }
}

@MainActor
final class AppSessionItemIconPreferencesTests: XCTestCase {
    private func makeSession(store: any AppItemIconPreferenceStore = MemoryAppItemIconPreferenceStore()) -> AppSessionModel {
        AppSessionModel(itemIconPreferenceStore: store)
    }

    func testSessionUsesDefaultsWhenNothingIsStored() {
        let session = makeSession()
        XCTAssertEqual(session.itemIconPreferences, .default)
        XCTAssertTrue(session.itemIconPreferences.isEnabled(for: .password))
        XCTAssertTrue(session.itemIconPreferences.isEnabled(for: .totp))
        XCTAssertTrue(session.itemIconPreferences.isEnabled(for: .passkey))
    }

    func testUpdatePersistsAndSurvivesRestart() {
        let store = MemoryAppItemIconPreferenceStore()
        let session = makeSession(store: store)

        var preferences = session.itemIconPreferences
        preferences.isEnabled = false
        preferences.setEnabled(false, for: .passkey)
        preferences.unmatchedPolicy = .hidden
        preferences.moveSource(.firstLetter, by: -2)
        session.updateItemIconPreferences(preferences)

        XCTAssertEqual(session.itemIconPreferences, preferences.normalized())

        // 重启（同一存储后端）：设置保持。
        let restarted = makeSession(store: store)
        XCTAssertEqual(restarted.itemIconPreferences, preferences.normalized())
        XCTAssertFalse(restarted.itemIconPreferences.isEnabled(for: .passkey))
        XCTAssertEqual(restarted.itemIconPreferences.sourcePriority, [.firstLetter, .symbol, .catalog])
    }

    func testRestoreDefaultResetsEveryField() {
        let store = MemoryAppItemIconPreferenceStore()
        let session = makeSession(store: store)
        var preferences = ItemIconPreferences.default
        preferences.isEnabled = false
        preferences.showsPasswordPageIcons = false
        preferences.unmatchedPolicy = .hidden
        preferences.sourcePriority = [.firstLetter, .catalog, .symbol]
        session.updateItemIconPreferences(preferences)

        session.restoreDefaultItemIconPreferences()
        XCTAssertEqual(session.itemIconPreferences, .default)
        XCTAssertEqual(store.loadPreferences(), .default)
    }

    /// 图标设置只在本机 UserDefaults：换一份存储（等价于恢复备份 / 新设备）不会带过去。
    func testPreferencesAreNotPartOfTheVaultBackup() {
        let session = makeSession(store: MemoryAppItemIconPreferenceStore())
        var preferences = session.itemIconPreferences
        preferences.unmatchedPolicy = .hidden
        session.updateItemIconPreferences(preferences)
        XCTAssertEqual(session.itemIconPreferences.unmatchedPolicy, .hidden)

        let restoredFromBackup = makeSession(store: MemoryAppItemIconPreferenceStore())
        XCTAssertEqual(restoredFromBackup.itemIconPreferences, .default)
    }

    func testTurningIconsOffKeepsTheSlotAndRowLayout() {
        let session = makeSession()
        let request = ItemIconRequest.login(
            LocalLoginEntry(
                id: "login-1",
                projectID: "project-1",
                title: "GitHub",
                username: "octocat",
                password: "secret",
                url: "https://github.com",
                icon: "catalog:dev"
            )
        )
        XCTAssertEqual(
            ItemIconAvatarResolver.avatar(for: request, preferences: session.itemIconPreferences),
            .symbol(ItemIconCatalog.entry(id: "dev")?.symbolName ?? "")
        )

        var disabled = session.itemIconPreferences
        disabled.isEnabled = false
        session.updateItemIconPreferences(disabled)
        XCTAssertEqual(
            ItemIconAvatarResolver.avatar(for: request, preferences: session.itemIconPreferences),
            .placeholder
        )
        // 关图标前后槽位尺寸一致：行高与留白不跳动。
        XCTAssertEqual(ItemIconSlotMetrics.slotWidth(isIconVisible: false), ItemIconSlotMetrics.slotWidth(isIconVisible: true))
        XCTAssertEqual(ItemIconSlotMetrics.slotHeight(isIconVisible: false), ItemIconSlotMetrics.slotHeight(isIconVisible: true))
    }

    func testPerPageSwitchOnlyHidesThatPage() {
        let session = makeSession()
        var preferences = session.itemIconPreferences
        preferences.setEnabled(false, for: .totp)
        session.updateItemIconPreferences(preferences)

        let totp = ItemIconRequest.totp(
            LocalTotpEntry(
                id: "totp-1",
                projectID: "project-1",
                title: "GitHub",
                secret: "JBSWY3DPEHPK3PXP",
                issuer: "GitHub",
                accountName: "octocat",
                period: 30,
                digits: 6,
                algorithm: "SHA1",
                otpType: "totp",
                counter: 0,
                iconName: "globe"
            )
        )
        XCTAssertEqual(
            ItemIconAvatarResolver.avatar(for: totp, preferences: session.itemIconPreferences),
            .placeholder
        )
        // 密码页不受影响。
        XCTAssertFalse(
            ItemIconAvatarResolver.avatar(
                for: ItemIconRequest(page: .password, kindID: "login", title: "Zeta"),
                preferences: session.itemIconPreferences
            ).isPlaceholder
        )
    }

    func testTOTPRequestTreatsEmptyIconAsNoExplicitChoice() {
        let emptyIcon = ItemIconRequest.totp(
            LocalTotpEntry(
                id: "totp-1",
                projectID: "project-1",
                title: "Zeta",
                secret: "JBSWY3DPEHPK3PXP",
                issuer: "",
                accountName: "",
                period: 30,
                digits: 6,
                algorithm: "SHA1",
                otpType: "totp",
                counter: 0,
                iconName: ""
            )
        )
        XCTAssertNil(ItemIconAvatarResolver.explicitSystemName(for: emptyIcon))
        XCTAssertEqual(
            ItemIconAvatarResolver.avatar(for: emptyIcon, preferences: .default),
            .initial("Z")
        )

        let explicitIcon = ItemIconRequest.totp(
            LocalTotpEntry(
                id: "totp-2",
                projectID: "project-1",
                title: "Zeta",
                secret: "JBSWY3DPEHPK3PXP",
                issuer: "",
                accountName: "",
                period: 30,
                digits: 6,
                algorithm: "SHA1",
                otpType: "totp",
                counter: 0,
                iconName: "lock.fill"
            )
        )
        XCTAssertEqual(
            ItemIconAvatarResolver.avatar(for: explicitIcon, preferences: .default),
            .symbol("lock.fill")
        )
    }

    func testLoginStoredIconStillDecodesThroughTheExistingCodec() {
        let entry = LocalLoginEntry(
            id: "login-1",
            projectID: "project-1",
            title: "银行",
            username: "",
            password: "",
            url: "",
            icon: "catalog:bank"
        )
        XCTAssertEqual(entry.icon, "catalog:bank")
        XCTAssertEqual(ItemIcon(storageValue: "catalog:bank")?.storageValue, "catalog:bank")
        XCTAssertEqual(
            ItemIconAvatarResolver.avatar(for: .login(entry), preferences: .default),
            .symbol("building.columns.fill")
        )
    }
}
