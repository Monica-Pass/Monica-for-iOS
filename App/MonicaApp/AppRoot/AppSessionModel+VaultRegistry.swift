import Foundation
import MonicaStorage

/// 本地多库（MDBX）管理：注册表只保存名称、路径提示、上次打开时间和默认库标记；
/// 主密码与包装密钥始终留在 Keychain，注册表里不出现任何密钥材料。
@MainActor
extension AppSessionModel {
    // MARK: - 列表快照

    var registeredVaultEntries: [VaultRegistryEntry] {
        vaultRegistry.sortedEntries
    }

    var registeredVaultCount: Int {
        vaultRegistry.count
    }

    var hasRegisteredVaults: Bool {
        !vaultRegistry.isEmpty
    }

    var selectedVaultRegistryEntry: VaultRegistryEntry? {
        vaultRegistry.selectedEntry ?? vaultRegistry.defaultEntry ?? vaultRegistry.sortedEntries.first
    }

    var defaultVaultRegistryEntry: VaultRegistryEntry? {
        vaultRegistry.defaultEntry
    }

    var activeVaultRegistryEntry: VaultRegistryEntry? {
        guard let activeVaultSession else { return nil }
        return vaultRegistry.entry(vaultID: activeVaultSession.handle.vaultID)
    }

    /// 从库里新建保险库时，锁屏要先走「设置主密码 → 确认」两步。
    var isPendingVaultCreation: Bool {
        pendingVaultCreationName != nil
    }

    var isVaultPasswordSetupFlow: Bool {
        isFirstTimeVaultSetup || isPendingVaultCreation
    }

    var selectedVaultDisplayName: String {
        if let pendingVaultCreationName, !pendingVaultCreationName.isEmpty {
            return pendingVaultCreationName
        }
        if let entry = selectedVaultRegistryEntry {
            return entry.displayName
        }
        if let remembered = rememberedVaultIdentity {
            return remembered.displayName
        }
        return String(localized: "新的保险库")
    }

    func isRegisteredVaultActive(_ entry: VaultRegistryEntry) -> Bool {
        guard vaultState == .unlocked, let activeVaultSession else { return false }
        return activeVaultSession.handle.vaultID == entry.vaultID
    }

    func isRegisteredVaultSelected(_ entry: VaultRegistryEntry) -> Bool {
        vaultRegistry.selectedEntry?.id == entry.id
    }

    func resolvedFileURL(for entry: VaultRegistryEntry, baseDirectory: URL? = nil) -> URL {
        vaultRegistry.resolveFileURL(
            for: entry,
            baseDirectory: baseDirectory ?? AppVaultDirectories.documentsDirectory
        )
    }

    func registeredVaultFileExists(_ entry: VaultRegistryEntry, baseDirectory: URL? = nil) -> Bool {
        LocalVaultRegistry.fileExists(resolvedFileURL(for: entry, baseDirectory: baseDirectory))
    }

    func pathHint(for entry: VaultRegistryEntry, baseDirectory: URL? = nil) -> String {
        let base = baseDirectory ?? AppVaultDirectories.documentsDirectory
        return AppVaultDirectories.pathHint(for: resolvedFileURL(for: entry, baseDirectory: base), baseDirectory: base)
    }

    // MARK: - 启动引导

    /// 启动时对齐注册表与「上次打开库」指针：
    /// 1. 旧单库用户（注册表为空）把 remembered 迁入注册表并标为默认库；
    /// 2. remembered 有记录但注册表缺项时补登记；
    /// 3. 选中项失效时回落到默认库 / 最近打开的库；
    /// 4. 容器路径变化时按文件名重新定位并写回。
    /// 这里只影响锁屏预选，不读取密钥、也不会自动解锁。
    func bootstrapVaultRegistry(baseDirectory: URL? = nil) {
        let base = baseDirectory ?? AppVaultDirectories.documentsDirectory
        let now = Date()
        var changed = false

        if let remembered = rememberedVaultIdentity, !remembered.vaultID.isEmpty {
            if vaultRegistry.isEmpty {
                changed = vaultRegistry.adoptLegacyVault(
                    vaultID: remembered.vaultID,
                    fileURL: remembered.fileURL,
                    displayName: remembered.displayName,
                    now: now
                ) || changed
            } else if vaultRegistry.entry(vaultID: remembered.vaultID) == nil,
                      vaultRegistry.entry(fileURL: remembered.fileURL) == nil {
                _ = vaultRegistry.register(
                    vaultID: remembered.vaultID,
                    fileURL: remembered.fileURL,
                    displayName: remembered.displayName,
                    bookmarkData: makeVaultBookmarkData(for: remembered.fileURL),
                    now: now
                )
                changed = true
            }
        }

        // 启动时按「默认库」预选；默认库文件不可用或未设置时回落到上次打开。
        var selectionChanged = false
        if let defaultEntry = vaultRegistry.defaultEntry,
           vaultRegistry.selectedEntryID != defaultEntry.id,
           registeredVaultFileExists(defaultEntry, baseDirectory: base) {
            try? vaultRegistry.select(id: defaultEntry.id)
            selectionChanged = true
            changed = true
        }
        if vaultRegistry.selectedEntry == nil,
           let fallback = vaultRegistry.sortedEntries.first {
            try? vaultRegistry.select(id: fallback.id)
            selectionChanged = true
            changed = true
        }

        // 让 remembered 记录始终指向预选中的库，锁屏与钥匙串解锁都以它为准。
        if let selected = vaultRegistry.selectedEntry,
           !selected.vaultID.isEmpty,
           selectionChanged || rememberedVaultIdentity?.vaultID != selected.vaultID {
            storeRememberedVault(
                fileURL: resolvedFileURL(for: selected, baseDirectory: base),
                displayName: selected.displayName,
                vaultID: selected.vaultID
            )
            changed = true
        }

        if vaultRegistry.rebaseStoredPaths(baseDirectory: base) {
            changed = true
        }
        if changed {
            persistVaultRegistry()
        }
    }

    // MARK: - 注册 / 切换

    /// 打开或新建成功后登记当前库；同一 MDBX 库 ID 或同一路径只会更新既有记录。
    @discardableResult
    func registerVaultInRegistry(
        _ session: LocalVaultSession,
        baseDirectory: URL? = nil,
        now: Date = Date()
    ) -> VaultRegistryEntry? {
        let base = baseDirectory ?? AppVaultDirectories.documentsDirectory
        let fileURL = session.descriptor.fileURL
        let entry = vaultRegistry.register(
            vaultID: session.handle.vaultID,
            fileURL: fileURL,
            displayName: session.descriptor.displayName,
            bookmarkData: makeVaultBookmarkData(for: fileURL),
            now: now
        )
        _ = vaultRegistry.rebaseStoredPaths(baseDirectory: base)
        persistVaultRegistry()
        return vaultRegistry.entry(id: entry.id)
    }

    /// 切换到注册表里的另一个库。已解锁时先锁定当前库（关句柄、清搜索/AutoFill/widget 快照），
    /// 然后只把「上次打开库」指向目标库——仍然需要用户自己输入主密码解锁。
    func switchToRegisteredVault(
        id: String,
        baseDirectory: URL? = nil
    ) throws {
        let base = baseDirectory ?? AppVaultDirectories.documentsDirectory
        guard let entry = vaultRegistry.entry(id: id) else {
            vaultRegistryOperationState = .failed(AppVaultRegistryError.missingVault.localizedDescription)
            throw AppVaultRegistryError.missingVault
        }
        let resolvedURL = resolvedFileURL(for: entry, baseDirectory: base)
        guard LocalVaultRegistry.fileExists(resolvedURL) else {
            let error = AppVaultRegistryError.fileMissing(entry.displayName)
            vaultRegistryOperationState = .failed(error.localizedDescription)
            throw error
        }

        let wasActiveVault = activeVaultSession?.handle.vaultID == entry.vaultID
        if vaultState == .unlocked, !wasActiveVault {
            // 切换库前必须关掉旧的 MDBX 句柄，并清掉旧的解锁密钥/搜索/AutoFill 会话。
            lockLocalVault()
        }

        do {
            try vaultRegistry.select(id: entry.id)
        } catch {
            vaultRegistryOperationState = .failed(AppVaultRegistryError.missingVault.localizedDescription)
            throw AppVaultRegistryError.missingVault
        }
        persistVaultRegistry()

        vaultPassword = ""
        firstTimePasswordSetupStep = .enterPassword
        pendingVaultCreationName = nil
        vaultOperationState = .idle
        vaultRegistryOperationState = .idle

        storeRememberedVault(
            fileURL: resolvedURL,
            displayName: entry.displayName,
            vaultID: entry.vaultID
        )
        if wasActiveVault {
            activeVaultName = entry.displayName
        } else {
            vaultState = .locked
        }
    }

    func setDefaultRegisteredVault(id: String) throws {
        guard let entry = vaultRegistry.entry(id: id) else {
            vaultRegistryOperationState = .failed(AppVaultRegistryError.missingVault.localizedDescription)
            throw AppVaultRegistryError.missingVault
        }
        try vaultRegistry.setDefault(id: entry.id)
        persistVaultRegistry()
        vaultRegistryOperationState = .succeeded(String(localized: "已设为默认库"))
    }

    // MARK: - 改名 / 删除

    /// 只改注册表里的显示名，不重命名磁盘上的 .mdbx 文件，避免破坏已保存的路径与 Keychain 映射。
    func renameRegisteredVault(id: String, to newName: String) throws {
        guard let entry = vaultRegistry.entry(id: id) else {
            vaultRegistryOperationState = .failed(AppVaultRegistryError.missingVault.localizedDescription)
            throw AppVaultRegistryError.missingVault
        }
        do {
            try vaultRegistry.rename(id: entry.id, to: newName)
        } catch let error as VaultRegistryError {
            vaultRegistryOperationState = .failed(AppVaultRegistryError.duplicateName(newName).localizedDescription)
            throw error
        }
        persistVaultRegistry()

        let trimmed = vaultRegistry.entry(id: entry.id)?.displayName ?? entry.displayName
        if activeVaultSession?.handle.vaultID == entry.vaultID, let session = activeVaultSession {
            let descriptor = LocalVaultDescriptor(
                fileURL: session.descriptor.fileURL,
                displayName: trimmed
            )
            activeVaultSession = LocalVaultSession(
                descriptor: descriptor,
                handle: session.handle,
                state: session.state
            )
            activeVaultName = trimmed
        }
        if rememberedVaultIdentity?.vaultID == entry.vaultID {
            storeRememberedVault(
                fileURL: resolvedFileURL(for: entry),
                displayName: trimmed,
                vaultID: entry.vaultID
            )
        }
        vaultRegistryOperationState = .succeeded(String(localized: "已重命名保险库"))
    }

    /// 删除注册记录；只有 removeFile 为真、且目标是 .mdbx 普通文件时才删除磁盘实体。
    func deleteRegisteredVault(
        id: String,
        removeFile: Bool,
        baseDirectory: URL? = nil
    ) throws {
        let base = baseDirectory ?? AppVaultDirectories.documentsDirectory
        guard let entry = vaultRegistry.entry(id: id) else {
            vaultRegistryOperationState = .failed(AppVaultRegistryError.missingVault.localizedDescription)
            throw AppVaultRegistryError.missingVault
        }
        let resolvedURL = resolvedFileURL(for: entry, baseDirectory: base)
        let isActiveVault = activeVaultSession?.handle.vaultID == entry.vaultID
        let wasRemembered = rememberedVaultIdentity?.vaultID == entry.vaultID

        if isActiveVault {
            // 先关句柄再删文件，避免 MDBX 仍占用文件。
            lockLocalVault()
        }

        if removeFile {
            guard resolvedURL.pathExtension.lowercased() == "mdbx" else {
                let error = AppVaultRegistryError.refusesToDeleteNonVaultFile
                vaultRegistryOperationState = .failed(error.localizedDescription)
                throw error
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: resolvedURL.path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                try FileManager.default.removeItem(at: resolvedURL)
            }
        }

        do {
            _ = try vaultRegistry.remove(id: entry.id)
        } catch {
            vaultRegistryOperationState = .failed(AppVaultRegistryError.missingVault.localizedDescription)
            throw AppVaultRegistryError.missingVault
        }
        persistVaultRegistry()

        if wasRemembered {
            discardRememberedVault()
            if let fallback = vaultRegistry.selectedEntry ?? vaultRegistry.defaultEntry ?? vaultRegistry.sortedEntries.first {
                storeRememberedVault(
                    fileURL: resolvedFileURL(for: fallback, baseDirectory: base),
                    displayName: fallback.displayName,
                    vaultID: fallback.vaultID
                )
            }
        }
        vaultOperationState = .idle
        vaultRegistryOperationState = .succeeded(String(localized: "已删除保险库"))
    }

    // MARK: - 新建

    /// 从多库列表发起新建：先校验名称，再让锁屏进入「设置主密码 → 确认」流程。
    @discardableResult
    func beginVaultCreation(named rawName: String, baseDirectory: URL? = nil) -> Bool {
        let base = baseDirectory ?? AppVaultDirectories.documentsDirectory
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            vaultRegistryOperationState = .failed(AppVaultRegistryError.emptyName.localizedDescription)
            return false
        }
        guard vaultRegistry.displayNameIsAvailable(name) else {
            vaultRegistryOperationState = .failed(AppVaultRegistryError.duplicateName(name).localizedDescription)
            return false
        }
        let candidateURL = base.appendingPathComponent("\(name).mdbx", isDirectory: false)
        guard !LocalVaultRegistry.fileExists(candidateURL) else {
            vaultRegistryOperationState = .failed(AppVaultRegistryError.nameAlreadyUsedByFile(name).localizedDescription)
            return false
        }
        if vaultState == .unlocked {
            lockLocalVault()
        }
        vaultName = name
        vaultPassword = ""
        firstTimePasswordSetupStep = .enterPassword
        pendingVaultCreationName = name
        vaultOperationState = .idle
        vaultRegistryOperationState = .idle
        return true
    }

    func cancelVaultCreation() {
        pendingVaultCreationName = nil
        vaultName = ""
        vaultPassword = ""
        firstTimePasswordSetupStep = .enterPassword
        vaultOperationState = .idle
        vaultRegistryOperationState = .idle
    }

    // MARK: - 持久化

    func refreshRegisteredVaultPaths(baseDirectory: URL? = nil) {
        let base = baseDirectory ?? AppVaultDirectories.documentsDirectory
        if vaultRegistry.rebaseStoredPaths(baseDirectory: base) {
            persistVaultRegistry()
        }
    }

    func persistVaultRegistry() {
        do {
            try vaultRegistryStore.save(vaultRegistry)
        } catch {
            vaultRegistryOperationState = .failed(String(localized: "保险库列表保存失败，请稍后重试。"))
        }
    }

    func makeVaultBookmarkData(for fileURL: URL) -> Data? {
        try? fileURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }
}
