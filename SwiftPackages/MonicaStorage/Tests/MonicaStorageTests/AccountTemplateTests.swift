import Foundation
import Testing

@testable import MonicaStorage

// MARK: - 内置模板目录

@Suite struct AccountTemplateCatalogTests {
    @Test func coversTheCommonServicesRequiredByTheIssue() {
        let builtins = AccountTemplateCatalog.builtins
        #expect(builtins.count >= 8)
        #expect(Set(builtins.map(\.templateID)).count == builtins.count)
        #expect(builtins.allSatisfy { $0.isBuiltin })
        #expect(builtins.allSatisfy { $0.itemKind == .login })
        #expect(builtins.allSatisfy { AccountTemplateCatalog.isBuiltinTemplateID($0.templateID) })

        let titles = builtins.map(\.title).joined(separator: "|")
        for keyword in ["Apple", "Google", "GitHub", "Microsoft", "银行", "运营商", "政务", "邮箱"] {
            #expect(titles.contains(keyword), "内置模板缺少 \(keyword)")
        }

        // 展示顺序连续，排序稳定。
        #expect(builtins.map(\.sortOrder) == Array(0..<builtins.count))
        #expect(AccountTemplateCatalog.builtins(for: .login).count == builtins.count)
        #expect(AccountTemplateCatalog.builtins(for: .totp).isEmpty)
    }

    @Test func builtinTemplatesCarryNoSensitiveFields() {
        let allowedKeys: Set<String> = [
            "templateID", "title", "itemKind", "defaultURLs",
            "usernamePlaceholder", "defaultNotes", "defaultCustomFields", "requiresTOTP"
        ]
        for template in AccountTemplateCatalog.builtins {
            let keys = Set(template.exportObject().keys)
            #expect(keys == allowedKeys, "\(template.templateID) 的导出字段多出了敏感键：\(keys.subtracting(allowedKeys))")

            // 模板里不能出现隐藏字段（那是条目自定义字段的受保护类型）。
            #expect(template.defaultCustomFields.allSatisfy { !$0.kind.isProtected })
            // 字段只有名字和默认值，没有值的模板也不该带任何密码。
            #expect(template.defaultCustomFields.allSatisfy { $0.defaultValue.isEmpty })
            // 模板本身不存密码：载荷 JSON 里没有 password/secret/token 键。
            let payload = (try? template.payloadJSONString()) ?? ""
            let lowered = payload.lowercased()
            for forbidden in ["\"password\"", "\"secret\"", "\"token\"", "\"privatekey\"", "\"passcode\""] {
                #expect(!lowered.contains(forbidden), "\(template.templateID) 载荷里出现了 \(forbidden)")
            }
        }
    }
}

// MARK: - 模型归一化

@Suite struct AccountTemplateNormalizationTests {
    @Test func trimsAndValidatesFields() throws {
        let template = AccountTemplate(
            templateID: "  t-1  ",
            title: "  示例模板  ",
            defaultURLs: [" https://example.com/login ", "https://example.com/login", ""],
            usernamePlaceholder: "  昵称  ",
            defaultNotes: "  说明  ",
            defaultCustomFields: [
                AccountTemplateCustomField(label: "  手机号  "),
                AccountTemplateCustomField(label: "手机号", defaultValue: "重复项"),
                AccountTemplateCustomField(label: "   ")
            ],
            sortOrder: -3
        )
        let normalized = try template.normalized()
        #expect(normalized.templateID == "t-1")
        #expect(normalized.title == "示例模板")
        #expect(normalized.defaultURLs == ["https://example.com/login"])
        #expect(normalized.usernamePlaceholder == "昵称")
        #expect(normalized.defaultNotes == "说明")
        #expect(normalized.defaultCustomFields.map(\.label) == ["手机号"])
        #expect(normalized.schemaVersion == AccountTemplate.currentSchemaVersion)
        #expect(normalized.isBuiltin == false)
    }

    @Test func rejectsInvalidContent() throws {
        #expect(throws: AccountTemplateError.emptyTitle) {
            _ = try AccountTemplate(title: "   ").normalized()
        }
        #expect(throws: AccountTemplateError.titleTooLong(limit: AccountTemplateRules.maxTitleLength)) {
            _ = try AccountTemplate(title: String(repeating: "长", count: 81)).normalized()
        }
        #expect(throws: AccountTemplateError.invalidURL("ftp://example.com")) {
            _ = try AccountTemplate(title: "T", defaultURLs: ["ftp://example.com"]).normalized()
        }
        #expect(throws: AccountTemplateError.tooManyURLs(limit: AccountTemplateRules.maxURLCount)) {
            let urls = (0...AccountTemplateRules.maxURLCount).map { "https://example.com/\($0)" }
            _ = try AccountTemplate(title: "T", defaultURLs: urls).normalized()
        }
        #expect(throws: AccountTemplateError.protectedCustomFieldUnsupported) {
            _ = try AccountTemplate(
                title: "T",
                defaultCustomFields: [AccountTemplateCustomField(label: "恢复码", kind: .hiddenText)]
            ).normalized()
        }
        #expect(throws: AccountTemplateError.emptyCustomFieldLabel) {
            _ = try AccountTemplateCustomField(label: "  ").normalized()
        }
        // 编辑器里留下的空字段行会被跳过，而不是让整条模板保存失败。
        let blankLabelTemplate = try AccountTemplate(
            title: "T",
            defaultCustomFields: [
                AccountTemplateCustomField(label: "  "),
                AccountTemplateCustomField(label: "地区")
            ]
        ).normalized()
        #expect(blankLabelTemplate.defaultCustomFields.map(\.label) == ["地区"])
    }

    @Test func emptyTitleFallsBackToPlaceholder() {
        #expect(AccountTemplate(title: "  ").displayTitle == "未命名模板")
        #expect(AccountTemplate(title: "T", defaultURLs: ["https://github.com/login"]).urlSummary == "github.com")
        #expect(AccountTemplate(title: "T").urlSummary == "未预设网址")
    }
}

// MARK: - 侧表载荷

@Suite struct AccountTemplatePayloadTests {
    private func sampleTemplate() -> AccountTemplate {
        AccountTemplate(
            templateID: "payload-1",
            title: "示例",
            defaultURLs: ["https://example.com/"],
            usernamePlaceholder: "邮箱",
            defaultNotes: "备注",
            defaultCustomFields: [
                AccountTemplateCustomField(label: "地区", kind: .text, defaultValue: "中国"),
                AccountTemplateCustomField(label: "官网", kind: .url, defaultValue: "https://example.com")
            ],
            requiresTOTP: true,
            sortOrder: 3,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    @Test func payloadJSONRoundTrips() throws {
        let original = sampleTemplate()
        let json = try original.payloadJSONString()
        let decoded = try #require(AccountTemplate(payloadJSON: json, fallbackTemplateID: original.templateID))
        #expect(decoded == original)
    }

    @Test func brokenPayloadFallsBackToIDOnlyRecord() throws {
        let decoded = try #require(AccountTemplate(payloadJSON: "{not json", fallbackTemplateID: "keep-me"))
        #expect(decoded.templateID == "keep-me")
        #expect(decoded.title.isEmpty)
        #expect(decoded.displayTitle == "未命名模板")
        #expect(decoded.itemKind == .login)

        #expect(AccountTemplate(payloadJSON: "", fallbackTemplateID: "") == nil)
    }

    @Test func payloadDropsProtectedAndNamelessFields() throws {
        let json = """
        {"templateID":"t","title":"T","defaultCustomFields":[
          {"label":"恢复码","kind":"hiddenText","defaultValue":"123456"},
          {"label":"","kind":"text"},
          {"label":"地区","kind":"unknown-kind","defaultValue":"中国"}
        ]}
        """
        let decoded = try #require(AccountTemplate(payloadJSON: json, fallbackTemplateID: "t"))
        #expect(decoded.defaultCustomFields.map(\.label) == ["地区"])
        #expect(decoded.defaultCustomFields.first?.kind == .text)
    }
}

// MARK: - 套用模板

@Suite struct AccountTemplateFillTests {
    @Test func fillsOnlyBlankFieldsAndKeepsUserInput() {
        let template = AccountTemplate(
            templateID: "fill-1",
            title: "GitHub",
            defaultURLs: ["https://github.com/login", "https://github.com/settings/tokens"],
            usernamePlaceholder: "GitHub 用户名",
            defaultNotes: "模板备注",
            defaultCustomFields: [
                AccountTemplateCustomField(label: "所属组织"),
                AccountTemplateCustomField(label: "安全邮箱")
            ],
            requiresTOTP: true
        )
        let draft = AccountTemplateFillDraft(
            title: "我的工作账号",
            urls: ["https://github.com/login"],
            username: "someone",
            notes: "我自己写的备注",
            customFieldLabels: ["所属组织"]
        )
        let outcome = AccountTemplateFill.apply(template, to: draft)

        // 用户已填的标题/账号/备注不被模板覆盖。
        #expect(outcome.title == "我的工作账号")
        #expect(outcome.username == "someone")
        #expect(outcome.notes == "我自己写的备注")
        // URL 取并集并保序去重。
        #expect(outcome.urls == ["https://github.com/login", "https://github.com/settings/tokens"])
        // 同名字段不重复新增。
        #expect(outcome.customFieldsToAdd.map(\.label) == ["安全邮箱"])
        #expect(outcome.usernamePlaceholder == "GitHub 用户名")
        #expect(outcome.requiresTOTP)
        #expect(outcome.hasChanges)
        // 标题/备注没被填，只有 URL 算一个。
        #expect(outcome.filledFieldCount == 1)
    }

    @Test func fillsEverythingWhenTheDraftIsEmpty() {
        let template = AccountTemplate(
            templateID: "fill-2",
            title: "示例",
            defaultURLs: ["https://example.com/"],
            defaultNotes: "说明",
            defaultCustomFields: [AccountTemplateCustomField(label: "地区")]
        )
        let outcome = AccountTemplateFill.apply(template, to: AccountTemplateFillDraft())
        #expect(outcome.title == "示例")
        #expect(outcome.notes == "说明")
        #expect(outcome.urls == ["https://example.com/"])
        #expect(outcome.customFieldsToAdd.count == 1)
        #expect(outcome.filledFieldCount == 3)
    }

    @Test func alreadyFilledDraftIsLeftAlone() {
        // 标题已经和模板一致、模板又没有网址/备注/字段时，套用是空操作。
        let outcome = AccountTemplateFill.apply(
            AccountTemplate(title: "空模板"),
            to: AccountTemplateFillDraft(title: "空模板")
        )
        #expect(!outcome.hasChanges)
        #expect(outcome.filledFieldCount == 0)
    }
}

// MARK: - JSON 导入/导出

@Suite struct AccountTemplateCodecTests {
    private func template(_ id: String, _ title: String, kind: UnifiedVaultItemKind = .login) -> AccountTemplate {
        AccountTemplate(
            templateID: id,
            title: title,
            itemKind: kind,
            defaultURLs: ["https://example.com/\(id)"],
            usernamePlaceholder: "账号",
            defaultNotes: "备注",
            defaultCustomFields: [AccountTemplateCustomField(label: "地区", defaultValue: "中国")],
            requiresTOTP: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test func exportAndPreviewRoundTrip() throws {
        let original = [template("t-1", "模板一"), template("t-2", "模板二", kind: .note)]
        let data = try AccountTemplateCodec.export(templates: original, now: Date(timeIntervalSince1970: 1_700_000_000))
        let summary = AccountTemplateCodec.preview(data: data)

        #expect(summary.formatVersion == AccountTemplateCodec.schemaVersion)
        #expect(summary.sourceTemplateCount == 2)
        #expect(summary.skippedTemplateCount == 0)
        #expect(summary.conflictCount == 0)
        #expect(summary.issues.isEmpty)
        #expect(summary.canImport)
        #expect(!summary.isEmptyFile)
        #expect(summary.exportedAt != nil)

        #expect(summary.templates.map(\.templateID) == ["t-1", "t-2"])
        #expect(summary.templates.map(\.title) == ["模板一", "模板二"])
        #expect(summary.templates.map(\.itemKind) == [.login, .note])
        #expect(summary.templates[0].defaultURLs == ["https://example.com/t-1"])
        #expect(summary.templates[0].defaultCustomFields.first?.defaultValue == "中国")
        #expect(summary.templates[0].requiresTOTP)
        #expect(summary.templates.allSatisfy { !$0.isBuiltin })
    }

    @Test func suggestedFileNameMatchesTheImportExportStyle() {
        let name = AccountTemplateCodec.suggestedFileName(now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(name.hasPrefix("Monica-Account-Templates-"))
        #expect(name.hasSuffix(".json"))
        #expect(name.count == "Monica-Account-Templates-yyyyMMdd-HHmmss.json".count)
    }

    @Test func reportsFileLevelProblems() {
        let tooLarge = Data(repeating: 0x61, count: AccountTemplateCodec.maximumFileSizeBytes + 1)
        let largeSummary = AccountTemplateCodec.preview(data: tooLarge)
        #expect(largeSummary.templates.isEmpty)
        #expect(largeSummary.issues.map(\.code) == [.fileTooLarge])

        let emptySummary = AccountTemplateCodec.preview(data: Data())
        #expect(emptySummary.templates.isEmpty)
        #expect(emptySummary.isEmptyFile)
        #expect(emptySummary.issues.map(\.code) == [.malformedJSON])

        let malformed = AccountTemplateCodec.preview(data: Data("hello".utf8))
        #expect(malformed.templates.isEmpty)
        #expect(malformed.issues.map(\.code) == [.malformedJSON])

        let wrongFormat = AccountTemplateCodec.preview(
            data: Data(#"{"format":"monica-vault","schemaVersion":1,"templates":[]}"#.utf8)
        )
        #expect(wrongFormat.templates.isEmpty)
        #expect(wrongFormat.issues.map(\.code) == [.unrecognizedFormat])

        let futureVersion = AccountTemplateCodec.preview(
            data: Data(#"{"format":"monica-account-templates","schemaVersion":9,"templates":[]}"#.utf8)
        )
        #expect(futureVersion.templates.isEmpty)
        #expect(futureVersion.issues.map(\.code) == [.unsupportedVersion])

        let noTemplates = AccountTemplateCodec.preview(
            data: Data(#"{"format":"monica-account-templates","schemaVersion":1,"templates":[]}"#.utf8)
        )
        #expect(noTemplates.templates.isEmpty)
        #expect(!noTemplates.canImport)
    }

    @Test func skipsInvalidRowsButKeepsGoodOnes() throws {
        let json = """
        {
          "format": "monica-account-templates",
          "schemaVersion": 1,
          "templates": [
            {"title": "正常", "defaultURLs": ["https://example.com/"], "itemKind": "login"},
            {"title": "  "},
            {"title": "坏类型", "itemKind": "spaceship"},
            {"title": "坏字段", "defaultCustomFields": [{"label": "恢复码", "kind": "hiddenText"}]},
            {"title": "坏链接", "defaultURLs": ["javascript:alert(1)"]},
            {"title": "正常", "defaultURLs": ["https://example.com/"], "itemKind": "login"}
          ]
        }
        """
        // 两条「正常」用了随机 ID，内容相同也算不同记录；这里给它们固定 ID 才有冲突语义。
        let rewritten = json.replacingOccurrences(
            of: #"{"title": "正常""#,
            with: #"{"templateID": "dup", "title": "正常""#
        )
        let summary = AccountTemplateCodec.preview(data: Data(rewritten.utf8))
        #expect(summary.sourceTemplateCount == 6)
        #expect(summary.templates.count == 1)
        #expect(summary.templates.first?.title == "正常")
        #expect(summary.skippedTemplateCount == 5)
        #expect(summary.conflictCount == 1)

        let codes = summary.issues.map(\.code)
        #expect(codes.contains(.missingRequiredField))
        #expect(codes.contains(.unsupportedItemKind))
        #expect(codes.contains(.invalidField))
        #expect(codes.contains(.duplicateItem))
        // 空标题的问题要指向具体字段，便于 UI 展示。
        let emptyTitleIssue = try #require(summary.issues.first { $0.code == .missingRequiredField })
        #expect(emptyTitleIssue.field == "title")
        #expect(emptyTitleIssue.sourceIndex == 1)
    }

    @Test func honorsExistingConflictsAndOverwrite() {
        let data = (try? AccountTemplateCodec.export(templates: [template("t-1", "模板一")])) ?? Data()
        let conflicting = AccountTemplateCodec.preview(
            data: data,
            options: AccountTemplateImportOptions(existingTemplateIDs: ["t-1"])
        )
        #expect(conflicting.templates.isEmpty)
        #expect(conflicting.conflictCount == 1)
        #expect(conflicting.issues.map(\.code) == [.duplicateItem])

        let overwritten = AccountTemplateCodec.preview(
            data: data,
            options: AccountTemplateImportOptions(existingTemplateIDs: ["t-1"], overwriteExisting: true)
        )
        #expect(overwritten.templates.map(\.templateID) == ["t-1"])
        #expect(overwritten.conflictCount == 0)
    }

    @Test func builtinIDsAreImportedAsCopies() throws {
        let json = """
        {"format":"monica-account-templates","schemaVersion":1,"templates":[
          {"templateID":"builtin.apple","title":"Apple 账户","isBuiltin":true}
        ]}
        """
        let summary = AccountTemplateCodec.preview(data: Data(json.utf8))
        #expect(summary.templates.count == 1)
        let imported = try #require(summary.templates.first)
        #expect(imported.templateID != "builtin.apple")
        #expect(!imported.isBuiltin)
        #expect(!AccountTemplateCatalog.isBuiltinTemplateID(imported.templateID))
        #expect(summary.issues.map(\.code) == [.skippedValue])
    }
}

// MARK: - 真引擎集成（MDBX）

@Suite(.serialized) struct AccountTemplateRepositoryTests {
    private let password = "模板 password 12345!"
    private let deviceID = "account-template-tests"

    private func temporaryVaultURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-templates-\(UUID().uuidString)", isDirectory: true)
    }

    private func vaultFileURL(in directory: URL) -> URL {
        directory.appendingPathComponent("Templates.mdbx", isDirectory: false)
    }

    private func makeVault(at url: URL) throws -> (session: LocalVaultSession, entries: LocalVaultEntryRepository) {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let engine = MDBXLocalVaultEngine()
        let vaultRepository = LocalVaultRepository(engine: engine)
        let session = try vaultRepository.createVault(
            named: "Templates",
            in: url,
            password: password,
            deviceID: deviceID
        )
        return (session, LocalVaultEntryRepository(session: session, engine: engine))
    }

    private func reopen(at url: URL) throws -> (session: LocalVaultSession, entries: LocalVaultEntryRepository) {
        let engine = MDBXLocalVaultEngine()
        let vaultRepository = LocalVaultRepository(engine: engine)
        let session = try vaultRepository.openVault(
            at: vaultFileURL(in: url),
            password: password,
            deviceID: deviceID
        )
        return (session, LocalVaultEntryRepository(session: session, engine: engine))
    }

    private func template(_ title: String, sortOrder: Int = 0) -> AccountTemplate {
        AccountTemplate(
            title: title,
            defaultURLs: ["https://example.com/"],
            usernamePlaceholder: "账号",
            defaultNotes: "备注",
            defaultCustomFields: [AccountTemplateCustomField(label: "地区")],
            requiresTOTP: true,
            sortOrder: sortOrder
        )
    }

    @Test func savesLoadsAndReopensTemplates() throws {
        let url = temporaryVaultURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (session, entries) = try makeVault(at: url)
        let repository = AccountTemplateRepository(
            entryRepository: entries,
            session: session,
            anchorStore: InMemoryVaultFolderAnchorStore()
        )

        let saved = try repository.save(template("模板一"))
        #expect(saved.isBuiltin == false)
        #expect(saved.sortOrder == 0)
        #expect(try repository.customTemplateCount() == 1)

        let second = try repository.save(template("模板二"))
        #expect(second.sortOrder == 1)

        let all = try repository.allTemplates()
        #expect(all.count == 2 + AccountTemplateCatalog.builtins.count)
        #expect(all.first?.isBuiltin == true)
        #expect(try repository.templates(for: .login).count == all.count)

        let anchorProjectID = try #require(repository.existingAnchorProjectID())
        let reopened = try reopen(at: url)
        let reopenedRepository = AccountTemplateRepository(
            entryRepository: reopened.entries,
            session: reopened.session,
            anchorStore: InMemoryVaultFolderAnchorStore()
        )
        #expect(reopenedRepository.existingAnchorProjectID() == nil)
        // 锚点存在内存里，重开后第一次调用会新建锚点工程——旧锚点里的记录不会丢，
        // 但这里只断言同一个会话内的持久化：直接读同一个锚点工程。
        let records = try reopened.entries.listAccountTemplates(anchorProjectID: anchorProjectID)
        #expect(records.map(\.title).sorted() == ["模板一", "模板二"])
    }

    @Test func updateKeepsOriginalOrderAndCreationDate() throws {
        let url = temporaryVaultURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (session, entries) = try makeVault(at: url)
        let repository = AccountTemplateRepository(entryRepository: entries, session: session)

        let first = try repository.save(template("模板一"))
        _ = try repository.save(template("模板二"))

        var edited = first
        edited.title = "模板一（改）"
        edited.sortOrder = 99
        edited.createdAt = Date(timeIntervalSince1970: 100)
        let saved = try repository.save(edited)

        #expect(saved.title == "模板一（改）")
        #expect(saved.sortOrder == first.sortOrder)
        // 侧表用 JSON 里的 timeIntervalSince1970 存日期，Double 精度会带来亚微秒级差异。
        #expect(abs(saved.createdAt.timeIntervalSince(first.createdAt)) < 0.001)
        #expect(try repository.customTemplates().map(\.title) == ["模板一（改）", "模板二"])
    }

    @Test func reordersCustomTemplatesAndKeepsUnknownIDsLast() throws {
        let url = temporaryVaultURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (session, entries) = try makeVault(at: url)
        let repository = AccountTemplateRepository(entryRepository: entries, session: session)

        let a = try repository.save(template("A"))
        let b = try repository.save(template("B"))
        let c = try repository.save(template("C"))
        try repository.reorder(customTemplateIDs: [c.templateID, a.templateID, "not-exist"])

        let ordered = try repository.customTemplates()
        #expect(ordered.map(\.templateID) == [c.templateID, a.templateID, b.templateID])
        #expect(ordered.map(\.sortOrder) == [0, 1, 2])
    }

    @Test func deletesTemplateAndIsIdempotent() throws {
        let url = temporaryVaultURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (session, entries) = try makeVault(at: url)
        let repository = AccountTemplateRepository(entryRepository: entries, session: session)

        let saved = try repository.save(template("待删除"))
        try repository.delete(templateID: saved.templateID)
        #expect(try repository.customTemplates().isEmpty)

        // 再删一次不报错，也不影响别的模板。
        _ = try repository.save(template("保留"))
        try repository.delete(templateID: saved.templateID)
        #expect(try repository.customTemplates().map(\.title) == ["保留"])
    }

    @Test func builtinTemplatesAreReadOnly() throws {
        let url = temporaryVaultURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (session, entries) = try makeVault(at: url)
        let repository = AccountTemplateRepository(entryRepository: entries, session: session)

        let builtin = try #require(AccountTemplateCatalog.builtins.first)
        #expect(throws: AccountTemplateError.builtinTemplateReadOnly) {
            _ = try repository.save(builtin)
        }
        #expect(throws: AccountTemplateError.builtinTemplateReadOnly) {
            try repository.delete(templateID: builtin.templateID)
        }
    }

    @Test func duplicateAsCustomGetsNewIdentity() throws {
        let url = temporaryVaultURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (session, entries) = try makeVault(at: url)
        let repository = AccountTemplateRepository(entryRepository: entries, session: session)

        let builtin = try #require(AccountTemplateCatalog.builtins.first)
        let copy = try repository.duplicateAsCustom(builtin)
        #expect(copy.templateID != builtin.templateID)
        #expect(!copy.isBuiltin)
        #expect(copy.title.hasSuffix(" 副本"))
        #expect(copy.defaultURLs == builtin.defaultURLs)
        #expect(try repository.customTemplates().count == 1)
    }

    @Test func importsTemplatesInBatch() throws {
        let url = temporaryVaultURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (session, entries) = try makeVault(at: url)
        let repository = AccountTemplateRepository(entryRepository: entries, session: session)

        let imported = try repository.importTemplates([template("导入一"), template("导入二")])
        #expect(imported == 2)
        #expect(try repository.customTemplates().map(\.title) == ["导入一", "导入二"])
    }
}
