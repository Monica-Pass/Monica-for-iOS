// MARK: - Bitwarden 同步数据模型（条目 / 快照 / 变更 / 冲突 / 同步状态）

import Foundation

public enum BitwardenSyncItemKind: String, Sendable, Equatable, Hashable, Codable {
    case login
    case passkey
    case secureNote
    case card
    case identity
    case sshKey

    public var displayName: String {
        switch self {
        case .login:
            "login"
        case .passkey:
            "passkey"
        case .secureNote:
            "note"
        case .card:
            "card"
        case .identity:
            "identity"
        case .sshKey:
            "ssh key"
        }
    }
}

public struct BitwardenSyncFolder: Sendable, Equatable, Identifiable {
    public var id: String { remoteID }

    public let remoteID: String
    public let name: String
    public let updatedAt: Date?

    public init(remoteID: String, name: String, updatedAt: Date? = nil) {
        self.remoteID = remoteID
        self.name = name
        self.updatedAt = updatedAt
    }

    public var redactedSummary: String {
        "Folder \(sanitizedBitwardenTitle(name))"
    }
}

public struct BitwardenSyncAttachment: Sendable, Equatable, Identifiable {
    public var id: String { remoteID }

    public let remoteID: String
    public let cipherRemoteID: String
    public let fileName: String
    public let encryptedKey: String?
    public let byteCount: Int

    public init(
        remoteID: String,
        cipherRemoteID: String,
        fileName: String,
        encryptedKey: String? = nil,
        byteCount: Int = 0
    ) {
        self.remoteID = remoteID
        self.cipherRemoteID = cipherRemoteID
        self.fileName = fileName
        self.encryptedKey = encryptedKey
        self.byteCount = byteCount
    }

    public var syncFingerprint: String {
        [
            remoteID,
            cipherRemoteID,
            fileName,
            encryptedKey ?? "",
            String(byteCount)
        ].joined(separator: "\u{1F}")
    }

    public var redactedSummary: String {
        "附件 \(sanitizedBitwardenTitle(fileName)) \(byteCount) 字节"
    }
}

public struct BitwardenSyncItem: Sendable, Equatable, Identifiable {
    public var id: String { remoteID }

    public let remoteID: String
    public let kind: BitwardenSyncItemKind
    public let title: String
    public let username: String
    public let url: String
    public let password: String?
    public let totpSecret: String?
    public let notes: String?
    public let folderID: String?
    public let folderName: String?
    public let collectionNames: [String]
    public let organizationID: String?
    public let collectionIDs: [String]
    public let customFields: [BitwardenSyncCustomField]
    public let attachments: [BitwardenSyncAttachment]
    public let attachmentByteCount: Int
    public let updatedAt: Date?
    public let favorite: Bool
    public let deletedAt: Date?
    public let cardholderName: String
    public let cardNumber: String
    public let cardExpiryMonth: String
    public let cardExpiryYear: String
    public let cardCode: String
    public let cardBrand: String
    public let identityFullName: String
    public let identityDocumentNumber: String
    public let identityIssuer: String
    public let identityCountry: String
    public let passkeyRelyingPartyID: String
    public let passkeyRelyingPartyName: String
    public let passkeyCredentialID: String
    public let passkeyUserHandle: String
    public let passkeyPublicKeyCOSE: String
    public let passkeyPrivateKeyReference: String
    public let passkeyPublicKeyAlgorithm: String
    public let passkeyCounter: String
    public let passkeyDiscoverable: Bool
    public let passkeyCreationDate: String
    public let sshPublicKey: String
    public let sshPrivateKey: String
    public let sshKeyFingerprint: String

    public init(
        remoteID: String,
        kind: BitwardenSyncItemKind,
        title: String,
        username: String = "",
        url: String = "",
        password: String? = nil,
        totpSecret: String? = nil,
        notes: String? = nil,
        folderID: String? = nil,
        folderName: String? = nil,
        collectionNames: [String] = [],
        organizationID: String? = nil,
        collectionIDs: [String] = [],
        customFields: [BitwardenSyncCustomField] = [],
        attachments: [BitwardenSyncAttachment] = [],
        attachmentByteCount: Int = 0,
        updatedAt: Date? = nil,
        favorite: Bool = false,
        deletedAt: Date? = nil,
        cardholderName: String = "",
        cardNumber: String = "",
        cardExpiryMonth: String = "",
        cardExpiryYear: String = "",
        cardCode: String = "",
        cardBrand: String = "",
        identityFullName: String = "",
        identityDocumentNumber: String = "",
        identityIssuer: String = "",
        identityCountry: String = "",
        passkeyRelyingPartyID: String = "",
        passkeyRelyingPartyName: String = "",
        passkeyCredentialID: String = "",
        passkeyUserHandle: String = "",
        passkeyPublicKeyCOSE: String = "",
        passkeyPrivateKeyReference: String = "",
        passkeyPublicKeyAlgorithm: String = "",
        passkeyCounter: String = "",
        passkeyDiscoverable: Bool = true,
        passkeyCreationDate: String = "",
        sshPublicKey: String = "",
        sshPrivateKey: String = "",
        sshKeyFingerprint: String = ""
    ) {
        self.remoteID = remoteID
        self.kind = kind
        self.title = title
        self.username = username
        self.url = url
        self.password = password
        self.totpSecret = totpSecret
        self.notes = notes
        self.folderID = folderID
        self.folderName = folderName
        self.collectionNames = collectionNames
        self.organizationID = organizationID
        self.collectionIDs = collectionIDs
        self.customFields = customFields
        self.attachments = attachments
        self.attachmentByteCount = attachments.isEmpty ? attachmentByteCount : attachments.reduce(0) { $0 + $1.byteCount }
        self.updatedAt = updatedAt
        self.favorite = favorite
        self.deletedAt = deletedAt
        self.cardholderName = cardholderName
        self.cardNumber = cardNumber
        self.cardExpiryMonth = cardExpiryMonth
        self.cardExpiryYear = cardExpiryYear
        self.cardCode = cardCode
        self.cardBrand = cardBrand
        self.identityFullName = identityFullName
        self.identityDocumentNumber = identityDocumentNumber
        self.identityIssuer = identityIssuer
        self.identityCountry = identityCountry
        self.passkeyRelyingPartyID = passkeyRelyingPartyID
        self.passkeyRelyingPartyName = passkeyRelyingPartyName
        self.passkeyCredentialID = passkeyCredentialID
        self.passkeyUserHandle = passkeyUserHandle
        self.passkeyPublicKeyCOSE = passkeyPublicKeyCOSE
        self.passkeyPrivateKeyReference = passkeyPrivateKeyReference
        self.passkeyPublicKeyAlgorithm = passkeyPublicKeyAlgorithm
        self.passkeyCounter = passkeyCounter
        self.passkeyDiscoverable = passkeyDiscoverable
        self.passkeyCreationDate = passkeyCreationDate
        self.sshPublicKey = sshPublicKey
        self.sshPrivateKey = sshPrivateKey
        self.sshKeyFingerprint = sshKeyFingerprint
    }

    /// 与 `BitwardenLocalItemSyncItem.syncFingerprint` 使用完全相同的字段顺序与分隔符，
    /// 因此可以直接比较「远端内容」与「本地上次同步内容」。
    public var syncFingerprint: String {
        [
            kind.rawValue,
            title,
            username,
            url,
            password ?? "",
            totpSecret ?? "",
            notes ?? "",
            folderID ?? "",
            folderName ?? "",
            favorite ? "true" : "false",
            cardholderName,
            cardNumber,
            cardExpiryMonth,
            cardExpiryYear,
            cardCode,
            cardBrand,
            identityFullName,
            identityDocumentNumber,
            identityIssuer,
            identityCountry,
            passkeyRelyingPartyID,
            passkeyRelyingPartyName,
            passkeyCredentialID,
            passkeyUserHandle,
            passkeyPublicKeyCOSE,
            passkeyPrivateKeyReference,
            passkeyPublicKeyAlgorithm,
            passkeyCounter,
            passkeyDiscoverable ? "true" : "false",
            passkeyCreationDate,
            sshPublicKey,
            sshPrivateKey,
            sshKeyFingerprint
        ].joined(separator: "\u{1F}")
    }

    /// 组织 / 集合归属的只读摘要（不含字段值）。
    public var collectionSummary: String {
        var parts: [String] = []
        if organizationID != nil { parts.append("组织条目") }
        if !collectionNames.isEmpty { parts.append(collectionNames.joined(separator: "、")) }
        return parts.joined(separator: " · ")
    }

    public var redactedSummary: String {
        if deletedAt != nil {
            return [
                kind.displayName,
                sanitizedBitwardenTitle(title),
                "已删除",
                attachmentByteCount > 0 ? "\(attachmentByteCount) 字节附件" : ""
            ]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        }
        return [
            kind.displayName,
            sanitizedBitwardenTitle(title),
            sanitizedBitwardenText(username),
            attachmentByteCount > 0 ? "\(attachmentByteCount) 字节附件" : ""
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }
}

public struct BitwardenSendSyncItem: Sendable, Equatable, Identifiable {
    public var id: String { remoteID }

    public let remoteID: String
    public let title: String
    public let body: String
    public let notes: String?
    public let expiresAt: String
    public let maxViews: Int
    public let attachmentByteCount: Int
    public let updatedAt: Date?

    public init(
        remoteID: String,
        title: String,
        body: String,
        notes: String? = nil,
        expiresAt: String = "",
        maxViews: Int = 1,
        attachmentByteCount: Int = 0,
        updatedAt: Date? = nil
    ) {
        self.remoteID = remoteID
        self.title = title
        self.body = body
        self.notes = notes
        self.expiresAt = expiresAt
        self.maxViews = maxViews
        self.attachmentByteCount = attachmentByteCount
        self.updatedAt = updatedAt
    }

    public var redactedSummary: String {
        [
            "Send",
            sanitizedBitwardenTitle(title),
            "\(maxViews) 次",
            attachmentByteCount > 0 ? "\(attachmentByteCount) 字节附件" : ""
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }
}

public struct BitwardenSyncSnapshot: Sendable, Equatable {
    public enum PremiumSource: String, Sendable, Equatable, Codable {
        case none
        case account
        case organization
    }

    public let accountLabel: String
    public let revision: String
    public let premiumSource: PremiumSource
    public let folders: [BitwardenSyncFolder]
    public let collections: [BitwardenSyncCollection]
    public let items: [BitwardenSyncItem]
    public let sends: [BitwardenSendSyncItem]

    public init(
        accountLabel: String,
        revision: String,
        premiumSource: PremiumSource = .none,
        folders: [BitwardenSyncFolder] = [],
        collections: [BitwardenSyncCollection] = [],
        items: [BitwardenSyncItem] = [],
        sends: [BitwardenSendSyncItem] = []
    ) {
        self.accountLabel = accountLabel
        self.revision = revision
        self.premiumSource = premiumSource
        self.folders = folders
        self.collections = collections
        self.items = items
        self.sends = sends
    }

    public var isPremium: Bool {
        premiumSource != .none
    }

    public var redactedSummary: String {
        "Bitwarden \(sanitizedBitwardenText(accountLabel))：\(items.count) 个条目，\(sends.count) 个 Send"
    }
}

public enum BitwardenSyncMutation: Sendable, Equatable {
    case upsertFolder(localID: String, remoteID: String?, name: String)
    case deleteFolder(localID: String, remoteID: String?, name: String)
    case upsertCipher(item: BitwardenLocalItemSyncItem, remoteID: String?)
    case restoreCipher(localID: String, remoteID: String?, kind: BitwardenSyncItemKind, title: String)
    case deleteCipher(localID: String, remoteID: String?, kind: BitwardenSyncItemKind, title: String)
    case permanentlyDeleteCipher(localID: String, remoteID: String?, kind: BitwardenSyncItemKind, title: String)
    case upsertSend(
        localID: String,
        remoteID: String?,
        title: String,
        body: String,
        notes: String?,
        expiresAt: String,
        maxViews: Int
    )
    case upsertEncryptedSend(
        localID: String,
        remoteID: String?,
        key: String,
        name: String,
        notes: String?,
        text: String,
        deletionDate: String,
        expirationDate: String?,
        maxAccessCount: Int?
    )
    case upsertFileSend(
        localID: String,
        remoteID: String?,
        title: String,
        fileName: String,
        fileContent: Data,
        mediaType: String,
        notes: String?,
        expiresAt: String,
        maxViews: Int,
        password: String?,
        hideEmail: Bool
    )
    case deleteSend(localID: String, remoteID: String?, title: String)

    public var redactedSummary: String {
        switch self {
        case .upsertFolder(_, _, let name):
            "upsert Folder \(sanitizedBitwardenTitle(name))"
        case .deleteFolder(_, _, let name):
            "delete Folder \(sanitizedBitwardenTitle(name))"
        case .upsertCipher(let item, _):
            "upsert \(item.redactedSummary)"
        case .restoreCipher(_, _, let kind, let title):
            "restore \(kind.displayName) \(sanitizedBitwardenTitle(title))"
        case .deleteCipher(_, _, let kind, let title):
            "delete \(kind.displayName) \(sanitizedBitwardenTitle(title))"
        case .permanentlyDeleteCipher(_, _, let kind, let title):
            "permanently delete \(kind.displayName) \(sanitizedBitwardenTitle(title))"
        case .upsertSend(_, _, let title, _, _, _, let maxViews):
            "upsert Send \(sanitizedBitwardenTitle(title)) \(maxViews) 次"
        case .upsertEncryptedSend:
            "upsert encrypted Send"
        case .upsertFileSend(_, _, let title, let fileName, let fileContent, _, _, _, let maxViews, _, _):
            "upsert File Send \(sanitizedBitwardenTitle(title)) \(sanitizedBitwardenTitle(fileName)) \(maxViews) 次 \(fileContent.count) 字节"
        case .deleteSend(_, _, let title):
            "delete Send \(sanitizedBitwardenTitle(title))"
        }
    }
}

public struct BitwardenLocalSendSyncItem: Sendable, Equatable, Identifiable {
    public var id: String { localID }

    public let localID: String
    public let title: String
    public let body: String
    public let notes: String?
    public let expiresAt: String
    public let maxViews: Int

    public init(
        localID: String,
        title: String,
        body: String,
        notes: String?,
        expiresAt: String,
        maxViews: Int
    ) {
        self.localID = localID
        self.title = title
        self.body = body
        self.notes = notes
        self.expiresAt = expiresAt
        self.maxViews = maxViews
    }

    public var syncFingerprint: String {
        [
            title,
            body,
            notes ?? "",
            expiresAt,
            String(maxViews)
        ].joined(separator: "\u{1F}")
    }
}

public struct BitwardenLocalItemSyncItem: Sendable, Equatable, Identifiable {
    public var id: String { localID }

    public let localID: String
    public let kind: BitwardenSyncItemKind
    public let title: String
    public let username: String
    public let url: String
    public let password: String?
    public let totpSecret: String?
    public let notes: String?
    public let folderID: String?
    public let folderName: String?
    public let favorite: Bool
    public let organizationID: String?
    public let collectionIDs: [String]
    public let cardholderName: String
    public let cardNumber: String
    public let cardExpiryMonth: String
    public let cardExpiryYear: String
    public let cardCode: String
    public let cardBrand: String
    public let identityFullName: String
    public let identityDocumentNumber: String
    public let identityIssuer: String
    public let identityCountry: String
    public let passkeyRelyingPartyID: String
    public let passkeyRelyingPartyName: String
    public let passkeyCredentialID: String
    public let passkeyUserHandle: String
    public let passkeyPublicKeyCOSE: String
    public let passkeyPrivateKeyReference: String
    public let passkeyPublicKeyAlgorithm: String
    public let passkeyCounter: String
    public let passkeyDiscoverable: Bool
    public let passkeyCreationDate: String
    public let sshPublicKey: String
    public let sshPrivateKey: String
    public let sshKeyFingerprint: String

    public init(
        localID: String,
        kind: BitwardenSyncItemKind,
        title: String,
        username: String = "",
        url: String = "",
        password: String? = nil,
        totpSecret: String? = nil,
        notes: String? = nil,
        folderID: String? = nil,
        folderName: String? = nil,
        favorite: Bool = false,
        organizationID: String? = nil,
        collectionIDs: [String] = [],
        cardholderName: String = "",
        cardNumber: String = "",
        cardExpiryMonth: String = "",
        cardExpiryYear: String = "",
        cardCode: String = "",
        cardBrand: String = "",
        identityFullName: String = "",
        identityDocumentNumber: String = "",
        identityIssuer: String = "",
        identityCountry: String = "",
        passkeyRelyingPartyID: String = "",
        passkeyRelyingPartyName: String = "",
        passkeyCredentialID: String = "",
        passkeyUserHandle: String = "",
        passkeyPublicKeyCOSE: String = "",
        passkeyPrivateKeyReference: String = "",
        passkeyPublicKeyAlgorithm: String = "",
        passkeyCounter: String = "",
        passkeyDiscoverable: Bool = true,
        passkeyCreationDate: String = "",
        sshPublicKey: String = "",
        sshPrivateKey: String = "",
        sshKeyFingerprint: String = ""
    ) {
        self.localID = localID
        self.kind = kind
        self.title = title
        self.username = username
        self.url = url
        self.password = password
        self.totpSecret = totpSecret
        self.notes = notes
        self.folderID = folderID
        self.folderName = folderName
        self.favorite = favorite
        self.organizationID = organizationID
        self.collectionIDs = collectionIDs
        self.cardholderName = cardholderName
        self.cardNumber = cardNumber
        self.cardExpiryMonth = cardExpiryMonth
        self.cardExpiryYear = cardExpiryYear
        self.cardCode = cardCode
        self.cardBrand = cardBrand
        self.identityFullName = identityFullName
        self.identityDocumentNumber = identityDocumentNumber
        self.identityIssuer = identityIssuer
        self.identityCountry = identityCountry
        self.passkeyRelyingPartyID = passkeyRelyingPartyID
        self.passkeyRelyingPartyName = passkeyRelyingPartyName
        self.passkeyCredentialID = passkeyCredentialID
        self.passkeyUserHandle = passkeyUserHandle
        self.passkeyPublicKeyCOSE = passkeyPublicKeyCOSE
        self.passkeyPrivateKeyReference = passkeyPrivateKeyReference
        self.passkeyPublicKeyAlgorithm = passkeyPublicKeyAlgorithm
        self.passkeyCounter = passkeyCounter
        self.passkeyDiscoverable = passkeyDiscoverable
        self.passkeyCreationDate = passkeyCreationDate
        self.sshPublicKey = sshPublicKey
        self.sshPrivateKey = sshPrivateKey
        self.sshKeyFingerprint = sshKeyFingerprint
    }

    public var syncFingerprint: String {
        [
            kind.rawValue,
            title,
            username,
            url,
            password ?? "",
            totpSecret ?? "",
            notes ?? "",
            folderID ?? "",
            folderName ?? "",
            favorite ? "true" : "false",
            cardholderName,
            cardNumber,
            cardExpiryMonth,
            cardExpiryYear,
            cardCode,
            cardBrand,
            identityFullName,
            identityDocumentNumber,
            identityIssuer,
            identityCountry,
            passkeyRelyingPartyID,
            passkeyRelyingPartyName,
            passkeyCredentialID,
            passkeyUserHandle,
            passkeyPublicKeyCOSE,
            passkeyPrivateKeyReference,
            passkeyPublicKeyAlgorithm,
            passkeyCounter,
            passkeyDiscoverable ? "true" : "false",
            passkeyCreationDate,
            sshPublicKey,
            sshPrivateKey,
            sshKeyFingerprint
        ].joined(separator: "\u{1F}")
    }

    public var redactedSummary: String {
        [
            kind.displayName,
            sanitizedBitwardenTitle(title),
            sanitizedBitwardenText(username)
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }
}

public struct BitwardenSendSyncState: Sendable, Equatable, Codable, Identifiable {
    public var id: String { localID }

    public let localID: String
    public let remoteID: String?
    public let lastSyncedFingerprint: String
    public let lastRemoteRevision: String?
    public let isDeleted: Bool

    public init(
        localID: String,
        remoteID: String?,
        lastSyncedFingerprint: String,
        lastRemoteRevision: String?,
        isDeleted: Bool = false
    ) {
        self.localID = localID
        self.remoteID = remoteID
        self.lastSyncedFingerprint = lastSyncedFingerprint
        self.lastRemoteRevision = lastRemoteRevision
        self.isDeleted = isDeleted
    }

    public var redactedSummary: String {
        isDeleted ? "Send 同步状态 已删除" : "Send 同步状态 已关联"
    }
}

public struct BitwardenFolderSyncState: Sendable, Equatable, Codable, Identifiable {
    public var id: String { localID }

    public let localID: String
    public let remoteID: String?
    public let name: String
    public let lastSyncedFingerprint: String
    public let lastRemoteRevision: String?
    public let isDeleted: Bool

    public init(
        localID: String,
        remoteID: String?,
        name: String,
        lastSyncedFingerprint: String,
        lastRemoteRevision: String?,
        isDeleted: Bool = false
    ) {
        self.localID = localID
        self.remoteID = remoteID
        self.name = name
        self.lastSyncedFingerprint = lastSyncedFingerprint
        self.lastRemoteRevision = lastRemoteRevision
        self.isDeleted = isDeleted
    }

    public var redactedSummary: String {
        isDeleted ? "Folder 同步状态 已删除" : "Folder \(sanitizedBitwardenTitle(name)) 同步状态 已关联"
    }
}

public struct BitwardenItemSyncState: Sendable, Equatable, Codable, Identifiable {
    public var id: String { localID }

    public let localID: String
    public let remoteID: String?
    public let kind: BitwardenSyncItemKind
    public let lastSyncedFingerprint: String
    public let lastRemoteRevision: String?
    public let isDeleted: Bool
    /// 上一次同步时远端条目的内容指纹。为 nil 表示旧版本写入的状态，
    /// 此时回退到 `lastRemoteRevision`（远端 updatedAt）判断远端是否变化。
    public let lastRemoteFingerprint: String?
    /// 组织归属与集合 ID，用于推送时保留远端归属，避免把组织条目写成个人条目。
    public let organizationID: String?
    public let collectionIDs: [String]?

    public init(
        localID: String,
        remoteID: String?,
        kind: BitwardenSyncItemKind,
        lastSyncedFingerprint: String,
        lastRemoteRevision: String?,
        isDeleted: Bool = false,
        lastRemoteFingerprint: String? = nil,
        organizationID: String? = nil,
        collectionIDs: [String]? = nil
    ) {
        self.localID = localID
        self.remoteID = remoteID
        self.kind = kind
        self.lastSyncedFingerprint = lastSyncedFingerprint
        self.lastRemoteRevision = lastRemoteRevision
        self.isDeleted = isDeleted
        self.lastRemoteFingerprint = lastRemoteFingerprint
        self.organizationID = organizationID
        self.collectionIDs = collectionIDs
    }

    public var redactedSummary: String {
        isDeleted ? "\(kind.displayName) 同步状态 已删除" : "\(kind.displayName) 同步状态 已关联"
    }
}

public enum BitwardenSyncConflictReason: Sendable, Equatable {
    case bothModified
    case remoteDeleted
    case localDeleted

    public var displayName: String {
        switch self {
        case .bothModified:
            "本地和远端都已修改"
        case .remoteDeleted:
            "远端已删除"
        case .localDeleted:
            "本地已删除"
        }
    }
}

public struct BitwardenSyncConflict: Sendable, Equatable {
    public let localID: String?
    public let remoteID: String?
    public let title: String
    public let reason: BitwardenSyncConflictReason

    public init(
        localID: String? = nil,
        remoteID: String? = nil,
        title: String,
        reason: BitwardenSyncConflictReason
    ) {
        self.localID = localID
        self.remoteID = remoteID
        self.title = title
        self.reason = reason
    }

    public var redactedSummary: String {
        "冲突 \(sanitizedBitwardenTitle(title))：\(reason.displayName)"
    }
}

public struct BitwardenSyncPushResult: Sendable, Equatable {
    public let acceptedMutationCount: Int
    public let conflicts: [BitwardenSyncConflict]
    public let revision: String
    public let assignedRemoteIDs: [String: String]

    public init(
        acceptedMutationCount: Int,
        conflicts: [BitwardenSyncConflict] = [],
        revision: String = "",
        assignedRemoteIDs: [String: String] = [:]
    ) {
        self.acceptedMutationCount = acceptedMutationCount
        self.conflicts = conflicts
        self.revision = revision
        self.assignedRemoteIDs = assignedRemoteIDs
    }

    public var redactedSummary: String {
        "Bitwarden 已推送 \(acceptedMutationCount) 个变更，\(conflicts.count) 个冲突"
    }
}
