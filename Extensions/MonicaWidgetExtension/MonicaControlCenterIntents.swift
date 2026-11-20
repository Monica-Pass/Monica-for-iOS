import AppIntents
import Foundation

/// 控制中心快捷入口可打开的 Monica 顶层页面。
///
/// `rawValue` 同时用于控制配置和 `monica://open/<page>` 深链，属于稳定协议，不能跟着界面文案改。
enum MonicaControlPage: String, AppEnum, CaseIterable, Sendable {
    case passwords
    case totp
    case wallet
    case settings

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Monica 页面")

    static let caseDisplayRepresentations: [MonicaControlPage: DisplayRepresentation] = [
        .passwords: DisplayRepresentation(title: "密码", image: DisplayRepresentation.Image(systemName: "key.fill")),
        .totp: DisplayRepresentation(title: "验证", image: DisplayRepresentation.Image(systemName: "timer")),
        .wallet: DisplayRepresentation(title: "卡包", image: DisplayRepresentation.Image(systemName: "creditcard")),
        .settings: DisplayRepresentation(title: "设置", image: DisplayRepresentation.Image(systemName: "gearshape"))
    ]

    var title: String {
        switch self {
        case .passwords:
            return "密码"
        case .totp:
            return "验证"
        case .wallet:
            return "卡包"
        case .settings:
            return "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .passwords:
            return "key.fill"
        case .totp:
            return "timer"
        case .wallet:
            return "creditcard"
        case .settings:
            return "gearshape"
        }
    }

    /// 只表达“打开哪个页面”，不携带条目 ID、标题或任何密钥。
    var deepLinkURL: URL {
        URL(string: "monica://open/\(rawValue)")!
    }
}

/// 控制中心动作与主 App 之间的最小交接面。
///
/// App Intents 在 App 进程内执行，但控制按钮也可能在 App 未启动或锁定时被点击，因此只把目标页面
/// 写进 App Group；主 App 在启动、回到前台或解锁后消费。这里永远只保存固定深链。
enum MonicaControlNavigationStore {
    static let appGroupIdentifier = "group.com.monicapass.monica"
    static let storageKey = "control-pending-navigation-v1"
    static let didUpdateNotification = Notification.Name("monica.control.pending-navigation.did-update")

    static func save(
        _ page: MonicaControlPage,
        to defaults: UserDefaults? = UserDefaults(suiteName: appGroupIdentifier)
    ) {
        guard let defaults else {
            return
        }
        defaults.set(page.deepLinkURL.absoluteString, forKey: storageKey)
        Task { @MainActor in
            NotificationCenter.default.post(name: didUpdateNotification, object: nil)
        }
    }

    static func consume(
        from defaults: UserDefaults? = UserDefaults(suiteName: appGroupIdentifier)
    ) -> URL? {
        guard let defaults,
              let rawURL = defaults.string(forKey: storageKey) else {
            return nil
        }
        defaults.removeObject(forKey: storageKey)
        return URL(string: rawURL)
    }
}

/// 控制按钮唯一会执行的动作：把配置的页面交给主 App，然后由系统将 App 带到前台。
struct OpenMonicaControlIntent: OpenIntent, Sendable {
    static let title: LocalizedStringResource = "打开 Monica"
    static let description = IntentDescription("打开 Monica 的指定页面。")
    static let openAppWhenRun = true

    @Parameter(title: "页面")
    var target: MonicaControlPage

    init() {
        target = .passwords
    }

    init(page: MonicaControlPage) {
        target = page
    }

    func perform() async throws -> some IntentResult {
        MonicaControlNavigationStore.save(target)
        return .result()
    }
}

/// 长按控制按钮时由系统展示的配置项：选择固定页面。
struct MonicaControlConfigurationIntent: ControlConfigurationIntent, Sendable {
    static let title: LocalizedStringResource = "选择 Monica 页面"
    static let description = IntentDescription("选择控制按钮要打开的页面。")

    @Parameter(title: "页面", default: MonicaControlPage.passwords)
    var page: MonicaControlPage

    init() {}
}
