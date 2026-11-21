import Foundation
import Testing
@testable import MonicaMDBX

/// issue #151：登录条目新增可选的「账号」（邮箱 / 手机号 / 账号 ID）字段。
///
/// account 与 username 分开保存；旧 payload 没有 `account` 键时必须解码为空字符串，
/// 且更新、换图标等操作不能把已保存的账号丢掉。
@Suite(.serialized)
struct LoginAccountFieldTests {
    private func makeVault(
        password: String = "account password 12345!"
    ) throws -> (MonicaMDBXVault, URL) {
        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-mdbx-login-account-\(UUID().uuidString).mdbx", isDirectory: false)
        let vault = try MonicaMDBXRuntime.createVault(
            at: vaultURL,
            password: password,
            deviceID: "swiftpm-login-account"
        )
        return (vault, vaultURL)
    }

    @Test func legacyPayloadWithoutAccountDecodesAsEmptyString() throws {
        let legacyPayload = """
        {"favorite":false,"kind":"password","notes":"旧备注","password":"legacy-secret","username":"legacy@example.com","website":"https://legacy.example.com/login"}
        """

        let entry = try MonicaMDBXLoginEntry.decodePayloadForTesting(legacyPayload)

        #expect(entry.username == "legacy@example.com")
        #expect(entry.account.isEmpty)
    }

    @Test func accountSurvivesCreateUpdateReopenAndIconChange() throws {
        let (vault, vaultURL) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let project = try vault.createProject(title: "工作")
        let created = try vault.createLoginEntry(
            projectID: project.id,
            title: "公司邮箱",
            username: "alice",
            account: "alice@example.com",
            password: "current-secret",
            url: "https://mail.example.com/login",
            urls: [
                "https://mail.example.com/login",
                "https://mail.example.com/admin"
            ],
            appBundleID: "com.example.mail",
            appName: "Example Mail"
        )

        #expect(created.username == "alice")
        #expect(created.account == "alice@example.com")

        // 关闭重开：账号写在 login payload 里，必须与其它详情字段一起持久化。
        let reopened = try MonicaMDBXRuntime.openVault(
            at: vaultURL,
            password: "account password 12345!",
            deviceID: "swiftpm-login-account"
        )
        let loaded = try #require(try reopened.listLoginEntries(projectID: project.id).first)
        #expect(loaded.account == "alice@example.com")
        #expect(loaded.username == "alice")

        // 不传 account（nil）表示保留旧值，而不是清空。
        let renamed = try reopened.updateLoginEntry(
            projectID: project.id,
            entryID: created.id,
            title: "公司邮箱（改名）",
            username: "alice",
            password: "current-secret",
            url: "https://mail.example.com/login"
        )
        #expect(renamed.account == "alice@example.com")

        // 换图标走 payload 就地改写，不能顺手丢掉账号、次级 URL 或应用绑定。
        let withIcon = try reopened.setLoginEntryIcon(
            projectID: project.id,
            entryID: created.id,
            icon: "catalog:mail"
        )
        #expect(withIcon.account == "alice@example.com")
        #expect(withIcon.urls == [
            "https://mail.example.com/login",
            "https://mail.example.com/admin"
        ])
        #expect(withIcon.appBundleID == "com.example.mail")
        #expect(withIcon.appName == "Example Mail")

        // 显式传入新值可以修改；显式传入空字符串可以清空。
        let changed = try reopened.updateLoginEntry(
            projectID: project.id,
            entryID: created.id,
            title: "公司邮箱（改名）",
            username: "alice",
            account: "alice@corp.example.com",
            password: "current-secret",
            url: "https://mail.example.com/login"
        )
        #expect(changed.account == "alice@corp.example.com")

        let cleared = try reopened.updateLoginEntry(
            projectID: project.id,
            entryID: created.id,
            title: "公司邮箱（改名）",
            username: "alice",
            account: "",
            password: "current-secret",
            url: "https://mail.example.com/login"
        )
        #expect(cleared.account.isEmpty)
    }
}
