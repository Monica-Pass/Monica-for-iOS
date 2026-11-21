import MonicaCore
import SwiftUI
import UIKit

/// 「设为默认密码管理器」引导页，也可作为「系统自动填充说明」复用。
///
/// iOS 的诚实版本：系统只允许用户在「设置」里选择自动填充来源，App 无法读取或设置
/// 「系统默认密码管理器」是谁，也无法监听其它 App 里的密码输入框。本页只提供公开的设置入口、
/// 可复制的引导文字、能力矩阵和测试步骤，不会声称已经接管系统自动填充。
struct AppAutoFillDefaultManagerGuideView: View {
    @Environment(\.openURL) private var openURL
    @State private var didCopyGuide = false
    private let title: String

    init(title: String = String(localized: "设为自动填充来源")) {
        self.title = title
    }

    var body: some View {
        AndroidParityScreen {
            stepsSection
            testSection
            quickTypeSection
            AppAutoFillCapabilityMatrixSection()
            limitationsSection
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 设置路径

    private var stepsSection: some View {
        AndroidParitySection(title: String(localized: "系统设置路径")) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                Text(passwordSettingsPathText)
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("不同 iOS 版本的入口名称可能略有差异：iOS 17 在「设置 › 密码 › 密码选项」，iOS 18 起密码独立成 App，也可能出现在「设置 › App › 密码」。Monica 不会构造私有设置链接，只能打开本 App 自己的设置页。")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                AndroidParityDivider()

                ForEach(Array(guideSteps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text(String(index + 1))
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(AndroidParityPalette.onPrimary)
                            .frame(width: 22, height: 22)
                            .background(
                                Circle().fill(AndroidParityPalette.primary)
                            )
                        Text(step)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AndroidParityPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                AndroidParityDivider()

                Button {
                    if let settingsURL = appSettingsURL {
                        openURL(settingsURL)
                    }
                } label: {
                    Label("打开 Monica 的系统设置", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                .disabled(appSettingsURL == nil)

                Button {
                    copyGuideText()
                } label: {
                    if didCopyGuide {
                        Label("已复制引导文字", systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("复制引导文字", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))

                Text("复制内容是上方的设置步骤，不包含任何账号、密码或密钥。")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 测试步骤

    private var testSection: some View {
        AndroidParitySection(title: String(localized: "测试自动填充")) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                ForEach(Array(testSteps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text(String(index + 1))
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(AndroidParityPalette.onPrimary)
                            .frame(width: 22, height: 22)
                            .background(
                                Circle().fill(AndroidParityPalette.primary)
                            )
                        Text(step)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AndroidParityPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text("如果 Safari 里没有出现 Monica 的建议：先确认扩展已启用，再到自动填充诊断里看「系统侧身份条目」是否为 0，点「重新发布身份」后重试。")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - QuickType

    private var quickTypeSection: some View {
        AndroidParitySection(title: String(localized: "快速输入说明")) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                Text("键盘上方的快速输入条（QuickType）由系统决定是否展示、展示哪一条建议。App 和扩展都不能控制它的出现时机，也不能强制弹出密码建议。")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Monica 能做的是把身份条目发布给系统；剩余部分由 iOS 的自动填充逻辑处理。")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - iOS 限制

    private var limitationsSection: some View {
        AndroidParitySection(title: String(localized: "iOS 的限制")) {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.55)) {
                ForEach(limitations, id: \.self) { limitation in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AndroidParityPalette.primary)
                            .padding(.top, 2)
                        Text(limitation)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - 文案

    private var appSettingsURL: URL? {
        URL(string: UIApplication.openSettingsURLString)
    }

    private var passwordSettingsPathText: String {
        if #available(iOS 18.0, *) {
            return String(localized: "设置 › 密码 › 密码选项 › 自动填充密码")
        }
        return String(localized: "设置 › 密码 › 密码选项 › 自动填充密码（iOS 17）")
    }

    private var guideSteps: [String] {
        [
            String(localized: "打开系统「设置」，找到密码相关入口（iOS 18 起也可能在「设置 › App › 密码」）。"),
            String(localized: "进入「密码选项 › 自动填充密码」，在来源列表里把 Monica 打开。"),
            String(localized: "回到 Monica 解锁保险库，条目载入后身份会自动发布；也可以在自动填充诊断里点「重新发布身份」。"),
            String(localized: "再次回到系统设置，确认 Monica 仍在自动填充来源列表里处于启用状态。"),
        ]
    }

    private var testSteps: [String] {
        [
            String(localized: "在 Safari 打开一个需要登录的网站（或任意有账号密码输入框的页面）。"),
            String(localized: "点账号输入框，键盘上方应出现 Monica 提供的账号建议。"),
            String(localized: "选择建议后，Monica 自动填充扩展会要求先解锁保险库，然后填入该条目。"),
            String(localized: "若要保存新密码，同样由系统弹出来源选择，Monica 只能在被选中后处理保存请求。"),
        ]
    }

    private var limitations: [String] {
        [
            String(localized: "iOS 不提供无障碍服务：Monica 读不到其它 App 的界面，也无法监听密码输入框。"),
            String(localized: "iOS 不允许 App 读取或设置「系统默认密码管理器」是谁，只能由你在系统设置里选择。"),
            String(localized: "Monica 无法自动打开系统的「密码选项」页面，只能打开本 App 的设置页。"),
            String(localized: "项目里声明了自动填充扩展，不代表你已经在系统里启用它；是否启用只能由系统记录，App 只能读取状态。"),
            String(localized: "不支持开机自启、后台常驻守护或强制打开无障碍等 Android 侧做法。"),
        ]
    }

    private var guideText: String {
        var lines = [String(localized: "把 Monica 设为 iOS 自动填充来源："), passwordSettingsPathText]
        for (index, step) in guideSteps.enumerated() {
            lines.append(String(index + 1) + ". " + step)
        }
        lines.append(String(localized: "iOS 不允许 App 读取或设置系统默认密码管理器是谁；是否启用只能由你在系统设置里决定。"))
        return lines.joined(separator: "\n")
    }

    /// 写入剪贴板的只有上面的设置步骤，不包含任何凭据内容。
    private func copyGuideText() {
        UIPasteboard.general.string = guideText
        didCopyGuide = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopyGuide = false
        }
    }
}
