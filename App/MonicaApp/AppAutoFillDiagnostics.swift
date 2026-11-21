import Foundation
import MonicaCore
import SwiftUI

/// 系统凭据存储的真实状态。
///
/// 只读取系统公开的开关状态与身份条目「数量」，不读取、不缓存、不打印任何凭据内容。
struct AppAutoFillIdentityStoreStatus: Equatable, Sendable {
    /// 用户是否在系统设置里启用了 Monica 的自动填充扩展。
    var isEnabled: Bool
    /// 系统是否支持增量更新（iOS 17.4 起才有意义）。
    var supportsIncrementalUpdates: Bool
    /// 系统侧当前保存的身份条目数量；iOS 17.4 以下无法读取，为 nil。
    var identityCount: Int?
}

/// 读取内嵌自动填充扩展的版本号，便于确认 App 与扩展是否同一构建。
enum AppAutoFillExtensionVersion {
    static let bundleName = "MonicaAutoFillExtension.appex"

    static func current(bundle: Bundle = .main) -> String? {
        guard
            let pluginsURL = bundle.builtInPlugInsURL,
            let extensionBundle = Bundle(url: pluginsURL.appendingPathComponent(bundleName))
        else {
            return nil
        }
        let shortVersion = extensionBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = extensionBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (shortVersion, buildVersion) {
        case let (shortVersion?, buildVersion?):
            return "\(shortVersion) (\(buildVersion))"
        case let (shortVersion?, nil):
            return shortVersion
        default:
            return nil
        }
    }
}

/// 自动填充诊断面板的状态模型。
///
/// 面板只展示真实读到的状态：「上次成功发布」「上次失败原因」来自实际写系统凭据列表的回调，
/// 没有记录时显示「暂无记录」，不会伪造成功。
@MainActor
final class AppAutoFillDiagnosticsModel: ObservableObject {
    struct Snapshot: Equatable {
        var status: AppAutoFillIdentityStoreStatus?
        var statusReadFailed: Bool
        var extensionVersion: String?
        var log: AppAutoFillPublishLog
        var loadedAt: Date

        static let placeholder = Snapshot(
            status: nil,
            statusReadFailed: false,
            extensionVersion: nil,
            log: AppAutoFillPublishLog(),
            loadedAt: .distantPast
        )
    }

    enum RepublishState: Equatable {
        case idle
        case running
        case submitted
        case failed(String)
        case skipped(String)

        var isRunning: Bool {
            if case .running = self {
                return true
            }
            return false
        }
    }

    @Published private(set) var snapshot: Snapshot = .placeholder
    @Published private(set) var isRefreshing = false
    @Published private(set) var republishState: RepublishState = .idle

    private let identityStore: (any AppAutoFillCredentialIdentityStore)?
    private let publishLogStore: any AppAutoFillPublishLogStore

    init(
        identityStore: (any AppAutoFillCredentialIdentityStore)?,
        publishLogStore: any AppAutoFillPublishLogStore
    ) {
        self.identityStore = identityStore
        self.publishLogStore = publishLogStore
    }

    /// 是否可以读取系统凭据存储状态（模拟器/未配置时为 false）。
    var canReadIdentityStore: Bool {
        identityStore != nil
    }

    /// 重新读取系统状态与发布记录。只读，不写系统凭据列表。
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        var status: AppAutoFillIdentityStoreStatus?
        var statusReadFailed = false
        if let identityStore {
            if let readStatus = await identityStore.loadIdentityStoreStatus() {
                status = readStatus
            } else {
                statusReadFailed = true
            }
        }

        snapshot = Snapshot(
            status: status,
            statusReadFailed: statusReadFailed,
            extensionVersion: AppAutoFillExtensionVersion.current(),
            log: publishLogStore.loadLog(),
            loadedAt: Date()
        )
    }

    /// 触发一次身份重新发布，并轮询发布记录拿到真实结果。
    ///
    /// - Parameter publish: 真正的发布动作，沿用既有 `refreshAutoFillEncryptedIndexIfConfigured()` 路径。
    func republish(publish: () throws -> Void) async {
        guard !republishState.isRunning else { return }
        republishState = .running
        await refresh()
        let baseline = snapshot.log

        do {
            try publish()
        } catch let error as AppAutoFillIndexError where error == .vaultLocked {
            republishState = .skipped(error.localizedDescription)
            await refresh()
            return
        } catch {
            republishState = .failed(error.localizedDescription)
            await refresh()
            return
        }

        // 发布本身是异步写系统存储的，轮询发布记录以区分「已写入」「被跳过」「被系统拒绝」。
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(150))
            await refresh()
            if
                snapshot.log.lastSucceededAt != baseline.lastSucceededAt
                    || snapshot.log.lastFailureAt != baseline.lastFailureAt
                    || snapshot.log.lastSkippedAt != baseline.lastSkippedAt
            {
                break
            }
        }

        let log = snapshot.log
        if log.lastFailureAt != baseline.lastFailureAt {
            republishState = .failed(log.lastFailureMessage ?? String(localized: "系统拒绝了身份发布。"))
        } else if log.lastSkippedAt != baseline.lastSkippedAt {
            republishState = .skipped(log.lastSkippedReason ?? String(localized: "未发布身份。"))
        } else {
            republishState = .submitted
        }
    }

    /// 清空已发布身份后刷新面板（锁定清空路径使用）。
    func noteIdentitiesCleared() async {
        await refresh()
    }
}
