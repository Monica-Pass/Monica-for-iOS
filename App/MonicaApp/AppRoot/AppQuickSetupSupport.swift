//
//  AppQuickSetupSupport.swift
//  Monica
//
//  首次使用清单状态与后台备份调度器。
//

import BackgroundTasks
import Foundation

struct AppQuickSetupState: Sendable, Equatable, Codable {
    var completedVaultIDs: Set<String> = []
    var lastCompletedAt: Date?

    func shouldPresent(for vaultID: String?) -> Bool {
        guard let vaultID, !vaultID.isEmpty else {
            return false
        }
        return !completedVaultIDs.contains(vaultID)
    }
}

protocol AppQuickSetupStateStore: Sendable {
    func loadState() -> AppQuickSetupState
    func saveState(_ state: AppQuickSetupState)
}

final class MemoryAppQuickSetupStateStore: AppQuickSetupStateStore, @unchecked Sendable {
    private var state: AppQuickSetupState

    init(state: AppQuickSetupState = AppQuickSetupState()) {
        self.state = state
    }

    func loadState() -> AppQuickSetupState { state }
    func saveState(_ state: AppQuickSetupState) { self.state = state }
}

final class UserDefaultsAppQuickSetupStateStore: AppQuickSetupStateStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard, key: String = "quick-setup-state-v1") {
        self.defaults = defaults
        self.key = key
    }

    func loadState() -> AppQuickSetupState {
        guard let data = defaults.data(forKey: key),
              let state = try? decoder.decode(AppQuickSetupState.self, from: data)
        else {
            return AppQuickSetupState()
        }
        return state
    }

    func saveState(_ state: AppQuickSetupState) {
        guard let data = try? encoder.encode(state) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}

enum AppBackgroundBackupSchedulerState: Sendable, Equatable {
    case unavailable
    case idle
    case scheduled(Date?)
    case failed(String)

    var label: String {
        switch self {
        case .unavailable:
            return String(localized: "后台任务不可用")
        case .idle:
            return String(localized: "未调度")
        case .scheduled(let date):
            guard let date else { return String(localized: "已调度") }
            return String(localized: "已调度 \(date.formatted(date: .abbreviated, time: .shortened))")
        case .failed(let message):
            return message
        }
    }
}

protocol AppBackgroundBackupScheduler: Sendable {
    func scheduleNextBackup(after interval: TimeInterval) async -> AppBackgroundBackupSchedulerState
}

struct SystemAppBackgroundBackupScheduler: AppBackgroundBackupScheduler {
    let refreshIdentifier: String

    init(refreshIdentifier: String = "com.monicapass.monica.backup.refresh") {
        self.refreshIdentifier = refreshIdentifier
    }

    func scheduleNextBackup(after interval: TimeInterval) async -> AppBackgroundBackupSchedulerState {
        let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do {
            try BGTaskScheduler.shared.submit(request)
            return .scheduled(request.earliestBeginDate)
        } catch {
            return .failed(String(localized: "后台备份调度失败"))
        }
    }
}
