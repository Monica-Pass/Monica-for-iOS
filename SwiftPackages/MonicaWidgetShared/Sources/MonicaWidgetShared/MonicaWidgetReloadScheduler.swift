import Foundation

/// Anything that can ask WidgetKit to refresh the Monica widget. The app depends on this
/// small protocol so tests can observe reload requests without touching WidgetKit.
@MainActor
public protocol MonicaWidgetReloadScheduling: AnyObject {
    /// Requests one reload, coalescing repeated calls made within the coalescing window.
    func requestReload()
    /// Drops any pending coalesced request and reloads now. Used for lock / vault switch,
    /// where the widget must lose access to the (now empty) vault projection immediately.
    func requestImmediateReload()
    /// Fires a pending coalesced request now (scene going to background) instead of
    /// letting it wait for a timeline that may not run while the app is suspended.
    func flushPendingReload()
}

/// Coalesces `WidgetCenter.shared.reloadTimelines(ofKind:)` requests.
///
/// `reloadTimelines` is only a *request* to WidgetKit: Apple does not guarantee that a
/// reload happens at a specific time, and WidgetKit budgets how often widgets are
/// refreshed. Calling it once per mutated entry (bulk import, sync, batch delete) is
/// therefore both wasteful and likely to be rate limited, so the first mutation in a
/// burst schedules one reload and every further mutation inside the window is absorbed.
@MainActor
public final class MonicaWidgetReloadScheduler: MonicaWidgetReloadScheduling {
    /// Short enough that a user who adds an entry sees the widget update on the next
    /// home-screen pass, long enough to absorb the synchronous burst of mutation events
    /// produced by a single user action or an import loop.
    public static let defaultCoalescingInterval: Duration = .milliseconds(750)

    private let coalescingInterval: Duration
    private let reload: @MainActor @Sendable () -> Void
    private var pendingTask: Task<Void, Never>?

    public init(
        coalescingInterval: Duration = MonicaWidgetReloadScheduler.defaultCoalescingInterval,
        reload: @escaping @MainActor @Sendable () -> Void
    ) {
        self.coalescingInterval = coalescingInterval
        self.reload = reload
    }

    public var isReloadPending: Bool {
        pendingTask != nil
    }

    public func requestReload() {
        guard pendingTask == nil else {
            return
        }
        let interval = coalescingInterval
        pendingTask = Task { [weak self] in
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else {
                return
            }
            self.pendingTask = nil
            self.reload()
        }
    }

    public func requestImmediateReload() {
        pendingTask?.cancel()
        pendingTask = nil
        reload()
    }

    public func flushPendingReload() {
        guard let pendingTask else {
            return
        }
        pendingTask.cancel()
        self.pendingTask = nil
        reload()
    }

    /// Test/support hook: suspends until the pending coalesced reload has fired (or until
    /// a cancelled request has unwound).
    public func waitForPendingReload() async {
        guard let pendingTask else {
            return
        }
        await pendingTask.value
    }
}
