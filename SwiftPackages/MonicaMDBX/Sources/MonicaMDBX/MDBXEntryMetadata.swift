import Foundation

/// 条目扩展元数据中的一个标签。
///
/// `id` 是稳定标识：重命名标签时只改 `name`，所有引用同一个 `id` 的条目会一起更新；
/// 删除标签只删除关联，不会删除任何条目。
public struct MDBXEntryTag: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// 存放在条目 payload 里的本地扩展元数据。
///
/// MDBX 的 Rust schema 由预编译 xcframework 提供、App 侧不可修改，payload JSON 是唯一
/// 可以自由扩展的加密存储区域，因此归档状态、标签与时间戳都写在 payload 的
/// `monicaMeta` 键下。该键随 MDBX 数据文件一起加密，不会写进任何明文日志。
///
/// 旧数据（拆分前创建、或由 Android 同步写入）没有 `monicaMeta` 键，解码时按
/// “未归档 / 无标签 / 无时间戳”处理，保持向后兼容。
public struct MDBXEntryMetadata: Sendable, Equatable {
    /// payload JSON 中扩展元数据使用的键名。
    public static let payloadKey = "monicaMeta"

    public var isArchived: Bool
    public var tags: [MDBXEntryTag]
    public var createdAt: Date?
    public var updatedAt: Date?

    /// 旧条目缺少 `monicaMeta` 时的取值。
    public static let empty = MDBXEntryMetadata()

    public init(
        isArchived: Bool = false,
        tags: [MDBXEntryTag] = [],
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.isArchived = isArchived
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 从 payload JSON 对象里解析扩展元数据；字段缺失或类型不符时回退到默认值。
    public init(payloadObject: [String: Any]) {
        guard let raw = payloadObject[Self.payloadKey] as? [String: Any] else {
            self = .empty
            return
        }
        let rawTags = raw["tags"] as? [[String: Any]] ?? []
        let tags = rawTags.compactMap { object -> MDBXEntryTag? in
            guard let id = object["id"] as? String, !id.isEmpty,
                  let name = object["name"] as? String
            else {
                return nil
            }
            return MDBXEntryTag(id: id, name: name)
        }
        self.init(
            isArchived: raw["archived"] as? Bool ?? false,
            tags: tags,
            createdAt: (raw["createdAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
            updatedAt: (raw["updatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        )
    }

    /// 序列化回 payload JSON 对象，只写入有值的字段，避免旧备份里出现空壳。
    public var payloadObject: [String: Any] {
        var object: [String: Any] = [:]
        if isArchived {
            object["archived"] = true
        }
        if !tags.isEmpty {
            object["tags"] = tags.map { ["id": $0.id, "name": $0.name] }
        }
        if let createdAt {
            object["createdAt"] = createdAt.timeIntervalSince1970
        }
        if let updatedAt {
            object["updatedAt"] = updatedAt.timeIntervalSince1970
        }
        return object
    }
}

/// payload JSON 的最小读写工具，供本文件的元数据 API 使用。
enum MDBXMetadataPayload {
    static func object(from json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    static func jsonString(_ object: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw MonicaMDBXError.verificationFailed("无法序列化 MDBX payload。")
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else {
            throw MonicaMDBXError.verificationFailed("无法序列化 MDBX payload。")
        }
        return string
    }
}

#if canImport(mdbx_ffiFFI)
extension MonicaMDBXVault {
    /// 读取单个条目的扩展元数据（归档、标签、时间戳）。
    public func entryMetadata(projectID: String, entryID: String) throws -> MDBXEntryMetadata {
        guard let entry = try rawVault
            .listEntries(projectId: projectID, entryType: nil)
            .first(where: { $0.entryId == entryID })
        else {
            throw MonicaMDBXError.verificationFailed("找不到 MDBX 条目。")
        }
        return MDBXEntryMetadata(payloadObject: MDBXMetadataPayload.object(from: entry.payloadJson) ?? [:])
    }

    /// 读取整个分类下所有条目的扩展元数据，键为 `entryId`。
    ///
    /// 一次 `listEntries` 拿到全部类型，避免按类型逐个查询；调用方（MonicaStorage）
    /// 用它在刷新标签目录时做全量扫描。
    public func listEntryMetadata(projectID: String) throws -> [String: MDBXEntryMetadata] {
        var result: [String: MDBXEntryMetadata] = [:]
        for entry in try rawVault.listEntries(projectId: projectID, entryType: nil) {
            result[entry.entryId] = MDBXEntryMetadata(
                payloadObject: MDBXMetadataPayload.object(from: entry.payloadJson) ?? [:]
            )
        }
        return result
    }

    /// 设置归档状态，返回更新后的元数据。
    public func setEntryArchived(
        projectID: String,
        entryID: String,
        archived: Bool
    ) throws -> MDBXEntryMetadata {
        try updateMetadata(projectID: projectID, entryID: entryID) { metadata in
            metadata.isArchived = archived
        }
    }

    /// 覆盖条目的标签列表，返回更新后的元数据。
    public func setEntryTags(
        projectID: String,
        entryID: String,
        tags: [MDBXEntryTag]
    ) throws -> MDBXEntryMetadata {
        try updateMetadata(projectID: projectID, entryID: entryID) { metadata in
            metadata.tags = tags
        }
    }

    /// 读改写 `monicaMeta`：先读当前 payload，替换扩展元数据，再写回其余字段。
    ///
    /// 只改 `monicaMeta`，其它 payload 键（密码、备注等）原样保留。
    private func updateMetadata(
        projectID: String,
        entryID: String,
        mutate: (inout MDBXEntryMetadata) -> Void
    ) throws -> MDBXEntryMetadata {
        guard let entry = try rawVault
            .listEntries(projectId: projectID, entryType: nil)
            .first(where: { $0.entryId == entryID })
        else {
            throw MonicaMDBXError.verificationFailed("找不到 MDBX 条目。")
        }
        var object = MDBXMetadataPayload.object(from: entry.payloadJson) ?? [:]
        var metadata = MDBXEntryMetadata(payloadObject: object)
        mutate(&metadata)
        metadata.updatedAt = Date()
        object[MDBXEntryMetadata.payloadKey] = metadata.payloadObject
        _ = try rawVault.updateEntry(
            projectId: projectID,
            entryId: entryID,
            entryType: entry.entryType,
            title: entry.title,
            payloadJson: try MDBXMetadataPayload.jsonString(object)
        )
        return metadata
    }
}
#else
extension MonicaMDBXVault {
    public func entryMetadata(projectID: String, entryID: String) throws -> MDBXEntryMetadata {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func listEntryMetadata(projectID: String) throws -> [String: MDBXEntryMetadata] {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func setEntryArchived(
        projectID: String,
        entryID: String,
        archived: Bool
    ) throws -> MDBXEntryMetadata {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }

    public func setEntryTags(
        projectID: String,
        entryID: String,
        tags: [MDBXEntryTag]
    ) throws -> MDBXEntryMetadata {
        throw MonicaMDBXError.unavailableOnCurrentPlatform
    }
}
#endif
