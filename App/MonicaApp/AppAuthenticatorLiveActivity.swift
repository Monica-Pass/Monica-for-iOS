//
//  AppAuthenticatorLiveActivity.swift
//  Monica
//
//  Issue #47：Android「验证器常驻通知」的 iOS 诚实替代 —— 由用户手动开始/结束的
//  Live Activity 试点。App 侧的全部新代码都放在这个文件里，避免与同时进行的
//  AppRootView / SettingsRootView 拆分互相踩行；`AppSessionModel` 不需要任何改动。
//
//  与 Android 前台服务不等价的地方（也是本试点的边界）：
//  - 没有常驻进程、没有后台 timer、没有轮询：只有用户点「在锁屏显示倒计时」时
//    才会创建 Activity，点「结束」会立刻 `end(dismissalPolicy: .immediate)`；
//  - 锁屏/灵动岛只显示「条目别名 + 系统渲染的倒计时」，不含 OTP 密钥，
//    也不含当前验证码正文——少一份密钥副本就少一条泄露路径；
//  - 生命周期由 ActivityKit 管理：系统可以提前回收，单次活动最长约 8 小时；
//    本试点额外设 30 分钟的 `staleDate`，到点后 App 内提示重新开始。
//
//  这里没有、也不应该有任何「刷新验证码」的定时器：倒计时由
//  `Text(timerInterval:)` / `ProgressView(timerInterval:)` 交给系统逐秒渲染。
//

import ActivityKit
import MonicaStorage
import MonicaWidgetShared
import SwiftUI

/// 管理本机唯一一条「验证器倒计时」Live Activity。
///
/// 真实的状态迁移都收敛在共享包的 `MonicaAuthenticatorActivitySession` 里，
/// 这个类只负责和 ActivityKit 打交道（request / update / end / 观察系统结束）。
@MainActor
@Observable
final class AuthenticatorLiveActivityController {
    /// 供界面展示的状态机（idle / starting / running / failed）。
    private(set) var session = MonicaAuthenticatorActivitySession()
    /// `ActivityAuthorizationInfo().areActivitiesEnabled` 的快照。
    private(set) var availability: MonicaAuthenticatorActivityAvailability = .available

    private var activity: Activity<MonicaAuthenticatorActivityAttributes>?
    private var stateObservation: Task<Void, Never>?

    /// 项目最低部署版本是 iOS 18，ActivityKit 一定存在；
    /// 「设备不支持」的情形已经包含在 `areActivitiesEnabled == false` 里。
    private static let isDeviceSupported = true

    /// 重新读取系统开关。用户可能在「设置 → Monica → 实时活动」里随时改掉它。
    func refreshAvailability() {
        availability = .evaluate(
            isDeviceSupported: Self.isDeviceSupported,
            areActivitiesEnabled: ActivityAuthorizationInfo().areActivitiesEnabled
        )
    }

    /// 界面出现时调用：接回上一次进程遗留的活动，并清掉已经过期的残留。
    func load() async {
        refreshAvailability()
        let existing = Activity<MonicaAuthenticatorActivityAttributes>.activities
        guard let first = existing.first else {
            activity = nil
            if session.isRunning { session.markEnded() }
            return
        }
        // 多条并存会让锁屏出现重复倒计时；只保留最早的一条。
        for duplicate in existing.dropFirst() {
            await duplicate.end(nil, dismissalPolicy: .immediate)
        }
        let plan = first.attributes.plan(with: first.content.state)
        if plan.isExpired(at: Date()) {
            await first.end(nil, dismissalPolicy: .immediate)
            activity = nil
            session.markFailed(.expired)
            return
        }
        activity = first
        session.markStarted(plan)
        observe(first)
    }

    /// 用户点「在锁屏显示倒计时」。
    ///
    /// 不可用、用户拒绝、`request` 抛错都会落到 `.failed(...)`，
    /// 界面据此回到普通列表并显示本地化提示，不会崩溃。
    func start(_ entry: MonicaAuthenticatorActivityEntry) async {
        refreshAvailability()
        guard session.beginStart(availability: availability) else { return }
        // 单实例：先清掉可能残留的旧活动，避免锁屏出现两条倒计时。
        await endAllActivities()

        let plan = MonicaAuthenticatorActivityPlan(entry: entry)
        guard !plan.isExpired(at: Date()) else {
            session.markFailed(.expired)
            return
        }
        do {
            let requested = try Activity<MonicaAuthenticatorActivityAttributes>.request(
                attributes: MonicaAuthenticatorActivityAttributes(plan: plan),
                content: ActivityContent(
                    state: MonicaAuthenticatorActivityAttributes.ContentState(plan: plan),
                    staleDate: plan.staleDate
                ),
                pushType: nil
            )
            activity = requested
            session.markStarted(plan)
            observe(requested)
        } catch {
            activity = nil
            session.markFailed(.requestFailed)
        }
    }

    /// 用户点「结束」：立即消失，不残留旧倒计时。
    func stop() async {
        await endAllActivities()
        session.markEnded()
    }

    /// App 回到前台时对齐窗口：跨周期就 update，试点到期就立刻结束。
    ///
    /// 这里从 `Activity.activities` 重新取一次活动，而不是直接复用上面存下来的引用：
    /// `Activity` 本身不是 `Sendable`，把存下来的实例跨隔离域传给 `update(_:)`
    /// 会让 Swift 6 判成「发送非 Sendable 值」。重新取到的是本函数内的新值，
    /// 语义上也更准确——系统可能已经回收了旧实例。
    func reconcile() async {
        refreshAvailability()
        guard session.isRunning else { return }
        guard let current = Activity<MonicaAuthenticatorActivityAttributes>.activities.first else {
            activity = nil
            session.markEnded()
            return
        }
        let advanced = session.refresh(at: Date())
        if let advanced {
            await current.update(
                ActivityContent(
                    state: MonicaAuthenticatorActivityAttributes.ContentState(plan: advanced),
                    staleDate: advanced.staleDate
                )
            )
        } else if session.failure == .expired {
            await endAllActivities()
        }
    }

    /// 结束所有本类活动（含其它进程/上一次启动遗留的），并停止观察。
    private func endAllActivities() async {
        stateObservation?.cancel()
        stateObservation = nil
        for existing in Activity<MonicaAuthenticatorActivityAttributes>.activities {
            await existing.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
    }

    /// 系统可以随时回收活动（用户上滑关掉、锁屏守护超时等）。
    /// 观察到 `.ended`/`.dismissed` 时把界面恢复成「未开始」。
    private func observe(_ activity: Activity<MonicaAuthenticatorActivityAttributes>) {
        stateObservation?.cancel()
        stateObservation = Task { @MainActor [weak self] in
            for await state in activity.activityStateUpdates {
                guard let self else { return }
                switch state {
                case .ended, .dismissed:
                    self.activity = nil
                    self.session.markEnded()
                    self.stateObservation = nil
                    return
                default:
                    continue
                }
            }
        }
    }
}

/// 验证器列表顶部的试点入口卡片。
///
/// 只做两件事：开始一条 Live Activity、结束它。失败信息就地展示，
/// 验证码列表本身不受影响。
struct AuthenticatorLiveActivityCard: View {
    let entries: [LocalTotpEntry]
    /// 由父视图每秒刷新的时钟，仅用于本地预览倒计时，不用于刷新验证码。
    let now: Date

    @State private var controller = AuthenticatorLiveActivityController()
    @State private var selectedEntryID: String?
    @Environment(\.scenePhase) private var scenePhase

    private var candidates: [MonicaAuthenticatorActivityEntry] {
        entries.map { entry in
            MonicaAuthenticatorActivityEntry(
                id: entry.id,
                title: entry.title,
                issuer: entry.issuer,
                accountName: entry.accountName,
                period: Int(entry.period)
            )
        }
    }

    private var selectedEntry: MonicaAuthenticatorActivityEntry? {
        if let selectedEntryID, let match = candidates.first(where: { $0.id == selectedEntryID }) {
            return match
        }
        return candidates.first
    }

    var body: some View {
        AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.52), cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let plan = controller.session.plan {
                    runningContent(plan)
                } else {
                    idleContent
                }
                if let failure = controller.session.failure {
                    fallbackNotice(failure)
                } else if !controller.availability.canStart {
                    fallbackNotice(.disabled)
                }
                Text("锁屏倒计时由系统调度：本试点开始后约 30 分钟自动结束，单次 Live Activity 最长约 8 小时；App 退到后台后不会持续刷新验证码。")
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await controller.load() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await controller.reconcile() }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            AndroidParityIconTile(systemImage: "lock.display", fill: AndroidParityPalette.primaryContainer)
            VStack(alignment: .leading, spacing: 2) {
                Text("锁屏倒计时（试点）")
                    .font(.subheadline.weight(.semibold))
                Text("只显示条目别名和倒计时，不显示验证码正文。")
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
            Spacer(minLength: 8)
            Text(controller.session.isRunning ? "进行中" : "未开始")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(
                        controller.session.isRunning
                            ? AndroidParityPalette.primary.opacity(0.18)
                            : AndroidParityPalette.outline
                    )
                )
                .foregroundStyle(
                    controller.session.isRunning
                        ? AndroidParityPalette.primary
                        : AndroidParityPalette.textSecondary
                )
        }
    }

    @ViewBuilder
    private var idleContent: some View {
        if candidates.isEmpty {
            Text("暂无可显示的验证码条目。")
                .font(.caption)
                .foregroundStyle(AndroidParityPalette.textSecondary)
        } else {
            if candidates.count > 1, let selectedEntry {
                Menu {
                    ForEach(candidates, id: \.id) { candidate in
                        Button {
                            selectedEntryID = candidate.id
                        } label: {
                            if candidate.id == selectedEntry.id {
                                Label(candidate.alias, systemImage: "checkmark")
                            } else {
                                Text(candidate.alias)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("选择显示的条目")
                            .font(.caption)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                        Spacer(minLength: 8)
                        Text(selectedEntry.alias)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(AndroidParityPalette.outline.opacity(0.5))
                    )
                }
                .disabled(!controller.availability.canStart)
            }
            Button {
                start()
            } label: {
                Label("在锁屏显示倒计时", systemImage: "lock.display")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .filled))
            .disabled(!controller.availability.canStart || selectedEntry == nil)
        }
    }

    private func runningContent(_ plan: MonicaAuthenticatorActivityPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("正在锁屏显示：\(plan.alias)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("验证码倒计时")
                        .font(.caption)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
                Spacer(minLength: 8)
                countdown(plan)
            }
            Button {
                Task { await controller.stop() }
            } label: {
                Label("结束锁屏倒计时", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .destructiveOutlined))
        }
    }

    /// 与锁屏完全相同的系统倒计时渲染，只是把窗口推进到「当前」。
    private func countdown(_ plan: MonicaAuthenticatorActivityPlan) -> some View {
        let livePlan = plan.advanced(to: now)
        return Text(timerInterval: livePlan.windowStart...livePlan.windowEnd, countsDown: true)
            .font(AndroidParityTypography.prominentTitle(weight: .heavy))
            .foregroundStyle(AndroidParityPalette.primary)
            .monospacedDigit()
            .frame(maxWidth: 96, alignment: .trailing)
    }

    private func fallbackNotice(_ failure: MonicaAuthenticatorActivityFailure) -> some View {
        Label(message(for: failure), systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(failure == .expired ? AndroidParityPalette.textSecondary : Color.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func message(for failure: MonicaAuthenticatorActivityFailure) -> String {
        switch failure {
        case .unsupportedDevice, .disabled:
            return String(localized: "实时活动当前不可用（设备不支持或已在系统设置中关闭）。你仍可以在这里查看验证码。")
        case .requestFailed:
            return String(localized: "无法开始锁屏倒计时，请稍后重试。你仍可以在这里查看验证码。")
        case .expired:
            return String(localized: "本次锁屏倒计时已结束，需要时请重新开始。")
        }
    }

    private func start() {
        guard let entry = selectedEntry else { return }
        Task { await controller.start(entry) }
    }
}
