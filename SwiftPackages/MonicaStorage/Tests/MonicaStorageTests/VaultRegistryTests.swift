import Foundation
import Testing
import MonicaStorage

private let registryBaseDate = Date(timeIntervalSince1970: 1_750_000_000)

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("monica-vault-registry-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeVaultFile(named fileName: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(fileName, isDirectory: false)
    try Data("mdbx-placeholder".utf8).write(to: url)
    return url
}

@Suite("本地多库注册表")
struct VaultRegistryTests {
    @Test func registryRegistersTwoVaultsAndKeepsLastOpenedSelection() throws {
        var registry = LocalVaultRegistry()
        let first = registry.register(
            vaultID: "vault-a",
            fileURL: URL(fileURLWithPath: "/tmp/monica-tests/A.mdbx"),
            displayName: "工作库",
            now: registryBaseDate
        )
        let second = registry.register(
            vaultID: "vault-b",
            fileURL: URL(fileURLWithPath: "/tmp/monica-tests/B.mdbx"),
            displayName: "个人库",
            now: registryBaseDate.addingTimeInterval(60)
        )

        #expect(registry.count == 2)
        #expect(registry.selectedEntryID == second.id)
        #expect(registry.selectedEntry?.displayName == "个人库")
        // 首个库自动成为默认库，后续登记不会抢默认标记。
        #expect(registry.defaultEntry?.id == first.id)
        #expect(registry.sortedEntries.map(\.displayName) == ["工作库", "个人库"])

        // 同一个库再次打开不会产生重复行，只更新上次打开时间与选择。
        let reopened = registry.register(
            vaultID: "vault-a",
            fileURL: URL(fileURLWithPath: "/tmp/monica-tests/A.mdbx"),
            displayName: "A.mdbx",
            now: registryBaseDate.addingTimeInterval(120)
        )
        #expect(registry.count == 2)
        #expect(reopened.id == first.id)
        #expect(reopened.displayName == "工作库")
        #expect(reopened.lastOpenedAt == registryBaseDate.addingTimeInterval(120))
        #expect(registry.selectedEntryID == first.id)
        #expect(registry.sortedEntries.first?.id == first.id)
    }

    @Test func registryKeepsExactlyOneDefaultVault() throws {
        var registry = LocalVaultRegistry()
        let first = registry.register(
            vaultID: "vault-a",
            fileURL: URL(fileURLWithPath: "/tmp/A.mdbx"),
            displayName: "A",
            now: registryBaseDate
        )
        let second = registry.register(
            vaultID: "vault-b",
            fileURL: URL(fileURLWithPath: "/tmp/B.mdbx"),
            displayName: "B",
            now: registryBaseDate.addingTimeInterval(30)
        )

        try registry.setDefault(id: second.id)
        #expect(registry.defaultEntry?.id == second.id)
        #expect(registry.entries.filter(\.isDefault).count == 1)
        #expect(registry.sortedEntries.first?.id == second.id)
        #expect(registry.entry(id: first.id)?.isDefault == false)

        // 删除默认库后，默认标记落到最近打开的剩余库。
        let removed = try registry.remove(id: second.id)
        #expect(removed.id == second.id)
        #expect(registry.count == 1)
        #expect(registry.defaultEntry?.id == first.id)
        #expect(registry.entries.filter(\.isDefault).count == 1)
    }

    @Test func registryRenameValidatesNameAndKeepsFileIdentity() throws {
        var registry = LocalVaultRegistry()
        let entry = registry.register(
            vaultID: "vault-a",
            fileURL: URL(fileURLWithPath: "/tmp/A.mdbx"),
            displayName: "A",
            now: registryBaseDate
        )
        _ = registry.register(
            vaultID: "vault-b",
            fileURL: URL(fileURLWithPath: "/tmp/B.mdbx"),
            displayName: "B",
            now: registryBaseDate.addingTimeInterval(10)
        )

        try registry.rename(id: entry.id, to: "  改名后的库  ")
        #expect(registry.entry(id: entry.id)?.displayName == "改名后的库")
        // 重命名只改显示名，文件名与库 ID 不变。
        #expect(registry.entry(id: entry.id)?.fileName == "A.mdbx")
        #expect(registry.entry(id: entry.id)?.vaultID == "vault-a")
        #expect(registry.entry(vaultID: "vault-a")?.id == entry.id)

        #expect(throws: VaultRegistryError.duplicateDisplayName("b")) {
            try registry.rename(id: entry.id, to: "b")
        }
        #expect(throws: VaultRegistryError.emptyDisplayName) {
            try registry.rename(id: entry.id, to: "   ")
        }
        #expect(throws: VaultRegistryError.entryNotFound) {
            try registry.rename(id: "missing", to: "新名字")
        }
        #expect(registry.entry(id: entry.id)?.displayName == "改名后的库")
    }

    @Test func registryRemovalNeverTouchesDiskFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let vaultURL = try makeVaultFile(named: "工作库.mdbx", in: directory)
        var registry = LocalVaultRegistry()
        let entry = registry.register(
            vaultID: "vault-a",
            fileURL: vaultURL,
            displayName: "工作库",
            now: registryBaseDate
        )

        let removed = try registry.remove(id: entry.id)

        #expect(removed.fileURL.standardizedFileURL == vaultURL.standardizedFileURL)
        #expect(registry.isEmpty)
        #expect(registry.selectedEntryID == nil)
        #expect(FileManager.default.fileExists(atPath: vaultURL.path))
    }

    @Test func registrySelectionFallsBackWhenSelectedVaultIsDeleted() throws {
        var registry = LocalVaultRegistry()
        _ = registry.register(
            vaultID: "vault-a",
            fileURL: URL(fileURLWithPath: "/tmp/A.mdbx"),
            displayName: "A",
            now: registryBaseDate
        )
        let second = registry.register(
            vaultID: "vault-b",
            fileURL: URL(fileURLWithPath: "/tmp/B.mdbx"),
            displayName: "B",
            now: registryBaseDate.addingTimeInterval(10)
        )
        let third = registry.register(
            vaultID: "vault-c",
            fileURL: URL(fileURLWithPath: "/tmp/C.mdbx"),
            displayName: "C",
            now: registryBaseDate.addingTimeInterval(20)
        )

        // 删掉当前选中的库：回落到默认库。
        _ = try registry.remove(id: third.id)
        #expect(registry.selectedEntry?.displayName == "A")

        // 再删一个非选中库不影响选择。
        try registry.select(id: second.id)
        #expect(throws: VaultRegistryError.entryNotFound) {
            try registry.remove(id: "nothing")
        }
        #expect(registry.selectedEntry?.id == second.id)
    }

    @Test func registryAdoptsLegacyVaultOnlyIntoEmptyRegistry() throws {
        var registry = LocalVaultRegistry()
        let legacyURL = URL(fileURLWithPath: "/tmp/legacy/Monica.mdbx")

        let adopted = registry.adoptLegacyVault(
            vaultID: "legacy-vault",
            fileURL: legacyURL,
            displayName: "Monica",
            now: registryBaseDate
        )
        #expect(adopted)
        #expect(registry.count == 1)
        #expect(registry.defaultEntry?.vaultID == "legacy-vault")
        #expect(registry.selectedEntry?.vaultID == "legacy-vault")
        #expect(registry.selectedEntry?.isDefault == true)

        // 已经有注册表时不再迁移，避免覆盖用户的多库状态。
        #expect(registry.adoptLegacyVault(
            vaultID: "other-vault",
            fileURL: URL(fileURLWithPath: "/tmp/other.mdbx"),
            displayName: "Other",
            now: registryBaseDate
        ) == false)
        #expect(registry.count == 1)
    }

    @Test func registryResolvesRelocatedContainerPathAndRebasesStoredPath() throws {
        let oldDirectory = try makeTemporaryDirectory()
        let newDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: oldDirectory)
            try? FileManager.default.removeItem(at: newDirectory)
        }

        let oldURL = oldDirectory.appendingPathComponent("Monica.mdbx", isDirectory: false)
        let newURL = try makeVaultFile(named: "Monica.mdbx", in: newDirectory)

        var registry = LocalVaultRegistry()
        let entry = registry.register(
            vaultID: "vault-a",
            fileURL: oldURL,
            displayName: "Monica",
            now: registryBaseDate
        )

        let resolved = registry.resolveFileURL(for: entry, baseDirectory: newDirectory)
        #expect(resolved.standardizedFileURL == newURL.standardizedFileURL)
        // resolve 只读：写回要显式调用 rebase。
        #expect(registry.entry(id: entry.id)?.fileURL.standardizedFileURL == oldURL.standardizedFileURL)

        let rebased = registry.rebaseStoredPaths(baseDirectory: newDirectory)
        #expect(rebased)
        #expect(registry.entry(id: entry.id)?.fileURL.standardizedFileURL == newURL.standardizedFileURL)
        #expect(registry.entry(id: entry.id)?.fileName == "Monica.mdbx")
        #expect(registry.rebaseStoredPaths(baseDirectory: newDirectory) == false)
        #expect(registry.missingEntries(baseDirectory: newDirectory).isEmpty)
    }

    @Test func registryReportsMissingFilesWithoutDroppingEntries() throws {
        var registry = LocalVaultRegistry()
        let entry = registry.register(
            vaultID: "vault-a",
            fileURL: URL(fileURLWithPath: "/tmp/definitely-missing-\(UUID().uuidString)/A.mdbx"),
            displayName: "A",
            now: registryBaseDate
        )

        #expect(registry.missingEntries(baseDirectory: nil).map(\.id) == [entry.id])
        #expect(registry.count == 1)
    }

    @Test func registryEncodesOnlyNonSecretMetadata() throws {
        var registry = LocalVaultRegistry()
        _ = registry.register(
            vaultID: "vault-a",
            fileURL: URL(fileURLWithPath: "/tmp/A.mdbx"),
            displayName: "A",
            now: registryBaseDate
        )

        let data = try JSONEncoder().encode(registry)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["schemaVersion", "entries", "selectedEntryID"])

        let entries = try #require(object["entries"] as? [[String: Any]])
        let allowedKeys: Set<String> = [
            "id", "vaultID", "displayName", "fileName", "fileURL",
            "bookmarkData", "lastOpenedAt", "isDefault",
        ]
        for entry in entries {
            #expect(Set(entry.keys).isSubset(of: allowedKeys))
        }

        // 主密码 / 密钥材料一律不得写进注册表 JSON。
        let json = String(decoding: data, as: UTF8.self).lowercased()
        for forbidden in ["password", "wrappedkey", "securitykey", "keymaterial", "secret", "masterkey"] {
            #expect(!json.contains(forbidden))
        }
    }

    @Test func registryRoundTripsThroughJSON() throws {
        var registry = LocalVaultRegistry()
        let entry = registry.register(
            vaultID: "vault-a",
            fileURL: URL(fileURLWithPath: "/tmp/A.mdbx"),
            displayName: "工作库",
            now: registryBaseDate
        )
        try registry.setDefault(id: entry.id)

        let data = try JSONEncoder().encode(registry)
        let decoded = try JSONDecoder().decode(LocalVaultRegistry.self, from: data)

        #expect(decoded == registry)
        #expect(decoded.schemaVersion == LocalVaultRegistry.currentSchemaVersion)
        #expect(decoded.selectedEntryID == entry.id)
        #expect(decoded.defaultEntry?.displayName == "工作库")
    }

    @Test func emptyRegistryHasNoSelectionOrDefault() {
        let registry = LocalVaultRegistry()
        #expect(registry.isEmpty)
        #expect(registry.defaultEntry == nil)
        #expect(registry.selectedEntry == nil)
        #expect(registry.sortedEntries.isEmpty)
        #expect(registry.missingEntries(baseDirectory: nil).isEmpty)
    }

}
