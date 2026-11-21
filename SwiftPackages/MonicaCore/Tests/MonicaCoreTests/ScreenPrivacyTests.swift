import Testing
@testable import MonicaCore

@Suite("屏幕隐私保护")
struct ScreenPrivacyTests {

    // MARK: - 场景切换

    @Test func activePhaseHidesShieldAndKeepsSession() {
        let unlocked = ScreenPrivacyPolicy.decision(for: .active, isVaultUnlocked: true)
        #expect(unlocked.showsShield == false)
        #expect(unlocked.locksVault == false)

        let locked = ScreenPrivacyPolicy.decision(for: .active, isVaultUnlocked: false)
        #expect(locked.showsShield == false)
        #expect(locked.locksVault == false)
    }

    @Test func inactivePhaseShieldsWithoutLockingEvenWhenVaultIsLocked() {
        let unlocked = ScreenPrivacyPolicy.decision(for: .inactive, isVaultUnlocked: true)
        #expect(unlocked.showsShield == true)
        // App Switcher 手势会先进入 inactive；此时不能丢会话。
        #expect(unlocked.locksVault == false)

        let locked = ScreenPrivacyPolicy.decision(for: .inactive, isVaultUnlocked: false)
        #expect(locked.showsShield == true)
        #expect(locked.locksVault == false)
    }

    @Test func backgroundPhaseShieldsEvenWhenVaultIsLocked() {
        let locked = ScreenPrivacyPolicy.decision(for: .background, isVaultUnlocked: false)
        // 锁屏上也可能有主密码输入等可见内容，后台必须遮住。
        #expect(locked.showsShield == true)
        #expect(locked.locksVault == false)
    }

    @Test func backgroundPhaseLocksOnlyUnlockedVault() {
        let unlocked = ScreenPrivacyPolicy.decision(for: .background, isVaultUnlocked: true)
        #expect(unlocked.showsShield == true)
        #expect(unlocked.locksVault == true)
    }

    // MARK: - 录制/共享期间的强制掩码

    @Test func captureForcesMaskingEvenWhenUserRequestedReveal() {
        #expect(
            SensitiveFieldMaskingPolicy.isMasked(isSceneCaptured: true, userRequestedReveal: true) == true
        )
        #expect(
            SensitiveFieldMaskingPolicy.isMasked(isSceneCaptured: true, userRequestedReveal: false) == true
        )
    }

    @Test func maskingFollowsUserPreferenceWhenCaptureStops() {
        // 停止录制后回落到用户自己的「显示敏感字段」开关，无需改写用户设置。
        #expect(
            SensitiveFieldMaskingPolicy.isMasked(isSceneCaptured: false, userRequestedReveal: true) == false
        )
        #expect(
            SensitiveFieldMaskingPolicy.isMasked(isSceneCaptured: false, userRequestedReveal: false) == true
        )
    }
}
