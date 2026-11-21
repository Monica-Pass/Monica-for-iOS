import Foundation
import MonicaStorage
import Testing

@Suite("Monica Send 加密分享包")
struct MonicaSendPackageTests {
    /// 固定时间，避免测试依赖系统时钟。
    private let fixedNow = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: 测试脚手架

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-send-package-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeLedger(in directory: URL) -> MonicaSendConsumptionLedger {
        MonicaSendConsumptionLedger(directoryURL: directory)
    }

    private func makePolicy(
        id: String = "send-entry-1",
        kind: MonicaSendContentKind = .text,
        title: String = "Wi-Fi 密码",
        fileName: String = "",
        mediaType: String = "",
        createdAt: Date? = nil,
        expiresAt: Date? = nil,
        maxViews: Int = 3
    ) -> MonicaSendPolicy {
        MonicaSendPolicy(
            id: id,
            kind: kind,
            title: title,
            fileName: fileName,
            mediaType: mediaType,
            createdAt: createdAt ?? fixedNow,
            expiresAt: expiresAt,
            maxViews: maxViews
        )
    }

    // MARK: 编解码

    @Test func sealsAndOpensTextPackage() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = makeLedger(in: directory)
        let content = Data("Wi-Fi 密码：monica-2026\n有效期到月底".utf8)
        let sealed = try MonicaSendPackage.seal(
            policy: makePolicy(expiresAt: fixedNow.addingTimeInterval(3600)),
            content: content,
            now: fixedNow
        )

        #expect(sealed.data.starts(with: Data("MNS1".utf8)))

        let opened = try MonicaSendPackage.open(
            sealed.data,
            code: sealed.code,
            ledger: ledger,
            now: fixedNow.addingTimeInterval(60),
            isVaultLocked: false
        )
        #expect(opened.content == content)
        #expect(opened.text == "Wi-Fi 密码：monica-2026\n有效期到月底")
        #expect(opened.descriptor.policy.kind == .text)
        #expect(opened.descriptor.policy.maxViews == 3)
        #expect(opened.opensBeforeThisOpen == 0)
        #expect(opened.remainingViews == 2)
    }

    @Test func sealsAndOpensBinaryFilePackage() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = makeLedger(in: directory)
        let content = Data((0 ..< 4096).map { UInt8($0 % 251) })
        let sealed = try MonicaSendPackage.seal(
            policy: makePolicy(kind: .file, title: "季度报表", fileName: "report.pdf", mediaType: "application/pdf"),
            content: content,
            now: fixedNow
        )

        let opened = try MonicaSendPackage.open(
            sealed.data,
            code: sealed.code,
            ledger: ledger,
            now: fixedNow.addingTimeInterval(1),
            isVaultLocked: false
        )
        #expect(opened.content == content)
        #expect(opened.text == nil)
        #expect(opened.descriptor.policy.fileName == "report.pdf")
        #expect(opened.descriptor.policy.mediaType == "application/pdf")
    }

    @Test func packageNeverContainsPlaintextOrShareCode() throws {
        let text = "今天下午三点在 3 号会议室交接门禁卡"
        let sealed = try MonicaSendPackage.seal(policy: makePolicy(), content: Data(text.utf8), now: fixedNow)

        let asUTF8 = String(decoding: sealed.data, as: UTF8.self)
        #expect(!asUTF8.contains(text))
        #expect(!asUTF8.contains(sealed.code.encoded))
        // 头部只保留元数据，且键名排序固定。
        #expect(asUTF8.contains("\"maxViews\":3"))
        #expect(asUTF8.contains("\"kind\":\"text\""))
    }

    @Test func inspectReadsMetadataWithoutShareCode() throws {
        let expiresAt = fixedNow.addingTimeInterval(7200)
        let sealed = try MonicaSendPackage.seal(
            policy: makePolicy(kind: .file, title: "合同草稿", fileName: "draft.docx", mediaType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", expiresAt: expiresAt, maxViews: 2),
            content: Data("draft".utf8),
            now: fixedNow
        )

        let descriptor = try MonicaSendPackage.inspect(sealed.data)
        #expect(descriptor.policy.title == "合同草稿")
        #expect(descriptor.policy.fileName == "draft.docx")
        #expect(descriptor.policy.maxViews == 2)
        #expect(descriptor.policy.expiresAt == expiresAt)
        #expect(descriptor.isExpired(at: fixedNow.addingTimeInterval(10)) == false)
        #expect(descriptor.isExpired(at: expiresAt.addingTimeInterval(1)))
    }

    // MARK: 认证与篡改

    @Test func rejectsWrongShareCode() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = makeLedger(in: directory)
        let sealed = try MonicaSendPackage.seal(policy: makePolicy(), content: Data("秘密".utf8), now: fixedNow)

        #expect(throws: MonicaSendPackageError.authenticationFailed) {
            _ = try MonicaSendPackage.open(
                sealed.data,
                code: MonicaSendCode.generate(),
                ledger: ledger,
                now: fixedNow,
                isVaultLocked: false
            )
        }
        // 打开失败不能消耗查看次数。
        let descriptor = try MonicaSendPackage.inspect(sealed.data)
        #expect(try ledger.record(for: descriptor.ledgerKey) == nil)
    }

    @Test func rejectsTamperedCiphertext() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = makeLedger(in: directory)
        let sealed = try MonicaSendPackage.seal(policy: makePolicy(), content: Data("机密内容".utf8), now: fixedNow)

        var tampered = sealed.data
        tampered[tampered.count - 1] ^= 0xFF

        #expect(throws: MonicaSendPackageError.authenticationFailed) {
            _ = try MonicaSendPackage.open(
                tampered,
                code: sealed.code,
                ledger: ledger,
                now: fixedNow,
                isVaultLocked: false
            )
        }
    }

    @Test func rejectsTamperedHeaderMetadata() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = makeLedger(in: directory)
        let sealed = try MonicaSendPackage.seal(policy: makePolicy(maxViews: 1), content: Data("一次性消息".utf8), now: fixedNow)

        // 把头部里的 maxViews 从 1 改成 9：JSON 仍可解析，但 AAD 变了，必须解密失败。
        let original = Data("\"maxViews\":1".utf8)
        let replacement = Data("\"maxViews\":9".utf8)
        guard let range = sealed.data.range(of: original) else {
            Issue.record("未在分享包头部找到 maxViews 字段")
            return
        }
        var tampered = sealed.data
        tampered.replaceSubrange(range, with: replacement)

        #expect(throws: MonicaSendPackageError.authenticationFailed) {
            _ = try MonicaSendPackage.open(
                tampered,
                code: sealed.code,
                ledger: ledger,
                now: fixedNow,
                isVaultLocked: false
            )
        }
    }

    @Test func rejectsCorruptedContainers() throws {
        #expect(throws: MonicaSendPackageError.invalidContainer) {
            _ = try MonicaSendPackage.inspect(Data())
        }
        #expect(throws: MonicaSendPackageError.invalidContainer) {
            _ = try MonicaSendPackage.inspect(Data("MNS1".utf8))
        }
        let sealed = try MonicaSendPackage.seal(policy: makePolicy(), content: Data("x".utf8), now: fixedNow)
        var wrongMagic = sealed.data
        wrongMagic[0] = 0x58 // 'X'
        #expect(throws: MonicaSendPackageError.invalidContainer) {
            _ = try MonicaSendPackage.inspect(wrongMagic)
        }
        #expect(throws: MonicaSendPackageError.invalidContainer) {
            _ = try MonicaSendPackage.inspect(sealed.data.prefix(sealed.data.count - 8))
        }
    }

    @Test func reportsUnsupportedVersion() throws {
        let sealed = try MonicaSendPackage.seal(policy: makePolicy(), content: Data("v".utf8), now: fixedNow)
        guard let range = sealed.data.range(of: Data("\"v\":1".utf8)) else {
            Issue.record("未找到版本字段")
            return
        }
        var upgraded = sealed.data
        upgraded.replaceSubrange(range, with: Data("\"v\":2".utf8))
        #expect(throws: MonicaSendPackageError.unsupportedVersion(2)) {
            _ = try MonicaSendPackage.inspect(upgraded)
        }
    }

    // MARK: 次数与过期

    @Test func destroysPackageAfterViewLimit() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = makeLedger(in: directory)
        let sealed = try MonicaSendPackage.seal(policy: makePolicy(maxViews: 2), content: Data("只给看两次".utf8), now: fixedNow)

        let first = try MonicaSendPackage.open(sealed.data, code: sealed.code, ledger: ledger, now: fixedNow, isVaultLocked: false)
        #expect(first.remainingViews == 1)
        let second = try MonicaSendPackage.open(sealed.data, code: sealed.code, ledger: ledger, now: fixedNow.addingTimeInterval(1), isVaultLocked: false)
        #expect(second.remainingViews == 0)

        #expect(throws: MonicaSendPackageError.viewLimitReached(maxViews: 2)) {
            _ = try MonicaSendPackage.open(sealed.data, code: sealed.code, ledger: ledger, now: fixedNow.addingTimeInterval(2), isVaultLocked: false)
        }
        let descriptor = try MonicaSendPackage.inspect(sealed.data)
        let record = try #require(try ledger.record(for: descriptor.ledgerKey))
        #expect(record.openCount == 2)
        #expect(record.firstOpenedAt == fixedNow)
        #expect(record.lastOpenedAt == fixedNow.addingTimeInterval(1))
    }

    @Test func refusesExpiredPackage() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = makeLedger(in: directory)
        let expiresAt = fixedNow.addingTimeInterval(60)
        let sealed = try MonicaSendPackage.seal(policy: makePolicy(expiresAt: expiresAt), content: Data("过期内容".utf8), now: fixedNow)

        #expect(throws: MonicaSendPackageError.expired(expiresAt: expiresAt)) {
            _ = try MonicaSendPackage.open(
                sealed.data,
                code: sealed.code,
                ledger: ledger,
                now: expiresAt.addingTimeInterval(1),
                isVaultLocked: false
            )
        }
        // 刚好到期也算过期。
        #expect(throws: MonicaSendPackageError.expired(expiresAt: expiresAt)) {
            _ = try MonicaSendPackage.open(
                sealed.data,
                code: sealed.code,
                ledger: ledger,
                now: expiresAt,
                isVaultLocked: false
            )
        }
        let descriptor = try MonicaSendPackage.inspect(sealed.data)
        #expect(try ledger.record(for: descriptor.ledgerKey) == nil)
    }

    @Test func refusesToDecryptWhenVaultIsLocked() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = makeLedger(in: directory)
        let sealed = try MonicaSendPackage.seal(policy: makePolicy(), content: Data("锁定态".utf8), now: fixedNow)

        #expect(throws: MonicaSendPackageError.vaultLocked) {
            _ = try MonicaSendPackage.open(
                sealed.data,
                code: sealed.code,
                ledger: ledger,
                now: fixedNow,
                isVaultLocked: true
            )
        }
        let descriptor = try MonicaSendPackage.inspect(sealed.data)
        #expect(try ledger.record(for: descriptor.ledgerKey) == nil)
    }

    @Test func ledgerFailsClosedWhenUnreadable() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = makeLedger(in: directory)
        try Data("{ not json".utf8).write(to: ledger.fileURL)
        let sealed = try MonicaSendPackage.seal(policy: makePolicy(), content: Data("账本损坏".utf8), now: fixedNow)

        #expect(throws: MonicaSendPackageError.consumptionLedgerUnavailable) {
            _ = try MonicaSendPackage.open(sealed.data, code: sealed.code, ledger: ledger, now: fixedNow, isVaultLocked: false)
        }
    }

    @Test func regeneratedPackageStartsWithFreshViewCount() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = makeLedger(in: directory)
        let first = try MonicaSendPackage.seal(policy: makePolicy(maxViews: 1), content: Data("第一版".utf8), now: fixedNow)
        _ = try MonicaSendPackage.open(first.data, code: first.code, ledger: ledger, now: fixedNow, isVaultLocked: false)
        #expect(throws: MonicaSendPackageError.viewLimitReached(maxViews: 1)) {
            _ = try MonicaSendPackage.open(first.data, code: first.code, ledger: ledger, now: fixedNow, isVaultLocked: false)
        }

        // 同一个 Send 重新生成分享包：新包有自己的创建时间，因此次数从头算。
        let node = fixedNow.addingTimeInterval(300)
        let second = try MonicaSendPackage.seal(
            policy: makePolicy(createdAt: node, maxViews: 1),
            content: Data("第二版".utf8),
            now: node
        )
        let opened = try MonicaSendPackage.open(second.data, code: second.code, ledger: ledger, now: node, isVaultLocked: false)
        #expect(opened.remainingViews == 0)
        #expect(opened.content == Data("第二版".utf8))
    }

    @Test func remainingViewsHelperReportsNilForBrokenLedger() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = makeLedger(in: directory)
        let sealed = try MonicaSendPackage.seal(policy: makePolicy(maxViews: 5), content: Data("n".utf8), now: fixedNow)
        let descriptor = try MonicaSendPackage.inspect(sealed.data)
        #expect(MonicaSendPackage.remainingViews(for: descriptor, ledger: ledger) == 5)

        _ = try MonicaSendPackage.open(sealed.data, code: sealed.code, ledger: ledger, now: fixedNow, isVaultLocked: false)
        #expect(MonicaSendPackage.remainingViews(for: descriptor, ledger: ledger) == 4)

        try Data("broken".utf8).write(to: ledger.fileURL)
        #expect(MonicaSendPackage.remainingViews(for: descriptor, ledger: ledger) == nil)
    }

    // MARK: 分享码与链接

    @Test func shareCodeRoundTripsThroughLinkFragment() throws {
        let sealed = try MonicaSendPackage.seal(policy: makePolicy(), content: Data("链接".utf8), now: fixedNow)
        let link = try sealed.makeLink()

        #expect(link.absoluteString == "monica://send/send-entry-1#\(sealed.code.encoded)")
        #expect(!link.absoluteString.contains("?"))
        let fragment = try #require(link.absoluteString.split(separator: "#").last.map(String.init))
        #expect(fragment == sealed.code.encoded)

        let parsed = try #require(MonicaSendLink(string: link.absoluteString))
        #expect(parsed.packageID == "send-entry-1")
        #expect(parsed.code == sealed.code)
        #expect(try parsed.makeURL() == link.makeURL())
        #expect(try MonicaSendCode.parse(link.absoluteString) == sealed.code)
    }

    @Test func parsesShareCodeWithWhitespaceAndPadding() throws {
        let code = MonicaSendCode.generate()
        #expect(try MonicaSendCode.parse(code.encoded) == code)
        #expect(try MonicaSendCode.parse("  \(code.encoded)\n") == code)
        #expect(try MonicaSendCode.parse("\(code.encoded.prefix(20)) \(code.encoded.dropFirst(20))") == code)

        #expect(throws: MonicaSendPackageError.invalidCode) {
            _ = try MonicaSendCode.parse("")
        }
        #expect(throws: MonicaSendPackageError.invalidCode) {
            _ = try MonicaSendCode.parse("not-a-share-code")
        }
        #expect(throws: MonicaSendPackageError.invalidCode) {
            _ = try MonicaSendCode(token: Data(repeating: 1, count: 16))
        }
    }

    @Test func rejectsMalformedLinks() {
        #expect(MonicaSendLink(string: "monica://send/only-id") == nil)
        #expect(MonicaSendLink(string: "monica://send/#abc") == nil)
        #expect(MonicaSendLink(string: "https://example.com/send/abc#def") == nil)
        #expect(MonicaSendLink(string: "monica://open/send-entry-1#\(MonicaSendCode.generate().encoded)") == nil)
    }

    // MARK: 参数校验

    @Test func rejectsInvalidPolicies() throws {
        let content = Data("内容".utf8)
        #expect(throws: MonicaSendPackageError.self) {
            _ = try MonicaSendPackage.seal(policy: makePolicy(title: "   "), content: content, now: fixedNow)
        }
        #expect(throws: MonicaSendPackageError.self) {
            _ = try MonicaSendPackage.seal(policy: makePolicy(maxViews: 0), content: content, now: fixedNow)
        }
        #expect(throws: MonicaSendPackageError.self) {
            _ = try MonicaSendPackage.seal(policy: makePolicy(maxViews: 1000), content: content, now: fixedNow)
        }
        #expect(throws: MonicaSendPackageError.self) {
            _ = try MonicaSendPackage.seal(policy: makePolicy(expiresAt: fixedNow.addingTimeInterval(-1)), content: content, now: fixedNow)
        }
        #expect(throws: MonicaSendPackageError.self) {
            _ = try MonicaSendPackage.seal(policy: makePolicy(), content: Data(), now: fixedNow)
        }
        #expect(throws: MonicaSendPackageError.self) {
            _ = try MonicaSendPackage.seal(policy: makePolicy(id: "bad id/with slash"), content: content, now: fixedNow)
        }
    }

    // MARK: 过期时间解析

    @Test func parsesSendExpiryText() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let timeZone = calendar.timeZone

        let dateOnly = try #require(MonicaSendExpiry.date(from: "2026-12-31", calendar: calendar, timeZone: timeZone))
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: dateOnly)
        #expect(components.year == 2026)
        #expect(components.month == 12)
        #expect(components.day == 31)
        #expect(components.hour == 23)
        #expect(components.minute == 59)
        #expect(components.second == 59)

        let dateTime = try #require(MonicaSendExpiry.date(from: "2026-12-31 18:30", calendar: calendar, timeZone: timeZone))
        components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: dateTime)
        #expect(components.year == 2026)
        #expect(components.month == 12)
        #expect(components.day == 31)
        #expect(components.hour == 18)
        #expect(components.minute == 30)

        #expect(MonicaSendExpiry.date(from: "", calendar: calendar, timeZone: timeZone) == nil)
        #expect(MonicaSendExpiry.date(from: "明天中午", calendar: calendar, timeZone: timeZone) == nil)
        let iso = try #require(MonicaSendExpiry.date(from: "2026-12-31T10:00:00+08:00", calendar: calendar, timeZone: timeZone))
        #expect(iso.timeIntervalSince1970 == 1_798_682_400)
    }

    @Test func makePolicyHelperUsesFixedClock() {
        // 防止脚手架漂移：所有测试都依赖 fixedNow。
        #expect(makePolicy().createdAt == fixedNow)
        #expect(makePolicy().maxViews == 3)
    }

    // MARK: 撤销

    @Test func revokedPackageCannotBeOpenedAgain() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = makeLedger(in: directory)
        let sealed = try MonicaSendPackage.seal(policy: makePolicy(maxViews: 5), content: Data("撤销后作废".utf8), now: fixedNow)
        let descriptor = try MonicaSendPackage.inspect(sealed.data)

        let opened = try MonicaSendPackage.open(sealed.data, code: sealed.code, ledger: ledger, now: fixedNow, isVaultLocked: false)
        #expect(opened.remainingViews == 4)

        try ledger.registerRevocation(for: descriptor.ledgerKey, at: fixedNow.addingTimeInterval(2))
        #expect(MonicaSendPackage.remainingViews(for: descriptor, ledger: ledger) == 0)
        #expect(throws: MonicaSendPackageError.viewLimitReached(maxViews: 5)) {
            _ = try MonicaSendPackage.open(
                sealed.data,
                code: sealed.code,
                ledger: ledger,
                now: fixedNow.addingTimeInterval(3),
                isVaultLocked: false
            )
        }
        // 撤销记录保留在账本里：删掉本机分享包后再导入副本仍然解不开。
        #expect(try ledger.record(for: descriptor.ledgerKey)?.openCount == Int.max)
    }
}
