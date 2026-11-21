import Foundation
import Testing
@testable import MonicaCore

/// RFC 6238 附录 B 的种子（ASCII "12345678901234567890" 的 Base32）。
private let rfc6238Secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
/// 正好落在 30 秒周期的起点。
private let rfc6238BaseTimestamp: TimeInterval = 1_800_000_000

/// 与 App 使用同一条生成路径；`validFrom` 就是下一码所属周期的起点。
private func rfc6238Code(_ nextCode: TotpAutoCopyNextCode) throws -> String {
    try TotpGenerator.generate(
        secret: rfc6238Secret,
        algorithm: .sha1,
        digits: 6,
        period: 30,
        timestamp: nextCode.validFrom.timeIntervalSince1970
    )
}

/// 固定时钟 + 假剪贴板 + 真实敏感剪贴板控制器。
///
/// 每次都把假时钟推进到 tick 的时刻，保证 `MonicaSensitivePasteboard`
/// 记录的到期时间与请求时间一致。
@MainActor
private final class AutoCopyHarness {
    let clock: MutableSensitiveClock
    let fake: FakeSensitivePasteboard
    let pasteboard: MonicaSensitivePasteboard
    let controller: TotpAutoCopyController

    private let ttl: SensitiveClipboardTTL

    init(ttl: SensitiveClipboardTTL = .seconds30, prefetchWindowSeconds: Int = 3) {
        let clock = MutableSensitiveClock(now: Date(timeIntervalSince1970: rfc6238BaseTimestamp))
        let fake = FakeSensitivePasteboard()
        let pasteboard = MonicaSensitivePasteboard(
            pasteboard: fake,
            now: { clock.now },
            digestKeyBytes: [0x31, 0x34, 0x38]
        )
        self.clock = clock
        self.fake = fake
        self.pasteboard = pasteboard
        self.ttl = ttl
        self.controller = TotpAutoCopyController(
            pasteboard: pasteboard,
            policy: TotpAutoCopyPolicy(prefetchWindowSeconds: prefetchWindowSeconds)
        )
    }

    func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: rfc6238BaseTimestamp + offset)
    }

    func arm(_ entryID: String = "entry-a") {
        controller.arm(entryID: entryID)
    }

    func entry(_ entryID: String = "entry-a", period: Int = 30, isHOTP: Bool = false) -> TotpAutoCopyController.Entry {
        TotpAutoCopyController.Entry(entryID: entryID, period: period, isHOTP: isHOTP)
    }

    @discardableResult
    func tick(
        _ offset: TimeInterval,
        entry: TotpAutoCopyController.Entry? = nil,
        isEnabled: Bool = true,
        isVaultUnlocked: Bool = true,
        isSceneActive: Bool = true,
        isAuthenticatorPageVisible: Bool = true,
        ttl: SensitiveClipboardTTL? = nil,
        code: (TotpAutoCopyNextCode) throws -> String = rfc6238Code
    ) -> TotpAutoCopyOutcome {
        let now = date(offset)
        clock.now = now
        return controller.tick(
            TotpAutoCopyController.Request(
                isEnabled: isEnabled,
                isVaultUnlocked: isVaultUnlocked,
                isSceneActive: isSceneActive,
                isAuthenticatorPageVisible: isAuthenticatorPageVisible,
                ttl: ttl ?? self.ttl,
                now: now
            ),
            entry: entry ?? self.entry(),
            code: code
        )
    }
}

/// 固定向量（独立用 python hmac 算过）：T=1_800_000_000/1_800_000_027 都是
/// counter 60,000,000 → `768147`；T=1_800_000_030/1_800_000_057 都是
/// counter 60,000,001 → `050219`。
@MainActor
@Suite("验证码到期自动续写")
struct TotpAutoCopyPolicyTests {
    @Test("剩余秒数与周期起点语义一致")
    func remainingSecondsMatchesAppSemantics() {
        let policy = TotpAutoCopyPolicy()
        let base = Date(timeIntervalSince1970: rfc6238BaseTimestamp)
        func at(_ offset: TimeInterval) -> Date {
            base.addingTimeInterval(offset)
        }

        #expect(policy.remainingSeconds(now: at(0), period: 30) == 30)
        #expect(policy.remainingSeconds(now: at(1), period: 30) == 29)
        #expect(policy.remainingSeconds(now: at(27), period: 30) == 3)
        #expect(policy.remainingSeconds(now: at(29), period: 30) == 1)
        #expect(policy.remainingSeconds(now: at(0), period: 0) == nil)
    }

    @Test("只有进入预取窗口才返回下一码")
    func nextCodeDueOnlyInsidePrefetchWindow() {
        let policy = TotpAutoCopyPolicy(prefetchWindowSeconds: 3)
        let base = Date(timeIntervalSince1970: rfc6238BaseTimestamp)

        #expect(policy.nextCodeDue(now: base.addingTimeInterval(26), period: 30, remainingSeconds: 4) == nil)
        let due = policy.nextCodeDue(now: base.addingTimeInterval(27), period: 30, remainingSeconds: 3)
        #expect(due?.periodIndex == 60_000_001)
        #expect(due?.validFrom == base.addingTimeInterval(30))
        #expect(policy.nextCodeDue(now: base.addingTimeInterval(27), period: 2, remainingSeconds: 1) == nil)
    }

    @Test("开关关闭时不写剪贴板")
    func disabledNeverWrites() {
        let harness = AutoCopyHarness()
        harness.arm()

        let outcome = harness.tick(27, isEnabled: false)

        #expect(outcome == .skipped(.disabled))
        #expect(harness.fake.writeCount == 0)
        #expect(!harness.fake.hasContent)
        #expect(harness.pasteboard.hasPendingAutoClear == false)
    }

    @Test("锁屏、后台与页面不可见时不写剪贴板")
    func backgroundAndLockedNeverWrite() {
        let harness = AutoCopyHarness()
        harness.arm()

        #expect(harness.tick(27, isVaultUnlocked: false) == .skipped(.vaultLocked))
        #expect(harness.tick(27, isSceneActive: false) == .skipped(.sceneNotActive))
        #expect(harness.tick(27, isAuthenticatorPageVisible: false) == .skipped(.authenticatorPageNotVisible))
        #expect(harness.fake.writeCount == 0)
        #expect(!harness.fake.hasContent)
    }

    @Test("HOTP 条目不自动续写")
    func hotpIsNeverAutoCopied() {
        let harness = AutoCopyHarness()
        harness.arm("hotp-entry")

        let outcome = harness.tick(27, entry: harness.entry("hotp-entry", isHOTP: true))

        #expect(outcome == .skipped(.hotpEntry))
        #expect(harness.fake.writeCount == 0)
    }

    @Test("没有手动复制过验证码时不续写")
    func neverWritesBeforeManualCopy() {
        let harness = AutoCopyHarness()

        let outcome = harness.tick(27)

        #expect(outcome == .skipped(.notArmed))
        #expect(harness.fake.writeCount == 0)
    }

    @Test("用户复制了别的内容后不覆盖剪贴板")
    func clipboardReplacedByAnotherAppIsLeftAlone() {
        let harness = AutoCopyHarness()
        harness.arm()
        harness.fake.simulateForeignCopy("其它 App 的内容")

        let outcome = harness.tick(27)

        #expect(outcome == .skipped(.clipboardReplacedByAnotherApp))
        #expect(harness.fake.writeCount == 0)
        #expect(harness.fake.string == "其它 App 的内容")
        #expect(!harness.controller.isArmed)
    }

    @Test("未进入预取窗口时不写剪贴板")
    func notDueOutsideWindow() {
        let harness = AutoCopyHarness()
        harness.arm()

        let outcome = harness.tick(0)

        #expect(outcome == .skipped(.notYetDue(remainingSeconds: 30)))
        #expect(harness.fake.writeCount == 0)
    }

    @Test("预取窗口不短于周期时永不触发")
    func prefetchWindowMustBeShorterThanPeriod() {
        let harness = AutoCopyHarness()
        harness.arm()

        let outcome = harness.tick(27, entry: harness.entry(period: 2))

        #expect(outcome == .skipped(.prefetchWindowNotShorterThanPeriod))
        #expect(harness.fake.writeCount == 0)
    }

    @Test("写入的是下一码而不是当前码")
    func copiesNextCodeValue() throws {
        let harness = AutoCopyHarness()
        harness.arm()

        let outcome = harness.tick(27)
        let currentCode = try TotpGenerator.generate(
            secret: rfc6238Secret,
            algorithm: .sha1,
            digits: 6,
            period: 30,
            timestamp: rfc6238BaseTimestamp + 27
        )

        // 独立计算过的固定向量：27s 属于 counter 60,000,000，下一码属于 60,000,001。
        let expectedNextCode = try rfc6238Code(
            TotpAutoCopyNextCode(periodIndex: 60_000_001, validFrom: harness.date(30))
        )
        #expect(currentCode == "768147")
        #expect(expectedNextCode == "050219")
        #expect(outcome == .copied(entryID: "entry-a", periodIndex: 60_000_001, expiresAt: harness.date(57)))
        #expect(harness.fake.string == "050219")
        #expect(harness.fake.string != currentCode)
    }

    @Test("同一周期只写一次，到下一个周期才再写")
    func writesAtMostOncePerPeriod() throws {
        let harness = AutoCopyHarness()
        harness.arm()

        // 27 秒：写下一码。
        #expect(harness.tick(27) == .copied(entryID: "entry-a", periodIndex: 60_000_001, expiresAt: harness.date(57)))
        #expect(harness.fake.writeCount == 1)

        // 同一周期内反复 tick 不再写。
        for offset in [28.0, 29.0] {
            #expect(harness.tick(offset) == .skipped(.alreadyCopiedThisPeriod(periodIndex: 60_000_001)))
        }
        #expect(harness.fake.writeCount == 1)

        // 新周期开始：还没到预取窗口。
        #expect(harness.tick(30) == .skipped(.notYetDue(remainingSeconds: 30)))
        #expect(harness.fake.writeCount == 1)

        // 57 秒：写下一个周期的码。
        #expect(harness.tick(57) == .copied(entryID: "entry-a", periodIndex: 60_000_002, expiresAt: harness.date(87)))
        #expect(harness.fake.writeCount == 2)
        let expectedSecondCode = try rfc6238Code(
            TotpAutoCopyNextCode(periodIndex: 60_000_002, validFrom: harness.date(60))
        )
        #expect(harness.fake.string == expectedSecondCode)

        // 跨周期后同一周期仍然只写一次。
        #expect(harness.tick(58) == .skipped(.alreadyCopiedThisPeriod(periodIndex: 60_000_002)))
        #expect(harness.fake.writeCount == 2)
    }

    @Test("自动写入的码同样受自动清除时长约束")
    func automaticCopyHonoursTTL() {
        let harness = AutoCopyHarness(ttl: .seconds30)
        harness.arm()

        #expect(harness.tick(27).isCopied)
        #expect(harness.pasteboard.remainingSeconds(at: harness.date(27)) == 30)
        #expect(harness.pasteboard.clearIfExpired(at: harness.date(56)) == .notYetDue(expiresAt: harness.date(57)))
        #expect(harness.fake.hasContent)
        #expect(harness.pasteboard.clearIfExpired(at: harness.date(57)) == .cleared)
        #expect(!harness.fake.hasContent)
        #expect(harness.fake.clearCount == 1)
    }

    @Test("关闭自动清除时不留下待清理记录")
    func automaticCopyWithTTLOffLeavesNoRecord() {
        let harness = AutoCopyHarness(ttl: .off)
        harness.arm()

        let outcome = harness.tick(27)

        #expect(outcome == .copied(entryID: "entry-a", periodIndex: 60_000_001, expiresAt: nil))
        #expect(harness.pasteboard.hasPendingAutoClear == false)
        #expect(harness.fake.string == "050219")
    }

    @Test("剪贴板被自动清除后停止续写")
    func stopsAfterClipboardWasCleared() {
        let harness = AutoCopyHarness(ttl: .seconds15)
        harness.arm()

        #expect(harness.tick(27).isCopied)
        #expect(harness.pasteboard.clearIfExpired(at: harness.date(42)) == .cleared)

        let outcome = harness.tick(57, ttl: .seconds15)

        #expect(outcome == .skipped(.clipboardReplacedByAnotherApp))
        #expect(harness.fake.writeCount == 1)
        #expect(!harness.controller.isArmed)
    }

    @Test("开关默认关闭并持久化到 UserDefaults")
    func preferenceDefaultsToOff() {
        let suiteName = "MonicaTotpAutoCopyPolicyTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsTotpAutoCopyPreferenceStore(userDefaults: defaults)
        #expect(store.loadIsEnabled() == false)

        store.saveIsEnabled(true)
        #expect(store.loadIsEnabled())
        #expect(defaults.bool(forKey: UserDefaultsTotpAutoCopyPreferenceStore.userDefaultsKey))
        #expect(UserDefaultsTotpAutoCopyPreferenceStore.userDefaultsKey == "monica.totp.autoCopyNextCode")
    }

    @Test("内存偏好实现可用于测试与预览")
    func memoryPreferenceStore() {
        let store = MemoryTotpAutoCopyPreferenceStore()
        #expect(store.loadIsEnabled() == false)
        store.saveIsEnabled(true)
        #expect(store.loadIsEnabled())
    }
}

private extension TotpAutoCopyOutcome {
    var isCopied: Bool {
        if case .copied = self {
            return true
        }
        return false
    }
}
