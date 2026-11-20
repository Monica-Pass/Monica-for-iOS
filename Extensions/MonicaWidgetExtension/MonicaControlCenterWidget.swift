import SwiftUI
import WidgetKit

/// 只读取配置页面，不读取保险库、条目或任何密钥。
struct MonicaControlValueProvider: AppIntentControlValueProvider {
    func previewValue(configuration: MonicaControlConfigurationIntent) -> MonicaControlPage {
        configuration.page
    }

    func currentValue(configuration: MonicaControlConfigurationIntent) async throws -> MonicaControlPage {
        configuration.page
    }
}

/// 控制中心的 Monica 按钮：点按后由 `OpenIntent` 打开 App，再在 App 内落到配置页面。
struct MonicaOpenPageControl: ControlWidget {
    static let kind = "com.monicapass.monica.control.open-page"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: Self.kind,
            provider: MonicaControlValueProvider()
        ) { page in
            ControlWidgetButton(action: OpenMonicaControlIntent(page: page)) {
                Label(page.title, systemImage: page.systemImage)
            }
        }
        .displayName("Monica")
        .description("一键打开密码、验证、卡包或设置页面。")
        .promptsForUserConfiguration()
    }
}
