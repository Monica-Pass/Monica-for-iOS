@testable import Monica
import AuthenticationServices
import CryptoKit
import MonicaCore
import MonicaSecurity
import MonicaStorage
import MonicaSync
import MonicaWidgetShared
import SwiftUI
import UIKit
import XCTest

@MainActor
final class GeneratorSaveLoginTests: XCTestCase {
    private func makeUnlockedModel() throws -> AppSessionModel {
        let model = AppSessionModel(vaultRepository: LocalVaultRepository(engine: RecordingVaultEngine()))
        model.vaultName = "Mobile"
        model.vaultPassword = "中文 password 12345!"
        try model.createLocalVault(
            in: URL(fileURLWithPath: "/tmp/monica-app-tests", isDirectory: true),
            deviceID: "ios-app-test-device"
        )
        return model
    }

    func testSaveGeneratedLoginPersistsEditedGeneratorResult() throws {
        let model = try makeUnlockedModel()

        let entry = try model.saveGeneratedLogin(
            title: "  Example  ",
            username: "alice@example.com",
            password: "V7!edited-by-user",
            url: "https://example.com/login"
        )

        XCTAssertEqual(entry.title, "Example")
        XCTAssertEqual(entry.username, "alice@example.com")
        XCTAssertEqual(entry.password, "V7!edited-by-user")
        XCTAssertEqual(entry.url, "https://example.com/login")
        XCTAssertEqual(entry.urls, ["https://example.com/login"])
        XCTAssertEqual(model.loginEntries.map(\.id), [entry.id])
        XCTAssertEqual(model.loginEntries.first?.password, "V7!edited-by-user")
        if case .succeeded(let title) = model.entryOperationState {
            XCTAssertEqual(title, "Example")
        } else {
            XCTFail("保存生成结果后应进入 succeeded 状态，实际为 \(model.entryOperationState)")
        }
    }

    func testSaveGeneratedLoginRejectsEmptyTitleAndPassword() throws {
        let model = try makeUnlockedModel()

        XCTAssertThrowsError(
            try model.saveGeneratedLogin(title: "  \n ", username: "", password: "secret", url: "")
        ) { error in
            XCTAssertEqual(error as? AppGeneratedLoginSaveError, .missingTitle)
        }
        XCTAssertThrowsError(
            try model.saveGeneratedLogin(title: "Example", username: "", password: "", url: "")
        ) { error in
            XCTAssertEqual(error as? AppGeneratedLoginSaveError, .missingPassword)
        }
        XCTAssertTrue(model.loginEntries.isEmpty)
    }

    func testSaveGeneratedLoginRequiresUnlockedVault() throws {
        let model = AppSessionModel(vaultRepository: LocalVaultRepository(engine: RecordingVaultEngine()))

        XCTAssertThrowsError(
            try model.saveGeneratedLogin(
                title: "Example",
                username: "alice",
                password: "secret",
                url: "https://example.com"
            )
        ) { error in
            XCTAssertEqual(error as? AppGeneratedLoginSaveError, .vaultLocked)
        }
    }

    func testGeneratorAndGuideCopyNeverOverpromisesAutoFill() {
        var visibleCopy: [String] = []
        for capability in AutoFillCapability.matrix {
            visibleCopy.append(AppAutoFillCapabilityCopy.title(for: capability))
            visibleCopy.append(AppAutoFillCapabilityCopy.detail(for: capability))
            visibleCopy.append(AppAutoFillCapabilityCopy.availabilityLabel(for: capability.availability))
        }
        visibleCopy.append(String(localized: "系统 QuickType 是否出现由 iOS 决定，Monica 无法强制它在所有输入框出现。"))

        XCTAssertNil(
            AutoFillCapabilityCopyGuard.firstOverpromisingPhrase(in: visibleCopy),
            "能力矩阵与自动填充说明不得出现承诺可填充任意字段的文案"
        )
    }
}
