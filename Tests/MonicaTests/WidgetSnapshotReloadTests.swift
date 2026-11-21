@testable import Monica
import Foundation
import MonicaWidgetShared
import XCTest

/// Covers the App Group contract that the app and the widget extension share: the on-disk
/// v1 payload keeps decoding, new writes keep the same file name and key set, and a corrupt
/// payload degrades to `.locked` instead of surfacing stale vault data.
@MainActor
final class WidgetSnapshotReloadTests: XCTestCase {
    private func makeContainer() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-widget-schema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testLegacyWidgetPayloadStillDecodesIntoTheSharedSchema() throws {
        let directory = try makeContainer()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = AppWidgetSnapshotFileStore(containerURL: directory)
        let legacyPayload = """
        {
          "vaultState": "unlocked",
          "totalEntryCount": 4,
          "totpItems": [
            {
              "id": "entry-1",
              "title": "GitHub TOTP",
              "issuer": "GitHub",
              "accountName": "alice@example.com",
              "secondsRemaining": 13
            }
          ],
          "shortcutItems": [
            {
              "id": "entry-2",
              "kind": "login",
              "title": "GitHub",
              "subtitle": "alice@example.com / github.com",
              "searchableText": "github alice"
            }
          ]
        }
        """
        try Data(legacyPayload.utf8).write(to: store.snapshotFileURL)

        let snapshot = try XCTUnwrap(try store.loadSnapshot())
        XCTAssertEqual(snapshot.schemaVersion, MonicaWidgetConstants.legacySchemaVersion)
        XCTAssertEqual(snapshot.vaultState, .unlocked)
        XCTAssertEqual(snapshot.totalEntryCount, 4)
        XCTAssertEqual(snapshot.totpItems.first?.secondsRemaining, 13)
        XCTAssertEqual(snapshot.totpItems.first?.title, "GitHub TOTP")
        XCTAssertEqual(snapshot.shortcutItems.first?.kind, "login")
        XCTAssertEqual(snapshot.shortcutItems.first?.title, "GitHub")
    }

    func testNewWidgetPayloadKeepsTheV1FileAndKeySetAndCorruptionFallsBackToLocked() throws {
        let directory = try makeContainer()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = AppWidgetSnapshotFileStore(containerURL: directory)
        XCTAssertEqual(store.snapshotFileURL.lastPathComponent, "widget-snapshot-v1.json")

        try store.saveSnapshot(
            AppWidgetSnapshot(
                vaultState: .unlocked,
                totalEntryCount: 2,
                totpItems: [
                    AppWidgetTotpItem(
                        id: "entry-1",
                        title: "GitHub TOTP",
                        issuer: "GitHub",
                        accountName: "alice@example.com",
                        secondsRemaining: 13
                    )
                ],
                shortcutItems: [
                    MonicaWidgetShortcutItem(
                        id: "entry-2",
                        kind: "login",
                        title: "GitHub",
                        subtitle: "alice@example.com / github.com",
                        searchableText: "github alice"
                    )
                ]
            )
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.snapshotFileURL)) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            ["schemaVersion", "vaultState", "totalEntryCount", "totpItems", "shortcutItems", "totpProgressStyle"]
        )
        XCTAssertEqual(object["totpProgressStyle"] as? String, "linear")
        XCTAssertEqual(object["schemaVersion"] as? Int, MonicaWidgetConstants.currentSchemaVersion)
        XCTAssertEqual(object["vaultState"] as? String, "unlocked")

        try Data("not-a-v1-snapshot".utf8).write(to: store.snapshotFileURL)
        XCTAssertEqual(store.loadSnapshotOrFallback(), .locked)

        let shortcutStore = AppShortcutSnapshotFileStore(containerURL: directory)
        XCTAssertEqual(shortcutStore.snapshotFileURL.lastPathComponent, "shortcuts-snapshot-v1.json")
        try Data("not-a-v1-snapshot".utf8).write(to: shortcutStore.snapshotFileURL)
        XCTAssertEqual(shortcutStore.loadSnapshotOrFallback(), .locked)
    }
}
