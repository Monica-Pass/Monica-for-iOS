//
//  AppVaultRegistrySupport.swift
//  Monica
//
//  本地保险库注册表的持久化与路径工具。
//  注册表只落盘「显示名 / 路径 / 时间戳 / 默认标记」，主密码与密钥仍只存在 Keychain。
//

import Foundation
import MonicaStorage

/// 注册表持久化。
protocol AppVaultRegistryStore: Sendable {
    func load() throws -> LocalVaultRegistry
    func save(_ registry: LocalVaultRegistry) throws
    func delete() throws
}

/// UserDefaults 落盘的注册表。
///
/// 只保存 `LocalVaultRegistry` 的 JSON：库名、文件路径、上次打开时间、默认标记。
/// 主密码、包裹密钥、AutoFill 索引密钥都不会进入这里（见 `KeychainWrappedVaultKeyStore`）。
final class UserDefaultsVaultRegistryStore: AppVaultRegistryStore, @unchecked Sendable {
    static let storageKey = "monica.vaultRegistry.v1"

    private let userDefaults: UserDefaults
    private let key = UserDefaultsVaultRegistryStore.storageKey

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func load() throws -> LocalVaultRegistry {
        guard let data = userDefaults.data(forKey: key) else {
            return LocalVaultRegistry()
        }
        return try JSONDecoder().decode(LocalVaultRegistry.self, from: data)
    }

    func save(_ registry: LocalVaultRegistry) throws {
        userDefaults.set(try JSONEncoder().encode(registry), forKey: key)
    }

    func delete() throws {
        userDefaults.removeObject(forKey: key)
    }
}

final class MemoryAppVaultRegistryStore: AppVaultRegistryStore, @unchecked Sendable {
    private let lock = NSLock()
    private var registry: LocalVaultRegistry

    init(registry: LocalVaultRegistry = LocalVaultRegistry()) {
        self.registry = registry
    }

    var currentRegistry: LocalVaultRegistry {
        lock.lock()
        defer { lock.unlock() }
        return registry
    }

    func load() throws -> LocalVaultRegistry {
        currentRegistry
    }

    func save(_ registry: LocalVaultRegistry) throws {
        lock.lock()
        defer { lock.unlock() }
        self.registry = registry
    }

    func delete() throws {
        try save(LocalVaultRegistry())
    }
}

/// 本地保险库文件的目录工具。
enum AppVaultDirectories {
    /// 与 `MonicaAppRoot.vaultDirectory` 一致：App 沙盒 Documents。
    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    /// 文件在容器内的相对路径；在容器外（导入的外部文件）返回 nil。
    static func relativePath(for fileURL: URL, baseDirectory: URL = AppVaultDirectories.documentsDirectory) -> String? {
        let basePath = baseDirectory.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(basePath + "/") else {
            return nil
        }
        return String(filePath.dropFirst(basePath.count + 1))
    }

    static func isInsideContainer(_ fileURL: URL, baseDirectory: URL = AppVaultDirectories.documentsDirectory) -> Bool {
        relativePath(for: fileURL, baseDirectory: baseDirectory) != nil
    }

    /// 路径提示：容器内显示相对路径，容器外显示所在目录 + 文件名。
    static func pathHint(for fileURL: URL, baseDirectory: URL = AppVaultDirectories.documentsDirectory) -> String {
        if let relativePath = relativePath(for: fileURL, baseDirectory: baseDirectory) {
            return relativePath
        }
        let parent = fileURL.deletingLastPathComponent().lastPathComponent
        if parent.isEmpty {
            return fileURL.lastPathComponent
        }
        return "\(parent)/\(fileURL.lastPathComponent)"
    }

    /// 外部位置（不在 App 容器内）的库需要额外提示，因为沙盒权限可能在重启后失效。
    static func isExternal(_ fileURL: URL, baseDirectory: URL = AppVaultDirectories.documentsDirectory) -> Bool {
        !isInsideContainer(fileURL, baseDirectory: baseDirectory)
    }
}

/// 注册表操作里只有 App 层才知道的错误。
enum AppVaultRegistryError: LocalizedError, Equatable, Sendable {
    case emptyName
    case duplicateName(String)
    case nameAlreadyUsedByFile(String)
    case missingVault
    case fileMissing(String)
    case activeVaultMustBeLocked
    case refusesToDeleteNonVaultFile
    case pendingPasswordSetup

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return String(localized: "保险库名称不能为空。")
        case .duplicateName(let name):
            return String(localized: "已存在同名保险库，请换一个名称。")
        case .nameAlreadyUsedByFile(let name):
            return String(localized: "目录里已经有同名的 .mdbx 文件，请换一个名称。")
        case .missingVault:
            return String(localized: "找不到这个保险库记录。")
        case .fileMissing(let name):
            return String(localized: "保险库文件不在原位置，请重新打开或删除该记录。")
        case .activeVaultMustBeLocked:
            return String(localized: "请先锁定当前保险库再执行该操作。")
        case .refusesToDeleteNonVaultFile:
            return String(localized: "只能删除 .mdbx 保险库文件。")
        case .pendingPasswordSetup:
            return String(localized: "请先完成当前保险库的主密码设置。")
        }
    }
}
