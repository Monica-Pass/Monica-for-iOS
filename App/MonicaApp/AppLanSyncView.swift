import SwiftUI
import UIKit

/// 设置 →「局域网同步」页面。
///
/// 安全模型：
/// - 只有在本页面点「发起同步 / 加入同步」后才会启动 Bonjour 广播或浏览，
///   离开页面、保险库锁定、App 进入后台都会立即停止；
/// - 广播里只有设备名、协议版本和随机设备标识，没有任何保险库数据；
/// - 配对码 + 双端验证码共同确认身份，之后的数据走 AES-GCM 加密通道；
/// - 同步失败或冲突不会删除、不会覆盖本地已修改的条目。
struct AppLanSyncSettingsView: View {
    let session: AppSessionModel

    @Environment(\.dismiss) private var dismiss

    @State private var coordinator: AppLanSyncCoordinator?
    @State private var setupError: String?
    @State private var selectedPeerID: String?
    @State private var pairingCode = ""
    @State private var isResetConfirmationPresented = false

    var body: some View {
        AndroidParityScreen {
            if let coordinator {
                content(coordinator)
            } else if let setupError {
                AndroidParitySection(title: "无法开始局域网同步") {
                    AndroidParityCard {
                        Text(setupError)
                            .font(.subheadline)
                            .foregroundStyle(AndroidParityPalette.textPrimary)
                        Text("请确认保险库已解锁，然后重新打开本页面。")
                            .font(.footnote)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }
                }
            } else {
                AndroidParitySection(title: "正在准备") {
                    AndroidParityCard {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
        }
        .navigationTitle("局域网同步")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard coordinator == nil else { return }
            do {
                let built = try session.makeLanSyncCoordinator()
                built.prepare()
                coordinator = built
            } catch {
                setupError = error.localizedDescription
            }
        }
        .onDisappear {
            coordinator?.cancel()
        }
        .onChange(of: session.vaultState) { _, newValue in
            if newValue != .unlocked {
                coordinator?.cancel()
            }
        }
    }

    // MARK: Content by stage

    @ViewBuilder
    private func content(_ coordinator: AppLanSyncCoordinator) -> some View {
        switch coordinator.stage {
        case .idle:
            menu(coordinator)
        case .browsing:
            joining(coordinator)
        case .hosting(let code):
            hosting(coordinator, code: code)
        case .connecting(let peerName):
            busy(coordinator, title: "正在连接", detail: "正在与「\(peerName)」建立加密连接…")
        case .verifying:
            verifying(coordinator)
        case .syncing(let peerName):
            busy(coordinator, title: "正在同步", detail: "正在与「\(peerName)」交换并合并数据，请保持两台设备都停留在本页面。")
        case .finished:
            summary(coordinator)
        case .failed(let message):
            failure(coordinator, message: message)
        }
    }

    // MARK: Menu

    @ViewBuilder
    private func menu(_ coordinator: AppLanSyncCoordinator) -> some View {
        AndroidParitySection(title: "在两台 iPhone 之间同步") {
            AndroidParityCard {
                Text("两台设备连接同一个 Wi-Fi（或其中一台开热点，另一台连接）后，一台发起、另一台加入即可。")
                    .font(.subheadline)
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                Button {
                    pairingCode = ""
                    selectedPeerID = nil
                    coordinator.startHosting()
                } label: {
                    Label("发起同步（这台设备显示配对码）", systemImage: "wifi")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                .disabled(session.vaultState != .unlocked)

                Button {
                    pairingCode = ""
                    selectedPeerID = nil
                    coordinator.startBrowsing()
                } label: {
                    Label("加入同步（输入对方的配对码）", systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                .disabled(session.vaultState != .unlocked)
            }
        }

        AndroidParitySection(title: "安全说明") {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.6)) {
                securityBullet("只在点击按钮后才广播，离开页面立即停止，不做后台常驻广播。")
                securityBullet("广播内容只有设备名、协议版本和随机设备标识，不包含保险库数据。")
                securityBullet("配对码用于建立会话密钥；两台设备还会显示同一个 6 位验证码，确认一致后才开始传输。")
                securityBullet("传输内容使用端到端加密，未配对设备或不同保险库无法解密。")
                securityBullet("冲突会列出来等你自己处理，不会自动覆盖或删除本地数据。")
            }
        }

        AndroidParitySection(title: "已配对设备") {
            AndroidParityCard {
                if coordinator.pairedPeers.isEmpty {
                    Text("还没有已配对的设备。完成一次配对后会显示在这里，之后可跳过配对码直接同步。")
                        .font(.footnote)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                } else {
                    ForEach(coordinator.pairedPeers, id: \.deviceID) { peer in
                        AndroidParityInfoRow(
                            title: peer.displayName,
                            value: peer.lastSyncedAt.map(Self.relativeDateString) ?? "尚未同步"
                        )
                        Text(peer.deviceID)
                            .font(.caption2.monospaced())
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }
                }
                Button(role: .destructive) {
                    isResetConfirmationPresented = true
                } label: {
                    Label("重置同步记录", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .destructiveOutlined))
            }
        }

        AndroidParitySection(title: "本机信息") {
            AndroidParityCard {
                AndroidParityInfoRow(title: "设备名称", value: UIDevice.current.name)
                AndroidParityInfoRow(title: "保险库标识", value: String(session.lanSyncVaultID.prefix(8)))
                Text("同步记录保存在本机应用沙盒内，不包含保险库密码。清除同步记录不会删除保险库里的条目。")
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }
        .confirmationDialog(
            "重置所有局域网同步记录？",
            isPresented: $isResetConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("重置同步记录", role: .destructive) {
                coordinator.resetSyncState()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已配对设备、合并基线和重试记录都会被清除；本机条目映射会保留，避免之后重新配对时重复创建条目。保险库中的条目不受影响。")
        }
    }

    private func securityBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.shield")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AndroidParityPalette.primary)
                .padding(.top, 2)
            Text(text)
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Hosting

    @ViewBuilder
    private func hosting(_ coordinator: AppLanSyncCoordinator, code: String) -> some View {
        AndroidParitySection(title: "把配对码告诉另一台设备") {
            AndroidParityCard {
                Text(displayCode(code))
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .foregroundStyle(AndroidParityPalette.primary)
                    .frame(maxWidth: .infinity)
                    .textSelection(.enabled)
                    .accessibilityLabel("配对码 \(code)")
                Text("在另一台设备上点「加入同步」，选择本设备后输入这 6 位数字。配对码 2 分钟内有效，离开本页面立即失效。")
                    .font(.footnote)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }

        AndroidParitySection(title: "接下来") {
            AndroidParityCard {
                Text("连接建立后，两台设备都会显示同一个 6 位验证码。确认两边的数字完全一致，再点「验证码一致」。")
                    .font(.subheadline)
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                Button(role: .destructive) {
                    coordinator.cancel()
                } label: {
                    Label("取消，停止等待", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .destructiveOutlined))
            }
        }
    }

    // MARK: Joining

    @ViewBuilder
    private func joining(_ coordinator: AppLanSyncCoordinator) -> some View {
        AndroidParitySection(title: "选择对方设备") {
            AndroidParityCard {
                if coordinator.peers.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在搜索附近已发起同步的 Monica 设备…")
                            .font(.footnote)
                            .foregroundStyle(AndroidParityPalette.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("如果一直搜不到：请确认两台设备在同一个 Wi-Fi / 热点下，且路由器没有开启「AP 隔离」；然后在系统设置 → 隐私与安全性 → 本地网络中允许 Monica 访问。")
                        .font(.caption)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                } else {
                    ForEach(coordinator.peers) { peer in
                        Button {
                            selectedPeerID = peer.id
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selectedPeerID == peer.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(AndroidParityPalette.primary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(peer.displayName)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(AndroidParityPalette.textPrimary)
                                    Text("附近设备")
                                        .font(.caption)
                                        .foregroundStyle(AndroidParityPalette.textSecondary)
                                }
                                Spacer(minLength: 8)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if peer.id != coordinator.peers.last?.id {
                            AndroidParityDivider()
                        }
                    }
                }
                Button {
                    coordinator.startBrowsing()
                } label: {
                    Label("重新搜索", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
            }
        }

        if let selectedPeer {
            AndroidParitySection(title: "输入配对码") {
                AndroidParityCard {
                    Text("在「\(selectedPeer.displayName)」上查看它显示的 6 位配对码。")
                        .font(.footnote)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                    TextField("6 位配对码", text: $pairingCode)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .textFieldStyle(AndroidParityTextFieldStyle())
                    Button {
                        coordinator.join(peer: selectedPeer, code: pairingCode)
                    } label: {
                        Label("连接并验证", systemImage: "lock.open")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                    .disabled(!LanSyncCodeInput.isValid(pairingCode))
                }
            }
        }

        AndroidParitySection(title: "") {
            Button(role: .destructive) {
                coordinator.cancel()
            } label: {
                Label("取消", systemImage: "xmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .destructiveOutlined))
        }
    }

    private var selectedPeer: AppLanSyncPeer? {
        guard let coordinator, let selectedPeerID else { return nil }
        return coordinator.peers.first { $0.id == selectedPeerID }
    }

    // MARK: Verification

    @ViewBuilder
    private func verifying(_ coordinator: AppLanSyncCoordinator) -> some View {
        AndroidParitySection(title: "核对验证码") {
            AndroidParityCard {
                if let prompt = coordinator.verificationPrompt {
                    Text(prompt.codeDisplay)
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                        .foregroundStyle(AndroidParityPalette.primary)
                        .frame(maxWidth: .infinity)
                        .textSelection(.enabled)
                    AndroidParityInfoRow(title: "对方设备", value: prompt.peerDisplayName)
                    AndroidParityInfoRow(title: "对方设备指纹", value: prompt.peerFingerprint)
                    Text("确认「\(prompt.peerDisplayName)」屏幕上显示的数字与上面完全一致。对不上说明连接可能被劫持，请立即取消。")
                        .font(.footnote)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
                Button {
                    coordinator.confirmVerification(matches: true)
                } label: {
                    Label("验证码一致，开始同步", systemImage: "checkmark.shield")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                Button(role: .destructive) {
                    coordinator.confirmVerification(matches: false)
                } label: {
                    Label("验证码不一致，取消", systemImage: "exclamationmark.triangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .destructiveOutlined))
            }
        }
    }

    // MARK: Busy

    @ViewBuilder
    private func busy(_ coordinator: AppLanSyncCoordinator, title: String, detail: String) -> some View {
        AndroidParitySection(title: title) {
            AndroidParityCard {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(AndroidParityPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(role: .destructive) {
                    coordinator.cancel()
                } label: {
                    Label("取消同步", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .destructiveOutlined))
            }
        }
    }

    // MARK: Summary

    @ViewBuilder
    private func summary(_ coordinator: AppLanSyncCoordinator) -> some View {
        AndroidParitySection(title: "同步完成") {
            AndroidParityCard {
                if let imported = coordinator.importedReceipt {
                    Text("从对方设备接收")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.primary)
                    AndroidParityInfoRow(title: "新增", value: "\(imported.created)")
                    AndroidParityInfoRow(title: "更新", value: "\(imported.updated)")
                    AndroidParityInfoRow(title: "删除", value: "\(imported.deleted)")
                    AndroidParityInfoRow(title: "冲突", value: "\(imported.conflicts)")
                }
                if let peer = coordinator.peerReceipt {
                    AndroidParityDivider()
                    Text("对方设备接收")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AndroidParityPalette.primary)
                    AndroidParityInfoRow(title: "新增", value: "\(peer.created)")
                    AndroidParityInfoRow(title: "更新", value: "\(peer.updated)")
                    AndroidParityInfoRow(title: "删除", value: "\(peer.deleted)")
                    AndroidParityInfoRow(title: "冲突", value: "\(peer.conflicts)")
                }
                if let imported = coordinator.importedReceipt, imported.alreadyApplied {
                    Text("这次重试的数据此前已经应用过，没有重复创建条目。")
                        .font(.caption)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                }
            }
        }

        if !coordinator.conflicts.isEmpty {
            AndroidParitySection(title: "需要你处理的冲突") {
                AndroidParityCard {
                    Text("以下条目两边都改过，或者一边删除另一边又修改了，所以没有自动合并。本地数据没有被覆盖。")
                        .font(.footnote)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                    ForEach(Array(coordinator.conflicts.enumerated()), id: \.offset) { _, conflict in
                        AndroidParityInfoRow(
                            title: conflict.title.isEmpty ? "未命名条目" : conflict.title,
                            value: conflict.reason.localizedSummary
                        )
                    }
                }
            }
        }

        AndroidParitySection(title: "") {
            Button {
                coordinator.cancel()
                dismiss()
            } label: {
                Label("完成", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AndroidParityButtonStyle(tone: .filled))
        }
    }

    // MARK: Failure

    @ViewBuilder
    private func failure(_ coordinator: AppLanSyncCoordinator, message: String) -> some View {
        AndroidParitySection(title: "同步没有完成") {
            AndroidParityCard {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let guidance = coordinator.guidance {
                    Text(guidance)
                        .font(.footnote)
                        .foregroundStyle(AndroidParityPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("本地保险库和条目没有被修改。可以按下面的按钮重试。")
                    .font(.caption)
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }

        AndroidParitySection(title: "重试") {
            AndroidParityCard {
                Button {
                    pairingCode = ""
                    selectedPeerID = nil
                    coordinator.startBrowsing()
                } label: {
                    Label("重新搜索设备", systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .filled))
                Button {
                    coordinator.startHosting()
                } label: {
                    Label("重新发起并显示配对码", systemImage: "wifi")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
                Button {
                    coordinator.cancel()
                    dismiss()
                } label: {
                    Label("返回设置", systemImage: "chevron.left")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
            }
        }

        AndroidParitySection(title: "常见原因") {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.6)) {
                securityBullet("本地网络权限被关闭：设置 → 隐私与安全性 → 本地网络，允许 Monica。")
                securityBullet("两台设备不在同一 Wi-Fi / 热点，或路由器开启了 AP 隔离。")
                securityBullet("配对码输错或已过期，重新发起一次即可。")
                securityBullet("其中一台设备锁屏或切到后台，连接会被系统挂起。")
            }
        }
    }

    // MARK: Helpers

    private func displayCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let middle = code.index(code.startIndex, offsetBy: 3)
        return "\(code[..<middle]) \(code[middle...])"
    }

    private static func relativeDateString(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// 配对码输入的最小校验，和 MonicaSync 中的规则保持一致。
private enum LanSyncCodeInput {
    static func isValid(_ code: String) -> Bool {
        let digits = code.filter(\.isNumber)
        return digits.count == 6
    }
}
