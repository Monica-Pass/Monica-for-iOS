import XCTest
@testable import Monica

final class AppSettingsSearchTests: XCTestCase {
    // MARK: - 索引与设置页同源

    /// 枚举设置页里实际出现的 `AndroidParitySection` 标题，确保每个 section 都有索引项。
    /// 新增 / 改名 section 却忘记同步 `AppSettingsSearch.swift` 时，这条测试会直接失败。
    func testEverySettingsSectionTitleHasIndexItems() throws {
        let region = try settingsScreenSource()

        var discoveredTitles = Self.sectionTitles(in: region)
        XCTAssertEqual(discoveredTitles.count, 24, "设置页内联 section 数量与预期不一致，请同步更新索引或本测试")

        // 设置页里直接引用的子视图（例如 AppThemeSettingsView）自身也带 section，需要一起收集。
        for composed in Self.composedSections {
            XCTAssertTrue(
                region.contains(composed.type),
                "设置页没有引用 \(composed.type)，请更新本测试的 section 清单"
            )
            let source = try String(
                contentsOf: try repoRoot().appendingPathComponent("App/MonicaApp/\(composed.file)"),
                encoding: .utf8
            )
            guard let block = Self.viewStructBlocks(in: source).first(where: { $0.name == composed.type }) else {
                XCTFail("找不到 \(composed.type) 的定义")
                continue
            }
            XCTAssertEqual(
                Self.sectionTitles(in: block.body),
                [composed.titleKey],
                "\(composed.type) 的 section 标题必须和 AppSettingsSection.\(composed.titleKey) 保持一致"
            )
            discoveredTitles.insert(composed.titleKey)
        }

        let catalogTitles = Set(AppSettingsSection.allCases.map(\.titleKey))
        XCTAssertEqual(
            discoveredTitles,
            catalogTitles,
            "设置页 section 标题必须和 AppSettingsSection 一一对应；新增或改名 section 时请同步 AppSettingsSearch.swift 与索引项。"
        )

        for section in AppSettingsSection.allCases {
            let items = AppSettingsSearchIndex.all.filter { $0.section == section }
            XCTAssertFalse(items.isEmpty, "section「\(section.titleKey)」没有登记任何搜索索引项")
        }

        // 每个 section 都必须挂上滚动锚点，且只挂一次。
        let anchorNames = Self.matches(
            in: region,
            pattern: "\\.settingsSearchAnchor\\(\\.(\\w+)"
        )
        XCTAssertEqual(anchorNames.count, AppSettingsSection.allCases.count, "滚动锚点数量与 section 数量不一致")
        XCTAssertEqual(Set(anchorNames), Set(AppSettingsSection.allCases.map(\.rawValue)))
    }

    /// 设置页以单行子视图形式挂载的 section。
    private static let composedSections: [(file: String, type: String, titleKey: String)] = [
        ("AppThemeSettingsView.swift", "AppThemeSettingsView", "主题与图标"),
        ("AppLanguageSettingsView.swift", "AppLanguageSettingsView", "语言"),
        ("AppPlusStoreView.swift", "AppPlusSettingsView", "Monica Plus"),
        ("AppAutoFillEnablementSection.swift", "AppAutoFillEnablementSection", "启用 Monica 作为密码管理器"),
        ("SensitivePrivacySettingsView.swift", "SensitivePrivacySettingsSection", "敏感隐私"),
        ("AppCloudKitSync.swift", "AppCloudKitSyncSection", "iCloud 同步"),
    ]

    func testIndexIdentifiersAndSectionTitlesAreUnique() {
        let ids = AppSettingsSearchIndex.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "索引项 id 必须唯一且稳定")

        let sectionTitles = AppSettingsSection.allCases.map(\.titleKey)
        XCTAssertEqual(Set(sectionTitles).count, sectionTitles.count, "section 标题不能重复，否则面包屑无法区分")

        for item in AppSettingsSearchIndex.all {
            XCTAssertFalse(item.titleKey.isEmpty)
            XCTAssertFalse(item.title.isEmpty)
            XCTAssertTrue(item.breadcrumb.contains(item.section.title))
            XCTAssertEqual(item.scrollAnchor, item.section)
        }
    }

    // MARK: - 匹配

    func testNormalizeAppliesNFKCAndCaseFolding() {
        XCTAssertEqual(AppSettingsSearch.normalize("ＡｕｔｏＦｉｌｌ"), "autofill")
        XCTAssertEqual(AppSettingsSearch.normalize("AUTOFILL"), "autofill")
        XCTAssertEqual(AppSettingsSearch.tokens(in: "自动　填充"), ["自动", "填充"])
        XCTAssertEqual(AppSettingsSearch.tokens(in: "  auto   fill "), ["auto", "fill"])
    }

    func testMatchingRequiresEveryToken() {
        let item = AppSettingsSearchItem(
            id: "test.alpha",
            titleKey: "Alpha Backup",
            section: .about,
            keywords: []
        )

        XCTAssertEqual(AppSettingsSearch.match(item: item, tokens: ["alpha", "backup"])?.tier, .title)
        XCTAssertNil(AppSettingsSearch.match(item: item, tokens: ["alpha", "zzz"]))
        XCTAssertNil(AppSettingsSearch.match(item: item, tokens: []))
    }

    func testTitleHitOutranksKeywordHitAndPathHit() {
        let titleHit = AppSettingsSearchItem(
            id: "test.title",
            titleKey: "Alpha Backup",
            section: .about,
            keywords: []
        )
        let keywordHit = AppSettingsSearchItem(
            id: "test.keyword",
            titleKey: "Gamma",
            section: .about,
            keywords: ["alpha", "backup"]
        )
        let pathHit = AppSettingsSearchItem(
            id: "test.path",
            titleKey: "Delta",
            section: .about,
            keywords: []
        )

        XCTAssertEqual(AppSettingsSearch.match(item: titleHit, tokens: ["alpha"])?.tier, .title)
        XCTAssertEqual(AppSettingsSearch.match(item: keywordHit, tokens: ["alpha"])?.tier, .keyword)
        // 面包屑里的分隔符既不在标题里，也不在关键词里，只可能命中路径。
        XCTAssertEqual(AppSettingsSearch.match(item: pathHit, tokens: ["›"])?.tier, .path)
        XCTAssertLessThan(AppSettingsSearchMatchTier.title, AppSettingsSearchMatchTier.keyword)
        XCTAssertLessThan(AppSettingsSearchMatchTier.keyword, AppSettingsSearchMatchTier.path)
    }

    // MARK: - 真实索引

    func testAutofillQueriesHitAutofillEntries() {
        let warmUp = AppSettingsSearchIndex.results(
            for: "自动填充",
            isVaultUnlocked: true,
            isDeveloperModeUnlocked: false
        )
        XCTAssertFalse(warmUp.isEmpty, "中文关键词必须能命中自动填充相关设置")

        for query in ["autofill", "auto fill", "填充", "zidongtianchong", "ＡｕｔｏＦｉｌｌ"] {
            let ids = Set(AppSettingsSearchIndex.results(
                for: query,
                isVaultUnlocked: true,
                isDeveloperModeUnlocked: false
            ).map(\.id))
            XCTAssertTrue(ids.contains("auto-fill.index"), "查询「\(query)」应命中自动填充索引")
            XCTAssertTrue(ids.contains("auto-fill.enablement"), "查询「\(query)」应命中启用密码管理器")
        }
    }

    func testResultsAreSortedByTierThenStableOrder() {
        let queries = ["autofill", "›", "beifen", "yuyan"]
        for query in queries {
            let results = AppSettingsSearchIndex.results(
                for: query,
                isVaultUnlocked: true,
                isDeveloperModeUnlocked: false
            )
            XCTAssertFalse(results.isEmpty, "查询「\(query)」不应为空")

            let tiers = results.map(\.tier)
            XCTAssertEqual(tiers, tiers.sorted(), "结果必须先按标题命中、关键词命中、路径命中排序（\(query)）")

            let ids = results.map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count)

            for result in results {
                XCTAssertEqual(result.scrollAnchor, result.item.section)
            }
        }

        // 「›」只出现在面包屑里，所以所有结果都应是路径命中。
        let pathOnly = AppSettingsSearchIndex.results(
            for: "›",
            isVaultUnlocked: true,
            isDeveloperModeUnlocked: false
        )
        XCTAssertTrue(pathOnly.allSatisfy { $0.tier == .path })
        XCTAssertEqual(pathOnly.count, AppSettingsSearchIndex.items(
            isVaultUnlocked: true,
            isDeveloperModeUnlocked: false
        ).count)
    }

    func testEmptyQueryReturnsNoResults() {
        for query in ["", "   ", "\u{3000}", "\n\t"] {
            XCTAssertTrue(
                AppSettingsSearchIndex.results(
                    for: query,
                    isVaultUnlocked: true,
                    isDeveloperModeUnlocked: false
                ).isEmpty,
                "空查询「\(query.debugDescription)」应返回空结果以恢复完整列表"
            )
        }
    }

    // MARK: - 锁定态与开发者模式

    func testLockedVaultKeepsSensitiveTitlesButDropsKeywords() {
        let lockedItems = AppSettingsSearchIndex.items(isVaultUnlocked: false, isDeveloperModeUnlocked: false)
        let sensitiveItems = lockedItems.filter(\.isSensitive)
        XCTAssertFalse(sensitiveItems.isEmpty, "应存在敏感索引项")

        for item in sensitiveItems {
            XCTAssertTrue(item.keywords.isEmpty, "锁定态下敏感项「\(item.titleKey)」不能保留关键词")
            XCTAssertFalse(item.title.isEmpty, "锁定态下敏感项仍需展示标题")
        }

        // 拼音关键词只存在于关键词字段：锁定后不应再能被搜出来。
        XCTAssertTrue(
            AppSettingsSearchIndex.results(for: "zhumima", isVaultUnlocked: false, isDeveloperModeUnlocked: false).isEmpty
        )
        XCTAssertTrue(
            AppSettingsSearchIndex.results(for: "key file", isVaultUnlocked: false, isDeveloperModeUnlocked: false).isEmpty
        )

        let unlocked = AppSettingsSearchIndex.results(
            for: "zhumima",
            isVaultUnlocked: true,
            isDeveloperModeUnlocked: false
        )
        XCTAssertTrue(unlocked.contains { $0.id == "master-password.change" })
    }

    func testDeveloperSectionIsHiddenUntilDeveloperModeUnlocked() {
        XCTAssertTrue(
            AppSettingsSearchIndex.results(for: "redacted", isVaultUnlocked: true, isDeveloperModeUnlocked: false).isEmpty
        )
        let unlocked = AppSettingsSearchIndex.results(
            for: "redacted",
            isVaultUnlocked: true,
            isDeveloperModeUnlocked: true
        )
        XCTAssertEqual(unlocked.map(\.id), ["developer.diagnostics"])
        XCTAssertFalse(
            AppSettingsSearchIndex.items(isVaultUnlocked: true, isDeveloperModeUnlocked: true)
                .contains { $0.requiresDeveloperMode && $0.section != .developer }
        )
    }

    // MARK: - 源码扫描

    private func settingsScreenSource() throws -> String {
        let source = try String(
            contentsOf: try repoRoot().appendingPathComponent("App/MonicaApp/SettingsRootView.swift"),
            encoding: .utf8
        )
        guard let start = source.range(of: "private var settingsScreen: some View {") else {
            XCTFail("找不到设置页 settingsScreen 源码")
            return ""
        }
        guard let end = source.range(of: "private struct AndroidParityOperationTimelineRow") else {
            XCTFail("找不到设置页源码的结束标记")
            return String(source[start.lowerBound...])
        }
        XCTAssertLessThan(start.lowerBound, end.lowerBound)
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private func repoRoot() throws -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func swiftFiles(in relativeDirectory: String) throws -> [URL] {
        let root = try repoRoot().appendingPathComponent(relativeDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            XCTFail("无法枚举 \(relativeDirectory)")
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        XCTAssertFalse(files.isEmpty)
        return files
    }

    /// `AndroidParitySection(title: …)` 的所有标题；支持 `String(localized:)` 包装与一层括号嵌套。
    static func sectionTitles(in source: String) -> Set<String> {
        let pattern = "AndroidParitySection\\(title:\\s*((?:[^()]|\\([^()]*\\))+?)\\)\\s*\\{"
        var titles = Set<String>()
        for argument in matches(in: source, pattern: pattern) {
            if let title = firstQuotedString(in: argument) {
                titles.insert(title)
            }
        }
        return titles
    }

    static func viewStructBlocks(in source: String) -> [(name: String, body: String)] {
        let pattern = "(?m)^(?:private |fileprivate |internal |public )?struct (\\w+)\\s*:\\s*View\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: ns.length))

        var blocks: [(String, String)] = []
        for (index, match) in matches.enumerated() {
            let nameRange = match.range(at: 1)
            guard nameRange.location != NSNotFound else { continue }
            let start = match.range.location
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            blocks.append((ns.substring(with: nameRange), ns.substring(with: NSRange(location: start, length: end - start))))
        }
        return blocks
    }

    static func matches(in source: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0, length: ns.length)).map { match in
            match.numberOfRanges > 1 ? ns.substring(with: match.range(at: 1)) : ns.substring(with: match.range)
        }
    }

    static func firstQuotedString(in text: String) -> String? {
        let pattern = "\"([^\"]+)\""
        return matches(in: text, pattern: pattern).first
    }
}
