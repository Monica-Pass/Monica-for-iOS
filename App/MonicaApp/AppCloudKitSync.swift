//
//  AppCloudKitSync.swift
//  Monica
//
//  iCloud（CloudKit 私人数据库）同步开关与状态（issue #76）。
//
//  安全边界：
//  - 上传到 iCloud 的只有本机保险库文件本身，而它已经是 MDBX + Monica 加密信封
//    的密文；CloudKit 记录里没有任何明文条目、用户名、密码、TOTP 或私钥。
//  - 本文件不做加解密、不读条目数据库，只负责“是否允许 iCloud 作为同步目标”和
//    “云端有没有变更”的展示；真正的上传/拉取仍由「云端保险库」页面驱动。
//  - 未登录 iCloud、无网络、容器未配置时，本机保险库照常可用：这里的每个操作都
//    是可重试的显式动作，失败只影响状态文案。
//

import Foundation
import MonicaSync
import SwiftUI

enum AppCloudKitSyncDefaultsKey {
    /// `Bool`，默认关闭。开启后「云端保险库」的 provider 列表里才会出现 iCloud。
    static let enabled = "monica.cloudkit.sync.enabled"
    /// 每个保险库各自的 CloudKit 变更令牌（不透明 `Data`，不含保险库内容）。
    static let changeTokenPrefix = "monica.cloudkit.change-token."
}

struct AppCloudKitSyncPreferences {
    /// A fresh value on every access: the struct only wraps `UserDefaults` and
    /// holds no mutable state of its own, so there is no shared instance to
    /// make concurrency-safe. `UserDefaults` itself is documented as
    /// thread-safe.
    static var shared: AppCloudKitSyncPreferences { AppCloudKitSyncPreferences() }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: AppCloudKitSyncDefaultsKey.enabled) }
        nonmutating set { defaults.set(newValue, forKey: AppCloudKitSyncDefaultsKey.enabled) }
    }

    func changeToken(forVaultID vaultID: String) -> Data? {
        defaults.data(forKey: AppCloudKitSyncDefaultsKey.changeTokenPrefix + vaultID)
    }

    func setChangeToken(_ token: Data?, forVaultID vaultID: String) {
        let key = AppCloudKitSyncDefaultsKey.changeTokenPrefix + vaultID
        if let token {
            defaults.set(token, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

/// Main-actor state for the iCloud settings section.
///
/// Nothing here touches CloudKit until the user taps a button: constructing a
/// `CKContainer` from a build without the iCloud entitlement traps inside
/// CloudKit itself (Apple behaviour), so the app never probes it speculatively.
@MainActor
@Observable
final class AppCloudKitSyncModel {
    enum AvailabilityState: Equatable {
        case unknown
        case checking
        case available
        case noAccount
        case restricted
        case temporarilyUnavailable
        case failed(String)
    }

    enum ChangeCheckState: Equatable {
        case idle
        case checking
        case upToDate(Date)
        case changed(Date)
        case reset(Date)
        case failed(String)
    }

    private(set) var isEnabled: Bool
    private(set) var availability: AvailabilityState = .unknown
    private(set) var changeCheck: ChangeCheckState = .idle
    private(set) var lastCheckedAt: Date?

    private let preferences: AppCloudKitSyncPreferences

    init(preferences: AppCloudKitSyncPreferences = .shared) {
        self.preferences = preferences
        self.isEnabled = preferences.isEnabled
    }

    var isBusy: Bool {
        availability == .checking || changeCheck == .checking
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        preferences.isEnabled = enabled
        if !enabled {
            availability = .unknown
            changeCheck = .idle
            lastCheckedAt = nil
        }
    }

    /// Asks CloudKit for the account status. Requires a build whose entitlements
    /// include the iCloud container; never called automatically.
    func refreshAvailability() async {
        availability = .checking
        do {
            let transport = CloudKitContainerVaultTransport(
                containerIdentifier: CloudKitVaultSpec.defaultContainerIdentifier
            )
            switch try await transport.accountAvailability() {
            case .available:
                availability = .available
            case .noAccount:
                availability = .noAccount
            case .restricted:
                availability = .restricted
            case .temporarilyUnavailable:
                availability = .temporarilyUnavailable
            case .couldNotDetermine:
                availability = .unknown
            }
            lastCheckedAt = Date()
        } catch let failure as CloudKitVaultFailure {
            availability = .failed(failure.redactedMessage)
        } catch {
            availability = .failed(failureText(for: error))
        }
    }

    /// Pulls the record-zone change feed since the stored token. This downloads
    /// no vault bytes; it only tells the user whether the cloud moved.
    func checkRemoteChanges(vaultID: String) async {
        changeCheck = .checking
        let configuration: CloudKitVaultConfiguration
        do {
            configuration = try CloudKitVaultConfiguration.vault(vaultID: vaultID)
        } catch {
            changeCheck = .failed(failureText(for: error))
            return
        }
        let store = CloudKitCloudVaultRemoteStore(
            configuration: configuration,
            transport: CloudKitContainerVaultTransport(
                containerIdentifier: configuration.containerIdentifier
            )
        )
        do {
            let changes = try await store.pollChanges(since: preferences.changeToken(forVaultID: vaultID))
            preferences.setChangeToken(changes.changeToken, forVaultID: vaultID)
            let now = Date()
            lastCheckedAt = now
            if changes.didReset {
                changeCheck = .reset(now)
                return
            }
            let vaultMoved = changes.changed.contains { $0.recordName == configuration.recordName }
                || changes.deletedRecordNames.contains(configuration.recordName)
            changeCheck = vaultMoved ? .changed(now) : .upToDate(now)
        } catch {
            changeCheck = .failed(failureText(for: error))
        }
    }

    var availabilityTitle: String {
        switch availability {
        case .unknown:
            return String(localized: "尚未检查")
        case .checking:
            return String(localized: "正在检查…")
        case .available:
            return String(localized: "iCloud 可用")
        case .noAccount:
            return String(localized: "未登录 iCloud")
        case .restricted:
            return String(localized: "iCloud 受限")
        case .temporarilyUnavailable:
            return String(localized: "iCloud 暂时不可用")
        case .failed(let message):
            return message
        }
    }

    var changeSummary: String {
        switch changeCheck {
        case .idle:
            return String(localized: "尚未检查云端变更")
        case .checking:
            return String(localized: "正在检查云端变更…")
        case .upToDate:
            return String(localized: "云端没有新的变更")
        case .changed:
            return String(localized: "云端有新的变更，请在「云端保险库」中拉取")
        case .reset:
            return String(localized: "云端变更记录已重置，请重新检查")
        case .failed(let message):
            return message
        }
    }

    private func failureText(for error: Error) -> String {
        if let cloudError = error as? CloudVaultError {
            return cloudError.errorDescription ?? String(localized: "iCloud 操作失败，请稍后重试。")
        }
        return String(localized: "无法连接 iCloud，请稍后重试。")
    }
}

/// Settings → 同步/备份 的 iCloud 开关与状态行。
struct AppCloudKitSyncSection: View {
    let session: AppSessionModel

    @State private var model: AppCloudKitSyncModel?

    var body: some View {
        AndroidParitySection(title: "iCloud 同步") {
            AndroidParityCard(fill: AndroidParityPalette.surfaceVariant.opacity(0.6)) {
                if let model {
                    content(for: model)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task {
            guard model == nil else { return }
            model = AppCloudKitSyncModel()
        }
    }

    @ViewBuilder
    private func content(for model: AppCloudKitSyncModel) -> some View {
        Toggle(isOn: Binding(
            get: { model.isEnabled },
            set: { model.setEnabled($0) }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                Text("通过 iCloud 私人数据库同步")
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(AndroidParityPalette.textPrimary)
                Text("仅上传已加密的保险库文件 · 手动 Push/Pull")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AndroidParityPalette.textSecondary)
            }
        }
        .tint(AndroidParityPalette.primary)

        AndroidParityInfoRow(title: "iCloud 账号", value: model.availabilityTitle)
        AndroidParityInfoRow(title: "云端变更", value: model.changeSummary)
        AndroidParityInfoRow(
            title: "最近检查",
            value: AppCloudVaultSyncCoordinator.formattedDate(model.lastCheckedAt)
        )

        Button {
            Task { await model.refreshAvailability() }
        } label: {
            Label("检查 iCloud 账号", systemImage: "person.icloud")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
        .disabled(model.isBusy)

        Button {
            guard let vaultID = unlockedVaultID else { return }
            Task { await model.checkRemoteChanges(vaultID: vaultID) }
        } label: {
            Label("检查云端变更", systemImage: "arrow.triangle.2.circlepath")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(AndroidParityButtonStyle(tone: .outlined))
        .disabled(model.isBusy || unlockedVaultID == nil)

        if unlockedVaultID == nil {
            Text("解锁保险库后才能检查 iCloud 上的变更。")
                .font(.footnote)
                .foregroundStyle(AndroidParityPalette.textSecondary)
        }

        Text("开启后「云端保险库」会多出 iCloud 选项；云端只保存加密后的保险库文件。未登录 iCloud、无网络或容器未配置时，本机保险库仍可正常使用。")
            .font(.footnote)
            .foregroundStyle(AndroidParityPalette.textSecondary)
    }

    private var unlockedVaultID: String? {
        guard session.vaultState == .unlocked else { return nil }
        return session.activeVaultSession?.handle.vaultID
    }
}
