import Foundation
import Testing
@testable import MonicaCore

/// 与 `UIPasteboard` 语义一致的假剪贴板：每次写入 `changeCount` 自增，
/// 并记录内容被读取的次数，用来断言策略“从不读取剪贴板内容”。
@MainActor
final class FakeSensitivePasteboard: SensitivePasteboardWriting {
    private(set) var changeCount = 0
    private(set) var contentReadCount = 0
    private(set) var clearCount = 0
    private(set) var writeCount = 0

    private var storedString: String?

    var string: String? {
        contentReadCount += 1
        return storedString
    }

    func setString(_ value: String) {
        storedString = value
        changeCount += 1
        writeCount += 1
    }

    func clear() {
        storedString = nil
        changeCount += 1
        clearCount += 1
    }

    /// 模拟其它 App 写入剪贴板：内容与 changeCount 都变化，但不经过本 App 的适配器。
    func simulateForeignCopy(_ value: String) {
        storedString = value
        changeCount += 1
    }

    func seedChangeCount(_ value: Int) {
        changeCount = value
    }

    var hasContent: Bool {
        storedString != nil
    }
}

@MainActor
final class MutableSensitiveClock {
    var now: Date

    init(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.now = now
    }

    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

@MainActor
@Suite("敏感剪贴板清理策略")
struct SensitivePasteboardTests {
    private let secret = "correct horse battery staple"

    private func makeSubject(
        ttl: SensitiveClipboardTTL = .seconds30,
        clock: MutableSensitiveClock
    ) -> (MonicaSensitivePasteboard, FakeSensitivePasteboard) {
        let pasteboard = FakeSensitivePasteboard()
        let subject = MonicaSensitivePasteboard(
            pasteboard: pasteboard,
            now: { clock.now },
            digestKeyBytes: Array(repeating: 0x42, count: 32)
        )
        return (subject, pasteboard)
    }

    @Test func copyRecordsChangeCountAfterWrite() {
        let clock = MutableSensitiveClock()
        let pasteboard = FakeSensitivePasteboard()
        pasteboard.seedChangeCount(41)
        let subject = MonicaSensitivePasteboard(
            pasteboard: pasteboard,
            now: { clock.now },
            digestKeyBytes: Array(repeating: 0x42, count: 32)
        )

        let outcome = subject.copy(secret: secret, ttl: .seconds30)

        #expect(pasteboard.writeCount == 1)
        #expect(pasteboard.contentReadCount == 0) // 写入路径不读取剪贴板内容
        #expect(outcome == .copiedWithAutoClear(expiresAt: clock.now.addingTimeInterval(30)))
        #expect(subject.activeRecord?.changeCount == 42)
        #expect(subject.activeRecord?.expiresAt == clock.now.addingTimeInterval(30))
        #expect(subject.hasPendingAutoClear)
        #expect(pasteboard.string == secret)
    }

    @Test func expiryClearsWhenChangeCountIsUnchanged() {
        let clock = MutableSensitiveClock()
        let (subject, pasteboard) = makeSubject(ttl: .seconds15, clock: clock)
        subject.copy(secret: secret, ttl: .seconds15)

        #expect(subject.clearIfExpired() == .notYetDue(expiresAt: clock.now.addingTimeInterval(15)))
        #expect(pasteboard.clearCount == 0)

        clock.advance(by: 15)
        #expect(subject.clearIfExpired() == .cleared)
        #expect(pasteboard.clearCount == 1)
        #expect(!pasteboard.hasContent)
        #expect(!subject.hasPendingAutoClear)
    }

    @Test func expiryDoesNotClearWhenAnotherAppReplacedTheValue() {
        let clock = MutableSensitiveClock()
        let (subject, pasteboard) = makeSubject(ttl: .seconds15, clock: clock)
        subject.copy(secret: secret, ttl: .seconds15)

        pasteboard.simulateForeignCopy("notes from another app")
        clock.advance(by: 60)

        #expect(subject.clearIfExpired() == .skippedBecauseReplacedByAnotherApp)
        #expect(pasteboard.clearCount == 0)
        #expect(pasteboard.string == "notes from another app")
        #expect(!subject.hasPendingAutoClear)
    }

    @Test func expiryNeverReadsPasteboardContents() {
        let clock = MutableSensitiveClock()
        let (subject, pasteboard) = makeSubject(ttl: .seconds15, clock: clock)
        subject.copy(secret: secret, ttl: .seconds15)

        clock.advance(by: 1)
        _ = subject.clearIfExpired()
        clock.advance(by: 30)
        _ = subject.clearIfExpired()
        _ = subject.clearImmediatelyIfOwned()
        _ = subject.remainingSeconds()

        #expect(pasteboard.contentReadCount == 0)
    }

    @Test func clearImmediatelyOnlyTouchesOwnValue() {
        let clock = MutableSensitiveClock()
        let (subject, pasteboard) = makeSubject(clock: clock)

        #expect(subject.clearImmediatelyIfOwned() == .noPendingValue)
        subject.copy(secret: secret, ttl: .seconds60)

        #expect(subject.clearImmediatelyIfOwned() == .cleared)
        #expect(pasteboard.clearCount == 1)
        #expect(!pasteboard.hasContent)
        #expect(subject.clearIfExpired() == .noPendingValue)
    }

    @Test func offDisablesAutoClearButStillClearsPreviousRecord() {
        let clock = MutableSensitiveClock()
        let (subject, pasteboard) = makeSubject(ttl: .seconds30, clock: clock)
        subject.copy(secret: secret, ttl: .seconds30)
        #expect(subject.hasPendingAutoClear)

        #expect(subject.copy(secret: "second secret", ttl: .off) == .copiedWithoutAutoClear)
        #expect(!subject.hasPendingAutoClear)
        #expect(pasteboard.string == "second secret")

        clock.advance(by: 600)
        #expect(subject.clearIfExpired() == .noPendingValue)
        #expect(pasteboard.clearCount == 0)
    }

    @Test func recordCarriesNoPlaintext() {
        let clock = MutableSensitiveClock()
        let (subject, pasteboard) = makeSubject(clock: clock)

        subject.copy(secret: secret, ttl: .seconds30)
        let record = try? #require(subject.activeRecord)

        #expect(record?.valueDigest != secret)
        #expect(record?.valueDigest.count == 64)
        #expect(record.map { String(describing: $0) }?.contains(secret) == false)
        #expect(record?.valueDigest.allSatisfy(\.isHexDigit) == true)

        // 相同值得到相同摘要，不同值得到不同摘要；摘要不随着 HTML/URL 编码漂移。
        subject.copy(secret: secret, ttl: .seconds30)
        #expect(subject.activeRecord?.valueDigest == record?.valueDigest)
        subject.copy(secret: "another \(secret)", ttl: .seconds30)
        #expect(subject.activeRecord?.valueDigest != record?.valueDigest)
    }

    @Test func emptySecretIsNotWritten() {
        let clock = MutableSensitiveClock()
        let (subject, pasteboard) = makeSubject(clock: clock)

        #expect(subject.copy(secret: "", ttl: .seconds30) == .nothingToCopy)
        #expect(pasteboard.writeCount == 0)
        #expect(pasteboard.changeCount == 0)
        #expect(!subject.hasPendingAutoClear)
    }

    @Test func remainingSecondsCountsDown() {
        let clock = MutableSensitiveClock()
        let (subject, _) = makeSubject(ttl: .seconds60, clock: clock)
        subject.copy(secret: secret, ttl: .seconds60)

        #expect(subject.remainingSeconds() == 60)
        clock.advance(by: 19.5)
        #expect(subject.remainingSeconds() == 41)
        clock.advance(by: 60)
        #expect(subject.remainingSeconds() == 0)
    }

    @Test func discardingPendingRecordLeavesPasteboardUntouched() {
        let clock = MutableSensitiveClock()
        let (subject, pasteboard) = makeSubject(clock: clock)
        subject.copy(secret: secret, ttl: .seconds60)

        subject.discardPendingRecord()
        clock.advance(by: 120)

        #expect(subject.clearIfExpired() == .noPendingValue)
        #expect(pasteboard.clearCount == 0)
        #expect(pasteboard.string == secret)
    }

    @Test func ttlOptionsMatchIssueAcceptance() {
        #expect(SensitiveClipboardTTL.allCases.map(\.rawValue) == [0, 15, 30, 60])
        #expect(SensitiveClipboardTTL.default == .seconds30)
        #expect(SensitiveClipboardTTL.off.seconds == nil)
        #expect(SensitiveClipboardTTL.seconds60.seconds == 60)
        #expect(SensitiveClipboardTTL.off.isEnabled == false)
        #expect(SensitiveClipboardTTL.seconds15.isEnabled)
    }

    @Test func clipboardPreferencePersistsOnlyTTL() {
        let suiteName = "SensitivePasteboardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsSensitiveClipboardPreferenceStore(userDefaults: defaults)
        #expect(store.loadTTL() == .seconds30)

        store.saveTTL(.seconds15)
        #expect(UserDefaultsSensitiveClipboardPreferenceStore(userDefaults: defaults).loadTTL() == .seconds15)

        store.saveTTL(.off)
        #expect(store.loadTTL() == .off)

        defaults.set(999, forKey: UserDefaultsSensitiveClipboardPreferenceStore.userDefaultsKey)
        #expect(store.loadTTL() == .seconds30)

        let persisted = defaults.dictionaryRepresentation().values
            .compactMap { $0 as? String }
            .joined(separator: " ")
        #expect(!persisted.contains(secret))
    }

    @Test func memoryStoreKeepsTTLInMemory() {
        let store = MemorySensitiveClipboardPreferenceStore()
        #expect(store.loadTTL() == .seconds30)
        store.saveTTL(.seconds60)
        #expect(store.loadTTL() == .seconds60)
    }

    @Test func unavailablePasteboardStoresNothing() {
        let clock = MutableSensitiveClock()
        let subject = MonicaSensitivePasteboard(
            pasteboard: UnavailableSensitivePasteboard(),
            now: { clock.now }
        )

        #expect(subject.copy(secret: secret, ttl: .seconds30) == .copiedWithAutoClear(expiresAt: clock.now.addingTimeInterval(30)))
        clock.advance(by: 31)
        #expect(subject.clearIfExpired() == .cleared)
        #expect(UnavailableSensitivePasteboard().string == nil)
    }
}
