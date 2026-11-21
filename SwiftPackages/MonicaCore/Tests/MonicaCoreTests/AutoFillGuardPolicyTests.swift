import Foundation
import Testing

@testable import MonicaCore

@Suite("自动填充守护策略")
struct AutoFillGuardPolicyTests {
    @Test("锁定状态下任何开关组合都不允许发布身份")
    func lockedVaultAlwaysBlocksPublishing() {
        let combinations: [AutoFillGuardPolicy] = [
            AutoFillGuardPolicy(),
            AutoFillGuardPolicy(publishesOnlyAfterBiometricUnlock: true),
            AutoFillGuardPolicy(clearsPublishedIdentitiesWhenVaultLocks: true),
            AutoFillGuardPolicy(
                publishesOnlyAfterBiometricUnlock: true,
                clearsPublishedIdentitiesWhenVaultLocks: true
            ),
        ]

        for policy in combinations {
            for unlockedWithBiometrics in [true, false] {
                let decision = policy.publishDecision(
                    vaultIsUnlocked: false,
                    unlockedWithBiometrics: unlockedWithBiometrics
                )
                #expect(decision == .blocked(.vaultLocked))
                #expect(decision.isAllowed == false)
                #expect(decision.blockReason == .vaultLocked)
            }
        }
    }

    @Test("默认策略在解锁后保持既有发布行为")
    func defaultPolicyAllowsPublishingWhenUnlocked() {
        let policy = AutoFillGuardPolicy.default

        #expect(
            policy.publishDecision(vaultIsUnlocked: true, unlockedWithBiometrics: false) == .allowed
        )
        #expect(
            policy.publishDecision(vaultIsUnlocked: true, unlockedWithBiometrics: true) == .allowed
        )
    }

    @Test("开启生物识别发布后，主密码解锁的会话不得发布身份")
    func biometricOnlyPolicyBlocksPasswordUnlock() {
        let policy = AutoFillGuardPolicy(publishesOnlyAfterBiometricUnlock: true)

        let decision = policy.publishDecision(vaultIsUnlocked: true, unlockedWithBiometrics: false)

        #expect(decision == .blocked(.biometricUnlockRequired))
        #expect(decision.blockReason == .biometricUnlockRequired)
    }

    @Test("开启生物识别发布后，设备所有者认证解锁的会话可以发布身份")
    func biometricOnlyPolicyAllowsBiometricUnlock() {
        let policy = AutoFillGuardPolicy(publishesOnlyAfterBiometricUnlock: true)

        let decision = policy.publishDecision(vaultIsUnlocked: true, unlockedWithBiometrics: true)

        #expect(decision == .allowed)
        #expect(decision.blockReason == nil)
    }

    @Test("清空身份开关默认关闭，只在显式开启后生效")
    func clearsIdentitiesOnLockFollowsFlag() {
        #expect(AutoFillGuardPolicy.default.clearsIdentitiesOnLock == false)
        #expect(
            AutoFillGuardPolicy(clearsPublishedIdentitiesWhenVaultLocks: true)
                .clearsIdentitiesOnLock
        )
    }

    @Test("清空身份开关不影响发布裁决")
    func clearingIdentitiesDoesNotChangePublishDecision() {
        let policy = AutoFillGuardPolicy(clearsPublishedIdentitiesWhenVaultLocks: true)

        #expect(
            policy.publishDecision(vaultIsUnlocked: true, unlockedWithBiometrics: false) == .allowed
        )
        #expect(
            policy.publishDecision(vaultIsUnlocked: false, unlockedWithBiometrics: false)
                == .blocked(.vaultLocked)
        )
    }

    @Test("旧版本 payload 缺失字段时回退为关闭")
    func decodingLegacyPayloadFallsBackToDisabledFlags() throws {
        let legacy = Data("{}".utf8)

        let policy = try JSONDecoder().decode(AutoFillGuardPolicy.self, from: legacy)

        #expect(policy == AutoFillGuardPolicy.default)
        #expect(policy.publishesOnlyAfterBiometricUnlock == false)
        #expect(policy.clearsPublishedIdentitiesWhenVaultLocks == false)
    }

    @Test("编码后可原样解码")
    func roundTripsThroughCodable() throws {
        let policy = AutoFillGuardPolicy(
            publishesOnlyAfterBiometricUnlock: true,
            clearsPublishedIdentitiesWhenVaultLocks: true
        )

        let data = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(AutoFillGuardPolicy.self, from: data)

        #expect(decoded == policy)
    }
}
