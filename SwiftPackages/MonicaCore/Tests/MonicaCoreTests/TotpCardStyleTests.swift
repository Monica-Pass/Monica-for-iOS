import Foundation
import Testing
import MonicaCore

@Suite("验证码进度条样式")
struct TotpCardStyleTests {
    // MARK: - 样式枚举

    @Test func styleRawValuesAreStable() {
        // raw value 会写进 Widget 快照，改动等于破坏向后兼容。
        #expect(TotpProgressStyle.linear.rawValue == "linear")
        #expect(TotpProgressStyle.circular.rawValue == "circular")
        #expect(TotpProgressStyle.allCases == [.linear, .circular])
    }

    @Test func snapshotValueRoundTripsForEveryStyle() {
        for style in TotpProgressStyle.allCases {
            #expect(TotpProgressStyle(snapshotValue: style.snapshotValue) == style)
            #expect(style.snapshotValue == style.rawValue)
        }
    }

    @Test func missingOrUnknownSnapshotValueFallsBackToLinear() {
        // 旧快照没有这个字段：必须还是旧的线性外观。
        #expect(TotpProgressStyle(snapshotValue: nil) == .linear)
        #expect(TotpProgressStyle(snapshotValue: "") == .linear)
        #expect(TotpProgressStyle(snapshotValue: "wave") == .linear)
        #expect(TotpProgressStyle(snapshotValue: "CIRCULAR") == .linear)
    }

    // MARK: - 默认值

    @Test func defaultsMatchLegacyAppearance() {
        let defaults = TotpProgressPreferences.default
        // 统一进度条默认关闭、线性、平滑动画开启：升级后外观与旧版本一致。
        #expect(defaults.usesUnifiedProgressBar == false)
        #expect(defaults.style == .linear)
        #expect(defaults.usesSmoothAnimation == true)
    }

    // MARK: - 减弱动态效果覆盖

    @Test func reduceMotionForcesSmoothAnimationOff() {
        let preferences = TotpProgressPreferences(usesUnifiedProgressBar: false, style: .linear, usesSmoothAnimation: true)
        let reduced = TotpCardStylePolicy(preferences: preferences, reduceMotion: true)

        #expect(reduced.isSmoothAnimationEnabled == false)
        // 样式本身不受减弱动态效果影响。
        #expect(reduced.style == .linear)
    }

    @Test func smoothAnimationFollowsPreferenceWhenMotionAllowed() {
        let smooth = TotpCardStylePolicy(
            preferences: TotpProgressPreferences(style: .circular, usesSmoothAnimation: true),
            reduceMotion: false
        )
        let stepped = TotpCardStylePolicy(
            preferences: TotpProgressPreferences(style: .circular, usesSmoothAnimation: false),
            reduceMotion: false
        )

        #expect(smooth.isSmoothAnimationEnabled == true)
        #expect(stepped.isSmoothAnimationEnabled == false)
        #expect(smooth.style == .circular)
    }

    // MARK: - 周期与比例

    @Test func unifiedProgressBarOnlyTakesOverStandardPeriod() {
        let unified = TotpCardStylePolicy(
            preferences: TotpProgressPreferences(usesUnifiedProgressBar: true),
            reduceMotion: false
        )
        #expect(unified.period(forEntryPeriod: 30) == 30)
        // 60 秒 / 自定义周期保持自身周期，否则进度条会在验证码没刷新时归零。
        #expect(unified.period(forEntryPeriod: 60) == 60)
        #expect(unified.period(forEntryPeriod: 15) == 15)
        // 异常周期（0 / 负数）按 1 秒兜底，避免除零。
        #expect(unified.period(forEntryPeriod: 0) == 1)

        let legacy = TotpCardStylePolicy(preferences: .default, reduceMotion: false)
        #expect(legacy.usesUnifiedProgressBar == false)
        #expect(legacy.period(forEntryPeriod: 60) == 60)
    }

    @Test func unifiedProgressBarTakesOverStandardCardBars() {
        let unified = TotpCardStylePolicy(
            preferences: TotpProgressPreferences(usesUnifiedProgressBar: true),
            reduceMotion: false
        )
        // 标准 30 秒周期由列表顶部那条统一进度条接管，卡片不再重复画。
        #expect(unified.showsCardProgress(isCounterBased: false, entryPeriod: 30) == false)
        // 60 秒 / 自定义周期保留自己的进度条，否则就完全没有倒计时了。
        #expect(unified.showsCardProgress(isCounterBased: false, entryPeriod: 60))
        #expect(unified.showsCardProgress(isCounterBased: false, entryPeriod: 15))
        // 计数器没有周期，始终不显示。
        #expect(unified.showsCardProgress(isCounterBased: true, entryPeriod: 30) == false)

        let legacy = TotpCardStylePolicy(preferences: .default, reduceMotion: false)
        #expect(legacy.showsCardProgress(isCounterBased: false, entryPeriod: 30))
        #expect(legacy.showsCardProgress(isCounterBased: true, entryPeriod: 30) == false)
    }

    @Test func unifiedRemainingSharesTheCardClock() {
        let policy = TotpCardStylePolicy(
            preferences: TotpProgressPreferences(usesUnifiedProgressBar: true),
            reduceMotion: false
        )
        // 与 `totpTimeRemaining` 同一公式：整除时返回整周期，方便识别「刚刷新」。
        #expect(policy.unifiedRemaining(at: Date(timeIntervalSince1970: 0)) == 30)
        #expect(policy.unifiedRemaining(at: Date(timeIntervalSince1970: 1)) == 29)
        #expect(policy.unifiedRemaining(at: Date(timeIntervalSince1970: 29)) == 1)
        #expect(policy.unifiedRemaining(at: Date(timeIntervalSince1970: 30)) == 30)
    }

    @Test func progressClampsToUnitRange() {
        let policy = TotpCardStylePolicy(preferences: .default, reduceMotion: false)

        #expect(policy.progress(remaining: 30, period: 30) == 1)
        #expect(policy.progress(remaining: 15, period: 30) == 0.5)
        #expect(policy.progress(remaining: 0, period: 30) == 0)
        // 越界与除零保护。
        #expect(policy.progress(remaining: 42, period: 30) == 1)
        #expect(policy.progress(remaining: -3, period: 30) == 0)
        #expect(policy.progress(remaining: 1, period: 0) == 1)
    }

    @Test func cycleStartIsTheWrapFrame() {
        let policy = TotpCardStylePolicy(preferences: .default, reduceMotion: false)

        // 刷新瞬间 remaining 等于整周期：这一帧关动画，否则会看到进度条从 0 补到满。
        #expect(policy.isCycleStart(remaining: 30, period: 30))
        #expect(policy.isCycleStart(remaining: 29, period: 30) == false)
        #expect(policy.isCycleStart(remaining: 1, period: 30) == false)
    }

    // MARK: - 存储往返

    @Test func memoryStoreRoundTrips() {
        let store = MemoryTotpProgressPreferenceStore()
        #expect(store.loadPreferences() == .default)

        let updated = TotpProgressPreferences(usesUnifiedProgressBar: true, style: .circular, usesSmoothAnimation: false)
        store.savePreferences(updated)
        #expect(store.loadPreferences() == updated)
    }

    @Test func userDefaultsStoreRoundTripsPerKey() throws {
        let suiteName = "TotpCardStyleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsTotpProgressPreferenceStore(defaults: defaults)

        // 全新安装：读设备用默认值，外观与旧版本一致。
        #expect(store.loadPreferences() == .default)

        let updated = TotpProgressPreferences(usesUnifiedProgressBar: true, style: .circular, usesSmoothAnimation: false)
        store.savePreferences(updated)
        #expect(store.loadPreferences() == updated)

        // 逐键写入：三个键是独立存储，取值可直接断言。
        #expect(defaults.string(forKey: TotpProgressPreferenceKey.style) == "circular")
        #expect(defaults.bool(forKey: TotpProgressPreferenceKey.unifiedProgressBar))
        #expect(defaults.bool(forKey: TotpProgressPreferenceKey.smoothAnimation) == false)
    }

    @Test func userDefaultsStoreIgnoresCorruptedKeys() throws {
        let suiteName = "TotpCardStyleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("wave", forKey: TotpProgressPreferenceKey.style)
        defaults.set(true, forKey: TotpProgressPreferenceKey.unifiedProgressBar)

        let loaded = UserDefaultsTotpProgressPreferenceStore(defaults: defaults).loadPreferences()
        // 未知样式回落线性，其它键仍然生效，不整组重置。
        #expect(loaded.style == .linear)
        #expect(loaded.usesUnifiedProgressBar)
        #expect(loaded.usesSmoothAnimation)
    }

    // MARK: - Codable 兼容

    @Test func decodingEmptyPayloadUsesDefaults() throws {
        let decoded = try JSONDecoder().decode(TotpProgressPreferences.self, from: Data("{}".utf8))
        #expect(decoded == .default)
    }

    @Test func decodingUnknownStyleFallsBackToLinear() throws {
        let json = #"{"usesUnifiedProgressBar":true,"style":"wave","usesSmoothAnimation":false}"#
        let decoded = try JSONDecoder().decode(TotpProgressPreferences.self, from: Data(json.utf8))

        #expect(decoded.style == .linear)
        #expect(decoded.usesUnifiedProgressBar)
        #expect(decoded.usesSmoothAnimation == false)
    }

    @Test func codableRoundTrips() throws {
        let preferences = TotpProgressPreferences(usesUnifiedProgressBar: true, style: .circular, usesSmoothAnimation: false)
        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(TotpProgressPreferences.self, from: data)
        #expect(decoded == preferences)
    }
}
