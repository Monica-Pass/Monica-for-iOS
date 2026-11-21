import Foundation
import MonicaMDBX

/// 条目上的一个标签。
///
/// `id` 是稳定标识，重命名只改 `name`；因此同一个标签可以同时挂在很多条目上，
/// 重命名 / 删除都能一次性作用到所有引用。
public struct VaultEntryTag: Sendable, Equatable, Hashable, Identifiable, Codable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// 标签目录里的一项：标签本身 + 当前引用它的条目数。
public struct VaultTag: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let entryCount: Int

    public init(id: String, name: String, entryCount: Int) {
        self.id = id
        self.name = name
        self.entryCount = entryCount
    }
}

/// 条目的本地扩展元数据（归档、标签、时间戳）。
///
/// 与 `MDBXEntryMetadata` 一一对应；Storage 对外只暴露这个类型，避免 App 依赖 MDBX 桥接细节。
public struct VaultEntryMetadata: Sendable, Equatable {
    public var isArchived: Bool
    public var tags: [VaultEntryTag]
    public var createdAt: Date?
    public var updatedAt: Date?

    public static let empty = VaultEntryMetadata()

    public init(
        isArchived: Bool = false,
        tags: [VaultEntryTag] = [],
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.isArchived = isArchived
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(_ metadata: MDBXEntryMetadata) {
        self.init(
            isArchived: metadata.isArchived,
            tags: metadata.tags.map { VaultEntryTag(id: $0.id, name: $0.name) },
            createdAt: metadata.createdAt,
            updatedAt: metadata.updatedAt
        )
    }
}

/// 标签相关的可预期错误。
public enum VaultTagError: Error, Sendable, Equatable, LocalizedError {
    case emptyName
    case nameTooLong
    case entryNotFound
    case metadataUnavailable

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return String(localized: "标签名不能为空。")
        case .nameTooLong:
            return String(localized: "标签名不能超过 \(VaultTagName.maxNameLength) 个字符。")
        case .entryNotFound:
            return String(localized: "找不到要更新的条目。")
        case .metadataUnavailable:
            return String(localized: "当前存储引擎不支持标签与归档。")
        }
    }
}

/// 标签名规范化规则。
///
/// - 去掉首尾空白，并把内部连续空白折叠成一个空格；
/// - 统一为 NFC（`precomposedStringWithCanonicalMapping`），避免同一标签出现两种码点；
/// - 长度上限 `maxNameLength` 个字符（按扩展字素簇计数）；
/// - 判重使用大小写不敏感 + 变音符号/全半角不敏感的 `matchingKey`。
///
/// 标签名只写入加密的 payload，不落日志、不写进密码字段。
public enum VaultTagName {
    public static let maxNameLength = 40

    public static func normalize(_ raw: String) throws -> String {
        let collapsed = collapseWhitespace(raw)
        guard !collapsed.isEmpty else {
            throw VaultTagError.emptyName
        }
        guard collapsed.count <= maxNameLength else {
            throw VaultTagError.nameTooLong
        }
        return collapsed
    }

    /// 大小写不敏感的去重键；调用方传入的原始名会先做同样的空白折叠与 NFC。
    public static func matchingKey(_ raw: String) -> String {
        collapseWhitespace(raw)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
    }

    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        !matchingKey(lhs).isEmpty && matchingKey(lhs) == matchingKey(rhs)
    }

    private static func collapseWhitespace(_ raw: String) -> String {
        raw
            .precomposedStringWithCanonicalMapping
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// 所有带标签/归档元数据的条目类型共有的只读视图，供 App 排序与筛选复用。
public protocol VaultTaggedEntry {
    var id: String { get }
    var title: String { get }
    var metadata: VaultEntryMetadata { get }
}

extension VaultTaggedEntry {
    public var isArchived: Bool { metadata.isArchived }
    public var tags: [VaultEntryTag] { metadata.tags }
    public var createdAt: Date? { metadata.createdAt }
    public var updatedAt: Date? { metadata.updatedAt }

    public func hasAnyTag(_ tagIDs: Set<String>) -> Bool {
        metadata.tags.contains { tagIDs.contains($0.id) }
    }
}

extension LocalLoginEntry: VaultTaggedEntry {}
extension LocalNoteEntry: VaultTaggedEntry {}
extension LocalTotpEntry: VaultTaggedEntry {}
extension LocalCardEntry: VaultTaggedEntry {}
extension LocalIdentityEntry: VaultTaggedEntry {}
extension LocalPasskeyEntry: VaultTaggedEntry {}
extension LocalSshKeyEntry: VaultTaggedEntry {}
extension LocalApiTokenEntry: VaultTaggedEntry {}
extension LocalWifiEntry: VaultTaggedEntry {}
extension LocalSSOEntry: VaultTaggedEntry {}
extension LocalBarcodeEntry: VaultTaggedEntry {}
extension LocalSendEntry: VaultTaggedEntry {}
extension LocalSteamEntry: VaultTaggedEntry {}
extension LocalAttachmentMetadata {
    /// 附件条目用文件名同时充当条目标题，便于排序与标签界面统一展示。
    public var title: String { fileName }
}

extension LocalAttachmentMetadata: VaultTaggedEntry {}

/// 存储引擎的扩展能力：标签、归档与条目元数据。
///
/// 单独成协议而不是往 `LocalVaultEngine` 里加方法，是为了让既有测试替身
/// （只实现条目 CRUD 的 fake engine）继续编译；仓库层在运行时向下转型，
/// 不支持的引擎会抛 `VaultTagError.metadataUnavailable`。
public protocol LocalVaultMetadataEngine: LocalVaultEngine {
    func entryMetadata(in handle: LocalVaultHandle, projectID: String) throws -> [String: VaultEntryMetadata]
    func setEntryArchived(in handle: LocalVaultHandle, projectID: String, entryID: String, archived: Bool) throws
    func setEntryTags(in handle: LocalVaultHandle, projectID: String, entryID: String, tags: [VaultEntryTag]) throws
    func listVaultTags(in handle: LocalVaultHandle) throws -> [VaultTag]
    func renameVaultTag(in handle: LocalVaultHandle, tagID: String, name: String) throws -> Int
    func deleteVaultTag(in handle: LocalVaultHandle, tagID: String) throws -> Int
}

extension MDBXLocalVaultEngine: LocalVaultMetadataEngine {
    public func entryMetadata(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [String: VaultEntryMetadata] {
        try vault(for: handle)
            .listEntryMetadata(projectID: projectID)
            .mapValues(VaultEntryMetadata.init)
    }

    public func setEntryArchived(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        archived: Bool
    ) throws {
        _ = try vault(for: handle).setEntryArchived(
            projectID: projectID,
            entryID: entryID,
            archived: archived
        )
    }

    public func setEntryTags(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        tags: [VaultEntryTag]
    ) throws {
        _ = try vault(for: handle).setEntryTags(
            projectID: projectID,
            entryID: entryID,
            tags: tags.map { MDBXEntryTag(id: $0.id, name: $0.name) }
        )
    }

    public func listVaultTags(in handle: LocalVaultHandle) throws -> [VaultTag] {
        let vault = try vault(for: handle)
        let projects = try listProjects(in: handle)
        var catalog: [String: (name: String, entryCount: Int)] = [:]
        for project in projects {
            let metadata = try vault.listEntryMetadata(projectID: project.id)
            for entryMetadata in metadata.values {
                for tag in entryMetadata.tags {
                    var item = catalog[tag.id] ?? (name: tag.name, entryCount: 0)
                    item.name = tag.name
                    item.entryCount += 1
                    catalog[tag.id] = item
                }
            }
        }
        return catalog
            .map { VaultTag(id: $0.key, name: $0.value.name, entryCount: $0.value.entryCount) }
            .sorted { lhs, rhs in
                let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
            }
    }

    public func renameVaultTag(
        in handle: LocalVaultHandle,
        tagID: String,
        name: String
    ) throws -> Int {
        let normalizedName = try VaultTagName.normalize(name)
        return try rewriteVaultTag(in: handle, tagID: tagID) { tags in
            // 重命名后若与条目上已有标签同名（大小写不敏感），就地合并，避免同一标签重复出现。
            let duplicates = tags.filter {
                $0.id != tagID && VaultTagName.matches($0.name, normalizedName)
            }
            tags.removeAll { duplicate in duplicates.contains { $0.id == duplicate.id } }
            if let index = tags.firstIndex(where: { $0.id == tagID }) {
                tags[index] = VaultEntryTag(id: tagID, name: normalizedName)
            } else {
                tags.append(VaultEntryTag(id: tagID, name: normalizedName))
            }
        }
    }

    public func deleteVaultTag(
        in handle: LocalVaultHandle,
        tagID: String
    ) throws -> Int {
        try rewriteVaultTag(in: handle, tagID: tagID) { tags in
            tags.removeAll { $0.id == tagID }
        }
    }

    /// 对全库所有条目应用一次标签改写，只重写真正含有该标签的条目。
    ///
    /// 删除 / 重命名都表现为“从 payload 中移除或替换标签”的显式写入，条目本身保留；
    /// 由于 MDBX 文件是备份与同步的载体，改写结果随文件一起持久化，重启后不会复活旧标签。
    private func rewriteVaultTag(
        in handle: LocalVaultHandle,
        tagID: String,
        mutate: (inout [VaultEntryTag]) -> Void
    ) throws -> Int {
        let vault = try vault(for: handle)
        let projects = try listProjects(in: handle)
        var affectedEntryCount = 0
        for project in projects {
            let metadata = try vault.listEntryMetadata(projectID: project.id)
            for (entryID, entryMetadata) in metadata {
                guard entryMetadata.tags.contains(where: { $0.id == tagID }) else {
                    continue
                }
                var tags = entryMetadata.tags.map { VaultEntryTag(id: $0.id, name: $0.name) }
                mutate(&tags)
                _ = try vault.setEntryTags(
                    projectID: project.id,
                    entryID: entryID,
                    tags: tags.map { MDBXEntryTag(id: $0.id, name: $0.name) }
                )
                affectedEntryCount += 1
            }
        }
        return affectedEntryCount
    }
}

extension LocalVaultEntryRepository {
    /// 全库标签目录（含引用计数），用于标签筛选条与标签管理页。
    public func listVaultTags() throws -> [VaultTag] {
        try metadataEngine.listVaultTags(in: session.handle)
    }

    /// 某个分类下所有条目的元数据快照（条目 id → 元数据）。
    public func entryMetadata(projectID: String) throws -> [String: VaultEntryMetadata] {
        try metadataEngine.entryMetadata(in: session.handle, projectID: projectID)
    }

    public func setEntryArchived(
        projectID: String,
        entryID: String,
        archived: Bool
    ) throws {
        try metadataEngine.setEntryArchived(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            archived: archived
        )
    }

    public func setEntryTags(
        projectID: String,
        entryID: String,
        tags: [VaultEntryTag]
    ) throws {
        let normalizedTags = try Self.normalizedTagList(tags)
        try metadataEngine.setEntryTags(
            in: session.handle,
            projectID: projectID,
            entryID: entryID,
            tags: normalizedTags
        )
    }

    /// 给条目追加上一个标签；已存在同名标签时复用已有 `tagID`，不会产生重复标签。
    @discardableResult
    public func addEntryTag(
        projectID: String,
        entryID: String,
        name: String,
        existingTags: [VaultEntryTag]
    ) throws -> VaultEntryTag {
        let normalizedName = try VaultTagName.normalize(name)
        if let existing = existingTags.first(where: { VaultTagName.matches($0.name, normalizedName) }) {
            return existing
        }
        let tag = VaultEntryTag(id: UUID().uuidString, name: normalizedName)
        var tags = existingTags
        tags.append(tag)
        try setEntryTags(projectID: projectID, entryID: entryID, tags: tags)
        return tag
    }

    @discardableResult
    public func renameVaultTag(tagID: String, name: String) throws -> Int {
        try metadataEngine.renameVaultTag(in: session.handle, tagID: tagID, name: name)
    }

    @discardableResult
    public func deleteVaultTag(tagID: String) throws -> Int {
        try metadataEngine.deleteVaultTag(in: session.handle, tagID: tagID)
    }

    private var metadataEngine: any LocalVaultMetadataEngine {
        get throws {
            guard let engine = engine as? any LocalVaultMetadataEngine else {
                throw VaultTagError.metadataUnavailable
            }
            return engine
        }
    }

    /// 规范化并去重一份标签列表：同一条目上大小写不敏感的同名标签只保留第一个。
    static func normalizedTagList(_ tags: [VaultEntryTag]) throws -> [VaultEntryTag] {
        var seenKeys: Set<String> = []
        var result: [VaultEntryTag] = []
        for tag in tags {
            let normalizedName = try VaultTagName.normalize(tag.name)
            let key = VaultTagName.matchingKey(normalizedName)
            guard !seenKeys.contains(key) else {
                continue
            }
            seenKeys.insert(key)
            result.append(VaultEntryTag(id: tag.id, name: normalizedName))
        }
        return result
    }
}
