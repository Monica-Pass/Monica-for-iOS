//
//  AppVaultLayoutPreferences.swift
//  Monica
//
//  布局偏好（#63）：版本化 schema + 独立存储后端。
//  与 `VaultDisplayPreferences` 分开存储，不改动既有存储层。
//

import Foundation

/// 版本化的密码页布局偏好（#63）。
///
/// - 只持久化稳定 ID（`PasswordLayoutModule.rawValue`），不存中文标题或数组下标。
/// - 与 `VaultDisplayPreferences`（卡片密度 / 字段显隐）分开存储，不改动已有存储层，
///   也不删除任何既有用户数据。
/// - 解码时归一化：未知 / 重复 ID 忽略，缺失 ID 按默认顺序补齐，未知版本整份回退，
///   保证老配置或脏数据安全可用且可恢复默认。
struct VaultLayoutPreferences: Sendable, Codable, Equatable {
    static let currentVersion = 1
    static let defaultModuleOrder: [PasswordLayoutModule] = [.login, .passkey, .note, .generator]
    static let defaultHiddenModuleIDs: [String] = [PasswordLayoutModule.generator.rawValue]
    static let `default` = VaultLayoutPreferences(
        version: currentVersion,
        moduleOrder: defaultModuleOrder.map(\.rawValue),
        hiddenModuleIDs: defaultHiddenModuleIDs
    )

    /// schema 版本；未知版本一律整份回退，不猜测新格式。
    var version: Int
    /// 四个可定制二级模块的顺序，全部以稳定 ID 持久化。
    var moduleOrder: [String]
    /// 从模块栏隐藏的模块；隐藏项仍可从「更多」菜单进入。
    var hiddenModuleIDs: [String]

    init(
        version: Int = Self.currentVersion,
        moduleOrder: [String]? = nil,
        hiddenModuleIDs: [String]? = nil
    ) {
        self.version = version
        self.moduleOrder = moduleOrder ?? Self.defaultModuleOrder.map(\.rawValue)
        self.hiddenModuleIDs = hiddenModuleIDs ?? Self.defaultHiddenModuleIDs
        normalize()
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case moduleOrder
        case hiddenModuleIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 老配置缺字段或字段类型不符时逐项回退到默认值，不让整份配置解码失败。
        let version = (try? container.decode(Int.self, forKey: .version)) ?? Self.currentVersion
        let moduleOrder = (try? container.decode([String].self, forKey: .moduleOrder))
            ?? Self.defaultModuleOrder.map(\.rawValue)
        let hiddenModuleIDs = (try? container.decode([String].self, forKey: .hiddenModuleIDs))
            ?? Self.defaultHiddenModuleIDs
        self.init(version: version, moduleOrder: moduleOrder, hiddenModuleIDs: hiddenModuleIDs)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(moduleOrder, forKey: .moduleOrder)
        try container.encode(hiddenModuleIDs, forKey: .hiddenModuleIDs)
    }

    /// 把任意来源的配置收敛成一份完整、可安全使用的布局。
    mutating func normalize() {
        guard version == Self.currentVersion else {
            self = Self.default
            return
        }

        var seen = Set<String>()
        var ordered: [PasswordLayoutModule] = []
        for rawValue in moduleOrder {
            guard let module = PasswordLayoutModule(rawValue: rawValue),
                  seen.insert(rawValue).inserted
            else {
                continue
            }
            ordered.append(module)
        }
        for module in Self.defaultModuleOrder where !seen.contains(module.rawValue) {
            ordered.append(module)
        }
        moduleOrder = ordered.map(\.rawValue)

        var hidden = Set<String>()
        for rawValue in hiddenModuleIDs {
            guard let module = PasswordLayoutModule(rawValue: rawValue) else { continue }
            _ = hidden.insert(module.rawValue)
        }
        // 至少保留一个列表模块可见，密码页不能只剩「其他」。
        let listModules = ordered.filter { $0.passwordModule != nil }
        if listModules.allSatisfy({ hidden.contains($0.rawValue) }) {
            _ = hidden.remove(PasswordLayoutModule.login.rawValue)
        }
        hiddenModuleIDs = ordered.map(\.rawValue).filter { hidden.contains($0) }
    }

    var orderedModules: [PasswordLayoutModule] {
        get {
            moduleOrder.compactMap { PasswordLayoutModule(rawValue: $0) }
        }
        set {
            moduleOrder = newValue.map(\.rawValue)
            normalize()
        }
    }

    var hiddenModules: [PasswordLayoutModule] {
        let hidden = Set(hiddenModuleIDs)
        return orderedModules.filter { hidden.contains($0.rawValue) }
    }

    var visibleModules: [PasswordLayoutModule] {
        let hidden = Set(hiddenModuleIDs)
        return orderedModules.filter { !hidden.contains($0.rawValue) }
    }

    func isHidden(_ module: PasswordLayoutModule) -> Bool {
        hiddenModuleIDs.contains(module.rawValue)
    }

    mutating func setHidden(_ isHidden: Bool, for module: PasswordLayoutModule) {
        var hidden = Set(hiddenModuleIDs)
        if isHidden {
            _ = hidden.insert(module.rawValue)
        } else {
            _ = hidden.remove(module.rawValue)
        }
        hiddenModuleIDs = orderedModules.map(\.rawValue).filter { hidden.contains($0) }
        normalize()
    }

    func normalized() -> Self {
        var copy = self
        copy.normalize()
        return copy
    }
}

/// 独立的版本化布局偏好存储（#63）：与显示偏好分开，避免改动已有存储层。
protocol VaultLayoutPreferenceStore: Sendable {
    func loadPreferences() -> VaultLayoutPreferences
    func savePreferences(_ preferences: VaultLayoutPreferences)
}

/// 布局偏好写入 `monica.vaultLayoutPreferences`，与既有 key 完全隔离（#63）。
final class UserDefaultsVaultLayoutPreferenceStore: VaultLayoutPreferenceStore, @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let key = "monica.vaultLayoutPreferences"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func loadPreferences() -> VaultLayoutPreferences {
        guard let data = userDefaults.data(forKey: key) else {
            return .default
        }
        do {
            return try JSONDecoder().decode(VaultLayoutPreferences.self, from: data)
        } catch {
            // 配置损坏或来自未知 schema：安全回退到默认布局；
            // 保留原始存储，不删除也不改写用户数据。
            NSLog(
                "Monica: vault layout preferences could not be decoded (%@); using defaults.",
                String(describing: error)
            )
            return .default
        }
    }

    func savePreferences(_ preferences: VaultLayoutPreferences) {
        do {
            let data = try JSONEncoder().encode(preferences)
            userDefaults.set(data, forKey: key)
        } catch {
            // 不静默吞错；写失败时保留上一次成功保存的值。
            NSLog(
                "Monica: vault layout preferences could not be encoded (%@); keeping existing value.",
                String(describing: error)
            )
        }
    }
}

final class MemoryVaultLayoutPreferenceStore: VaultLayoutPreferenceStore, @unchecked Sendable {
    private(set) var preferences: VaultLayoutPreferences?

    init(preferences: VaultLayoutPreferences? = nil) {
        self.preferences = preferences
    }

    func loadPreferences() -> VaultLayoutPreferences {
        preferences ?? .default
    }

    func savePreferences(_ preferences: VaultLayoutPreferences) {
        self.preferences = preferences
    }
}
