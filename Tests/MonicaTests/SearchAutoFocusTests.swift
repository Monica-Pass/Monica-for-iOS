import XCTest
@testable import Monica

@MainActor
final class SearchAutoFocusTests: XCTestCase {
    func testDefaultIsOffAndEnablingPersists() {
        let store = MemoryAppSearchAutoFocusPreferenceStore()
        let model = AppSessionModel(searchAutoFocusPreferenceStore: store)

        XCTAssertFalse(model.isSearchAutoFocusOnLaunchEnabled)
        XCTAssertFalse(store.loadIsSearchAutoFocusEnabled())

        model.setSearchAutoFocusOnLaunchEnabled(true)

        XCTAssertTrue(model.isSearchAutoFocusOnLaunchEnabled)
        XCTAssertTrue(store.loadIsSearchAutoFocusEnabled())

        model.setSearchAutoFocusOnLaunchEnabled(false)

        XCTAssertFalse(model.isSearchAutoFocusOnLaunchEnabled)
        XCTAssertFalse(store.loadIsSearchAutoFocusEnabled())
    }

    func testInvalidPersistedValueFallsBackToOff() {
        let model = AppSessionModel(
            searchAutoFocusPreferenceStore: MemoryAppSearchAutoFocusPreferenceStore(persistedValue: "true")
        )

        XCTAssertFalse(model.isSearchAutoFocusOnLaunchEnabled)
    }

    func testColdLaunchFocusesOnce() {
        let model = makeUnlockedModel()
        XCTAssertTrue(model.isSearchAutoFocusOnLaunchEnabled)

        XCTAssertTrue(model.settleLaunchSearchAutoFocus(allowsForcedKeyboard: true))
        XCTAssertEqual(model.expandedToolbarAction, .search)
        XCTAssertTrue(model.isSearchAutoFocusPendingForPasswordPage)
        XCTAssertTrue(model.didHandleLaunchSearchAutoFocus)

        // 同一个进程只结算一次，不会再抢走用户后续的焦点。
        XCTAssertFalse(model.settleLaunchSearchAutoFocus(allowsForcedKeyboard: true))
    }

    func testLockedVaultNeverFocuses() {
        let model = makeModel(isEnabled: true)

        XCTAssertFalse(model.settleLaunchSearchAutoFocus(allowsForcedKeyboard: true))
        XCTAssertFalse(model.didHandleLaunchSearchAutoFocus)
        XCTAssertNil(model.expandedToolbarAction)
        XCTAssertFalse(model.isSearchAutoFocusPendingForPasswordPage)
    }

    func testDeepLinkOrControlCenterTargetSuppressesFocus() {
        let model = makeUnlockedModel()

        // 控制中心导航可能落在密码页且不留详情路由，必须靠启动导航标记压制。
        model.handleControlPage(.passwords)

        XCTAssertFalse(model.settleLaunchSearchAutoFocus(allowsForcedKeyboard: true))
        XCTAssertNil(model.expandedToolbarAction)
        XCTAssertFalse(model.isSearchAutoFocusPendingForPasswordPage)
    }

    func testDisabledSwitchSuppressesFocus() {
        let model = makeModel(isEnabled: false)
        model.vaultState = .unlocked

        XCTAssertFalse(model.settleLaunchSearchAutoFocus(allowsForcedKeyboard: true))
        XCTAssertNil(model.expandedToolbarAction)
    }

    func testRegularWidthDoesNotForceKeyboard() {
        let model = makeUnlockedModel()

        XCTAssertFalse(model.settleLaunchSearchAutoFocus(allowsForcedKeyboard: false))
        XCTAssertNil(model.expandedToolbarAction)
    }

    func testNonPasswordTabSuppressesFocus() {
        let model = makeUnlockedModel()
        model.selectedTab = .totp

        XCTAssertFalse(model.settleLaunchSearchAutoFocus(allowsForcedKeyboard: true))
        XCTAssertNil(model.expandedToolbarAction)
    }

    func testDiagnosticContextForColdLaunch() {
        let model = makeUnlockedModel()
        let before = model.didHandleLaunchSearchAutoFocus
        let should = model.shouldFocusSearchOnLaunch(isPasswordRoot: true, allowsForcedKeyboard: true)
        let taken = model.takeLaunchSearchAutoFocus(isPasswordRoot: true, allowsForcedKeyboard: true)
        let settled = model.settleLaunchSearchAutoFocus(allowsForcedKeyboard: true)
        print(
            "DIAG2 beforeHandled=\(before) shouldFocus=\(should) taken=\(taken) settled=\(settled) afterHandled=\(model.didHandleLaunchSearchAutoFocus) suppressing=\(model.hasPendingSearchAutoFocusSuppressingTarget) action=\(String(describing: model.expandedToolbarAction)) pendingPage=\(model.isSearchAutoFocusPendingForPasswordPage)"
        )
    }

    private func makeModel(isEnabled: Bool) -> AppSessionModel {
        AppSessionModel(
            searchAutoFocusPreferenceStore: MemoryAppSearchAutoFocusPreferenceStore(persistedValue: isEnabled)
        )
    }

    private func makeUnlockedModel() -> AppSessionModel {
        let model = makeModel(isEnabled: true)
        model.vaultState = .unlocked
        return model
    }
}
