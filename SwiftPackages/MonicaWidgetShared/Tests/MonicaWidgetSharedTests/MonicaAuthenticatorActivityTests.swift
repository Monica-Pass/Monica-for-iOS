//
//  MonicaAuthenticatorActivityTests.swift
//  MonicaWidgetSharedTests
//
//  覆盖 Issue #47 里能进包的逻辑：载荷只含非敏感字段、倒计时窗口边界、
//  别名/周期清洗、feature-gate 回退、以及「结束/超时」的状态迁移。
//

import Foundation
import Testing
@testable import MonicaWidgetShared

@Suite("Authenticator Live Activity plan")
struct MonicaAuthenticatorActivityPlanTests {
    private func entry(period: Int = 30) -> MonicaAuthenticatorActivityEntry {
        MonicaAuthenticatorActivityEntry(id: "entry-1", alias: "GitHub", period: period)
    }

    @Test("payload only carries the non-secret fields")
    func payloadContainsNoSecret() throws {
        let entry = MonicaAuthenticatorActivityEntry(id: "e", alias: "GitHub", period: 30)
        #expect(entry.id == "e")
        #expect(entry.alias == "GitHub")
        #expect(entry.period == 30)
        // 共享载荷类型没有 secret / 验证码字段，编码结果里也不应出现它们。
        let encoded = String(data: try JSONEncoder().encode(entry), encoding: .utf8) ?? ""
        #expect(!encoded.lowercased().contains("secret"))
        #expect(!encoded.lowercased().contains("code"))
        #expect(encoded.contains("GitHub"))
    }

    @Test("window start snaps to the period boundary")
    func windowAlignment() {
        // 1970-01-01T00:16:39Z => 999 秒，周期 30 => 窗口 [990, 1020)
        let now = Date(timeIntervalSince1970: 999)
        let plan = MonicaAuthenticatorActivityPlan(entry: entry(), now: now)
        #expect(plan.windowStart == Date(timeIntervalSince1970: 990))
        #expect(plan.windowEnd == Date(timeIntervalSince1970: 1020))
        #expect(plan.remainingSeconds(at: now) == 21)
        // 与 App 现有 totpTimeRemaining 的取整方式一致：整秒边界给满周期。
        #expect(plan.remainingSeconds(at: Date(timeIntervalSince1970: 1020)) == 0)
        #expect(plan.remainingSeconds(at: Date(timeIntervalSince1970: 1021)) == 0)
        #expect(plan.remainingSeconds(at: Date(timeIntervalSince1970: 1000)) == 20)
    }

    @Test("remaining seconds round up so the last tick never shows zero early")
    func remainingRoundsUp() {
        let plan = MonicaAuthenticatorActivityPlan(entry: entry(), now: Date(timeIntervalSince1970: 990.2))
        #expect(plan.remainingSeconds(at: Date(timeIntervalSince1970: 990.2)) == 30)
        #expect(plan.remainingSeconds(at: Date(timeIntervalSince1970: 1019.1)) == 1)
        #expect(plan.remainingSeconds(at: Date(timeIntervalSince1970: 1019.9)) == 1)
    }

    @Test("session end and stale date use the normalized pilot duration")
    func sessionDuration() {
        let now = Date(timeIntervalSince1970: 100)
        let plan = MonicaAuthenticatorActivityPlan(entry: entry(), now: now)
        #expect(plan.sessionEndsAt == now.addingTimeInterval(MonicaAuthenticatorActivityLimits.pilotSessionDuration))
        #expect(plan.staleDate == plan.sessionEndsAt)
        #expect(!plan.isExpired(at: plan.sessionEndsAt.addingTimeInterval(-1)))
        #expect(plan.isExpired(at: plan.sessionEndsAt))
    }

    @Test("duration is clamped into the supported range")
    func durationClamping() {
        let now = Date(timeIntervalSince1970: 0)
        let short = MonicaAuthenticatorActivityPlan(entry: entry(), now: now, duration: 5)
        #expect(short.sessionEndsAt == now.addingTimeInterval(MonicaAuthenticatorActivityLimits.minimumSessionDuration))
        let long = MonicaAuthenticatorActivityPlan(entry: entry(), now: now, duration: 48 * 60 * 60)
        #expect(long.sessionEndsAt == now.addingTimeInterval(MonicaAuthenticatorActivityLimits.systemMaximumDuration))
        let nan = MonicaAuthenticatorActivityPlan(entry: entry(), now: now, duration: .nan)
        #expect(nan.sessionEndsAt == now.addingTimeInterval(MonicaAuthenticatorActivityLimits.pilotSessionDuration))
    }

    @Test("advance moves to the next window without extending the session")
    func advanceKeepsSessionEnd() {
        let now = Date(timeIntervalSince1970: 990)
        let plan = MonicaAuthenticatorActivityPlan(entry: entry(), now: now)
        let advanced = plan.advanced(to: Date(timeIntervalSince1970: 1035))
        #expect(advanced.windowStart == Date(timeIntervalSince1970: 1020))
        #expect(advanced.windowEnd == Date(timeIntervalSince1970: 1050))
        #expect(advanced.sessionEndsAt == plan.sessionEndsAt)
        #expect(advanced.staleDate == plan.staleDate)
        #expect(plan.isWindowExpired(at: Date(timeIntervalSince1970: 1035)))
        #expect(!advanced.isWindowExpired(at: Date(timeIntervalSince1970: 1035)))
    }

    @Test("advance never moves backwards in time")
    func advanceDoesNotRewind() {
        let plan = MonicaAuthenticatorActivityPlan(entry: entry(), now: Date(timeIntervalSince1970: 990))
        let rewound = plan.advanced(to: Date(timeIntervalSince1970: 900))
        #expect(rewound == plan)
    }

    @Test("advance is a no-op once the session expired")
    func advanceAfterExpiry() {
        let plan = MonicaAuthenticatorActivityPlan(entry: entry(), now: Date(timeIntervalSince1970: 990))
        let late = plan.sessionEndsAt.addingTimeInterval(10)
        #expect(plan.advanced(to: late) == plan)
    }
}

@Suite("Authenticator Live Activity payload hygiene")
struct MonicaAuthenticatorActivityEntryTests {
    @Test("alias collapses whitespace and trims")
    func aliasCollapsed() {
        let entry = MonicaAuthenticatorActivityEntry(id: "1", alias: "  GitHub   Enterprise \n", period: 30)
        #expect(entry.alias == "GitHub Enterprise")
    }

    @Test("empty alias falls back to the localized generic label")
    func aliasFallback() {
        let entry = MonicaAuthenticatorActivityEntry(id: "1", alias: "   ", period: 30)
        #expect(entry.alias == MonicaAuthenticatorActivityLimits.fallbackAlias)
        #expect(!entry.alias.isEmpty)
    }

    @Test("alias is truncated to the maximum length")
    func aliasTruncated() {
        let raw = String(repeating: "长", count: 200)
        let entry = MonicaAuthenticatorActivityEntry(id: "1", alias: raw, period: 30)
        #expect(entry.alias.count == MonicaAuthenticatorActivityLimits.maximumAliasLength)
    }

    @Test("title wins over issuer and account name")
    func aliasSourceOrder() {
        let full = MonicaAuthenticatorActivityEntry(id: "1", title: "Work", issuer: "GitHub", accountName: "me@example.com", period: 30)
        #expect(full.alias == "Work")
        let issuerOnly = MonicaAuthenticatorActivityEntry(id: "1", title: " ", issuer: "GitHub", accountName: "me@example.com", period: 30)
        #expect(issuerOnly.alias == "GitHub")
        let accountOnly = MonicaAuthenticatorActivityEntry(id: "1", title: "", issuer: "", accountName: "me@example.com", period: 30)
        #expect(accountOnly.alias == "me@example.com")
    }

    @Test("period is clamped into 1...600 with a 30 second default")
    func periodClamping() {
        #expect(MonicaAuthenticatorActivityLimits.normalizedPeriod(0) == 30)
        #expect(MonicaAuthenticatorActivityLimits.normalizedPeriod(-5) == 30)
        #expect(MonicaAuthenticatorActivityLimits.normalizedPeriod(1) == 1)
        #expect(MonicaAuthenticatorActivityLimits.normalizedPeriod(30) == 30)
        #expect(MonicaAuthenticatorActivityLimits.normalizedPeriod(10_000) == 600)
        #expect(MonicaAuthenticatorActivityEntry(id: "1", alias: "x", period: 0).period == 30)
    }

    @Test("decoding re-sanitizes instead of trusting the stored payload")
    func decodingSanitizes() throws {
        let json = #"{"id":"x","alias":"   ","period":99999}"#
        let decoded = try JSONDecoder().decode(MonicaAuthenticatorActivityEntry.self, from: Data(json.utf8))
        #expect(decoded.alias == MonicaAuthenticatorActivityLimits.fallbackAlias)
        #expect(decoded.period == MonicaAuthenticatorActivityLimits.maximumPeriod)
    }
}

@Suite("Authenticator Live Activity session state machine")
struct MonicaAuthenticatorActivitySessionTests {
    private var plan: MonicaAuthenticatorActivityPlan {
        MonicaAuthenticatorActivityPlan(
            entry: MonicaAuthenticatorActivityEntry(id: "e", alias: "GitHub", period: 30),
            now: Date(timeIntervalSince1970: 990)
        )
    }

    @Test("unsupported device falls back to inline UI without starting")
    func unsupportedDevice() {
        var session = MonicaAuthenticatorActivitySession()
        let started = session.beginStart(availability: .evaluate(isDeviceSupported: false, areActivitiesEnabled: true))
        #expect(!started)
        #expect(session.state == .failed(.unsupportedDevice))
        #expect(session.shouldPresentInlineFallback)
        #expect(!session.isRunning)
    }

    @Test("disabled live activities fall back to inline UI")
    func disabledActivities() {
        var session = MonicaAuthenticatorActivitySession()
        let started = session.beginStart(availability: .evaluate(isDeviceSupported: true, areActivitiesEnabled: false))
        #expect(!started)
        #expect(session.failure == .disabled)
        #expect(session.shouldPresentInlineFallback)
    }

    @Test("request failure is recoverable and keeps the fallback visible")
    func requestFailure() {
        var session = MonicaAuthenticatorActivitySession()
        let started = session.beginStart(availability: .available)
        #expect(started)
        #expect(session.isStarting)
        session.markFailed(.requestFailed)
        #expect(session.failure == .requestFailed)
        #expect(session.shouldPresentInlineFallback)
        // 失败后可以重试。
        let retried = session.beginStart(availability: .available)
        #expect(retried)
    }

    @Test("available start transitions to running")
    func running() {
        var session = MonicaAuthenticatorActivitySession()
        let started = session.beginStart(availability: .available)
        #expect(started)
        session.markStarted(plan)
        #expect(session.isRunning)
        #expect(session.plan == plan)
        // 不重复发起。
        let restarted = session.beginStart(availability: .available)
        #expect(!restarted)
    }

    @Test("ending the session clears the running plan")
    func ending() {
        var session = MonicaAuthenticatorActivitySession(state: .running(plan))
        session.markEnded()
        #expect(session.state == .idle)
        #expect(!session.isRunning)
    }

    @Test("refresh advances an expired window and leaves the fresh one alone")
    func refresh() {
        var session = MonicaAuthenticatorActivitySession(state: .running(plan))
        let unchanged = session.refresh(at: Date(timeIntervalSince1970: 995))
        #expect(unchanged == nil)
        let advanced = session.refresh(at: Date(timeIntervalSince1970: 1035))
        #expect(advanced?.windowStart == Date(timeIntervalSince1970: 1020))
        #expect(session.plan?.windowStart == Date(timeIntervalSince1970: 1020))
    }

    @Test("refresh past the session end reports expiry so the activity can be ended")
    func refreshExpired() {
        var session = MonicaAuthenticatorActivitySession(state: .running(plan))
        let expired = session.refresh(at: plan.sessionEndsAt.addingTimeInterval(1))
        #expect(expired == nil)
        #expect(session.failure == .expired)
        #expect(!session.isRunning)
    }

    @Test("refresh without a running activity does nothing")
    func refreshIdle() {
        var session = MonicaAuthenticatorActivitySession()
        let unchanged = session.refresh(at: Date())
        #expect(unchanged == nil)
        #expect(session.state == .idle)
    }

    @Test("every failure reason requires the inline fallback")
    func allFailuresFallBack() {
        for failure in MonicaAuthenticatorActivityFailure.allCases {
            #expect(failure.fallsBackToInlineUI)
        }
    }
}
