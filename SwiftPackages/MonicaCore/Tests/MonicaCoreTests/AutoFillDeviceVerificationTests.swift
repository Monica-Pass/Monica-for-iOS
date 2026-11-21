import Foundation
import Testing

@testable import MonicaCore

@Suite("自动填充设备验证")
struct AutoFillDeviceVerificationTests {
    @Test("开关默认关闭时静默填充与交互填充都与历史行为一致")
    func defaultPolicyKeepsExistingBehaviour() {
        let policy = AutoFillDeviceVerificationPolicy.default

        #expect(policy.requiresVerificationBeforeFilling == false)
        #expect(policy.authorizeSilentFill().isAuthorized)

        let outcomes: [AutoFillDeviceVerificationOutcome] = [
            .verified,
            .cancelled,
            .failed,
            .unavailable,
        ]
        for outcome in outcomes {
            #expect(policy.authorizeInteractiveFill(after: outcome).isAuthorized)
        }
    }

    @Test("开关打开后静默路径绝不直接放行密码")
    func enabledPolicyNeverFillsSilently() {
        let policy = AutoFillDeviceVerificationPolicy(requiresVerificationBeforeFilling: true)
        let authorization = policy.authorizeSilentFill()

        #expect(authorization == .interactionRequired)
        #expect(authorization.isAuthorized == false)
        #expect(authorization.grant == nil)
        #expect(authorization.failure == nil)
    }

    @Test("开关打开后注入的四种验证结果只在验证通过时放行")
    func enabledPolicyMapsEveryOutcome() {
        let policy = AutoFillDeviceVerificationPolicy(requiresVerificationBeforeFilling: true)

        let verified = policy.authorizeInteractiveFill(after: .verified)
        #expect(verified.isAuthorized)
        #expect(verified.grant?.isAvailable == true)
        #expect(verified.failure == nil)

        let expectedFailures: [(AutoFillDeviceVerificationOutcome, AutoFillDeviceVerificationFailure)] = [
            (.cancelled, .userCancelled),
            (.failed, .verificationFailed),
            (.unavailable, .verificationUnavailable),
        ]
        for (outcome, expectedFailure) in expectedFailures {
            let authorization = policy.authorizeInteractiveFill(after: outcome)
            #expect(authorization.isAuthorized == false)
            #expect(authorization.grant == nil)
            #expect(authorization == .refused(expectedFailure))
        }
    }

    @Test("同一份验证结果只能放行一次填充")
    func grantIsSingleUse() throws {
        var grant = AutoFillDeviceVerificationGrant()
        #expect(grant.isAvailable)
        let firstUse = grant.consume()
        #expect(firstUse)
        #expect(grant.isAvailable == false)
        let secondUse = grant.consume()
        #expect(secondUse == false)

        // 每次判决都发新的放行凭证：取消一次不影响下一次（也说明没有缓存上一次的验证结果）。
        let policy = AutoFillDeviceVerificationPolicy(requiresVerificationBeforeFilling: true)
        let first = policy.authorizeInteractiveFill(after: .verified)
        let second = policy.authorizeInteractiveFill(after: .verified)
        var firstGrant = try #require(first.grant)
        var secondGrant = try #require(second.grant)
        let firstGrantUsed = firstGrant.consume()
        let secondGrantUsed = secondGrant.consume()
        #expect(firstGrantUsed)
        #expect(secondGrantUsed)
    }

    @Test("拒绝原因不带任何凭据内容，文案明确说明没有返回密码")
    func failuresCarryNoCredentialAndSaySo() {
        // 拒绝结果只带原因码：Mirror 里没有任何字段，也就不可能夹带用户名或密码。
        #expect(Mirror(reflecting: AutoFillDeviceVerificationFailure.verificationFailed).children.isEmpty)

        let failures: [AutoFillDeviceVerificationFailure] = [
            .userCancelled,
            .verificationFailed,
            .verificationUnavailable,
        ]
        for failure in failures {
            let message = failure.message
            #expect(message.isEmpty == false)
            #expect(message.contains("没有返回密码") || message.contains("不会返回密码"))
            // 文案不吹嘘验证成功，也不含任何示例凭据。
            #expect(message.contains("验证成功") == false)
            #expect(message.contains("hunter2") == false)
        }
    }

    @Test("开关默认关闭，写入后对新实例可见")
    func preferenceStorePersistsAcrossInstances() {
        let suiteName = "monica.tests.issue146.\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }

        let store = AutoFillDeviceVerificationPreferenceStore(suiteName: suiteName)
        #expect(store.requiresVerificationBeforeFilling == false)

        store.saveRequiresVerificationBeforeFilling(true)
        #expect(store.requiresVerificationBeforeFilling)

        let reloaded = AutoFillDeviceVerificationPreferenceStore(suiteName: suiteName)
        #expect(reloaded.requiresVerificationBeforeFilling)

        store.saveRequiresVerificationBeforeFilling(false)
        #expect(reloaded.requiresVerificationBeforeFilling == false)
    }

    @Test("共享偏好不可用时按开启处理，宁可多验证一次也不直接给密码")
    func preferenceStoreFailsClosedWhenGroupUnavailable() {
        let store = AutoFillDeviceVerificationPreferenceStore(defaults: nil)

        #expect(store.isAvailable == false)
        #expect(store.requiresVerificationBeforeFilling)
    }
}
