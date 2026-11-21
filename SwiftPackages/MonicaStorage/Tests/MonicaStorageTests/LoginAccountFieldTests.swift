import Foundation
import Testing
@testable import MonicaStorage

/// issue #151：登录条目「账号」字段的存储兼容性。
///
/// 覆盖真实 MDBX 往返、CSV 追加列与旧 CSV 回落、Android 备份 JSON 往返与旧备份回落，
/// 以及搜索把账号与用户名当成两个独立字段。
@Suite(.serialized)
struct LoginAccountFieldTests {
    private struct ScratchVault {
        let directoryURL: URL
        let fileURL: URL
        let repository: LocalVaultRepository
    }

    private func makeScratchVault() throws -> ScratchVault {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-storage-login-account-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let repository = LocalVaultRepository(engine: MDBXLocalVaultEngine())
        let session = try repository.createVault(
            named: "Account",
            in: directoryURL,
            password: "Account password 12345!",
            deviceID: "swiftpm-storage-login-account"
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
            password: "Account password 12345!",
            deviceID: "swiftpm-storage-login-account"
        )
    }

    // MARK: - 真实 MDBX 往返

    @Test func accountRoundTripsThroughRealVaultAndUpdateKeepsIt() throws {
        let scratch = try makeScratchVault()
        defer { try? FileManager.default.removeItem(at: scratch.directoryURL) }

        let session = try reopen(scratch)
        let entries = scratch.repository.entryRepository(for: session)
        let project = try entries.createProject(title: "工作")
        let created = try entries.createLoginEntry(
            projectID: project.id,
            draft: LocalLoginEntryDraft(
                title: "公司邮箱",
                username: "alice",
                account: "alice@example.com",
                password: "current-secret",
                url: "https://mail.example.com/login"
            )
        )

        #expect(created.username == "alice")
        #expect(created.account == "alice@example.com")

        // 锁库再打开：账号必须和用户名一起从 payload 解出来。
        scratch.repository.closeVault(for: session)
        let reopened = try reopen(scratch)
        let reopenedEntries = scratch.repository.entryRepository(for: reopened)
        let loaded = try #require(try reopenedEntries.listLoginEntries(projectID: project.id).first)
        #expect(loaded == created)
        #expect(loaded.account == "alice@example.com")

        // 编辑回写时调用方会带上原账号；不能因为改标题而丢失。
        let renamed = try reopenedEntries.updateLoginEntry(
            projectID: project.id,
            entryID: created.id,
            draft: LocalLoginEntryDraft(
                title: "公司邮箱（改名）",
                username: loaded.username,
                account: loaded.account,
                password: loaded.password,
                url: loaded.url,
                notes: loaded.notes,
                urls: loaded.urls,
                appBundleID: loaded.appBundleID,
                appName: loaded.appName,
                passwordHistory: loaded.passwordHistory
            )
        )
        #expect(renamed.account == "alice@example.com")
        #expect(renamed.title == "公司邮箱（改名）")
    }

    @Test func passwordHistoryAndURLMutationsKeepAccount() {
        let draft = LocalLoginEntryDraft(
            title: "站点",
            username: "alice",
            account: "alice@example.com",
            password: "secret",
            url: "https://example.com"
        )

        #expect(draft.withURLs(["https://example.com", "https://example.com/admin"]).account == "alice@example.com")
        #expect(draft.withPasswordHistory([]).account == "alice@example.com")
    }

    // MARK: - CSV

    @Test func csvAppendsAccountColumnAndRoundTrips() {
        #expect(VaultCSVCodec.columns.last == "account")

        let items: [VaultCSVItemDraft] = [
            .login(LocalLoginEntryDraft(
                title: "公司邮箱",
                username: "alice",
                account: "alice@example.com",
                password: "p,ass",
                url: "https://mail.example.com"
            ))
        ]

        let csv = VaultCSVCodec.exportItems(items)
        let header = csv.components(separatedBy: "\n").first ?? ""
        #expect(header.hasSuffix(",account"))

        let report = VaultCSVCodec.importItems(from: csv)
        #expect(report.issues.isEmpty)
        #expect(report.items == items)
    }

    @Test func legacyCSVWithoutAccountColumnImportsEmptyAccount() throws {
        let csv = """
        kind,title,username,password,url,notes
        login,旧站点,legacy,legacy-secret,https://legacy.example.com,旧备注
        """

        let report = VaultCSVCodec.importItems(from: csv)
        #expect(report.issues.isEmpty)
        let item = try #require(report.items.first)
        guard case .login(let draft) = item else {
            Issue.record("Expected login draft")
            return
        }
        #expect(draft.username == "legacy")
        #expect(draft.account.isEmpty)
        #expect(draft.password == "legacy-secret")
    }

    // MARK: - Android 备份

    @Test func androidBackupRoundTripsAccount() throws {
        let draft = LocalLoginEntryDraft(
            title: "公司邮箱",
            username: "alice",
            account: "alice@example.com",
            password: "backup-secret",
            url: "https://mail.example.com"
        )

        let archive = try AndroidBackupCodec.exportItems([.login(draft)])
        let report = try AndroidBackupCodec.importItems(from: archive)

        #expect(report.issues.isEmpty)
        let item = try #require(report.items.first)
        guard case .login(let imported) = item else {
            Issue.record("Expected login draft")
            return
        }
        #expect(imported.username == "alice")
        #expect(imported.account == "alice@example.com")
        #expect(report.items == [.login(draft)])
    }

    @Test func legacyAndroidBackupWithoutAccountKeyImportsEmptyAccount() throws {
        let object: [String: Any] = [
            "id": 151,
            "title": "旧版 Android 条目",
            "username": "legacy",
            "password": "legacy-secret",
            "website": "https://legacy.example.com",
            "notes": "旧备份",
            "isFavorite": false
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let json = try #require(String(data: jsonData, encoding: .utf8))
        let archive = try AndroidBackupCodec.exportZip(entries: [
            "folders/Legacy/passwords/password_151_1797000000151.json": json
        ])

        let report = try AndroidBackupCodec.importItems(from: archive)
        #expect(report.issues.isEmpty)
        let item = try #require(report.items.first)
        guard case .login(let draft) = item else {
            Issue.record("Expected login draft")
            return
        }
        #expect(draft.username == "legacy")
        #expect(draft.account.isEmpty)
    }

    // MARK: - 搜索

    @Test func searchMatchesAccountAndReportsAccountField() throws {
        var snapshot = VaultSearchEntrySnapshot()
        snapshot.loginEntries = [
            LocalLoginEntry(
                id: "login-mail",
                projectID: "project-work",
                title: "公司邮箱",
                username: "alice",
                account: "alice@example.com",
                password: "secret",
                url: "https://mail.example.com"
            )
        ]
        let index = VaultSearchIndex(
            documents: VaultSearchDocumentBuilder.documents(from: snapshot, usage: [:])
        )

        let accountResults = index.search("alice@example.com")
        let match = try #require(accountResults.results.first(where: { $0.id == "login-mail" }))
        #expect(match.matches.contains(where: { $0.field == .account }))
        #expect(!match.matches.contains(where: { $0.field == .username }))

        // 用户名仍是独立字段：只搜 username 时命中 .username。
        let usernameResults = index.search("alice")
        let usernameMatch = try #require(usernameResults.results.first(where: { $0.id == "login-mail" }))
        #expect(usernameMatch.matches.contains(where: { $0.field == .username }))
    }
}
