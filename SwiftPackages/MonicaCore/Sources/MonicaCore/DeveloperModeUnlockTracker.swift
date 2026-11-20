import Foundation

/// Counts rapid taps on the version row and reveals the developer section on
/// the seventh. Pure value type so the gesture rule is unit-tested instead of
/// being buried in a SwiftUI view.
public struct DeveloperModeUnlockTracker: Sendable, Equatable {
    public static let requiredTapCount = 7
    /// A pause longer than this restarts the count, so unrelated taps over a
    /// long session never accidentally unlock the section.
    public static let maximumTapInterval: TimeInterval = 2

    public private(set) var tapCount: Int
    public private(set) var lastTapAt: Date?

    public init() {
        tapCount = 0
        lastTapAt = nil
    }

    /// Returns `true` on the tap that completes the sequence.
    @discardableResult
    public mutating func registerTap(at date: Date = Date()) -> Bool {
        if let lastTapAt, date.timeIntervalSince(lastTapAt) > Self.maximumTapInterval {
            tapCount = 0
        }
        tapCount += 1
        self.lastTapAt = date
        guard tapCount >= Self.requiredTapCount else {
            return false
        }
        reset()
        return true
    }

    public mutating func reset() {
        tapCount = 0
        lastTapAt = nil
    }

    /// How many taps remain before the developer section unlocks.
    public var remainingTapCount: Int {
        max(0, Self.requiredTapCount - tapCount)
    }
}
