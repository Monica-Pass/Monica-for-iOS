import MonicaCore
import SwiftUI
import UIKit

/// 备用 App 图标的系统调用封装。
///
/// 走 Apple 文档要求的 asset catalog 路线：图标是 `Assets.xcassets` 里的
/// `AppIcon*.appiconset`，工程通过 `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`
/// 把它们编译进 `CFBundleAlternateIcons`，运行时用
/// `UIApplication.setAlternateIconName(_:)` 切换；`nil` 恢复默认图标。
///
/// 不支持的平台（部分模拟器 / 受管理设备）与失败都会抛错，由设置页如实展示，
/// 不会先把「已切换」写进偏好再假装成功。
/// 备用图标切换失败原因。`LocalizedError` 的要求是 nonisolated，因此这里不加
/// `@MainActor`：错误值本身是 Sendable，可跨隔离域传递。
enum AlternateAppIconError: LocalizedError, Equatable, Sendable {
    case unsupported
    case notAvailable(String)

    var errorDescription: String? {
        switch self {
        case .unsupported:
            String(localized: "当前设备或模拟器不支持备用 App 图标。请以真机安装后的系统行为为准。")
        case .notAvailable(let name):
            String(localized: "系统没有找到图标 \(name)。请确认图标集已随 App 一起打包。")
        }
    }
}

@MainActor
final class AppAlternateIconController {
    static let shared = AppAlternateIconController()

    private let application: UIApplication

    init(application: UIApplication = .shared) {
        self.application = application
    }

    /// 系统实际生效的图标。系统返回未知名称时按默认图标处理。
    var current: AlternateAppIcon {
        AlternateAppIcon.current(alternateIconName: application.alternateIconName)
    }

    var isSupported: Bool {
        application.supportsAlternateIcons
    }

    func apply(_ icon: AlternateAppIcon) async throws {
        guard isSupported else {
            throw AlternateAppIconError.unsupported
        }
        let requestedName = icon.alternateIconName
        guard application.alternateIconName != requestedName else { return }
        do {
            try await application.setAlternateIconName(requestedName)
        } catch {
            let name = requestedName ?? AlternateAppIcon.standard.rawValue
            throw AlternateAppIconError.notAvailable(name)
        }
        // 系统可能静默忽略（例如图标集缺失）；以系统状态为准再确认一次。
        guard current == icon else {
            throw AlternateAppIconError.notAvailable(requestedName ?? AlternateAppIcon.standard.rawValue)
        }
    }
}
