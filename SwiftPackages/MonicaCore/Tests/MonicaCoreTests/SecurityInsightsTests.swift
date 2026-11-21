import Foundation
import Testing
import MonicaCore

/// 固定时间点，避免测试依赖当前时间。
private let auditNow = Date(timeIntervalSince1970: 1_800_000_000)

private func makeSubject(
    id: String,
    title: String = "",
    username: String = "",
    url: String = "",
    password: String,
    changedAt: Date? = nil,
    hasAuthenticator: Bool = true,
    markedBreached: Bool = false
) -> SecurityInsightSubject {
    SecurityInsightSubject(
        id: id,
        title: title,
        username: username,
        url: url,
        password: password,
        passwordChangedAt: changedAt,
        hasLinkedAuthenticator: hasAuthenticator,
        isMarkedBreached: markedBreached
    )
}

/// 验收用固定样本：重复密码 2 条（一组）、弱密码 1 条、未开 2FA 2 条。
private func fixedSampleSubjects(changedAt: Date? = nil) -> [SecurityInsightSubject] {
    [
        makeSubject(
            id: "alpha",
            title: "Alpha",
            username: "alice",
            url: "https://alpha.example.com",
            password: "CorrectHorseBatteryStaple1!",
            changedAt: changedAt
        ),
        makeSubject(
            id: "beta",
            title: "Beta",
            username: "bob",
            url: "https://beta.example.com",
            password: "CorrectHorseBatteryStaple1!",
            changedAt: changedAt
        ),
        makeSubject(
            id: "gamma",
            title: "Gamma",
            username: "carol",
            url: "https://gamma.example.com",
            password: "short",
            changedAt: changedAt,
            hasAuthenticator: false
        ),
        makeSubject(
            id: "delta",
            title: "Delta",
            username: "dave",
            url: "https://delta.example.com",
            password: "AnotherUniquePassw0rd#42",
            changedAt: changedAt,
            hasAuthenticator: false
        ),
        makeSubject(
            id: "epsilon",
            title: "Epsilon",
            username: "erin",
            url: "https://epsilon.example.com",
            password: "Y3tAn0therUnique!Pass"
        ),
    ]
}

// MARK: - 评分

@Test func fixedSampleProducesAuditableScore() {
    let recent = auditNow.addingTimeInterval(-30 * 86_400)
    let report = SecurityInsightAnalyzer.analyze(subjects: fixedSampleSubjects(changedAt: recent), now: auditNow)

    #expect(report.totalItemCount == 5)
    #expect(report.count(for: .reusedPassword) == 2)
    #expect(report.count(for: .weakPassword) == 1)
    #expect(report.count(for: .missingTwoFactor) == 2)
    #expect(report.count(for: .duplicateEntry) == 0)
    #expect(report.count(for: .stalePassword) == 0)
    #expect(report.count(for: .flaggedBreach) == 0)

    // 扣分逐项可核对：复用 2×8=16、弱密码 1×10=10、未开 2FA 2×5=10，合计 36。
    #expect(report.penalty(for: .reusedPassword) == 16)
    #expect(report.penalty(for: .weakPassword) == 10)
    #expect(report.penalty(for: .missingTwoFactor) == 10)
    #expect(report.score == SecurityInsightScoring.maximumScore - 36)
    #expect(report.score == 64)
    #expect(report.auditedAt == auditNow)

    #expect(report.findings.count == 4)
    #expect(report.findings.allSatisfy { !$0.issues.isEmpty })
    #expect(report.findings.allSatisfy { $0.issues.contains(.missingTwoFactor) == false || $0.id != "alpha" })
}

@Test func scoreNeverDropsBelowZero() {
    var subjects: [SecurityInsightSubject] = []
    for index in 0..<8 {
        subjects.append(
            makeSubject(
                id: "breached-\(index)",
                title: "Breached \(index)",
                username: "user-\(index)",
                url: "https://breached-\(index).example.com",
                password: "UnrelatedStrong-Passw0rd-\(index)!",
                markedBreached: true
            )
        )
    }
    let report = SecurityInsightAnalyzer.analyze(subjects: subjects, now: auditNow)
    #expect(report.count(for: .flaggedBreach) == 8)
    // 8×12=96，但单类封顶 48。
    #expect(report.penalty(for: .flaggedBreach) == 48)
    #expect(report.score == 52)
}

@Test func emptyVaultScoresFullMarks() {
    let report = SecurityInsightAnalyzer.analyze(subjects: [], now: auditNow)

    #expect(report.isEmpty)
    #expect(report.score == SecurityInsightScoring.maximumScore)
    #expect(report.totalItemCount == 0)
    #expect(report.findings.isEmpty)
    #expect(report.penalties.allSatisfy { $0.count == 0 && $0.points == 0 })
    #expect(SecurityPasswordAgeBucket.allCases.allSatisfy { report.ageCount(for: $0) == 0 })
}

@Test func markedBreachIsCountedAndDeducted() {
    let subjects = [
        makeSubject(
            id: "one",
            title: "One",
            username: "one",
            url: "https://one.example.com",
            password: "UniqueStrongPassw0rd!1",
            markedBreached: true
        )
    ]
    let report = SecurityInsightAnalyzer.analyze(subjects: subjects, now: auditNow)
    #expect(report.count(for: .flaggedBreach) == 1)
    #expect(report.penalty(for: .flaggedBreach) == 12)
    #expect(report.score == 88)
    #expect(report.findings.first?.issues == [.flaggedBreach])
}

@Test func scoringPointsAreCappedPerCategory() {
    #expect(SecurityInsightScoring.points(count: 0, for: .weakPassword) == 0)
    #expect(SecurityInsightScoring.points(count: 1, for: .weakPassword) == 10)
    #expect(SecurityInsightScoring.points(count: 4, for: .weakPassword) == 40)
    #expect(SecurityInsightScoring.points(count: 9, for: .weakPassword) == 40)
    #expect(SecurityInsightScoring.score(counts: [:]) == 100)
    #expect(SecurityInsightScoring.score(counts: [.flaggedBreach: 100]) == 52)
}

@Test func scoreBandBoundariesAreStable() {
    #expect(SecurityInsightScoreBand.band(for: 100) == .excellent)
    #expect(SecurityInsightScoreBand.band(for: 90) == .excellent)
    #expect(SecurityInsightScoreBand.band(for: 89) == .good)
    #expect(SecurityInsightScoreBand.band(for: 75) == .good)
    #expect(SecurityInsightScoreBand.band(for: 74) == .fair)
    #expect(SecurityInsightScoreBand.band(for: 55) == .fair)
    #expect(SecurityInsightScoreBand.band(for: 54) == .atRisk)
    #expect(SecurityInsightScoreBand.band(for: 0) == .atRisk)
    #expect(SecurityInsightScoreBand.band(for: -5) == .atRisk)
    #expect(SecurityInsightScoreBand.band(for: 140) == .excellent)
    #expect(SecurityInsightScoreBand.excellent.maximumScore == 100)
    #expect(SecurityInsightScoreBand.good.maximumScore == 89)
    #expect(SecurityInsightScoreBand.atRisk.minimumScore == 0)
}

// MARK: - 重复

@Test func identicalTitleAccountAndSiteIsDuplicate() {
    let subjects = [
        makeSubject(
            id: "one",
            title: " GitHub ",
            username: "Alice",
            url: "https://github.com",
            password: "UniqueStrongPassw0rd!1"
        ),
        makeSubject(
            id: "two",
            title: "github",
            username: "alice ",
            url: " HTTPS://GitHub.com ",
            password: "UniqueStrongPassw0rd!2"
        ),
    ]
    let report = SecurityInsightAnalyzer.analyze(subjects: subjects, now: auditNow)
    #expect(report.count(for: .duplicateEntry) == 2)
    #expect(report.penalty(for: .duplicateEntry) == 12)
    #expect(report.score == 88)
}

@Test func sameSiteWithDifferentAccountsIsNotDuplicate() {
    let subjects = [
        makeSubject(
            id: "work",
            title: "Acme",
            username: "alice@acme.example.com",
            url: "https://acme.example.com",
            password: "WorkAccountPassw0rd!1"
        ),
        makeSubject(
            id: "personal",
            title: "Acme",
            username: "alice.personal@acme.example.com",
            url: "https://acme.example.com",
            password: "PersonalAccountPassw0rd!2"
        ),
    ]
    let report = SecurityInsightAnalyzer.analyze(subjects: subjects, now: auditNow)
    #expect(report.count(for: .duplicateEntry) == 0)
    #expect(report.count(for: .reusedPassword) == 0)
    #expect(report.score == 100)
    #expect(report.findings.isEmpty)
}

@Test func deletedEntriesDoNotLeakIntoTheReport() {
    // 已删除条目意味着它不在输入里：既不计数，也不会留下空壳命中。
    let remaining = [
        makeSubject(id: "kept", title: "Kept", username: "kept", url: "https://kept.example.com", password: "KeptStrongPassw0rd!1")
    ]
    let report = SecurityInsightAnalyzer.analyze(subjects: remaining, now: auditNow)
    #expect(report.totalItemCount == 1)
    #expect(report.findings.isEmpty)
    #expect(report.count(for: .duplicateEntry) == 0)
}

// MARK: - 密码复用

@Test func reusedPasswordGroupsOnlyActualDuplicates() {
    let subjects = [
        makeSubject(id: "a", password: "SharedPassw0rd!23"),
        makeSubject(id: "b", password: "SharedPassw0rd!23"),
        makeSubject(id: "c", password: "SharedPassw0rd!23"),
        makeSubject(id: "d", password: "DifferentPassw0rd!4"),
        makeSubject(id: "e", password: "   "),
        makeSubject(id: "f", password: ""),
    ]
    let report = SecurityInsightAnalyzer.analyze(subjects: subjects, now: auditNow)
    #expect(report.count(for: .reusedPassword) == 3)
    #expect(report.penalty(for: .reusedPassword) == 24)
    // 空密码不参与复用统计，也不产生命中。
    #expect(report.findings.first(where: { $0.id == "f" }) == nil)
    #expect(report.findings.first(where: { $0.id == "e" }) == nil)
}

@Test func reuseFingerprintDoesNotStorePlaintext() {
    let report = SecurityInsightAnalyzer.analyze(
        subjects: [makeSubject(id: "a", password: "SharedPassw0rd!23"), makeSubject(id: "b", password: "SharedPassw0rd!23")],
        now: auditNow
    )
    // 报告只暴露聚合结果，任何序列化形态都不应出现密码原文。
    let description = String(describing: report)
    #expect(!description.isEmpty)
    #expect(!description.contains("SharedPassw0rd"))
    let pointJSON = String(describing: SecurityAuditTrendPoint(report: report, now: auditNow))
    #expect(!pointJSON.contains("SharedPassw0rd"))
}

// MARK: - 密码年龄

@Test func stalePasswordBoundaryIs365Days() {
    let subjects = [
        makeSubject(
            id: "old364",
            title: "Old364",
            username: "u364",
            url: "https://old364.example.com",
            password: "EnoughStrongPassw0rd!1",
            changedAt: auditNow.addingTimeInterval(-364 * 86_400)
        ),
        makeSubject(
            id: "old365",
            title: "Old365",
            username: "u365",
            url: "https://old365.example.com",
            password: "EnoughStrongPassw0rd!2",
            changedAt: auditNow.addingTimeInterval(-365 * 86_400)
        ),
        makeSubject(
            id: "future",
            title: "Future",
            username: "ufuture",
            url: "https://future.example.com",
            password: "EnoughStrongPassw0rd!3",
            changedAt: auditNow.addingTimeInterval(86_400)
        ),
    ]
    let report = SecurityInsightAnalyzer.analyze(subjects: subjects, now: auditNow)
    #expect(report.count(for: .stalePassword) == 1)
    #expect(report.findings.first(where: { $0.id == "old365" })?.issues.contains(.stalePassword) == true)
    #expect(report.findings.first(where: { $0.id == "old364" }) == nil)
    #expect(report.findings.first(where: { $0.id == "future" }) == nil)
    #expect(report.ageCount(for: .days180To364) == 1)
    #expect(report.ageCount(for: .atLeast365Days) == 1)
    #expect(report.ageCount(for: .under90Days) == 1)
    #expect(report.penalty(for: .stalePassword) == 4)
}

@Test func unknownPasswordAgeIsNotStale() {
    let subjects = [makeSubject(id: "unknown", title: "Unknown", username: "u", url: "https://u.example.com", password: "EnoughStrongPassw0rd!1")]
    let report = SecurityInsightAnalyzer.analyze(subjects: subjects, now: auditNow)
    #expect(report.count(for: .stalePassword) == 0)
    #expect(report.ageCount(for: .unknown) == 1)
    #expect(SecurityInsightAnalyzer.passwordAgeDays(changedAt: nil, now: auditNow) == nil)
    #expect(SecurityInsightAnalyzer.passwordAgeDays(changedAt: auditNow.addingTimeInterval(60), now: auditNow) == 0)
    #expect(SecurityInsightAnalyzer.passwordAgeDays(changedAt: auditNow.addingTimeInterval(-86_400), now: auditNow) == 1)
}

@Test func ageBucketsUseDocumentedBoundaries() {
    #expect(SecurityPasswordAgeBucket.bucket(forAgeDays: nil) == .unknown)
    #expect(SecurityPasswordAgeBucket.bucket(forAgeDays: -1) == .unknown)
    #expect(SecurityPasswordAgeBucket.bucket(forAgeDays: 0) == .under90Days)
    #expect(SecurityPasswordAgeBucket.bucket(forAgeDays: 89) == .under90Days)
    #expect(SecurityPasswordAgeBucket.bucket(forAgeDays: 90) == .days90To179)
    #expect(SecurityPasswordAgeBucket.bucket(forAgeDays: 179) == .days90To179)
    #expect(SecurityPasswordAgeBucket.bucket(forAgeDays: 180) == .days180To364)
    #expect(SecurityPasswordAgeBucket.bucket(forAgeDays: 364) == .days180To364)
    #expect(SecurityPasswordAgeBucket.bucket(forAgeDays: 365) == .atLeast365Days)
    #expect(SecurityPasswordAgeBucket.bucket(forAgeDays: 4_000) == .atLeast365Days)
}

// MARK: - 弱密码

@Test func weakPasswordRulesAreExplainable() {
    #expect(SecurityInsightAnalyzer.isWeakPassword("") == false)
    #expect(SecurityInsightAnalyzer.isWeakPassword("   ") == false)
    #expect(SecurityInsightAnalyzer.isWeakPassword("short"))
    #expect(SecurityInsightAnalyzer.isWeakPassword("Abcdefgh1234"))
    #expect(SecurityInsightAnalyzer.isWeakPassword("abcdefghijkl"))
    #expect(SecurityInsightAnalyzer.isWeakPassword("password"))
    #expect(SecurityInsightAnalyzer.isWeakPassword("PASSWORD") == true)
    #expect(SecurityInsightAnalyzer.isWeakPassword("Abcdefgh123!") == false)
    #expect(SecurityInsightAnalyzer.isWeakPassword("Abcdefgh123!x") == false)
}

// MARK: - 2FA 启发式

@Test func twoFactorMatcherLinksAccountsAndSites() {
    let github = SecurityInsightTwoFactorMatcher.AuthenticatorIdentity(
        accountName: "alice",
        issuer: "GitHub",
        title: "GitHub: alice"
    )
    let mailbox = SecurityInsightTwoFactorMatcher.AuthenticatorIdentity(
        accountName: "bob@example.com",
        issuer: "",
        title: ""
    )

    #expect(
        SecurityInsightTwoFactorMatcher.isLinked(
            username: "alice",
            urls: ["https://github.com"],
            title: "GitHub",
            authenticators: [github]
        )
    )
    #expect(
        SecurityInsightTwoFactorMatcher.isLinked(
            username: "bob",
            urls: ["https://mail.example.com"],
            title: "Example Mail",
            authenticators: [mailbox]
        )
    )
    #expect(
        SecurityInsightTwoFactorMatcher.isLinked(
            username: "",
            urls: ["https://example.com"],
            title: "Example",
            authenticators: [mailbox]
        )
    )
    #expect(
        SecurityInsightTwoFactorMatcher.isLinked(
            username: "",
            urls: ["https://gitlab.example.org"],
            title: "GitLab",
            authenticators: [SecurityInsightTwoFactorMatcher.AuthenticatorIdentity(accountName: "carol", issuer: "GitLab", title: "")]
        )
    )
    #expect(
        SecurityInsightTwoFactorMatcher.isLinked(
            username: "alice",
            urls: ["https://other.example.net"],
            title: "Other",
            authenticators: [SecurityInsightTwoFactorMatcher.AuthenticatorIdentity(accountName: "gitlab:alice", issuer: "", title: "")]
        )
    )
    #expect(
        SecurityInsightTwoFactorMatcher.isLinked(
            username: "dave",
            urls: ["https://unrelated.example.com"],
            title: "Unrelated",
            authenticators: [github]
        ) == false
    )
}

@Test func missingTwoFactorOnlyCountsLoginsWithoutMatch() {
    let subjects = [
        makeSubject(id: "with", password: "OneStrongPassw0rd!1", hasAuthenticator: true),
        makeSubject(id: "without", password: "TwoStrongPassw0rd!2", hasAuthenticator: false),
    ]
    let report = SecurityInsightAnalyzer.analyze(subjects: subjects, now: auditNow)
    #expect(report.count(for: .missingTwoFactor) == 1)
    #expect(report.findings.map(\.id) == ["without"])
}

// MARK: - 锁定态

@Test func lockedSnapshotExposesNoItemMetadata() {
    let report = SecurityInsightAnalyzer.analyze(subjects: fixedSampleSubjects(), now: auditNow)
    let snapshot = SecurityInsightDashboardSnapshot(isLocked: true, report: report)

    #expect(snapshot.isLocked)
    #expect(snapshot.report == nil)
    #expect(snapshot.score == nil)
    #expect(snapshot.totalItemCount == nil)
    #expect(snapshot.counts.isEmpty)
    #expect(snapshot.penalties.isEmpty)
    #expect(snapshot.findings.isEmpty)
    #expect(snapshot.ageDistribution.isEmpty)
    #expect(snapshot.findings(matching: .weakPassword).isEmpty)
    #expect(snapshot.findings(matching: nil).isEmpty)
    #expect(snapshot.count(for: .weakPassword) == 0)
    #expect(SecurityInsightDashboardSnapshot.locked.findings.isEmpty)
    #expect(SecurityInsightDashboardSnapshot.locked.score == nil)
}

@Test func unlockedSnapshotCarriesReport() {
    let report = SecurityInsightAnalyzer.analyze(subjects: fixedSampleSubjects(), now: auditNow)
    let snapshot = SecurityInsightDashboardSnapshot.unlocked(report)
    #expect(snapshot.isLocked == false)
    #expect(snapshot.score == 64)
    #expect(snapshot.totalItemCount == 5)
    #expect(snapshot.count(for: .weakPassword) == 1)
    #expect(snapshot.findings(matching: .missingTwoFactor).count == 2)
}

// MARK: - 命中列表

@Test func findingsAreFilteredAndOrderedBySeverity() {
    let report = SecurityInsightAnalyzer.analyze(subjects: fixedSampleSubjects(), now: auditNow)

    #expect(report.findings(matching: nil).count == report.findings.count)
    #expect(report.findings(matching: .weakPassword).map(\.id) == ["gamma"])
    #expect(report.findings(matching: .missingTwoFactor).map(\.id) == ["gamma", "delta"])
    #expect(report.findings(matching: .flaggedBreach).isEmpty)

    // 严重度靠前的分类先出现，同严重度内标题升序。
    #expect(report.findings.map(\.id) == ["gamma", "alpha", "beta", "delta"])
    #expect(report.findings.first?.severityRank == SecurityInsightIssue.weakPassword.severityRank)
}

@Test func findingsCarrySiteAndAgeButNoPassword() {
    let recent = auditNow.addingTimeInterval(-120 * 86_400)
    let report = SecurityInsightAnalyzer.analyze(
        subjects: [
            makeSubject(
                id: "one",
                title: "One",
                username: "one@example.com",
                url: "https://www.example.com/login",
                password: "EnoughStrongPassw0rd!1",
                changedAt: recent,
                hasAuthenticator: false
            )
        ],
        now: auditNow
    )
    let finding = report.findings.first
    #expect(finding?.host == "example.com")
    #expect(finding?.username == "one@example.com")
    #expect(finding?.ageDays == 120)
    #expect(!String(describing: finding).contains("EnoughStrongPassw0rd"))
}

// MARK: - 趋势

@Test func trendKeepsOnePointPerDayAndCapsAtThirty() {
    var trend = SecurityAuditTrend()
    for offset in 0..<40 {
        let day = auditNow.addingTimeInterval(Double(offset) * 86_400)
        trend.record(
            SecurityAuditTrendPoint(
                dayKey: SecurityAuditTrend.dayKey(for: day),
                recordedAt: day,
                score: offset,
                totalItemCount: offset,
                issueCounts: [:]
            )
        )
    }
    #expect(trend.points.count == SecurityAuditTrend.maximumPointCount)
    #expect(trend.latest?.score == 39)
    #expect(trend.earliest?.score == 10)
    // 相邻两天的变化是逐日增量；整段变化另有口径。
    #expect(trend.scoreDelta == 1)
    #expect(trend.totalItemDelta == 1)
    #expect(trend.scoreDeltaFromEarliest == 29)
    #expect(trend.totalItemDeltaFromEarliest == 29)
    #expect(trend.points.map(\.dayKey) == trend.points.map(\.dayKey).sorted())

    // 同一天再记录一次：只保留最新值，不新增点。
    let sameDay = auditNow.addingTimeInterval(39 * 86_400)
    trend.record(
        SecurityAuditTrendPoint(
            dayKey: SecurityAuditTrend.dayKey(for: sameDay),
            recordedAt: sameDay,
            score: 70,
            totalItemCount: 12,
            issueCounts: [:]
        )
    )
    #expect(trend.points.count == SecurityAuditTrend.maximumPointCount)
    #expect(trend.latest?.score == 70)
    #expect(trend.scoreDelta == 32)
    #expect(trend.scoreDeltaFromEarliest == 60)
}

@Test func trendDecodingNormalizesDirtyHistory() {
    let points = (0..<35).map { offset in
        SecurityAuditTrendPoint(
            dayKey: String(format: "2026-02-%02d", (offset % 28) + 1),
            recordedAt: auditNow,
            score: offset,
            totalItemCount: 1,
            issueCounts: [:]
        )
    }
    let trend = SecurityAuditTrend(points: points)
    #expect(trend.points.count == 28)
    let encoded = try? JSONEncoder().encode(trend)
    let decoded = encoded.flatMap { try? JSONDecoder().decode(SecurityAuditTrend.self, from: $0) }
    #expect(decoded?.points.count == 28)
    #expect(decoded == trend)
    #expect(SecurityAuditTrend().scoreDelta == nil)
    #expect(SecurityAuditTrend().scoreDeltaFromEarliest == nil)
    #expect(SecurityAuditTrend().isEmpty)
}

@Test func trendPointRecordsIssueCounts() {
    let report = SecurityInsightAnalyzer.analyze(subjects: fixedSampleSubjects(), now: auditNow)
    let point = SecurityAuditTrendPoint(report: report, now: auditNow)
    #expect(point.count(for: .weakPassword) == 1)
    #expect(point.count(for: .reusedPassword) == 2)
    #expect(point.score == 64)
    #expect(point.totalItemCount == 5)
    #expect(point.dayKey == SecurityAuditTrend.dayKey(for: auditNow))
}

// MARK: - 标记与持久化

@Test func breachMarkIsScopedToPasswordRevision() {
    var state = SecurityInsightState.empty
    let first = SecurityInsightRevision.token(historyCount: 0, latestChangeAt: nil)
    let second = SecurityInsightRevision.token(historyCount: 1, latestChangeAt: auditNow)

    state.setBreachMark(true, entryID: "entry", revision: first)
    #expect(state.isMarkedBreached(entryID: "entry", revision: first))
    #expect(state.isMarkedBreached(entryID: "entry", revision: second) == false)

    // 密码改过（修订变化）→ 旧标记失效。
    state.pruneBreachMarks(keeping: ["entry": second])
    #expect(state.breachMarks.isEmpty)
}

@Test func breachMarkKeepsSameRevisionAndCanBeCleared() {
    var state = SecurityInsightState.empty
    let revision = SecurityInsightRevision.token(historyCount: 2, latestChangeAt: auditNow)

    state.setBreachMark(true, entryID: "entry", revision: revision)
    state.pruneBreachMarks(keeping: ["entry": revision])
    #expect(state.isMarkedBreached(entryID: "entry", revision: revision))

    state.setBreachMark(false, entryID: "entry", revision: revision)
    #expect(state.breachMarks.isEmpty)
    #expect(state.isMarkedBreached(entryID: "entry", revision: revision) == false)

    state.setBreachMark(true, entryID: "", revision: revision)
    #expect(state.breachMarks.isEmpty)
}

@Test func stateRecordsOneAuditPointPerDay() {
    var state = SecurityInsightState.empty
    let report = SecurityInsightAnalyzer.analyze(subjects: fixedSampleSubjects(), now: auditNow)
    state.recordAudit(report, now: auditNow)
    state.recordAudit(report, now: auditNow.addingTimeInterval(3_600))
    #expect(state.trend.points.count == 1)
    #expect(state.trend.latest?.score == 64)
}

@Test func fileStoreRoundTripsPerVault() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SecurityInsightsTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileSecurityInsightStore(directoryURL: directory)

    var state = SecurityInsightState.empty
    state.setBreachMark(true, entryID: "entry", revision: "1:100")
    state.trend.record(
        SecurityAuditTrendPoint(
            dayKey: "2026-02-01",
            recordedAt: auditNow,
            score: 61,
            totalItemCount: 7,
            issueCounts: ["weakPassword": 2]
        )
    )
    try await store.save(state, vaultID: "vault-one")

    let loaded = try await store.load(vaultID: "vault-one")
    #expect(loaded == state)
    #expect(loaded.breachMarks == ["entry": "1:100"])
    #expect(loaded.trend.points.count == 1)

    let otherVault = try await store.load(vaultID: "vault-two")
    #expect(otherVault == SecurityInsightState.empty)

    try await store.remove(vaultID: "vault-one")
    let removed = try await store.load(vaultID: "vault-one")
    #expect(removed == SecurityInsightState.empty)
}

@Test func fileStoreFallsBackToEmptyOnCorruptOrUnknownPayload() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SecurityInsightsTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileSecurityInsightStore(directoryURL: directory)
    let url = try store.fileURL(for: "vault-one")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    try Data("not json at all".utf8).write(to: url)
    let corrupt = try await store.load(vaultID: "vault-one")
    #expect(corrupt == SecurityInsightState.empty)

    let unknownVersion = #"{"version": 99, "breachMarks": {"entry": "1:1"}, "trend": {"points": []}}"#
    try Data(unknownVersion.utf8).write(to: url)
    let unknown = try await store.load(vaultID: "vault-one")
    #expect(unknown == SecurityInsightState.empty)
    #expect(unknown.breachMarks.isEmpty)
}

@Test func fileStoreRejectsBlankVaultIdentifier() {
    let store = FileSecurityInsightStore(directoryURL: URL(fileURLWithPath: NSTemporaryDirectory()))
    #expect(throws: SecurityInsightStoreError.invalidVaultIdentifier) {
        try store.fileURL(for: "   ")
    }
    #expect(throws: SecurityInsightStoreError.self) {
        try store.fileURL(for: "")
    }
}

@Test func memoryStoreKeepsStateInMemoryOnly() async throws {
    let store = MemorySecurityInsightStore()
    var state = SecurityInsightState.empty
    state.setBreachMark(true, entryID: "entry", revision: "1:1")
    try await store.save(state, vaultID: "vault-one")
    let loaded = try await store.load(vaultID: "vault-one")
    #expect(loaded.breachMarks == ["entry": "1:1"])
    try await store.remove(vaultID: "vault-one")
    let removed = try await store.load(vaultID: "vault-one")
    #expect(removed.breachMarks.isEmpty)
}
