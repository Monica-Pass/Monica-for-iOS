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

// MARK: - #63 密码页布局自定义

@MainActor
final class VaultLayoutPreferencesTests: XCTestCase {
    private let layoutStoreKey = "monica.vaultLayoutPreferences"

    // MARK: 稳定 ID 与默认值

    func testLayoutModulesUseStableRawValueIDs() {
        XCTAssertEqual(
            PasswordLayoutModule.allCases.map(\.rawValue),
            ["login", "note", "passkey", "generator", "keePass"]
        )
        XCTAssertEqual(VaultLayoutPreferences.currentVersion, 1)
        XCTAssertEqual(
            VaultLayoutPreferences.default.moduleOrder,
            ["login", "passkey", "note", "generator"]
        )
        XCTAssertEqual(VaultLayoutPreferences.default.hiddenModuleIDs, ["generator"])
        XCTAssertEqual(VaultLayoutPreferences.default.version, 1)
        // 默认布局与 #77 的固定二级模块顺序保持一致，不改变既有 UI。
        XCTAssertEqual(
            VaultLayoutPreferences.default.orderedModules.compactMap(\.passwordModule),
            [.login, .passkey, .note]
        )
        XCTAssertNil(PasswordLayoutModule.generator.passwordModule)
        // issue #32：KeePass 库同样是工具页，不进入密码模块栏，但恒定出现在「更多」。
        XCTAssertNil(PasswordLayoutModule.keePass.passwordModule)
    }

    func testFourRootTabsRemainFixedRegardlessOfLayout() {
        XCTAssertEqual(
            MonicaAppTab.rootTabs,
            [.passwords, .totp, .wallet, .settings]
        )
        XCTAssertEqual(MonicaAppTab.rootTabs.map(\.title), ["密码", "验证", "卡包", "设置"])
    }

    func testPasswordModuleCasesAreUntouchedByLayout() {
        XCTAssertEqual(
            PasswordModule.allModules.map(\.rawValue),
            ["login", "passkey", "note", "other"]
        )
        XCTAssertEqual(PasswordModule.primaryModules, [.login, .passkey, .note])
    }

    // MARK: 自定义 → 重启 → 恢复默认

    func testCustomizeRestartAndRestoreDefaultAreConsistent() throws {
        let store = MemoryVaultLayoutPreferenceStore()
        let session = AppSessionModel(vaultLayoutPreferenceStore: store)

        var preferences = session.vaultLayoutPreferences
        preferences.orderedModules = [.note, .generator, .login, .passkey]
        preferences.setHidden(true, for: .passkey)
        preferences.setHidden(false, for: .generator)
        session.updateVaultLayoutPreferences(preferences)

        XCTAssertEqual(
            session.vaultLayoutPreferences.moduleOrder,
            ["note", "generator", "login", "passkey"]
        )
        XCTAssertEqual(session.vaultLayoutPreferences.hiddenModuleIDs, ["passkey"])

        // 用同一个 store 重建 session，模拟应用重启后读回持久化配置。
        let restarted = AppSessionModel(vaultLayoutPreferenceStore: store)
        XCTAssertEqual(restarted.vaultLayoutPreferences, session.vaultLayoutPreferences)
        XCTAssertEqual(
            restarted.passwordModuleBarModules.map(\.rawValue),
            ["note", "login", "other"]
        )

        restarted.restoreDefaultVaultLayoutPreferences()
        XCTAssertEqual(restarted.vaultLayoutPreferences, VaultLayoutPreferences.default)

        let restartedAgain = AppSessionModel(vaultLayoutPreferenceStore: store)
        XCTAssertEqual(restartedAgain.vaultLayoutPreferences, VaultLayoutPreferences.default)
    }

    func testUserDefaultsStoreRoundTripPreservesCustomLayout() throws {
        let suiteName = "VaultLayoutPreferencesTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsVaultLayoutPreferenceStore(userDefaults: defaults)
        XCTAssertEqual(store.loadPreferences(), VaultLayoutPreferences.default)

        var preferences = VaultLayoutPreferences.default
        preferences.orderedModules = [.passkey, .note, .generator, .login]
        preferences.setHidden(true, for: .note)
        store.savePreferences(preferences)

        XCTAssertEqual(store.loadPreferences(), preferences)
        XCTAssertNotNil(defaults.data(forKey: layoutStoreKey))
        // 既有偏好 key 未被触碰，存储层没有重排或覆盖用户数据。
        XCTAssertNil(defaults.data(forKey: "monica.vaultDisplayPreferences"))
    }

    // MARK: 老配置 / 未知值安全回退

    func testDirtyConfigsNormalizeWithoutLosingStoredData() throws {
        // 缺字段（老配置）、未知 ID、重复 ID、类型不符都逐项容错。
        let cases: [(String, [String])] = [
            ("{}", ["login", "passkey", "note", "generator"]),
            (
                #"{"version":1,"moduleOrder":["generator","note","note","unknown","login"],"hiddenModuleIDs":["unknown"]}"#,
                ["generator", "note", "login", "passkey"]
            ),
            (
                #"{"version":1,"moduleOrder":"wrongType","hiddenModuleIDs":["passkey","passkey"]}"#,
                ["login", "passkey", "note", "generator"]
            ),
            (
                #"{"version":1,"moduleOrder":[],"hiddenModuleIDs":["login","note","passkey","generator"]}"#,
                ["login", "passkey", "note", "generator"]
            ),
        ]
        for (json, expectedOrder) in cases {
            let decoded = try JSONDecoder().decode(
                VaultLayoutPreferences.self,
                from: Data(json.utf8)
            )
            XCTAssertEqual(decoded.version, 1, json)
            XCTAssertEqual(decoded.moduleOrder, expectedOrder, json)
            XCTAssertEqual(decoded.moduleOrder.count, Set(decoded.moduleOrder).count, json)
            XCTAssertFalse(decoded.visibleModules.isEmpty, json)
            XCTAssertFalse(
                decoded.visibleModules.allSatisfy { $0.passwordModule == nil },
                json
            )
        }
        // 全隐藏脏配置会强制保留至少一个列表模块可见。
        let allHidden = try JSONDecoder().decode(
            VaultLayoutPreferences.self,
            from: Data(
                #"{"version":1,"moduleOrder":["login","passkey","note","generator"],"hiddenModuleIDs":["login","passkey","note","generator"]}"#.utf8
            )
        )
        XCTAssertFalse(allHidden.isHidden(.login))
        XCTAssertEqual(allHidden.visibleModules, [.login])
    }

    func testUnknownFutureVersionFallsBackToDefaults() throws {
        let future = try JSONDecoder().decode(
            VaultLayoutPreferences.self,
            from: Data(
                #"{"version":999,"moduleOrder":["note","generator"],"hiddenModuleIDs":["note"]}"#.utf8
            )
        )
        XCTAssertEqual(future, VaultLayoutPreferences.default)
    }

    func testCorruptStoredJSONFallsBackWithoutDeletingOriginalData() throws {
        let suiteName = "VaultLayoutPreferencesTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: layoutStoreKey)
        let store = UserDefaultsVaultLayoutPreferenceStore(userDefaults: defaults)
        XCTAssertEqual(store.loadPreferences(), VaultLayoutPreferences.default)
        // 不删除也不改写原始存储，用户数据仍在。
        XCTAssertEqual(defaults.data(forKey: layoutStoreKey), corrupt)
    }

    // MARK: 隐藏项仍可从「更多」进入

    func testHiddenModulesRemainReachableFromMoreMenu() throws {
        let session = AppSessionModel()

        var preferences = session.vaultLayoutPreferences
        preferences.setHidden(true, for: .passkey)
        preferences.setHidden(true, for: .note)
        session.updateVaultLayoutPreferences(preferences)

        let more = session.moreMenuLayoutModules
        XCTAssertTrue(more.contains(.passkey))
        XCTAssertTrue(more.contains(.note))
        XCTAssertTrue(more.contains(.generator))
        // 生成器恒定可达，菜单不会因布局变化而消失。
        XCTAssertEqual(more.filter { $0 == .generator }.count, 1)
        // issue #32：KeePass 库与生成器一样恒定可达。
        XCTAssertTrue(more.contains(.keePass))
        XCTAssertEqual(more.filter { $0 == .keePass }.count, 1)

        var showGenerator = session.vaultLayoutPreferences
        showGenerator.setHidden(false, for: .generator)
        session.updateVaultLayoutPreferences(showGenerator)
        XCTAssertFalse(session.vaultLayoutPreferences.isHidden(.generator))
        // 生成器未隐藏时，更多菜单仍保留一个工具入口，不会消失。
        XCTAssertTrue(session.moreMenuLayoutModules.contains(.generator))
        XCTAssertEqual(session.moreMenuLayoutModules.filter { $0 == .generator }.count, 1)
    }

    func testHidingSelectedModuleFallsBackToFirstVisibleListModule() {
        let session = AppSessionModel()
        session.passwordModule = .passkey

        var preferences = session.vaultLayoutPreferences
        preferences.setHidden(true, for: .passkey)
        session.updateVaultLayoutPreferences(preferences)

        XCTAssertEqual(session.passwordModule, .login)
        XCTAssertFalse(session.passwordModuleBarModules.contains(.passkey))
    }

    func testOtherModuleIsAlwaysLastInBar() {
        var preferences = VaultLayoutPreferences.default
        preferences.orderedModules = [.generator, .note, .passkey, .login]
        preferences.setHidden(false, for: .generator)
        preferences.setHidden(true, for: .passkey)
        let session = AppSessionModel(
            vaultLayoutPreferenceStore: MemoryVaultLayoutPreferenceStore(preferences: preferences)
        )
        XCTAssertEqual(session.passwordModuleBarModules.last, .other)
        XCTAssertEqual(session.passwordModuleBarModules.filter { $0 == .other }.count, 1)
        XCTAssertFalse(session.passwordModuleBarModules.contains(.passkey))
    }
}
