import XCTest
@testable import Monica
import MonicaStorage

@MainActor
final class VaultRegistrySessionTests: XCTestCase {
    private let deviceID = "ios-vault-registry-test-device"
    private let passwordA = "Alpha password 12345!"
    private let passwordB = "Beta password 12345!"

    // MARK: - Helpers

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-vault-registry-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func makeSession(
        rememberedVaultStore: any RememberedVaultStore = MemoryRememberedVaultStore(),
        vaultRegistryStore: any AppVaultRegistryStore = MemoryAppVaultRegistryStore()
    ) -> AppSessionModel {
        AppSessionModel(
            vaultRepository: LocalVaultRepository(),
            rememberedVaultStore: rememberedVaultStore,
            vaultRegistryStore: vaultRegistryStore
        )
    }

    private func createVault(_ name: String, password: String, in directory: URL, model: AppSessionModel) throws {
        model.vaultName = name
        model.vaultPassword = password
        try model.createLocalVault(in: directory, deviceID: deviceID)
    }

    private func entry(named name: String, in model: AppSessionModel) throws -> VaultRegistryEntry {
        try XCTUnwrap(model.registeredVaultEntries.first { $0.displayName == name })
    }

    // MARK: - 注册表

    func testCreatingTwoVaultsRegistersDistinctEntriesWithStableIDs() throws {
        let directory = makeDirectory()
        let registryStore = MemoryAppVaultRegistryStore()
        let model = makeSession(vaultRegistryStore: registryStore)

        try createVault("Alpha", password: passwordA, in: directory, model: model)
        let alphaVaultID = try XCTUnwrap(model.activeVaultSession?.handle.vaultID)
        model.lockLocalVault()

        try createVault("Beta", password: passwordB, in: directory, model: model)
        let betaVaultID = try XCTUnwrap(model.activeVaultSession?.handle.vaultID)

        XCTAssertNotEqual(alphaVaultID, betaVaultID)
        XCTAssertEqual(model.registeredVaultCount, 2)
        XCTAssertEqual(Set(model.registeredVaultEntries.map(\.vaultID)), [alphaVaultID, betaVaultID])

        let alpha = try entry(named: "Alpha", in: model)
        let beta = try entry(named: "Beta", in: model)
        XCTAssertEqual(alpha.vaultID, alphaVaultID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: alpha.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: beta.fileURL.path))
        XCTAssertEqual(beta.vaultID, betaVaultID)

        // 最后打开的库是 Beta，默认库仍然只有一个。
        XCTAssertEqual(model.selectedVaultRegistryEntry?.vaultID, betaVaultID)
        XCTAssertEqual(model.registeredVaultEntries.filter(\.isDefault).count, 1)
        XCTAssertEqual(registryStore.currentRegistry.count, 2)
    }

    func testRegistryStorePersistsOnlyNonSecretMetadata() throws {
        let directory = makeDirectory()
        let registryStore = MemoryAppVaultRegistryStore()
        let model = makeSession(vaultRegistryStore: registryStore)
        try createVault("Alpha", password: passwordA, in: directory, model: model)

        let data = try JSONEncoder().encode(registryStore.currentRegistry)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8)?.lowercased())
        for secret in ["password", "wrappedkey", "securitykey", "keymaterial", "masterkey"] {
            XCTAssertFalse(json.contains(secret), "注册表不应包含 \(secret)")
        }
    }

    // MARK: - 切换

    func testSwitchingVaultLocksSessionAndDoesNotUnlockAutomatically() throws {
        let directory = makeDirectory()
        let model = makeSession()

        try createVault("Alpha", password: passwordA, in: directory, model: model)
        let alphaVaultID = try XCTUnwrap(model.activeVaultSession?.handle.vaultID)
        model.lockLocalVault()
        try createVault("Beta", password: passwordB, in: directory, model: model)

        let alpha = try entry(named: "Alpha", in: model)
        try model.switchToRegisteredVault(id: alpha.id)

        XCTAssertEqual(model.vaultState, .locked)
        XCTAssertNil(model.activeVaultSession)
        XCTAssertNil(model.activeEntryRepository)
        XCTAssertEqual(model.rememberedVaultIdentity?.vaultID, alphaVaultID)
        XCTAssertEqual(model.selectedVaultRegistryEntry?.vaultID, alphaVaultID)
        XCTAssertTrue(model.vaultPassword.isEmpty)
    }

    func testSwitchingVaultKeepsContentsIsolated() throws {
        let directory = makeDirectory()
        let model = makeSession()

        try createVault("Alpha", password: passwordA, in: directory, model: model)
        model.loginTitle = "Alpha only login"
        model.loginUsername = "alpha@example.com"
        model.loginPassword = "alpha-secret"
        try model.createLoginEntry(projectTitle: "Alpha")
        XCTAssertEqual(model.loginEntries.count, 1)
        model.lockLocalVault()

        try createVault("Beta", password: passwordB, in: directory, model: model)
        XCTAssertEqual(model.loginEntries.count, 0)
        let betaVaultID = try XCTUnwrap(model.activeVaultSession?.handle.vaultID)
        model.lockLocalVault()

        // 切回 Alpha 并解锁：只应该看到 Alpha 的条目。
        let alpha = try entry(named: "Alpha", in: model)
        try model.switchToRegisteredVault(id: alpha.id)
        model.vaultPassword = passwordA
        try model.unlockRememberedVaultWithPassword(
            deviceID: deviceID,
            fallbackDirectory: directory
        )
        XCTAssertEqual(model.vaultState, .unlocked)
        XCTAssertEqual(model.loginEntries.map(\.title), ["Alpha only login"])

        // 再切到 Beta：Beta 的内容保持为空。
        model.lockLocalVault()
        let beta = try entry(named: "Beta", in: model)
        try model.switchToRegisteredVault(id: beta.id)
        XCTAssertEqual(model.rememberedVaultIdentity?.vaultID, betaVaultID)
        model.vaultPassword = passwordB
        try model.unlockRememberedVaultWithPassword(
            deviceID: deviceID,
            fallbackDirectory: directory
        )
        XCTAssertEqual(model.loginEntries.count, 0)
    }

    // MARK: - 默认库

    func testDefaultVaultIsExclusiveAndOnlyMarksSelection() throws {
        let directory = makeDirectory()
        let model = makeSession()

        try createVault("Alpha", password: passwordA, in: directory, model: model)
        model.lockLocalVault()
        try createVault("Beta", password: passwordB, in: directory, model: model)
        model.lockLocalVault()

        let alpha = try entry(named: "Alpha", in: model)
        let beta = try entry(named: "Beta", in: model)

        try model.setDefaultRegisteredVault(id: alpha.id)
        XCTAssertEqual(model.defaultVaultRegistryEntry?.id, alpha.id)
        XCTAssertEqual(model.registeredVaultEntries.filter(\.isDefault).count, 1)
        // 设默认库不会自动解锁，也不会改写「上次打开」。
        XCTAssertEqual(model.vaultState, .locked)
        XCTAssertEqual(model.rememberedVaultIdentity?.vaultID, beta.vaultID)
        XCTAssertEqual(model.selectedVaultRegistryEntry?.id, beta.id)
    }

    // MARK: - 重命名

    func testRenamingRegistryEntryKeepsFileAndUpdatesRememberedName() throws {
        let directory = makeDirectory()
        let model = makeSession()
        try createVault("Alpha", password: passwordA, in: directory, model: model)

        let alpha = try entry(named: "Alpha", in: model)
        let vaultID = try XCTUnwrap(model.activeVaultSession?.handle.vaultID)

        try model.renameRegisteredVault(id: alpha.id, to: "Alpha 工作库")

        let renamed = try entry(named: "Alpha 工作库", in: model)
        XCTAssertEqual(renamed.id, alpha.id)
        XCTAssertEqual(renamed.fileName, alpha.fileName)
        XCTAssertEqual(renamed.fileURL, alpha.fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.fileURL.path))
        XCTAssertEqual(model.rememberedVaultIdentity?.displayName, "Alpha 工作库")
        XCTAssertEqual(model.activeVaultName, "Alpha 工作库")
        XCTAssertEqual(model.activeVaultSession?.handle.vaultID, vaultID)
    }

    func testRenamingRegistryEntryRejectsDuplicateName() throws {
        let directory = makeDirectory()
        let model = makeSession()
        try createVault("Alpha", password: passwordA, in: directory, model: model)
        model.lockLocalVault()
        try createVault("Beta", password: passwordB, in: directory, model: model)

        let beta = try entry(named: "Beta", in: model)
        XCTAssertThrowsError(try model.renameRegisteredVault(id: beta.id, to: "Alpha"))
        XCTAssertEqual(try entry(named: "Beta", in: model).id, beta.id)
    }

    // MARK: - 删除

    func testDeletingRegistryEntryWithoutFileKeepsMdbxOnDisk() throws {
        let directory = makeDirectory()
        let model = makeSession()
        try createVault("Alpha", password: passwordA, in: directory, model: model)
        model.lockLocalVault()
        try createVault("Beta", password: passwordB, in: directory, model: model)

        let beta = try entry(named: "Beta", in: model)
        try model.deleteRegisteredVault(id: beta.id, removeFile: false)

        XCTAssertEqual(model.registeredVaultCount, 1)
        XCTAssertTrue(model.registeredVaultEntries.allSatisfy { $0.id != beta.id })
        XCTAssertTrue(FileManager.default.fileExists(atPath: beta.fileURL.path))
        // 删掉「上次打开」的库后，指针回落到剩下的库，避免锁屏指向不存在的记录。
        XCTAssertEqual(model.rememberedVaultIdentity?.displayName, "Alpha")
        XCTAssertEqual(model.vaultState, .locked)
    }

    func testDeletingRegistryEntryWithFileRemovesMdbx() throws {
        let directory = makeDirectory()
        let model = makeSession()
        try createVault("Alpha", password: passwordA, in: directory, model: model)
        model.lockLocalVault()
        try createVault("Beta", password: passwordB, in: directory, model: model)

        let beta = try entry(named: "Beta", in: model)
        XCTAssertTrue(FileManager.default.fileExists(atPath: beta.fileURL.path))

        try model.deleteRegisteredVault(id: beta.id, removeFile: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: beta.fileURL.path))
        XCTAssertEqual(model.registeredVaultCount, 1)
        XCTAssertEqual(model.defaultVaultRegistryEntry?.displayName, "Alpha")
    }

    func testDeletingLastVaultFallsBackToFirstTimeSetup() throws {
        let directory = makeDirectory()
        let model = makeSession()
        try createVault("Alpha", password: passwordA, in: directory, model: model)
        model.lockLocalVault()

        let alpha = try entry(named: "Alpha", in: model)
        try model.deleteRegisteredVault(id: alpha.id, removeFile: false)

        XCTAssertEqual(model.registeredVaultCount, 0)
        XCTAssertNil(model.rememberedVaultIdentity)
        XCTAssertTrue(model.isFirstTimeVaultSetup)
    }

    // MARK: - 老用户迁移

    func testBootstrapAdoptsLegacySingleVaultIntoDefaultEntry() throws {
        let directory = makeDirectory()
        let legacyURL = directory.appendingPathComponent("Monica.mdbx")
        let remembered = MemoryRememberedVaultStore(
            record: RememberedVaultRecord(
                fileURL: legacyURL,
                displayName: "Monica",
                vaultID: "legacy-vault-id"
            )
        )
        let registryStore = MemoryAppVaultRegistryStore()

        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(),
            rememberedVaultStore: remembered,
            vaultRegistryStore: registryStore
        )

        XCTAssertEqual(model.registeredVaultCount, 1)
        XCTAssertEqual(model.defaultVaultRegistryEntry?.vaultID, "legacy-vault-id")
        XCTAssertEqual(model.selectedVaultRegistryEntry?.displayName, "Monica")
        // 单库老用户启动行为不变：仍然使用 remembered 里的库，锁屏不进入首次设置流程。
        XCTAssertFalse(model.isFirstTimeVaultSetup)
        XCTAssertFalse(model.isVaultPasswordSetupFlow)
        XCTAssertEqual(model.vaultState, .locked)
        XCTAssertEqual(registryStore.currentRegistry.entries.first?.vaultID, "legacy-vault-id")
    }

    func testBootstrapRestoresSelectionFromDefaultWhenRegistryHasNoSelection() throws {
        let directory = makeDirectory()
        let alphaURL = directory.appendingPathComponent("Alpha.mdbx")
        var registry = LocalVaultRegistry()
        let alpha = registry.register(
            vaultID: "alpha-id",
            fileURL: alphaURL,
            displayName: "Alpha",
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try registry.setDefault(id: alpha.id)
        registry.clearSelection()

        let registryStore = MemoryAppVaultRegistryStore(registry: registry)
        let model = AppSessionModel(
            vaultRepository: LocalVaultRepository(),
            rememberedVaultStore: MemoryRememberedVaultStore(),
            vaultRegistryStore: registryStore
        )

        XCTAssertEqual(model.selectedVaultRegistryEntry?.vaultID, "alpha-id")
        XCTAssertEqual(model.rememberedVaultIdentity?.vaultID, "alpha-id")
        XCTAssertEqual(model.defaultVaultRegistryEntry?.vaultID, "alpha-id")
    }

    // MARK: - 新建

    func testBeginVaultCreationRejectsDuplicateNameAndPreparesPasswordSetup() throws {
        let directory = makeDirectory()
        let model = makeSession()
        try createVault("Alpha", password: passwordA, in: directory, model: model)
        model.lockLocalVault()

        XCTAssertFalse(model.beginVaultCreation(named: "Alpha", baseDirectory: directory))
        XCTAssertTrue(model.hasRegisteredVaults)

        XCTAssertTrue(model.beginVaultCreation(named: "Gamma", baseDirectory: directory))
        XCTAssertTrue(model.isPendingVaultCreation)
        XCTAssertTrue(model.isVaultPasswordSetupFlow)
        XCTAssertEqual(model.selectedVaultDisplayName, "Gamma")

        model.vaultPassword = "Gamma password 12345!"
        model.beginFirstTimePasswordConfirmation()
        model.vaultPassword = "Gamma password 12345!"
        try model.confirmFirstTimePasswordAndCreateVault(in: directory, deviceID: deviceID)

        XCTAssertNil(model.pendingVaultCreationName)
        XCTAssertEqual(model.vaultState, .unlocked)
        XCTAssertEqual(model.registeredVaultCount, 2)
        XCTAssertEqual(model.activeVaultSession?.descriptor.displayName, "Gamma")
    }

    func testCancelVaultCreationReturnsToLockedState() throws {
        let directory = makeDirectory()
        let model = makeSession()
        try createVault("Alpha", password: passwordA, in: directory, model: model)
        model.lockLocalVault()

        XCTAssertTrue(model.beginVaultCreation(named: "Gamma", baseDirectory: directory))
        model.cancelVaultCreation()

        XCTAssertFalse(model.isPendingVaultCreation)
        XCTAssertEqual(model.vaultState, .locked)
        XCTAssertEqual(model.registeredVaultCount, 1)
    }
}
