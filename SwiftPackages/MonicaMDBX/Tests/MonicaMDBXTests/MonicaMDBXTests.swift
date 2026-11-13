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
