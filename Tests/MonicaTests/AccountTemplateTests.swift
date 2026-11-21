@testable import Monica
import MonicaStorage
import XCTest

/// issue #127：常用账号模板在 App 会话层的接线。
///
/// 覆盖创建入口取模板、不覆盖用户已填内容、模板不含密码、自定义模板的
/// 增删排序，以及 JSON 导入预览 + 确认的完整流程。
@MainActor
final class AccountTemplateTests: XCTestCase {
    private let vaultPassword = "中文 template password 12345!"

    private func vaultDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-account-template-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 建库并注入内存锚点，测试不落到用户 Application Support 目录。
    private func makeSession() throws -> (model: AppSessionModel, directory: URL) {
        let model = AppSessionModel(vaultRepository: LocalVaultRepository())
        model.vaultFolderAnchorStore = InMemoryVaultFolderAnchorStore()
        model.vaultName = "Templates-\(UUID().uuidString)"
        model.vaultPassword = vaultPassword
        let directory = try vaultDirectory()
        try model.createLocalVault(in: directory, deviceID: "ios-account-template-test-device")
        return (model, directory)
    }

    private func template(_ title: String) -> AccountTemplate {
        AccountTemplate(
            title: title,
            defaultURLs: ["https://mail.example.com/login"],
            usernamePlaceholder: "公司邮箱地址",
            defaultNotes: "由 IT 部门下发",
            defaultCustomFields: [AccountTemplateCustomField(label: "部门", defaultValue: "研发")]
        )
    }

    func testBuiltinTemplateFillsLoginEditorWithoutPrefillingPassword() throws {
        let (model, directory) = try makeSession()
        defer {
            model.lockLocalVault()
            try? FileManager.default.removeItem(at: directory)
        }

        model.reloadAccountTemplates()
        XCTAssertGreaterThanOrEqual(AccountTemplateCatalog.builtins.count, 8)
        let github = try XCTUnwrap(
            model.accountTemplates(for: .login).first(where: { $0.templateID == "builtin.github" })
        )

        model.presentAddEditor(forItemKind: .login)
        model.applyAccountTemplate(github)

        XCTAssertEqual(model.loginTitle, "GitHub")
        XCTAssertEqual(model.loginURL, "https://github.com/login")
        XCTAssertEqual(model.loginUsername, "")
        XCTAssertEqual(model.loginPassword, "", "模板永远不能填充密码")
        XCTAssertFalse(model.accountTemplateUsernamePrompt.isEmpty)
        XCTAssertNotNil(model.accountTemplatePrefillMessage)
    }

    func testApplyingTemplateDoesNotOverwriteTypedFields() throws {
        let (model, directory) = try makeSession()
        defer {
            model.lockLocalVault()
            try? FileManager.default.removeItem(at: directory)
        }

        try model.saveAccountTemplate(template("公司邮箱"))
        model.reloadAccountTemplates()
        let saved = try XCTUnwrap(model.customAccountTemplates.first)

        model.presentAddEditor(forItemKind: .login)
        model.loginTitle = "我自己填的标题"
        model.loginUsername = "me@example.com"
        model.applyAccountTemplate(saved)

        XCTAssertEqual(model.loginTitle, "我自己填的标题")
        XCTAssertEqual(model.loginUsername, "me@example.com")
        XCTAssertEqual(model.loginURL, "https://mail.example.com/login")
        XCTAssertEqual(model.loginNotes, "由 IT 部门下发")
        XCTAssertEqual(model.presentedCustomFields.map(\.label), ["部门"])
        XCTAssertEqual(model.accountTemplateUsernamePrompt, "公司邮箱地址")
    }

    func testCustomTemplateCRUDAndReorderThroughSession() throws {
        let (model, directory) = try makeSession()
        defer {
            model.lockLocalVault()
            try? FileManager.default.removeItem(at: directory)
        }

        try model.saveAccountTemplate(template("模板一"))
        try model.saveAccountTemplate(template("模板二"))
        model.reloadAccountTemplates()
        XCTAssertEqual(model.customAccountTemplates.map(\.title), ["模板一", "模板二"])

        let second = try XCTUnwrap(model.customAccountTemplates.last)
        model.moveAccountTemplate(second, offset: -1)
        XCTAssertEqual(model.customAccountTemplates.map(\.title), ["模板二", "模板一"])

        let first = try XCTUnwrap(model.customAccountTemplates.first)
        model.deleteAccountTemplate(first)
        XCTAssertEqual(model.customAccountTemplates.map(\.title), ["模板一"])
        XCTAssertEqual(model.accountTemplateStatusMessage, "模板已删除。")
    }

    func testImportPreviewThenConfirmAddsTemplates() throws {
        let (model, directory) = try makeSession()
        defer {
            model.lockLocalVault()
            try? FileManager.default.removeItem(at: directory)
        }

        let data = try AccountTemplateCodec.export(templates: [template("导入的模板")])
        let fileURL = directory.appendingPathComponent("templates.json")
        try data.write(to: fileURL)

        model.beginAccountTemplateImport(from: fileURL)
        let preview = try XCTUnwrap(model.accountTemplateImportPreview)
        XCTAssertTrue(preview.canImport)
        XCTAssertEqual(preview.itemCount, 1)
        XCTAssertTrue(preview.issues.isEmpty)

        model.confirmAccountTemplateImport()
        XCTAssertNil(model.accountTemplateImportPreview)
        XCTAssertEqual(model.customAccountTemplates.map(\.title), ["导入的模板"])
    }

    func testImportOfBrokenFileShowsReadableErrorAndKeepsTemplates() throws {
        let (model, directory) = try makeSession()
        defer {
            model.lockLocalVault()
            try? FileManager.default.removeItem(at: directory)
        }

        try model.saveAccountTemplate(template("已有模板"))
        model.reloadAccountTemplates()

        let fileURL = directory.appendingPathComponent("broken.json")
        try Data("不是 JSON".utf8).write(to: fileURL)
        model.beginAccountTemplateImport(from: fileURL)

        let preview = try XCTUnwrap(model.accountTemplateImportPreview)
        XCTAssertFalse(preview.canImport)
        XCTAssertEqual(preview.issues.first?.code, .malformedJSON)

        model.cancelAccountTemplateImport()
        XCTAssertNil(model.accountTemplateImportPreview)
        XCTAssertEqual(model.customAccountTemplates.map(\.title), ["已有模板"])
    }

    /// 源码断言：新建条目编辑器确实把模板入口挂在登录表单里（本机不能跑 UI 测试，
    /// 所以这里检查接线点仍然存在）。
    func testLoginEditorSourceStillHostsTemplatePrefillEntryPoint() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let editor = try String(
            contentsOf: root.appendingPathComponent("App/MonicaApp/AndroidParityVaultHomeView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(editor.contains("AccountTemplatePrefillSection(session: session)"))
        XCTAssertTrue(editor.contains("if mode.isAdding"))
        XCTAssertTrue(editor.contains("accountTemplateUsernamePrompt"))

        let settings = try String(
            contentsOf: root.appendingPathComponent("App/MonicaApp/SettingsRootView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(settings.contains("presentAccountTemplates()"))
    }
}
