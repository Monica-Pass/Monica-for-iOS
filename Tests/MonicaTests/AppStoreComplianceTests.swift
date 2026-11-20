import Foundation
import XCTest

/// 回归测试：App Store 合规所需的用途说明、出口合规声明与隐私清单。
///
/// 这些文件不会参与 Swift Package 测试，只在 `MonicaTests` 中校验仓库内容；
/// 打包后的实际内容由 `Scripts/archive.sh`/App Store 校验兜底。
final class AppStoreComplianceTests: XCTestCase {
    private struct ManifestExpectation {
        let path: String
        let userDefaultsReasons: [String]
        let fileTimestampReasons: [String]
        let diskSpaceReasons: [String]
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func loadPlist(_ relativePath: String) throws -> [String: Any] {
        let url = repositoryRoot().appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(plist as? [String: Any], "\(relativePath) 不是字典类型的 plist")
    }

    private func topLevelKeys(in relativePath: String) throws -> [String] {
        let url = repositoryRoot().appendingPathComponent(relativePath)
        let contents = try String(contentsOf: url, encoding: .utf8)
        let expression = try NSRegularExpression(pattern: #"(?m)^\t<key>([^<]+)</key>$"#)
        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        return expression.matches(in: contents, range: range).compactMap { match in
            Range(match.range(at: 1), in: contents).map { String(contents[$0]) }
        }
    }

    private func localizedStrings(at relativePath: String) throws -> [String: String] {
        let url = repositoryRoot().appendingPathComponent(relativePath)
        let contents = try String(contentsOf: url, encoding: .utf8)
        let expression = try NSRegularExpression(
            pattern: #""((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";"#
        )
        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        var result: [String: String] = [:]
        for match in expression.matches(in: contents, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: contents),
                  let valueRange = Range(match.range(at: 2), in: contents) else { continue }
            let value = String(contents[valueRange])
                .replacingOccurrences(of: #"\\"#, with: #"\"#)
                .replacingOccurrences(of: #"\""#, with: #"""#)
            result[String(contents[keyRange])] = value
        }
        return result
    }

    func testAppInfoPlistDeclaresFaceIDAndExemptEncryption() throws {
        let info = try loadPlist("App/MonicaApp/Info.plist")

        let faceID = try XCTUnwrap(info["NSFaceIDUsageDescription"] as? String)
        XCTAssertFalse(faceID.isEmpty)
        XCTAssertTrue(faceID.contains("解锁"), "Face ID 文案应说明用于解锁保险库：\(faceID)")
        XCTAssertTrue(faceID.contains("生物识别"), "Face ID 文案应说明生物识别数据的处理方式：\(faceID)")
        XCTAssertFalse(faceID.contains("广告"), "Face ID 文案不得声称用于广告等未实现用途：\(faceID)")

        XCTAssertEqual(
            info["ITSAppUsesNonExemptEncryption"] as? Bool,
            false,
            "本 App 仅使用标准密码学（AES-GCM/Twofish/Argon2id/系统 TLS 与 Keychain），应声明 false"
        )

        let keys = try topLevelKeys(in: "App/MonicaApp/Info.plist")
        XCTAssertEqual(Set(keys).count, keys.count, "Info.plist 存在重复顶层键：\(keys.sorted())")
        XCTAssertEqual(keys.filter { $0 == "NSFaceIDUsageDescription" }.count, 1)
        XCTAssertEqual(keys.filter { $0 == "ITSAppUsesNonExemptEncryption" }.count, 1)
        XCTAssertEqual(
            keys.filter { $0 == "NSLocalNetworkUsageDescription" }.count,
            1,
            "NSLocalNetworkUsageDescription 必须只有一个，否则 InfoPlist.strings 会覆盖成旧文案"
        )

        let localNetwork = try XCTUnwrap(info["NSLocalNetworkUsageDescription"] as? String)
        XCTAssertTrue(localNetwork.contains("Wi-Fi"), "本地网络文案应描述局域网同步：\(localNetwork)")
        XCTAssertFalse(localNetwork.contains("自托管"), "本地网络文案不应再引用已下线的自托管服务器：\(localNetwork)")
    }

    func testAutoFillInfoPlistDeclaresFaceIDForPasskeys() throws {
        let info = try loadPlist("Extensions/MonicaAutoFillExtension/Info.plist")
        let faceID = try XCTUnwrap(info["NSFaceIDUsageDescription"] as? String)
        XCTAssertTrue(faceID.contains("通行密钥"), "自动填充扩展的 Face ID 文案应说明通行密钥用途：\(faceID)")
    }

    func testLocalizedUsageDescriptionsStayInSyncWithInfoPlist() throws {
        let appInfo = try loadPlist("App/MonicaApp/Info.plist")
        let autoFillInfo = try loadPlist("Extensions/MonicaAutoFillExtension/Info.plist")
        let appFaceID = try XCTUnwrap(appInfo["NSFaceIDUsageDescription"] as? String)
        let autoFillFaceID = try XCTUnwrap(autoFillInfo["NSFaceIDUsageDescription"] as? String)

        let chinese = try localizedStrings(at: "App/MonicaApp/zh-Hans.lproj/InfoPlist.strings")
        XCTAssertEqual(chinese["NSFaceIDUsageDescription"], appFaceID)
        XCTAssertTrue(
            try XCTUnwrap(chinese["NSLocalNetworkUsageDescription"]).contains("Wi-Fi"),
            "中文本地网络文案应描述局域网同步"
        )
        XCTAssertFalse(
            try XCTUnwrap(chinese["NSLocalNetworkUsageDescription"]).contains("自托管"),
            "中文 InfoPlist.strings 不应保留旧的自托管服务器文案"
        )

        let english = try localizedStrings(at: "App/MonicaApp/en.lproj/InfoPlist.strings")
        let englishFaceID = try XCTUnwrap(english["NSFaceIDUsageDescription"])
        XCTAssertTrue(englishFaceID.contains("unlock"))
        XCTAssertTrue(englishFaceID.contains("biometric"))
        XCTAssertFalse(englishFaceID.contains("广告"))
        XCTAssertTrue(try XCTUnwrap(english["NSLocalNetworkUsageDescription"]).contains("Wi-Fi"))
        XCTAssertFalse(try XCTUnwrap(english["NSLocalNetworkUsageDescription"]).contains("self-hosted"))

        let autoFillChinese = try localizedStrings(
            at: "Extensions/MonicaAutoFillExtension/zh-Hans.lproj/InfoPlist.strings"
        )
        XCTAssertEqual(autoFillChinese["NSFaceIDUsageDescription"], autoFillFaceID)

        let autoFillEnglish = try localizedStrings(
            at: "Extensions/MonicaAutoFillExtension/en.lproj/InfoPlist.strings"
        )
        XCTAssertTrue(try XCTUnwrap(autoFillEnglish["NSFaceIDUsageDescription"]).contains("passkey"))
    }

    func testPrivacyManifestsDeclareActualRequiredReasonAPIs() throws {
        let expectations = [
            ManifestExpectation(
                path: "App/MonicaApp/PrivacyInfo.xcprivacy",
                userDefaultsReasons: ["CA92.1", "1C8F.1"],
                fileTimestampReasons: ["C617.1"],
                diskSpaceReasons: ["E174.1"]
            ),
            ManifestExpectation(
                path: "Extensions/MonicaAutoFillExtension/PrivacyInfo.xcprivacy",
                userDefaultsReasons: ["CA92.1"],
                fileTimestampReasons: ["C617.1"],
                diskSpaceReasons: ["E174.1"]
            ),
            ManifestExpectation(
                path: "Extensions/MonicaWidgetExtension/PrivacyInfo.xcprivacy",
                userDefaultsReasons: ["1C8F.1"],
                fileTimestampReasons: [],
                diskSpaceReasons: []
            ),
            ManifestExpectation(
                path: "Extensions/MonicaShareExtension/PrivacyInfo.xcprivacy",
                userDefaultsReasons: [],
                fileTimestampReasons: [],
                diskSpaceReasons: []
            ),
        ]

        for expectation in expectations {
            let manifest = try loadPlist(expectation.path)
            XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false, expectation.path)
            XCTAssertEqual((manifest["NSPrivacyTrackingDomains"] as? [Any])?.count, 0, expectation.path)
            XCTAssertEqual((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.count, 0, expectation.path)

            let entries = try XCTUnwrap(
                manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]],
                "\(expectation.path) 缺少 NSPrivacyAccessedAPITypes"
            )
            var reasonsByCategory: [String: [String]] = [:]
            for entry in entries {
                let category = try XCTUnwrap(entry["NSPrivacyAccessedAPIType"] as? String)
                let reasons = try XCTUnwrap(entry["NSPrivacyAccessedAPITypeReasons"] as? [String])
                XCTAssertFalse(reasons.isEmpty, "\(expectation.path) 的 \(category) 没有 reason code")
                XCTAssertNil(reasonsByCategory[category], "\(expectation.path) 重复声明 \(category)")
                reasonsByCategory[category] = reasons.sorted()
            }

            XCTAssertEqual(
                reasonsByCategory["NSPrivacyAccessedAPICategoryUserDefaults"] ?? [],
                expectation.userDefaultsReasons.sorted(),
                "\(expectation.path) 的 UserDefaults reason code 与代码使用不符"
            )
            XCTAssertEqual(
                reasonsByCategory["NSPrivacyAccessedAPICategoryFileTimestamp"] ?? [],
                expectation.fileTimestampReasons.sorted(),
                "\(expectation.path) 的 FileTimestamp reason code 与代码使用不符"
            )
            XCTAssertEqual(
                reasonsByCategory["NSPrivacyAccessedAPICategoryDiskSpace"] ?? [],
                expectation.diskSpaceReasons.sorted(),
                "\(expectation.path) 的 DiskSpace reason code 与代码使用不符"
            )

            let expectedCategories = [
                expectation.userDefaultsReasons.isEmpty ? nil : "NSPrivacyAccessedAPICategoryUserDefaults",
                expectation.fileTimestampReasons.isEmpty ? nil : "NSPrivacyAccessedAPICategoryFileTimestamp",
                expectation.diskSpaceReasons.isEmpty ? nil : "NSPrivacyAccessedAPICategoryDiskSpace",
            ].compactMap { $0 }
            XCTAssertEqual(Set(reasonsByCategory.keys), Set(expectedCategories), expectation.path)
        }
    }

    func testPrivacyManifestsAreRegisteredWithEveryTarget() throws {
        let project = try String(
            contentsOf: repositoryRoot().appendingPathComponent("Monica.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let resourcePhaseEntries = project.components(
            separatedBy: "/* PrivacyInfo.xcprivacy in Resources */,"
        ).count - 1
        XCTAssertEqual(resourcePhaseEntries, 4, "四个 target 都应把 PrivacyInfo.xcprivacy 加入 Resources")

        for path in [
            "App/MonicaApp/PrivacyInfo.xcprivacy",
            "Extensions/MonicaAutoFillExtension/PrivacyInfo.xcprivacy",
            "Extensions/MonicaShareExtension/PrivacyInfo.xcprivacy",
            "Extensions/MonicaWidgetExtension/PrivacyInfo.xcprivacy",
        ] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: repositoryRoot().appendingPathComponent(path).path))
        }
    }
}
