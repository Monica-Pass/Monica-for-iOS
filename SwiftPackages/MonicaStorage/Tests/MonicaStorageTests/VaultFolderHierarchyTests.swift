import Foundation
import Testing

@testable import MonicaStorage

// MARK: - 命名规则固定向量

@Suite struct VaultFolderNameRulesTests {
    @Test func acceptsOrdinaryNamesAndTrimsWhitespace() throws {
        #expect(try VaultFolderNameRules.normalizedName("  工作  ") == "工作")
        #expect(try VaultFolderNameRules.normalizedName("多层 目录 2026") == "多层 目录 2026")
        #expect(try VaultFolderNameRules.normalizedName("emoji 🗂️ 目录") == "emoji 🗂️ 目录")
    }

    @Test func rejectsEmptyName() throws {
        #expect(throws: VaultFolderError.emptyName) {
            _ = try VaultFolderNameRules.normalizedName("   ")
        }
        #expect(throws: VaultFolderError.emptyName) {
            _ = try VaultFolderNameRules.normalizedName("\n\t")
        }
    }

    @Test func rejectsPathSeparators() throws {
        for name in ["a/b", "a\\b", "/abs", "\\abs"] {
            #expect(throws: VaultFolderError.self) {
                _ = try VaultFolderNameRules.normalizedName(name)
            }
        }
    }

    @Test func rejectsDotDotAndDot() throws {
        #expect(throws: VaultFolderError.invalidName(reason: .relativePathSegment)) {
            _ = try VaultFolderNameRules.normalizedName("..")
        }
        #expect(throws: VaultFolderError.invalidName(reason: .relativePathSegment)) {
            _ = try VaultFolderNameRules.normalizedName(".")
        }
    }

    @Test func rejectsControlCharactersAndNul() throws {
        #expect(throws: VaultFolderError.invalidName(reason: .controlCharacter)) {
            _ = try VaultFolderNameRules.normalizedName("换\n行")
        }
        #expect(throws: VaultFolderError.invalidName(reason: .nullCharacter)) {
            _ = try VaultFolderNameRules.normalizedName("空\0字符")
        }
    }

    @Test func rejectsTooLongName() throws {
        let long = String(repeating: "目", count: VaultFolderNameRules.maxNameLength + 1)
        #expect(throws: VaultFolderError.nameTooLong(limit: VaultFolderNameRules.maxNameLength)) {
            _ = try VaultFolderNameRules.normalizedName(long)
        }
        let boundary = String(repeating: "目", count: VaultFolderNameRules.maxNameLength)
        #expect(try VaultFolderNameRules.normalizedName(boundary) == boundary)
    }
}

// MARK: - 树的清洗与遍历

@Suite struct VaultFolderTreeTests {
    private func record(
        _ id: String,
        parent: String?,
        title: String,
        order: Int = 0,
        updated: TimeInterval = 1
    ) -> VaultFolderRecord {
        VaultFolderRecord(
            folderID: id,
            parentID: parent,
            title: title,
            sortOrder: order,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: updated)
        )
    }

    @Test func buildsNestedPathsForThreeLevels() throws {
        let tree = VaultFolderTree(records: [
            record("a", parent: nil, title: "A", order: 0),
            record("b", parent: "a", title: "B", order: 0),
            record("c", parent: "b", title: "C", order: 0)
        ])

        #expect(tree.rootFolders.map(\.id) == ["a"])
        #expect(tree.children(of: "a").map(\.id) == ["b"])
        #expect(tree.path(to: "c").map(\.title) == ["A", "B", "C"])
        #expect(tree.displayPath(to: "c") == "A / B / C")
        #expect(tree.depth(of: "c") == 3)
        #expect(tree.descendants(of: "a").map(\.id) == ["b", "c"])
    }

    @Test func sameNamedFoldersInDifferentParentsStayDistinct() throws {
        let tree = VaultFolderTree(records: [
            record("a", parent: nil, title: "工作"),
            record("b", parent: nil, title: "个人"),
            record("a-child", parent: "a", title: "归档"),
            record("b-child", parent: "b", title: "归档")
        ])

        #expect(tree.displayPath(to: "a-child") == "工作 / 归档")
        #expect(tree.displayPath(to: "b-child") == "个人 / 归档")
        #expect(tree.folder(id: "a-child")?.parentID == "a")
        #expect(tree.folder(id: "b-child")?.parentID == "b")
    }

    @Test func orphanNodesArePromotedToRoot() throws {
        let tree = VaultFolderTree(records: [
            record("lost", parent: "missing-parent", title: "孤儿")
        ])

        #expect(tree.rootFolders.map(\.id) == ["lost"])
        #expect(tree.folder(id: "lost")?.parentID == nil)
    }

    @Test func selfParentIsPromotedToRoot() throws {
        let tree = VaultFolderTree(records: [
            record("self", parent: "self", title: "自引用")
        ])
        #expect(tree.rootFolders.map(\.id) == ["self"])
    }

    @Test func cyclesAreBrokenWithoutHanging() throws {
        // a → b → c → a 的三节点环
        let tree = VaultFolderTree(records: [
            record("a", parent: "c", title: "A"),
            record("b", parent: "a", title: "B"),
            record("c", parent: "b", title: "C")
        ])

        #expect(tree.folders.count == 3)
        #expect(tree.rootFolders.count == 1)
        // 每个节点的路径长度都有限，遍历不会无限递归
        for folder in tree.folders {
            #expect(tree.path(to: folder.id).count <= 3)
            #expect(tree.depth(of: folder.id) >= 1)
        }
    }

    @Test func duplicateFolderIDsKeepLatestRecord() throws {
        let tree = VaultFolderTree(records: [
            record("dup", parent: nil, title: "旧名", updated: 10),
            record("dup", parent: nil, title: "新名", updated: 20)
        ])

        #expect(tree.folders.count == 1)
        #expect(tree.folder(id: "dup")?.title == "新名")
    }

    @Test func blankLegacyTitleFallsBackToPlaceholder() throws {
        let tree = VaultFolderTree(records: [
            record("blank", parent: nil, title: "   ")
        ])
        #expect(tree.folder(id: "blank")?.title == "未命名文件夹")
    }

    @Test func rejectsMovingFolderIntoItselfOrDescendant() throws {
        let tree = VaultFolderTree(records: [
            record("a", parent: nil, title: "A"),
            record("b", parent: "a", title: "B"),
            record("c", parent: "b", title: "C")
        ])

        #expect(tree.canMove(folderID: "a", to: "a") == false)
        #expect(tree.canMove(folderID: "a", to: "c") == false)
        #expect(tree.canMove(folderID: "c", to: "a") == true)
        #expect(tree.canMove(folderID: "c", to: nil) == true)
    }

    @Test func depthLimitBlocksDeepMoves() throws {
        var records: [VaultFolderRecord] = [record("root", parent: nil, title: "根")]
        var parent: String? = "root"
        for level in 2...(VaultFolderNameRules.maxDepth - 1) {
            let id = "n\(level)"
            records.append(record(id, parent: parent, title: "第\(level)层"))
            parent = id
        }
        // 另有一棵两层高的子树，整棵挪到第 7 层会超过上限
        records.append(record("u", parent: nil, title: "待移动"))
        records.append(record("v", parent: "u", title: "待移动子级"))
        let tree = VaultFolderTree(records: records)
        let deepest = "n\(VaultFolderNameRules.maxDepth - 1)"
        #expect(tree.depth(of: deepest) == VaultFolderNameRules.maxDepth - 1)
        #expect(tree.canMove(folderID: "u", to: deepest) == false)
        // 单层目录刚好还能落在最后一层
        #expect(tree.canMove(folderID: "v", to: deepest) == true)
        // 但把自己挪到自己的后代会直接成环
        #expect(tree.canMove(folderID: "root", to: "v") == false)
    }

    @Test func siblingLookupIgnoresCaseAndExcludesSelf() throws {
        let tree = VaultFolderTree(records: [
            record("a", parent: nil, title: "Work"),
            record("b", parent: nil, title: "Personal")
        ])
        #expect(tree.hasSibling(named: "work", parentID: nil) == true)
        #expect(tree.hasSibling(named: "work", parentID: nil, excluding: "a") == false)
        #expect(tree.hasSibling(named: "work", parentID: "b") == false)
    }
}

// MARK: - 侧表 payload 兼容性

@Suite struct VaultFolderRecordPayloadTests {
    @Test func roundTripsAllFields() throws {
        let record = VaultFolderRecord(
            folderID: "folder-1",
            parentID: "folder-0",
            title: "工作",
            sortOrder: 3,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let json = try record.payloadJSONString()
        let decoded = try #require(VaultFolderRecord(payloadJSON: json, fallbackFolderID: "fallback"))

        #expect(decoded.folderID == "folder-1")
        #expect(decoded.parentID == "folder-0")
        #expect(decoded.title == "工作")
        #expect(decoded.sortOrder == 3)
        #expect(abs(decoded.updatedAt.timeIntervalSince1970 - 1_700_000_100) < 0.001)
    }

    @Test func decodesLegacyPayloadWithoutNewFields() throws {
        let json = #"{"folderID":"legacy-1","title":"旧文件夹"}"#
        let decoded = try #require(VaultFolderRecord(payloadJSON: json, fallbackFolderID: "fallback"))

        #expect(decoded.folderID == "legacy-1")
        #expect(decoded.parentID == nil)
        #expect(decoded.title == "旧文件夹")
        #expect(decoded.sortOrder == 0)
        #expect(decoded.schemaVersion == VaultFolderRecord.currentSchemaVersion)
    }

    @Test func ignoresUnknownFieldsAndBadTypes() throws {
        let json = #"{"folderID":"f","parentID":42,"title":"T","future":"x","sortOrder":"no"}"#
        let decoded = try #require(VaultFolderRecord(payloadJSON: json, fallbackFolderID: "fallback"))
        #expect(decoded.folderID == "f")
        #expect(decoded.sortOrder == 0)
    }

    @Test func fallsBackToEntryTitleWhenPayloadIsCorrupt() throws {
        let decoded = try #require(VaultFolderRecord(payloadJSON: "not-json", fallbackFolderID: "entry-title"))
        #expect(decoded.folderID == "entry-title")
        #expect(VaultFolderRecord(payloadJSON: "not-json", fallbackFolderID: "") == nil)
    }

    @Test func emptyParentIDIsTreatedAsRoot() throws {
        let json = #"{"folderID":"f","parentID":"","title":"根"}"#
        let decoded = try #require(VaultFolderRecord(payloadJSON: json, fallbackFolderID: "fallback"))
        #expect(decoded.parentID == nil)
    }
}

// MARK: - 总览统计

@Suite struct VaultFolderOverviewTests {
    private func document(
        _ id: String,
        kind: UnifiedVaultItemKind,
        favorite: Bool = false,
        deleted: Bool = false,
        viewedAt: TimeInterval? = nil
    ) -> VaultSearchDocument {
        VaultSearchDocument(
            kind: kind,
            id: id,
            projectID: "p",
            title: id,
            isFavorite: favorite,
            isDeleted: deleted,
            lastViewedAt: viewedAt.map { Date(timeIntervalSince1970: $0) }
        )
    }

    @Test func countsByKindFavoritesAndTrash() throws {
        let documents = [
            document("l1", kind: .login, favorite: true),
            document("l2", kind: .login),
            document("l3", kind: .login, deleted: true),
            document("n1", kind: .note),
            document("s1", kind: .sso, favorite: true)
        ]
        let overview = VaultFolderOverview.builder(documents: documents, tree: .empty)

        #expect(overview.totalActiveEntries == 4)
        #expect(overview.totalFavorites == 2)
        #expect(overview.totalTrashedEntries == 1)

        let login = overview.kindCounts.first { $0.kind == .login }
        #expect(login?.activeCount == 2)
        #expect(login?.favoriteCount == 1)
        #expect(login?.trashedCount == 1)
        #expect(overview.kindCounts.first { $0.kind == .sso }?.activeCount == 1)
        // 每一类都要有行，UI 才能稳定展示 12 类
        #expect(overview.kindCounts.count == UnifiedVaultItemKind.allCases.count)
    }

    @Test func recentItemsAreOrderedAndLimited() throws {
        let documents = [
            document("old", kind: .login, viewedAt: 100),
            document("new", kind: .note, viewedAt: 300),
            document("mid", kind: .card, viewedAt: 200),
            document("never", kind: .totp)
        ]
        let overview = VaultFolderOverview.builder(documents: documents, tree: .empty, recentLimit: 2)
        #expect(overview.recentDocuments.map(\.id) == ["new", "mid"])
    }

    @Test func countsFoldersAndDepth() throws {
        let tree = VaultFolderTree(records: [
            VaultFolderRecord(folderID: "a", parentID: nil, title: "A"),
            VaultFolderRecord(folderID: "b", parentID: "a", title: "B"),
            VaultFolderRecord(folderID: "c", parentID: nil, title: "C")
        ])
        let overview = VaultFolderOverview.builder(documents: [], tree: tree)
        #expect(overview.rootFolderCount == 2)
        #expect(overview.nestedFolderCount == 1)
        #expect(overview.deepestLevel == 2)
        #expect(overview.isEmpty == false)
    }

    @Test func emptyVaultIsReportedAsEmpty() throws {
        let overview = VaultFolderOverview.builder(documents: [], tree: .empty)
        #expect(overview.isEmpty)
        #expect(overview.totalFolderCount == 0)
        #expect(overview.recentDocuments.isEmpty)
    }
}

// MARK: - 真引擎集成（MDBX）

@Suite(.serialized) struct VaultFolderRepositoryTests {
    private let password = "文件夹 password 12345!"
    private let deviceID = "vault-folder-tests"

    /// 每个测试独占一个目录，避免并行用例共用同一个 vault 文件。
    private func temporaryVaultURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-folder-\(UUID().uuidString)", isDirectory: true)
    }

    private func vaultFileURL(in directory: URL) -> URL {
        directory.appendingPathComponent("Folders.mdbx", isDirectory: false)
    }

    private func makeVault(
        at url: URL,
        anchorStore: any VaultFolderAnchorStore
    ) throws -> (session: LocalVaultSession, entries: LocalVaultEntryRepository) {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let engine = MDBXLocalVaultEngine()
        let vaultRepository = LocalVaultRepository(engine: engine)
        let session = try vaultRepository.createVault(
            named: "Folders",
            in: url,
            password: password,
            deviceID: deviceID
        )
        let entries = LocalVaultEntryRepository(session: session, engine: engine)
        _ = anchorStore
        return (session, entries)
    }

    private func reopen(
        at url: URL,
        anchorStore: any VaultFolderAnchorStore
    ) throws -> (session: LocalVaultSession, entries: LocalVaultEntryRepository) {
        let engine = MDBXLocalVaultEngine()
        let vaultRepository = LocalVaultRepository(engine: engine)
        let session = try vaultRepository.openVault(
            at: vaultFileURL(in: url),
            password: password,
            deviceID: deviceID
        )
        _ = anchorStore
        return (session, LocalVaultEntryRepository(session: session, engine: engine))
    }

    @Test func createsThreeLevelsAndKeepsThemAfterReopen() throws {
        let url = temporaryVaultURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let anchorStore = InMemoryVaultFolderAnchorStore()

        var created: [String] = []
        do {
            let (session, entries) = try makeVault(at: url, anchorStore: anchorStore)
            let folders = VaultFolderRepository(
                entryRepository: entries,
                session: session,
                anchorStore: anchorStore
            )
            let a = try folders.createFolder(title: "A", parentID: nil)
            let b = try folders.createFolder(title: "B", parentID: a.id)
            let c = try folders.createFolder(title: "C", parentID: b.id)
            created = [a.id, b.id, c.id]

            let tree = try folders.tree()
            #expect(tree.displayPath(to: c.id) == "A / B / C")

            let login = try entries.createLoginEntry(
                projectID: c.id,
                draft: LocalLoginEntryDraft(title: "GitHub", username: "octocat", password: "pw", url: "https://github.com")
            )
            #expect(login.projectID == c.id)
        }

        // 模拟 App 重启：新引擎实例 + 同一个锚点
        let (session, entries) = try reopen(at: url, anchorStore: anchorStore)
        let folders = VaultFolderRepository(
            entryRepository: entries,
            session: session,
            anchorStore: anchorStore
        )
        let tree = try folders.tree()

        #expect(tree.folders.count == 3)
        #expect(tree.displayPath(to: created[2]) == "A / B / C")
        #expect(try entries.listLoginEntries(projectID: created[2]).map(\.title) == ["GitHub"])
    }

    @Test func legacyProjectsBecomeRootFolders() throws {
        let url = temporaryVaultURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let anchorStore = InMemoryVaultFolderAnchorStore()

        let (session, entries) = try makeVault(at: url, anchorStore: anchorStore)
        let personal = try entries.createProject(title: "个人")
        let work = try entries.createProject(title: "工作")

        let folders = VaultFolderRepository(
            entryRepository: entries,
            session: session,
            anchorStore: anchorStore
        )
        let tree = try folders.tree()

        #expect(Set(tree.rootFolders.map(\.id)) == Set([personal.id, work.id]))
        #expect(tree.folders.count == 2)
        // 锚点工程不能出现在用户的文件夹树里
        #expect(tree.folders.contains { $0.title == VaultFolderRepository.anchorProjectTitle } == false)
    }

    @Test func rejectsCyclesAndKeepsDataIntact() throws {
        let url = temporaryVaultURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let anchorStore = InMemoryVaultFolderAnchorStore()

        let (session, entries) = try makeVault(at: url, anchorStore: anchorStore)
        let folders = VaultFolderRepository(
            entryRepository: entries,
            session: session,
            anchorStore: anchorStore
        )
        let a = try folders.createFolder(title: "A", parentID: nil)
        let b = try folders.createFolder(title: "B", parentID: a.id)
        let c = try folders.createFolder(title: "C", parentID: b.id)

        #expect(throws: VaultFolderError.cycleDetected) {
            _ = try folders.moveFolder(id: a.id, newParentID: c.id)
        }
        #expect(throws: VaultFolderError.cycleDetected) {
            _ = try folders.moveFolder(id: a.id, newParentID: a.id)
        }

        let tree = try folders.tree()
        #expect(tree.displayPath(to: c.id) == "A / B / C")
        #expect(tree.rootFolders.map(\.id) == [a.id])
    }

    @Test func movesSubtreeToRootAndKeepsEntriesOwnership() throws {
        let url = temporaryVaultURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let anchorStore = InMemoryVaultFolderAnchorStore()

        let (session, entries) = try makeVault(at: url, anchorStore: anchorStore)
        let folders = VaultFolderRepository(
            entryRepository: entries,
            session: session,
            anchorStore: anchorStore
        )
        let a = try folders.createFolder(title: "A", parentID: nil)
        let b = try folders.createFolder(title: "B", parentID: a.id)
        let c = try folders.createFolder(title: "C", parentID: b.id)
        _ = try entries.createLoginEntry(
            projectID: c.id,
            draft: LocalLoginEntryDraft(title: "在 C 里的条目", username: "u", password: "p", url: "")
        )

        _ = try folders.moveFolder(id: c.id, newParentID: nil)
        let tree = try folders.tree()
        #expect(tree.displayPath(to: c.id) == "C")
        #expect(tree.rootFolders.count == 2)
        #expect(try entries.listLoginEntries(projectID: c.id).map(\.title) == ["在 C 里的条目"])
    }

    @Test func sameNamedFoldersUnderDifferentParentsKeepEntriesSeparate() throws {
        let url = temporaryVaultURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let anchorStore = InMemoryVaultFolderAnchorStore()

        let (session, entries) = try makeVault(at: url, anchorStore: anchorStore)
        let folders = VaultFolderRepository(
            entryRepository: entries,
            session: session,
            anchorStore: anchorStore
        )
        let a = try folders.createFolder(title: "A", parentID: nil)
        let b = try folders.createFolder(title: "B", parentID: nil)
        let aWork = try folders.createFolder(title: "工作", parentID: a.id)
        let bWork = try folders.createFolder(title: "工作", parentID: b.id)
        // 同名不同父：两条路径必须各自独立，不能因为显示路径相同就串数据。
        #expect(aWork.id != bWork.id)
        #expect(try folders.tree().displayPath(to: aWork.id) == "A / 工作")
        #expect(try folders.tree().displayPath(to: bWork.id) == "B / 工作")

        _ = try entries.createLoginEntry(
            projectID: aWork.id,
            draft: LocalLoginEntryDraft(title: "A 的条目", username: "u", password: "p", url: "")
        )
        _ = try entries.createLoginEntry(
            projectID: bWork.id,
            draft: LocalLoginEntryDraft(title: "B 的条目", username: "u", password: "p", url: "")
        )
        #expect(try entries.listLoginEntries(projectID: aWork.id).map(\.title) == ["A 的条目"])
        #expect(try entries.listLoginEntries(projectID: bWork.id).map(\.title) == ["B 的条目"])
    }

    @Test func deletedFolderStaysDeletedAcrossReopen() throws {
        let url = temporaryVaultURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let anchorStore = InMemoryVaultFolderAnchorStore()

        let (session, entries) = try makeVault(at: url, anchorStore: anchorStore)
        let folders = VaultFolderRepository(
            entryRepository: entries,
            session: session,
            anchorStore: anchorStore
        )
        let a = try folders.createFolder(title: "临时", parentID: nil)
        _ = try entries.createLoginEntry(
            projectID: a.id,
            draft: LocalLoginEntryDraft(title: "会被移入回收站", username: "u", password: "p", url: "")
        )
        _ = try folders.deleteFolder(folderID: a.id, strategy: .recursiveTrash)
        #expect(try folders.tree().isEmpty)

        // 重启后不能把删掉的文件夹当成「旧分类」重新导入。
        let (reopenedSession, reopenedEntries) = try reopen(at: url, anchorStore: anchorStore)
        let reopenedFolders = VaultFolderRepository(
            entryRepository: reopenedEntries,
            session: reopenedSession,
            anchorStore: anchorStore
        )
        #expect(try reopenedFolders.tree().isEmpty)
        // 条目仍然在回收站里，没有被静默永久删除。
        #expect(try reopenedEntries.listDeletedLoginEntries(projectID: a.id).map(\.title) == ["会被移入回收站"])
    }

    @Test func rejectsDuplicateSiblingNames() throws {
        let url = temporaryVaultURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let anchorStore = InMemoryVaultFolderAnchorStore()

        let (session, entries) = try makeVault(at: url, anchorStore: anchorStore)
        let folders = VaultFolderRepository(
            entryRepository: entries,
            session: session,
            anchorStore: anchorStore
        )
        _ = try folders.createFolder(title: "工作", parentID: nil)
        #expect(throws: VaultFolderError.duplicateName("工作")) {
            _ = try folders.createFolder(title: "工作", parentID: nil)
        }
    }

    @Test func deletingNonEmptyFolderNeverDropsEntriesSilently() throws {
        let url = temporaryVaultURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let anchorStore = InMemoryVaultFolderAnchorStore()

        let (session, entries) = try makeVault(at: url, anchorStore: anchorStore)
        let folders = VaultFolderRepository(
            entryRepository: entries,
            session: session,
            anchorStore: anchorStore
        )
        let parent = try folders.createFolder(title: "父", parentID: nil)
        let child = try folders.createFolder(title: "子", parentID: parent.id)
        _ = try entries.createLoginEntry(
            projectID: child.id,
            draft: LocalLoginEntryDraft(title: "子文件夹里的密码", username: "u", password: "p", url: "")
        )

        let plan = try folders.deletionPlan(folderID: child.id)
        #expect(plan.liveEntryCount == 1)
        #expect(plan.canReparent)
        #expect(plan.isEffectivelyEmpty == false)

        // 根文件夹没有上级，只能递归进回收站
        #expect(throws: VaultFolderError.folderNotEmpty.self) {
            _ = try folders.deleteFolder(folderID: parent.id, strategy: .reparent)
        }

        // 内容上移：条目搬到父文件夹，条目本身不丢
        let result = try folders.deleteFolder(folderID: child.id, strategy: .reparent)
        #expect(result.movedEntryCount == 1)
        #expect(try entries.listLoginEntries(projectID: parent.id).map(\.title) == ["子文件夹里的密码"])
        #expect(try folders.tree().folder(id: child.id) == nil)
    }

    @Test func recursiveTrashMovesEntriesToRecycleBin() throws {
        let url = temporaryVaultURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let anchorStore = InMemoryVaultFolderAnchorStore()

        let (session, entries) = try makeVault(at: url, anchorStore: anchorStore)
        let folders = VaultFolderRepository(
            entryRepository: entries,
            session: session,
            anchorStore: anchorStore
        )
        let root = try folders.createFolder(title: "根", parentID: nil)
        let nested = try folders.createFolder(title: "子", parentID: root.id)
        _ = try entries.createLoginEntry(
            projectID: root.id,
            draft: LocalLoginEntryDraft(title: "根里的密码", username: "u", password: "p", url: "")
        )
        _ = try entries.createLoginEntry(
            projectID: nested.id,
            draft: LocalLoginEntryDraft(title: "子里的密码", username: "u", password: "p", url: "")
        )

        let result = try folders.deleteFolder(folderID: root.id, strategy: .recursiveTrash)
        #expect(result.removedFolderCount == 2)
        #expect(result.trashedEntryCount == 2)
        // 条目进了回收站，而不是被永久删除
        #expect(try entries.listLoginEntries(projectID: root.id).isEmpty)
        #expect(try entries.listDeletedLoginEntries(projectID: root.id).map(\.title) == ["根里的密码"])
        #expect(try entries.listDeletedLoginEntries(projectID: nested.id).map(\.title) == ["子里的密码"])
        #expect(try folders.tree().isEmpty)
    }

    @Test func depthLimitIsEnforcedWhenCreatingFolders() throws {
        let url = temporaryVaultURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let anchorStore = InMemoryVaultFolderAnchorStore()

        let (session, entries) = try makeVault(at: url, anchorStore: anchorStore)
        let folders = VaultFolderRepository(
            entryRepository: entries,
            session: session,
            anchorStore: anchorStore
        )
        var parentID: String?
        for level in 1...VaultFolderNameRules.maxDepth {
            let node = try folders.createFolder(title: "第\(level)层", parentID: parentID)
            parentID = node.id
        }
        #expect(throws: VaultFolderError.self) {
            _ = try folders.createFolder(title: "第9层", parentID: parentID)
        }
    }

    @Test func rejectsInvalidFolderNames() throws {
        let url = temporaryVaultURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let anchorStore = InMemoryVaultFolderAnchorStore()

        let (session, entries) = try makeVault(at: url, anchorStore: anchorStore)
        let folders = VaultFolderRepository(
            entryRepository: entries,
            session: session,
            anchorStore: anchorStore
        )
        #expect(throws: VaultFolderError.emptyName) {
            _ = try folders.createFolder(title: "  ", parentID: nil)
        }
        #expect(throws: VaultFolderError.invalidName(reason: .pathSeparator)) {
            _ = try folders.createFolder(title: "a/b", parentID: nil)
        }
        #expect(throws: VaultFolderError.invalidName(reason: .relativePathSegment)) {
            _ = try folders.createFolder(title: "..", parentID: nil)
        }
        #expect(try folders.tree().isEmpty)
    }

    @Test func renameKeepsIdentityAndRejectsSiblingCollision() throws {
        let url = temporaryVaultURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let anchorStore = InMemoryVaultFolderAnchorStore()

        let (session, entries) = try makeVault(at: url, anchorStore: anchorStore)
        let folders = VaultFolderRepository(
            entryRepository: entries,
            session: session,
            anchorStore: anchorStore
        )
        let work = try folders.createFolder(title: "工作", parentID: nil)
        let other = try folders.createFolder(title: "个人", parentID: nil)
        _ = try entries.createNoteEntry(
            projectID: work.id,
            draft: LocalNoteEntryDraft(title: "笔记", body: "正文")
        )

        let renamed = try folders.renameFolder(id: work.id, title: "公司")
        #expect(renamed.title == "公司")
        // 重命名不改主键，条目归属不变
        #expect(try entries.listNoteEntries(projectID: work.id).map(\.title) == ["笔记"])
        #expect(try folders.tree().folder(id: work.id)?.title == "公司")

        #expect(throws: VaultFolderError.duplicateName("公司")) {
            _ = try folders.renameFolder(id: other.id, title: "公司")
        }
    }
}
