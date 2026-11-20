import Foundation
import Testing
@testable import MonicaStorage

/// issue #16：多 URL、应用绑定、备注与密码历史走真实 MDBX 引擎的保存 → 关闭 → 重新打开链路。
@Suite(.serialized)
struct LoginEntryDetailStorageTests {
    private struct ScratchVault {
        let directoryURL: URL
        let fileURL: URL
        let repository: LocalVaultRepository
    }

    private func makeScratchVault() throws -> ScratchVault {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-storage-login-detail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let repository = LocalVaultRepository(engine: MDBXLocalVaultEngine())
        let session = try repository.createVault(
            named: "Detail",
            in: directoryURL,
            password: "Detail password 12345!",
            deviceID: "swiftpm-storage-login-detail"
        )
        return ScratchVault(
            directoryURL: directoryURL,
            fileURL: session.descriptor.fileURL,
            repository: repository
        )
    }

    private func reopen(_ scratch: ScratchVault) throws -> LocalVaultSession {
        try scratch.repository.openVault(
            at: scratch.fileURL,
            password: "Detail password 12345!",
            deviceID: "swiftpm-storage-login-detail"
        )
    }

    @Test func loginDetailFieldsRoundTripThroughRealVault() throws {
        let scratch = try makeScratchVault()
        defer { try? FileManager.default.removeItem(at: scratch.directoryURL) }

        let session = try reopen(scratch)
        let entries = scratch.repository.entryRepository(for: session)
        let project = try entries.createProject(title: "工作")
        let history = [
            LocalLoginPasswordHistoryEntry(
                changedAt: Date(timeIntervalSince1970: 1_700_000_000.123),
                password: "old-secret-1"
            ),
            LocalLoginPasswordHistoryEntry(
                changedAt: Date(timeIntervalSince1970: 1_700_003_600.456),
                password: "old-secret-2"
            )
        ]

        let created = try entries.createLoginEntry(
            projectID: project.id,
            draft: LocalLoginEntryDraft(
                title: "公司邮箱",
                username: "alice@example.com",
                password: "current-secret",
                url: "https://mail.example.com/login",
                notes: "硬件密钥两步验证",
                urls: [
                    "https://mail.example.com/login",
                    "https://mail.example.com/admin",
                    "https://mail.example.com/login"
                ],
                appBundleID: "com.example.mail",
                appName: "Example Mail",
                passwordHistory: history
            )
        )

        #expect(created.effectiveURLs == ["https://mail.example.com/login", "https://mail.example.com/admin"])
        #expect(created.url == "https://mail.example.com/login")
        #expect(created.appBundleID == "com.example.mail")
        #expect(created.appName == "Example Mail")
        #expect(created.notes == "硬件密钥两步验证")
        #expect(created.passwordHistory.map(\.password) == ["old-secret-1", "old-secret-2"])
        #expect(created.passwordHistory.map(\.changedAt) == history.map(\.changedAt))

        // 关闭再打开（等价于锁库后重新解锁），所有字段必须一致。
        scratch.repository.closeVault(for: session)
        let reopenedSession = try reopen(scratch)
        let reopenedEntries = scratch.repository.entryRepository(for: reopenedSession)
        let loaded = try #require(try reopenedEntries.listLoginEntries(projectID: project.id).first)

        #expect(loaded == created)
        #expect(loaded.effectiveURLs == ["https://mail.example.com/login", "https://mail.example.com/admin"])
        #expect(loaded.appBundleID == "com.example.mail")
        #expect(loaded.appName == "Example Mail")
        #expect(loaded.notes == "硬件密钥两步验证")
        #expect(loaded.passwordHistory.map(\.password) == ["old-secret-1", "old-secret-2"])
        #expect(loaded.passwordHistory.map(\.changedAt) == history.map(\.changedAt))
    }

    @Test func legacySingleURLStillReadsAndSavesWithoutLosingDetail() throws {
        let scratch = try makeScratchVault()
        defer { try? FileManager.default.removeItem(at: scratch.directoryURL) }

        let session = try reopen(scratch)
        let entries = scratch.repository.entryRepository(for: session)
        let project = try entries.createProject(title: "个人")
        let created = try entries.createLoginEntry(
            projectID: project.id,
            draft: LocalLoginEntryDraft(
                title: "旧站点",
                username: "legacy",
                password: "legacy-secret",
                url: "https://legacy.example.com"
            )
        )

        #expect(created.url == "https://legacy.example.com")
        #expect(created.effectiveURLs == ["https://legacy.example.com"])
        #expect(created.appBundleID.isEmpty)
        #expect(created.appName.isEmpty)
        #expect(created.passwordHistory.isEmpty)

        // 只改标题、不传 URL 列表：主 URL 与（不存在的）次级 URL 都不受影响。
        let renamed = try entries.updateLoginEntry(
            projectID: project.id,
            entryID: created.id,
            draft: LocalLoginEntryDraft(
                title: "旧站点（改名）",
                username: "legacy",
                password: "legacy-secret",
                url: "https://legacy.example.com"
            )
        )
        #expect(renamed.title == "旧站点（改名）")
        #expect(renamed.effectiveURLs == ["https://legacy.example.com"])
        #expect(renamed.passwordHistory.isEmpty)
        #expect(renamed.password == "legacy-secret")
    }

    @Test func urlRulesReportIssuesWithoutThrowing() {
        #expect(LoginEntryURLRules.issue(for: "") == .empty)
        #expect(LoginEntryURLRules.issue(for: "   ") == .empty)
        #expect(LoginEntryURLRules.issue(for: "https://mail.example.com/login") == nil)
        #expect(LoginEntryURLRules.issue(for: "http://example.com") == nil)
        #expect(LoginEntryURLRules.issue(for: "example.com/login") == nil)
        #expect(LoginEntryURLRules.issue(for: "ftp://example.com") == .unsupportedScheme("ftp"))
        #expect(LoginEntryURLRules.issue(for: "https://") == .missingHost)
        #expect(LoginEntryURLRules.issue(for: "不是 一个 网址") == .malformed)
        #expect(!LoginEntryURLRules.isValid("not a url"))

        #expect(
            LoginEntryURLRules.normalizedURLs(
                primary: " https://a.example.com ",
                additional: ["https://b.example.com", "https://a.example.com", "", "  "]
            ) == ["https://a.example.com", "https://b.example.com"]
        )
    }

    @Test func invalidURLsAreStoredWithoutCrashing() throws {
        let scratch = try makeScratchVault()
        defer { try? FileManager.default.removeItem(at: scratch.directoryURL) }

        let session = try reopen(scratch)
        let entries = scratch.repository.entryRepository(for: session)
        let project = try entries.createProject(title: "异常输入")

        let created = try entries.createLoginEntry(
            projectID: project.id,
            draft: LocalLoginEntryDraft(
                title: "半成品",
                username: "user",
                password: "secret",
                url: "  这是一个网址 ",
                urls: ["  这是一个网址 ", "ftp://legacy.example.com", "https://ok.example.com"]
            )
        )

        #expect(created.effectiveURLs == ["这是一个网址", "ftp://legacy.example.com", "https://ok.example.com"])
        #expect(created.url == "这是一个网址")
        #expect(LoginEntryURLRules.isValid(created.url) == false)
    }

    @Test func passwordHistoryAppendsOnlyWhenPasswordChanges() throws {
        let scratch = try makeScratchVault()
        defer { try? FileManager.default.removeItem(at: scratch.directoryURL) }

        let session = try reopen(scratch)
        let entries = scratch.repository.entryRepository(for: session)
        let project = try entries.createProject(title: "历史")
        let created = try entries.createLoginEntry(
            projectID: project.id,
            draft: LocalLoginEntryDraft(
                title: "历史站点",
                username: "user",
                password: "v1",
                url: "https://history.example.com"
            )
        )
        #expect(created.passwordHistory.isEmpty)

        func update(password: String, history: [LocalLoginPasswordHistoryEntry]? = nil) throws -> LocalLoginEntry {
            try entries.updateLoginEntry(
                projectID: project.id,
                entryID: created.id,
                draft: LocalLoginEntryDraft(
                    title: "历史站点",
                    username: "user",
                    password: password,
                    url: "https://history.example.com",
                    passwordHistory: history
                )
            )
        }

        // 密码没变：不追加。
        let unchanged = try update(password: "v1")
        #expect(unchanged.passwordHistory.isEmpty)

        // 只改备注（密码不变）：不追加。
        let notesOnly = try entries.updateLoginEntry(
            projectID: project.id,
            entryID: created.id,
            draft: LocalLoginEntryDraft(
                title: "历史站点",
                username: "user",
                password: "v1",
                url: "https://history.example.com",
                notes: "补一条备注"
            )
        )
        #expect(notesOnly.passwordHistory.isEmpty)
        #expect(notesOnly.notes == "补一条备注")

        let second = try update(password: "v2")
        #expect(second.passwordHistory.map(\.password) == ["v1"])

        // 再保存同一密码：不重复追加。
        let sameAgain = try update(password: "v2")
        #expect(sameAgain.passwordHistory.map(\.password) == ["v1"])

        let third = try update(password: "v3")
        #expect(third.passwordHistory.map(\.password) == ["v2", "v1"])

        // UI 删除单条：显式传回剩余历史，不会再被补回来。
        let remainingIDs = Array(third.passwordHistory.dropFirst())
        let deletedOne = try update(password: "v3", history: remainingIDs)
        #expect(deletedOne.passwordHistory.map(\.password) == ["v1"])

        // UI 清空：显式传空列表。
        let cleared = try update(password: "v3", history: [])
        #expect(cleared.passwordHistory.isEmpty)

        // 清空后再次改密：从当前密文继续记录。
        let fourth = try update(password: "v4")
        #expect(fourth.passwordHistory.map(\.password) == ["v3"])
    }

    @Test func passwordHistoryEntriesCanBeRemovedAndClearedByPolicy() {
        let history = [
            LocalLoginPasswordHistoryEntry(changedAt: Date(timeIntervalSince1970: 3), password: "c"),
            LocalLoginPasswordHistoryEntry(changedAt: Date(timeIntervalSince1970: 2), password: "b"),
            LocalLoginPasswordHistoryEntry(changedAt: Date(timeIntervalSince1970: 1), password: "a")
        ]
        let removed = LoginPasswordHistoryPolicy.removing(id: history[1].id, from: history)
        #expect(removed.map(\.password) == ["c", "a"])
        #expect(LoginPasswordHistoryPolicy.sanitizedHistory([]).isEmpty)

        // 连续重复与空密码不进历史。
        let messy = [
            LocalLoginPasswordHistoryEntry(changedAt: Date(timeIntervalSince1970: 2), password: ""),
            LocalLoginPasswordHistoryEntry(changedAt: Date(timeIntervalSince1970: 1), password: "x")
        ]
        #expect(LoginPasswordHistoryPolicy.sanitizedHistory(messy).map(\.password) == ["x"])
    }

    @Test func historyIsUnavailableAfterVaultIsClosed() throws {
        let scratch = try makeScratchVault()
        defer { try? FileManager.default.removeItem(at: scratch.directoryURL) }

        let session = try reopen(scratch)
        let entries = scratch.repository.entryRepository(for: session)
        let project = try entries.createProject(title: "锁定")
        let created = try entries.createLoginEntry(
            projectID: project.id,
            draft: LocalLoginEntryDraft(
                title: "锁定站点",
                username: "user",
                password: "v2",
                url: "https://locked.example.com",
                passwordHistory: [
                    LocalLoginPasswordHistoryEntry(changedAt: Date(timeIntervalSince1970: 1_700_000_000), password: "v1")
                ]
            )
        )
        #expect(created.passwordHistory.count == 1)

        scratch.repository.closeVault(for: session)

        #expect(throws: LocalVaultRepositoryError.vaultUnavailable) {
            _ = try entries.listLoginEntries(projectID: project.id)
        }
        #expect(throws: (any Error).self) {
            _ = try scratch.repository.openVault(
                at: scratch.fileURL,
                password: "wrong password 12345!",
                deviceID: "swiftpm-storage-login-detail"
            )
        }
    }
}
