import Foundation
import Testing
@testable import MonicaWidgetShared

@MainActor
private final class ReloadCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

@MainActor
@Suite("Widget reload coalescing")
struct MonicaWidgetReloadSchedulerTests {
    private func makeScheduler(
        coalescing: Duration = .milliseconds(30)
    ) -> (MonicaWidgetReloadScheduler, ReloadCounter) {
        let counter = ReloadCounter()
        let scheduler = MonicaWidgetReloadScheduler(coalescingInterval: coalescing) {
            counter.increment()
        }
        return (scheduler, counter)
    }

    @Test func burstOfRequestsReloadsOnce() async throws {
        let (scheduler, counter) = makeScheduler()

        scheduler.requestReload()
        scheduler.requestReload()
        scheduler.requestReload()

        #expect(scheduler.isReloadPending)
        await scheduler.waitForPendingReload()

        #expect(counter.count == 1)
        #expect(!scheduler.isReloadPending)
    }

    @Test func requestAfterReloadSchedulesAnotherReload() async throws {
        let (scheduler, counter) = makeScheduler()

        scheduler.requestReload()
        await scheduler.waitForPendingReload()
        #expect(counter.count == 1)

        scheduler.requestReload()
        #expect(scheduler.isReloadPending)
        await scheduler.waitForPendingReload()
        #expect(counter.count == 2)
    }

    @Test func immediateReloadCancelsPendingCoalescedReload() async throws {
        let (scheduler, counter) = makeScheduler(coalescing: .milliseconds(80))

        scheduler.requestReload()
        scheduler.requestImmediateReload()
        #expect(counter.count == 1)
        #expect(!scheduler.isReloadPending)

        try await Task.sleep(for: .milliseconds(160))
        #expect(counter.count == 1)
    }

    @Test func flushFiresPendingReloadImmediately() async throws {
        let (scheduler, counter) = makeScheduler(coalescing: .seconds(10))

        scheduler.requestReload()
        scheduler.flushPendingReload()

        #expect(counter.count == 1)
        #expect(!scheduler.isReloadPending)
    }

    @Test func flushWithoutPendingReloadDoesNothing() {
        let (scheduler, counter) = makeScheduler()

        scheduler.flushPendingReload()
        #expect(counter.count == 0)
    }

    @Test func waitWithoutPendingReloadReturnsImmediately() async {
        let (scheduler, counter) = makeScheduler()

        await scheduler.waitForPendingReload()
        #expect(counter.count == 0)
    }
}
