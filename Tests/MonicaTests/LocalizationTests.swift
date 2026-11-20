import Foundation
import XCTest

final class LocalizationTests: XCTestCase {
    private struct CatalogEntry: Decodable {
        struct Localization: Decodable {
            struct StringUnit: Decodable {
                let state: String?
                let value: String?
            }

            struct Variations: Decodable {
                struct PluralForm: Decodable {
                    let stringUnit: StringUnit?

                    var value: String? { stringUnit?.value }
                }

                struct Plural: Decodable {
                    let one: PluralForm?
                    let other: PluralForm?
                }

                let plural: Plural?
            }

            let stringUnit: StringUnit?
            let variations: Variations?
        }

        let localizations: [String: Localization]?
    }

    private struct Catalog: Decodable {
        let sourceLanguage: String
        let strings: [String: CatalogEntry]
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func loadCatalog() throws -> Catalog {
        let url = repositoryRoot().appendingPathComponent("App/MonicaApp/Localizable.xcstrings")
        return try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
    }

    private func englishValue(for key: String, in catalog: Catalog) -> String? {
        catalog.strings[key]?.localizations?["en"]?.stringUnit?.value
    }

    private func formatSpecifiers(in string: String) -> [String] {
        let expression = try! NSRegularExpression(
            pattern: #"%(?:\d+\$)?(?:@|lld|ld|d|s|f)"#
        )
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return expression.matches(in: string, range: range).compactMap { match in
            Range(match.range, in: string).map {
                String(string[$0]).replacingOccurrences(
                    of: #"%\d+\$"#,
                    with: "%",
                    options: .regularExpression
                )
            }
        }.sorted()
    }

    func testCatalogUsesSimplifiedChineseSourceAndCoversCoreUIInEnglish() throws {
        let catalog = try loadCatalog()
        XCTAssertEqual(catalog.sourceLanguage, "zh-Hans")

        let coreKeys = [
            "密码", "验证", "卡包", "设置",
            "解锁", "取消", "保存", "备份",
            "主密码", "通行密钥", "自动填充", "验证码"
        ]
        for key in coreKeys {
            let value = englishValue(for: key, in: catalog)
            XCTAssertNotNil(value, "Missing English localization for \(key)")
            XCTAssertNotEqual(value, key, "English localization should not fall back to Chinese for \(key)")
        }
    }

    func testEveryChineseCatalogKeyHasEnglishLocalizationAndMatchingFormatSpecifiers() throws {
        let catalog = try loadCatalog()
        let chineseExpression = try NSRegularExpression(pattern: #"[\u4e00-\u9fff]"#)

        for (key, entry) in catalog.strings {
            let keyRange = NSRange(key.startIndex..<key.endIndex, in: key)
            guard chineseExpression.firstMatch(in: key, range: keyRange) != nil else {
                continue
            }

            let localization = entry.localizations?["en"]
            let translatedValues: [String]
            if let value = localization?.stringUnit?.value {
                translatedValues = [value]
            } else if let plural = localization?.variations?.plural {
                translatedValues = [plural.one?.value, plural.other?.value].compactMap { $0 }
            } else {
                translatedValues = []
            }

            XCTAssertFalse(translatedValues.isEmpty, "Missing English localization for \(key)")
            for value in translatedValues {
                XCTAssertNil(
                    chineseExpression.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)),
                    "English localization still contains Chinese for \(key): \(value)"
                )
                XCTAssertEqual(
                    formatSpecifiers(in: value),
                    formatSpecifiers(in: key),
                    "Format specifiers differ for \(key): \(value)"
                )
            }
        }
    }

    func testCountStringsUsePluralVariations() throws {
        let catalog = try loadCatalog()
        let pluralKeys = ["%lld 个", "%lld 项", "已选择 %lld 项", "变更 %lld", "已移动 %lld 项"]
        for key in pluralKeys {
            let plural = catalog.strings[key]?.localizations?["en"]?.variations?.plural
            XCTAssertNotNil(plural?.one?.value, "Missing English singular form for \(key)")
            XCTAssertNotNil(plural?.other?.value, "Missing English plural form for \(key)")
        }
    }

    func testInfoPlistStringsProvideEnglishAndChinesePermissionCopy() throws {
        let root = repositoryRoot()
        let appEnglish = try readStrings(at: root.appendingPathComponent("App/MonicaApp/en.lproj/InfoPlist.strings"))
        let appChinese = try readStrings(at: root.appendingPathComponent("App/MonicaApp/zh-Hans.lproj/InfoPlist.strings"))

        for key in ["NSCameraUsageDescription", "NSFaceIDUsageDescription", "NSLocalNetworkUsageDescription"] {
            XCTAssertFalse(appEnglish[key]?.isEmpty ?? true, "Missing English \(key)")
            XCTAssertFalse(appChinese[key]?.isEmpty ?? true, "Missing Chinese \(key)")
        }
        XCTAssertTrue(appEnglish["NSCameraUsageDescription"]?.contains("scan") ?? false)
        XCTAssertTrue(appChinese["NSCameraUsageDescription"]?.contains("扫描") ?? false)

        let extensionPaths = [
            "Extensions/MonicaAutoFillExtension",
            "Extensions/MonicaWidgetExtension",
            "Extensions/MonicaShareExtension"
        ]
        for path in extensionPaths {
            let english = try readStrings(at: root.appendingPathComponent("\(path)/en.lproj/InfoPlist.strings"))
            let chinese = try readStrings(at: root.appendingPathComponent("\(path)/zh-Hans.lproj/InfoPlist.strings"))
            XCTAssertFalse(english["CFBundleDisplayName"]?.isEmpty ?? true, "Missing English display name in \(path)")
            XCTAssertFalse(chinese["CFBundleDisplayName"]?.isEmpty ?? true, "Missing Chinese display name in \(path)")
        }
    }

    func testCompiledEnglishBundleContainsTranslatedCoreStrings() throws {
        guard let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            XCTFail("English localization bundle is missing from the app")
            return
        }

        let tabTitle = bundle.localizedString(forKey: "密码", value: nil, table: nil)
        XCTAssertNotEqual(tabTitle, "密码")
        XCTAssertFalse(tabTitle.isEmpty)

        let cameraCopy = bundle.localizedString(forKey: "NSCameraUsageDescription", value: nil, table: "InfoPlist")
        XCTAssertTrue(cameraCopy.contains("scan"))
    }

    func testProjectDevelopmentRegionFallsBackToEnglish() throws {
        let project = try String(
            contentsOf: repositoryRoot().appendingPathComponent("Monica.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        XCTAssertTrue(project.contains("developmentRegion = en;"))
        XCTAssertTrue(project.contains("knownRegions = ("))
    }

    private func readStrings(at url: URL) throws -> [String: String] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        var result: [String: String] = [:]
        for line in contents.split(separator: "\n") {
            let pieces = line.split(separator: "=", maxSplits: 1)
            guard pieces.count == 2 else { continue }
            let key = pieces[0].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = pieces[1].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\";"))
            result[key] = value
        }
        return result
    }
}
