@testable import Monica
import XCTest

final class AppLiquidGlassSupportTests: XCTestCase {
    private func repositoryAppDirectoryURL() throws -> URL {
        #if os(iOS) && !targetEnvironment(simulator)
        throw XCTSkip("Repository files are not available inside the real-device test sandbox.")
        #else
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/MonicaApp", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw XCTSkip("Repository directory is not available in this test environment: \(url.path)")
        }
        return url
        #endif
    }

    private func swiftFileContents(in directory: URL) throws -> [String: String] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw XCTSkip("Repository directory could not be enumerated: \(directory.path)")
        }
        var files: [String: String] = [:]
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let relativePath = fileURL.path.replacingOccurrences(of: directory.path + "/", with: "")
            files[relativePath] = try String(contentsOf: fileURL, encoding: .utf8)
        }
        return files
    }

    func testFloatingSurfaceUsesGlassOnlyOnIOS26WithoutReduceTransparency() {
        func style(_ available: Bool, _ reduceTransparency: Bool, _ increaseContrast: Bool) -> AppLiquidGlass.FloatingSurfaceStyle {
            AppLiquidGlass.floatingSurface(
                isAvailable: available,
                reduceTransparency: reduceTransparency,
                increaseContrast: increaseContrast
            )
        }

        XCTAssertEqual(
            style(true, false, false),
            AppLiquidGlass.FloatingSurfaceStyle(material: .liquidGlass, opaqueOutlineWidth: 0)
        )
        // 增强对比度时玻璃材质自身已加深，不额外描边。
        XCTAssertEqual(
            style(true, false, true),
            AppLiquidGlass.FloatingSurfaceStyle(material: .liquidGlass, opaqueOutlineWidth: 0)
        )
        // 降低透明度必须退化到不透明表面，否则浮动控件会失去与内容的对比。
        XCTAssertEqual(
            style(true, true, false),
            AppLiquidGlass.FloatingSurfaceStyle(material: .opaqueSurface, opaqueOutlineWidth: 0)
        )
        XCTAssertEqual(
            style(true, true, true),
            AppLiquidGlass.FloatingSurfaceStyle(material: .opaqueSurface, opaqueOutlineWidth: 1.5)
        )
        // iOS 17–25 没有玻璃材质，保持原有不透明表面。
        XCTAssertEqual(
            style(false, false, false),
            AppLiquidGlass.FloatingSurfaceStyle(material: .opaqueSurface, opaqueOutlineWidth: 0)
        )
        XCTAssertEqual(
            style(false, false, true),
            AppLiquidGlass.FloatingSurfaceStyle(material: .opaqueSurface, opaqueOutlineWidth: 1.5)
        )
    }

    func testGlassSurfaceNeverAppearsWhenTransparencyIsReduced() {
        for available in [true, false] {
            for increaseContrast in [true, false] {
                XCTAssertFalse(
                    AppLiquidGlass.floatingSurface(
                        isAvailable: available,
                        reduceTransparency: true,
                        increaseContrast: increaseContrast
                    ).usesGlass
                )
            }
        }
    }

    /// issue #78 的架构约束：iOS 26 液态玻璃 API 只允许出现在适配层，
    /// 业务视图统一调用修饰符，避免 `#available` 散落各处。
    func testLiquidGlassAPIsStayInsideAdapterFile() throws {
        let adapterFileName = "AppLiquidGlassSupport.swift"
        // 适配层对外提供的全部 iOS 26 液态玻璃 / 边缘效果 API。
        let glassTokens = [
            "glassEffect",
            "tabBarMinimizeBehavior",
            "tabViewBottomAccessory",
            "searchToolbarBehavior",
            "scrollEdgeEffectStyle",
            "GlassEffectContainer"
        ]
        // 适配层当前实际使用的 API（其余保留在扫描名单里，防止日后又被散落引用）。
        let adoptedTokens = ["glassEffect", "tabBarMinimizeBehavior", "scrollEdgeEffectStyle"]
        let files = try swiftFileContents(in: try repositoryAppDirectoryURL())

        var offenders: [String] = []
        for (fileName, contents) in files where !fileName.hasSuffix(adapterFileName) {
            for token in glassTokens where contents.contains(token) {
                offenders.append("\(fileName) 使用了 \(token)")
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "iOS 26 液态玻璃 API 只允许出现在 \(adapterFileName)：\(offenders.sorted().joined(separator: "；"))"
        )

        let adapter = try XCTUnwrap(
            files.first { $0.key.hasSuffix(adapterFileName) }?.value,
            "缺少适配层文件 \(adapterFileName)"
        )
        for token in adoptedTokens {
            XCTAssertTrue(adapter.contains(token), "适配层应集中声明 \(token)")
        }
        XCTAssertTrue(adapter.contains("#available(iOS 26.0, *)"), "iOS 26 分支必须做可用性判断")
    }
}
