import MonicaCore
import SwiftUI

/// 设置页「关于」区块：展示版本号，并通过 App Store Lookup 检查是否有新版本。
///
/// iOS 上应用不能自行下载或安装更新，所以这里只做三件事：显示当前版本、查询商店版本、把用户送到商店页。
/// 任何查询失败都必须如实显示「无法检查」，不允许伪装成「已是最新」。
struct AppUpdateCheckSectionView: View {
    @Environment(\.openURL) private var openURL

    @State private var availability: AppUpdateAvailability?
    @State private var isChecking = false

    /// 没有真实 App Store ID 时不展示「检查更新」：查询一个不存在的应用只会得到误导性的结果。
    private var isStoreConfigured: Bool {
        Self.makeChecker().appStoreID != nil
    }

    var body: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.6)) {
            VStack(alignment: .leading, spacing: 12) {
                AndroidParityInfoRow(
                    title: String(localized: "当前版本"),
                    value: Self.displayVersion
                )

                AndroidParityDivider()

                statusView

                if case .updateAvailable(_, _, let storeURL) = availability {
                    Button {
                        openURL(storeURL)
                    } label: {
                        Label("打开 App Store", systemImage: "arrow.up.forward.app")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                }

                if isStoreConfigured {
                    Button {
                        Task { await checkForUpdate() }
                    } label: {
                        Label(
                            isChecking ? String(localized: "正在检查…") : String(localized: "检查更新"),
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                    .disabled(isChecking)
                }

                Text("iOS 不允许应用自行下载或安装更新。检查到新版本后会打开 App Store，由你确认更新。")
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        if isChecking {
            statusRow(
                systemImage: "clock.arrow.circlepath",
                tint: AndroidParityPalette.textSecondary,
                text: String(localized: "正在向 App Store 查询最新版本…")
            )
        } else if let availability {
            switch availability {
            case .notConfigured:
                statusRow(
                    systemImage: "questionmark.circle",
                    tint: AndroidParityPalette.textSecondary,
                    text: String(localized: "当前构建未配置 App Store ID（开发版或尚未上架），无法检查更新。")
                )
            case .notFoundInStore:
                statusRow(
                    systemImage: "magnifyingglass",
                    tint: AndroidParityPalette.textSecondary,
                    text: String(localized: "App Store 中暂时查不到这个应用。")
                )
            case .upToDate(_, let latestVersion):
                statusRow(
                    systemImage: "checkmark.seal",
                    tint: AndroidParityPalette.primary,
                    text: String(localized: "已是最新版本（商店版本 \(latestVersion)）。")
                )
            case .updateAvailable(_, let latestVersion, _):
                statusRow(
                    systemImage: "arrow.down.circle",
                    tint: AndroidParityPalette.primary,
                    text: String(localized: "发现新版本 \(latestVersion)。")
                )
            case .untrustedStoreURL(_, let latestVersion):
                statusRow(
                    systemImage: "exclamationmark.triangle",
                    tint: AndroidParityPalette.textSecondary,
                    text: String(localized: "商店返回了 \(latestVersion)，但下载链接不是受信任的 Apple 域名，已阻止打开。")
                )
            case .failed(_, let error):
                statusRow(
                    systemImage: "exclamationmark.triangle",
                    tint: AndroidParityPalette.textSecondary,
                    text: Self.failureText(for: error)
                )
            }
        } else if isStoreConfigured {
            statusRow(
                systemImage: "info.circle",
                tint: AndroidParityPalette.textSecondary,
                text: String(localized: "点击「检查更新」向 App Store 查询是否有新版本。")
            )
        } else {
            statusRow(
                systemImage: "questionmark.circle",
                tint: AndroidParityPalette.textSecondary,
                text: String(localized: "当前构建未配置 App Store ID（开发版或尚未上架），无法检查更新。")
            )
        }
    }

    private func statusRow(systemImage: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func checkForUpdate() async {
        guard !isChecking else { return }
        isChecking = true
        availability = nil
        let checker = Self.makeChecker()
        availability = await checker.checkForUpdate(currentVersion: Self.versionString)
        isChecking = false
    }

    // MARK: - Bundle facts

    /// 只读 `Bundle.main` 的版本键；缺失时返回占位文案，绝不编造版本号。
    static func makeChecker(bundle: Bundle = .main) -> AppStoreUpdateChecker {
        let appStoreID = bundle.object(forInfoDictionaryKey: AppStoreUpdateChecker.bundledAppStoreIDInfoKey) as? String
        return AppStoreUpdateChecker(appStoreID: appStoreID, countryCode: Locale.current.region?.identifier)
    }

    static var versionString: String {
        version(in: .main)
    }

    static var displayVersion: String {
        let short = versionString
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let build, !build.isEmpty, build != short {
            return "\(short) (\(build))"
        }
        return short
    }

    private static func version(in bundle: Bundle) -> String {
        guard let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !version.isEmpty
        else {
            return String(localized: "未知版本")
        }
        return version
    }

    static func failureText(for error: AppStoreUpdateError) -> String {
        switch error {
        case .transport:
            return String(localized: "无法连接 App Store，请稍后重试。")
        case .httpStatus(let status):
            return String(localized: "App Store 返回异常状态码 \(status)，请稍后重试。")
        case .malformedResponse:
            return String(localized: "App Store 返回的数据无法解析，请稍后重试。")
        case .currentVersionUnparsable(let version):
            return String(localized: "当前版本号「\(version)」不是标准格式，无法比较。")
        }
    }
}

#Preview {
    ScrollView {
        AppUpdateCheckSectionView()
            .padding()
    }
    .background(AndroidParityPalette.background)
}
