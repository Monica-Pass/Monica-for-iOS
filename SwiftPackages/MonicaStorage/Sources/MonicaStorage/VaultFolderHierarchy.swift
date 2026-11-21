import Foundation

// MARK: - 文件夹命名与层级约束
//
// 设计要点（见 issue #27）：
// - 文件夹的稳定主键就是它自己的 MDBX projectID，绝不拿「显示路径」当主键，
//   否则重命名/移动会让所有引用失效。
// - 父目录关系（parentID）加密落在侧表记录里，和条目一样随保险库加密。
// - 旧库里的平铺 project 没有父目录记录，一律按「根文件夹」处理。

/// 文件夹层级相关的错误。
public enum VaultFolderError: Error, Sendable, Equatable, LocalizedError {
    /// 名字去掉首尾空白后为空。
    case emptyName
    /// 名字超过 `VaultFolderNameRules.maxNameLength` 个字素。
    case nameTooLong(limit: Int)
    /// 名字里出现路径分隔符 / 控制字符 / `.` / `..` 这类危险片段。
    case invalidName(reason: VaultFolderInvalidNameReason)
    /// 同级已经有同名文件夹（不做路径拼接，所以同名只允许出现在不同父目录下）。
    case duplicateName(String)
    /// 嵌套层数超过上限。
    case depthExceeded(limit: Int)
    /// 指定的父文件夹不存在。
    case parentNotFound
    /// 指定的文件夹不存在。
    case notFound
    /// 把文件夹移动到它自己或它的后代下。
    case cycleDetected
    /// 非空文件夹不能直接删除（需要显式选择处置策略）。
    case folderNotEmpty
    /// 当前引擎没有提供文件夹侧表能力。
    case engineUnavailable
    /// 锚点工程（保存文件夹记录的隐藏 project）不可用。
    case anchorUnavailable

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return "文件夹名称不能为空。"
        case .nameTooLong(let limit):
            return "文件夹名称最多 \(limit) 个字符。"
        case .invalidName(let reason):
            return reason.message
        case .duplicateName(let name):
            return "同级已存在同名文件夹「\(name)」。"
        case .depthExceeded(let limit):
            return "文件夹层级最多 \(limit) 层。"
        case .parentNotFound:
            return "上级文件夹不存在。"
        case .notFound:
            return "文件夹不存在。"
        case .cycleDetected:
            return "不能把文件夹移动到它自己或它的子文件夹下。"
        case .folderNotEmpty:
            return "文件夹内仍有内容，请选择如何处理后再删除。"
        case .engineUnavailable:
            return "当前存储引擎不支持文件夹层级。"
        case .anchorUnavailable:
            return "文件夹索引暂不可用。"
        }
    }
}

/// 名字被拒绝的具体原因（便于 UI 给出精确提示）。
public enum VaultFolderInvalidNameReason: String, Sendable, Equatable, Hashable {
    /// 含 `/` 或 `\`：路径分隔符会破坏面包屑与导出路径。
    case pathSeparator
    /// 名字是 `.` 或 `..`。
    case relativePathSegment
    /// 以 `/` 开头（绝对路径）。
    case absolutePath
    /// 含换行或其它控制字符。
    case controlCharacter
    /// 含 NUL。
    case nullCharacter

    public var message: String {
        switch self {
        case .pathSeparator:
            return "文件夹名称不能包含 “/” 或 “\\”。"
        case .relativePathSegment:
            return "文件夹名称不能是 “.” 或 “..”。"
        case .absolutePath:
            return "文件夹名称不能是绝对路径。"
        case .controlCharacter:
            return "文件夹名称不能包含换行或控制字符。"
        case .nullCharacter:
            return "文件夹名称不能包含空字符。"
        }
    }
}

/// 文件夹命名/层级规则。全部是纯函数，方便测试固定向量。
public enum VaultFolderNameRules {
    /// 允许的最大嵌套层数（根文件夹算第 1 层）。
    public static let maxDepth = 8
    /// 名字的最大字素数量。
    public static let maxNameLength = 64

    /// 规范化并校验一个文件夹名称。
    ///
    /// - 去掉首尾空白与换行；
    /// - 拒绝空名、超长、`/`、`\`、`.`、`..`、绝对路径、控制字符、NUL。
    public static func normalizedName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VaultFolderError.emptyName
        }
        if trimmed.contains("\0") {
            throw VaultFolderError.invalidName(reason: .nullCharacter)
        }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("\\") {
            throw VaultFolderError.invalidName(reason: .absolutePath)
        }
        if trimmed.contains("/") || trimmed.contains("\\") {
            throw VaultFolderError.invalidName(reason: .pathSeparator)
        }
        if trimmed == "." || trimmed == ".." {
            throw VaultFolderError.invalidName(reason: .relativePathSegment)
        }
        if trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw VaultFolderError.invalidName(reason: .controlCharacter)
        }
        guard trimmed.count <= maxNameLength else {
            throw VaultFolderError.nameTooLong(limit: maxNameLength)
        }
        return trimmed
    }
}

// MARK: - 节点与树

/// 一个文件夹节点。
///
/// `id` 同时是该文件夹在 MDBX 里的 projectID，条目归属因此不需要额外的映射表。
public struct VaultFolderNode: Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public var parentID: String?
    public var title: String
    public var sortOrder: Int
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        parentID: String?,
        title: String,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.parentID = parentID
        self.title = title
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var displayName: String { title }
}

/// 不可变的文件夹森林。
///
/// 构造时就做了清洗：孤儿节点（父目录不存在）提升为根，环被强制打断，
/// 因此任何遍历都不会因为脏数据而无限递归。
public struct VaultFolderTree: Sendable, Equatable {
    /// 已按（父目录，sortOrder，标题，id）排好序的节点。
    public let folders: [VaultFolderNode]
    /// 已删除文件夹的墓碑 ID：不在 `folders` 里，但可以阻止「旧分类导入」把它们复活。
    public let tombstonedIDs: Set<String>
    private let byID: [String: VaultFolderNode]
    private let childrenByParent: [String?: [VaultFolderNode]]

    public static let empty = VaultFolderTree(records: [])

    public init(records: [VaultFolderRecord]) {
        let sanitized = VaultFolderTree.sanitize(records)
        folders = sanitized
        tombstonedIDs = Set(
            records
                .filter { $0.isDeleted && !$0.folderID.isEmpty }
                .map(\.folderID)
        )
        var byID: [String: VaultFolderNode] = [:]
        for folder in sanitized {
            byID[folder.id] = folder
        }
        self.byID = byID
        var children: [String?: [VaultFolderNode]] = [:]
        for folder in sanitized {
            children[folder.parentID, default: []].append(folder)
        }
        childrenByParent = children
    }

    public init(folders: [VaultFolderNode]) {
        self.init(records: folders.map(VaultFolderRecord.init(folder:)))
    }

    public var isEmpty: Bool { folders.isEmpty }

    /// 根级文件夹（没有父目录，或父目录已被清洗掉）。
    public var rootFolders: [VaultFolderNode] {
        childrenByParent[nil] ?? []
    }

    public func folder(id: String) -> VaultFolderNode? {
        byID[id]
    }

    public func children(of parentID: String?) -> [VaultFolderNode] {
        childrenByParent[parentID] ?? []
    }

    /// 从根到目标文件夹的路径（含自身）。找不到时返回空数组；有环也会在上限内停下。
    public func path(to folderID: String) -> [VaultFolderNode] {
        var chain: [VaultFolderNode] = []
        var seen: Set<String> = []
        var currentID: String? = folderID
        while let id = currentID, seen.insert(id).inserted {
            guard let node = byID[id] else { break }
            chain.append(node)
            currentID = node.parentID
            if chain.count > folders.count { break }
        }
        return chain.reversed()
    }

    /// 面包屑用的显示路径，用 ` / ` 连接。仅供展示，绝不用作主键。
    public func displayPath(to folderID: String) -> String {
        path(to: folderID).map(\.title).joined(separator: " / ")
    }

    /// 文件夹深度：根为 1。
    public func depth(of folderID: String) -> Int {
        path(to: folderID).count
    }

    /// 所有后代（不含自身），层序展开。
    public func descendants(of folderID: String) -> [VaultFolderNode] {
        var result: [VaultFolderNode] = []
        var queue = children(of: folderID)
        var visited: Set<String> = [folderID]
        while let node = queue.first {
            queue.removeFirst()
            guard visited.insert(node.id).inserted else { continue }
            result.append(node)
            queue.append(contentsOf: children(of: node.id))
        }
        return result
    }

    /// 以某个文件夹为根的子树（含自身）。
    public func subtree(rootedAt folderID: String) -> [VaultFolderNode] {
        guard let node = byID[folderID] else { return [] }
        return [node] + descendants(of: folderID)
    }

    /// 目标子树允许的最大追加深度：把整棵子树移动到某父目录下是否会超限。
    public func canMove(folderID: String, to newParentID: String?) -> Bool {
        guard let node = byID[folderID] else { return false }
        if let newParentID {
            guard let parent = byID[newParentID] else { return false }
            if newParentID == folderID { return false }
            if descendants(of: folderID).contains(where: { $0.id == newParentID }) { return false }
            let subtreeHeight = (descendants(of: folderID).map { depth(of: $0.id) - depth(of: node.id) }.max() ?? 0) + 1
            return depth(of: parent.id) + subtreeHeight <= VaultFolderNameRules.maxDepth
        }
        let subtreeHeight = (descendants(of: folderID).map { depth(of: $0.id) - depth(of: node.id) }.max() ?? 0) + 1
        return subtreeHeight <= VaultFolderNameRules.maxDepth
    }

    /// 同级里是否已经有同名文件夹。
    public func hasSibling(named title: String, parentID: String?, excluding folderID: String? = nil) -> Bool {
        let target = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return children(of: parentID).contains { child in
            child.id != folderID && child.title.lowercased() == target
        }
    }

    /// 层序展开的整棵树，渲染列表时用。
    public func flattened() -> [(node: VaultFolderNode, depth: Int)] {
        var result: [(VaultFolderNode, Int)] = []
        var queue: [(VaultFolderNode, Int)] = rootFolders.map { ($0, 1) }
        var visited: Set<String> = []
        while !queue.isEmpty {
            let (node, level) = queue.removeFirst()
            guard visited.insert(node.id).inserted else { continue }
            result.append((node, level))
            queue.append(contentsOf: children(of: node.id).map { ($0, level + 1) })
        }
        return result.map { (node: $0.0, depth: $0.1) }
    }

    // MARK: 清洗

    private static func sanitize(_ records: [VaultFolderRecord]) -> [VaultFolderNode] {
        // 同一 folderID 只保留 updatedAt 最新的一条（墓碑优先，避免旧记录压过删除动作）。
        var latest: [String: VaultFolderRecord] = [:]
        for record in records where !record.folderID.isEmpty {
            if let existing = latest[record.folderID] {
                let newerIsTombstone = record.isDeleted && !existing.isDeleted
                let sameStateNewer = record.isDeleted == existing.isDeleted
                    && record.updatedAt >= existing.updatedAt
                if newerIsTombstone || sameStateNewer {
                    latest[record.folderID] = record
                }
            } else {
                latest[record.folderID] = record
            }
        }
        latest = latest.filter { !$0.value.isDeleted }

        var nodes: [String: VaultFolderNode] = [:]
        for record in latest.values {
            nodes[record.folderID] = VaultFolderNode(
                id: record.folderID,
                parentID: record.parentID,
                title: record.normalizedTitle,
                sortOrder: record.sortOrder,
                createdAt: record.createdAt,
                updatedAt: record.updatedAt
            )
        }

        // 孤儿 / 自引用 → 根。
        for id in nodes.keys.sorted() {
            guard let parentID = nodes[id]?.parentID else { continue }
            if parentID == id || nodes[parentID] == nil {
                nodes[id]?.parentID = nil
            }
        }

        // 打断环：对每个仍有父目录的节点向上走，重复访问到起点就说明在环里，
        // 把环里（sortOrder, id）最小的那个提升为根，保证结果确定。
        var guardCount = nodes.count + 1
        var progressed = true
        while progressed, guardCount > 0 {
            progressed = false
            guardCount -= 1
            for id in nodes.keys.sorted() {
                var seen: [String] = []
                var cursor: String? = id
                while let current = cursor, let node = nodes[current] {
                    if seen.contains(current) {
                        let cycle = Array(seen[seen.firstIndex(of: current)!...])
                        let promoted = cycle
                            .compactMap { nodes[$0] }
                            .sorted { lhs, rhs in
                                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                                return lhs.id < rhs.id
                            }
                            .first
                        if let promoted, nodes[promoted.id]?.parentID != nil {
                            nodes[promoted.id]?.parentID = nil
                            progressed = true
                        }
                        break
                    }
                    seen.append(current)
                    cursor = node.parentID
                }
                if progressed { break }
            }
        }

        return nodes.values.sorted { lhs, rhs in
            let lhsParent = lhs.parentID ?? ""
            let rhsParent = rhs.parentID ?? ""
            if lhsParent != rhsParent { return lhsParent < rhsParent }
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            if lhs.title != rhs.title { return lhs.title < rhs.title }
            return lhs.id < rhs.id
        }
    }
}

// MARK: - 加密侧表记录

/// 文件夹元数据在 MDBX 侧表里的持久化格式。
///
/// 记录放在一个隐藏的「锚点工程」里，这样不需要知道每个文件夹的 projectID
/// 就能一次列出整棵树；记录本身随保险库加密，外部看不到文件夹名。
public struct VaultFolderRecord: Sendable, Equatable, Codable {
    /// 侧表 entryType，和条目自定义字段保持一致，避免新增 entryType 影响旧库。
    public static let entryType = "document-ref"
    /// 侧表 kind。
    public static let entryKind = "vault-folder"
    /// 当前 schema 版本。
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var folderID: String
    public var parentID: String?
    public var title: String
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date
    /// 删除墓碑：文件夹被删后记录保留（内容可能还在回收站），但不再出现在树上，
    /// 也不会被「旧分类导入」重新补成根文件夹。
    public var isDeleted: Bool

    public init(
        schemaVersion: Int = VaultFolderRecord.currentSchemaVersion,
        folderID: String,
        parentID: String?,
        title: String,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isDeleted: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.folderID = folderID
        self.parentID = parentID
        self.title = title
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
    }

    public init(folder: VaultFolderNode) {
        self.init(
            folderID: folder.id,
            parentID: folder.parentID,
            title: folder.title,
            sortOrder: folder.sortOrder,
            createdAt: folder.createdAt,
            updatedAt: folder.updatedAt
        )
    }

    /// 展示用标题：历史记录里可能存着未经规范的字符串，这里再兜一层。
    public var normalizedTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名文件夹" : trimmed
    }

    /// 宽容解码：缺字段、类型不符都回退到默认值，保证旧库/旧备份可读。
    public init?(payloadJSON: String, fallbackFolderID: String) {
        guard !fallbackFolderID.isEmpty || !payloadJSON.isEmpty else { return nil }
        let parsed = payloadJSON.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        // 完全无法解析的脏载荷也要能读出来：退化成「只有 folderID」的容错记录，
        // 否则一篇坏数据就能让整棵文件夹树消失。
        let object = parsed ?? [:]
        let folderID = (object["folderID"] as? String) ?? fallbackFolderID
        guard !folderID.isEmpty else { return nil }
        self.schemaVersion = (object["schemaVersion"] as? Int) ?? VaultFolderRecord.currentSchemaVersion
        self.folderID = folderID
        let parent = object["parentID"] as? String
        self.parentID = (parent?.isEmpty ?? true) ? nil : parent
        self.title = (object["title"] as? String) ?? ""
        self.sortOrder = (object["sortOrder"] as? Int) ?? 0
        let created = VaultFolderRecord.date(from: object["createdAt"])
        let updated = VaultFolderRecord.date(from: object["updatedAt"])
        self.createdAt = created ?? updated ?? Date(timeIntervalSince1970: 0)
        self.updatedAt = updated ?? self.createdAt
        self.isDeleted = (object["isDeleted"] as? Bool) ?? false
    }

    private static func date(from raw: Any?) -> Date? {
        if let value = raw as? Double {
            return Date(timeIntervalSince1970: value)
        }
        if let value = raw as? Int {
            return Date(timeIntervalSince1970: TimeInterval(value))
        }
        if let value = raw as? String {
            return ISO8601DateFormatter().date(from: value)
        }
        return nil
    }

    public func payloadJSONString() throws -> String {
        let object: [String: Any] = [
            "schemaVersion": schemaVersion,
            "folderID": folderID,
            "parentID": parentID ?? "",
            "title": title,
            "sortOrder": sortOrder,
            "createdAt": createdAt.timeIntervalSince1970,
            "updatedAt": updatedAt.timeIntervalSince1970,
            "isDeleted": isDeleted
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        return json
    }
}

// MARK: - 引擎侧表能力

/// 文件夹记录的锚点：保存文件夹索引的隐藏 projectID。
///
/// MDBX 的 FFI 没有「列出所有 project」的接口，重启后引擎拿不到任何 projectID，
/// 因此需要一个 vault 级的小锚点。锚点只包含一个随机 UUID，不含任何用户内容，
/// 所以按 `FileAppBitwardenPendingMutationQueueStore` 的既有做法落在本地文件即可；
/// 文件夹名/层级仍然只存在加密的侧表里。
public protocol VaultFolderAnchorStore: Sendable {
    func loadAnchorProjectID(vaultID: String) throws -> String?
    func saveAnchorProjectID(_ anchorProjectID: String?, vaultID: String) throws
}

/// 进程内锚点（测试与无法落盘时的兜底）。
public final class InMemoryVaultFolderAnchorStore: VaultFolderAnchorStore, @unchecked Sendable {
    private let lock = NSLock()
    private var anchors: [String: String] = [:]

    public init() {}

    public func loadAnchorProjectID(vaultID: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return anchors[vaultID]
    }

    public func saveAnchorProjectID(_ anchorProjectID: String?, vaultID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        anchors[vaultID] = anchorProjectID
    }
}

/// 落盘锚点：只写一个 UUID，不含用户内容。
public struct FileVaultFolderAnchorStore: VaultFolderAnchorStore {
    private let directoryURL: URL
    private var fileManager: FileManager { .default }

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL.appendingPathComponent("vault-folder-anchor-v1", isDirectory: true)
    }

    public func loadAnchorProjectID(vaultID: String) throws -> String? {
        let url = fileURL(vaultID: vaultID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let anchor = object["anchorProjectID"] as? String,
              !anchor.isEmpty
        else {
            return nil
        }
        return anchor
    }

    public func saveAnchorProjectID(_ anchorProjectID: String?, vaultID: String) throws {
        let url = fileURL(vaultID: vaultID)
        guard let anchorProjectID, !anchorProjectID.isEmpty else {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            return
        }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: ["schemaVersion": 1, "anchorProjectID": anchorProjectID],
            options: [.sortedKeys]
        )
        try data.write(to: url, options: [.atomic])
    }

    private func fileURL(vaultID: String) -> URL {
        let sanitized = vaultID
            .unicodeScalars
            .map { scalar -> String in
                switch scalar.value {
                case 48...57, 65...90, 97...122, 45, 95:
                    return String(scalar)
                default:
                    return "_"
                }
            }
            .joined()
        return directoryURL.appendingPathComponent("\(sanitized).json", isDirectory: false)
    }
}

// MARK: - 引擎侧表方法（默认空实现，避免打断所有测试替身）

public extension LocalVaultEngine {
    /// 列出锚点工程里保存的文件夹记录。
    func listVaultFolderRecords(
        in handle: LocalVaultHandle,
        anchorProjectID: String
    ) throws -> [VaultFolderRecord] {
        []
    }

    /// 写入（新增或覆盖）一条文件夹记录。
    func saveVaultFolderRecord(
        in handle: LocalVaultHandle,
        anchorProjectID: String,
        record: VaultFolderRecord
    ) throws {}

    /// 删除一条文件夹记录。
    func deleteVaultFolderRecord(
        in handle: LocalVaultHandle,
        anchorProjectID: String,
        folderID: String
    ) throws {}
}

// MARK: - 删除策略

/// 非空文件夹的处置策略。删除永远需要调用方明确选择，绝不静默永久删除条目。
public enum VaultFolderDeleteStrategy: String, Sendable, Equatable, Codable, CaseIterable {
    /// 内容上移：子文件夹挂到父文件夹下，条目移动到父文件夹。
    /// 根文件夹没有父级，无法上移，只能选 `recursiveTrash`。
    case reparent
    /// 递归进回收站：子树里的所有条目软删除（可在回收站恢复），随后移除文件夹。
    case recursiveTrash

    public var displayName: String {
        switch self {
        case .reparent:
            return "内容上移到上级"
        case .recursiveTrash:
            return "内容移入回收站"
        }
    }
}

/// 删除前的影响评估，UI 用它做二次确认。
public struct VaultFolderDeletionPlan: Sendable, Equatable {
    public let folderID: String
    public let title: String
    public let descendantFolderCount: Int
    public let liveEntryCount: Int
    public let trashedEntryCount: Int
    /// 根文件夹没有上级，只能递归进回收站。
    public let canReparent: Bool

    public var isEffectivelyEmpty: Bool {
        descendantFolderCount == 0 && liveEntryCount == 0 && trashedEntryCount == 0
    }
}

/// 删除结果。
public struct VaultFolderDeletionResult: Sendable, Equatable {
    public let removedFolderCount: Int
    public let movedEntryCount: Int
    public let trashedEntryCount: Int
}

// MARK: - 文件夹仓储

/// 文件夹层级仓储：所有写操作都以 MDBX project 为落点，
/// 因此条目归属天然跟着文件夹走，备份 / 同步 / AutoFill 索引都不需要改。
public struct VaultFolderRepository {
    private let entryRepository: LocalVaultEntryRepository
    private let session: LocalVaultSession
    private let anchorStore: any VaultFolderAnchorStore

    public init(
        entryRepository: LocalVaultEntryRepository,
        session: LocalVaultSession,
        anchorStore: any VaultFolderAnchorStore = InMemoryVaultFolderAnchorStore()
    ) {
        self.entryRepository = entryRepository
        self.session = session
        self.anchorStore = anchorStore
    }

    // MARK: 读取

    /// 读取整棵树；首次打开旧库时会自动把既有 category 导入成根文件夹。
    public func tree() throws -> VaultFolderTree {
        let anchorProjectID = try ensureAnchor()
        let records = try entryRepository.listVaultFolderRecords(anchorProjectID: anchorProjectID)
        var tree = VaultFolderTree(records: records)
        let imported = try importLegacyProjectsIfNeeded(tree: &tree, anchorProjectID: anchorProjectID)
        if imported {
            let refreshed = try entryRepository.listVaultFolderRecords(anchorProjectID: anchorProjectID)
            tree = VaultFolderTree(records: refreshed)
        }
        return tree
    }

    /// 只读地取锚点，不存在时返回 nil（不会创建）。
    public func existingAnchorProjectID() -> String? {
        try? anchorStore.loadAnchorProjectID(vaultID: session.handle.vaultID)
    }

    // MARK: 写入

    @discardableResult
    public func createFolder(title: String, parentID: String?) throws -> VaultFolderNode {
        let normalized = try VaultFolderNameRules.normalizedName(title)
        let anchorProjectID = try ensureAnchor()
        var tree = VaultFolderTree(
            records: try entryRepository.listVaultFolderRecords(anchorProjectID: anchorProjectID)
        )
        // 旧库可能还没导入，先补齐，否则第一次新建文件夹会丢掉既有分类的层级信息。
        if try importLegacyProjectsIfNeeded(tree: &tree, anchorProjectID: anchorProjectID) {
            tree = VaultFolderTree(
                records: try entryRepository.listVaultFolderRecords(anchorProjectID: anchorProjectID)
            )
        }

        if let parentID {
            guard let parent = tree.folder(id: parentID) else {
                throw VaultFolderError.parentNotFound
            }
            guard tree.depth(of: parent.id) + 1 <= VaultFolderNameRules.maxDepth else {
                throw VaultFolderError.depthExceeded(limit: VaultFolderNameRules.maxDepth)
            }
        }
        guard !tree.hasSibling(named: normalized, parentID: parentID) else {
            throw VaultFolderError.duplicateName(normalized)
        }

        let project = try entryRepository.createProject(title: normalized)
        let now = Date()
        let record = VaultFolderRecord(
            folderID: project.id,
            parentID: parentID,
            title: normalized,
            sortOrder: (tree.children(of: parentID).map(\.sortOrder).max() ?? -1) + 1,
            createdAt: now,
            updatedAt: now
        )
        do {
            try entryRepository.saveVaultFolderRecord(anchorProjectID: anchorProjectID, record: record)
        } catch {
            // 侧表写失败就回滚刚建的 project，避免出现「有工程但没有层级记录」的幽灵文件夹。
            try? entryRepository.deleteProject(projectID: project.id)
            throw error
        }
        return VaultFolderNode(
            id: project.id,
            parentID: parentID,
            title: normalized,
            sortOrder: record.sortOrder,
            createdAt: now,
            updatedAt: now
        )
    }

    @discardableResult
    public func renameFolder(id: String, title: String) throws -> VaultFolderNode {
        let normalized = try VaultFolderNameRules.normalizedName(title)
        let anchorProjectID = try ensureAnchor()
        var tree = VaultFolderTree(
            records: try entryRepository.listVaultFolderRecords(anchorProjectID: anchorProjectID)
        )
        guard let node = tree.folder(id: id) else {
            throw VaultFolderError.notFound
        }
        guard !tree.hasSibling(named: normalized, parentID: node.parentID, excluding: id) else {
            throw VaultFolderError.duplicateName(normalized)
        }
        let now = Date()
        let record = VaultFolderRecord(
            folderID: node.id,
            parentID: node.parentID,
            title: normalized,
            sortOrder: node.sortOrder,
            createdAt: node.createdAt,
            updatedAt: now
        )
        try entryRepository.saveVaultFolderRecord(anchorProjectID: anchorProjectID, record: record)
        // project 标题同步一份，让 LanSync / 备份里的分类名不落后。
        _ = try? entryRepository.renameProject(projectID: id, title: normalized)
        var updated = node
        updated.title = normalized
        updated.updatedAt = now
        tree = VaultFolderTree(
            records: try entryRepository.listVaultFolderRecords(anchorProjectID: anchorProjectID)
        )
        return updated
    }

    @discardableResult
    public func moveFolder(id: String, newParentID: String?) throws -> VaultFolderNode {
        let anchorProjectID = try ensureAnchor()
        let tree = VaultFolderTree(
            records: try entryRepository.listVaultFolderRecords(anchorProjectID: anchorProjectID)
        )
        guard let node = tree.folder(id: id) else {
            throw VaultFolderError.notFound
        }
        if let newParentID {
            guard tree.folder(id: newParentID) != nil else {
                throw VaultFolderError.parentNotFound
            }
            if newParentID == id || tree.descendants(of: id).contains(where: { $0.id == newParentID }) {
                throw VaultFolderError.cycleDetected
            }
            guard tree.canMove(folderID: id, to: newParentID) else {
                throw VaultFolderError.depthExceeded(limit: VaultFolderNameRules.maxDepth)
            }
        }
        if node.parentID == newParentID {
            return node
        }
        guard !tree.hasSibling(named: node.title, parentID: newParentID, excluding: id) else {
            throw VaultFolderError.duplicateName(node.title)
        }
        let now = Date()
        let record = VaultFolderRecord(
            folderID: node.id,
            parentID: newParentID,
            title: node.title,
            sortOrder: (tree.children(of: newParentID).map(\.sortOrder).max() ?? -1) + 1,
            createdAt: node.createdAt,
            updatedAt: now
        )
        try entryRepository.saveVaultFolderRecord(anchorProjectID: anchorProjectID, record: record)
        var updated = node
        updated.parentID = newParentID
        updated.sortOrder = record.sortOrder
        updated.updatedAt = now
        return updated
    }

    /// 评估删除影响（条目数、子文件夹数），不做任何修改。
    public func deletionPlan(folderID: String) throws -> VaultFolderDeletionPlan {
        let anchorProjectID = try ensureAnchor()
        let tree = VaultFolderTree(
            records: try entryRepository.listVaultFolderRecords(anchorProjectID: anchorProjectID)
        )
        guard let node = tree.folder(id: folderID) else {
            throw VaultFolderError.notFound
        }
        let subtree = tree.subtree(rootedAt: folderID)
        var live = 0
        var trashed = 0
        for folder in subtree {
            live += try entryRepository.liveVaultEntryIDs(projectID: folder.id).count
            trashed += try entryRepository.trashedVaultEntryIDs(projectID: folder.id).count
        }
        return VaultFolderDeletionPlan(
            folderID: folderID,
            title: node.title,
            descendantFolderCount: subtree.count - 1,
            liveEntryCount: live,
            trashedEntryCount: trashed,
            canReparent: node.parentID != nil
        )
    }

    /// 按显式策略删除文件夹。
    @discardableResult
    public func deleteFolder(
        folderID: String,
        strategy: VaultFolderDeleteStrategy
    ) throws -> VaultFolderDeletionResult {
        let anchorProjectID = try ensureAnchor()
        let tree = VaultFolderTree(
            records: try entryRepository.listVaultFolderRecords(anchorProjectID: anchorProjectID)
        )
        guard let node = tree.folder(id: folderID) else {
            throw VaultFolderError.notFound
        }
        let children = tree.children(of: folderID)
        let subtree = tree.descendants(of: folderID)
        let liveEntryIDs = try entryRepository.liveVaultEntryIDs(projectID: folderID)

        switch strategy {
        case .reparent:
            guard let parentID = node.parentID else {
                // 根文件夹没有上级可挂，内容只能进回收站。
                guard liveEntryIDs.isEmpty, children.isEmpty, subtree.isEmpty else {
                    throw VaultFolderError.folderNotEmpty
                }
                try removeRecord(folderID: folderID, anchorProjectID: anchorProjectID, tree: tree)
                try? entryRepository.deleteProject(projectID: folderID)
                return VaultFolderDeletionResult(removedFolderCount: 1, movedEntryCount: 0, trashedEntryCount: 0)
            }
            var movedEntries = 0
            for (kind, entryID) in liveEntryIDs {
                _ = try entryRepository.moveEntry(
                    kind: kind,
                    entryID: entryID,
                    fromProjectID: folderID,
                    toProjectID: parentID
                )
                movedEntries += 1
            }
            for child in children {
                _ = try moveFolder(id: child.id, newParentID: parentID)
            }
            try removeRecord(folderID: folderID, anchorProjectID: anchorProjectID, tree: tree)
            try? entryRepository.deleteProject(projectID: folderID)
            return VaultFolderDeletionResult(
                removedFolderCount: 1,
                movedEntryCount: movedEntries,
                trashedEntryCount: 0
            )

        case .recursiveTrash:
            var trashedEntries = 0
            for (kind, entryID) in liveEntryIDs {
                try entryRepository.deleteEntry(kind: kind, entryID: entryID, projectID: folderID)
                trashedEntries += 1
            }
            for descendant in subtree {
                let ids = try entryRepository.liveVaultEntryIDs(projectID: descendant.id)
                for (kind, entryID) in ids {
                    try entryRepository.deleteEntry(
                        kind: kind,
                        entryID: entryID,
                        projectID: descendant.id
                    )
                    trashedEntries += 1
                }
            }
            // 先删叶子再删自己，避免中途失败留下「父子都在但父已删」的错位。
            for descendant in subtree.reversed() {
                try removeRecord(folderID: descendant.id, anchorProjectID: anchorProjectID, tree: tree)
                try? entryRepository.deleteProject(projectID: descendant.id)
            }
            try removeRecord(folderID: folderID, anchorProjectID: anchorProjectID, tree: tree)
            try? entryRepository.deleteProject(projectID: folderID)
            return VaultFolderDeletionResult(
                removedFolderCount: subtree.count + 1,
                movedEntryCount: 0,
                trashedEntryCount: trashedEntries
            )
        }
    }

    // MARK: 内部

    /// 删除文件夹时写墓碑而不是物理删记录：条目可能还在回收站，
    /// 而且旧分类导入需要知道「这个 project 是被人为删掉的」，不能重新补成根文件夹。
    private func removeRecord(
        folderID: String,
        anchorProjectID: String,
        tree: VaultFolderTree
    ) throws {
        var record = tree.folder(id: folderID).map(VaultFolderRecord.init(folder:))
            ?? VaultFolderRecord(folderID: folderID, parentID: nil, title: "")
        record.isDeleted = true
        record.updatedAt = Date()
        try entryRepository.saveVaultFolderRecord(anchorProjectID: anchorProjectID, record: record)
    }

    /// 取锚点工程，没有就建一个。
    private func ensureAnchor() throws -> String {
        let vaultID = session.handle.vaultID
        if let existing = try? anchorStore.loadAnchorProjectID(vaultID: vaultID), !existing.isEmpty {
            return existing
        }
        let project = try entryRepository.createProject(title: VaultFolderRepository.anchorProjectTitle)
        try anchorStore.saveAnchorProjectID(project.id, vaultID: vaultID)
        return project.id
    }

    /// 首次打开旧库：把既有 project（不含锚点）导入成根文件夹，父目录一律为空。
    private func importLegacyProjectsIfNeeded(
        tree: inout VaultFolderTree,
        anchorProjectID: String
    ) throws -> Bool {
        let projects = try entryRepository.listProjects()
        var inserted = false
        var order = tree.rootFolders.map(\.sortOrder).max() ?? -1
        for project in projects where project.id != anchorProjectID {
            // 已删除（有墓碑）的文件夹不能因为 project 还留在内存列表里被重新导入。
            if tree.tombstonedIDs.contains(project.id) { continue }
            if tree.folder(id: project.id) != nil { continue }
            // 同名但不同 project 的旧分类各自成根，不做合并——避免把两批条目混到一起。
            order += 1
            let record = VaultFolderRecord(
                folderID: project.id,
                parentID: nil,
                title: project.title,
                sortOrder: order
            )
            try entryRepository.saveVaultFolderRecord(anchorProjectID: anchorProjectID, record: record)
            inserted = true
        }
        return inserted
    }

    /// 锚点工程用的隐藏标题；不会出现在文件夹树里。
    static let anchorProjectTitle = "内部：文件夹索引"
}

// MARK: - 条目枚举（按 kind 穷尽）

public extension LocalVaultEntryRepository {
    /// 列出锚点工程里的文件夹记录。
    func listVaultFolderRecords(anchorProjectID: String) throws -> [VaultFolderRecord] {
        try engine.listVaultFolderRecords(in: session.handle, anchorProjectID: anchorProjectID)
    }

    func saveVaultFolderRecord(anchorProjectID: String, record: VaultFolderRecord) throws {
        try engine.saveVaultFolderRecord(
            in: session.handle,
            anchorProjectID: anchorProjectID,
            record: record
        )
    }

    func deleteVaultFolderRecord(anchorProjectID: String, folderID: String) throws {
        try engine.deleteVaultFolderRecord(
            in: session.handle,
            anchorProjectID: anchorProjectID,
            folderID: folderID
        )
    }

    /// 某个文件夹里（投影到回收站之外）的所有条目，按 kind 穷尽枚举。
    func liveVaultEntryIDs(projectID: String) throws -> [(UnifiedVaultItemKind, String)] {
        var result: [(UnifiedVaultItemKind, String)] = []
        for kind in UnifiedVaultItemKind.allCases {
            result.append(contentsOf: try vaultEntryIDs(kind: kind, projectID: projectID, deleted: false)
                .map { (kind, $0) })
        }
        return result
    }

    /// 某个文件夹回收站里的条目。
    func trashedVaultEntryIDs(projectID: String) throws -> [(UnifiedVaultItemKind, String)] {
        var result: [(UnifiedVaultItemKind, String)] = []
        for kind in UnifiedVaultItemKind.allCases {
            result.append(contentsOf: try vaultEntryIDs(kind: kind, projectID: projectID, deleted: true)
                .map { (kind, $0) })
        }
        return result
    }

    /// 按 kind 取出条目 ID。switch 保持穷尽（含 `.sso` / `.gpgKey` / `.steam`）。
    func vaultEntryIDs(
        kind: UnifiedVaultItemKind,
        projectID: String,
        deleted: Bool
    ) throws -> [String] {
        switch kind {
        case .login:
            return try (deleted ? listDeletedLoginEntries(projectID: projectID) : listLoginEntries(projectID: projectID)).map(\.id)
        case .totp:
            return try (deleted ? listDeletedTotpEntries(projectID: projectID) : listTotpEntries(projectID: projectID)).map(\.id)
        case .note:
            return try (deleted ? listDeletedNoteEntries(projectID: projectID) : listNoteEntries(projectID: projectID)).map(\.id)
        case .card:
            return try (deleted ? listDeletedCardEntries(projectID: projectID) : listCardEntries(projectID: projectID)).map(\.id)
        case .identity:
            return try (deleted ? listDeletedIdentityEntries(projectID: projectID) : listIdentityEntries(projectID: projectID)).map(\.id)
        case .passkey:
            return try (deleted ? listDeletedPasskeyEntries(projectID: projectID) : listPasskeyEntries(projectID: projectID)).map(\.id)
        case .sshKey:
            return try (deleted ? listDeletedSshKeyEntries(projectID: projectID) : listSshKeyEntries(projectID: projectID)).map(\.id)
        case .apiToken:
            return try (deleted ? listDeletedApiTokenEntries(projectID: projectID) : listApiTokenEntries(projectID: projectID)).map(\.id)
        case .wifi:
            return try (deleted ? listDeletedWifiEntries(projectID: projectID) : listWifiEntries(projectID: projectID)).map(\.id)
        case .sso:
            return try (deleted ? listDeletedSSOEntries(projectID: projectID) : listSSOEntries(projectID: projectID)).map(\.id)
        case .gpgKey:
            return try (deleted ? listDeletedGPGKeyEntries(projectID: projectID) : listGPGKeyEntries(projectID: projectID)).map(\.id)
        case .steam:
            return try (deleted ? listDeletedSteamEntries(projectID: projectID) : listSteamEntries(projectID: projectID)).map(\.id)
        case .barcode:
            return try (deleted ? listDeletedBarcodeEntries(projectID: projectID) : listBarcodeEntries(projectID: projectID)).map(\.id)
        case .send:
            return try (deleted ? listDeletedSendEntries(projectID: projectID) : listSendEntries(projectID: projectID)).map(\.id)
        case .billingAddress:
            return try (deleted
                ? listDeletedBillingAddressEntries(projectID: projectID)
                : listBillingAddressEntries(projectID: projectID)).map(\.id)
        case .paymentAccount:
            return try (deleted
                ? listDeletedPaymentAccountEntries(projectID: projectID)
                : listPaymentAccountEntries(projectID: projectID)).map(\.id)
        case .attachmentRef:
            return try (deleted
                ? listDeletedAttachmentMetadata(projectID: projectID)
                : listAttachmentMetadata(projectID: projectID)).map(\.id)
        }
    }

    /// 按 kind 删除一条条目（进回收站）。
    func deleteEntry(kind: UnifiedVaultItemKind, entryID: String, projectID: String) throws {
        switch kind {
        case .login:
            try deleteLoginEntry(projectID: projectID, entryID: entryID)
        case .totp:
            try deleteTotpEntry(projectID: projectID, entryID: entryID)
        case .note:
            try deleteNoteEntry(projectID: projectID, entryID: entryID)
        case .card:
            try deleteCardEntry(projectID: projectID, entryID: entryID)
        case .identity:
            try deleteIdentityEntry(projectID: projectID, entryID: entryID)
        case .passkey:
            try deletePasskeyEntry(projectID: projectID, entryID: entryID)
        case .sshKey:
            try deleteSshKeyEntry(projectID: projectID, entryID: entryID)
        case .apiToken:
            try deleteApiTokenEntry(projectID: projectID, entryID: entryID)
        case .wifi:
            try deleteWifiEntry(projectID: projectID, entryID: entryID)
        case .sso:
            try deleteSSOEntry(projectID: projectID, entryID: entryID)
        case .gpgKey:
            try deleteGPGKeyEntry(projectID: projectID, entryID: entryID)
        case .steam:
            try deleteSteamEntry(projectID: projectID, entryID: entryID)
        case .barcode:
            try deleteBarcodeEntry(projectID: projectID, entryID: entryID)
        case .send:
            try deleteSendEntry(projectID: projectID, entryID: entryID)
        case .billingAddress:
            try deleteBillingAddressEntry(projectID: projectID, entryID: entryID)
        case .paymentAccount:
            try deletePaymentAccountEntry(projectID: projectID, entryID: entryID)
        case .attachmentRef:
            try deleteAttachmentMetadata(projectID: projectID, attachmentID: entryID)
        }
    }
}

// MARK: - 总览

/// 保险箱总览：每类条目数量、收藏、回收站、最近使用与文件夹规模。
public struct VaultFolderOverview: Sendable, Equatable {
    public struct KindCount: Sendable, Equatable, Identifiable {
        public let kind: UnifiedVaultItemKind
        public let activeCount: Int
        public let favoriteCount: Int
        public let trashedCount: Int

        public var id: String { kind.rawValue }
    }

    public let kindCounts: [KindCount]
    public let rootFolderCount: Int
    public let nestedFolderCount: Int
    public let deepestLevel: Int
    /// 最近使用（按 lastViewedAt 倒序），最多 `recentLimit` 条。
    public let recentDocuments: [VaultSearchDocument]
    /// 每个文件夹（projectID）直属的活跃条目数；不含子文件夹。
    public let entryCountByFolderID: [String: Int]

    /// 某个文件夹直属的活跃条目数。
    public func entryCount(inFolder folderID: String) -> Int {
        entryCountByFolderID[folderID] ?? 0
    }

    public var totalActiveEntries: Int { kindCounts.reduce(0) { $0 + $1.activeCount } }
    public var totalFavorites: Int { kindCounts.reduce(0) { $0 + $1.favoriteCount } }
    public var totalTrashedEntries: Int { kindCounts.reduce(0) { $0 + $1.trashedCount } }
    public var totalFolderCount: Int { rootFolderCount + nestedFolderCount }
    public var isEmpty: Bool { totalActiveEntries == 0 && totalTrashedEntries == 0 && totalFolderCount == 0 }

    /// 纯函数构建，方便在没有 MDBX 的情况下用固定向量测试。
    public static func builder(
        documents: [VaultSearchDocument],
        tree: VaultFolderTree,
        recentLimit: Int = 5
    ) -> VaultFolderOverview {
        var active: [UnifiedVaultItemKind: Int] = [:]
        var favorites: [UnifiedVaultItemKind: Int] = [:]
        var trashed: [UnifiedVaultItemKind: Int] = [:]
        var perFolder: [String: Int] = [:]
        for document in documents {
            if document.isDeleted {
                trashed[document.kind, default: 0] += 1
                continue
            }
            active[document.kind, default: 0] += 1
            if document.isFavorite {
                favorites[document.kind, default: 0] += 1
            }
            if !document.projectID.isEmpty {
                perFolder[document.projectID, default: 0] += 1
            }
        }
        let counts = UnifiedVaultItemKind.allCases.map { kind in
            KindCount(
                kind: kind,
                activeCount: active[kind] ?? 0,
                favoriteCount: favorites[kind] ?? 0,
                trashedCount: trashed[kind] ?? 0
            )
        }
        let recent = documents
            .filter { !$0.isDeleted && $0.lastViewedAt != nil }
            .sorted { lhs, rhs in
                let left = lhs.lastViewedAt ?? .distantPast
                let right = rhs.lastViewedAt ?? .distantPast
                if left != right { return left > right }
                return lhs.id < rhs.id
            }
            .prefix(max(0, recentLimit))
        let depths = tree.folders.map { tree.depth(of: $0.id) }
        return VaultFolderOverview(
            kindCounts: counts,
            rootFolderCount: tree.rootFolders.count,
            nestedFolderCount: tree.folders.count - tree.rootFolders.count,
            deepestLevel: depths.max() ?? 0,
            recentDocuments: Array(recent),
            entryCountByFolderID: perFolder
        )
    }
}
