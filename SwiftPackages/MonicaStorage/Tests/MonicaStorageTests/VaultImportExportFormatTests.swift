import Foundation
import Testing

import MonicaStorage

/// 覆盖 issue #37 的导入导出格式扩展：CSV 新列、JSON 往返、Bitwarden/Aegis/Stratum
/// 嗅探与映射、加密导出、逐行错误聚合与判重。
@Suite("导入导出格式")
struct VaultImportExportFormatTests {
    private func preview(
        _ data: Data,
        fileName: String,
        contentType: String? = nil,
        password: String? = nil,
        existingLogins: [LocalLoginEntry] = [],
        existingTotp: [LocalTotpEntry] = []
    ) -> VaultImportResult {
        VaultImportEngine.preview(
            data: data,
            fileName: fileName,
            contentType: contentType,
            options: VaultImportOptions(
                password: password,
                existingLoginEntries: existingLogins,
                existingTotpEntries: existingTotp
            )
        )
    }

    private func preview(
        _ text: String,
        fileName: String,
        contentType: String? = nil,
        password: String? = nil,
        existingLogins: [LocalLoginEntry] = [],
        existingTotp: [LocalTotpEntry] = []
    ) -> VaultImportResult {
        preview(
            Data(text.utf8),
            fileName: fileName,
            contentType: contentType,
            password: password,
            existingLogins: existingLogins,
            existingTotp: existingTotp
        )
    }

    private func loginDraft(
        title: String = "GitHub",
        username: String = "octocat",
        password: String = "s3cret",
        url: String = "https://github.com",
        notes: String = "",
        urls: [String] = []
    ) -> VaultCSVItemDraft {
        .login(LocalLoginEntryDraft(
            title: title,
            username: username,
            password: password,
            url: url,
            notes: notes,
            urls: urls
        ))
    }

    // MARK: - Monica CSV

    @Test func csvExportRoundTripKeepsAdditionalURLsAndCustomFields() throws {
        let draft = loginDraft(
            notes: "双因素已开",
            urls: ["https://github.com", "https://gist.github.com"]
        )
        let customFields = [
            VaultCustomField(label: "恢复码", kind: .hiddenText, value: "abcd-efgh", order: 0),
            VaultCustomField(label: "控制台", kind: .url, value: "https://github.com/settings", order: 1)
        ]
        let artifact = try VaultExportEngine.export(
            items: [VaultTransferItem(draft: draft, customFields: customFields)],
            options: VaultExportOptions(format: .csv)
        )

        let result = preview(artifact.data, fileName: artifact.fileName)
        #expect(result.format == .monicaCSV)
        #expect(result.items.count == 1)
        #expect(result.issues.isEmpty)
        let imported = try #require(result.items.first)
        guard case .login(let loaded) = imported.draft else {
            Issue.record("期望 login 草稿")
            return
        }
        #expect(loaded.title == "GitHub")
        #expect(loaded.notes == "双因素已开")
        #expect(loaded.urls == ["https://github.com", "https://gist.github.com"])
        #expect(imported.customFields.map(\.label) == ["恢复码", "控制台"])
        #expect(imported.customFields.map(\.kind) == [.hiddenText, .url])
        #expect(imported.customFields.map(\.value) == ["abcd-efgh", "https://github.com/settings"])
    }

    @Test func csvExportWithoutCustomFieldsLeavesColumnEmpty() throws {
        let draft = loginDraft()
        let artifact = try VaultExportEngine.export(
            items: [VaultTransferItem(draft: draft, customFields: [
                VaultCustomField(label: "PIN", kind: .hiddenText, value: "1234")
            ])],
            options: VaultExportOptions(format: .csv, includeCustomFields: false)
        )
        let result = preview(artifact.data, fileName: artifact.fileName)
        #expect(result.items.count == 1)
        #expect(result.items.first?.customFields.isEmpty == true)
    }

    @Test func legacyCSVWithoutNewColumnsStillImports() {
        let legacyColumns = Array(VaultCSVCodec.columns.dropLast(2))
        var values = Dictionary(uniqueKeysWithValues: legacyColumns.map { ($0, "") })
        values["kind"] = "login"
        values["title"] = "老版本 CSV"
        values["username"] = "user"
        values["password"] = "pass"
        values["url"] = "https://legacy.example.com"
        let csv = legacyColumns.joined(separator: ",") + "\n" + legacyColumns.map { values[$0] ?? "" }.joined(separator: ",")

        let result = preview(csv, fileName: "legacy.csv")
        #expect(result.format == .monicaCSV)
        #expect(result.items.count == 1)
        #expect(result.issues.isEmpty)
        guard case .login(let draft) = try! #require(result.items.first?.draft) else {
            Issue.record("期望 login 草稿")
            return
        }
        #expect(draft.title == "老版本 CSV")
        #expect(draft.urls.isEmpty)
    }

    @Test func csvImportAggregatesRowErrorsWithoutAborting() {
        let csv = """
        kind,title,secret,period,username,password,url
        login,好的条目,,,u,p,https://ok.example.com
        totp,,JBSWY3DPEHPK3PXP,30,,
        totp,坏周期,JBSWY3DPEHPK3PXP,abc,,
        """
        let result = preview(csv, fileName: "mixed.csv")
        #expect(result.format == .monicaCSV)
        #expect(result.items.count == 1)
        #expect(result.issues.count == 2)
        #expect(result.issues.allSatisfy { $0.sourceIndex != nil })
        let fields = result.issues.compactMap(\.field)
        #expect(fields.contains("title"))
        #expect(fields.contains("period"))
        #expect(result.issues.contains { $0.code == .missingRequiredField })
        #expect(result.issues.contains { $0.code == .invalidField })
        #expect(result.issues.allSatisfy { !$0.message.contains("JBSWY3DPEHPK3PXP") })
    }

    // MARK: - Monica JSON

    @Test func jsonExportRoundTripPreservesKindsAndValues() throws {
        let items: [VaultTransferItem] = [
            VaultTransferItem(draft: loginDraft(urls: ["https://github.com", "https://gist.github.com"]), customFields: [
                VaultCustomField(label: "PIN", kind: .hiddenText, value: "1234")
            ]),
            VaultTransferItem(draft: .totp(LocalTotpEntryDraft(
                title: "GitHub 2FA",
                secret: "JBSWY3DPEHPK3PXP",
                issuer: "GitHub",
                accountName: "octocat",
                period: 60,
                digits: 8,
                algorithm: "SHA256",
                otpType: "totp",
                counter: 0
            ))),
            VaultTransferItem(draft: .note(LocalNoteEntryDraft(title: "备忘", body: "多行\n内容"))),
            VaultTransferItem(draft: .card(LocalCardEntryDraft(
                title: "招商银行",
                cardholderName: "张三",
                number: "4111111111111111",
                expiryMonth: "1",
                expiryYear: "2030",
                cvv: "123",
                issuer: "招商银行",
                network: "Visa",
                notes: ""
            )))
        ]
        let artifact = try VaultExportEngine.export(items: items, options: VaultExportOptions(format: .json))
        #expect(artifact.fileName.hasSuffix(".json"))

        let result = preview(artifact.data, fileName: artifact.fileName)
        #expect(result.format == .monicaJSON)
        #expect(result.issues.isEmpty)
        #expect(result.items.count == items.count)
        #expect(result.items.map(\.draft.kind) == items.map(\.draft.kind))
        for (index, item) in result.items.enumerated() {
            #expect(item.draft == items[index].draft)
        }
        #expect(result.items[0].customFields.map(\.label) == ["PIN"])
    }

    @Test func jsonExportRejectsUnsupportedSchemaVersion() throws {
        let json = """
        {"format":"monica-vault","schemaVersion":9,"itemCount":1,"items":[]}
        """
        let result = preview(json, fileName: "future.json")
        #expect(result.format == .monicaJSON)
        #expect(result.items.isEmpty)
        #expect(result.issues.contains { $0.code == .unsupportedVersion })
    }

    // MARK: - Bitwarden

    private let bitwardenJSON = """
    {
      "encrypted": false,
      "folders": [{"id": "f1", "name": "工作"}],
      "items": [
        {
          "id": "i1",
          "folderId": "f1",
          "type": 1,
          "name": "GitHub",
          "notes": "已开启 2FA",
          "favorite": true,
          "fields": [
            {"name": "恢复码", "value": "abcd-efgh", "type": 1},
            {"name": "控制台", "value": "https://github.com/settings", "type": 0}
          ],
          "login": {
            "uris": [{"uri": "https://github.com"}, {"uri": "https://gist.github.com"}],
            "username": "octocat",
            "password": "s3cret",
            "totp": "otpauth://totp/GitHub:octocat?secret=JBSWY3DPEHPK3PXP&issuer=GitHub&digits=8&period=60"
          }
        },
        {"id": "i2", "type": 2, "name": "安全笔记", "notes": "纯文本"},
        {
          "id": "i3",
          "type": 3,
          "name": "Visa",
          "card": {"cardholderName": "张三", "brand": "Visa", "number": "4111111111111111", "expMonth": "1", "expYear": "2030", "code": "123"}
        },
        {
          "id": "i4",
          "type": 4,
          "name": "护照",
          "identity": {"firstName": "Ada", "lastName": "Lovelace", "passportNumber": "X1234567", "country": "UK", "email": "ada@example.com"}
        },
        {"id": "i5", "type": 1, "name": "已删除", "deletedDate": "2024-01-01T00:00:00Z", "login": {"uris": [], "username": "x", "password": "y"}},
        {"id": "i6", "type": 9, "name": "未知类型"}
      ]
    }
    """

    @Test func bitwardenJSONMapsLoginsTOTPAndExtras() {
        let result = preview(bitwardenJSON, fileName: "bitwarden_export_20260101.json")
        #expect(result.format == .bitwardenJSON)
        #expect(result.items.count == 5)

        let login = result.items.first { $0.draft.kind == .login }
        guard case .login(let draft)? = login?.draft else {
            Issue.record("缺少 login 条目")
            return
        }
        #expect(draft.title == "GitHub")
        #expect(draft.username == "octocat")
        #expect(draft.password == "s3cret")
        #expect(draft.notes == "已开启 2FA")
        #expect(draft.url == "https://github.com")
        #expect(draft.urls == ["https://github.com", "https://gist.github.com"])
        #expect(login?.customFields.contains { $0.label == "文件夹" && $0.value == "工作" } == true)
        #expect(login?.customFields.contains { $0.label == "恢复码" && $0.kind == .hiddenText } == true)
        #expect(login?.customFields.contains { $0.label == "控制台" && $0.kind == .text } == true)

        let totp = result.items.first { $0.draft.kind == .totp }
        guard case .totp(let totpDraft)? = totp?.draft else {
            Issue.record("login.totp 应拆成独立 TOTP 条目")
            return
        }
        #expect(totpDraft.title == "GitHub")
        #expect(totpDraft.secret == "JBSWY3DPEHPK3PXP")
        #expect(totpDraft.issuer == "GitHub")
        #expect(totpDraft.accountName == "octocat")
        #expect(totpDraft.digits == 8)
        #expect(totpDraft.period == 60)

        #expect(result.items.contains { $0.draft.kind == .note })
        guard case .card(let card)? = result.items.first(where: { $0.draft.kind == .card })?.draft else {
            Issue.record("缺少 card 条目")
            return
        }
        #expect(card.cardholderName == "张三")
        #expect(card.number == "4111111111111111")
        #expect(card.expiryYear == "2030")
        guard case .identity(let identity)? = result.items.first(where: { $0.draft.kind == .identity })?.draft else {
            Issue.record("缺少 identity 条目")
            return
        }
        #expect(identity.fullName == "Ada Lovelace")
        #expect(identity.documentNumber == "X1234567")
        #expect(identity.country == "UK")

        // 已删除条目被跳过；未知 type 报错；favorite 只提示一次。
        #expect(result.issues.contains { $0.code == .unsupportedItemKind && $0.field == "type" })
        #expect(result.issues.filter { $0.field == "favorite" }.count == 1)
        #expect(!result.items.contains { $0.draft.kind == .login && $0.sourceIndex == 4 })
    }

    @Test func bitwardenJSONIgnoresBareBase32TOTPThatIsInvalid() {
        let json = """
        {"encrypted":false,"items":[{"id":"i1","type":1,"name":"Bad","login":{"uris":[],"username":"u","password":"p","totp":"not-a-secret"}}]}
        """
        let result = preview(json, fileName: "bitwarden.json")
        #expect(result.items.count == 1)
        #expect(result.items.first?.draft.kind == .login)
        #expect(result.issues.contains { $0.field == "login.totp" })
    }

    @Test func encryptedBitwardenJSONIsRefusedRatherThanGuessed() {
        let json = """
        {"encrypted":true,"salt":"c2FsdA==","kdfType":0,"kdfIterations":600000,"data":"U2FsdGVkX1+..."}
        """
        let result = preview(json, fileName: "bitwarden_encrypted.json", password: "guess")
        #expect(result.items.isEmpty)
        #expect(result.detection.outcome == .unsupportedEncryption(.bitwardenJSON))
        #expect(result.issues.contains { $0.code == .encryptedFormat })
        #expect(result.issues.allSatisfy { !$0.message.contains("guess") })
    }

    // MARK: - Aegis

    private let aegisJSON = """
    {
      "version": 1,
      "header": {"slots": null, "params": null},
      "db": {
        "version": 3,
        "entries": [
          {
            "type": "totp",
            "uuid": "u1",
            "name": "GitHub",
            "issuer": "GitHub",
            "note": "备注",
            "favorite": false,
            "info": {"secret": "JBSWY3DPEHPK3PXP", "algo": "SHA256", "digits": 8, "period": 60}
          },
          {
            "type": "hotp",
            "uuid": "u2",
            "name": "银行",
            "issuer": "",
            "info": {"secret": "JBSWY3DPEHPK3PXP", "algo": "SHA1", "digits": 6, "counter": 5}
          },
          {
            "type": "steam",
            "uuid": "u3",
            "name": "Steam",
            "issuer": "Steam",
            "info": {"secret": "JBSWY3DPEHPK3PXP"}
          }
        ],
        "groups": []
      }
    }
    """

    @Test func aegisJSONImportsTOTPAndHOTP() {
        let result = preview(aegisJSON, fileName: "aegis-export.json")
        #expect(result.format == .aegisJSON)
        #expect(result.items.count == 2)
        #expect(result.items.allSatisfy { $0.draft.kind == .totp })
        guard case .totp(let totp)? = result.items.first?.draft else {
            Issue.record("缺少 totp 条目")
            return
        }
        #expect(totp.title == "GitHub")
        #expect(totp.issuer == "GitHub")
        #expect(totp.algorithm == "SHA256")
        #expect(totp.digits == 8)
        #expect(totp.period == 60)
        guard case .totp(let hotp)? = result.items.last?.draft else {
            Issue.record("缺少 hotp 条目")
            return
        }
        #expect(hotp.otpType == "hotp")
        #expect(hotp.counter == 5)
        #expect(result.issues.contains { $0.code == .unsupportedItemKind })
    }

    @Test func encryptedAegisVaultIsRefused() {
        let json = """
        {"version":1,"header":{"slots":["c2xvdA=="],"params":{"n":32768}},"db":"YWJjZGVmZ2hpamtsbW5vcA=="}
        """
        let result = preview(json, fileName: "aegis-encrypted.json", password: "pw")
        #expect(result.items.isEmpty)
        #expect(result.detection.outcome == .unsupportedEncryption(.aegisJSON))
        #expect(result.issues.contains { $0.code == .encryptedFormat })
    }

    // MARK: - Stratum

    private let stratumJSON = """
    {
      "Authenticators": [
        {"Type": 2, "Icon": null, "Issuer": "GitHub", "Username": "octocat", "Secret": "JBSWY3DPEHPK3PXP", "Pin": "", "Algorithm": 1, "Digits": 8, "Period": 60, "Counter": 0, "Ranking": 0, "CopyCount": 0},
        {"Type": 1, "Icon": null, "Issuer": "银行", "Username": "me", "Secret": "JBSWY3DPEHPK3PXP", "Pin": "", "Algorithm": 2, "Digits": 6, "Period": 30, "Counter": 7, "Ranking": 0, "CopyCount": 0},
        {"Type": 2, "Icon": null, "Issuer": "带 PIN", "Username": "me", "Secret": "JBSWY3DPEHPK3PXP", "Pin": "7777", "Algorithm": 0, "Digits": 6, "Period": 30, "Counter": 0, "Ranking": 0, "CopyCount": 0},
        {"Type": 4, "Icon": null, "Issuer": "Steam", "Username": "me", "Secret": "JBSWY3DPEHPK3PXP", "Pin": "", "Algorithm": 0, "Digits": 5, "Period": 30, "Counter": 0, "Ranking": 0, "CopyCount": 0}
      ],
      "Categories": [],
      "AuthenticatorCategories": [],
      "CustomIcons": []
    }
    """

    @Test func stratumJSONImportsSupportedTypes() {
        let result = preview(stratumJSON, fileName: "stratum.json")
        #expect(result.format == .stratumJSON)
        #expect(result.items.count == 3)
        guard case .totp(let totp)? = result.items.first?.draft else {
            Issue.record("缺少 totp 条目")
            return
        }
        #expect(totp.issuer == "GitHub")
        #expect(totp.accountName == "octocat")
        #expect(totp.algorithm == "SHA256")
        #expect(totp.digits == 8)
        #expect(totp.period == 60)

        guard case .totp(let hotp) = result.items[1].draft else {
            Issue.record("缺少 hotp 条目")
            return
        }
        #expect(hotp.otpType == "hotp")
        #expect(hotp.counter == 7)
        #expect(hotp.algorithm == "SHA512")

        #expect(result.items[2].customFields.contains { $0.label == "PIN" && $0.kind == .hiddenText })
        #expect(result.issues.contains { $0.code == .unsupportedItemKind })
        #expect(result.issues.contains { $0.code == .skippedValue && $0.field == "Pin" })
        #expect(result.issues.allSatisfy { !$0.message.contains("7777") })
    }

    @Test func encryptedStratumBinaryIsRefused() {
        let data = Data("AUTHENTICATORPRO".utf8) + Data(repeating: 0, count: 64)
        let result = preview(data, fileName: "stratum.authpro")
        #expect(result.items.isEmpty)
        #expect(result.detection.outcome == .unsupportedEncryption(.stratumJSON))
        #expect(result.issues.contains { $0.code == .encryptedFormat })
    }

    // MARK: - 通用 CSV / 1Password CSV

    @Test func genericCSVHeaderMappingWorks() {
        let csv = """
        name,login,password,website,notes
        路由器,admin,pass123,https://192.168.1.1,记得改默认密码
        """
        let result = preview(csv, fileName: "passwords.csv")
        #expect(result.format == .genericCSV)
        #expect(result.items.count == 1)
        guard case .login(let draft) = try! #require(result.items.first?.draft) else {
            Issue.record("期望 login 草稿")
            return
        }
        #expect(draft.title == "路由器")
        #expect(draft.username == "admin")
        #expect(draft.url == "https://192.168.1.1")
        #expect(draft.notes == "记得改默认密码")
    }

    @Test func onePasswordCSVHeaderMappingAddsTOTPEntry() {
        let csv = """
        Title,Url,Username,Password,OTPAuth,Notes,Tags
        GitHub,https://github.com,octocat,s3cret,otpauth://totp/GitHub:octocat?secret=JBSWY3DPEHPK3PXP&issuer=GitHub,备注,工作
        """
        let result = preview(csv, fileName: "1password.csv")
        #expect(result.format == .onePasswordCSV)
        #expect(result.items.count == 2)
        #expect(result.items.map(\.draft.kind) == [.login, .totp])
        guard case .totp(let totp)? = result.items.last?.draft else {
            Issue.record("缺少 totp 条目")
            return
        }
        #expect(totp.secret == "JBSWY3DPEHPK3PXP")
        #expect(totp.issuer == "GitHub")
    }

    // MARK: - 嗅探

    @Test func contentSignatureWinsOverFileExtension() {
        let result = preview(bitwardenJSON, fileName: "backup.csv", contentType: "text/csv")
        #expect(result.format == .bitwardenJSON)
        #expect(!result.detection.warnings.isEmpty)
    }

    @Test func oversizedFileIsRejectedBeforeParsing() {
        let data = Data(repeating: 0x41, count: VaultImportDetector.maximumFileSizeBytes + 1)
        let result = preview(data, fileName: "huge.json")
        #expect(result.items.isEmpty)
        #expect(result.issues.contains { $0.code == .fileTooLarge })
        #expect(result.detection.outcome == .unsupported)
    }

    @Test func emptyFileIsRejected() {
        let result = preview(Data(), fileName: "empty.csv")
        #expect(result.items.isEmpty)
        #expect(result.issues.contains { $0.code == .unsupportedFile })
    }

    @Test func unrecognizedTextIsReported() {
        let result = preview("这不是任何受支持的格式", fileName: "notes.txt")
        #expect(result.items.isEmpty)
        #expect(result.issues.contains { $0.code == .unrecognizedFormat })
    }

    // MARK: - 加密导出

    @Test func encryptedExportRequiresPasswordAndRoundTrips() throws {
        let items = [
            VaultTransferItem(draft: loginDraft()),
            VaultTransferItem(draft: .note(LocalNoteEntryDraft(title: "备忘", body: "内容"))),
        ]
        let artifact = try VaultExportEngine.export(
            items: items,
            options: VaultExportOptions(format: .json, encryptionPassword: "correct horse")
        )
        #expect(artifact.isEncrypted)
        #expect(artifact.fileName.hasSuffix(".json.enc"))

        let withoutPassword = preview(artifact.data, fileName: artifact.fileName)
        #expect(withoutPassword.detection.outcome == .passwordRequired)
        #expect(withoutPassword.items.isEmpty)
        #expect(withoutPassword.issues.contains { $0.code == .passwordRequired })

        let wrongPassword = preview(artifact.data, fileName: artifact.fileName, password: "wrong")
        #expect(wrongPassword.items.isEmpty)
        #expect(wrongPassword.issues.contains { $0.code == .decryptionFailed })

        let unlocked = preview(artifact.data, fileName: artifact.fileName, password: "correct horse")
        #expect(unlocked.format == .monicaJSON)
        #expect(unlocked.items.count == 2)
        #expect(unlocked.items.first?.draft == items[0].draft)
    }

    @Test func emptyPasswordIsRejected() {
        #expect(throws: VaultExportError.emptyPassword) {
            _ = try VaultExportEngine.export(
                items: [VaultTransferItem(draft: loginDraft())],
                options: VaultExportOptions(format: .csv, encryptionPassword: "")
            )
        }
    }

    // MARK: - 判重

    @Test func duplicateLoginsAreSkippedWhenDeduplicating() {
        let existing = LocalLoginEntry(
            id: "existing",
            projectID: "p1",
            title: "GitHub",
            username: "octocat",
            password: "s3cret",
            url: "https://github.com",
            urls: ["https://github.com"]
        )
        let csv = """
        kind,title,url,username,password
        login,GitHub,https://github.com,octocat,s3cret
        login,GitLab,https://gitlab.com,octocat,s3cret
        """
        let result = preview(csv, fileName: "dupes.csv", existingLogins: [existing])
        #expect(result.items.count == 1)
        #expect(result.skippedDuplicateCount == 1)
        #expect(result.issues.contains { $0.code == .duplicateItem })
        guard case .login(let kept) = try! #require(result.items.first?.draft) else {
            Issue.record("期望 login 草稿")
            return
        }
        #expect(kept.title == "GitLab")
    }

    @Test func deduplicationCanBeDisabled() {
        let existing = LocalLoginEntry(
            id: "existing",
            projectID: "p1",
            title: "GitHub",
            username: "octocat",
            password: "s3cret",
            url: "https://github.com"
        )
        let result = VaultImportEngine.preview(
            data: Data(bitwardenJSON.utf8),
            fileName: "bitwarden.json",
            options: VaultImportOptions(existingLoginEntries: [existing], deduplicate: false)
        )
        #expect(result.items.contains { $0.draft.kind == .login && $0.sourceIndex == 0 })
    }
}
