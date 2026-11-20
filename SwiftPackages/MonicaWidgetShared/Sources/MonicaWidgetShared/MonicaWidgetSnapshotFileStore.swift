import Foundation

/// Reads and writes the widget snapshot in the App Group container.
///
/// The store only knows the container URL; the app and the widget extension resolve that
/// URL through `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` exactly
/// as they did before, so App Group access and entitlements are unchanged.
public struct MonicaWidgetSnapshotFileStore: Sendable {
    public let snapshotFileURL: URL

    public init(containerURL: URL) {
        self.snapshotFileURL = containerURL.appendingPathComponent(
            MonicaWidgetConstants.widgetSnapshotFileName,
            isDirectory: false
        )
    }

    public func saveSnapshot(_ snapshot: MonicaWidgetSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try Self.write(try encoder.encode(snapshot), to: snapshotFileURL)
    }

    /// Returns `nil` only when the snapshot has never been written. Decoding and file
    /// errors are thrown so callers can distinguish "no snapshot yet" from corruption.
    public func loadSnapshot() throws -> MonicaWidgetSnapshot? {
        guard FileManager.default.fileExists(atPath: snapshotFileURL.path) else {
            return nil
        }
        return try JSONDecoder().decode(MonicaWidgetSnapshot.self, from: Data(contentsOf: snapshotFileURL))
    }

    /// The extension-facing read path: any missing/corrupt/newer payload degrades to a
    /// locked snapshot instead of showing stale content.
    public func loadSnapshotOrFallback() -> MonicaWidgetSnapshot {
        guard
            let snapshot = try? loadSnapshot(),
            snapshot.schemaVersion <= MonicaWidgetConstants.currentSchemaVersion
        else {
            return .locked
        }
        return snapshot
    }

    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: writingOptions)
    }

    static var writingOptions: Data.WritingOptions {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        [.atomic, .completeFileProtection]
        #else
        // File protection is an iOS-family concept; macOS only needs the atomic replace
        // so package tests can run headlessly on the host.
        [.atomic]
        #endif
    }
}

public struct MonicaShortcutSnapshotFileStore: Sendable {
    public let snapshotFileURL: URL

    public init(containerURL: URL) {
        self.snapshotFileURL = containerURL.appendingPathComponent(
            MonicaWidgetConstants.shortcutsSnapshotFileName,
            isDirectory: false
        )
    }

    public func saveSnapshot(_ snapshot: MonicaShortcutSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try MonicaWidgetSnapshotFileStore.write(try encoder.encode(snapshot), to: snapshotFileURL)
    }

    public func loadSnapshot() throws -> MonicaShortcutSnapshot? {
        guard FileManager.default.fileExists(atPath: snapshotFileURL.path) else {
            return nil
        }
        return try JSONDecoder().decode(MonicaShortcutSnapshot.self, from: Data(contentsOf: snapshotFileURL))
    }

    public func loadSnapshotOrFallback() -> MonicaShortcutSnapshot {
        guard
            let snapshot = try? loadSnapshot(),
            snapshot.schemaVersion <= MonicaWidgetConstants.currentSchemaVersion
        else {
            return .locked
        }
        return snapshot
    }
}
