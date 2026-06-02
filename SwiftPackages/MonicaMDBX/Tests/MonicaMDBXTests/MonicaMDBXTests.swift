import Testing
import Foundation
import MonicaMDBX

@Test func bridgeInfoDocumentsUniffiPath() {
    let info = MonicaMDBXBridgeInfo()

    #expect(info.bridge == "UniFFI")
    #expect(info.state == .ready)
    #expect(MonicaMDBXBindingAvailability.binaryModule == "mdbx_ffiFFI")
}

@Test func runtimeReportsUnavailableOutsideIOS() {
    #if !os(iOS)
    do {
        _ = try MonicaMDBXRuntime.createVault(
            at: URL(fileURLWithPath: "/tmp/monica-unavailable.mdbx"),
            password: "中文 password 12345!",
            deviceID: "macos-swift-test"
        )
        Issue.record("MDBX runtime should not be available in non-iOS SwiftPM tests.")
    } catch MonicaMDBXError.unavailableOnCurrentPlatform {
        return
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    #endif
}
