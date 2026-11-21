import Testing
import Foundation
import MonicaMDBX

@Test func bridgeInfoDocumentsUniffiPath() {
    let info = MonicaMDBXBridgeInfo()

    #expect(info.bridge == "UniFFI")
    #expect(info.state == .ready)
    #expect(MonicaMDBXBindingAvailability.binaryModule == "mdbx_ffiFFI")
}

@Test func runtimeCreatesAndReopensVaultWithRealNativeBindings() throws {
    // xcframework 现在同时携带 iOS 与 macOS slice，因此在 macOS 上跑 SwiftPM 测试
    // 也能走真实 FFI 路径，而不是回落到 unavailableOnCurrentPlatform stub。
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("monica-mdbx-\(UUID().uuidString).mdbx", isDirectory: false)
    defer { try? FileManager.default.removeItem(at: vaultURL) }

    let vault = try MonicaMDBXRuntime.createVault(
        at: vaultURL,
        password: "中文 password 12345!",
        deviceID: "swiftpm-native-test"
    )
    let info = vault.info()
    #expect(!info.vaultID.isEmpty)

    let reopened = try MonicaMDBXRuntime.openVault(
        at: vaultURL,
        password: "中文 password 12345!",
        deviceID: "swiftpm-native-test"
    )
    #expect(reopened.info().vaultID == info.vaultID)
}

@Test func resetMasterPasswordRewrapsVaultKeyAndKeepsSecurityKeyMethod() throws {
    // 主密码是包裹 vault key 的 KEK：改密只重写 Password 解锁方式，
    // 数据不变、旧口令立即失效、此前注册的 security key 仍能解锁。
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("monica-mdbx-change-\(UUID().uuidString).mdbx", isDirectory: false)
    defer { try? FileManager.default.removeItem(at: vaultURL) }

    let vault = try MonicaMDBXRuntime.createVault(
        at: vaultURL,
        password: "old password",
        deviceID: "swiftpm-change-password"
    )
    let vaultID = vault.info().vaultID
    let project = try vault.createProject(title: "Probe")
    #expect(!project.id.isEmpty)

    let securityKeyMaterial = Data(repeating: 0x5A, count: 32)
    try vault.setupLocalSecurityKeyUnlock(securityKeyMaterial)

    try vault.resetMasterPassword("new password 123!")

    let reopened = try MonicaMDBXRuntime.openVault(
        at: vaultURL,
        password: "new password 123!",
        deviceID: "swiftpm-change-password"
    )
    #expect(reopened.info().vaultID == vaultID)
    #expect(try reopened.createProject(title: "After").title == "After")

    let securityKeyOpened = try MonicaMDBXRuntime.openVaultWithSecurityKey(
        at: vaultURL,
        securityKeyMaterial: securityKeyMaterial,
        deviceID: "swiftpm-change-password"
    )
    #expect(securityKeyOpened.info().vaultID == vaultID)

    #expect(throws: (any Error).self) {
        _ = try MonicaMDBXRuntime.openVault(
            at: vaultURL,
            password: "old password",
            deviceID: "swiftpm-change-password"
        )
    }
}

@Test func loginEntryIconSurvivesUpdatesAndReopen() throws {
    // 图标存在登录条目的 payload `icon` 键里：更新其它字段不能丢，
    // 未知标识原样保存（渲染层负责回退），nil 则清除并回到按类型默认。
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("monica-mdbx-icon-\(UUID().uuidString).mdbx", isDirectory: false)
    defer { try? FileManager.default.removeItem(at: vaultURL) }

    let vault = try MonicaMDBXRuntime.createVault(
        at: vaultURL,
        password: "icon password 123!",
        deviceID: "swiftpm-icon-test"
    )
    let project = try vault.createProject(title: "Icons")
    let entry = try vault.createLoginEntry(
        projectID: project.id,
        title: "银行",
        username: "alice",
        password: "secret",
        url: "https://bank.example"
    )
    #expect(entry.icon == nil)

    let withIcon = try vault.setLoginEntryIcon(projectID: project.id, entryID: entry.id, icon: "catalog:bank")
    #expect(withIcon.icon == "catalog:bank")

    let updated = try vault.updateLoginEntry(
        projectID: project.id,
        entryID: entry.id,
        title: "银行（改）",
        username: "alice",
        password: "secret2",
        url: "https://bank.example",
        notes: "备注"
    )
    #expect(updated.icon == "catalog:bank")
    #expect(updated.title == "银行（改）")

    let unknown = try vault.setLoginEntryIcon(projectID: project.id, entryID: entry.id, icon: "sf:not.a.real.symbol")
    #expect(unknown.icon == "sf:not.a.real.symbol")

    let reopened = try MonicaMDBXRuntime.openVault(
        at: vaultURL,
        password: "icon password 123!",
        deviceID: "swiftpm-icon-test"
    )
    let reopenedEntries = try reopened.listLoginEntries(projectID: project.id)
    #expect(reopenedEntries.first(where: { $0.id == entry.id })?.icon == "sf:not.a.real.symbol")

    _ = try reopened.setLoginEntryIcon(projectID: project.id, entryID: entry.id, icon: nil)
    #expect(try reopened.listLoginEntries(projectID: project.id).first?.icon == nil)
}
