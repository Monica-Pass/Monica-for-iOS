import Foundation
import MonicaCore

/// 「启动时自动聚焦搜索框」设置项的读写约定。
protocol AppSearchAutoFocusPreferenceStore: Sendable {
    func loadIsSearchAutoFocusEnabled() -> Bool
    func saveIsSearchAutoFocusEnabled(_ isEnabled: Bool)
}

/// 使用 UserDefaults 持久化；键缺失或值非法时回退为关闭。
final class UserDefaultsAppSearchAutoFocusPreferenceStore: AppSearchAutoFocusPreferenceStore, @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let key: String

    init(
        userDefaults: UserDefaults = .standard,
        key: String = SearchAutoFocusPreference.userDefaultsKey
    ) {
        self.userDefaults = userDefaults
        self.key = key
    }

    func loadIsSearchAutoFocusEnabled() -> Bool {
        SearchAutoFocusPreference.isEnabled(persistedValue: userDefaults.object(forKey: key))
    }

    func saveIsSearchAutoFocusEnabled(_ isEnabled: Bool) {
        userDefaults.set(isEnabled, forKey: key)
    }
}

/// 测试与预览用的内存实现。
final class MemoryAppSearchAutoFocusPreferenceStore: AppSearchAutoFocusPreferenceStore, @unchecked Sendable {
    private(set) var persistedValue: Any?

    init(persistedValue: Any? = nil) {
        self.persistedValue = persistedValue
    }

    func loadIsSearchAutoFocusEnabled() -> Bool {
        SearchAutoFocusPreference.isEnabled(persistedValue: persistedValue)
    }

    func saveIsSearchAutoFocusEnabled(_ isEnabled: Bool) {
        persistedValue = isEnabled
    }
}

extension AppSessionModel {
    /// 更新设置项并持久化；值没有变化时不写盘、不记录用户活动。
    func setSearchAutoFocusOnLaunchEnabled(_ isEnabled: Bool) {
        guard isSearchAutoFocusOnLaunchEnabled != isEnabled else {
            return
        }
        isSearchAutoFocusOnLaunchEnabled = isEnabled
        searchAutoFocusPreferenceStore.saveIsSearchAutoFocusEnabled(isEnabled)
        recordUserActivity()
    }

    /// 当前是否有会覆盖启动自动聚焦的导航目标或模态界面。
    var hasPendingSearchAutoFocusSuppressingTarget: Bool {
        didReceiveLaunchNavigationTarget
            || pendingControlPage != nil
            || presentedDetailRoute != nil
            || monicaSendIncoming != nil
            || isGlobalSearchPresented
            || isKeePassLibraryPresented
            || isVaultOverviewPresented
            || presentedEditorMode != nil
            || isQuickSetupPresented
            || isExtensionsPresented
            || isAccountTemplatesPresented
    }

    /// 启动自动聚焦的决策上下文，复用 MonicaCore 里的纯策略。
    func searchAutoFocusContext(isPasswordRoot: Bool, allowsForcedKeyboard: Bool) -> SearchAutoFocusContext {
        SearchAutoFocusContext(
            isEnabled: isSearchAutoFocusOnLaunchEnabled,
            isVaultUnlocked: vaultState == .unlocked,
            isPasswordPage: isPasswordRoot && selectedTab == .passwords,
            hasPendingNavigationTarget: hasPendingSearchAutoFocusSuppressingTarget,
            allowsForcedKeyboard: allowsForcedKeyboard,
            hasAlreadyHandledLaunch: didHandleLaunchSearchAutoFocus
        )
    }

    /// 是否应该聚焦搜索框。纯查询，没有副作用，便于测试与预览。
    func shouldFocusSearchOnLaunch(isPasswordRoot: Bool, allowsForcedKeyboard: Bool) -> Bool {
        SearchAutoFocusPolicy.shouldFocusOnLaunch(
            searchAutoFocusContext(isPasswordRoot: isPasswordRoot, allowsForcedKeyboard: allowsForcedKeyboard)
        )
    }

    /// 解锁后由根视图调用：结算启动自动聚焦（每个进程只结算一次）。
    @discardableResult
    func settleLaunchSearchAutoFocus(allowsForcedKeyboard: Bool) -> Bool {
        takeLaunchSearchAutoFocus(
            isPasswordRoot: selectedTab == .passwords,
            allowsForcedKeyboard: allowsForcedKeyboard
        )
    }

    /// 结算本次启动的自动聚焦：同一个进程只结算一次，返回是否真的需要聚焦。
    @discardableResult
    func takeLaunchSearchAutoFocus(isPasswordRoot: Bool, allowsForcedKeyboard: Bool) -> Bool {
        guard vaultState == .unlocked, !didHandleLaunchSearchAutoFocus else {
            return false
        }
        didHandleLaunchSearchAutoFocus = true
        guard shouldFocusSearchOnLaunch(isPasswordRoot: isPasswordRoot, allowsForcedKeyboard: allowsForcedKeyboard) else {
            return false
        }
        expandedToolbarAction = .search
        isSearchAutoFocusPendingForPasswordPage = true
        return true
    }
}
