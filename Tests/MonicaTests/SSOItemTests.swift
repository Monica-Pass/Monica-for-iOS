@testable import Monica
import MonicaStorage
import XCTest

@MainActor
final class SSOItemTests: XCTestCase {
    private let vaultPassword = "中文 password 12345!"

    private func temporaryVaultName() -> String {
        "monica-sso-\(UUID().uuidString)"
    }

    func testSSOEntrySurvivesVaultReopenWithLinkedLogin() throws {
        let repository = LocalVaultRepository()
        let directory = FileManager.default.temporaryDirectory
        let vaultName = temporaryVaultName()
        defer {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent("\(vaultName).mdbx")
            )
        }

        let session = try repository.createVault(
            named: vaultName,
            in: directory,
            password: vaultPassword,
            deviceID: "ios-sso-xctest-device"
        )
        let entries = repository.entryRepository(for: session)
        let project = try entries.createProject(title: "Personal")
        let linkedLogin = try entries.createLoginEntry(
            projectID: project.id,
            draft: LocalLoginEntryDraft(
                title: "公司邮箱",
                username: "alice@example.com",
                password: "login-secret",
                url: "https://mail.example.com",
                notes: "SSO 关联账号"
            )
        )
        let draft = LocalSSOEntryDraft(
            title: "公司 SSO",
            provider: .google,
            providerName: "",
            issuer: "https://accounts.google.com",
            accountName: "alice@example.com",
            loginURL: "https://accounts.google.com/signin",
            linkedLoginEntryID: linkedLogin.id,
            notes: "只记录配置",
            secret: "sso-secret-token"
        )

        let created = try entries.createSSOEntry(projectID: project.id, draft: draft)

        XCTAssertEqual(try entries.listSSOEntries(projectID: project.id), [created])
        XCTAssertEqual(created.provider, .google)
        XCTAssertEqual(created.accountName, "alice@example.com")
        XCTAssertEqual(created.loginURL, "https://accounts.google.com/signin")
        XCTAssertEqual(created.linkedLoginEntryID, linkedLogin.id)
        XCTAssertEqual(created.secret, "sso-secret-token")

        repository.closeVault(for: session)

        let reopened = try repository.openVault(
            at: session.descriptor.fileURL,
            password: vaultPassword,
            deviceID: "ios-sso-xctest-device"
        )
        defer { repository.closeVault(for: reopened) }
        let reopenedEntries = repository.entryRepository(for: reopened)

        let listed = try reopenedEntries.listSSOEntries(projectID: project.id)
        XCTAssertEqual(listed.count, 1)
        let restored = try XCTUnwrap(listed.first)
        XCTAssertEqual(restored.title, "公司 SSO")
        XCTAssertEqual(restored.displayProviderName, "Google")
        XCTAssertEqual(restored.issuer, "https://accounts.google.com")
        XCTAssertEqual(restored.accountName, "alice@example.com")
        XCTAssertEqual(restored.linkedLoginEntryID, linkedLogin.id)
        XCTAssertEqual(restored.notes, "只记录配置")
        XCTAssertEqual(restored.secret, "sso-secret-token")

        let logins = try reopenedEntries.listLoginEntries(projectID: project.id)
        XCTAssertEqual(restored.resolvedLinkedLoginEntry(in: logins)?.title, "公司邮箱")
    }

    func testLinkedLoginDeletionDegradesGracefully() throws {
        let repository = LocalVaultRepository()
        let directory = FileManager.default.temporaryDirectory
        let vaultName = temporaryVaultName()
        defer {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent("\(vaultName).mdbx")
            )
        }

        let session = try repository.createVault(
            named: vaultName,
            in: directory,
            password: vaultPassword,
            deviceID: "ios-sso-xctest-device"
        )
        defer { repository.closeVault(for: session) }
        let entries = repository.entryRepository(for: session)
        let project = try entries.createProject(title: "Personal")
        let linkedLogin = try entries.createLoginEntry(
            projectID: project.id,
            draft: LocalLoginEntryDraft(
                title: "个人账号",
                username: "alice",
                password: "login-secret",
                url: "https://example.com"
            )
        )
        let sso = try entries.createSSOEntry(
            projectID: project.id,
            draft: LocalSSOEntryDraft(
                title: "自建 IdP",
                provider: .keycloak,
                issuer: "https://idp.example.com",
                accountName: "alice",
                loginURL: "https://idp.example.com/login",
                linkedLoginEntryID: linkedLogin.id
            )
        )

        try entries.deleteLoginEntry(projectID: project.id, entryID: linkedLogin.id)

        let ssoEntries = try entries.listSSOEntries(projectID: project.id)
        let logins = try entries.listLoginEntries(projectID: project.id)
        XCTAssertEqual(ssoEntries.first?.id, sso.id)
        XCTAssertNil(ssoEntries.first?.resolvedLinkedLoginEntry(in: logins))
        XCTAssertEqual(ssoEntries.first?.accountName, "alice")
        XCTAssertEqual(ssoEntries.first?.sanitizedLoginURL?.absoluteString, "https://idp.example.com/login")
    }

    func testSSOEntrySessionFlowAndLockClearsSensitiveState() throws {
        let model = AppSessionModel(vaultRepository: LocalVaultRepository())
        let vaultName = temporaryVaultName()
        model.vaultName = vaultName
        model.vaultPassword = vaultPassword
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-sso-app-tests", isDirectory: true),
            deviceID: "ios-sso-app-test-device"
        )
        defer { model.lockLocalVault() }

        model.ssoTitle = "GitHub SSO"
        model.ssoProvider = .github
        model.ssoIssuer = "https://github.com"
        model.ssoAccountName = "alice@example.com"
        model.ssoLoginURL = "https://github.com/login"
        model.ssoNotes = "仅记录配置"
        model.ssoSecret = "sso-secret-token"
        try model.createSSOEntry(projectTitle: "Personal")

        XCTAssertEqual(model.ssoEntries.first?.title, "GitHub SSO")
        XCTAssertEqual(model.ssoSecret, "")
        model.ssoSearchQuery = "github"
        XCTAssertEqual(model.filteredSSOEntries.map(\.title), ["GitHub SSO"])

        let created = try XCTUnwrap(model.ssoEntries.first)
        XCTAssertNotNil(model.prepareSSOLoginURL(entryID: created.id))

        model.selectSSOEntryForEditing(created)
        XCTAssertEqual(model.editingSSOSecret, "sso-secret-token")
        model.editingSSOAccountName = "bob@example.com"
        try model.updateSelectedSSOEntry()
        XCTAssertEqual(model.ssoEntries.first?.accountName, "bob@example.com")

        try model.setSelectedSSOFavorite(true)
        XCTAssertTrue(model.ssoEntries.first?.favorite == true)

        let rows = model.ssoDetailRows(for: try XCTUnwrap(model.ssoEntries.first))
        XCTAssertEqual(rows.first(where: { $0.id == "title" })?.value, "GitHub SSO")
        XCTAssertNotNil(rows.first(where: { $0.id == "secret" }))
        XCTAssertEqual(model.ssoDetailSecrets(for: try XCTUnwrap(model.ssoEntries.first))["secret"], "sso-secret-token")

        model.lockLocalVault()

        XCTAssertEqual(model.ssoSearchQuery, "")
        XCTAssertEqual(model.editingSSOSecret, "")
        XCTAssertTrue(model.ssoEntries.isEmpty)
        XCTAssertNil(model.prepareSSOLoginURL(entryID: created.id))
    }

    func testUnsafeLoginURLIsRejectedBeforeSave() throws {
        let model = AppSessionModel(vaultRepository: LocalVaultRepository())
        let vaultName = temporaryVaultName()
        model.vaultName = vaultName
        model.vaultPassword = vaultPassword
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-sso-app-tests", isDirectory: true),
            deviceID: "ios-sso-app-test-device"
        )
        defer { model.lockLocalVault() }

        model.ssoTitle = "危险地址"
        model.ssoLoginURL = "javascript:alert(1)"
        XCTAssertNotNil(model.ssoCreateFormURLIssue)

        XCTAssertThrowsError(try model.createSSOEntry(projectTitle: "Personal"))
        XCTAssertTrue(model.ssoEntries.isEmpty)

        model.ssoLoginURL = "https://idp.example.com/login"
        XCTAssertNil(model.ssoCreateFormURLIssue)
    }
}
