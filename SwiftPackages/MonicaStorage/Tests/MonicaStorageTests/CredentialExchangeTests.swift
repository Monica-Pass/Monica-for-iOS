import Foundation
import Testing
import MonicaStorage

@Test func credentialExchangeImportMapsPasswordAndTOTP() {
    let account = CredentialExchangeAccount(
        userName: "alice@example.com",
        items: [
            CredentialExchangeItem(
                title: "",
                urls: ["https://Example.com/login"],
                credentials: [
                    .password(CredentialExchangePassword(userName: "alice", password: "s3cret"))
                ]
            ),
            CredentialExchangeItem(
                title: "GitHub",
                credentials: [
                    .totp(CredentialExchangeTOTP(
                        secret: "jbswy3dpehpk3pxp",
                        period: 30,
                        digits: 6,
                        accountName: "alice",
                        issuer: "GitHub",
                        algorithm: "sha256"
                    ))
                ]
            )
        ]
    )

    let plan = CredentialExchangeCodec.importPlan(accounts: [account])

    #expect(plan.sourceAccountCount == 1)
    #expect(plan.sourceItemCount == 2)
    #expect(plan.passwordCount == 1)
    #expect(plan.totpCount == 1)
    #expect(plan.drafts.count == 2)
    #expect(plan.invalidCredentialCount == 0)
    #expect(plan.skippedDuplicateCount == 0)

    guard case .login(let login) = plan.drafts[0] else {
        Issue.record("第一个草稿应该是登录条目")
        return
    }
    #expect(login.title == "example.com")
    #expect(login.username == "alice")
    #expect(login.password == "s3cret")
    #expect(login.url == "https://Example.com/login")

    guard case .totp(let totp) = plan.drafts[1] else {
        Issue.record("第二个草稿应该是 TOTP 条目")
        return
    }
    #expect(totp.title == "GitHub")
    #expect(totp.secret == "JBSWY3DPEHPK3PXP")
    #expect(totp.issuer == "GitHub")
    #expect(totp.accountName == "alice")
    #expect(totp.algorithm == "SHA256")
    #expect(totp.otpType == "TOTP")
}

@Test func credentialExchangeImportSkipsDuplicatesWithinPayloadAndAgainstVault() {
    let existing = LocalLoginEntry(
        id: "login-1",
        projectID: "project-1",
        title: "Example",
        username: "alice",
        password: "s3cret",
        url: "https://example.com/login"
    )
    let existingTOTP = LocalTotpEntry(
        id: "totp-1",
        projectID: "project-1",
        title: "GitHub",
        secret: "JBSWY3DPEHPK3PXP",
        issuer: "GitHub",
        accountName: "alice",
        period: 30,
        digits: 6,
        algorithm: "SHA1",
        otpType: "TOTP",
        counter: 0
    )
    let account = CredentialExchangeAccount(
        userName: "alice",
        items: [
            CredentialExchangeItem(
                title: "Example duplicate",
                urls: ["https://example.com/login"],
                credentials: [
                    .password(CredentialExchangePassword(userName: "alice", password: "s3cret"))
                ]
            ),
            CredentialExchangeItem(
                title: "New",
                urls: ["https://new.example.com"],
                credentials: [
                    .password(CredentialExchangePassword(userName: "bob", password: "hunter2")),
                    .password(CredentialExchangePassword(userName: "bob", password: "hunter2"))
                ]
            ),
            CredentialExchangeItem(
                title: "GitHub duplicate",
                credentials: [
                    .totp(CredentialExchangeTOTP(secret: "jbswy3dpehpk3pxp", accountName: "alice"))
                ]
            )
        ]
    )

    let plan = CredentialExchangeCodec.importPlan(
        accounts: [account],
        existingLoginEntries: [existing],
        existingTOTPEntries: [existingTOTP]
    )

    #expect(plan.drafts.count == 1)
    #expect(plan.passwordCount == 1)
    #expect(plan.totpCount == 0)
    #expect(plan.skippedDuplicateCount == 3)
}

@Test func credentialExchangeImportCountsUnsupportedAndInvalidCredentials() {
    let account = CredentialExchangeAccount(
        userName: "alice",
        items: [
            CredentialExchangeItem(
                title: "Passkey",
                credentials: [.unsupported(label: "通行密钥")]
            ),
            CredentialExchangeItem(
                title: "Broken TOTP",
                credentials: [.totp(CredentialExchangeTOTP(secret: "not base32"))]
            ),
            CredentialExchangeItem(
                title: "Empty password",
                credentials: [.password(CredentialExchangePassword(userName: "", password: ""))]
            )
        ]
    )

    let plan = CredentialExchangeCodec.importPlan(accounts: [account])

    #expect(plan.isEmpty)
    #expect(plan.unsupportedCredentialCount == 1)
    #expect(plan.invalidCredentialCount == 2)
}

@Test func credentialExchangeExportKeepsFavoritesAndSkipsInvalidTOTP() {
    let login = LocalLoginEntry(
        id: "login-1",
        projectID: "project-1",
        title: "Example",
        username: "alice",
        password: "s3cret",
        url: "https://example.com/login",
        favorite: true
    )
    let totp = LocalTotpEntry(
        id: "totp-1",
        projectID: "project-1",
        title: "GitHub",
        secret: "jbswy3dpehpk3pxp",
        issuer: "GitHub",
        accountName: "alice",
        period: 30,
        digits: 6,
        algorithm: "sha1",
        otpType: "TOTP",
        counter: 0
    )
    let invalidTOTP = LocalTotpEntry(
        id: "totp-2",
        projectID: "project-1",
        title: "Broken",
        secret: "abc",
        issuer: "",
        accountName: "alice",
        period: 30,
        digits: 6,
        algorithm: "SHA1",
        otpType: "TOTP",
        counter: 0
    )

    let plan = CredentialExchangeCodec.exportPlan(
        loginEntries: [login],
        totpEntries: [totp, invalidTOTP]
    )

    #expect(plan.passwordCount == 1)
    #expect(plan.totpCount == 1)
    #expect(plan.skippedCount == 1)
    #expect(plan.account.items.count == 2)
    #expect(plan.account.items[0].favorite)
    #expect(plan.account.items[0].urls == ["https://example.com/login"])

    guard case .totp(let exported) = plan.account.items[1].credentials[0] else {
        Issue.record("导出条目应包含 TOTP 凭据")
        return
    }
    #expect(exported.secret == "JBSWY3DPEHPK3PXP")
    #expect(exported.algorithm == "SHA1")
    #expect(exported.period == 30)
}

@Test func credentialExchangeBase32NormalizesAndRejectsInvalidSecrets() {
    #expect(CredentialExchangeCodec.Base32.normalizedSecret("jbswy3 dpehpk3- pxp") == "JBSWY3DPEHPK3PXP")
    #expect(CredentialExchangeCodec.Base32.normalizedSecret("JBSWY3DPEHPK3PXP====") == "JBSWY3DPEHPK3PXP")
    #expect(CredentialExchangeCodec.Base32.normalizedSecret("JBSWY3DPEHPK3PX") == nil)
    #expect(CredentialExchangeCodec.Base32.normalizedSecret("JBSW1Y3DPEHPK3PXP") == nil)
    #expect(CredentialExchangeCodec.Base32.normalizedSecret("MZXW6===") == nil)
    #expect(CredentialExchangeCodec.Base32.normalizedSecret("") == nil)
}

@Test func credentialExchangeImportIgnoresEmptyAccounts() {
    let plan = CredentialExchangeCodec.importPlan(
        accounts: [CredentialExchangeAccount(userName: "alice", items: [])]
    )
    #expect(plan.isEmpty)
    #expect(plan.sourceAccountCount == 1)
    #expect(plan.sourceItemCount == 0)
}

@Test func credentialExchangeImportMapsPasskeyForTheCryptoLayer() {
    let credentialID = Data(repeating: 0x22, count: 32)
    let passkey = CredentialExchangePasskey(
        credentialID: credentialID,
        relyingPartyIdentifier: "github.com",
        userName: "alice",
        userDisplayName: "Alice",
        userHandle: Data("github-handle".utf8),
        privateKey: Data(repeating: 0x30, count: 48)
    )
    let account = CredentialExchangeAccount(
        userName: "alice",
        items: [
            CredentialExchangeItem(
                title: "GitHub",
                urls: ["https://github.com/login"],
                favorite: true,
                credentials: [.passkey(passkey)]
            )
        ]
    )

    let plan = CredentialExchangeCodec.importPlan(accounts: [account])

    #expect(plan.passkeyCount == 1)
    #expect(plan.passkeys.count == 1)
    #expect(plan.importableCount == 1)
    #expect(!plan.isEmpty)
    #expect(plan.unsupportedCredentialCount == 0)
    #expect(plan.invalidCredentialCount == 0)
    #expect(plan.passkeyIssues.isEmpty)

    let item = plan.passkeys[0]
    #expect(item.title == "GitHub")
    #expect(item.urls == ["https://github.com/login"])
    #expect(item.favorite)
    #expect(item.credential == passkey)
    #expect(item.credential.privateKey == Data(repeating: 0x30, count: 48))
}

@Test func credentialExchangeImportDegradesBadPasskeysToPerItemIssues() {
    let account = CredentialExchangeAccount(
        userName: "alice",
        items: [
            CredentialExchangeItem(
                title: "无 ID",
                credentials: [.passkey(CredentialExchangePasskey(
                    credentialID: Data(),
                    relyingPartyIdentifier: "github.com",
                    userName: "alice",
                    userHandle: Data("handle".utf8),
                    privateKey: Data(repeating: 0x30, count: 48)
                ))]
            ),
            CredentialExchangeItem(
                title: "无 RP",
                credentials: [.passkey(CredentialExchangePasskey(
                    credentialID: Data(repeating: 0x01, count: 32),
                    relyingPartyIdentifier: "   ",
                    userName: "alice",
                    userHandle: Data("handle".utf8),
                    privateKey: Data(repeating: 0x30, count: 48)
                ))]
            ),
            CredentialExchangeItem(
                title: "无 handle",
                credentials: [.passkey(CredentialExchangePasskey(
                    credentialID: Data(repeating: 0x02, count: 32),
                    relyingPartyIdentifier: "github.com",
                    userName: "alice",
                    userHandle: Data(),
                    privateKey: Data(repeating: 0x30, count: 48)
                ))]
            ),
            CredentialExchangeItem(
                title: "无私钥",
                credentials: [.passkey(CredentialExchangePasskey(
                    credentialID: Data(repeating: 0x03, count: 32),
                    relyingPartyIdentifier: "github.com",
                    userName: "alice",
                    userHandle: Data("handle".utf8),
                    privateKey: Data()
                ))]
            ),
            CredentialExchangeItem(
                title: "好的那条",
                credentials: [.passkey(CredentialExchangePasskey(
                    credentialID: Data(repeating: 0x04, count: 32),
                    relyingPartyIdentifier: "example.com",
                    userName: "bob",
                    userHandle: Data("bob-handle".utf8),
                    privateKey: Data(repeating: 0x30, count: 48)
                ))]
            )
        ]
    )

    let plan = CredentialExchangeCodec.importPlan(accounts: [account])

    // 逐条降级：一条坏数据不影响其余条目。
    #expect(plan.passkeyCount == 1)
    #expect(plan.passkeys[0].credential.relyingPartyIdentifier == "example.com")
    #expect(plan.invalidCredentialCount == 4)
    #expect(plan.passkeyIssues.count == 4)
    #expect(plan.passkeyIssues.map(\.title) == ["无 ID", "无 RP", "无 handle", "无私钥"])
    #expect(plan.passkeyIssues.map(\.reason) == [
        .missingCredentialID,
        .missingRelyingPartyIdentifier,
        .missingUserHandle,
        .missingPrivateKey
    ])
}

@Test func credentialExchangeImportSkipsDuplicatePasskeysAndListsThem() {
    let existingCredentialID = Data(repeating: 0x05, count: 32)
    let existing = LocalPasskeyEntry(
        id: "passkey-1",
        projectID: "project-1",
        title: "GitHub",
        relyingPartyID: "github.com",
        username: "alice",
        userHandle: Data("handle".utf8).base64EncodedString(),
        credentialID: existingCredentialID.base64EncodedString(),
        publicKeyCOSE: Data(repeating: 0x01, count: 77).base64EncodedString(),
        privateKeyReference: "monica-passkey://existing",
        notes: ""
    )
    let newCredentialID = Data(repeating: 0x06, count: 32)
    let account = CredentialExchangeAccount(
        userName: "alice",
        items: [
            CredentialExchangeItem(
                title: "Already here",
                credentials: [.passkey(CredentialExchangePasskey(
                    credentialID: existingCredentialID,
                    relyingPartyIdentifier: "github.com",
                    userName: "alice",
                    userHandle: Data("handle".utf8),
                    privateKey: Data(repeating: 0x30, count: 48)
                ))]
            ),
            CredentialExchangeItem(
                title: "New",
                credentials: [
                    .passkey(CredentialExchangePasskey(
                        credentialID: newCredentialID,
                        relyingPartyIdentifier: "example.com",
                        userName: "bob",
                        userHandle: Data("bob-handle".utf8),
                        privateKey: Data(repeating: 0x30, count: 48)
                    )),
                    .passkey(CredentialExchangePasskey(
                        credentialID: newCredentialID,
                        relyingPartyIdentifier: "example.com",
                        userName: "bob",
                        userHandle: Data("bob-handle".utf8),
                        privateKey: Data(repeating: 0x30, count: 48)
                    ))
                ]
            )
        ]
    )

    let plan = CredentialExchangeCodec.importPlan(
        accounts: [account],
        existingPasskeyEntries: [existing]
    )

    #expect(plan.passkeyCount == 1)
    #expect(plan.skippedDuplicateCount == 2)
    #expect(plan.invalidCredentialCount == 0)
    #expect(plan.passkeyIssues.count == 2)
    #expect(plan.passkeyIssues.allSatisfy { $0.reason == .duplicate })
}

@Test func credentialExchangeExportEmitsPasskeyItemsAndSkipsInvalidOnes() {
    let credentialID = Data(repeating: 0x07, count: 32)
    let passkey = CredentialExchangePasskey(
        credentialID: credentialID,
        relyingPartyIdentifier: "github.com",
        userName: "alice",
        userDisplayName: "Alice",
        userHandle: Data("handle".utf8),
        privateKey: Data(repeating: 0x30, count: 48)
    )
    let plan = CredentialExchangeCodec.exportPlan(
        loginEntries: [],
        totpEntries: [],
        passkeyExports: [
            CredentialExchangePasskeyExport(title: "GitHub", favorite: true, credential: passkey),
            // 私钥未加载的条目必须跳过，而不是发出空 key。
            CredentialExchangePasskeyExport(
                title: "Broken",
                credential: CredentialExchangePasskey(
                    credentialID: Data(repeating: 0x08, count: 32),
                    relyingPartyIdentifier: "example.com",
                    userName: "bob",
                    userHandle: Data("handle".utf8),
                    privateKey: Data()
                )
            ),
            // 重复 credentialID 只导出一次。
            CredentialExchangePasskeyExport(title: "Duplicate", credential: passkey)
        ]
    )

    #expect(plan.passkeyCount == 1)
    #expect(plan.skippedCount == 2)
    #expect(!plan.isEmpty)
    #expect(plan.account.items.count == 1)
    #expect(plan.account.items[0].title == "GitHub")
    #expect(plan.account.items[0].urls == ["https://github.com"])
    #expect(plan.account.items[0].favorite)
    guard case .passkey(let exported) = plan.account.items[0].credentials[0] else {
        Issue.record("导出条目应包含通行密钥凭据")
        return
    }
    #expect(exported == passkey)
}

@Test func credentialExchangeEmptyExportPlanAccountsForPasskeys() {
    let plan = CredentialExchangeCodec.exportPlan(loginEntries: [], totpEntries: [])
    #expect(plan.isEmpty)
    #expect(plan.passkeyCount == 0)
}
