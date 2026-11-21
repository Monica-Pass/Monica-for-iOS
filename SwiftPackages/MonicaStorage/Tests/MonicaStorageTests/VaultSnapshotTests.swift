import Testing
import Foundation
import MonicaStorage

// MARK: - 索引 / 差异（纯模型）

@Test func snapshotIndexIsCodableAndFingerprintsOnlyMetadata() throws {
    let document = VaultSearchDocument(
        kind: .login,
        id: "entry-1",
        projectID: "project-1",
        title: "GitHub",
        username: "octocat",
        url: "https://github.com",
        notes: "备注",
        tags: ["代码", "工作"],
        isFavorite: true
    )
    let index = VaultSnapshotIndexBuilder.index(
        projects: [VaultSnapshotProject(id: "project-1", title: "个人")],
        documents: [document]
    )

    #expect(index.itemCount == 1)
    #expect(index.liveCountsByKind()[.login] == 1)
    #expect(index.items.first?.title == "GitHub")

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoded = try JSONDecoder().decode(VaultSnapshotIndex.self, from: encoder.encode(index))
    #expect(decoded == index)

    // 仅用查看次数不同的同一文档，摘要必须一致：读条目不算内容变化。
    var viewed = document
    viewed.viewCount = 42
    viewed.lastViewedAt = Date(timeIntervalSince1970: 1_000)
    #expect(VaultSnapshotIndexBuilder.digest(for: viewed) == VaultSnapshotIndexBuilder.digest(for: document))

    // 标题变化必须产生不同摘要。
    var renamed = document
    renamed = VaultSearchDocument(
        kind: .login,
        id: "entry-1",
        projectID: "project-1",
        title: "GitHub 改名",
        username: "octocat",
        url: "https://github.com",
        notes: "备注",
        tags: ["代码", "工作"],
        isFavorite: true
    )
    #expect(VaultSnapshotIndexBuilder.digest(for: renamed) != VaultSnapshotIndexBuilder.digest(for: document))
}

@Test func snapshotDiffClassifiesAddedRemovedAndModifiedItems() {
    let snapshotDocuments = [
        VaultSearchDocument(kind: .login, id: "kept", projectID: "p", title: "保持不变"),
        VaultSearchDocument(kind: .login, id: "changed", projectID: "p", title: "旧标题"),
        VaultSearchDocument(kind: .note, id: "only-in-snapshot", projectID: "p", title: "快照独有"),
        VaultSearchDocument(kind: .login, id: "deleted-in-snapshot", projectID: "p", title: "已删除", isDeleted: true)
    ]
    let currentDocuments = [
        VaultSearchDocument(kind: .login, id: "kept", projectID: "p", title: "保持不变"),
        VaultSearchDocument(kind: .login, id: "changed", projectID: "p", title: "新标题"),
        VaultSearchDocument(kind: .login, id: "only-in-current", projectID: "p", title: "当前独有")
    ]

    let snapshot = VaultSnapshotIndexBuilder.index(
        projects: [VaultSnapshotProject(id: "p", title: "项目")],
        documents: snapshotDocuments
    )
    let current = VaultSnapshotIndexBuilder.index(
        projects: [VaultSnapshotProject(id: "p", title: "项目")],
        documents: currentDocuments
    )
    let diff = VaultSnapshotDiffEngine.diff(snapshot: snapshot, current: current)

    #expect(diff.unchangedItemCount == 1)
    #expect(diff.addedCount == 2)          // only-in-snapshot + deleted-in-snapshot
    #expect(diff.removedCount == 1)        // only-in-current
    #expect(diff.modifiedCount == 1)       // changed
    #expect(diff.isDestructive)

    let removed = diff.items(.removed)
    #expect(removed.first?.currentTitle == "当前独有")
    #expect(removed.first?.snapshotTitle == nil)

    let modified = diff.items(.modified)
    #expect(modified.first?.snapshotTitle == "旧标题")
    #expect(modified.first?.currentTitle == "新标题")
    #expect(diff.countsByKind()[.login]?[.removed] == 1)

    let identical = VaultSnapshotDiffEngine.diff(snapshot: current, current: current)
    #expect(identical.isEmpty)
    #expect(!identical.isDestructive)
}

// MARK: - 真实 MDBX 保险库：创建 / 差异 / 恢复

@Test func snapshotCapturesConsistentVaultAndRestoreRoundTrips() throws {
    let directory = try makeTemporaryDirectory(prefix: "monica-snapshot-roundtrip")
    defer { try? FileManager.default.removeItem(at: directory) }

    let vaultURL = directory.appendingPathComponent("vault.mdbx")
    let snapshotsURL = directory.appendingPathComponent("snapshots", isDirectory: true)
    let password = "snapshot vault password 123!"
    let deviceID = "swiftpm-snapshot-test"
    let vaultID = "vault-roundtrip"

    let engine = MDBXLocalVaultEngine()
    let keyProvider = InMemoryVaultSnapshotKeyProvider()
    let store = VaultSnapshotStore(directoryURL: snapshotsURL, keyProvider: keyProvider)

    // 状态 A：一个项目 + 两条登录条目。
    let handleA = try engine.createVault(at: vaultURL, password: password, deviceID: deviceID)
    let repositoryA = makeRepository(
        engine: engine,
        vaultURL: vaultURL,
        displayName: "Roundtrip",
        handle: handleA
    )
    let projectA = try repositoryA.createProject(title: "个人")
    let knownProjects = [VaultSnapshotProject(id: projectA.id, title: projectA.title)]
    _ = try repositoryA.createLoginEntry(
        projectID: projectA.id,
        draft: LocalLoginEntryDraft(
            title: "GitHub",
            username: "octocat",
            password: "p@ssw0rd",
            url: "https://github.com"
        )
    )
    let indexA = try makeIndex(repository: repositoryA, projects: knownProjects)
    #expect(indexA.itemCount == 1)

    // 快照必须在关掉 FFI 连接之后创建（静默状态）。
    engine.closeVault(handleA)
    let manifestA = try store.createSnapshot(
        vaultFileURL: vaultURL,
        vaultID: vaultID,
        vaultDisplayName: "Roundtrip",
        reason: .manual,
        index: indexA,
        now: Date(timeIntervalSince1970: 1_000_000)
    )
    #expect(manifestA.itemCount == indexA.itemCount)
    #expect(manifestA.payloadByteCount > 0)

    // 加密信封里不能出现明文字段或保险库明文。
    let envelope = try Data(contentsOf: store.record(snapshotID: manifestA.id, vaultID: vaultID).fileURL)
    #expect(envelope.range(of: Data("GitHub".utf8)) == nil)
    #expect(envelope.range(of: Data("octocat".utf8)) == nil)
    #expect(envelope.prefix(VaultSnapshotStore.envelopeMagic.count) == VaultSnapshotStore.envelopeMagic)

    // 状态 B：新增一条笔记。
    let handleB = try engine.openVault(at: vaultURL, password: password, deviceID: deviceID)
    let repositoryB = makeRepository(
        engine: engine,
        vaultURL: vaultURL,
        displayName: "Roundtrip",
        handle: handleB
    )
    _ = try repositoryB.createNoteEntry(
        projectID: projectA.id,
        draft: LocalNoteEntryDraft(title: "旅行清单", body: "护照 / 充电器")
    )
    let indexB = try makeIndex(repository: repositoryB, projects: knownProjects)
    #expect(indexB.itemCount == 2)
    engine.closeVault(handleB)

    let diff = VaultSnapshotDiffEngine.diff(
        snapshot: manifestA.index,
        current: indexB
    )
    #expect(diff.removedCount == 1)   // 恢复 A 会让「旅行清单」消失
    #expect(diff.addedCount == 0)
    #expect(diff.isDestructive)

    // 校验快照自身。
    let verified = try store.verifySnapshot(snapshotID: manifestA.id, vaultID: vaultID)
    #expect(verified.payloadSHA256 == manifestA.payloadSHA256)

    // 恢复：自动留回滚点 + 原子替换 + 校验哈希。
    let result = try store.restoreSnapshot(
        snapshotID: manifestA.id,
        vaultID: vaultID,
        to: vaultURL,
        vaultDisplayName: "Roundtrip",
        currentIndex: indexB,
        now: Date(timeIntervalSince1970: 1_000_100)
    )
    #expect(result.restoredPayloadSHA256 == manifestA.payloadSHA256)
    #expect(result.safetySnapshot?.reason == .preRestoreSafety)
    let restoredDigest = try VaultSnapshotCrypto.sha256Hex(ofFileAt: vaultURL)
    #expect(restoredDigest == manifestA.payloadSHA256)

    // 重新打开验证条目数/内容就是状态 A。
    let reopened = try engine.openVault(at: vaultURL, password: password, deviceID: deviceID)
    let reopenedRepository = makeRepository(
        engine: engine,
        vaultURL: vaultURL,
        displayName: "Roundtrip",
        handle: reopened
    )
    let reopenedIndex = try makeIndex(repository: reopenedRepository, projects: knownProjects)
    #expect(reopenedIndex.itemCount == 1)
    #expect(reopenedIndex.items.first?.title == "GitHub")
    #expect(try reopenedRepository.listLoginEntries(projectID: projectA.id).count == 1)
    #expect(try reopenedRepository.listNoteEntries(projectID: projectA.id).isEmpty)
    engine.closeVault(reopened)

    // 保留策略：两份快照（手动 + 回滚点）都在。
    let records = try store.listSnapshots(vaultID: vaultID)
    #expect(records.count == 2)
    #expect(records.first?.manifest.reason == .preRestoreSafety)
}

// MARK: - 失败路径：未静默 / 篡改 / 磁盘不足 / 写入中断

@Test func snapshotRefusesVaultWithActiveWalSidecar() throws {
    let directory = try makeTemporaryDirectory(prefix: "monica-snapshot-wal")
    defer { try? FileManager.default.removeItem(at: directory) }

    let vaultURL = directory.appendingPathComponent("vault.mdbx")
    let store = VaultSnapshotStore(
        directoryURL: directory.appendingPathComponent("snapshots", isDirectory: true),
        keyProvider: InMemoryVaultSnapshotKeyProvider()
    )
    let engine = MDBXLocalVaultEngine()
    let handle = try engine.createVault(at: vaultURL, password: "wal password 123!", deviceID: "wal-device")
    engine.closeVault(handle)

    // 模拟「还有连接在写」：留下非空 -wal 侧车文件。
    let walURL = URL(fileURLWithPath: vaultURL.path.replacingOccurrences(of: ".mdbx", with: "-wal"))
        .deletingLastPathComponent()
        .appendingPathComponent("vault.mdbx-wal")
    try Data(repeating: 0x7A, count: 512).write(to: walURL)
    defer { try? FileManager.default.removeItem(at: walURL) }

    #expect(throws: VaultSnapshotError.self) {
        _ = try store.createSnapshot(
            vaultFileURL: vaultURL,
            vaultID: "vault-wal",
            vaultDisplayName: "WAL",
            reason: .manual,
            index: .empty
        )
    }
    // 没有产生任何快照文件。
    #expect(try store.listSnapshots(vaultID: "vault-wal").isEmpty)
}

@Test func snapshotDetectsTamperingAndWrongKey() throws {
    let directory = try makeTemporaryDirectory(prefix: "monica-snapshot-tamper")
    defer { try? FileManager.default.removeItem(at: directory) }

    let vaultURL = directory.appendingPathComponent("vault.mdbx")
    let snapshotsURL = directory.appendingPathComponent("snapshots", isDirectory: true)
    let keyProvider = InMemoryVaultSnapshotKeyProvider()
    let store = VaultSnapshotStore(directoryURL: snapshotsURL, keyProvider: keyProvider)

    let engine = MDBXLocalVaultEngine()
    let handle = try engine.createVault(at: vaultURL, password: "tamper password 123!", deviceID: "tamper-device")
    engine.closeVault(handle)
    let originalBytes = try Data(contentsOf: vaultURL)

    let manifest = try store.createSnapshot(
        vaultFileURL: vaultURL,
        vaultID: "vault-tamper",
        vaultDisplayName: "Tamper",
        reason: .manual,
        index: .empty
    )
    let record = try store.record(snapshotID: manifest.id, vaultID: "vault-tamper")

    // 篡改信封最后一个字节（payload 密文的认证标签）。
    var tampered = try Data(contentsOf: record.fileURL)
    tampered[tampered.count - 1] ^= 0xFF
    try tampered.write(to: record.fileURL)
    #expect(throws: VaultSnapshotError.self) {
        _ = try store.verifySnapshot(snapshotID: manifest.id, vaultID: "vault-tamper")
    }
    #expect(throws: VaultSnapshotError.self) {
        _ = try store.restoreSnapshot(
            snapshotID: manifest.id,
            vaultID: "vault-tamper",
            to: vaultURL,
            vaultDisplayName: "Tamper",
            currentIndex: .empty
        )
    }
    // 保险库本体没有被改动。
    #expect(try Data(contentsOf: vaultURL) == originalBytes)

    // 换一把密钥：清单都解不开，列表为空、校验失败。
    let wrongKeyProvider = FixedKeyProvider(key: VaultSnapshotCrypto.randomKey())
    let wrongStore = VaultSnapshotStore(directoryURL: snapshotsURL, keyProvider: wrongKeyProvider)
    #expect(try wrongStore.listSnapshots(vaultID: "vault-tamper").isEmpty)
    #expect(throws: VaultSnapshotError.self) {
        _ = try wrongStore.verifySnapshot(snapshotID: manifest.id, vaultID: "vault-tamper")
    }
}

@Test func snapshotRestoreFailureLeavesOriginalVaultUntouched() throws {
    let directory = try makeTemporaryDirectory(prefix: "monica-snapshot-restore-fail")
    defer { try? FileManager.default.removeItem(at: directory) }

    let vaultURL = directory.appendingPathComponent("vault.mdbx")
    let snapshotsURL = directory.appendingPathComponent("snapshots", isDirectory: true)
    let keyProvider = InMemoryVaultSnapshotKeyProvider()
    let store = VaultSnapshotStore(directoryURL: snapshotsURL, keyProvider: keyProvider)

    let engine = MDBXLocalVaultEngine()
    let handle = try engine.createVault(at: vaultURL, password: "restore fail 123!", deviceID: "restore-device")
    let repository = makeRepository(engine: engine, vaultURL: vaultURL, displayName: "拒写", handle: handle)
    let project = try repository.createProject(title: "项目")
    let knownProjects = [VaultSnapshotProject(id: project.id, title: project.title)]
    let index = try makeIndex(repository: repository, projects: knownProjects)
    engine.closeVault(handle)

    let manifest = try store.createSnapshot(
        vaultFileURL: vaultURL,
        vaultID: "vault-restore-fail",
        vaultDisplayName: "拒写",
        reason: .manual,
        index: index
    )
    let originalDigest = try VaultSnapshotCrypto.sha256Hex(ofFileAt: vaultURL)

    // 1) 写入中断（模拟磁盘故障）：临时文件写不进去。
    let failingStore = VaultSnapshotStore(
        directoryURL: snapshotsURL,
        keyProvider: keyProvider,
        fileWriter: ThrowingFileWriter()
    )
    #expect(throws: (any Error).self) {
        _ = try failingStore.restoreSnapshot(
            snapshotID: manifest.id,
            vaultID: "vault-restore-fail",
            to: vaultURL,
            vaultDisplayName: "拒写",
            currentIndex: .empty
        )
    }
    #expect(try VaultSnapshotCrypto.sha256Hex(ofFileAt: vaultURL) == originalDigest)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0.contains("snapshot-restore") }
    #expect(leftovers.isEmpty)

    // 2) 磁盘空间不足：在写任何字节之前就拒绝。
    let smallDiskStore = VaultSnapshotStore(
        directoryURL: snapshotsURL,
        keyProvider: keyProvider,
        capacityProvider: { _ in 1_024 }
    )
    #expect(throws: VaultSnapshotError.self) {
        _ = try smallDiskStore.restoreSnapshot(
            snapshotID: manifest.id,
            vaultID: "vault-restore-fail",
            to: vaultURL,
            vaultDisplayName: "拒写",
            currentIndex: .empty
        )
    }
    #expect(try VaultSnapshotCrypto.sha256Hex(ofFileAt: vaultURL) == originalDigest)

    // 3) 快照与保险库不匹配。
    #expect(throws: VaultSnapshotError.self) {
        _ = try store.restoreSnapshot(
            snapshotID: manifest.id,
            vaultID: "another-vault",
            to: vaultURL,
            vaultDisplayName: "拒写",
            currentIndex: .empty
        )
    }
    #expect(try VaultSnapshotCrypto.sha256Hex(ofFileAt: vaultURL) == originalDigest)

    // 原保险库仍然能正常打开。
    let reopened = try engine.openVault(at: vaultURL, password: "restore fail 123!", deviceID: "restore-device")
    let reopenedRepository = makeRepository(
        engine: engine,
        vaultURL: vaultURL,
        displayName: "拒写",
        handle: reopened
    )
    let reopenedIndex = try makeIndex(repository: reopenedRepository, projects: knownProjects)
    #expect(reopenedIndex == index)
    engine.closeVault(reopened)
}

// MARK: - 保留策略 / 显式清理

@Test func snapshotRetentionKeepsNewestAndExplicitClearRemovesEverything() throws {
    let directory = try makeTemporaryDirectory(prefix: "monica-snapshot-retention")
    defer { try? FileManager.default.removeItem(at: directory) }

    let vaultURL = directory.appendingPathComponent("vault.mdbx")
    let snapshotsURL = directory.appendingPathComponent("snapshots", isDirectory: true)
    let store = VaultSnapshotStore(
        directoryURL: snapshotsURL,
        keyProvider: InMemoryVaultSnapshotKeyProvider(),
        retentionLimit: 3
    )

    let engine = MDBXLocalVaultEngine()
    let handle = try engine.createVault(at: vaultURL, password: "retention 123!", deviceID: "retention-device")
    engine.closeVault(handle)

    var created: [VaultSnapshotManifest] = []
    for offset in 0..<5 {
        created.append(
            try store.createSnapshot(
                vaultFileURL: vaultURL,
                vaultID: "vault-retention",
                vaultDisplayName: "保留策略",
                reason: .manual,
                index: .empty,
                now: Date(timeIntervalSince1970: 2_000_000 + Double(offset))
            )
        )
    }

    let records = try store.listSnapshots(vaultID: "vault-retention")
    #expect(records.count == 3)
    #expect(Set(records.map(\.manifest.id)) == Set(created.suffix(3).map(\.id)))
    // 最旧的已被清理。
    #expect(!records.contains { $0.manifest.id == created[0].id })

    let removedCount = try store.deleteAllSnapshots(vaultID: "vault-retention")
    #expect(removedCount == 3)
    #expect(try store.listSnapshots(vaultID: "vault-retention").isEmpty)

    // 保险库本体不受清理影响。
    let reopened = try engine.openVault(at: vaultURL, password: "retention 123!", deviceID: "retention-device")
    engine.closeVault(reopened)
}

// MARK: - 辅助

private func makeTemporaryDirectory(prefix: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeRepository(
    engine: MDBXLocalVaultEngine,
    vaultURL: URL,
    displayName: String,
    handle: LocalVaultHandle
) -> LocalVaultEntryRepository {
    LocalVaultEntryRepository(
        session: LocalVaultSession(
            descriptor: LocalVaultDescriptor(fileURL: vaultURL, displayName: displayName),
            handle: handle,
            state: .unlocked
        ),
        engine: engine
    )
}

/// 用搜索投影构造快照索引：和生产代码走同一条路径（全部类型枚举 → 文档 → 指纹）。
private func makeIndex(
    repository: LocalVaultEntryRepository,
    projects: [VaultSnapshotProject]
) throws -> VaultSnapshotIndex {
    var snapshot = VaultSearchEntrySnapshot()
    for project in projects {
        let projectID = project.id
        snapshot.loginEntries += (try? repository.listLoginEntries(projectID: projectID)) ?? []
        snapshot.deletedLoginEntries += (try? repository.listDeletedLoginEntries(projectID: projectID)) ?? []
        snapshot.noteEntries += (try? repository.listNoteEntries(projectID: projectID)) ?? []
        snapshot.deletedNoteEntries += (try? repository.listDeletedNoteEntries(projectID: projectID)) ?? []
        snapshot.totpEntries += (try? repository.listTotpEntries(projectID: projectID)) ?? []
        snapshot.deletedTotpEntries += (try? repository.listDeletedTotpEntries(projectID: projectID)) ?? []
        snapshot.cardEntries += (try? repository.listCardEntries(projectID: projectID)) ?? []
        snapshot.deletedCardEntries += (try? repository.listDeletedCardEntries(projectID: projectID)) ?? []
        snapshot.identityEntries += (try? repository.listIdentityEntries(projectID: projectID)) ?? []
        snapshot.deletedIdentityEntries += (try? repository.listDeletedIdentityEntries(projectID: projectID)) ?? []
        snapshot.passkeyEntries += (try? repository.listPasskeyEntries(projectID: projectID)) ?? []
        snapshot.deletedPasskeyEntries += (try? repository.listDeletedPasskeyEntries(projectID: projectID)) ?? []
        snapshot.sshKeyEntries += (try? repository.listSshKeyEntries(projectID: projectID)) ?? []
        snapshot.deletedSshKeyEntries += (try? repository.listDeletedSshKeyEntries(projectID: projectID)) ?? []
        snapshot.apiTokenEntries += (try? repository.listApiTokenEntries(projectID: projectID)) ?? []
        snapshot.deletedApiTokenEntries += (try? repository.listDeletedApiTokenEntries(projectID: projectID)) ?? []
        snapshot.wifiEntries += (try? repository.listWifiEntries(projectID: projectID)) ?? []
        snapshot.deletedWifiEntries += (try? repository.listDeletedWifiEntries(projectID: projectID)) ?? []
        snapshot.sendEntries += (try? repository.listSendEntries(projectID: projectID)) ?? []
        snapshot.deletedSendEntries += (try? repository.listDeletedSendEntries(projectID: projectID)) ?? []
        snapshot.steamEntries += (try? repository.listSteamEntries(projectID: projectID)) ?? []
        snapshot.deletedSteamEntries += (try? repository.listDeletedSteamEntries(projectID: projectID)) ?? []
        snapshot.attachmentEntries += (try? repository.listAttachmentMetadata(projectID: projectID)) ?? []
        snapshot.deletedAttachmentEntries += (try? repository.listDeletedAttachmentMetadata(projectID: projectID)) ?? []
    }

    let documents = VaultSearchDocumentBuilder.documents(from: snapshot)
    return VaultSnapshotIndexBuilder.index(projects: projects, documents: documents)
}

private struct FixedKeyProvider: VaultSnapshotKeyProviding {
    let key: Data
    func snapshotKey(forVaultID vaultID: String) throws -> Data { key }
}

private struct ThrowingFileWriter: VaultSnapshotFileWriting {
    struct WriteFailure: Error {}
    func write(_ data: Data, to url: URL) throws { throw WriteFailure() }
}
