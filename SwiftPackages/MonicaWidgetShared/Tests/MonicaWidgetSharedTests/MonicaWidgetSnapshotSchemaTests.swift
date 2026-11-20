import Foundation
import Testing
@testable import MonicaWidgetShared

@Suite("Widget snapshot schema")
struct MonicaWidgetSnapshotSchemaTests {
    // Payload written by the shipped app before the schema became shared/versioned. It has
    // no `schemaVersion` key and must keep decoding.
    private let legacyWidgetSnapshotJSON = """
    {
      "vaultState" : "unlocked",
      "totalEntryCount" : 2,
      "totpItems" : [
        {
          "id" : "totp-1",
          "title" : "GitHub TOTP",
          "issuer" : "GitHub",
          "accountName" : "alice@example.com",
          "secondsRemaining" : 13
        }
      ],
      "shortcutItems" : [
        {
          "id" : "entry-1",
          "kind" : "login",
          "title" : "GitHub",
          "subtitle" : "alice@example.com / github.com",
          "searchableText" : "github alice"
        }
      ]
    }
    """

    private let legacyShortcutSnapshotJSON = """
    {
      "vaultState" : "unlocked",
      "entries" : [
        {
          "id" : "entry-1",
          "kind" : "login",
          "title" : "GitHub",
          "subtitle" : "alice@example.com / github.com",
          "searchableText" : "github alice",
          "openURL" : "monica://shortcut/login/entry-1"
        }
      ]
    }
    """

    @Test func widgetSnapshotRoundTripsThroughJSON() throws {
        let snapshot = MonicaWidgetSnapshot(
            vaultState: .unlocked,
            totalEntryCount: 3,
            totpItems: [
                MonicaWidgetTotpItem(
                    id: "totp-1",
                    title: "GitHub TOTP",
                    issuer: "GitHub",
                    accountName: "alice@example.com",
                    secondsRemaining: 17
                )
            ],
            shortcutItems: [
                MonicaWidgetShortcutItem(
                    id: "login-1",
                    kind: "login",
                    title: "GitHub",
                    subtitle: "alice@example.com",
                    searchableText: "github"
                )
            ]
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(MonicaWidgetSnapshot.self, from: data)

        #expect(decoded == snapshot)
        #expect(decoded.schemaVersion == MonicaWidgetConstants.currentSchemaVersion)
    }

    @Test func shortcutSnapshotRoundTripsThroughJSON() throws {
        let snapshot = MonicaShortcutSnapshot(
            vaultState: .unlocked,
            entries: [
                MonicaShortcutSnapshotEntry(
                    id: "login-1",
                    kind: "login",
                    title: "GitHub",
                    subtitle: "alice@example.com",
                    searchableText: "github",
                    openURL: try #require(URL(string: "monica://shortcut/login/login-1"))
                )
            ]
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(MonicaShortcutSnapshot.self, from: data)

        #expect(decoded == snapshot)
    }

    @Test func legacyWidgetSnapshotWithoutSchemaVersionStillDecodes() throws {
        let data = try #require(legacyWidgetSnapshotJSON.data(using: .utf8))
        let snapshot = try JSONDecoder().decode(MonicaWidgetSnapshot.self, from: data)

        #expect(snapshot.schemaVersion == MonicaWidgetConstants.legacySchemaVersion)
        #expect(snapshot.vaultState == .unlocked)
        #expect(snapshot.totalEntryCount == 2)
        #expect(snapshot.totpItems.map(\.id) == ["totp-1"])
        #expect(snapshot.totpItems.first?.secondsRemaining == 13)
        #expect(snapshot.shortcutItems.map(\.kind) == ["login"])
    }

    @Test func legacyShortcutSnapshotWithoutSchemaVersionStillDecodes() throws {
        let data = try #require(legacyShortcutSnapshotJSON.data(using: .utf8))
        let snapshot = try JSONDecoder().decode(MonicaShortcutSnapshot.self, from: data)

        #expect(snapshot.schemaVersion == MonicaWidgetConstants.legacySchemaVersion)
        #expect(snapshot.vaultState == .unlocked)
        #expect(snapshot.entries.count == 1)
        #expect(snapshot.entries.first?.openURL.absoluteString == "monica://shortcut/login/entry-1")
    }

    @Test func lockedSnapshotDropsSensitiveProjection() throws {
        let payload = """
        {
          "schemaVersion" : 1,
          "vaultState" : "locked",
          "totalEntryCount" : 12,
          "totpItems" : [
            { "id" : "totp-1", "title" : "GitHub", "issuer" : "GitHub", "accountName" : "alice", "secondsRemaining" : 9 }
          ],
          "shortcutItems" : [
            { "id" : "login-1", "kind" : "login", "title" : "GitHub", "subtitle" : "", "searchableText" : "" }
          ]
        }
        """
        let snapshot = try JSONDecoder().decode(MonicaWidgetSnapshot.self, from: #require(payload.data(using: .utf8)))

        #expect(snapshot.vaultState == .locked)
        #expect(snapshot.totalEntryCount == 0)
        #expect(snapshot.totpItems.isEmpty)
        #expect(snapshot.shortcutItems.isEmpty)
        #expect(snapshot == .locked)
    }

    @Test func unknownVaultStateDecodesAsLocked() throws {
        let payload = """
        { "schemaVersion" : 1, "vaultState" : "sealed", "totalEntryCount" : 4 }
        """
        let snapshot = try JSONDecoder().decode(
            MonicaWidgetSnapshot.self,
            from: #require(payload.data(using: .utf8))
        )

        #expect(snapshot.vaultState == .locked)
        #expect(snapshot.totalEntryCount == 0)
    }

    @Test func missingVaultStateDecodesAsLocked() throws {
        let payload = """
        { "totalEntryCount" : 4 }
        """
        let snapshot = try JSONDecoder().decode(
            MonicaWidgetSnapshot.self,
            from: #require(payload.data(using: .utf8))
        )

        #expect(snapshot.vaultState == .locked)
        #expect(snapshot.schemaVersion == MonicaWidgetConstants.legacySchemaVersion)
    }

    @Test func shortcutEntryDerivesOpenURLWhenMissing() throws {
        let payload = """
        {
          "vaultState" : "unlocked",
          "entries" : [
            { "id" : "note-7", "kind" : "note", "title" : "Recovery", "subtitle" : "", "searchableText" : "" }
          ]
        }
        """
        let snapshot = try JSONDecoder().decode(
            MonicaShortcutSnapshot.self,
            from: #require(payload.data(using: .utf8))
        )

        #expect(snapshot.entries.first?.openURL.absoluteString == "monica://shortcut/note/note-7")
    }

    @Test func storeFallsBackToLockedForMissingCorruptAndFutureSnapshots() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-widget-shared-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = MonicaWidgetSnapshotFileStore(containerURL: directory)

        // Missing file: nil for the diagnostic read, locked for the extension read.
        let missingSnapshot = try store.loadSnapshot()
        #expect(missingSnapshot == nil)
        #expect(store.loadSnapshotOrFallback() == .locked)

        // Corrupt payload.
        try Data("{ not json".utf8).write(to: store.snapshotFileURL)
        #expect(store.loadSnapshotOrFallback() == .locked)

        // Structurally valid but of an unsupported future version.
        try Data(#"{ "schemaVersion" : 99, "vaultState" : "unlocked", "totalEntryCount" : 5 }"#.utf8)
            .write(to: store.snapshotFileURL)
        #expect(store.loadSnapshotOrFallback() == .locked)

        // A valid v1 (legacy, no version key) snapshot round-trips through the store.
        try Data(legacyWidgetSnapshotJSON.utf8).write(to: store.snapshotFileURL)
        let snapshot = store.loadSnapshotOrFallback()
        #expect(snapshot.vaultState == .unlocked)
        #expect(snapshot.totalEntryCount == 2)
    }

    @Test func shortcutStoreFallsBackToLockedForMissingAndCorruptSnapshots() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-shortcut-shared-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = MonicaShortcutSnapshotFileStore(containerURL: directory)
        let missingSnapshot = try store.loadSnapshot()
        #expect(missingSnapshot == nil)
        #expect(store.loadSnapshotOrFallback() == .locked)

        try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: store.snapshotFileURL)
        #expect(store.loadSnapshotOrFallback() == .locked)
    }

    @Test func persistedSnapshotUsesStableFileNamesAndKeys() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-widget-shared-names-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let widgetStore = MonicaWidgetSnapshotFileStore(containerURL: directory)
        try widgetStore.saveSnapshot(MonicaWidgetSnapshot(vaultState: .unlocked, totalEntryCount: 1))

        let shortcutStore = MonicaShortcutSnapshotFileStore(containerURL: directory)
        try shortcutStore.saveSnapshot(MonicaShortcutSnapshot(vaultState: .unlocked))

        #expect(widgetStore.snapshotFileURL.lastPathComponent == "widget-snapshot-v1.json")
        #expect(shortcutStore.snapshotFileURL.lastPathComponent == "shortcuts-snapshot-v1.json")

        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: widgetStore.snapshotFileURL))
                as? [String: Any]
        )
        #expect(Set(json.keys) == ["schemaVersion", "vaultState", "totalEntryCount", "totpItems", "shortcutItems"])
    }
}
