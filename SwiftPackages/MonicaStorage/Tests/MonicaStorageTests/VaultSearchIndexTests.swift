import Foundation
import Testing
import MonicaStorage

// MARK: - 固定测试数据

private let baseDate = Date(timeIntervalSince1970: 1_750_000_000)

private struct SearchFixture {
    let snapshot: VaultSearchEntrySnapshot
    let usage: [VaultSearchItemKey: VaultSearchUsage]
    /// 任何情况下都不允许进入索引的 secret 明文。
    let secrets: [String]

    var index: VaultSearchIndex {
        VaultSearchIndex(
            documents: VaultSearchDocumentBuilder.documents(from: snapshot, usage: usage)
        )
    }
}

private func makeFixture() -> SearchFixture {
    var snapshot = VaultSearchEntrySnapshot()

    snapshot.loginEntries = [
        LocalLoginEntry(
            id: "login-github",
            projectID: "project-personal",
            title: "GitHub",
            username: "octocat",
            password: "pw-github-9f8e7d",
            url: "https://github.com/login",
            notes: "工作账号，开启双重验证",
            favorite: true
        ),
        LocalLoginEntry(
            id: "login-bank",
            projectID: "project-work",
            title: "招商银行",
            username: "zhang.wei",
            password: "pw-bank-1234",
            url: "https://www.cmbchina.com/",
            notes: "工资卡网银"
        )
    ]
    snapshot.deletedLoginEntries = [
        LocalLoginEntry(
            id: "login-deleted",
            projectID: "project-personal",
            title: "已删除的 GitHub 旧账号",
            username: "old-octocat",
            password: "pw-old-secret",
            url: "https://github.com/old",
            notes: "回收站里的登录条目"
        )
    ]

    snapshot.noteEntries = [
        LocalNoteEntry(
            id: "note-wifi",
            projectID: "project-personal",
            title: "家里网络备忘",
            body: "路由器放在书房，恢复出厂设置前先备份配置。",
            favorite: true
        ),
        LocalNoteEntry(
            id: "note-travel",
            projectID: "project-work",
            title: "出差清单",
            body: "护照、充电器、GitHub 硬件密钥。"
        )
    ]
    snapshot.deletedNoteEntries = [
        LocalNoteEntry(
            id: "note-deleted",
            projectID: "project-personal",
            title: "回收站笔记",
            body: "这条已经被软删除。"
        )
    ]

    snapshot.cardEntries = [
        LocalCardEntry(
            id: "card-visa",
            projectID: "project-personal",
            title: "Visa 白金卡",
            cardholderName: "张伟",
            number: "4111111111111111",
            expiryMonth: "08",
            expiryYear: "2030",
            cvv: "987",
            issuer: "招商银行",
            network: "Visa",
            notes: "日常消费主卡"
        ),
        LocalCardEntry(
            id: "card-unionpay",
            projectID: "project-work",
            title: "云闪付卡",
            cardholderName: "Zhang Wei",
            number: "6222020202020202",
            expiryMonth: "01",
            expiryYear: "2029",
            cvv: "123",
            issuer: "中国银联",
            network: "UnionPay",
            notes: "公司报销用卡"
        )
    ]
    snapshot.deletedCardEntries = [
        LocalCardEntry(
            id: "card-deleted",
            projectID: "project-personal",
            title: "已注销的卡",
            cardholderName: "张伟",
            number: "4000000000000002",
            expiryMonth: "02",
            expiryYear: "2020",
            cvv: "321",
            issuer: "招商银行",
            network: "Visa",
            notes: ""
        )
    ]

    snapshot.totpEntries = [
        LocalTotpEntry(
            id: "totp-github",
            projectID: "project-personal",
            title: "GitHub 动态码",
            secret: "JBSWY3DPEHPK3PXP",
            issuer: "GitHub",
            accountName: "octocat",
            period: 30,
            digits: 6,
            algorithm: "SHA1",
            otpType: "TOTP",
            counter: 0
        ),
        LocalTotpEntry(
            id: "totp-bank",
            projectID: "project-work",
            title: "银行令牌",
            secret: "KRSXG5CTMVRXEZLU",
            issuer: "招商银行",
            accountName: "zhang.wei",
            period: 30,
            digits: 6,
            algorithm: "SHA1",
            otpType: "TOTP",
            counter: 0
        )
    ]
    snapshot.deletedTotpEntries = [
        LocalTotpEntry(
            id: "totp-deleted",
            projectID: "project-personal",
            title: "已删除的验证器",
            secret: "MFRGGZDFMZTWQ2LK",
            issuer: "旧站点",
            accountName: "old",
            period: 30,
            digits: 6,
            algorithm: "SHA1",
            otpType: "TOTP",
            counter: 0
        )
    ]

    snapshot.passkeyEntries = [
        LocalPasskeyEntry(
            id: "passkey-apple",
            projectID: "project-personal",
            title: "Apple 通行密钥",
            relyingPartyID: "apple.com",
            username: "zhang.wei@example.com",
            userHandle: "handle-apple",
            credentialID: "credential-id-apple",
            publicKeyCOSE: "cose-public-key-apple",
            privateKeyReference: "private-ref-apple",
            notes: "iCloud 钥匙串同步"
        ),
        LocalPasskeyEntry(
            id: "passkey-github",
            projectID: "project-work",
            title: "GitHub Passkey",
            relyingPartyID: "github.com",
            username: "octocat",
            userHandle: "handle-github",
            credentialID: "credential-id-github",
            publicKeyCOSE: "cose-public-key-github",
            privateKeyReference: "private-ref-github",
            notes: ""
        )
    ]
    snapshot.deletedPasskeyEntries = [
        LocalPasskeyEntry(
            id: "passkey-deleted",
            projectID: "project-personal",
            title: "已删除的通行密钥",
            relyingPartyID: "old.example.com",
            username: "old",
            userHandle: "handle-old",
            credentialID: "credential-id-old",
            publicKeyCOSE: "cose-old",
            privateKeyReference: "private-ref-old",
            notes: ""
        )
    ]

    snapshot.sshKeyEntries = [
        LocalSshKeyEntry(
            id: "ssh-work",
            projectID: "project-work",
            title: "工作服务器",
            username: "deploy",
            host: "build.internal.example.com",
            publicKey: "ssh-ed25519 AAAAPUBLIC",
            privateKeyReference: "private-ref-ssh-work",
            passphraseHint: "生日",
            notes: "CI 部署密钥"
        )
    ]
    snapshot.apiTokenEntries = [
        LocalApiTokenEntry(
            id: "token-github",
            projectID: "project-work",
            title: "GitHub Actions Token",
            issuer: "GitHub",
            accountName: "ci-bot",
            token: "ghp_supersecrettoken0123456789",
            scopes: "repo workflow",
            expiresAt: "2027-01-01",
            notes: "流水线只读"
        )
    ]
    snapshot.wifiEntries = [
        LocalWifiEntry(
            id: "wifi-home",
            projectID: "project-personal",
            title: "家里 Wi-Fi",
            ssid: "MonicaHome",
            securityType: "WPA3",
            password: "wifi-password-8888",
            hidden: false,
            notes: "5GHz"
        )
    ]
    snapshot.identityEntries = [
        LocalIdentityEntry(
            id: "identity-passport",
            projectID: "project-personal",
            title: "护照",
            documentType: "护照",
            fullName: "张伟",
            documentNumber: "E12345678",
            issuer: "国家移民管理局",
            country: "中国",
            issueDate: "2020-01-01",
            expiryDate: "2030-01-01",
            notes: "备用证件"
        )
    ]

    let usage: [VaultSearchItemKey: VaultSearchUsage] = [
        .init(kind: .login, id: "login-github"): VaultSearchUsage(
            viewCount: 5,
            lastViewedAt: baseDate.addingTimeInterval(500)
        ),
        .init(kind: .note, id: "note-wifi"): VaultSearchUsage(
            viewCount: 1,
            lastViewedAt: baseDate.addingTimeInterval(900)
        ),
        .init(kind: .card, id: "card-visa"): VaultSearchUsage(
            viewCount: 1,
            lastViewedAt: baseDate.addingTimeInterval(100)
        )
    ]

    return SearchFixture(
        snapshot: snapshot,
        usage: usage,
        secrets: [
            "pw-github-9f8e7d",
            "pw-bank-1234",
            "pw-old-secret",
            "4111111111111111",
            "6222020202020202",
            "4000000000000002",
            "987",
            "123",
            "321",
            "JBSWY3DPEHPK3PXP",
            "KRSXG5CTMVRXEZLU",
            "MFRGGZDFMZTWQ2LK",
            "credential-id-apple",
            "private-ref-apple",
            "private-ref-github",
            "cose-public-key-apple",
            "private-ref-ssh-work",
            "AAAAPUBLIC",
            "ghp_supersecrettoken0123456789",
            "wifi-password-8888",
            "E12345678"
        ]
    )
}

private func resultKeys(_ results: [VaultSearchResult]) -> [String] {
    results.map(\.stableIdentifier)
}

// MARK: - 按标题 / 用户名 / 域名匹配

@Test func searchIndexMatchesLoginsByTitleUsernameAndDomain() {
    let fixture = makeFixture()
    let index = fixture.index

    #expect(resultKeys(index.search("GitHub").results).contains("login:login-github"))
    #expect(resultKeys(index.search("octocat").results).contains("login:login-github"))
    #expect(resultKeys(index.search("github.com").results).contains("login:login-github"))

    let domain = index.search("cmbchina")
    guard let bank = domain.results.first(where: { $0.id == "login-bank" }) else {
        Issue.record("应能通过域名命中招商银行登录条目")
        return
    }
    #expect(bank.matches.contains(where: { $0.field == .url }))
    #expect(bank.primaryMatchField != nil)
}

@Test func searchIndexRanksTitleAboveNotesAndIsStable() {
    let fixture = makeFixture()
    let index = fixture.index
    let first = index.search("GitHub")
    let second = index.search("GitHub")

    #expect(resultKeys(first.results) == resultKeys(second.results))
    #expect(Set(resultKeys(first.results)).count == first.results.count)

    guard let github = first.results.first(where: { $0.id == "login-github" })
    else {
        Issue.record("GitHub 查询应命中登录条目")
        return
    }
    #expect(github.matches.contains(where: { $0.field == .title }))
    // 软删除条目默认不返回。
    #expect(!resultKeys(first.results).contains("login:login-deleted"))
}

@Test func searchIndexMatchesNotesByTitleAndBody() {
    let fixture = makeFixture()
    let index = fixture.index

    #expect(resultKeys(index.search("出差").results).contains("note:note-travel"))
    #expect(resultKeys(index.search("路由器").results).contains("note:note-wifi"))
    #expect(resultKeys(index.search("恢复出厂设置").results).contains("note:note-wifi"))

    let note = index.search("路由器").results.first(where: { $0.id == "note-wifi" })
    #expect(note?.matches.contains(where: { $0.field == .notes }) == true)
}

@Test func searchIndexMatchesCardsByTitleHolderAndIssuer() {
    let fixture = makeFixture()
    let index = fixture.index

    #expect(resultKeys(index.search("Visa").results).contains("card:card-visa"))
    #expect(resultKeys(index.search("张伟").results).contains("card:card-visa"))
    #expect(resultKeys(index.search("UnionPay").results).contains("card:card-unionpay"))

    let card = index.search("中国银联").results.first(where: { $0.id == "card-unionpay" })
    #expect(card != nil)
}

@Test func searchIndexMatchesTOTPByTitleIssuerAndAccount() {
    let fixture = makeFixture()
    let index = fixture.index

    #expect(resultKeys(index.search("动态码").results).contains("totp:totp-github"))
    #expect(resultKeys(index.search("招商银行").results).contains("totp:totp-bank"))
    #expect(resultKeys(index.search("zhang.wei").results).contains("totp:totp-bank"))
}

@Test func searchIndexMatchesPasskeyByTitleRelyingPartyAndUsername() {
    let fixture = makeFixture()
    let index = fixture.index

    #expect(resultKeys(index.search("Apple 通行密钥").results).contains("passkey:passkey-apple"))
    #expect(resultKeys(index.search("apple.com").results).contains("passkey:passkey-apple"))
    #expect(resultKeys(index.search("octocat").results).contains("passkey:passkey-github"))
}

// MARK: - 过滤

@Test func searchIndexHidesDeletedEntriesByDefaultAndCanIncludeThem() {
    let fixture = makeFixture()
    let index = fixture.index

    let defaultResults = index.search("旧账号")
    #expect(defaultResults.results.isEmpty)

    var filters = VaultSearchFilters()
    filters.includeDeleted = true
    let withDeleted = index.search("旧账号", filters: filters)
    #expect(resultKeys(withDeleted.results) == ["login:login-deleted"])

    let deletedNote = index.search("回收站笔记")
    #expect(deletedNote.results.isEmpty)
    #expect(resultKeys(index.search("回收站笔记", filters: filters).results) == ["note:note-deleted"])
}

@Test func searchIndexFiltersByKindProjectFavoriteAndArchive() {
    let fixture = makeFixture()
    let index = fixture.index

    var filters = VaultSearchFilters(kinds: [.login])
    let loginsOnly = index.search("GitHub", filters: filters)
    #expect(loginsOnly.results.allSatisfy { $0.kind == .login })
    #expect(!resultKeys(loginsOnly.results).contains("totp:totp-github"))

    filters = VaultSearchFilters(projectIDs: ["project-work"])
    let workOnly = index.search("GitHub", filters: filters)
    #expect(workOnly.results.allSatisfy { $0.projectID == "project-work" })
    #expect(resultKeys(workOnly.results).contains("passkey:passkey-github"))
    #expect(!resultKeys(workOnly.results).contains("login:login-github"))

    filters = VaultSearchFilters(favoritesOnly: true)
    let favorites = index.search("GitHub", filters: filters)
    #expect(favorites.results.allSatisfy { $0.isFavorite })

    var archived = VaultSearchDocument(
        kind: .login,
        id: "archived-login",
        projectID: "project-personal",
        title: "归档的 GitHub 条目",
        username: "archived",
        isArchived: true
    )
    archived.lastViewedAt = nil
    let archivedIndex = VaultSearchIndex(documents: index.documents + [archived])
    #expect(archivedIndex.search("归档").results.isEmpty)
    filters = VaultSearchFilters(includeArchived: true)
    #expect(resultKeys(archivedIndex.search("归档", filters: filters).results) == ["login:archived-login"])
}

// MARK: - 空查询 / 最近 / 常用

@Test func emptyQueryReturnsRecentAndFrequentLists() {
    let fixture = makeFixture()
    let index = fixture.index

    let results = index.search("", limit: 2)
    #expect(results.query.isEmpty)
    #expect(resultKeys(results.recent) == ["note:note-wifi", "login:login-github"])
    #expect(resultKeys(results.frequent) == [
        "login:login-github",
        "note:note-wifi"
    ])
    #expect(resultKeys(results.results) == ["note:note-wifi", "login:login-github"])
    #expect(!results.isEmpty)
    #expect(!results.truncated)
}

@Test func whitespaceOnlyQueryIsTreatedAsEmptyAndUsageIsFiltered() {
    let fixture = makeFixture()
    let index = fixture.index

    let empty = index.search("   \n\t  ")
    #expect(empty.results.count == 3)

    let filters = VaultSearchFilters(kinds: [.card])
    let cards = index.search("", filters: filters)
    #expect(resultKeys(cards.results) == ["card:card-visa"])
    #expect(cards.frequent.first?.id == "card-visa")
}

@Test func emptyQueryWithoutUsageReturnsEmptyResults() {
    let index = VaultSearchIndex()
    let results = index.search("")
    #expect(results.isEmpty)
    #expect(results.recent.isEmpty)
    #expect(results.frequent.isEmpty)
}

// MARK: - 非法输入

@Test func illegalCharactersDoNotCrashAndReturnNoSecrets() {
    let fixture = makeFixture()
    let index = fixture.index

    let weirdQueries = [
        "*",
        "(",
        ")",
        "[",
        "]",
        "\\",
        "%",
        "\"",
        "\u{0000}\u{0001}",
        "   ",
        String(repeating: "a", count: 5_000),
        "😀🔐",
        "title:GitHub AND password:*"
    ]
    for query in weirdQueries {
        let results = index.search(query)
        #expect(results.results.allSatisfy { result in
            fixture.secrets.allSatisfy { secret in
                !result.title.contains(secret)
                    && !result.subtitle.contains(secret)
                    && result.matches.allSatisfy { !$0.snippet.contains(secret) }
            }
        })
    }
    // 超长输入会被截断而不是崩溃，也不会匹配出任何 secret。
    #expect(index.search(String(repeating: "a", count: 5_000)).isEmpty)
}

// MARK: - secret 永不入索引

@Test func secretsAreNeverIndexed() {
    let fixture = makeFixture()
    let documents = fixture.index.documents

    let snapshot = fixture.snapshot
    let expectedCount = snapshot.loginEntries.count
        + snapshot.deletedLoginEntries.count
        + snapshot.noteEntries.count
        + snapshot.deletedNoteEntries.count
        + snapshot.cardEntries.count
        + snapshot.deletedCardEntries.count
        + snapshot.totpEntries.count
        + snapshot.deletedTotpEntries.count
        + snapshot.identityEntries.count
        + snapshot.passkeyEntries.count
        + snapshot.deletedPasskeyEntries.count
        + snapshot.sshKeyEntries.count
        + snapshot.apiTokenEntries.count
        + snapshot.wifiEntries.count
    #expect(documents.count == expectedCount)

    for document in documents {
        let searchable = [
            document.title,
            document.username,
            document.url,
            document.details,
            document.notes,
            document.tags.joined(separator: " ")
        ].joined(separator: "\n")

        for secret in fixture.secrets {
            #expect(!searchable.contains(secret))
        }
    }

    for secret in fixture.secrets {
        #expect(fixture.index.search(secret).results.isEmpty)
    }
}

// MARK: - 取消语义

@Test func staleSearchGenerationCannotOverwriteNewerResults() async throws {
    let fixture = makeFixture()
    let session = VaultSearchSession(documents: fixture.index.documents)

    let staleGeneration = session.nextSearchGeneration()
    let freshGeneration = session.nextSearchGeneration()

    let fresh = try await session.search("GitHub", generation: freshGeneration)
    #expect(!fresh.results.isEmpty)

    do {
        _ = try await session.search("GitHub", generation: staleGeneration)
        Issue.record("旧代次搜索应抛出 superseded")
    } catch let error as VaultSearchError {
        #expect(error == .superseded)
    }
}

@Test func replacingIndexInvalidatesInflightGeneration() async throws {
    let fixture = makeFixture()
    let session = VaultSearchSession(documents: fixture.index.documents)
    let generation = session.nextSearchGeneration()

    session.replaceDocuments([])

    do {
        _ = try await session.search("GitHub", generation: generation)
        Issue.record("索引更新后旧搜索应抛出 superseded")
    } catch let error as VaultSearchError {
        #expect(error == .superseded)
    }

    let latest = try await session.search("GitHub", generation: session.nextSearchGeneration())
    #expect(latest.results.isEmpty)
}

@Test func cancelledTaskStopsSearch() async {
    let fixture = makeFixture()
    let session = VaultSearchSession(documents: fixture.index.documents)
    let gate = SearchTestGate()

    let task = Task { () -> Bool in
        await gate.wait()
        do {
            _ = try await session.search("GitHub")
            return false
        } catch is CancellationError {
            return true
        } catch {
            return false
        }
    }
    task.cancel()
    await gate.open()
    #expect(await task.value)
}

@Test func indexSearchHonorsCancellationCheckpoint() {
    let fixture = makeFixture()
    let index = fixture.index

    struct Expected: Error {}

    var checks = 0
    do {
        _ = try index.search("GitHub", filters: VaultSearchFilters(), limit: 10) {
            checks += 1
            if checks > 1 { throw Expected() }
        }
        Issue.record("检查点抛错后应停止搜索")
    } catch is Expected {
        #expect(checks > 1)
    } catch {
        Issue.record("意外错误：\(error)")
    }
}

// MARK: - 锁库

@Test func lockClearsIndexAndPreventsLeakage() async throws {
    let fixture = makeFixture()
    let session = VaultSearchSession(documents: fixture.index.documents)
    #expect(session.documentCount == fixture.index.documents.count)
    #expect(!session.isLocked)

    let inFlight = session.nextSearchGeneration()
    session.lock()

    #expect(session.isLocked)
    #expect(session.documentCount == 0)

    // 锁库后进行中的搜索直接返回空结果（不抛错、不泄漏任何条目）。
    let afterLockInFlight = try await session.search("GitHub", generation: inFlight)
    #expect(afterLockInFlight.isEmpty)

    let afterLock = try await session.search(
        "GitHub",
        generation: session.nextSearchGeneration()
    )
    #expect(afterLock.isEmpty)

    // 锁库后记录查看不会重建任何数据。
    session.recordView(VaultSearchItemKey(kind: .login, id: "login-github"))
    #expect(session.documentCount == 0)
    let afterRecordView = try await session.search(
        "",
        generation: session.nextSearchGeneration()
    )
    #expect(afterRecordView.isEmpty)
}

@Test func recordViewUpdatesRecencyAndFrequency() async throws {
    let fixture = makeFixture()
    let session = VaultSearchSession(documents: fixture.index.documents)
    let key = VaultSearchItemKey(kind: .card, id: "card-unionpay")
    let viewedAt = baseDate.addingTimeInterval(10_000)

    session.recordView(key, at: viewedAt)

    let results = try await session.search("云闪付", generation: session.nextSearchGeneration())
    guard let card = results.results.first(where: { $0.id == "card-unionpay" }) else {
        Issue.record("查看记录后仍应能搜索到该卡")
        return
    }
    #expect(card.viewCount == 1)
    #expect(card.lastViewedAt == viewedAt)

    let recents = try await session.search("", limit: 3, generation: session.nextSearchGeneration())
    #expect(recents.recent.first?.id == "card-unionpay")
}

// MARK: - 辅助

private actor SearchTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}
