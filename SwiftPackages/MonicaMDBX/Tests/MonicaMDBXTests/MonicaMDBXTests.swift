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
