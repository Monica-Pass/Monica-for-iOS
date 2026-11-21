import Foundation
import CryptoKit
import MonicaMDBX
import MonicaStorageTwofish
import ZIPFoundation
import argon2
import zlib

public enum MonicaStorageBaseline {
    public static let primaryStore = "MDBX"
}

public enum VaultSource: String, Sendable, Equatable, CaseIterable {
    case mdbx
    case keepass
    case bitwarden
    case androidBackup
    case csvImport

    public var displayName: String {
        switch self {
        case .mdbx:
            return "MDBX"
        case .keepass:
            return "KeePass"
        case .bitwarden:
            return "Bitwarden"
        case .androidBackup:
            return "移动端备份"
        case .csvImport:
            return "CSV 导入"
        }
    }

    public static let phaseOneSources: [VaultSource] = [.mdbx]
    public static let longTermSources: [VaultSource] = [
        .mdbx,
        .keepass,
        .bitwarden,
        .androidBackup,
        .csvImport
    ]
}

public enum UnifiedVaultItemKind: String, Sendable, Equatable, Hashable, CaseIterable {
    case login
    case totp
    case note
    case card
    case identity
    case passkey
    case sshKey
    case apiToken
    case wifi
    case sso
    case send
    case attachmentRef
    case steam
    case barcode
    case billingAddress
    case paymentAccount
    case gpgKey

    public var displayName: String {
        switch self {
        case .login:
            return "密码"
        case .totp:
            return "验证器"
        case .note:
            return "笔记"
        case .card:
            return "银行卡"
        case .identity:
            return "证件"
        case .passkey:
            return "通行密钥"
        case .sshKey:
            return "SSH 密钥"
        case .apiToken:
            return "API Token"
        case .wifi:
            return "Wi-Fi"
        case .sso:
            return "SSO"
        case .send:
            return "安全发送"
        case .attachmentRef:
            return "附件"
        case .steam:
            return "Steam"
        case .barcode:
            return "条码"
        case .billingAddress:
            return "账单地址"
        case .paymentAccount:
            return "支付账户"
        case .gpgKey:
            return "GPG 密钥"
        }
    }

    public static let phaseOneKinds: [UnifiedVaultItemKind] = [
        .login,
        .totp,
        .note,
        .card,
        .identity
    ]

    public static let fullAndroidParityKinds: [UnifiedVaultItemKind] = [
        .login,
        .card,
        .identity,
        .totp,
        .passkey,
        .note,
        .sshKey,
        .apiToken,
        .wifi,
        .sso,
        .send,
        .attachmentRef,
        .steam,
        .barcode,
        .billingAddress,
        .paymentAccount,
        .gpgKey
    ]
}

public struct UnifiedVaultItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let source: VaultSource
    public let kind: UnifiedVaultItemKind
    public let title: String
    public let subtitle: String
    public let searchableText: String
    public let isFavorite: Bool
    public let isDeleted: Bool

    public init(
        id: String,
        source: VaultSource,
        kind: UnifiedVaultItemKind,
        title: String,
        subtitle: String,
        searchableText: String,
        isFavorite: Bool,
        isDeleted: Bool
    ) {
        self.id = id
        self.source = source
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.searchableText = searchableText
        self.isFavorite = isFavorite
        self.isDeleted = isDeleted
    }

    public var listTitle: String { title }
    public var listSubtitle: String { subtitle }

    public func matches(_ query: String) -> Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return true
        }
        return searchableText.localizedCaseInsensitiveContains(trimmedQuery)
    }
}

public protocol ItemRepository {
    func listItems(
        source: VaultSource?,
        kinds: [UnifiedVaultItemKind],
        includeDeleted: Bool
    ) throws -> [UnifiedVaultItem]

    func deleteItem(_ item: UnifiedVaultItem) throws
    func restoreItem(_ item: UnifiedVaultItem) throws
    func setFavorite(_ favorite: Bool, for item: UnifiedVaultItem) throws -> UnifiedVaultItem
}

public enum LocalVaultState: Sendable, Equatable {
    case unlocked
    case locked
}

public enum LocalVaultRepositoryError: Error, Sendable, Equatable, LocalizedError {
    case emptyVaultName
    case emptyPassword
    case emptySecurityKeyMaterial
    case currentPasswordMismatch
    case passwordUnchanged
    case emptyProjectTitle
    case emptyEntryTitle
    case vaultUnavailable
    case projectNotFound
    case projectNotEmpty
    case unsupportedEntryType(UnifiedVaultItemKind)
    case invalidEntryPayload

    public var errorDescription: String? {
        switch self {
        case .emptyVaultName:
            return "保险库名称不能为空。"
        case .emptyPassword:
            return "保险库密码不能为空。"
        case .emptySecurityKeyMaterial:
            return "保险库安全密钥材料不能为空。"
        case .currentPasswordMismatch:
            return "当前主密码不正确。"
        case .passwordUnchanged:
            return "新主密码不能与当前主密码相同。"
        case .emptyProjectTitle:
            return "项目标题不能为空。"
        case .emptyEntryTitle:
            return "条目标题不能为空。"
        case .vaultUnavailable:
            return "保险库会话已不可用。"
        case .projectNotFound:
            return "分类不存在。"
        case .projectNotEmpty:
            return "分类内仍有条目，无法直接删除。"
        case .unsupportedEntryType(let kind):
            return "\(kind.displayName) 还没有接入当前 MDBX 引擎。"
        case .invalidEntryPayload:
            return "保险库条目 payload 无法解析。"
        }
    }
}

public struct LocalVaultDescriptor: Sendable, Equatable {
    public let fileURL: URL
    public let displayName: String

    public init(fileURL: URL, displayName: String) {
        self.fileURL = fileURL
        self.displayName = displayName
    }
}

public struct LocalVaultHandle: Sendable, Equatable {
    public let vaultID: String
    public let deviceID: String

    public init(vaultID: String, deviceID: String) {
        self.vaultID = vaultID
        self.deviceID = deviceID
    }
}

public struct LocalVaultSession: Sendable, Equatable {
    public let descriptor: LocalVaultDescriptor
    public let handle: LocalVaultHandle
    public let state: LocalVaultState

    public init(
        descriptor: LocalVaultDescriptor,
        handle: LocalVaultHandle,
        state: LocalVaultState
    ) {
        self.descriptor = descriptor
        self.handle = handle
        self.state = state
    }
}

public protocol LocalVaultEngine {
    func createVault(
        at fileURL: URL,
        password: String,
        deviceID: String
    ) throws -> LocalVaultHandle

    func openVault(
        at fileURL: URL,
        password: String,
        deviceID: String
    ) throws -> LocalVaultHandle

    func openVaultWithSecurityKey(
        at fileURL: URL,
        securityKeyMaterial: Data,
        deviceID: String
    ) throws -> LocalVaultHandle

    func setupLocalSecurityKeyUnlock(
        in handle: LocalVaultHandle,
        securityKeyMaterial: Data
    ) throws

    /// 只校验主密码，不登记新会话，也不改变已经在使用的句柄。
    ///
    /// 修改主密码前需要先确认旧口令；实现必须在一个独立的临时连接上验证，
    /// 让正在使用的会话在验证失败时保持原样。
    func verifyMasterPassword(
        at fileURL: URL,
        password: String,
        deviceID: String
    ) throws -> LocalVaultHandle

    func resetMasterPassword(
        in handle: LocalVaultHandle,
        newPassword: String
    ) throws

    func closeVault(_ handle: LocalVaultHandle)

    func createProject(
        in handle: LocalVaultHandle,
        title: String
    ) throws -> LocalVaultProject

    func listProjects(
        in handle: LocalVaultHandle
    ) throws -> [LocalVaultProject]

    func renameProject(
        in handle: LocalVaultHandle,
        projectID: String,
        title: String
    ) throws -> LocalVaultProject

    func deleteProject(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws

    func createLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalLoginEntryDraft
    ) throws -> LocalLoginEntry

    func listLoginEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalLoginEntry]

    func updateLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalLoginEntryDraft
    ) throws -> LocalLoginEntry

    func setLoginEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalLoginEntry

    func setLoginEntryIcon(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        icon: String?
    ) throws -> LocalLoginEntry

    func deleteLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedLoginEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalLoginEntry]

    func restoreLoginEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalLoginEntry

    func createNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalNoteEntryDraft
    ) throws -> LocalNoteEntry

    func listNoteEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalNoteEntry]

    func updateNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalNoteEntryDraft
    ) throws -> LocalNoteEntry

    func setNoteEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalNoteEntry

    func deleteNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedNoteEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalNoteEntry]

    func restoreNoteEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalNoteEntry

    func createTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalTotpEntryDraft
    ) throws -> LocalTotpEntry

    func listTotpEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalTotpEntry]

    func updateTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalTotpEntryDraft
    ) throws -> LocalTotpEntry

    func setTotpEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalTotpEntry

    func deleteTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedTotpEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalTotpEntry]

    func restoreTotpEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalTotpEntry

    func createCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalCardEntryDraft
    ) throws -> LocalCardEntry

    func listCardEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalCardEntry]

    func updateCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalCardEntryDraft
    ) throws -> LocalCardEntry

    func setCardEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalCardEntry

    func deleteCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedCardEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalCardEntry]

    func restoreCardEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalCardEntry

    func createIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalIdentityEntryDraft
    ) throws -> LocalIdentityEntry

    func listIdentityEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalIdentityEntry]

    func updateIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalIdentityEntryDraft
    ) throws -> LocalIdentityEntry

    func setIdentityEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalIdentityEntry

    func deleteIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedIdentityEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalIdentityEntry]

    func restoreIdentityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalIdentityEntry

    func createPasskeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalPasskeyEntryDraft
    ) throws -> LocalPasskeyEntry

    func listPasskeyEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalPasskeyEntry]

    func updatePasskeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalPasskeyEntryDraft
    ) throws -> LocalPasskeyEntry

    func setPasskeyEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalPasskeyEntry

    func deletePasskeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedPasskeyEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalPasskeyEntry]

    func restorePasskeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalPasskeyEntry

    func createSshKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalSshKeyEntryDraft
    ) throws -> LocalSshKeyEntry

    func listSshKeyEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSshKeyEntry]

    func updateSshKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalSshKeyEntryDraft
    ) throws -> LocalSshKeyEntry

    func setSshKeyEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalSshKeyEntry

    func deleteSshKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedSshKeyEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSshKeyEntry]

    func restoreSshKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalSshKeyEntry

    func createGPGKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalGPGKeyEntryDraft
    ) throws -> LocalGPGKeyEntry

    func listGPGKeyEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalGPGKeyEntry]

    func updateGPGKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalGPGKeyEntryDraft
    ) throws -> LocalGPGKeyEntry

    func setGPGKeyEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalGPGKeyEntry

    func deleteGPGKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedGPGKeyEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalGPGKeyEntry]

    func restoreGPGKeyEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalGPGKeyEntry

    func createApiTokenEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalApiTokenEntryDraft
    ) throws -> LocalApiTokenEntry

    func listApiTokenEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalApiTokenEntry]

    func updateApiTokenEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalApiTokenEntryDraft
    ) throws -> LocalApiTokenEntry

    func setApiTokenEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalApiTokenEntry

    func deleteApiTokenEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedApiTokenEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalApiTokenEntry]

    func restoreApiTokenEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalApiTokenEntry

    func createWifiEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalWifiEntryDraft
    ) throws -> LocalWifiEntry

    func listWifiEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalWifiEntry]

    func updateWifiEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalWifiEntryDraft
    ) throws -> LocalWifiEntry

    func setWifiEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalWifiEntry

    func deleteWifiEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedWifiEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalWifiEntry]

    func restoreWifiEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalWifiEntry

    func createSSOEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalSSOEntryDraft
    ) throws -> LocalSSOEntry

    func listSSOEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSSOEntry]

    func updateSSOEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalSSOEntryDraft
    ) throws -> LocalSSOEntry

    func setSSOEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalSSOEntry

    func createBarcodeEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalBarcodeEntryDraft
    ) throws -> LocalBarcodeEntry

    func listBarcodeEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalBarcodeEntry]

    func updateBarcodeEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalBarcodeEntryDraft
    ) throws -> LocalBarcodeEntry

    func setBarcodeEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalBarcodeEntry

    func deleteSSOEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func deleteBarcodeEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedSSOEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSSOEntry]

    func restoreSSOEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalSSOEntry

    func createSteamEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalSteamEntryDraft
    ) throws -> LocalSteamEntry

    func listSteamEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSteamEntry]

    func updateSteamEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalSteamEntryDraft
    ) throws -> LocalSteamEntry

    func setSteamEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalSteamEntry

    func deleteSteamEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedSteamEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSteamEntry]

    func restoreSteamEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalSteamEntry

    func listDeletedBarcodeEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalBarcodeEntry]

    func restoreBarcodeEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalBarcodeEntry

    func createSendEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalSendEntryDraft
    ) throws -> LocalSendEntry

    func listSendEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSendEntry]

    func updateSendEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalSendEntryDraft
    ) throws -> LocalSendEntry

    func setSendEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalSendEntry

    func deleteSendEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedSendEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalSendEntry]

    func restoreSendEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalSendEntry

    func createAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String?,
        fileName: String,
        mediaType: String,
        originalSize: Int64,
        storedSize: Int64,
        contentHash: String,
        storageMode: String,
        source: String,
        downloadState: String,
        wrappedContentEncryptionKey: String?,
        localPath: String?
    ) throws -> LocalAttachmentMetadata

    func listAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalAttachmentMetadata]

    func updateAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String,
        attachmentID: String,
        entryID: String?,
        fileName: String,
        mediaType: String,
        originalSize: Int64,
        storedSize: Int64,
        contentHash: String,
        storageMode: String,
        source: String,
        downloadState: String,
        wrappedContentEncryptionKey: String?,
        localPath: String?
    ) throws -> LocalAttachmentMetadata

    func deleteAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String,
        attachmentID: String
    ) throws

    func listDeletedAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalAttachmentMetadata]

    func restoreAttachmentMetadata(
        in handle: LocalVaultHandle,
        projectID: String,
        attachmentID: String
    ) throws -> LocalAttachmentMetadata

    func createBillingAddressEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalBillingAddressEntryDraft
    ) throws -> LocalBillingAddressEntry

    func listBillingAddressEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalBillingAddressEntry]

    func updateBillingAddressEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalBillingAddressEntryDraft
    ) throws -> LocalBillingAddressEntry

    func setBillingAddressEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalBillingAddressEntry

    func deleteBillingAddressEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedBillingAddressEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalBillingAddressEntry]

    func restoreBillingAddressEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalBillingAddressEntry

    func createPaymentAccountEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        draft: LocalPaymentAccountEntryDraft
    ) throws -> LocalPaymentAccountEntry

    func listPaymentAccountEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalPaymentAccountEntry]

    func updatePaymentAccountEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        draft: LocalPaymentAccountEntryDraft
    ) throws -> LocalPaymentAccountEntry

    func setPaymentAccountEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        favorite: Bool
    ) throws -> LocalPaymentAccountEntry

    func deletePaymentAccountEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws

    func listDeletedPaymentAccountEntries(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [LocalPaymentAccountEntry]

    func restorePaymentAccountEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String
    ) throws -> LocalPaymentAccountEntry

    func moveEntry(
        in handle: LocalVaultHandle,
        kind: UnifiedVaultItemKind,
        entryID: String,
        fromProjectID: String,
        toProjectID: String
    ) throws -> LocalVaultMovedEntry

    /// 读取一个分类里所有条目的自定义字段/关联侧表，键是条目的稳定 itemID。
    func listItemExtras(
        in handle: LocalVaultHandle,
        projectID: String
    ) throws -> [String: VaultItemExtras]

    /// 写入（或更新）单个条目的侧表。返回归一化后的结果，调用方可以据此回填编辑器。
    func saveItemExtras(
        in handle: LocalVaultHandle,
        projectID: String,
        extras: VaultItemExtras
    ) throws -> VaultItemExtras

    /// 清空单个条目的侧表；条目本身不受影响。
    func deleteItemExtras(
        in handle: LocalVaultHandle,
        projectID: String,
        itemID: String
    ) throws

    /// 条目换分类时让侧表跟随，避免自定义字段/关联在移动后丢失。
    func moveItemExtras(
        in handle: LocalVaultHandle,
        itemID: String,
        fromProjectID: String,
        toProjectID: String
    ) throws

    /// 列出锚点工程里的文件夹层级记录（issue #27）。
    func listVaultFolderRecords(
        in handle: LocalVaultHandle,
        anchorProjectID: String
    ) throws -> [VaultFolderRecord]

    /// 写入（新增或覆盖）一条文件夹层级记录（issue #27）。
    func saveVaultFolderRecord(
        in handle: LocalVaultHandle,
        anchorProjectID: String,
        record: VaultFolderRecord
    ) throws

    /// 删除一条文件夹层级记录（issue #27）。
    func deleteVaultFolderRecord(
        in handle: LocalVaultHandle,
        anchorProjectID: String,
        folderID: String
    ) throws

    /// 列出锚点工程里的常用账号模板记录（issue #127）。
    func listAccountTemplates(
        in handle: LocalVaultHandle,
        anchorProjectID: String
    ) throws -> [AccountTemplate]

    /// 写入（新增或覆盖）一条常用账号模板记录（issue #127）。
    func saveAccountTemplate(
        in handle: LocalVaultHandle,
        anchorProjectID: String,
        template: AccountTemplate
    ) throws

    /// 删除一条常用账号模板记录（issue #127）。
    func deleteAccountTemplate(
        in handle: LocalVaultHandle,
        anchorProjectID: String,
        templateID: String
    ) throws
}

public extension LocalVaultEngine {
    func moveEntry(in handle: LocalVaultHandle, kind: UnifiedVaultItemKind, entryID: String, fromProjectID: String, toProjectID: String) throws -> LocalVaultMovedEntry { throw LocalVaultRepositoryError.unsupportedEntryType(kind) }

    func createBillingAddressEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalBillingAddressEntryDraft) throws -> LocalBillingAddressEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.billingAddress) }
    func listBillingAddressEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalBillingAddressEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.billingAddress) }
    func updateBillingAddressEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalBillingAddressEntryDraft) throws -> LocalBillingAddressEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.billingAddress) }
    func setBillingAddressEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalBillingAddressEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.billingAddress) }
    func deleteBillingAddressEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.billingAddress) }
    func listDeletedBillingAddressEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalBillingAddressEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.billingAddress) }
    func restoreBillingAddressEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalBillingAddressEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.billingAddress) }

    func createPaymentAccountEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalPaymentAccountEntryDraft) throws -> LocalPaymentAccountEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.paymentAccount) }
    func listPaymentAccountEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalPaymentAccountEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.paymentAccount) }
    func updatePaymentAccountEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalPaymentAccountEntryDraft) throws -> LocalPaymentAccountEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.paymentAccount) }
    func setPaymentAccountEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalPaymentAccountEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.paymentAccount) }
    func deletePaymentAccountEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.paymentAccount) }
    func listDeletedPaymentAccountEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalPaymentAccountEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.paymentAccount) }
    func restorePaymentAccountEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalPaymentAccountEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.paymentAccount) }

    func createPasskeyEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalPasskeyEntryDraft) throws -> LocalPasskeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.passkey) }
    func listPasskeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalPasskeyEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.passkey) }
    func updatePasskeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalPasskeyEntryDraft) throws -> LocalPasskeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.passkey) }
    func setPasskeyEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalPasskeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.passkey) }
    func deletePasskeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.passkey) }
    func listDeletedPasskeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalPasskeyEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.passkey) }
    func restorePasskeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalPasskeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.passkey) }

    func createSshKeyEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalSshKeyEntryDraft) throws -> LocalSshKeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.sshKey) }
    func listSshKeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSshKeyEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.sshKey) }
    func updateSshKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalSshKeyEntryDraft) throws -> LocalSshKeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.sshKey) }
    func setSshKeyEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalSshKeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.sshKey) }
    func deleteSshKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.sshKey) }
    func listDeletedSshKeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSshKeyEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.sshKey) }
    func restoreSshKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalSshKeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.sshKey) }
    func createGPGKeyEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalGPGKeyEntryDraft) throws -> LocalGPGKeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.gpgKey) }
    func listGPGKeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalGPGKeyEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.gpgKey) }
    func updateGPGKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalGPGKeyEntryDraft) throws -> LocalGPGKeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.gpgKey) }
    func setGPGKeyEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalGPGKeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.gpgKey) }
    func deleteGPGKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.gpgKey) }
    func listDeletedGPGKeyEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalGPGKeyEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.gpgKey) }
    func restoreGPGKeyEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalGPGKeyEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.gpgKey) }

    func createApiTokenEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalApiTokenEntryDraft) throws -> LocalApiTokenEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.apiToken) }
    func listApiTokenEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalApiTokenEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.apiToken) }
    func updateApiTokenEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalApiTokenEntryDraft) throws -> LocalApiTokenEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.apiToken) }
    func setApiTokenEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalApiTokenEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.apiToken) }
    func deleteApiTokenEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.apiToken) }
    func listDeletedApiTokenEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalApiTokenEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.apiToken) }
    func restoreApiTokenEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalApiTokenEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.apiToken) }

    func createWifiEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalWifiEntryDraft) throws -> LocalWifiEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.wifi) }
    func listWifiEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalWifiEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.wifi) }
    func updateWifiEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalWifiEntryDraft) throws -> LocalWifiEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.wifi) }
    func setWifiEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalWifiEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.wifi) }
    func deleteWifiEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.wifi) }
    func listDeletedWifiEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalWifiEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.wifi) }
    func restoreWifiEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalWifiEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.wifi) }

    func createSSOEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalSSOEntryDraft) throws -> LocalSSOEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.sso) }
    func listSSOEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSSOEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.sso) }
    func updateSSOEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalSSOEntryDraft) throws -> LocalSSOEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.sso) }
    func setSSOEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalSSOEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.sso) }
    func deleteSSOEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.sso) }
    func listDeletedSSOEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSSOEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.sso) }
    func restoreSSOEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalSSOEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.sso) }
    func createSteamEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalSteamEntryDraft) throws -> LocalSteamEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.steam) }
    func listSteamEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSteamEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.steam) }
    func updateSteamEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalSteamEntryDraft) throws -> LocalSteamEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.steam) }
    func setSteamEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalSteamEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.steam) }
    func deleteSteamEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.steam) }
    func listDeletedSteamEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSteamEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.steam) }
    func restoreSteamEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalSteamEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.steam) }

    func createBarcodeEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalBarcodeEntryDraft) throws -> LocalBarcodeEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.barcode) }
    func listBarcodeEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalBarcodeEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.barcode) }
    func updateBarcodeEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalBarcodeEntryDraft) throws -> LocalBarcodeEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.barcode) }
    func setBarcodeEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalBarcodeEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.barcode) }
    func deleteBarcodeEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.barcode) }
    func listDeletedBarcodeEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalBarcodeEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.barcode) }
    func restoreBarcodeEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalBarcodeEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.barcode) }

    func createSendEntry(in handle: LocalVaultHandle, projectID: String, draft: LocalSendEntryDraft) throws -> LocalSendEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.send) }
    func listSendEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSendEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.send) }
    func updateSendEntry(in handle: LocalVaultHandle, projectID: String, entryID: String, draft: LocalSendEntryDraft) throws -> LocalSendEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.send) }
    func setSendEntryFavorite(in handle: LocalVaultHandle, projectID: String, entryID: String, favorite: Bool) throws -> LocalSendEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.send) }
    func deleteSendEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.send) }
    func listDeletedSendEntries(in handle: LocalVaultHandle, projectID: String) throws -> [LocalSendEntry] { throw LocalVaultRepositoryError.unsupportedEntryType(.send) }
    func restoreSendEntry(in handle: LocalVaultHandle, projectID: String, entryID: String) throws -> LocalSendEntry { throw LocalVaultRepositoryError.unsupportedEntryType(.send) }

    func createAttachmentMetadata(in handle: LocalVaultHandle, projectID: String, entryID: String?, fileName: String, mediaType: String, originalSize: Int64, storedSize: Int64, contentHash: String, storageMode: String, source: String = "", downloadState: String = "", wrappedContentEncryptionKey: String? = nil, localPath: String? = nil) throws -> LocalAttachmentMetadata { throw LocalVaultRepositoryError.unsupportedEntryType(.attachmentRef) }
    func listAttachmentMetadata(in handle: LocalVaultHandle, projectID: String) throws -> [LocalAttachmentMetadata] { throw LocalVaultRepositoryError.unsupportedEntryType(.attachmentRef) }
    func updateAttachmentMetadata(in handle: LocalVaultHandle, projectID: String, attachmentID: String, entryID: String?, fileName: String, mediaType: String, originalSize: Int64, storedSize: Int64, contentHash: String, storageMode: String, source: String = "", downloadState: String = "", wrappedContentEncryptionKey: String? = nil, localPath: String? = nil) throws -> LocalAttachmentMetadata { throw LocalVaultRepositoryError.unsupportedEntryType(.attachmentRef) }
    func deleteAttachmentMetadata(in handle: LocalVaultHandle, projectID: String, attachmentID: String) throws { throw LocalVaultRepositoryError.unsupportedEntryType(.attachmentRef) }
    func listDeletedAttachmentMetadata(in handle: LocalVaultHandle, projectID: String) throws -> [LocalAttachmentMetadata] { throw LocalVaultRepositoryError.unsupportedEntryType(.attachmentRef) }
    func restoreAttachmentMetadata(in handle: LocalVaultHandle, projectID: String, attachmentID: String) throws -> LocalAttachmentMetadata { throw LocalVaultRepositoryError.unsupportedEntryType(.attachmentRef) }
}

public struct LocalVaultProject: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct LocalVaultMovedEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let kind: UnifiedVaultItemKind

    public init(id: String, title: String, kind: UnifiedVaultItemKind) {
        self.id = id
        self.title = title
        self.kind = kind
    }
}

// MARK: - Billing addresses & payment accounts

public struct LocalVaultRepository {
    private let engine: any LocalVaultEngine

    public init(engine: any LocalVaultEngine = MDBXLocalVaultEngine()) {
        self.engine = engine
    }

    public func entryRepository(for session: LocalVaultSession) -> LocalVaultEntryRepository {
        LocalVaultEntryRepository(session: session, engine: engine)
    }

    public func closeVault(for session: LocalVaultSession) {
        engine.closeVault(session.handle)
    }

    public func createVault(
        named name: String,
        in directoryURL: URL,
        password: String,
        deviceID: String
    ) throws -> LocalVaultSession {
        let displayName = try normalizedVaultName(name)
        try validatePassword(password)

        let fileURL = directoryURL.appendingPathComponent(
            "\(displayName).mdbx",
            isDirectory: false
        )
        let handle = try engine.createVault(
            at: fileURL,
            password: password,
            deviceID: deviceID
        )
        return LocalVaultSession(
            descriptor: LocalVaultDescriptor(fileURL: fileURL, displayName: displayName),
            handle: handle,
            state: .unlocked
        )
    }

    public func openVault(
        at fileURL: URL,
        password: String,
        deviceID: String
    ) throws -> LocalVaultSession {
        try validatePassword(password)

        let handle = try engine.openVault(
            at: fileURL,
            password: password,
            deviceID: deviceID
        )
        return LocalVaultSession(
            descriptor: LocalVaultDescriptor(
                fileURL: fileURL,
                displayName: fileURL.deletingPathExtension().lastPathComponent
            ),
            handle: handle,
            state: .unlocked
        )
    }

    public func openVaultWithSecurityKey(
        at fileURL: URL,
        securityKeyMaterial: Data,
        deviceID: String
    ) throws -> LocalVaultSession {
        try validateSecurityKeyMaterial(securityKeyMaterial)

        let handle = try engine.openVaultWithSecurityKey(
            at: fileURL,
            securityKeyMaterial: securityKeyMaterial,
            deviceID: deviceID
        )
        return LocalVaultSession(
            descriptor: LocalVaultDescriptor(
                fileURL: fileURL,
                displayName: fileURL.deletingPathExtension().lastPathComponent
            ),
            handle: handle,
            state: .unlocked
        )
    }

    public func setupLocalSecurityKeyUnlock(
        for session: LocalVaultSession,
        securityKeyMaterial: Data
    ) throws {
        try validateSecurityKeyMaterial(securityKeyMaterial)
        try engine.setupLocalSecurityKeyUnlock(
            in: session.handle,
            securityKeyMaterial: securityKeyMaterial
        )
    }

    public func resetMasterPassword(
        for session: LocalVaultSession,
        newPassword: String
    ) throws {
        try validatePassword(newPassword)
        try engine.resetMasterPassword(
            in: session.handle,
            newPassword: newPassword
        )
    }

    /// 在独立临时连接上校验主密码，不改变当前会话状态。
    ///
    /// 供「按数据类型清空」等高风险操作做二次确认：校验失败会抛
    /// `LocalVaultRepositoryError.currentPasswordMismatch`，调用方必须放弃删除。
    public func verifyMasterPassword(
        for session: LocalVaultSession,
        password: String
    ) throws {
        guard session.state == .unlocked else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        try validatePassword(password)
        let verifiedHandle = try engine.verifyMasterPassword(
            at: session.descriptor.fileURL,
            password: password,
            deviceID: session.handle.deviceID
        )
        guard verifiedHandle.vaultID == session.handle.vaultID else {
            throw LocalVaultRepositoryError.currentPasswordMismatch
        }
    }

    /// 修改主密码：先校验旧口令，再在同一个已解锁会话上重包裹 vault key。
    ///
    /// 设计要点：
    /// - 主密码只是 KEK，MDBX 里的记录/附件仍然由同一个随机 vault key 加密，所以这里
    ///   只替换 `unlock_methods` 里的 KDF 参数与 `wrapped_vault_key`，不做全库重加密。
    /// - 旧口令在**独立临时连接**上验证，失败时不触碰正在使用的句柄；引擎实现必须保证
    ///   临时连接不会被登记为当前会话（见 `verifyMasterPassword`）。
    /// - 真正的重包裹由引擎在单个事务里完成；中途掉电由 SQLite 回滚，旧口令仍然有效。
    /// - 注意：当前 FFI 的 `resetMasterPassword` 使用默认 KDF 档位（Multi），与「忘记密码」
    ///   重置路径一致；这只会影响新建 wrapped key 的 KDF 参数，不影响既有数据。
    public func changeMasterPassword(
        for session: LocalVaultSession,
        currentPassword: String,
        newPassword: String
    ) throws {
        guard session.state == .unlocked else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        try validatePassword(currentPassword)
        try validatePassword(newPassword)
        guard !newPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalVaultRepositoryError.emptyPassword
        }
        guard currentPassword != newPassword else {
            throw LocalVaultRepositoryError.passwordUnchanged
        }

        try verifyMasterPassword(for: session, password: currentPassword)

        try engine.resetMasterPassword(
            in: session.handle,
            newPassword: newPassword
        )
    }

    private func normalizedVaultName(_ name: String) throws -> String {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw LocalVaultRepositoryError.emptyVaultName
        }
        return normalized
    }

    private func validatePassword(_ password: String) throws {
        guard !password.isEmpty else {
            throw LocalVaultRepositoryError.emptyPassword
        }
    }

    private func validateSecurityKeyMaterial(_ securityKeyMaterial: Data) throws {
        guard !securityKeyMaterial.isEmpty else {
            throw LocalVaultRepositoryError.emptySecurityKeyMaterial
        }
    }
}

public struct LocalVaultEntryRepository {
    let session: LocalVaultSession
    let engine: any LocalVaultEngine

    public init(
        session: LocalVaultSession,
        engine: any LocalVaultEngine
    ) {
        self.session = session
        self.engine = engine
    }

    public func createProject(title: String) throws -> LocalVaultProject {
        let normalizedTitle = try normalizedProjectTitle(title)
        return try engine.createProject(
            in: session.handle,
            title: normalizedTitle
        )
    }

    public func listProjects() throws -> [LocalVaultProject] {
        try engine.listProjects(in: session.handle)
    }

    public func renameProject(
        projectID: String,
        title: String
    ) throws -> LocalVaultProject {
        let normalizedTitle = try normalizedProjectTitle(title)
        return try engine.renameProject(
            in: session.handle,
            projectID: projectID,
            title: normalizedTitle
        )
    }

    public func deleteProject(projectID: String) throws {
        try engine.deleteProject(
            in: session.handle,
            projectID: projectID
        )
    }

    public func moveEntry(
        kind: UnifiedVaultItemKind,
        entryID: String,
        fromProjectID: String,
        toProjectID: String
    ) throws -> LocalVaultMovedEntry {
        let moved = try engine.moveEntry(
            in: session.handle,
            kind: kind,
            entryID: entryID,
            fromProjectID: fromProjectID,
            toProjectID: toProjectID
        )
        // 侧表用稳定 itemID 关联，跟着条目一起换分类，避免移动后自定义字段/关联丢失。
        try engine.moveItemExtras(
            in: session.handle,
            itemID: entryID,
            fromProjectID: fromProjectID,
            toProjectID: toProjectID
        )
        return moved
    }

    private func normalizedProjectTitle(_ title: String) throws -> String {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw LocalVaultRepositoryError.emptyProjectTitle
        }
        return normalized
    }

    func normalizedEntryTitle(_ title: String) throws -> String {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw LocalVaultRepositoryError.emptyEntryTitle
        }
        return normalizedTitle
    }
}

public final class MDBXLocalVaultEngine: LocalVaultEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var vaults: [String: MonicaMDBXVault] = [:]
    private var projects: [String: [LocalVaultProject]] = [:]

    public init() {}

    public func createVault(
        at fileURL: URL,
        password: String,
        deviceID: String
    ) throws -> LocalVaultHandle {
        let vault = try MonicaMDBXRuntime.createVault(
            at: fileURL,
            password: password,
            deviceID: deviceID
        )
        let info = vault.info()
        store(vault, vaultID: info.vaultID)
        return LocalVaultHandle(vaultID: info.vaultID, deviceID: info.deviceID)
    }

    public func openVault(
        at fileURL: URL,
        password: String,
        deviceID: String
    ) throws -> LocalVaultHandle {
        let vault = try MonicaMDBXRuntime.openVault(
            at: fileURL,
            password: password,
            deviceID: deviceID
        )
        let info = vault.info()
        store(vault, vaultID: info.vaultID)
        return LocalVaultHandle(vaultID: info.vaultID, deviceID: info.deviceID)
    }

    public func openVaultWithSecurityKey(
        at fileURL: URL,
        securityKeyMaterial: Data,
        deviceID: String
    ) throws -> LocalVaultHandle {
        let vault = try MonicaMDBXRuntime.openVaultWithSecurityKey(
            at: fileURL,
            securityKeyMaterial: securityKeyMaterial,
            deviceID: deviceID
        )
        let info = vault.info()
        store(vault, vaultID: info.vaultID)
        return LocalVaultHandle(vaultID: info.vaultID, deviceID: info.deviceID)
    }

    /// 用临时连接校验主密码。
    ///
    /// 这里刻意**不**把这个连接登记进 `vaults`：同一个保险库的 vaultID 不变，一旦登记就会
    /// 覆盖正在使用的句柄，随后 `closeVault` 会把用户的活会话一起关掉。临时连接在函数返回
    /// 时随 ARC 释放，SQLite 的 WAL 允许它与现有连接并存。
    public func verifyMasterPassword(
        at fileURL: URL,
        password: String,
        deviceID: String
    ) throws -> LocalVaultHandle {
        do {
            let vault = try MonicaMDBXRuntime.openVault(
                at: fileURL,
                password: password,
                deviceID: deviceID
            )
            let info = vault.info()
            return LocalVaultHandle(vaultID: info.vaultID, deviceID: info.deviceID)
        } catch {
            throw Self.verificationError(from: error)
        }
    }

    private static func verificationError(from error: Error) -> Error {
        #if canImport(mdbx_ffiFFI)
        if let ffiError = error as? MdbxFfiError, case .Storage(let message) = ffiError {
            // 引擎对错误口令返回 StorageError::Validation("incorrect credential")，
            // 只有这种情形才转换成「当前主密码不正确」，其余错误（IO、schema 等）原样抛出。
            if message.localizedCaseInsensitiveContains("credential") {
                return LocalVaultRepositoryError.currentPasswordMismatch
            }
        }
        #endif
        return error
    }

    public func setupLocalSecurityKeyUnlock(
        in handle: LocalVaultHandle,
        securityKeyMaterial: Data
    ) throws {
        try vault(for: handle).setupLocalSecurityKeyUnlock(securityKeyMaterial)
    }

    public func resetMasterPassword(
        in handle: LocalVaultHandle,
        newPassword: String
    ) throws {
        try vault(for: handle).resetMasterPassword(newPassword)
    }

    public func closeVault(_ handle: LocalVaultHandle) {
        lock.lock()
        defer { lock.unlock() }
        vaults.removeValue(forKey: handle.vaultID)
        projects.removeValue(forKey: handle.vaultID)
    }

    public func createProject(
        in handle: LocalVaultHandle,
        title: String
    ) throws -> LocalVaultProject {
        let project = try vault(for: handle).createProject(title: title)
        let localProject = LocalVaultProject(id: project.id, title: project.title)
        lock.lock()
        projects[handle.vaultID, default: []].append(localProject)
        lock.unlock()
        return localProject
    }

    public func listProjects(in handle: LocalVaultHandle) throws -> [LocalVaultProject] {
        _ = try vault(for: handle)
        lock.lock()
        defer { lock.unlock() }
        return projects[handle.vaultID, default: []]
    }

    public func renameProject(
        in handle: LocalVaultHandle,
        projectID: String,
        title: String
    ) throws -> LocalVaultProject {
        _ = try vault(for: handle)
        lock.lock()
        defer { lock.unlock() }
        guard let index = projects[handle.vaultID, default: []].firstIndex(where: { $0.id == projectID }) else {
            throw LocalVaultRepositoryError.projectNotFound
        }
        let renamed = LocalVaultProject(id: projectID, title: title)
        projects[handle.vaultID, default: []][index] = renamed
        return renamed
    }

    public func deleteProject(in handle: LocalVaultHandle, projectID: String) throws {
        _ = try vault(for: handle)
        guard try !projectContainsEntries(handle: handle, projectID: projectID) else {
            throw LocalVaultRepositoryError.projectNotEmpty
        }
        lock.lock()
        defer { lock.unlock() }
        guard projects[handle.vaultID, default: []].contains(where: { $0.id == projectID }) else {
            throw LocalVaultRepositoryError.projectNotFound
        }
        projects[handle.vaultID, default: []].removeAll { $0.id == projectID }
    }

    public func moveEntry(
        in handle: LocalVaultHandle,
        kind: UnifiedVaultItemKind,
        entryID: String,
        fromProjectID: String,
        toProjectID: String
    ) throws -> LocalVaultMovedEntry {
        switch kind {
        case .login:
            let entry = try vault(for: handle).moveLoginEntry(
                projectID: fromProjectID,
                entryID: entryID,
                targetProjectID: toProjectID
            )
            return LocalVaultMovedEntry(id: entry.id, title: entry.title, kind: kind)
        case .note:
            let entry = try vault(for: handle).moveNoteEntry(
                projectID: fromProjectID,
                entryID: entryID,
                targetProjectID: toProjectID
            )
            return LocalVaultMovedEntry(id: entry.id, title: entry.title, kind: kind)
        case .totp:
            let entry = try vault(for: handle).moveTotpEntry(
                projectID: fromProjectID,
                entryID: entryID,
                targetProjectID: toProjectID
            )
            return LocalVaultMovedEntry(id: entry.id, title: entry.title, kind: kind)
        case .card:
            let entry = try vault(for: handle).moveCardEntry(
                projectID: fromProjectID,
                entryID: entryID,
                targetProjectID: toProjectID
            )
            return LocalVaultMovedEntry(id: entry.id, title: entry.title, kind: kind)
        case .identity:
            let entry = try vault(for: handle).moveIdentityEntry(
                projectID: fromProjectID,
                entryID: entryID,
                targetProjectID: toProjectID
            )
            return LocalVaultMovedEntry(id: entry.id, title: entry.title, kind: kind)
        case .passkey, .sshKey, .apiToken, .wifi, .sso, .barcode, .send, .attachmentRef, .steam, .billingAddress, .paymentAccount, .gpgKey:
            let mapping = parityMoveMapping(for: kind)
            let entry = try moveParityEntry(
                in: handle,
                projectID: fromProjectID,
                entryID: entryID,
                entryType: mapping.entryType,
                kind: mapping.kind,
                targetProjectID: toProjectID
            )
            return LocalVaultMovedEntry(id: entry.id, title: entry.title, kind: kind)
        }
    }

    private func store(_ vault: MonicaMDBXVault, vaultID: String) {
        lock.lock()
        defer { lock.unlock() }
        vaults[vaultID] = vault
        projects[vaultID, default: []] = projects[vaultID, default: []]
    }

    func vault(for handle: LocalVaultHandle) throws -> MonicaMDBXVault {
        lock.lock()
        defer { lock.unlock() }
        guard let vault = vaults[handle.vaultID] else {
            throw LocalVaultRepositoryError.vaultUnavailable
        }
        return vault
    }

    private func projectContainsEntries(handle: LocalVaultHandle, projectID: String) throws -> Bool {
        try !listLoginEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedLoginEntries(in: handle, projectID: projectID).isEmpty
            || !listNoteEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedNoteEntries(in: handle, projectID: projectID).isEmpty
            || !listTotpEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedTotpEntries(in: handle, projectID: projectID).isEmpty
            || !listCardEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedCardEntries(in: handle, projectID: projectID).isEmpty
            || !listIdentityEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedIdentityEntries(in: handle, projectID: projectID).isEmpty
            || !listPasskeyEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedPasskeyEntries(in: handle, projectID: projectID).isEmpty
            || !listSshKeyEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedSshKeyEntries(in: handle, projectID: projectID).isEmpty
            || !listApiTokenEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedApiTokenEntries(in: handle, projectID: projectID).isEmpty
            || !listWifiEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedWifiEntries(in: handle, projectID: projectID).isEmpty
            || !listSSOEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedSSOEntries(in: handle, projectID: projectID).isEmpty
            || !listBarcodeEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedBarcodeEntries(in: handle, projectID: projectID).isEmpty
            || !listSendEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedSendEntries(in: handle, projectID: projectID).isEmpty
            || !listAttachmentMetadata(in: handle, projectID: projectID).isEmpty
            || !listDeletedAttachmentMetadata(in: handle, projectID: projectID).isEmpty
            || !listGPGKeyEntries(in: handle, projectID: projectID).isEmpty
            || !listDeletedGPGKeyEntries(in: handle, projectID: projectID).isEmpty
    }

    func createParityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryType: String,
        kind: String,
        title: String,
        payload: [String: Any]
    ) throws -> MonicaMDBXParityEntry {
        try vault(for: handle).createParityEntry(
            projectID: projectID,
            entryType: entryType,
            kind: kind,
            title: title,
            payloadJSON: parityPayloadJSON(payload)
        )
    }

    func listParityEntries(
        in handle: LocalVaultHandle,
        projectID: String,
        entryType: String,
        kind: String
    ) throws -> [MonicaMDBXParityEntry] {
        try vault(for: handle).listParityEntries(projectID: projectID, entryType: entryType, kind: kind)
    }

    func listDeletedParityEntries(
        in handle: LocalVaultHandle,
        projectID: String,
        entryType: String,
        kind: String
    ) throws -> [MonicaMDBXParityEntry] {
        try vault(for: handle).listDeletedParityEntries(projectID: projectID, entryType: entryType, kind: kind)
    }

    func updateParityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        entryType: String,
        kind: String,
        title: String,
        payload: [String: Any]
    ) throws -> MonicaMDBXParityEntry {
        try vault(for: handle).updateParityEntry(
            projectID: projectID,
            entryID: entryID,
            entryType: entryType,
            kind: kind,
            title: title,
            payloadJSON: parityPayloadJSON(payload)
        )
    }

    func setParityEntryFavorite(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        entryType: String,
        kind: String,
        favorite: Bool
    ) throws -> MonicaMDBXParityEntry {
        try vault(for: handle).setParityEntryFavorite(
            projectID: projectID,
            entryID: entryID,
            entryType: entryType,
            kind: kind,
            favorite: favorite
        )
    }

    func deleteParityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        entryType: String,
        kind: String
    ) throws {
        try vault(for: handle).deleteParityEntry(
            projectID: projectID,
            entryID: entryID,
            entryType: entryType,
            kind: kind
        )
    }

    func restoreParityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        entryType: String,
        kind: String
    ) throws -> MonicaMDBXParityEntry {
        try vault(for: handle).restoreParityEntry(
            projectID: projectID,
            entryID: entryID,
            entryType: entryType,
            kind: kind
        )
    }

    func moveParityEntry(
        in handle: LocalVaultHandle,
        projectID: String,
        entryID: String,
        entryType: String,
        kind: String,
        targetProjectID: String
    ) throws -> MonicaMDBXParityEntry {
        try vault(for: handle).moveParityEntry(
            projectID: projectID,
            entryID: entryID,
            entryType: entryType,
            kind: kind,
            targetProjectID: targetProjectID
        )
    }

    private func parityMoveMapping(for kind: UnifiedVaultItemKind) -> (entryType: String, kind: String) {
        switch kind {
        case .passkey:
            return ("passkey", "passkey")
        case .sshKey:
            return ("ssh-key", "ssh-key")
        case .apiToken:
            return ("api-token", "api-token")
        case .wifi:
            return ("document-ref", "wifi")
        case .sso:
            return ("document-ref", "sso")
        case .barcode:
            return ("document-ref", "barcode")
        case .send:
            return ("document-ref", "send")
        case .attachmentRef:
            return ("document-ref", "attachment-ref")
        case .steam:
            return ("document-ref", "steam")
        case .billingAddress:
            return ("document-ref", "billing-address")
        case .paymentAccount:
            return ("document-ref", "payment-account")
        case .gpgKey:
            return ("document-ref", "gpg-key")
        case .login, .totp, .note, .card, .identity:
            preconditionFailure("Core entry kinds do not use parity move mapping.")
        }
    }

    private func parityPayloadJSON(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        return json
    }

    // MARK: - Item extras (自定义字段 + 关联条目)

    // MARK: - 文件夹层级侧表（issue #27）
    //
    // 文件夹的 parentID 等元数据放在一个隐藏的「锚点工程」里，每条记录一个
    // ParityEntry；记录随保险库加密，且不需要知道每个文件夹的 projectID
    // 就能一次列出整棵树。

    // MARK: - 常用账号模板侧表（issue #127）
    //
    // 模板和文件夹记录共用隐藏锚点工程（同一个 project），但用独立的 entryKind。
    // 侧表记录的 title 存的是 templateID，正文才是模板 JSON——和文件夹侧表一致。

}

extension MonicaMDBXParityEntry {
    func payloadDictionary() throws -> [String: Any] {
        guard let data = payloadJSON.data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalVaultRepositoryError.invalidEntryPayload
        }
        return payload
    }
}

/// 跨条目引用（卡片/地址 ID）在 CSV 与备份里用分号连接成字符串，避免依赖数组解析。
func joinedVaultReferenceIdentifiers(_ identifiers: [String]) -> String {
    identifiers
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { $0.isEmpty == false }
        .joined(separator: ";")
}

func splitVaultReferenceIdentifiers(_ value: String) -> [String] {
    value
        .split(separator: ";")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { $0.isEmpty == false }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String {
        self[key] as? String ?? ""
    }

    func optionalString(_ key: String) -> String? {
        self[key] as? String
    }

    func bool(_ key: String) -> Bool {
        self[key] as? Bool ?? false
    }

    func int(_ key: String) -> Int {
        if let value = self[key] as? Int {
            return value
        }
        if let value = self[key] as? NSNumber {
            return value.intValue
        }
        return 0
    }

    func stringArray(_ key: String) -> [String] {
        if let values = self[key] as? [Any] {
            return values.compactMap { $0 as? String }.filter { $0.isEmpty == false }
        }
        if let joined = self[key] as? String {
            return splitVaultReferenceIdentifiers(joined)
        }
        return []
    }

    func int64(_ key: String) -> Int64 {
        if let value = self[key] as? Int64 {
            return value
        }
        if let value = self[key] as? Int {
            return Int64(value)
        }
        if let value = self[key] as? NSNumber {
            return value.int64Value
        }
        return 0
    }
}
