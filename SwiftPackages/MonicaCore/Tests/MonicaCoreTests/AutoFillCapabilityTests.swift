import XCTest
@testable import MonicaCore

final class AutoFillCapabilityTests: XCTestCase {
    func testCapabilityMatrixCoversEveryPublicAPIBoundary() {
        XCTAssertEqual(
            AutoFillCapability.matrix.map(\.id),
            [
                "credential-provider",
                "system-quicktype",
                "arbitrary-field-scan",
                "inline-suggestion-panel",
                "strong-password-suggestion",
                "read-default-manager",
                "default-manager-selection",
                "open-app-settings",
                "open-password-settings",
                "in-app-generator",
                "save-generated-login"
            ]
        )
        XCTAssertEqual(AutoFillCapability.matrix.count, Set(AutoFillCapability.matrix.map(\.id)).count)
    }

    func testQuickTypeAvailabilityIsDecidedByIOSNotByApp() {
        XCTAssertEqual(AutoFillCapability.systemQuickType.availability, .systemDecided)
        XCTAssertEqual(AutoFillCapability.defaultManagerSelection.availability, .systemDecided)
        XCTAssertNotEqual(AutoFillCapability.systemQuickType.availability, .supported)
    }

    func testArbitraryFieldInjectionIsMarkedUnsupported() {
        XCTAssertEqual(AutoFillCapability.arbitraryFieldScan.availability, .unsupported)
        XCTAssertEqual(AutoFillCapability.inlineSuggestionPanel.availability, .unsupported)
        XCTAssertEqual(AutoFillCapability.strongPasswordSuggestion.availability, .unsupported)
        XCTAssertEqual(AutoFillCapability.readDefaultManager.availability, .unsupported)
        XCTAssertEqual(AutoFillCapability.openPasswordSettings.availability, .unsupported)
    }

    func testInAppGeneratorAndLoginSavingAreSupported() {
        XCTAssertEqual(AutoFillCapability.inAppGenerator.availability, .supported)
        XCTAssertEqual(AutoFillCapability.saveGeneratedLogin.availability, .supported)
        XCTAssertEqual(AutoFillCapability.openAppSettings.availability, .supported)
        XCTAssertEqual(AutoFillCapability.credentialProvider.availability, .supported)
    }

    func testHighlightedCapabilitiesKeepTheFourHonestLimitsVisible() {
        XCTAssertEqual(
            AutoFillCapability.highlighted.map(\.id),
            [
                "system-quicktype",
                "arbitrary-field-scan",
                "inline-suggestion-panel",
                "strong-password-suggestion",
                "in-app-generator"
            ]
        )
        XCTAssertTrue(AutoFillCapability.matrix.allSatisfy { capability in
            capability.isHighlighted == AutoFillCapability.highlighted.contains(capability)
        })
    }

    func testCopyGuardRejectsOverpromisingChineseAndEnglishCopy() {
        XCTAssertTrue(AutoFillCapabilityCopyGuard.isOverpromising("保存后保证可填充所有账号密码输入框"))
        XCTAssertTrue(AutoFillCapabilityCopyGuard.isOverpromising("Monica 可以自动填充任意字段"))
        XCTAssertTrue(AutoFillCapabilityCopyGuard.isOverpromising("Guaranteed to fill every input field"))
        XCTAssertTrue(
            AutoFillCapabilityCopyGuard.isOverpromising("Monica can fill any field in other apps")
        )
        XCTAssertEqual(
            AutoFillCapabilityCopyGuard.firstOverpromisingPhrase(in: ["正常文案", "确保能填充"]),
            "确保能填充"
        )
    }

    func testCopyGuardAcceptsHonestLimitationCopy() {
        let honestCopy = [
            "系统 QuickType 是否出现由 iOS 决定，Monica 无法强制它在所有输入框出现。",
            "iOS 不允许第三方自动填充扩展监听其它 App 或网页里的输入框。",
            "系统未识别的输入框不会显示 Monica 建议。",
            "可以在 Monica 内生成密码并保存为登录项，再复制使用。",
            "The system decides whether QuickType appears; Monica cannot force it."
        ]
        XCTAssertNil(AutoFillCapabilityCopyGuard.firstOverpromisingPhrase(in: honestCopy))
    }
}
