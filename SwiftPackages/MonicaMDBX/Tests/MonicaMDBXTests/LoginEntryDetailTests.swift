import Foundation
import Testing
@testable import MonicaMDBX

/// issue #16：多 URL、应用绑定、备注与密码历史都写在 login payload 里，
/// 必须能穿过真实 MDBX 往返、对旧库保持兼容，并且落盘后不可明文读取。
@Suite(.serialized)
struct LoginEntryDetailTests {
    private func makeVault(password: String = "detail password 12345!") throws -> (MonicaMDBXVault, URL) {
        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("monica-mdbx-login-detail-\(UUID().uuidString).mdbx", isDirectory: false)
        let vault = try MonicaMDBXRuntime.createVault(
            at: vaultURL,
            password: password,
            deviceID: "swiftpm-login-detail"
        )
        return (vault, vaultURL)
    }

    @Test func loginDetailFieldsSurviveVaultReopen() throws {
        let (vault, vaultURL) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let project = try vault.createProject(title: "工作")
        let history = [
            MonicaMDBXLoginPasswordHistoryEntry(
                changedAt: Date(timeIntervalSince1970: 1_700_000_000.123),
                password: "previous-secret-1"
            ),
            MonicaMDBXLoginPasswordHistoryEntry(
                changedAt: Date(timeIntervalSince1970: 1_700_003_600.456),
                password: "previous-secret-2"
            )
        ]

        let created = try vault.createLoginEntry(
            projectID: project.id,
            title: "公司邮箱",
            username: "alice@example.com",
            password: "current-secret",
            url: "https://mail.example.com/login",
            notes: "两步验证用硬件密钥",
            urls: [
                "https://mail.example.com/login",
                "https://mail.example.com/admin",
                "https://mail.example.com/login"
            ],
            appBundleID: "com.example.mail",
            appName: "Example Mail",
            passwordHistory: history
        )

        #expect(created.url == "https://mail.example.com/login")
        #expect(created.urls == ["https://mail.example.com/login", "https://mail.example.com/admin"])
        #expect(created.appBundleID == "com.example.mail")
        #expect(created.appName == "Example Mail")
        #expect(created.notes == "两步验证用硬件密钥")
        #expect(created.passwordHistory.map(\.password) == ["previous-secret-1", "previous-secret-2"])
        #expect(created.passwordHistory.map(\.changedAt) == history.map(\.changedAt))

        let reopened = try MonicaMDBXRuntime.openVault(
            at: vaultURL,
            password: "detail password 12345!",
            deviceID: "swiftpm-login-detail"
        )
        let entries = try reopened.listLoginEntries(projectID: project.id)
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry == created)
        #expect(entry.urls == ["https://mail.example.com/login", "https://mail.example.com/admin"])
        #expect(entry.appBundleID == "com.example.mail")
        #expect(entry.appName == "Example Mail")
        #expect(entry.notes == "两步验证用硬件密钥")
        #expect(entry.passwordHistory.map(\.password) == ["previous-secret-1", "previous-secret-2"])
        #expect(entry.passwordHistory.map(\.changedAt) == history.map(\.changedAt))
    }

    @Test func legacyPayloadWithOnlyWebsiteDecodesAsSingleURL() throws {
        let legacyPayload = """
        {"favorite":false,"kind":"password","notes":"旧备注","password":"legacy-secret","username":"legacy@example.com","website":"https://legacy.example.com/login"}
        """

        let entry = try MonicaMDBXLoginEntry.decodePayloadForTesting(legacyPayload)

        #expect(entry.url == "https://legacy.example.com/login")
        #expect(entry.urls == ["https://legacy.example.com/login"])
        #expect(entry.appBundleID.isEmpty)
        #expect(entry.appName.isEmpty)
        #expect(entry.passwordHistory.isEmpty)
        #expect(entry.notes == "旧备注")
        #expect(entry.favorite == false)
    }

    @Test func updateWithoutExplicitListsPreservesSecondaryURLsAndHistory() throws {
        let (vault, vaultURL) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let project = try vault.createProject(title: "个人")
        let historyEntry = MonicaMDBXLoginPasswordHistoryEntry(
            changedAt: Date(timeIntervalSince1970: 1_700_000_000),
            password: "first-secret"
        )
        let created = try vault.createLoginEntry(
            projectID: project.id,
            title: "论坛",
            username: "bob",
            password: "current-secret",
            url: "https://forum.example.com",
            urls: ["https://forum.example.com", "https://forum.example.com/settings"],
            appBundleID: "com.example.forum",
            appName: "Example Forum",
            passwordHistory: [historyEntry]
        )

        let updated = try vault.updateLoginEntry(
            projectID: project.id,
            entryID: created.id,
            title: "论坛（工作）",
            username: "bob",
            password: "current-secret",
            url: "https://forum.example.com",
            notes: ""
        )

        #expect(updated.urls == ["https://forum.example.com", "https://forum.example.com/settings"])
        #expect(updated.appBundleID == "com.example.forum")
        #expect(updated.appName == "Example Forum")
        #expect(updated.passwordHistory == [historyEntry])
    }

    @Test func updateWithExplicitListsReplacesAndNormalizesURLs() throws {
        let (vault, vaultURL) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let project = try vault.createProject(title: "项目")
        let created = try vault.createLoginEntry(
            projectID: project.id,
            title: "控制台",
            username: "carol",
            password: "one",
            url: "https://console.example.com",
            urls: ["https://console.example.com", "https://console.example.com/billing"]
        )

        let updated = try vault.updateLoginEntry(
            projectID: project.id,
            entryID: created.id,
            title: "控制台",
            username: "carol",
            password: "two",
            url: "https://console.example.com",
            urls: ["https://console.example.com", "  ", "https://console.example.com/support", "https://console.example.com"],
            appBundleID: "com.example.console",
            appName: "Example Console",
            passwordHistory: [
                MonicaMDBXLoginPasswordHistoryEntry(
                    changedAt: Date(timeIntervalSince1970: 1_700_100_000),
                    password: "one"
                )
            ]
        )

        #expect(updated.urls == ["https://console.example.com", "https://console.example.com/support"])
        #expect(updated.passwordHistory.map(\.password) == ["one"])
        #expect(updated.appBundleID == "com.example.console")
    }

    @Test func vaultFileDoesNotStoreDetailFieldsInPlaintext() throws {
        let (vault, vaultURL) = try makeVault()
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let project = try vault.createProject(title: "明文探针")
        _ = try vault.createLoginEntry(
            projectID: project.id,
            title: "PLAINTEXT-TITLE-PROBE",
            username: "plaintext-user-probe",
            password: "PLAINTEXT-PASSWORD-PROBE-9f2c",
            url: "https://plaintext-probe.example.com",
            urls: ["https://plaintext-probe.example.com", "https://plaintext-probe.example.com/second"],
            appBundleID: "com.plaintext.probe",
            appName: "PLAINTEXT-APP-PROBE",
            passwordHistory: [
                MonicaMDBXLoginPasswordHistoryEntry(
                    changedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    password: "PLAINTEXT-HISTORY-PROBE-77aa"
                )
            ]
        )

        let probes = [
            "PLAINTEXT-TITLE-PROBE",
            "plaintext-user-probe",
            "PLAINTEXT-PASSWORD-PROBE-9f2c",
            "plaintext-probe.example.com",
            "com.plaintext.probe",
            "PLAINTEXT-APP-PROBE",
            "PLAINTEXT-HISTORY-PROBE-77aa"
        ]
        let rawBytes = try vaultBytes(at: vaultURL)
        #expect(!rawBytes.isEmpty)
        for probe in probes {
            #expect(rawBytes.range(of: Data(probe.utf8)) == nil, "vault 文件里出现了明文：\(probe)")
        }

        // 错误口令无法打开：锁库后既读不到条目也读不到历史。
        #expect(throws: (any Error).self) {
            _ = try MonicaMDBXRuntime.openVault(
                at: vaultURL,
                password: "wrong password",
                deviceID: "swiftpm-login-detail"
            )
        }
    }

    private func vaultBytes(at vaultURL: URL) throws -> Data {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: vaultURL.path, isDirectory: &isDirectory) else {
            return Data()
        }
        guard isDirectory.boolValue else {
            return try Data(contentsOf: vaultURL)
        }
        var combined = Data()
        let enumerator = fileManager.enumerator(at: vaultURL, includingPropertiesForKeys: [.isRegularFileKey])
        while let fileURL = enumerator?.nextObject() as? URL {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            combined.append(try Data(contentsOf: fileURL))
        }
        return combined
    }
}
