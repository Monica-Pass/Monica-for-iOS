import MonicaCore
import Observation
import SwiftUI
import UIKit

// MARK: - 场景阶段映射

extension ScreenPrivacyPhase {
    /// 把 SwiftUI 的场景阶段映射到可测试的隐私决策输入。
    /// 未知阶段按 `.inactive` 处理：宁可多遮一层，也不要把 Vault 内容暴露在快照里。
    init(_ phase: ScenePhase) {
        switch phase {
        case .active:
            self = .active
        case .inactive:
            self = .inactive
        case .background:
            self = .background
        @unknown default:
            self = .inactive
        }
    }
}

// MARK: - 录制/共享状态

/// 维护「当前场景是否正在被录屏或共享」以及 App 切到后台时的遮罩状态。
///
/// 纯决策（什么时候遮罩、录制结束后如何回落到用户设置）在
/// `MonicaCore.ScreenPrivacyPolicy` / `SensitiveFieldMaskingPolicy` 里，这里只负责
/// 接收 SwiftUI/UIKit 的事件并通知界面。
@MainActor
@Observable
final class ScreenPrivacyMonitor {
    /// 当前场景是否正在被录制、镜像或共享。
    private(set) var isSceneCaptured = false
    /// 是否需要显示不包含任何 Vault 数据的中性遮罩（App Switcher / 后台）。
    private(set) var showsShield = false
    /// 截屏提示的标识；非 nil 时显示提示，几秒后自动清除。
    private(set) var screenshotNoticeID: UUID?

    private var screenshotNoticeDismissTask: Task<Void, Never>?

    func updateSceneCaptured(_ captured: Bool) {
        guard isSceneCaptured != captured else { return }
        isSceneCaptured = captured
    }

    func updateShieldVisibility(_ visible: Bool) {
        guard showsShield != visible else { return }
        showsShield = visible
    }

    /// iOS 只能在截屏发生之后通知；这里给一次性中性提示，不假装事前拦截。
    func noteScreenshotTaken() {
        screenshotNoticeDismissTask?.cancel()
        screenshotNoticeID = UUID()
        screenshotNoticeDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.screenshotNoticeID = nil
        }
    }

    func dismissScreenshotNotice() {
        screenshotNoticeDismissTask?.cancel()
        screenshotNoticeDismissTask = nil
        screenshotNoticeID = nil
    }
}

private struct ScreenPrivacyMonitorKey: EnvironmentKey {
    static let defaultValue: ScreenPrivacyMonitor? = nil
}

extension EnvironmentValues {
    /// 由 `AppScreenPrivacyHost` 注入；缺失时（例如独立预览）按「未录制」处理。
    var screenPrivacyMonitor: ScreenPrivacyMonitor? {
        get { self[ScreenPrivacyMonitorKey.self] }
        set { self[ScreenPrivacyMonitorKey.self] = newValue }
    }
}

// MARK: - 覆盖窗口

/// 独立于 SwiftUI 视图树的遮罩/提示窗口。
///
/// 根视图里的 `ZStack` 遮罩盖不住 `.sheet`（详情页、快速设置等），而 App Switcher
/// 快照会包含这些 sheet；因此遮罩放在一个不参与交互的高层级窗口里。
@MainActor
final class AppPrivacyOverlayWindow {
    static let shared = AppPrivacyOverlayWindow()

    private var window: UIWindow?

    private init() {}

    func install(monitor: ScreenPrivacyMonitor) {
        guard window == nil else { return }
        guard let scene = Self.windowScene() else { return }

        let host = UIHostingController(rootView: AppPrivacyOverlayView(monitor: monitor))
        host.view.backgroundColor = .clear
        // 只负责显示：关闭交互，避免遮住下方 App 的手势与输入。
        host.view.isUserInteractionEnabled = false

        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.windowLevel = .alert + 1
        window.isUserInteractionEnabled = false
        window.backgroundColor = .clear
        window.frame = scene.coordinateSpace.bounds
        window.isHidden = false
        self.window = window
    }

    private static func windowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first(where: { $0.activationState == .foregroundInactive })
            ?? scenes.first
    }
}

private struct AppPrivacyOverlayView: View {
    let monitor: ScreenPrivacyMonitor

    var body: some View {
        ZStack(alignment: .top) {
            if monitor.showsShield {
                PrivacyShieldView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
                    .ignoresSafeArea()
                notices
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var notices: some View {
        VStack(spacing: 8) {
            if monitor.isSceneCaptured {
                AppPrivacyNoticeCard(
                    systemImage: "eye.slash.fill",
                    title: "当前正在被录制或共享",
                    message: "敏感内容已隐藏"
                )
            }
            if monitor.screenshotNoticeID != nil {
                AppPrivacyNoticeCard(
                    systemImage: "camera.viewfinder",
                    title: "已检测到截屏",
                    message: "截图可能包含当前屏幕内容，请注意保护。"
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

private struct AppPrivacyNoticeCard: View {
    let systemImage: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                Text(message)
                    .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
        .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 根视图钩子

/// 只做三件事：注入录制状态、驱动遮罩窗口、把 UIKit 的通知转成状态。
/// 决策本身在 MonicaCore 中，已由单元测试覆盖。
struct AppScreenPrivacyHost: ViewModifier {
    let monitor: ScreenPrivacyMonitor

    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        captureAware(
            content
                .onAppear {
                    monitor.updateShieldVisibility(scenePhase != .active)
                    AppPrivacyOverlayWindow.shared.install(monitor: monitor)
                }
                .onChange(of: scenePhase) { _, phase in
                    monitor.updateShieldVisibility(phase != .active)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIScene.willDeactivateNotification)) { _ in
                    // 系统在 resign active 时同步发出，早于 App Switcher 快照生成。
                    monitor.updateShieldVisibility(true)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { _ in
                    monitor.updateShieldVisibility(false)
                    // 首帧时场景可能尚未就绪，激活后再兜底安装一次。
                    AppPrivacyOverlayWindow.shared.install(monitor: monitor)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
                    // iOS 不提供截屏前的拦截回调，只能在事后给中性提示。
                    monitor.noteScreenshotTaken()
                }
        )
    }

    @ViewBuilder
    private func captureAware<V: View>(_ content: V) -> some View {
        if #available(iOS 17.0, *) {
            content.modifier(AppSceneCaptureWatcher(monitor: monitor))
        } else {
            // iOS 17 之前没有场景捕获状态 API：保留后台遮罩，录制提示不可用。
            content
        }
    }
}

@available(iOS 17.0, *)
private struct AppSceneCaptureWatcher: ViewModifier {
    let monitor: ScreenPrivacyMonitor

    @Environment(\.isSceneCaptured) private var isSceneCaptured

    func body(content: Content) -> some View {
        content.onChange(of: isSceneCaptured, initial: true) { _, captured in
            monitor.updateSceneCaptured(captured)
        }
    }
}
