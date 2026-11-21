import Foundation
import Testing

@testable import MonicaStorage

// MARK: - 固定时钟

private let trashReferenceDate = Date(timeIntervalSince1970: 1_800_000_000)

private func daysAgo(_ days: Double) -> Date {
    trashReferenceDate.addingTimeInterval(-days * 86_400)
}

private func makeTrashTestRepository(
    engine: RecordingVaultEngine
) throws -> (repository: LocalVaultEntryRepository, vaultID: String) {
    let vaultRepository = LocalVaultRepository(engine: engine)
    let session = try vaultRepository.createVault(
        named: "Trash",
        in: URL(fileURLWithPath: "/tmp/monica-storage-tests", isDirectory: true),
        password: "trash password 12345!",
        deviceID: "ios-trash-tests"
    )
    return (
        LocalVaultEntryRepository(session: session, engine: engine),
        session.handle.vaultID
    )
}

/// 第 N 次引擎级移动直接失败，用来验证批量迁移的回滚。
final class FailingMoveEngine: RecordingVaultEngine {
    var failOnMoveNumber: Int?
    private(set) var moveEntryCallCount = 0

    override func moveEntry(
        in handle: LocalVaultHandle,
        kind: UnifiedVaultItemKind,
        entryID: String,
        fromProjectID: String,
        toProjectID: String
    ) throws -> LocalVaultMovedEntry {
        moveEntryCallCount += 1
        if let failOnMoveNumber, moveEntryCallCount == failOnMoveNumber {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        return try super.moveEntry(
            in: handle,
            kind: kind,
            entryID: entryID,
            fromProjectID: fromProjectID,
            toProjectID: toProjectID
        )
    }
}

// MARK: - 保留策略

@Test func trashRetentionPolicyDefaultsToDisabledAutomaticPurge() {
    #expect(TrashRetentionPolicy.standard == .never)
    #expect(TrashRetentionPolicy.standard.retentionDays == nil)
    #expect(TrashRetentionPolicy.standard.retentionInterval == nil)
    #expect(!TrashRetentionPolicy.standard.isAutomaticPurgeEnabled)
    #expect(TrashRetentionPolicy.sevenDays.retentionDays == 7)
    #expect(TrashRetentionPolicy.thirtyDays.retentionDays == 30)
    #expect(TrashRetentionPolicy.ninetyDays.retentionDays == 90)
    #expect(TrashRetentionPolicy.never.retentionDays == nil)
    #expect(TrashRetentionPolicy.never.isAutomaticPurgeEnabled == false)
    #expect(TrashRetentionPolicy.thirtyDays.isAutomaticPurgeEnabled)
}

@Test func trashRetentionBoundaryOnlyPurgesItemsOlderThanThirtyDays() {
    let sixDays = TrashRetentionRecord(
        id: "six",
        kind: .login,
        projectID: "p1",
        title: "六天前删除",
        deletedAt: daysAgo(6)
    )
    let exactlyThirtyDays = TrashRetentionRecord(
        id: "thirty",
        kind: .note,
        projectID: "p1",
        title: "整三十天",
        deletedAt: daysAgo(30)
    )
    let thirtyOneDays = TrashRetentionRecord(
        id: "thirtyOne",
        kind: .card,
        projectID: "p1",
        title: "三十一天前",
        deletedAt: daysAgo(31)
    )

    let plan = TrashRetentionEvaluator.plan(
        records: [sixDays, exactlyThirtyDays, thirtyOneDays],
        policy: .thirtyDays,
        now: trashReferenceDate
    )

    #expect(plan.expired.map(\.id) == ["thirtyOne"])
    #expect(plan.retained.map(\.id) == ["six", "thirty"])
    #expect(plan.undated.isEmpty)
    #expect(plan.totalCount == 3)
    #expect(plan.expiredCount == 1)
    #expect(
        TrashRetentionEvaluator.isExpired(
            deletedAt: daysAgo(30),
            policy: .thirtyDays,
            now: trashReferenceDate
        ) == false
    )
    #expect(
        TrashRetentionEvaluator.isExpired(
            deletedAt: daysAgo(30).addingTimeInterval(-1),
            policy: .thirtyDays,
            now: trashReferenceDate
        )
    )
}

@Test func trashRetentionPolicySwitchesApplyToTheSameDeletionTime() {
    let record = TrashRetentionRecord(
        id: "note-1",
        kind: .note,
        projectID: "p1",
        title: "季度复盘",
        deletedAt: daysAgo(40)
    )

    #expect(
        TrashRetentionEvaluator.plan(
            records: [record],
            policy: .sevenDays,
            now: trashReferenceDate
        ).expiredCount == 1
    )
    #expect(
        TrashRetentionEvaluator.plan(
            records: [record],
            policy: .ninetyDays,
            now: trashReferenceDate
        ).expiredCount == 0
    )
    #expect(
        TrashRetentionEvaluator.plan(
            records: [record],
            policy: .never,
            now: trashReferenceDate
        ).expiredCount == 0
    )
    #expect(
        TrashRetentionEvaluator.expirationDate(
            deletedAt: daysAgo(40),
            policy: .ninetyDays
        ) == daysAgo(40).addingTimeInterval(90 * 86_400)
    )
    #expect(
        TrashRetentionEvaluator.expirationDate(
            deletedAt: daysAgo(40),
            policy: .never
        ) == nil
    )
}

@Test func trashRetentionNeverPurgesItemsWithoutDeletionTime() {
    let legacy = TrashRetentionRecord(
        id: "legacy",
        kind: .login,
        projectID: "p1",
        title: "旧版本删除",
        deletedAt: nil
    )

    let plan = TrashRetentionEvaluator.plan(
        records: [legacy],
        policy: .sevenDays,
        now: trashReferenceDate
    )

    #expect(plan.expired.isEmpty)
    #expect(plan.retained.isEmpty)
    #expect(plan.undated.map(\.id) == ["legacy"])
    #expect(plan.totalCount == 1)
}

@Test func trashLedgerTracksDeletionRestoreAndPurge() {
    var ledger = TrashLedger()
    ledger.recordDeletion(
        itemID: "login-1",
        kind: .login,
        projectID: "p1",
        title: "GitHub",
        at: daysAgo(31)
    )

    #expect(ledger.deletedAt(for: "login-1") == daysAgo(31))
    #expect(ledger.isPurged("login-1") == false)
    #expect(ledger.record(for: "login-1")?.itemKind == .login)

    ledger.markPurged(itemIDs: ["login-1"], at: trashReferenceDate)
    #expect(ledger.isPurged("login-1"))
    #expect(ledger.purgedItemIDs == ["login-1"])

    // 清理后再次删除（用户先恢复再删除）应该重新开始计时，并清掉旧的清理标记。
    ledger.recordDeletion(
        itemID: "login-1",
        kind: .login,
        projectID: "p1",
        title: "GitHub",
        at: trashReferenceDate
    )
    #expect(ledger.isPurged("login-1") == false)
    #expect(ledger.deletedAt(for: "login-1") == trashReferenceDate)

    ledger.markRestored(itemID: "login-1")
    #expect(ledger.record(for: "login-1") == nil)
}

@Test func trashLedgerPrunesOnlyOldPurgedRecords() {
    var ledger = TrashLedger()
    ledger.recordDeletion(itemID: "old", kind: .note, projectID: "p1", title: "旧", at: daysAgo(300))
    ledger.markPurged(itemIDs: ["old"], at: daysAgo(200))
    ledger.recordDeletion(itemID: "recent", kind: .note, projectID: "p1", title: "新", at: daysAgo(2))
    ledger.markPurged(itemIDs: ["recent"], at: daysAgo(1))
    ledger.recordDeletion(itemID: "pending", kind: .note, projectID: "p1", title: "待清理", at: daysAgo(40))

    let removed = ledger.prunePurgedRecords(olderThan: daysAgo(30))

    #expect(removed == 1)
    #expect(ledger.record(for: "old") == nil)
    #expect(ledger.record(for: "recent") != nil)
    #expect(ledger.record(for: "pending") != nil)
}

// MARK: - 加密账本

@Test func trashLedgerStoreEncryptsTitlesOnDiskAndRoundTrips() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("monica-trash-ledger-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let key = Data(repeating: 0x42, count: 32)
    let store = TrashLedgerStore(
        directoryURL: directory,
        keyProvider: try StaticTrashLedgerKeyProvider(key: key)
    )

    var ledger = TrashLedger()
    ledger.recordDeletion(
        itemID: "login-1",
        kind: .login,
        projectID: "p1",
        title: "GitHub 主账号",
        at: daysAgo(31)
    )
    try store.saveLedger(ledger, vaultID: "vault-1")

    let fileURL = try store.ledgerFileURL(vaultID: "vault-1")
    let raw = try Data(contentsOf: fileURL)
    #expect(raw.prefix(TrashLedgerStore.magic.count) == TrashLedgerStore.magic)
    #expect(raw.range(of: Data("GitHub".utf8)) == nil)
    #expect(raw.range(of: Data("login-1".utf8)) == nil)
    #expect(try store.loadLedger(vaultID: "vault-1") == ledger)
    #expect(try store.hasLedger(vaultID: "vault-1"))

    // 换密钥读取必须报错，不能把损坏内容当成空账本。
    let otherStore = TrashLedgerStore(
        directoryURL: directory,
        keyProvider: try StaticTrashLedgerKeyProvider(key: Data(repeating: 0x24, count: 32))
    )
    #expect(throws: TrashLedgerStoreError.authenticationFailed) {
        _ = try otherStore.loadLedger(vaultID: "vault-1")
    }

    try store.deleteLedger(vaultID: "vault-1")
    #expect(try store.hasLedger(vaultID: "vault-1") == false)
    #expect(try store.loadLedger(vaultID: "vault-1") == TrashLedger())
}

@Test func trashLedgerStoreRejectsCorruptedFilesAndMissingVaultIDs() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("monica-trash-ledger-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = TrashLedgerStore(
        directoryURL: directory,
        keyProvider: try StaticTrashLedgerKeyProvider(key: Data(repeating: 0x11, count: 32))
    )

    #expect(throws: TrashLedgerStoreError.invalidVaultIdentifier) {
        _ = try store.ledgerFileURL(vaultID: "   ")
    }

    let fileURL = try store.ledgerFileURL(vaultID: "vault-1")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("not a ledger".utf8).write(to: fileURL)

    #expect(throws: TrashLedgerStoreError.corrupted) {
        _ = try store.loadLedger(vaultID: "vault-1")
    }
}

// MARK: - 批量迁移

@Test func batchMoveMovesEntriesWithExtrasAndAttachmentReferences() throws {
    let engine = RecordingVaultEngine()
    let (repository, _) = try makeTrashTestRepository(engine: engine)
    let source = try repository.createProject(title: "个人")
    let target = try repository.createProject(title: "工作")

    var items: [VaultBatchMigrationItem] = []
    var attachmentIDs: [String] = []
    for index in 0..<3 {
        let entry = try repository.createLoginEntry(
            projectID: source.id,
            draft: LocalLoginEntryDraft(
                title: "站点 \(index)",
                username: "user\(index)",
                password: "password-\(index)",
                url: "https://example\(index).com"
            )
        )
        _ = try repository.saveItemExtras(
            projectID: source.id,
            extras: VaultItemExtras(
                itemID: entry.id,
                itemKind: .login,
                customFields: [
                    VaultCustomField(label: "备注", kind: .text, value: "字段 \(index)")
                ]
            )
        )
        let attachment = try repository.createAttachmentMetadata(
            projectID: source.id,
            entryID: entry.id,
            fileName: "file-\(index).pdf",
            mediaType: "application/pdf",
            originalSize: 1024,
            storedSize: 512,
            contentHash: "hash-\(index)",
            storageMode: "local",
            source: "test",
            downloadState: "downloaded",
            wrappedContentEncryptionKey: nil,
            localPath: nil
        )
        attachmentIDs.append(attachment.id)
        items.append(VaultBatchMigrationItem(id: entry.id, kind: .login, title: entry.title))
    }

    let outcome = try repository.moveEntries(
        items,
        fromProjectID: source.id,
        toProjectID: target.id
    )

    #expect(outcome.movedCount == 3)
    #expect(Set(outcome.movedAttachmentIDs) == Set(attachmentIDs))
    #expect(Set(outcome.movedExtrasItemIDs) == Set(items.map(\.id)))
    #expect(try repository.listLoginEntries(projectID: source.id).isEmpty)
    let movedEntries = try repository.listLoginEntries(projectID: target.id)
    #expect(Set(movedEntries.map(\.id)) == Set(items.map(\.id)))
    #expect(movedEntries.allSatisfy { $0.projectID == target.id })

    let targetExtras = try repository.listItemExtras(projectID: target.id)
    #expect(Set(targetExtras.keys) == Set(items.map(\.id)))
    #expect(try repository.listItemExtras(projectID: source.id).isEmpty)

    let targetAttachments = try repository.listAttachmentMetadata(projectID: target.id)
    #expect(Set(targetAttachments.map(\.id)) == Set(attachmentIDs))
    #expect(targetAttachments.allSatisfy { $0.entryID != nil && $0.deleted == false })
    #expect(try repository.listAttachmentMetadata(projectID: source.id).isEmpty)
}

@Test func batchMoveRollsBackWhenFifthMoveFails() throws {
    let engine = FailingMoveEngine()
    engine.failOnMoveNumber = 5
    let (repository, _) = try makeTrashTestRepository(engine: engine)
    let source = try repository.createProject(title: "个人")
    let target = try repository.createProject(title: "工作")

    var items: [VaultBatchMigrationItem] = []
    for index in 0..<10 {
        let entry = try repository.createLoginEntry(
            projectID: source.id,
            draft: LocalLoginEntryDraft(
                title: "条目 \(index)",
                username: "user\(index)",
                password: "password-\(index)",
                url: "https://example.com/\(index)"
            )
        )
        items.append(VaultBatchMigrationItem(id: entry.id, kind: .login, title: entry.title))
    }

    var captured: VaultBatchMigrationFailure?
    do {
        _ = try repository.moveEntries(
            items,
            fromProjectID: source.id,
            toProjectID: target.id
        )
        Issue.record("第 5 条失败时应该抛出迁移失败")
    } catch let failure as VaultBatchMigrationFailure {
        captured = failure
    }

    let failure = try #require(captured)
    #expect(failure.failedIndex == 4)
    #expect(failure.failedItemTitle == "条目 4")
    #expect(failure.movedBeforeFailure == 4)
    #expect(failure.rolledBackCount == 4)
    #expect(failure.rollbackFailures.isEmpty)
    #expect(failure.errorDescription?.contains("源分类数据保持完整") == true)
    #expect(try repository.listLoginEntries(projectID: source.id).count == 10)
    #expect(try repository.listLoginEntries(projectID: target.id).isEmpty)
}

@Test func batchMovePrecheckRejectsUnavailableItemsBeforeMovingAnything() throws {
    let engine = FailingMoveEngine()
    let (repository, _) = try makeTrashTestRepository(engine: engine)
    let source = try repository.createProject(title: "个人")
    let target = try repository.createProject(title: "工作")

    let entry = try repository.createLoginEntry(
        projectID: source.id,
        draft: LocalLoginEntryDraft(
            title: "存在的条目",
            username: "user",
            password: "password",
            url: "https://example.com"
        )
    )

    var captured: VaultBatchMigrationPrecheckError?
    do {
        _ = try repository.moveEntries(
            [
                VaultBatchMigrationItem(id: entry.id, kind: .login, title: entry.title),
                VaultBatchMigrationItem(id: "ghost", kind: .login, title: "不存在的条目")
            ],
            fromProjectID: source.id,
            toProjectID: target.id
        )
        Issue.record("预检应该拒绝不可用的条目")
    } catch let error as VaultBatchMigrationPrecheckError {
        captured = error
    }

    guard case .unavailableItems(let titles) = try #require(captured) else {
        Issue.record("应返回 unavailableItems")
        return
    }
    #expect(titles.contains { $0.contains("不存在的条目") })
    #expect(engine.moveEntryCallCount == 0)
    #expect(try repository.listLoginEntries(projectID: source.id).count == 1)
}

@Test func batchMovePrecheckRejectsUnknownTargetAndDuplicateIDs() throws {
    let engine = FailingMoveEngine()
    let (repository, _) = try makeTrashTestRepository(engine: engine)
    let source = try repository.createProject(title: "个人")
    let target = try repository.createProject(title: "工作")
    let entry = try repository.createLoginEntry(
        projectID: source.id,
        draft: LocalLoginEntryDraft(
            title: "条目",
            username: "user",
            password: "password",
            url: "https://example.com"
        )
    )

    #expect(throws: VaultBatchMigrationPrecheckError.projectUnavailable("missing")) {
        _ = try repository.moveEntries(
            [VaultBatchMigrationItem(id: entry.id, kind: .login, title: entry.title)],
            fromProjectID: source.id,
            toProjectID: "missing"
        )
    }
    #expect(throws: VaultBatchMigrationPrecheckError.sameProject) {
        _ = try repository.moveEntries(
            [VaultBatchMigrationItem(id: entry.id, kind: .login, title: entry.title)],
            fromProjectID: source.id,
            toProjectID: source.id
        )
    }
    #expect(throws: VaultBatchMigrationPrecheckError.emptySelection) {
        _ = try repository.moveEntries(
            [],
            fromProjectID: source.id,
            toProjectID: source.id
        )
    }
    #expect(throws: VaultBatchMigrationPrecheckError.duplicateItemIDs([entry.id])) {
        _ = try repository.moveEntries(
            [
                VaultBatchMigrationItem(id: entry.id, kind: .login, title: entry.title),
                VaultBatchMigrationItem(id: entry.id, kind: .note, title: entry.title)
            ],
            fromProjectID: source.id,
            toProjectID: target.id
        )
    }
    #expect(engine.moveEntryCallCount == 0)
}

// MARK: - 永久清理

@Test func purgeOnlyRemovesDeletedEntriesAndSkipsRestoredOnes() throws {
    let engine = RecordingVaultEngine()
    let (repository, _) = try makeTrashTestRepository(engine: engine)
    let project = try repository.createProject(title: "个人")

    var deleted: [LocalLoginEntry] = []
    for index in 0..<3 {
        let entry = try repository.createLoginEntry(
            projectID: project.id,
            draft: LocalLoginEntryDraft(
                title: "待删除 \(index)",
                username: "user\(index)",
                password: "password-\(index)",
                url: "https://example.com/\(index)"
            )
        )
        try repository.deleteLoginEntry(projectID: project.id, entryID: entry.id)
        deleted.append(entry)
    }
    _ = try repository.restoreLoginEntry(projectID: project.id, entryID: deleted[2].id)

    let records = try repository.listTrashEntries(projectID: project.id)
    #expect(records.count == 2)

    let outcome = repository.purgeTrashEntries(records + [
        TrashRetentionRecord(id: "never-existed", kind: .login, projectID: project.id, title: "幽灵")
    ])

    #expect(outcome.purgedCount == 2)
    #expect(Set(outcome.purgedItemIDs) == Set([deleted[0].id, deleted[1].id]))
    #expect(outcome.skipped.count == 1)
    #expect(outcome.skipped.first?.record.id == "never-existed")
    #expect(outcome.failures.isEmpty)
    #expect(outcome.wasCancelled == false)
    // 恢复过的条目仍然在活动列表里，没有被清理。
    #expect(try repository.listLoginEntries(projectID: project.id).contains { $0.id == deleted[2].id })
}

@Test func purgeRemovesExtrasAndAttachmentReferences() throws {
    let engine = RecordingVaultEngine()
    let (repository, _) = try makeTrashTestRepository(engine: engine)
    let project = try repository.createProject(title: "个人")

    let entry = try repository.createLoginEntry(
        projectID: project.id,
        draft: LocalLoginEntryDraft(
            title: "带附件",
            username: "user",
            password: "password",
            url: "https://example.com"
        )
    )
    _ = try repository.saveItemExtras(
        projectID: project.id,
        extras: VaultItemExtras(
            itemID: entry.id,
            itemKind: .login,
            customFields: [VaultCustomField(label: "备份码", kind: .hiddenText, value: "123456")]
        )
    )
    let attachment = try repository.createAttachmentMetadata(
        projectID: project.id,
        entryID: entry.id,
        fileName: "recovery.pdf",
        mediaType: "application/pdf",
        originalSize: 1024,
        storedSize: 512,
        contentHash: "hash",
        storageMode: "local",
        source: "test",
        downloadState: "downloaded",
        wrappedContentEncryptionKey: nil,
        localPath: nil
    )

    try repository.deleteLoginEntry(projectID: project.id, entryID: entry.id)
    let records = try repository.listTrashEntries(projectID: project.id)
    #expect(records.count == 1)

    let outcome = repository.purgeTrashEntries(records)

    #expect(outcome.purgedItemIDs == [entry.id])
    #expect(outcome.purgedAttachmentIDs == [attachment.id])
    #expect(outcome.failures.isEmpty)
    #expect(try repository.listItemExtras(projectID: project.id).isEmpty)
    #expect(try repository.listAttachmentMetadata(projectID: project.id).isEmpty)
}

@Test func purgeStopsBetweenItemsWhenCancelled() throws {
    let engine = RecordingVaultEngine()
    let (repository, _) = try makeTrashTestRepository(engine: engine)
    let project = try repository.createProject(title: "个人")

    for index in 0..<3 {
        let entry = try repository.createLoginEntry(
            projectID: project.id,
            draft: LocalLoginEntryDraft(
                title: "待清理 \(index)",
                username: "user\(index)",
                password: "password",
                url: "https://example.com/\(index)"
            )
        )
        try repository.deleteLoginEntry(projectID: project.id, entryID: entry.id)
    }
    let records = try repository.listTrashEntries(projectID: project.id)

    var checks = 0
    let outcome = repository.purgeTrashEntries(records) {
        checks += 1
        return checks <= 1
    }

    #expect(outcome.wasCancelled)
    #expect(outcome.purgedCount == 1)
    #expect(outcome.failures.isEmpty)
}
