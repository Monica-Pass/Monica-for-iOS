import Foundation

/// 条目自定义字段的类型。只有这四种会出现在编辑器的类型菜单里。
///
/// `hiddenText` 是受保护类型：值只在用户主动点“显示”时才会进入 UI，
/// 不会被写入搜索索引、普通 Widget 快照或日志。
public enum VaultCustomFieldKind: String, Sendable, Equatable, Hashable, CaseIterable {
    case text
    case hiddenText
    case url
    case date

    public var isProtected: Bool {
        self == .hiddenText
    }

    /// 编辑器类型菜单里的名字。
    public var displayName: String {
        switch self {
        case .text:
            return String(localized: "普通文本")
        case .hiddenText:
            return String(localized: "隐藏文本")
        case .url:
            return String(localized: "链接")
        case .date:
            return String(localized: "日期")
        }
    }

    /// 解码时把未知/缺失的类型降级成普通文本，保证未来版本或旧数据仍能安全打开。
    public init(storageValue: String?) {
        self = VaultCustomFieldKind(rawValue: storageValue ?? "") ?? .text
    }
}

public struct VaultCustomField: Sendable, Equatable, Hashable, Identifiable {
    public static let maxLabelLength = 120
    public static let maxValueLength = 4096

    public var fieldID: String
    public var label: String
    public var kind: VaultCustomFieldKind
    public var value: String
    public var order: Int

    public var id: String { fieldID }

    public init(
        fieldID: String = UUID().uuidString,
        label: String,
        kind: VaultCustomFieldKind = .text,
        value: String = "",
        order: Int = 0
    ) {
        self.fieldID = fieldID
        self.label = label
        self.kind = kind
        self.value = value
        self.order = order
    }

    public var isProtected: Bool { kind.isProtected }

    public var trimmedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isEmpty: Bool {
        trimmedLabel.isEmpty && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 受保护字段在概览/详情里的默认展示值：固定长度掩码，不泄漏真实长度。
    public var maskedValue: String {
        value.isEmpty ? "" : "••••••••"
    }

    /// 链接字段的轻量校验，仅用于编辑器提示；不阻塞保存。
    public var hasValidURLValue: Bool {
        VaultCustomFieldValidation.isValidURLValue(value)
    }

    public func displayValue(revealed: Bool = false) -> String {
        if isProtected && !revealed {
            return maskedValue
        }
        return value
    }
}

public enum VaultCustomFieldValidation {
    /// 空值视为“未填写”，不报错；非空值要求是带 scheme 的绝对链接。
    public static func isValidURLValue(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return true
        }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme,
              !scheme.isEmpty
        else {
            return false
        }
        if let host = components.host, !host.isEmpty {
            return true
        }
        // mailto:/tel: 之类的无 host 链接也是合法的。
        return components.path.isEmpty == false || components.query != nil
    }
}

public enum VaultCustomFieldDateCoding {
    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    /// 日期字段统一存成 `yyyy-MM-dd`（UTC），保证跨时区/跨设备往返稳定。
    public static func string(from date: Date) -> String {
        formatter().string(from: date)
    }

    public static func date(from value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return formatter().date(from: trimmed)
    }
}

/// 关系只保存目标的稳定 itemID 与类型，不保存标题，也不展开目标内容。
public struct VaultItemRelation: Sendable, Equatable, Hashable, Identifiable {
    public var targetItemID: String
    public var targetKind: UnifiedVaultItemKind

    public var id: String { "\(targetKind.rawValue):\(targetItemID)" }

    public init(targetItemID: String, targetKind: UnifiedVaultItemKind) {
        self.targetItemID = targetItemID
        self.targetKind = targetKind
    }
}

/// 条目的附加数据：自定义字段 + 关联条目。
///
/// 用版本化 schema 存放，缺失字段时回落到空数组（历史数据安全默认）。
/// 解码时对未知类型/未来版本做兼容，不做递归解析，因此 A↔B 互链不会递归展开。
public struct VaultItemExtras: Sendable, Equatable, Hashable {
    public static let currentSchemaVersion = 1
    public static let maxCustomFields = 100
    public static let maxRelations = 200

    public var schemaVersion: Int
    public var itemID: String
    public var itemKind: UnifiedVaultItemKind?
    public var customFields: [VaultCustomField]
    public var relations: [VaultItemRelation]

    public init(
        itemID: String,
        itemKind: UnifiedVaultItemKind? = nil,
        customFields: [VaultCustomField] = [],
        relations: [VaultItemRelation] = [],
        schemaVersion: Int = VaultItemExtras.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.itemID = itemID
        self.itemKind = itemKind
        self.customFields = customFields
        self.relations = relations
    }

    public var isEmpty: Bool {
        customFields.isEmpty && relations.isEmpty
    }

    public var hasProtectedValues: Bool {
        customFields.contains { $0.isProtected }
    }

    /// 归一化：去空白、裁剪超长、稳定排序并把 order 重排成 0..<n。
    /// 只做本地整理，不做任何网络/递归展开。
    public func normalized() -> VaultItemExtras {
        let trimmedItemID = itemID.trimmingCharacters(in: .whitespacesAndNewlines)

        var fields = customFields.enumerated()
            .filter { !$0.element.isEmpty }
            .sorted { lhs, rhs in
                if lhs.element.order == rhs.element.order {
                    return lhs.offset < rhs.offset
                }
                return lhs.element.order < rhs.element.order
            }
            .map { _, field -> VaultCustomField in
                var copy = field
                if copy.fieldID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    copy.fieldID = UUID().uuidString
                }
                copy.label = String(copy.trimmedLabel.prefix(VaultCustomField.maxLabelLength))
                copy.value = String(
                    copy.value
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .prefix(VaultCustomField.maxValueLength)
                )
                if copy.kind == .date,
                   let date = VaultCustomFieldDateCoding.date(from: copy.value) {
                    copy.value = VaultCustomFieldDateCoding.string(from: date)
                }
                return copy
            }
        if fields.count > VaultItemExtras.maxCustomFields {
            fields = Array(fields.prefix(VaultItemExtras.maxCustomFields))
        }
        for index in fields.indices {
            fields[index].order = index
        }

        var seenRelations = Set<String>()
        var relations: [VaultItemRelation] = []
        for relation in self.relations {
            let targetID = relation.targetItemID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !targetID.isEmpty, targetID != trimmedItemID else {
                continue
            }
            let key = "\(relation.targetKind.rawValue):\(targetID)"
            guard seenRelations.insert(key).inserted else {
                continue
            }
            relations.append(VaultItemRelation(targetItemID: targetID, targetKind: relation.targetKind))
            if relations.count >= VaultItemExtras.maxRelations {
                break
            }
        }

        return VaultItemExtras(
            itemID: trimmedItemID,
            itemKind: itemKind,
            customFields: fields,
            relations: relations,
            schemaVersion: VaultItemExtras.currentSchemaVersion
        )
    }

    /// 序列化成保险库 payload 里的 JSON 字符串（键排序，便于做稳定比较/测试）。
    public func payloadJSONString() throws -> String {
        let normalized = normalized()
        guard !normalized.itemID.isEmpty else {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        var payload: [String: Any] = [
            "schemaVersion": normalized.schemaVersion,
            "itemID": normalized.itemID,
            "customFields": normalized.customFields.map { field in
                [
                    "fieldID": field.fieldID,
                    "label": field.label,
                    "kind": field.kind.rawValue,
                    "value": field.value,
                    "order": field.order
                ] as [String: Any]
            },
            "relations": normalized.relations.map { relation in
                [
                    "targetItemID": relation.targetItemID,
                    "targetKind": relation.targetKind.rawValue
                ] as [String: Any]
            }
        ]
        if let itemKind = normalized.itemKind {
            payload["itemKind"] = itemKind.rawValue
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        return json
    }

    /// 容错解码：未知字段忽略、缺字段回落默认值、没有稳定 itemID 的记录返回 nil。
    public init?(payloadJSON: String, fallbackItemID: String? = nil) {
        guard let data = payloadJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any]
        else {
            return nil
        }

        let storedItemID = (payload["itemID"] as? String) ?? ""
        let resolvedItemID = storedItemID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (fallbackItemID ?? "")
            : storedItemID
        let itemID = resolvedItemID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !itemID.isEmpty else {
            return nil
        }

        let schemaVersion = max(1, payload["schemaVersion"] as? Int ?? VaultItemExtras.currentSchemaVersion)
        let itemKindRaw = payload["itemKind"] as? String
        let itemKind = itemKindRaw.flatMap(UnifiedVaultItemKind.init(rawValue:))

        let rawFields = payload["customFields"] as? [[String: Any]] ?? []
        let fields = rawFields.enumerated().map { index, raw -> VaultCustomField in
            let fieldID = (raw["fieldID"] as? String) ?? ""
            return VaultCustomField(
                fieldID: fieldID.isEmpty ? UUID().uuidString : fieldID,
                label: (raw["label"] as? String) ?? "",
                kind: VaultCustomFieldKind(storageValue: raw["kind"] as? String),
                value: (raw["value"] as? String) ?? "",
                order: raw["order"] as? Int ?? index
            )
        }

        let rawRelations = payload["relations"] as? [[String: Any]] ?? []
        let relations: [VaultItemRelation] = rawRelations.compactMap { raw in
            guard let targetItemID = raw["targetItemID"] as? String,
                  !targetItemID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let kindRaw = raw["targetKind"] as? String,
                  let kind = UnifiedVaultItemKind(rawValue: kindRaw)
            else {
                return nil
            }
            return VaultItemRelation(targetItemID: targetItemID, targetKind: kind)
        }

        self.init(
            itemID: itemID,
            itemKind: itemKind,
            customFields: fields,
            relations: relations,
            schemaVersion: schemaVersion
        )
    }
}

extension VaultItemExtras: CustomDebugStringConvertible {
    /// 刻意不输出字段值：受保护值不能出现在日志/崩溃报告里。
    public var debugDescription: String {
        "VaultItemExtras(itemID: \(itemID), fields: \(customFields.count), protectedFields: \(customFields.filter(\.isProtected).count), relations: \(relations.count), schema: \(schemaVersion))"
    }
}

/// 关联目标在某一时刻的可解析快照。只描述“这个条目还在不在”，不展开目标的关系。
public struct VaultItemDescriptor: Sendable, Equatable, Hashable {
    public let itemID: String
    public let kind: UnifiedVaultItemKind
    public let title: String
    public let isDeleted: Bool

    public init(itemID: String, kind: UnifiedVaultItemKind, title: String, isDeleted: Bool) {
        self.itemID = itemID
        self.kind = kind
        self.title = title
        self.isDeleted = isDeleted
    }
}

public enum VaultItemRelationStatus: String, Sendable, Equatable, Hashable {
    case available
    case deleted
    case kindMismatch
    case missing

    public var isBroken: Bool {
        self != .available
    }
}

public struct VaultItemResolvedRelation: Sendable, Equatable, Hashable, Identifiable {
    public let relation: VaultItemRelation
    public let status: VaultItemRelationStatus
    public let targetTitle: String?

    public var id: String { relation.id }
    public var targetItemID: String { relation.targetItemID }
    public var targetKind: UnifiedVaultItemKind { relation.targetKind }

    public init(
        relation: VaultItemRelation,
        status: VaultItemRelationStatus,
        targetTitle: String?
    ) {
        self.relation = relation
        self.status = status
        self.targetTitle = targetTitle
    }
}

public enum VaultItemRelationResolver {
    /// 单层解析：只为每个关系找到目标当前状态，绝不递归跟随目标自身的关系，
    /// 因此 A→B 与 B→A 同时存在时也不会互相展开或死循环。
    public static func resolve(
        _ relations: [VaultItemRelation],
        descriptors: [VaultItemDescriptor]
    ) -> [VaultItemResolvedRelation] {
        var descriptorsByID: [String: [VaultItemDescriptor]] = [:]
        for descriptor in descriptors {
            descriptorsByID[descriptor.itemID, default: []].append(descriptor)
        }

        return relations.map { relation in
            let matches = descriptorsByID[relation.targetItemID] ?? []
            if let exact = matches.first(where: { $0.kind == relation.targetKind }) {
                return VaultItemResolvedRelation(
                    relation: relation,
                    status: exact.isDeleted ? .deleted : .available,
                    targetTitle: exact.title
                )
            }
            if let mismatched = matches.first {
                return VaultItemResolvedRelation(
                    relation: relation,
                    status: .kindMismatch,
                    targetTitle: mismatched.title
                )
            }
            return VaultItemResolvedRelation(
                relation: relation,
                status: .missing,
                targetTitle: nil
            )
        }
    }
}

/// 侧表在保险库里的 entryType/kind。
///
/// MDBX FFI 只接受固定的 entryType 白名单，所以侧表借用 `document-ref` 这一泛型类型，
/// 再用私有 kind 区分。旧版本/其他端只按已知 kind（wifi/send/attachment-ref）读取，
/// 因此这些隐藏记录对它们不可见、也不会破坏项目非空判定。
public enum VaultItemExtrasStorage {
    public static let entryType = "document-ref"
    public static let entryKind = "item-metadata"
}

/// 不支持侧表的引擎（测试替身）保持空实现：不会破坏旧测试，也不会悄悄改写条目内容。
public extension LocalVaultEngine {
    func listItemExtras(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [String: VaultItemExtras] {
        [:]
    }

    func saveItemExtras(
        in handle: LocalVaultHandle,
        projectID: String,
        extras: VaultItemExtras
    ) throws -> VaultItemExtras {
        extras.normalized()
    }

    func deleteItemExtras(
        in handle: LocalVaultHandle,
        projectID: String,
        itemID: String
    ) throws {}

    func moveItemExtras(
        in handle: LocalVaultHandle,
        itemID: String,
        fromProjectID: String,
        toProjectID: String
    ) throws {}
}
