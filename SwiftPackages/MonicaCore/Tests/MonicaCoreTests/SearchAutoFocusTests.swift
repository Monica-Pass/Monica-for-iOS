import Foundation
import MonicaCore
import Testing

@Suite("启动自动聚焦搜索框")
struct SearchAutoFocusTests {
    @Test("冷启动、开关开启、已解锁时聚焦")
    func coldLaunchFocuses() {
        #expect(SearchAutoFocusPolicy.shouldFocusOnLaunch(.init(isEnabled: true, isVaultUnlocked: true)))
    }

    @Test("有深链 / 控制中心 / 快捷指令目标时不抢焦点")
    func pendingNavigationTargetSuppressesFocus() {
        let context = SearchAutoFocusContext(
            isEnabled: true,
            isVaultUnlocked: true,
            hasPendingNavigationTarget: true
        )
        #expect(SearchAutoFocusPolicy.shouldFocusOnLaunch(context) == false)
    }

    @Test("开关关闭时不聚焦")
    func disabledSwitchSuppressesFocus() {
        let context = SearchAutoFocusContext(isEnabled: false, isVaultUnlocked: true)
        #expect(SearchAutoFocusPolicy.shouldFocusOnLaunch(context) == false)
    }

    @Test("未解锁绝不聚焦，避免键盘遮挡锁屏")
    func lockedVaultNeverFocuses() {
        let context = SearchAutoFocusContext(isEnabled: true, isVaultUnlocked: false)
        #expect(SearchAutoFocusPolicy.shouldFocusOnLaunch(context) == false)
    }

    @Test("不在密码页时不聚焦")
    func nonPasswordPageSuppressesFocus() {
        let context = SearchAutoFocusContext(isEnabled: true, isVaultUnlocked: true, isPasswordPage: false)
        #expect(SearchAutoFocusPolicy.shouldFocusOnLaunch(context) == false)
    }

    @Test("iPad 大屏与分屏不强制弹出键盘")
    func regularWidthDoesNotForceKeyboard() {
        let context = SearchAutoFocusContext(isEnabled: true, isVaultUnlocked: true, allowsForcedKeyboard: false)
        #expect(SearchAutoFocusPolicy.shouldFocusOnLaunch(context) == false)
    }

    @Test("同一次启动只聚焦一次")
    func launchIsHandledOnce() {
        let context = SearchAutoFocusContext(
            isEnabled: true,
            isVaultUnlocked: true,
            hasAlreadyHandledLaunch: true
        )
        #expect(SearchAutoFocusPolicy.shouldFocusOnLaunch(context) == false)
    }

    @Test("缺失或非法持久化值回退为关闭")
    func invalidPersistedValuesFallBackToOff() {
        #expect(SearchAutoFocusPreference.isEnabled(persistedValue: nil) == false)
        #expect(SearchAutoFocusPreference.isEnabled(persistedValue: "true") == false)
        #expect(SearchAutoFocusPreference.isEnabled(persistedValue: "1") == false)
        #expect(SearchAutoFocusPreference.isEnabled(persistedValue: 1) == false)
        #expect(SearchAutoFocusPreference.isEnabled(persistedValue: NSNumber(value: 1)) == false)
        #expect(SearchAutoFocusPreference.isEnabled(persistedValue: false) == false)
    }

    @Test("合法布尔值按原值读取")
    func booleanPersistedValuesAreRespected() {
        #expect(SearchAutoFocusPreference.isEnabled(persistedValue: true))
        #expect(SearchAutoFocusPreference.isEnabled(persistedValue: NSNumber(value: true)))
        #expect(SearchAutoFocusPreference.isEnabled(persistedValue: false) == false)
    }
}
