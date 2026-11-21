import Foundation

// MARK: - Bitwarden 密码库元数据（集合 / 自定义字段）
//
// 这些类型把 Bitwarden 保险库里的组织归属与自定义字段从 parser 里暴露出来，
// 供预览、集合过滤与字段级合并使用。全部为纯值类型，不持有任何解密密钥。

/// Bitwarden 集合（Collection）。集合归属于某个组织，个人保险库没有集合。
public struct BitwardenSyncCollection: Sendable, Equatable, Identifiable {
    public var id: String { remoteID }

    public let remoteID: String
    public let name: String
    public let organizationID: String?
    public let isDefault: Bool

    public init(remoteID: String, name: String, organizationID: String? = nil, isDefault: Bool = false) {
        self.remoteID = remoteID
        self.name = name
        self.organizationID = organizationID
        self.isDefault = isDefault
    }

    public var redactedSummary: String {
        [name.isEmpty ? "未命名集合" : name, isDefault ? "默认" : ""]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Bitwarden 自定义字段类型。0 = text, 1 = hidden, 2 = boolean。
public enum BitwardenSyncCustomFieldType: String, Sendable, Equatable, Codable {
    case text
    case hidden
    case boolean

    public var displayName: String {
        switch self {
        case .text: "文本"
        case .hidden: "隐藏"
        case .boolean: "布尔"
        }
    }
}

/// Bitwarden 自定义字段。隐藏字段的值在任何摘要里都必须脱敏。
public struct BitwardenSyncCustomField: Sendable, Equatable, Identifiable {
    public var id: String { "\(type.rawValue):\(name)" }

    public let name: String
    public let value: String
    public let type: BitwardenSyncCustomFieldType

    public init(name: String, value: String, type: BitwardenSyncCustomFieldType = .text) {
        self.name = name
        self.value = value
        self.type = type
    }

    public var isHidden: Bool { type == .hidden }

    /// 隐藏字段只回显固定占位符，调用方不需要再自行判断。
    public var displayValue: String {
        isHidden ? "••••••" : value
    }

    public var redactedSummary: String {
        [name.isEmpty ? "未命名字段" : name, displayValue]
            .filter { !$0.isEmpty }
            .joined(separator: "：")
    }
}

// MARK: - 增量同步修订

/// 一次 `accounts/revision-date` 查询的结果。只保存服务端修订标记与抓取时间，
/// 不含任何 token；调用方用它避免「没有变化也重新导入一遍」。
public struct BitwardenSyncRevision: Sendable, Equatable, Codable {
    public let value: String
    public let capturedAt: Date

    public init(value: String, capturedAt: Date = Date()) {
        self.value = value
        self.capturedAt = capturedAt
    }

    public var redactedSummary: String {
        "修订 \(value)（\(capturedAt.formatted(date: .numeric, time: .shortened))）"
    }
}

/// 带增量判断的拉取结果。
public enum BitwardenSyncPullOutcome: Sendable, Equatable {
    case unchanged(revision: BitwardenSyncRevision?)
    case changed(snapshot: BitwardenSyncSnapshot, revision: BitwardenSyncRevision?)

    public var snapshot: BitwardenSyncSnapshot? {
        guard case let .changed(snapshot, _) = self else { return nil }
        return snapshot
    }

    public var revision: BitwardenSyncRevision? {
        switch self {
        case let .unchanged(revision): revision
        case let .changed(_, revision): revision
        }
    }

    public var redactedSummary: String {
        switch self {
        case let .unchanged(revision):
            ["远端没有变化", revision?.redactedSummary ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        case let .changed(snapshot, revision):
            [snapshot.redactedSummary, revision?.redactedSummary ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }
}

// MARK: - 字段级合并

/// 可比较的同步字段。字段名只用于本地化展示，不含任何密文。
public enum BitwardenSyncField: String, Sendable, Equatable, Hashable, CaseIterable {
    case kind
    case title
    case username
    case url
    case password
    case totp
    case notes
    case folder
    case favorite
    case cardholderName
    case cardNumber
    case cardExpiryMonth
    case cardExpiryYear
    case cardCode
    case cardBrand
    case identityFullName
    case identityDocumentNumber
    case identityIssuer
    case identityCountry
    case passkeyRelyingPartyID
    case passkeyRelyingPartyName
    case passkeyCredentialID
    case passkeyUserHandle
    case passkeyPublicKeyCOSE
    case passkeyPrivateKeyReference
    case passkeyPublicKeyAlgorithm
    case passkeyCounter
    case passkeyDiscoverable
    case passkeyCreationDate
    case sshPublicKey
    case sshPrivateKey
    case sshKeyFingerprint

    public var displayName: String {
        switch self {
        case .kind: "类型"
        case .title: "标题"
        case .username: "用户名"
        case .url: "网址"
        case .password: "密码"
        case .totp: "验证码密钥"
        case .notes: "备注"
        case .folder: "文件夹"
        case .favorite: "收藏"
        case .cardholderName: "持卡人"
        case .cardNumber: "卡号"
        case .cardExpiryMonth: "有效期月份"
        case .cardExpiryYear: "有效期年份"
        case .cardCode: "安全码"
        case .cardBrand: "卡组织"
        case .identityFullName: "姓名"
        case .identityDocumentNumber: "证件号"
        case .identityIssuer: "签发机构"
        case .identityCountry: "国家/地区"
        case .passkeyRelyingPartyID: "Passkey 依赖方"
        case .passkeyRelyingPartyName: "Passkey 依赖方名称"
        case .passkeyCredentialID: "Passkey 凭据 ID"
        case .passkeyUserHandle: "Passkey 用户句柄"
        case .passkeyPublicKeyCOSE: "Passkey 公钥"
        case .passkeyPrivateKeyReference: "Passkey 私钥引用"
        case .passkeyPublicKeyAlgorithm: "Passkey 算法"
        case .passkeyCounter: "Passkey 计数器"
        case .passkeyDiscoverable: "Passkey 可发现"
        case .passkeyCreationDate: "Passkey 创建时间"
        case .sshPublicKey: "SSH 公钥"
        case .sshPrivateKey: "SSH 私钥"
        case .sshKeyFingerprint: "SSH 指纹"
        }
    }

    /// 敏感字段只允许出现在「字段名」级别的报告里，永远不带值。
    public var isSensitive: Bool {
        switch self {
        case .password, .totp, .notes, .cardNumber, .cardCode,
             .identityDocumentNumber, .passkeyUserHandle, .passkeyPublicKeyCOSE,
             .passkeyPrivateKeyReference, .sshPrivateKey:
            true
        default:
            false
        }
    }
}

/// 字段级三方合并的结论。`fields` 只携带字段名，绝不携带字段值。
public enum BitwardenItemMergeOutcome: Sendable, Equatable {
    /// 远端新增，本地没有对应条目。
    case newRemote
    /// 本地新增，远端没有对应条目。
    case newLocal
    /// 两侧内容一致（或已经收敛）。
    case unchanged
    /// 只有远端改动，可以把内容应用到本地。
    case remoteUpdate(fields: [BitwardenSyncField])
    /// 只有本地改动，等待推送。
    case localUpdate(fields: [BitwardenSyncField])
    /// 两侧都改了同一批字段，不能自动覆盖。
    case conflict(fields: [BitwardenSyncField])
    /// 远端软删除，本地没有改动，可以安全删除本地条目。
    case remoteDeletion
    /// 远端删除了条目，但本地在上次同步后改过，需要用户确认。
    case remoteDeletionConflict(fields: [BitwardenSyncField])
    /// 本地删除，等待推送到远端。
    case localDeletion
    /// 本地已删除，但远端在上次同步后改过，需要用户确认。
    case localDeletionConflict(fields: [BitwardenSyncField])

    public var fields: [BitwardenSyncField] {
        switch self {
        case let .remoteUpdate(fields), let .localUpdate(fields), let .conflict(fields),
             let .remoteDeletionConflict(fields), let .localDeletionConflict(fields):
            fields
        default:
            []
        }
    }

    /// 需要用户介入才能继续的结论。
    public var needsAttention: Bool {
        switch self {
        case .conflict, .remoteDeletionConflict, .localDeletionConflict:
            true
        default:
            false
        }
    }

    /// 可以直接应用到本地条目的内容（远端胜出的场景）。
    public var appliesRemoteContent: Bool {
        if case .remoteUpdate = self { return true }
        return false
    }

    /// 允许在不询问用户的情况下删除本地条目。
    public var appliesRemoteDeletion: Bool {
        if case .remoteDeletion = self { return true }
        return false
    }

    public var redactedSummary: String {
        switch self {
        case .newRemote: "新增：远端条目"
        case .newLocal: "新增：本地条目"
        case .unchanged: "无变化"
        case let .remoteUpdate(fields): "更新：远端改动 \(Self.fieldList(fields))"
        case let .localUpdate(fields): "待推送：本地改动 \(Self.fieldList(fields))"
        case let .conflict(fields): "冲突：两侧都改了 \(Self.fieldList(fields))"
        case .remoteDeletion: "删除：远端已删除"
        case let .remoteDeletionConflict(fields): "冲突：远端已删除，本地也改过 \(Self.fieldList(fields))"
        case .localDeletion: "待推送：本地已删除"
        case let .localDeletionConflict(fields): "冲突：本地已删除，远端也改过 \(Self.fieldList(fields))"
        }
    }

    private static func fieldList(_ fields: [BitwardenSyncField]) -> String {
        fields.isEmpty ? "（无字段差异）" : fields.map(\.displayName).joined(separator: "、")
    }
}

/// 纯逻辑的字段级三方合并引擎：`lastSyncedFingerprint` 记录本地上次同步的内容，
/// `lastRemoteFingerprint`（或旧状态的 `lastRemoteRevision`）记录远端上次同步的版本，
/// 二者共同决定某一侧是否真的改动过。
public struct BitwardenItemMergeEngine: Sendable {
    public init() {}

    public func outcome(
        remote: BitwardenSyncItem?,
        local: BitwardenLocalItemSyncItem?,
        state: BitwardenItemSyncState?,
        localIsDeleted: Bool = false
    ) -> BitwardenItemMergeOutcome {
        let localChanged = Self.hasLocalChanged(local: local, state: state)
        let remoteChanged = Self.hasRemoteChanged(remote: remote, state: state)
        let differences = Self.fieldDifferences(remote: remote, local: local)

        // 本地删除：只要远端在上次同步后没变，就可以继续推送删除。
        if localIsDeleted || state?.isDeleted == true {
            guard let remote else { return .localDeletion }
            if remote.deletedAt != nil { return .localDeletion }
            if remoteChanged { return .localDeletionConflict(fields: differences) }
            return .localDeletion
        }

        // 远端软删除（Bitwarden 的 deletedDate 表示进入回收站）。
        if let remote, remote.deletedAt != nil {
            guard let local, let state else { return .remoteDeletion }
            if localChanged || state.isDeleted { return .remoteDeletionConflict(fields: differences) }
            return .remoteDeletion
        }

        guard let remote else {
            guard let local else { return .unchanged }
            guard let state else { return .newLocal }
            return localChanged ? .remoteDeletionConflict(fields: differences) : .remoteDeletion
        }

        guard let local, let state else {
            return .newRemote
        }

        if differences.isEmpty {
            return .unchanged
        }
        if localChanged && remoteChanged {
            return .conflict(fields: differences)
        }
        if localChanged {
            return .localUpdate(fields: differences)
        }
        if remoteChanged {
            return .remoteUpdate(fields: differences)
        }
        // 两侧的记账版本都没有变化，但内容不同（状态缺失或由旧版本写入）：
        // 这种情况无法判断谁更新，保守地交给用户。
        return .conflict(fields: differences)
    }

    static func hasLocalChanged(local: BitwardenLocalItemSyncItem?, state: BitwardenItemSyncState?) -> Bool {
        guard let local, let state else { return false }
        return local.syncFingerprint != state.lastSyncedFingerprint
    }

    static func hasRemoteChanged(remote: BitwardenSyncItem?, state: BitwardenItemSyncState?) -> Bool {
        guard let remote, let state else { return false }
        if let lastRemoteFingerprint = state.lastRemoteFingerprint {
            return remote.syncFingerprint != lastRemoteFingerprint
        }
        return Self.revisionToken(for: remote) != (state.lastRemoteRevision ?? "")
    }

    static func revisionToken(for item: BitwardenSyncItem) -> String {
        guard let updatedAt = item.updatedAt else { return "" }
        return String(updatedAt.timeIntervalSince1970)
    }

    static func fieldDifferences(
        remote: BitwardenSyncItem?,
        local: BitwardenLocalItemSyncItem?
    ) -> [BitwardenSyncField] {
        guard let remote, let local else { return [] }
        let remoteValues = fieldValues(of: remote)
        let localValues = fieldValues(of: local)
        return BitwardenSyncField.allCases.filter { remoteValues[$0] != localValues[$0] }
    }

    static func fieldValues(of item: BitwardenSyncItem) -> [BitwardenSyncField: String] {
        [
            .kind: item.kind.rawValue,
            .title: item.title,
            .username: item.username,
            .url: item.url,
            .password: item.password ?? "",
            .totp: item.totpSecret ?? "",
            .notes: item.notes ?? "",
            .folder: item.folderID ?? "",
            .favorite: item.favorite ? "true" : "false",
            .cardholderName: item.cardholderName,
            .cardNumber: item.cardNumber,
            .cardExpiryMonth: item.cardExpiryMonth,
            .cardExpiryYear: item.cardExpiryYear,
            .cardCode: item.cardCode,
            .cardBrand: item.cardBrand,
            .identityFullName: item.identityFullName,
            .identityDocumentNumber: item.identityDocumentNumber,
            .identityIssuer: item.identityIssuer,
            .identityCountry: item.identityCountry,
            .passkeyRelyingPartyID: item.passkeyRelyingPartyID,
            .passkeyRelyingPartyName: item.passkeyRelyingPartyName,
            .passkeyCredentialID: item.passkeyCredentialID,
            .passkeyUserHandle: item.passkeyUserHandle,
            .passkeyPublicKeyCOSE: item.passkeyPublicKeyCOSE,
            .passkeyPrivateKeyReference: item.passkeyPrivateKeyReference,
            .passkeyPublicKeyAlgorithm: item.passkeyPublicKeyAlgorithm,
            .passkeyCounter: item.passkeyCounter,
            .passkeyDiscoverable: item.passkeyDiscoverable ? "true" : "false",
            .passkeyCreationDate: item.passkeyCreationDate,
            .sshPublicKey: item.sshPublicKey,
            .sshPrivateKey: item.sshPrivateKey,
            .sshKeyFingerprint: item.sshKeyFingerprint
        ]
    }

    static func fieldValues(of item: BitwardenLocalItemSyncItem) -> [BitwardenSyncField: String] {
        [
            .kind: item.kind.rawValue,
            .title: item.title,
            .username: item.username,
            .url: item.url,
            .password: item.password ?? "",
            .totp: item.totpSecret ?? "",
            .notes: item.notes ?? "",
            .folder: item.folderID ?? "",
            .favorite: item.favorite ? "true" : "false",
            .cardholderName: item.cardholderName,
            .cardNumber: item.cardNumber,
            .cardExpiryMonth: item.cardExpiryMonth,
            .cardExpiryYear: item.cardExpiryYear,
            .cardCode: item.cardCode,
            .cardBrand: item.cardBrand,
            .identityFullName: item.identityFullName,
            .identityDocumentNumber: item.identityDocumentNumber,
            .identityIssuer: item.identityIssuer,
            .identityCountry: item.identityCountry,
            .passkeyRelyingPartyID: item.passkeyRelyingPartyID,
            .passkeyRelyingPartyName: item.passkeyRelyingPartyName,
            .passkeyCredentialID: item.passkeyCredentialID,
            .passkeyUserHandle: item.passkeyUserHandle,
            .passkeyPublicKeyCOSE: item.passkeyPublicKeyCOSE,
            .passkeyPrivateKeyReference: item.passkeyPrivateKeyReference,
            .passkeyPublicKeyAlgorithm: item.passkeyPublicKeyAlgorithm,
            .passkeyCounter: item.passkeyCounter,
            .passkeyDiscoverable: item.passkeyDiscoverable ? "true" : "false",
            .passkeyCreationDate: item.passkeyCreationDate,
            .sshPublicKey: item.sshPublicKey,
            .sshPrivateKey: item.sshPrivateKey,
            .sshKeyFingerprint: item.sshKeyFingerprint
        ]
    }
}

// MARK: - 同步预览摘要

/// 手动同步前的预览计数。只包含数量与字段名，不包含任何条目内容。
public struct BitwardenSyncPreviewSummary: Sendable, Equatable {
    public let newItemCount: Int
    public let updatedItemCount: Int
    public let pendingUploadItemCount: Int
    public let unchangedItemCount: Int
    public let conflictItemCount: Int
    public let remoteDeletionCount: Int
    public let localDeletionCount: Int
    public let localOnlyItemCount: Int
    public let duplicateItemCount: Int
    public let skippedItemCount: Int
    public let collectionCount: Int
    public let organizationItemCount: Int
    public let attachmentByteCount: Int
    public let customFieldCount: Int
    public let conflictFieldNames: [String]
    public let collectionNames: [String]

    init(
        newItemCount: Int = 0,
        updatedItemCount: Int = 0,
        pendingUploadItemCount: Int = 0,
        unchangedItemCount: Int = 0,
        conflictItemCount: Int = 0,
        remoteDeletionCount: Int = 0,
        localDeletionCount: Int = 0,
        localOnlyItemCount: Int = 0,
        duplicateItemCount: Int = 0,
        skippedItemCount: Int = 0,
        collectionCount: Int = 0,
        organizationItemCount: Int = 0,
        attachmentByteCount: Int = 0,
        customFieldCount: Int = 0,
        conflictFieldNames: [String] = [],
        collectionNames: [String] = []
    ) {
        self.newItemCount = newItemCount
        self.updatedItemCount = updatedItemCount
        self.pendingUploadItemCount = pendingUploadItemCount
        self.unchangedItemCount = unchangedItemCount
        self.conflictItemCount = conflictItemCount
        self.remoteDeletionCount = remoteDeletionCount
        self.localDeletionCount = localDeletionCount
        self.localOnlyItemCount = localOnlyItemCount
        self.duplicateItemCount = duplicateItemCount
        self.skippedItemCount = skippedItemCount
        self.collectionCount = collectionCount
        self.organizationItemCount = organizationItemCount
        self.attachmentByteCount = attachmentByteCount
        self.customFieldCount = customFieldCount
        self.conflictFieldNames = conflictFieldNames
        self.collectionNames = collectionNames
    }

    public var needsAttention: Bool { conflictItemCount > 0 }

    public var hasChanges: Bool {
        newItemCount > 0 || updatedItemCount > 0 || pendingUploadItemCount > 0
            || remoteDeletionCount > 0 || localDeletionCount > 0 || localOnlyItemCount > 0
            || conflictItemCount > 0
    }

    /// 逐项计数，供 UI 分行展示。
    public var countLines: [(title: String, count: Int)] {
        [
            ("新增", newItemCount),
            ("更新", updatedItemCount),
            ("待推送", pendingUploadItemCount),
            ("无变化", unchangedItemCount),
            ("冲突", conflictItemCount),
            ("远端删除", remoteDeletionCount),
            ("本地删除", localDeletionCount),
            ("仅本地", localOnlyItemCount),
            ("重复", duplicateItemCount),
            ("已跳过", skippedItemCount)
        ]
    }

    public var countsSummary: String {
        countLines
            .filter { $0.count > 0 }
            .map { "\($0.title) \($0.count)" }
            .joined(separator: " · ")
    }

    public var redactedSummary: String {
        var parts: [String] = []
        if !countsSummary.isEmpty { parts.append(countsSummary) }
        if collectionCount > 0 { parts.append("集合 \(collectionCount)") }
        if organizationItemCount > 0 { parts.append("组织条目 \(organizationItemCount)") }
        if customFieldCount > 0 { parts.append("自定义字段 \(customFieldCount)") }
        if attachmentByteCount > 0 { parts.append("附件 \(attachmentByteCount) 字节") }
        if !conflictFieldNames.isEmpty {
            parts.append("冲突字段 \(conflictFieldNames.joined(separator: "、"))")
        }
        return parts.isEmpty ? "没有可同步的变化" : parts.joined(separator: " · ")
    }
}

/// 由远端快照 + 本地条目 + 上次同步状态计算预览计数。
/// 这是一个纯函数：不访问网络、不读写磁盘，可以在测试里直接覆盖。
public struct BitwardenSyncPreviewBuilder: Sendable {
    public init() {}

    public func summary(
        remote: BitwardenSyncSnapshot,
        localItems: [BitwardenLocalItemSyncItem] = [],
        deletedLocalItems: [BitwardenLocalItemSyncItem] = [],
        previousStates: [BitwardenItemSyncState] = [],
        collectionFilter: Set<String>? = nil
    ) -> BitwardenSyncPreviewSummary {
        let engine = BitwardenItemMergeEngine()
        var statesByRemoteID: [String: BitwardenItemSyncState] = [:]
        for state in previousStates {
            guard let remoteID = state.remoteID else { continue }
            statesByRemoteID[remoteID] = state
        }
        var localByRemoteID: [String: BitwardenLocalItemSyncItem] = [:]
        var remoteIDByLocalID: [String: String] = [:]
        for state in previousStates {
            guard let remoteID = state.remoteID else { continue }
            remoteIDByLocalID[state.localID] = remoteID
        }
        var localByLocalID: [String: BitwardenLocalItemSyncItem] = [:]
        for local in localItems { localByLocalID[local.localID] = local }
        for local in deletedLocalItems { localByLocalID[local.localID] = local }
        for local in localItems {
            guard let remoteID = remoteIDByLocalID[local.localID] else { continue }
            localByRemoteID[remoteID] = local
        }

        var newItemCount = 0
        var updatedItemCount = 0
        var pendingUploadItemCount = 0
        var unchangedItemCount = 0
        var conflictItemCount = 0
        var remoteDeletionCount = 0
        var localDeletionCount = 0
        var localOnlyItemCount = 0
        var duplicateItemCount = 0
        var skippedItemCount = 0
        var organizationItemCount = 0
        var attachmentByteCount = 0
        var customFieldCount = 0
        var conflictFields: Set<BitwardenSyncField> = []
        var seenRemoteIDs: Set<String> = []

        for item in remote.items {
            if !seenRemoteIDs.insert(item.remoteID).inserted {
                duplicateItemCount += 1
                continue
            }
            if let collectionFilter, !collectionFilter.isEmpty,
               Set(item.collectionIDs).isDisjoint(with: collectionFilter) {
                skippedItemCount += 1
                continue
            }
            if item.organizationID != nil { organizationItemCount += 1 }
            attachmentByteCount += item.attachmentByteCount
            customFieldCount += item.customFields.count

            let state = statesByRemoteID[item.remoteID]
            let local = localByRemoteID[item.remoteID]
            let outcome = engine.outcome(remote: item, local: local, state: state)
            switch outcome {
            case .newRemote: newItemCount += 1
            case .remoteUpdate: updatedItemCount += 1
            case .localUpdate: pendingUploadItemCount += 1
            case .unchanged: unchangedItemCount += 1
            case .conflict:
                conflictItemCount += 1
                conflictFields.formUnion(outcome.fields)
            case .remoteDeletion, .remoteDeletionConflict:
                // 远端仍然返回了条目时不会走到这两个分支（只有软删除才会）。
                remoteDeletionCount += 1
                conflictFields.formUnion(outcome.fields)
            case .localDeletion, .localDeletionConflict:
                localDeletionCount += 1
                conflictFields.formUnion(outcome.fields)
            case .newLocal:
                localOnlyItemCount += 1
            }
        }

        // 远端已彻底删除、本地还有关联状态的条目。
        let remoteIDs = Set(remote.items.map(\.remoteID))
        for state in previousStates {
            guard let remoteID = state.remoteID, !remoteIDs.contains(remoteID) else { continue }
            let local = localByLocalID[state.localID]
            let outcome = engine.outcome(remote: nil, local: local, state: state, localIsDeleted: state.isDeleted)
            if outcome.appliesRemoteDeletion {
                remoteDeletionCount += 1
            } else if outcome.needsAttention {
                conflictItemCount += 1
                conflictFields.formUnion(outcome.fields)
            }
        }

        // 本地删除、等待推送的条目。
        for local in deletedLocalItems {
            let state = previousStates.first { $0.localID == local.localID }
            guard let state else {
                localDeletionCount += 1
                continue
            }
            let remote = remote.items.first { $0.remoteID == state.remoteID }
            let outcome = engine.outcome(remote: remote, local: local, state: state, localIsDeleted: true)
            localDeletionCount += 1
            if outcome.needsAttention { conflictItemCount += 1 }
        }

        // 完全没有远端关联的本地条目。
        let knownLocalIDs = Set(previousStates.map(\.localID))
        for local in localItems where !knownLocalIDs.contains(local.localID) {
            let outcome = engine.outcome(remote: nil, local: local, state: nil)
            if case .newLocal = outcome { localOnlyItemCount += 1 }
        }

        let collectionNames = remote.collections.map(\.redactedSummary).sorted()
        return BitwardenSyncPreviewSummary(
            newItemCount: newItemCount,
            updatedItemCount: updatedItemCount,
            pendingUploadItemCount: pendingUploadItemCount,
            unchangedItemCount: unchangedItemCount,
            conflictItemCount: conflictItemCount,
            remoteDeletionCount: remoteDeletionCount,
            localDeletionCount: localDeletionCount,
            localOnlyItemCount: localOnlyItemCount,
            duplicateItemCount: duplicateItemCount,
            skippedItemCount: skippedItemCount,
            collectionCount: remote.collections.count,
            organizationItemCount: organizationItemCount,
            attachmentByteCount: attachmentByteCount,
            customFieldCount: customFieldCount,
            conflictFieldNames: BitwardenSyncField.allCases
                .filter { conflictFields.contains($0) }
                .map(\.displayName),
            collectionNames: collectionNames
        )
    }
}
